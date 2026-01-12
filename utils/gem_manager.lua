-- F:/lua/SideKick/utils/gem_manager.lua
-- Gem Manager - Spell gem assignments and memorization
-- Role-based loadouts with user override persistence

local mq = require('mq')

local M = {}

-- Lazy-load dependencies
local _Core = nil
local function getCore()
    if not _Core then
        local ok, c = pcall(require, 'utils.core')
        if ok then _Core = c end
    end
    return _Core
end

local _SpellEvents = nil
local function getSpellEvents()
    if not _SpellEvents then
        local ok, se = pcall(require, 'utils.spell_events')
        if ok then _SpellEvents = se end
    end
    return _SpellEvents
end

-- Gem state
local GemState = {
    assignments = {},      -- [gemNum] = { spellName, priority, locked, spellId }
    spellToGem = {},       -- [spellName] = gemNum
    activeRole = 'default',
    useGem = 13,           -- Rotation gem (for dynamic memorization)
    numGems = 13,          -- mq.TLO.Me.NumGems()
    memorizing = false,
    memorizingGem = 0,
    memorizingSpell = '',
    memStartTime = 0,
    initialized = false,
}

-- Loaded spellsets cache
local _spellsets = {}

-- Get class short name
local function getClassShort()
    local me = mq.TLO.Me
    if not me or not me() then return nil end
    local class = me.Class
    if not class or not class() then return nil end
    return class.ShortName()
end

-- Load spellset for class
local function loadSpellset(classShort)
    if _spellsets[classShort] then
        return _spellsets[classShort]
    end

    local path = string.format('data.spellsets.%s', classShort)
    local ok, spellset = pcall(require, path)
    if ok and spellset then
        _spellsets[classShort] = spellset
        return spellset
    end

    return nil
end

-- Resolve spell line to best available spell
local function resolveSpellLine(spellLine, spellset)
    local me = mq.TLO.Me
    if not me or not me() then return nil end

    -- Check spellset for spell line definition
    local lineSpells = spellset and spellset.spellLines and spellset.spellLines[spellLine]
    if lineSpells then
        -- Try each spell in order (newest first)
        for _, spellName in ipairs(lineSpells) do
            local inBook = me.Book(spellName)
            if inBook and inBook() then
                return spellName
            end
        end
    end

    -- Fallback: try spell line name directly
    local inBook = me.Book(spellLine)
    if inBook and inBook() then
        return spellLine
    end

    return nil
end

-- Get setting value
local function getSetting(key, default)
    local Core = getCore()
    if Core and Core.Settings and Core.Settings[key] ~= nil then
        return Core.Settings[key]
    end
    return default
end

--- Initialize gem manager
function M.init()
    local me = mq.TLO.Me
    if not me or not me() then return end

    -- Get number of gem slots
    GemState.numGems = tonumber(me.NumGems()) or 13
    GemState.useGem = getSetting('SpellUseGem', GemState.numGems)

    -- Initialize assignments
    GemState.assignments = {}
    GemState.spellToGem = {}
    for i = 1, GemState.numGems do
        GemState.assignments[i] = { spellName = '', priority = 0, locked = false, spellId = 0 }
    end

    -- Load current gem bar state
    M.syncFromGameState()

    -- Register memorization event callbacks
    local SpellEvents = getSpellEvents()
    if SpellEvents then
        SpellEvents.onMemBegin = function(spellName)
            GemState.memorizing = true
            GemState.memorizingSpell = spellName
            GemState.memStartTime = os.clock()
        end
        SpellEvents.onMemEnd = function(spellName)
            GemState.memorizing = false
            GemState.memorizingSpell = ''
            M.syncFromGameState()
        end
        SpellEvents.onMemAbort = function()
            GemState.memorizing = false
            GemState.memorizingSpell = ''
        end
    end

    GemState.initialized = true
end

--- Sync gem state from game
function M.syncFromGameState()
    local me = mq.TLO.Me
    if not me or not me() then return end

    GemState.spellToGem = {}

    for i = 1, GemState.numGems do
        local gem = me.Gem(i)
        if gem and gem() then
            local spellName = gem.Name() or ''
            local spellId = tonumber(gem.ID()) or 0

            -- Only update if not locked or if lock is enabled and matches
            local current = GemState.assignments[i]
            if current and not current.locked then
                current.spellName = spellName
                current.spellId = spellId
            end

            if spellName ~= '' then
                GemState.spellToGem[spellName] = i
            end
        end
    end
end

--- Load role-based spell loadout
-- @param roleName string Role name ('heal', 'dps', 'cc', etc.)
function M.loadRole(roleName)
    local classShort = getClassShort()
    if not classShort then return end

    local spellset = loadSpellset(classShort)
    if not spellset or not spellset.roles or not spellset.roles[roleName] then
        return
    end

    local role = spellset.roles[roleName]
    GemState.activeRole = roleName

    -- Apply role gems (skip locked gems)
    for gemNum, gemDef in pairs(role.gems or {}) do
        local current = GemState.assignments[gemNum]
        if current and not current.locked then
            local spellName = resolveSpellLine(gemDef.spellLine, spellset)
            if spellName then
                current.spellName = spellName
                current.priority = gemDef.priority or 1
                current.locked = false

                -- Get spell ID
                local spell = mq.TLO.Spell(spellName)
                current.spellId = spell and tonumber(spell.ID()) or 0

                GemState.spellToGem[spellName] = gemNum
            end
        end
    end
end

--- Set user override for a gem
-- @param gemNum number Gem slot number
-- @param spellName string Spell name (empty to clear)
function M.setUserOverride(gemNum, spellName)
    if gemNum < 1 or gemNum > GemState.numGems then return end

    local current = GemState.assignments[gemNum]
    if not current then return end

    if spellName and spellName ~= '' then
        current.spellName = spellName
        current.locked = true
        current.priority = 1

        local spell = mq.TLO.Spell(spellName)
        current.spellId = spell and tonumber(spell.ID()) or 0

        GemState.spellToGem[spellName] = gemNum
    else
        -- Clear override - revert to empty or role default
        current.spellName = ''
        current.locked = true  -- Still locked (user explicitly removed)
        current.priority = 0
        current.spellId = 0
    end

    -- Persist to INI
    M.saveUserOverrides()
end

--- Clear user override for a gem
-- @param gemNum number Gem slot number
function M.clearUserOverride(gemNum)
    if gemNum < 1 or gemNum > GemState.numGems then return end

    local current = GemState.assignments[gemNum]
    if current then
        current.locked = false
        -- Role will re-apply on next loadRole call
    end

    M.saveUserOverrides()
end

--- Save user overrides to INI
function M.saveUserOverrides()
    local Core = getCore()
    if not Core or not Core.Ini then return end

    -- Save to [SideKick-Spells] section
    if not Core.Ini['SideKick-Spells'] then
        Core.Ini['SideKick-Spells'] = {}
    end

    for gemNum, assignment in pairs(GemState.assignments) do
        if assignment.locked then
            local value = string.format('%s|%d|1', assignment.spellName or '', assignment.priority or 0)
            Core.Ini['SideKick-Spells']['Gem' .. gemNum] = value
        else
            Core.Ini['SideKick-Spells']['Gem' .. gemNum] = nil
        end
    end

    -- Save role
    Core.Ini['SideKick-Spells']['SpellRole'] = GemState.activeRole

    -- Trigger INI save
    if Core.saveIni then
        Core.saveIni()
    end
end

--- Load user overrides from INI
function M.loadUserOverrides()
    local Core = getCore()
    if not Core or not Core.Ini then return end

    local section = Core.Ini['SideKick-Spells']
    if not section then return end

    -- Load role
    if section.SpellRole then
        GemState.activeRole = section.SpellRole
    end

    -- Load gem overrides
    for gemNum = 1, GemState.numGems do
        local value = section['Gem' .. gemNum]
        if value and value ~= '' then
            local parts = {}
            for part in string.gmatch(value, '[^|]+') do
                table.insert(parts, part)
            end

            local spellName = parts[1] or ''
            local priority = tonumber(parts[2]) or 0
            local locked = (parts[3] == '1')

            if locked then
                local current = GemState.assignments[gemNum]
                if current then
                    current.spellName = spellName
                    current.priority = priority
                    current.locked = true

                    if spellName ~= '' then
                        local spell = mq.TLO.Spell(spellName)
                        current.spellId = spell and tonumber(spell.ID()) or 0
                        GemState.spellToGem[spellName] = gemNum
                    end
                end
            end
        end
    end
end

--- Get gem number for a spell
-- @param spellName string Spell name
-- @return number|nil Gem number if memorized
function M.getSpellGem(spellName)
    -- Check cached state first
    if GemState.spellToGem[spellName] then
        return GemState.spellToGem[spellName]
    end

    -- Check actual game state
    local me = mq.TLO.Me
    if not me or not me() then return nil end

    local gem = me.Gem(spellName)
    if gem and gem() then
        local gemNum = gem()
        GemState.spellToGem[spellName] = gemNum
        return gemNum
    end

    return nil
end

--- Check if spell is memorized
-- @param spellName string Spell name
-- @return boolean
function M.isSpellMemorized(spellName)
    return M.getSpellGem(spellName) ~= nil
end

--- Get available gem for dynamic memorization
-- @return number Gem slot number
function M.getAvailableGem()
    return GemState.useGem or GemState.numGems
end

--- Memorize spell to gem (non-blocking start)
-- @param gemNum number Gem slot
-- @param spellName string Spell name
function M.memorize(gemNum, spellName)
    if gemNum < 1 or gemNum > GemState.numGems then return end
    if not spellName or spellName == '' then return end

    GemState.memorizing = true
    GemState.memorizingGem = gemNum
    GemState.memorizingSpell = spellName
    GemState.memStartTime = os.clock()

    mq.cmdf('/memspell %d "%s"', gemNum, spellName)
end

--- Check if currently memorizing
-- @return boolean
function M.isMemorizing()
    return GemState.memorizing
end

--- Get memorizing info
-- @return table|nil { gem, spell, startTime }
function M.getMemorizingInfo()
    if GemState.memorizing then
        return {
            gem = GemState.memorizingGem,
            spell = GemState.memorizingSpell,
            startTime = GemState.memStartTime,
        }
    end
    return nil
end

--- Get all gem assignments
-- @return table Array of assignments
function M.getAssignments()
    return GemState.assignments
end

--- Get current role
-- @return string Role name
function M.getActiveRole()
    return GemState.activeRole
end

--- Get available roles for current class
-- @return table Array of role names
function M.getAvailableRoles()
    local classShort = getClassShort()
    if not classShort then return {} end

    local spellset = loadSpellset(classShort)
    if not spellset or not spellset.roles then return {} end

    local roles = {}
    for roleName, _ in pairs(spellset.roles) do
        table.insert(roles, roleName)
    end
    table.sort(roles)
    return roles
end

--- Tick function for ongoing operations
function M.tick()
    -- Check memorization timeout
    if GemState.memorizing then
        local timeout = getSetting('SpellMemTimeout', 25000) / 1000
        if (os.clock() - GemState.memStartTime) > timeout then
            GemState.memorizing = false
            GemState.memorizingSpell = ''
        end
    end
end

--- Check if initialized
-- @return boolean
function M.isInitialized()
    return GemState.initialized
end

return M
