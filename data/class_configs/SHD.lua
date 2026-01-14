-- F:/lua/SideKick/data/class_configs/SHD.lua
-- Shadow Knight Class Configuration with condition-based rotations

local mq = require('mq')

local M = {}

-- Spell Lines
M.spellLines = {
    -- Spear Nuke
    ['SpearNuke'] = {
        "Spear of Grelleth", "Spear of Vizat", "Spear of Tylix",
        "Spear of Bloodwretch", "Spear of Lazam", "Spear of Muram",
    },

    -- Life Tap
    ['LifeTap'] = {
        "Dire Confession", "Dire Covenant", "Dire Testimony",
        "Dire Declaration", "Dire Indictment", "Dire Accusation",
    },

    -- Terror (hate)
    ['Terror'] = {
        "Terror of Tarantella", "Terror of Teratoma", "Terror of Desolor",
        "Terror of Thule", "Terror of Discord", "Terror of Darkness",
    },

    -- Torrent (AE hate)
    ['Torrent'] = {
        "Torrent of Pain", "Torrent of Agony", "Torrent of Suffering",
        "Torrent of Misery", "Torrent of Hate", "Torrent of Anguish",
    },

    -- Poison DoT
    ['PoisonDoT'] = {
        "Dire Stenosis", "Dire Stricture", "Dire Convulsion",
        "Dire Seizure", "Dire Implication", "Dire Constriction",
    },

    -- Disease DoT
    ['DiseaseDoT'] = {
        "Blood of Laarthik", "Blood of Korihor", "Blood of Ikatiar",
        "Blood of Tearc", "Blood of Shoru", "Blood of Thule",
    },

    -- Corruption DoT
    ['CorruptionDoT'] = {
        "Spear of Grelleth", "Bond of Vulak", "Bond of Bynn",
        "Bond of Inruku", "Bond of Tatalros", "Bond of Mortality",
    },

    -- Hate Buff (buff that generates hate)
    ['HateBuff'] = {
        "Voice of Thule", "Voice of the Grave", "Voice of Death",
        "Shroud of Undeath", "Shroud of Discord",
    },

    -- Self Lifetap Proc
    ['LifetapProc'] = {
        "Lich Sting", "Mental Anguish", "Seething Hatred",
        "Touch of T`Vem", "Touch of Volatis", "Touch of the Warlord",
    },

    -- HP Buff
    ['HPBuff'] = {
        "Dire Shield", "Dark Shield", "Shadow Shield",
        "Unholy Guard", "Shroud of Pain",
    },

    -- Pet (skeletal servant)
    ['Pet'] = {
        "Servant of Darkness", "Minion of Darkness", "Child of Darkness",
        "Spawn of Darkness", "Specter of Darkness",
    },
}

-- Disc Lines
M.discLines = {
    ['Leechcurse'] = { "Leechcurse Discipline", "Vicious Bite of Chaos" },
    ['DeflectionDisc'] = { "Deflection Discipline" },
    ['UnholyAura'] = { "Unholy Aura Discipline" },
    ['DamageDisc'] = { "Reavers Bargain", "Insidious Denial" },
    ['AEAggroDisc'] = { "Explosion of Hatred", "Hateful Shock" },
}

-- AA Lines
M.aaLines = {
    ['ExplosionOfHatred'] = { "Explosion of Hatred" },
    ['ExplosionOfSpite'] = { "Explosion of Spite" },
    ['Leech'] = { "Leech Touch" },
    ['HarmTouch'] = { "Harm Touch" },
    ['ThoughtLeech'] = { "Thought Leech" },
    ['VisageOfDeath'] = { "Visage of Death" },
    ['SpireOfShadowKnight'] = { "Spire of the Reavers" },
}

-- Default conditions
M.defaultConditions = {
    ['doLeechcurse'] = function(ctx)
        return ctx.me.pctHPs < 35 and not ctx.me.activeDisc
    end,
    ['doDeflectionDisc'] = function(ctx)
        return ctx.me.pctHPs < 45 and ctx.me.xTargetCount > 4 and not ctx.me.activeDisc
    end,
    ['doUnholyAura'] = function(ctx)
        return ctx.me.pctHPs < 50 and ctx.target.named and not ctx.me.activeDisc
    end,
    ['doDamageDisc'] = function(ctx)
        return ctx.burn and not ctx.me.activeDisc
    end,
    ['doAEAggroDisc'] = function(ctx)
        return ctx.me.xTargetCount >= 3 and ctx.mode == 'Tank'
    end,

    ['doExplosionOfHatred'] = function(ctx)
        return ctx.me.xTargetCount >= 3 and ctx.spawn.npcRadius(50) > 1
    end,
    ['doExplosionOfSpite'] = function(ctx)
        return ctx.me.xTargetCount >= 2
    end,
    ['doLeech'] = function(ctx)
        return ctx.me.pctHPs < 60 and ctx.combat
    end,
    ['doHarmTouch'] = function(ctx)
        return ctx.target.named and ctx.burn
    end,
    ['doThoughtLeech'] = function(ctx)
        return ctx.me.pctMana < 40
    end,
    ['doVisageOfDeath'] = function(ctx)
        return ctx.me.pctHPs < 40 and ctx.combat
    end,

    ['doSpearNuke'] = function(ctx)
        return ctx.combat
    end,
    ['doLifeTap'] = function(ctx)
        return ctx.combat and ctx.me.pctHPs < 80
    end,
    ['doTerror'] = function(ctx)
        return ctx.mode == 'Tank' and not ctx.target.myBuff('Terror')
    end,
    ['doTorrent'] = function(ctx)
        return ctx.me.xTargetCount >= 2 and ctx.mode == 'Tank'
    end,
    ['doPoisonDoT'] = function(ctx)
        return ctx.target.named and not ctx.target.myBuff('Dire') and ctx.target.pctHPs > 30
    end,
    ['doDiseaseDoT'] = function(ctx)
        return ctx.target.named and not ctx.target.myBuff('Blood') and ctx.target.pctHPs > 30
    end,
    ['doCorruptionDoT'] = function(ctx)
        return ctx.target.named and not ctx.target.myBuff('Bond') and ctx.target.pctHPs > 30
    end,

    ['doHateBuff'] = function(ctx)
        return not ctx.me.buff('Voice') and ctx.mode == 'Tank'
    end,
    ['doLifetapProc'] = function(ctx)
        return not ctx.me.buff('Lich Sting') and not ctx.me.buff('Touch')
    end,
    ['doHPBuff'] = function(ctx)
        return not ctx.combat
    end,

    ['doSpireOfShadowKnight'] = function(ctx)
        return ctx.burn
    end,
}

-- Category overrides
M.categoryOverrides = {
    ['doLeechcurse'] = 'emergency',
    ['doDeflectionDisc'] = 'defenses',
    ['doUnholyAura'] = 'defenses',
    ['doDamageDisc'] = 'burn',
    ['doAEAggroDisc'] = 'aggro',
    ['doExplosionOfHatred'] = 'aggro',
    ['doExplosionOfSpite'] = 'aggro',
    ['doLeech'] = 'emergency',
    ['doHarmTouch'] = 'burn',
    ['doThoughtLeech'] = 'utility',
    ['doVisageOfDeath'] = 'defenses',
    ['doSpearNuke'] = 'combat',
    ['doLifeTap'] = 'combat',
    ['doTerror'] = 'aggro',
    ['doTorrent'] = 'aggro',
    ['doPoisonDoT'] = 'combat',
    ['doDiseaseDoT'] = 'combat',
    ['doCorruptionDoT'] = 'combat',
    ['doHateBuff'] = 'buff',
    ['doLifetapProc'] = 'buff',
    ['doHPBuff'] = 'buff',
    ['doSpireOfShadowKnight'] = 'burn',
}

-- AbilitySets: Spell/AA progressions (highest to lowest rank)
M.AbilitySets = {
    -- Spear Nuke
    SpearNuke = {
        "Spear of Grelleth", "Spear of Vizat", "Spear of Tylix",
        "Spear of Bloodwretch", "Spear of Lazam", "Spear of Muram",
    },
    -- Life Tap
    LifeTap = {
        "Dire Confession", "Dire Covenant", "Dire Testimony",
        "Dire Declaration", "Dire Indictment", "Dire Accusation",
    },
    -- Terror (hate)
    Terror = {
        "Terror of Tarantella", "Terror of Teratoma", "Terror of Desolor",
        "Terror of Thule", "Terror of Discord", "Terror of Darkness",
    },
    -- Torrent (AE hate)
    Torrent = {
        "Torrent of Pain", "Torrent of Agony", "Torrent of Suffering",
        "Torrent of Misery", "Torrent of Hate", "Torrent of Anguish",
    },
    -- Poison DoT
    PoisonDoT = {
        "Dire Stenosis", "Dire Stricture", "Dire Convulsion",
        "Dire Seizure", "Dire Implication", "Dire Constriction",
    },
    -- Disease DoT
    DiseaseDoT = {
        "Blood of Laarthik", "Blood of Korihor", "Blood of Ikatiar",
        "Blood of Tearc", "Blood of Shoru", "Blood of Thule",
    },
    -- Corruption DoT
    CorruptionDoT = {
        "Bond of Vulak", "Bond of Bynn", "Bond of Inruku",
        "Bond of Tatalros", "Bond of Mortality", "Bond of Death",
    },
    -- Hate Buff
    HateBuff = {
        "Voice of Thule", "Voice of the Grave", "Voice of Death",
        "Shroud of Undeath", "Shroud of Discord",
    },
    -- Lifetap Proc
    LifetapProc = {
        "Lich Sting", "Mental Anguish", "Seething Hatred",
        "Touch of T`Vem", "Touch of Volatis", "Touch of the Warlord",
    },
    -- HP Buff
    HPBuff = {
        "Dire Shield", "Dark Shield", "Shadow Shield",
        "Unholy Guard", "Shroud of Pain",
    },
    -- Pet
    Pet = {
        "Servant of Darkness", "Minion of Darkness", "Child of Darkness",
        "Spawn of Darkness", "Specter of Darkness",
    },
    -- AA: Explosion of Hatred
    ExplosionOfHatredAA = { "Explosion of Hatred" },
    -- AA: Explosion of Spite
    ExplosionOfSpiteAA = { "Explosion of Spite" },
    -- AA: Leech Touch
    LeechAA = { "Leech Touch" },
    -- AA: Harm Touch
    HarmTouchAA = { "Harm Touch" },
    -- AA: Thought Leech
    ThoughtLeechAA = { "Thought Leech" },
    -- AA: Visage of Death
    VisageOfDeathAA = { "Visage of Death" },
    -- AA: Spire of the Reavers
    SpireOfShadowKnightAA = { "Spire of the Reavers" },
}

-- SpellLoadouts: Role-based gem assignments with extended schema
M.SpellLoadouts = {
    tank = {
        name = "Tank Focused",
        description = "Focus on aggro and tanking",
        gems = {
            [1] = "SpearNuke",
            [2] = "Terror",
            [3] = "Torrent",
            [4] = "LifeTap",
            [5] = "HateBuff",
            [6] = "LifetapProc",
            [7] = "HPBuff",
            [8] = "PoisonDoT",
        },
        defaults = {
            -- Tank
            DoTerror = true,
            DoTorrent = true,
            -- Combat
            DoLifeTaps = true,
            DoDoTs = false,
            DoSpearNuke = true,
            -- Buffs
            DoHateBuff = true,
            DoLifetapProc = true,
            DoHPBuff = true,
            -- Emergency
            UseLeech = true,
            UseVisageOfDeath = true,
            UseLeechcurse = true,
            UseDefenseDiscs = true,
            -- Burns
            UseHarmTouch = true,
            UseSpireOfShadowKnight = true,
        },
        layerAssignments = {
            -- Emergency
            UseLeech = "emergency",
            UseVisageOfDeath = "emergency",
            UseLeechcurse = "emergency",
            -- Defenses
            UseDefenseDiscs = "defenses",
            -- Combat (aggro)
            DoTerror = "combat",
            DoTorrent = "combat",
            DoLifeTaps = "combat",
            DoDoTs = "combat",
            DoSpearNuke = "combat",
            -- Burn
            UseHarmTouch = "burn",
            UseSpireOfShadowKnight = "burn",
            -- Buff
            DoHateBuff = "buff",
            DoLifetapProc = "buff",
            DoHPBuff = "buff",
        },
        layerOrder = {
            emergency = {"UseLeech", "UseVisageOfDeath", "UseLeechcurse"},
            defenses = {"UseDefenseDiscs"},
            combat = {"DoTerror", "DoTorrent", "DoLifeTaps", "DoSpearNuke", "DoDoTs"},
            burn = {"UseHarmTouch", "UseSpireOfShadowKnight"},
            buff = {"DoHateBuff", "DoLifetapProc", "DoHPBuff"},
        },
    },
    dps = {
        name = "DPS Focused",
        description = "Maximize damage with DoTs and nukes",
        gems = {
            [1] = "SpearNuke",
            [2] = "LifeTap",
            [3] = "PoisonDoT",
            [4] = "DiseaseDoT",
            [5] = "CorruptionDoT",
            [6] = "Terror",
            [7] = "LifetapProc",
            [8] = "HPBuff",
        },
        defaults = {
            -- Tank (minimal)
            DoTerror = true,
            DoTorrent = false,
            -- Combat (primary)
            DoLifeTaps = true,
            DoDoTs = true,
            DoSpearNuke = true,
            -- Buffs
            DoHateBuff = false,
            DoLifetapProc = true,
            DoHPBuff = true,
            -- Emergency
            UseLeech = true,
            UseVisageOfDeath = true,
            UseLeechcurse = true,
            UseDefenseDiscs = false,
            -- Burns
            UseHarmTouch = true,
            UseSpireOfShadowKnight = true,
        },
        layerAssignments = {
            UseLeech = "emergency",
            UseVisageOfDeath = "emergency",
            UseLeechcurse = "emergency",
            UseDefenseDiscs = "defenses",
            DoTerror = "combat",
            DoTorrent = "combat",
            DoLifeTaps = "combat",
            DoDoTs = "combat",
            DoSpearNuke = "combat",
            UseHarmTouch = "burn",
            UseSpireOfShadowKnight = "burn",
            DoHateBuff = "utility",
            DoLifetapProc = "utility",
            DoHPBuff = "utility",
        },
        layerOrder = {
            emergency = {"UseLeech", "UseVisageOfDeath", "UseLeechcurse"},
            defenses = {"UseDefenseDiscs"},
            combat = {"DoDoTs", "DoSpearNuke", "DoLifeTaps", "DoTerror", "DoTorrent"},
            burn = {"UseHarmTouch", "UseSpireOfShadowKnight"},
            buff = {"DoLifetapProc", "DoHPBuff", "DoHateBuff"},
        },
    },
    dot = {
        name = "DOT Heavy",
        description = "Focus on damage over time abilities",
        gems = {
            [1] = "PoisonDoT",
            [2] = "DiseaseDoT",
            [3] = "CorruptionDoT",
            [4] = "LifeTap",
            [5] = "SpearNuke",
            [6] = "Terror",
            [7] = "LifetapProc",
            [8] = "HPBuff",
        },
        defaults = {
            -- Tank (minimal)
            DoTerror = true,
            DoTorrent = false,
            -- Combat (primary)
            DoLifeTaps = true,
            DoDoTs = true,
            DoSpearNuke = true,
            -- Buffs
            DoHateBuff = false,
            DoLifetapProc = true,
            DoHPBuff = true,
            -- Emergency
            UseLeech = true,
            UseVisageOfDeath = true,
            UseLeechcurse = true,
            UseDefenseDiscs = false,
            -- Burns
            UseHarmTouch = true,
            UseSpireOfShadowKnight = true,
        },
        layerAssignments = {
            UseLeech = "emergency",
            UseVisageOfDeath = "emergency",
            UseLeechcurse = "emergency",
            UseDefenseDiscs = "defenses",
            DoTerror = "combat",
            DoTorrent = "combat",
            DoLifeTaps = "combat",
            DoDoTs = "combat",
            DoSpearNuke = "combat",
            UseHarmTouch = "burn",
            UseSpireOfShadowKnight = "burn",
            DoHateBuff = "utility",
            DoLifetapProc = "utility",
            DoHPBuff = "utility",
        },
        layerOrder = {
            emergency = {"UseLeech", "UseVisageOfDeath", "UseLeechcurse"},
            defenses = {"UseDefenseDiscs"},
            combat = {"DoDoTs", "DoLifeTaps", "DoSpearNuke", "DoTerror", "DoTorrent"},
            burn = {"UseHarmTouch", "UseSpireOfShadowKnight"},
            buff = {"DoLifetapProc", "DoHPBuff", "DoHateBuff"},
        },
    },
}

M.Settings = {
    DoLifeTaps = {
        Default = true,
        Category = "Combat",
        DisplayName = "Use Life Taps",
    },
    DoDoTs = {
        Default = true,
        Category = "Combat",
        DisplayName = "Use DoTs",
    },
    DoSpearNuke = {
        Default = true,
        Category = "Combat",
        DisplayName = "Spear Nuke",
    },
    DoTerror = {
        Default = true,
        Category = "Aggro",
        DisplayName = "Use Terror",
    },
    DoTorrent = {
        Default = true,
        Category = "Aggro",
        DisplayName = "AE Torrent",
    },
    DoHateBuff = {
        Default = true,
        Category = "Buff",
        DisplayName = "Hate Buff",
    },
    DoLifetapProc = {
        Default = true,
        Category = "Buff",
        DisplayName = "Lifetap Proc",
    },
    DoHPBuff = {
        Default = true,
        Category = "Buff",
        DisplayName = "HP Buff",
    },
    UseLeech = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Leech Touch",
    },
    UseVisageOfDeath = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Visage of Death",
    },
    UseLeechcurse = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Leechcurse",
    },
    UseDefenseDiscs = {
        Default = true,
        Category = "Defense",
        DisplayName = "Defense Discs",
    },
    UseHarmTouch = {
        Default = true,
        Category = "Burn",
        DisplayName = "Harm Touch",
    },
    UseSpireOfShadowKnight = {
        Default = true,
        Category = "Burn",
        DisplayName = "Spire of SK",
    },
}

return M
