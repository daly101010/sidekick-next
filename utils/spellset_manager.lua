-- F:/lua/sidekick/utils/spellset_manager.lua
-- Spell Set Manager - spell set storage, resolution, and OOC memorization

local mq = require('mq')

local M = {}

-- Spell set state
M.initialized = false
M.spellSets = {}           -- {[name] = SpellSet}
M.activeSetName = nil      -- Current active set name
M.pendingApply = nil       -- Queued set to apply when OOC
M.applying = false         -- True while apply is running
M.lastCapacityCheck = 0
M.rotationCapacity = 12    -- NumGems - 1 (updated periodically)

-- Lazy-load dependencies
local _Core = nil
local function getCore()
    if not _Core then
        local ok, c = pcall(require, 'utils.core')
        if ok then _Core = c end
    end
    return _Core
end

local _SpellsClr = nil
local function getSpellsClr()
    if not _SpellsClr then
        local ok, s = pcall(require, 'sk_spells_clr')
        if ok then _SpellsClr = s end
    end
    return _SpellsClr
end

local _ConditionBuilder = nil
local function getConditionBuilder()
    if not _ConditionBuilder then
        local ok, cb = pcall(require, 'ui.condition_builder')
        if ok then _ConditionBuilder = cb end
    end
    return _ConditionBuilder
end

-- INI section for spell sets
local SPELLSET_SECTION = 'SideKick-SpellSets'

local function getNumGems()
    local me = mq.TLO.Me
    if not me or not me() then return 0 end
    return tonumber(me.NumGems()) or 0
end

local function getRotationGems()
    local numGems = getNumGems()
    if numGems <= 1 then return 0 end
    return numGems - 1
end

--- Update rotation capacity from NumGems (call periodically)
function M.updateCapacity()
    local now = os.clock()
    if (now - M.lastCapacityCheck) < 30 then return end
    M.lastCapacityCheck = now

    local numGems = getNumGems()
    if numGems <= 0 then return end
    M.rotationCapacity = numGems - 1
end

--- Get current rotation capacity
function M.getRotationCapacity()
    M.updateCapacity()
    return M.rotationCapacity
end

--- Resolve the best spell from a line (highest level in spellbook)
-- @param lineName string The spell line name
-- @return string|nil The resolved spell name or nil
function M.resolveSpellFromLine(lineName)
    local SpellsClr = getSpellsClr()
    if not SpellsClr then return nil end

    local lineData = SpellsClr.getLine(lineName)
    if not lineData or not lineData.spells then return nil end

    local me = mq.TLO.Me
    if not me or not me() then return nil end

    for _, spellName in ipairs(lineData.spells) do
        local inBook = me.Book(spellName)
        if inBook and inBook() then
            return spellName
        end
    end

    return nil
end

--------------------------------------------------------------------------------
-- Spell Set CRUD Operations
--------------------------------------------------------------------------------

--- Create a new spell set
-- @param name string The spell set name
-- @return table|nil The new spell set or nil if invalid
function M.createSet(name)
    if not name or name == '' then return nil end
    if M.spellSets[name] then return M.spellSets[name] end

    local set = {
        name = name,
        lines = {},  -- {[lineName] = {enabled, slotType, condition, priority}}
    }

    M.spellSets[name] = set
    M.saveSpellSets()
    return set
end

--- Delete a spell set
-- @param name string The spell set name
-- @return boolean True if deleted
function M.deleteSet(name)
    if not name or not M.spellSets[name] then return false end

    M.spellSets[name] = nil

    if M.activeSetName == name then
        M.activeSetName = nil
    end

    M.saveSpellSets()
    return true
end

--- Get a spell set by name
function M.getSet(name)
    return M.spellSets[name]
end

--- Get the active spell set
function M.getActiveSet()
    if not M.activeSetName then return nil end
    return M.spellSets[M.activeSetName]
end

--- Get list of all spell set names
function M.getSetNames()
    local names = {}
    for name, _ in pairs(M.spellSets) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

--------------------------------------------------------------------------------
-- Spell Line Enable/Disable Operations
--------------------------------------------------------------------------------

--- Count enabled rotation lines in a set
function M.countEnabledRotation(setName)
    local set = M.getSet(setName)
    if not set then return 0 end

    local count = 0
    for _, lineData in pairs(set.lines) do
        if lineData.enabled and lineData.slotType == 'rotation' then
            count = count + 1
        end
    end
    return count
end

--- Enable a spell line in a set
function M.enableLine(setName, lineName, slotType)
    local set = M.getSet(setName)
    if not set then return false end

    local SpellsClr = getSpellsClr()
    local lineInfo = SpellsClr and SpellsClr.getLine(lineName) or nil
    local defaultSlotType = (lineInfo and lineInfo.defaultSlotType) or 'rotation'

    if not slotType then
        slotType = defaultSlotType
    end

    if slotType == 'rotation' then
        local count = M.countEnabledRotation(setName)
        if count >= M.getRotationCapacity() then
            return false
        end
    end

    set.lines[lineName] = set.lines[lineName] or {}
    local lineData = set.lines[lineName]
    lineData.enabled = true
    lineData.slotType = slotType
    lineData.priority = lineData.priority or 999
    lineData.resolved = M.resolveSpellFromLine(lineName)

    M.saveSpellSets()
    return true
end

--- Disable a spell line in a set
function M.disableLine(setName, lineName)
    local set = M.getSet(setName)
    if not set or not set.lines[lineName] then return end

    set.lines[lineName].enabled = false
    M.saveSpellSets()
end

--- Set slot type for a line
function M.setLineSlotType(setName, lineName, slotType)
    local set = M.getSet(setName)
    if not set then return false end

    set.lines[lineName] = set.lines[lineName] or {}
    local lineData = set.lines[lineName]

    if slotType == 'rotation' and lineData.enabled then
        local count = M.countEnabledRotation(setName)
        if lineData.slotType ~= 'rotation' and count >= M.getRotationCapacity() then
            return false
        end
    end

    lineData.slotType = slotType
    M.saveSpellSets()
    return true
end

--- Set condition for a line
function M.setLineCondition(setName, lineName, conditionData)
    local set = M.getSet(setName)
    if not set then return end

    set.lines[lineName] = set.lines[lineName] or {}
    set.lines[lineName].condition = conditionData
    M.saveSpellSets()
end

--- Set priority for a line
function M.setLinePriority(setName, lineName, priority)
    local set = M.getSet(setName)
    if not set then return end

    set.lines[lineName] = set.lines[lineName] or {}
    set.lines[lineName].priority = priority
    M.saveSpellSets()
end

--------------------------------------------------------------------------------
-- Spell Set Activation and Memorization
--------------------------------------------------------------------------------

--- Activate a spell set (does not memorize yet)
function M.activateSet(setName)
    if not M.spellSets[setName] then return false end

    M.activeSetName = setName
    M.saveSpellSets()
    return true
end

--- Queue spell set application (memorization)
-- Always queues and runs from the main loop when OOC.
-- @param setName string|nil The spell set name (nil = active set)
-- @return string 'queued' or 'error'
function M.applySet(setName)
    setName = setName or M.activeSetName
    if not setName or not M.spellSets[setName] then
        return 'error'
    end

    M.pendingApply = setName
    return 'queued'
end

--- Actually apply a spell set (memorize spells)
-- Only call when OOC and castBusy == false
function M.doApplySet(setName)
    local set = M.spellSets[setName]
    if not set then return end
    if M.applying then return end
    M.applying = true

    local me = mq.TLO.Me
    if not me or not me() then
        M.applying = false
        return
    end

    -- Build list of rotation spells in priority order
    local rotationSpells = {}
    for lineName, lineData in pairs(set.lines) do
        if lineData.enabled and lineData.slotType == 'rotation' then
            lineData.resolved = lineData.resolved or M.resolveSpellFromLine(lineName)
            if lineData.resolved then
                table.insert(rotationSpells, {
                    lineName = lineName,
                    spellName = lineData.resolved,
                    priority = lineData.priority or 999,
                })
            end
        end
    end

    table.sort(rotationSpells, function(a, b)
        return a.priority < b.priority
    end)

    local function waitForMemorize(slot, spellName)
        -- Wait for the gem to reflect the memorized spell (prevents memspell overlap).
        local timeoutMs = 12000
        mq.delay(timeoutMs, function()
            if not me or not me() then return true end
            local gem = me.Gem(slot)
            local name = gem and gem() and gem.Name() or ''
            return name == spellName and not me.Casting()
        end)
    end

    local numGems = M.getRotationCapacity()
    for i, spell in ipairs(rotationSpells) do
        if i > numGems then break end

        local currentGem = me.Gem(i)
        local currentName = currentGem and currentGem() and currentGem.Name() or ''

        if currentName ~= spell.spellName then
            mq.cmdf('/memspell %d "%s"', i, spell.spellName)
            waitForMemorize(i, spell.spellName)
        end
    end

    M.activeSetName = setName
    M.pendingApply = nil
    M.saveSpellSets()
    M.applying = false
end

--- Check for pending apply and execute when safe
function M.checkPendingApply()
    if not M.pendingApply or M.applying then return end

    local me = mq.TLO.Me
    if not me or not me() then return end

    local inCombat = me.Combat()
    local casting = me.Casting and me.Casting()
    local moving = me.Moving and me.Moving()

    if not inCombat and not casting and not moving then
        M.doApplySet(M.pendingApply)
    end
end

--------------------------------------------------------------------------------
-- Spell Set INI Persistence
--------------------------------------------------------------------------------

--- Save all spell sets to INI
function M.saveSpellSets()
    local Core = getCore()
    if not Core or not Core.Ini then return end

    local ConditionBuilder = getConditionBuilder()

    Core.Ini[SPELLSET_SECTION] = Core.Ini[SPELLSET_SECTION] or {}
    local section = Core.Ini[SPELLSET_SECTION]

    for key in pairs(section) do
        section[key] = nil
    end

    local setNames = M.getSetNames()
    section['_sets'] = table.concat(setNames, ',')
    section['_active'] = M.activeSetName or ''

    for setName, set in pairs(M.spellSets) do
        local prefix = 'set_' .. setName:gsub('[^%w]', '_') .. '_'

        for lineName, lineData in pairs(set.lines) do
            local linePrefix = prefix .. lineName:gsub('[^%w]', '_') .. '_'
            section[linePrefix .. 'enabled'] = lineData.enabled and '1' or '0'
            section[linePrefix .. 'slotType'] = lineData.slotType or 'rotation'
            section[linePrefix .. 'priority'] = tostring(lineData.priority or 999)

            if lineData.condition and ConditionBuilder then
                section[linePrefix .. 'condition'] = ConditionBuilder.serialize(lineData.condition)
            else
                section[linePrefix .. 'condition'] = ''
            end
        end
    end

    if Core.save then Core.save() end
end

--- Load spell sets from INI
function M.loadSpellSets()
    local Core = getCore()
    if not Core or not Core.Ini then return end

    local ConditionBuilder = getConditionBuilder()
    local section = Core.Ini[SPELLSET_SECTION]
    if not section then return end

    M.spellSets = {}

    local setNamesStr = section['_sets'] or ''
    M.activeSetName = section['_active']
    if M.activeSetName == '' then M.activeSetName = nil end

    local setNames = {}
    for name in setNamesStr:gmatch('[^,]+') do
        name = name:match('^%s*(.-)%s*$')
        if name ~= '' then
            table.insert(setNames, name)
            M.spellSets[name] = { name = name, lines = {} }
        end
    end

    for key, value in pairs(section) do
        local setKey, lineName, prop = key:match('^set_([^_]+)_([^_]+)_(.+)$')
        if setKey and lineName and prop then
            local setName = nil
            for name, _ in pairs(M.spellSets) do
                if name:gsub('[^%w]', '_') == setKey then
                    setName = name
                    break
                end
            end

            if setName and M.spellSets[setName] then
                local set = M.spellSets[setName]
                set.lines[lineName] = set.lines[lineName] or {}
                local lineData = set.lines[lineName]

                if prop == 'enabled' then
                    lineData.enabled = (value == '1')
                elseif prop == 'slotType' then
                    lineData.slotType = value
                elseif prop == 'priority' then
                    lineData.priority = tonumber(value) or 999
                elseif prop == 'condition' then
                    if value ~= '' and ConditionBuilder then
                        lineData.condition = ConditionBuilder.deserialize(value)
                    end
                end
            end
        end
    end

    for _, set in pairs(M.spellSets) do
        for lineName, lineData in pairs(set.lines) do
            if lineData.enabled then
                lineData.resolved = M.resolveSpellFromLine(lineName)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Module Query Functions
--------------------------------------------------------------------------------

--- Get enabled lines of a specific slot type, sorted by priority
function M.getEnabledLines(slotType)
    local set = M.getActiveSet()
    if not set then return {} end

    local lines = {}
    for lineName, lineData in pairs(set.lines) do
        if lineData.enabled and lineData.slotType == slotType and lineData.resolved then
            table.insert(lines, {
                lineName = lineName,
                spellName = lineData.resolved,
                condition = lineData.condition,
                priority = lineData.priority or 999,
            })
        end
    end

    table.sort(lines, function(a, b)
        return a.priority < b.priority
    end)

    return lines
end

function M.getRotationLines()
    return M.getEnabledLines('rotation')
end

function M.getBuffSwapLines()
    return M.getEnabledLines('buff_swap')
end

--- Find the best matching spell for a category with conditions
function M.findBestSpell(category, ctx)
    local set = M.getActiveSet()
    if not set then return nil end

    local SpellsClr = getSpellsClr()
    local ConditionBuilder = getConditionBuilder()
    if not SpellsClr then return nil end

    local candidates = {}
    for lineName, lineData in pairs(set.lines) do
        if lineData.enabled and lineData.slotType == 'rotation' and lineData.resolved then
            local lineInfo = SpellsClr.getLine(lineName)
            if lineInfo and lineInfo.category == category then
                table.insert(candidates, {
                    lineName = lineName,
                    spellName = lineData.resolved,
                    condition = lineData.condition,
                    priority = lineData.priority or 999,
                })
            end
        end
    end

    table.sort(candidates, function(a, b)
        return a.priority < b.priority
    end)

    for _, cand in ipairs(candidates) do
        local passes = true
        if cand.condition and ConditionBuilder then
            passes = ConditionBuilder.evaluateWithContext(cand.condition, ctx)
        end

        if passes then
            local me = mq.TLO.Me
            if me and me() and me.SpellReady(cand.spellName)() then
                return cand.spellName
            end
        end
    end

    return nil
end

--------------------------------------------------------------------------------
-- Init / Tick
--------------------------------------------------------------------------------

function M.init()
    if M.initialized then return end

    M.loadSpellSets()
    M.updateCapacity()

    -- Ensure we always have at least one set to edit
    if not next(M.spellSets) then
        local defaultName = 'Default'
        M.spellSets[defaultName] = { name = defaultName, lines = {} }
        M.activeSetName = defaultName
        M.saveSpellSets()
    elseif not M.activeSetName then
        local names = M.getSetNames()
        if names[1] then
            M.activeSetName = names[1]
            M.saveSpellSets()
        end
    end

    M.initialized = true
end

function M.tick()
    if not M.initialized then return end
    M.checkPendingApply()
end

return M
