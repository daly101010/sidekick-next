-- F:/lua/sidekick-next/sk_dps.lua
-- DPS module for SideKick multi-script system.
-- Uses the active spell-set combat rotation instead of hardcoded class spell lines.

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local OffensiveTarget = require('sidekick-next.utils.offensive_target')
local CoordinationPolicy = require('sidekick-next.utils.coordination_policy')
local Cache = require('sidekick-next.utils.runtime_cache')

local module = ModuleBase.create('dps', lib.Priority.DPS)

-------------------------------------------------------------------------------
-- Runtime State
-------------------------------------------------------------------------------

local Config = {
    minManaPct = 0,
    minTargetHpPct = 1,
    spellSetReloadSeconds = 5,
    targetCacheMs = CoordinationPolicy.STATE_TTL_SECONDS.ACTOR_TARGET * 1000,
    actorTargetTtlSeconds = CoordinationPolicy.STATE_TTL_SECONDS.ACTOR_TARGET,
}

local _lastSpellSetLoadAt = 0
local _lastSpellSetPath = nil
local _lastReason = 'init'
local _lastExecuteReason = 'none'
local _lastExecuteAt = 0
local _lastCastAttempt = 'none'
local _lastCandidateDecisions = {}
local _lastCompletedRotation = {}
local _selectionCache = { atMs = 0, valid = false, action = nil, reason = nil }

local function commandEcho(fmt, ...)
    local msg
    if select('#', ...) > 0 then
        local ok, formatted = pcall(string.format, fmt, ...)
        msg = ok and formatted or tostring(fmt)
    else
        msg = tostring(fmt)
    end
    pcall(function()
        print(string.format('%s \ag[SK DPS]\ax %s', lib.timestampPrefix(), msg))
    end)
end

-------------------------------------------------------------------------------
-- Spell-set Loading
-------------------------------------------------------------------------------

local function loadSpellSets(force)
    local ok, Persistence = pcall(require, 'sidekick-next.utils.spellset_persistence')
    if not ok or not Persistence then return nil, 'spellset_persistence_unavailable' end

    local now = os.clock()
    local shouldLoad = force == true or not Persistence.loaded
        or (now - (_lastSpellSetLoadAt or 0)) >= Config.spellSetReloadSeconds

    if shouldLoad and Persistence.load then
        local loadOk, loaded = pcall(Persistence.load)
        if not loadOk or loaded ~= true then
            return nil, 'spellset_load_failed:' .. tostring(loaded)
        end
        _lastSpellSetLoadAt = now
        if Persistence.getConfigPath then
            local pathOk, path = pcall(Persistence.getConfigPath)
            if pathOk then _lastSpellSetPath = path end
        end
    end

    return Persistence, nil
end

local function getActiveSpellSet()
    local Persistence, reason = loadSpellSets(false)
    if not Persistence then return nil, reason, nil end
    local spellSet = Persistence.getActiveSet and Persistence.getActiveSet() or nil
    if not spellSet then
        return nil, 'no_active_spellset:' .. tostring(Persistence.activeSetName), Persistence
    end
    return spellSet, nil, Persistence
end

-------------------------------------------------------------------------------
-- Spell Helpers
-------------------------------------------------------------------------------

local function isSpellReady(slot, spellName)
    local me = mq.TLO.Me
    if not (me and me()) then return false end

    local gem = me.Gem(slot)
    if not (gem and gem()) then return false end

    if spellName and spellName ~= '' then
        return lib.safeTLO(function() return me.SpellReady(spellName)() end, false) == true
    end

    return lib.safeTLO(function() return me.SpellReady(slot)() end, false) == true
end

local function getSpellCastTime(spellName)
    if not spellName then return 0 end
    local spell = mq.TLO.Spell(spellName)
    if not (spell and spell()) then return 0 end
    return lib.safeNum(function() return spell.MyCastTime() end, 0) / 1000
end

local function isUtilityGem(config)
    local utility = config and config.utility
    return utility and (utility.combat == true or utility.ooc == true)
end

-- DPS owns damage spells only. Persistent debuffs and dispels are selected by
-- sk_debuff at its fixed, higher coordinator tier.
local function dpsOwnsSpellType(spellType)
    spellType = tostring(spellType or ''):lower()
    return spellType == 'direct_damage' or spellType == 'dot'
end

local function ownerForSpellType(spellType)
    spellType = tostring(spellType or ''):lower()
    if spellType == 'buff' then return 'buffs' end
    if spellType == 'pet' then return 'resources_when_enabled' end
    if spellType == 'heal' then return 'healing' end
    if spellType == 'debuff' or spellType == 'dispel' then return 'debuff' end
    return dpsOwnsSpellType(spellType) and 'dps' or 'unassigned'
end

-------------------------------------------------------------------------------
-- Target Selection
-------------------------------------------------------------------------------

local function isCombatTargetActive(target)
    return OffensiveTarget.isCombatActive(target)
end

local function getMATarget()
    return OffensiveTarget.select(module, {
        actorTargetTtlSeconds = Config.actorTargetTtlSeconds,
        targetCacheMs = Config.targetCacheMs,
    })
end

local function spellNeedsNpcTarget(entry)
    local spellType = tostring(entry and entry.spellType or ''):lower()
    if spellType == 'debuff' or spellType == 'dot' or spellType == 'direct_damage'
        or spellType == 'dispel' then
        return true
    end

    local buffTargetType = entry and entry.config and entry.config.buffTarget and entry.config.buffTarget.type or ''
    buffTargetType = tostring(buffTargetType):lower()
    return buffTargetType == 'npc' or buffTargetType == 'npc_target' or buffTargetType == 'current_npc'
end

local function shouldSkipExistingEffect(entry, targetId)
    if not entry or not targetId or targetId <= 0 then return false end

    local spellType = tostring(entry.spellType or ''):lower()
    if spellType ~= 'debuff' and spellType ~= 'dot' then
        return false
    end

    local spawn = mq.TLO.Spawn(targetId)
    if not (spawn and spawn()) then return false end

    local spellName = entry.spellName
    if spellName and spellName ~= '' then
        local byName = spawn.Buff(spellName)
        if byName and byName() and byName.ID and byName.ID() then
            local duration = byName.Duration and tonumber(byName.Duration()) or 0
            if duration == nil or duration > 0 then
                return true, 'effect_present_name'
            end
        end
    end

    local spellId = tonumber(entry.spellId) or 0
    if spellId > 0 then
        local byId = spawn.Buff(spellId)
        if byId and byId() and byId.ID and byId.ID() then
            local duration = byId.Duration and tonumber(byId.Duration()) or 0
            if duration == nil or duration > 0 then
                return true, 'effect_present_id'
            end
        end
    end

    -- StacksTarget only evaluates against current target. If we already have
    -- the intended mob targeted, use it as a fallback for same-line effects
    -- where the landed debuff may have a different spell ID/name than the cast.
    local currentId = lib.safeNum(function() return mq.TLO.Target.ID() end, 0)
    if spellName and currentId == targetId then
        local spell = mq.TLO.Spell(spellName)
        if spell and spell() and spell.StacksTarget then
            local stacks = lib.safeTLO(function() return spell.StacksTarget() end, true)
            if stacks == false then
                return true, 'effect_not_stackable'
            end
        end
    end

    return false
end

-------------------------------------------------------------------------------
-- Spell Selection
-------------------------------------------------------------------------------

local function getCombatExec()
    local ok, CombatExec = pcall(require, 'sidekick-next.utils.combat_spell_executor')
    if ok then return CombatExec end
    return nil
end

local function buildConditionContext(targetId, combatActive)
    local ok, ConditionContext = pcall(require, 'sidekick-next.utils.condition_context')
    if not ok or not ConditionContext or not ConditionContext.build then return nil end

    local ctx = ConditionContext.build()
    ctx = ctx or {}
    ctx.inCombat = combatActive == true
    ctx.myHp = lib.safeNum(function() return mq.TLO.Me.PctHPs() end, 100)
    ctx.myMana = lib.safeNum(function() return mq.TLO.Me.PctMana() end, 100)
    ctx.myEndurance = lib.safeNum(function() return mq.TLO.Me.PctEndurance() end, 100)
    ctx.isInvis = lib.safeTLO(function() return mq.TLO.Me.Invis() end, false) == true
    ctx.pctAggro = lib.safeNum(function() return mq.TLO.Me.PctAggro() end, 0)
    if targetId and targetId > 0 then
        ctx.targetId = targetId
        local spawn = mq.TLO.Spawn(targetId)
        if spawn and spawn() then
            ctx.targetHp = lib.safeNum(function() return spawn.PctHPs() end, 100)
            ctx.targetLevel = lib.safeNum(function() return spawn.Level() end, 0)
            ctx.targetDistance = lib.safeNum(function() return spawn.Distance() end, 999)
            ctx.targetNamed = lib.safeTLO(function() return spawn.Named() end, false) == true
            ctx.targetType = lib.safeTLO(function() return spawn.Type() end, '')
            ctx.targetName = lib.safeTLO(function() return spawn.CleanName() end, '')
            ctx.targetClass = lib.safeTLO(function() return spawn.Class.ShortName() end, '')
            ctx.targetSlowed = lib.safeTLO(function()
                local raw = spawn.Slowed()
                return raw ~= nil and raw ~= '' and raw ~= false
            end, false) == true
            ctx.targetRooted = lib.safeTLO(function()
                local raw = spawn.Rooted()
                return raw ~= nil and raw ~= '' and raw ~= false
            end, false) == true
            ctx.targetMezzed = lib.safeTLO(function()
                local raw = spawn.Mezzed()
                return raw ~= nil and raw ~= '' and raw ~= false
            end, false) == true
            ctx.targetSnared = lib.safeTLO(function()
                local raw = spawn.Snared()
                return raw ~= nil and raw ~= '' and raw ~= false
            end, false) == true
        end
    end
    return ctx
end

local function rotationKey(entry)
    return string.format('%s:%s', tostring(entry and entry.spellId or 0),
        tostring(entry and entry.slot or 0))
end

local function rotationGroup(activeSet, priority)
    return string.format('%s:%s', tostring(activeSet or ''), tostring(priority or 0))
end

-- Equal-priority entries are round-robin after a successful cast. Explicit
-- priority differences remain strict, while default same-type entries no longer
-- let the lowest gem slot monopolize the rotation.
local function getFairCastList(castList, activeSet)
    local result = {}
    local index = 1
    while index <= #castList do
        local groupEnd = index
        local priority = castList[index].priority
        while groupEnd < #castList and castList[groupEnd + 1].priority == priority do
            groupEnd = groupEnd + 1
        end

        local start = index
        local group = rotationGroup(activeSet, priority)
        local lastKey = _lastCompletedRotation[group]
        if lastKey then
            for i = index, groupEnd do
                if rotationKey(castList[i]) == lastKey then
                    start = i + 1
                    if start > groupEnd then start = index end
                    break
                end
            end
        end

        for offset = 0, groupEnd - index do
            local source = start + offset
            if source > groupEnd then source = index + (source - groupEnd - 1) end
            result[#result + 1] = castList[source]
        end
        index = groupEnd + 1
    end
    return result
end

local function computeSpellSelection()
    _lastCandidateDecisions = {}
    local spellSet, reason, Persistence = getActiveSpellSet()
    if not spellSet then return nil, reason end

    local target = getMATarget()
    if not target then return nil, 'no_target' end
    local combatActive = isCombatTargetActive(target)
    if not combatActive then
        OffensiveTarget.clear(module)
        return nil, 'no_combat'
    end
    if target.hp < Config.minTargetHpPct then return nil, 'target_low_hp' end
    local moving = lib.safeTLO(function() return mq.TLO.Me.Moving() end, false) == true
    local navActive = lib.safeTLO(function()
        return mq.TLO.Navigation and mq.TLO.Navigation.Active
            and mq.TLO.Navigation.Active()
    end, false) == true
    local class = tostring(lib.safeTLO(function()
        return mq.TLO.Me.Class.ShortName()
    end, '') or ''):upper()
    if class ~= 'BRD' and (moving or navActive) then return nil, 'moving' end

    local mana = lib.safeNum(function() return mq.TLO.Me.PctMana() end, 0)
    if mana < Config.minManaPct then return nil, 'low_mana' end

    -- DPS mana floor (DpsMinManaPct, UI: Automation tab). Debuffs have their
    -- own worker and are not suppressed by this damage-only threshold.
    local manaFloor = 0
    do
        local okCore, Core = pcall(require, 'sidekick-next.utils.core')
        if okCore and Core and Core.Settings then
            manaFloor = tonumber(Core.Settings.DpsMinManaPct) or 0
        end
    end
    local manaLow = manaFloor > 0 and mana < manaFloor

    local CombatExec = getCombatExec()
    if not CombatExec or not CombatExec.getSortedCastList then
        return nil, 'combat_executor_unavailable'
    end

    local castList = CombatExec.getSortedCastList(spellSet)
    if #castList == 0 then
        return nil, 'empty_cast_list:' .. tostring(Persistence and Persistence.activeSetName or '')
    end

    local activeSet = Persistence and Persistence.activeSetName or nil
    castList = getFairCastList(castList, activeSet)
    local ctx = buildConditionContext(target.id, combatActive)
    local firstSkip = nil
    local selectedAction = nil
    for _, entry in ipairs(castList) do
        local decision = {
            slot = tonumber(entry and entry.slot) or 0,
            spellName = tostring(entry and entry.spellName or ''),
            spellType = tostring(entry and entry.spellType or ''),
            priority = tonumber(entry and entry.priority) or 0,
            ready = false,
            condition = false,
            allowed = false,
            selected = false,
            reason = 'invalid_entry',
        }
        _lastCandidateDecisions[#_lastCandidateDecisions + 1] = decision

        if not entry or not entry.slot then
            firstSkip = firstSkip or 'invalid_entry'
        elseif isUtilityGem(entry.config) then
            decision.reason = 'utility'
            firstSkip = firstSkip or ('utility:' .. tostring(entry.spellName))
        elseif not dpsOwnsSpellType(entry.spellType) then
            decision.reason = 'owned_by_' .. ownerForSpellType(entry.spellType)
            firstSkip = firstSkip or (decision.reason .. ':' .. tostring(entry.spellName))
        else
            if manaLow then
                decision.reason = 'mana_floor'
                firstSkip = firstSkip or ('mana_floor:' .. tostring(entry.spellName))
                goto continue_entry
            end
            local targetId = spellNeedsNpcTarget(entry) and target.id or nil
            decision.ready = isSpellReady(entry.slot, entry.spellName)
            if decision.ready then
                local conditionOk = true
                if CombatExec.evaluateCondition then
                    local ok, value = pcall(CombatExec.evaluateCondition, entry.config, ctx)
                    conditionOk = ok and value == true
                    if not ok then decision.conditionError = tostring(value) end
                end
                decision.condition = conditionOk
                if conditionOk then
                    local skipEffect, effectReason = shouldSkipExistingEffect(entry, targetId)
                    if skipEffect then
                        decision.reason = effectReason or 'effect_present'
                        firstSkip = firstSkip or (effectReason .. ':' .. tostring(entry.spellName))
                    else
                        local allowed, intelReason, intelDetails = true, 'eligible', nil
                        if CombatExec.evaluateDamageCandidate then
                            local ok, value, why, details = pcall(
                                CombatExec.evaluateDamageCandidate,
                                entry.spellType, entry.spellName, targetId)
                            if ok then
                                allowed = value == true
                                intelReason = tostring(why or (allowed and 'eligible' or 'intelligence_rejected'))
                                intelDetails = details
                            else
                                -- Intelligence must fail open; record the error for diagnostics.
                                intelReason = 'intelligence_error'
                                decision.intelligenceError = tostring(value)
                            end
                        end
                        decision.intelligence = intelReason
                        decision.intel = intelDetails
                        if not allowed then
                            decision.reason = intelReason
                            firstSkip = firstSkip
                                or (intelReason .. ':' .. tostring(entry.spellName))
                        elseif not selectedAction then
                            decision.allowed = true
                            decision.selected = true
                            decision.reason = 'selected'
                            selectedAction = {
                                slot = entry.slot,
                                spellName = entry.spellName,
                                spellType = entry.spellType,
                                targetId = targetId,
                                targetName = target.name,
                                activeSet = activeSet,
                                rotationGroup = rotationGroup(activeSet, entry.priority),
                                rotationKey = rotationKey(entry),
                                rotationPriority = entry.priority,
                            }
                        else
                            decision.allowed = true
                            decision.reason = 'eligible_after_selected'
                        end
                    end
                else
                    decision.reason = decision.conditionError and 'condition_error' or 'condition_false'
                    firstSkip = firstSkip or ('condition_false:' .. tostring(entry.spellName))
                end
            else
                decision.reason = 'not_ready'
                firstSkip = firstSkip or ('not_ready:' .. tostring(entry.spellName))
            end
        end
        ::continue_entry::
    end

    if selectedAction then return selectedAction, nil end
    return nil, firstSkip or 'no_eligible_spell'
end

local function selectSpell()
    local now = lib.getTimeMs()
    if _selectionCache.valid and (now - (_selectionCache.atMs or 0)) <= 75 then
        return _selectionCache.action, _selectionCache.reason
    end
    local action, reason = computeSpellSelection()
    _selectionCache = {
        atMs = now,
        valid = true,
        action = action,
        reason = reason,
    }
    return action, reason
end

local function debugList()
    local spellSet, reason, Persistence = getActiveSpellSet()
    if not spellSet then
        commandEcho('list: no spell set: %s', tostring(reason))
        return
    end

    local target = getMATarget()
    local CombatExec = getCombatExec()
    if not CombatExec or not CombatExec.getSortedCastList then
        commandEcho('list: combat executor unavailable')
        return
    end

    local combatActive = target and isCombatTargetActive(target) or false
    local ctx = target and buildConditionContext(target.id, combatActive) or nil
    local castList = CombatExec.getSortedCastList(spellSet)
    castList = getFairCastList(castList, Persistence and Persistence.activeSetName or nil)
    commandEcho('list: activeSet=%s gems=%d target=%s targetHp=%s targetSource=%s actorCombat=%s combatActive=%s path=%s',
        tostring(Persistence and Persistence.activeSetName or nil),
        #castList,
        target and tostring(target.id) or 'none',
        target and tostring(target.hp) or 'none',
        target and tostring(target.source) or 'none',
        tostring(target and target.coordinatedCombat == true),
        tostring(combatActive),
        tostring(_lastSpellSetPath))

    if #castList == 0 then
        commandEcho('list: empty cast list')
        return
    end

    for _, entry in ipairs(castList) do
        local utility = isUtilityGem(entry.config)
        local routedElsewhere = not dpsOwnsSpellType(entry.spellType)
        local ready = entry and entry.slot and isSpellReady(entry.slot, entry.spellName) or false
        local conditionOk = false
        local conditionReason = ''
        if utility then
            conditionReason = 'utility'
        elseif routedElsewhere then
            conditionReason = 'owned_by_' .. ownerForSpellType(entry.spellType)
        elseif not target then
            conditionReason = 'no_target'
        elseif not combatActive then
            conditionReason = 'no_combat'
        elseif not ready then
            conditionReason = 'not_ready'
        else
            conditionOk = true
            if CombatExec.evaluateCondition then
                local ok, result = pcall(CombatExec.evaluateCondition, entry.config, ctx)
                conditionOk = ok and result == true
                if not ok then
                    conditionReason = 'condition_error:' .. tostring(result)
                elseif not conditionOk then
                    conditionReason = 'condition_false'
                else
                    local targetId = spellNeedsNpcTarget(entry) and target.id or nil
                    local skipEffect, effectReason = shouldSkipExistingEffect(entry, targetId)
                    if skipEffect then
                        conditionOk = false
                        conditionReason = effectReason or 'effect_present'
                    else
                        conditionReason = 'eligible'
                        if CombatExec.evaluateDamageCandidate then
                            local ok, allowed, intelReason = pcall(
                                CombatExec.evaluateDamageCandidate,
                                entry.spellType, entry.spellName, targetId)
                            if not ok then
                                conditionReason = 'intelligence_error:' .. tostring(allowed)
                            elseif allowed ~= true then
                                conditionOk = false
                                conditionReason = tostring(intelReason or 'intelligence_rejected')
                            else
                                conditionReason = tostring(intelReason or 'eligible')
                            end
                        end
                    end
                end
            else
                conditionReason = 'eligible_no_condition_api'
            end
        end

        commandEcho(
            'list: gem=%s spell=%s type=%s owner=%s priority=%s targetNpc=%s ready=%s condition=%s skip=%s',
            tostring(entry.slot),
            tostring(entry.spellName),
            tostring(entry.spellType),
            tostring(ownerForSpellType(entry.spellType)),
            tostring(entry.priority),
            tostring(spellNeedsNpcTarget(entry)),
            tostring(ready),
            tostring(conditionOk),
            tostring(conditionReason))
    end
end

local function debugActorTargets()
    local team = module.state and module.state.team or nil
    if type(team) ~= 'table' then
        commandEcho('actors: no Actor Team snapshot')
        return
    end
    local settings = lib.getSettings() or {}
    commandEcho('actors: enabled=%s team=%s leader=%s members=%d assistMode=%s assistName=%s',
        tostring(team.enabled), tostring(team.label or team.teamId or ''),
        tostring(team.leader or ''), #(team.members or {}),
        tostring(settings.AssistMode or 'group'), tostring(settings.AssistName or ''))
    for _, member in ipairs(team.members or {}) do
        commandEcho('actors: name=%s self=%s role=%s zone=%s age=%sms combat=%s target=%s type=%s targetName=%s',
            tostring(member.character or ''), tostring(member.self == true),
            tostring(member.role or ''),
            tostring(member.zone or ''), tostring(member.ageMs or 0),
            tostring(member.inCombat == true), tostring(member.targetId or 0),
            tostring(member.targetType or ''), tostring(member.targetName or ''))
    end
end

-------------------------------------------------------------------------------
-- Coordinated DPS intelligence lifecycle
-------------------------------------------------------------------------------

local _intel = {}
local _sessionDamageBatch = {}
local _lastSessionDamageSendAt = 0
local _lastIntelTelemetryAt = 0
local _lastIntelCatalogAt = 0
local SESSION_DAMAGE_BATCH_MS = 250
local SESSION_DAMAGE_BATCH_MAX = 50
local INTEL_TELEMETRY_MS = 1000
local INTEL_CATALOG_MS = 10000

local function flushSessionDamage(self, force)
    if #_sessionDamageBatch == 0 or not self or not self.sendToLocalUi then return end
    local now = lib.getTimeMs()
    if not force and #_sessionDamageBatch < SESSION_DAMAGE_BATCH_MAX
        and (now - _lastSessionDamageSendAt) < SESSION_DAMAGE_BATCH_MS then
        return
    end
    local batch = _sessionDamageBatch
    _sessionDamageBatch = {}
    _lastSessionDamageSendAt = now
    self:sendToLocalUi('session:damage', { events = batch })
end

local function initDpsIntelligence()
    -- Ensure DamageObserver/CombatMode are loaded before damage_events chooses
    -- lean versus full registration scope.
    lib.getSettings()
    local specs = {
        { key = 'damageEvents', path = 'sidekick-next.utils.damage_events' },
        { key = 'dps', path = 'sidekick-next.utils.dps_intelligence' },
        { key = 'spellDamage', path = 'sidekick-next.utils.spell_damage_tracker' },
        { key = 'mobHp', path = 'sidekick-next.utils.mob_hp_estimator' },
        { key = 'resist', path = 'sidekick-next.utils.resist_tracker' },
    }
    for _, spec in ipairs(specs) do
        local ok, mod = pcall(require, spec.path)
        if ok and mod then
            _intel[spec.key] = mod
            if mod.init then
                local initOk, err = pcall(mod.init)
                if not initOk then
                    _intel[spec.key] = nil
                    commandEcho('intelligence init failed: %s: %s', spec.key, tostring(err))
                end
            end
        else
            commandEcho('intelligence module unavailable: %s', spec.key)
        end
    end
    local damageEvents = _intel.damageEvents
    if damageEvents and damageEvents.addListener then
        damageEvents.addListener(function(event)
            if type(event) ~= 'table' then return end
            if #_sessionDamageBatch >= 400 then table.remove(_sessionDamageBatch, 1) end
            _sessionDamageBatch[#_sessionDamageBatch + 1] = {
                target = tostring(event.target or ''),
                amount = tonumber(event.amount) or 0,
                mine = event.mine == true,
                attacker = tostring(event.attacker or ''),
                kind = tostring(event.kind or ''),
                spell = tostring(event.spell or ''),
            }
        end)
    end
end

local function sendIntelTelemetry(self, action, reason)
    if not self or not self.sendToLocalUi then return end
    local now = lib.getTimeMs()
    if (now - _lastIntelTelemetryAt) < INTEL_TELEMETRY_MS then return end
    _lastIntelTelemetryAt = now

    local settings = lib.getSettings() or {}
    local target = getMATarget()
    local combatActive = target and isCombatTargetActive(target) or false
    local payload = {
        capturedAtMs = now,
        reason = tostring(reason or ''),
        action = action and {
            spellName = tostring(action.spellName or ''),
            spellType = tostring(action.spellType or ''),
            slot = tonumber(action.slot) or 0,
            activeSet = tostring(action.activeSet or ''),
            rotationPriority = tonumber(action.rotationPriority) or 0,
        } or nil,
        observerScope = _intel.damageEvents and _intel.damageEvents.getScope
            and tostring(_intel.damageEvents.getScope() or '') or '',
        modules = {
            dps = _intel.dps ~= nil,
            resist = _intel.resist ~= nil,
            mobHp = _intel.mobHp ~= nil,
            spellDamage = _intel.spellDamage ~= nil,
            damageEvents = _intel.damageEvents ~= nil,
        },
        elementResists = {},
        spellResists = {},
        candidates = _lastCandidateDecisions,
    }

    if target then
        local spawn = mq.TLO.Spawn(target.id)
        local targetName = tostring(lib.safeTLO(function()
            return spawn and spawn() and spawn.CleanName() or ''
        end, '') or '')
        local pctHp = lib.safeNum(function()
            return spawn and spawn() and spawn.PctHPs() or target.hp
        end, tonumber(target.hp) or 0)
        payload.target = {
            id = tonumber(target.id) or 0,
            name = targetName,
            pctHp = pctHp,
            source = tostring(target.source or ''),
            combatActive = combatActive == true,
            coordinatedCombat = target.coordinatedCombat == true,
        }

        local dps = _intel.dps
        if dps then
            if dps.getTTD then
                local ok, ttd, source = pcall(dps.getTTD, target.id)
                if ok then
                    payload.target.ttd = tonumber(ttd)
                    payload.target.ttdSource = tostring(source or 'unknown')
                end
            end
            if dps.getRemainingHP then
                local ok, remaining, weight = pcall(dps.getRemainingHP, target.id)
                if ok then
                    payload.target.remainingHp = tonumber(remaining)
                    payload.target.hpWeight = tonumber(weight) or 0
                end
            end
            local defaultNuke = tonumber(settings.DpsDefaultNukeCastTime) or 3
            local defaultDot = tonumber(settings.DpsDefaultDotDuration) or 24
            if dps.nukeViable then
                local ok, value = pcall(dps.nukeViable, target.id, defaultNuke)
                if ok then payload.target.nukeViable = value == true end
            end
            if dps.dotViable then
                local ok, value = pcall(dps.dotViable, target.id, defaultDot)
                if ok then payload.target.dotViable = value == true end
            end
            if dps.rainViable then
                local ok, value = pcall(dps.rainViable, target.id, defaultNuke)
                if ok then payload.target.rainViable = value == true end
            end
            if dps.rainSafe then
                local ok, value = pcall(dps.rainSafe, target.id)
                if ok then payload.target.rainSafe = value == true end
            end
        end

        local mobHp = _intel.mobHp
        if mobHp and mobHp.getMaxHP then
            local ok, maxHp, weight = pcall(mobHp.getMaxHP, target.id)
            if ok then
                payload.target.maxHp = tonumber(maxHp)
                payload.target.hpWeight = math.max(
                    tonumber(payload.target.hpWeight) or 0,
                    tonumber(weight) or 0)
            end
        end

        local resist = _intel.resist
        local mobStats = resist and resist.zoneStats and resist.zoneStats[targetName] or nil
        if type(mobStats) == 'table' then
            for element, stats in pairs(mobStats) do
                if type(stats) == 'table' then
                    local landed = tonumber(stats.landed) or 0
                    local resisted = tonumber(stats.resisted) or 0
                    local samples = landed + resisted
                    local effCount = tonumber(stats.effCount) or 0
                    local avoid = false
                    if resist.shouldAvoid then
                        local ok, value = pcall(resist.shouldAvoid, targetName, element, settings)
                        avoid = ok and value == true
                    end
                    payload.elementResists[#payload.elementResists + 1] = {
                        element = tostring(element),
                        landed = landed,
                        resisted = resisted,
                        samples = samples,
                        resistPct = samples > 0 and (resisted / samples * 100) or nil,
                        efficiencyPct = effCount > 0
                            and ((tonumber(stats.effSum) or 0) / effCount * 100) or nil,
                        efficiencySamples = effCount,
                        avoid = avoid,
                    }
                end
            end
        end

        local okLog, resistLog = pcall(require, 'sidekick-next.utils.resist_log')
        if okLog and resistLog then
            if resistLog.load then pcall(resistLog.load) end
            if resistLog.getPolicy then
                local ok, policy = pcall(resistLog.getPolicy)
                if ok and type(policy) == 'table' then payload.resistPolicy = policy end
            end
            if resistLog.iterZone then
                for mobName, spellName, record in resistLog.iterZone() do
                    if tostring(mobName):lower() == targetName:lower() then
                        local skip, skipReason = false, nil
                        if resistLog.shouldSkip then
                            local ok, value, why = pcall(resistLog.shouldSkip, spellName, targetName)
                            if ok then
                                skip = value == true
                                skipReason = why
                            end
                        end
                        local consecutive = 0
                        if resistLog.getConsecutiveResists then
                            local ok, count = pcall(
                                resistLog.getConsecutiveResists, nil, targetName, spellName)
                            if ok then consecutive = tonumber(count) or 0 end
                        end
                        payload.spellResists[#payload.spellResists + 1] = {
                            spellName = tostring(spellName),
                            casts = tonumber(record and record.casts) or 0,
                            resists = tonumber(record and record.resists) or 0,
                            lastResistAt = tonumber(record and record.lastResistAt) or 0,
                            consecutiveResists = consecutive,
                            skip = skip,
                            skipReason = tostring(skipReason or ''),
                        }
                    end
                end
            end
        end
    end

    local spellDamage = _intel.spellDamage
    if spellDamage and spellDamage.getDiagnostics then
        local ok, diagnostics = pcall(spellDamage.getDiagnostics)
        if ok and type(diagnostics) == 'table' then
            payload.spellDamageDiagnostics = diagnostics
        end
    end
    if spellDamage and type(spellDamage.data) == 'table'
        and (now - _lastIntelCatalogAt) >= INTEL_CATALOG_MS then
        _lastIntelCatalogAt = now
        payload.spellDamage = {}
        for spellName, record in pairs(spellDamage.data) do
            if type(record) == 'table' then
                payload.spellDamage[#payload.spellDamage + 1] = {
                    spellName = tostring(spellName),
                    count = tonumber(record.count) or 0,
                    expected = tonumber(record.ema) or 0,
                    maxSeen = tonumber(record.maxSeen) or 0,
                    baseline = spellDamage.getBaseline
                        and tonumber(spellDamage.getBaseline(spellName)) or nil,
                }
            end
        end
    end

    self:sendToLocalUi('intel:telemetry', payload)
end

local function tickDpsIntelligence(self)
    local damageEvents = _intel.damageEvents
    if damageEvents and damageEvents.ensureScope then
        pcall(damageEvents.ensureScope)
    end
    local resist = _intel.resist
    if resist then
        if resist.loadZone then pcall(resist.loadZone) end
        if resist.tick then pcall(resist.tick) end
    end
    local mobHp = _intel.mobHp
    if mobHp then
        if mobHp.loadZone then pcall(mobHp.loadZone) end
        if mobHp.tick then pcall(mobHp.tick) end
    end
    local spellDamage = _intel.spellDamage
    if spellDamage and spellDamage.tick then pcall(spellDamage.tick) end
    flushSessionDamage(self, false)
end

local function shutdownDpsIntelligence()
    for _, key in ipairs({ 'resist', 'mobHp', 'spellDamage', 'damageEvents' }) do
        local mod = _intel[key]
        if mod and mod.shutdown then pcall(mod.shutdown) end
    end
end

-------------------------------------------------------------------------------
-- Module Callbacks
-------------------------------------------------------------------------------

module.onTick = function(self)
    Cache.setSettings(lib.getSettings())
    if not self.componentMode then Cache.tick() end
    if self.componentMode and self.domainKillAuthorized ~= true then
        _selectionCache = {
            atMs = lib.getTimeMs(),
            valid = true,
            action = nil,
            reason = self.domainKillGateReason or 'kill_not_authorized',
        }
        _lastReason = tostring(
            self.domainKillGateReason or 'kill_not_authorized')
        self:setIntent(false, nil, _lastReason)
        return
    end
    tickDpsIntelligence(self)
    local action, reason = selectSpell()
    _lastReason = action and ('ready:' .. tostring(action.spellName)) or tostring(reason or 'none')
    sendIntelTelemetry(self, action, _lastReason)
    self:setIntent(action ~= nil, action and 500 or nil, _lastReason)
end

module.shouldAct = function(self)
    if not self:hasValidState() then return false end
    if self.componentMode and self.domainKillAuthorized ~= true then return false end
    local action = selectSpell()
    return action ~= nil
end

module.getAction = function(self)
    local action = selectSpell()
    if not action then return nil end

    return {
        kind = lib.ActionKind.CAST_SPELL,
        name = action.spellName,
        spellName = action.spellName,
        gemSlot = action.slot,
        targetId = action.targetId,
        targetType = 'NPC',
        targetName = action.targetName,
        combatAction = true,
        allowBreakInvis = true,
        rotationGroup = action.rotationGroup,
        rotationKey = action.rotationKey,
        rotationPriority = action.rotationPriority,
        -- Targeting plus the configured humanized reaction window happens
        -- before /cast, so this workflow needs an explicit bounded exception.
        castStartTimeoutMs = 4000,
        timeoutMs = (getSpellCastTime(action.spellName) + 3) * 1000,
        castOptions = {
            spellCategory = 'damage',
            sourceLayer = 'dps',
            maxRetries = 0,
        },
        idempotencyKey = string.format('dps:%s:%s:%d',
            tostring(action.activeSet or 'set'),
            tostring(action.spellName or action.slot),
            tonumber(action.targetId or 0) or 0),
        reason = string.format('spellset %s gem %d', tostring(action.activeSet or ''), action.slot),
    }
end

module.executeAction = function(self)
    if not self:ownsLease() then
        _lastExecuteReason = 'no_ownership'
        return false, 'no_ownership'
    end

    local action = self:getLeaseAction()
    if not action then
        _lastExecuteReason = 'no_action'
        return false, 'no_action'
    end

    local slot = tonumber(action.gemSlot) or 0
    local spellName = action.spellName or action.name
    local targetId = tonumber(action.targetId) or 0

    if slot <= 0 then
        _lastExecuteReason = 'bad_gem_slot'
        return true, 'bad_gem_slot'
    end
    if not isSpellReady(slot, spellName) then
        _lastExecuteReason = 'spell_not_ready'
        return false, 'spell_not_ready'
    end

    _lastExecuteAt = lib.getTimeMs()
    _lastCastAttempt = string.format('slot=%d spell=%s target=%d', slot, tostring(spellName), targetId)
    commandEcho('execute: %s', _lastCastAttempt)

    if targetId > 0 then
        mq.cmdf('/target id %d', targetId)
        mq.delay(500, function()
            local t = mq.TLO.Target
            return t and t() and t.ID() == targetId
        end)
        local currentTarget = lib.safeNum(function() return mq.TLO.Target.ID() end, 0)
        if currentTarget ~= targetId then
            _lastExecuteReason = string.format('target_failed:%d', currentTarget)
            commandEcho('execute failed: target wanted=%d got=%d', targetId, currentTarget)
            return true, 'target_failed'
        end
    end

    do
        local ok, H = pcall(require, 'sidekick-next.humanize')
        if ok and H and H.gate then
            local delay = H.gate('cast', { spell = spellName, target = targetId })
            if delay == H.SKIP then
                _lastExecuteReason = 'humanize_skip'
                commandEcho('execute skipped by humanize: %s', tostring(spellName))
                return false, 'humanize_skip'
            end
            if delay and delay > 0 then mq.delay(delay) end
        end
    end

    lib.log('info', self.name, 'Casting gem %d (%s) target=%s', slot, tostring(spellName), tostring(targetId))
    mq.cmdf('/cast %d', slot)
    mq.delay(100)

    if not lib.isCasting() then
        _lastExecuteReason = 'cast_did_not_start'
        commandEcho('execute failed: cast did not start for %s', tostring(spellName))
        return true, 'cast_did_not_start'
    end

    _lastExecuteReason = 'casting'
    local startTime = lib.getTimeMs()
    local maxWait = (getSpellCastTime(spellName) + 1) * 1000
    while lib.isCasting() do
        mq.delay(50)
        self:renewLease()
        if not self:ownsLease() then
            _lastExecuteReason = 'ownership_lost'
            commandEcho('execute interrupted: ownership lost')
            return true, 'ownership_lost'
        end
        if (lib.getTimeMs() - startTime) > maxWait then
            _lastExecuteReason = 'cast_timeout'
            commandEcho('execute failed: cast timeout')
            return true, 'cast_timeout'
        end
    end

    _lastExecuteReason = 'completed'
    commandEcho('execute completed: %s', tostring(spellName))
    return true, 'completed'
end


-- The legacy callback above is retained only as migration reference and must
-- never be selected by ModuleBase.
module.executeAction = nil
module:enableUnifiedExecutor({
    preflight = function(action)
        if module.componentMode
            and (module.domainKillAuthorized ~= true
                or tonumber(action.targetId) ~= tonumber(module.domainKillTargetId)) then
            return false, 'kill_authorization_changed'
        end
        local slot = tonumber(action.gemSlot) or 0
        if slot <= 0 then return false, 'bad_gem_slot' end
        if not isSpellReady(slot, action.spellName or action.name) then
            return false, 'spell_not_ready'
        end
        _lastExecuteAt = lib.getTimeMs()
        _lastCastAttempt = string.format('slot=%d spell=%s target=%d', slot,
            tostring(action.spellName or action.name), tonumber(action.targetId) or 0)
        _lastExecuteReason = 'dispatching'
        return true
    end,
    onComplete = function(action)
        _lastExecuteReason = 'completed'
        if action.rotationGroup and action.rotationKey then
            _lastCompletedRotation[tostring(action.rotationGroup)] = tostring(action.rotationKey)
        end
        _selectionCache.valid = false
        commandEcho('execute completed: %s', tostring(action.spellName or action.name))
    end,
    onFailure = function(_, _, _, result)
        _selectionCache.valid = false
        _lastExecuteReason = tostring(result and result.reason or 'failed')
    end,
    onCancel = function(_, _, _, result)
        _selectionCache.valid = false
        _lastExecuteReason = tostring(result and result.reason or 'cancelled')
    end,
})

-- DPS needs peer target telemetry even on pure casters/healers where the melee
-- assist worker intentionally does not select or hold a local target.
module:enablePeerActors()

-------------------------------------------------------------------------------
-- Command Binding
-------------------------------------------------------------------------------

mq.bind('/sk_dps', function(cmd)
    cmd = tostring(cmd or ''):lower()
    if cmd == 'stop' then
        module:stop()
        lib.log('info', module.name, 'Stop requested')
        commandEcho('Stop requested')
    elseif cmd == 'reload' then
        _lastSpellSetLoadAt = 0
        local Persistence, reason = loadSpellSets(true)
        commandEcho('reload activeSet=%s reason=%s path=%s',
            tostring(Persistence and Persistence.activeSetName or nil),
            tostring(reason),
            tostring(_lastSpellSetPath))
    elseif cmd == 'status' or cmd == '' then
        local spellSet, reason, Persistence = getActiveSpellSet()
        local target = getMATarget()
        local combatActive = target and isCombatTargetActive(target) or false
        local action, actionReason = selectSpell()
        local gemCount = 0
        for _ in pairs((spellSet and spellSet.gems) or {}) do gemCount = gemCount + 1 end
        local lease = module.state and module.state.lease
        commandEcho(
            'running=%s hasState=%s tier=%s ownsLease=%s leasePending=%s request=%s leaseHolder=%s activeSet=%s gems=%d target=%s targetHp=%s targetSource=%s actorCombat=%s combatActive=%s next=%s slot=%s lastReason=%s reason=%s lastExec=%s lastAttempt=%s path=%s',
            tostring(module.running),
            tostring(module:hasValidState()),
            tostring(module.priority),
            tostring(module:ownsLease()),
            tostring(module.requestPending),
            tostring(module.currentRequestId or 'none'),
            tostring(lease and lease.holderModule or 'nil'),
            tostring(Persistence and Persistence.activeSetName or nil),
            gemCount,
            target and tostring(target.id) or 'none',
            target and tostring(target.hp) or 'none',
            target and tostring(target.source) or 'none',
            tostring(target and target.coordinatedCombat == true),
            tostring(combatActive),
            action and tostring(action.spellName) or 'none',
            action and tostring(action.slot) or 'none',
            tostring(_lastReason),
            tostring(actionReason or reason),
            tostring(_lastExecuteReason),
            tostring(_lastCastAttempt),
            tostring(_lastSpellSetPath))
    elseif cmd == 'list' then
        debugList()
    elseif cmd == 'actors' then
        debugActorTargets()
    else
        commandEcho('Usage: /sk_dps status|list|actors|reload|stop')
    end
end)

-------------------------------------------------------------------------------
-- Run
-------------------------------------------------------------------------------

initDpsIntelligence()
module:run(50)
if not module.componentMode then
    flushSessionDamage(module, true)
    shutdownDpsIntelligence()
end

return module
