# Spell Set Editor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enable users to create named spell sets by selecting spell lines from `sk_spells_clr.lua`, with conditions and slot type classification.

**Architecture:** SpellsetManager handles storage/resolution, UI provides editing interface, ConditionBuilder provides pure condition evaluation, modules query spell sets at cast time.

**Tech Stack:** MQ2 Lua, ImGui, INI persistence via `mq.pickle()`

---

## Task 1: Add Spell Line Enumeration to sk_spells_clr.lua

**Files:**
- Modify: `F:/lua/sidekick/sk_spells_clr.lua`

**Step 1: Add category metadata and enumeration function**

Add at the end of `sk_spells_clr.lua`, before `return M`:

```lua
-- Category to default slot type mapping
M.DEFAULT_SLOT_TYPES = {
    -- Combat essential (rotation)
    Heals = 'rotation',
    GroupHeals = 'rotation',
    HoT = 'rotation',
    DirectHeals = 'rotation',
    Reactive = 'rotation',
    Damage = 'rotation',
    Stuns = 'rotation',
    Debuffs = 'rotation',
    Cures = 'rotation',
    AEDamage = 'rotation',

    -- OOC acceptable (buff_swap)
    Buffs = 'buff_swap',
    Auras = 'buff_swap',
    SelfBuffs = 'buff_swap',
    Wards = 'buff_swap',
    GroupBuffs = 'buff_swap',
    Procs = 'buff_swap',
    Persistent = 'buff_swap',
}

--- Enumerate all spell lines with their category
-- @return table Array of {category, lineName, spells, defaultSlotType}
function M.enumerateLines()
    local lines = {}

    -- Helper to process a category table
    local function processCategory(categoryName, categoryTable)
        if type(categoryTable) ~= 'table' then return end

        for lineName, spells in pairs(categoryTable) do
            if type(spells) == 'table' and #spells > 0 then
                table.insert(lines, {
                    category = categoryName,
                    lineName = lineName,
                    spells = spells,
                    defaultSlotType = M.DEFAULT_SLOT_TYPES[categoryName] or 'rotation',
                })
            end
        end
    end

    -- Process all categories
    processCategory('Heals', M.Heals)
    processCategory('GroupHeals', M.GroupHeals)
    processCategory('HoT', M.HoT)
    processCategory('DirectHeals', M.DirectHeals)
    processCategory('Reactive', M.Reactive)
    processCategory('Damage', M.Damage)
    processCategory('Stuns', M.Stuns)
    processCategory('Debuffs', M.Debuffs)
    processCategory('Cures', M.Cures)
    processCategory('AEDamage', M.AEDamage)
    processCategory('Buffs', M.Buffs)
    processCategory('Auras', M.Auras)
    processCategory('SelfBuffs', M.SelfBuffs)
    processCategory('Wards', M.Wards)
    processCategory('GroupBuffs', M.GroupBuffs)
    processCategory('Procs', M.Procs)
    processCategory('Persistent', M.Persistent)

    -- Sort by category then line name
    table.sort(lines, function(a, b)
        if a.category ~= b.category then
            return a.category < b.category
        end
        return a.lineName < b.lineName
    end)

    return lines
end

--- Get a specific spell line by name
-- @param lineName string The line name (e.g., "Remedy")
-- @return table|nil The spell list or nil if not found
function M.getLine(lineName)
    for _, lineData in ipairs(M.enumerateLines()) do
        if lineData.lineName == lineName then
            return lineData
        end
    end
    return nil
end
```

**Step 2: Verify the enumeration works**

Run in MQ2: `/lua run sidekick/test_spell_enum`

Create a quick test script `F:/lua/sidekick/test_spell_enum.lua`:

```lua
local mq = require('mq')
local Spells = require('sidekick.sk_spells_clr')

local lines = Spells.enumerateLines()
print(string.format('Found %d spell lines', #lines))

for i, line in ipairs(lines) do
    if i <= 10 then
        print(string.format('  %s.%s (%s) - %d spells',
            line.category, line.lineName, line.defaultSlotType, #line.spells))
    end
end

print('Enumeration test complete')
```

Expected: Output showing spell lines with categories and slot types.

**Step 3: Commit**

```bash
git add sk_spells_clr.lua test_spell_enum.lua
git commit -m "feat(spells): add spell line enumeration and slot type defaults"
```

---

## Task 2: Add Pure Context Evaluation to ConditionBuilder

**Files:**
- Modify: `F:/lua/sidekick/ui/condition_builder.lua`

**Step 1: Add context-aware evaluate function**

Find the existing `M.evaluate` function and add a new `M.evaluateWithContext` function after it:

```lua
--- Evaluate a condition with explicit context (pure function, no global state)
-- @param conditionData table The condition data structure
-- @param ctx table Context with targetId, targetHp, targetClass, myHp, myMana, etc.
-- @return boolean True if condition passes
function M.evaluateWithContext(conditionData, ctx)
    if not conditionData or not conditionData.conditions or #conditionData.conditions == 0 then
        return true  -- No conditions = always pass
    end

    ctx = ctx or {}

    local function evaluateSingle(cond)
        local subject = cond.subject or 'My'
        local property = cond.property or 'HP'
        local operator = cond.operator or 'is below'
        local value = cond.value

        local actual = nil

        -- Resolve actual value based on subject + property
        if subject == 'My' then
            if property == 'HP' then
                actual = ctx.myHp or (mq.TLO.Me.PctHPs() or 100)
            elseif property == 'Mana' then
                actual = ctx.myMana or (mq.TLO.Me.PctMana() or 100)
            elseif property == 'Endurance' then
                actual = ctx.myEndurance or (mq.TLO.Me.PctEndurance() or 100)
            elseif property == 'Combat' then
                actual = ctx.inCombat
                if actual == nil then
                    actual = mq.TLO.Me.Combat() or false
                end
            end
        elseif subject == "My Target's" or subject == 'My Target' then
            if property == 'HP' then
                actual = ctx.targetHp
            elseif property == 'Class' then
                actual = ctx.targetClass
            elseif property == 'Type' then
                actual = ctx.targetType
            elseif property == 'Named' then
                actual = ctx.targetNamed
            end
        elseif subject == "My Group's" then
            if property == 'injured count' then
                actual = ctx.groupInjuredCount or 0
            elseif property == 'count' then
                actual = ctx.groupCount or 0
            end
        end

        -- Apply operator
        if operator == 'is below' then
            return (tonumber(actual) or 0) < (tonumber(value) or 0)
        elseif operator == 'is above' then
            return (tonumber(actual) or 0) > (tonumber(value) or 0)
        elseif operator == 'equals' or operator == 'is' then
            if type(actual) == 'boolean' then
                return actual == (value == 'true' or value == true)
            end
            -- Handle multi-value (WAR|PAL|SHD)
            if type(value) == 'string' and value:find('|') then
                for v in value:gmatch('[^|]+') do
                    if tostring(actual):upper() == v:upper() then
                        return true
                    end
                end
                return false
            end
            return tostring(actual):upper() == tostring(value):upper()
        elseif operator == 'is not' then
            return tostring(actual):upper() ~= tostring(value):upper()
        elseif operator == 'is active' then
            return actual == true
        elseif operator == 'is not active' then
            return actual == false or actual == nil
        end

        return true  -- Unknown operator = pass
    end

    -- Evaluate first condition
    local result = evaluateSingle(conditionData.conditions[1])

    -- Apply connectors for subsequent conditions
    for i = 2, #conditionData.conditions do
        local cond = conditionData.conditions[i]
        local connector = conditionData.conditions[i - 1].connector or 'AND'
        local condResult = evaluateSingle(cond)

        if connector == 'AND' then
            result = result and condResult
        elseif connector == 'OR' then
            result = result or condResult
        end
    end

    return result
end
```

**Step 2: Commit**

```bash
git add ui/condition_builder.lua
git commit -m "feat(conditions): add pure evaluateWithContext function"
```

---

## Task 3: Create Spell Set Data Model in SpellsetManager

**Files:**
- Modify: `F:/lua/sidekick/utils/spellset_manager.lua`

**Step 1: Add spell set data structures**

Add near the top of the file, after existing state variables:

```lua
-- Spell Set state
M.spellSets = {}           -- {[name] = SpellSet}
M.activeSetName = nil      -- Name of currently active spell set
M.pendingApply = nil       -- Queued set to apply when OOC
M.lastCapacityCheck = 0    -- Throttle capacity updates
M.rotationCapacity = 12    -- NumGems - 1, updated periodically

-- Lazy-load spell database
local _SpellsClr = nil
local function getSpellsClr()
    if not _SpellsClr then
        local ok, s = pcall(require, 'sidekick.sk_spells_clr')
        if ok then _SpellsClr = s end
    end
    return _SpellsClr
end

-- Lazy-load condition builder
local _ConditionBuilder = nil
local function getConditionBuilder()
    if not _ConditionBuilder then
        local ok, cb = pcall(require, 'ui.condition_builder')
        if ok then _ConditionBuilder = cb end
    end
    return _ConditionBuilder
end
```

**Step 2: Add capacity calculation**

```lua
--- Update rotation capacity from NumGems (call periodically)
function M.updateCapacity()
    local now = os.clock()
    if (now - M.lastCapacityCheck) < 30 then return end  -- Every 30s
    M.lastCapacityCheck = now

    local me = mq.TLO.Me
    if not me or not me() then return end

    local numGems = tonumber(me.NumGems()) or 8
    M.rotationCapacity = numGems - 1  -- Last gem reserved for buff swap
end

--- Get current rotation capacity
-- @return number Available rotation gem slots
function M.getRotationCapacity()
    M.updateCapacity()
    return M.rotationCapacity
end
```

**Step 3: Add spell resolution**

```lua
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

    -- Spells are ordered highest to lowest, return first one in spellbook
    for _, spellName in ipairs(lineData.spells) do
        local inBook = me.Book(spellName)
        if inBook and inBook() then
            return spellName
        end
    end

    return nil
end
```

**Step 4: Commit**

```bash
git add utils/spellset_manager.lua
git commit -m "feat(spellset): add capacity and spell resolution"
```

---

## Task 4: Add Spell Set CRUD Operations

**Files:**
- Modify: `F:/lua/sidekick/utils/spellset_manager.lua`

**Step 1: Add spell set creation**

```lua
--- Create a new spell set
-- @param name string The spell set name
-- @return table The new spell set
function M.createSet(name)
    if not name or name == '' then return nil end
    if M.spellSets[name] then return M.spellSets[name] end

    local set = {
        name = name,
        lines = {},  -- {[lineName] = {enabled, slotType, condition, priority}}
    }

    M.spellSets[name] = set
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
-- @param name string The spell set name
-- @return table|nil The spell set or nil
function M.getSet(name)
    return M.spellSets[name]
end

--- Get the active spell set
-- @return table|nil The active spell set or nil
function M.getActiveSet()
    if not M.activeSetName then return nil end
    return M.spellSets[M.activeSetName]
end

--- Get list of all spell set names
-- @return table Array of spell set names
function M.getSetNames()
    local names = {}
    for name, _ in pairs(M.spellSets) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end
```

**Step 2: Add line enable/disable**

```lua
--- Enable a spell line in a set
-- @param setName string The spell set name
-- @param lineName string The spell line name
-- @param slotType string 'rotation' or 'buff_swap'
-- @return boolean True if enabled, false if at capacity
function M.enableLine(setName, lineName, slotType)
    local set = M.getSet(setName)
    if not set then return false end

    slotType = slotType or 'rotation'

    -- Check capacity for rotation lines
    if slotType == 'rotation' then
        local count = M.countEnabledRotation(setName)
        if count >= M.getRotationCapacity() then
            return false  -- At capacity
        end
    end

    -- Get default slot type if not specified
    if not set.lines[lineName] then
        local SpellsClr = getSpellsClr()
        local lineData = SpellsClr and SpellsClr.getLine(lineName)
        if lineData then
            slotType = lineData.defaultSlotType or 'rotation'
        end
    end

    set.lines[lineName] = set.lines[lineName] or {}
    set.lines[lineName].enabled = true
    set.lines[lineName].slotType = slotType
    set.lines[lineName].priority = set.lines[lineName].priority or 999
    set.lines[lineName].resolved = M.resolveSpellFromLine(lineName)

    M.saveSpellSets()
    return true
end

--- Disable a spell line in a set
-- @param setName string The spell set name
-- @param lineName string The spell line name
function M.disableLine(setName, lineName)
    local set = M.getSet(setName)
    if not set or not set.lines[lineName] then return end

    set.lines[lineName].enabled = false
    M.saveSpellSets()
end

--- Count enabled rotation lines in a set
-- @param setName string The spell set name
-- @return number Count of enabled rotation lines
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

--- Set the slot type for a line
-- @param setName string The spell set name
-- @param lineName string The spell line name
-- @param slotType string 'rotation' or 'buff_swap'
-- @return boolean True if successful
function M.setLineSlotType(setName, lineName, slotType)
    local set = M.getSet(setName)
    if not set or not set.lines[lineName] then return false end

    -- If moving to rotation, check capacity
    if slotType == 'rotation' and set.lines[lineName].slotType ~= 'rotation' then
        if set.lines[lineName].enabled then
            local count = M.countEnabledRotation(setName)
            if count >= M.getRotationCapacity() then
                return false  -- At capacity
            end
        end
    end

    set.lines[lineName].slotType = slotType
    M.saveSpellSets()
    return true
end

--- Set condition for a line
-- @param setName string The spell set name
-- @param lineName string The spell line name
-- @param conditionData table The condition data (from ConditionBuilder)
function M.setLineCondition(setName, lineName, conditionData)
    local set = M.getSet(setName)
    if not set or not set.lines[lineName] then return end

    set.lines[lineName].condition = conditionData
    M.saveSpellSets()
end

--- Set priority for a line
-- @param setName string The spell set name
-- @param lineName string The spell line name
-- @param priority number The priority (lower = higher priority)
function M.setLinePriority(setName, lineName, priority)
    local set = M.getSet(setName)
    if not set or not set.lines[lineName] then return end

    set.lines[lineName].priority = priority
    M.saveSpellSets()
end
```

**Step 3: Commit**

```bash
git add utils/spellset_manager.lua
git commit -m "feat(spellset): add CRUD operations for spell sets and lines"
```

---

## Task 5: Add Spell Set INI Persistence

**Files:**
- Modify: `F:/lua/sidekick/utils/spellset_manager.lua`

**Step 1: Add save function**

```lua
local SPELLSET_SECTION = 'SideKick-SpellSets'

--- Save all spell sets to INI
function M.saveSpellSets()
    local Core = getCore()
    if not Core or not Core.Ini then return end

    local ConditionBuilder = getConditionBuilder()

    -- Save set list
    Core.Ini[SPELLSET_SECTION] = Core.Ini[SPELLSET_SECTION] or {}
    local section = Core.Ini[SPELLSET_SECTION]

    -- Clear old entries
    for key in pairs(section) do
        section[key] = nil
    end

    -- Save set names
    local setNames = M.getSetNames()
    section['_sets'] = table.concat(setNames, ',')
    section['_active'] = M.activeSetName or ''

    -- Save each set
    for setName, set in pairs(M.spellSets) do
        local prefix = 'set_' .. setName:gsub('[^%w]', '_') .. '_'

        for lineName, lineData in pairs(set.lines) do
            local linePrefix = prefix .. lineName .. '_'
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
```

**Step 2: Add load function**

```lua
--- Load spell sets from INI
function M.loadSpellSets()
    local Core = getCore()
    if not Core or not Core.Ini then return end

    local ConditionBuilder = getConditionBuilder()
    local section = Core.Ini[SPELLSET_SECTION]
    if not section then return end

    M.spellSets = {}

    -- Load set names
    local setNamesStr = section['_sets'] or ''
    M.activeSetName = section['_active']
    if M.activeSetName == '' then M.activeSetName = nil end

    -- Parse set names
    local setNames = {}
    for name in setNamesStr:gmatch('[^,]+') do
        name = name:match('^%s*(.-)%s*$')  -- Trim
        if name ~= '' then
            table.insert(setNames, name)
            M.spellSets[name] = { name = name, lines = {} }
        end
    end

    -- Load line data for each set
    for key, value in pairs(section) do
        local setKey, lineName, prop = key:match('^set_([^_]+)_([^_]+)_(.+)$')
        if setKey and lineName and prop then
            -- Find the actual set name (convert back from safe key)
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

    -- Resolve spells for all enabled lines
    for _, set in pairs(M.spellSets) do
        for lineName, lineData in pairs(set.lines) do
            if lineData.enabled then
                lineData.resolved = M.resolveSpellFromLine(lineName)
            end
        end
    end
end
```

**Step 3: Update init to load spell sets**

Find the existing `M.init()` function and add near the end:

```lua
    -- Load spell sets
    M.loadSpellSets()
    M.updateCapacity()
```

**Step 4: Commit**

```bash
git add utils/spellset_manager.lua
git commit -m "feat(spellset): add INI persistence for spell sets"
```

---

## Task 6: Add Spell Set Application (Memorization)

**Files:**
- Modify: `F:/lua/sidekick/utils/spellset_manager.lua`

**Step 1: Add set activation and apply logic**

```lua
--- Activate a spell set (does not memorize yet)
-- @param setName string The spell set name
-- @return boolean True if activated
function M.activateSet(setName)
    if not M.spellSets[setName] then return false end

    M.activeSetName = setName
    M.saveSpellSets()
    return true
end

--- Queue spell set application (memorization)
-- If in combat, queues for OOC. Otherwise applies immediately.
-- @param setName string|nil The spell set name (nil = active set)
-- @return string 'applied', 'queued', or 'error'
function M.applySet(setName)
    setName = setName or M.activeSetName
    if not setName or not M.spellSets[setName] then
        return 'error'
    end

    -- Check if in combat
    local me = mq.TLO.Me
    local inCombat = me and me() and me.Combat()

    if inCombat then
        M.pendingApply = setName
        return 'queued'
    end

    M.doApplySet(setName)
    return 'applied'
end

--- Actually apply a spell set (memorize spells)
-- Only call when OOC and castBusy == false
-- @param setName string The spell set name
function M.doApplySet(setName)
    local set = M.spellSets[setName]
    if not set then return end

    local me = mq.TLO.Me
    if not me or not me() then return end

    -- Build list of rotation spells in priority order
    local rotationSpells = {}
    for lineName, lineData in pairs(set.lines) do
        if lineData.enabled and lineData.slotType == 'rotation' and lineData.resolved then
            table.insert(rotationSpells, {
                lineName = lineName,
                spellName = lineData.resolved,
                priority = lineData.priority or 999,
            })
        end
    end

    -- Sort by priority
    table.sort(rotationSpells, function(a, b)
        return a.priority < b.priority
    end)

    -- Memorize into gems 1..N
    local numGems = M.getRotationCapacity()
    for i, spell in ipairs(rotationSpells) do
        if i > numGems then break end

        local currentGem = me.Gem(i)
        local currentName = currentGem and currentGem() and currentGem.Name() or ''

        if currentName ~= spell.spellName then
            mq.cmdf('/memspell %d "%s"', i, spell.spellName)
            mq.delay(100)  -- Brief delay between mems
        end
    end

    M.activeSetName = setName
    M.pendingApply = nil
    M.saveSpellSets()
end

--- Check for pending apply and execute when safe
-- Call from main loop tick
function M.checkPendingApply()
    if not M.pendingApply then return end

    local me = mq.TLO.Me
    if not me or not me() then return end

    local inCombat = me.Combat()
    local casting = me.Casting and me.Casting()

    if not inCombat and not casting then
        M.doApplySet(M.pendingApply)
    end
end
```

**Step 2: Update tick to check pending apply**

Find `M.tick()` and add:

```lua
    -- Check for pending spell set apply
    M.checkPendingApply()
```

**Step 3: Commit**

```bash
git add utils/spellset_manager.lua
git commit -m "feat(spellset): add spell set activation and memorization"
```

---

## Task 7: Add Query Functions for Modules

**Files:**
- Modify: `F:/lua/sidekick/utils/spellset_manager.lua`

**Step 1: Add module query functions**

```lua
--- Get enabled lines of a specific slot type, sorted by priority
-- @param slotType string 'rotation' or 'buff_swap'
-- @return table Array of {lineName, spellName, condition, priority}
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

--- Get enabled rotation lines
-- @return table Array of rotation line data
function M.getRotationLines()
    return M.getEnabledLines('rotation')
end

--- Get enabled buff swap lines
-- @return table Array of buff swap line data
function M.getBuffSwapLines()
    return M.getEnabledLines('buff_swap')
end

--- Find the best matching spell for a category with conditions
-- @param category string The category to match (e.g., 'Heals', 'Damage')
-- @param ctx table Context for condition evaluation
-- @return string|nil The best matching spell name or nil
function M.findBestSpell(category, ctx)
    local set = M.getActiveSet()
    if not set then return nil end

    local SpellsClr = getSpellsClr()
    local ConditionBuilder = getConditionBuilder()
    if not SpellsClr then return nil end

    -- Build list of matching lines
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

    -- Sort by priority
    table.sort(candidates, function(a, b)
        return a.priority < b.priority
    end)

    -- Return first one where condition passes
    for _, cand in ipairs(candidates) do
        local passes = true
        if cand.condition and ConditionBuilder then
            passes = ConditionBuilder.evaluateWithContext(cand.condition, ctx)
        end

        if passes then
            -- Check if spell is ready
            local me = mq.TLO.Me
            if me and me() and me.SpellReady(cand.spellName)() then
                return cand.spellName
            end
        end
    end

    return nil
end
```

**Step 2: Commit**

```bash
git add utils/spellset_manager.lua
git commit -m "feat(spellset): add module query functions"
```

---

## Task 8: Create Spell Set Editor UI - Basic Structure

**Files:**
- Create: `F:/lua/sidekick/ui/spell_set_editor.lua`

**Step 1: Create the UI module structure**

```lua
-- F:/lua/sidekick/ui/spell_set_editor.lua
-- Spell Set Editor UI for creating and managing spell sets

local mq = require('mq')
local imgui = require('ImGui')

local M = {}

-- State
M.isOpen = false
M.selectedSet = nil
M.newSetName = ''
M.showNewSetPopup = false
M.showDeleteConfirm = false
M.showConditionPopup = false
M.conditionEditLine = nil
M.categoryFilter = 'All'

-- Lazy-load dependencies
local _SpellsetManager = nil
local function getSpellsetManager()
    if not _SpellsetManager then
        local ok, sm = pcall(require, 'utils.spellset_manager')
        if ok then _SpellsetManager = sm end
    end
    return _SpellsetManager
end

local _SpellsClr = nil
local function getSpellsClr()
    if not _SpellsClr then
        local ok, s = pcall(require, 'sidekick.sk_spells_clr')
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

--- Toggle the editor window
function M.toggle()
    M.isOpen = not M.isOpen
end

--- Open the editor window
function M.open()
    M.isOpen = true

    -- Select active set if none selected
    local SpellsetManager = getSpellsetManager()
    if SpellsetManager and not M.selectedSet then
        M.selectedSet = SpellsetManager.activeSetName
    end
end

--- Close the editor window
function M.close()
    M.isOpen = false
end

--- Initialize the editor
function M.init()
    local SpellsetManager = getSpellsetManager()
    if SpellsetManager then
        M.selectedSet = SpellsetManager.activeSetName
    end
end

return M
```

**Step 2: Commit**

```bash
git add ui/spell_set_editor.lua
git commit -m "feat(ui): create spell set editor module structure"
```

---

## Task 9: Add Spell Set Editor UI - Main Render

**Files:**
- Modify: `F:/lua/sidekick/ui/spell_set_editor.lua`

**Step 1: Add the main render function**

Add before `return M`:

```lua
--- Render the spell set editor window
function M.render()
    if not M.isOpen then return end

    local SpellsetManager = getSpellsetManager()
    local SpellsClr = getSpellsClr()
    if not SpellsetManager or not SpellsClr then return end

    imgui.SetNextWindowSize(500, 600, ImGuiCond.FirstUseEver)

    local open
    open, M.isOpen = imgui.Begin('Spell Set Editor##SpellSetEditor', M.isOpen)

    if open then
        M.renderHeader(SpellsetManager)
        imgui.Separator()
        M.renderSpellLines(SpellsetManager, SpellsClr)
    end

    imgui.End()

    -- Render popups
    M.renderNewSetPopup(SpellsetManager)
    M.renderDeleteConfirmPopup(SpellsetManager)
    M.renderConditionPopup()
end

--- Render the header (set selector, buttons)
function M.renderHeader(SpellsetManager)
    -- Set selector dropdown
    local setNames = SpellsetManager.getSetNames()
    local currentIdx = 0
    for i, name in ipairs(setNames) do
        if name == M.selectedSet then
            currentIdx = i
            break
        end
    end

    imgui.Text('Spell Set:')
    imgui.SameLine()
    imgui.SetNextItemWidth(200)

    local previewName = M.selectedSet or '(None)'
    if imgui.BeginCombo('##SetSelector', previewName) then
        for i, name in ipairs(setNames) do
            local isSelected = (name == M.selectedSet)
            if imgui.Selectable(name, isSelected) then
                M.selectedSet = name
                SpellsetManager.activateSet(name)
            end
        end
        imgui.EndCombo()
    end

    -- Buttons
    imgui.SameLine()
    if imgui.Button('New') then
        M.newSetName = ''
        M.showNewSetPopup = true
        imgui.OpenPopup('New Spell Set##NewSetPopup')
    end

    imgui.SameLine()
    if imgui.Button('Delete') then
        if M.selectedSet then
            M.showDeleteConfirm = true
            imgui.OpenPopup('Delete Spell Set?##DeleteConfirm')
        end
    end

    imgui.SameLine()
    if imgui.Button('Apply') then
        if M.selectedSet then
            local result = SpellsetManager.applySet(M.selectedSet)
            if result == 'queued' then
                mq.cmd('/echo [SpellSet] Memorization queued for out of combat')
            elseif result == 'applied' then
                mq.cmd('/echo [SpellSet] Memorization started')
            end
        end
    end

    -- Slot counter
    if M.selectedSet then
        local rotationCount = SpellsetManager.countEnabledRotation(M.selectedSet)
        local capacity = SpellsetManager.getRotationCapacity()
        imgui.Text(string.format('Rotation Slots: %d/%d', rotationCount, capacity))
    end
end
```

**Step 2: Commit**

```bash
git add ui/spell_set_editor.lua
git commit -m "feat(ui): add spell set editor header rendering"
```

---

## Task 10: Add Spell Set Editor UI - Line Rendering

**Files:**
- Modify: `F:/lua/sidekick/ui/spell_set_editor.lua`

**Step 1: Add spell line rendering**

```lua
--- Render the spell lines sections
function M.renderSpellLines(SpellsetManager, SpellsClr)
    if not M.selectedSet then
        imgui.TextDisabled('Select or create a spell set to begin.')
        return
    end

    local set = SpellsetManager.getSet(M.selectedSet)
    if not set then return end

    local allLines = SpellsClr.enumerateLines()
    local capacity = SpellsetManager.getRotationCapacity()
    local rotationCount = SpellsetManager.countEnabledRotation(M.selectedSet)
    local atCapacity = rotationCount >= capacity

    -- Category filter
    imgui.Text('Filter:')
    imgui.SameLine()
    imgui.SetNextItemWidth(150)
    if imgui.BeginCombo('##CategoryFilter', M.categoryFilter) then
        if imgui.Selectable('All', M.categoryFilter == 'All') then
            M.categoryFilter = 'All'
        end

        local categories = {}
        for _, line in ipairs(allLines) do
            if not categories[line.category] then
                categories[line.category] = true
                if imgui.Selectable(line.category, M.categoryFilter == line.category) then
                    M.categoryFilter = line.category
                end
            end
        end
        imgui.EndCombo()
    end

    imgui.Separator()

    -- Rotation section
    if imgui.CollapsingHeader('Rotation Spells (combat)', ImGuiTreeNodeFlags.DefaultOpen) then
        M.renderLineSection(SpellsetManager, allLines, set, 'rotation', atCapacity)
    end

    -- Buff swap section
    if imgui.CollapsingHeader('Buff Swap Spells (OOC only)', ImGuiTreeNodeFlags.DefaultOpen) then
        M.renderLineSection(SpellsetManager, allLines, set, 'buff_swap', false)
    end
end

--- Render a section of spell lines
function M.renderLineSection(SpellsetManager, allLines, set, slotType, atCapacity)
    for _, lineInfo in ipairs(allLines) do
        -- Apply category filter
        if M.categoryFilter ~= 'All' and lineInfo.category ~= M.categoryFilter then
            goto continue
        end

        local lineName = lineInfo.lineName
        local lineData = set.lines[lineName] or {}
        local isEnabled = lineData.enabled == true
        local currentSlotType = lineData.slotType or lineInfo.defaultSlotType

        -- Only show lines matching this section's slot type
        if currentSlotType ~= slotType then
            goto continue
        end

        imgui.PushID('line_' .. lineName)

        -- Checkbox (disabled if at capacity and not enabled)
        local canEnable = isEnabled or not atCapacity or slotType ~= 'rotation'

        if not canEnable then
            imgui.BeginDisabled()
        end

        local newEnabled
        newEnabled, _ = imgui.Checkbox('##enabled', isEnabled)

        if not canEnable then
            imgui.EndDisabled()
            if imgui.IsItemHovered(ImGuiHoveredFlags.AllowWhenDisabled) then
                imgui.SetTooltip('Disable another rotation line to enable this one')
            end
        end

        if newEnabled ~= isEnabled then
            if newEnabled then
                SpellsetManager.enableLine(M.selectedSet, lineName, slotType)
            else
                SpellsetManager.disableLine(M.selectedSet, lineName)
            end
        end

        -- Line name
        imgui.SameLine()
        imgui.Text(lineName)

        -- Resolved spell
        local resolved = lineData.resolved or SpellsetManager.resolveSpellFromLine(lineName)
        imgui.SameLine()
        imgui.TextColored(0.6, 0.6, 0.6, 1, '→')
        imgui.SameLine()
        if resolved then
            imgui.TextColored(0.7, 0.9, 0.7, 1, resolved)
        else
            imgui.TextColored(0.9, 0.5, 0.5, 1, '(not in book)')
        end

        -- Condition button
        imgui.SameLine()
        local hasCondition = lineData.condition and lineData.condition.conditions and #lineData.condition.conditions > 0
        if hasCondition then
            imgui.PushStyleColor(ImGuiCol.Button, 0.2, 0.5, 0.2, 1)
        end
        if imgui.SmallButton('Cond##' .. lineName) then
            M.conditionEditLine = lineName
            M.showConditionPopup = true
        end
        if hasCondition then
            imgui.PopStyleColor()
        end

        -- Right-click context menu
        if imgui.BeginPopupContextItem('ctx_' .. lineName) then
            local otherSlot = slotType == 'rotation' and 'buff_swap' or 'rotation'
            local label = slotType == 'rotation' and 'Move to Buff Swap' or 'Move to Rotation'

            if imgui.MenuItem(label) then
                if otherSlot == 'rotation' and atCapacity then
                    mq.cmd('/echo [SpellSet] Cannot move to rotation - at capacity')
                else
                    SpellsetManager.setLineSlotType(M.selectedSet, lineName, otherSlot)
                end
            end
            imgui.EndPopup()
        end

        imgui.PopID()
        ::continue::
    end
end
```

**Step 2: Commit**

```bash
git add ui/spell_set_editor.lua
git commit -m "feat(ui): add spell line rendering with enable/disable"
```

---

## Task 11: Add Spell Set Editor UI - Popups

**Files:**
- Modify: `F:/lua/sidekick/ui/spell_set_editor.lua`

**Step 1: Add popup rendering functions**

```lua
--- Render the new set popup
function M.renderNewSetPopup(SpellsetManager)
    if imgui.BeginPopupModal('New Spell Set##NewSetPopup', nil, ImGuiWindowFlags.AlwaysAutoResize) then
        imgui.Text('Enter a name for the new spell set:')
        imgui.SetNextItemWidth(250)

        local changed
        M.newSetName, changed = imgui.InputText('##NewSetName', M.newSetName, 64)

        imgui.Spacing()

        if imgui.Button('Create', 100, 0) then
            if M.newSetName ~= '' then
                SpellsetManager.createSet(M.newSetName)
                M.selectedSet = M.newSetName
                SpellsetManager.activateSet(M.newSetName)
                SpellsetManager.saveSpellSets()
                imgui.CloseCurrentPopup()
            end
        end

        imgui.SameLine()
        if imgui.Button('Cancel', 100, 0) then
            imgui.CloseCurrentPopup()
        end

        imgui.EndPopup()
    end
end

--- Render the delete confirmation popup
function M.renderDeleteConfirmPopup(SpellsetManager)
    if imgui.BeginPopupModal('Delete Spell Set?##DeleteConfirm', nil, ImGuiWindowFlags.AlwaysAutoResize) then
        imgui.Text(string.format('Are you sure you want to delete "%s"?', M.selectedSet or ''))
        imgui.Spacing()

        if imgui.Button('Delete', 100, 0) then
            SpellsetManager.deleteSet(M.selectedSet)
            M.selectedSet = nil

            -- Select first available set
            local names = SpellsetManager.getSetNames()
            if #names > 0 then
                M.selectedSet = names[1]
                SpellsetManager.activateSet(M.selectedSet)
            end

            imgui.CloseCurrentPopup()
        end

        imgui.SameLine()
        if imgui.Button('Cancel', 100, 0) then
            imgui.CloseCurrentPopup()
        end

        imgui.EndPopup()
    end
end

--- Render the condition editor popup
function M.renderConditionPopup()
    if not M.showConditionPopup or not M.conditionEditLine then return end

    local ConditionBuilder = getConditionBuilder()
    local SpellsetManager = getSpellsetManager()
    if not ConditionBuilder or not SpellsetManager then return end

    local set = SpellsetManager.getSet(M.selectedSet)
    if not set then return end

    local lineData = set.lines[M.conditionEditLine] or {}
    local resolved = lineData.resolved or SpellsetManager.resolveSpellFromLine(M.conditionEditLine)

    imgui.SetNextWindowSize(450, 300, ImGuiCond.FirstUseEver)

    local title = string.format('Condition: %s → %s##CondPopup', M.conditionEditLine, resolved or '?')
    local open = true
    open, _ = imgui.Begin(title, open, ImGuiWindowFlags.NoCollapse)

    if open then
        -- Initialize condition data if needed
        if not M.editingCondition then
            M.editingCondition = lineData.condition or { conditions = {} }
        end

        -- Render condition builder
        ConditionBuilder.render(M.editingCondition)

        imgui.Spacing()
        imgui.Separator()
        imgui.Spacing()

        if imgui.Button('Save', 80, 0) then
            SpellsetManager.setLineCondition(M.selectedSet, M.conditionEditLine, M.editingCondition)
            M.showConditionPopup = false
            M.conditionEditLine = nil
            M.editingCondition = nil
        end

        imgui.SameLine()
        if imgui.Button('Clear', 80, 0) then
            M.editingCondition = { conditions = {} }
        end

        imgui.SameLine()
        if imgui.Button('Cancel', 80, 0) then
            M.showConditionPopup = false
            M.conditionEditLine = nil
            M.editingCondition = nil
        end
    else
        M.showConditionPopup = false
        M.conditionEditLine = nil
        M.editingCondition = nil
    end

    imgui.End()
end
```

**Step 2: Commit**

```bash
git add ui/spell_set_editor.lua
git commit -m "feat(ui): add spell set editor popups"
```

---

## Task 12: Integrate Spell Set Editor into SideKick

**Files:**
- Modify: `F:/lua/sidekick/SideKick.lua`

**Step 1: Add require and init**

Near the top with other requires, add:

```lua
local SpellSetEditor = require('ui.spell_set_editor')
```

In the `main()` function after other inits, add:

```lua
    SpellSetEditor.init()
```

**Step 2: Add render call**

In the `mq.imgui.init('SideKick', function() ... end)` callback, add:

```lua
        SpellSetEditor.render()
```

**Step 3: Add command binding**

In the `/SideKick` command handler, add a case:

```lua
        elseif a1 == 'spellset' or a1 == 'ss' then
            SpellSetEditor.toggle()
```

**Step 4: Commit**

```bash
git add SideKick.lua
git commit -m "feat: integrate spell set editor into SideKick"
```

---

## Task 13: Update sk_healing.lua to Use Spell Sets

**Files:**
- Modify: `F:/lua/sidekick/sk_healing.lua`

**Step 1: Add SpellsetManager integration**

Near the top, add:

```lua
local _SpellsetManager = nil
local function getSpellsetManager()
    if not _SpellsetManager then
        local ok, sm = pcall(require, 'utils.spellset_manager')
        if ok then _SpellsetManager = sm end
    end
    return _SpellsetManager
end

local _ConditionBuilder = nil
local function getConditionBuilder()
    if not _ConditionBuilder then
        local ok, cb = pcall(require, 'ui.condition_builder')
        if ok then _ConditionBuilder = cb end
    end
    return _ConditionBuilder
end
```

**Step 2: Add context builder**

```lua
local function buildHealContext(targetId)
    local target = mq.TLO.Spawn(targetId)
    local me = mq.TLO.Me

    return {
        targetId = targetId,
        targetHp = target and target() and target.PctHPs() or 100,
        targetClass = target and target() and target.Class.ShortName() or '',
        targetType = target and target() and target.Type() or '',
        myHp = me and me() and me.PctHPs() or 100,
        myMana = me and me() and me.PctMana() or 100,
        inCombat = me and me() and me.Combat() or false,
        groupCount = mq.TLO.Group.Members() or 0,
    }
end
```

**Step 3: Update resolveSpell to use spell sets**

Replace or modify the `resolveSpell` function:

```lua
local function resolveSpell(lineKey)
    local SpellsetManager = getSpellsetManager()
    local ConditionBuilder = getConditionBuilder()

    -- Try spell set first
    if SpellsetManager then
        local set = SpellsetManager.getActiveSet()
        if set then
            -- Build context for condition evaluation
            local target = getMATarget() or findHealTarget()
            local ctx = target and buildHealContext(target.id) or {}

            -- Find best matching spell from enabled heal lines
            local spellName = SpellsetManager.findBestSpell('Heals', ctx)
            if spellName then return spellName end

            spellName = SpellsetManager.findBestSpell('GroupHeals', ctx)
            if spellName then return spellName end
        end
    end

    -- Fall back to hardcoded config
    local line = Config.spellLines[lineKey]
    if not line then return nil end
    for _, name in ipairs(line) do
        if isSpellMemorized(name) then
            return name
        end
    end
    return nil
end
```

**Step 4: Commit**

```bash
git add sk_healing.lua
git commit -m "feat(healing): integrate spell set queries"
```

---

## Task 14: Clean Up Test File and Final Verification

**Files:**
- Delete: `F:/lua/sidekick/test_spell_enum.lua` (if created for testing)

**Step 1: Remove test file**

```bash
rm -f test_spell_enum.lua
```

**Step 2: Run SideKick and verify**

In MQ2:
1. `/lua run sidekick`
2. `/sidekick spellset` - Should open spell set editor
3. Create a new spell set
4. Enable some spell lines
5. Click Apply
6. Verify spells are memorized

**Step 3: Final commit**

```bash
git add -A
git commit -m "feat: complete spell set editor implementation"
```

---

## Acceptance Checklist

- [ ] `sk_spells_clr.lua` has `enumerateLines()` function
- [ ] `ConditionBuilder.evaluateWithContext()` works with passed context
- [ ] `SpellsetManager` can create/delete/save/load spell sets
- [ ] `SpellsetManager` enforces rotation capacity limits
- [ ] `SpellsetManager.applySet()` queues if in combat
- [ ] Spell Set Editor UI opens with `/sidekick spellset`
- [ ] Can create new spell sets
- [ ] Can enable/disable spell lines with capacity enforcement
- [ ] Can set conditions on lines
- [ ] Can move lines between rotation and buff_swap
- [ ] Apply button memorizes spells
- [ ] `sk_healing.lua` queries spell sets for heal spells
