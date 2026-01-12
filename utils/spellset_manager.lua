-- F:/lua/sidekick/utils/spellset_manager.lua
-- Spell Set Manager - Handles spell loadout detection, switching, and custom user loadouts
-- Implements "Option A" - Automatic Detection Mode:
--   When user manually forgets a spell, system detects the change
--   Current loadout switches to "(Custom)" indicator
--   User can "Save As" to preserve changes as a named loadout

local mq = require('mq')

local M = {}

-- State tracking
M.currentLoadout = nil      -- Name of active loadout (or nil if no loadout selected)
M.isCustomMode = false      -- True if user made manual changes
M.lastGems = {}             -- Last known spell gems for change detection {[gem] = spellName}
M.customLoadouts = {}       -- User-saved custom loadouts {[name] = {gems = {[gem] = spellName}, description = ""}}
M.initialized = false       -- Has init() been called
M.detectionEnabled = true   -- Whether to auto-detect manual spell changes
M.lastCheckTime = 0         -- Last time we checked for changes (throttle)
M.checkInterval = 0.5       -- How often to check for changes (seconds)
M.builtInLoadouts = {}      -- Cache of built-in loadouts from spellset files

-- Lazy-load dependencies
local _Core = nil
local function getCore()
    if not _Core then
        local ok, c = pcall(require, 'utils.core')
        if ok then _Core = c end
    end
    return _Core
end

local _GemManager = nil
local function getGemManager()
    if not _GemManager then
        local ok, gm = pcall(require, 'utils.gem_manager')
        if ok then _GemManager = gm end
    end
    return _GemManager
end

-- INI section for custom loadouts
local LOADOUT_SECTION = 'SideKick-SpellLoadouts'

--- Get class short name
local function getClassShort()
    local me = mq.TLO.Me
    if not me or not me() then return nil end
    local class = me.Class
    if not class or not class() then return nil end
    return class.ShortName()
end

--- Get number of spell gems
local function getNumGems()
    local me = mq.TLO.Me
    if not me or not me() then return 13 end
    return tonumber(me.NumGems()) or 13
end

--- Serialize a gem table to string for INI storage
-- Format: "1:SpellName|2:SpellName|..."
local function serializeGems(gems)
    local parts = {}
    for gem, spellName in pairs(gems or {}) do
        if spellName and spellName ~= '' then
            table.insert(parts, string.format('%d:%s', gem, spellName))
        end
    end
    table.sort(parts)
    return table.concat(parts, '|')
end

--- Deserialize a gem string from INI
local function deserializeGems(str)
    local gems = {}
    if not str or str == '' then return gems end

    for part in string.gmatch(str, '[^|]+') do
        local gem, spellName = part:match('^(%d+):(.+)$')
        if gem and spellName then
            gems[tonumber(gem)] = spellName
        end
    end
    return gems
end

--- Load built-in loadouts from spellset file
local function loadBuiltInLoadouts()
    local classShort = getClassShort()
    if not classShort then return end

    M.builtInLoadouts = {}

    local path = string.format('data.spellsets.%s', classShort)
    local ok, spellset = pcall(require, path)
    if not ok or not spellset or not spellset.roles then
        return
    end

    -- Convert roles to loadout format
    for roleName, roleData in pairs(spellset.roles) do
        local gems = {}
        if roleData.gems then
            for gemNum, gemDef in pairs(roleData.gems) do
                -- Resolve spell line to actual spell
                local spellLine = gemDef.spellLine
                if spellLine then
                    local lineSpells = spellset.spellLines and spellset.spellLines[spellLine]
                    if lineSpells then
                        -- Find best available spell
                        local me = mq.TLO.Me
                        for _, spellName in ipairs(lineSpells) do
                            if me and me.Book and me.Book(spellName) and me.Book(spellName)() then
                                gems[gemNum] = spellName
                                break
                            end
                        end
                    end
                end
            end
        end

        M.builtInLoadouts[roleName] = {
            gems = gems,
            description = roleData.name or roleName,
            isBuiltIn = true,
        }
    end
end

--- Load custom loadouts from INI
local function loadCustomLoadouts()
    local Core = getCore()
    if not Core or not Core.Ini then return end

    M.customLoadouts = {}

    local section = Core.Ini[LOADOUT_SECTION]
    if not section then return end

    -- Parse entries: name_gems = "gem:spell|gem:spell", name_desc = "description"
    local loadoutData = {}
    for key, value in pairs(section) do
        local name, suffix = key:match('^(.+)_([^_]+)$')
        if name and suffix then
            if not loadoutData[name] then
                loadoutData[name] = {}
            end
            if suffix == 'gems' then
                loadoutData[name].gems = deserializeGems(value)
            elseif suffix == 'desc' then
                loadoutData[name].description = value
            end
        end
    end

    -- Build loadout entries
    for name, data in pairs(loadoutData) do
        if data.gems and next(data.gems) then
            M.customLoadouts[name] = {
                gems = data.gems,
                description = data.description or '',
                isBuiltIn = false,
            }
        end
    end
end

--- Save custom loadouts to INI
local function saveCustomLoadouts()
    local Core = getCore()
    if not Core or not Core.Ini then return end

    -- Clear existing section
    Core.Ini[LOADOUT_SECTION] = {}

    -- Save each custom loadout
    for name, loadout in pairs(M.customLoadouts) do
        if not loadout.isBuiltIn then
            Core.Ini[LOADOUT_SECTION][name .. '_gems'] = serializeGems(loadout.gems)
            if loadout.description and loadout.description ~= '' then
                Core.Ini[LOADOUT_SECTION][name .. '_desc'] = loadout.description
            end
        end
    end

    -- Save current loadout name
    if M.currentLoadout then
        Core.Ini[LOADOUT_SECTION]['_current'] = M.currentLoadout
    end

    if Core.save then Core.save() end
end

--- Save current loadout selection to INI
local function saveCurrentLoadoutSelection()
    local Core = getCore()
    if not Core or not Core.Ini then return end

    Core.Ini[LOADOUT_SECTION] = Core.Ini[LOADOUT_SECTION] or {}
    Core.Ini[LOADOUT_SECTION]['_current'] = M.currentLoadout or ''
    Core.Ini[LOADOUT_SECTION]['_isCustom'] = M.isCustomMode and '1' or '0'

    if Core.save then Core.save() end
end

--- Initialize the spellset manager
-- Loads saved loadouts from INI and sets up change detection
function M.init()
    if M.initialized then return end

    local Core = getCore()
    if Core and Core.Settings then
        M.detectionEnabled = (Core.Settings.AutoDetectSpellChanges ~= false)
    end

    -- Load built-in loadouts from spellset file
    loadBuiltInLoadouts()

    -- Load custom loadouts from INI
    loadCustomLoadouts()

    -- Load current loadout selection
    if Core and Core.Ini and Core.Ini[LOADOUT_SECTION] then
        M.currentLoadout = Core.Ini[LOADOUT_SECTION]['_current']
        if M.currentLoadout == '' then M.currentLoadout = nil end
        M.isCustomMode = Core.Ini[LOADOUT_SECTION]['_isCustom'] == '1'
    end

    -- Capture initial gem state
    M.captureCurrentGems()

    M.initialized = true
end

--- Tick function - call from main loop to detect manual spell changes
function M.tick()
    if not M.initialized then return end
    if not M.detectionEnabled then return end

    -- Throttle checks
    local now = os.clock()
    if (now - M.lastCheckTime) < M.checkInterval then
        return
    end
    M.lastCheckTime = now

    -- Detect manual changes
    M.detectManualChanges()
end

--- Get the currently active loadout name
-- Returns "(Custom)" if user made manual changes, or the loadout name
-- @return string|nil The loadout name or "(Custom)" or nil
function M.getCurrentLoadout()
    if M.isCustomMode then
        return '(Custom)'
    end
    return M.currentLoadout
end

--- Get the raw loadout name (without Custom indicator)
-- @return string|nil The actual loadout name
function M.getCurrentLoadoutName()
    return M.currentLoadout
end

--- Check if current state is in custom mode
-- @return boolean True if user made manual changes
function M.isInCustomMode()
    return M.isCustomMode
end

--- Switch to a loadout (applies spells to gem bar)
-- @param name string The loadout name to switch to
-- @param applyImmediately boolean If true, immediately memorize spells (default: true)
-- @return boolean True if loadout was found and set
function M.setLoadout(name, applyImmediately)
    if applyImmediately == nil then applyImmediately = true end

    -- Look up loadout (check built-in first, then custom)
    local loadout = M.builtInLoadouts[name] or M.customLoadouts[name]
    if not loadout then
        mq.cmdf('/echo [SpellsetManager] Loadout not found: %s', name)
        return false
    end

    M.currentLoadout = name
    M.isCustomMode = false

    -- Save selection
    saveCurrentLoadoutSelection()

    if applyImmediately then
        -- Apply the loadout (memorize spells)
        M.applyLoadout(name)
    end

    -- Update lastGems to match expected state (avoid false "manual change" detection)
    M.lastGems = {}
    for gem, spellName in pairs(loadout.gems) do
        M.lastGems[gem] = spellName
    end

    return true
end

--- Apply a loadout's spells to the gem bar
-- @param name string The loadout name to apply
-- @return boolean True if application started
function M.applyLoadout(name)
    local loadout = M.builtInLoadouts[name] or M.customLoadouts[name]
    if not loadout or not loadout.gems then
        return false
    end

    local me = mq.TLO.Me
    if not me or not me() then return false end

    mq.cmdf('/echo [SpellsetManager] Applying loadout: %s', name)

    -- Memorize each spell
    for gem, spellName in pairs(loadout.gems) do
        if spellName and spellName ~= '' then
            -- Check if already memorized in this slot
            local currentSpell = me.Gem(gem)
            local currentName = currentSpell and currentSpell.Name and currentSpell.Name() or ''

            if currentName ~= spellName then
                mq.cmdf('/memspell %d "%s"', gem, spellName)
                -- Small delay between memorizations to avoid issues
                mq.delay(100)
            end
        end
    end

    return true
end

--- Save current gem bar state as a loadout
-- @param name string The name for the loadout
-- @param description string Optional description
-- @return boolean True if saved successfully
function M.saveLoadout(name, description)
    if not name or name == '' then
        mq.cmd('/echo [SpellsetManager] Cannot save loadout: name required')
        return false
    end

    -- Don't allow overwriting built-in loadouts
    if M.builtInLoadouts[name] then
        mq.cmdf('/echo [SpellsetManager] Cannot overwrite built-in loadout: %s', name)
        return false
    end

    -- Capture current gem state
    local gems = M.captureCurrentGems()

    M.customLoadouts[name] = {
        gems = gems,
        description = description or '',
        isBuiltIn = false,
    }

    -- Update state
    M.currentLoadout = name
    M.isCustomMode = false
    M.lastGems = {}
    for gem, spellName in pairs(gems) do
        M.lastGems[gem] = spellName
    end

    -- Save to INI
    saveCustomLoadouts()

    mq.cmdf('/echo [SpellsetManager] Saved loadout: %s', name)
    return true
end

--- Delete a saved loadout
-- @param name string The loadout name to delete
-- @return boolean True if deleted successfully
function M.deleteLoadout(name)
    if not name or name == '' then
        return false
    end

    -- Can't delete built-in loadouts
    if M.builtInLoadouts[name] then
        mq.cmdf('/echo [SpellsetManager] Cannot delete built-in loadout: %s', name)
        return false
    end

    if not M.customLoadouts[name] then
        return false
    end

    M.customLoadouts[name] = nil

    -- If we deleted the current loadout, clear selection
    if M.currentLoadout == name then
        M.currentLoadout = nil
        M.isCustomMode = true
    end

    -- Save changes
    saveCustomLoadouts()

    mq.cmdf('/echo [SpellsetManager] Deleted loadout: %s', name)
    return true
end

--- Get list of all available loadouts (built-in + custom)
-- @return table Array of {name, description, isBuiltIn}
function M.getAvailableLoadouts()
    local loadouts = {}

    -- Add built-in loadouts
    for name, data in pairs(M.builtInLoadouts) do
        table.insert(loadouts, {
            name = name,
            description = data.description or name,
            isBuiltIn = true,
        })
    end

    -- Add custom loadouts
    for name, data in pairs(M.customLoadouts) do
        table.insert(loadouts, {
            name = name,
            description = data.description or name,
            isBuiltIn = false,
        })
    end

    -- Sort: built-in first, then alphabetically
    table.sort(loadouts, function(a, b)
        if a.isBuiltIn ~= b.isBuiltIn then
            return a.isBuiltIn
        end
        return a.name < b.name
    end)

    return loadouts
end

--- Get the gem assignments for a specific loadout
-- @param name string The loadout name
-- @return table|nil {[gem] = spellName} or nil if not found
function M.getLoadoutGems(name)
    local loadout = M.builtInLoadouts[name] or M.customLoadouts[name]
    if loadout then
        return loadout.gems
    end
    return nil
end

--- Capture current spell bar state
-- @return table {[gem] = spellName}
function M.captureCurrentGems()
    local gems = {}
    local me = mq.TLO.Me
    if not me or not me() then return gems end

    local numGems = getNumGems()
    for i = 1, numGems do
        local spell = me.Gem(i)
        if spell and spell() then
            local name = spell.Name and spell.Name() or ''
            if name ~= '' then
                gems[i] = name
            end
        end
    end

    -- Update lastGems
    M.lastGems = {}
    for gem, spellName in pairs(gems) do
        M.lastGems[gem] = spellName
    end

    return gems
end

--- Detect if user manually changed spells
-- Sets isCustomMode = true if changes detected
-- @return boolean True if changes were detected
function M.detectManualChanges()
    local me = mq.TLO.Me
    if not me or not me() then return false end

    -- Don't detect during memorization
    local GemManager = getGemManager()
    if GemManager and GemManager.isMemorizing and GemManager.isMemorizing() then
        return false
    end

    local numGems = getNumGems()
    local changesDetected = false

    for i = 1, numGems do
        local spell = me.Gem(i)
        local currentName = ''
        if spell and spell() then
            currentName = spell.Name and spell.Name() or ''
        end

        local lastName = M.lastGems[i] or ''

        if currentName ~= lastName then
            changesDetected = true
            -- Update our tracking
            if currentName == '' then
                M.lastGems[i] = nil
            else
                M.lastGems[i] = currentName
            end
        end
    end

    if changesDetected and not M.isCustomMode then
        M.isCustomMode = true
        saveCurrentLoadoutSelection()
    end

    return changesDetected
end

--- Reset custom mode (after saving, etc.)
function M.clearCustomMode()
    M.isCustomMode = false
    saveCurrentLoadoutSelection()
end

--- Check if a loadout exists
-- @param name string The loadout name
-- @return boolean True if loadout exists
function M.loadoutExists(name)
    return M.builtInLoadouts[name] ~= nil or M.customLoadouts[name] ~= nil
end

--- Check if a loadout is built-in
-- @param name string The loadout name
-- @return boolean True if loadout is built-in
function M.isBuiltInLoadout(name)
    return M.builtInLoadouts[name] ~= nil
end

--- Rename a custom loadout
-- @param oldName string Current name
-- @param newName string New name
-- @return boolean True if renamed successfully
function M.renameLoadout(oldName, newName)
    if not oldName or not newName or oldName == '' or newName == '' then
        return false
    end

    if M.builtInLoadouts[oldName] then
        mq.cmd('/echo [SpellsetManager] Cannot rename built-in loadout')
        return false
    end

    if not M.customLoadouts[oldName] then
        return false
    end

    if M.loadoutExists(newName) then
        mq.cmdf('/echo [SpellsetManager] Loadout already exists: %s', newName)
        return false
    end

    -- Copy to new name
    M.customLoadouts[newName] = M.customLoadouts[oldName]
    M.customLoadouts[oldName] = nil

    -- Update current if needed
    if M.currentLoadout == oldName then
        M.currentLoadout = newName
    end

    saveCustomLoadouts()
    return true
end

--- Refresh built-in loadouts (e.g., after class change)
function M.refreshBuiltInLoadouts()
    loadBuiltInLoadouts()
end

--- Get comparison between current gems and a loadout
-- @param name string The loadout name to compare
-- @return table Array of {gem, expected, current, matches}
function M.compareToLoadout(name)
    local loadout = M.builtInLoadouts[name] or M.customLoadouts[name]
    if not loadout then return {} end

    local results = {}
    local me = mq.TLO.Me
    if not me or not me() then return results end

    local numGems = getNumGems()
    for i = 1, numGems do
        local expected = loadout.gems[i] or ''
        local spell = me.Gem(i)
        local current = ''
        if spell and spell() then
            current = spell.Name and spell.Name() or ''
        end

        table.insert(results, {
            gem = i,
            expected = expected,
            current = current,
            matches = (expected == current) or (expected == '' and current ~= ''),
        })
    end

    return results
end

--- Set whether auto-detection is enabled
-- @param enabled boolean True to enable detection
function M.setDetectionEnabled(enabled)
    M.detectionEnabled = enabled

    -- Save to settings
    local Core = getCore()
    if Core and Core.set then
        Core.set('AutoDetectSpellChanges', enabled)
    end
end

--- Check if detection is enabled
-- @return boolean
function M.isDetectionEnabled()
    return M.detectionEnabled
end

return M
