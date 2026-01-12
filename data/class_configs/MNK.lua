-- F:/lua/SideKick/data/class_configs/MNK.lua
-- Monk Class Configuration with condition-based rotations

local mq = require('mq')

local M = {}

-- Disc Lines
M.discLines = {
    ['Innerflame'] = { "Innerflame Discipline", "Heel of Kanji" },
    ['Speed'] = { "Speed Focus Discipline" },
    ['EarthForce'] = { "Earth Force Discipline" },
    ['Ironfist'] = { "Ironfist Discipline" },
    ['Terrorpalm'] = { "Terrorpalm Discipline" },
    ['Shuriken'] = { "Shuriken Storm" },
    ['Crane'] = { "Crane Stance" },
    ['Thunderfoot'] = { "Thunderfoot Discipline" },
    ['Impenetrable'] = { "Impenetrable Discipline" },
}

-- AA Lines
M.aaLines = {
    ['FeignDeath'] = { "Feign Death" },
    ['MendWounds'] = { "Mend", "Imitate Death" },
    ['FlyingKick'] = { "Flying Kick" },
    ['TigerClaw'] = { "Tiger Claw" },
    ['EagleStrike'] = { "Eagle Strike" },
    ['DragonPunch'] = { "Dragon Punch" },
    ['Intimidation'] = { "Intimidation" },
    ['SpireOfMonk'] = { "Spire of the Sensei" },
    ['Intensity'] = { "Intensity of the Resolute" },
    ['CraneStance'] = { "Crane Stance" },
    ['ThousandFists'] = { "Thousand Fists Discipline" },
    ['DichotomicForm'] = { "Dichotomic Form" },
}

-- Default conditions
M.defaultConditions = {
    ['doFeignDeath'] = function(ctx)
        return ctx.me.pctHPs < 20 or ctx.me.pctAggro > 95
    end,
    ['doMendWounds'] = function(ctx)
        return ctx.me.pctHPs < 50
    end,
    ['doImpenetrable'] = function(ctx)
        return ctx.me.pctHPs < 40 and not ctx.me.activeDisc
    end,

    ['doFlyingKick'] = function(ctx)
        return ctx.combat
    end,
    ['doTigerClaw'] = function(ctx)
        return ctx.combat
    end,
    ['doEagleStrike'] = function(ctx)
        return ctx.combat
    end,
    ['doDragonPunch'] = function(ctx)
        return ctx.combat
    end,
    ['doIntimidation'] = function(ctx)
        return ctx.combat and ctx.me.pctEnd > 30
    end,
    ['doShuriken'] = function(ctx)
        return ctx.combat and ctx.me.pctEnd > 40
    end,

    ['doInnerflame'] = function(ctx)
        return ctx.burn and not ctx.me.activeDisc
    end,
    ['doSpeed'] = function(ctx)
        return ctx.burn
    end,
    ['doEarthForce'] = function(ctx)
        return ctx.burn
    end,
    ['doIronfist'] = function(ctx)
        return ctx.burn and not ctx.me.activeDisc
    end,
    ['doTerrorpalm'] = function(ctx)
        return ctx.burn and not ctx.me.activeDisc
    end,
    ['doThunderfoot'] = function(ctx)
        return ctx.burn
    end,

    ['doSpireOfMonk'] = function(ctx)
        return ctx.burn
    end,
    ['doIntensity'] = function(ctx)
        return ctx.burn
    end,
    ['doCraneStance'] = function(ctx)
        return ctx.burn
    end,
    ['doThousandFists'] = function(ctx)
        return ctx.burn and not ctx.me.activeDisc
    end,
    ['doDichotomicForm'] = function(ctx)
        return ctx.burn and ctx.combat
    end,
}

-- Category overrides
M.categoryOverrides = {
    ['doFeignDeath'] = 'emergency',
    ['doMendWounds'] = 'emergency',
    ['doImpenetrable'] = 'defenses',
    ['doFlyingKick'] = 'combat',
    ['doTigerClaw'] = 'combat',
    ['doEagleStrike'] = 'combat',
    ['doDragonPunch'] = 'combat',
    ['doIntimidation'] = 'combat',
    ['doShuriken'] = 'combat',
    ['doInnerflame'] = 'burn',
    ['doSpeed'] = 'burn',
    ['doEarthForce'] = 'burn',
    ['doIronfist'] = 'burn',
    ['doTerrorpalm'] = 'burn',
    ['doThunderfoot'] = 'burn',
    ['doSpireOfMonk'] = 'burn',
    ['doIntensity'] = 'burn',
    ['doCraneStance'] = 'burn',
    ['doThousandFists'] = 'burn',
    ['doDichotomicForm'] = 'burn',
}

M.Settings = {
    DoFlyingKick = {
        Default = true,
        Category = "Combat",
        DisplayName = "Flying Kick",
    },
    DoIntimidation = {
        Default = true,
        Category = "Combat",
        DisplayName = "Intimidation",
    },
    UseDefenseDiscs = {
        Default = true,
        Category = "Defense",
        DisplayName = "Defense Discs",
    },
}

return M
