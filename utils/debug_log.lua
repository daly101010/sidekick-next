--- Debug logging factory: eliminates duplicated debugLog/clearLogFile boilerplate.
---
--- Two modes:
---   1. Centralized (Pattern A) - logs to Paths.getLogPath('debug'), tagged
---   2. Per-module  (Pattern B) - logs to mq.configDir/<name>_debug.log, with enable flag + startup clear
---
--- Usage:
---   local debugLog = require('sidekick-next.utils.debug_log')
---
---   -- Pattern A: centralized debug log with tag
---   local log = debugLog.tagged('Main', 'SideKick_Debug.log')
---   log('something happened: %s', detail)
---
---   -- Pattern B: per-module log with startup clear
---   local log = debugLog.module('sk_coordinator', 'SK_COORDINATOR')
---   log('tick %d', tickId)

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local getPaths = lazy('sidekick-next.utils.paths')

local M = {}

--- Pattern A: tagged centralized log.
--- @param tag string  Bracket tag like 'Main', 'Heal', 'SpellEngine', 'Med'
--- @param fallbackFile string  Fallback filename if Paths unavailable
--- @return fun(fmt: string, ...: any)
function M.tagged(tag, fallbackFile)
    return function(fmt, ...)
        local msg = string.format(fmt, ...)
        local Paths = getPaths()
        local logPath = Paths and Paths.getLogPath('debug') or (mq.configDir .. '/' .. fallbackFile)
        local f = io.open(logPath, 'a')
        if f then
            f:write(string.format('[%s] [%s] %s\n', os.date('%H:%M:%S'), tag, msg))
            f:close()
        end
    end
end

--- Pattern B: per-module debug log with enable flag and startup clear.
--- @param filename string  Log filename without path (e.g. 'sk_coordinator_debug.log')
--- @param header string  Header label for startup line (e.g. 'SK_COORDINATOR')
--- @param enabled? boolean  Enable flag (default true)
--- @return fun(fmt: string, ...: any)
function M.module(filename, header, enabled)
    if enabled == nil then enabled = true end
    local logPath = mq.configDir .. '/' .. filename .. '_debug.log'
    -- Clear log on creation
    local f = io.open(logPath, 'w')
    if f then
        f:write(string.format('=== %s DEBUG LOG STARTED %s ===\n', header, os.date('%Y-%m-%d %H:%M:%S')))
        f:close()
    end
    return function(fmt, ...)
        if not enabled then return end
        local msg = string.format(fmt, ...)
        local fh = io.open(logPath, 'a')
        if fh then
            fh:write(string.format('[%s] %s\n', os.date('%H:%M:%S'), msg))
            fh:close()
        end
    end
end

--- Pattern B variant: per-module with a tag per-call (like sk_module_base).
--- @param filename string  Log filename without path
--- @param header string  Header label for startup line
--- @param enabled? boolean  Enable flag (default true)
--- @return fun(moduleName: string, fmt: string, ...: any)
function M.moduleTagged(filename, header, enabled)
    if enabled == nil then enabled = true end
    local logPath = mq.configDir .. '/' .. filename .. '_debug.log'
    -- Clear log on creation
    local f = io.open(logPath, 'w')
    if f then
        f:write(string.format('=== %s DEBUG LOG STARTED %s ===\n', header, os.date('%Y-%m-%d %H:%M:%S')))
        f:close()
    end
    return function(moduleName, fmt, ...)
        if not enabled then return end
        local msg = string.format(fmt, ...)
        local fh = io.open(logPath, 'a')
        if fh then
            fh:write(string.format('[%s] [%s] %s\n', os.date('%H:%M:%S'), moduleName, msg))
            fh:close()
        end
    end
end

return M
