-- F:/lua/sidekick-next/sk_dps.lua
-- DPS module for SideKick multi-script system.
-- Uses the active spell-set combat rotation instead of hardcoded class spell lines.

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')

local module = ModuleBase.create('dps', lib.Priority.DPS)

-------------------------------------------------------------------------------
-- Runtime State
-------------------------------------------------------------------------------

local Config = {
    minManaPct = 0,
    minTargetHpPct = 20,
    spellSetReloadSeconds = 5,
    targetCacheMs = 5000,
}

local _lastSpellSetLoadAt = 0
local _lastSpellSetPath = nil
local _lastReason = 'init'
local _lastExecuteReason = 'none'
local _lastExecuteAt = 0
local _lastCastAttempt = 'none'
local _lastValidTarget = nil

local function commandEcho(fmt, ...)
    local msg
    if select('#', ...) > 0 then
        local ok, formatted = pcall(string.format, fmt, ...)
        msg = ok and formatted or tostring(fmt)
    else
        msg = tostring(fmt)
    end
    pcall(function() print(string.format('\ag[SK DPS]\ax %s', msg)) end)
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

-------------------------------------------------------------------------------
-- Target Selection
-------------------------------------------------------------------------------

local function addCandidate(candidates, seen, id, source)
    id = tonumber(id) or 0
    if id <= 0 or seen[id] then return end
    seen[id] = true
    candidates[#candidates + 1] = { id = id, source = source or 'unknown' }
end

local function addSpawnTargetCandidates(candidates, seen, spawn, source)
    if not (spawn and spawn()) then return end
    addCandidate(candidates, seen, lib.safeNum(function() return spawn.Target.ID() end, 0), source .. '_target')
    addCandidate(candidates, seen, lib.safeNum(function() return spawn.TargetOfTarget.ID() end, 0), source .. '_tot')
end

local function validateNpcTarget(targetId, source, remember)
    targetId = tonumber(targetId) or 0
    if targetId <= 0 then return nil end

    local target = mq.TLO.Spawn(targetId)
    if not (target and target()) then return nil end

    local targetType = lib.safeTLO(function() return target.Type() end, '') or ''
    local dead = lib.safeTLO(function() return target.Dead() end, false) == true
    if targetType:lower() ~= 'npc' or dead then return nil end

    local result = {
        id = targetId,
        hp = lib.safeNum(function() return target.PctHPs() end, 100),
        source = source or 'unknown',
    }

    if remember ~= false then
        _lastValidTarget = {
            id = result.id,
            hp = result.hp,
            source = result.source,
            seenAt = lib.getTimeMs(),
        }
    end

    return result
end

local function isCombatTargetActive(target)
    if not target or not target.id or target.id <= 0 then return false end

    -- XTarget hater/auto slots are direct evidence that the client is aware of
    -- combat. This is the most reliable local signal for casters/healers.
    if lib.inCombat() then return true end

    local source = tostring(target.source or ''):lower()
    if source:find('xtarget', 1, true) then return true end

    local spawn = mq.TLO.Spawn(target.id)
    if not (spawn and spawn()) then return false end

    -- A damaged NPC is enough to consider the encounter active even if this
    -- character has not entered local combat yet.
    local hp = lib.safeNum(function() return spawn.PctHPs() end, 100)
    if hp > 0 and hp < 100 then return true end

    -- If the NPC is targeting a player/pet/merc, it is probably engaged. This
    -- keeps multi-group casters working without treating a group member's idle
    -- NPC target as combat.
    local targetType = tostring(lib.safeTLO(function() return spawn.Target.Type() end, '') or ''):lower()
    if targetType == 'pc' or targetType == 'pet' or targetType == 'mercenary' then
        return true
    end

    return false
end

local function addXTargetCandidates(candidates, seen)
    local xtCount = lib.safeNum(function() return mq.TLO.Me.XTarget() end, 0)
    for i = 1, xtCount do
        local xt = mq.TLO.Me.XTarget(i)
        if xt and xt() then
            local xtType = tostring(lib.safeTLO(function() return xt.TargetType() end, '') or ''):lower()
            if xtType:find('hater', 1, true) or xtType:find('auto', 1, true) then
                addCandidate(candidates, seen, lib.safeNum(function() return xt.ID() end, 0), 'xtarget' .. tostring(i))
            end
        end
    end
end

local function getMATarget()
    local maId = lib.getMainAssistId()
    local candidates = {}
    local seen = {}
    if maId > 0 then
        local ma = mq.TLO.Spawn(maId)
        addSpawnTargetCandidates(candidates, seen, ma, 'mainassist')
    end

    addSpawnTargetCandidates(candidates, seen, mq.TLO.Group.MainAssist, 'group_ma')
    addSpawnTargetCandidates(candidates, seen, mq.TLO.Group.MainTank, 'group_mt')
    addSpawnTargetCandidates(candidates, seen, mq.TLO.Group.Leader, 'group_leader')

    local currentTarget = mq.TLO.Target
    if currentTarget and currentTarget() then
        addCandidate(candidates, seen, lib.safeNum(function() return currentTarget.ID() end, 0), 'current')
        addSpawnTargetCandidates(candidates, seen, currentTarget, 'current')
    end

    addXTargetCandidates(candidates, seen)

    for _, candidate in ipairs(candidates) do
        local target = validateNpcTarget(candidate.id, candidate.source, true)
        if target then return target end
    end

    if _lastValidTarget and (lib.getTimeMs() - (_lastValidTarget.seenAt or 0)) <= Config.targetCacheMs then
        local target = validateNpcTarget(_lastValidTarget.id, 'cache:' .. tostring(_lastValidTarget.source), false)
        if target then return target end
    end

    return nil
end

local function spellNeedsNpcTarget(entry)
    local spellType = tostring(entry and entry.spellType or ''):lower()
    if spellType == 'debuff' or spellType == 'dot' or spellType == 'direct_damage' then
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

local function selectSpell()
    local spellSet, reason, Persistence = getActiveSpellSet()
    if not spellSet then return nil, reason end

    local target = getMATarget()
    if not target then return nil, 'no_target' end
    local combatActive = isCombatTargetActive(target)
    if not combatActive then
        _lastValidTarget = nil
        return nil, 'no_combat'
    end
    if target.hp < Config.minTargetHpPct then return nil, 'target_low_hp' end

    local mana = lib.safeNum(function() return mq.TLO.Me.PctMana() end, 0)
    if mana < Config.minManaPct then return nil, 'low_mana' end

    local CombatExec = getCombatExec()
    if not CombatExec or not CombatExec.getSortedCastList then
        return nil, 'combat_executor_unavailable'
    end

    local castList = CombatExec.getSortedCastList(spellSet)
    if #castList == 0 then
        return nil, 'empty_cast_list:' .. tostring(Persistence and Persistence.activeSetName or '')
    end

    local ctx = buildConditionContext(target.id, combatActive)
    local firstSkip = nil
    for _, entry in ipairs(castList) do
        if entry and entry.slot and not isUtilityGem(entry.config) then
            local targetId = spellNeedsNpcTarget(entry) and target.id or nil
            if isSpellReady(entry.slot, entry.spellName) then
                local conditionOk = true
                if CombatExec.evaluateCondition then
                    conditionOk = CombatExec.evaluateCondition(entry.config, ctx)
                end
                if conditionOk then
                    local skipEffect, effectReason = shouldSkipExistingEffect(entry, targetId)
                    if skipEffect then
                        firstSkip = firstSkip or (effectReason .. ':' .. tostring(entry.spellName))
                    else
                        return {
                            slot = entry.slot,
                            spellName = entry.spellName,
                            spellType = entry.spellType,
                            targetId = targetId,
                            activeSet = Persistence and Persistence.activeSetName or nil,
                        }, nil
                    end
                else
                    firstSkip = firstSkip or ('condition_false:' .. tostring(entry.spellName))
                end
            else
                firstSkip = firstSkip or ('not_ready:' .. tostring(entry.spellName))
            end
        end
    end

    return nil, firstSkip or 'no_eligible_spell'
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
    commandEcho('list: activeSet=%s gems=%d target=%s targetSource=%s combatActive=%s path=%s',
        tostring(Persistence and Persistence.activeSetName or nil),
        #castList,
        target and tostring(target.id) or 'none',
        target and tostring(target.source) or 'none',
        tostring(combatActive),
        tostring(_lastSpellSetPath))

    if #castList == 0 then
        commandEcho('list: empty cast list')
        return
    end

    for _, entry in ipairs(castList) do
        local utility = isUtilityGem(entry.config)
        local ready = entry and entry.slot and isSpellReady(entry.slot, entry.spellName) or false
        local conditionOk = false
        local conditionReason = ''
        if utility then
            conditionReason = 'utility'
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
                    end
                end
            else
                conditionReason = 'eligible_no_condition_api'
            end
        end

        commandEcho(
            'list: gem=%s spell=%s type=%s priority=%s targetNpc=%s ready=%s condition=%s skip=%s',
            tostring(entry.slot),
            tostring(entry.spellName),
            tostring(entry.spellType),
            tostring(entry.priority),
            tostring(spellNeedsNpcTarget(entry)),
            tostring(ready),
            tostring(conditionOk),
            tostring(conditionReason))
    end
end

local function directTestCast()
    local action, reason = selectSpell()
    if not action then
        commandEcho('testcast: no action: %s', tostring(reason))
        return
    end

    commandEcho('testcast: slot=%s spell=%s target=%s',
        tostring(action.slot), tostring(action.spellName), tostring(action.targetId))

    if action.targetId and action.targetId > 0 then
        mq.cmdf('/target id %d', action.targetId)
        mq.delay(500, function()
            local t = mq.TLO.Target
            return t and t() and t.ID() == action.targetId
        end)
        local currentTarget = lib.safeNum(function() return mq.TLO.Target.ID() end, 0)
        if currentTarget ~= action.targetId then
            commandEcho('testcast failed: target wanted=%s got=%s', tostring(action.targetId), tostring(currentTarget))
            return
        end
    end

    mq.cmdf('/cast %d', action.slot)
    mq.delay(250)
    commandEcho('testcast result: casting=%s spellReady=%s',
        tostring(lib.isCasting()), tostring(isSpellReady(action.slot, action.spellName)))
end

-------------------------------------------------------------------------------
-- Module Callbacks
-------------------------------------------------------------------------------

module.onTick = function(self)
    local action, reason = selectSpell()
    _lastReason = action and ('ready:' .. tostring(action.spellName)) or tostring(reason or 'none')
    self:sendNeed(action ~= nil, action and 500 or nil, _lastReason)
end

module.shouldAct = function(self)
    if not self:hasValidState() then return false end
    local action = selectSpell()
    return action ~= nil
end

module.getAction = function(self)
    local action = selectSpell()
    if not action then return nil end

    return {
        kind = lib.ActionKind.CAST_SPELL,
        -- DPS only needs exclusive cast ownership. It briefly targets the MA's
        -- mob immediately before casting; requiring a target claim can deadlock
        -- behind stale movement/assist target ownership even though no cast is
        -- happening.
        type = lib.ClaimType.CAST,
        name = action.spellName,
        spellName = action.spellName,
        gemSlot = action.slot,
        targetId = action.targetId,
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
    if not self:ownsClaim() then
        _lastExecuteReason = 'no_ownership'
        return false, 'no_ownership'
    end

    local action = self.state and self.state.castOwner and self.state.castOwner.action
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
        if not self:ownsClaim() then
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


module:enableUnifiedExecutor({
    preflight = function(action)
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
        commandEcho('execute completed: %s', tostring(action.spellName or action.name))
    end,
    onFailure = function(_, _, _, result)
        _lastExecuteReason = tostring(result and result.reason or 'failed')
    end,
    onCancel = function(_, _, _, result)
        _lastExecuteReason = tostring(result and result.reason or 'cancelled')
    end,
})

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
        local castOwner = module.state and module.state.castOwner
        local targetOwner = module.state and module.state.targetOwner
        commandEcho(
            'running=%s hasState=%s priority=%s statePrio=%s castBusy=%s ownsClaim=%s ownsCast=%s ownsTarget=%s claimPending=%s claimType=%s castOwner=%s targetOwner=%s activeSet=%s gems=%d target=%s targetSource=%s combatActive=%s next=%s slot=%s lastReason=%s reason=%s lastExec=%s lastAttempt=%s path=%s',
            tostring(module.running),
            tostring(module:hasValidState()),
            tostring(module:isMyPriority()),
            tostring(module.state and module.state.activePriority),
            tostring(module.state and module.state.castBusy),
            tostring(module:ownsClaim()),
            tostring(module:ownsCast()),
            tostring(module:ownsTarget()),
            tostring(module.claimPending),
            tostring(module.currentClaimType),
            tostring(castOwner and castOwner.module or 'nil'),
            tostring(targetOwner and targetOwner.module or 'nil'),
            tostring(Persistence and Persistence.activeSetName or nil),
            gemCount,
            target and tostring(target.id) or 'none',
            target and tostring(target.source) or 'none',
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
    elseif cmd == 'testcast' then
        directTestCast()
    else
        commandEcho('Usage: /sk_dps status|list|testcast|reload|stop')
    end
end)

-------------------------------------------------------------------------------
-- Run
-------------------------------------------------------------------------------

module:run(50)

return module
