-- F:/lua/SideKick/data/class_configs/BER.lua
-- Berserker Class Configuration with condition-based rotations

local mq = require('mq')

local M = {}

-- Disc Lines
M.discLines = {
    ['CleansingRage'] = { "Cleansing Rage Discipline", "Reckless Rage" },
    ['Bloodfury'] = { "Bloodfury Discipline" },
    ['SavageSpirit'] = { "Savage Spirit Discipline" },
    ['Frenzy'] = { "Frenzy" },
    ['Volley'] = { "Volley Discipline", "Throwing Axe" },
    ['Axe'] = { "Axe of the Destroyer", "Axe of the Vindicator" },
    ['Juggernaut'] = { "Juggernaut Surge" },
    ['Assault'] = { "Assault Discipline" },
    ['Blinding'] = { "Blinding Fury Discipline" },
    ['Destruction'] = { "Destruction Discipline" },
}

-- AA Lines
M.aaLines = {
    ['BloodPact'] = { "Blood Pact" },
    ['Bloodfury'] = { "Bloodfury" },
    ['Frenzy'] = { "Frenzy" },
    ['WarCry'] = { "War Cry" },
    ['BattleLeap'] = { "Battle Leap" },
    ['SpireOfBerserker'] = { "Spire of the Juggernaut" },
    ['Intensity'] = { "Intensity of the Resolute" },
    ['DecapitateAA'] = { "Decapitate" },
    ['VehementRage'] = { "Vehement Rage" },
    ['ChillingRage'] = { "Chilling Rage" },
    ['Dichotomic'] = { "Dichotomic Rage" },
}

-- Default conditions
M.defaultConditions = {
    ['doBloodPact'] = function(ctx)
        return ctx.me.pctHPs < 30
    end,

    ['doFrenzy'] = function(ctx)
        return ctx.combat
    end,
    ['doVolley'] = function(ctx)
        return ctx.combat and ctx.me.pctEnd > 20
    end,
    ['doAxe'] = function(ctx)
        return ctx.combat
    end,
    ['doWarCry'] = function(ctx)
        return ctx.combat and not ctx.me.buff('War Cry')
    end,
    ['doBattleLeap'] = function(ctx)
        return ctx.combat
    end,

    ['doCleansingRage'] = function(ctx)
        return ctx.burn and not ctx.me.activeDisc
    end,
    ['doBloodfury'] = function(ctx)
        return ctx.burn
    end,
    ['doSavageSpirit'] = function(ctx)
        return ctx.burn
    end,
    ['doJuggernaut'] = function(ctx)
        return ctx.burn and ctx.target.named
    end,
    ['doAssault'] = function(ctx)
        return ctx.burn and not ctx.me.activeDisc
    end,
    ['doBlinding'] = function(ctx)
        return ctx.burn and not ctx.me.activeDisc
    end,
    ['doDestruction'] = function(ctx)
        return ctx.burn and ctx.target.named and not ctx.me.activeDisc
    end,

    ['doSpireOfBerserker'] = function(ctx)
        return ctx.burn
    end,
    ['doIntensity'] = function(ctx)
        return ctx.burn
    end,
    ['doDecapitateAA'] = function(ctx)
        return ctx.burn and ctx.combat
    end,
    ['doVehementRage'] = function(ctx)
        return ctx.burn
    end,
    ['doChillingRage'] = function(ctx)
        return ctx.burn
    end,
    ['doDichotomic'] = function(ctx)
        return ctx.burn and ctx.combat
    end,
}

-- Category overrides
M.categoryOverrides = {
    ['doBloodPact'] = 'emergency',
    ['doFrenzy'] = 'combat',
    ['doVolley'] = 'combat',
    ['doAxe'] = 'combat',
    ['doWarCry'] = 'combat',
    ['doBattleLeap'] = 'combat',
    ['doCleansingRage'] = 'burn',
    ['doBloodfury'] = 'burn',
    ['doSavageSpirit'] = 'burn',
    ['doJuggernaut'] = 'burn',
    ['doAssault'] = 'burn',
    ['doBlinding'] = 'burn',
    ['doDestruction'] = 'burn',
    ['doSpireOfBerserker'] = 'burn',
    ['doIntensity'] = 'burn',
    ['doDecapitateAA'] = 'burn',
    ['doVehementRage'] = 'burn',
    ['doChillingRage'] = 'burn',
    ['doDichotomic'] = 'burn',
}

-- AbilitySets: Disc/AA progressions (highest to lowest rank)
-- Berserker has no spells
M.AbilitySets = {
    -- Cleansing Rage
    CleansingRage = { "Cleansing Rage Discipline", "Reckless Rage" },
    -- Bloodfury
    Bloodfury = { "Bloodfury Discipline" },
    -- Savage Spirit
    SavageSpirit = { "Savage Spirit Discipline" },
    -- Frenzy
    Frenzy = { "Frenzy" },
    -- Volley
    Volley = { "Volley Discipline", "Throwing Axe" },
    -- Axe
    Axe = { "Axe of the Destroyer", "Axe of the Vindicator" },
    -- Juggernaut
    Juggernaut = { "Juggernaut Surge" },
    -- Assault
    Assault = { "Assault Discipline" },
    -- Blinding
    Blinding = { "Blinding Fury Discipline" },
    -- Destruction
    Destruction = { "Destruction Discipline" },
    -- AA: Blood Pact
    BloodPactAA = { "Blood Pact" },
    -- AA: Bloodfury
    BloodfuryAA = { "Bloodfury" },
    -- AA: War Cry
    WarCryAA = { "War Cry" },
    -- AA: Battle Leap
    BattleLeapAA = { "Battle Leap" },
    -- AA: Spire of the Juggernaut
    SpireOfBerserkerAA = { "Spire of the Juggernaut" },
    -- AA: Intensity
    IntensityAA = { "Intensity of the Resolute" },
    -- AA: Decapitate
    DecapitateAA = { "Decapitate" },
    -- AA: Vehement Rage
    VehementRageAA = { "Vehement Rage" },
    -- AA: Chilling Rage
    ChillingRageAA = { "Chilling Rage" },
    -- AA: Dichotomic Rage
    DichotomicAA = { "Dichotomic Rage" },
}

-- SpellLoadouts: Role-based configurations with extended schema
-- Berserker has no spells, so gems are empty
M.SpellLoadouts = {
    dps = {
        name = "DPS Focused",
        description = "Maximize damage output",
        gems = {},
        defaults = {
            -- Combat
            DoFrenzy = true,
            DoVolley = true,
            DoAxe = true,
            DoWarCry = true,
            DoBattleLeap = true,
            -- Emergency
            UseBloodPact = true,
            -- Burns
            UseCleansingRage = true,
            UseBloodfury = true,
            UseSavageSpirit = true,
            UseJuggernaut = true,
            UseAssault = true,
            UseBlinding = true,
            UseDestruction = true,
            UseSpireOfBerserker = true,
            UseIntensity = true,
            UseDecapitate = true,
            UseVehementRage = true,
            UseChillingRage = true,
            UseDichotomic = true,
        },
        layerAssignments = {
            -- Emergency
            UseBloodPact = "emergency",
            -- Combat
            DoFrenzy = "combat",
            DoVolley = "combat",
            DoAxe = "combat",
            DoWarCry = "combat",
            DoBattleLeap = "combat",
            -- Burn
            UseCleansingRage = "burn",
            UseBloodfury = "burn",
            UseSavageSpirit = "burn",
            UseJuggernaut = "burn",
            UseAssault = "burn",
            UseBlinding = "burn",
            UseDestruction = "burn",
            UseSpireOfBerserker = "burn",
            UseIntensity = "burn",
            UseDecapitate = "burn",
            UseVehementRage = "burn",
            UseChillingRage = "burn",
            UseDichotomic = "burn",
        },
        layerOrder = {
            emergency = {"UseBloodPact"},
            combat = {"DoFrenzy", "DoVolley", "DoAxe", "DoWarCry", "DoBattleLeap"},
            burn = {"UseCleansingRage", "UseBloodfury", "UseSavageSpirit", "UseJuggernaut", "UseAssault", "UseBlinding", "UseDestruction", "UseSpireOfBerserker", "UseIntensity", "UseDecapitate", "UseVehementRage", "UseChillingRage", "UseDichotomic"},
        },
    },
}

M.Settings = {
    DoFrenzy = {
        Default = true,
        Category = "Combat",
        DisplayName = "Frenzy",
    },
    DoVolley = {
        Default = true,
        Category = "Combat",
        DisplayName = "Volley",
    },
    DoAxe = {
        Default = true,
        Category = "Combat",
        DisplayName = "Axe",
    },
    DoWarCry = {
        Default = true,
        Category = "Combat",
        DisplayName = "War Cry",
    },
    DoBattleLeap = {
        Default = true,
        Category = "Combat",
        DisplayName = "Battle Leap",
    },
    UseBloodPact = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Blood Pact",
    },
    UseCleansingRage = {
        Default = true,
        Category = "Burn",
        DisplayName = "Cleansing Rage",
    },
    UseBloodfury = {
        Default = true,
        Category = "Burn",
        DisplayName = "Bloodfury",
    },
    UseSavageSpirit = {
        Default = true,
        Category = "Burn",
        DisplayName = "Savage Spirit",
    },
    UseJuggernaut = {
        Default = true,
        Category = "Burn",
        DisplayName = "Juggernaut",
    },
    UseAssault = {
        Default = true,
        Category = "Burn",
        DisplayName = "Assault",
    },
    UseBlinding = {
        Default = true,
        Category = "Burn",
        DisplayName = "Blinding",
    },
    UseDestruction = {
        Default = true,
        Category = "Burn",
        DisplayName = "Destruction",
    },
    UseSpireOfBerserker = {
        Default = true,
        Category = "Burn",
        DisplayName = "Spire of Berserker",
    },
    UseIntensity = {
        Default = true,
        Category = "Burn",
        DisplayName = "Intensity",
    },
    UseDecapitate = {
        Default = true,
        Category = "Burn",
        DisplayName = "Decapitate",
    },
    UseVehementRage = {
        Default = true,
        Category = "Burn",
        DisplayName = "Vehement Rage",
    },
    UseChillingRage = {
        Default = true,
        Category = "Burn",
        DisplayName = "Chilling Rage",
    },
    UseDichotomic = {
        Default = true,
        Category = "Burn",
        DisplayName = "Dichotomic",
    },
}

return M
