package.path = '../?.lua;../?/init.lua;' .. package.path

package.preload.mq = function()
    return {
        gettime = function() return 1000 end,
        TLO = {},
    }
end

local expected = {
    'emergency', 'support', 'tank', 'combat', 'pull', 'chase',
    'maintenance', 'items', 'meditation', 'scribing',
}

_G.SIDEKICK_NEXT_CONFIG = nil
package.loaded['sidekick-next.config'] = nil
package.loaded['sidekick-next.sk_lib'] = nil
local lib = require('sidekick-next.sk_lib')
assert(lib.WorkerProfile == 'consolidated')
assert(#lib.WorkerRegistry == 10)
for index, name in ipairs(expected) do
    assert(lib.WorkerRegistry[index].module == name,
        string.format('worker %d: expected %s, got %s',
            index, name, tostring(lib.WorkerRegistry[index].module)))
end
assert(lib.getActiveWorkerSpec('fidget') == nil)
assert(lib.getActiveWorkerSpec('healing') == nil)
assert(lib.getWorkerSpec('healing') ~= nil)

_G.SIDEKICK_NEXT_CONFIG.CONSOLIDATED_WORKERS = false
package.loaded['sidekick-next.sk_lib'] = nil
lib = require('sidekick-next.sk_lib')
assert(lib.WorkerProfile == 'legacy')
assert(#lib.WorkerRegistry == 18)
assert(lib.getActiveWorkerSpec('healing') ~= nil)
assert(lib.getActiveWorkerSpec('support') == nil)
assert(lib.getActiveWorkerSpec('fidget') == nil)

print('worker_profile_test: ok')
