-- F:/lua/SideKick/data/spellsets/PAL.lua
-- Paladin Spellsets - Role-based spell loadouts with spell line definitions

return {
    roles = {
        tank = {
            name = "Tank Focused",
            gems = {
                [1] = { spellLine = "CrushTimer5", priority = 1 },
                [2] = { spellLine = "CrushTimer6", priority = 1 },
                [3] = { spellLine = "StunTimer4", priority = 1 },
                [4] = { spellLine = "StunTimer5", priority = 1 },
                [5] = { spellLine = "Healtaunt", priority = 2 },
                [6] = { spellLine = "Affirmation", priority = 2 },
                [7] = { spellLine = "Aurora", priority = 2 },
                [8] = { spellLine = "WaveHeal", priority = 3 },
                [9] = { spellLine = "Preservation", priority = 3 },
            },
        },
        heal = {
            name = "Heal Support",
            gems = {
                [1] = { spellLine = "WaveHeal", priority = 1 },
                [2] = { spellLine = "WaveHeal2", priority = 1 },
                [3] = { spellLine = "Aurora", priority = 1 },
                [4] = { spellLine = "HealNuke", priority = 1 },
                [5] = { spellLine = "Healward", priority = 2 },
                [6] = { spellLine = "Healstun", priority = 2 },
                [7] = { spellLine = "Cleansehot", priority = 2 },
                [8] = { spellLine = "Splashcure", priority = 3 },
                [9] = { spellLine = "Preservation", priority = 3 },
            },
        },
        dps = {
            name = "DPS Focused",
            gems = {
                [1] = { spellLine = "CrushTimer5", priority = 1 },
                [2] = { spellLine = "CrushTimer6", priority = 1 },
                [3] = { spellLine = "HealNuke", priority = 1 },
                [4] = { spellLine = "DebuffNuke", priority = 1 },
                [5] = { spellLine = "Doctrine", priority = 2 },
                [6] = { spellLine = "Lowaggronuke", priority = 2 },
                [7] = { spellLine = "Aurora", priority = 2 },
                [8] = { spellLine = "WaveHeal", priority = 3 },
                [9] = { spellLine = "FuryProc", priority = 3 },
            },
        },
    },
    spellLines = {
        -- Crush spells
        ["CrushTimer5"] = {
            "Crush of the Wayunder", "Crush of the Twilight Sea",
            "Crush of the Grotto", "Crush of the Timorous Deep",
            "Crush of the Darkened Sea", "Crush of the Iceclad",
            "Crush of Oseka", "Crush of Marr", "Crush of the Crying Seas",
        },
        ["CrushTimer6"] = {
            "Crush of the Heroic", "Crush of the Umbra", "Crush of Restless Ice",
            "Crush of E'Ci", "Crush of Povar", "Crush of Tarew",
            "Crush of Tides", "Crush of Repentance", "Crush of Compunction",
        },
        -- Stun spells
        ["StunTimer4"] = {
            "Avowed Force", "Pious Force", "Sincere Force", "Merciful Force",
            "Ardent Force", "Reverent Force", "Zealous Force", "Earnest Force",
            "Solemn Force", "Devout Force", "Sacred Force", "Force of Piety",
            "Force of Akilae", "Cease",
        },
        ["StunTimer5"] = {
            "Force of the Wayunder", "Force of the Umbra", "Force of the Grotto",
            "Force of the Timorous Deep", "Force of the Darkened Sea",
            "Force of the Iceclad", "Force of Oseka", "Force of Marr",
            "Force of the Crying Seas", "Force of Timorous", "Force of Prexus",
            "Ancient: Force of Jeron", "Ancient: Force of Chaos", "Force of Akera",
        },
        ["Healstun"] = {
            "Force of the Avowed", "Force of Generosity", "Force of Reverence",
            "Force of Ardency", "Force of Mercy", "Force of Sincerity",
        },
        -- Heal spells
        ["WaveHeal"] = {
            "Wave of Regret", "Wave of Bereavement", "Wave of Propitiation",
            "Wave of Expiation", "Wave of Grief", "Wave of Sorrow",
            "Wave of Contrition", "Wave of Penitence", "Wave of Remitment",
            "Wave of Absolution", "Wave of Forgiveness", "Wave of Piety",
            "Wave of Marr", "Wave of Trushar", "Healing Wave of Prexus",
        },
        ["WaveHeal2"] = {
            "Wave of Bereavement", "Wave of Propitiation", "Wave of Expiation",
            "Wave of Grief", "Wave of Sorrow", "Wave of Contrition",
            "Wave of Penitence", "Wave of Remitment", "Wave of Absolution",
        },
        ["Aurora"] = {
            "Aurora of Realizing", "Aurora of Wakening", "Aurora of Morninglight",
            "Aurora of Dayspring", "Aurora of Sunrise", "Aurora of Splendor",
            "Aurora of Daybreak", "Aurora of Dawnlight", "Aurora of Dawning",
        },
        ["HealNuke"] = {
            "Brilliant Denouncement", "Brilliant Acquittal", "Brilliant Exculpation",
            "Brilliant Exoneration", "Brilliant Vindication", "Glorious Expurgation",
            "Glorious Exculpation", "Glorious Exoneration", "Glorious Vindication",
        },
        ["Healward"] = {
            "Protective Consecration", "Protective Proclamation",
            "Protective Allegiance", "Protective Dedication", "Protective Devotion",
            "Protective Confession", "Protective Revelation", "Protective Acceptance",
        },
        ["Cleansehot"] = {
            "Avowed Cleansing", "Devout Cleansing", "Sincere Cleansing",
            "Merciful Cleansing", "Ardent Cleansing", "Reverent Cleansing",
            "Zealous Cleansing", "Earnest Cleansing", "Solemn Cleansing",
            "Sacred Cleansing", "Pious Cleansing", "Supernal Cleansing",
            "Celestial Cleansing", "Ethereal Cleansing",
        },
        ["Splashcure"] = {
            "Splash of Exaltation", "Splash of Depuration", "Splash of Atonement",
            "Splash of Cleansing", "Splash of Purification",
            "Splash of Sanctification", "Splash of Repentance", "Splash of Heroism",
        },
        ["Selfheal"] = {
            "Angst", "Culpability", "Propitiation", "Exaltation",
            "Grief", "Sorrow", "Contrition", "Penitence",
        },
        -- Preservation (emergency heal)
        ["Preservation"] = {
            "Preservation of the Fern", "Preservation of the Basilica",
            "Preservation of the Grotto", "Preservation of Rodcet",
            "Preservation of the Iceclad", "Preservation of Oseka",
            "Preservation of Marr", "Preservation of Tunare",
            "Sustenance of Tunare", "Ward of Tunare",
        },
        -- TempHP
        ["TempHP"] = {
            "Unwavering Stance", "Adamant Stance", "Stormwall Stance",
            "Defiant Stance", "Steadfast Stance", "Staunch Stance",
            "Stoic Stance", "Stubborn Stance", "Steely Stance",
        },
        -- Undead nukes
        ["DebuffNuke"] = {
            "Revelation", "Hymnal", "Requiem", "Remembrance", "Consecration",
            "Laudation", "Paean", "Elegy", "Eulogy", "Benediction",
            "Burial Rites", "Last Rites",
        },
        ["Doctrine"] = {
            "Doctrine of Repudiation", "Doctrine of Abolishment",
            "Doctrine of Exculpation", "Doctrine of Rescission",
            "Doctrine of Abrogation",
        },
        -- Low aggro nuke
        ["Lowaggronuke"] = {
            "Chastise", "Upbraid", "Remonstrate", "Censure", "Admonish",
            "Ostracize", "Reprimand", "Denouncement",
        },
        -- Aggro spells
        ["Healtaunt"] = {
            "Valiant Deterrence", "Valiant Diversion", "Valiant Defense",
            "Valiant Deflection", "Valiant Disruption", "Valiant Defiance",
        },
        ["Affirmation"] = {
            "Unyielding Affirmation", "Unflinching Affirmation",
            "Unbroken Affirmation", "Undivided Affirmation",
            "Unrelenting Affirmation", "Unending Affirmation",
            "Unconditional Affirmation",
        },
        -- Procs
        ["FuryProc"] = {
            "Avowed Fury", "Wrathful Fury", "Sincere Fury", "Merciful Fury",
            "Ardent Fury", "Reverent Fury", "Zealous Fury", "Earnest Fury",
            "Devout Fury", "Righteous Fury", "Pious Fury", "Holy Order",
        },
        ["UndeadProc"] = {
            "Silvered Fury", "Ward of Nife", "Instrument of Nife",
        },
        ["Healproc"] = {
            "Renewing Steel", "Revitalizating Steel", "Reinvigorating Steel",
            "Rejuvenating Steel", "Regenerating Steel", "Restoring Steel",
        },
        -- Buffs
        ["Aego"] = {
            "Hand of the Fernshade Keeper", "Fernshade Keeper",
            "Hand of the Dreaming Keeper", "Shadewell Keeper",
            "Hand of the Stormwall Keeper", "Stormwall Keeper",
            "Hand of the Ashbound Keeper", "Ashbound Keeper",
            "Hand of the Stormbound Keeper", "Stormbound Keeper",
            "Hand of the Pledged Keeper", "Pledged Keeper",
            "Hand of the Avowed Keeper", "Avowed Keeper",
            "Oathbound Keeper", "Sworn Keeper", "Oathbound Protector",
        },
        ["Brells"] = {
            "Brell's Unbreakable Palisade", "Brell's Steadfast Aegis",
            "Brell's Mountainous Barrier", "Brell's Stalwart Shield",
            "Brell's Brawny Bulwark", "Brell's Stony Guard",
            "Brell's Earthen Aegis", "Brell's Blessed Barrier",
        },
        ["Reverseds"] = {
            "Mark of the Forgotten Hero", "Mark of the Eclipsed Cohort",
            "Mark of the Jade Cohort", "Mark of the Commander",
            "Mark of the Exemplar", "Mark of the Reverent",
            "Mark of the Defender", "Mark of the Pure",
            "Mark of the Pious", "Mark of the Crusader", "Mark of the Saint",
        },
        ["Incoming"] = {
            "Paradoxical Blessing", "Penumbral Blessing", "Confluent Blessing",
            "Concordant Blessing", "Harmonious Blessing",
        },
        -- Cure spells (Paladin has limited cure capability - Disease only via Cleanse line)
        ["CureDisease"] = {
            "Avowed Cleansing", "Devout Cleansing", "Sincere Cleansing",
            "Merciful Cleansing", "Ardent Cleansing", "Reverent Cleansing",
            "Zealous Cleansing", "Earnest Cleansing", "Solemn Cleansing",
            "Sacred Cleansing", "Pious Cleansing", "Supernal Cleansing",
            "Celestial Cleansing", "Ethereal Cleansing",
        },
        ["CureAll"] = {
            "Splash of Exaltation", "Splash of Depuration", "Splash of Atonement",
            "Splash of Cleansing", "Splash of Purification",
            "Splash of Sanctification", "Splash of Repentance", "Splash of Heroism",
        },
        ["CureAllGroup"] = {
            "Splash of Exaltation", "Splash of Depuration", "Splash of Atonement",
            "Splash of Cleansing", "Splash of Purification",
        },
    },
}
