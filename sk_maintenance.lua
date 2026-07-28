local lib = require('sidekick-next.sk_lib')
local Domain = require('sidekick-next.utils.domain_orchestrator')

local module = Domain.create({
    name = 'maintenance',
    priority = lib.Priority.DPS,
    components = { 'resources', 'buffs' },
    cache = true,
    shouldInterrupt = function()
        return false
    end,
})

module:run(50)
return module
