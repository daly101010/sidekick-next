-- F:/lua/SideKick/utils/rotation_engine.lua
-- Rotation Engine - Layered ability execution with priority ordering
-- Based on rgmercs pattern: Emergency > Aggro > Defenses > Burn > Combat

local mq = require('mq')

local M = {}

-- Lazy-load dependencies to avoid circular requires
local _Cache = nil
local function getCache()
    if not _Cache then
        local ok, c = pcall(require, 'utils.runtime_cache')
        if ok then _Cache = c end
    end
    return _Cache
end

local _Executor = nil
local function getExecutor()
    if not _Executor then
        local ok, e = pcall(require, 'utils.action_executor')
        if ok then _Executor = e end
    end
    return _Executor
end

local _Abilities = nil
local function getAbilities()
    if not _Abilities then
        local ok, a = pcall(require, 'utils.abilities')
        if ok then _Abilities = a end
    end
    return _Abilities
end

local _ConditionBuilder = nil
local function getConditionBuilder()
    if not _ConditionBuilder then
        local ok, cb = pcall(require, 'ui.condition_builder')
        if ok then _ConditionBuilder = cb end
    end
    return _ConditionBuilder
end

local _SpellRotation = nil
local function getSpellRotation()
    if not _SpellRotation then
        local ok, sr = pcall(require, 'utils.spell_rotation')
        if ok then _SpellRotation = sr end
    end
    return _SpellRotation
end

local _ConditionContext = nil
local function getConditionContext()
    if not _ConditionContext then
        local ok, cc = pcall(require, 'utils.condition_context')
        if ok then _ConditionContext = cc end
    end
    return _ConditionContext
end

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
    { name = 'aggro',      priority = 2, stepsPerTick = 1 },  -- Hate generation (tank only)
    { name = 'defenses',   priority = 3, stepsPerTick = 1 },  -- Defensive cooldowns
    { name = 'support',    priority = 4, stepsPerTick = 2 },  -- Support: self-heal > CC > debuffs (SHM/ENC/DRU/BRD/NEC)
    { name = 'burn',       priority = 5, stepsPerTick = 2 },  -- Burn abilities (when burning)
    { name = 'combat',     priority = 6, stepsPerTick = 1 },  -- Normal combat rotation
    { name = 'utility',    priority = 7, stepsPerTick = 1 },  -- Utility (misc)
}

-- Layer name -> definition lookup
M.layerByName = {}
for _, layer in ipairs(M.LAYERS) do
    M.layerByName[layer.name] = layer
end

-- Category -> Layer mapping
-- Abilities are assigned to layers based on their category tag
local CATEGORY_TO_LAYER = {
    emergency = 'emergency',
    defensive = 'defenses',
    defense = 'defenses',
    aggro = 'aggro',
    hate = 'aggro',
    taunt = 'aggro',
    -- Support layer: self-heals, CC, debuffs (for support classes)
    selfheal = 'support',
    groupheal = 'support',
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
    -- Utility layer (misc)
    utility = 'utility',
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
-- @return string Layer name
function M.getAbilityLayer(def, settings)
    if not def then return 'combat' end

    -- Check for explicit layer assignment in settings
    local layerKey = def.settingKey and (def.settingKey .. 'Layer')
    if layerKey and settings and settings[layerKey] then
        local layer = tostring(settings[layerKey]):lower()
        if M.layerByName[layer] then
            return layer
        end
    end

    -- Check category tag on ability definition
    if def.category then
        local mapped = CATEGORY_TO_LAYER[def.category:lower()]
        if mapped then return mapped end
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
    local name = layer.name

    -- If we're in "priority healing" state, skip damage-focused layers.
    if state and state.priorityHealingActive == true then
        if name == 'combat' or name == 'burn' then
            return false
        end
    end

    -- Emergency: only when HP is critical
    if name == 'emergency' then
        local hp = Cache and Cache.me.hp or 100
        local threshold = state.emergencyHpThreshold or 35
        return hp <= threshold
    end

    -- Aggro: only when tanking and in combat
    if name == 'aggro' then
        local isTanking = state.combatMode == 'tank'
        local inCombat = Cache and Cache.inCombat() or false
        return isTanking and inCombat
    end

    -- Defenses: in combat, optionally gated by HP or named
    if name == 'defenses' then
        local inCombat = Cache and Cache.inCombat() or false
        if not inCombat then return false end

        -- Run defenses if HP below threshold or fighting named
        -- Tanks use lower threshold (40%), non-tanks use higher (70%)
        local hp = Cache and Cache.me.hp or 100
        local isTanking = state.combatMode == 'tank'
        local defenseHpThreshold = isTanking and (state.tankDefenseHpThreshold or 40) or (state.defenseHpThreshold or 70)
        local isNamed = Cache and Cache.isTargetNamed() or false
        return hp <= defenseHpThreshold or isNamed
    end

    -- Support: for support classes (SHM/ENC/DRU/BRD/NEC/CLR) when in combat
    -- Handles: self-heals (if low), CC/mez, debuffs
    if name == 'support' then
        local inCombat = Cache and Cache.inCombat() or false
        if not inCombat then return false end

        -- Only run for support classes
        local myClass = state.myClass or ''
        if not SUPPORT_CLASSES[myClass] then return false end

        return true
    end

    -- Burn: only when burn is active
    if name == 'burn' then
        return state.burnActive == true
    end

    -- Combat: always runs in combat
    if name == 'combat' then
        local inCombat = Cache and Cache.inCombat() or false
        return inCombat
    end

    -- Utility: in combat
    if name == 'utility' then
        local inCombat = Cache and Cache.inCombat() or false
        return inCombat
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

    -- On-demand: never auto-fire (user must click)
    if mode == Abilities.MODE.ON_DEMAND or mode == Abilities.MODE.MANUAL then
        return false
    end

    -- On cooldown: always fire (if ready)
    if mode == Abilities.MODE.ON_CD then
        return true
    end

    -- On burn: only during burn
    if mode == Abilities.MODE.ON_BURN then
        return state.burnActive == true
    end

    -- On named: only against named mobs
    if mode == Abilities.MODE.ON_NAMED then
        local Cache = getCache()
        return Cache and Cache.isTargetNamed() or false
    end

    -- On condition: evaluate condition gate (user override OR class config default)
    if mode == Abilities.MODE.ON_CONDITION then
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

    return false
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
-- @return table Map of layer name -> array of abilities
function M.categorizeByLayer(abilities, settings)
    local byLayer = {}
    for _, layer in ipairs(M.LAYERS) do
        byLayer[layer.name] = {}
    end

    for _, def in ipairs(abilities) do
        if type(def) == 'table' then
            local layer = M.getAbilityLayer(def, settings)
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
    if not Abilities then return 0 end

    local executed = 0
    local maxSteps = layer.stepsPerTick or 1

    -- Sort by user priority
    local sorted = Abilities.sortByPriority(abilities)

    for _, def in ipairs(sorted) do
        if executed >= maxSteps then break end

        -- 1. Check master toggle by ability type (UseSpells, UseAAs, UseDiscs)
        if not M.checkMasterToggle(def, settings) then goto continue end

        -- 2. Check individual enabled toggle
        local enabled = def.settingKey and settings[def.settingKey] == true
        if not enabled then goto continue end

        -- 3. Check mode gate (includes condition evaluation for ON_CONDITION mode)
        if not M.checkModeGate(def, settings, state, ctx, classConfig) then goto continue end

        -- 4. Try to execute
        if M.tryExecute(def) then
            executed = executed + 1
        end

        ::continue::
    end

    return executed
end

--- Run full rotation through all layers
-- @param opts table Options: abilities, settings, burnActive, combatMode
function M.tick(opts)
    opts = opts or {}
    local abilities = opts.abilities or {}
    local settings = opts.settings or {}

    -- Early exit if all ability types are disabled
    if settings.UseSpells == false and settings.UseAAs == false and settings.UseDiscs == false then
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

    -- Build condition context once (shared across all layers)
    local ctx = nil
    local ConditionContext = getConditionContext()
    if ConditionContext then
        ctx = ConditionContext.build()
    end

    -- Load class config once (shared across all layers)
    local classConfig = getClassConfig(myClass)

    -- Categorize abilities by layer
    local byLayer = M.categorizeByLayer(abilities, settings)

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
        { name = 'aggro',     priority = 2, description = 'Hate generation (tank mode)' },
        { name = 'defenses',  priority = 3, description = 'Defensive cooldowns' },
        { name = 'support',   priority = 4, description = 'Support: self-heal > CC > debuffs (SHM/ENC/DRU/BRD/NEC/CLR)' },
        { name = 'burn',      priority = 5, description = 'Burn abilities (when burning)' },
        { name = 'combat',    priority = 6, description = 'Normal combat rotation' },
        { name = 'utility',   priority = 7, description = 'Utility abilities' },
    }
end

return M
