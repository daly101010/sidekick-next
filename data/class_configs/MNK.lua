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

-- AbilitySets: Disc/AA progressions (highest to lowest rank)
-- Monk has no spells
M.AbilitySets = {
    -- Innerflame
    Innerflame = { "Innerflame Discipline", "Heel of Kanji" },
    -- Speed
    Speed = { "Speed Focus Discipline" },
    -- Earth Force
    EarthForce = { "Earth Force Discipline" },
    -- Ironfist
    Ironfist = { "Ironfist Discipline" },
    -- Terrorpalm
    Terrorpalm = { "Terrorpalm Discipline" },
    -- Shuriken
    Shuriken = { "Shuriken Storm" },
    -- Crane Stance
    Crane = { "Crane Stance" },
    -- Thunderfoot
    Thunderfoot = { "Thunderfoot Discipline" },
    -- Impenetrable
    Impenetrable = { "Impenetrable Discipline" },
    -- AA: Feign Death
    FeignDeathAA = { "Feign Death" },
    -- AA: Mend
    MendWoundsAA = { "Mend", "Imitate Death" },
    -- AA: Flying Kick
    FlyingKickAA = { "Flying Kick" },
    -- AA: Tiger Claw
    TigerClawAA = { "Tiger Claw" },
    -- AA: Eagle Strike
    EagleStrikeAA = { "Eagle Strike" },
    -- AA: Dragon Punch
    DragonPunchAA = { "Dragon Punch" },
    -- AA: Intimidation
    IntimidationAA = { "Intimidation" },
    -- AA: Spire of the Sensei
    SpireOfMonkAA = { "Spire of the Sensei" },
    -- AA: Intensity
    IntensityAA = { "Intensity of the Resolute" },
    -- AA: Crane Stance
    CraneStanceAA = { "Crane Stance" },
    -- AA: Thousand Fists
    ThousandFistsAA = { "Thousand Fists Discipline" },
    -- AA: Dichotomic Form
    DichotomicFormAA = { "Dichotomic Form" },
}

-- SpellLoadouts: Role-based configurations with extended schema
-- Monk has no spells, so gems are empty
M.SpellLoadouts = {
    dps = {
        name = "DPS Focused",
        description = "Maximize damage output",
        gems = {},
        defaults = {
            -- Combat
            DoFlyingKick = true,
            DoTigerClaw = true,
            DoEagleStrike = true,
            DoDragonPunch = true,
            DoIntimidation = true,
            DoShuriken = true,
            -- Emergency
            UseFeignDeath = true,
            UseMendWounds = true,
            -- Defenses
            UseDefenseDiscs = true,
            UseImpenetrable = true,
            -- Burns
            UseInnerflame = true,
            UseSpeed = true,
            UseEarthForce = true,
            UseIronfist = true,
            UseTerrorpalm = true,
            UseThunderfoot = true,
            UseSpireOfMonk = true,
            UseIntensity = true,
            UseCraneStance = true,
            UseThousandFists = true,
            UseDichotomicForm = true,
        },
        layerAssignments = {
            -- Emergency
            UseFeignDeath = "emergency",
            UseMendWounds = "emergency",
            -- Defenses
            UseDefenseDiscs = "defenses",
            UseImpenetrable = "defenses",
            -- Combat
            DoFlyingKick = "combat",
            DoTigerClaw = "combat",
            DoEagleStrike = "combat",
            DoDragonPunch = "combat",
            DoIntimidation = "combat",
            DoShuriken = "combat",
            -- Burn
            UseInnerflame = "burn",
            UseSpeed = "burn",
            UseEarthForce = "burn",
            UseIronfist = "burn",
            UseTerrorpalm = "burn",
            UseThunderfoot = "burn",
            UseSpireOfMonk = "burn",
            UseIntensity = "burn",
            UseCraneStance = "burn",
            UseThousandFists = "burn",
            UseDichotomicForm = "burn",
        },
        layerOrder = {
            emergency = {"UseFeignDeath", "UseMendWounds"},
            defenses = {"UseImpenetrable", "UseDefenseDiscs"},
            combat = {"DoFlyingKick", "DoTigerClaw", "DoEagleStrike", "DoDragonPunch", "DoIntimidation", "DoShuriken"},
            burn = {"UseInnerflame", "UseSpeed", "UseEarthForce", "UseIronfist", "UseTerrorpalm", "UseThunderfoot", "UseSpireOfMonk", "UseIntensity", "UseCraneStance", "UseThousandFists", "UseDichotomicForm"},
        },
    },
}

M.Settings = {
    DoFlyingKick = {
        Default = true,
        Category = "Combat",
        DisplayName = "Flying Kick",
    },
    DoTigerClaw = {
        Default = true,
        Category = "Combat",
        DisplayName = "Tiger Claw",
    },
    DoEagleStrike = {
        Default = true,
        Category = "Combat",
        DisplayName = "Eagle Strike",
    },
    DoDragonPunch = {
        Default = true,
        Category = "Combat",
        DisplayName = "Dragon Punch",
    },
    DoIntimidation = {
        Default = true,
        Category = "Combat",
        DisplayName = "Intimidation",
    },
    DoShuriken = {
        Default = true,
        Category = "Combat",
        DisplayName = "Shuriken",
    },
    UseFeignDeath = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Feign Death",
    },
    UseMendWounds = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Mend Wounds",
    },
    UseDefenseDiscs = {
        Default = true,
        Category = "Defense",
        DisplayName = "Defense Discs",
    },
    UseImpenetrable = {
        Default = true,
        Category = "Defense",
        DisplayName = "Impenetrable",
    },
    UseInnerflame = {
        Default = true,
        Category = "Burn",
        DisplayName = "Innerflame",
    },
    UseSpeed = {
        Default = true,
        Category = "Burn",
        DisplayName = "Speed",
    },
    UseEarthForce = {
        Default = true,
        Category = "Burn",
        DisplayName = "Earth Force",
    },
    UseIronfist = {
        Default = true,
        Category = "Burn",
        DisplayName = "Ironfist",
    },
    UseTerrorpalm = {
        Default = true,
        Category = "Burn",
        DisplayName = "Terrorpalm",
    },
    UseThunderfoot = {
        Default = true,
        Category = "Burn",
        DisplayName = "Thunderfoot",
    },
    UseSpireOfMonk = {
        Default = true,
        Category = "Burn",
        DisplayName = "Spire of Monk",
    },
    UseIntensity = {
        Default = true,
        Category = "Burn",
        DisplayName = "Intensity",
    },
    UseCraneStance = {
        Default = true,
        Category = "Burn",
        DisplayName = "Crane Stance",
    },
    UseThousandFists = {
        Default = true,
        Category = "Burn",
        DisplayName = "Thousand Fists",
    },
    UseDichotomicForm = {
        Default = true,
        Category = "Burn",
        DisplayName = "Dichotomic Form",
    },
}

return M
