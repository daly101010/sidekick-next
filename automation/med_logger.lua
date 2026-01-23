-- automation/med_logger.lua
local mq = require('mq')

local M = {}

local _logFile = nil
local _logPath = nil
local _currentDate = nil
local _sessionId = nil
local _level = 'info'
local _enabled = true

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }

function M.init(opts)
    opts = opts or {}
    _sessionId = _sessionId or string.format('%s_%d', os.date('%H%M%S'), math.random(1000, 9999))
    if opts.level then
        _level = tostring(opts.level)
    end
    if opts.enabled ~= nil then
        _enabled = opts.enabled == true
    end
    M.ensureLogDir()
    M.rotate()
end

function M.setLevel(level)
    _level = tostring(level or _level)
end

function M.setEnabled(enabled)
    _enabled = enabled == true
end

function M.ensureLogDir()
    local configDir = mq.configDir or 'config'
    local logDir = configDir .. '/MedLogs'
    local ok, lfs = pcall(require, 'lfs')
    if ok and lfs and lfs.mkdir then
        lfs.mkdir(logDir)
    else
        os.execute('mkdir "' .. logDir .. '" 2>nul')
    end
    _logPath = logDir
end

function M.rotate()
    local today = os.date('%Y-%m-%d')
    if _currentDate == today and _logFile then return end

    if _logFile then
        _logFile:close()
    end

    _currentDate = today

    local charName = 'Unknown'
    local ok, name = pcall(function() return mq.TLO.Me.CleanName() end)
    if ok and name then charName = name end

    local server = 'Unknown'
    ok, name = pcall(function() return mq.TLO.EverQuest.Server() end)
    if ok and name then server = name:gsub(' ', '_') end

    local filename = string.format('%s/%s_%s_%s.log', _logPath, server, charName, today)

    local err
    _logFile, err = io.open(filename, 'a')
    if _logFile then
        M.info('session', '=== Med Session %s started ===', _sessionId)
    elseif err then
        print(string.format('[Med Logger] Failed to open %s: %s', filename, err))
    end
end

local function shouldLog(level)
    if not _enabled then return false end
    local configLevel = LEVELS[_level] or 2
    local msgLevel = LEVELS[level] or 2
    return msgLevel >= configLevel
end

local function write(level, category, fmt, ...)
    if not shouldLog(level) then return end
    M.rotate()
    if not _logFile then return end

    local timestamp = os.date('%H:%M:%S')
    local msg
    if select('#', ...) > 0 then
        local ok, result = pcall(string.format, fmt, ...)
        msg = ok and result or tostring(fmt)
    else
        msg = tostring(fmt)
    end
    local line = string.format('[%s][%s][%s] %s\n', timestamp, level:upper(), category or 'general', msg)
    _logFile:write(line)
    _logFile:flush()
end

function M.debug(category, fmt, ...) write('debug', category, fmt, ...) end
function M.info(category, fmt, ...) write('info', category, fmt, ...) end
function M.warn(category, fmt, ...) write('warn', category, fmt, ...) end
function M.error(category, fmt, ...) write('error', category, fmt, ...) end

function M.shutdown()
    if _logFile then
        M.info('session', '=== Med Session %s ended ===', _sessionId)
        _logFile:close()
        _logFile = nil
    end
end

return M
