-- F:/lua/SideKick/data/spellsets/ENC.lua
-- Enchanter Spellsets - Role-based spell loadouts with spell line definitions

return {
    roles = {
        cc = {
            name = "Crowd Control",
            gems = {
                [1] = { spellLine = "MezSpell", priority = 1 },
                [2] = { spellLine = "MezAESpell", priority = 1 },
                [3] = { spellLine = "MezSpellFast", priority = 1 },
                [4] = { spellLine = "SlowSpell", priority = 1 },
                [5] = { spellLine = "TashSpell", priority = 2 },
                [6] = { spellLine = "Haste", priority = 2 },
                [7] = { spellLine = "ManaRegen", priority = 2 },
                [8] = { spellLine = "SelfRune1", priority = 3 },
                [9] = { spellLine = "GroupRune", priority = 3 },
            },
        },
        dps = {
            name = "DPS Focused",
            gems = {
                [1] = { spellLine = "MagicNuke", priority = 1 },
                [2] = { spellLine = "RuneNuke", priority = 1 },
                [3] = { spellLine = "ManaTapNuke", priority = 1 },
                [4] = { spellLine = "TwinCastMez", priority = 2 },
                [5] = { spellLine = "MezSpell", priority = 2 },
                [6] = { spellLine = "SlowSpell", priority = 2 },
                [7] = { spellLine = "TashSpell", priority = 2 },
                [8] = { spellLine = "SelfRune1", priority = 3 },
                [9] = { spellLine = "Haste", priority = 3 },
            },
        },
        buff = {
            name = "Buff/Support",
            gems = {
                [1] = { spellLine = "Haste", priority = 1 },
                [2] = { spellLine = "ManaRegen", priority = 1 },
                [3] = { spellLine = "GroupRune", priority = 1 },
                [4] = { spellLine = "SelfRune1", priority = 2 },
                [5] = { spellLine = "SelfRune2", priority = 2 },
                [6] = { spellLine = "MezSpell", priority = 2 },
                [7] = { spellLine = "SlowSpell", priority = 3 },
                [8] = { spellLine = "TashSpell", priority = 3 },
            },
        },
    },
    spellLines = {
        -- Single target mez
        ["MezSpell"] = {
            "Flummox", "Addle", "Deceive", "Delude", "Bewilder", "Confound",
            "Mislead", "Baffle", "Befuddle", "Mystify", "Bewilderment",
            "Euphoria", "Felicity", "Bliss", "Sleep",
        },
        -- Fast mez
        ["MezSpellFast"] = {
            "Flummoxing Flash", "Addling Flash", "Deceiving Flash", "Deluding Flash",
            "Bewildering Flash", "Confounding Flash", "Misleading Flash", "Baffling Flash",
            "Befuddling Flash", "Mystifying Flash", "Perplexing Flash",
        },
        -- Fast AE mez (glance line)
        ["MezAESpellFast"] = {
            "Vexing Glance", "Confounding Glance", "Neutralizing Glance",
            "Perplexing Glance", "Slackening Glance",
        },
        -- AE mez
        ["MezAESpell"] = {
            "Neutralizing Wave", "Perplexing Wave", "Deadening Wave",
            "Slackening Wave", "Peaceful Wave", "Serene Wave",
            "Ensorcelling Wave", "Quelling Wave", "Wake of Subdual",
            "Wake of Felicity", "Bliss of the Nihil", "Fascination",
            "Mesmerization", "Bewildering Wave",
        },
        -- PBAE mez
        ["MezPBAESpell"] = {
            "Neutralize", "Perplex", "Bafflement", "Disorientation",
            "Confusion", "Serenity", "Docility", "Visions of Kirathas",
            "Dreams of Veldyn", "Circle of Dreams", "Word of Morell",
        },
        -- Twin cast mez (for DPS)
        ["TwinCastMez"] = {
            "Chaotic Deception", "Chaotic Delusion", "Chaotic Bewildering",
            "Chaotic Confounding", "Chaotic Confusion", "Chaotic Baffling",
            "Chaotic Befuddling", "Chaotic Puzzlement", "Chaotic Conundrum",
        },
        -- Slow
        ["SlowSpell"] = {
            "Desolate Deeds", "Dreary Deeds", "Forlorn Deeds",
            "Shiftless Deeds", "Tepid Deeds", "Languid Pace",
        },
        -- Tash (magic debuff)
        ["TashSpell"] = {
            "Roar of Tashan", "Edict of Tashan", "Proclamation of Tashan",
            "Order of Tashan", "Decree of Tashan", "Enunciation of Tashan",
            "Declaration of Tashan", "Clamor of Tashan", "Bark of Tashan",
            "Din of Tashan", "Echo of Tashan", "Howl of Tashan",
            "Tashanian", "Tashania", "Tashani", "Tashina",
        },
        -- Haste
        ["Haste"] = {
            "Hastening of Jharin", "Hastening of Salik", "Hastening of Ellowind",
            "Hastening of Erradien", "Speed of Salik", "Speed of Ellowind",
            "Speed of Erradien", "Speed of Novak", "Speed of Aransir",
            "Speed of Sviir", "Vallon's Quickening", "Visions of Grandeur",
            "Wondrous Rapidity", "Aanya's Quickening", "Swift Like the Wind",
            "Celerity", "Augmentation", "Alacrity", "Quickness",
        },
        -- Mana regen
        ["ManaRegen"] = {
            "Voice of Preordination", "Voice of Perception", "Voice of Sagacity",
            "Voice of Perspicacity", "Voice of Precognition", "Voice of Foresight",
            "Voice of Premeditation", "Voice of Forethought", "Voice of Prescience",
            "Voice of Cognizance", "Voice of Intuition", "Voice of Clairvoyance",
            "Voice of Quellious", "Tranquility", "Koadic's Endless Intellect",
            "Clarity II", "Clarity", "Breeze",
        },
        -- Self rune 1
        ["SelfRune1"] = {
            "Esoteric Rune", "Marvel's Rune", "Deviser's Rune",
            "Transfixer's Rune", "Enticer's Rune", "Mastermind's Rune",
            "Arcanaward's Rune", "Spectral Rune", "Pearlescent Rune",
            "Opalescent Rune", "Draconic Rune", "Ethereal Rune", "Arcane Rune",
        },
        -- Self rune 2
        ["SelfRune2"] = {
            "Polyradiant Rune", "Polyluminous Rune", "Polycascading Rune",
            "Polyfluorescent Rune", "Polyrefractive Rune", "Polyiridescent Rune",
            "Polyarcanic Rune", "Polyspectral Rune", "Polychaotic Rune",
            "Multichromatic Rune", "Polychromatic Rune",
        },
        -- Group rune
        ["GroupRune"] = {
            "Gloaming Rune", "Eclipsed Rune", "Crepuscular Rune",
            "Tenebrous Rune", "Darkened Rune", "Umbral Rune",
            "Shadowed Rune", "Twilight Rune", "Rune of the Void",
        },
        -- Magic nuke
        ["MagicNuke"] = {
            "Mindrend", "Mindreap", "Mindrift", "Mindslash", "Mindsunder",
            "Mindcleave", "Mindscythe", "Mindblade", "Spectral Assault",
            "Polychaotic Assault", "Multichromatic Assault",
        },
        -- Rune nuke (fast)
        ["RuneNuke"] = {
            "Chromatic Spike", "Chromatic Flare", "Chromatic Stab",
            "Chromatic Flicker", "Chromatic Blink", "Chromatic Percussion",
            "Chromatic Flash", "Chromatic Jab",
        },
        -- Mana tap nuke
        ["ManaTapNuke"] = {
            "Psychological Appropriation", "Ideological Appropriation",
            "Psychic Appropriation", "Intellectual Appropriation",
            "Mental Appropriation", "Cognitive Appropriation",
        },
        -- Color stun (PBAE)
        ["ColorStun"] = {
            "Color Calibration", "Color Conflagration", "Color Cascade",
            "Color Congruence", "Color Concourse", "Color Conflux",
            "Color Collapse", "Color Cataclysm", "Color Shift", "Color Skew",
        },
    },
}
