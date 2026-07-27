-- Lowest-tier leased driver for bounded idle humanization episodes.

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local Humanize = require('sidekick-next.humanize')
local Fidget = require('sidekick-next.humanize.fidget')

local module = ModuleBase.create('fidget', lib.Priority.AMBIENT)
local selected = nil
local cleanupSamples = 0

module.onTick = function(self)
    Humanize.tick()
    if self.currentRequestId then
        self:setIntent(true, nil,
            Fidget.hasPending() and 'fidget_episode_active' or 'fidget_waiting_for_lease')
        return
    end
    local action, reason = Fidget.planAction()
    selected = action
    self:setIntent(action ~= nil, nil, reason or 'idle_auxiliary')
end

module.shouldAct = function()
    return selected ~= nil
end

module.getAction = function()
    return selected
end

module:enableUnifiedExecutor({
    preflight = function(action)
        return selected ~= nil
            and tostring(action.planId or '') == tostring(selected.planId or ''),
            'fidget_plan_changed'
    end,
    dispatch = function(action)
        selected = nil
        local started, reason = Fidget.startAction(action)
        if not started then return false, reason or 'fidget_start_refused' end
        module:markDirtyEffects(Fidget.hasPending())
        if Fidget.hasPending() then return true, reason, 'custom' end
        return true, reason, 'none'
    end,
    onTick = function()
        local done, reason = Fidget.advanceAction()
        if done then return true, reason, 'completed' end
        return true, reason
    end,
    onFailure = function()
        Fidget.cancelAction()
    end,
    onCancel = function()
        Fidget.cancelAction()
    end,
})

module.onLeaseFinalizing = function(self, _, reason)
    if reason == 'orphan_recovery' then
        Fidget.recoverHeldKeys()
    else
        Fidget.cancelAction()
    end
    if Fidget.hasPending() then
        cleanupSamples = 0
        return false, 'fidget_cleanup_pending'
    end
    if self.dirtyEffects or reason == 'orphan_recovery' then
        cleanupSamples = cleanupSamples + 1
        if cleanupSamples < 2 then return false, 'confirming_fidget_cleanup' end
    end
    cleanupSamples = 0
    self:markDirtyEffects(false)
    return true
end

mq.bind('/sk_fidget', function(cmd)
    cmd = tostring(cmd or ''):lower()
    if cmd == 'stop' then
        module:stop()
    elseif cmd == '' or cmd == 'status' then
        print(string.format(
            '\ag[SK Fidget]\ax running=%s ownsLease=%s pending=%s intent=%s',
            tostring(module.running), tostring(module:ownsLease()),
            tostring(Fidget.hasPending()), tostring(module.intent.reason)))
    end
end)

module:run(100)

return module
