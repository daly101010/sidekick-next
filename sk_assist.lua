-- Coordinated melee-assist worker.
-- Each target/attack/stick transition is a finite single-lease action.

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local CombatAssist = require('sidekick-next.utils.combatassist')
local Assist = require('sidekick-next.automation.assist')
local CasterAssist = require('sidekick-next.automation.caster_assist')
local Actors = require('sidekick-next.utils.actors_coordinator')

local module = ModuleBase.create('assist', lib.Priority.DPS)
module:enablePeerActors()

local ACTOR_TARGET_TTL_SECONDS = 5
local _settings = nil
local _selectedTarget = nil
local _stickyActorTargetId = nil
local _lastReason = 'init'
local _wasEnabled = false
local _needsStop = false
local _stableTargetId = 0
local _casterRouting = false
local _standoffNeeded = false
local _cleanupStableSamples = 0
local _cleanupOwnNavigation = false

local function commandEcho(fmt, ...)
    local ok, message = pcall(string.format, fmt, ...)
    print(string.format('\ag[SK Assist]\ax %s', ok and message or tostring(fmt)))
end

local function applySettings()
    _settings = lib.getSettings() or _settings or {}
    local enabled = tostring(_settings.CombatMode or 'off'):lower() == 'assist'
    local engageCondition = tostring(_settings.AssistEngageCondition or 'hp'):lower()
    CombatAssist.apply_config({
        enabled = enabled,
        assist_at = engageCondition == 'tank_aggro' and 100 or _settings.AssistAt,
        assist_rng = _settings.AssistRange,
        assist_mode = _settings.AssistMode,
        assist_name = _settings.AssistName,
        stick_cmd = _settings.StickCommand,
    })
    if _wasEnabled and not enabled then
        _needsStop = true
        _stickyActorTargetId = nil
    end
    _wasEnabled = enabled
    return _settings, enabled
end

local function validateTarget(targetId, source, settings)
    targetId = tonumber(targetId) or 0
    if targetId <= 0 then return nil, 'no_target' end

    local spawn = mq.TLO.Spawn(targetId)
    if not (spawn and spawn()) then return nil, 'target_missing' end
    local targetType = tostring(lib.safeTLO(function() return spawn.Type() end, '') or ''):lower()
    if targetType ~= 'npc' then return nil, 'target_not_npc' end
    if lib.safeTLO(function() return spawn.Dead() end, false) == true then
        return nil, 'target_dead'
    end

    -- Hard engagement radius: after a wipe/rez, sticky targets and stale
    -- tank broadcasts can still name mobs that RESET across the zone —
    -- spawn-valid, alive, often still damaged. Never navigate to a mob
    -- beyond AssistRange; if it isn't near camp, it isn't our fight.
    local dist = lib.safeNum(function() return spawn.Distance3D() end, 999)
    local maxRange = tonumber(settings.AssistRange) or 100
    if dist > maxRange then
        return nil, string.format('beyond_assist_range:%d>%d', math.floor(dist), maxRange)
    end

    local hp = lib.safeNum(function() return spawn.PctHPs() end, 100)
    local engageAt = tonumber(settings.AssistAt) or 97
    local engageCondition = tostring(settings.AssistEngageCondition or 'hp'):lower()
    if engageCondition == 'hp' and hp > engageAt then
        return nil, string.format('above_assist_at:%d>%d', hp, engageAt)
    elseif engageCondition == 'tank_aggro' then
        local tankId = 0
        if tostring(source or ''):find('actor_', 1, true) == 1 then
            tankId = tonumber(Assist.tankId) or 0
        else
            local mainAssist = CombatAssist.get_main_assist_spawn()
            tankId = lib.safeNum(function() return mainAssist.ID() end, 0)
        end
        local targetOfTargetId = lib.safeNum(function() return spawn.TargetOfTarget.ID() end, 0)
        if tankId <= 0 or targetOfTargetId ~= tankId then
            return nil, 'waiting_tank_aggro'
        end
    end

    return {
        id = targetId,
        source = source or 'unknown',
        hp = hp,
    }, nil
end

local function actorTarget(settings)
    local state = Actors.getTankState and Actors.getTankState() or nil
    if type(state) ~= 'table' or tonumber(state.updatedAt) == nil
        or (os.clock() - tonumber(state.updatedAt)) > ACTOR_TARGET_TTL_SECONDS then
        _stickyActorTargetId = nil
        return nil, 'actor_target_stale', false
    end

    local primaryId = tonumber(state.primaryTargetId) or 0
    Assist.tankId = tonumber(state.tankId) or Assist.tankId
    Assist.tankName = tostring(state.tankName or Assist.tankName or '')

    -- Coordinated assist always follows the published group kill intent.
    -- `currentTargetId` is the tank's private working target and may point at
    -- a loose add during taunt/hate recovery.
    if primaryId <= 0 then
        _stickyActorTargetId = nil
        return nil, 'actor_primary_cleared', true
    end
    _stickyActorTargetId = primaryId
    local target, reason = validateTarget(primaryId, 'actor_primary', settings)
    return target, reason, true
end

local function selectTarget(settings)
    local target, actorReason, authoritative = actorTarget(settings)
    if target then return target, nil end
    if authoritative then return nil, actorReason end

    local id = CombatAssist.get_assist_target()
    local fallback, fallbackReason = validateTarget(id, 'assist_' .. tostring(settings.AssistMode or 'group'), settings)
    if fallback then return fallback, nil end
    return nil, fallbackReason or actorReason or 'no_target'
end

module.onTick = function(self)
    local settings, enabled = applySettings()
    if not enabled then
        _selectedTarget = nil
        _lastReason = 'mode_off'
        self:setIntent(_needsStop, nil, _lastReason)
        return
    end
    local pureCaster = CasterAssist.isPureCaster()
    local standoffRoute = CasterAssist.shouldRouteStandoff
        and CasterAssist.shouldRouteStandoff(settings)
    local casterUsesStick = pureCaster and settings.CasterUseStick == true
        and settings.CasterStandoffEnabled ~= true
    _casterRouting = (pureCaster or standoffRoute) and not casterUsesStick
    if _casterRouting then
        local target, reason = selectTarget(settings)
        _selectedTarget = target
        _standoffNeeded = false
        if target then
            local currentId = lib.safeNum(function() return mq.TLO.Target.ID() end, 0)
            if currentId == target.id then
                _stableTargetId = target.id
                _standoffNeeded = select(1,
                    CasterAssist.getStandoffNeed(settings, target.id)) == true
            else
                _stableTargetId = 0
            end
        end
        local needs = _needsStop or (target ~= nil
            and (_stableTargetId ~= target.id or _standoffNeeded))
        _lastReason = target
            and (_standoffNeeded and 'ranged_standoff'
                or (_stableTargetId == target.id and 'caster_target_stable'
                    or 'caster_target_ready'))
            or tostring(reason or 'no_target')
        self:setIntent(needs, nil, _lastReason)
        return
    end

    local hadTarget = _selectedTarget ~= nil
    local target, reason = selectTarget(settings)
    _selectedTarget = target
    if hadTarget and not target then _needsStop = true end
    if target then
        local currentId = lib.safeNum(function() return mq.TLO.Target.ID() end, 0)
        local attacking = lib.safeTLO(function() return mq.TLO.Me.Combat() end, false) == true
        local sticking = lib.safeTLO(function()
            return mq.TLO.Stick and mq.TLO.Stick.Active and mq.TLO.Stick.Active()
        end, false) == true
        if currentId ~= target.id or not attacking or not sticking then
            _stableTargetId = 0
        end
    end
    _lastReason = target and ('ready:' .. tostring(target.source)) or tostring(reason or 'no_target')
    local needs = _needsStop or (target ~= nil and _stableTargetId ~= target.id)
    self:setIntent(needs, needs and 500 or nil, _lastReason)
end

module.shouldAct = function()
    return _needsStop or (_wasEnabled and _selectedTarget ~= nil
        and _stableTargetId ~= _selectedTarget.id)
end

module.getAction = function()
    if _needsStop then
        return {
            kind = 'assist_stop',
            name = 'Stop melee assist',
            targetId = _stableTargetId,
            skipBoundaryTarget = true,
            breaksInvis = false,
            idempotencyKey = 'assist:stop',
            reason = 'assist_state_no_longer_valid',
        }
    end
    local target = _selectedTarget
    if not target then return nil end
    if _casterRouting then
        local spawn = mq.TLO.Spawn(target.id)
        local targetName = spawn and spawn()
            and tostring(spawn.CleanName() or '') or ''
        if _stableTargetId ~= target.id then
            return {
                kind = 'target',
                assistMode = 'caster_target',
                name = 'Caster assist target',
                targetId = target.id,
                targetType = 'NPC',
                targetName = targetName,
                breaksInvis = false,
                idempotencyKey = string.format('assist:caster-target:%d', target.id),
                reason = tostring(target.source),
            }
        end
        if _standoffNeeded then
            return {
                kind = 'movement',
                assistMode = 'caster_standoff',
                name = 'Caster standoff',
                targetId = target.id,
                targetType = 'NPC',
                targetName = targetName,
                breaksInvis = false,
                combatAction = true,
                timeoutMs = 10000,
                idempotencyKey = string.format('assist:standoff:%d', target.id),
                reason = 'ranged_standoff',
            }
        end
        return nil
    end
    return {
        kind = 'assist_target',
        name = 'Melee assist',
        targetId = target.id,
        targetType = 'NPC',
        targetName = lib.safeTLO(function()
            return mq.TLO.Spawn(target.id).CleanName()
        end, ''),
        combatAction = true,
        allowBreakInvis = true,
        idempotencyKey = string.format('assist:%d', target.id),
        reason = string.format('%s hp=%d', tostring(target.source), tonumber(target.hp) or 0),
    }
end

module.executeAction = function(self)
    local leasedAction = self:getLeaseAction()
    if not leasedAction then return true, 'no_action' end
    if leasedAction.kind == 'assist_stop' then
        CombatAssist.stop()
        _needsStop = false
        _stableTargetId = 0
        return true, 'stopped'
    end

    local settings, enabled = applySettings()
    if not enabled then
        CombatAssist.stop()
        _needsStop = false
        _stableTargetId = 0
        return true, 'mode_off'
    end
    local claimedId = tonumber(leasedAction.targetId) or 0
    local target, reason = selectTarget(settings)
    if not target then
        CombatAssist.stop()
        return true, reason or 'target_lost'
    end
    if target.id ~= claimedId then
        return true, 'target_changed'
    end

    local pureCaster = CasterAssist.isPureCaster()
    local standoffRoute = CasterAssist.shouldRouteStandoff
        and CasterAssist.shouldRouteStandoff(settings)
    local casterUsesStick = pureCaster and settings.CasterUseStick == true
        and settings.CasterStandoffEnabled ~= true
    local casterRouting = (pureCaster or standoffRoute) and not casterUsesStick
    if casterRouting then
        if leasedAction.assistMode == 'caster_target' then
            mq.cmdf('/target id %d', claimedId)
            mq.delay(150, function()
                return lib.safeNum(function() return mq.TLO.Target.ID() end, 0)
                    == claimedId
            end)
            if not self:ownsLease() then return true, 'lease_lost' end
            if lib.safeNum(function() return mq.TLO.Target.ID() end, 0) ~= claimedId then
                return true, 'target_not_stable'
            end
            _stableTargetId = claimedId
            _needsStop = false
            return true, 'caster_target_stable'
        elseif leasedAction.assistMode == 'caster_standoff' then
            if CasterAssist.isRepositioning() then
                local done, standoffReason =
                    CasterAssist.advanceStandoff(settings, claimedId)
                if done then return true, standoffReason end
                self:renewLease()
                return false, standoffReason
            end
            local started, standoffReason =
                CasterAssist.startStandoff(settings, claimedId)
            if not started then
                return true, standoffReason or 'standoff_no_longer_needed'
            end
            self:markDirtyEffects(true)
            return false, standoffReason
        end
        return true, 'caster_action_changed'
    end
    if leasedAction.assistMode then return true, 'assist_routing_changed' end

    if tostring(target.source):find('actor_', 1, true) == 1 then
        Assist.currentTargetId = target.id
        if Assist.shouldEngage(settings) then
            Assist.engageTarget(target.id, settings)
        else
            CombatAssist.stop()
        end
    else
        CombatAssist.tick()
    end

    local currentId = lib.safeNum(function() return mq.TLO.Target.ID() end, 0)
    if currentId ~= target.id then return true, 'target_not_stable' end
    _stableTargetId = target.id
    _needsStop = false
    return true, 'engagement_stable'
end

module.onLeaseFinalizing = function(self, action, reason)
    if CasterAssist.isRepositioning() then
        _cleanupOwnNavigation = true
        CasterAssist.stopStandoff()
    elseif reason == 'orphan_recovery' then
        _cleanupOwnNavigation = true
        if lib.safeTLO(function()
            return mq.TLO.Navigation and mq.TLO.Navigation.Active
                and mq.TLO.Navigation.Active()
        end, false) == true then
            mq.cmd('/squelch /nav stop')
        end
    end

    if _cleanupOwnNavigation then
        local navActive = lib.safeTLO(function()
            return mq.TLO.Navigation and mq.TLO.Navigation.Active
                and mq.TLO.Navigation.Active()
        end, false) == true
        if navActive then
            _cleanupStableSamples = 0
            return false, 'stopping_standoff_navigation'
        end
    end

    if self.dirtyEffects or reason == 'orphan_recovery' then
        _cleanupStableSamples = _cleanupStableSamples + 1
        if _cleanupStableSamples < 2 then
            return false, 'confirming_standoff_cleanup'
        end
    end
    _cleanupStableSamples = 0
    _cleanupOwnNavigation = false
    self:markDirtyEffects(false)
    return true
end

mq.bind('/sk_assist', function(cmd)
    cmd = tostring(cmd or 'status'):lower()
    if cmd == 'stop' then
        CombatAssist.stop()
        module:stop()
        commandEcho('Stop requested')
    elseif cmd == 'status' or cmd == '' then
        local settings, enabled = applySettings()
        local target, reason = selectTarget(settings)
        commandEcho(
            'enabled=%s tier=%s ownsLease=%s request=%s target=%s source=%s hp=%s reason=%s last=%s',
            tostring(enabled), tostring(module.priority),
            tostring(module:ownsLease()), tostring(module.currentRequestId or 'none'),
            tostring(target and target.id or 'none'),
            tostring(target and target.source or 'none'), tostring(target and target.hp or 'none'),
            tostring(reason or 'ready'), tostring(_lastReason))
    else
        commandEcho('Usage: /sk_assist status|stop')
    end
end)

Assist.init({ CombatAssist = CombatAssist })
module:run(50)
CombatAssist.stop()

return module
