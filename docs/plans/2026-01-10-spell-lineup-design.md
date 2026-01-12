# Spell Lineup System Design

## Overview

Gem-based spell lineup system that scans memorized spells, auto-categorizes via SPA effects, and provides them to the spell rotation in priority order.

---

## Part 1: Gem Handling

### Gem Layout

| Gems | Purpose |
|------|---------|
| 1 to (NumGems-1) | Rotation spells - user memorizes their lineup |
| NumGems (last) | Utility gem - reserved for future buff cycling |

### Gem Count Detection

```lua
local numGems = mq.TLO.Me.NumGems() or 8
local rotationGems = numGems - 1
local utilityGem = numGems
```

---

## Part 2: Spell Data Structure

Each scanned spell stores:

```lua
{
    gem = 3,                  -- Gem slot number
    name = "Ice Comet",       -- Spell name
    id = 12345,               -- Spell ID
    category = 'nuke',        -- Auto-detected or override
    resistType = 'Cold',      -- For damage spells (nuke/dot)
    targetType = 'Single',    -- Single, PBAE, TargetAE, Group, etc.
}
```

---

## Part 3: SPA-Based Categorization

### Key SPA IDs

| SPA ID | Effect | Category |
|--------|--------|----------|
| 0 | HP change | heal (beneficial) / nuke (detrimental) |
| 79 | HP over time | heal (beneficial) / dot (detrimental) |
| 11 | Attack Speed | slow |
| 31 | Mesmerize | mez |
| 99 | Root | root |
| 3 | Movement Speed | snare |
| 22 | Charm | charm |
| 23 | Fear | fear |
| 21 | Stun | stun |
| 50 | Magic Resist debuff | tash |
| 46-49 | Other resist debuffs | debuff |

### Categorization Function

```lua
function categorizeSpell(spell)
    if not spell or not spell() then return nil end

    local isDetrimental = spell.SpellType() == 'Detrimental'

    -- Specific CC/debuff effects (check first)
    if spell.HasSPA(31)() then return 'mez' end
    if spell.HasSPA(11)() then return 'slow' end
    if spell.HasSPA(99)() then return 'root' end
    if spell.HasSPA(3)() and isDetrimental then return 'snare' end
    if spell.HasSPA(22)() then return 'charm' end
    if spell.HasSPA(23)() then return 'fear' end
    if spell.HasSPA(21)() then return 'stun' end
    if spell.HasSPA(50)() and isDetrimental then return 'tash' end

    -- Resist debuffs (malo-type)
    for spa = 46, 49 do
        if spell.HasSPA(spa)() and isDetrimental then return 'debuff' end
    end

    -- HP-based: heal vs nuke/dot
    if spell.HasSPA(0)() or spell.HasSPA(79)() then
        if isDetrimental then
            if spell.HasSPA(79)() then return 'dot' end
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

### Resist Type Detection

For nuke/dot spells:

```lua
function getResistType(spell)
    local rt = spell.ResistType and spell.ResistType()
    if rt and rt ~= '' and rt ~= 'Unresistable' then
        return rt  -- Magic, Fire, Cold, Poison, Disease, Chromatic
    end
    return nil
end
```

### Target Type Detection

```lua
function getTargetType(spell)
    local tt = spell.TargetType and spell.TargetType()
    -- Single, Group v1, Group v2, PB AE, Targeted AE, Beam, Self, etc.
    return tt or 'Unknown'
end
```

---

## Part 4: Casting Priority

### Category Priority Order

1. heal (emergency when HP critical)
2. heal (support)
3. mez
4. slow
5. tash
6. debuff
7. nuke
8. dot

### Within Category: Gem Order

Spells in same category fire in gem slot order (1, 2, 3...).

### Priority Table

```lua
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
    buff = 10,
}
```

---

## Part 5: Gem Scanning

### When to Scan

- Script initialization
- Zone change (if `SpellRescanOnZone` enabled)
- Manual rescan command

### Scan Function

```lua
function scanMemorizedSpells()
    local spells = {}
    local numGems = mq.TLO.Me.NumGems() or 8

    for gem = 1, numGems - 1 do  -- Skip utility gem
        local spell = mq.TLO.Me.Gem(gem)
        if spell and spell() and spell.ID() and spell.ID() > 0 then
            local category = categorizeSpell(spell)
            local entry = {
                gem = gem,
                name = spell.Name(),
                id = spell.ID(),
                category = category,
                resistType = nil,
                targetType = getTargetType(spell),
            }

            -- Store resist type for damage spells
            if category == 'nuke' or category == 'dot' then
                entry.resistType = getResistType(spell)
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

    return spells
end
```

---

## Part 6: Integration with Spell Rotation

### Current Flow

```
rotation_engine.tick()
  └── SpellRotation.tick({ spells = {}, settings })  -- Empty!
```

### New Flow

```
rotation_engine.tick()
  └── SpellRotation.tick({ spells = SpellLineup.getSpells(), settings })
```

Or spell_rotation.lua calls SpellLineup internally:

```lua
function M.tick(opts)
    local SpellLineup = getSpellLineup()
    local spells = SpellLineup and SpellLineup.getSpells() or {}
    -- ... rest of tick using spells
end
```

---

## Part 7: Condition Gating (Placeholder)

First pass: Basic conditions only

| Category | Basic Condition |
|----------|-----------------|
| heal | Group member below HealThreshold |
| mez | In combat, add exists |
| slow | Target not slowed |
| tash | Target not tashed |
| debuff | Target not debuffed |
| nuke | In combat, have mana |
| dot | In combat, have mana, target HP > threshold |

Detailed heal targeting and buff weaving deferred to later phases.

---

## Part 8: New Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| SpellRescanOnZone | bool | true | Rescan gems on zone change |
| HealThreshold | number | 80 | HP % to trigger healing |
| HealPetsEnabled | bool | false | Include pets as heal targets |

---

## Part 9: File Structure

### New File

| File | Purpose |
|------|---------|
| `utils/spell_lineup.lua` | Gem scanning, SPA categorization, priority sorting |

### Modified Files

| File | Changes |
|------|---------|
| `utils/spell_rotation.lua` | Get spells from spell_lineup |
| `registry.lua` | Add new settings |
| `SideKick.lua` | Initialize spell_lineup, rescan on zone |

---

## Implementation Order

1. Create `utils/spell_lineup.lua` with SPA categorization
2. Implement gem scanning and sorting
3. Add settings to registry
4. Wire spell_lineup into spell_rotation
5. Add zone change rescan trigger
6. Add basic condition gating per category
