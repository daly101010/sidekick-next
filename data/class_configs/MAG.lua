-- F:/lua/SideKick/data/class_configs/MAG.lua
-- Magician Class Configuration with condition-based rotations

local mq = require('mq')

local M = {}

-- Spell Lines
M.spellLines = {
    -- Fire Nuke
    ['FireNuke'] = {
        "Spear of Molten Arcronite", "Spear of Molten Komite",
        "Spear of Molten Luclinite", "Spear of Molten Steel",
        "Spear of Molten Silite", "Spear of Blistersteel",
    },

    -- Bolt Nuke
    ['BoltNuke'] = {
        "Bolt of Molten Arcronite", "Bolt of Molten Komite",
        "Bolt of Molten Luclinite", "Bolt of Molten Steel",
        "Bolt of Molten Slag", "Shock of Magma",
    },

    -- Chaotic Nuke
    ['ChaoticNuke'] = {
        "Chaotic Pyroclasm", "Chaotic Magmablast", "Chaotic Lavaflux",
        "Chaotic Calamity", "Chaotic Fire", "Chaos Flames",
    },

    -- Rain (AE)
    ['RainSpell'] = {
        "Magmatic Rain", "Volcanic Rain", "Fiery Rain",
        "Rain of Lava", "Fire Rain",
    },

    -- Malo (magic debuff)
    ['Malo'] = {
        "Malosinara", "Malosinete", "Malosinia", "Malosini", "Malo",
    },

    -- DS (damage shield)
    ['DamageShield'] = {
        "Fickle Magma", "Fickle Fire", "Fickle Inferno",
        "Burning Aura", "Circle of Fire",
    },

    -- Pet
    ['Pet'] = {
        "Ruinous Servant", "Relentless Servant", "Reckless Servant",
        "Rageful Servant", "Rapacious Servant", "Riotous Servant",
    },

    -- Pet Heal
    ['PetHeal'] = {
        "Rekindling Steel", "Reinforce Steel", "Restorative Steel",
        "Mend Companion", "Renewal of Voltz",
    },

    -- Pet Buff
    ['PetBuff'] = {
        "Burnout XIV", "Burnout XIII", "Burnout XII", "Burnout XI",
        "Burnout X", "Burnout IX", "Burnout VIII",
    },

    -- Shield
    ['Shield'] = {
        "Arcane Shield", "Mystic Shield", "Phantom Shield",
        "Force Shield",
    },
}

-- AA Lines
M.aaLines = {
    ['ServantOfRo'] = { "Servant of Ro" },
    ['HeartOfFlames'] = { "Heart of Flames" },
    ['HeartOfIce'] = { "Heart of Ice" },
    ['HeartOfStone'] = { "Heart of Stone" },
    ['SpireOfMagician'] = { "Spire of Elements" },
    ['FocusOfArcanum'] = { "Focus of Arcanum" },
    ['ThroesOfFire'] = { "Throe of Fire" },
    ['Swarm'] = { "Swarm of Summoned Fire" },
    ['ForcefulRejuvenation'] = { "Forceful Rejuvenation" },
    ['MalaisBestow'] = { "Malaise's Bestow" },
}

-- Default conditions
M.defaultConditions = {
    ['doForcefulRejuvenation'] = function(ctx)
        return ctx.me.pctMana < 20
    end,

    ['doPetHeal'] = function(ctx)
        return ctx.pet.pctHPs and ctx.pet.pctHPs < 50
    end,
    ['doPetBuff'] = function(ctx)
        return not ctx.combat and ctx.pet.id > 0 and not ctx.pet.buff('Burnout')
    end,

    ['doFireNuke'] = function(ctx)
        return ctx.combat and ctx.me.pctMana > 30
    end,
    ['doBoltNuke'] = function(ctx)
        return ctx.combat and ctx.me.pctMana > 40
    end,
    ['doChaoticNuke'] = function(ctx)
        return ctx.combat
    end,
    ['doRainSpell'] = function(ctx)
        return ctx.combat and ctx.me.xTargetCount >= 3 and ctx.me.pctMana > 40
    end,
    ['doMalo'] = function(ctx)
        return ctx.combat and not ctx.target.myBuff('Malo') and ctx.target.pctHPs > 50
    end,

    ['doDamageShield'] = function(ctx)
        return not ctx.combat
    end,
    ['doShield'] = function(ctx)
        return not ctx.me.buff('Shield') and not ctx.combat
    end,

    ['doServantOfRo'] = function(ctx)
        return ctx.burn and ctx.target.named
    end,
    ['doHeartOfFlames'] = function(ctx)
        return ctx.burn
    end,
    ['doSpireOfMagician'] = function(ctx)
        return ctx.burn
    end,
    ['doFocusOfArcanum'] = function(ctx)
        return ctx.burn
    end,
    ['doThroesOfFire'] = function(ctx)
        return ctx.burn and ctx.combat
    end,
    ['doSwarm'] = function(ctx)
        return ctx.burn and ctx.combat
    end,
    ['doMalaisBestow'] = function(ctx)
        return ctx.combat and not ctx.target.myBuff('Malo')
    end,
}

-- Category overrides
M.categoryOverrides = {
    ['doForcefulRejuvenation'] = 'emergency',
    ['doPetHeal'] = 'support',
    ['doPetBuff'] = 'utility',
    ['doFireNuke'] = 'combat',
    ['doBoltNuke'] = 'combat',
    ['doChaoticNuke'] = 'combat',
    ['doRainSpell'] = 'combat',
    ['doMalo'] = 'support',
    ['doDamageShield'] = 'utility',
    ['doShield'] = 'utility',
    ['doServantOfRo'] = 'burn',
    ['doHeartOfFlames'] = 'burn',
    ['doSpireOfMagician'] = 'burn',
    ['doFocusOfArcanum'] = 'burn',
    ['doThroesOfFire'] = 'burn',
    ['doSwarm'] = 'burn',
    ['doMalaisBestow'] = 'support',
}

M.Settings = {
    DoNukes = {
        Default = true,
        Category = "DPS",
        DisplayName = "Use Nukes",
    },
    DoMalo = {
        Default = true,
        Category = "Debuff",
        DisplayName = "Auto-Malo",
    },
    DoPetHeals = {
        Default = true,
        Category = "Pet",
        DisplayName = "Heal Pet",
    },
    DoAENukes = {
        Default = true,
        Category = "DPS",
        DisplayName = "AE Nukes",
    },
}

return M
