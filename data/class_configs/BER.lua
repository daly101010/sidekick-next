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
    DoWarCry = {
        Default = true,
        Category = "Combat",
        DisplayName = "War Cry",
    },
}

return M
