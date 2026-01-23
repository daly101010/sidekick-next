-- utils/paths.lua
-- Centralized path management for SideKick
-- All config and log paths are consolidated under mq.configDir/SideKick/

local mq = require('mq')

local M = {}

-- Cache for character info (computed once per session)
local _charName = nil
local _serverName = nil

--- Get character and server info (cached)
local function getCharInfo()
    if not _charName then
        local ok, name = pcall(function() return mq.TLO.Me.CleanName() end)
        _charName = (ok and name) or 'Character'
    end
    if not _serverName then
        local ok, server = pcall(function() return mq.TLO.EverQuest.Server() end)
        _serverName = (ok and server) and server:gsub(' ', '_') or 'Server'
    end
    return _charName, _serverName
end

--- Get the root SideKick directory
function M.getRootDir()
    return mq.configDir .. '/SideKick'
end

--- Get the config directory
function M.getConfigDir()
    return M.getRootDir() .. '/config'
end

--- Get the healing subdirectory
function M.getHealingDir()
    return M.getRootDir() .. '/healing'
end

--- Get the data directory (for shared data like immune database)
function M.getDataDir()
    return M.getRootDir() .. '/data'
end

--- Get the logs root directory
function M.getLogsDir()
    return M.getRootDir() .. '/logs'
end

--- Get a specific log subdirectory
-- @param category string Log category (healing, med, buff)
function M.getLogDir(category)
    return M.getLogsDir() .. '/' .. (category or 'general')
end

--- Ensure a directory exists (creates parent dirs as needed)
-- @param path string Directory path to create
function M.ensureDir(path)
    -- Try lfs first for cleaner creation
    local ok, lfs = pcall(require, 'lfs')
    if ok and lfs and lfs.mkdir then
        -- Create parent directories iteratively
        local parts = {}
        for part in path:gmatch('[^/\\]+') do
            table.insert(parts, part)
        end
        local current = ''
        for _, part in ipairs(parts) do
            current = current .. part .. '/'
            lfs.mkdir(current)
        end
    else
        -- Fallback to os.execute with mkdir -p equivalent for Windows
        os.execute('mkdir "' .. path .. '" 2>nul')
    end
end

-------------------------------------------------------------------------------
-- Config File Paths
-------------------------------------------------------------------------------

--- Get the main INI config path
-- Path: SideKick/config/<Server>_<CharName>.ini
function M.getMainConfigPath()
    local char, server = getCharInfo()
    M.ensureDir(M.getConfigDir())
    return string.format('%s/%s_%s.ini', M.getConfigDir(), server, char)
end

--- Get the healing config path
-- Path: SideKick/healing/config_<Server>_<CharName>.lua
function M.getHealingConfigPath()
    local char, server = getCharInfo()
    M.ensureDir(M.getHealingDir())
    return string.format('%s/config_%s_%s.lua', M.getHealingDir(), server, char)
end

--- Get the healing learned data path
-- Path: SideKick/healing/data_<Server>_<CharName>.lua
function M.getHealingDataPath()
    local char, server = getCharInfo()
    M.ensureDir(M.getHealingDir())
    return string.format('%s/data_%s_%s.lua', M.getHealingDir(), server, char)
end

--- Get the immune database path
-- Path: SideKick/data/immune_database.lua
function M.getImmuneDatabasePath()
    M.ensureDir(M.getDataDir())
    return M.getDataDir() .. '/immune_database.lua'
end

-------------------------------------------------------------------------------
-- Log File Paths
-------------------------------------------------------------------------------

--- Get a log file path for a given category
-- Path: SideKick/logs/<category>/<Server>_<CharName>_<date>.log
-- @param category string Log category (healing, med, buff, debug)
-- @param date string Optional date string (defaults to today YYYY-MM-DD)
function M.getLogPath(category, date)
    local char, server = getCharInfo()
    local logDir = M.getLogDir(category)
    M.ensureDir(logDir)
    date = date or os.date('%Y-%m-%d')
    return string.format('%s/%s_%s_%s.log', logDir, server, char, date)
end

--- Get the healing log directory
function M.getHealingLogDir()
    local dir = M.getLogDir('healing')
    M.ensureDir(dir)
    return dir
end

--- Get the meditation log directory
function M.getMedLogDir()
    local dir = M.getLogDir('med')
    M.ensureDir(dir)
    return dir
end

--- Get the buff log directory
function M.getBuffLogDir()
    local dir = M.getLogDir('buff')
    M.ensureDir(dir)
    return dir
end

--- Get the debug log directory
function M.getDebugLogDir()
    local dir = M.getLogDir('debug')
    M.ensureDir(dir)
    return dir
end

-------------------------------------------------------------------------------
-- Migration Support
-------------------------------------------------------------------------------

--- Check if old config files exist and need migration
-- @return table List of files that need migration with {old, new} paths
function M.checkMigrationNeeded()
    local char, server = getCharInfo()
    local migrations = {}

    -- Old main config path
    local oldMain = string.format('%s/%s_%s_SideKick.ini', mq.configDir, server, char)
    local newMain = M.getMainConfigPath()
    local f = io.open(oldMain, 'r')
    if f then
        f:close()
        table.insert(migrations, { old = oldMain, new = newMain, type = 'main_config' })
    end

    -- Old healing config path
    local oldHealConfig = string.format('%s/SideKick_Healing_%s_%s.lua', mq.configDir, server, char)
    local newHealConfig = M.getHealingConfigPath()
    f = io.open(oldHealConfig, 'r')
    if f then
        f:close()
        table.insert(migrations, { old = oldHealConfig, new = newHealConfig, type = 'healing_config' })
    end

    -- Old healing data path
    local oldHealData = string.format('%s/SideKick_HealData_%s_%s.lua', mq.configDir, server, char)
    local newHealData = M.getHealingDataPath()
    f = io.open(oldHealData, 'r')
    if f then
        f:close()
        table.insert(migrations, { old = oldHealData, new = newHealData, type = 'healing_data' })
    end

    -- Old immune database path
    local oldImmune = mq.configDir .. '/SideKick/immune_database.lua'
    local newImmune = M.getImmuneDatabasePath()
    f = io.open(oldImmune, 'r')
    if f then
        f:close()
        -- Only migrate if paths are different
        if oldImmune ~= newImmune then
            table.insert(migrations, { old = oldImmune, new = newImmune, type = 'immune_db' })
        end
    end

    return migrations
end

--- Migrate a single file from old to new location
-- @param oldPath string Old file path
-- @param newPath string New file path
-- @return boolean True if migration succeeded
function M.migrateFile(oldPath, newPath)
    -- Read old file
    local oldFile = io.open(oldPath, 'r')
    if not oldFile then
        return false
    end
    local content = oldFile:read('*a')
    oldFile:close()

    -- Ensure destination directory exists
    local dir = newPath:match('^(.+)[/\\][^/\\]+$')
    if dir then
        M.ensureDir(dir)
    end

    -- Write to new location
    local newFile = io.open(newPath, 'w')
    if not newFile then
        return false
    end
    newFile:write(content)
    newFile:close()

    return true
end

--- Run all pending migrations
-- @return table Results { migrated = count, failed = count, details = {} }
function M.runMigrations()
    local migrations = M.checkMigrationNeeded()
    local results = { migrated = 0, failed = 0, details = {} }

    for _, m in ipairs(migrations) do
        local success = M.migrateFile(m.old, m.new)
        if success then
            results.migrated = results.migrated + 1
            table.insert(results.details, { type = m.type, status = 'migrated', from = m.old, to = m.new })
        else
            results.failed = results.failed + 1
            table.insert(results.details, { type = m.type, status = 'failed', from = m.old, to = m.new })
        end
    end

    return results
end

return M
