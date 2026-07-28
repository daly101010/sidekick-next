-- Pure, action-blind single-lease scheduler.
--
-- This module deliberately has no MacroQuest or Actors dependency. The
-- coordinator validates local transport identity, then delegates only
-- registered worker/session/request lifecycle data here.

local M = {}
M.__index = M

local function nonEmpty(value)
    local text = tostring(value or '')
    if text == '' then return nil end
    return text
end

local function clamp(value, minimum, maximum, fallback)
    local number = tonumber(value) or fallback
    if number < minimum then return minimum end
    if number > maximum then return maximum end
    return number
end

local function shallowCopy(source)
    if type(source) ~= 'table' then return nil end
    local result = {}
    for key, value in pairs(source) do result[key] = value end
    return result
end

local function sortedRegistry(registry)
    local result = {}
    for _, spec in ipairs(registry or {}) do result[#result + 1] = spec end
    table.sort(result, function(left, right)
        local leftTier = tonumber(left.tier) or math.huge
        local rightTier = tonumber(right.tier) or math.huge
        if leftTier ~= rightTier then return leftTier < rightTier end
        local leftOrder = tonumber(left.order) or math.huge
        local rightOrder = tonumber(right.order) or math.huge
        if leftOrder ~= rightOrder then return leftOrder < rightOrder end
        return tostring(left.module or '') < tostring(right.module or '')
    end)
    return result
end

function M.new(options)
    options = options or {}
    local self = setmetatable({}, M)
    self.protocolVersion = tonumber(options.protocolVersion) or 1
    self.bootId = assert(nonEmpty(options.bootId), 'lease scheduler requires bootId')
    self.defaultRequestTtlMs = tonumber(options.defaultRequestTtlMs) or 2000
    self.defaultLeaseTtlMs = tonumber(options.defaultLeaseTtlMs) or 5000
    self.revocationGraceMs = tonumber(options.revocationGraceMs) or 2000
    self.recoveryTtlMs = tonumber(options.recoveryTtlMs) or 5000
    self.registry = sortedRegistry(options.registry)
    self.byModule = {}
    for _, spec in ipairs(self.registry) do
        local moduleName = assert(nonEmpty(spec.module), 'worker registry entry requires module')
        assert(nonEmpty(spec.script), 'worker registry entry requires script')
        assert(not self.byModule[moduleName], 'duplicate worker module: ' .. moduleName)
        self.byModule[moduleName] = spec
    end

    self.requests = {}
    self.recoveryRequests = {}
    self.operationSequences = {}
    self.lease = nil
    self.pauseRequested = false
    self.available = true
    self.unavailableReason = nil
    self.selfDead = false
    self.preemptionEnabled = options.preemptionEnabled ~= false
    self.lifecycle = 'running'
    self.faultReason = nil
    self.tokenCounter = 0
    self.epoch = 0
    self.lastTransitionAtMs = tonumber(options.nowMs) or 0
    self.metrics = {
        requests = 0,
        requestRejects = 0,
        grants = 0,
        renewals = 0,
        releases = 0,
        revocations = 0,
        recoveries = 0,
        requestExpiries = 0,
        leaseTtlExpiries = 0,
        revocationGraceExpiries = 0,
        recoveryTimeouts = 0,
    }
    return self
end

function M:_acceptOperation(content, moduleName, workerSessionId)
    local sequence = tonumber(content and content.operationSeq)
    if not sequence or sequence <= 0 or sequence % 1 ~= 0 then
        return false, 'missing_operation_sequence'
    end
    local previous = self.operationSequences[moduleName]
    if previous and previous.workerSessionId == workerSessionId
        and sequence <= (previous.sequence or 0) then
        return false, 'stale_operation_sequence'
    end
    self.operationSequences[moduleName] = {
        workerSessionId = workerSessionId,
        sequence = sequence,
    }
    return true
end

function M:_transition(nowMs)
    self.epoch = self.epoch + 1
    self.lastTransitionAtMs = tonumber(nowMs) or self.lastTransitionAtMs
    self:_refreshLifecycle()
end

function M:_refreshLifecycle()
    if self.faultReason then
        self.lifecycle = 'faulted'
    elseif self.pauseRequested then
        self.lifecycle = self.lease and 'pausing' or 'paused'
    elseif self.lease and self.lease.status == 'recovering' then
        self.lifecycle = 'recovering'
    elseif not self.available then
        self.lifecycle = self.lease and 'draining' or 'suspended'
    else
        self.lifecycle = 'running'
    end
end

function M:_newToken(prefix)
    self.tokenCounter = self.tokenCounter + 1
    return string.format('%s:%s:%d', self.bootId, prefix or 'lease', self.tokenCounter)
end

function M:_validateWorker(content, senderScript)
    if type(content) ~= 'table' then return nil, 'invalid_payload' end
    local moduleName = nonEmpty(content.module)
    local workerSessionId = nonEmpty(content.workerSessionId)
    if not moduleName then return nil, 'missing_module' end
    if not workerSessionId then return nil, 'missing_worker_session' end
    local spec = self.byModule[moduleName]
    if not spec then return nil, 'unregistered_module' end
    if tostring(senderScript or '') ~= tostring(spec.script) then
        return nil, 'wrong_sender_script'
    end
    return spec, nil, moduleName, workerSessionId
end

function M:_validateBoot(content)
    if tostring(content.coordinatorBootId or '') ~= self.bootId then
        return false, 'wrong_coordinator_boot'
    end
    return true
end

function M:_validateLeaseOperation(content, senderScript, allowedStatuses)
    local spec, reason, moduleName, workerSessionId =
        self:_validateWorker(content, senderScript)
    if not spec then return nil, reason end
    local bootOk, bootReason = self:_validateBoot(content)
    if not bootOk then return nil, bootReason end
    if tonumber(content.version) ~= self.protocolVersion then
        return nil, 'wrong_protocol_version'
    end
    local lease = self.lease
    if not lease then return nil, 'no_active_lease' end
    if lease.holderModule ~= moduleName then return nil, 'wrong_holder_module' end
    if lease.workerSessionId ~= workerSessionId then return nil, 'wrong_worker_session' end
    if lease.requestId ~= tostring(content.requestId or '') then return nil, 'wrong_request_id' end
    if lease.token ~= tostring(content.token or '') then return nil, 'wrong_token' end
    if allowedStatuses and not allowedStatuses[lease.status] then
        return nil, 'wrong_lease_status'
    end
    return lease, nil, spec
end

function M:request(content, senderScript, nowMs)
    nowMs = tonumber(nowMs) or 0
    self.metrics.requests = self.metrics.requests + 1
    local spec, reason, moduleName, workerSessionId =
        self:_validateWorker(content, senderScript)
    if not spec then
        self.metrics.requestRejects = self.metrics.requestRejects + 1
        return false, reason
    end
    local bootOk, bootReason = self:_validateBoot(content)
    if not bootOk then
        self.metrics.requestRejects = self.metrics.requestRejects + 1
        return false, bootReason
    end
    if tonumber(content.version) ~= self.protocolVersion then
        self.metrics.requestRejects = self.metrics.requestRejects + 1
        return false, 'wrong_protocol_version'
    end
    local requestId = nonEmpty(content.requestId)
    if not requestId then
        self.metrics.requestRejects = self.metrics.requestRejects + 1
        return false, 'missing_request_id'
    end
    local ordered, orderReason =
        self:_acceptOperation(content, moduleName, workerSessionId)
    if not ordered then
        self.metrics.requestRejects = self.metrics.requestRejects + 1
        return false, orderReason
    end

    local lease = self.lease
    if lease
        and lease.holderModule == moduleName
        and lease.workerSessionId == workerSessionId
        and lease.requestId == requestId then
        return true, 'already_granted'
    end

    if self.pauseRequested or not self.available or self.faultReason then
        self.metrics.requestRejects = self.metrics.requestRejects + 1
        return false, self.faultReason and 'scheduler_faulted'
            or (self.pauseRequested and 'scheduler_paused' or 'scheduler_unavailable')
    end
    if self.selfDead and spec.canActDead ~= true then
        self.metrics.requestRejects = self.metrics.requestRejects + 1
        return false, 'worker_not_allowed_while_dead'
    end

    local ttlMs = clamp(content.requestTtlMs, 250, 10000,
        self.defaultRequestTtlMs)
    local previous = self.requests[moduleName]
    local isRefresh = previous
        and previous.workerSessionId == workerSessionId
        and previous.requestId == requestId
    local firstReceivedAtMs = isRefresh
        and (tonumber(previous.firstReceivedAtMs)
            or tonumber(previous.receivedAtMs)) or nowMs
    local blockedByModule = isRefresh and previous.blockedByModule
        or (self.lease and self.lease.holderModule or nil)
    local blockedByStatus = isRefresh and previous.blockedByStatus
        or (self.lease and self.lease.status or nil)
    self.requests[moduleName] = {
        version = self.protocolVersion,
        module = moduleName,
        workerSessionId = workerSessionId,
        requestId = requestId,
        requestTtlMs = ttlMs,
        receivedAtMs = nowMs,
        firstReceivedAtMs = firstReceivedAtMs,
        lastReceivedAtMs = nowMs,
        expiresAtMs = nowMs + ttlMs,
        senderScript = spec.script,
        blockedByModule = blockedByModule,
        blockedByStatus = blockedByStatus,
        refreshCount = isRefresh
            and ((tonumber(previous.refreshCount) or 0) + 1) or 0,
    }
    self:_transition(nowMs)
    return true, 'queued'
end

function M:withdraw(content, senderScript, nowMs)
    nowMs = tonumber(nowMs) or 0
    local spec, reason, moduleName, workerSessionId =
        self:_validateWorker(content, senderScript)
    if not spec then return false, reason end
    local bootOk, bootReason = self:_validateBoot(content)
    if not bootOk then return false, bootReason end
    if tonumber(content.version) ~= self.protocolVersion then
        return false, 'wrong_protocol_version'
    end
    local ordered, orderReason =
        self:_acceptOperation(content, moduleName, workerSessionId)
    if not ordered then return false, orderReason end
    local request = self.requests[moduleName]
    -- Advancing the sequence even when the request has not arrived yet creates
    -- a withdrawal tombstone: a delayed lower-sequence request cannot resurrect.
    if not request then return true, 'withdrawn_absent' end
    if request.workerSessionId ~= workerSessionId then return false, 'wrong_worker_session' end
    if request.requestId ~= tostring(content.requestId or '') then return false, 'wrong_request_id' end
    self.requests[moduleName] = nil
    self:_transition(nowMs)
    return true, 'withdrawn'
end

function M:renew(content, senderScript, nowMs)
    nowMs = tonumber(nowMs) or 0
    local lease, reason = self:_validateLeaseOperation(content, senderScript,
        { active = true })
    if not lease then return false, reason end
    lease.renewedAtMs = nowMs
    self.metrics.renewals = self.metrics.renewals + 1
    return true, 'renewed'
end

function M:release(content, senderScript, nowMs)
    nowMs = tonumber(nowMs) or 0
    local lease, reason = self:_validateLeaseOperation(content, senderScript,
        { active = true, revoking = true, recovering = true })
    if not lease then return false, reason end
    self.lease = nil
    self.metrics.releases = self.metrics.releases + 1
    self:_transition(nowMs)
    return true, 'released'
end

function M:recovered(content, senderScript, nowMs)
    nowMs = tonumber(nowMs) or 0
    local lease, reason = self:_validateLeaseOperation(content, senderScript,
        { recovering = true })
    if not lease then
        -- Track validation-reject frequency for the current recovering lease.
        -- Legitimate recoveries rarely reject; a torrent of rejects for the
        -- same recovering lease means the worker is sending stale token/
        -- requestId (transport dropped an update, or the lease was already
        -- rotated by adoptRecoverySession between broadcast and worker send).
        -- The tick-time safety valve M:tickRecoveryStuckCheck reads this.
        local live = self.lease
        if live and live.status == 'recovering' then
            live.rejectedRecoveryReports =
                (tonumber(live.rejectedRecoveryReports) or 0) + 1
        end
        return false, reason
    end
    self.lease = nil
    self.metrics.releases = self.metrics.releases + 1
    self:_transition(nowMs)
    return true, 'recovered'
end

-- Safety valve: worker's heartbeat is authoritative for its own local state.
-- When a lease sits in 'recovering' for a module whose freshest heartbeat says
-- "I have no dirty effects, no pending request, no in-flight action", the
-- worker considers itself clean but the coordinator disagrees — usually
-- because a lease:recovered message was dropped by transport dedup or
-- rejected on a stale token/requestId. Force-clear the lease so the module
-- can queue fresh work. Only fires against 'recovering' status; active
-- leases still require an explicit release to prevent stealing in-flight
-- work from a component that genuinely owns the mutation boundary.
function M:observeCleanHeartbeat(moduleName, workerSessionId, senderScript, nowMs)
    nowMs = tonumber(nowMs) or 0
    moduleName = tostring(moduleName or '')
    workerSessionId = nonEmpty(workerSessionId)
    local spec = self.byModule[moduleName]
    if not spec then return false, 'unregistered_module' end
    if tostring(senderScript or '') ~= spec.script then
        return false, 'wrong_sender_script'
    end
    if not workerSessionId then return false, 'missing_worker_session' end
    local lease = self.lease
    if not lease or lease.status ~= 'recovering' then
        return false, 'no_recovering_lease'
    end
    if lease.holderModule ~= moduleName then return false, 'wrong_holder_module' end
    if lease.workerSessionId ~= workerSessionId then
        return false, 'wrong_worker_session'
    end
    self.lease = nil
    self.metrics.releases = self.metrics.releases + 1
    self.metrics.heartbeatClearedRecoveries =
        (self.metrics.heartbeatClearedRecoveries or 0) + 1
    self:_transition(nowMs)
    return true, 'heartbeat_cleared'
end

function M:_beginRevocation(reason, nowMs)
    local lease = self.lease
    if not lease or lease.status ~= 'active' then return false end
    lease.status = 'revoking'
    lease.revokeReason = tostring(reason or 'revoked')
    lease.revokedAtMs = nowMs
    lease.revocationDeadlineAtMs = nowMs + self.revocationGraceMs
    self.metrics.revocations = self.metrics.revocations + 1
    self:_transition(nowMs)
    return true
end

function M:revoke(reason, nowMs)
    return self:_beginRevocation(reason, tonumber(nowMs) or 0)
end

function M:beginRecovery(reason, nowMs)
    nowMs = tonumber(nowMs) or 0
    local lease = self.lease
    if not lease then return false, 'no_active_lease' end
    if lease.status == 'recovering' then return true, 'already_recovering' end
    local oldToken = lease.token
    local oldRequestId = lease.requestId
    lease.status = 'recovering'
    lease.revokeReason = tostring(reason or lease.revokeReason or 'lease_recovery')
    lease.fencedToken = oldToken
    lease.fencedRequestId = oldRequestId
    lease.token = self:_newToken('recovery')
    lease.requestId = string.format('recovery:%d', self.tokenCounter)
    lease.grantedAtMs = nowMs
    lease.renewedAtMs = nowMs
    lease.queueTiming = nil
    lease.ttlMs = self.recoveryTtlMs
    lease.recoveryStartedAtMs = nowMs
    lease.recoveryDeadlineAtMs = nowMs + self.recoveryTtlMs
    lease.recoveryAttempt = tonumber(lease.recoveryAttempt) or 1
    lease.recoveryTimedOut = nil
    lease.recoveryRestartIssued = nil
    self.requests[lease.holderModule] = nil
    self.metrics.recoveries = self.metrics.recoveries + 1
    self:_transition(nowMs)
    return true, 'recovering'
end

function M:adoptRecoverySession(moduleName, workerSessionId, senderScript, nowMs)
    nowMs = tonumber(nowMs) or 0
    local spec = self.byModule[tostring(moduleName or '')]
    local lease = self.lease
    if not spec or spec.script ~= tostring(senderScript or '') then
        return false, 'wrong_sender_script'
    end
    if not lease or lease.status ~= 'recovering'
        or lease.holderModule ~= moduleName then
        return false, 'no_matching_recovery'
    end
    workerSessionId = nonEmpty(workerSessionId)
    if not workerSessionId then return false, 'missing_worker_session' end
    if lease.workerSessionId == workerSessionId then return true, 'already_assigned' end
    lease.workerSessionId = workerSessionId
    lease.fencedToken = lease.token
    lease.token = self:_newToken('recovery')
    lease.requestId = string.format('recovery:%d', self.tokenCounter)
    lease.grantedAtMs = nowMs
    lease.renewedAtMs = nowMs
    lease.recoveryStartedAtMs = nowMs
    lease.recoveryDeadlineAtMs = nowMs + self.recoveryTtlMs
    lease.recoveryAttempt = (tonumber(lease.recoveryAttempt) or 1) + 1
    lease.recoveryTimedOut = nil
    lease.recoveryRestartIssued = nil
    self:_transition(nowMs)
    return true, 'recovery_reassigned'
end

function M:requestRecovery(moduleName, workerSessionId, senderScript, nowMs)
    nowMs = tonumber(nowMs) or 0
    moduleName = tostring(moduleName or '')
    workerSessionId = nonEmpty(workerSessionId)
    local spec = self.byModule[moduleName]
    if not spec then return false, 'unregistered_module' end
    if tostring(senderScript or '') ~= spec.script then return false, 'wrong_sender_script' end
    if not workerSessionId then return false, 'missing_worker_session' end

    if self.lease and self.lease.holderModule == moduleName then
        if self.lease.status ~= 'recovering' then
            self:beginRecovery('dirty_effects', nowMs)
        end
        return self:adoptRecoverySession(moduleName, workerSessionId,
            senderScript, nowMs)
    end

    self.recoveryRequests[moduleName] = {
        module = moduleName,
        workerSessionId = workerSessionId,
        senderScript = spec.script,
        receivedAtMs = nowMs,
    }
    if self.lease and self.lease.status == 'active' then
        self:_beginRevocation('recovery_pending:' .. moduleName, nowMs)
    end
    self:_transition(nowMs)
    return true, 'recovery_queued'
end

-- Dirty effects are expected while the exact active lease owns their cleanup.
-- Recovery is required only when the worker explicitly reports lost authority,
-- or when dirty effects no longer match the coordinator's active lease.
function M:heartbeatNeedsRecovery(content, moduleName, workerSessionId)
    content = content or {}
    if content.needsRecovery == true then return true end
    if content.dirtyEffects ~= true then return false end

    local lease = self.lease
    return not (lease
        and lease.status == 'active'
        and tostring(lease.holderModule or '') == tostring(moduleName or '')
        and tostring(lease.workerSessionId or '') == tostring(workerSessionId or '')
        and tostring(lease.requestId or '') == tostring(content.requestId or ''))
end

function M:observeWorkerSession(moduleName, workerSessionId, senderScript, nowMs)
    nowMs = tonumber(nowMs) or 0
    moduleName = tostring(moduleName or '')
    workerSessionId = nonEmpty(workerSessionId)
    local spec = self.byModule[moduleName]
    if not spec then return false, 'unregistered_module' end
    if tostring(senderScript or '') ~= spec.script then return false, 'wrong_sender_script' end
    if not workerSessionId then return false, 'missing_worker_session' end

    local changed = false
    local request = self.requests[moduleName]
    if request and request.workerSessionId ~= workerSessionId then
        self.requests[moduleName] = nil
        changed = true
    end
    local recoveryRequest = self.recoveryRequests[moduleName]
    if recoveryRequest and recoveryRequest.workerSessionId ~= workerSessionId then
        recoveryRequest.workerSessionId = workerSessionId
        recoveryRequest.receivedAtMs = nowMs
        changed = true
    end

    local lease = self.lease
    if lease and lease.holderModule == moduleName
        and lease.workerSessionId ~= workerSessionId then
        if lease.status ~= 'recovering' then
            self:beginRecovery('worker_session_changed', nowMs)
        end
        self:adoptRecoverySession(moduleName, workerSessionId, senderScript, nowMs)
        changed = true
    end
    if changed then self:_transition(nowMs) end
    return true, changed and 'session_updated' or 'session_unchanged'
end

function M:withdrawWorker(moduleName, reason, nowMs)
    nowMs = tonumber(nowMs) or 0
    moduleName = tostring(moduleName or '')
    local changed = false
    if self.requests[moduleName] then
        self.requests[moduleName] = nil
        changed = true
    end
    if self.recoveryRequests[moduleName] then
        self.recoveryRequests[moduleName] = nil
        changed = true
    end
    if self.lease and self.lease.holderModule == moduleName
        and self.lease.status == 'active' then
        self:_beginRevocation(reason or 'worker_withdrawn', nowMs)
        changed = true
    end
    if changed then self:_transition(nowMs) end
    return changed
end

function M:faultRecovery(reason, nowMs)
    if not self.lease or self.lease.status ~= 'recovering' then
        return false, 'not_recovering'
    end
    self.faultReason = tostring(reason or 'recovery_failed')
    self.lease.recoveryFault = self.faultReason
    self:_transition(tonumber(nowMs) or 0)
    return true, 'faulted'
end

function M:setPaused(paused, reason, nowMs)
    nowMs = tonumber(nowMs) or 0
    paused = paused == true
    if self.pauseRequested == paused then
        self:_refreshLifecycle()
        return false
    end
    self.pauseRequested = paused
    if paused then
        self.requests = {}
        self:_beginRevocation(reason or 'automation_paused', nowMs)
    end
    self:_transition(nowMs)
    return true
end

function M:setAvailable(available, reason, nowMs)
    nowMs = tonumber(nowMs) or 0
    available = available == true
    if self.available == available
        and (available or self.unavailableReason == tostring(reason or 'unavailable')) then
        return false
    end
    self.available = available
    self.unavailableReason = available and nil or tostring(reason or 'unavailable')
    if not available then
        self.requests = {}
        self:_beginRevocation(self.unavailableReason, nowMs)
    end
    self:_transition(nowMs)
    return true
end

function M:setSelfDead(dead, nowMs)
    nowMs = tonumber(nowMs) or 0
    dead = dead == true
    if self.selfDead == dead then return false end
    self.selfDead = dead
    if dead then
        for moduleName in pairs(self.requests) do
            local spec = self.byModule[moduleName]
            if not spec or spec.canActDead ~= true then
                self.requests[moduleName] = nil
            end
        end
        local lease = self.lease
        local spec = lease and self.byModule[lease.holderModule] or nil
        if lease and (not spec or spec.canActDead ~= true) then
            self:_beginRevocation('self_dead', nowMs)
        end
    end
    self:_transition(nowMs)
    return true
end

function M:setPreemptionEnabled(enabled, nowMs)
    enabled = enabled ~= false
    if self.preemptionEnabled == enabled then return false end
    self.preemptionEnabled = enabled
    self:_transition(tonumber(nowMs) or 0)
    return true
end

function M:_expireRequests(nowMs)
    local changed = false
    for moduleName, request in pairs(self.requests) do
        if nowMs > (tonumber(request.expiresAtMs) or 0) then
            self.requests[moduleName] = nil
            self.metrics.requestExpiries = self.metrics.requestExpiries + 1
            changed = true
        end
    end
    if changed then self:_transition(nowMs) end
end

function M:_bestRequest(predicate)
    for _, spec in ipairs(self.registry) do
        local request = self.requests[spec.module]
        if request
            and (not self.selfDead or spec.canActDead == true)
            and (not predicate or predicate(spec, request)) then
            return spec, request
        end
    end
    return nil, nil
end

function M:_grantRecovery(nowMs)
    for _, spec in ipairs(self.registry) do
        local request = self.recoveryRequests[spec.module]
        if request then
            self.recoveryRequests[spec.module] = nil
            local token = self:_newToken('recovery')
            self.lease = {
                coordinatorBootId = self.bootId,
                token = token,
                holderModule = spec.module,
                workerSessionId = request.workerSessionId,
                requestId = string.format('recovery:%d', self.tokenCounter),
                tier = spec.tier,
                status = 'recovering',
                grantedAtMs = nowMs,
                renewedAtMs = nowMs,
                ttlMs = self.recoveryTtlMs,
                revokeReason = 'dirty_effects',
                recoveryStartedAtMs = nowMs,
                recoveryDeadlineAtMs = nowMs + self.recoveryTtlMs,
                recoveryAttempt = 1,
            }
            self.metrics.recoveries = self.metrics.recoveries + 1
            self:_transition(nowMs)
            return true
        end
    end
    return false
end

function M:_grantNext(nowMs)
    if self.lease or self.faultReason then
        return false
    end
    if self:_grantRecovery(nowMs) then return true end
    if self.pauseRequested or not self.available then return false end
    local spec, request = self:_bestRequest()
    if not spec then return false end
    self.requests[spec.module] = nil
    self.lease = {
        coordinatorBootId = self.bootId,
        token = self:_newToken('lease'),
        holderModule = spec.module,
        workerSessionId = request.workerSessionId,
        requestId = request.requestId,
        tier = spec.tier,
        status = 'active',
        grantedAtMs = nowMs,
        renewedAtMs = nowMs,
        ttlMs = self.defaultLeaseTtlMs,
        queueTiming = {
            schedulerWaitMs = math.max(0, nowMs
                - (tonumber(request.firstReceivedAtMs)
                    or tonumber(request.receivedAtMs) or nowMs)),
            blockedByModule = tostring(request.blockedByModule or ''),
            blockedByStatus = tostring(request.blockedByStatus or ''),
            requestRefreshes = tonumber(request.refreshCount) or 0,
        },
    }
    -- Requests can arrive together while no lease exists. Attribute those
    -- already waiting requests to the holder selected by this transition.
    for _, pending in pairs(self.requests) do
        if not nonEmpty(pending.blockedByModule) then
            pending.blockedByModule = spec.module
            pending.blockedByStatus = 'active'
        end
    end
    self.metrics.grants = self.metrics.grants + 1
    self:_transition(nowMs)
    return true
end

function M:_considerPreemption(nowMs)
    local lease = self.lease
    if not self.preemptionEnabled or not lease or lease.status ~= 'active' then
        return false
    end
    local spec = self:_bestRequest(function(candidate)
        return candidate.canPreempt == true
            and tonumber(candidate.tier) < tonumber(lease.tier)
    end)
    if not spec then return false end
    return self:_beginRevocation('preempted_by:' .. tostring(spec.module), nowMs)
end

-- Threshold for the "stuck recovery loop" safety valve. If a lease has been
-- in 'recovering' status for this long AND rejected >=2 recovery reports
-- from the worker (token/requestId mismatch that heartbeat-based clearing
-- can't resolve), drop the holder record. Chosen to be well above any
-- legitimate cleanup: real recoveries complete in 1-30ms; the recovery TTL
-- itself is 5s (LEASE_RECOVERY_TTL_MS), so 8s guarantees at least one
-- adoptRecoverySession renewal cycle has passed without progress.
local STUCK_RECOVERY_MS = 8000
local STUCK_RECOVERY_MIN_REJECTS = 2

function M:tick(nowMs)
    nowMs = tonumber(nowMs) or 0
    self:_expireRequests(nowMs)

    local lease = self.lease
    if lease then
        if lease.status == 'active'
            and (nowMs - (tonumber(lease.renewedAtMs) or 0))
                > (tonumber(lease.ttlMs) or self.defaultLeaseTtlMs) then
            self.metrics.leaseTtlExpiries =
                self.metrics.leaseTtlExpiries + 1
            self:beginRecovery('lease_ttl_expired', nowMs)
        elseif lease.status == 'revoking'
            and nowMs >= (tonumber(lease.revocationDeadlineAtMs) or 0) then
            self.metrics.revocationGraceExpiries =
                self.metrics.revocationGraceExpiries + 1
            self:beginRecovery('revocation_grace_expired', nowMs)
        elseif lease.status == 'recovering'
            and nowMs >= (tonumber(lease.recoveryDeadlineAtMs) or math.huge) then
            if lease.recoveryTimedOut ~= true then
                self.metrics.recoveryTimeouts =
                    self.metrics.recoveryTimeouts + 1
                lease.recoveryTimedOut = true
            end
        end

        -- Stuck-recovery safety valve: if the same recovering lease has
        -- lingered >8s with multiple rejected lease:recovered messages, the
        -- worker and coordinator are permanently desynced on the current
        -- token/requestId. Drop the holder record so the module can queue
        -- fresh work; the worker's next dirty heartbeat (if any) will queue
        -- a new recovery cleanly. This is aggressive but bounded: only
        -- fires on recovering leases with actual reject evidence, never on
        -- active leases doing real work.
        if lease and lease.status == 'recovering'
            and (tonumber(lease.rejectedRecoveryReports) or 0)
                >= STUCK_RECOVERY_MIN_REJECTS
            and (nowMs - (tonumber(lease.recoveryStartedAtMs) or nowMs))
                >= STUCK_RECOVERY_MS then
            self.lease = nil
            self.metrics.releases = self.metrics.releases + 1
            self.metrics.stuckRecoveryClears =
                (self.metrics.stuckRecoveryClears or 0) + 1
        end
    end

    self:_considerPreemption(nowMs)
    self:_grantNext(nowMs)
    self:_refreshLifecycle()
    return self:getSnapshot()
end

function M:bestPendingTier()
    local spec = self:_bestRequest()
    return spec and spec.tier or nil
end

function M:getSnapshot()
    local requestCount = 0
    for _ in pairs(self.requests) do requestCount = requestCount + 1 end
    local recoveryRequestCount = 0
    for _ in pairs(self.recoveryRequests) do
        recoveryRequestCount = recoveryRequestCount + 1
    end
    return {
        coordinatorBootId = self.bootId,
        epoch = self.epoch,
        lifecycle = self.lifecycle,
        lease = shallowCopy(self.lease),
        requestCount = requestCount,
        recoveryRequestCount = recoveryRequestCount,
        activePriority = self.lease and self.lease.tier
            or self:bestPendingTier() or 99,
        preemptionEnabled = self.preemptionEnabled,
        available = self.available,
        unavailableReason = self.unavailableReason,
        selfDead = self.selfDead,
        faultReason = self.faultReason,
        lastTransitionAtMs = self.lastTransitionAtMs,
        metrics = shallowCopy(self.metrics),
    }
end

return M
