-- F:/lua/SideKick/data/spellsets/DRU.lua
-- Druid Spellsets - Role-based spell loadouts with spell line definitions

return {
    roles = {
        heal = {
            name = "Healing Focused",
            gems = {
                [1] = { spellLine = "QuickHealSurge", priority = 1 },
                [2] = { spellLine = "QuickHeal", priority = 1 },
                [3] = { spellLine = "LongHeal1", priority = 1 },
                [4] = { spellLine = "QuickGroupHeal", priority = 1 },
                [5] = { spellLine = "LongGroupHeal", priority = 2 },
                [6] = { spellLine = "PromHeal", priority = 2 },
                [7] = { spellLine = "SingleTgtCure", priority = 2 },
                [8] = { spellLine = "GroupCure", priority = 3 },
                [9] = { spellLine = "SkinDebuff", priority = 3 },
            },
        },
        dps = {
            name = "DPS Focused",
            gems = {
                [1] = { spellLine = "SunDot", priority = 1 },
                [2] = { spellLine = "HordeDot", priority = 1 },
                [3] = { spellLine = "NaturesWrathDot", priority = 1 },
                [4] = { spellLine = "SunMoonDot", priority = 1 },
                [5] = { spellLine = "FrostDebuff", priority = 2 },
                [6] = { spellLine = "RoDebuff", priority = 2 },
                [7] = { spellLine = "QuickHealSurge", priority = 2 },
                [8] = { spellLine = "QuickGroupHeal", priority = 3 },
                [9] = { spellLine = "SkinDebuff", priority = 3 },
            },
        },
        mana = {
            name = "Mana Recovery",
            gems = {
                [1] = { spellLine = "QuickHealSurge", priority = 1 },
                [2] = { spellLine = "QuickHeal", priority = 1 },
                [3] = { spellLine = "QuickGroupHeal", priority = 1 },
                [4] = { spellLine = "LongGroupHeal", priority = 2 },
                [5] = { spellLine = "SingleTgtCure", priority = 2 },
                [6] = { spellLine = "SkinDebuff", priority = 2 },
                [7] = { spellLine = "ReptileCombatInnate", priority = 3 },
                [8] = { spellLine = "IceAura", priority = 3 },
            },
        },
    },
    spellLines = {
        -- Quick heals (Adrenaline line)
        ["QuickHealSurge"] = {
            "Adrenaline Fury", "Adrenaline Spate", "Adrenaline Deluge",
            "Adrenaline Barrage", "Adrenaline Torrent", "Adrenaline Rush",
            "Adrenaline Flood", "Adrenaline Blast", "Adrenaline Burst",
            "Adrenaline Swell", "Adrenaline Surge",
        },
        ["QuickHeal"] = {
            "Resuscitation", "Sootheseance", "Rejuvenescence", "Revitalization",
            "Resurgence", "Vivification", "Invigoration", "Rejuvilation",
        },
        -- Long heals
        ["LongHeal1"] = {
            "Vivavida", "Clotavida", "Viridavida", "Curavida", "Panavida",
            "Sterivida", "Sanavida", "Benevida", "Granvida", "Puravida",
            "Pure Life", "Chlorotrope", "Sylvan Infusion", "Nature's Infusion",
            "Nature's Touch", "Chloroblast", "Forest's Renewal", "Superior Healing",
        },
        -- Group heals
        ["QuickGroupHeal"] = {
            "Survival of the Heroic", "Survival of the Unrelenting",
            "Survival of the Favored", "Survival of the Auspicious",
            "Survival of the Serendipitous", "Survival of the Fortuitous",
            "Survival of the Prosperous", "Survival of the Propitious",
            "Survival of the Felicitous", "Survival of the Fittest",
        },
        ["LongGroupHeal"] = {
            "Lunacea", "Lunarush", "Lunalesce", "Lunasalve", "Lunasoothe",
            "Lunassuage", "Lunalleviation", "Lunamelioration", "Lunulation",
            "Crescentbloom", "Lunarlight", "Moonshadow",
        },
        -- Promised heal
        ["PromHeal"] = {
            "Promised Regrowth", "Promised Reknit", "Promised Replenishment",
            "Promised Revitalization", "Promised Recovery", "Promised Regeneration",
            "Promised Rebirth", "Promised Refreshment", "Promised Revivification",
        },
        -- Cures
        ["SingleTgtCure"] = {
            "Sanctified Blood", "Expurgated Blood", "Unblemished Blood",
            "Cleansed Blood", "Perfected Blood", "Purged Blood", "Purified Blood",
        },
        ["GroupCure"] = {
            "Nightwhisper's Breeze", "Wildtender's Breeze", "Copsetender's Breeze",
            "Bosquetender's Breeze", "Fawnwalker's Breeze",
        },
        ["CureDisease"] = {
            "Sanctified Blood", "Expurgated Blood", "Unblemished Blood",
            "Cure Disease", "Remove Disease", "Counteract Disease",
        },
        ["CurePoison"] = {
            "Sanctified Blood", "Expurgated Blood", "Unblemished Blood",
            "Abolish Poison", "Counteract Poison", "Cure Poison", "Remove Poison",
        },
        ["CureCurse"] = {
            "Sanctified Blood", "Expurgated Blood", "Unblemished Blood",
            "Remove Greater Curse", "Remove Curse", "Abolish Curse",
        },
        ["CureCorruption"] = {
            "Sanctified Blood", "Expurgated Blood", "Unblemished Blood",
            "Restore", "Eradicate Corruption", "Purify Corruption",
        },
        ["CureAll"] = {
            "Sanctified Blood", "Expurgated Blood", "Unblemished Blood",
            "Cleansed Blood", "Perfected Blood", "Purged Blood", "Purified Blood",
            "Purified Spirits",
        },
        ["CureAllGroup"] = {
            "Nightwhisper's Breeze", "Wildtender's Breeze", "Copsetender's Breeze",
            "Bosquetender's Breeze", "Fawnwalker's Breeze",
        },
        -- DOTs
        ["SunDot"] = {
            "Sunscald", "Sunpyre", "Sunshock", "Sunflame", "Sunflash",
            "Sunblaze", "Sunscorch", "Sunbrand", "Sunsinge", "Sunsear",
            "Vengeance of the Sun", "Vengeance of Tunare",
        },
        ["HordeDot"] = {
            "Horde of Hotaria", "Horde of Duskwigs", "Horde of Hyperboreads",
            "Horde of Polybiads", "Horde of Aculeids", "Horde of Mutillids",
            "Horde of Vespids", "Horde of Scoriae", "Horde of the Hive",
            "Horde of Fireants", "Swarm of Fireants", "Wasp Swarm",
            "Swarming Death", "Winged Death", "Drifting Death",
        },
        ["NaturesWrathDot"] = {
            "Nature's Fervid Wrath", "Nature's Blistering Wrath",
            "Nature's Fiery Wrath", "Nature's Withering Wrath",
            "Nature's Scorching Wrath", "Nature's Incinerating Wrath",
            "Nature's Searing Wrath", "Nature's Burning Wrath",
            "Nature's Blazing Wrath", "Nature's Sweltering Wrath",
        },
        ["SunMoonDot"] = {
            "Mythical Moonbeam", "Searing Sunray", "Onyx Moonbeam",
            "Tenebrous Sunray", "Opaline Moonbeam", "Erupting Sunray",
            "Pearlescent Moonbeam", "Overwhelming Sunray", "Argent Moonbeam",
        },
        -- Debuffs
        ["FrostDebuff"] = {
            "Mythic Frost", "Primal Frost", "Restless Frost", "Glistening Frost",
            "Moonbright Frost", "Lustrous Frost", "Silver Frost", "Argent Frost",
            "Blanched Frost", "Gelid Frost", "Hoar Frost",
        },
        ["RoDebuff"] = {
            "Clench of Ro", "Cinch of Ro", "Clasp of Ro", "Cowl of Ro",
            "Crush of Ro", "Clutch of Ro", "Grip of Ro", "Grasp of Ro",
            "Sun's Corona", "Ro's Illumination", "Fixation of Ro",
        },
        ["SkinDebuff"] = {
            "Skin to Lichen", "Skin to Sumac", "Skin to Seedlings",
            "Skin to Foliage", "Skin to Leaves", "Skin to Flora",
            "Skin to Mulch", "Skin to Vines",
        },
        ["IceBreathDebuff"] = {
            "Algid Breath", "Twilight Breath", "Icerend Breath",
            "Frostreave Breath", "Blizzard Breath", "Frosthowl Breath",
            "Encompassing Breath", "Bracing Breath", "Coldwhisper Breath",
        },
        -- Buffs
        ["ReptileCombatInnate"] = {
            "Chitin of the Reptile", "Bulwark of the Reptile",
            "Defense of the Reptile", "Guard of the Reptile",
            "Pellicle of the Reptile", "Husk of the Reptile",
            "Hide of the Reptile", "Shell of the Reptile",
            "Carapace of the Reptile", "Scales of the Reptile",
        },
        -- Auras
        ["IceAura"] = {
            "Coldburst Aura", "Nightchill Aura", "Icerend Aura",
            "Frostreave Aura", "Frostweave Aura", "Frostone Aura",
            "Frostcloak Aura", "Frostfell Aura",
        },
        ["FireAura"] = {
            "Wildspark Aura", "Wildblaze Aura", "Wildfire Aura",
        },
        -- Charm
        ["CharmSpell"] = {
            "Beast's Bestowing", "Beast's Bellowing", "Beast's Beckoning",
            "Beast's Beseeching", "Beast's Bidding", "Beast's Bespelling",
            "Beast's Behest", "Beast's Beguiling", "Nature's Beckon",
            "Charm Animals", "Befriend Animal",
        },
    },
}
