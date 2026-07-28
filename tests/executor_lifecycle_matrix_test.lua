package.path = '../?.lua;../?/init.lua;' .. package.path

local clock = 1000
package.loaded.mq = {
    gettime = function() return clock end,
    TLO = {},
}
package.loaded['sidekick-next.utils.core'] = {
    CanQueryItems = function() return true end,
}
package.loaded['sidekick-next.lib.helpers'] = {
    discNameCandidates = function(name) return { name } end,
}
package.loaded['sidekick-next.sk_lib'] = {
    isCasting = function() return false end,
    isIncapacitated = function() return false end,
}
package.loaded['sidekick-next.utils.lazy_require'] = setmetatable({
    once = function() return function() return nil end end,
}, {
    __call = function() return function() return nil end end,
})

local Executor = require('sidekick-next.utils.action_executor')

local function terminal(action, handlers, drive)
    Executor.init()
    local ok, reason = Executor.submit(action, {
        handlers = handlers,
        context = {},
    })
    assert(ok, reason)
    drive()
    local result = assert(Executor.consumeResult(), 'terminal result not drainable')
    assert(not Executor.hasJob(), 'terminal job leaked after consume')
    return result
end

local completed = terminal({ kind = 'test', timeoutMs = 5000 }, {
    dispatch = function() return true, 'done', 'none' end,
}, function() Executor.tick({ ownsAction = function() return true end }) end)
assert(completed.phase == 'completed')

local failed = terminal({ kind = 'test', timeoutMs = 5000 }, {
    dispatch = function() return false, 'rejected' end,
}, function() Executor.tick({ ownsAction = function() return true end }) end)
assert(failed.phase == 'failed' and failed.reason == 'rejected')

local defaultFallback = terminal({ kind = 'test', timeoutMs = 5000 }, {
    dispatch = function()
        return nil, Executor.USE_DEFAULT_DISPATCH
    end,
}, function() Executor.tick({ ownsAction = function() return true end }) end)
assert(defaultFallback.phase == 'failed'
    and defaultFallback.reason == 'unsupported_kind:test')

local cancelled = terminal({ kind = 'test', timeoutMs = 5000 }, {}, function()
    assert(Executor.cancel('revoke'))
end)
assert(cancelled.phase == 'cancelled' and cancelled.reason == 'revoke')

local ownershipLost = terminal({ kind = 'test', timeoutMs = 5000 }, {}, function()
    Executor.tick({ ownsAction = function() return false end })
end)
assert(ownershipLost.phase == 'cancelled'
    and ownershipLost.reason == 'ownership_lost')

local customTicks = 0
local custom = terminal({ kind = 'test', timeoutMs = 5000 }, {
    dispatch = function() return true, 'started', 'custom' end,
    onTick = function()
        customTicks = customTicks + 1
        return true, 'done', 'completed'
    end,
}, function()
    Executor.tick({ ownsAction = function() return true end })
    Executor.tick({ ownsAction = function() return true end })
end)
assert(custom.phase == 'completed' and customTicks == 1)

local timedOut = terminal({ kind = 'test', timeoutMs = 500 }, {
    dispatch = function() return true, 'started', 'custom' end,
}, function()
    Executor.tick({ ownsAction = function() return true end })
    clock = clock + 501
    Executor.tick({ ownsAction = function() return true end })
end)
assert(timedOut.phase == 'failed' and timedOut.reason == 'action_timeout')

print('executor_lifecycle_matrix_test: ok')
