local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local Chase = require('sidekick-next.automation.chase')
local Movement = require('sidekick-next.utils.chase_movement')

local module = ModuleBase.create('chase', lib.Priority.DPS)

local SLICE_MS = 15000
local PROGRESS_SAMPLE_MS = 1000
local REQUEUE_BACKOFF_MS = 500
local MAX_RECOVERY_ATTEMPTS = 2
local STAND_CONFIRM_MS = 1500

local _settings = {}
local _intent = nil
local _activeAction = nil
local _lastReason = 'init'
local _backoffUntilMs = 0
local _orphanRecoveryComplete = false
local _lastTelemetryAtMs = 0

local function nowMs()
    return lib.getTimeMs()
end

local function positionDelta(left, right)
    if type(left) ~= 'table' or type(right) ~= 'table' then return 0 end
    local dx = (tonumber(left.x) or 0) - (tonumber(right.x) or 0)
    local dy = (tonumber(left.y) or 0) - (tonumber(right.y) or 0)
    local dz = (tonumber(left.z) or 0) - (tonumber(right.z) or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function refreshSettings()
    _settings = lib.getSettings() or _settings or {}
    Chase.applySettings(_settings)
    return _settings
end

local function currentDistance(action)
    if type(action) ~= 'table' or type(action.fingerprint) ~= 'table' then return nil end
    local spawn = Chase.validateFingerprint(action.fingerprint)
    if not spawn then return nil end
    return Chase.distanceTo(spawn)
end

local function needsBackoff(reason)
    reason = tostring(reason or ''):lower()
    return reason:find('timed_out', 1, true) ~= nil
        or reason:find('stalled', 1, true) ~= nil
        or reason:find('start_failed', 1, true) ~= nil
        or reason:find('arrival_unstable', 1, true) ~= nil
        or reason:find('dirty_marker_write_failed', 1, true) ~= nil
        or reason:find('no_movement_backend', 1, true) ~= nil
end

local function finishEpisode(reason)
    reason = tostring(reason or 'completed')
    if needsBackoff(reason) then _backoffUntilMs = nowMs() + REQUEUE_BACKOFF_MS end
    Chase.endEpisode()
    _activeAction = nil
    _lastReason = reason
end

local function resultPhase(reason)
    reason = tostring(reason or '')
    if reason == 'arrived' then return 'resolved' end
    if reason:find('timed_out', 1, true) then return 'timed_out' end
    if reason:find('stalled', 1, true)
        or reason:find('failed', 1, true)
        or reason:find('backend_', 1, true)
        or reason == 'no_movement_backend'
    then
        return 'failed'
    end
    return 'cancelled'
end

local function driveCleanup(self, action, reason, requireInRange)
    action = action or _activeAction
    reason = tostring(reason or (action and action.terminalReason) or 'cleanup')
    if action then
        action.terminalReason = action.terminalReason or reason
        action.requireInRangeCleanup = action.requireInRangeCleanup == true
            or requireInRange == true
    end

    Movement.beginCleanup(reason, action and action.requireInRangeCleanup == true)
    local done, detail = Movement.tickCleanup(currentDistance(action))
    if not done then
        self:renewLease()
        _lastReason = tostring(detail or 'cleanup')
        return false, detail
    end

    local finalReason = (detail == nil or detail == 'clean')
        and reason or tostring(detail)
    finishEpisode(finalReason)
    self:finishAction({
        phase = resultPhase(finalReason),
        reason = finalReason,
        targetId = action and action.targetId or 0,
        targetName = action and action.targetName or '',
        backend = action and action.backend or '',
        recoveryAttempts = action and action.recoveryAttempts or 0,
        elapsedMs = action and action.sliceStartedAtMs
            and math.max(0, nowMs() - action.sliceStartedAtMs) or 0,
    })
    return false, finalReason
end

local function publishTelemetry(self)
    local now = nowMs()
    if (now - _lastTelemetryAtMs) < 500 then return end
    _lastTelemetryAtMs = now
    local movement = Movement.snapshot()
    self:sendToLocalUi('chase:telemetry', {
        reason = _lastReason,
        backoffMs = math.max(0, _backoffUntilMs - now),
        movement = movement,
        targetId = _activeAction and _activeAction.targetId
            or (_intent and _intent.targetId) or 0,
        targetName = _activeAction and _activeAction.targetName
            or (_intent and _intent.targetName) or '',
    })
end

module.onTick = function(self)
    refreshSettings()

    if not _orphanRecoveryComplete then
        _intent = {
            kind = 'chase_orphan_recovery',
            name = 'Recover chase movement',
            targetId = 0,
            skipBoundaryTarget = true,
            breaksInvis = false,
            idempotencyKey = 'chase:orphan-recovery',
            reason = 'orphan_recovery',
        }
        _lastReason = 'orphan_recovery_pending'
        publishTelemetry(self)
        return
    end

    if self.currentRequestId then
        local action = self.currentAction
        if not self:ownsLease(self.currentRequestId) and action then
            local _, distance, reason = Chase.revalidateIntent(action, _settings)
            local externalReason = Movement.externalMovementReason()
            if reason or externalReason
                or (distance and distance <= (tonumber(action.triggerDistance) or 0))
            then
                self:withdrawLeaseRequest(reason or externalReason or 'in_range_while_queued')
                _lastReason = tostring(reason or externalReason or 'in_range_while_queued')
            end
        end
        _intent = nil
        publishTelemetry(self)
        return
    end

    if Movement.hasOwnedEffects() then
        _intent = {
            kind = 'chase_owned_cleanup',
            name = 'Clean chase movement',
            targetId = 0,
            skipBoundaryTarget = true,
            breaksInvis = false,
            idempotencyKey = 'chase:owned-cleanup',
            reason = 'orphan_local_effect',
        }
        _lastReason = 'orphan_local_effect'
        publishTelemetry(self)
        return
    end

    if nowMs() < _backoffUntilMs then
        _intent = nil
        _lastReason = 'slice_backoff'
        publishTelemetry(self)
        return
    end

    local externalReason = Movement.externalMovementReason()
    local intent, reason = Chase.selectIntent(_settings, {
        externalMovementReason = externalReason,
    })
    if intent then
        intent.kind = 'chase'
        intent.workflow = 'chase_slice'
        intent.targetId = intent.fingerprint.id
        intent.targetName = intent.fingerprint.cleanName
        intent.targetType = 'PC'
        intent.breaksInvis = false
        intent.actionKey = string.format('chase:%d:%d:%d',
            tonumber(intent.fingerprint.zoneId) or 0,
            tonumber(intent.fingerprint.instanceId) or 0,
            tonumber(intent.fingerprint.id) or 0)
        intent.idempotencyKey = intent.actionKey
    end
    _intent = intent
    _lastReason = intent and 'ready' or tostring(reason or 'idle')
    publishTelemetry(self)
end

module.shouldAct = function()
    return _intent ~= nil
end

module.getAction = function()
    return _intent
end

module.executeAction = function(self)
    local action = self:getLeaseAction()
    if not action then return true, 'missing_lease_action' end
    _activeAction = action
    refreshSettings()

    if action.kind == 'chase_orphan_recovery' then
        local done, reason = Movement.tickOrphanRecovery()
        _lastReason = tostring(reason or 'orphan_recovery')
        if done then
            _orphanRecoveryComplete = true
            _activeAction = nil
            return true, _lastReason
        end
        self:renewLease()
        return false, _lastReason
    elseif action.kind == 'chase_owned_cleanup' then
        Movement.beginCleanup('orphan_local_effect', false)
        local done, reason = Movement.tickCleanup(nil)
        _lastReason = tostring(reason or 'owned_cleanup')
        if done then
            _activeAction = nil
            return true, _lastReason
        end
        self:renewLease()
        return false, _lastReason
    end

    local _, distance, invalidReason = Chase.revalidateIntent(action, _settings)
    if invalidReason then
        return driveCleanup(self, action, invalidReason, false)
    end
    action.lastDistance = distance

    if not action.sliceStartedAtMs then
        action.sliceStartedAtMs = nowMs()
        action.deadlineAtMs = action.sliceStartedAtMs + SLICE_MS
        action.lastProgressAtMs = action.sliceStartedAtMs
        action.lastProgressPosition = Chase.position()
        action.lastProgressDistance = distance
        action.recoveryAttempts = 0
        action.arrivalSamples = 0
        action.phase = 'preparing'
    end

    if nowMs() >= action.deadlineAtMs then
        return driveCleanup(self, action, 'timed_out', false)
    end

    local sitting = lib.safeTLO(function() return mq.TLO.Me.Sitting() end, false) == true
    if sitting then
        if not action.standRequestedAtMs
            or (nowMs() - action.standRequestedAtMs) >= 500
        then
            Movement.requestStand()
            action.standRequestedAtMs = action.standRequestedAtMs or nowMs()
        end
        if (nowMs() - action.standRequestedAtMs) >= STAND_CONFIRM_MS then
            return driveCleanup(self, action, 'stand_failed', false)
        end
        _lastReason = 'standing'
        return false, _lastReason
    end
    action.standRequestedAtMs = nil

    if action.phase == 'preparing' then
        -- This is the final pre-command check after the lease grant.
        local externalReason = Movement.externalMovementReason()
        if externalReason then
            return driveCleanup(self, action, externalReason, false)
        end
        local lease = self:getLease() or {}
        local started, backendOrReason = Movement.begin(
            action.fingerprint, action.arrivalDistance, self.currentRequestId, {
                token = lease.token,
                workerSessionId = self.workerSessionId,
                coordinatorBootId = self.coordinatorBootId,
            })
        if not started then
            return driveCleanup(self, action, backendOrReason or 'movement_start_failed', false)
        end
        action.backend = backendOrReason
        action.phase = 'moving'
        _lastReason = 'starting:' .. tostring(action.backend)
        return false, _lastReason
    end

    local route = Movement.tick()
    if route.status == 'backend_start_failed' then
        return driveCleanup(self, action, 'backend_start_failed', false)
    end
    if route.status and route.status:find('^recovery_failed:') then
        return driveCleanup(self, action, 'stalled:' .. route.status, false)
    end
    if route.status and route.status:find('^external_') then
        return driveCleanup(self, action, route.status, false)
    end
    if route.phase and route.phase:find('^recovery_') then
        _lastReason = tostring(route.status or route.phase)
        return false, _lastReason
    end

    if distance <= (tonumber(action.arrivalDistance) or 20) then
        action.arrivalSamples = (action.arrivalSamples or 0) + 1
        if action.arrivalSamples >= 2 then
            return driveCleanup(self, action, 'arrived', true)
        end
        _lastReason = 'arrival_confirming'
        return false, _lastReason
    end
    action.arrivalSamples = 0

    if route.status == 'backend_replaced' then
        return driveCleanup(self, action, 'external_backend_replaced', false)
    end
    if route.status == 'backend_inactive' then
        if (action.recoveryAttempts or 0) >= MAX_RECOVERY_ATTEMPTS then
            return driveCleanup(self, action, 'stalled:backend_inactive', false)
        end
        local recovering, reason = Movement.beginRecovery()
        if not recovering then
            return driveCleanup(self, action, 'stalled:' .. tostring(reason), false)
        end
        action.recoveryAttempts = (action.recoveryAttempts or 0) + 1
        action.lastProgressAtMs = nowMs()
        action.lastProgressPosition = Chase.position()
        action.lastProgressDistance = distance
        _lastReason = 'recovery:' .. tostring(action.recoveryAttempts)
        return false, _lastReason
    end

    if (nowMs() - (action.lastProgressAtMs or 0)) >= PROGRESS_SAMPLE_MS then
        local position = Chase.position()
        local moved = positionDelta(position, action.lastProgressPosition)
        local priorDistance = tonumber(action.lastProgressDistance) or distance
        local closer = priorDistance - distance
        local progressed = closer >= 0.75
            or (moved >= 1.5 and distance <= (priorDistance + 2))

        action.lastProgressAtMs = nowMs()
        action.lastProgressPosition = position
        action.lastProgressDistance = distance
        if not progressed then
            if (action.recoveryAttempts or 0) >= MAX_RECOVERY_ATTEMPTS then
                return driveCleanup(self, action, 'stalled:no_progress', false)
            end
            local recovering, reason = Movement.beginRecovery()
            if not recovering then
                return driveCleanup(self, action, 'stalled:' .. tostring(reason), false)
            end
            action.recoveryAttempts = (action.recoveryAttempts or 0) + 1
            _lastReason = 'recovery:' .. tostring(action.recoveryAttempts)
            return false, _lastReason
        end
    end

    self:renewLease()
    _lastReason = string.format('moving:%s:%.1f', tostring(action.backend), distance)
    return false, _lastReason
end

local function finalizeLease(self, action, reason)
    action = action or _activeAction
    if not Movement.hasOwnedEffects() then
        if not _orphanRecoveryComplete then
            local done, detail = Movement.tickOrphanRecovery()
            if done then _orphanRecoveryComplete = true end
            return done, detail
        end
        finishEpisode(reason)
        return true, reason
    end

    Movement.beginCleanup(reason or 'lease_finalizing', false)
    local done, detail = Movement.tickCleanup(currentDistance(action))
    if done then finishEpisode(detail or reason) end
    return done, detail
end

module.onLeaseFinalizing = finalizeLease
module.onSafetyDrain = finalizeLease

module.onSchedulerResume = function(self, elapsedMs)
    elapsedMs = tonumber(elapsedMs) or 0
    local action = self.currentAction
    if action and elapsedMs > 0 then
        for _, key in ipairs({
            'sliceStartedAtMs', 'deadlineAtMs', 'lastProgressAtMs',
            'standRequestedAtMs',
        }) do
            if tonumber(action[key]) then action[key] = action[key] + elapsedMs end
        end
    end
    Movement.rebaseTimers(elapsedMs)
end

module:run(50)

return module
