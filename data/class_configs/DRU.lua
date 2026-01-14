-- F:/lua/SideKick/data/class_configs/DRU.lua
-- Druid Class Configuration with condition-based rotations

local mq = require('mq')

local M = {}

-- Spell Lines
M.spellLines = {
    -- Quick Heal Surge
    ['QuickHealSurge'] = {
        "Adrenaline Surge", "Resurgence", "Survival of the Auspicious",
        "Survival of the Favorable", "Survival of the Serendipitous",
        "Survival of the Fortuitous", "Survival of the Unrelenting",
    },

    -- Quick Heal
    ['QuickHeal'] = {
        "Rejuvenation of the Arbor", "Resurgence of the Arbor",
        "Revitalization of the Arbor", "Renewal of the Arbor",
        "Restoration of the Arbor", "Revival of the Arbor",
    },

    -- Long Heal 1
    ['LongHeal1'] = {
        "Sylvan Remedy", "Sylvan Touch", "Sylvan Infusion",
        "Sylvan Light", "Sylvan Salve", "Sylvan Water",
    },

    -- Quick Group Heal
    ['QuickGroupHeal'] = {
        "Lunasoothe", "Moonsoothe", "Sunsoothe",
        "Planetsoothe", "Starsoothe", "Solarsoothe",
    },

    -- Long Group Heal
    ['LongGroupHeal'] = {
        "Survival of the Favored", "Survival of the Fittest",
        "Survival of the Unrelenting", "Moonshadow",
    },

    -- Sun Nuke
    ['SunNuke'] = {
        "Sunpyre", "Sunflash", "Sunfire", "Sunstrike",
        "Sunblaze", "Sunray", "Sunburst",
    },

    -- Fire DoT
    ['FireDoT'] = {
        "Horde of Duskwigs", "Horde of Hotaria", "Horde of Hyperboreads",
        "Horde of Polybiads", "Horde of Fireants", "Swarm of Fireants",
    },

    -- Nature DoT
    ['NatureDoT'] = {
        "Nature's Frozen Wrath", "Nature's Frost", "Nature's Blight",
        "Nature's Entropy", "Nature's Decay", "Immolation of Nature",
    },

    -- Debuff (Magic/Fire)
    ['Debuff'] = {
        "Blessing of Ro", "Hand of Ro", "Sun's Corona",
        "Vengeance of the Sun", "Ro's Fiery Sundering",
    },

    -- Snare
    ['Snare'] = {
        "Ensnare", "Tangling Weeds", "Snare",
    },

    -- Root
    ['Root'] = {
        "Vinelash Assault", "Vinelash Cascade", "Savage Roots",
        "Entrapping Roots", "Engorging Roots", "Root",
    },

    -- Skin (HP buff)
    ['Skin'] = {
        "Opaline Skin", "Pellucid Skin", "Lucid Skin",
        "Crystalline Skin", "Virtuous Skin", "Steeloak Skin",
    },

    -- DS (damage shield)
    ['DamageShield'] = {
        "Viridifloral Shield", "Viridithorn Shield", "Briarcoat",
        "Thorncoat", "Spikecoat", "Barbcoat",
    },

    -- Regen
    ['Regen'] = {
        "Mask of the Shadowcat", "Mask of the Stalker",
        "Mask of the Hunter", "Mask of the Wild",
        "Reptile", "Pack Regeneration", "Regeneration",
    },
}

-- AA Lines
M.aaLines = {
    ['Convergence'] = { "Convergence of Spirits" },
    ['NaturesGuardian'] = { "Nature's Guardian" },
    ['SpiritOfTheWood'] = { "Spirit of the Wood" },
    ['NaturesBoon'] = { "Nature's Boon" },
    ['Swarm'] = { "Swarm of Fireflies" },
    ['SpireOfNature'] = { "Spire of Nature" },
    ['ImprovedTwincast'] = { "Improved Twincast" },
}

-- Default conditions
M.defaultConditions = {
    ['doConvergence'] = function(ctx)
        return ctx.group.injured(40) >= 3
    end,
    ['doNaturesGuardian'] = function(ctx)
        return ctx.me.pctHPs < 30
    end,
    ['doSpiritOfTheWood'] = function(ctx)
        return ctx.group.injured(50) >= 4
    end,

    ['doQuickHealSurge'] = function(ctx)
        return ctx.group.lowestHP < 75
    end,
    ['doQuickHeal'] = function(ctx)
        return ctx.group.lowestHP < 80
    end,
    ['doLongHeal1'] = function(ctx)
        return ctx.group.lowestHP < 50
    end,
    ['doQuickGroupHeal'] = function(ctx)
        return ctx.group.injured(70) >= 2
    end,
    ['doLongGroupHeal'] = function(ctx)
        return ctx.group.injured(60) >= 3
    end,

    ['doSunNuke'] = function(ctx)
        return ctx.combat and ctx.me.pctMana > 50 and ctx.target.pctHPs > 20
    end,
    ['doFireDoT'] = function(ctx)
        return ctx.combat and ctx.target.named and not ctx.target.myBuff('Horde') and ctx.target.pctHPs > 30
    end,
    ['doNatureDoT'] = function(ctx)
        return ctx.combat and ctx.target.named and not ctx.target.myBuff('Nature') and ctx.target.pctHPs > 30
    end,
    ['doDebuff'] = function(ctx)
        return ctx.combat and not ctx.target.myBuff('Ro') and ctx.target.pctHPs > 50
    end,
    ['doSnare'] = function(ctx)
        return ctx.combat and not ctx.target.buff('Snare')
    end,
    ['doRoot'] = function(ctx)
        return ctx.combat and ctx.me.xTargetCount > 1
    end,

    ['doSkin'] = function(ctx)
        return not ctx.combat
    end,
    ['doDamageShield'] = function(ctx)
        return not ctx.combat
    end,
    ['doRegen'] = function(ctx)
        return not ctx.combat
    end,

    ['doSpireOfNature'] = function(ctx)
        return ctx.burn
    end,
    ['doImprovedTwincast'] = function(ctx)
        return ctx.burn and not ctx.me.buff('Improved Twincast') and not ctx.me.buff('Twincast')
    end,
}

-- Category overrides
M.categoryOverrides = {
    ['doConvergence'] = 'emergency',
    ['doNaturesGuardian'] = 'emergency',
    ['doSpiritOfTheWood'] = 'emergency',
    ['doQuickHealSurge'] = 'support',
    ['doQuickHeal'] = 'support',
    ['doLongHeal1'] = 'support',
    ['doQuickGroupHeal'] = 'support',
    ['doLongGroupHeal'] = 'support',
    ['doSunNuke'] = 'combat',
    ['doFireDoT'] = 'combat',
    ['doNatureDoT'] = 'combat',
    ['doDebuff'] = 'combat',
    ['doSnare'] = 'combat',
    ['doRoot'] = 'support',
    ['doSkin'] = 'buff',
    ['doDamageShield'] = 'buff',
    ['doRegen'] = 'buff',
    ['doSpireOfNature'] = 'burn',
    ['doImprovedTwincast'] = 'burn',
}

-- AbilitySets: Spell/AA progressions (highest to lowest rank)
M.AbilitySets = {
    -- Quick heals (Adrenaline line)
    QuickHealSurge = {
        "Adrenaline Fury", "Adrenaline Spate", "Adrenaline Deluge",
        "Adrenaline Barrage", "Adrenaline Torrent", "Adrenaline Rush",
        "Adrenaline Surge", "Resurgence", "Survival of the Auspicious",
    },
    QuickHeal = {
        "Resuscitation", "Sootheseance", "Rejuvenescence", "Revitalization",
        "Rejuvenation of the Arbor", "Resurgence of the Arbor",
        "Revitalization of the Arbor", "Renewal of the Arbor",
    },
    -- Long heal
    LongHeal1 = {
        "Vivavida", "Clotavida", "Viridavida", "Curavida", "Panavida",
        "Sylvan Remedy", "Sylvan Touch", "Sylvan Infusion",
        "Sylvan Light", "Sylvan Salve", "Sylvan Water",
    },
    -- Group heals
    QuickGroupHeal = {
        "Survival of the Heroic", "Survival of the Unrelenting",
        "Survival of the Favored", "Survival of the Auspicious",
        "Lunasoothe", "Moonsoothe", "Sunsoothe",
        "Planetsoothe", "Starsoothe", "Solarsoothe",
    },
    LongGroupHeal = {
        "Lunacea", "Lunarush", "Lunalesce", "Lunasalve", "Lunasoothe",
        "Survival of the Favored", "Survival of the Fittest",
        "Survival of the Unrelenting", "Moonshadow",
    },
    -- Sun Nuke
    SunNuke = {
        "Sunscald", "Sunpyre", "Sunshock", "Sunflame", "Sunflash",
        "Sunfire", "Sunstrike", "Sunblaze", "Sunray", "Sunburst",
    },
    -- Fire DoT (Horde line)
    FireDoT = {
        "Horde of Hotaria", "Horde of Duskwigs", "Horde of Hyperboreads",
        "Horde of Polybiads", "Horde of Fireants", "Swarm of Fireants",
    },
    -- Nature DoT
    NatureDoT = {
        "Nature's Fervid Wrath", "Nature's Blistering Wrath",
        "Nature's Frozen Wrath", "Nature's Frost", "Nature's Blight",
        "Nature's Entropy", "Nature's Decay", "Immolation of Nature",
    },
    -- Debuff (Ro line)
    Debuff = {
        "Clench of Ro", "Cinch of Ro", "Clasp of Ro", "Cowl of Ro",
        "Blessing of Ro", "Hand of Ro", "Sun's Corona",
        "Vengeance of the Sun", "Ro's Fiery Sundering",
    },
    -- Snare
    Snare = {
        "Entrap", "Ensnare", "Tangling Weeds", "Snare",
    },
    -- Root
    Root = {
        "Vinelash Assault", "Vinelash Cascade", "Savage Roots",
        "Entrapping Roots", "Engorging Roots", "Root",
    },
    -- Skin (HP buff)
    Skin = {
        "Opaline Skin", "Pellucid Skin", "Lucid Skin",
        "Crystalline Skin", "Virtuous Skin", "Steeloak Skin",
    },
    -- DS (damage shield)
    DamageShield = {
        "Viridifloral Shield", "Viridithorn Shield", "Briarcoat",
        "Thorncoat", "Spikecoat", "Barbcoat",
    },
    -- Regen
    Regen = {
        "Mask of the Shadowcat", "Mask of the Stalker",
        "Mask of the Hunter", "Mask of the Wild",
        "Reptile", "Pack Regeneration", "Regeneration",
    },
    -- Cure All
    CureAllSpell = {
        "Sanctified Blood", "Expurgated Blood", "Unblemished Blood",
        "Cleansed Blood", "Perfected Blood", "Purged Blood", "Purified Blood",
    },
    -- AA: Convergence of Spirits
    ConvergenceAA = { "Convergence of Spirits" },
    -- AA: Nature's Guardian
    NaturesGuardianAA = { "Nature's Guardian" },
    -- AA: Spirit of the Wood
    SpiritOfTheWoodAA = { "Spirit of the Wood" },
    -- AA: Nature's Boon
    NaturesBoonAA = { "Nature's Boon" },
    -- AA: Swarm of Fireflies
    SwarmAA = { "Swarm of Fireflies" },
    -- AA: Spire of Nature
    SpireOfNatureAA = { "Spire of Nature" },
    -- AA: Improved Twincast
    ImprovedTwincastAA = { "Improved Twincast" },
}

-- SpellLoadouts: Role-based gem assignments with extended schema
M.SpellLoadouts = {
    heal = {
        name = "Healing Focused",
        description = "Focus on single target and group healing",
        gems = {
            [1] = "QuickHealSurge",
            [2] = "QuickHeal",
            [3] = "LongHeal1",
            [4] = "QuickGroupHeal",
            [5] = "LongGroupHeal",
            [6] = "CureAllSpell",
            [7] = "Skin",
            [8] = "Regen",
        },
        defaults = {
            -- Healing
            DoHealing = true,
            DoGroupHeals = true,
            DoHoTs = true,
            -- DPS (minimal)
            DoNukes = false,
            DoDoTs = false,
            DoDebuff = false,
            -- Utility
            DoSnare = true,
            DoRoot = false,
            DoDamageShield = true,
            DoRegen = true,
            DoSkin = true,
            -- Burns
            UseSpireOfNature = true,
            UseImprovedTwincast = true,
            -- Emergency
            UseConvergence = true,
            UseNaturesGuardian = true,
            UseSpiritOfTheWood = true,
        },
        layerAssignments = {
            -- Emergency
            UseConvergence = "emergency",
            UseNaturesGuardian = "emergency",
            UseSpiritOfTheWood = "emergency",
            -- Support (healing primary)
            DoHealing = "support",
            DoGroupHeals = "support",
            DoHoTs = "support",
            -- Combat
            DoNukes = "combat",
            DoDoTs = "combat",
            DoDebuff = "combat",
            DoSnare = "combat",
            DoRoot = "combat",
            -- Burn
            UseSpireOfNature = "burn",
            UseImprovedTwincast = "burn",
            -- Buff
            DoDamageShield = "buff",
            DoRegen = "buff",
            DoSkin = "buff",
        },
        layerOrder = {
            emergency = {"UseConvergence", "UseNaturesGuardian", "UseSpiritOfTheWood"},
            support = {"DoHealing", "DoGroupHeals", "DoHoTs"},
            combat = {"DoSnare", "DoDebuff", "DoNukes", "DoDoTs", "DoRoot"},
            burn = {"UseSpireOfNature", "UseImprovedTwincast"},
            buff = {"DoSkin", "DoRegen", "DoDamageShield"},
        },
    },
    dps = {
        name = "DPS Focused",
        description = "Maximize damage with DoTs and nukes",
        gems = {
            [1] = "SunNuke",
            [2] = "FireDoT",
            [3] = "NatureDoT",
            [4] = "Debuff",
            [5] = "QuickHealSurge",
            [6] = "QuickGroupHeal",
            [7] = "Snare",
            [8] = "Skin",
        },
        defaults = {
            -- Healing (essential only)
            DoHealing = true,
            DoGroupHeals = true,
            DoHoTs = false,
            -- DPS (primary)
            DoNukes = true,
            DoDoTs = true,
            DoDebuff = true,
            -- Utility
            DoSnare = true,
            DoRoot = false,
            DoDamageShield = true,
            DoRegen = false,
            DoSkin = true,
            -- Burns
            UseSpireOfNature = true,
            UseImprovedTwincast = true,
            -- Emergency
            UseConvergence = true,
            UseNaturesGuardian = true,
            UseSpiritOfTheWood = true,
        },
        layerAssignments = {
            UseConvergence = "emergency",
            UseNaturesGuardian = "emergency",
            UseSpiritOfTheWood = "emergency",
            DoHealing = "support",
            DoGroupHeals = "support",
            DoHoTs = "support",
            DoNukes = "combat",
            DoDoTs = "combat",
            DoDebuff = "combat",
            DoSnare = "combat",
            DoRoot = "combat",
            UseSpireOfNature = "burn",
            UseImprovedTwincast = "burn",
            DoDamageShield = "buff",
            DoRegen = "buff",
            DoSkin = "buff",
        },
        layerOrder = {
            emergency = {"UseConvergence", "UseNaturesGuardian", "UseSpiritOfTheWood"},
            support = {"DoHealing", "DoGroupHeals", "DoHoTs"},
            combat = {"DoDebuff", "DoDoTs", "DoNukes", "DoSnare", "DoRoot"},
            burn = {"UseImprovedTwincast", "UseSpireOfNature"},
            buff = {"DoSkin", "DoDamageShield", "DoRegen"},
        },
    },
    hybrid = {
        name = "Hybrid Heal/DPS",
        description = "Balance healing with damage output",
        gems = {
            [1] = "QuickHealSurge",
            [2] = "QuickGroupHeal",
            [3] = "SunNuke",
            [4] = "FireDoT",
            [5] = "Debuff",
            [6] = "Snare",
            [7] = "Skin",
            [8] = "LongHeal1",
        },
        defaults = {
            -- Healing
            DoHealing = true,
            DoGroupHeals = true,
            DoHoTs = true,
            -- DPS
            DoNukes = true,
            DoDoTs = true,
            DoDebuff = true,
            -- Utility
            DoSnare = true,
            DoRoot = false,
            DoDamageShield = true,
            DoRegen = true,
            DoSkin = true,
            -- Burns
            UseSpireOfNature = true,
            UseImprovedTwincast = true,
            -- Emergency
            UseConvergence = true,
            UseNaturesGuardian = true,
            UseSpiritOfTheWood = true,
        },
        layerAssignments = {
            UseConvergence = "emergency",
            UseNaturesGuardian = "emergency",
            UseSpiritOfTheWood = "emergency",
            DoHealing = "support",
            DoGroupHeals = "support",
            DoHoTs = "support",
            DoNukes = "combat",
            DoDoTs = "combat",
            DoDebuff = "combat",
            DoSnare = "combat",
            DoRoot = "combat",
            UseSpireOfNature = "burn",
            UseImprovedTwincast = "burn",
            DoDamageShield = "buff",
            DoRegen = "buff",
            DoSkin = "buff",
        },
        layerOrder = {
            emergency = {"UseConvergence", "UseNaturesGuardian", "UseSpiritOfTheWood"},
            support = {"DoHealing", "DoGroupHeals", "DoHoTs"},
            combat = {"DoDebuff", "DoNukes", "DoDoTs", "DoSnare", "DoRoot"},
            burn = {"UseSpireOfNature", "UseImprovedTwincast"},
            buff = {"DoSkin", "DoRegen", "DoDamageShield"},
        },
    },
}

M.Settings = {
    DoHealing = {
        Default = true,
        Category = "Heal",
        DisplayName = "Enable Healing",
        Tooltip = "Enable automatic healing",
        AbilitySet = "QuickHealSurge",
    },
    DoGroupHeals = {
        Default = true,
        Category = "Heal",
        DisplayName = "Group Heals",
        Tooltip = "Use group heal spells",
        AbilitySet = "QuickGroupHeal",
    },
    DoHoTs = {
        Default = true,
        Category = "Heal",
        DisplayName = "Use HoTs",
        Tooltip = "Use heal-over-time spells",
        AbilitySet = "Regen",
    },
    DoNukes = {
        Default = true,
        Category = "DPS",
        DisplayName = "Use Nukes",
        Tooltip = "Use direct damage spells",
        AbilitySet = "SunNuke",
    },
    DoDoTs = {
        Default = true,
        Category = "DPS",
        DisplayName = "Use DoTs",
        Tooltip = "Use damage-over-time spells",
        AbilitySet = "FireDoT",
    },
    DoDebuff = {
        Default = true,
        Category = "Debuff",
        DisplayName = "Use Debuffs",
        Tooltip = "Use debuff spells on targets",
        AbilitySet = "Debuff",
    },
    DoSnare = {
        Default = true,
        Category = "Utility",
        DisplayName = "Auto-Snare",
        Tooltip = "Automatically snare targets",
        AbilitySet = "Snare",
    },
    DoRoot = {
        Default = false,
        Category = "Utility",
        DisplayName = "Auto-Root",
        Tooltip = "Automatically root targets",
        AbilitySet = "Root",
    },
    DoCures = {
        Default = true,
        Category = "Cure",
        DisplayName = "Enable Cures",
        Tooltip = "Automatically cure detrimental effects",
        AbilitySet = "CureAllSpell",
    },
    DoDamageShield = {
        Default = true,
        Category = "Buff",
        DisplayName = "Damage Shield",
        Tooltip = "Use damage shield buff",
        AbilitySet = "DamageShield",
    },
    DoRegen = {
        Default = true,
        Category = "Buff",
        DisplayName = "Regen Buff",
        Tooltip = "Use regeneration buff",
        AbilitySet = "Regen",
    },
    DoSkin = {
        Default = true,
        Category = "Buff",
        DisplayName = "Skin Buff",
        Tooltip = "Use skin HP buff",
        AbilitySet = "Skin",
    },
    UseConvergence = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Convergence",
        Tooltip = "Use Convergence of Spirits",
        AbilitySet = "ConvergenceAA",
    },
    UseNaturesGuardian = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Nature's Guardian",
        Tooltip = "Use Nature's Guardian",
        AbilitySet = "NaturesGuardianAA",
    },
    UseSpiritOfTheWood = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Spirit of the Wood",
        Tooltip = "Use Spirit of the Wood",
        AbilitySet = "SpiritOfTheWoodAA",
    },
    UseSpireOfNature = {
        Default = true,
        Category = "Burn",
        DisplayName = "Spire of Nature",
        Tooltip = "Use Spire of Nature during burns",
        AbilitySet = "SpireOfNatureAA",
    },
    UseImprovedTwincast = {
        Default = true,
        Category = "Burn",
        DisplayName = "Improved Twincast",
        Tooltip = "Use Improved Twincast during burns",
        AbilitySet = "ImprovedTwincastAA",
    },
}

return M
