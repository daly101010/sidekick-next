--- Lazy-require utility: eliminates duplicated pcall/require/cache boilerplate.
--- Returns a getter function that lazy-loads a module on first access.
---
--- Usage:
---   local lazy = require('sidekick-next.utils.lazy_require')
---
---   -- Retry mode (retries on failure each call, like Form A):
---   local getPaths = lazy('sidekick-next.utils.paths')
---
---   -- Once mode (tries once, returns nil forever after failure, like Form B/C):
---   local getMonitor = lazy.once('sidekick-next.healing.ui.monitor')

local _cache = {}      -- shared cache: modulePath -> loaded module (or false sentinel)
local _attempted = {}  -- tracks whether a once() path has been attempted

local lazy = {}

--- Retry mode: returns nil on failure, retries next call.
--- Replaces Form A pattern (underscore-prefixed, `if not _X` guard).
local function retryLoader(modulePath)
    return function()
        local cached = _cache[modulePath]
        if cached then return cached end
        if cached == false and _attempted[modulePath] then return nil end
        local ok, m = pcall(require, modulePath)
        if ok and m then
            _cache[modulePath] = m
            return m
        end
        return nil
    end
end

--- Once mode: tries once, returns nil forever on failure.
--- Replaces Form B (PascalCase + false sentinel) and Form C (loaded-flag boolean).
function lazy.once(modulePath)
    return function()
        if _attempted[modulePath] then
            local cached = _cache[modulePath]
            return cached or nil
        end
        _attempted[modulePath] = true
        local ok, m = pcall(require, modulePath)
        if ok and m then
            _cache[modulePath] = m
            return m
        end
        _cache[modulePath] = false
        return nil
    end
end

-- Make lazy callable as lazy('path') for retry mode, and indexable for lazy.once()
setmetatable(lazy, { __call = function(_, modulePath) return retryLoader(modulePath) end })

return lazy
