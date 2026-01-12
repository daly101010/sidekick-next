# Class Config System Design

## Overview

Unified class configuration system that provides prebuilt spell lineups, rotation conditions, and settings UI based on RGMercs patterns. Consolidates spellsets, class_configs, and UI settings into one per-class file.

---

## Part 1: File Structure

### Current Structure
```
data/
  spellsets/ENC.lua     -- Spell lines and role loadouts
  class_configs/WAR.lua -- Ability sets and conditions
  classes/ENC.lua       -- AA ability definitions
```

### New Structure
```
data/
  class_configs/
    ENC.lua   -- Unified: spellsets + ability sets + rotations + settings
    SHM.lua   -- Same pattern
    WAR.lua   -- Already exists, extend with rotations
    ...
```

---

## Part 2: Class Config Structure

```lua
local M = {}

-- 1. AbilitySets: Spell/AA progressions (highest to lowest rank)
M.AbilitySets = {
    MezSpell = { "Flummox", "Addle", "Deceive", ... },
    SlowSpell = { "Desolate Deeds", "Dreary Deeds", ... },
    TashSpell = { "Roar of Tashan", "Edict of Tashan", ... },
    -- AAs
    MindStormAA = { "Mindstorm Mantle", ... },
}

-- 2. SpellLoadouts: Role-based gem assignments
M.SpellLoadouts = {
    cc = {
        name = "Crowd Control",
        gems = {
            [1] = "MezSpell",
            [2] = "MezAESpell",
            [3] = "SlowSpell",
            [4] = "TashSpell",
            ...
        },
    },
    dps = { ... },
    buff = { ... },
}

-- 3. Rotations: Priority-ordered actions with conditions
M.Rotations = {
    -- Emergency layer
    Emergency = {
        { name = "SelfRune1", type = "spell", cond = "Me.PctHPs < 40" },
    },
    -- Support layer (debuffs, CC)
    Support = {
        { name = "MezSpell", type = "spell", cond = "AddCount > 1", target = "add" },
        { name = "SlowSpell", type = "spell", cond = "Target.Slowed.ID == nil" },
        { name = "TashSpell", type = "spell", cond = "Target.Tashed.ID == nil" },
    },
    -- Combat layer (damage)
    Combat = {
        { name = "MagicNuke", type = "spell" },
        { name = "RuneNuke", type = "spell" },
        { name = "MindStormAA", type = "aa" },
    },
    -- Burn layer
    Burn = {
        { name = "SpireOfEnchantment", type = "aa" },
        { name = "FocusedDestruction", type = "aa" },
    },
}

-- 4. DefaultConfig: Settings with UI metadata
M.DefaultConfig = {
    DoMez = {
        Default = true,
        Category = "CC",
        DisplayName = "Use Mez",
        Tooltip = "Enable mesmerization of adds",
    },
    DoSlow = {
        Default = true,
        Category = "Debuff",
        DisplayName = "Use Slow",
        Tooltip = "Enable slow on targets",
    },
    DoTash = {
        Default = true,
        Category = "Debuff",
        DisplayName = "Use Tash",
        Tooltip = "Enable magic resist debuff",
    },
    DoNuke = {
        Default = true,
        Category = "Combat",
        DisplayName = "Use Nukes",
        Tooltip = "Enable damage nukes",
    },
    DoSelfRune = {
        Default = true,
        Category = "Defense",
        DisplayName = "Self Rune",
        Tooltip = "Keep self-rune active",
    },
    MaxMezTargets = {
        Default = 3,
        Category = "CC",
        DisplayName = "Max Mez Targets",
        Tooltip = "Maximum number of mobs to mez",
        Min = 1,
        Max = 10,
    },
    MezRadius = {
        Default = 100,
        Category = "CC",
        DisplayName = "Mez Radius",
        Tooltip = "Distance to check for mez targets",
        Min = 30,
        Max = 200,
    },
}

return M
```

---

## Part 3: Condition System

### Simple Condition Strings
For basic checks, use condition strings that the engine evaluates:
```lua
cond = "Me.PctHPs < 40"
cond = "Target.Slowed.ID == nil"
cond = "AddCount > 1"
```

### Condition Variables
Engine provides these variables to condition evaluator:
| Variable | Meaning |
|----------|---------|
| Me | mq.TLO.Me |
| Target | mq.TLO.Target |
| AddCount | Number of XTarget adds |
| InCombat | boolean - in combat |
| Settings | Current settings table |

### Complex Conditions (AST)
For complex logic, use condition AST (already in condition_builder):
```lua
cond = {
    type = 'and',
    children = {
        { type = 'comparison', left = 'Me.PctHPs', op = '<', right = '40' },
        { type = 'comparison', left = 'Target.Named', op = '==', right = 'true' },
    },
}
```

---

## Part 4: Rotation Engine Integration

### Current Flow
```
rotation_engine.tick()
  └── executes AA/disc rotations
  └── SpellRotation.tick()
        └── uses SpellLineup.getSpells() for gems
```

### New Flow
```
rotation_engine.tick()
  └── ClassConfig.getRotation(layer)
        └── evaluates conditions
        └── returns next action
  └── executes action (AA/disc/spell)
```

### Layer Priority
1. Emergency (health critical)
2. Support (debuffs, CC, heals)
3. Combat (damage)
4. Burn (when burn active)
5. Utility (buffs, out of combat)

---

## Part 5: Spell Resolution

### resolveAbilitySet(setName)
```lua
function M.resolveAbilitySet(setName)
    local set = M.AbilitySets[setName]
    if not set then return nil end

    for _, name in ipairs(set) do
        local spell = mq.TLO.Me.Book(name)
        if spell and spell() then return name end

        local aa = mq.TLO.Me.AltAbility(name)
        if aa and aa() then return name end
    end
    return nil
end
```

### applyLoadout(roleName)
```lua
function M.applyLoadout(roleName)
    local loadout = M.SpellLoadouts[roleName]
    if not loadout then return false end

    local resolved = {}
    for gem, setName in pairs(loadout.gems) do
        local spell = M.resolveAbilitySet(setName)
        if spell then
            resolved[gem] = spell
        end
    end

    -- Use gem_manager to memorize
    return resolved
end
```

---

## Part 6: Settings UI Generation

### Category Grouping
Settings are grouped by Category for UI display:
```lua
local categories = {}
for key, meta in pairs(ClassConfig.DefaultConfig) do
    local cat = meta.Category or "General"
    categories[cat] = categories[cat] or {}
    table.insert(categories[cat], { key = key, meta = meta })
end
```

### Widget Rendering
```lua
for catName, settings in pairs(categories) do
    if ImGui.CollapsingHeader(catName) then
        for _, s in ipairs(settings) do
            if s.meta.Min and s.meta.Max then
                -- Slider for numeric with range
                ImGui.SliderInt(s.meta.DisplayName, value, s.meta.Min, s.meta.Max)
            elseif type(s.meta.Default) == 'boolean' then
                -- Checkbox for boolean
                ImGui.Checkbox(s.meta.DisplayName, value)
            else
                -- InputText for other
                ImGui.InputText(s.meta.DisplayName, value)
            end
            if s.meta.Tooltip and ImGui.IsItemHovered() then
                ImGui.SetTooltip(s.meta.Tooltip)
            end
        end
    end
end
```

---

## Part 7: Files to Create/Modify

### New Files
| File | Purpose |
|------|---------|
| `data/class_configs/ENC.lua` | Enchanter unified config |
| `utils/class_config_loader.lua` | Load and resolve class configs |
| `ui/class_settings.lua` | Generate settings UI from DefaultConfig |

### Modified Files
| File | Changes |
|------|---------|
| `utils/rotation_engine.lua` | Integrate ClassConfig rotations |
| `ui/settings.lua` | Include class settings panel |
| `SideKick.lua` | Load class config on init |

---

## Implementation Order

1. Create class_config_loader.lua with resolveAbilitySet()
2. Create ENC.lua with AbilitySets and DefaultConfig
3. Create class_settings.lua for UI generation
4. Wire loader into rotation_engine
5. Add class settings to settings.lua
6. Add SpellLoadouts and applyLoadout()
7. Add Rotations and condition evaluation
