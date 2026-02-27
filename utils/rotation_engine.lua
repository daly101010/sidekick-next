-- F:/lua/SideKick/utils/rotation_engine.lua
-- Rotation Engine - Layered ability execution with priority ordering
-- Based on rgmercs pattern: Emergency > Aggro > Defenses > Burn > Combat

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

-- Lazy-load throttled logging
local getThrottledLog = lazy('sidekick-next.utils.throttled_log')

-- Enable/disable debug logging for rotation engine
M.debugLogging = false -- Set to true to enable layer/ability logging

-- Lazy-load dependencies to avoid circular requires
local getCache = lazy('sidekick-next.utils.runtime_cache')
local getExecutor = lazy('sidekick-next.utils.action_executor')
local getAbilities = lazy('sidekick-next.utils.abilities')
local getConditionBuilder = lazy('sidekick-next.ui.condition_builder')
local getSpellRotation = lazy('sidekick-next.utils.spell_rotation')
local getConditionContext = lazy('sidekick-next.utils.condition_context')
local getBuffLogger = lazy('sidekick-next.automation.buff_logger')

local _ClassConfigs = {}
local function getClassConfig(classShort)
    if not classShort or classShort == '' then return nil end
    classShort = classShort:upper()
    if _ClassConfigs[classShort] then
        return _ClassConfigs[classShort]
    end
    local ok, cfg = pcall(require, string.format('data.class_configs.%s', classShort))
    if ok and cfg then
        _ClassConfigs[classShort] = cfg
        return cfg
    end
    return nil
end

-- Layer definitions with priority (lower = higher priority)
-- Each layer processes before the next
M.LAYERS = {
    { name = 'emergency',  priority = 1, stepsPerTick = 2 },  -- Panic buttons (HP critical)
    { name = 'heal',       priority = 2, stepsPerTick = 2 },  -- Heals (anytime - not combat gated)
    { name = 'aggro',      priority = 3, stepsPerTick = 1 },  -- Hate generation (tank only)
    { name = 'defenses',   priority = 4, stepsPerTick = 1 },  -- Defensive cooldowns
    { name = 'support',    priority = 5, stepsPerTick = 2 },  -- Support: CC > debuffs (SHM/ENC/DRU/BRD/NEC)
    { name = 'burn',       priority = 6, stepsPerTick = 2 },  -- Burn abilities (when burning)
    { name = 'combat',     priority = 7, stepsPerTick = 1 },  -- Normal combat rotation
    { name = 'utility',    priority = 8, stepsPerTick = 1 },  -- Utility (misc)
    { name = 'buff',       priority = 9, stepsPerTick = 1 },  -- Buffs (out of combat only)
}

-- Layer name -> definition lookup
M.layerByName = {}
for _, layer in ipairs(M.LAYERS) do
    M.layerByName[layer.name] = layer
end

-- Category -> Layer mapping
-- Abilities are assigned to layers based on their category tag
-- NOTE: Categories from class_config Settings.Category are case-insensitive (lowercased)
local CATEGORY_TO_LAYER = {
    -- Emergency layer
    emergency = 'emergency',
    defensive = 'defenses',
    defense = 'defenses',
    -- Aggro layer
    aggro = 'aggro',
    hate = 'aggro',
    taunt = 'aggro',
    -- Heal layer: heals anytime (not combat gated)
    heal = 'heal',
    selfheal = 'heal',
    groupheal = 'heal',
    cure = 'heal',  -- Cures run like heals (anytime)
    -- Support layer: CC, debuffs (for support classes, in combat)
    cc = 'support',
    mez = 'support',
    debuff = 'support',
    slow = 'support',
    cripple = 'support',
    malo = 'support',
    tash = 'support',
    -- Burn layer
    burn = 'burn',
    offensive = 'burn',
    -- Combat layer
    combat = 'combat',
    dps = 'combat',
    nuke = 'combat',
    dot = 'combat',
    -- Utility layer (misc, in combat)
    utility = 'utility',
    rez = 'utility',  -- Rez is utility (in combat battle rez)
    mana = 'buff',    -- Mana regen runs out of combat with buffs
    -- Buff layer (out of combat)
    buff = 'buff',
    selfbuff = 'buff',
    groupbuff = 'buff',
    aura = 'buff',
}

-- Support classes that use the support layer (casters/priests only)
-- Melee classes (including hybrids) prioritize combat first
local SUPPORT_CLASSES = {
    SHM = true,  -- Shaman: heals, slow, cripple, malo
    ENC = true,  -- Enchanter: runes, mez, tash, slow
    DRU = true,  -- Druid: heals, debuffs
    NEC = true,  -- Necromancer: mez, debuffs
    CLR = true,  -- Cleric: heals
    WIZ = true,  -- Wizard: caster, may have utility
    MAG = true,  -- Magician: caster, malo
}
-- Excluded (melee - prioritize combat):
-- WAR, PAL, SHD, RNG, MNK, BRD, ROG, BST, BER

--- Determine which layer an ability belongs to
-- @param def table Ability definition
-- @param settings table Settings table
-- @param classConfig table Optional class config with Settings metadata
-- @return string Layer name
function M.getAbilityLayer(def, settings, classConfig)
    if not def then return 'combat' end

    -- Check for explicit layer assignment in settings
    local layerKey = def.settingKey and (def.settingKey .. 'Layer')
    if layerKey and settings and settings[layerKey] then
        local layer = tostring(settings[layerKey]):lower()
        if M.layerByName[layer] then
            return layer
        end
    end

    -- Check category tag on ability definition itself
    if def.category then
        local mapped = CATEGORY_TO_LAYER[def.category:lower()]
        if mapped then return mapped end
    end

    -- Check Category from class config Settings metadata (e.g., Settings.DoHaste.Category = "Buff")
    if classConfig and classConfig.Settings and def.settingKey then
        local settingMeta = classConfig.Settings[def.settingKey]
        if settingMeta and settingMeta.Category then
            local mapped = CATEGORY_TO_LAYER[settingMeta.Category:lower()]
            if mapped then return mapped end
        end
    end

    -- Check if marked for aggro use (tank abilities)
    local aggroKey = def.settingKey and (def.settingKey .. 'UseForAggro')
    if aggroKey and settings and settings[aggroKey] == true then
        return 'aggro'
    end

    -- Default to combat layer
    return 'combat'
end

--- Check if a layer should run this tick
-- @param layer table Layer definition
-- @param state table Current automation state
-- @return boolean True if layer should run
function M.shouldLayerRun(layer, state)
    local Cache = getCache()
    local TL = getThrottledLog()
    local name = layer.name

    -- If we're in "priority healing" state, skip damage-focused layers.
    if state and state.priorityHealingActive == true then
        if name == 'combat' or name == 'burn' then
            if M.debugLogging and TL then
                TL.log('layer_skip_' .. name, 10, 'Layer %s SKIP: priority healing active', name)
            end
            return false
        end
    end

    -- Emergency: only when HP is critical
    if name == 'emergency' then
        local hp = Cache and Cache.me.hp or 100
        local threshold = state.emergencyHpThreshold or 35
        local shouldRun = hp <= threshold
        if M.debugLogging and TL and shouldRun then
            TL.log('layer_emergency', 5, 'Layer EMERGENCY: HP=%d <= threshold=%d', hp, threshold)
        end
        return shouldRun
    end

    -- Heal: always runs (not combat gated) - heals should work anytime
    if name == 'heal' then
        if M.debugLogging and TL then
            TL.log('layer_heal', 10, 'Layer HEAL: always runs (not combat gated)')
        end
        return true
    end

    -- Aggro: only when tanking and in combat
    if name == 'aggro' then
        local isTanking = state.combatMode == 'tank'
        local inCombat = Cache and Cache.inCombat() or false
        local shouldRun = isTanking and inCombat
        if M.debugLogging and TL then
            TL.log('layer_aggro', 10, 'Layer AGGRO: tanking=%s, inCombat=%s -> %s', tostring(isTanking), tostring(inCombat), tostring(shouldRun))
        end
        return shouldRun
    end

    -- Defenses: in combat, optionally gated by HP or named
    if name == 'defenses' then
        local inCombat = Cache and Cache.inCombat() or false
        if not inCombat then
            if M.debugLogging and TL then
                TL.log('layer_defenses_ooc', 10, 'Layer DEFENSES: SKIP (not in combat)')
            end
            return false
        end

        -- Run defenses if HP below threshold or fighting named
        -- Tanks use lower threshold (40%), non-tanks use higher (70%)
        local hp = Cache and Cache.me.hp or 100
        local isTanking = state.combatMode == 'tank'
        local defenseHpThreshold = isTanking and (state.tankDefenseHpThreshold or 40) or (state.defenseHpThreshold or 70)
        local isNamed = Cache and Cache.isTargetNamed() or false
        local shouldRun = hp <= defenseHpThreshold or isNamed
        if M.debugLogging and TL then
            TL.log('layer_defenses', 10, 'Layer DEFENSES: hp=%d, threshold=%d, named=%s -> %s', hp, defenseHpThreshold, tostring(isNamed), tostring(shouldRun))
        end
        return shouldRun
    end

    -- Support: for support classes (SHM/ENC/DRU/BRD/NEC/CLR) when in combat
    -- Handles: self-heals (if low), CC/mez, debuffs
    if name == 'support' then
        local inCombat = Cache and Cache.inCombat() or false
        if not inCombat then
            if M.debugLogging and TL then
                TL.log('layer_support_ooc', 10, 'Layer SUPPORT: SKIP (not in combat)')
            end
            return false
        end

        -- Only run for support classes
        local myClass = state.myClass or ''
        if not SUPPORT_CLASSES[myClass] then
            if M.debugLogging and TL then
                TL.log('layer_support_class', 10, 'Layer SUPPORT: SKIP (class %s not a support class)', myClass)
            end
            return false
        end

        if M.debugLogging and TL then
            TL.log('layer_support', 10, 'Layer SUPPORT: class=%s, running', myClass)
        end
        return true
    end

    -- Burn: only when burn is active
    if name == 'burn' then
        local shouldRun = state.burnActive == true
        if M.debugLogging and TL then
            TL.log('layer_burn', 10, 'Layer BURN: active=%s', tostring(state.burnActive))
        end
        return shouldRun
    end

    -- Combat: always runs in combat
    if name == 'combat' then
        local inCombat = Cache and Cache.inCombat() or false
        if M.debugLogging and TL then
            TL.log('layer_combat', 10, 'Layer COMBAT: inCombat=%s', tostring(inCombat))
        end
        return inCombat
    end

    -- Utility: in combat
    if name == 'utility' then
        local inCombat = Cache and Cache.inCombat() or false
        if M.debugLogging and TL then
            TL.log('layer_utility', 10, 'Layer UTILITY: inCombat=%s', tostring(inCombat))
        end
        return inCombat
    end

    -- Buff: out of combat only (for rebuffing self/group)
    if name == 'buff' then
        local inCombat = Cache and Cache.inCombat() or false
        -- Only buff when not in combat
        if inCombat then
            if M.debugLogging and TL then
                TL.log('layer_buff_ic', 10, 'Layer BUFF: SKIP (in combat)')
            end
            return false
        end
        if M.debugLogging and TL then
            TL.log('layer_buff', 10, 'Layer BUFF: out of combat, running')
        end
        return true
    end

    return true
end

--- Check master toggles (UseSpells, UseAAs, UseDiscs)
-- @param def table Ability definition
-- @param settings table Settings table
-- @return boolean True if master toggle allows this ability type
function M.checkMasterToggle(def, settings)
    if not def then return false end

    local kind = def.kind or def.type or ''
    kind = tostring(kind):lower()

    -- Check master toggles based on ability type
    if kind == 'spell' then
        if settings.UseSpells == false then return false end
    elseif kind == 'aa' or kind == 'altability' then
        if settings.UseAAs == false then return false end
    elseif kind == 'disc' or kind == 'discipline' or kind == 'combat_ability' then
        if settings.UseDiscs == false then return false end
    end

    return true
end

--- Evaluate condition gate (user override OR class config default)
-- @param def table Ability definition
-- @param settings table Settings table
-- @param ctx table Condition context from condition_context.build()
-- @param classConfig table Class config with defaultConditions
-- @return boolean True if condition passes
function M.evaluateConditionGate(def, settings, ctx, classConfig)
    local cb = getConditionBuilder()

    -- 1. Check for user override in settings (from condition builder UI)
    local condKey = def.conditionKey or (def.modeKey and def.modeKey:gsub('Mode$', 'Condition'))
    local condData = condKey and settings[condKey]

    if cb and condData then
        local evalData = condData
        if type(condData) == 'string' and condData ~= '' then
            evalData = cb.deserialize and cb.deserialize(condData) or nil
        end
        if evalData and type(evalData) == 'table' then
            return cb.evaluate(evalData) == true
        end
    end

    -- 2. Fall back to class config default condition
    if classConfig and classConfig.defaultConditions and def.settingKey then
        local defaultCond = classConfig.defaultConditions[def.settingKey]
        if type(defaultCond) == 'function' then
            local ok, result = pcall(defaultCond, ctx)
            if ok then
                return result == true
            end
        end
    end

    -- 3. No condition defined = always execute when in ON_CONDITION mode
    return true
end

--- Check if an ability passes its mode gate
-- Mode types:
--   ON_DEMAND = never auto-fire (user must click)
--   ON_CONDITION = auto-fire based on layer + condition gate
--   ON_COOLDOWN = handled separately by mash queue (not in normal rotation)
-- @param def table Ability definition
-- @param settings table Settings table
-- @param state table Current automation state
-- @param ctx table Optional condition context (built if not provided)
-- @param classConfig table Optional class config (loaded if not provided)
-- @return boolean True if mode gate passes
function M.checkModeGate(def, settings, state, ctx, classConfig)
    local Abilities = getAbilities()
    if not Abilities then return false end

    local mode = def.modeKey and tonumber(settings[def.modeKey]) or Abilities.MODE.ON_DEMAND

    -- Only ON_CONDITION mode auto-fires through the rotation engine.
    -- Any other mode (ON_DEMAND, ON_COOLDOWN, or invalid values like 4) should not auto-fire here.
    -- ON_COOLDOWN is handled by the separate mash queue.
    if mode ~= Abilities.MODE.ON_CONDITION then
        return false
    end

    -- ON_CONDITION mode: evaluate condition gate (user override OR class config default)
    -- Note: category/layer context is already checked by shouldLayerRun()
    -- Build context if not provided
    if not ctx then
        local ConditionContext = getConditionContext()
        if ConditionContext then
            ctx = ConditionContext.build()
        else
            ctx = {}
        end
    end

    -- Load class config if not provided
    if not classConfig then
        classConfig = getClassConfig(state.myClass)
    end

    return M.evaluateConditionGate(def, settings, ctx, classConfig)
end

--- Try to execute an ability through the action executor
-- @param def table Ability definition
-- @return boolean True if executed
function M.tryExecute(def)
    local Executor = getExecutor()
    if not Executor then return false end

    return Executor.executeAbility(def)
end

--- Categorize abilities into layers
-- @param abilities table Array of ability definitions
-- @param settings table Settings table
-- @param classConfig table Optional class config with Settings metadata
-- @return table Map of layer name -> array of abilities
function M.categorizeByLayer(abilities, settings, classConfig)
    local byLayer = {}
    for _, layer in ipairs(M.LAYERS) do
        byLayer[layer.name] = {}
    end

    for _, def in ipairs(abilities) do
        if type(def) == 'table' then
            local layer = M.getAbilityLayer(def, settings, classConfig)
            table.insert(byLayer[layer], def)
        end
    end

    return byLayer
end

--- Run a single layer's rotation
-- @param layer table Layer definition
-- @param abilities table Array of abilities in this layer
-- @param settings table Settings table
-- @param state table Current automation state
-- @param ctx table Optional condition context (shared across layer)
-- @param classConfig table Optional class config (shared across layer)
-- @return number Number of abilities executed
function M.runLayer(layer, abilities, settings, state, ctx, classConfig)
    local Abilities = getAbilities()
    local TL = getThrottledLog()
    if not Abilities then return 0 end

    local executed = 0
    local maxSteps = layer.stepsPerTick or 1

    -- Log layer execution start
    if M.debugLogging and TL then
        TL.log('runLayer_' .. layer.name, 10, 'Running layer %s with %d abilities (max %d steps)', layer.name, #abilities, maxSteps)
    end

    -- Sort by user priority
    local sorted = Abilities.sortByPriority(abilities)

    for _, def in ipairs(sorted) do
        if executed >= maxSteps then break end

        local abilityName = def.settingKey or def.name or 'unknown'

        -- 1. Check master toggle by ability type (UseSpells, UseAAs, UseDiscs)
        if not M.checkMasterToggle(def, settings) then
            if M.debugLogging and TL then
                TL.log('ability_master_' .. abilityName, 15, '  %s: SKIP (master toggle disabled for %s)', abilityName, def.kind or 'unknown')
            end
            goto continue
        end

        -- 2. Check individual enabled toggle
        local enabled = def.settingKey and settings[def.settingKey] == true
        if not enabled then
            if M.debugLogging and TL then
                TL.log('ability_disabled_' .. abilityName, 15, '  %s: SKIP (setting disabled, key=%s, value=%s)', abilityName, tostring(def.settingKey), tostring(settings[def.settingKey]))
            end
            goto continue
        end

        -- 3. Check mode gate (includes condition evaluation for ON_CONDITION mode)
        if not M.checkModeGate(def, settings, state, ctx, classConfig) then
            if M.debugLogging and TL then
                local modeVal = def.modeKey and settings[def.modeKey] or 'nil'
                TL.log('ability_mode_' .. abilityName, 15, '  %s: SKIP (mode gate failed, modeKey=%s, mode=%s)', abilityName, tostring(def.modeKey), tostring(modeVal))
            end
            goto continue
        end

        -- 4. Try to execute
        if M.debugLogging and TL then
            TL.log('ability_exec_' .. abilityName, 5, '  %s: EXECUTING (all gates passed)', abilityName)
        end
        if def.sourceLayer ~= layer.name then
            def.sourceLayer = layer.name
        end
        if layer.name == 'buff' and tostring(def.kind or ''):lower() == 'spell' then
            local log = getBuffLogger()
            if log then
                log.info('rotation', 'Buff layer cast attempt: ability=%s spell=%s targetId=%d modeKey=%s settingKey=%s',
                    tostring(def.name or def.settingKey or 'unknown'), tostring(def.spellName or ''),
                    tonumber(def.targetId) or 0, tostring(def.modeKey or ''), tostring(def.settingKey or ''))
            end
        end
        if M.tryExecute(def) then
            executed = executed + 1
            if M.debugLogging and TL then
                TL.log('ability_success_' .. abilityName, 5, '  %s: SUCCESS', abilityName)
            end
            if layer.name == 'buff' and tostring(def.kind or ''):lower() == 'spell' then
                local log = getBuffLogger()
                if log then
                    log.info('rotation', 'Buff layer cast accepted: ability=%s spell=%s targetId=%d',
                        tostring(def.name or def.settingKey or 'unknown'), tostring(def.spellName or ''),
                        tonumber(def.targetId) or 0)
                end
            end
        else
            if M.debugLogging and TL then
                TL.log('ability_fail_' .. abilityName, 5, '  %s: FAILED (executor returned false)', abilityName)
            end
            if layer.name == 'buff' and tostring(def.kind or ''):lower() == 'spell' then
                local log = getBuffLogger()
                if log then
                    log.warn('rotation', 'Buff layer cast rejected: ability=%s spell=%s targetId=%d',
                        tostring(def.name or def.settingKey or 'unknown'), tostring(def.spellName or ''),
                        tonumber(def.targetId) or 0)
                end
            end
        end

        ::continue::
    end

    return executed
end

--- Run full rotation through all layers
-- @param opts table Options: abilities, settings, burnActive, combatMode
function M.tick(opts)
    local TL = getThrottledLog()
    opts = opts or {}
    local abilities = opts.abilities or {}
    local settings = opts.settings or {}

    -- Early exit if all ability types are disabled
    if settings.UseSpells == false and settings.UseAAs == false and settings.UseDiscs == false then
        if M.debugLogging and TL then
            TL.log('tick_disabled', 30, 'Rotation SKIP: all ability types disabled (UseSpells=%s, UseAAs=%s, UseDiscs=%s)',
                tostring(settings.UseSpells), tostring(settings.UseAAs), tostring(settings.UseDiscs))
        end
        return
    end

    -- Get character class
    local Cache = getCache()
    local myClass = (Cache and Cache.me and Cache.me.class) or ''
    if myClass == '' and mq.TLO.Me and mq.TLO.Me.Class and mq.TLO.Me.Class.ShortName then
        myClass = tostring(mq.TLO.Me.Class.ShortName() or ''):upper()
    end

    local state = {
        burnActive = opts.burnActive or opts.burn,
        combatMode = settings.CombatMode or 'off',
        myClass = myClass,
        emergencyHpThreshold = settings.EmergencyHpThreshold or 35,
        defenseHpThreshold = settings.DefenseHpThreshold or 70,
        tankDefenseHpThreshold = settings.TankDefenseHpThreshold or 40,
        tankSafeAECheck = settings.TankSafeAECheck or false,
        priorityHealingActive = opts.priorityHealingActive == true,
    }

    -- Log tick start
    if M.debugLogging and TL then
        local inCombat = Cache and Cache.inCombat() or false
        TL.log('tick_start', 10, 'Rotation tick: class=%s, combatMode=%s, inCombat=%s, abilities=%d',
            myClass, state.combatMode, tostring(inCombat), #abilities)
    end

    -- Load class config once (shared across all layers) - MUST be before categorizeByLayer
    local classConfig = getClassConfig(myClass)

    -- Categorize abilities by layer (needs classConfig for Settings.Category lookup)
    local byLayer = M.categorizeByLayer(abilities, settings, classConfig)

    -- Build condition context once (shared across all layers)
    local ctx = nil
    local ConditionContext = getConditionContext()
    if ConditionContext then
        ctx = ConditionContext.build()
    end

    -- Log layer categorization
    if M.debugLogging and TL then
        local layerCounts = {}
        for _, layer in ipairs(M.LAYERS) do
            local count = byLayer[layer.name] and #byLayer[layer.name] or 0
            if count > 0 then
                table.insert(layerCounts, layer.name .. '=' .. count)
            end
        end
        if #layerCounts > 0 then
            TL.log('tick_layers', 15, 'Ability layer counts: %s', table.concat(layerCounts, ', '))
        end
    end

    -- Process each layer in priority order
    for _, layer in ipairs(M.LAYERS) do
        if M.shouldLayerRun(layer, state) then
            local layerAbilities = byLayer[layer.name] or {}
            if #layerAbilities > 0 then
                M.runLayer(layer, layerAbilities, settings, state, ctx, classConfig)
            end
        end
    end

    -- Run spell rotation after AA/disc rotation
    local SpellRotation = getSpellRotation()
    if SpellRotation then
        SpellRotation.tick({
            spells = opts.spells or {},
            settings = settings,
            ctx = ctx,
            classConfig = classConfig,
        })
    end
end

--- Get layer info for UI display
-- @return table Array of layer info { name, priority, description }
function M.getLayerInfo()
    return {
        { name = 'emergency', priority = 1, description = 'Panic buttons when HP critical' },
        { name = 'heal',      priority = 2, description = 'Heals (anytime - not combat gated)' },
        { name = 'aggro',     priority = 3, description = 'Hate generation (tank mode)' },
        { name = 'defenses',  priority = 4, description = 'Defensive cooldowns' },
        { name = 'support',   priority = 5, description = 'Support: CC > debuffs (SHM/ENC/DRU/BRD/NEC/CLR)' },
        { name = 'burn',      priority = 6, description = 'Burn abilities (when burning)' },
        { name = 'combat',    priority = 7, description = 'Normal combat rotation' },
        { name = 'utility',   priority = 8, description = 'Utility abilities' },
        { name = 'buff',      priority = 9, description = 'Buffs (out of combat only)' },
    }
end

--- Get currently active layers based on current state
-- @param settings table Optional settings table for combat mode etc
-- @return table { active = { layerName = true }, inCombat = bool, hp = number }
function M.getActiveLayerState(settings)
    settings = settings or {}
    local Cache = getCache()

    local myClass = ''
    if Cache and Cache.me and Cache.me.class then
        myClass = Cache.me.class
    elseif mq.TLO.Me and mq.TLO.Me.Class and mq.TLO.Me.Class.ShortName then
        myClass = tostring(mq.TLO.Me.Class.ShortName() or ''):upper()
    end

    local state = {
        burnActive = settings.BurnActive or false,
        combatMode = settings.CombatMode or 'off',
        myClass = myClass,
        emergencyHpThreshold = settings.EmergencyHpThreshold or 35,
        defenseHpThreshold = settings.DefenseHpThreshold or 70,
        tankDefenseHpThreshold = settings.TankDefenseHpThreshold or 40,
    }

    local inCombat = Cache and Cache.inCombat() or false
    local hp = Cache and Cache.me.hp or 100
    local isNamed = Cache and Cache.isTargetNamed() or false

    local activeLayers = {}
    for _, layer in ipairs(M.LAYERS) do
        if M.shouldLayerRun(layer, state) then
            activeLayers[layer.name] = true
        end
    end

    return {
        active = activeLayers,
        inCombat = inCombat,
        hp = hp,
        isNamed = isNamed,
        myClass = myClass,
    }
end

--- Process mash queue (ON_COOLDOWN abilities)
-- These are instant abilities that fire whenever ready, checked after normal rotation.
-- Multiple can fire per tick since they're off-GCD.
-- @param opts table Options: abilities, settings
-- @return number Number of abilities executed
function M.processMashQueue(opts)
    opts = opts or {}
    local abilities = opts.abilities or {}
    local settings = opts.settings or {}

    local Abilities = getAbilities()
    if not Abilities then return 0 end

    local Cache = getCache()
    local inCombat = Cache and Cache.inCombat() or false

    local executed = 0

    for _, def in ipairs(abilities) do
        if type(def) ~= 'table' then goto continue end

        -- Only process ON_COOLDOWN mode abilities
        local mode = def.modeKey and tonumber(settings[def.modeKey]) or Abilities.MODE.ON_DEMAND
        if mode ~= Abilities.MODE.ON_COOLDOWN then goto continue end

        -- Check master toggle by ability type
        if not M.checkMasterToggle(def, settings) then goto continue end

        -- Check individual enabled toggle
        local enabled = def.settingKey and settings[def.settingKey] == true
        if not enabled then goto continue end

        -- Check context (Combat/Out of Combat/Anytime)
        local contextKey = def.settingKey and (def.settingKey .. 'Context')
        local context = contextKey and tonumber(settings[contextKey]) or Abilities.CONTEXT.COMBAT

        if context == Abilities.CONTEXT.COMBAT and not inCombat then
            goto continue
        elseif context == Abilities.CONTEXT.OUT_OF_COMBAT and inCombat then
            goto continue
        end
        -- ANYTIME passes regardless of combat state

        -- Try to execute (instant abilities, no GCD contention)
        if M.tryExecute(def) then
            executed = executed + 1
        end

        ::continue::
    end

    return executed
end

return M
