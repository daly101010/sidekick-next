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
    ['doRegenSong'] = 'utility',
    ['doManaSong'] = 'utility',
    ['doResistSong'] = 'utility',
    ['doAttackSong'] = 'combat',
    ['doDoTSong'] = 'combat',
    ['doFuryOfTheAges'] = 'burn',
    ['doQuickTime'] = 'burn',
    ['doBladedSong'] = 'burn',
    ['doSpireOfBard'] = 'burn',
    ['doEpic'] = 'burn',
}

M.Settings = {
    DoMez = {
        Default = true,
        Category = "CC",
        DisplayName = "Use Mez",
    },
    DoSlow = {
        Default = true,
        Category = "Debuff",
        DisplayName = "Use Slow",
    },
    DoMeleeMode = {
        Default = true,
        Category = "Combat",
        DisplayName = "Melee Mode",
    },
}

return M
