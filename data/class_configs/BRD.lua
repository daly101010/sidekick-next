-- F:/lua/SideKick/data/class_configs/BRD.lua
-- Bard Class Configuration with condition-based rotations

local mq = require('mq')

local M = {}

-- Song Lines
M.spellLines = {
    -- War March (melee haste/damage)
    ['WarMarch'] = {
        "War March of Dekloaz", "War March of Radiwol", "War March of Jocelyn",
        "War March of Brekt", "War March of Illdaera", "War March of Dagda",
    },

    -- Fire Debuff (fire resist)
    ['FireDebuff'] = {
        "Aria of Pli Xin Liako", "Aria of Margidor", "Aria of Begalru",
        "Aria of Maetanrus", "Aria of the Orator", "Aria of the Composer",
    },

    -- Overhaste Song
    ['OverhasteSong'] = {
        "Fierce Eye", "Thousand Blades", "Bladed Song",
        "Veshma's Keen Eye", "Selo's Acceleration",
    },

    -- Slow Song
    ['SlowSong'] = {
        "Requiem of Time", "Angstlich's Echo of Terror", "Largo's Assonant Binding",
        "Selo's Chords of Cessation", "Denon's Desperate Dirge",
    },

    -- Mez Song
    ['MezSong'] = {
        "Slumber of the Diabo", "Slumber of Jembel", "Slumber of Silisia",
        "Slumber of Sionachie", "Lullaby of Morell", "Kelin's Lucid Lullaby",
    },

    -- AE Mez Song
    ['AEMezSong'] = {
        "Wave of Stupor", "Wave of Somnolence", "Wave of Sleep",
        "Wave of Dreams", "Veil of Discord", "Song of Twilight",
    },

    -- Regen Song
    ['RegenSong'] = {
        "Chorus of Rejuvenation", "Chorus of Replenishment", "Chorus of Restoration",
        "Chorus of Vitality", "Cantata of Soothing", "Hymn of Restoration",
    },

    -- Mana Song
    ['ManaSong'] = {
        "Chorus of Marr", "Cantata of Rodcet", "Cassindra's Chorus",
        "Cassindra's Chant", "Selo's Chant of Battle",
    },

    -- Resist Song
    ['ResistSong'] = {
        "Psalm of the Nomad", "Psalm of Survival", "Psalm of Cooling",
        "Psalm of Warmth", "Psalm of Veeshan", "Psalm of Purity",
    },

    -- Attack Song
    ['AttackSong'] = {
        "Insult of Djenrru", "Insult of Dsjr", "Insult of Szarol",
        "Insult of Yelinak", "Insult of Erradien", "Brusco's Boastful Bellow",
    },

    -- DoT Song
    ['DoTSong'] = {
        "Shojrn's Chant of Disease", "Chant of Kromtus", "Chant of Fury",
        "Chant of Disease", "Chant of Flame", "Chant of Frost",
    },
}

-- AA Lines
M.aaLines = {
    ['FuryOfTheAges'] = { "Funeral Dirge" },
    ['QuickTime'] = { "Quick Time" },
    ['BladedSong'] = { "Fierce Eye" },
    ['SpireOfBard'] = { "Spire of the Minstrels" },
    ['Fade'] = { "Fading Memories" },
    ['Epic'] = { "Spirit of Vesagran", "Blade of Vesagran" },
}

-- Default conditions
M.defaultConditions = {
    ['doFade'] = function(ctx)
        return ctx.me.pctHPs < 25 or ctx.me.pctAggro > 95
    end,

    ['doMezSong'] = function(ctx)
        return ctx.me.xTargetCount >= 2
    end,
    ['doAEMezSong'] = function(ctx)
        return ctx.me.xTargetCount >= 4
    end,
    ['doSlowSong'] = function(ctx)
        return ctx.combat and not ctx.target.myBuff('Requiem') and not ctx.target.myBuff('Lullaby')
    end,

    ['doWarMarch'] = function(ctx)
        return not ctx.me.song('War March')
    end,
    ['doFireDebuff'] = function(ctx)
        return ctx.combat and not ctx.me.song('Aria')
    end,
    ['doOverhasteSong'] = function(ctx)
        return ctx.combat and ctx.mode ~= 'Healer'
    end,
    ['doRegenSong'] = function(ctx)
        return ctx.mode == 'Healer' or not ctx.combat
    end,
    ['doManaSong'] = function(ctx)
        return true  -- Usually twist this
    end,
    ['doResistSong'] = function(ctx)
        return ctx.target.named
    end,
    ['doAttackSong'] = function(ctx)
        return ctx.combat
    end,
    ['doDoTSong'] = function(ctx)
        return ctx.combat and ctx.target.named
    end,

    ['doFuryOfTheAges'] = function(ctx)
        return ctx.burn
    end,
    ['doQuickTime'] = function(ctx)
        return ctx.burn
    end,
    ['doBladedSong'] = function(ctx)
        return ctx.burn and ctx.combat
    end,
    ['doSpireOfBard'] = function(ctx)
        return ctx.burn
    end,
    ['doEpic'] = function(ctx)
        return ctx.burn and ctx.combat
    end,
}

-- Category overrides
M.categoryOverrides = {
    ['doFade'] = 'emergency',
    ['doMezSong'] = 'support',
    ['doAEMezSong'] = 'support',
    ['doSlowSong'] = 'support',
    ['doWarMarch'] = 'combat',
    ['doFireDebuff'] = 'combat',
    ['doOverhasteSong'] = 'combat',
    ['doRegenSong'] = 'buff',
    ['doManaSong'] = 'buff',
    ['doResistSong'] = 'buff',
    ['doAttackSong'] = 'combat',
    ['doDoTSong'] = 'combat',
    ['doFuryOfTheAges'] = 'burn',
    ['doQuickTime'] = 'burn',
    ['doBladedSong'] = 'burn',
    ['doSpireOfBard'] = 'burn',
    ['doEpic'] = 'burn',
}

-- AbilitySets: Song/AA progressions (highest to lowest rank)
M.AbilitySets = {
    -- War March (melee haste/damage)
    WarMarch = {
        "War March of Dekloaz", "War March of Radiwol", "War March of Jocelyn",
        "War March of Brekt", "War March of Illdaera", "War March of Dagda",
    },
    -- Fire Debuff
    FireDebuff = {
        "Aria of Pli Xin Liako", "Aria of Margidor", "Aria of Begalru",
        "Aria of Maetanrus", "Aria of the Orator", "Aria of the Composer",
    },
    -- Overhaste Song
    OverhasteSong = {
        "Fierce Eye", "Thousand Blades", "Bladed Song",
        "Veshma's Keen Eye", "Selo's Acceleration",
    },
    -- Slow Song
    SlowSong = {
        "Requiem of Time", "Angstlich's Echo of Terror", "Largo's Assonant Binding",
        "Selo's Chords of Cessation", "Denon's Desperate Dirge",
    },
    -- Mez Song
    MezSong = {
        "Slumber of the Diabo", "Slumber of Jembel", "Slumber of Silisia",
        "Slumber of Sionachie", "Lullaby of Morell", "Kelin's Lucid Lullaby",
    },
    -- AE Mez Song
    AEMezSong = {
        "Wave of Stupor", "Wave of Somnolence", "Wave of Sleep",
        "Wave of Dreams", "Veil of Discord", "Song of Twilight",
    },
    -- Regen Song
    RegenSong = {
        "Chorus of Rejuvenation", "Chorus of Replenishment", "Chorus of Restoration",
        "Chorus of Vitality", "Cantata of Soothing", "Hymn of Restoration",
    },
    -- Mana Song
    ManaSong = {
        "Chorus of Marr", "Cantata of Rodcet", "Cassindra's Chorus",
        "Cassindra's Chant", "Selo's Chant of Battle",
    },
    -- Resist Song
    ResistSong = {
        "Psalm of the Nomad", "Psalm of Survival", "Psalm of Cooling",
        "Psalm of Warmth", "Psalm of Veeshan", "Psalm of Purity",
    },
    -- Attack Song (Insults)
    AttackSong = {
        "Insult of Djenrru", "Insult of Dsjr", "Insult of Szarol",
        "Insult of Yelinak", "Insult of Erradien", "Brusco's Boastful Bellow",
    },
    -- DoT Song
    DoTSong = {
        "Shojrn's Chant of Disease", "Chant of Kromtus", "Chant of Fury",
        "Chant of Disease", "Chant of Flame", "Chant of Frost",
    },
    -- AA: Funeral Dirge
    FuryOfTheAgesAA = { "Funeral Dirge" },
    -- AA: Quick Time
    QuickTimeAA = { "Quick Time" },
    -- AA: Fierce Eye
    BladedSongAA = { "Fierce Eye" },
    -- AA: Spire of the Minstrels
    SpireOfBardAA = { "Spire of the Minstrels" },
    -- AA: Fading Memories
    FadeAA = { "Fading Memories" },
    -- AA: Epic
    EpicAA = { "Spirit of Vesagran", "Blade of Vesagran" },
}

-- SpellLoadouts: Role-based song twists with extended schema
M.SpellLoadouts = {
    melee = {
        name = "Melee Support",
        description = "Focus on melee ADPS songs",
        gems = {
            [1] = "WarMarch",
            [2] = "OverhasteSong",
            [3] = "FireDebuff",
            [4] = "AttackSong",
            [5] = "DoTSong",
            [6] = "MezSong",
        },
        defaults = {
            -- Melee Songs
            DoWarMarch = true,
            DoOverhaste = true,
            DoFireDebuff = true,
            DoAttackSong = true,
            DoDoTSong = true,
            -- CC
            DoMez = true,
            DoAEMez = false,
            DoSlow = true,
            -- Support
            DoRegenSong = false,
            DoManaSong = false,
            DoResistSong = false,
            -- Emergency
            UseFade = true,
            -- Burns
            UseFuryOfTheAges = true,
            UseQuickTime = true,
            UseBladedSong = true,
            UseSpireOfBard = true,
            UseEpic = true,
            -- Mode
            DoMeleeMode = true,
        },
        layerAssignments = {
            -- Emergency
            UseFade = "emergency",
            -- Support (CC)
            DoMez = "support",
            DoAEMez = "support",
            DoSlow = "support",
            -- Combat (melee songs)
            DoWarMarch = "combat",
            DoOverhaste = "combat",
            DoFireDebuff = "combat",
            DoAttackSong = "combat",
            DoDoTSong = "combat",
            DoMeleeMode = "combat",
            -- Burn
            UseFuryOfTheAges = "burn",
            UseQuickTime = "burn",
            UseBladedSong = "burn",
            UseSpireOfBard = "burn",
            UseEpic = "burn",
            -- Buff
            DoRegenSong = "buff",
            DoManaSong = "buff",
            DoResistSong = "buff",
        },
        layerOrder = {
            emergency = {"UseFade"},
            support = {"DoMez", "DoAEMez", "DoSlow"},
            combat = {"DoWarMarch", "DoOverhaste", "DoFireDebuff", "DoAttackSong", "DoDoTSong", "DoMeleeMode"},
            burn = {"UseFuryOfTheAges", "UseQuickTime", "UseBladedSong", "UseSpireOfBard", "UseEpic"},
            buff = {"DoRegenSong", "DoManaSong", "DoResistSong"},
        },
    },
    caster = {
        name = "Caster Support",
        description = "Focus on caster ADPS songs",
        gems = {
            [1] = "FireDebuff",
            [2] = "ManaSong",
            [3] = "RegenSong",
            [4] = "ResistSong",
            [5] = "MezSong",
            [6] = "SlowSong",
        },
        defaults = {
            -- Melee Songs (minimal)
            DoWarMarch = false,
            DoOverhaste = false,
            DoFireDebuff = true,
            DoAttackSong = false,
            DoDoTSong = false,
            -- CC
            DoMez = true,
            DoAEMez = true,
            DoSlow = true,
            -- Support (primary)
            DoRegenSong = true,
            DoManaSong = true,
            DoResistSong = true,
            -- Emergency
            UseFade = true,
            -- Burns
            UseFuryOfTheAges = true,
            UseQuickTime = false,
            UseBladedSong = false,
            UseSpireOfBard = true,
            UseEpic = true,
            -- Mode
            DoMeleeMode = false,
        },
        layerAssignments = {
            UseFade = "emergency",
            DoMez = "support",
            DoAEMez = "support",
            DoSlow = "support",
            DoWarMarch = "combat",
            DoOverhaste = "combat",
            DoFireDebuff = "combat",
            DoAttackSong = "combat",
            DoDoTSong = "combat",
            DoMeleeMode = "combat",
            UseFuryOfTheAges = "burn",
            UseQuickTime = "burn",
            UseBladedSong = "burn",
            UseSpireOfBard = "burn",
            UseEpic = "burn",
            DoRegenSong = "buff",
            DoManaSong = "buff",
            DoResistSong = "buff",
        },
        layerOrder = {
            emergency = {"UseFade"},
            support = {"DoMez", "DoAEMez", "DoSlow"},
            combat = {"DoFireDebuff", "DoWarMarch", "DoOverhaste", "DoAttackSong", "DoDoTSong", "DoMeleeMode"},
            burn = {"UseFuryOfTheAges", "UseSpireOfBard", "UseEpic", "UseQuickTime", "UseBladedSong"},
            buff = {"DoManaSong", "DoRegenSong", "DoResistSong"},
        },
    },
    cc = {
        name = "Crowd Control",
        description = "Focus on mezzing and slowing",
        gems = {
            [1] = "MezSong",
            [2] = "AEMezSong",
            [3] = "SlowSong",
            [4] = "WarMarch",
            [5] = "ManaSong",
            [6] = "RegenSong",
        },
        defaults = {
            -- Melee Songs (minimal)
            DoWarMarch = true,
            DoOverhaste = false,
            DoFireDebuff = false,
            DoAttackSong = false,
            DoDoTSong = false,
            -- CC (primary)
            DoMez = true,
            DoAEMez = true,
            DoSlow = true,
            -- Support
            DoRegenSong = true,
            DoManaSong = true,
            DoResistSong = false,
            -- Emergency
            UseFade = true,
            -- Burns
            UseFuryOfTheAges = true,
            UseQuickTime = false,
            UseBladedSong = false,
            UseSpireOfBard = true,
            UseEpic = true,
            -- Mode
            DoMeleeMode = false,
        },
        layerAssignments = {
            UseFade = "emergency",
            DoMez = "support",
            DoAEMez = "support",
            DoSlow = "support",
            DoWarMarch = "combat",
            DoOverhaste = "combat",
            DoFireDebuff = "combat",
            DoAttackSong = "combat",
            DoDoTSong = "combat",
            DoMeleeMode = "combat",
            UseFuryOfTheAges = "burn",
            UseQuickTime = "burn",
            UseBladedSong = "burn",
            UseSpireOfBard = "burn",
            UseEpic = "burn",
            DoRegenSong = "buff",
            DoManaSong = "buff",
            DoResistSong = "buff",
        },
        layerOrder = {
            emergency = {"UseFade"},
            support = {"DoMez", "DoAEMez", "DoSlow"},
            combat = {"DoWarMarch", "DoFireDebuff", "DoOverhaste", "DoAttackSong", "DoDoTSong", "DoMeleeMode"},
            burn = {"UseFuryOfTheAges", "UseSpireOfBard", "UseEpic", "UseQuickTime", "UseBladedSong"},
            buff = {"DoManaSong", "DoRegenSong", "DoResistSong"},
        },
    },
}

M.Settings = {
    DoWarMarch = {
        Default = true,
        Category = "Combat",
        DisplayName = "War March",
    },
    DoOverhaste = {
        Default = true,
        Category = "Combat",
        DisplayName = "Overhaste",
    },
    DoFireDebuff = {
        Default = true,
        Category = "Combat",
        DisplayName = "Fire Debuff",
    },
    DoAttackSong = {
        Default = true,
        Category = "Combat",
        DisplayName = "Attack Song",
    },
    DoDoTSong = {
        Default = true,
        Category = "Combat",
        DisplayName = "DoT Song",
    },
    DoMez = {
        Default = true,
        Category = "CC",
        DisplayName = "Use Mez",
    },
    DoAEMez = {
        Default = false,
        Category = "CC",
        DisplayName = "AE Mez",
    },
    DoSlow = {
        Default = true,
        Category = "Debuff",
        DisplayName = "Use Slow",
    },
    DoRegenSong = {
        Default = false,
        Category = "Utility",
        DisplayName = "Regen Song",
    },
    DoManaSong = {
        Default = false,
        Category = "Utility",
        DisplayName = "Mana Song",
    },
    DoResistSong = {
        Default = false,
        Category = "Utility",
        DisplayName = "Resist Song",
    },
    UseFade = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Fading Memories",
    },
    UseFuryOfTheAges = {
        Default = true,
        Category = "Burn",
        DisplayName = "Fury of Ages",
    },
    UseQuickTime = {
        Default = true,
        Category = "Burn",
        DisplayName = "Quick Time",
    },
    UseBladedSong = {
        Default = true,
        Category = "Burn",
        DisplayName = "Bladed Song",
    },
    UseSpireOfBard = {
        Default = true,
        Category = "Burn",
        DisplayName = "Spire of Bard",
    },
    UseEpic = {
        Default = true,
        Category = "Burn",
        DisplayName = "Epic",
    },
    DoMeleeMode = {
        Default = true,
        Category = "Combat",
        DisplayName = "Melee Mode",
    },
}

return M
