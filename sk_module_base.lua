-- Shared worker lifecycle for SideKick-Next's single-lease coordinator.
--
-- The coordinator never receives an action payload.  It schedules a registered
-- worker identity and an opaque request id; the selected action remains local
-- to this Lua process for its entire lifetime.

local mq = require('mq')
local actors = require('actors')
local lib = require('sidekick-next.sk_lib')
local ActionExecutor = require('sidekick-next.utils.action_executor')
local ActionCounters = require('sidekick-next.utils.action_counters')
local ActionBoundary = require('sidekick-next.utils.action_boundary')

local M = {}

local debugLog = require('sidekick-next.utils.debug_log')
    .moduleTagged('sk_module_base', 'SK_MODULE_BASE')

local REQUEST_REFRESH_MS = 500
local LEASE_RENEW_MS = 500
local REQUEST_TTL_MS = 2000
local MAX_STATE_INBOX = 32

local function nowMs()
    return lib.getTimeMs()
end

local function actorSafeCopy(value, seen)
    local valueType = type(value)
    if valueType == 'string' or valueType == 'number' or valueType == 'boolean' then
        return value
    end
    if valueType ~= 'table' then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    local out = {}
    for key, child in pairs(value) do
        local keyType = type(key)
        if keyType == 'string'
            or (keyType == 'number' and key >= 0 and key % 1 == 0) then
            local copied = actorSafeCopy(child, seen)
            if copied ~= nil then out[key] = copied end
        end
    end
    seen[value] = nil
    return out
end

local function actionKey(action)
    if type(action) ~= 'table' then return '' end
    return tostring(action.idempotencyKey
        or action.actionKey
        or string.format('%s:%s:%s',
            tostring(action.kind or ''),
            tostring(action.name or action.spellName or action.itemName or ''),
            tostring(action.targetId or '')))
end

local function currentScriptFor(moduleName)
    if lib.getWorkerSpec then
        local spec = lib.getWorkerSpec(moduleName)
        if spec and spec.script then return spec.script end
    end
    return 'sidekick-next/sk_' .. tostring(moduleName)
end

local function workerCanActDead(moduleName)
    if lib.getWorkerSpec then
        local spec = lib.getWorkerSpec(moduleName)
        return spec and spec.canActDead == true or false
    end
    return moduleName == 'resurrection'
end

local function mailbox(name, fallback)
    return lib.Mailbox and lib.Mailbox[name] or fallback
end

local function addressFor(mailboxName)
    local address = {
        mailbox = mailboxName,
        script = lib.Scripts.COORDINATOR,
        character = lib.localCharacter(),
    }
    local server = lib.getMyServer()
    if server and server ~= '' then address.server = server end
    return address
end

function M.create(moduleName, legacyPriority)
    ActionExecutor.init()

    local registeredTier = legacyPriority
    if lib.getWorkerSpec then
        local spec = lib.getWorkerSpec(moduleName)
        if spec and spec.tier ~= nil then registeredTier = spec.tier end
    end

    local self = {
        name = moduleName,
        priority = registeredTier,
        script = currentScriptFor(moduleName),
        canActDead = workerCanActDead(moduleName),

        state = nil,
        coordinatorBootId = nil,
        retiredCoordinatorBootIds = {},
        candidateBootId = nil,
        candidateBootSeenAt = 0,
        stateReceivedAt = 0,
        stateInbox = {},
        lastStateTick = nil,
        awaitingResumeState = false,
        resumeStateTick = nil,
        resumeDetectedAt = 0,
        lastCoordinatorCheckAt = 0,
        lastCoordinatorStatus = '',

        workerSessionId = string.format('%s:%s:%s:%d:%d',
            tostring(lib.getMyServer() or ''),
            tostring(lib.getMyName() or ''),
            tostring(moduleName),
            nowMs(),
            math.random(100000, 999999)),
        requestCounter = 0,
        leaseOperationSeq = 0,
        currentRequestId = nil,
        currentAction = nil,
        currentActionKey = nil,
        requestPending = false,
        requestRequestedAt = 0,
        requestLastSentAt = 0,
        lastRequestSendOk = nil,
        lastRequestSendError = nil,
        activeLeaseSnapshot = nil,
        lastLeaseRenewAt = 0,
        finalizing = nil,
        lastFinishedRequestId = nil,
        lastFinishedAtMs = 0,
        lastActionResult = nil,
        intent = { active = false, reason = 'init', updatedAtMs = 0 },
        dirtyEffects = false,
        needsRecovery = false,

        running = true,
        initialized = false,
        warmupUntil = 0,
        dropbox = nil,
        stateDropbox = nil,
        peerActorsEnabled = false,
        peerActors = nil,
        forensicsCastHooked = false,
        settingsRevision = nil,
        unifiedExecutorEnabled = false,
        actionHandlers = nil,

        onTick = nil,
        shouldAct = nil,
        getAction = nil,
        getDiagnosticAction = nil,
        executeAction = nil,
        onLeaseFinalizing = nil,
        onSafetyDrain = nil,
        onRequestWithdrawn = nil,
    }

    function self:hasValidState()
        if type(self.state) ~= 'table' then return false end
        local ttlMs = math.max(1, math.min(
            tonumber(self.state.ttlMs) or lib.Timing.STATE_TTL_MS,
            lib.Timing.STATE_TTL_MS))
        return self.stateReceivedAt > 0
            and (nowMs() - self.stateReceivedAt) <= ttlMs
    end

    function self:isWarmingUp()
        return nowMs() < self.warmupUntil
    end

    function self:canRequestLease()
        if not self:hasValidState() or self:isWarmingUp() then return false end
        local lifecycle = tostring(self.state.lifecycle or 'running')
        local spec = lib.getWorkerSpec and lib.getWorkerSpec(self.name) or nil
        local settings = lib.getSettings and lib.getSettings() or {}
        if spec and spec.enableSetting
            and settings[spec.enableSetting] == false then
            return false
        end
        return lifecycle == 'running'
            and self.state.automationPaused ~= true
    end

    function self:getLease()
        return type(self.state) == 'table' and self.state.lease or nil
    end

    function self:ownsLease(requestId)
        if not self:hasValidState() then return false end
        local lease = self:getLease()
        if type(lease) ~= 'table' then return false end
        if tostring(lease.coordinatorBootId or self.state.coordinatorBootId or '')
            ~= tostring(self.coordinatorBootId or '') then
            return false
        end
        if tostring(lease.holderModule or '') ~= tostring(self.name) then return false end
        if tostring(lease.workerSessionId or '') ~= tostring(self.workerSessionId) then return false end
        local expectedRequest = tostring(requestId or self.currentRequestId or '')
        if expectedRequest == ''
            or tostring(lease.requestId or '') ~= expectedRequest then
            return false
        end
        if self.lastFinishedRequestId
            and tostring(lease.requestId or '') == tostring(self.lastFinishedRequestId) then
            return false
        end
        if tostring(lease.token or '') == '' then return false end
        self.activeLeaseSnapshot = actorSafeCopy(lease)
        return true
    end

    function self:getLeaseAction()
        if not self.currentRequestId or not self.currentAction then return nil end
        if not self:ownsLease(self.currentRequestId) then return nil end
        return self.currentAction
    end

    function self:setIntent(active, _, reason)
        self.intent.active = active == true
        self.intent.reason = tostring(reason or (active and 'ready' or 'idle'))
        self.intent.updatedAtMs = nowMs()
    end

    function self:_sendLeaseMessage(mailboxName, payload)
        if not self.dropbox then return false, 'no_dropbox' end
        payload = payload or {}
        payload.version = tonumber(lib.LEASE_PROTOCOL_VERSION) or 1
        payload.module = self.name
        payload.script = self.script
        payload.ownerName = lib.getMyName()
        payload.ownerServer = lib.getMyServer()
        payload.workerSessionId = self.workerSessionId
        payload.coordinatorBootId = payload.coordinatorBootId
            or self.coordinatorBootId
        payload.sentAtMs = nowMs()
        if tostring(payload.msgType or ''):sub(1, 6) == 'lease:' then
            self.leaseOperationSeq = self.leaseOperationSeq + 1
            payload.operationSeq = self.leaseOperationSeq
        end
        local ok, result = pcall(function()
            return self.dropbox:send(addressFor(mailboxName), payload)
        end)
        if not ok or result == false then
            return false, tostring(result)
        end
        return true
    end

    function self:markDirtyEffects(value)
        self.dirtyEffects = value == true
        self.needsRecovery = self.dirtyEffects
    end

    function self:_sendRequest()
        if not self.currentRequestId then return false end
        local ok, err = self:_sendLeaseMessage(
            mailbox('LEASE_REQUEST', 'sk:lease:request'), {
                msgType = 'lease:request',
                requestId = self.currentRequestId,
                requestTtlMs = REQUEST_TTL_MS,
            })
        self.requestLastSentAt = nowMs()
        self.lastRequestSendOk = ok
        self.lastRequestSendError = ok and nil or err
        if not ok then
            lib.log('warn', self.name, 'Lease request send failed: %s', tostring(err))
        end
        return ok
    end

    function self:requestLease(action)
        if type(action) ~= 'table' or not self:canRequestLease() then return false end
        if self.currentRequestId then return false end
        self.requestCounter = self.requestCounter + 1
        self.currentRequestId = string.format('%s:%d:%d',
            self.workerSessionId, nowMs(), self.requestCounter)
        self.currentAction = action
        self.currentActionKey = actionKey(action)
        self.requestPending = true
        self.requestRequestedAt = nowMs()
        self.finalizing = nil
        local ok = self:_sendRequest()
        if not ok then
            if type(self.onRequestWithdrawn) == 'function' then
                pcall(self.onRequestWithdrawn, self, self.currentAction,
                    'request_send_failed')
            end
            self:_clearLocalRequest()
            return false
        end
        lib.log('debug', self.name, 'Lease requested: %s (%s)',
            tostring(self.currentRequestId), tostring(self.currentActionKey))
        return true
    end

    function self:_clearLocalRequest()
        self.currentRequestId = nil
        self.currentAction = nil
        self.currentActionKey = nil
        self.requestPending = false
        self.requestRequestedAt = 0
        self.requestLastSentAt = 0
        self.activeLeaseSnapshot = nil
        self.lastLeaseRenewAt = 0
        self.finalizing = nil
    end

    function self:withdrawLeaseRequest(reason)
        if not self.currentRequestId then return false end
        if self:ownsLease(self.currentRequestId) then
            return self:finishAction(reason or 'withdrawn')
        end
        local requestId = self.currentRequestId
        local withdrawnAction = self.currentAction
        self:_sendLeaseMessage(mailbox('LEASE_WITHDRAW', 'sk:lease:withdraw'), {
            msgType = 'lease:withdraw',
            requestId = requestId,
        })
        if type(self.onRequestWithdrawn) == 'function' then
            pcall(self.onRequestWithdrawn, self, withdrawnAction,
                tostring(reason or 'withdrawn'))
        end
        self.lastFinishedRequestId = requestId
        self.lastFinishedAtMs = nowMs()
        self:_clearLocalRequest()
        return true
    end

    function self:renewLease(force)
        if not self:ownsLease(self.currentRequestId) then return false end
        local lease = self:getLease()
        if tostring(lease.status or 'active') ~= 'active' then return false end
        if not force and (nowMs() - self.lastLeaseRenewAt) < LEASE_RENEW_MS then
            return true
        end
        local ok = self:_sendLeaseMessage(mailbox('LEASE_RENEW', 'sk:lease:renew'), {
            msgType = 'lease:renew',
            coordinatorBootId = self.coordinatorBootId,
            requestId = self.currentRequestId,
            token = lease.token,
        })
        if ok then self.lastLeaseRenewAt = nowMs() end
        return ok
    end

    function self:_runFinalizer()
        local pending = self.finalizing
        if not pending then return true end
        local callback = self.onLeaseFinalizing or self.onSafetyDrain
        if type(callback) == 'function' then
            local ok, done, detail = pcall(callback, self,
                self.currentAction, pending.reason, pending.result)
            if not ok then
                lib.log('error', self.name, 'Lease finalizer failed: %s', tostring(done))
                pending.reason = 'finalizer_error:' .. tostring(done)
            elseif done == false then
                pending.detail = detail
                return false
            end
        end
        return true
    end

    function self:_sendRelease()
        local pending = self.finalizing
        if not pending then return false end
        local lease = self:getLease() or self.activeLeaseSnapshot or {}
        local requestId = self.currentRequestId
        self:_sendLeaseMessage(mailbox('LEASE_RELEASE', 'sk:lease:release'), {
            msgType = 'lease:release',
            coordinatorBootId = tostring(lease.coordinatorBootId
                or self.coordinatorBootId or ''),
            requestId = requestId,
            token = tostring(lease.token or ''),
        })
        self.lastFinishedRequestId = requestId
        self.lastFinishedAtMs = nowMs()
        self.lastActionResult = pending.result or {
            phase = pending.reason == 'preempted' and 'preempted' or 'resolved',
            reason = pending.reason,
        }
        lib.log('debug', self.name, 'Lease released: %s (%s)',
            tostring(requestId), tostring(pending.reason))
        self:_clearLocalRequest()
        return true
    end

    function self:finishAction(result)
        if not self.currentRequestId then return false end
        local normalized
        if type(result) == 'table' then
            normalized = result
        else
            normalized = {
                phase = tostring(result or 'resolved'),
                reason = tostring(result or 'completed'),
            }
        end
        self.finalizing = self.finalizing or {
            reason = tostring(normalized.reason or normalized.phase or 'completed'),
            result = normalized,
        }
        if not self:_runFinalizer() then return false end
        return self:_sendRelease()
    end

    function self:_cancelAndFinalize(reason, phase)
        if self.currentRequestId and self:ownsLease(self.currentRequestId) then
            if self.unifiedExecutorEnabled and ActionExecutor.hasActiveJob() then
                ActionExecutor.cancel(reason)
                ActionExecutor.consumeResult()
            end
            self:finishAction({ phase = phase or 'cancelled', reason = reason })
        elseif self.currentRequestId and self.activeLeaseSnapshot == nil then
            self:withdrawLeaseRequest(reason)
        elseif self.currentRequestId then
            -- A cached lease is diagnostic evidence, never authority. Preserve
            -- dirty state and wait for the coordinator's fenced recovery lease
            -- before issuing stop-cast/nav/key-release cleanup mutations.
            self:markDirtyEffects(true)
            self.intent.reason = 'recovery_required:' .. tostring(reason)
        end
    end

    function self:enableUnifiedExecutor(handlers)
        self.unifiedExecutorEnabled = true
        self.actionHandlers = handlers or {}
    end

    function self:cancelUnifiedAction(reason)
        if not self:ownsLease(self.currentRequestId) then return false end
        if self.unifiedExecutorEnabled and ActionExecutor.hasActiveJob() then
            ActionExecutor.cancel(reason or 'cancelled')
            return true
        end
        return false
    end

    function self:driveUnifiedAction()
        if not self.unifiedExecutorEnabled or not self:ownsLease() then return false end
        if not ActionExecutor.hasJob() then
            local action = self:getLeaseAction()
            if not action then
                self:finishAction({ phase = 'failed', reason = 'executor:no_action' })
                return true
            end
            action.requestId = self.currentRequestId
            local accepted, reason = ActionExecutor.submit(action, {
                handlers = self.actionHandlers,
                context = self,
            })
            if not accepted then
                self:finishAction({
                    phase = 'failed',
                    reason = 'executor:' .. tostring(reason or 'submit_failed'),
                })
                return true
            end
        end
        self:renewLease()
        ActionExecutor.tick({
            ownsAction = function() return self:ownsLease() end,
        })
        local result = ActionExecutor.consumeResult()
        if result then
            local phaseMap = {
                completed = 'resolved',
                failed = 'failed',
                cancelled = 'cancelled',
            }
            result.phase = phaseMap[result.phase] or result.phase
            self.lastActionResult = result
            if result.phase == 'resolved' then
                ActionCounters.bump('done:' .. tostring(result.kind or 'action'))
            elseif result.phase == 'failed' then
                ActionCounters.bump('failed')
            end
            self:finishAction(result)
        end
        return true
    end

    function self:sendHeartbeat()
        if not self.dropbox then return end
        local inGame = lib.isInGame()
        self:_sendLeaseMessage(mailbox('HEARTBEAT', 'sk:hb'), {
            msgType = 'heartbeat',
            ready = inGame and self:hasValidState() and not self.awaitingResumeState,
            suspended = not inGame,
            requestId = self.currentRequestId,
            requestPending = self.requestPending == true,
            dirtyEffects = self.dirtyEffects == true,
            needsRecovery = self.needsRecovery == true,
            counters = ActionCounters.snapshot(),
        })
    end

    function self:_driveRecoveryLease()
        local lease = self:getLease()
        if type(lease) ~= 'table'
            or tostring(lease.status or '') ~= 'recovering'
            or tostring(lease.holderModule or '') ~= tostring(self.name)
            or tostring(lease.workerSessionId or '') ~= tostring(self.workerSessionId) then
            return false
        end
        local requestId = tostring(lease.requestId or '')
        local token = tostring(lease.token or '')
        if requestId == '' or token == '' then return false end

        self.currentRequestId = requestId
        self.currentAction = self.currentAction or {
            kind = 'recovery_cleanup',
            skipBoundaryTarget = true,
            breaksInvis = false,
            idempotencyKey = 'recovery:' .. requestId,
        }
        self.currentActionKey = actionKey(self.currentAction)
        self.requestPending = false
        self.activeLeaseSnapshot = actorSafeCopy(lease)

        if self.unifiedExecutorEnabled and ActionExecutor.hasActiveJob() then
            ActionExecutor.cancel('orphan_recovery')
            ActionExecutor.consumeResult()
        end

        local callback = self.onSafetyDrain or self.onLeaseFinalizing
        if type(callback) == 'function' then
            local ok, done, detail = pcall(callback, self, self.currentAction,
                'orphan_recovery', { phase = 'cancelled', reason = 'orphan_recovery' })
            if not ok then
                lib.log('error', self.name, 'Recovery drain failed: %s', tostring(done))
                return true
            end
            if done == false then
                self.intent.reason = tostring(detail or 'recovery_draining')
                return true
            end
        end

        self:_sendLeaseMessage(mailbox('LEASE_RECOVERED', 'sk:lease:recovered'), {
            msgType = 'lease:recovered',
            requestId = requestId,
            token = token,
        })
        self.dirtyEffects = false
        self.needsRecovery = false
        self.lastFinishedRequestId = requestId
        self.lastFinishedAtMs = nowMs()
        self:_clearLocalRequest()
        return true
    end

    function self:_enqueueState(message)
        local ok, content = pcall(function() return message() end)
        if not ok or type(content) ~= 'table' then return end
        local copied = actorSafeCopy(content)
        if not copied then return end
        local sender = message.sender or {}
        local entry = {
            content = copied,
            sender = {
                character = tostring(sender.character or ''),
                server = tostring(sender.server or ''),
                script = tostring(sender.script or ''),
                mailbox = tostring(sender.mailbox or ''),
            },
        }
        if #self.stateInbox >= MAX_STATE_INBOX then table.remove(self.stateInbox, 1) end
        self.stateInbox[#self.stateInbox + 1] = entry
    end

    function self:onStateReceived(entry)
        local content = type(entry) == 'table' and entry.content or nil
        local sender = type(entry) == 'table' and entry.sender or nil
        if type(content) ~= 'table' then return end
        if type(sender) ~= 'table'
            or tostring(sender.character or '') ~= tostring(lib.getMyName() or '')
            or tostring(sender.server or '') ~= tostring(lib.getMyServer() or '')
            or tostring(sender.script or '') ~= tostring(lib.Scripts.COORDINATOR or '') then
            return
        end
        local logicalMailbox = tostring(sender.mailbox or ''):lower():match('([^:]+)$')
        if logicalMailbox ~= 'coordinator' then
            return
        end
        if tonumber(content.version) ~= tonumber(lib.LEASE_PROTOCOL_VERSION) then return end
        if tostring(content.ownerName or '') ~= tostring(lib.getMyName() or '') then return end
        if tostring(content.ownerServer or '') ~= tostring(lib.getMyServer() or '') then return end

        local incomingBootId = tostring(content.coordinatorBootId or '')
        if incomingBootId == '' or self.retiredCoordinatorBootIds[incomingBootId] then return end
        if self.coordinatorBootId and incomingBootId ~= self.coordinatorBootId then
            if self.candidateBootId ~= incomingBootId
                or (nowMs() - self.candidateBootSeenAt) > 2000 then
                self.candidateBootId = incomingBootId
                self.candidateBootSeenAt = nowMs()
                return
            end
            self.retiredCoordinatorBootIds[self.coordinatorBootId] = true
            if self.currentRequestId or self.activeLeaseSnapshot then
                self:markDirtyEffects(true)
            end
            self.state = nil
            self.lastStateTick = nil
        end
        self.coordinatorBootId = incomingBootId
        self.candidateBootId = nil

        local incomingTick = tonumber(content.tickId)
        if not incomingTick or incomingTick <= 0 then return end
        if self.lastStateTick and incomingTick <= self.lastStateTick then return end
        self.lastStateTick = incomingTick
        self.state = content
        self.stateReceivedAt = nowMs()
        if self.peerActors and self.peerActors.setTeamContext then
            pcall(self.peerActors.setTeamContext, content.team)
        end

        if self.awaitingResumeState
            and (not self.resumeStateTick
                or (incomingTick and incomingTick > self.resumeStateTick)) then
            self.awaitingResumeState = false
            self.resumeStateTick = nil
            self.resumeDetectedAt = 0
        end

        if not self.initialized then
            self.warmupUntil = nowMs() + lib.Timing.WARMUP_MS
            self.initialized = true
            lib.log('info', self.name, 'First coordinator state; warming for %dms',
                lib.Timing.WARMUP_MS)
        end

        if self:ownsLease(self.currentRequestId) then
            self.requestPending = false
        end
    end

    function self:drainStateInbox()
        if #self.stateInbox == 0 then return end
        local inbox = self.stateInbox
        self.stateInbox = {}
        for _, entry in ipairs(inbox) do self:onStateReceived(entry) end
    end

    function self:enablePeerActors()
        self.peerActorsEnabled = true
    end

    function self:sendToLocalUi(msgId, payload)
        if not self.dropbox or not msgId or msgId == '' then return false end
        local safePayload = actorSafeCopy(payload or {}) or {}
        safePayload.id = msgId
        safePayload.from = safePayload.from or lib.getMyName()
        safePayload.server = safePayload.server or lib.getMyServer()
        local scripts = type(lib.Scripts.UI) == 'table'
            and lib.Scripts.UI or { lib.Scripts.UI }
        local sent = false
        for _, scriptName in ipairs(scripts) do
            local ok = pcall(self.dropbox.send, self.dropbox, {
                mailbox = 'sidekick',
                script = scriptName,
                server = lib.getMyServer(),
                character = lib.localCharacter(),
            }, safePayload)
            sent = sent or ok
        end
        return sent
    end

    function self:_reloadSettingsIfNeeded()
        local revision = tonumber(self.state and self.state.settingsRevision)
        if revision and revision ~= self.settingsRevision then
            lib.refreshSettings(revision)
            self.settingsRevision = revision
            if self.onSettingsReload then pcall(self.onSettingsReload, self, revision) end
        end
        local desired = self.state and self.state.humanizeOverride
        if desired ~= nil and desired ~= self.appliedHumanizeOverride then
            local humanize = package.loaded['sidekick-next.humanize']
            if humanize and humanize.setOverride then
                pcall(humanize.setOverride, desired ~= 'auto' and desired or nil)
                self.appliedHumanizeOverride = desired
            end
        end
    end

    function self:_refreshPendingRequest()
        if not self.currentRequestId or self:ownsLease(self.currentRequestId) then return end
        if not self:canRequestLease() then
            self:withdrawLeaseRequest('worker_disabled_or_paused')
            return
        end
        local stillNeeded = self.shouldAct and self.shouldAct(self) == true
        if not stillNeeded then
            self:withdrawLeaseRequest('intent_cleared')
            return
        end
        local nextAction = self.getAction and self.getAction(self) or nil
        if not nextAction then
            self:withdrawLeaseRequest('action_cleared')
            return
        end
        local nextKey = actionKey(nextAction)
        if nextKey ~= self.currentActionKey then
            self:withdrawLeaseRequest('action_changed')
            self:requestLease(nextAction)
            return
        end
        self.currentAction = nextAction
        if (nowMs() - self.requestLastSentAt) >= REQUEST_REFRESH_MS then
            self:_sendRequest()
        end
    end

    function self:tick()
        self:drainStateInbox()

        if not lib.isInGame() then
            self:_cancelAndFinalize('not_ingame', 'cancelled')
            self:setIntent(false, nil, 'not_ingame')
            return
        end

        if self.awaitingResumeState then
            if (nowMs() - self.resumeDetectedAt) <= lib.Timing.COORDINATOR_ABSENCE_MS then
                self:setIntent(self.currentRequestId ~= nil, nil, 'scheduler_resume_wait')
                return
            end
            self.awaitingResumeState = false
            self.resumeStateTick = nil
        end

        if not self:hasValidState() then
            self:_cancelAndFinalize('state_stale', 'cancelled')
            self:setIntent(false, nil, 'state_stale')
            return
        end

        self:_reloadSettingsIfNeeded()

        if self:_driveRecoveryLease() then return end

        local lifecycle = tostring(self.state.lifecycle or 'running')
        if self.state.automationPaused == true
            or lifecycle == 'pausing' or lifecycle == 'paused'
            or lifecycle == 'faulted' then
            self:_cancelAndFinalize('automation_' .. lifecycle, 'cancelled')
            self:setIntent(false, nil, 'automation_' .. lifecycle)
            return
        end

        if lib.isSelfDeadOrHovering and lib.isSelfDeadOrHovering()
            and not self.canActDead then
            self:_cancelAndFinalize('self_dead', 'cancelled')
            self:setIntent(false, nil, 'self_dead')
            return
        end

        local incapacitated, incapReason = lib.isIncapacitated()
        if incapacitated then
            local reason = 'incapacitated:' .. tostring(incapReason or 'unknown')
            self:_cancelAndFinalize(reason, 'cancelled')
            self:setIntent(false, nil, reason)
            return
        end

        if self:isWarmingUp() then return end

        if self.onTick then
            local ok, err = pcall(self.onTick, self)
            if not ok then
                lib.log('error', self.name, 'Sensor tick failed: %s', tostring(err))
            end
        end

        if self:ownsLease(self.currentRequestId) then
            local lease = self:getLease()
            if tostring(lease.status or 'active') == 'revoking' then
                self:cancelUnifiedAction(tostring(lease.revokeReason or 'preempted'))
                self:finishAction({
                    phase = 'preempted',
                    reason = tostring(lease.revokeReason or 'preempted'),
                })
                return
            end
            self:renewLease()
            if self.finalizing then
                self:finishAction(self.finalizing.result)
                return
            end
            local admitted, boundaryReason = ActionBoundary.require(
                self, self.currentAction or {}, {
                    skipTarget = self.currentAction
                        and self.currentAction.skipBoundaryTarget == true,
                })
            if not admitted then
                self:finishAction({
                    phase = 'cancelled',
                    reason = boundaryReason or 'boundary_rejected',
                })
                return
            end
            if self.unifiedExecutorEnabled then
                self:driveUnifiedAction()
            elseif self.executeAction then
                local ok, terminal, reason = pcall(self.executeAction, self)
                if not ok then
                    self:finishAction({
                        phase = 'failed',
                        reason = 'execute_error:' .. tostring(terminal),
                    })
                elseif terminal == true or reason == 'completed' then
                    self:finishAction({
                        phase = terminal == true and 'resolved' or 'failed',
                        reason = tostring(reason or 'completed'),
                    })
                end
            else
                self:finishAction({ phase = 'failed', reason = 'no_executor' })
            end
            return
        end

        if self.currentRequestId then
            self:_refreshPendingRequest()
            return
        end

        if self:canRequestLease()
            and self.shouldAct and self.shouldAct(self) == true
            and self.getAction then
            local action = self.getAction(self)
            if action then self:requestLease(action) end
        end
    end

    function self:initialize()
        lib.log('info', self.name, 'Initializing worker session %s',
            tostring(self.workerSessionId))
        self.dropbox = actors.register(self.name, function(message)
            self:_enqueueState(message)
        end)
        self.stateDropbox = actors.register(mailbox('STATE', 'sk:state'), function(message)
            self:_enqueueState(message)
        end)

        if not self.forensicsCastHooked then
            local ok, SpellEngine = pcall(require, 'sidekick-next.utils.spell_engine')
            if ok and SpellEngine and SpellEngine.addCastCompleteListener then
                SpellEngine.addCastCompleteListener(function(castData, result)
                    local settings = lib.getSettings()
                    if settings and settings.DeathForensicsEnabled == false then return end
                    castData = castData or {}
                    self:sendToLocalUi('forensics:cast', {
                        castData = {
                            spellName = tostring(castData.spellName or ''),
                            spellCategory = tostring(castData.spellCategory or ''),
                            targetId = tonumber(castData.targetId) or 0,
                        },
                        result = tonumber(result) or result,
                    })
                end)
                self.forensicsCastHooked = true
            end
        end

        if self.peerActorsEnabled then
            local ok, coordinator = pcall(require, 'sidekick-next.utils.actors_coordinator')
            if ok and coordinator then
                coordinator.init()
                self.peerActors = coordinator
                if coordinator.setTeamContext then
                    pcall(coordinator.setTeamContext,
                        self.state and self.state.team or nil)
                end
            end
        end
    end

    function self:isCoordinatorAbsent()
        if not lib.isInGame() or not self.initialized or self.stateReceivedAt == 0 then
            return false
        end
        if (nowMs() - self.stateReceivedAt) <= lib.Timing.COORDINATOR_ABSENCE_MS then
            return false
        end
        if (nowMs() - self.lastCoordinatorCheckAt) < 1000 then
            return self.lastCoordinatorStatus == 'EXITED'
        end
        self.lastCoordinatorCheckAt = nowMs()
        self.lastCoordinatorStatus = lib.getLuaScriptStatus(lib.Scripts.COORDINATOR)
        return self.lastCoordinatorStatus == 'EXITED'
    end

    function self:run(tickDelayMs)
        tickDelayMs = tickDelayMs or 50
        self:initialize()
        local lastHeartbeat = 0
        local wasInGame = lib.isInGame()
        local lastLoopAt = nowMs()
        local lastParentCheckAt = nowMs()
        local parentMisses = 0

        while self.running do
            local loopAt = nowMs()
            local loopGap = loopAt - lastLoopAt
            lastLoopAt = loopAt
            if self.state and loopGap > lib.Timing.STATE_TTL_MS then
                self.awaitingResumeState = true
                self.resumeStateTick = tonumber(self.state.tickId)
                self.resumeDetectedAt = loopAt
                if ActionExecutor.rebaseTimers then ActionExecutor.rebaseTimers(loopGap) end
                if self.onSchedulerResume then
                    pcall(self.onSchedulerResume, self, loopGap)
                end
            end

            if self.peerActors and self.peerActors.tick then self.peerActors.tick() end
            if mq.doevents then pcall(mq.doevents) end

            if not lib.isInGame() then
                lastParentCheckAt = loopAt
                parentMisses = 0
            elseif (loopAt - lastParentCheckAt) >= 5000 then
                lastParentCheckAt = loopAt
                if lib.isUiRunning() then
                    parentMisses = 0
                else
                    parentMisses = parentMisses + 1
                    if parentMisses >= 2 then
                        self:stop()
                        break
                    end
                end
            end

            self:tick()

            local inGame = lib.isInGame()
            if inGame and not wasInGame then self.stateReceivedAt = nowMs() end
            wasInGame = inGame
            if (nowMs() - lastHeartbeat) >= lib.Timing.MODULE_HEARTBEAT_MS then
                self:sendHeartbeat()
                lastHeartbeat = nowMs()
            end

            if self:isCoordinatorAbsent() then self:stop() end
            mq.delay(tickDelayMs)
        end
        lib.log('info', self.name, 'Worker stopped')
    end

    function self:stop()
        self:_cancelAndFinalize('shutdown', 'cancelled')
        local drainDeadline = nowMs() + 1000
        while self.finalizing and self.currentRequestId and nowMs() < drainDeadline do
            self:finishAction(self.finalizing.result)
            if self.finalizing then mq.delay(50) end
        end
        if self.currentRequestId and not self.activeLeaseSnapshot then
            self:withdrawLeaseRequest('shutdown')
        end
        self.running = false
        if self.dropbox and self.dropbox.unregister then
            pcall(function() self.dropbox:unregister() end)
        end
        if self.stateDropbox and self.stateDropbox.unregister then
            pcall(function() self.stateDropbox:unregister() end)
        end
    end

    return self
end

return M
