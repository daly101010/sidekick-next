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
    ['doSkin'] = 'utility',
    ['doDamageShield'] = 'utility',
    ['doRegen'] = 'utility',
    ['doSpireOfNature'] = 'burn',
    ['doImprovedTwincast'] = 'burn',
}

M.Settings = {
    DoHealing = {
        Default = true,
        Category = "Heal",
        DisplayName = "Enable Healing",
    },
    DoNukes = {
        Default = true,
        Category = "DPS",
        DisplayName = "Use Nukes",
    },
    DoDoTs = {
        Default = true,
        Category = "DPS",
        DisplayName = "Use DoTs",
    },
    DoDebuff = {
        Default = true,
        Category = "Debuff",
        DisplayName = "Use Debuffs",
    },
    DoSnare = {
        Default = true,
        Category = "Utility",
        DisplayName = "Auto-Snare",
    },
}

return M
