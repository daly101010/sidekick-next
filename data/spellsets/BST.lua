-- F:/lua/SideKick/data/spellsets/BST.lua
-- Beastlord Spellsets - Role-based spell loadouts with spell line definitions

return {
    roles = {
        dps = {
            name = "DPS Focused",
            gems = {
                [1] = { spellLine = "FrozenPoi", priority = 1 },
                [2] = { spellLine = "Maelstrom", priority = 1 },
                [3] = { spellLine = "PoiBite", priority = 1 },
                [4] = { spellLine = "Icelance1", priority = 1 },
                [5] = { spellLine = "DichoSpell", priority = 2 },
                [6] = { spellLine = "Feralgia", priority = 2 },
                [7] = { spellLine = "EndemicDot", priority = 2 },
                [8] = { spellLine = "BloodDot", priority = 3 },
                [9] = { spellLine = "ColdDot", priority = 3 },
            },
        },
        dot = {
            name = "DOT Heavy",
            gems = {
                [1] = { spellLine = "EndemicDot", priority = 1 },
                [2] = { spellLine = "BloodDot", priority = 1 },
                [3] = { spellLine = "ColdDot", priority = 1 },
                [4] = { spellLine = "FrozenPoi", priority = 1 },
                [5] = { spellLine = "Maelstrom", priority = 2 },
                [6] = { spellLine = "DichoSpell", priority = 2 },
                [7] = { spellLine = "Feralgia", priority = 2 },
                [8] = { spellLine = "HealSpell", priority = 3 },
                [9] = { spellLine = "SlowSpell", priority = 3 },
            },
        },
        heal = {
            name = "Heal Support",
            gems = {
                [1] = { spellLine = "HealSpell", priority = 1 },
                [2] = { spellLine = "PetHealSpell", priority = 1 },
                [3] = { spellLine = "FrozenPoi", priority = 1 },
                [4] = { spellLine = "Maelstrom", priority = 2 },
                [5] = { spellLine = "SlowSpell", priority = 2 },
                [6] = { spellLine = "DichoSpell", priority = 2 },
                [7] = { spellLine = "Feralgia", priority = 3 },
                [8] = { spellLine = "EndemicDot", priority = 3 },
            },
        },
    },
    spellLines = {
        -- Nukes
        ["FrozenPoi"] = {
            "Frozen Creep", "Frozen Blight", "Frozen Malignance",
            "Frozen Toxin", "Frozen Miasma", "Frozen Carbomate",
            "Frozen Cyanin", "Frozen Venin", "Frozen Venom",
        },
        ["Maelstrom"] = {
            "Rimeclaw's Maelstrom", "Va Xakra's Maelstrom", "Vkjen's Maelstrom",
            "Beramos' Maelstrom", "Visoracius' Maelstrom", "Nak's Maelstrom",
            "Bale's Maelstrom", "Kron's Maelstrom",
        },
        ["PoiBite"] = {
            "Mortimus' Bite", "Zelniak's Bite", "Bloodmaw's Bite",
            "Mawmun's Bite", "Kreig's Bite", "Poantaar's Bite",
            "Rotsil's Bite", "Sarsez' Bite", "Bite of the Vitrik",
            "Bite of the Borrower", "Bite of the Empress",
        },
        -- Lance spells
        ["Icelance1"] = {
            "Ankexfen Lance", "Crystalline Lance", "Frostbite Lance",
            "Kromrif Lance", "Glacial Lance", "Jagged Torrent",
            "Ancient: Savage Ice", "Ancient: Frozen Chaos", "Frost Spear",
            "Blizzard Blast", "Frost Shard", "Blast of Frost",
        },
        ["Icelance2"] = {
            "Restless Lance", "Kromtus Lance", "Frostrift Lance",
            "Frigid Lance", "Spiked Sleet", "Glacier Spear",
            "Trushar's Frost", "Ice Shard", "Ice Spear",
        },
        ["AERoar"] = {
            "Hoarfrost Roar", "Polar Roar", "Restless Roar",
            "Frostbite Roar", "Kromtus Roar", "Kromrif Roar",
            "Frostrift Roar", "Glacial Roar",
        },
        -- DOTs
        ["EndemicDot"] = {
            "Fevered Endemic", "Vampyric Endemic", "Neemzaq's Endemic",
            "Elkikatar's Endemic", "Hemocoraxius' Endemic", "Natigo's Endemic",
            "Silbar's Endemic", "Shiverback Endemic", "Tsetsian Endemic",
            "Fever Surge", "Fever Spike", "Festering Malady",
            "Plague", "Malaria", "Sicken",
        },
        ["BloodDot"] = {
            "Forgebound Blood", "Akhevan Blood", "Ikatiar's Blood",
            "Polybiad Blood", "Glistenwing Blood", "Asp Blood",
            "Binaesa Blood", "Spinechiller Blood", "Ikaav Blood",
            "Falrazim's Gnashing", "Diregriffon's Bite", "Chimera Blood",
            "Turepta Blood", "Scorpion Venom", "Venom of the Snake",
        },
        ["ColdDot"] = {
            "Lazam's Chill", "Sylra Fris' Chill", "Endaroky's Chill",
            "Ekron's Chill", "Kirchen's Chill", "Edoth's Chill",
        },
        -- Swarm Pet
        ["SwarmPet"] = {
            "Shriek at the Moon", "Bellow at the Moon", "Bay at the Moon",
            "Roar at the Moon", "Cry at the Moon", "Yell at the Moon",
            "Scream at the Moon", "Shout at the Moon", "Yowl at the Moon",
            "Howl at the Moon", "Bark at the Moon", "Bestial Empathy",
        },
        ["Feralgia"] = {
            "SingleMalt's Feralgia", "Ander's Feralgia", "Griklor's Feralgia",
            "Akalit's Feralgia", "Krenk's Feralgia", "Kesar's Feralgia",
            "Yahnoa's Feralgia", "Tuzil's Feralgia", "Haergen's Feralgia",
        },
        -- Dicho
        ["DichoSpell"] = {
            "Reciprocal Fury", "Ecliptic Fury", "Composite Fury",
            "Dissident Fury", "Dichotomic Fury",
        },
        -- Slow
        ["SlowSpell"] = {
            "Sha's Reprisal", "Sha's Legacy", "Sha's Revenge",
            "Sha's Advantage", "Sha's Lethargy", "Drowsy",
        },
        -- Heals
        ["HealSpell"] = {
            "Thornhost's Mending", "Korah's Mending", "Bethun's Mending",
            "Deltro's Mending", "Sabhattin's Mending", "Jaerol's Mending",
            "Mending of the Izon", "Jorra's Mending", "Cadmael's Mending",
            "Daria's Mending", "Minohten Mending", "Muada's Mending",
            "Trushar's Mending", "Chloroblast", "Spirit Salve",
        },
        ["PetHealSpell"] = {
            "Salve of Homer", "Salve of Jaegir", "Salve of Tobart",
            "Salve of Artikla", "Salve of Clorith", "Salve of Blezon",
            "Salve of Yubai", "Salve of Sevna", "Salve of Reshan",
            "Salve of Feldan", "Healing of Uluanes", "Healing of Mikkily",
        },
        -- Pet
        ["PetSpell"] = {
            "Spirit of Shae", "Spirit of Panthea", "Spirit of Blizzent",
            "Spirit of Akalit", "Spirit of Avalit", "Spirit of Lachemit",
            "Spirit of Kolos", "Spirit of Averc", "Spirit of Hoshkar",
            "Spirit of Silverwing", "Spirit of Uluanes", "Spirit of Rashara",
        },
        -- Pet Buffs
        ["PetHaste"] = {
            "Insatiable Voracity", "Unsurpassed Velocity", "Astounding Velocity",
            "Tremendous Velocity", "Extraordinary Velocity", "Exceptional Velocity",
            "Incomparable Velocity", "Unrivaled Rapidity", "Peerless Penchant",
            "Unparalleled Voracity", "Growl of the Beast", "Arag's Celerity",
        },
        ["PetOffenseBuff"] = {
            "Magna's Aggression", "Panthea's Aggression", "Horasug's Aggression",
            "Virzak's Aggression", "Sekmoset's Aggression", "Plakt's Aggression",
            "Mea's Aggression", "Neivr's Aggression",
        },
        ["PetDefenseBuff"] = {
            "Magna's Protection", "Panthea's Protection", "Horasug's Protection",
            "Virzak's Protection", "Sekmoset's Protection", "Plakt's Protection",
            "Mea's Protection", "Neivr's Protection",
        },
        ["PetGrowl"] = {
            "Growl of the Clouded Leopard", "Growl of the Lioness",
            "Growl of the Sabretooth", "Growl of the Leopard",
            "Growl of the Snow Leopard", "Growl of the Lion",
            "Growl of the Tiger", "Growl of the Jaguar",
            "Growl of the Puma", "Growl of the Panther",
        },
        ["PetHealProc"] = {
            "Friendly Pet", "Bolstering Warder", "Empowering Warder",
            "Invigorating Warder", "Mending Warder", "Convivial Warder",
            "Sympathetic Warder", "Protective Warder",
        },
        ["PetDamageProc"] = {
            "Comrade's Unity", "Ally's Unity", "Spirit of Siver",
            "Spirit of Mandrikai", "Spirit of Beramos", "Spirit of Visoracius",
            "Spirit of Nak", "Spirit of Bale", "Spirit of Kron",
        },
        ["PetSlowProc"] = {
            "Deadlock Jaws", "Fellgrip Jaws", "Lockfang Jaws", "Steeltrap Jaws",
        },
        ["PetSpellGuard"] = {
            "Spellbreaker's Synergy", "Spellbreaker's Fortress",
            "Spellbreaker's Citadel", "Spellbreaker's Keep",
            "Spellbreaker's Palisade", "Spellbreaker's Ward",
        },
        ["PetGroupEndRegenProc"] = {
            "Sapping Bite", "Wearying Bite", "Depleting Bite",
            "Exhausting Bite", "Fatiguing Bite",
        },
        -- Unity Buff
        ["UnityBuff"] = {
            "Wildfang's Unity", "Chieftain's Unity", "Reclaimer's Unity",
            "Feralist's Unity", "Stormblood's Unity", "Spiritual Unity",
        },
        ["KillShotBuff"] = {
            "Killshot Buff",
        },
    },
}
