--- Safe call utilities for SideKick
--- Provides consistent error handling with Logger integration.
---
--- Usage:
---   local safe = require('sidekick-next.utils.safe')
---   safe.call('Loading config', function() ... end)           -- logs error, returns false
---   safe.callOr(0, 'TLO query', function() return val end)   -- returns 0 on error
---   local wrappedFn = safe.wrap('Module.tick', module.tick)   -- returns safe wrapper

local Logger = require('sidekick-next.utils.logger')
local log = Logger.new('Safe')

local M = {}

--- Call a function safely. On error, logs the error and returns false.
--- @param context string Description of what's being called (for error messages)
--- @param fn function The function to call
--- @param ... any Arguments to pass to fn
--- @return any Result of fn, or false on error
function M.call(context, fn, ...)
    if not fn then
        log.warn('%s: fn is nil (no-op)', context)
        return false
    end

    local ok, result = pcall(fn, ...)
    if not ok then
        log.error('%s: %s', context, tostring(result))
        return false
    end
    return result
end

--- Call a function safely, returning a default value on error.
--- @param default any Value to return on error
--- @param context string Description of what's being called
--- @param fn function The function to call
--- @param ... any Arguments to pass to fn
--- @return any Result of fn, or default on error
function M.callOr(default, context, fn, ...)
    if not fn then return default end

    local ok, result = pcall(fn, ...)
    if not ok then
        log.error('%s: %s', context, tostring(result))
        return default
    end
    return result
end

--- Wrap a function so that it catches errors and logs them.
--- Returns a new function that can be called like the original.
--- @param context string Description for error messages
--- @param fn function The function to wrap
--- @return function Wrapped function that catches errors
function M.wrap(context, fn)
    if not fn then
        return function() end
    end
    return function(...)
        local ok, result = pcall(fn, ...)
        if not ok then
            log.error('%s: %s', context, tostring(result))
            return false
        end
        return result
    end
end

return M
