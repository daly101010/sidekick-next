-- Coordinated pull worker. Scanning is read-only; navigation, targeting, and
-- the pull ability begin only after the coordinator grants target ownership.

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local Pull = require('sidekick-next.automation.pull')
local ActorsCoordinator = require('sidekick-next.utils.actors_coordinator')

local module = ModuleBase.create('pull', lib.Priority.PULL)
local MAX_MANUAL_QUEUE = 20
local _snapshot = nil
local _hadOwnership = false
local _manualRequests = {}
local _lastTelemetryAt = 0
local _actorCallbacksRegistered = false

local function hasValidV2Envelope(content)
    local envelope = type(content) == 'table'
        and type(content.envelope) == 'table' and content.envelope or nil
    local sequence = envelope and tonumber(envelope.sequence) or 0
    local ttlMs = envelope and tonumber(envelope.ttlMs) or 0
    return envelope ~= nil
        and tonumber(envelope.version) == ActorsCoordinator.ENVELOPE_VERSION
        and tostring(envelope.session or '') ~= ''
        and sequence > 0
        and sequence == math.floor(sequence)
        and ttlMs > 0 and ttlMs <= 30000
        and tonumber(envelope.sentAtMs) ~= nil
end

local function isLocalUiSender(sender, fromMe)
    if fromMe ~= true or type(sender) ~= 'table' then return false end
    local scripts = type(lib.Scripts.UI) == 'table'
        and lib.Scripts.UI or { lib.Scripts.UI }
    for _, scriptName in ipairs(scripts) do
        if lib.actorSenderMatches(sender, scriptName, 'sidekick') then return true end
    end
    return false
end

local function receiveManualRequest(command, content, envelope, sender, fromMe)
    if type(content) ~= 'table'
        or not hasValidV2Envelope(envelope)
        or not isLocalUiSender(sender, fromMe) then
        return true
    end
    command = tostring(command or ''):lower()
    if command ~= 'pulltarget' and command ~= 'clearignore'
        and command ~= 'camp' and command ~= 'status' then
        return true
    end
    if #_manualRequests >= MAX_MANUAL_QUEUE then table.remove(_manualRequests, 1) end
    _manualRequests[#_manualRequests + 1] = {
        command = command,
        targetId = tonumber(content.targetId) or 0,
    }
    return true
end

local function ensureActorCallbacks(coordinator)
    if _actorCallbacksRegistered or not coordinator then return end
    if not coordinator.registerWorkerCommand then return end
    coordinator.registerWorkerCommand('pull', receiveManualRequest)
    _actorCallbacksRegistered = true
end

local function drainManualRequests()
    if #_manualRequests == 0 then return end
    local requests = _manualRequests
    _manualRequests = {}
    for _, request in ipairs(requests) do
        if request.command == 'pulltarget' then
            if request.targetId > 0 then
                Pull.selectTargetId(request.targetId)
            end
        elseif request.command == 'clearignore' then
            Pull.clearIgnore()
        elseif request.command == 'camp' then
            Pull.setCamp()
        elseif request.command == 'status' then
            local state = Pull.getState()
            print(string.format('%s \ag[SK Pull]\ax state=%s reason=%s target=%s owns=%s',
                lib.timestampPrefix(),
                tostring(state.state), tostring(state.reason), tostring(state.pullId),
                tostring(module:ownsLease())))
        end
    end
end

local function refresh()
    Pull.tick({ allowActions = false })
    _snapshot = Pull.getState()
    return _snapshot
end

local function publishTelemetry(state)
    local now = lib.getTimeMs()
    if (now - _lastTelemetryAt) < 250 then return end
    _lastTelemetryAt = now
    if not module.peerActors or not module.peerActors.sendTelemetryToScript then return end
    local scripts = type(lib.Scripts.UI) == 'table'
        and lib.Scripts.UI or { lib.Scripts.UI }
    for _, scriptName in ipairs(scripts) do
        pcall(module.peerActors.sendTelemetryToScript,
            scriptName, module.name, 'pull:telemetry', {
            state = tostring(state.state or ''),
            reason = tostring(state.reason or ''),
            pullId = tonumber(state.pullId) or 0,
            campSet = state.campSet == true,
            ownsLease = module:ownsLease(),
        })
    end
end

module.onSettingsReload = function()
    Pull.reloadSettings()
end

module.onTick = function(self)
    ensureActorCallbacks(self.peerActors)
    drainManualRequests()
    local before = Pull.getState()
    local active = before.state == Pull.STATES.NAV_TO_TARGET
        or before.state == Pull.STATES.PULLING
        or before.state == Pull.STATES.RETURN_CAMP
        or before.state == Pull.STATES.WAITING_MOB
    if active and _hadOwnership and not self:ownsLease() then
        Pull.cancel('lease_lost')
    end
    _hadOwnership = self:ownsLease()

    local state = refresh()
    publishTelemetry(state)
    local needs = state.state == Pull.STATES.READY
        or state.state == Pull.STATES.NAV_TO_TARGET
        or state.state == Pull.STATES.PULLING
        or state.state == Pull.STATES.RETURN_CAMP
        or state.state == Pull.STATES.WAITING_MOB
    self:setIntent(needs, nil,
        needs and ('pull:' .. tostring(state.state)) or tostring(state.reason or state.state))
end

module.shouldAct = function()
    return _snapshot ~= nil
        and tonumber(_snapshot.pullId) > 0
        and _snapshot.state ~= Pull.STATES.IDLE
        and _snapshot.state ~= Pull.STATES.SCAN
        and _snapshot.state ~= Pull.STATES.WAITING_GATE
end

module.getAction = function()
    if not _snapshot or tonumber(_snapshot.pullId) <= 0 then return nil end
    local targetId = tonumber(_snapshot.pullId)
    local spawn = mq.TLO.Spawn(targetId)
    local targetName = spawn and spawn() and tostring(spawn.CleanName() or '') or ''
    local targetType = spawn and spawn() and tostring(spawn.Type() or '') or ''
    return {
        kind = 'movement',
        name = 'Pull target',
        targetId = targetId,
        targetName = targetName,
        targetType = targetType,
        expectsCastStart = false,
        idempotencyKey = string.format('pull:%d', targetId),
        reason = 'pull:' .. tostring(_snapshot.state),
    }
end

module.executeAction = function(self)
    _hadOwnership = true
    self:markDirtyEffects(true)
    Pull.tick({ allowActions = true })
    _snapshot = Pull.getState()
    if _snapshot.state == Pull.STATES.IDLE or _snapshot.state == Pull.STATES.WAITING_GATE then
        return true, tostring(_snapshot.reason or 'completed')
    end
    return false, 'pull:' .. tostring(_snapshot.state)
end

module.onLeaseFinalizing = function(self, _, reason)
    local state = Pull.getState()
    if state.state ~= Pull.STATES.IDLE and state.state ~= Pull.STATES.WAITING_GATE then
        Pull.cancel('lease_released:' .. tostring(reason or 'unknown'))
    end
    self:markDirtyEffects(false)
    _hadOwnership = false
    return true
end

module:enablePeerActors()
-- Register before ModuleBase initializes the Actor mailbox so a command sent
-- during worker startup cannot be validated and drained before this receiver exists.
ensureActorCallbacks(ActorsCoordinator)

Pull.init()
module:run(50)
Pull.cancel('worker_exit')

return module
