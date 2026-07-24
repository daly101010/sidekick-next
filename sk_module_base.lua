-- F:/lua/sidekick-next/sk_module_base.lua
-- Base class for SideKick priority modules
-- Handles state reception, claim requests, and execution guards

local mq = require('mq')
local actors = require('actors')
local lib = require('sidekick-next.sk_lib')
local ActionExecutor = require('sidekick-next.utils.action_executor')
local ActionCounters = require('sidekick-next.utils.action_counters')

local M = {}

local debugLogToFile = require('sidekick-next.utils.debug_log').moduleTagged('sk_module_base', 'SK_MODULE_BASE')

-- Action tables are mutable runtime objects and may accumulate values the
-- Actors post office cannot serialize. Copy only supported scalar/table data.
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
        if keyType == 'string' or (keyType == 'number' and key >= 0 and key % 1 == 0) then
            local safeChild = actorSafeCopy(child, seen)
            if safeChild ~= nil then out[key] = safeChild end
        end
    end
    seen[value] = nil
    return out
end

--- Create a new module instance
-- @param moduleName string Unique module name
-- @param priority number Module's priority tier
-- @return table Module instance
function M.create(moduleName, priority)
    ActionExecutor.init()
    local self = {
        name = moduleName,
        priority = priority,

        -- State from Coordinator
        state = nil,
        coordinatorBootId = nil,
        retiredCoordinatorBootIds = {},
        stateReceivedAt = 0,
        awaitingResumeState = false,
        resumeStateTick = nil,
        resumeDetectedAt = 0,
        lastCoordinatorCheckAt = 0,
        lastCoordinatorStatus = '',

        -- Claim tracking
        claimCounter = 0,
        currentClaimId = nil,
        currentClaimType = nil,
        claimPending = false,
        claimRequestedAt = 0,
        claimEpochAtRequest = nil,
        lastClaimSendOk = nil,
        lastClaimSendError = nil,
        lastClaimSendAt = 0,
        lastReleasedClaimId = nil,
        lastReleasedAtMs = 0,
        lastNeedSentAt = 0,
        lastNeedValue = nil,
        lastNeedReason = nil,

        -- Running flag
        running = true,
        initialized = false,
        warmupUntil = 0,

        -- Actor dropbox
        dropbox = nil,
        stateDropbox = nil,
        peerActorsEnabled = false,
        peerActors = nil,
        forensicsCastHooked = false,
        settingsRevision = nil,

        -- Unified action executor (opt-in during compatibility migration)
        unifiedExecutorEnabled = false,
        actionHandlers = nil,
        lastActionResult = nil,

        -- Callbacks (override these)
        onTick = nil,          -- Called each tick when active
        shouldAct = nil,       -- Returns true if module needs to act
        getAction = nil,       -- Returns action details for claim
        getDiagnosticAction = nil, -- Returns side-effect-free pending action status
        executeAction = nil,   -- Executes the action after claim granted
    }

    ---------------------------------------------------------------------------
    -- State Management
    ---------------------------------------------------------------------------

    function self:hasValidState()
        if not self.state then return false end
        -- Coordinator and worker run in separate Lua processes. Treat the
        -- worker-local receipt timestamp as authoritative so clock-domain skew
        -- or transport latency cannot make a newly delivered snapshot stale.
        local ttlMs = tonumber(self.state.ttlMs) or lib.Timing.STATE_TTL_MS
        return self.stateReceivedAt > 0
            and (lib.getTimeMs() - self.stateReceivedAt) <= ttlMs
    end

    function self:isMyPriority()
        if not self:hasValidState() then return false end
        -- Better-or-equal tier may act (lower number = higher priority).
        -- Exact-match gating forced every higher-priority action — heals,
        -- tank engage after a kill — to wait a full need -> scheduler
        -- priority-flip -> broadcast round trip (~0.5-2s wall under turbo
        -- slicing) before its claim could even be SENT. Ownership arbitration
        -- in the coordinator (canGrantResource) still enforces ordering.
        return self.priority <= self.state.activePriority
            or self.priority == lib.Priority.EMERGENCY
    end

    function self:isWarmingUp()
        return lib.getTimeMs() < self.warmupUntil
    end

    ---------------------------------------------------------------------------
    -- Ownership Checks
    ---------------------------------------------------------------------------

    function self:ownsCast()
        if not self:hasValidState() then return false end
        local owner = self.state.castOwner
        if not owner then return false end
        if owner.module ~= self.name then return false end
        -- Actor state is asynchronous. Never resurrect a claim we have already
        -- released merely because one older coordinator snapshot is still in
        -- self.state.
        if owner.claimId == self.lastReleasedClaimId then return false end

        -- If we own by module name but claimId doesn't match, adopt the coordinator's claimId
        -- This handles the case where we sent multiple claims and an earlier one was granted
        if owner.claimId ~= self.currentClaimId then
            debugLogToFile(self.name, 'ownsCast: Adopting coordinator claimId (owner=%s, was=%s)',
                tostring(owner.claimId), tostring(self.currentClaimId))
            self.currentClaimId = owner.claimId
            self.claimPending = false
            self.claimEpochAtRequest = nil
        end

        -- The coordinator includes this module as owner in the state broadcast,
        -- which means ownership is still valid. Module name match is authoritative.
        return true
    end

    function self:ownsTarget()
        if not self:hasValidState() then return false end
        local owner = self.state.targetOwner
        if not owner then return false end
        if owner.module ~= self.name then return false end
        if owner.claimId == self.lastReleasedClaimId then return false end

        -- If we own by module name but claimId doesn't match, adopt the coordinator's claimId
        if owner.claimId ~= self.currentClaimId then
            debugLogToFile(self.name, 'ownsTarget: Adopting coordinator claimId (owner=%s, was=%s)',
                tostring(owner.claimId), tostring(self.currentClaimId))
            self.currentClaimId = owner.claimId
            self.claimPending = false
            self.claimEpochAtRequest = nil
        end

        -- The coordinator includes this module as owner in the state broadcast,
        -- which means ownership is still valid. Module name match is authoritative.
        return true
    end

    function self:ownsAction()
        return self:ownsCast() and self:ownsTarget()
    end

    function self:ownsClaim()
        local claimType = self.currentClaimType or lib.ClaimType.ACTION
        if claimType == lib.ClaimType.CAST then
            return self:ownsCast()
        elseif claimType == lib.ClaimType.TARGET then
            return self:ownsTarget()
        end
        return self:ownsAction()
    end

    ---------------------------------------------------------------------------
    -- Claim Management
    ---------------------------------------------------------------------------

    function self:requestClaim(action)
        if not self:hasValidState() then
            lib.log('debug', self.name, 'Cannot claim: no valid state')
            return false
        end

        if self.claimPending then
            -- Check for timeout
            local elapsed = lib.getTimeMs() - self.claimRequestedAt
            if elapsed < 200 then
                return false -- Still waiting
            end
            -- Timeout, reset
            self.claimPending = false
        end

        self.claimCounter = self.claimCounter + 1
        self.currentClaimId = lib.generateClaimId(self.name, self.claimCounter)
        self.currentClaimType = action.type or lib.ClaimType.ACTION

        local wants = action.wants
        if type(wants) ~= 'table' then
            if self.currentClaimType == lib.ClaimType.CAST then
                wants = { 'cast' }
            elseif self.currentClaimType == lib.ClaimType.TARGET then
                wants = { 'target' }
            else
                wants = { 'target', 'cast' }
            end
        end

        local claim = {
            msgType = 'claim',
            type = self.currentClaimType,
            wants = wants,
            module = self.name,
            ownerName = lib.getMyName(),
            ownerServer = lib.getMyServer(),
            priority = self.priority,
            claimId = self.currentClaimId,
            epochSeen = self.state.epoch,
            -- Pre-cast workflows such as memorization or navigation can ask
            -- for a longer bounded lease. The coordinator still revokes it on
            -- heartbeat loss, incapacitation, or explicit release.
            ttlMs = tonumber(action.claimTtlMs) or lib.Timing.CLAIM_DEFAULT_TTL_MS,
            expectsCastStart = action.expectsCastStart ~= false
                and action.kind == lib.ActionKind.CAST_SPELL,
            castStartTimeoutMs = tonumber(action.castStartTimeoutMs)
                or lib.Timing.CLAIM_CAST_START_MS,
            reason = action.reason or 'action',
            action = actorSafeCopy(action),
        }

        self.claimPending = true
        self.claimRequestedAt = lib.getTimeMs()
        self.claimEpochAtRequest = self.state.epoch

        local ok, result = pcall(function()
            return self.dropbox:send(
                { mailbox = lib.Mailbox.CLAIM, script = lib.Scripts.COORDINATOR, character = lib.localCharacter() }, claim)
        end)
        self.lastClaimSendAt = lib.getTimeMs()
        self.lastClaimSendOk = ok and result ~= false
        self.lastClaimSendError = self.lastClaimSendOk and nil or tostring(result)
        if not self.lastClaimSendOk then
            self.claimPending = false
            self.claimEpochAtRequest = nil
            lib.log('warn', self.name, 'Claim send failed: %s', tostring(self.lastClaimSendError))
            return false
        end

        lib.log('debug', self.name, 'Claim requested: %s (epoch=%d)', self.currentClaimId, self.state.epoch)
        return true
    end

    function self:releaseClaim(reason)
        if not self.currentClaimId then return end

        local releasedClaimId = self.currentClaimId

        local release = {
            msgType = 'release',
            type = self.currentClaimType or lib.ClaimType.ACTION,
            module = self.name,
            ownerName = lib.getMyName(),
            ownerServer = lib.getMyServer(),
            claimId = self.currentClaimId,
            epochSeen = self.state and self.state.epoch or 0,
            reason = reason or 'completed',
        }

        pcall(function()
            self.dropbox:send({ mailbox = lib.Mailbox.RELEASE, script = lib.Scripts.COORDINATOR, character = lib.localCharacter() }, release)
        end)

        lib.log('debug', self.name, 'Release sent: %s (%s)', self.currentClaimId, reason)
        self.lastReleasedClaimId = releasedClaimId
        self.lastReleasedAtMs = lib.getTimeMs()
        self.currentClaimId = nil
        self.currentClaimType = nil
        self.claimPending = false
        self.claimEpochAtRequest = nil
        if self.onClaimReleased then
            pcall(self.onClaimReleased, self, reason or 'completed')
        end
    end

    function self:requestInterrupt(reason)
        if not self:hasValidState() then return end

        local interrupt = {
            msgType = 'interrupt',
            requestingModule = self.name,
            ownerName = lib.getMyName(),
            ownerServer = lib.getMyServer(),
            requestingPriority = self.priority,
            reason = reason or 'preempt',
        }

        pcall(function()
            self.dropbox:send({ mailbox = lib.Mailbox.INTERRUPT, script = lib.Scripts.COORDINATOR, character = lib.localCharacter() }, interrupt)
        end)

        lib.log('debug', self.name, 'Interrupt requested: %s', reason)
    end

    function self:sendHeartbeat()
        debugLogToFile(self.name, 'Sending heartbeat to %s', lib.Scripts.COORDINATOR)
        local action = self.unifiedExecutorEnabled and ActionExecutor.getStatus() or nil
        if (not action or action.active ~= true) and self.getDiagnosticAction then
            local ok, diagnostic = pcall(self.getDiagnosticAction, self)
            if ok and type(diagnostic) == 'table' then action = diagnostic end
        end
        local inGame = lib.isInGame()
        local stateReady = inGame and self:hasValidState() and not self.awaitingResumeState
        pcall(function()
            self.dropbox:send({ mailbox = lib.Mailbox.HEARTBEAT, script = lib.Scripts.COORDINATOR, character = lib.localCharacter() }, {
                msgType = 'heartbeat',
                module = self.name,
                ownerName = lib.getMyName(),
                ownerServer = lib.getMyServer(),
                sentAtMs = lib.getTimeMs(),
                ready = stateReady,
                suspended = not inGame,
                action = action,
                counters = ActionCounters.snapshot(),
            })
        end)
    end

    ---------------------------------------------------------------------------
    -- Unified Action Executor
    ---------------------------------------------------------------------------

    function self:enableUnifiedExecutor(handlers)
        self.unifiedExecutorEnabled = true
        self.actionHandlers = handlers or {}
    end

    function self:getClaimAction()
        local claimType = self.currentClaimType or lib.ClaimType.ACTION
        if claimType == lib.ClaimType.TARGET then
            return self.state and self.state.targetOwner and self.state.targetOwner.action
        end
        return self.state and self.state.castOwner and self.state.castOwner.action
    end

    function self:cancelUnifiedAction(reason)
        if self.unifiedExecutorEnabled and ActionExecutor.hasActiveJob() then
            ActionExecutor.cancel(reason or 'cancelled')
        end
    end

    function self:driveUnifiedAction()
        if not self.unifiedExecutorEnabled then return false end

        if not ActionExecutor.hasJob() then
            local action = self:getClaimAction()
            if not action then
                self:releaseClaim('executor:no_action')
                return true
            end
            action.claimId = action.claimId or self.currentClaimId
            local accepted, reason = ActionExecutor.submit(action, {
                handlers = self.actionHandlers,
                context = self,
            })
            if not accepted then
                self.lastActionResult = { phase = 'failed', reason = reason or 'submit_failed' }
                self:releaseClaim('executor:' .. tostring(reason or 'submit_failed'))
                return true
            end
        end

        ActionExecutor.tick({
            -- Every unified action owns the cast resource. Target ownership
            -- may be released while an already-started cast is deliberately
            -- allowed to finish, so the executor follows the cast lease after
            -- its initial full-claim admission check.
            ownsAction = function() return self:ownsCast() end,
        })
        local result = ActionExecutor.consumeResult()
        if result then
            self.lastActionResult = result
            -- Activity counters: every unified action funnels through here,
            -- so one bump site covers heals, nukes, buffs, taunts, items...
            if result.phase == 'completed' then
                ActionCounters.bump('done:' .. tostring(result.kind or 'action'))
            elseif result.phase == 'failed' then
                ActionCounters.bump('failed')
            end
            local reason = string.format('executor:%s:%s',
                tostring(result.phase or 'unknown'), tostring(result.reason or 'unknown'))
            lib.log(result.phase == 'completed' and 'debug' or 'warn', self.name,
                'Action %s: kind=%s name=%s reason=%s elapsed=%dms',
                tostring(result.phase), tostring(result.kind), tostring(result.name),
                tostring(result.reason), tonumber(result.elapsedMs) or 0)
            self:releaseClaim(reason)
        end
        return true
    end

    function self:sendNeed(needsAction, ttlMs, reason)
        if not self.dropbox then return end
        local now = lib.getTimeMs()
        local value = needsAction == true
        -- Always send if reason changed (diagnostic updates matter)
        local reasonChanged = reason ~= self.lastNeedReason
        -- Unchanged needs are pure keep-alives. Refresh at 400ms against a
        -- 1000ms TTL instead of 100ms against 250ms: the old cadence cost
        -- ~110 need sends/sec fleet-wide (~1ms apiece sender-side) and made
        -- `drain` the coordinator's top chronic offender. Value/reason
        -- CHANGES still send immediately, so engagement latency is unchanged.
        if not reasonChanged and self.lastNeedValue == value and (now - (self.lastNeedSentAt or 0)) < 400 then
            return
        end
        self.lastNeedValue = value
        self.lastNeedSentAt = now
        self.lastNeedReason = reason
        pcall(function()
            self.dropbox:send({ mailbox = lib.Mailbox.NEED, script = lib.Scripts.COORDINATOR, character = lib.localCharacter() }, {
                msgType = 'need',
                module = self.name,
                ownerName = lib.getMyName(),
                ownerServer = lib.getMyServer(),
                priority = self.priority,
                needsAction = value,
                -- Default TTL must stay comfortably above the 400ms
                -- keep-alive refresh or steady needs flap expired/valid.
                ttlMs = ttlMs or 1000,
                reason = reason,
            })
        end)
    end

    ---------------------------------------------------------------------------
    -- Message Handling
    ---------------------------------------------------------------------------

    function self:onStateReceived(content)
        if type(content) ~= 'table' then return end
        if tostring(content.ownerName or '') ~= tostring(lib.getMyName() or '') then return end
        if tostring(content.ownerServer or '') ~= tostring(lib.getMyServer() or '') then return end

        -- tickId is monotonic only within one coordinator process. Accept a
        -- new boot even when its counter restarted at zero, then tombstone the
        -- old boot so delayed packets cannot switch us back.
        local incomingBootId = tostring(content.coordinatorBootId or '')
        if incomingBootId ~= '' and self.retiredCoordinatorBootIds[incomingBootId] then return end
        if incomingBootId ~= '' and incomingBootId ~= self.coordinatorBootId then
            if self.coordinatorBootId and self.coordinatorBootId ~= '' then
                -- A single delayed packet from a dead boot must never hijack a
                -- live session: adopting it would tombstone the real boot and
                -- permanently reject every later broadcast. Require a second
                -- sighting within 2s — a genuinely restarted coordinator
                -- rebroadcasts every STATE_BROADCAST_MS so it confirms at
                -- once; a stray from a dead boot never repeats.
                if self.candidateBootId ~= incomingBootId
                    or (lib.getTimeMs() - (self.candidateBootSeenAt or 0)) > 2000 then
                    self.candidateBootId = incomingBootId
                    self.candidateBootSeenAt = lib.getTimeMs()
                    return
                end
                self.retiredCoordinatorBootIds[self.coordinatorBootId] = true
            end
            self.candidateBootId = nil
            if self.cancelUnifiedAction then
                self:cancelUnifiedAction('coordinator_restarted')
            end
            self.coordinatorBootId = incomingBootId
            self.state = nil
            self.claimPending = false
            self.currentClaimId = nil
            self.currentClaimType = nil
            self.claimEpochAtRequest = nil
            self.awaitingResumeState = false
            self.resumeStateTick = nil
        end

        -- Actors delivery is asynchronous. Within one coordinator boot, never
        -- let an older snapshot replace newer ownership or freshness.
        local incomingTick = tonumber(content.tickId)
        local currentTick = tonumber(self.state and self.state.tickId)
        if incomingTick and currentTick and incomingTick < currentTick then return end

        self.state = content
        self.stateReceivedAt = lib.getTimeMs()
        if self.awaitingResumeState
            and (not self.resumeStateTick or (incomingTick and incomingTick > self.resumeStateTick)) then
            self.awaitingResumeState = false
            self.resumeStateTick = nil
            self.resumeDetectedAt = 0
        end

        -- Start warmup on first state
        if not self.initialized then
            self.warmupUntil = lib.getTimeMs() + lib.Timing.WARMUP_MS
            self.initialized = true
            debugLogToFile(self.name, 'First state received, epoch=%d priority=%d', content.epoch or -1, content.activePriority or -1)
            lib.log('info', self.name, 'First state received, warming up for %dms', lib.Timing.WARMUP_MS)
        end

        -- Check if our claim was granted or rejected
        if self.claimPending then
            if self:ownsClaim() then
                lib.log('debug', self.name, 'Claim granted: %s', self.currentClaimId)
                self.claimPending = false
                self.claimEpochAtRequest = nil
            elseif self.claimEpochAtRequest and self.state.epoch > self.claimEpochAtRequest then
                -- Epoch changed but we don't own - claim was rejected or someone else got it
                local elapsed = lib.getTimeMs() - self.claimRequestedAt
                if elapsed > 100 then
                    lib.log('debug', self.name, 'Claim likely rejected (epoch changed): %s', self.currentClaimId)
                    self.claimPending = false
                    self.currentClaimId = nil
                    self.currentClaimType = nil
                    self.claimEpochAtRequest = nil
                end
            end
        end
    end

    ---------------------------------------------------------------------------
    -- Main Loop Logic
    ---------------------------------------------------------------------------

    function self:tick()
        -- Zoning is a suspended state, not a module shutdown. Keep Actors
        -- heartbeats alive but advertise no work and never touch character
        -- TLOs until MacroQuest reports INGAME again.
        if not lib.isInGame() then
            self:cancelUnifiedAction('not_ingame')
            if self.currentClaimId then
                self:releaseClaim('not_ingame')
            end
            self:sendNeed(false, nil, 'not_ingame')
            return
        end

        -- A foreground/background transition can suspend every Lua coroutine
        -- while wall-clock time continues. Do not cancel a valid in-flight job
        -- on the first resumed worker tick; wait for a newer coordinator tick.
        if self.awaitingResumeState then
            local resumeAge = lib.getTimeMs() - (self.resumeDetectedAt or 0)
            if resumeAge <= lib.Timing.COORDINATOR_ABSENCE_MS then
                local active = self.currentClaimId ~= nil
                    or (self.unifiedExecutorEnabled and ActionExecutor.hasActiveJob())
                self:sendNeed(active, active and 5000 or nil, 'scheduler_resume_wait')
                return
            end
            self.awaitingResumeState = false
            self.resumeStateTick = nil
        end

        -- Reload shared settings only when the UI-published revision changes.
        -- This replaces the former 500ms all-INI polling in every worker.
        local revision = tonumber(self.state and self.state.settingsRevision)
        if revision and revision ~= self.settingsRevision then
            lib.refreshSettings(revision)
            self.settingsRevision = revision
            if self.onSettingsReload then pcall(self.onSettingsReload, self, revision) end
        end

        -- Humanize override (/skboss, /skfullbore) is transient UI state relayed
        -- through the coordinator snapshot. Apply it to this process's humanize
        -- instance; stays pending until the module actually loads humanize
        -- (some workers only require it lazily on first cast).
        local desiredOverride = self.state and self.state.humanizeOverride
        if desiredOverride ~= nil and desiredOverride ~= self.appliedHumanizeOverride then
            local H = package.loaded['sidekick-next.humanize']
            if H and H.setOverride then
                pcall(H.setOverride, desiredOverride ~= 'auto' and desiredOverride or nil)
                self.appliedHumanizeOverride = desiredOverride
            end
        end

        -- Global automation pause. Keep the worker alive and heartbeating, but
        -- advertise no work and release any claim so the coordinator is not
        -- pinned to a paused module.
        local paused = self.state and self.state.automationPaused
        if paused == nil and lib.isAutomationPaused then paused = lib.isAutomationPaused() end
        if paused == true then
            self:cancelUnifiedAction('automation_paused')
            if self.currentClaimId then
                self:releaseClaim('automation_paused')
            end
            self.claimPending = false
            self.claimEpochAtRequest = nil
            self:sendNeed(false, nil, 'automation_paused')
            return
        end

        -- Death/hovering invalidates any local action claim. Continuing to
        -- advertise need while dead can leave the coordinator stuck on an
        -- owner that cannot cast after a wipe.
        if lib.isSelfDeadOrHovering and lib.isSelfDeadOrHovering() then
            self:cancelUnifiedAction('self_dead')
            if self.currentClaimId then
                lib.log('warn', self.name, 'Self dead/hovering, releasing claim')
                self:releaseClaim('self_dead')
            end
            self:sendNeed(false, nil, 'self_dead')
            return
        end

        -- Revalidate local control state in the worker's normal tick. This is
        -- intentionally independent of the coordinator snapshot so a stun/mez
        -- cannot leave a granted claim waiting for the next Actor broadcast.
        local incapacitated, incapReason = lib.isIncapacitated()
        if incapacitated then
            local reason = 'incapacitated:' .. tostring(incapReason or 'unknown')
            self:cancelUnifiedAction(reason)
            if self.currentClaimId then
                lib.log('warn', self.name, 'Unable to act (%s), releasing claim', tostring(incapReason))
                self:releaseClaim(reason)
            end
            self.claimPending = false
            self.claimEpochAtRequest = nil
            self:sendNeed(false, nil, reason)
            return
        end

        -- Safety: stop if no valid state
        if not self:hasValidState() then
            -- Log occasionally to avoid spam
            if not self._lastNoStateLog or (lib.getTimeMs() - self._lastNoStateLog) > 5000 then
                self._lastNoStateLog = lib.getTimeMs()
                debugLogToFile(self.name, 'tick: No valid state (state=%s)', self.state and 'exists' or 'nil')
            end
            self:cancelUnifiedAction('state_stale')
            if self.currentClaimId then
                lib.log('warn', self.name, 'State stale, releasing claim')
                self:releaseClaim('state_stale')
            end
            self.claimPending = false
            self.claimEpochAtRequest = nil
            self:sendNeed(false, nil, 'state_stale')
            return
        end

        -- Skip during warmup
        if self:isWarmingUp() then
            return
        end

        -- Call custom tick handler
        if self.onTick then
            self.onTick(self)
        end

        -- Once submitted, an action continues to be monitored even if the
        -- scheduler's active priority changes. The coordinator may preserve a
        -- live cast while revoking target ownership; the executor finishes the
        -- observed cast and releases the original claim when it ends.
        if self.unifiedExecutorEnabled and (ActionExecutor.hasJob() or self:ownsClaim()) then
            self:driveUnifiedAction()
            return
        end

        -- Check if we should act
        if not self:isMyPriority() then
            return
        end

        -- If we already own the action, execute
        local ownsIt = self:ownsClaim()
        if ownsIt then
            if self.executeAction then
                -- A control effect can land after the priority/ownership checks
                -- above. Sample once more immediately before side effects.
                local blocked, blockedReason = lib.isIncapacitated()
                if blocked then
                    local reason = 'incapacitated:' .. tostring(blockedReason or 'unknown')
                    self:releaseClaim(reason)
                    self:sendNeed(false, nil, reason)
                    return
                end
                local success, reason = self.executeAction(self)
                lib.log('debug', self.name, 'executeAction returned: success=%s reason=%s', tostring(success), tostring(reason))
                if success or reason == 'completed' then
                    self:releaseClaim(reason or 'completed')
                end
            end
            return
        end

        -- Check if we should request a claim
        if self.shouldAct and self.shouldAct(self) then
            if self.getAction then
                local action = self.getAction(self)
                if action then
                    lib.log('debug', self.name, 'Requesting claim for action: %s', tostring(action.name or action.reason or 'unknown'))
                    self:requestClaim(action)
                end
            end
        end
    end

    ---------------------------------------------------------------------------
    -- Initialization
    ---------------------------------------------------------------------------

    function self:enablePeerActors()
        self.peerActorsEnabled = true
    end

    --- Send low-volume worker telemetry to the UI script on this character.
    -- Script scoping is explicit because a mailbox-only Actor address cannot
    -- cross from sidekick-next/sk_* into the sidekick-next UI process.
    function self:sendToLocalUi(msgId, payload)
        if not self.dropbox or not msgId or msgId == '' then return false end
        local character = lib.localCharacter()
        if not character then return false end
        local server = lib.getMyServer()
        local safePayload = actorSafeCopy(payload or {}) or {}
        safePayload.id = msgId
        safePayload.from = safePayload.from or lib.getMyName()
        safePayload.server = safePayload.server or server
        local sent = false
        local uiScripts = type(lib.Scripts.UI) == 'table'
            and lib.Scripts.UI or { lib.Scripts.UI }
        for _, scriptName in ipairs(uiScripts) do
            if scriptName and scriptName ~= '' then
                local address = {
                    mailbox = 'sidekick',
                    script = scriptName,
                    character = character,
                }
                if server and server ~= '' then address.server = server end
                local ok = pcall(self.dropbox.send, self.dropbox, address, safePayload)
                sent = sent or ok
            end
        end
        return sent
    end

    function self:initialize()
        debugLogToFile(self.name, 'Initializing module (priority=%d)', self.priority)
        lib.log('info', self.name, 'Initializing module (priority=%d)', self.priority)

        -- Register actor to receive state broadcasts
        self.dropbox = actors.register(self.name, function(message)
            local content = message()
            if type(content) ~= 'table' then return end

            -- Check if this is a state broadcast
            if content.tickId and content.epoch then
                self:onStateReceived(content)
            end
        end)

        -- Also listen on state mailbox
        self.stateDropbox = actors.register(lib.Mailbox.STATE, function(message)
            local content = message()
            if type(content) == 'table' and content.tickId and content.epoch then
                self:onStateReceived(content)
            end
        end)

        -- Automatic casts occur in worker-local SpellEngine instances. Forward
        -- their terminal results to the UI-owned death black box.
        if not self.forensicsCastHooked then
            local ok, SpellEngine = pcall(require, 'sidekick-next.utils.spell_engine')
            if ok and SpellEngine and SpellEngine.addCastCompleteListener then
                SpellEngine.addCastCompleteListener(function(castData, result)
                    local settings = lib.getSettings()
                    if settings and settings.DeathForensicsEnabled == false then return end
                    castData = castData or {}
                    local targetId = tonumber(castData.targetId) or 0
                    local targetName = ''
                    if targetId > 0 then
                        targetName = lib.safeTLO(function()
                            local spawn = mq.TLO.Spawn(targetId)
                            return spawn and spawn() and spawn.CleanName() or ''
                        end, '') or ''
                    end
                    self:sendToLocalUi('forensics:cast', {
                        castData = {
                            spellName = tostring(castData.spellName or ''),
                            spellCategory = tostring(castData.spellCategory or ''),
                            targetId = targetId,
                            targetName = targetName,
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
            end
        end

        lib.log('info', self.name, 'Module ready, waiting for Coordinator state...')
    end

    --- Check if coordinator has been absent too long
    ---@return boolean True if coordinator is presumed crashed
    function self:isCoordinatorAbsent()
        -- Coordinator state broadcasts may pause during a zone transition.
        -- Do not convert that expected pause into a worker self-shutdown.
        if not lib.isInGame() then return false end
        -- Not initialized yet = still waiting, not absent
        if not self.initialized then return false end
        -- Never received state = still in startup
        if self.stateReceivedAt == 0 then return false end

        local now = lib.getTimeMs()
        local absence = now - self.stateReceivedAt
        if absence <= lib.Timing.COORDINATOR_ABSENCE_MS then return false end

        -- Actor state delivery is not authoritative for local process
        -- liveness. If MQ2Lua still has the coordinator process, preserve this
        -- worker and start a fresh absence window. Unknown status is handled
        -- non-destructively as well.
        if (now - (self.lastCoordinatorCheckAt or 0)) < 1000 then
            return self.lastCoordinatorStatus == 'EXITED'
        end
        local status = lib.getLuaScriptStatus(lib.Scripts.COORDINATOR)
        self.lastCoordinatorCheckAt = now
        self.lastCoordinatorStatus = status
        if status ~= 'EXITED' then
            debugLogToFile(self.name,
                'WATCHDOG: coordinator actor state stale but Lua status=%s; keeping worker',
                status ~= '' and status or 'UNKNOWN')
            return false
        end
        return true
    end

    function self:run(tickDelayMs)
        tickDelayMs = tickDelayMs or 50

        self:initialize()

        local lastHeartbeat = 0
        local _coordinatorAbsentLogged = false
        local wasInGame = lib.isInGame()
        local lastLoopAt = lib.getTimeMs()
        -- Orphan watchdog: a forced /lua stop of the parent UI skips
        -- init.lua's Supervisor.stop(), leaving workers running headless.
        -- Poll the parent every 5s; two consecutive misses (10s — rides out
        -- a fast /lua restart of the UI) means we self-terminate.
        local lastParentCheckAt = lib.getTimeMs()
        local parentMisses = 0

        while self.running do
            local loopStartedAt = lib.getTimeMs()
            local loopGap = loopStartedAt - lastLoopAt
            lastLoopAt = loopStartedAt
            if self.state and loopGap > lib.Timing.STATE_TTL_MS then
                self.awaitingResumeState = true
                self.resumeStateTick = tonumber(self.state.tickId)
                self.resumeDetectedAt = loopStartedAt
                if ActionExecutor.rebaseTimers then ActionExecutor.rebaseTimers(loopGap) end
                if self.onSchedulerResume then pcall(self.onSchedulerResume, self, loopGap) end
                debugLogToFile(self.name,
                    'Scheduler resumed after %dms; awaiting coordinator tick newer than %s',
                    loopGap, tostring(self.resumeStateTick or '-'))
            end
            if self.peerActors and self.peerActors.tick then
                self.peerActors.tick()
            end
            -- Spell/cast result events belong to the worker process that
            -- issued the action. Drain them from the yieldable main loop so
            -- the unified executor can advance without module-specific event
            -- plumbing.
            if mq.doevents then pcall(mq.doevents) end

            do
                local nowMs = lib.getTimeMs()
                if not lib.isInGame() then
                    -- Process TLOs can be unavailable during zoning; never
                    -- count that expected gap as a missing parent.
                    lastParentCheckAt = nowMs
                    parentMisses = 0
                elseif (nowMs - lastParentCheckAt) >= 5000 then
                    lastParentCheckAt = nowMs
                    if lib.isUiRunning() then
                        parentMisses = 0
                    else
                        parentMisses = parentMisses + 1
                        if parentMisses >= 2 then
                            lib.log('info', self.name,
                                'Parent SideKick script stopped; shutting down worker')
                            self:stop()
                            break
                        end
                    end
                end
            end

            self:tick()

            -- Send heartbeat periodically
            local now = lib.getTimeMs()
            local inGame = lib.isInGame()
            if inGame and not wasInGame then
                -- Coordinator state delivery and worker ticks race on the
                -- first frame after zoning. Start a fresh absence window.
                self.stateReceivedAt = now
            end
            wasInGame = inGame
            if (now - lastHeartbeat) >= lib.Timing.MODULE_HEARTBEAT_MS then
                self:sendHeartbeat()
                lastHeartbeat = now
            end

            -- Watchdog: check for coordinator absence
            if self:isCoordinatorAbsent() then
                if not _coordinatorAbsentLogged then
                    _coordinatorAbsentLogged = true
                    local absence = now - self.stateReceivedAt
                    -- print(string.format(
                    --     '\ar[SK-Watchdog]\ax Module "%s": Coordinator absent for %.1fs — shutting down gracefully',
                    --     self.name, absence / 1000))
                    debugLogToFile(self.name, 'WATCHDOG: Coordinator absent for %dms, shutting down', now - self.stateReceivedAt)
                    lib.log('warn', self.name,
                        'Stopping worker: coordinator Lua process is EXITED')
                end
                self:stop()
            else
                _coordinatorAbsentLogged = false
            end

            mq.delay(tickDelayMs)
        end

        lib.log('info', self.name, 'Module stopped')
    end

    function self:stop()
        self.running = false
        self:cancelUnifiedAction('shutdown')
        if self.currentClaimId then
            self:releaseClaim('shutdown')
        end
    end

    return self
end

return M
