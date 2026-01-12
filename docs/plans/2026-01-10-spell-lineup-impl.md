# Spell Lineup System Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement gem-based spell lineup system that scans memorized spells, auto-categorizes them, and provides sorted spell list to rotation.

**Architecture:** spell_lineup.lua scans gems 1-(NumGems-1), categorizes via SPA effects, sorts by category priority then gem order, provides to spell_rotation.lua.

**Tech Stack:** MacroQuest Lua, mq.TLO.Me.Gem(), spell.HasSPA()

---

## Task 1: Add Spell Lineup Settings to Registry

**Files:**
- Modify: `registry.lua`

**Step 1: Add new settings after Spell Rotation Settings**

```lua
    -- Spell Lineup Settings
    SpellRescanOnZone = { type = 'bool', Default = true, Category = 'Spells', DisplayName = 'Rescan Gems on Zone' },
    HealThreshold = { type = 'number', Default = 80, Category = 'Spells', DisplayName = 'Heal HP Threshold' },
    HealPetsEnabled = { type = 'bool', Default = false, Category = 'Spells', DisplayName = 'Heal Pets' },
```

---

## Task 2: Create Spell Lineup Module

**Files:**
- Create: `utils/spell_lineup.lua`

**Step 1: Create module with SPA constants and state**

```lua
-- F:/lua/SideKick/utils/spell_lineup.lua
-- Spell Lineup - Gem scanning and spell categorization

local mq = require('mq')

local M = {}

-- Cached spell list
M.spells = {}
M.lastScanZone = ''

-- SPA IDs for categorization
M.SPA = {
    HP = 0,
    MOVEMENT_SPEED = 3,
    ATTACK_SPEED = 11,
    STUN = 21,
    CHARM = 22,
    FEAR = 23,
    MESMERIZE = 31,
    RESIST_FIRE = 46,
    RESIST_COLD = 47,
    RESIST_POISON = 48,
    RESIST_DISEASE = 49,
    RESIST_MAGIC = 50,
    HP_OVER_TIME = 79,
    ROOT = 99,
}

-- Category priority (lower = higher priority)
M.CATEGORY_PRIORITY = {
    heal = 1,
    mez = 2,
    slow = 3,
    tash = 4,
    debuff = 5,
    nuke = 6,
    dot = 7,
    snare = 8,
    root = 9,
    charm = 10,
    fear = 11,
    stun = 12,
    buff = 20,
}

return M
```

---

## Task 3: Implement Spell Categorization

**Files:**
- Modify: `utils/spell_lineup.lua`

**Step 1: Add categorizeSpell function**

```lua
--- Categorize a spell based on its SPA effects
-- @param spell userdata MQ Spell object
-- @return string Category name
function M.categorizeSpell(spell)
    if not spell or not spell() then return nil end

    local isDetrimental = spell.SpellType() == 'Detrimental'

    -- Check specific CC/debuff effects first (most specific wins)
    if spell.HasSPA(M.SPA.MESMERIZE)() then return 'mez' end
    if spell.HasSPA(M.SPA.ATTACK_SPEED)() and isDetrimental then return 'slow' end
    if spell.HasSPA(M.SPA.ROOT)() then return 'root' end
    if spell.HasSPA(M.SPA.MOVEMENT_SPEED)() and isDetrimental then return 'snare' end
    if spell.HasSPA(M.SPA.CHARM)() then return 'charm' end
    if spell.HasSPA(M.SPA.FEAR)() then return 'fear' end
    if spell.HasSPA(M.SPA.STUN)() and isDetrimental then return 'stun' end
    if spell.HasSPA(M.SPA.RESIST_MAGIC)() and isDetrimental then return 'tash' end

    -- Resist debuffs (malo-type)
    if isDetrimental then
        for _, spa in ipairs({M.SPA.RESIST_FIRE, M.SPA.RESIST_COLD, M.SPA.RESIST_POISON, M.SPA.RESIST_DISEASE}) do
            if spell.HasSPA(spa)() then return 'debuff' end
        end
    end

    -- HP-based: heal vs nuke/dot
    local hasHP = spell.HasSPA(M.SPA.HP)()
    local hasHPot = spell.HasSPA(M.SPA.HP_OVER_TIME)()
    if hasHP or hasHPot then
        if isDetrimental then
            if hasHPot then return 'dot' end
            return 'nuke'
        else
            return 'heal'
        end
    end

    -- Fallback
    if isDetrimental then return 'debuff' end
    return 'buff'
end
```

**Step 2: Add helper functions for resist/target type**

```lua
--- Get resist type for a spell
-- @param spell userdata MQ Spell object
-- @return string|nil Resist type or nil
function M.getResistType(spell)
    if not spell or not spell() then return nil end
    local rt = spell.ResistType and spell.ResistType()
    if rt and rt ~= '' and rt ~= 'Unresistable' then
        return rt
    end
    return nil
end

--- Get target type for a spell
-- @param spell userdata MQ Spell object
-- @return string Target type
function M.getTargetType(spell)
    if not spell or not spell() then return 'Unknown' end
    local tt = spell.TargetType and spell.TargetType()
    return tt or 'Unknown'
end
```

---

## Task 4: Implement Gem Scanning

**Files:**
- Modify: `utils/spell_lineup.lua`

**Step 1: Add scan function**

```lua
--- Scan memorized spells and build sorted list
-- @return table Array of spell entries
function M.scan()
    local spells = {}
    local numGems = mq.TLO.Me.NumGems() or 8

    -- Scan gems 1 to (NumGems-1), skip utility gem
    for gem = 1, numGems - 1 do
        local spell = mq.TLO.Me.Gem(gem)
        if spell and spell() and spell.ID() and spell.ID() > 0 then
            local category = M.categorizeSpell(spell)
            local entry = {
                gem = gem,
                name = spell.Name(),
                id = spell.ID(),
                category = category,
                resistType = nil,
                targetType = M.getTargetType(spell),
            }

            -- Store resist type for damage spells
            if category == 'nuke' or category == 'dot' then
                entry.resistType = M.getResistType(spell)
            end

            table.insert(spells, entry)
        end
    end

    -- Sort by category priority, then gem order
    table.sort(spells, function(a, b)
        local prioA = M.CATEGORY_PRIORITY[a.category] or 99
        local prioB = M.CATEGORY_PRIORITY[b.category] or 99
        if prioA ~= prioB then
            return prioA < prioB
        end
        return a.gem < b.gem
    end)

    M.spells = spells
    M.lastScanZone = mq.TLO.Zone.ShortName() or ''

    return spells
end

--- Get cached spells, rescan if needed
-- @param forceRescan boolean Force a rescan
-- @return table Array of spell entries
function M.getSpells(forceRescan)
    if forceRescan or #M.spells == 0 then
        return M.scan()
    end
    return M.spells
end
```

---

## Task 5: Add Zone Change Detection

**Files:**
- Modify: `utils/spell_lineup.lua`

**Step 1: Add zone check function**

```lua
--- Check if zone changed and rescan if needed
-- @param settings table Settings table
function M.checkZoneChange(settings)
    if not settings or settings.SpellRescanOnZone == false then return end

    local currentZone = mq.TLO.Zone.ShortName() or ''
    if currentZone ~= M.lastScanZone and currentZone ~= '' then
        M.scan()
    end
end

--- Initialize spell lineup
function M.init()
    M.scan()
end
```

---

## Task 6: Wire Spell Lineup into Spell Rotation

**Files:**
- Modify: `utils/spell_rotation.lua`

**Step 1: Add lazy-load for SpellLineup**

Add after other lazy-load functions:

```lua
local _SpellLineup = nil
local function getSpellLineup()
    if not _SpellLineup then
        local ok, sl = pcall(require, 'utils.spell_lineup')
        if ok then _SpellLineup = sl end
    end
    return _SpellLineup
end
```

**Step 2: Update M.tick to use SpellLineup**

Modify tick function to get spells from lineup:

```lua
function M.tick(opts)
    opts = opts or {}
    local settings = opts.settings or {}

    if not settings.SpellRotationEnabled then return end

    -- Get spells from lineup (replaces opts.spells)
    local SpellLineup = getSpellLineup()
    local spells = {}
    if SpellLineup then
        SpellLineup.checkZoneChange(settings)
        spells = SpellLineup.getSpells()
    end

    -- ... rest of existing tick logic using spells
```

---

## Task 7: Add Basic Condition Checks

**Files:**
- Modify: `utils/spell_rotation.lua`

**Step 1: Add category condition function**

```lua
--- Check if a spell's category conditions are met
-- @param spellEntry table Spell entry from lineup
-- @param settings table Settings
-- @return boolean True if conditions met
function M.checkCategoryCondition(spellEntry, settings)
    local category = spellEntry.category
    if not category then return false end

    local Cache = getCache()
    local inCombat = Cache and Cache.inCombat() or false

    -- Heal: someone below threshold (basic check)
    if category == 'heal' then
        local threshold = settings.HealThreshold or 80
        -- Basic: check self HP for now
        local myHp = mq.TLO.Me.PctHPs() or 100
        return myHp < threshold
    end

    -- CC/Debuffs: in combat with valid target
    if category == 'mez' or category == 'slow' or category == 'tash' or category == 'debuff' then
        if not inCombat then return false end
        local targetId = mq.TLO.Target.ID() or 0
        return targetId > 0
    end

    -- Damage: in combat with target
    if category == 'nuke' or category == 'dot' then
        if not inCombat then return false end
        local targetId = mq.TLO.Target.ID() or 0
        return targetId > 0
    end

    -- Root/Snare: in combat
    if category == 'root' or category == 'snare' then
        return inCombat
    end

    -- Buff: not in combat (basic)
    if category == 'buff' then
        return not inCombat
    end

    return true
end
```

**Step 2: Update selectNextSpell to use condition check**

Add condition check in the spell selection loop:

```lua
        -- Check category condition
        if not M.checkCategoryCondition(spellDef, settings) then
            goto continue
        end
```

---

## Task 8: Wire Spell Lineup Lifecycle

**Files:**
- Modify: `SideKick.lua`

**Step 1: Add SpellLineup require**

```lua
local SpellLineup = require('utils.spell_lineup')
```

**Step 2: Initialize in main()**

```lua
SpellLineup.init()
```

---

## Task 9: Add Settings UI

**Files:**
- Modify: `ui/settings.lua`

**Step 1: Add Spell Lineup settings to Spell Rotation section**

After existing spell rotation settings:

```lua
        ImGui.Separator()
        ImGui.Text('Spell Lineup')

        changed, settings.SpellRescanOnZone = ImGui.Checkbox('Rescan Gems on Zone', settings.SpellRescanOnZone ~= false)
        if changed then Core.set('SpellRescanOnZone', settings.SpellRescanOnZone) end

        changed, settings.HealThreshold = ImGui.SliderInt('Heal HP Threshold', settings.HealThreshold or 80, 10, 100)
        if changed then Core.set('HealThreshold', settings.HealThreshold) end

        changed, settings.HealPetsEnabled = ImGui.Checkbox('Heal Pets', settings.HealPetsEnabled or false)
        if changed then Core.set('HealPetsEnabled', settings.HealPetsEnabled) end
```

---

## Summary

**New File:**
- `utils/spell_lineup.lua` - Gem scanning, SPA categorization, priority sorting

**Modified Files:**
- `registry.lua` - Add SpellRescanOnZone, HealThreshold, HealPetsEnabled
- `utils/spell_rotation.lua` - Wire in SpellLineup, add condition checks
- `SideKick.lua` - Initialize SpellLineup
- `ui/settings.lua` - Add lineup settings UI

**Total: 9 Tasks**
