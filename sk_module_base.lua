-- F:/lua/sidekick-next/sk_module_base.lua
-- Base class for SideKick priority modules
-- Handles state reception, claim requests, and execution guards

local mq = require('mq')
local actors = require('actors')
local lib = require('sidekick-next.sk_lib')
local ActionExecutor = require('sidekick-next.utils.action_executor')

local M = {}

local debugLogToFile = require('sidekick-next.utils.debug_log').moduleTagged('sk_module_base', 'SK_MODULE_BASE')

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
        stateReceivedAt = 0,

        -- Claim tracking
        claimCounter = 0,
        currentClaimId = nil,
        currentClaimType = nil,
        claimPending = false,
        claimRequestedAt = 0,
        claimEpochAtRequest = nil,
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
        settingsRevision = nil,

        -- Unified action executor (opt-in during compatibility migration)
        unifiedExecutorEnabled = false,
        actionHandlers = nil,
        lastActionResult = nil,

        -- Callbacks (override these)
        onTick = nil,          -- Called each tick when active
        shouldAct = nil,       -- Returns true if module needs to act
        getAction = nil,       -- Returns action details for claim
        executeAction = nil,   -- Executes the action after claim granted
    }

    ---------------------------------------------------------------------------
    -- State Management
    ---------------------------------------------------------------------------

    function self:hasValidState()
        if not self.state then return false end
        return not lib.isStale(self.state.sentAtMs, self.state.ttlMs)
    end

    function self:isMyPriority()
        if not self:hasValidState() then return false end
        return self.state.activePriority == self.priority or self.priority == lib.Priority.EMERGENCY
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
            action = action,
        }

        self.claimPending = true
        self.claimRequestedAt = lib.getTimeMs()
        self.claimEpochAtRequest = self.state.epoch

        pcall(function()
            self.dropbox:send({ mailbox = lib.Mailbox.CLAIM, script = lib.Scripts.COORDINATOR }, claim)
        end)

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
            self.dropbox:send({ mailbox = lib.Mailbox.RELEASE, script = lib.Scripts.COORDINATOR }, release)
        end)

        lib.log('debug', self.name, 'Release sent: %s (%s)', self.currentClaimId, reason)
        self.lastReleasedClaimId = releasedClaimId
        self.lastReleasedAtMs = lib.getTimeMs()
        self.currentClaimId = nil
        self.currentClaimType = nil
        self.claimPending = false
        self.claimEpochAtRequest = nil
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
            self.dropbox:send({ mailbox = lib.Mailbox.INTERRUPT, script = lib.Scripts.COORDINATOR }, interrupt)
        end)

        lib.log('debug', self.name, 'Interrupt requested: %s', reason)
    end

    function self:sendHeartbeat()
        debugLogToFile(self.name, 'Sending heartbeat to %s', lib.Scripts.COORDINATOR)
        pcall(function()
            self.dropbox:send({ mailbox = lib.Mailbox.HEARTBEAT, script = lib.Scripts.COORDINATOR }, {
                msgType = 'heartbeat',
                module = self.name,
                ownerName = lib.getMyName(),
                ownerServer = lib.getMyServer(),
                sentAtMs = lib.getTimeMs(),
                ready = true,
                action = self.unifiedExecutorEnabled and ActionExecutor.getStatus() or nil,
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
        if not reasonChanged and self.lastNeedValue == value and (now - (self.lastNeedSentAt or 0)) < 100 then
            return
        end
        self.lastNeedValue = value
        self.lastNeedSentAt = now
        self.lastNeedReason = reason
        pcall(function()
            self.dropbox:send({ mailbox = lib.Mailbox.NEED, script = lib.Scripts.COORDINATOR }, {
                msgType = 'need',
                module = self.name,
                ownerName = lib.getMyName(),
                ownerServer = lib.getMyServer(),
                priority = self.priority,
                needsAction = value,
                ttlMs = ttlMs or 250,
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

        self.state = content
        self.stateReceivedAt = lib.getTimeMs()

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

        -- Reload shared settings only when the UI-published revision changes.
        -- This replaces the former 500ms all-INI polling in every worker.
        local revision = tonumber(self.state and self.state.settingsRevision)
        if revision and revision ~= self.settingsRevision then
            lib.refreshSettings(revision)
            self.settingsRevision = revision
            if self.onSettingsReload then pcall(self.onSettingsReload, self, revision) end
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
        local status = lib.getLuaScriptStatus(lib.Scripts.COORDINATOR)
        if status ~= 'EXITED' then
            self.stateReceivedAt = now
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

        while self.running do
            if self.peerActors and self.peerActors.tick then
                self.peerActors.tick()
            end
            -- Spell/cast result events belong to the worker process that
            -- issued the action. Drain them from the yieldable main loop so
            -- the unified executor can advance without module-specific event
            -- plumbing.
            if mq.doevents then pcall(mq.doevents) end
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
