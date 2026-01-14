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
    ['doDamageShield'] = 'buff',
    ['doShield'] = 'buff',
    ['doServantOfRo'] = 'burn',
    ['doHeartOfFlames'] = 'burn',
    ['doSpireOfMagician'] = 'burn',
    ['doFocusOfArcanum'] = 'burn',
    ['doThroesOfFire'] = 'burn',
    ['doSwarm'] = 'burn',
    ['doMalaisBestow'] = 'support',
}

-- AbilitySets: Spell/AA progressions (highest to lowest rank)
M.AbilitySets = {
    -- Fire Nuke
    FireNuke = {
        "Spear of Molten Arcronite", "Spear of Molten Komite",
        "Spear of Molten Luclinite", "Spear of Molten Steel",
        "Spear of Molten Silite", "Spear of Blistersteel",
    },
    -- Bolt Nuke
    BoltNuke = {
        "Bolt of Molten Arcronite", "Bolt of Molten Komite",
        "Bolt of Molten Luclinite", "Bolt of Molten Steel",
        "Bolt of Molten Slag", "Shock of Magma",
    },
    -- Chaotic Nuke
    ChaoticNuke = {
        "Chaotic Pyroclasm", "Chaotic Magmablast", "Chaotic Lavaflux",
        "Chaotic Calamity", "Chaotic Fire", "Chaos Flames",
    },
    -- Rain
    RainSpell = {
        "Magmatic Rain", "Volcanic Rain", "Fiery Rain",
        "Rain of Lava", "Fire Rain",
    },
    -- Malo
    Malo = {
        "Malosinara", "Malosinete", "Malosinia", "Malosini", "Malo",
    },
    -- DS
    DamageShield = {
        "Fickle Magma", "Fickle Fire", "Fickle Inferno",
        "Burning Aura", "Circle of Fire",
    },
    -- Pet
    Pet = {
        "Ruinous Servant", "Relentless Servant", "Reckless Servant",
        "Rageful Servant", "Rapacious Servant", "Riotous Servant",
    },
    -- Pet Heal
    PetHeal = {
        "Rekindling Steel", "Reinforce Steel", "Restorative Steel",
        "Mend Companion", "Renewal of Voltz",
    },
    -- Pet Buff
    PetBuff = {
        "Burnout XIV", "Burnout XIII", "Burnout XII", "Burnout XI",
        "Burnout X", "Burnout IX", "Burnout VIII",
    },
    -- Shield
    Shield = {
        "Arcane Shield", "Mystic Shield", "Phantom Shield",
        "Force Shield",
    },
    -- AA: Servant of Ro
    ServantOfRoAA = { "Servant of Ro" },
    -- AA: Heart of Flames
    HeartOfFlamesAA = { "Heart of Flames" },
    -- AA: Heart of Ice
    HeartOfIceAA = { "Heart of Ice" },
    -- AA: Heart of Stone
    HeartOfStoneAA = { "Heart of Stone" },
    -- AA: Spire of Elements
    SpireOfMagicianAA = { "Spire of Elements" },
    -- AA: Focus of Arcanum
    FocusOfArcanumAA = { "Focus of Arcanum" },
    -- AA: Throe of Fire
    ThroesOfFireAA = { "Throe of Fire" },
    -- AA: Swarm of Summoned Fire
    SwarmAA = { "Swarm of Summoned Fire" },
    -- AA: Forceful Rejuvenation
    ForcefulRejuvenationAA = { "Forceful Rejuvenation" },
    -- AA: Malaise's Bestow
    MalaisBestowAA = { "Malaise's Bestow" },
}

-- SpellLoadouts: Role-based gem assignments with extended schema
M.SpellLoadouts = {
    dps = {
        name = "DPS Focused",
        description = "Maximize damage output",
        gems = {
            [1] = "FireNuke",
            [2] = "BoltNuke",
            [3] = "ChaoticNuke",
            [4] = "RainSpell",
            [5] = "Malo",
            [6] = "PetHeal",
            [7] = "DamageShield",
            [8] = "Shield",
        },
        defaults = {
            -- DPS
            DoNukes = true,
            DoAENukes = true,
            -- Support
            DoMalo = true,
            DoPetHeals = true,
            DoPetBuff = true,
            -- Utility
            DoDamageShield = true,
            DoShield = true,
            -- Emergency
            UseForcefulRejuvenation = true,
            -- Burns
            UseServantOfRo = true,
            UseHeartOfFlames = true,
            UseSpireOfMagician = true,
            UseFocusOfArcanum = true,
            UseThroesOfFire = true,
            UseSwarm = true,
            UseMalaisBestow = true,
        },
        layerAssignments = {
            -- Emergency
            UseForcefulRejuvenation = "emergency",
            -- Support
            DoMalo = "support",
            DoPetHeals = "support",
            DoPetBuff = "support",
            -- Combat
            DoNukes = "combat",
            DoAENukes = "combat",
            -- Burn
            UseServantOfRo = "burn",
            UseHeartOfFlames = "burn",
            UseSpireOfMagician = "burn",
            UseFocusOfArcanum = "burn",
            UseThroesOfFire = "burn",
            UseSwarm = "burn",
            UseMalaisBestow = "burn",
            -- Buff
            DoDamageShield = "buff",
            DoShield = "buff",
        },
        layerOrder = {
            emergency = {"UseForcefulRejuvenation"},
            support = {"DoMalo", "DoPetHeals", "DoPetBuff"},
            combat = {"DoNukes", "DoAENukes"},
            burn = {"UseServantOfRo", "UseHeartOfFlames", "UseFocusOfArcanum", "UseThroesOfFire", "UseSwarm", "UseSpireOfMagician", "UseMalaisBestow"},
            buff = {"DoDamageShield", "DoShield"},
        },
    },
    pet = {
        name = "Pet Focus",
        description = "Focus on pet support",
        gems = {
            [1] = "FireNuke",
            [2] = "ChaoticNuke",
            [3] = "Malo",
            [4] = "PetHeal",
            [5] = "PetBuff",
            [6] = "DamageShield",
            [7] = "Shield",
            [8] = "RainSpell",
        },
        defaults = {
            DoNukes = true,
            DoAENukes = true,
            DoMalo = true,
            DoPetHeals = true,
            DoPetBuff = true,
            DoDamageShield = true,
            DoShield = true,
            UseForcefulRejuvenation = true,
            UseServantOfRo = true,
            UseHeartOfFlames = true,
            UseSpireOfMagician = true,
            UseFocusOfArcanum = true,
            UseThroesOfFire = true,
            UseSwarm = true,
            UseMalaisBestow = true,
        },
        layerAssignments = {
            UseForcefulRejuvenation = "emergency",
            DoMalo = "support",
            DoPetHeals = "support",
            DoPetBuff = "support",
            DoNukes = "combat",
            DoAENukes = "combat",
            UseServantOfRo = "burn",
            UseHeartOfFlames = "burn",
            UseSpireOfMagician = "burn",
            UseFocusOfArcanum = "burn",
            UseThroesOfFire = "burn",
            UseSwarm = "burn",
            UseMalaisBestow = "burn",
            DoDamageShield = "utility",
            DoShield = "utility",
        },
        layerOrder = {
            emergency = {"UseForcefulRejuvenation"},
            support = {"DoPetHeals", "DoPetBuff", "DoMalo"},
            combat = {"DoNukes", "DoAENukes"},
            burn = {"UseServantOfRo", "UseHeartOfFlames", "UseSwarm", "UseFocusOfArcanum", "UseThroesOfFire", "UseSpireOfMagician", "UseMalaisBestow"},
            buff = {"DoDamageShield", "DoShield"},
        },
    },
}

M.Settings = {
    DoNukes = {
        Default = true,
        Category = "DPS",
        DisplayName = "Use Nukes",
    },
    DoAENukes = {
        Default = true,
        Category = "DPS",
        DisplayName = "AE Nukes",
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
    DoPetBuff = {
        Default = true,
        Category = "Pet",
        DisplayName = "Pet Buff",
    },
    DoDamageShield = {
        Default = true,
        Category = "Utility",
        DisplayName = "Damage Shield",
    },
    DoShield = {
        Default = true,
        Category = "Utility",
        DisplayName = "Self Shield",
    },
    UseForcefulRejuvenation = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Forceful Rejuvenation",
    },
    UseServantOfRo = {
        Default = true,
        Category = "Burn",
        DisplayName = "Servant of Ro",
    },
    UseHeartOfFlames = {
        Default = true,
        Category = "Burn",
        DisplayName = "Heart of Flames",
    },
    UseSpireOfMagician = {
        Default = true,
        Category = "Burn",
        DisplayName = "Spire of Magician",
    },
    UseFocusOfArcanum = {
        Default = true,
        Category = "Burn",
        DisplayName = "Focus of Arcanum",
    },
    UseThroesOfFire = {
        Default = true,
        Category = "Burn",
        DisplayName = "Throes of Fire",
    },
    UseSwarm = {
        Default = true,
        Category = "Burn",
        DisplayName = "Swarm",
    },
    UseMalaisBestow = {
        Default = true,
        Category = "Burn",
        DisplayName = "Malaise's Bestow",
    },
}

return M
