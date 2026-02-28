--- Unified Logger for SideKick
--- Provides leveled logging with console + file output, caller tracing, and filtering.
---
--- Usage:
---   local Logger = require('sidekick-next.utils.logger')
---   local log = Logger.new('MyModule')
---   log.error('Failed to load: %s', err)
---   log.warn('Missing spell: %s', name)
---   log.info('Loaded %d spells', count)
---   log.debug('Checking target %d', id)
---   log.verbose('Cache hit for %s', key)
---
--- Global controls:
---   Logger.setLevel(4)              -- 1=error .. 5=verbose
---   Logger.setFilter('heal|spell')  -- pipe-separated pattern match
---   Logger.setFileLogging(true)     -- enable file output

local mq = require('mq')

local M = {}

-- ============================================================
-- LOG LEVELS
-- ============================================================

local LEVELS = {
    error   = { num = 1, tag = 'ERROR  ', color = '\ar' },
    warn    = { num = 2, tag = 'WARN   ', color = '\ay' },
    info    = { num = 3, tag = 'INFO   ', color = '\ao' },
    debug   = { num = 4, tag = 'DEBUG  ', color = '\am' },
    verbose = { num = 5, tag = 'VERBOSE', color = '\ap' },
}

-- ============================================================
-- GLOBAL STATE
-- ============================================================

local _globalLevel = 3        -- Default: info and above
local _consoleLevel = nil     -- nil = same as _globalLevel
local _fileLevel = nil        -- nil = same as _globalLevel
local _filter = nil           -- nil = no filter
local _fileLogging = false    -- File logging off by default
local _fileHandle = nil       -- Lazy file handle
local _filePath = nil         -- Current log file path
local _fileDate = nil         -- Date for log rotation
local _tracerEnabled = true   -- Caller tracing on by default
local _scriptLabel = 'SK'     -- Short script prefix for console output

-- ============================================================
-- GLOBAL CONTROL API
-- ============================================================

--- Set the global minimum log level (1=error, 2=warn, 3=info, 4=debug, 5=verbose)
function M.setLevel(level)
    _globalLevel = math.max(1, math.min(5, tonumber(level) or 3))
end

--- Get the current global log level
function M.getLevel()
    return _globalLevel
end

--- Set minimum level for console output (nil = use global level)
function M.setConsoleLevel(level)
    _consoleLevel = level and math.max(1, math.min(5, tonumber(level) or 3)) or nil
end

--- Set minimum level for file output (nil = use global level)
function M.setFileLevel(level)
    _fileLevel = level and math.max(1, math.min(5, tonumber(level) or 3)) or nil
end

--- Set a pipe-separated filter pattern. Only messages matching the pattern are shown.
--- Pass nil to clear the filter.
function M.setFilter(pattern)
    _filter = pattern
end

--- Enable or disable file logging
function M.setFileLogging(enabled)
    _fileLogging = enabled
    if not enabled and _fileHandle then
        _fileHandle:close()
        _fileHandle = nil
    end
end

--- Enable or disable caller tracing (file::func():line)
function M.setTracerEnabled(enabled)
    _tracerEnabled = enabled
end

--- Set the script label prefix for console output (default: 'SK')
function M.setScriptLabel(label)
    _scriptLabel = label or 'SK'
end

-- ============================================================
-- INTERNAL HELPERS
-- ============================================================

--- Get caller info from the call stack
--- @param stackDepth number Frames to skip (caller of log function)
local function getCallerInfo(stackDepth)
    if not _tracerEnabled then return '' end

    local info = debug.getinfo(stackDepth, 'Snl')
    if not info then return '' end

    local file = 'unknown'
    if info.short_src then
        file = info.short_src:match('[^\\^/]*.lua$') or info.short_src:match('[^\\^/]*$') or 'unknown'
    end
    local func = info.name or '?'
    local line = info.currentline or 0

    return string.format(' \aw(\at%s\aw::\at%s()\aw:\at%d\aw)', file, func, line)
end

--- Get or create the file handle for today's log
local function getFileHandle()
    if not _fileLogging then return nil end

    local today = os.date('%Y-%m-%d')
    if _fileDate == today and _fileHandle then
        return _fileHandle
    end

    -- Close old handle if date changed
    if _fileHandle then
        _fileHandle:close()
        _fileHandle = nil
    end

    _fileDate = today

    -- Build log path using Paths module if available
    local ok, Paths = pcall(require, 'sidekick-next.utils.paths')
    if ok and Paths then
        _filePath = Paths.getLogPath('debug', today)
    else
        -- Fallback: write to mq.configDir directly
        local charName = 'Character'
        local cOk, cName = pcall(function() return mq.TLO.Me.CleanName() end)
        if cOk and cName then charName = cName end
        _filePath = string.format('%s/SideKick_%s_%s.log', mq.configDir, charName, today)
    end

    _fileHandle = io.open(_filePath, 'a')
    if _fileHandle then
        _fileHandle:write(string.format('\n=== SideKick Logger started %s ===\n', os.date('%Y-%m-%d %H:%M:%S')))
        _fileHandle:flush()
    end

    return _fileHandle
end

--- Format message safely (handles missing varargs, bad format strings)
local function formatMessage(fmt, ...)
    if select('#', ...) == 0 then
        return tostring(fmt)
    end
    local ok, result = pcall(string.format, fmt, ...)
    return ok and result or tostring(fmt)
end

--- Strip MQ color codes for file output
local function stripColors(text)
    return text:gsub('\a.', '')
end

--- Check if a message passes the current filter
local function passesFilter(moduleName, message)
    if not _filter or _filter == '' then return true end

    local combined = (moduleName or '') .. ' ' .. (message or '')
    combined = combined:lower()
    local filterLower = _filter:lower()

    for pattern in filterLower:gmatch('[^|]+') do
        pattern = pattern:match('^%s*(.-)%s*$')  -- trim
        if pattern ~= '' and combined:find(pattern, 1, true) then
            return true
        end
    end

    return false
end

-- ============================================================
-- CORE LOG FUNCTION
-- ============================================================

--- Write a log message at the given level
--- @param levelName string Level name (error, warn, info, debug, verbose)
--- @param moduleName string Module name for context
--- @param depthOffset number Extra stack frames to skip for caller tracing (default 0)
--- @param fmt string Format string
--- @param ... any Format arguments
local function writeLog(levelName, moduleName, depthOffset, fmt, ...)
    local levelDef = LEVELS[levelName]
    if not levelDef then return end

    local levelNum = levelDef.num
    local message = formatMessage(fmt, ...)

    -- Check filter
    if not passesFilter(moduleName, message) then return end

    -- Console output
    local consoleMin = _consoleLevel or _globalLevel
    if levelNum <= consoleMin then
        -- Stack: getCallerInfo → writeLog → log.X → caller = depth 4 + depthOffset
        local callerInfo = getCallerInfo(4 + (depthOffset or 0))
        local consoleLine = string.format('%s[%s]\ax \aw[\at%s\aw]%s %s%s\ax',
            levelDef.color, _scriptLabel,
            moduleName or '?',
            callerInfo,
            levelDef.color, message)
        printf(consoleLine)
    end

    -- File output
    local fileMin = _fileLevel or _globalLevel
    if levelNum <= fileMin then
        local fh = getFileHandle()
        if fh then
            local timestamp = os.date('%H:%M:%S')
            local fileLine = string.format('[%s][%s][%s] %s\n',
                timestamp, levelDef.tag, moduleName or '?', stripColors(message))
            fh:write(fileLine)
            fh:flush()
        end
    end
end

-- ============================================================
-- LOGGER INSTANCE FACTORY
-- ============================================================

--- Create a new logger instance for a module.
--- @param moduleName string Human-readable module name (e.g., 'HealSelector', 'Coordinator')
--- @param depthOffset? number Extra stack frames for caller tracing (default 0). Use 1 for wrappers.
--- @return table Logger instance with error/warn/info/debug/verbose methods
function M.new(moduleName, depthOffset)
    depthOffset = depthOffset or 0
    local logger = {}

    function logger.error(fmt, ...) writeLog('error', moduleName, depthOffset, fmt, ...) end
    function logger.warn(fmt, ...)  writeLog('warn',  moduleName, depthOffset, fmt, ...) end
    function logger.info(fmt, ...)  writeLog('info',  moduleName, depthOffset, fmt, ...) end
    function logger.debug(fmt, ...) writeLog('debug', moduleName, depthOffset, fmt, ...) end
    function logger.verbose(fmt, ...) writeLog('verbose', moduleName, depthOffset, fmt, ...) end

    --- Check if a level would produce output (for expensive message construction)
    function logger.isLevel(level)
        local maxLevel = math.max(_consoleLevel or _globalLevel, _fileLevel or _globalLevel)
        return (LEVELS[level] and LEVELS[level].num or 99) <= maxLevel
    end

    return logger
end

-- ============================================================
-- CONVENIENCE: Module-level logger (backward compat with debug_log patterns)
-- ============================================================

--- Shortcut: create a logger and return just the info-level function.
--- Drop-in replacement for debug_log.tagged() callers.
--- @param tag string Module tag
--- @return fun(fmt: string, ...: any) Info-level log function
function M.tagged(tag)
    local log = M.new(tag)
    return log.info
end

-- ============================================================
-- SHUTDOWN
-- ============================================================

function M.shutdown()
    if _fileHandle then
        _fileHandle:write(string.format('=== SideKick Logger stopped %s ===\n', os.date('%Y-%m-%d %H:%M:%S')))
        _fileHandle:close()
        _fileHandle = nil
    end
end

return M
