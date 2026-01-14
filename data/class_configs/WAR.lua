-- F:/lua/SideKick/data/class_configs/WAR.lua
-- Warrior Class Configuration with condition-based rotations
-- Pure melee class - no spells

local mq = require('mq')

local M = {}

-- No spell lines for warrior (pure melee)

-- Disc Lines
M.discLines = {
    -- Defensive Stand Disciplines (Timer 02)
    ['StandDisc'] = {
        "Climactic Stand", "Resolute Stand", "Ultimate Stand Discipline",
        "Culminating Stand Discipline", "Last Stand Discipline",
        "Final Stand Discipline", "Defensive Discipline",
    },

    -- Fortitude (Timer 03)
    ['Fortitude'] = { "Fortitude Discipline" },

    -- Absorption Disciplines (Timer 18)
    ['AbsorbDisc'] = {
        "End of the Line", "Finish the Fight",
        "Pain Doesn't Hurt", "No Time to Bleed",
    },

    -- Shield Attacks (Timer 22)
    ['ShieldHit'] = {
        "Shield Split", "Shield Rupture", "Shield Splinter",
        "Shield Sunder", "Shield Break", "Shield Topple",
    },

    -- Primary Hate Generation
    ['AddHate1'] = {
        "Mortimus' Roar", "Namdrows' Roar", "Kragek's Roar",
        "Kluzen's Roar", "Cyclone Roar", "Krondal's Roar",
        "Grendlaen Roar", "Bazu Roar", "Ancient: Chaos Cry",
    },

    -- Secondary Hate Generation
    ['AddHate2'] = {
        "Distressing Shout", "Twilight Shout", "Oppressing Shout",
        "Burning Shout", "Tormenting Shout", "Harassing Shout",
    },

    -- Absorb Taunt (Timer 09)
    ['AbsorbTaunt'] = {
        "Infuriate", "Bristle", "Aggravate", "Slander",
        "Insult", "Ridicule", "Scorn", "Scoff",
    },

    -- AE Blades (Timer 10)
    ['AEBlades'] = {
        "Cyclone Blades XIV", "Spiraling Blades", "Hurricane Blades",
        "Tempest Blades", "Dragonstrike Blades", "Stormstrike Blades",
    },

    -- Attention (Timer 15)
    ['Attention'] = {
        "Unquestioned Attention", "Unconditional Attention",
        "Unrelenting Attention", "Unending Attention",
        "Unyielding Attention", "Unflinching Attention",
    },

    -- Endurance Regeneration (Timer 13)
    ['EndRegen'] = {
        "Hiatus V", "Convalesce", "Night's Calming", "Relax",
        "Hiatus", "Breather", "Seventh Wind", "Rest",
    },

    -- Onslaught Disciplines (Timer 06)
    ['Onslaught'] = {
        "Brightfeld's Onslaught Discipline",
        "Brutal Onslaught Discipline",
        "Savage Onslaught Discipline",
    },

    -- Warrior's Rune Shield (Timer 16)
    ['RuneShield'] = {
        "Warrior's Resolve", "Warrior's Aegis", "Warrior's Rampart",
        "Warrior's Bastion", "Warrior's Bulwark", "Warrior's Auspice",
    },

    -- Tongue Disciplines (Timer 04)
    ['TongueDisc'] = {
        "Razor Tongue Discipline", "Biting Tongue Discipline",
        "Barbed Tongue Discipline",
    },
}

-- AA Lines
M.aaLines = {
    ['AgelessEnmity'] = { "Ageless Enmity" },
    ['BlastOfAnger'] = { "Blast of Anger" },
    ['ProjectionOfFury'] = { "Projection of Fury" },
    ['FlashOfAnger'] = { "Flash of Anger" },
    ['PhantomAggressor'] = { "Phantom Aggressor" },
    ['WarlordsFury'] = { "Warlord's Fury" },
    ['WarlordsTenacity'] = { "Warlord's Tenacity" },
    ['WarlordsResurgence'] = { "Warlord's Resurgence" },
    ['Resplendent'] = { "Resplendent Glory" },
    ['UnstoppableRage'] = { "Unstoppable Rage" },
    ['Imperator'] = { "Imperator's Command" },
    ['SpireOfWarrior'] = { "Spire of the Warlord" },
    ['Intensity'] = { "Intensity of the Resolute" },
}

-- Default Conditions
M.defaultConditions = {
    -- Emergency / Defense
    ['doFortitude'] = function(ctx)
        return ctx.me.pctHPs < 30 and not ctx.me.activeDisc
    end,
    ['doStandDisc'] = function(ctx)
        return ctx.me.pctHPs < 40 and not ctx.me.activeDisc
    end,
    ['doAbsorbDisc'] = function(ctx)
        return ctx.me.pctHPs < 50 and not ctx.me.activeDisc
    end,
    ['doRuneShield'] = function(ctx)
        return ctx.me.pctHPs < 60 and not ctx.me.buff('Warrior')
    end,
    ['doWarlordsResurgence'] = function(ctx)
        return ctx.me.pctHPs < 35
    end,

    -- Aggro / Hate
    ['doAddHate1'] = function(ctx)
        return ctx.combat
    end,
    ['doAddHate2'] = function(ctx)
        return ctx.combat
    end,
    ['doAbsorbTaunt'] = function(ctx)
        return ctx.combat
    end,
    ['doAgelessEnmity'] = function(ctx)
        return ctx.combat and ctx.me.pctAggro < 100 and ctx.target.pctHPs < 90
    end,
    ['doBlastOfAnger'] = function(ctx)
        return ctx.combat and ctx.target.secondaryPctAggro > 70
    end,
    ['doProjectionOfFury'] = function(ctx)
        return ctx.combat and ctx.target.named and ctx.target.secondaryPctAggro > 80
    end,
    ['doFlashOfAnger'] = function(ctx)
        return ctx.combat and ctx.me.pctAggro < 100
    end,
    ['doAttention'] = function(ctx)
        return ctx.combat and ctx.target.named
    end,
    ['doTongueDisc'] = function(ctx)
        return ctx.combat and ctx.me.pctAggro < 100
    end,

    -- AE Aggro
    ['doAEBlades'] = function(ctx)
        return ctx.combat and ctx.me.xTargetCount >= 3 and ctx.spawn.count('npc xtarhater radius 50') >= 3
    end,

    -- Combat
    ['doShieldHit'] = function(ctx)
        return ctx.combat
    end,
    ['doPhantomAggressor'] = function(ctx)
        return ctx.combat and ctx.target.named
    end,

    -- Endurance
    ['doEndRegen'] = function(ctx)
        return ctx.me.pctEnd < 30 and not ctx.combat
    end,

    -- Burn
    ['doOnslaught'] = function(ctx)
        return ctx.burn and not ctx.me.activeDisc
    end,
    ['doWarlordsFury'] = function(ctx)
        return ctx.burn
    end,
    ['doWarlordsTenacity'] = function(ctx)
        return ctx.burn
    end,
    ['doResplendent'] = function(ctx)
        return ctx.burn
    end,
    ['doUnstoppableRage'] = function(ctx)
        return ctx.burn and ctx.target.named
    end,
    ['doImperator'] = function(ctx)
        return ctx.burn and ctx.target.named
    end,
    ['doSpireOfWarrior'] = function(ctx)
        return ctx.burn
    end,
    ['doIntensity'] = function(ctx)
        return ctx.burn
    end,
}

-- Category Overrides
M.categoryOverrides = {
    ['doFortitude'] = 'emergency',
    ['doStandDisc'] = 'defenses',
    ['doAbsorbDisc'] = 'defenses',
    ['doRuneShield'] = 'defenses',
    ['doWarlordsResurgence'] = 'emergency',
    ['doAddHate1'] = 'aggro',
    ['doAddHate2'] = 'aggro',
    ['doAbsorbTaunt'] = 'aggro',
    ['doAgelessEnmity'] = 'aggro',
    ['doBlastOfAnger'] = 'aggro',
    ['doProjectionOfFury'] = 'aggro',
    ['doFlashOfAnger'] = 'aggro',
    ['doAttention'] = 'aggro',
    ['doTongueDisc'] = 'aggro',
    ['doAEBlades'] = 'aggro',
    ['doShieldHit'] = 'combat',
    ['doPhantomAggressor'] = 'combat',
    ['doEndRegen'] = 'utility',
    ['doOnslaught'] = 'burn',
    ['doWarlordsFury'] = 'burn',
    ['doWarlordsTenacity'] = 'burn',
    ['doResplendent'] = 'burn',
    ['doUnstoppableRage'] = 'burn',
    ['doImperator'] = 'burn',
    ['doSpireOfWarrior'] = 'burn',
    ['doIntensity'] = 'burn',
}

-- AbilitySets: Disc/AA progressions (highest to lowest rank)
-- Warrior has no spells, uses discs and abilities
M.AbilitySets = {
    -- Defensive Stand (Timer 02)
    StandDisc = {
        "Climactic Stand", "Resolute Stand", "Ultimate Stand Discipline",
        "Culminating Stand Discipline", "Last Stand Discipline",
        "Final Stand Discipline", "Defensive Discipline",
    },
    -- Fortitude (Timer 03)
    Fortitude = { "Fortitude Discipline" },
    -- Absorption (Timer 18)
    AbsorbDisc = {
        "End of the Line", "Finish the Fight",
        "Pain Doesn't Hurt", "No Time to Bleed",
    },
    -- Shield Attacks (Timer 22)
    ShieldHit = {
        "Shield Split", "Shield Rupture", "Shield Splinter",
        "Shield Sunder", "Shield Break", "Shield Topple",
    },
    -- Primary Hate (Roar)
    AddHate1 = {
        "Mortimus' Roar", "Namdrows' Roar", "Kragek's Roar",
        "Kluzen's Roar", "Cyclone Roar", "Krondal's Roar",
    },
    -- Secondary Hate (Shout)
    AddHate2 = {
        "Distressing Shout", "Twilight Shout", "Oppressing Shout",
        "Burning Shout", "Tormenting Shout", "Harassing Shout",
    },
    -- Absorb Taunt (Timer 09)
    AbsorbTaunt = {
        "Infuriate", "Bristle", "Aggravate", "Slander",
        "Insult", "Ridicule", "Scorn", "Scoff",
    },
    -- AE Blades (Timer 10)
    AEBlades = {
        "Cyclone Blades XIV", "Spiraling Blades", "Hurricane Blades",
        "Tempest Blades", "Dragonstrike Blades", "Stormstrike Blades",
    },
    -- Attention (Timer 15)
    Attention = {
        "Unquestioned Attention", "Unconditional Attention",
        "Unrelenting Attention", "Unending Attention",
        "Unyielding Attention", "Unflinching Attention",
    },
    -- Onslaught (Timer 06)
    Onslaught = {
        "Brightfeld's Onslaught Discipline",
        "Brutal Onslaught Discipline",
        "Savage Onslaught Discipline",
    },
    -- Rune Shield (Timer 16)
    RuneShield = {
        "Warrior's Resolve", "Warrior's Aegis", "Warrior's Rampart",
        "Warrior's Bastion", "Warrior's Bulwark", "Warrior's Auspice",
    },
    -- Tongue (Timer 04)
    TongueDisc = {
        "Razor Tongue Discipline", "Biting Tongue Discipline",
        "Barbed Tongue Discipline",
    },
    -- AA: Ageless Enmity
    AgelessEnmityAA = { "Ageless Enmity" },
    -- AA: Blast of Anger
    BlastOfAngerAA = { "Blast of Anger" },
    -- AA: Projection of Fury
    ProjectionOfFuryAA = { "Projection of Fury" },
    -- AA: Flash of Anger
    FlashOfAngerAA = { "Flash of Anger" },
    -- AA: Phantom Aggressor
    PhantomAggressorAA = { "Phantom Aggressor" },
    -- AA: Warlord's Fury
    WarlordsFuryAA = { "Warlord's Fury" },
    -- AA: Warlord's Tenacity
    WarlordsTenacityAA = { "Warlord's Tenacity" },
    -- AA: Warlord's Resurgence
    WarlordsResurgenceAA = { "Warlord's Resurgence" },
    -- AA: Resplendent Glory
    ResplendentAA = { "Resplendent Glory" },
    -- AA: Unstoppable Rage
    UnstoppableRageAA = { "Unstoppable Rage" },
    -- AA: Imperator's Command
    ImperatorAA = { "Imperator's Command" },
    -- AA: Spire of the Warlord
    SpireOfWarriorAA = { "Spire of the Warlord" },
    -- AA: Intensity of the Resolute
    IntensityAA = { "Intensity of the Resolute" },
}

-- SpellLoadouts: Role-based configurations with extended schema
-- Warrior has no spells, so gems are empty but defaults/layers are used
M.SpellLoadouts = {
    tank = {
        name = "Tank Focused",
        description = "Focus on aggro and defense",
        gems = {}, -- No spell gems for Warrior
        defaults = {
            -- Aggro
            DoRoar = true,
            DoShout = true,
            DoAbsorbTaunt = true,
            DoAttention = true,
            DoTongue = true,
            UseAETaunt = true,
            -- Combat
            DoShieldHit = true,
            -- Emergency
            UseFortitude = true,
            UseWarlordsResurgence = true,
            -- Defenses
            UseDefenseDiscs = true,
            UseStandDisc = true,
            UseAbsorbDisc = true,
            UseRuneShield = true,
            -- Burns
            UseOnslaught = true,
            UseWarlordsFury = true,
            UseWarlordsTenacity = true,
            UseSpireOfWarrior = true,
            UseIntensity = true,
        },
        layerAssignments = {
            -- Emergency
            UseFortitude = "emergency",
            UseWarlordsResurgence = "emergency",
            -- Defenses
            UseDefenseDiscs = "defenses",
            UseStandDisc = "defenses",
            UseAbsorbDisc = "defenses",
            UseRuneShield = "defenses",
            -- Aggro
            DoRoar = "aggro",
            DoShout = "aggro",
            DoAbsorbTaunt = "aggro",
            DoAttention = "aggro",
            DoTongue = "aggro",
            UseAETaunt = "aggro",
            -- Combat
            DoShieldHit = "combat",
            -- Burn
            UseOnslaught = "burn",
            UseWarlordsFury = "burn",
            UseWarlordsTenacity = "burn",
            UseSpireOfWarrior = "burn",
            UseIntensity = "burn",
        },
        layerOrder = {
            emergency = {"UseFortitude", "UseWarlordsResurgence"},
            defenses = {"UseStandDisc", "UseAbsorbDisc", "UseRuneShield", "UseDefenseDiscs"},
            aggro = {"DoRoar", "DoShout", "DoAbsorbTaunt", "DoAttention", "DoTongue", "UseAETaunt"},
            combat = {"DoShieldHit"},
            burn = {"UseOnslaught", "UseWarlordsFury", "UseWarlordsTenacity", "UseSpireOfWarrior", "UseIntensity"},
        },
    },
    dps = {
        name = "DPS Focused",
        description = "Maximize damage output",
        gems = {},
        defaults = {
            -- Aggro (minimal)
            DoRoar = true,
            DoShout = false,
            DoAbsorbTaunt = false,
            DoAttention = false,
            DoTongue = false,
            UseAETaunt = false,
            -- Combat
            DoShieldHit = true,
            -- Emergency
            UseFortitude = true,
            UseWarlordsResurgence = true,
            -- Defenses (minimal)
            UseDefenseDiscs = false,
            UseStandDisc = false,
            UseAbsorbDisc = false,
            UseRuneShield = true,
            -- Burns
            UseOnslaught = true,
            UseWarlordsFury = true,
            UseWarlordsTenacity = true,
            UseSpireOfWarrior = true,
            UseIntensity = true,
        },
        layerAssignments = {
            UseFortitude = "emergency",
            UseWarlordsResurgence = "emergency",
            UseDefenseDiscs = "defenses",
            UseStandDisc = "defenses",
            UseAbsorbDisc = "defenses",
            UseRuneShield = "defenses",
            DoRoar = "aggro",
            DoShout = "aggro",
            DoAbsorbTaunt = "aggro",
            DoAttention = "aggro",
            DoTongue = "aggro",
            UseAETaunt = "aggro",
            DoShieldHit = "combat",
            UseOnslaught = "burn",
            UseWarlordsFury = "burn",
            UseWarlordsTenacity = "burn",
            UseSpireOfWarrior = "burn",
            UseIntensity = "burn",
        },
        layerOrder = {
            emergency = {"UseFortitude", "UseWarlordsResurgence"},
            defenses = {"UseRuneShield", "UseStandDisc", "UseAbsorbDisc", "UseDefenseDiscs"},
            aggro = {"DoRoar", "DoShout", "DoAbsorbTaunt", "DoAttention", "DoTongue", "UseAETaunt"},
            combat = {"DoShieldHit"},
            burn = {"UseOnslaught", "UseWarlordsFury", "UseWarlordsTenacity", "UseIntensity", "UseSpireOfWarrior"},
        },
    },
}

M.Settings = {
    DoRoar = {
        Default = true,
        Category = "Aggro",
        DisplayName = "Use Roar",
    },
    DoShout = {
        Default = true,
        Category = "Aggro",
        DisplayName = "Use Shout",
    },
    DoAbsorbTaunt = {
        Default = true,
        Category = "Aggro",
        DisplayName = "Absorb Taunt",
    },
    DoAttention = {
        Default = true,
        Category = "Aggro",
        DisplayName = "Attention",
    },
    DoTongue = {
        Default = true,
        Category = "Aggro",
        DisplayName = "Tongue Disc",
    },
    UseAETaunt = {
        Default = true,
        Category = "Aggro",
        DisplayName = "AE Taunt",
    },
    AETauntThreshold = {
        Default = 3,
        Category = "Aggro",
        DisplayName = "AE Taunt Mob Count",
        Min = 2,
        Max = 10,
    },
    SafeAECheck = {
        Default = true,
        Category = "Aggro",
        DisplayName = "Safe AE Check",
        Tooltip = "Only AE if all NPCs in range are hostile",
    },
    DoShieldHit = {
        Default = true,
        Category = "Combat",
        DisplayName = "Shield Hit",
    },
    UseFortitude = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Fortitude",
    },
    UseWarlordsResurgence = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Warlord's Resurgence",
    },
    UseDefenseDiscs = {
        Default = true,
        Category = "Defense",
        DisplayName = "Defense Discs",
    },
    UseStandDisc = {
        Default = true,
        Category = "Defense",
        DisplayName = "Stand Disc",
    },
    UseAbsorbDisc = {
        Default = true,
        Category = "Defense",
        DisplayName = "Absorb Disc",
    },
    UseRuneShield = {
        Default = true,
        Category = "Defense",
        DisplayName = "Rune Shield",
    },
    UseOnslaught = {
        Default = true,
        Category = "Burn",
        DisplayName = "Onslaught",
    },
    UseWarlordsFury = {
        Default = true,
        Category = "Burn",
        DisplayName = "Warlord's Fury",
    },
    UseWarlordsTenacity = {
        Default = true,
        Category = "Burn",
        DisplayName = "Warlord's Tenacity",
    },
    UseSpireOfWarrior = {
        Default = true,
        Category = "Burn",
        DisplayName = "Spire of Warrior",
    },
    UseIntensity = {
        Default = true,
        Category = "Burn",
        DisplayName = "Intensity",
    },
}

return M
