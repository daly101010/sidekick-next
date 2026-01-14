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
    useGem = 13,           -- Use gem (for dynamic memorization); clamped to rotation gems (NumGems-1)
    numGems = 13,          -- mq.TLO.Me.NumGems()
    memorizing = false,
    memorizingGem = 0,
    memorizingSpell = '',
    memStartTime = 0,
    initialized = false,
}

local function clamp(n, min, max)
    if n == nil then return min end
    if n < min then return min end
    if n > max then return max end
    return n
end

local function getLiveNumGems()
    local me = mq.TLO.Me
    if not (me and me()) then return nil end
    local n = tonumber(me.NumGems()) or 0
    if n <= 0 then return nil end
    return n
end

local function getRotationGemCount(numGems)
    numGems = tonumber(numGems) or 0
    if numGems <= 1 then return 0 end
    return numGems - 1
end

local function computeUseGem(numGems, getSettingFn)
    local rotation = getRotationGemCount(numGems)
    if rotation <= 0 then return 1 end
    local desired = tonumber(getSettingFn('SpellUseGem', rotation)) or rotation
    return clamp(desired, 1, rotation)
end

local function resizeAssignments(numGems)
    numGems = tonumber(numGems) or 0
    if numGems <= 0 then return end

    for i = 1, numGems do
        if not GemState.assignments[i] then
            GemState.assignments[i] = { spellName = '', priority = 0, locked = false, spellId = 0 }
        end
    end
    for i = numGems + 1, #GemState.assignments do
        GemState.assignments[i] = nil
    end
end

-- Loaded class configs cache
local _classConfigs = {}

-- Get class short name
local function getClassShort()
    local me = mq.TLO.Me
    if not me or not me() then return nil end
    local class = me.Class
    if not class or not class() then return nil end
    return class.ShortName()
end

-- Load class config for class
local function loadClassConfig(classShort)
    if _classConfigs[classShort] then
        return _classConfigs[classShort]
    end

    local path = string.format('data.class_configs.%s', classShort)
    local ok, classConfig = pcall(require, path)
    if ok and classConfig then
        _classConfigs[classShort] = classConfig
        return classConfig
    end

    return nil
end

-- Resolve spell line to best available spell
local function resolveSpellLine(spellLine, classConfig)
    local me = mq.TLO.Me
    if not me or not me() then return nil end

    -- Check class config for spell line definition
    local lineSpells = classConfig and classConfig.spellLines and classConfig.spellLines[spellLine]
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

--- Refresh gem count and derived settings from TLO
-- @return boolean True if character loaded and gem info available
function M.refresh()
    local numGems = getLiveNumGems()
    if not numGems then return false end

    if GemState.numGems ~= numGems then
        GemState.numGems = numGems
        resizeAssignments(numGems)
    end

    GemState.useGem = computeUseGem(GemState.numGems, getSetting)
    return true
end

--- Initialize gem manager
function M.init()
    local me = mq.TLO.Me
    if not me or not me() then return end

    -- Get number of gem slots and clamp use gem away from reserved buff gem.
    if not M.refresh() then return end

    -- Initialize assignments (preserve locks if already present)
    GemState.spellToGem = {}
    resizeAssignments(GemState.numGems)

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

    M.refresh()
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

    local classConfig = loadClassConfig(classShort)
    if not classConfig or not classConfig.SpellLoadouts or not classConfig.SpellLoadouts[roleName] then
        return
    end

    local loadout = classConfig.SpellLoadouts[roleName]
    GemState.activeRole = roleName

    -- Apply loadout gems (skip locked gems)
    -- SpellLoadouts use gem number as key, spell line name as value
    for gemNum, spellLine in pairs(loadout.gems or {}) do
        local current = GemState.assignments[gemNum]
        if current and not current.locked then
            local spellName = resolveSpellLine(spellLine, classConfig)
            if spellName then
                current.spellName = spellName
                current.priority = 1
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
    M.refresh()
    local rotation = getRotationGemCount(GemState.numGems)
    if rotation > 0 then
        return clamp(GemState.useGem or rotation, 1, rotation)
    end
    return 1
end

--- Get the reserved buff rotation gem (last gem)
-- @return number
function M.getReservedBuffGem()
    M.refresh()
    return GemState.numGems
end

--- Get number of gems available for rotation spells (NumGems - 1)
-- @return number
function M.getRotationGems()
    M.refresh()
    return getRotationGemCount(GemState.numGems)
end

--- Get total number of gems (NumGems)
-- @return number
function M.getNumGems()
    M.refresh()
    return GemState.numGems
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

    local classConfig = loadClassConfig(classShort)
    if not classConfig or not classConfig.SpellLoadouts then return {} end

    local roles = {}
    for roleName, _ in pairs(classConfig.SpellLoadouts) do
        table.insert(roles, roleName)
    end
    table.sort(roles)
    return roles
end

--- Tick function for ongoing operations
function M.tick()
    -- Auto-init once the character is loaded (init() can be called before Me() is ready).
    if not GemState.initialized then
        M.init()
        return
    end

    M.refresh()

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
