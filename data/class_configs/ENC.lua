-- F:/lua/SideKick/data/class_configs/ENC.lua
-- Enchanter Class Configuration with condition-based rotations

local mq = require('mq')

local M = {}

-- Spell Lines (for condition system)
M.spellLines = {
    -- Single Target Mez
    ['SingleMez'] = {
        "Flummox", "Addle", "Deceive", "Delude", "Bewilder", "Confound",
        "Mislead", "Baffle", "Befuddle", "Mystify", "Bewilderment",
    },

    -- Fast Mez
    ['FastMez'] = {
        "Deceiving Flash", "Deluding Flash", "Bewildering Flash",
        "Confounding Flash", "Misleading Flash", "Baffling Flash",
    },

    -- AE Mez
    ['AEMez'] = {
        "Neutralizing Wave", "Perplexing Wave", "Deadening Wave",
        "Slackening Wave", "Peaceful Wave", "Serene Wave",
    },

    -- PBAE Mez
    ['PBAEMez'] = {
        "Neutralize", "Perplex", "Bafflement", "Disorientation",
        "Confusion", "Serenity", "Docility",
    },

    -- Slow
    ['Slow'] = {
        "Desolate Deeds", "Dreary Deeds", "Forlorn Deeds",
        "Shiftless Deeds", "Tepid Deeds", "Languid Pace",
    },

    -- Tash (Magic Resist Debuff)
    ['Tash'] = {
        "Roar of Tashan", "Edict of Tashan", "Proclamation of Tashan",
        "Order of Tashan", "Decree of Tashan", "Enunciation of Tashan",
    },

    -- Cripple
    ['Cripple'] = {
        "Crippling Snare", "Incapacitate", "Cripple",
    },

    -- Self Rune 1
    ['SelfRune'] = {
        "Esoteric Rune", "Marvel's Rune", "Deviser's Rune",
        "Transfixer's Rune", "Enticer's Rune", "Mastermind's Rune",
    },

    -- Self Rune 2 (Poly)
    ['PolyRune'] = {
        "Polyradiant Rune", "Polyluminous Rune", "Polycascading Rune",
        "Polyfluorescent Rune", "Polyrefractive Rune", "Polyiridescent Rune",
    },

    -- Group Rune
    ['GroupRune'] = {
        "Gloaming Rune", "Eclipsed Rune", "Crepuscular Rune",
        "Tenebrous Rune", "Darkened Rune", "Umbral Rune",
    },

    -- Haste
    ['Haste'] = {
        "Hastening of Jharin", "Hastening of Salik", "Hastening of Ellowind",
        "Hastening of Erradien", "Speed of Salik", "Speed of Ellowind",
    },

    -- Mana Regen
    ['ManaRegen'] = {
        "Voice of Preordination", "Voice of Perception", "Voice of Sagacity",
        "Voice of Perspicacity", "Voice of Precognition", "Voice of Foresight",
    },

    -- Magic Nuke
    ['MindNuke'] = {
        "Mindrend", "Mindreap", "Mindrift", "Mindslash", "Mindsunder",
        "Mindcleave", "Mindscythe", "Mindblade",
    },

    -- Chromatic Nuke (Fast)
    ['ChromaticNuke'] = {
        "Chromatic Spike", "Chromatic Flare", "Chromatic Stab",
        "Chromatic Flicker", "Chromatic Blink", "Chromatic Percussion",
    },

    -- Mana Tap Nuke
    ['ManaTap'] = {
        "Psychological Appropriation", "Ideological Appropriation",
        "Psychic Appropriation", "Intellectual Appropriation",
    },

    -- Color Stun (PBAE)
    ['ColorStun'] = {
        "Color Calibration", "Color Conflagration", "Color Cascade",
        "Color Congruence", "Color Concourse", "Color Conflux",
    },

    -- Charm
    ['Charm'] = {
        "Clamoring Command", "Grating Command", "Imposing Command",
        "Compelling Command", "Crushing Command", "Chaotic Command",
    },

    -- DoT
    ['DoT'] = {
        "Mind Whirl", "Mind Twist", "Mind Storm",
    },
}

-- AA Lines
M.aaLines = {
    ['ChromaticHaze'] = { "Chromatic Haze" },
    ['IllusionsOfGrandeur'] = { "Illusions of Grandeur" },
    ['SpireOfEnchanter'] = { "Spire of Enchantment" },
    ['SilentCasting'] = { "Silent Casting" },
    ['EldritchRune'] = { "Eldritch Rune" },
    ['DimensionalShield'] = { "Dimensional Shield" },
    ['MindStorm'] = { "Mind Storm" },
    ['BeguilersSynergy'] = { "Beguiler's Synergy" },
    ['ReactiveRune'] = { "Reactive Rune" },
    ['VeilOfMindshadow'] = { "Veil of Mindshadow" },
    ['AzureMindCrystal'] = { "Azure Mind Crystal" },
    ['GatherMana'] = { "Gather Mana" },
    ['SelfStasis'] = { "Self Stasis" },
    ['FocusedMezAA'] = { "Beguiler's Banishment" },
}

-- Disc Lines (Enchanters have very few)
M.discLines = {}

-- Opt ENC into the discipline engine. Without this, sk_disciplines
-- skips ENC by default (caster classes are off by default).
M.useDisciplineEngine = true

-- Allow spell-kind picks for ENC. Default is {aa, disc} only — but
-- ENC's combat rotation is almost entirely spells (mez, tash, slow,
-- nukes, mana-taps), so we widen the filter for this class.
M.allowKindsInRotation = { 'aa', 'disc', 'spell' }

-- Per-condition target selector. The default selector ('current_target')
-- casts on the active EQ target. ENC's mez line predicates fire when
-- there are 2+ haters but should target the next un-mezzed hater (NOT
-- the main assist's tank target). Route them through automation/cc.lua's
-- claim system so two ENC boxes don't double-mez the same mob.
M.targetSelector = {
    doSingleMez = 'mez_target',
    doFastMez   = 'mez_target',
    doAEMez     = 'mez_target',
    doPBAEMez   = 'mez_target',
    doColorStun = 'mez_target',
}

-- Firing precedence for the engine: emergency runes first, then CC
-- (mez/stun before debuffs so adds get locked down before we tash/slow
-- the focus mob), then debuffs, nukes, mana-tap (for mana sustain),
-- and finally burn AAs which only fire when /sk_burn is on.
M.conditionOrder = {
    -- Emergency self-defense
    'doSelfStasis', 'doDimensionalShield', 'doEldritchRune', 'doReactiveRune',
    -- Mana sustain (stays high so we can keep casting)
    'doGatherMana', 'doAzureMindCrystal', 'doManaTap',
    -- CC: lock down adds first
    'doColorStun', 'doPBAEMez', 'doAEMez', 'doFastMez', 'doSingleMez',
    -- Debuffs on focus target
    'doTash', 'doSlow', 'doCripple',
    -- DPS
    'doMindStorm', 'doDoT', 'doMindNuke', 'doChromaticNuke',
    -- Burn (only fires when ctx.burn is true)
    'doSilentCasting', 'doIllusionsOfGrandeur', 'doChromaticHaze',
    'doSpireOfEnchanter', 'doBeguilersSynergy',
}

-- Default Conditions
M.defaultConditions = {
    -- Emergency
    ['doEldritchRune'] = function(ctx)
        return ctx.me.pctHPs < 40 and not ctx.me.buff('Rune')
    end,
    ['doDimensionalShield'] = function(ctx)
        return ctx.me.pctHPs < 30
    end,
    ['doReactiveRune'] = function(ctx)
        return ctx.me.pctHPs < 50 and not ctx.me.buff('Reactive')
    end,
    ['doSelfStasis'] = function(ctx)
        return ctx.me.pctHPs < 20
    end,

    -- CC
    ['doSingleMez'] = function(ctx)
        return ctx.me.xTargetCount >= 2
    end,
    ['doFastMez'] = function(ctx)
        return ctx.me.xTargetCount >= 2
    end,
    ['doAEMez'] = function(ctx)
        return ctx.me.xTargetCount >= 4
    end,
    ['doPBAEMez'] = function(ctx)
        return ctx.me.xTargetCount >= 3 and ctx.spawn.count('npc radius 30') >= 3
    end,
    ['doColorStun'] = function(ctx)
        return ctx.combat and ctx.me.xTargetCount >= 2 and ctx.me.pctHPs < 60
    end,

    -- Debuffs
    ['doTash'] = function(ctx)
        return ctx.combat and not ctx.target.myBuff('Tashan')
    end,
    ['doSlow'] = function(ctx)
        return ctx.combat and not ctx.target.myBuff('Deeds') and ctx.target.pctHPs > 50
    end,
    ['doCripple'] = function(ctx)
        return ctx.combat and ctx.target.named and not ctx.target.myBuff('Cripple')
    end,

    -- Combat
    ['doMindNuke'] = function(ctx)
        return ctx.combat and ctx.me.pctMana > 40
    end,
    ['doChromaticNuke'] = function(ctx)
        return ctx.combat and ctx.me.pctMana > 30
    end,
    ['doManaTap'] = function(ctx)
        return ctx.combat and ctx.me.pctMana < 70
    end,
    ['doDoT'] = function(ctx)
        return ctx.combat and ctx.target.named and not ctx.target.myBuff('Mind') and ctx.target.pctHPs > 30
    end,
    ['doMindStorm'] = function(ctx)
        return ctx.combat and ctx.target.named
    end,

    -- Buffs (OOC)
    ['doSelfRune'] = function(ctx)
        return not ctx.me.buff('Rune') and not ctx.combat
    end,
    ['doPolyRune'] = function(ctx)
        return not ctx.me.buff('Poly') and not ctx.combat
    end,
    ['doGroupRune'] = function(ctx)
        return not ctx.combat
    end,
    ['doHaste'] = function(ctx)
        return not ctx.combat
    end,
    ['doManaRegen'] = function(ctx)
        return not ctx.combat
    end,

    -- Burn
    ['doChromaticHaze'] = function(ctx)
        return ctx.burn and not ctx.me.buff('Chromatic Haze')
    end,
    ['doIllusionsOfGrandeur'] = function(ctx)
        return ctx.burn and not ctx.me.buff('Illusions of Grandeur')
    end,
    ['doSpireOfEnchanter'] = function(ctx)
        return ctx.burn
    end,
    ['doBeguilersSynergy'] = function(ctx)
        return ctx.burn and ctx.combat
    end,
    ['doSilentCasting'] = function(ctx)
        return ctx.burn and not ctx.me.buff('Silent Casting')
    end,
    ['doGatherMana'] = function(ctx)
        return ctx.me.pctMana < 50
    end,
    ['doAzureMindCrystal'] = function(ctx)
        return ctx.me.pctMana < 40
    end,
}

-- Category Overrides
M.categoryOverrides = {
    ['doEldritchRune'] = 'emergency',
    ['doDimensionalShield'] = 'emergency',
    ['doReactiveRune'] = 'emergency',
    ['doSelfStasis'] = 'emergency',
    ['doSingleMez'] = 'support',
    ['doFastMez'] = 'support',
    ['doAEMez'] = 'support',
    ['doPBAEMez'] = 'support',
    ['doColorStun'] = 'support',
    ['doTash'] = 'support',
    ['doSlow'] = 'support',
    ['doCripple'] = 'support',
    ['doMindNuke'] = 'combat',
    ['doChromaticNuke'] = 'combat',
    ['doManaTap'] = 'combat',
    ['doDoT'] = 'combat',
    ['doMindStorm'] = 'combat',
    ['doSelfRune'] = 'utility',
    ['doPolyRune'] = 'utility',
    ['doGroupRune'] = 'utility',
    ['doHaste'] = 'buff',
    ['doManaRegen'] = 'utility',
    ['doChromaticHaze'] = 'burn',
    ['doIllusionsOfGrandeur'] = 'burn',
    ['doSpireOfEnchanter'] = 'burn',
    ['doBeguilersSynergy'] = 'burn',
    ['doSilentCasting'] = 'burn',
    ['doGatherMana'] = 'burn',
    ['doAzureMindCrystal'] = 'burn',
}

-- AbilitySets: Spell/AA progressions (highest to lowest rank)
M.AbilitySets = {
    -- Single Target Mez
    MezSpell = {
        "Flummox", "Addle", "Deceive", "Delude", "Bewilder", "Confound",
        "Mislead", "Baffle", "Befuddle", "Mystify", "Bewilderment",
        "Euphoria", "Felicity", "Bliss", "Sleep",
    },

    -- Fast Mez
    MezSpellFast = {
        "Flummoxing Flash", "Addling Flash", "Deceiving Flash", "Deluding Flash",
        "Bewildering Flash", "Confounding Flash", "Misleading Flash", "Baffling Flash",
        "Befuddling Flash", "Mystifying Flash", "Perplexing Flash",
    },

    -- Fast AE Mez (Glance line)
    MezAESpellFast = {
        "Vexing Glance", "Confounding Glance", "Neutralizing Glance",
        "Perplexing Glance", "Slackening Glance",
    },

    -- AE Mez
    MezAESpell = {
        "Neutralizing Wave", "Perplexing Wave", "Deadening Wave",
        "Slackening Wave", "Peaceful Wave", "Serene Wave",
        "Ensorcelling Wave", "Quelling Wave", "Wake of Subdual",
        "Wake of Felicity", "Bliss of the Nihil", "Fascination",
        "Mesmerization", "Bewildering Wave",
    },

    -- PBAE Mez
    MezPBAESpell = {
        "Neutralize", "Perplex", "Bafflement", "Disorientation",
        "Confusion", "Serenity", "Docility", "Visions of Kirathas",
        "Dreams of Veldyn", "Circle of Dreams", "Word of Morell",
    },

    -- Slow
    SlowSpell = {
        "Desolate Deeds", "Dreary Deeds", "Forlorn Deeds",
        "Shiftless Deeds", "Tepid Deeds", "Languid Pace",
    },

    -- Tash (Magic Resist Debuff)
    TashSpell = {
        "Roar of Tashan", "Edict of Tashan", "Proclamation of Tashan",
        "Order of Tashan", "Decree of Tashan", "Enunciation of Tashan",
        "Declaration of Tashan", "Clamor of Tashan", "Bark of Tashan",
        "Din of Tashan", "Echo of Tashan", "Howl of Tashan",
        "Tashanian", "Tashania", "Tashani", "Tashina",
    },

    -- Cripple
    CrippleSpell = {
        "Crippling Snare", "Incapacitate", "Cripple",
    },

    -- Self Rune 1
    SelfRune1 = {
        "Esoteric Rune", "Marvel's Rune", "Deviser's Rune",
        "Transfixer's Rune", "Enticer's Rune", "Mastermind's Rune",
        "Arcanaward's Rune", "Spectral Rune", "Pearlescent Rune",
        "Opalescent Rune", "Draconic Rune", "Ethereal Rune", "Arcane Rune",
    },

    -- Self Rune 2
    SelfRune2 = {
        "Polyradiant Rune", "Polyluminous Rune", "Polycascading Rune",
        "Polyfluorescent Rune", "Polyrefractive Rune", "Polyiridescent Rune",
        "Polyarcanic Rune", "Polyspectral Rune", "Polychaotic Rune",
        "Multichromatic Rune", "Polychromatic Rune",
    },

    -- Group Rune
    GroupRune = {
        "Gloaming Rune", "Eclipsed Rune", "Crepuscular Rune",
        "Tenebrous Rune", "Darkened Rune", "Umbral Rune",
        "Shadowed Rune", "Twilight Rune", "Rune of the Void",
    },

    -- Haste
    HasteSpell = {
        "Hastening of Jharin", "Hastening of Salik", "Hastening of Ellowind",
        "Hastening of Erradien", "Speed of Salik", "Speed of Ellowind",
        "Speed of Erradien", "Speed of Novak", "Speed of Aransir",
        "Speed of Sviir", "Vallon's Quickening", "Visions of Grandeur",
        "Wondrous Rapidity", "Aanya's Quickening", "Swift Like the Wind",
        "Celerity", "Augmentation", "Alacrity", "Quickness",
    },

    -- Mana Regen
    ManaRegenSpell = {
        "Voice of Preordination", "Voice of Perception", "Voice of Sagacity",
        "Voice of Perspicacity", "Voice of Precognition", "Voice of Foresight",
        "Voice of Premeditation", "Voice of Forethought", "Voice of Prescience",
        "Voice of Cognizance", "Voice of Intuition", "Voice of Clairvoyance",
        "Voice of Quellious", "Tranquility", "Koadic's Endless Intellect",
        "Clarity II", "Clarity", "Breeze",
    },

    -- Magic Nuke
    MagicNuke = {
        "Mindrend", "Mindreap", "Mindrift", "Mindslash", "Mindsunder",
        "Mindcleave", "Mindscythe", "Mindblade", "Spectral Assault",
        "Polychaotic Assault", "Multichromatic Assault",
    },

    -- Chromatic Nuke (Fast)
    RuneNuke = {
        "Chromatic Spike", "Chromatic Flare", "Chromatic Stab",
        "Chromatic Flicker", "Chromatic Blink", "Chromatic Percussion",
        "Chromatic Flash", "Chromatic Jab",
    },

    -- Mana Tap Nuke
    ManaTapNuke = {
        "Psychological Appropriation", "Ideological Appropriation",
        "Psychic Appropriation", "Intellectual Appropriation",
        "Mental Appropriation", "Cognitive Appropriation",
    },

    -- Color Stun (PBAE)
    ColorStun = {
        "Color Calibration", "Color Conflagration", "Color Cascade",
        "Color Congruence", "Color Concourse", "Color Conflux",
        "Color Collapse", "Color Cataclysm", "Color Shift", "Color Skew",
    },

    -- Charm
    CharmSpell = {
        "Clamoring Command", "Grating Command", "Imposing Command",
        "Compelling Command", "Crushing Command", "Chaotic Command",
        "Astonishing Command", "Beguiling Command", "Captivating Command",
    },

    -- DoT
    DotSpell = {
        "Mind Whirl", "Mind Twist", "Mind Storm",
    },

    -- Twin Cast Mez (for DPS)
    TwinCastMez = {
        "Chaotic Deception", "Chaotic Delusion", "Chaotic Bewildering",
        "Chaotic Confounding", "Chaotic Confusion", "Chaotic Baffling",
        "Chaotic Befuddling", "Chaotic Puzzlement", "Chaotic Conundrum",
    },

    -- AA: Chromatic Haze
    ChromaticHazeAA = { "Chromatic Haze" },

    -- AA: Illusions of Grandeur
    IllusionsOfGrandeurAA = { "Illusions of Grandeur" },

    -- AA: Spire of Enchantment
    SpireOfEnchantmentAA = { "Spire of Enchantment" },

    -- AA: Silent Casting
    SilentCastingAA = { "Silent Casting" },

    -- AA: Eldritch Rune
    EldritchRuneAA = { "Eldritch Rune" },

    -- AA: Dimensional Shield
    DimensionalShieldAA = { "Dimensional Shield" },

    -- AA: Mind Storm
    MindStormAA = { "Mind Storm" },

    -- AA: Beguiler's Synergy
    BeguilersSynergyAA = { "Beguiler's Synergy" },

    -- AA: Reactive Rune
    ReactiveRuneAA = { "Reactive Rune" },

    -- AA: Veil of Mindshadow
    VeilOfMindshadowAA = { "Veil of Mindshadow" },

    -- AA: Azure Mind Crystal
    AzureMindCrystalAA = { "Azure Mind Crystal" },

    -- AA: Gather Mana
    GatherManaAA = { "Gather Mana" },

    -- AA: Self Stasis
    SelfStasisAA = { "Self Stasis" },
}

-- SpellLoadouts: Role-based gem assignments with extended schema
M.SpellLoadouts = {
    cc = {
        name = "Crowd Control",
        description = "Focus on mezzing and debuffing",
        gems = {
            [1] = "MezSpell",
            [2] = "MezAESpell",
            [3] = "MezSpellFast",
            [4] = "SlowSpell",
            [5] = "TashSpell",
            [6] = "HasteSpell",
            [7] = "ManaRegenSpell",
            [8] = "SelfRune1",
            [9] = "GroupRune",
        },
        defaults = {
            -- CC
            DoMez = true,
            DoAEMez = true,
            DoStun = false,
            -- Debuffs
            DoSlow = true,
            DoTash = true,
            DoCripple = false,
            -- Combat (minimal for CC role)
            DoNuke = false,
            DoDoT = false,
            DoCharm = false,
            DoManaTap = true,
            -- Defense
            DoSelfRune = true,
            DoGroupRune = true,
            UseReactiveRune = true,
            -- Buffs
            DoHaste = true,
            DoManaRegen = true,
            -- Burn
            UseChromaticHaze = true,
            UseIllusionsOfGrandeur = true,
            UseSpireOfEnchantment = true,
            UseBeguilersSynergy = true,
        },
        layerAssignments = {
            -- Emergency
            DoSelfRune = "emergency",
            UseReactiveRune = "emergency",
            -- Support (CC primary)
            DoMez = "support",
            DoAEMez = "support",
            DoStun = "support",
            DoSlow = "support",
            DoTash = "support",
            DoCripple = "support",
            -- Combat
            DoNuke = "combat",
            DoDoT = "combat",
            DoManaTap = "combat",
            DoCharm = "combat",
            -- Burn
            UseChromaticHaze = "burn",
            UseIllusionsOfGrandeur = "burn",
            UseSpireOfEnchantment = "burn",
            UseBeguilersSynergy = "burn",
            -- Utility
            DoGroupRune = "buff",
            DoHaste = "buff",
            DoManaRegen = "buff",
        },
        layerOrder = {
            emergency = {"DoSelfRune", "UseReactiveRune"},
            support = {"DoMez", "DoAEMez", "DoStun", "DoSlow", "DoTash", "DoCripple"},
            combat = {"DoManaTap", "DoNuke", "DoDoT", "DoCharm"},
            burn = {"UseChromaticHaze", "UseIllusionsOfGrandeur", "UseSpireOfEnchantment", "UseBeguilersSynergy"},
            buff = {"DoGroupRune", "DoHaste", "DoManaRegen"},
        },
    },
    dps = {
        name = "DPS Focused",
        description = "Maximize damage output",
        gems = {
            [1] = "MagicNuke",
            [2] = "RuneNuke",
            [3] = "ManaTapNuke",
            [4] = "DotSpell",
            [5] = "MezSpell",
            [6] = "SlowSpell",
            [7] = "TashSpell",
            [8] = "SelfRune1",
            [9] = "HasteSpell",
        },
        defaults = {
            -- CC (minimal)
            DoMez = true,
            DoAEMez = false,
            DoStun = false,
            -- Debuffs
            DoSlow = true,
            DoTash = true,
            DoCripple = false,
            -- Combat (primary)
            DoNuke = true,
            DoDoT = true,
            DoCharm = false,
            DoManaTap = true,
            -- Defense
            DoSelfRune = true,
            DoGroupRune = false,
            UseReactiveRune = true,
            -- Buffs
            DoHaste = true,
            DoManaRegen = false,
            -- Burn
            UseChromaticHaze = true,
            UseIllusionsOfGrandeur = true,
            UseSpireOfEnchantment = true,
            UseBeguilersSynergy = true,
        },
        layerAssignments = {
            -- Emergency
            DoSelfRune = "emergency",
            UseReactiveRune = "emergency",
            -- Support
            DoMez = "support",
            DoAEMez = "support",
            DoStun = "support",
            DoSlow = "support",
            DoTash = "support",
            DoCripple = "support",
            -- Combat (primary)
            DoNuke = "combat",
            DoDoT = "combat",
            DoManaTap = "combat",
            DoCharm = "combat",
            -- Burn
            UseChromaticHaze = "burn",
            UseIllusionsOfGrandeur = "burn",
            UseSpireOfEnchantment = "burn",
            UseBeguilersSynergy = "burn",
            -- Utility
            DoGroupRune = "buff",
            DoHaste = "buff",
            DoManaRegen = "buff",
        },
        layerOrder = {
            emergency = {"DoSelfRune", "UseReactiveRune"},
            support = {"DoTash", "DoSlow", "DoMez", "DoAEMez", "DoStun", "DoCripple"},
            combat = {"DoNuke", "DoDoT", "DoManaTap", "DoCharm"},
            burn = {"UseChromaticHaze", "UseIllusionsOfGrandeur", "UseSpireOfEnchantment", "UseBeguilersSynergy"},
            buff = {"DoHaste", "DoGroupRune", "DoManaRegen"},
        },
    },
    buff = {
        name = "Buff/Support",
        description = "Focus on group buffs",
        gems = {
            [1] = "HasteSpell",
            [2] = "ManaRegenSpell",
            [3] = "GroupRune",
            [4] = "SelfRune1",
            [5] = "SelfRune2",
            [6] = "MezSpell",
            [7] = "SlowSpell",
            [8] = "TashSpell",
        },
        defaults = {
            -- CC (backup)
            DoMez = true,
            DoAEMez = false,
            DoStun = false,
            -- Debuffs
            DoSlow = true,
            DoTash = true,
            DoCripple = false,
            -- Combat (minimal)
            DoNuke = false,
            DoDoT = false,
            DoCharm = false,
            DoManaTap = true,
            -- Defense
            DoSelfRune = true,
            DoGroupRune = true,
            UseReactiveRune = true,
            -- Buffs (primary)
            DoHaste = true,
            DoManaRegen = true,
            -- Burn
            UseChromaticHaze = true,
            UseIllusionsOfGrandeur = true,
            UseSpireOfEnchantment = true,
            UseBeguilersSynergy = true,
        },
        layerAssignments = {
            -- Emergency
            DoSelfRune = "emergency",
            UseReactiveRune = "emergency",
            -- Support
            DoMez = "support",
            DoAEMez = "support",
            DoStun = "support",
            DoSlow = "support",
            DoTash = "support",
            DoCripple = "support",
            -- Combat
            DoNuke = "combat",
            DoDoT = "combat",
            DoManaTap = "combat",
            DoCharm = "combat",
            -- Burn
            UseChromaticHaze = "burn",
            UseIllusionsOfGrandeur = "burn",
            UseSpireOfEnchantment = "burn",
            UseBeguilersSynergy = "burn",
            -- Utility (primary)
            DoGroupRune = "buff",
            DoHaste = "buff",
            DoManaRegen = "buff",
        },
        layerOrder = {
            emergency = {"DoSelfRune", "UseReactiveRune"},
            support = {"DoMez", "DoSlow", "DoTash", "DoAEMez", "DoStun", "DoCripple"},
            combat = {"DoManaTap", "DoNuke", "DoDoT", "DoCharm"},
            burn = {"UseIllusionsOfGrandeur", "UseChromaticHaze", "UseSpireOfEnchantment", "UseBeguilersSynergy"},
            buff = {"DoHaste", "DoManaRegen", "DoGroupRune"},
        },
    },
    raid = {
        name = "Raid DPS",
        description = "Raid damage with essential CC",
        gems = {
            [1] = "MagicNuke",
            [2] = "RuneNuke",
            [3] = "ManaTapNuke",
            [4] = "TwinCastMez",
            [5] = "MezSpell",
            [6] = "TashSpell",
            [7] = "SelfRune1",
            [8] = "SelfRune2",
            [9] = "ColorStun",
        },
        defaults = {
            -- CC (essential)
            DoMez = true,
            DoAEMez = false,
            DoStun = true,
            -- Debuffs
            DoSlow = false,
            DoTash = true,
            DoCripple = false,
            -- Combat (primary)
            DoNuke = true,
            DoDoT = true,
            DoCharm = false,
            DoManaTap = true,
            -- Defense
            DoSelfRune = true,
            DoGroupRune = false,
            UseReactiveRune = true,
            -- Buffs (minimal)
            DoHaste = false,
            DoManaRegen = false,
            -- Burn (full)
            UseChromaticHaze = true,
            UseIllusionsOfGrandeur = true,
            UseSpireOfEnchantment = true,
            UseBeguilersSynergy = true,
        },
        layerAssignments = {
            -- Emergency
            DoSelfRune = "emergency",
            UseReactiveRune = "emergency",
            -- Support
            DoMez = "support",
            DoAEMez = "support",
            DoStun = "support",
            DoSlow = "support",
            DoTash = "support",
            DoCripple = "support",
            -- Combat (primary)
            DoNuke = "combat",
            DoDoT = "combat",
            DoManaTap = "combat",
            DoCharm = "combat",
            -- Burn (primary)
            UseChromaticHaze = "burn",
            UseIllusionsOfGrandeur = "burn",
            UseSpireOfEnchantment = "burn",
            UseBeguilersSynergy = "burn",
            -- Utility
            DoGroupRune = "buff",
            DoHaste = "buff",
            DoManaRegen = "buff",
        },
        layerOrder = {
            emergency = {"DoSelfRune", "UseReactiveRune"},
            support = {"DoTash", "DoMez", "DoStun", "DoAEMez", "DoSlow", "DoCripple"},
            combat = {"DoNuke", "DoDoT", "DoManaTap", "DoCharm"},
            burn = {"UseChromaticHaze", "UseIllusionsOfGrandeur", "UseSpireOfEnchantment", "UseBeguilersSynergy"},
            buff = {"DoHaste", "DoManaRegen", "DoGroupRune"},
        },
    },
}

-- DefaultConfig: Settings with UI metadata
M.DefaultConfig = {
    -- CC Settings
    DoMez = {
        Default = true,
        Category = "CC",
        DisplayName = "Use Mez",
        Tooltip = "Enable mesmerization of adds",
        AbilitySet = "MezSpell",
    },
    DoAEMez = {
        Default = false,
        Category = "CC",
        DisplayName = "Use AE Mez",
        Tooltip = "Enable area mez when multiple adds",
        AbilitySet = "MezAESpell",
    },
    DoStun = {
        Default = false,
        Category = "CC",
        DisplayName = "Use Color Stun",
        Tooltip = "Use PBAE stun for emergency CC",
        AbilitySet = "ColorStun",
    },
    MaxMezTargets = {
        Default = 3,
        Category = "CC",
        DisplayName = "Max Mez Targets",
        Tooltip = "Maximum number of mobs to mez",
        Min = 1,
        Max = 10,
    },
    MezRadius = {
        Default = 100,
        Category = "CC",
        DisplayName = "Mez Radius",
        Tooltip = "Distance to check for mez targets",
        Min = 30,
        Max = 200,
    },

    -- Debuff Settings
    DoSlow = {
        Default = true,
        Category = "Debuff",
        DisplayName = "Use Slow",
        Tooltip = "Enable slow on targets",
        AbilitySet = "SlowSpell",
    },
    DoTash = {
        Default = true,
        Category = "Debuff",
        DisplayName = "Use Tash",
        Tooltip = "Enable magic resist debuff",
        AbilitySet = "TashSpell",
    },
    DoCripple = {
        Default = false,
        Category = "Debuff",
        DisplayName = "Use Cripple",
        Tooltip = "Enable cripple debuff",
        AbilitySet = "CrippleSpell",
    },

    -- Combat Settings
    DoNuke = {
        Default = true,
        Category = "Combat",
        DisplayName = "Use Nukes",
        Tooltip = "Enable damage nukes",
        AbilitySet = "MagicNuke",
    },
    DoDoT = {
        Default = false,
        Category = "Combat",
        DisplayName = "Use DoTs",
        Tooltip = "Enable damage over time spells",
        AbilitySet = "DotSpell",
    },
    DoCharm = {
        Default = false,
        Category = "Combat",
        DisplayName = "Use Charm",
        Tooltip = "Enable charm on mobs (advanced)",
        AbilitySet = "CharmSpell",
    },
    DoManaTap = {
        Default = true,
        Category = "Combat",
        DisplayName = "Use Mana Tap",
        Tooltip = "Enable mana recovery nukes",
        AbilitySet = "ManaTapNuke",
    },
    NukeMinMana = {
        Default = 40,
        Category = "Combat",
        DisplayName = "Nuke Min Mana %",
        Tooltip = "Stop nuking below this mana percentage",
        Min = 10,
        Max = 80,
    },

    -- Defense Settings
    DoSelfRune = {
        Default = true,
        Category = "Defense",
        DisplayName = "Keep Self Rune",
        Tooltip = "Maintain self-rune buff",
        AbilitySet = "SelfRune1",
    },
    DoGroupRune = {
        Default = true,
        Category = "Defense",
        DisplayName = "Cast Group Rune",
        Tooltip = "Cast group rune when not in combat",
        AbilitySet = "GroupRune",
    },
    EmergencyRuneHP = {
        Default = 40,
        Category = "Defense",
        DisplayName = "Emergency Rune HP %",
        Tooltip = "HP threshold to cast emergency rune",
        Min = 10,
        Max = 80,
    },
    UseReactiveRune = {
        Default = true,
        Category = "Defense",
        DisplayName = "Use Reactive Rune",
        Tooltip = "Use Reactive Rune AA for defense",
    },

    -- Buff Settings
    DoHaste = {
        Default = true,
        Category = "Buff",
        DisplayName = "Cast Haste",
        Tooltip = "Maintain haste on group members",
    },
    DoManaRegen = {
        Default = true,
        Category = "Buff",
        DisplayName = "Cast Mana Regen",
        Tooltip = "Maintain mana regen on casters",
    },

    -- Burn Settings
    UseChromaticHaze = {
        Default = true,
        Category = "Burn",
        DisplayName = "Chromatic Haze",
        Tooltip = "Use Chromatic Haze during burns",
    },
    UseIllusionsOfGrandeur = {
        Default = true,
        Category = "Burn",
        DisplayName = "Illusions of Grandeur",
        Tooltip = "Use Illusions of Grandeur during burns",
    },
    UseSpireOfEnchantment = {
        Default = true,
        Category = "Burn",
        DisplayName = "Spire of Enchantment",
        Tooltip = "Use Spire of Enchantment during burns",
    },
    UseBeguilersSynergy = {
        Default = true,
        Category = "Burn",
        DisplayName = "Beguiler's Synergy",
        Tooltip = "Use Beguiler's Synergy during burns",
    },
}

-- Rotations: Priority-ordered actions with conditions
M.Rotations = {
    -- Emergency layer (health critical)
    Emergency = {
        { name = "EldritchRuneAA", type = "aa", settingKey = "DoSelfRune" },
        { name = "DimensionalShieldAA", type = "aa" },
        { name = "ReactiveRuneAA", type = "aa", settingKey = "UseReactiveRune" },
        { name = "SelfStasisAA", type = "aa" },
    },

    -- Support layer (debuffs, CC)
    Support = {
        { name = "MezSpell", type = "spell", settingKey = "DoMez",
          cond = "AddCount > 0" },
        { name = "MezAESpell", type = "spell", settingKey = "DoAEMez",
          cond = "AddCount > 2" },
        { name = "SlowSpell", type = "spell", settingKey = "DoSlow",
          cond = "Target.Slowed.ID == nil" },
        { name = "TashSpell", type = "spell", settingKey = "DoTash",
          cond = "Target.Tashed.ID == nil" },
        { name = "CrippleSpell", type = "spell", settingKey = "DoCripple" },
    },

    -- Combat layer (damage)
    Combat = {
        { name = "MagicNuke", type = "spell", settingKey = "DoNuke" },
        { name = "RuneNuke", type = "spell", settingKey = "DoNuke" },
        { name = "ManaTapNuke", type = "spell", settingKey = "DoManaTap" },
        { name = "DotSpell", type = "spell", settingKey = "DoDoT" },
        { name = "MindStormAA", type = "aa", settingKey = "DoNuke" },
    },

    -- Burn layer (when burn active)
    Burn = {
        { name = "ChromaticHazeAA", type = "aa", settingKey = "UseChromaticHaze" },
        { name = "IllusionsOfGrandeurAA", type = "aa", settingKey = "UseIllusionsOfGrandeur" },
        { name = "SpireOfEnchantmentAA", type = "aa", settingKey = "UseSpireOfEnchantment" },
        { name = "BeguilersSynergyAA", type = "aa", settingKey = "UseBeguilersSynergy" },
        { name = "SilentCastingAA", type = "aa" },
        { name = "GatherManaAA", type = "aa" },
    },

    -- Utility layer (buffs, out of combat)
    Utility = {
        { name = "SelfRune1", type = "spell", settingKey = "DoSelfRune",
          cond = "not InCombat" },
        { name = "SelfRune2", type = "spell", settingKey = "DoSelfRune",
          cond = "not InCombat" },
        { name = "GroupRune", type = "spell", settingKey = "DoGroupRune",
          cond = "not InCombat" },
        { name = "HasteSpell", type = "spell", settingKey = "DoHaste",
          cond = "not InCombat" },
        { name = "ManaRegenSpell", type = "spell", settingKey = "DoManaRegen",
          cond = "not InCombat" },
    },
}

--- Resolve an AbilitySet to the best available ability
-- @param setName string AbilitySet name
-- @return string|nil Best available ability name
function M.resolveAbilitySet(setName)
    local set = M.AbilitySets[setName]
    if not set then return nil end

    local me = mq.TLO.Me
    if not me or not me() then return nil end

    for _, name in ipairs(set) do
        -- Check spellbook
        local spell = me.Book(name)
        if spell and spell() then
            return name
        end

        -- Check AAs
        local aa = me.AltAbility(name)
        if aa and aa() then
            return name
        end
    end

    return nil
end

--- Resolve a loadout to gem -> spell mapping
-- @param loadoutName string Loadout role name
-- @return table Gem -> spell name mapping
function M.resolveLoadout(loadoutName)
    local loadout = M.SpellLoadouts[loadoutName]
    if not loadout or not loadout.gems then return {} end

    local resolved = {}
    for gem, setName in pairs(loadout.gems) do
        local spell = M.resolveAbilitySet(setName)
        if spell then
            resolved[gem] = spell
        end
    end

    return resolved
end

return M
