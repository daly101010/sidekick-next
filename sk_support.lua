local lib = require('sidekick-next.sk_lib')
local Domain = require('sidekick-next.utils.domain_orchestrator')

local module = Domain.create({
    name = 'support',
    priority = lib.Priority.HEALING,
    components = { 'healing', 'cures', 'resurrection' },
    shouldInterrupt = function(_, active, winner)
        return active == 'resurrection'
            and (winner == 'healing' or winner == 'cures')
    end,
})

module:run(50)
return module
