-- Managed coordinated-mode driver for the idle humanize fidget state machine.

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local Humanize = require('sidekick-next.humanize')
local Fidget = require('sidekick-next.humanize.fidget')

local module = ModuleBase.create('fidget', lib.Priority.IDLE)
module.onTick = function(self)
    Humanize.tick()
    Fidget.tick()
    self:sendNeed(false, nil, 'idle_auxiliary')
end

mq.bind('/sk_fidget', function(cmd)
    if tostring(cmd or ''):lower() == 'stop' then module:stop() end
end)

module:run(100)
Fidget.releaseHeldKeys()

return module
