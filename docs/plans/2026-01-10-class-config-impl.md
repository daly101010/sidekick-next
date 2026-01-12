# Class Config System Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create unified class configuration system with prebuilt spell lineups, rotation conditions, and auto-generated settings UI.

**Architecture:** Per-class config files contain AbilitySets, SpellLoadouts, Rotations, and DefaultConfig. Loader resolves abilities, settings UI auto-generates from DefaultConfig metadata.

**Tech Stack:** MacroQuest Lua, mq.TLO.Me, ImGui

---

## Task 1: Create Class Config Loader

**Files:**
- Create: `utils/class_config_loader.lua`

**Step 1: Create module with class config loading**

```lua
-- F:/lua/SideKick/utils/class_config_loader.lua
-- Class Config Loader - Load and resolve class configurations

local mq = require('mq')

local M = {}

-- Cached configs by class
M.configs = {}

-- Current class config
M.current = nil

--- Load class config for specified class
-- @param classShort string Class short name (ENC, WAR, etc.)
-- @return table|nil Class config or nil
function M.load(classShort)
    if not classShort or classShort == '' then return nil end

    -- Check cache
    if M.configs[classShort] then
        M.current = M.configs[classShort]
        return M.current
    end

    -- Try to load
    local path = 'data.class_configs.' .. classShort
    local ok, config = pcall(require, path)
    if ok and config then
        M.configs[classShort] = config
        M.current = config
        return config
    end

    return nil
end

--- Resolve an AbilitySet to the best available ability
-- @param setName string AbilitySet name
-- @param config table Optional specific config (uses current if nil)
-- @return string|nil Best available ability name
function M.resolveAbilitySet(setName, config)
    config = config or M.current
    if not config or not config.AbilitySets then return nil end

    local set = config.AbilitySets[setName]
    if not set then return nil end

    local me = mq.TLO.Me
    if not me or not me() then return nil end

    for _, name in ipairs(set) do
        -- Check spellbook
        local spell = me.Book(name)
        if spell and spell() then
            return name
        end

        -- Check AAs
        local aa = me.AltAbility(name)
        if aa and aa() then
            return name
        end

        -- Check combat abilities (discs)
        local disc = me.CombatAbility(name)
        if disc and disc() then
            return name
        end
    end

    return nil
end

--- Get all resolved abilities for a loadout
-- @param loadoutName string Loadout role name
-- @param config table Optional specific config
-- @return table Gem -> spell name mapping
function M.resolveLoadout(loadoutName, config)
    config = config or M.current
    if not config or not config.SpellLoadouts then return {} end

    local loadout = config.SpellLoadouts[loadoutName]
    if not loadout or not loadout.gems then return {} end

    local resolved = {}
    for gem, setName in pairs(loadout.gems) do
        local spell = M.resolveAbilitySet(setName, config)
        if spell then
            resolved[gem] = spell
        end
    end

    return resolved
end

--- Get available loadout names for current config
-- @return table Array of loadout names
function M.getLoadoutNames()
    if not M.current or not M.current.SpellLoadouts then return {} end

    local names = {}
    for name, loadout in pairs(M.current.SpellLoadouts) do
        table.insert(names, {
            key = name,
            name = loadout.name or name,
        })
    end

    return names
end

--- Get DefaultConfig for current class
-- @return table DefaultConfig or empty table
function M.getDefaultConfig()
    if not M.current or not M.current.DefaultConfig then return {} end
    return M.current.DefaultConfig
end

--- Initialize loader for current character
function M.init()
    local classShort = mq.TLO.Me.Class.ShortName() or ''
    if classShort ~= '' then
        M.load(classShort)
    end
end

return M
```

---

## Task 2: Create Enchanter Class Config

**Files:**
- Create: `data/class_configs/ENC.lua`

**Step 1: Create config with AbilitySets**

```lua
-- F:/lua/SideKick/data/class_configs/ENC.lua
-- Enchanter Class Configuration

local mq = require('mq')

local M = {}

-- AbilitySets: Spell/AA progressions (highest to lowest rank)
M.AbilitySets = {
    -- Single Target Mez
    MezSpell = {
        "Flummox", "Addle", "Deceive", "Delude", "Bewilder", "Confound",
        "Mislead", "Baffle", "Befuddle", "Mystify", "Bewilderment",
        "Euphoria", "Felicity", "Bliss", "Sleep",
    },

    -- Fast Mez
    MezSpellFast = {
        "Deceiving Flash", "Deluding Flash", "Bewildering Flash",
        "Confounding Flash", "Misleading Flash", "Baffling Flash",
        "Befuddling Flash", "Mystifying Flash",
    },

    -- AE Mez
    MezAESpell = {
        "Neutralizing Wave", "Perplexing Wave", "Deadening Wave",
        "Slackening Wave", "Peaceful Wave", "Serene Wave",
        "Ensorcelling Wave", "Quelling Wave", "Wake of Subdual",
        "Wake of Felicity", "Bliss of the Nihil", "Fascination",
    },

    -- Slow
    SlowSpell = {
        "Desolate Deeds", "Dreary Deeds", "Forlorn Deeds",
        "Shiftless Deeds", "Tepid Deeds", "Languid Pace",
    },

    -- Tash (Magic Resist Debuff)
    TashSpell = {
        "Roar of Tashan", "Edict of Tashan", "Proclamation of Tashan",
        "Order of Tashan", "Decree of Tashan", "Enunciation of Tashan",
        "Declaration of Tashan", "Clamor of Tashan", "Bark of Tashan",
        "Din of Tashan", "Echo of Tashan", "Howl of Tashan",
        "Tashanian", "Tashania", "Tashani", "Tashina",
    },

    -- Cripple
    CrippleSpell = {
        "Crippling Snare", "Incapacitate", "Cripple",
    },

    -- Self Rune 1
    SelfRune1 = {
        "Esoteric Rune", "Marvel's Rune", "Deviser's Rune",
        "Transfixer's Rune", "Enticer's Rune", "Mastermind's Rune",
        "Arcanaward's Rune", "Spectral Rune", "Pearlescent Rune",
        "Opalescent Rune", "Draconic Rune", "Ethereal Rune", "Arcane Rune",
    },

    -- Self Rune 2
    SelfRune2 = {
        "Polyradiant Rune", "Polyluminous Rune", "Polycascading Rune",
        "Polyfluorescent Rune", "Polyrefractive Rune", "Polyiridescent Rune",
        "Polyarcanic Rune", "Polyspectral Rune", "Polychaotic Rune",
        "Multichromatic Rune", "Polychromatic Rune",
    },

    -- Group Rune
    GroupRune = {
        "Gloaming Rune", "Eclipsed Rune", "Crepuscular Rune",
        "Tenebrous Rune", "Darkened Rune", "Umbral Rune",
        "Shadowed Rune", "Twilight Rune", "Rune of the Void",
    },

    -- Haste
    HasteSpell = {
        "Hastening of Jharin", "Hastening of Salik", "Hastening of Ellowind",
        "Hastening of Erradien", "Speed of Salik", "Speed of Ellowind",
        "Speed of Erradien", "Speed of Novak", "Speed of Aransir",
        "Speed of Sviir", "Vallon's Quickening", "Visions of Grandeur",
        "Wondrous Rapidity", "Aanya's Quickening", "Swift Like the Wind",
        "Celerity", "Augmentation", "Alacrity", "Quickness",
    },

    -- Mana Regen
    ManaRegenSpell = {
        "Voice of Preordination", "Voice of Perception", "Voice of Sagacity",
        "Voice of Perspicacity", "Voice of Precognition", "Voice of Foresight",
        "Voice of Premeditation", "Voice of Forethought", "Voice of Prescience",
        "Voice of Cognizance", "Voice of Intuition", "Voice of Clairvoyance",
        "Voice of Quellious", "Tranquility", "Koadic's Endless Intellect",
        "Clarity II", "Clarity", "Breeze",
    },

    -- Magic Nuke
    MagicNuke = {
        "Mindrend", "Mindreap", "Mindrift", "Mindslash", "Mindsunder",
        "Mindcleave", "Mindscythe", "Mindblade", "Spectral Assault",
    },

    -- Chromatic Nuke (Fast)
    RuneNuke = {
        "Chromatic Spike", "Chromatic Flare", "Chromatic Stab",
        "Chromatic Flicker", "Chromatic Blink", "Chromatic Percussion",
        "Chromatic Flash", "Chromatic Jab",
    },

    -- Mana Tap Nuke
    ManaTapNuke = {
        "Psychological Appropriation", "Ideological Appropriation",
        "Psychic Appropriation", "Intellectual Appropriation",
        "Mental Appropriation", "Cognitive Appropriation",
    },

    -- Color Stun (PBAE)
    ColorStun = {
        "Color Calibration", "Color Conflagration", "Color Cascade",
        "Color Congruence", "Color Concourse", "Color Conflux",
        "Color Collapse", "Color Cataclysm", "Color Shift", "Color Skew",
    },

    -- Charm
    CharmSpell = {
        "Clamoring Command", "Grating Command", "Imposing Command",
        "Compelling Command", "Crushing Command", "Chaotic Command",
        "Astonishing Command", "Beguiling Command", "Captivating Command",
    },

    -- DoT
    DotSpell = {
        "Mind Whirl", "Mind Twist", "Mind Storm",
    },

    -- AA: Chromatic Haze
    ChromaticHazeAA = { "Chromatic Haze" },

    -- AA: Illusions of Grandeur
    IllusionsOfGrandeurAA = { "Illusions of Grandeur" },

    -- AA: Spire of Enchantment
    SpireOfEnchantmentAA = { "Spire of Enchantment" },

    -- AA: Silent Casting
    SilentCastingAA = { "Silent Casting" },

    -- AA: Eldritch Rune
    EldritchRuneAA = { "Eldritch Rune" },

    -- AA: Dimensional Shield
    DimensionalShieldAA = { "Dimensional Shield" },

    -- AA: Mind Storm
    MindStormAA = { "Mind Storm" },
}

return M
```

---

## Task 3: Add SpellLoadouts to ENC Config

**Files:**
- Modify: `data/class_configs/ENC.lua`

**Step 1: Add SpellLoadouts after AbilitySets**

```lua
-- SpellLoadouts: Role-based gem assignments
M.SpellLoadouts = {
    cc = {
        name = "Crowd Control",
        description = "Focus on mezzing and debuffing",
        gems = {
            [1] = "MezSpell",
            [2] = "MezAESpell",
            [3] = "MezSpellFast",
            [4] = "SlowSpell",
            [5] = "TashSpell",
            [6] = "HasteSpell",
            [7] = "ManaRegenSpell",
            [8] = "SelfRune1",
            [9] = "GroupRune",
        },
    },
    dps = {
        name = "DPS Focused",
        description = "Maximize damage output",
        gems = {
            [1] = "MagicNuke",
            [2] = "RuneNuke",
            [3] = "ManaTapNuke",
            [4] = "DotSpell",
            [5] = "MezSpell",
            [6] = "SlowSpell",
            [7] = "TashSpell",
            [8] = "SelfRune1",
            [9] = "HasteSpell",
        },
    },
    buff = {
        name = "Buff/Support",
        description = "Focus on group buffs",
        gems = {
            [1] = "HasteSpell",
            [2] = "ManaRegenSpell",
            [3] = "GroupRune",
            [4] = "SelfRune1",
            [5] = "SelfRune2",
            [6] = "MezSpell",
            [7] = "SlowSpell",
            [8] = "TashSpell",
        },
    },
}
```

---

## Task 4: Add DefaultConfig to ENC Config

**Files:**
- Modify: `data/class_configs/ENC.lua`

**Step 1: Add DefaultConfig for settings UI**

```lua
-- DefaultConfig: Settings with UI metadata
M.DefaultConfig = {
    -- CC Settings
    DoMez = {
        Default = true,
        Category = "CC",
        DisplayName = "Use Mez",
        Tooltip = "Enable mesmerization of adds",
    },
    DoAEMez = {
        Default = false,
        Category = "CC",
        DisplayName = "Use AE Mez",
        Tooltip = "Enable area mez when multiple adds",
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

    -- Debuff Settings
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
    DoCripple = {
        Default = false,
        Category = "Debuff",
        DisplayName = "Use Cripple",
        Tooltip = "Enable cripple debuff",
    },

    -- Combat Settings
    DoNuke = {
        Default = true,
        Category = "Combat",
        DisplayName = "Use Nukes",
        Tooltip = "Enable damage nukes",
    },
    DoCharm = {
        Default = false,
        Category = "Combat",
        DisplayName = "Use Charm",
        Tooltip = "Enable charm on mobs (advanced)",
    },
    DoManaTap = {
        Default = true,
        Category = "Combat",
        DisplayName = "Use Mana Tap",
        Tooltip = "Enable mana recovery nukes",
    },

    -- Defense Settings
    DoSelfRune = {
        Default = true,
        Category = "Defense",
        DisplayName = "Keep Self Rune",
        Tooltip = "Maintain self-rune buff",
    },
    DoGroupRune = {
        Default = true,
        Category = "Defense",
        DisplayName = "Cast Group Rune",
        Tooltip = "Cast group rune when not in combat",
    },
    EmergencyRuneHP = {
        Default = 40,
        Category = "Defense",
        DisplayName = "Emergency Rune HP %",
        Tooltip = "HP threshold to cast emergency rune",
        Min = 10,
        Max = 80,
    },

    -- Buff Settings
    DoHaste = {
        Default = true,
        Category = "Buff",
        DisplayName = "Cast Haste",
        Tooltip = "Maintain haste on group members",
    },
    DoManaRegen = {
        Default = true,
        Category = "Buff",
        DisplayName = "Cast Mana Regen",
        Tooltip = "Maintain mana regen on casters",
    },

    -- Burn Settings
    UseChromaticHaze = {
        Default = true,
        Category = "Burn",
        DisplayName = "Chromatic Haze",
        Tooltip = "Use Chromatic Haze during burns",
    },
    UseIllusionsOfGrandeur = {
        Default = true,
        Category = "Burn",
        DisplayName = "Illusions of Grandeur",
        Tooltip = "Use Illusions of Grandeur during burns",
    },
    UseSpireOfEnchantment = {
        Default = true,
        Category = "Burn",
        DisplayName = "Spire of Enchantment",
        Tooltip = "Use Spire of Enchantment during burns",
    },
}
```

---

## Task 5: Create Class Settings UI Generator

**Files:**
- Create: `ui/class_settings.lua`

**Step 1: Create UI module**

```lua
-- F:/lua/SideKick/ui/class_settings.lua
-- Class Settings UI - Auto-generates settings from DefaultConfig

local mq = require('mq')
require 'ImGui'

local M = {}

-- Lazy-load dependencies
local _ConfigLoader = nil
local function getConfigLoader()
    if not _ConfigLoader then
        local ok, cl = pcall(require, 'utils.class_config_loader')
        if ok then _ConfigLoader = cl end
    end
    return _ConfigLoader
end

local _Core = nil
local function getCore()
    if not _Core then
        local ok, c = pcall(require, 'utils.core')
        if ok then _Core = c end
    end
    return _Core
end

--- Group settings by category
-- @param defaultConfig table DefaultConfig from class config
-- @return table Categories with their settings
local function groupByCategory(defaultConfig)
    local categories = {}
    local categoryOrder = {}

    for key, meta in pairs(defaultConfig) do
        local cat = meta.Category or "General"

        if not categories[cat] then
            categories[cat] = {}
            table.insert(categoryOrder, cat)
        end

        table.insert(categories[cat], {
            key = key,
            meta = meta,
        })
    end

    -- Sort categories alphabetically
    table.sort(categoryOrder)

    -- Sort settings within each category by DisplayName
    for _, cat in ipairs(categoryOrder) do
        table.sort(categories[cat], function(a, b)
            return (a.meta.DisplayName or a.key) < (b.meta.DisplayName or b.key)
        end)
    end

    return categories, categoryOrder
end

--- Render class-specific settings
-- @param settings table Current settings
-- @param setFunc function Function to save settings (key, value)
function M.render(settings, setFunc)
    local ConfigLoader = getConfigLoader()
    if not ConfigLoader or not ConfigLoader.current then
        ImGui.Text("No class config loaded")
        return
    end

    local defaultConfig = ConfigLoader.getDefaultConfig()
    if not defaultConfig or next(defaultConfig) == nil then
        ImGui.Text("No class settings available")
        return
    end

    local categories, categoryOrder = groupByCategory(defaultConfig)

    for _, catName in ipairs(categoryOrder) do
        local catSettings = categories[catName]

        if ImGui.CollapsingHeader(catName, ImGuiTreeNodeFlags.DefaultOpen) then
            for _, s in ipairs(catSettings) do
                local key = s.key
                local meta = s.meta
                local displayName = meta.DisplayName or key

                -- Get current value, fallback to default
                local currentValue = settings[key]
                if currentValue == nil then
                    currentValue = meta.Default
                end

                local changed = false
                local newValue = currentValue

                -- Render appropriate widget based on type
                if meta.Min ~= nil and meta.Max ~= nil then
                    -- Slider for numeric with range
                    changed, newValue = ImGui.SliderInt(displayName, currentValue or meta.Default, meta.Min, meta.Max)
                elseif type(meta.Default) == 'boolean' then
                    -- Checkbox for boolean
                    changed, newValue = ImGui.Checkbox(displayName, currentValue or false)
                elseif type(meta.Default) == 'number' then
                    -- InputInt for numbers without range
                    changed, newValue = ImGui.InputInt(displayName, currentValue or 0)
                else
                    -- InputText for strings
                    changed, newValue = ImGui.InputText(displayName, currentValue or '', 256)
                end

                -- Show tooltip on hover
                if meta.Tooltip and ImGui.IsItemHovered() then
                    ImGui.SetTooltip(meta.Tooltip)
                end

                -- Save if changed
                if changed and setFunc then
                    setFunc(key, newValue)
                end
            end
        end
    end
end

--- Get default values for all class settings
-- @return table Default values
function M.getDefaults()
    local ConfigLoader = getConfigLoader()
    if not ConfigLoader or not ConfigLoader.current then return {} end

    local defaults = {}
    local defaultConfig = ConfigLoader.getDefaultConfig()

    for key, meta in pairs(defaultConfig) do
        defaults[key] = meta.Default
    end

    return defaults
end

return M
```

---

## Task 6: Wire Class Settings into Main Settings UI

**Files:**
- Modify: `ui/settings.lua`

**Step 1: Add ClassSettings lazy-load**

Add after other lazy-loads:

```lua
local _ClassSettings = nil
local function getClassSettings()
    if not _ClassSettings then
        local ok, cs = pcall(require, 'ui.class_settings')
        if ok then _ClassSettings = cs end
    end
    return _ClassSettings
end
```

**Step 2: Add class settings section**

Find the spells section and add after it:

```lua
        ImGui.Separator()
        if ImGui.CollapsingHeader('Class Abilities', ImGuiTreeNodeFlags.DefaultOpen) then
            local ClassSettings = getClassSettings()
            if ClassSettings then
                ClassSettings.render(settings, Core.set)
            end
        end
```

---

## Task 7: Wire Loader into SideKick Init

**Files:**
- Modify: `SideKick.lua`

**Step 1: Add ClassConfigLoader require**

After other requires:

```lua
local ClassConfigLoader = require('utils.class_config_loader')
```

**Step 2: Initialize in main()**

After SpellLineup.init():

```lua
ClassConfigLoader.init()
```

---

## Task 8: Add Rotations to ENC Config

**Files:**
- Modify: `data/class_configs/ENC.lua`

**Step 1: Add Rotations table**

```lua
-- Rotations: Priority-ordered actions with conditions
M.Rotations = {
    -- Emergency layer (health critical)
    Emergency = {
        { name = "EldritchRuneAA", type = "aa", settingKey = "DoSelfRune" },
        { name = "DimensionalShieldAA", type = "aa" },
    },

    -- Support layer (debuffs, CC)
    Support = {
        { name = "MezSpell", type = "spell", settingKey = "DoMez",
          cond = "AddCount > 0" },
        { name = "SlowSpell", type = "spell", settingKey = "DoSlow",
          cond = "Target.Slowed.ID == nil" },
        { name = "TashSpell", type = "spell", settingKey = "DoTash",
          cond = "Target.Tashed.ID == nil" },
        { name = "CrippleSpell", type = "spell", settingKey = "DoCripple" },
    },

    -- Combat layer (damage)
    Combat = {
        { name = "MagicNuke", type = "spell", settingKey = "DoNuke" },
        { name = "RuneNuke", type = "spell", settingKey = "DoNuke" },
        { name = "ManaTapNuke", type = "spell", settingKey = "DoManaTap" },
        { name = "MindStormAA", type = "aa", settingKey = "DoNuke" },
    },

    -- Burn layer (when burn active)
    Burn = {
        { name = "ChromaticHazeAA", type = "aa", settingKey = "UseChromaticHaze" },
        { name = "IllusionsOfGrandeurAA", type = "aa", settingKey = "UseIllusionsOfGrandeur" },
        { name = "SpireOfEnchantmentAA", type = "aa", settingKey = "UseSpireOfEnchantment" },
        { name = "SilentCastingAA", type = "aa" },
    },

    -- Utility layer (buffs, out of combat)
    Utility = {
        { name = "SelfRune1", type = "spell", settingKey = "DoSelfRune",
          cond = "not Me.FindBuff" },
        { name = "GroupRune", type = "spell", settingKey = "DoGroupRune",
          cond = "not InCombat" },
        { name = "HasteSpell", type = "spell", settingKey = "DoHaste",
          cond = "not InCombat" },
        { name = "ManaRegenSpell", type = "spell", settingKey = "DoManaRegen",
          cond = "not InCombat" },
    },
}
```

---

## Task 9: Add resolveAbilitySet to ENC Config

**Files:**
- Modify: `data/class_configs/ENC.lua`

**Step 1: Add helper functions at end of file**

```lua
--- Resolve an AbilitySet to the best available ability
-- @param setName string AbilitySet name
-- @return string|nil Best available ability name
function M.resolveAbilitySet(setName)
    local set = M.AbilitySets[setName]
    if not set then return nil end

    local me = mq.TLO.Me
    if not me or not me() then return nil end

    for _, name in ipairs(set) do
        -- Check spellbook
        local spell = me.Book(name)
        if spell and spell() then
            return name
        end

        -- Check AAs
        local aa = me.AltAbility(name)
        if aa and aa() then
            return name
        end
    end

    return nil
end

--- Resolve a loadout to gem -> spell mapping
-- @param loadoutName string Loadout role name
-- @return table Gem -> spell name mapping
function M.resolveLoadout(loadoutName)
    local loadout = M.SpellLoadouts[loadoutName]
    if not loadout or not loadout.gems then return {} end

    local resolved = {}
    for gem, setName in pairs(loadout.gems) do
        local spell = M.resolveAbilitySet(setName)
        if spell then
            resolved[gem] = spell
        end
    end

    return resolved
end

return M
```

---

## Summary

**New Files:**
- `utils/class_config_loader.lua` - Load and resolve class configs
- `data/class_configs/ENC.lua` - Enchanter unified config
- `ui/class_settings.lua` - Auto-generate settings UI from DefaultConfig

**Modified Files:**
- `ui/settings.lua` - Include class settings panel
- `SideKick.lua` - Initialize ClassConfigLoader

**Total: 9 Tasks**
