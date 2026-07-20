local mq = require('mq')
local actors = require('actors')
local lib = require('sidekick-next.sk_lib')

local M = {}

local dropbox = nil
local started = false
local lastHeartbeatAt = 0
local sessionId = nil
local lastGameState = ''
local latestState = {}

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

local function send(msgType)
    if not dropbox then return false end
    local ownerName, ownerServer = identity()
    local payload = {
        msgType = msgType,
        module = 'supervisor',
        ownerName = ownerName,
        ownerServer = ownerServer,
        sessionId = sessionId,
        sentAtMs = lib.getTimeMs(),
        automationPaused = latestState.automationPaused == true,
        settingsRevision = tonumber(latestState.settingsRevision) or 0,
    }
    return pcall(function()
        dropbox:send({ mailbox = lib.Mailbox.SUPERVISOR, script = lib.Scripts.COORDINATOR }, payload)
    end)
end

function M.start()
    if started then return end
    started = true
    lastGameState = lib.getGameState()
    sessionId = string.format('%s:%s:%d', lib.getMyServer(), lib.getMyName(), lib.getTimeMs())
    dropbox = actors.register('supervisor', function() end)

    -- A previous UI can be force-stopped without running Lua cleanup. Clear
    -- managed scripts before starting a new coordinated session, but wait for
    -- MQ2Lua to actually retire each process before issuing a matching run.
    for _, script in ipairs(lib.Scripts.WORKERS) do
        stopScript(script, 3000)
    end
    for _, script in ipairs(lib.Scripts.LEGACY_WORKERS or {}) do
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
end

function M.tick(state)
    if not started then return end
    if type(state) == 'table' then latestState = state end
    local now = lib.getTimeMs()

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
    send('supervisor_shutdown')
    mq.delay(50)
    for _, script in ipairs(lib.Scripts.WORKERS) do
        stopScript(script, 3000)
    end
    for _, script in ipairs(lib.Scripts.LEGACY_WORKERS or {}) do
        stopScript(script, 3000)
    end
    stopScript(lib.Scripts.COORDINATOR, 3000)
    if dropbox and dropbox.unregister then
        pcall(function() dropbox:unregister() end)
    end
    dropbox = nil
    started = false
    lastGameState = ''
    latestState = {}
end

function M.sessionId()
    return sessionId
end

return M
