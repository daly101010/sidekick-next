-- F:/lua/sidekick/utils/immune_database.lua
-- Immune Database - Persistent tracking of mob immunities per zone

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

-- Full database (all zones)
M.database = {}

-- Current zone's immunes (loaded into memory)
M.zoneImmunes = {}

-- Current zone name
M.currentZone = ''

-- Dirty flag for persistence
M.dirty = false

-- Lazy-load Paths module
local getPaths = lazy('sidekick-next.utils.paths')

-- Database file path
local function getDbPath()
    local Paths = getPaths()
    if Paths then
        return Paths.getImmuneDatabasePath()
    end
    return mq.configDir .. '/SideKick/immune_database.lua'
end

--- Load the full database from disk
function M.loadDatabase()
    -- Reset zone cache to force reload on next loadZone()
    M.currentZone = ''
    M.zoneImmunes = {}

    local path = getDbPath()
    local file = io.open(path, 'r')
    if not file then
        M.database = {}
        return
    end

    local content = file:read('*all')
    file:close()

    if content and content ~= '' then
        local fn = loadstring('return ' .. content)
        if fn then
            local ok, data = pcall(fn)
            if ok and type(data) == 'table' then
                M.database = data
                return
            end
        end
    end

    M.database = {}
end

--- Save the full database to disk
function M.saveDatabase()
    if not M.dirty then return end

    -- Ensure directory exists
    local Paths = getPaths()
    if Paths then
        Paths.ensureDir(Paths.getDataDir())
    else
        local dir = mq.configDir .. '/SideKick'
        os.execute('mkdir "' .. dir .. '" 2>nul')
    end

    local path = getDbPath()

    -- Escape special characters in strings for safe serialization
    local function escapeString(s)
        return s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r')
    end

    -- Simple serialization
    local function serialize(tbl, indent)
        indent = indent or ''
        local lines = {}
        table.insert(lines, '{')
        for k, v in pairs(tbl) do
            local key = type(k) == 'string' and ('["' .. escapeString(k) .. '"]') or ('[' .. k .. ']')
            if type(v) == 'table' then
                table.insert(lines, indent .. '  ' .. key .. ' = ' .. serialize(v, indent .. '  ') .. ',')
            elseif type(v) == 'boolean' then
                table.insert(lines, indent .. '  ' .. key .. ' = ' .. tostring(v) .. ',')
            else
                table.insert(lines, indent .. '  ' .. key .. ' = "' .. escapeString(tostring(v)) .. '",')
            end
        end
        table.insert(lines, indent .. '}')
        return table.concat(lines, '\n')
    end

    local content = serialize(M.database)
    local safeWrite = require('sidekick-next.utils.safe_write')
    local ok, err = safeWrite(path, content)
    if not ok then
        print(string.format('\ar[ImmuneDB]\ax Failed to save: %s', tostring(err)))
        return
    end
    M.dirty = false
end

--- Load current zone's immunes into memory
function M.loadZone()
    local zone = mq.TLO.Zone.ShortName() or ''
    if zone == M.currentZone then return end

    M.currentZone = zone
    M.zoneImmunes = M.database[zone] or {}
end

--- Check if a mob is immune to a category
-- @param mobName string Mob name
-- @param category string Immune category (slow, mez, fire, etc.)
-- @return boolean True if immune
function M.isImmune(mobName, category)
    if not mobName or mobName == '' then return false end
    if not category or category == '' then return false end

    local mobData = M.zoneImmunes[mobName]
    if not mobData then return false end

    return mobData[category:lower()] == true
end

--- Add an immune entry
-- @param mobName string Mob name
-- @param category string Immune category
function M.addImmune(mobName, category)
    if not mobName or mobName == '' then return end
    if not category or category == '' then return end

    local zone = M.currentZone
    if zone == '' then return end

    -- Ensure zone table exists
    if not M.database[zone] then
        M.database[zone] = {}
    end

    -- Ensure mob table exists
    if not M.database[zone][mobName] then
        M.database[zone][mobName] = {}
    end

    -- Add immune entry
    M.database[zone][mobName][category:lower()] = true

    -- Update memory cache
    M.zoneImmunes = M.database[zone]

    -- Mark dirty for save
    M.dirty = true
end

--- Initialize - load database and current zone
function M.init()
    M.loadDatabase()
    M.loadZone()
end

--- Shutdown - save database
function M.shutdown()
    M.saveDatabase()
end

return M
