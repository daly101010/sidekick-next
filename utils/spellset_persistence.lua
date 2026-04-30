-- utils/spellset_persistence.lua
-- Spell Set Persistence Module
-- Handles saving/loading spell sets to disk using mq.pickle()

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')
local SafeLoad = require('sidekick-next.utils.safe_load')

local M = {}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

M.spellSets = {}       -- Dictionary of spell sets by name {[name] = SpellSet}
M.activeSetName = nil  -- Currently active set name
M.loaded = false       -- True after a load attempt for the current character path
M.loadError = nil      -- Non-nil when the on-disk file exists but failed to load
M.pathError = nil      -- Non-nil when character/server identity is not ready

--------------------------------------------------------------------------------
-- Lazy-loaded dependencies
--------------------------------------------------------------------------------

local getSpellSetData = lazy('sidekick-next.utils.spellset_data')
local getConditionBuilder = lazy('sidekick-next.ui.condition_builder')
local getPaths = lazy('sidekick-next.utils.paths')

local _lastConfigPath = nil

local function fileExists(path)
    local f = io.open(path, 'r')
    if f then
        f:close()
        return true
    end
    return false
end

local function countSets(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

--------------------------------------------------------------------------------
-- Path Helpers
--------------------------------------------------------------------------------

--- Get the config path for spell sets
--- Path: mq.configDir/SideKick/Server_CharName_spellsets.lua
---@return string The full path to the spell sets config file
function M.getConfigPath()
    M.pathError = nil

    -- Get server name
    local ok, s = pcall(function() return mq.TLO.EverQuest.Server() end)
    local server = ok and tostring(s or ''):gsub(' ', '_') or ''
    if server == '' or server:lower() == 'null' then
        M.pathError = 'server_not_ready'
        return _lastConfigPath
    end

    -- Get character name
    ok, s = pcall(function() return mq.TLO.Me.CleanName() end)
    local charName = ok and tostring(s or '') or ''
    if charName == '' or charName:lower() == 'null' then
        M.pathError = 'character_not_ready'
        return _lastConfigPath
    end

    -- Ensure SideKick directory exists
    local Paths = getPaths()
    local baseDir = mq.configDir .. '/SideKick'
    if Paths and Paths.ensureDir then
        Paths.ensureDir(baseDir)
    else
        -- Fallback: try to create directory
        os.execute('mkdir "' .. baseDir .. '" 2>nul')
    end

    _lastConfigPath = string.format('%s/%s_%s_spellsets.lua', baseDir, server, charName)
    return _lastConfigPath
end

--------------------------------------------------------------------------------
-- Serialization Helpers
--------------------------------------------------------------------------------

--- Serialize a Lua value to a string representation (fallback serializer)
---@param val any The value to serialize
---@return string The serialized string
local function serializeValueFallback(val)
    local t = type(val)

    if t == "nil" then
        return "nil"
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "number" then
        return tostring(val)
    elseif t == "string" then
        return string.format("%q", val)
    elseif t == "table" then
        local parts = {}
        local isArray = true
        local maxIdx = 0

        for k, _ in pairs(val) do
            if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then
                isArray = false
                break
            end
            if k > maxIdx then maxIdx = k end
        end

        if isArray then
            for i = 1, maxIdx do
                if val[i] == nil then
                    isArray = false
                    break
                end
            end
        end

        if isArray and maxIdx > 0 then
            for i = 1, maxIdx do
                table.insert(parts, serializeValueFallback(val[i]))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        else
            for k, v in pairs(val) do
                local keyStr
                if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                    keyStr = k
                else
                    keyStr = "[" .. serializeValueFallback(k) .. "]"
                end
                table.insert(parts, keyStr .. "=" .. serializeValueFallback(v))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    else
        return "nil"
    end
end

--- Serialize condition data for storage
---@param condition table|nil The condition data
---@return string|nil Serialized condition string or nil
local function serializeCondition(condition)
    if not condition then return nil end

    -- Try condition_builder.serialize first
    local ConditionBuilder = getConditionBuilder()
    if ConditionBuilder and ConditionBuilder.serialize then
        local ok, result = pcall(ConditionBuilder.serialize, condition)
        if ok and result and result ~= '' then
            return result
        end
    end

    -- Fallback: use our own serializer
    local ok, result = pcall(serializeValueFallback, condition)
    if ok and result and result ~= '' then
        return result
    end

    return nil
end

--- Deserialize condition data from storage
---@param str string|nil The serialized condition string
---@return table|nil The deserialized condition data
local function deserializeCondition(str)
    if not str or str == '' then return nil end

    -- Try condition_builder.deserialize first
    local ConditionBuilder = getConditionBuilder()
    if ConditionBuilder and ConditionBuilder.deserialize then
        local ok, result = pcall(ConditionBuilder.deserialize, str)
        if ok and result then
            return result
        end
    end

    -- Fallback: try to load as Lua
    local fn, err = load('return ' .. str, 'condition', 't', {})
    if fn then
        local ok, data = pcall(fn)
        if ok and type(data) == 'table' then
            return data
        end
    end

    return nil
end

--------------------------------------------------------------------------------
-- Save/Load Functions
--------------------------------------------------------------------------------

--- Save all spell sets to disk
--- Creates data table with version=2, activeSet, sets
--- For each spell set, serializes gems and oocBuffs
--- Uses mq.pickle(path, data) to write
function M.save()
    local path = M.getConfigPath()
    if not path or M.pathError then
        print(string.format('\ar[SpellSetPersistence]\ax Refusing to save: %s', tostring(M.pathError or 'no_config_path')))
        return false
    end

    -- Several UI/module paths can reach Persistence.save() lazily. If that
    -- happens before Persistence.load(), the module still contains its initial
    -- empty tables and saving would overwrite the user's spell-set file with a
    -- blank/default set. Force load first, and refuse to save over a file that
    -- failed to parse.
    if not M.loaded then
        if countSets(M.spellSets) == 0 then
            M.load()
        else
            print('\ar[SpellSetPersistence]\ax Refusing to save spell sets before loading existing data')
            return false
        end
    end

    if M.loadError then
        print(string.format('\ar[SpellSetPersistence]\ax Refusing to save because load failed: %s', tostring(M.loadError)))
        return false
    end

    -- Count sets for debug output
    local setCount = countSets(M.spellSets)
    -- print(string.format('\\ay[SpellSetPersistence]\\ax Saving %d spell set(s) to: %s', setCount, path))

    -- Build data structure for persistence
    local data = {
        version = 2,
        activeSet = M.activeSetName,
        sets = {},
    }

    -- Serialize each spell set
    for name, spellSet in pairs(M.spellSets) do
        -- print(string.format('\\ay[SpellSetPersistence]\\ax   - Serializing set: "%s"', name))
        local setData = {
            name = spellSet.name,
            gems = {},
            oocBuffs = {},
        }

        -- Serialize gems
        if spellSet.gems then
            for slot, gemConfig in pairs(spellSet.gems) do
                setData.gems[slot] = {
                    spellId = gemConfig.spellId,
                    condition = serializeCondition(gemConfig.condition),
                    priority = gemConfig.priority,
                    buffTarget = gemConfig.buffTarget,
                }
            end
        end

        -- Serialize oocBuffs
        if spellSet.oocBuffs then
            for i, buffConfig in ipairs(spellSet.oocBuffs) do
                setData.oocBuffs[i] = {
                    spellId = buffConfig.spellId,
                    enabled = buffConfig.enabled,
                    priority = buffConfig.priority,
                    condition = serializeCondition(buffConfig.condition),
                    buffTarget = buffConfig.buffTarget,
                }
            end
        end

        data.sets[name] = setData
    end

    -- Keep a last-known-good backup before overwriting. This is intentionally
    -- best-effort; failure to copy the backup should not block normal saves.
    if fileExists(path) then
        pcall(function()
            local src = io.open(path, 'r')
            if not src then return end
            local content = src:read('*all')
            src:close()
            local dst = io.open(path .. '.bak', 'w')
            if not dst then return end
            dst:write(content or '')
            dst:close()
        end)
    end

    -- Write to file using mq.pickle
    local ok, err = pcall(function()
        mq.pickle(path, data)
    end)

    if not ok then
        print(string.format('\ar[SpellSetPersistence]\ax Save failed: %s', tostring(err)))
        return false
    end

    -- Count saved sets for confirmation
    local savedCount = 0
    for _ in pairs(data.sets) do
        savedCount = savedCount + 1
    end
    -- print(string.format('\ag[SpellSetPersistence]\ax Save complete: %d set(s) saved successfully', savedCount))

    return true
end

--- Load spell sets from disk
--- Loads saved spellset data from a table literal file.
--- Deserializes conditions
--- If load fails or empty, creates "Default" set
--- Ensures activeSetName points to valid set
function M.load()
    local path = M.getConfigPath()
    if not path or M.pathError then
        M.loaded = false
        M.loadError = tostring(M.pathError or 'no_config_path')
        return false
    end
    -- print(string.format('\\ay[SpellSetPersistence]\\ax Loading spell sets from: %s', path))
    M.loaded = false
    M.loadError = nil

    -- Probe for file existence before dofile so the normal "first-run, no
    -- saved sets" case stays silent. A red error should only fire for actual
    -- parse/format problems, not for the expected absence of the file.
    local fh = io.open(path, 'r')
    if not fh then
        -- No file yet — treat as "no sets saved". Fall through to the
        -- default-set bootstrap below.
    else
        fh:close()
    end

    local data = nil
    if fh then
        local content
        do
            local f = io.open(path, 'r')
            if f then
                content = f:read('*all')
                f:close()
            end
        end
        local result, err = SafeLoad.tableLiteral(content, path)
        if type(result) == 'table' then
            data = result
        else
            -- File exists but failed to parse — this IS an error worth surfacing.
            print(string.format('\\ar[SpellSetPersistence]\\ax Failed to load: %s', tostring(err)))
            M.loadError = tostring(err or 'unknown error')
            if fileExists(path .. '.bak') then
                local backupContent
                local bf = io.open(path .. '.bak', 'r')
                if bf then
                    backupContent = bf:read('*all')
                    bf:close()
                end
                local backupResult, backupErr = SafeLoad.tableLiteral(backupContent, path .. '.bak')
                if type(backupResult) == 'table' then
                    print('\\ay[SpellSetPersistence]\\ax Loaded spell sets from backup file')
                    data = backupResult
                    M.loadError = nil
                else
                    print(string.format('\\ar[SpellSetPersistence]\\ax Backup load failed: %s', tostring(backupErr)))
                end
            end
        end
    end

    -- Reset state
    M.spellSets = {}
    M.activeSetName = nil

    if M.loadError then
        M.loaded = true
        return false
    end

    -- Process loaded data
    if data and data.version and data.sets then
        -- Handle version differences if needed in the future
        -- Currently version=2 is the only version

        -- Count sets in data
        local loadedSetCount = 0
        for _ in pairs(data.sets) do
            loadedSetCount = loadedSetCount + 1
        end
        -- print(string.format('\\ag[SpellSetPersistence]\\ax Found %d spell set(s) in file', loadedSetCount))

        -- Deserialize each spell set
        for name, setData in pairs(data.sets) do
            -- print(string.format('\\ag[SpellSetPersistence]\\ax   - Loading set: "%s"', name))
            local SpellSetData = getSpellSetData()
            local spellSet = nil

            if SpellSetData and SpellSetData.newSpellSet then
                spellSet = SpellSetData.newSpellSet(name)
            else
                -- Fallback: create minimal spell set structure
                spellSet = {
                    name = name,
                    gems = {},
                    oocBuffs = {},
                }
            end

            if spellSet then
                -- Deserialize gems
                if setData.gems then
                    for slot, gemData in pairs(setData.gems) do
                        local slotNum = tonumber(slot)
                        if slotNum then
                            spellSet.gems[slotNum] = {
                                spellId = gemData.spellId,
                                condition = deserializeCondition(gemData.condition),
                                priority = gemData.priority,
                                buffTarget = gemData.buffTarget,
                            }
                        end
                    end
                end

                -- Deserialize oocBuffs
                if setData.oocBuffs then
                    for _, buffData in ipairs(setData.oocBuffs) do
                        table.insert(spellSet.oocBuffs, {
                            spellId = buffData.spellId,
                            enabled = buffData.enabled ~= false, -- Default to true
                            priority = buffData.priority or 100,
                            condition = deserializeCondition(buffData.condition),
                            buffTarget = buffData.buffTarget,
                        })
                    end
                end

                M.spellSets[name] = spellSet
            end
        end

        -- Restore active set name
        M.activeSetName = data.activeSet
    end

    -- Ensure activeSetName points to valid set
    if M.activeSetName and not M.spellSets[M.activeSetName] then
        M.activeSetName = nil
    end

    -- If no sets or activeSetName is nil, pick first available
    if not M.activeSetName then
        local names = M.getSetNames()
        if names[1] then
            M.activeSetName = names[1]
        end
    end

    -- If no sets exist at all, create "Default" set
    if not next(M.spellSets) then
        M.createSet('Default')
        M.activeSetName = 'Default'
    end

    M.loaded = true
    return true
end

--------------------------------------------------------------------------------
-- Spell Set CRUD Operations
--------------------------------------------------------------------------------

--- Create a new spell set
---@param name string The name for the new spell set
---@return table|nil The created spell set, or nil if creation failed
function M.createSet(name)
    if not name or name == '' then return nil end

    -- Don't overwrite existing set
    if M.spellSets[name] then
        -- print(string.format('\\ay[SpellSetPersistence]\\ax Set "%s" already exists, returning existing', name))
        return M.spellSets[name]
    end

    -- print(string.format('\\ag[SpellSetPersistence]\\ax Creating new spell set: "%s"', name))

    local SpellSetData = getSpellSetData()
    local spellSet = nil

    if SpellSetData and SpellSetData.newSpellSet then
        spellSet = SpellSetData.newSpellSet(name)
    else
        -- Fallback: create minimal spell set structure
        spellSet = {
            name = name,
            gems = {},
            oocBuffs = {},
        }
    end

    if spellSet then
        M.spellSets[name] = spellSet
    end

    return spellSet
end

--- Delete a spell set
---@param name string The name of the spell set to delete
---@return boolean True if deleted, false if not found
function M.deleteSet(name)
    if not name or not M.spellSets[name] then
        return false
    end

    M.spellSets[name] = nil

    -- Update activeSetName if we deleted the active set
    if M.activeSetName == name then
        local names = M.getSetNames()
        M.activeSetName = names[1] -- May be nil if no sets remain
    end

    return true
end

--- Get a spell set by name
---@param name string The name of the spell set
---@return table|nil The spell set, or nil if not found
function M.getSet(name)
    if not name then return nil end
    return M.spellSets[name]
end

--- Get the active spell set
---@return table|nil The active spell set, or nil if none active
function M.getActiveSet()
    if not M.activeSetName then return nil end
    return M.spellSets[M.activeSetName]
end

--- Set the active spell set
---@param name string The name of the spell set to activate
---@return boolean True if set was activated, false if not found
function M.setActiveSet(name)
    if not name then
        M.activeSetName = nil
        return true
    end

    if not M.spellSets[name] then
        return false
    end

    M.activeSetName = name
    return true
end

--- Get a sorted array of all spell set names
---@return string[] Array of spell set names, sorted alphabetically
function M.getSetNames()
    local names = {}
    for name, _ in pairs(M.spellSets) do
        table.insert(names, name)
    end
    table.sort(names)
    -- Debug: uncomment to trace set names
    -- print(string.format('\\ay[SpellSetPersistence]\\ax getSetNames() returning %d sets: %s', #names, table.concat(names, ', ')))
    return names
end

return M
