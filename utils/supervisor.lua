local mq = require('mq')
local actors = require('actors')
local lib = require('sidekick-next.sk_lib')

local M = {}

local dropbox = nil
local started = false
local lastHeartbeatAt = 0
local lastCoordinatorCheckAt = 0
local coordinatorRecoveryAt = 0
local coordinatorRecoveryAttempts = 0
local coordinatorStableSince = 0
local coordinatorRecoveryExhaustedLogged = false
local sessionId = nil
local lastGameState = ''
local latestState = {}
local pendingMessages = {}
local MAX_PENDING_MESSAGES = 16
local shutdownDrained = false
local lastCoordinatorBootId = nil

local function enqueueSupervisorMessage(message)
    -- Actor callbacks are non-yieldable. Copy the small scalar acknowledgement
    -- and validate/apply it from tick()/stop().
    local content = message()
    if type(content) ~= 'table' then return end
    local sender = message.sender or {}
    if #pendingMessages >= MAX_PENDING_MESSAGES then table.remove(pendingMessages, 1) end
    pendingMessages[#pendingMessages + 1] = {
        msgType = tostring(content.msgType or ''),
        ownerName = tostring(content.ownerName or ''),
        ownerServer = tostring(content.ownerServer or ''),
        sessionId = tostring(content.sessionId or ''),
        coordinatorBootId = tostring(content.coordinatorBootId or ''),
        senderCharacter = tostring(sender.character or ''),
        senderServer = tostring(sender.server or ''),
        senderScript = tostring(sender.script or ''),
        senderMailbox = tostring(sender.mailbox or ''),
    }
end

local function drainSupervisorMessages()
    if #pendingMessages == 0 then return end
    local pending = pendingMessages
    pendingMessages = {}
    local myName, myServer = lib.getMyName(), lib.getMyServer()
    for _, content in ipairs(pending) do
        local logicalMailbox = content.senderMailbox:lower():match('([^:]+)$')
        if content.msgType == 'supervisor_shutdown_drained'
            and content.sessionId == tostring(sessionId or '')
            and content.ownerName == tostring(myName or '')
            and content.ownerServer == tostring(myServer or '')
            and content.senderCharacter == tostring(myName or '')
            and content.senderServer == tostring(myServer or '')
            and content.senderScript == tostring(lib.Scripts.COORDINATOR or '')
            and logicalMailbox == 'coordinator' then
            shutdownDrained = true
            lastCoordinatorBootId = content.coordinatorBootId
        end
    end
end

local function isRunning(script)
    return lib.isLuaScriptRunning(script)
end

local function waitUntilStopped(script, timeoutMs)
    local deadline = lib.getTimeMs() + (timeoutMs or 3000)
    while isRunning(script) and lib.getTimeMs() < deadline do
        mq.delay(50)
    end
    return not isRunning(script)
end

local function waitUntilRunning(script, timeoutMs)
    local deadline = lib.getTimeMs() + (timeoutMs or 3000)
    while not isRunning(script) and lib.getTimeMs() < deadline do
        mq.delay(50)
    end
    return isRunning(script)
end

local function stopScript(script, timeoutMs)
    if not script or script == '' then return true end
    if not isRunning(script) then return true end
    mq.cmdf('/squelch /lua stop %s', script)
    return waitUntilStopped(script, timeoutMs)
end

local function startScript(script, timeoutMs)
    if not script or script == '' then return false end
    if isRunning(script) then return true end
    mq.cmdf('/lua run %s', script)
    return waitUntilRunning(script, timeoutMs)
end

local function identity()
    return lib.getMyName(), lib.getMyServer()
end

-- Current humanize override as a wire string. Overrides are transient UI-side
-- state (/skboss, /skfullbore), so the heartbeat samples them live rather than
-- requiring binds to push through the supervisor.
local function humanizeOverride()
    local H = package.loaded['sidekick-next.humanize']
    local o = H and H.getOverride and H.getOverride() or nil
    return o or 'auto'
end

local function send(msgType)
    if not dropbox then return false end
    local ownerName, ownerServer = identity()
    local revision = tonumber(latestState.settingsRevision) or 0
    local settings = lib.refreshSettings(revision) or lib.getSettings() or {}
    local preemptionEnabled = latestState.leasePreemptionEnabled
    if preemptionEnabled == nil then
        preemptionEnabled = settings.LeasePreemptionEnabled ~= false
    end
    local payload = {
        msgType = msgType,
        module = 'supervisor',
        ownerName = ownerName,
        ownerServer = ownerServer,
        sessionId = sessionId,
        sentAtMs = lib.getTimeMs(),
        automationPaused = latestState.automationPaused == true,
        settingsRevision = revision,
        humanizeOverride = humanizeOverride(),
        leasePreemptionEnabled = preemptionEnabled ~= false,
    }
    local ok, result = pcall(function()
        dropbox:send({ mailbox = lib.Mailbox.SUPERVISOR, script = lib.Scripts.COORDINATOR,
            character = lib.localCharacter() }, payload)
    end)
    return ok and result ~= false
end

function M.start()
    if started then return end
    started = true
    lastGameState = lib.getGameState()
    sessionId = string.format('%s:%s:%d', lib.getMyServer(), lib.getMyName(), lib.getTimeMs())
    pendingMessages = {}
    shutdownDrained = false
    lastCoordinatorBootId = nil
    dropbox = actors.register('supervisor', enqueueSupervisorMessage)

    -- A previous UI can be force-stopped without running Lua cleanup. Clear
    -- managed scripts before starting a new coordinated session, but wait for
    -- MQ2Lua to actually retire each process before issuing a matching run.
    for _, script in ipairs(lib.Scripts.WORKERS) do
        stopScript(script, 3000)
    end
    stopScript(lib.Scripts.COORDINATOR, 3000)

    startScript(lib.Scripts.COORDINATOR, 3000)
    send('supervisor_heartbeat')
    lastHeartbeatAt = lib.getTimeMs()
    for _, script in ipairs(lib.Scripts.WORKERS) do
        startScript(script, 250)
    end
    send('supervisor_heartbeat')
    lastHeartbeatAt = lib.getTimeMs()
    lastCoordinatorCheckAt = lastHeartbeatAt
end

function M.tick(state)
    if not started then return end
    if type(state) == 'table' then latestState = state end
    drainSupervisorMessages()
    local now = lib.getTimeMs()

    -- The parent owns coordinator lifetime. MQ2Lua stop/run commands complete
    -- asynchronously, so a manual reload can otherwise race and leave every
    -- worker alive but permanently state-stale. Detect that condition before
    -- the workers' longer coordinator-absence watchdog expires.
    if (now - lastCoordinatorCheckAt) >= lib.Timing.SUPERVISOR_HEARTBEAT_MS then
        lastCoordinatorCheckAt = now
        local coordinatorRunning = isRunning(lib.Scripts.COORDINATOR)
        if coordinatorRunning then
            coordinatorStableSince = coordinatorStableSince > 0 and coordinatorStableSince or now
            if (now - coordinatorStableSince) >= lib.Timing.RESTART_STABLE_MS then
                coordinatorRecoveryAttempts = 0
                coordinatorRecoveryExhaustedLogged = false
            end
        else
            coordinatorStableSince = 0
        end
        if not coordinatorRunning
            and coordinatorRecoveryAttempts < lib.MAX_MODULE_RESTARTS
            and (coordinatorRecoveryAttempts == 0
                or (now - coordinatorRecoveryAt) >= lib.Timing.RESTART_COOLDOWN_MS) then
            coordinatorRecoveryAt = now
            coordinatorRecoveryAttempts = coordinatorRecoveryAttempts + 1
            printf('\ay[SK Supervisor]\ax Coordinator exited; restarting it')
            if startScript(lib.Scripts.COORDINATOR, 3000) then
                send('supervisor_heartbeat')
                lastHeartbeatAt = lib.getTimeMs()
            else
                printf('\ar[SK Supervisor]\ax Coordinator restart failed')
            end
        elseif not coordinatorRunning
            and coordinatorRecoveryAttempts >= lib.MAX_MODULE_RESTARTS
            and not coordinatorRecoveryExhaustedLogged then
            coordinatorRecoveryExhaustedLogged = true
            printf('\ar[SK Supervisor]\ax Coordinator restart limit reached (%d)',
                lib.MAX_MODULE_RESTARTS)
        end
    end

    -- Do not wait for the normal interval after a zone transition. An
    -- immediate heartbeat gives the coordinator a fresh post-zone liveness
    -- signal before any watchdog can evaluate the pre-zone timestamp.
    local gameState = lib.getGameState()
    if gameState ~= lastGameState then
        lastGameState = gameState
        lastHeartbeatAt = now
        send('supervisor_heartbeat')
        return
    end

    if (now - lastHeartbeatAt) < lib.Timing.SUPERVISOR_HEARTBEAT_MS then return end
    lastHeartbeatAt = now
    send('supervisor_heartbeat')
end

function M.stop()
    if not started then return end
    shutdownDrained = false
    send('supervisor_shutdown')
    local drainDeadline = lib.getTimeMs()
        + lib.Timing.LEASE_REVOCATION_GRACE_MS
        + lib.Timing.LEASE_RECOVERY_TTL_MS
        + 1000
    while not shutdownDrained
        and isRunning(lib.Scripts.COORDINATOR)
        and lib.getTimeMs() < drainDeadline do
        drainSupervisorMessages()
        if not shutdownDrained then mq.delay(50) end
    end
    if not shutdownDrained and isRunning(lib.Scripts.COORDINATOR) then
        printf('\ar[SK Supervisor]\ax Lease drain acknowledgement timed out; stopping fleet in safety-fault state')
    end
    for _, script in ipairs(lib.Scripts.WORKERS) do
        stopScript(script, 3000)
    end
    stopScript(lib.Scripts.COORDINATOR, 3000)
    if dropbox and dropbox.unregister then
        pcall(function() dropbox:unregister() end)
    end
    dropbox = nil
    started = false
    lastGameState = ''
    lastCoordinatorCheckAt = 0
    coordinatorRecoveryAt = 0
    coordinatorRecoveryAttempts = 0
    coordinatorStableSince = 0
    coordinatorRecoveryExhaustedLogged = false
    latestState = {}
    pendingMessages = {}
    shutdownDrained = false
    lastCoordinatorBootId = nil
end

function M.sessionId()
    return sessionId
end

return M
