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
    ['doRegenSpells'] = 'buff',
    ['doSnare'] = 'combat',
    ['doRoot'] = 'support',
    ['doDamageShield'] = 'buff',
    ['doPureshot'] = 'burn',
    ['doEmpoweredBlades'] = 'burn',
    ['doAuspiceOfTheHunter'] = 'burn',
    ['doSpireOfRanger'] = 'burn',
    ['doOutrider'] = 'burn',
    ['doChampionsClaim'] = 'burn',
    ['doScarletCheetah'] = 'combat',
    ['doDichotomic'] = 'burn',
}

-- AbilitySets: Spell/AA progressions (highest to lowest rank)
M.AbilitySets = {
    -- Fire Nuke
    FireNuke = {
        "Summer's Tempest", "Summer's Torrent", "Summer's Cyclone",
        "Summer's Storm", "Summer's Deluge", "Summer's Squall",
    },
    -- Poison DoT
    PoisonDoT = {
        "Venomous Cascade", "Venomous Squall", "Venomous Deluge",
        "Venomous Rain", "Venomous Storm", "Envenomed Breath",
    },
    -- Ice Nuke
    IceNuke = {
        "Rimeclaw's Torrent", "Rimeclaw's Cascade", "Rimeclaw's Squall",
        "Sunder", "Frost Wind", "Icefall",
    },
    -- Fast Heal
    FastHeal = {
        "Desperate Mending", "Frantic Mending", "Feral Mending",
        "Fervent Mending", "Fierce Mending", "Ferocious Mending",
    },
    -- Heal
    Heal = {
        "Bosquetender's Covenant", "Bosquetender's Alliance",
        "Woodstalker's Covenant", "Sylvan Water", "Sylvan Healing",
    },
    -- Regen
    RegenSpells = {
        "Dawnstrike", "Suncrest", "Call of the Predator",
        "Strength of the Hunter", "Nature's Rebirth", "Regeneration",
    },
    -- Snare
    Snare = {
        "Entrap", "Ensnare", "Snare",
    },
    -- Root
    Root = {
        "Vinelash Cascade", "Savage Roots", "Engulfing Roots", "Root",
    },
    -- DS
    DamageShield = {
        "Shield of Needles", "Shield of Thistles", "Shield of Thorns",
        "Shield of Barbs", "Shield of Brambles",
    },
    -- AA: Adrenaline Surge
    AdrenalineAA = { "Adrenaline Surge" },
    -- AA: Auspice of the Hunter
    AuspiceOfTheHunterAA = { "Auspice of the Hunter" },
    -- AA: Empowered Blades
    EmpoweredBladesAA = { "Empowered Blades" },
    -- AA: Spire of the Pathfinders
    SpireOfRangerAA = { "Spire of the Pathfinders" },
    -- AA: Outrider's Accuracy
    OutriderAA = { "Outrider's Accuracy" },
    -- AA: Champion's Claim
    ChampionsClaimAA = { "Champion's Claim" },
    -- AA: Scarlet Cheetah's Fang
    ScarletCheetahAA = { "Scarlet Cheetah's Fang" },
    -- AA: Dichotomic Fusillade
    DichotomicAA = { "Dichotomic Fusillade" },
}

-- SpellLoadouts: Role-based gem assignments with extended schema
M.SpellLoadouts = {
    dps = {
        name = "DPS Focused",
        description = "Maximize damage output",
        gems = {
            [1] = "FireNuke",
            [2] = "IceNuke",
            [3] = "PoisonDoT",
            [4] = "FastHeal",
            [5] = "Snare",
            [6] = "DamageShield",
            [7] = "RegenSpells",
            [8] = "Heal",
        },
        defaults = {
            -- DPS
            DoNukes = true,
            DoDoTs = true,
            DoSnare = true,
            -- Healing
            DoHealing = true,
            DoFastHeal = true,
            -- Utility
            DoRegenSpells = true,
            DoDamageShield = true,
            DoRoot = false,
            -- Emergency
            UseAdrenaline = true,
            -- Burns
            UsePureshot = true,
            UseEmpoweredBlades = true,
            UseAuspiceOfTheHunter = true,
            UseSpireOfRanger = true,
            UseOutrider = true,
            UseChampionsClaim = true,
            UseScarletCheetah = true,
            UseDichotomic = true,
        },
        layerAssignments = {
            -- Emergency
            UseAdrenaline = "emergency",
            -- Support (healing)
            DoHealing = "support",
            DoFastHeal = "support",
            -- Combat
            DoNukes = "combat",
            DoDoTs = "combat",
            DoSnare = "combat",
            DoRoot = "combat",
            -- Burn
            UsePureshot = "burn",
            UseEmpoweredBlades = "burn",
            UseAuspiceOfTheHunter = "burn",
            UseSpireOfRanger = "burn",
            UseOutrider = "burn",
            UseChampionsClaim = "burn",
            UseScarletCheetah = "burn",
            UseDichotomic = "burn",
            -- Buff
            DoRegenSpells = "buff",
            DoDamageShield = "buff",
        },
        layerOrder = {
            emergency = {"UseAdrenaline"},
            support = {"DoHealing", "DoFastHeal"},
            combat = {"DoNukes", "DoDoTs", "DoSnare", "DoRoot"},
            burn = {"UsePureshot", "UseEmpoweredBlades", "UseAuspiceOfTheHunter", "UseSpireOfRanger", "UseOutrider", "UseChampionsClaim", "UseScarletCheetah", "UseDichotomic"},
            buff = {"DoRegenSpells", "DoDamageShield"},
        },
    },
    hybrid = {
        name = "Hybrid Heal/DPS",
        description = "Balance healing with damage",
        gems = {
            [1] = "FastHeal",
            [2] = "Heal",
            [3] = "FireNuke",
            [4] = "PoisonDoT",
            [5] = "Snare",
            [6] = "RegenSpells",
            [7] = "DamageShield",
            [8] = "Root",
        },
        defaults = {
            DoNukes = true,
            DoDoTs = true,
            DoSnare = true,
            DoHealing = true,
            DoFastHeal = true,
            DoRegenSpells = true,
            DoDamageShield = true,
            DoRoot = true,
            UseAdrenaline = true,
            UsePureshot = true,
            UseEmpoweredBlades = true,
            UseAuspiceOfTheHunter = true,
            UseSpireOfRanger = true,
            UseOutrider = true,
            UseChampionsClaim = true,
            UseScarletCheetah = true,
            UseDichotomic = true,
        },
        layerAssignments = {
            UseAdrenaline = "emergency",
            DoHealing = "support",
            DoFastHeal = "support",
            DoNukes = "combat",
            DoDoTs = "combat",
            DoSnare = "combat",
            DoRoot = "combat",
            UsePureshot = "burn",
            UseEmpoweredBlades = "burn",
            UseAuspiceOfTheHunter = "burn",
            UseSpireOfRanger = "burn",
            UseOutrider = "burn",
            UseChampionsClaim = "burn",
            UseScarletCheetah = "burn",
            UseDichotomic = "burn",
            DoRegenSpells = "utility",
            DoDamageShield = "utility",
        },
        layerOrder = {
            emergency = {"UseAdrenaline"},
            support = {"DoHealing", "DoFastHeal"},
            combat = {"DoSnare", "DoNukes", "DoDoTs", "DoRoot"},
            burn = {"UsePureshot", "UseEmpoweredBlades", "UseAuspiceOfTheHunter", "UseScarletCheetah", "UseSpireOfRanger", "UseOutrider", "UseChampionsClaim", "UseDichotomic"},
            buff = {"DoRegenSpells", "DoDamageShield"},
        },
    },
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
    DoFastHeal = {
        Default = true,
        Category = "Heal",
        DisplayName = "Fast Heal",
    },
    DoSnare = {
        Default = true,
        Category = "Utility",
        DisplayName = "Auto-Snare",
    },
    DoRoot = {
        Default = false,
        Category = "Utility",
        DisplayName = "Auto-Root",
    },
    DoRegenSpells = {
        Default = true,
        Category = "Utility",
        DisplayName = "Regen",
    },
    DoDamageShield = {
        Default = true,
        Category = "Utility",
        DisplayName = "Damage Shield",
    },
    UseAdrenaline = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Adrenaline",
    },
    UsePureshot = {
        Default = true,
        Category = "Burn",
        DisplayName = "Pureshot",
    },
    UseEmpoweredBlades = {
        Default = true,
        Category = "Burn",
        DisplayName = "Empowered Blades",
    },
    UseAuspiceOfTheHunter = {
        Default = true,
        Category = "Burn",
        DisplayName = "Auspice",
    },
    UseSpireOfRanger = {
        Default = true,
        Category = "Burn",
        DisplayName = "Spire of Ranger",
    },
    UseOutrider = {
        Default = true,
        Category = "Burn",
        DisplayName = "Outrider",
    },
    UseChampionsClaim = {
        Default = true,
        Category = "Burn",
        DisplayName = "Champion's Claim",
    },
    UseScarletCheetah = {
        Default = true,
        Category = "Burn",
        DisplayName = "Scarlet Cheetah",
    },
    UseDichotomic = {
        Default = true,
        Category = "Burn",
        DisplayName = "Dichotomic",
    },
}

return M
