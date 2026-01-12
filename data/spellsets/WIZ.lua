-- F:/lua/SideKick/data/spellsets/WIZ.lua
-- Wizard Spellsets - Role-based spell loadouts with spell line definitions

return {
    roles = {
        dps = {
            name = "DPS Focused",
            gems = {
                [1] = { spellLine = "FireEtherealNuke", priority = 1 },
                [2] = { spellLine = "IceEtherealNuke", priority = 1 },
                [3] = { spellLine = "FireClaw", priority = 1 },
                [4] = { spellLine = "IceClaw", priority = 1 },
                [5] = { spellLine = "CloudburstNuke", priority = 2 },
                [6] = { spellLine = "VortexNuke", priority = 2 },
                [7] = { spellLine = "FuseNuke", priority = 2 },
                [8] = { spellLine = "DichoSpell", priority = 3 },
                [9] = { spellLine = "ChaosNuke", priority = 3 },
            },
        },
        fire = {
            name = "Fire Focused",
            gems = {
                [1] = { spellLine = "FireEtherealNuke", priority = 1 },
                [2] = { spellLine = "FireClaw", priority = 1 },
                [3] = { spellLine = "FireNuke", priority = 1 },
                [4] = { spellLine = "ChaosNuke", priority = 1 },
                [5] = { spellLine = "DichoSpell", priority = 2 },
                [6] = { spellLine = "VortexNuke", priority = 2 },
                [7] = { spellLine = "FuseNuke", priority = 2 },
                [8] = { spellLine = "WildNuke", priority = 3 },
                [9] = { spellLine = "GambitSpell", priority = 3 },
            },
        },
        ice = {
            name = "Ice Focused",
            gems = {
                [1] = { spellLine = "IceEtherealNuke", priority = 1 },
                [2] = { spellLine = "IceClaw", priority = 1 },
                [3] = { spellLine = "IceNuke", priority = 1 },
                [4] = { spellLine = "CloudburstNuke", priority = 1 },
                [5] = { spellLine = "DichoSpell", priority = 2 },
                [6] = { spellLine = "VortexNuke", priority = 2 },
                [7] = { spellLine = "FuseNuke", priority = 2 },
                [8] = { spellLine = "WildNuke", priority = 3 },
                [9] = { spellLine = "GambitSpell", priority = 3 },
            },
        },
        magic = {
            name = "Magic Focused",
            gems = {
                [1] = { spellLine = "MagicEtherealNuke", priority = 1 },
                [2] = { spellLine = "MagicClaw", priority = 1 },
                [3] = { spellLine = "MagicNuke", priority = 1 },
                [4] = { spellLine = "CloudburstNuke", priority = 1 },
                [5] = { spellLine = "DichoSpell", priority = 2 },
                [6] = { spellLine = "VortexNuke", priority = 2 },
                [7] = { spellLine = "FuseNuke", priority = 2 },
                [8] = { spellLine = "WildNuke", priority = 3 },
                [9] = { spellLine = "StunSpell", priority = 3 },
            },
        },
    },
    spellLines = {
        -- Claw spells (fast cast)
        ["IceClaw"] = {
            "Claw of the Void", "Claw of Gozzrem", "Claw of Travenro",
            "Claw of the Oceanlord", "Claw of the Icewing", "Claw of the Abyss",
            "Glacial Claw", "Claw of Selig", "Claw of Selay", "Claw of Vox",
            "Claw of Frost", "Claw of Ankexfen",
        },
        ["FireClaw"] = {
            "Claw of Ingot", "Claw of the Duskflame", "Claw of Sontalak",
            "Claw of Qunard", "Claw of the Flameweaver", "Claw of the Flamewing",
            "Villification of Havoc", "Denunciation of Havoc", "Malediction of Havoc",
        },
        ["MagicClaw"] = {
            "Claw of Itzal", "Claw of Feshlak", "Claw of Ellarr",
            "Claw of the Indagatori", "Claw of the Ashwing", "Claw of the Battleforged",
        },
        -- Ethereal nukes (high damage)
        ["FireEtherealNuke"] = {
            "Ethereal Immolation", "Ethereal Ignition", "Ethereal Brand",
            "Ethereal Skyfire", "Ethereal Skyblaze", "Ethereal Incandescence",
            "Ethereal Blaze", "Ethereal Inferno", "Ethereal Combustion",
            "Ethereal Incineration", "Ethereal Conflagration", "Ether Flame",
        },
        ["IceEtherealNuke"] = {
            "Lunar Ice Comet", "Restless Ice Comet", "Ethereal Icefloe",
            "Ethereal Rimeblast", "Ethereal Hoarfrost", "Ethereal Frost",
            "Ethereal Glaciation", "Ethereal Iceblight", "Ethereal Rime",
            "Ethereal Freeze",
        },
        ["MagicEtherealNuke"] = {
            "Ethereal Mortar", "Ethereal Blast", "Ethereal Volley",
            "Ethereal Flash", "Ethereal Salvo", "Ethereal Barrage", "Ethereal Blitz",
        },
        -- Element nukes
        ["FireNuke"] = {
            "Kindleheart's Fire", "The Diabo's Fire", "Dagarn's Fire",
            "Dragoflux's Fire", "Narendi's Fire", "Gosik's Fire",
            "Daevan's Fire", "Lithara's Fire", "Klixcxyk's Fire",
            "Inizen's Fire", "Sothgar's Flame",
        },
        ["IceNuke"] = {
            "Glacial Ice Cascade", "Tundra Ice Cascade", "Restless Ice Cascade",
            "Icefloe Cascade", "Rimeblast Cascade", "Hoarfrost Cascade",
            "Rime Cascade", "Glacial Cascade", "Icesheet Cascade",
            "Glacial Collapse", "Icefall Avalanche",
        },
        ["MagicNuke"] = {
            "Lightning Cyclone", "Lightning Maelstrom", "Lightning Roar",
            "Lightning Tempest", "Lightning Storm", "Lightning Squall",
            "Lightning Swarm", "Lightning Helix", "Ribbon Lightning",
            "Rolling Lightning", "Ball Lightning",
        },
        -- Vortex (resist debuff)
        ["VortexNuke"] = {
            "Chromospheric Vortex", "Shadebright Vortex", "Thaumaturgic Vortex",
            "Stormjolt Vortex", "Shocking Vortex", "Hoarfrost Vortex",
            "Ether Vortex", "Incandescent Vortex", "Frost Vortex",
            "Power Vortex", "Flame Vortex", "Ice Vortex", "Mana Vortex",
        },
        -- Cloudburst
        ["CloudburstNuke"] = {
            "Cloudburst Lightningstrike", "Cloudburst Joltstrike",
            "Cloudburst Stormbolt", "Cloudburst Thunderbolt",
            "Cloudburst Stormstrike", "Cloudburst Tempest",
            "Cloudburst Storm", "Cloudburst Levin", "Cloudburst Bolts",
        },
        -- Fuse (combo nuke)
        ["FuseNuke"] = {
            "Ethereal Twist", "Ethereal Confluence", "Ethereal Braid",
            "Ethereal Fuse", "Ethereal Weave", "Ethereal Plait",
        },
        -- Chaos
        ["ChaosNuke"] = {
            "Chaos Flame", "Chaos Inferno", "Chaos Burn", "Chaos Scintillation",
            "Chaos Incandescence", "Chaos Blaze", "Chaos Char",
            "Chaos Combustion", "Chaos Conflagration", "Chaos Immolation",
        },
        -- Wild
        ["WildNuke"] = {
            "Wildspell Strike", "Wildflame Strike", "Wildscorch Strike",
            "Wildflash Strike", "Wildflash Barrage", "Wildether Barrage",
            "Wildspark Barrage", "Wildmana Barrage", "Wildmagic Blast",
            "Wildmagic Burst", "Wildmagic Strike",
        },
        -- Dicho
        ["DichoSpell"] = {
            "Reciprocal Fire", "Ecliptic Fire", "Composite Fire",
            "Dissident Fire", "Dichotomic Fire",
        },
        -- Stun
        ["StunSpell"] = {
            "Teladaka", "Teladaja", "Telajaga", "Telanata", "Telanara",
            "Telanaga", "Telanama", "Telakama", "Telajara", "Telajasz",
            "Telakisz", "Telekara", "Telaka", "Telekin",
        },
        -- Gambit (mana regen)
        ["GambitSpell"] = {
            "Contemplative Gambit", "Anodyne Gambit", "Idyllic Gambit",
            "Musing Gambit", "Quiescent Gambit", "Bucolic Gambit",
        },
        -- Self buffs
        ["SelfHPBuff"] = {
            "Shield of Memories", "Shield of Shadow", "Shield of Restless Ice",
            "Shield of Scales", "Shield of the Pellarus", "Shield of the Dauntless",
            "Shield of Bronze", "Shield of Dreams", "Shield of the Void",
            "Bulwark of the Crystalwing", "Shield of the Crystalwing",
        },
        ["SelfRune1"] = {
            "Aegis of Remembrance", "Aegis of the Umbra",
            "Aegis of the Crystalwing", "Armor of Wirn", "Armor of the Codex",
            "Armor of the Stonescale", "Armor of the Crystalwing",
            "Dermis of the Crystalwing", "Squamae of the Crystalwing",
        },
        ["SelfSpellShield1"] = {
            "Shield of Inescapability", "Shield of Inevitability",
            "Shield of Destiny", "Shield of Order",
            "Shield of Consequence", "Shield of Fate",
        },
        -- Familiar
        ["FamiliarBuff"] = {
            "Greater Familiar", "Familiar", "Lesser Familiar", "Minor Familiar",
        },
        -- Twincast
        ["TwincastSpell"] = {
            "Twincast",
        },
        -- Pet
        ["PetSpell"] = {
            "Kindleheart's Pyroblade", "Diabo Xi Fer's Pyroblade",
            "Ricartine's Pyroblade", "Virnax's Pyroblade", "Yulin's Pyroblade",
            "Mul's Pyroblade", "Burnmaster's Pyroblade", "Lithara's Pyroblade",
            "Daveron's Pyroblade", "Euthanos' Flameblade",
        },
        -- Utility
        ["RootSpell"] = {
            "Greater Fetter", "Fetter", "Paralyzing Earth", "Immobilize", "Root",
        },
        ["SnareSpell"] = {
            "Atol's Concussive Shackles", "Atol's Spectral Shackles", "Bonds of Force",
        },
        -- Alliance
        ["AllianceSpell"] = {
            "Frostbound Covariance", "Frostbound Conjunction",
            "Frostbound Coalition", "Frostbound Covenant", "Frostbound Alliance",
        },
    },
}
