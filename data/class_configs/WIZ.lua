-- F:/lua/SideKick/data/class_configs/WIZ.lua
-- Wizard Class Configuration with condition-based rotations

local mq = require('mq')

local M = {}

-- Spell Lines
M.spellLines = {
    -- Fire Nuke
    ['FireNuke'] = {
        "Ethereal Skyfire", "Ethereal Inferno", "Ethereal Conflagration",
        "Ethereal Incandescence", "Ethereal Blaze", "Ethereal Combustion",
        "Skyfire", "Pillar of Fire", "Fire Bolt",
    },

    -- Ice Nuke
    ['IceNuke'] = {
        "Glacial Cascade", "Glacial Freeze", "Glacial Ice",
        "Claw of Travenro", "Claw of Vox", "Ice Comet",
    },

    -- Magic Nuke
    ['MagicNuke'] = {
        "Ethereal Braid", "Ethereal Twist", "Ethereal Weave",
        "Force of Will", "Force of Flame", "Shock of Lightning",
    },

    -- Ethereal Nuke (fast cast)
    ['EtherealNuke'] = {
        "Ethereal Hoarfrost", "Ethereal Frost", "Ethereal Rime",
        "Ethereal Rimeblast", "Remote Skyblaze", "Remote Moonfire",
    },

    -- Rain (AE)
    ['RainSpell'] = {
        "Tears of Prexus", "Tears of the Sun", "Tears of Drysa",
        "Tears of Solusek", "Rain of Skyfire", "Ice Rain",
    },

    -- AE Fire
    ['AEFire'] = {
        "Circle of Firestorm", "Circle of Flashfire", "Circle of Inferno",
        "Column of Fire", "Pillar of Flame", "Rain of Fire",
    },

    -- AE Ice
    ['AEIce'] = {
        "Frore Storm", "Freezing Hail", "Ice Storm",
    },

    -- Jolt (aggro dump)
    ['Jolt'] = {
        "Concussion", "Phantasmal Recourse", "Mind Crash",
        "Claw of Frost", "Jolt",
    },

    -- Harvest (mana recovery)
    ['Harvest'] = {
        "Ethereal Harvest", "Arcane Harvest", "Mystic Harvest",
        "Contemplation", "Harvest of Druzzil", "Harvest",
    },

    -- Self Shield
    ['SelfShield'] = {
        "Shield of Consequence", "Shield of Order", "Shield of Dreams",
        "Shield of Shadow", "Shield of the Arcane", "Shield of the Magi",
    },

    -- Familiar
    ['Familiar'] = {
        "Greater Familiar", "Improved Familiar", "Familiar",
    },
}

-- AA Lines
M.aaLines = {
    ['ImprovedTwincast'] = { "Improved Twincast" },
    ['FuryOfMagic'] = { "Fury of the Gods" },
    ['Harvest'] = { "Harvest of Druzzil" },
    ['ForcefulRejuvenation'] = { "Forceful Rejuvenation" },
    ['Concussion'] = { "Concussion", "Mind Crash" },
    ['SpireOfWizard'] = { "Spire of Arcanum" },
    ['IntensityOfResolute'] = { "Intensity of the Resolute" },
    ['ArcaneFury'] = { "Arcane Fury" },
    ['Firebound'] = { "Firebound Orb" },
    ['Icebound'] = { "Icebound Orb" },
}

-- Default conditions
M.defaultConditions = {
    ['doHarvest'] = function(ctx)
        return ctx.me.pctMana < 30
    end,
    ['doForcefulRejuvenation'] = function(ctx)
        return ctx.me.pctMana < 20
    end,
    ['doConcussion'] = function(ctx)
        return ctx.me.pctAggro > 85
    end,
    ['doJolt'] = function(ctx)
        return ctx.me.pctAggro > 90
    end,

    ['doFireNuke'] = function(ctx)
        return ctx.combat and ctx.me.pctMana > 30
    end,
    ['doIceNuke'] = function(ctx)
        return ctx.combat and ctx.me.pctMana > 30
    end,
    ['doMagicNuke'] = function(ctx)
        return ctx.combat and ctx.me.pctMana > 30
    end,
    ['doEtherealNuke'] = function(ctx)
        return ctx.combat and ctx.target.named
    end,
    ['doRainSpell'] = function(ctx)
        return ctx.combat and ctx.me.xTargetCount >= 3 and ctx.me.pctMana > 40
    end,
    ['doAEFire'] = function(ctx)
        return ctx.combat and ctx.me.xTargetCount >= 3 and ctx.me.pctMana > 40
    end,
    ['doAEIce'] = function(ctx)
        return ctx.combat and ctx.me.xTargetCount >= 3 and ctx.me.pctMana > 40
    end,

    ['doSelfShield'] = function(ctx)
        return not ctx.me.buff('Shield') and not ctx.combat
    end,
    ['doFamiliar'] = function(ctx)
        return not ctx.me.buff('Familiar') and not ctx.combat
    end,

    ['doImprovedTwincast'] = function(ctx)
        return ctx.burn and not ctx.me.buff('Improved Twincast') and not ctx.me.buff('Twincast')
    end,
    ['doFuryOfMagic'] = function(ctx)
        return ctx.burn
    end,
    ['doSpireOfWizard'] = function(ctx)
        return ctx.burn
    end,
    ['doIntensityOfResolute'] = function(ctx)
        return ctx.burn
    end,
    ['doArcaneFury'] = function(ctx)
        return ctx.burn
    end,
    ['doFirebound'] = function(ctx)
        return ctx.burn
    end,
    ['doIcebound'] = function(ctx)
        return ctx.burn
    end,
}

-- Category overrides
M.categoryOverrides = {
    ['doHarvest'] = 'emergency',
    ['doForcefulRejuvenation'] = 'emergency',
    ['doConcussion'] = 'aggro',
    ['doJolt'] = 'aggro',
    ['doFireNuke'] = 'combat',
    ['doIceNuke'] = 'combat',
    ['doMagicNuke'] = 'combat',
    ['doEtherealNuke'] = 'combat',
    ['doRainSpell'] = 'combat',
    ['doAEFire'] = 'combat',
    ['doAEIce'] = 'combat',
    ['doSelfShield'] = 'utility',
    ['doFamiliar'] = 'utility',
    ['doImprovedTwincast'] = 'burn',
    ['doFuryOfMagic'] = 'burn',
    ['doSpireOfWizard'] = 'burn',
    ['doIntensityOfResolute'] = 'burn',
    ['doArcaneFury'] = 'burn',
    ['doFirebound'] = 'burn',
    ['doIcebound'] = 'burn',
}

M.Settings = {
    DoFireNukes = {
        Default = true,
        Category = "DPS",
        DisplayName = "Fire Nukes",
    },
    DoIceNukes = {
        Default = true,
        Category = "DPS",
        DisplayName = "Ice Nukes",
    },
    DoMagicNukes = {
        Default = true,
        Category = "DPS",
        DisplayName = "Magic Nukes",
    },
    DoAENukes = {
        Default = true,
        Category = "DPS",
        DisplayName = "AE Nukes",
    },
    DoJolt = {
        Default = true,
        Category = "Aggro",
        DisplayName = "Auto-Jolt",
    },
}

return M
