-- Dedicated coordinated debuff worker.
--
-- Peer reservation happens before the local action lease. The coordinator
-- remains action-blind: spell, target, and debuff category stay in this
-- process and are revalidated immediately before dispatch.

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local OffensiveTarget = require('sidekick-next.utils.offensive_target')
local Debuff = require('sidekick-next.automation.debuff')
local Cache = require('sidekick-next.utils.runtime_cache')

local module = ModuleBase.create('debuff', lib.Priority.DEBUFF)

local Config = {
    spellSetReloadSeconds = 5,
    actorTargetTtlSeconds = 5,
    targetCacheMs = 5000,
    peerClaimSettleMs = 300,
}

local _lastSpellSetLoadAt = 0
local _lastReason = 'init'
local _lastResult = 'none'
local _reservation = nil

local function commandEcho(fmt, ...)
    local ok, message = pcall(string.format, tostring(fmt), ...)
    print(string.format('\am[SK Debuff]\ax %s', ok and message or tostring(fmt)))
end

local function loadSpellSets(force)
    local ok, Persistence = pcall(require, 'sidekick-next.utils.spellset_persistence')
    if not ok or not Persistence then return nil, 'spellset_persistence_unavailable' end
    local now = os.clock()
    if force == true or not Persistence.loaded
        or (now - _lastSpellSetLoadAt) >= Config.spellSetReloadSeconds then
        local loadedOk, loaded = pcall(Persistence.load)
        if not loadedOk or loaded ~= true then
            return nil, 'spellset_load_failed:' .. tostring(loaded)
        end
        _lastSpellSetLoadAt = now
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
    local spell = spellName and mq.TLO.Spell(spellName) or nil
    if not (spell and spell()) then return 0 end
    return lib.safeNum(function() return spell.MyCastTime() end, 0) / 1000
end

local function isUtilityGem(config)
    local utility = config and config.utility
    return utility and (utility.combat == true or utility.ooc == true)
end

local function ownsSpellType(spellType)
    spellType = tostring(spellType or ''):lower()
    return spellType == 'debuff' or spellType == 'dispel'
end

local DEBUFF_TYPE_MAP = {
    Slowed = 'slow',
    Tashed = 'tash',
    Maloed = 'malo',
    Snared = 'snare',
    Crippled = 'cripple',
}

local EFFECT_PROPERTY_BY_TYPE = {
    slow = 'Slowed',
    tash = 'Tashed',
    malo = 'Maloed',
    snare = 'Snared',
    cripple = 'Crippled',
}

local function normalizeSpellKey(spellName)
    local key = tostring(spellName or ''):lower()
    key = key:gsub('%s+rk%.?%s*iii$', ''):gsub('%s+rk%.?%s*ii$', '')
        :gsub('%s+rk%.?%s*i$', ''):gsub('[^%w]+', '_')
    return key ~= '' and key or 'generic'
end

local function classifyDebuff(entry)
    if tostring(entry and entry.spellType or ''):lower() == 'dispel' then
        return 'dispel', nil
    end
    local ok, Defaults = pcall(require, 'sidekick-next.utils.condition_defaults')
    local spell = entry and (mq.TLO.Spell(entry.spellId or entry.spellName)) or nil
    if ok and Defaults and Defaults.detectDebuffType and spell and spell() then
        local detected = Defaults.detectDebuffType(spell)
        if detected == 'Rooted' or detected == 'Mezzed' then
            return nil, 'owned_by_cc:' .. tostring(detected):lower()
        end
        if DEBUFF_TYPE_MAP[detected] then return DEBUFF_TYPE_MAP[detected], nil end
    end
    return 'spell_' .. normalizeSpellKey(entry and entry.spellName), nil
end

local function buildConditionContext(target)
    local ok, ConditionContext = pcall(require, 'sidekick-next.utils.condition_context')
    if not ok or not ConditionContext or not ConditionContext.build then return nil end
    local ctx = ConditionContext.build() or {}
    ctx.inCombat = true
    ctx.myHp = lib.safeNum(function() return mq.TLO.Me.PctHPs() end, 100)
    ctx.myMana = lib.safeNum(function() return mq.TLO.Me.PctMana() end, 100)
    ctx.myEndurance = lib.safeNum(function() return mq.TLO.Me.PctEndurance() end, 100)
    ctx.isInvis = lib.safeTLO(function() return mq.TLO.Me.Invis() end, false) == true
    ctx.pctAggro = lib.safeNum(function() return mq.TLO.Me.PctAggro() end, 0)
    ctx.targetId = target.id
    ctx.targetHp = target.hp
    ctx.targetName = target.name
    local spawn = mq.TLO.Spawn(target.id)
    if spawn and spawn() then
        ctx.targetLevel = lib.safeNum(function() return spawn.Level() end, 0)
        ctx.targetDistance = lib.safeNum(function() return spawn.Distance() end, 999)
        ctx.targetNamed = lib.safeTLO(function() return spawn.Named() end, false) == true
        ctx.targetType = lib.safeTLO(function() return spawn.Type() end, '')
        ctx.targetClass = lib.safeTLO(function() return spawn.Class.ShortName() end, '')
        ctx.targetSlowed = lib.safeTLO(function()
            return spawn.Slowed and spawn.Slowed.ID
                and (tonumber(spawn.Slowed.ID()) or 0) > 0
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
    return ctx
end

local function liveEffectPresent(action)
    local targetId = tonumber(action and action.targetId) or 0
    if targetId <= 0 then return false end

    local spawn = mq.TLO.Spawn(targetId)
    if not (spawn and spawn()) then return false end
    local property = EFFECT_PROPERTY_BY_TYPE[tostring(action.debuffType or '')]
    if property ~= nil then
        local present = lib.safeTLO(function()
            local effect = spawn[property]
            if not effect then return false end
            if effect.ID then return (tonumber(effect.ID()) or 0) > 0 end
            local raw = effect()
            return raw ~= nil and raw ~= false and raw ~= ''
                and tostring(raw):upper() ~= 'NULL'
        end, false)
        if present == true then return true end
    end

    local spellName = tostring(action.spellName or '')
    if spellName ~= '' then
        local byName = spawn.CachedBuff and spawn.CachedBuff(spellName)
            or (spawn.Buff and spawn.Buff(spellName))
        if byName and byName() and byName.ID
            and (tonumber(byName.ID()) or 0) > 0 then
            return true
        end
    end
    local spellId = tonumber(action.spellId) or 0
    if spellId > 0 then
        local byId = spawn.CachedBuff and spawn.CachedBuff(spellId)
            or (spawn.Buff and spawn.Buff(spellId))
        if byId and byId() and byId.ID
            and (tonumber(byId.ID()) or 0) > 0 then
            return true
        end
    end

    -- StacksTarget is meaningful only for the current target. It also catches
    -- same-line rank differences that a name/ID lookup cannot see.
    local currentId = lib.safeNum(function() return mq.TLO.Target.ID() end, 0)
    if currentId == targetId and spellName ~= '' then
        local spell = mq.TLO.Spell(spellName)
        if spell and spell() and spell.StacksTarget then
            local stacks = lib.safeTLO(function() return spell.StacksTarget() end, true)
            if stacks == false then return true end
        end
    end
    return false
end

local function effectPresent(action)
    if action and action.debuffType ~= 'dispel'
        and Debuff.hasDebuff(action.targetId, action.debuffType) then
        return true
    end
    return liveEffectPresent(action)
end

local function selectSpell()
    local settings = lib.getSettings() or {}
    if settings.DpsEnabled == false then return nil, 'dps_disabled' end
    if settings.UseSpells == false then return nil, 'spells_disabled' end

    local spellSet, reason, Persistence = getActiveSpellSet()
    if not spellSet then return nil, reason end
    local target = OffensiveTarget.select(module, {
        actorTargetTtlSeconds = Config.actorTargetTtlSeconds,
        targetCacheMs = Config.targetCacheMs,
    })
    if not target then return nil, 'no_target' end
    if not OffensiveTarget.isCombatActive(target) then
        OffensiveTarget.clear(module)
        return nil, 'no_combat'
    end

    local ok, CombatExec = pcall(require, 'sidekick-next.utils.combat_spell_executor')
    if not ok or not CombatExec or not CombatExec.getSortedCastList then
        return nil, 'combat_executor_unavailable'
    end
    local castList = CombatExec.getSortedCastList(spellSet)
    local ctx = buildConditionContext(target)
    local firstSkip = nil

    for _, entry in ipairs(castList) do
        if entry and entry.slot and not isUtilityGem(entry.config)
            and ownsSpellType(entry.spellType) then
            local debuffType, classificationReason = classifyDebuff(entry)
            if not debuffType then
                firstSkip = firstSkip or classificationReason
            elseif isSpellReady(entry.slot, entry.spellName) then
                local conditionOk = true
                if CombatExec.evaluateCondition then
                    local evalOk, result = pcall(CombatExec.evaluateCondition, entry.config, ctx)
                    conditionOk = evalOk and result == true
                    if not evalOk then firstSkip = firstSkip or ('condition_error:' .. tostring(result)) end
                end
                local candidate = {
                    slot = tonumber(entry.slot),
                    spellName = tostring(entry.spellName or ''),
                    spellId = tonumber(entry.spellId) or 0,
                    spellType = tostring(entry.spellType or ''),
                    debuffType = debuffType,
                    targetId = target.id,
                    targetName = target.name,
                    targetType = 'NPC',
                    activeSet = Persistence and Persistence.activeSetName or nil,
                }
                if not conditionOk then
                    firstSkip = firstSkip or ('condition_false:' .. candidate.spellName)
                elseif debuffType ~= 'dispel' and effectPresent(candidate) then
                    firstSkip = firstSkip or ('effect_present:' .. candidate.spellName)
                else
                    local claimed, claimer = Debuff.isDebuffClaimed(target.id, debuffType)
                    if claimed then
                        firstSkip = firstSkip
                            or string.format('peer_claimed:%s:%s', debuffType, tostring(claimer))
                    else
                        return candidate, nil
                    end
                end
            else
                firstSkip = firstSkip or ('not_ready:' .. tostring(entry.spellName))
            end
        end
    end
    return nil, firstSkip or 'no_eligible_debuff'
end

local function sameReservation(candidate)
    return _reservation and candidate
        and tonumber(_reservation.targetId) == tonumber(candidate.targetId)
        and tostring(_reservation.debuffType) == tostring(candidate.debuffType)
        and tostring(_reservation.spellName) == tostring(candidate.spellName)
end

local function releaseReservation(reason)
    local reserved = _reservation
    _reservation = nil
    if reserved then
        Debuff.releaseClaim(reserved.targetId, reserved.debuffType)
        _lastResult = tostring(reason or 'reservation_released')
    end
end

local function reserveCandidate(candidate)
    if sameReservation(candidate)
        and Debuff.ownsClaim(candidate.targetId, candidate.debuffType) then
        Debuff.renewClaim(candidate.targetId, candidate.debuffType)
        return true
    end
    releaseReservation('candidate_changed')
    if not Debuff.claimDebuff(candidate.targetId, candidate.debuffType) then
        return false
    end
    _reservation = {
        targetId = candidate.targetId,
        targetName = candidate.targetName,
        debuffType = candidate.debuffType,
        spellName = candidate.spellName,
        reservedAtMs = lib.getTimeMs(),
    }
    return true
end

module.onTick = function(self)
    Cache.setSettings(lib.getSettings())
    if not self.componentMode then Cache.tick() end
    Debuff.tick()
    if self.componentMode and self.domainKillAuthorized ~= true then
        releaseReservation(self.domainKillGateReason or 'kill_not_authorized')
        module._candidate = nil
        _lastReason = tostring(
            self.domainKillGateReason or 'kill_not_authorized')
        self:setIntent(false, nil, _lastReason)
        return
    end
    local action, reason = selectSpell()
    if _reservation and self.currentRequestId then
        if not Debuff.renewClaim(_reservation.targetId, _reservation.debuffType) then
            _lastReason = 'peer_reservation_lost'
            module._candidate = nil
            self:setIntent(false, nil, _lastReason)
            return
        end
        -- Keep the exact reserved action stable while its request is queued
        -- or leased. Mutable spell/target/effect facts are rechecked at the
        -- final action boundary and executor preflight.
        action = self.currentAction or action
        reason = 'reserved_request'
    elseif _reservation and action and sameReservation(action) then
        if not Debuff.renewClaim(_reservation.targetId, _reservation.debuffType) then
            releaseReservation('peer_reservation_lost')
        end
    elseif _reservation then
        releaseReservation(action and 'candidate_changed'
            or (reason or 'candidate_cleared'))
    end
    if action and not _reservation and not reserveCandidate(action) then
        action = nil
        reason = 'peer_reservation_failed'
    end
    local settling = action and _reservation
        and (lib.getTimeMs() - (tonumber(_reservation.reservedAtMs) or 0))
            < Config.peerClaimSettleMs
    _lastReason = action and (
        (settling and 'peer_settling:' or 'ready:') .. action.spellName
    ) or tostring(reason or 'idle')
    module._candidate = action
    self:setIntent(action ~= nil, action and 750 or nil, _lastReason)
end

module.shouldAct = function(self)
    return self:hasValidState() and module._candidate ~= nil
end

module.getAction = function()
    local candidate = module._candidate
    if not candidate or not reserveCandidate(candidate) then return nil end
    if (lib.getTimeMs() - (tonumber(_reservation.reservedAtMs) or 0))
        < Config.peerClaimSettleMs then
        return nil
    end
    return {
        kind = lib.ActionKind.CAST_SPELL,
        name = candidate.spellName,
        spellName = candidate.spellName,
        spellId = candidate.spellId,
        spellType = candidate.spellType,
        debuffType = candidate.debuffType,
        gemSlot = candidate.slot,
        targetId = candidate.targetId,
        targetName = candidate.targetName,
        targetType = candidate.targetType,
        combatAction = true,
        allowBreakInvis = true,
        castStartTimeoutMs = 4000,
        timeoutMs = (getSpellCastTime(candidate.spellName) + 3) * 1000,
        castOptions = {
            spellCategory = 'debuff',
            sourceLayer = 'debuff',
            maxRetries = 0,
        },
        idempotencyKey = string.format('debuff:%s:%s:%s:%d',
            tostring(candidate.activeSet or 'set'),
            tostring(candidate.debuffType),
            tostring(candidate.spellName),
            tonumber(candidate.targetId) or 0),
        reason = string.format('%s on %s', candidate.debuffType,
            candidate.targetName ~= '' and candidate.targetName or candidate.targetId),
    }
end

module:enableUnifiedExecutor({
    preflight = function(action)
        if module.componentMode
            and (module.domainKillAuthorized ~= true
                or tonumber(action.targetId) ~= tonumber(module.domainKillTargetId)) then
            return false, 'kill_authorization_changed'
        end
        if not Debuff.ownsClaim(action.targetId, action.debuffType) then
            return false, 'peer_reservation_lost'
        end
        if not isSpellReady(action.gemSlot, action.spellName) then
            return false, 'spell_not_ready'
        end
        if action.debuffType ~= 'dispel' and effectPresent(action) then
            return false, 'effect_already_present'
        end
        return true
    end,
    onComplete = function(action)
        if action.debuffType ~= 'dispel' and liveEffectPresent(action) then
            Debuff.trackDebuff(action.targetId, action.debuffType, action.spellName, 60)
            _reservation = nil
            _lastResult = 'landed_confirmed'
        else
            -- Cast completion is not proof of landing. Never poison peer state
            -- after a resist, immunity, dispel, or an unobservable effect.
            releaseReservation(action.debuffType == 'dispel'
                and 'dispel_completed' or 'landing_unconfirmed')
        end
    end,
    onFailure = function(action, _, _, result)
        releaseReservation(result and result.reason or ('failed:' .. tostring(action.spellName)))
    end,
    onCancel = function(action, _, _, result)
        releaseReservation(result and result.reason or ('cancelled:' .. tostring(action.spellName)))
    end,
})

module.onRequestWithdrawn = function(_, _, reason)
    releaseReservation(reason or 'request_withdrawn')
end

local function finalizeLease(_, _, reason)
    releaseReservation(reason or 'lease_finalized')
    return true
end

module.onLeaseFinalizing = finalizeLease
module.onSafetyDrain = finalizeLease
module:enablePeerActors()

mq.bind('/sk_debuff', function(cmd)
    cmd = tostring(cmd or ''):lower()
    if cmd == 'stop' then
        module:stop()
    elseif cmd == 'reload' then
        _lastSpellSetLoadAt = 0
        local _, reason = loadSpellSets(true)
        commandEcho('reload=%s', tostring(reason or 'ok'))
    elseif cmd == '' or cmd == 'status' then
        local action, reason = selectSpell()
        local lease = module.state and module.state.lease or nil
        commandEcho(
            'running=%s tier=%s ownsLease=%s pending=%s request=%s holder=%s next=%s type=%s target=%s reason=%s last=%s',
            tostring(module.running), tostring(module.priority), tostring(module:ownsLease()),
            tostring(module.currentRequestId ~= nil and not module:ownsLease()),
            tostring(module.currentRequestId or 'none'),
            tostring(lease and lease.holderModule or 'none'),
            tostring(action and action.spellName or 'none'),
            tostring(action and action.debuffType or 'none'),
            tostring(action and action.targetName or 'none'),
            tostring(reason or _lastReason), tostring(_lastResult))
    else
        commandEcho('Usage: /sk_debuff status|reload|stop')
    end
end)

Debuff.init()
module:run(50)
if not module.componentMode then releaseReservation('worker_exit') end

return module
