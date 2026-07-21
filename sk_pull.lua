-- Coordinated pull worker. Scanning is read-only; navigation, targeting, and
-- the pull ability begin only after the coordinator grants target ownership.

local mq = require('mq')
local actors = require('actors')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local Pull = require('sidekick-next.automation.pull')

local module = ModuleBase.create('pull', lib.Priority.PULL)
local _snapshot = nil
local _hadOwnership = false
local _manualRequests = {}
local _lastTelemetryAt = 0

local manualDropbox = actors.register('sidekick', function(message)
    local content = message()
    if type(content) ~= 'table' or tostring(content.id or ''):lower() ~= 'pull:manual' then return end
    if #_manualRequests >= 20 then table.remove(_manualRequests, 1) end
    _manualRequests[#_manualRequests + 1] = {
        command = tostring(content.command or ''):lower(),
        targetId = tonumber(content.targetId) or 0,
    }
end)

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
            print(string.format('\ag[SK Pull]\ax state=%s reason=%s target=%s owns=%s',
                tostring(state.state), tostring(state.reason), tostring(state.pullId),
                tostring(module:ownsTarget())))
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
    pcall(function()
        manualDropbox:send({ mailbox = 'sidekick', script = 'sidekick-next' }, {
            id = 'pull:telemetry',
            state = tostring(state.state or ''),
            reason = tostring(state.reason or ''),
            pullId = tonumber(state.pullId) or 0,
            campSet = state.campSet == true,
            ownsTarget = module:ownsTarget(),
        })
    end)
end

module.onSettingsReload = function()
    Pull.reloadSettings()
end

module.onTick = function(self)
    drainManualRequests()
    local before = Pull.getState()
    local active = before.state == Pull.STATES.NAV_TO_TARGET
        or before.state == Pull.STATES.PULLING
        or before.state == Pull.STATES.RETURN_CAMP
        or before.state == Pull.STATES.WAITING_MOB
    if active and _hadOwnership and not self:ownsTarget() then
        Pull.cancel('ownership_lost')
    end
    _hadOwnership = self:ownsTarget()

    local state = refresh()
    publishTelemetry(state)
    local needs = state.state == Pull.STATES.READY
        or state.state == Pull.STATES.NAV_TO_TARGET
        or state.state == Pull.STATES.PULLING
        or state.state == Pull.STATES.RETURN_CAMP
        or state.state == Pull.STATES.WAITING_MOB
    self:sendNeed(needs, needs and 5000 or nil,
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
    return {
        kind = 'pull_target',
        type = lib.ClaimType.TARGET,
        name = 'Pull target',
        targetId = tonumber(_snapshot.pullId),
        expectsCastStart = false,
        claimTtlMs = 240000,
        idempotencyKey = string.format('pull:%d', tonumber(_snapshot.pullId)),
        reason = 'pull:' .. tostring(_snapshot.state),
    }
end

module.executeAction = function(self)
    _hadOwnership = true
    Pull.tick({ allowActions = true })
    _snapshot = Pull.getState()
    if _snapshot.state == Pull.STATES.IDLE or _snapshot.state == Pull.STATES.WAITING_GATE then
        return true, tostring(_snapshot.reason or 'completed')
    end
    return false, 'pull:' .. tostring(_snapshot.state)
end

module.onClaimReleased = function(_, reason)
    local state = Pull.getState()
    if state.state ~= Pull.STATES.IDLE and state.state ~= Pull.STATES.WAITING_GATE then
        Pull.cancel('claim_released:' .. tostring(reason or 'unknown'))
    end
end

Pull.init()
module:run(50)
Pull.cancel('worker_exit')
if manualDropbox and manualDropbox.unregister then pcall(function() manualDropbox:unregister() end) end

return module
