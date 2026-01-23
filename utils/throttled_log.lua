-- F:/lua/SideKick/utils/throttled_log.lua
-- Throttled logging utility to prevent console spam
-- Each log key can only fire once per interval

local mq = require('mq')

local M = {}

-- Default throttle interval in seconds
M.defaultInterval = 5

-- State tracking for throttled messages
M._lastLogTime = {}

--- Log a message if not throttled
-- @param key string Unique key for this log message (used for throttling)
-- @param interval number Optional interval in seconds (default: M.defaultInterval)
-- @param format string Format string for message
-- @param ... Additional arguments for format
-- @return boolean True if message was logged, false if throttled
function M.log(key, interval, format, ...)
    local now = os.clock()
    interval = interval or M.defaultInterval

    local lastTime = M._lastLogTime[key] or 0
    if now - lastTime < interval then
        return false
    end

    M._lastLogTime[key] = now

    -- In-game echo disabled
    return true
end

--- Log with default interval
-- @param key string Unique key for this log message
-- @param format string Format string for message
-- @param ... Additional arguments for format
-- @return boolean True if message was logged
function M.logDefault(key, format, ...)
    return M.log(key, M.defaultInterval, format, ...)
end

--- Log immediately (no throttle)
-- @param format string Format string for message
-- @param ... Additional arguments for format
function M.logImmediate(format, ...)
    -- In-game echo disabled
end

--- Check if a key is currently throttled
-- @param key string Log key
-- @param interval number Optional interval to check against
-- @return boolean True if throttled (would not log)
function M.isThrottled(key, interval)
    local now = os.clock()
    interval = interval or M.defaultInterval
    local lastTime = M._lastLogTime[key] or 0
    return (now - lastTime) < interval
end

--- Clear throttle for a specific key
-- @param key string Log key to clear
function M.clearKey(key)
    M._lastLogTime[key] = nil
end

--- Clear all throttle state
function M.clearAll()
    M._lastLogTime = {}
end

--- Set default interval
-- @param seconds number New default interval
function M.setDefaultInterval(seconds)
    M.defaultInterval = seconds
end

-- Debug logging (can be enabled/disabled)
M.debugEnabled = false

--- Log debug message if debug is enabled
-- @param key string Unique key for throttling
-- @param format string Format string for message
-- @param ... Additional arguments for format
-- @return boolean True if message was logged
function M.debug(key, format, ...)
    if not M.debugEnabled then return false end
    return M.log(key, M.defaultInterval, "[DEBUG] " .. format, ...)
end

--- Enable or disable debug logging
-- @param enabled boolean
function M.setDebug(enabled)
    M.debugEnabled = enabled == true
end

return M
