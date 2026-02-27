-- F:/lua/sidekick-next/sk_module_base.lua
-- Base class for SideKick priority modules
-- Handles state reception, claim requests, and execution guards

local mq = require('mq')
local actors = require('actors')
local lib = require('sidekick-next.sk_lib')

local M = {}

local debugLogToFile = require('sidekick-next.utils.debug_log').moduleTagged('sk_module_base', 'SK_MODULE_BASE')

--- Create a new module instance
-- @param moduleName string Unique module name
-- @param priority number Module's priority tier
-- @return table Module instance
function M.create(moduleName, priority)
    local self = {
        name = moduleName,
        priority = priority,

        -- State from Coordinator
        state = nil,
        stateReceivedAt = 0,

        -- Claim tracking
        claimCounter = 0,
        currentClaimId = nil,
        claimPending = false,
        claimRequestedAt = 0,
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

        -- If we own by module name but claimId doesn't match, adopt the coordinator's claimId
        -- This handles the case where we sent multiple claims and an earlier one was granted
        if owner.claimId ~= self.currentClaimId then
            debugLogToFile(self.name, 'ownsCast: Adopting coordinator claimId (owner=%s, was=%s)',
                tostring(owner.claimId), tostring(self.currentClaimId))
            self.currentClaimId = owner.claimId
            self.claimPending = false
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

        -- If we own by module name but claimId doesn't match, adopt the coordinator's claimId
        if owner.claimId ~= self.currentClaimId then
            debugLogToFile(self.name, 'ownsTarget: Adopting coordinator claimId (owner=%s, was=%s)',
                tostring(owner.claimId), tostring(self.currentClaimId))
            self.currentClaimId = owner.claimId
            self.claimPending = false
        end

        -- The coordinator includes this module as owner in the state broadcast,
        -- which means ownership is still valid. Module name match is authoritative.
        return true
    end

    function self:ownsAction()
        return self:ownsCast() and self:ownsTarget()
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

        local claim = {
            msgType = 'claim',
            type = lib.ClaimType.ACTION,
            wants = { 'target', 'cast' },
            module = self.name,
            priority = self.priority,
            claimId = self.currentClaimId,
            epochSeen = self.state.epoch,
            ttlMs = lib.Timing.CLAIM_DEFAULT_TTL_MS,
            reason = action.reason or 'action',
            action = action,
        }

        self.claimPending = true
        self.claimRequestedAt = lib.getTimeMs()

        pcall(function()
            self.dropbox:send({ mailbox = lib.Mailbox.CLAIM, script = lib.Scripts.COORDINATOR }, claim)
        end)

        lib.log('debug', self.name, 'Claim requested: %s (epoch=%d)', self.currentClaimId, self.state.epoch)
        return true
    end

    function self:releaseClaim(reason)
        if not self.currentClaimId then return end

        local release = {
            msgType = 'release',
            type = 'action',
            module = self.name,
            claimId = self.currentClaimId,
            epochSeen = self.state and self.state.epoch or 0,
            reason = reason or 'completed',
        }

        pcall(function()
            self.dropbox:send({ mailbox = lib.Mailbox.RELEASE, script = lib.Scripts.COORDINATOR }, release)
        end)

        lib.log('debug', self.name, 'Release sent: %s (%s)', self.currentClaimId, reason)
        self.currentClaimId = nil
        self.claimPending = false
    end

    function self:requestInterrupt(reason)
        if not self:hasValidState() then return end

        local interrupt = {
            msgType = 'interrupt',
            requestingModule = self.name,
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
                sentAtMs = lib.getTimeMs(),
                ready = true,
            })
        end)
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
            if self:ownsAction() then
                lib.log('debug', self.name, 'Claim granted: %s', self.currentClaimId)
                self.claimPending = false
            elseif self.state.epoch > (self.claimRequestedAt and self.state.epoch or 0) then
                -- Epoch changed but we don't own - claim was rejected or someone else got it
                local elapsed = lib.getTimeMs() - self.claimRequestedAt
                if elapsed > 100 then
                    lib.log('debug', self.name, 'Claim likely rejected (epoch changed): %s', self.currentClaimId)
                    self.claimPending = false
                    self.currentClaimId = nil
                end
            end
        end
    end

    ---------------------------------------------------------------------------
    -- Main Loop Logic
    ---------------------------------------------------------------------------

    function self:tick()
        -- Safety: stop if no valid state
        if not self:hasValidState() then
            -- Log occasionally to avoid spam
            if not self._lastNoStateLog or (lib.getTimeMs() - self._lastNoStateLog) > 5000 then
                self._lastNoStateLog = lib.getTimeMs()
                debugLogToFile(self.name, 'tick: No valid state (state=%s)', self.state and 'exists' or 'nil')
            end
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

        -- Check if we should act
        if not self:isMyPriority() then
            return
        end

        -- If we already own the action, execute
        local ownsIt = self:ownsAction()
        if ownsIt then
            if self.executeAction then
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

        lib.log('info', self.name, 'Module ready, waiting for Coordinator state...')
    end

    --- Check if coordinator has been absent too long
    ---@return boolean True if coordinator is presumed crashed
    function self:isCoordinatorAbsent()
        -- Not initialized yet = still waiting, not absent
        if not self.initialized then return false end
        -- Never received state = still in startup
        if self.stateReceivedAt == 0 then return false end

        local now = lib.getTimeMs()
        local absence = now - self.stateReceivedAt
        return absence > lib.Timing.COORDINATOR_ABSENCE_MS
    end

    function self:run(tickDelayMs)
        tickDelayMs = tickDelayMs or 50

        self:initialize()

        local lastHeartbeat = 0
        local _coordinatorAbsentLogged = false

        while self.running do
            self:tick()

            -- Send heartbeat periodically
            local now = lib.getTimeMs()
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
        if self.currentClaimId then
            self:releaseClaim('shutdown')
        end
    end

    return self
end

return M
