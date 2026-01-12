-- F:/lua/SideKick/data/class_configs/RNG.lua
-- Ranger Class Configuration with condition-based rotations

local mq = require('mq')

local M = {}

-- Spell Lines
M.spellLines = {
    -- Fire Nuke
    ['FireNuke'] = {
        "Summer's Tempest", "Summer's Torrent", "Summer's Cyclone",
        "Summer's Storm", "Summer's Deluge", "Summer's Squall",
    },

    -- Poison DoT
    ['PoisonDoT'] = {
        "Venomous Cascade", "Venomous Squall", "Venomous Deluge",
        "Venomous Rain", "Venomous Storm", "Envenomed Breath",
    },

    -- Ice Nuke
    ['IceNuke'] = {
        "Rimeclaw's Torrent", "Rimeclaw's Cascade", "Rimeclaw's Squall",
        "Sunder", "Frost Wind", "Icefall",
    },

    -- Fast Heal
    ['FastHeal'] = {
        "Desperate Mending", "Frantic Mending", "Feral Mending",
        "Fervent Mending", "Fierce Mending", "Ferocious Mending",
    },

    -- Heal
    ['Heal'] = {
        "Bosquetender's Covenant", "Bosquetender's Alliance",
        "Woodstalker's Covenant", "Sylvan Water", "Sylvan Healing",
    },

    -- Regen (self)
    ['RegenSpells'] = {
        "Dawnstrike", "Suncrest", "Call of the Predator",
        "Strength of the Hunter", "Nature's Rebirth", "Regeneration",
    },

    -- Snare
    ['Snare'] = {
        "Entrap", "Ensnare", "Snare",
    },

    -- Root
    ['Root'] = {
        "Vinelash Cascade", "Savage Roots", "Engulfing Roots", "Root",
    },

    -- DS (damage shield)
    ['DamageShield'] = {
        "Shield of Needles", "Shield of Thistles", "Shield of Thorns",
        "Shield of Barbs", "Shield of Brambles",
    },
}

-- Disc Lines
M.discLines = {
    ['Pureshot'] = { "Pureshot Discipline" },
    ['EmpoweredBlades'] = { "Empowered Blades" },
    ['Auspice'] = { "Auspice of the Hunter" },
    ['GroupGuardian'] = { "Group Guardian of the Forest" },
}

-- AA Lines
M.aaLines = {
    ['Adrenaline'] = { "Adrenaline Surge" },
    ['AuspiceOfTheHunter'] = { "Auspice of the Hunter" },
    ['EmpoweredBlades'] = { "Empowered Blades" },
    ['SpireOfRanger'] = { "Spire of the Pathfinders" },
    ['Outrider'] = { "Outrider's Accuracy" },
    ['ChampionsClaim'] = { "Champion's Claim" },
    ['ScarletCheetah'] = { "Scarlet Cheetah's Fang" },
    ['Dichotomic'] = { "Dichotomic Fusillade" },
}

-- Default conditions
M.defaultConditions = {
    ['doAdrenaline'] = function(ctx)
        return ctx.me.pctHPs < 40
    end,

    ['doFireNuke'] = function(ctx)
        return ctx.combat and ctx.me.pctMana > 40
    end,
    ['doPoisonDoT'] = function(ctx)
        return ctx.combat and not ctx.target.myBuff('Venomous') and ctx.target.pctHPs > 30
    end,
    ['doIceNuke'] = function(ctx)
        return ctx.combat and ctx.me.pctMana > 50
    end,

    ['doFastHeal'] = function(ctx)
        return ctx.me.pctHPs < 60 or ctx.group.lowestHP < 50
    end,
    ['doHeal'] = function(ctx)
        return ctx.group.lowestHP < 70
    end,
    ['doRegenSpells'] = function(ctx)
        return not ctx.me.buff('Regen') and not ctx.combat
    end,

    ['doSnare'] = function(ctx)
        return ctx.combat and not ctx.target.buff('Snare')
    end,
    ['doRoot'] = function(ctx)
        return ctx.combat and ctx.me.xTargetCount > 1
    end,
    ['doDamageShield'] = function(ctx)
        return not ctx.combat
    end,

    ['doPureshot'] = function(ctx)
        return ctx.burn and not ctx.me.activeDisc
    end,
    ['doEmpoweredBlades'] = function(ctx)
        return ctx.burn
    end,
    ['doAuspiceOfTheHunter'] = function(ctx)
        return ctx.burn and not ctx.me.buff('Auspice')
    end,
    ['doSpireOfRanger'] = function(ctx)
        return ctx.burn
    end,
    ['doOutrider'] = function(ctx)
        return ctx.burn and ctx.combat
    end,
    ['doChampionsClaim'] = function(ctx)
        return ctx.burn and ctx.combat
    end,
    ['doScarletCheetah'] = function(ctx)
        return ctx.combat
    end,
    ['doDichotomic'] = function(ctx)
        return ctx.burn and ctx.combat
    end,
}

-- Category overrides
M.categoryOverrides = {
    ['doAdrenaline'] = 'emergency',
    ['doFireNuke'] = 'combat',
    ['doPoisonDoT'] = 'combat',
    ['doIceNuke'] = 'combat',
    ['doFastHeal'] = 'support',
    ['doHeal'] = 'support',
    ['doRegenSpells'] = 'utility',
    ['doSnare'] = 'combat',
    ['doRoot'] = 'support',
    ['doDamageShield'] = 'utility',
    ['doPureshot'] = 'burn',
    ['doEmpoweredBlades'] = 'burn',
    ['doAuspiceOfTheHunter'] = 'burn',
    ['doSpireOfRanger'] = 'burn',
    ['doOutrider'] = 'burn',
    ['doChampionsClaim'] = 'burn',
    ['doScarletCheetah'] = 'combat',
    ['doDichotomic'] = 'burn',
}

M.Settings = {
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
    DoHealing = {
        Default = true,
        Category = "Heal",
        DisplayName = "Enable Healing",
    },
    DoSnare = {
        Default = true,
        Category = "Utility",
        DisplayName = "Auto-Snare",
    },
}

return M
