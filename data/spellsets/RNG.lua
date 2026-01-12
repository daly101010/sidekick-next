-- F:/lua/SideKick/data/spellsets/RNG.lua
-- Ranger Spellsets - Role-based spell loadouts with spell line definitions

return {
    roles = {
        dps = {
            name = "DPS Focused",
            gems = {
                [1] = { spellLine = "FocusedArrows", priority = 1 },
                [2] = { spellLine = "CalledShotsArrow", priority = 1 },
                [3] = { spellLine = "DichoSpell", priority = 1 },
                [4] = { spellLine = "SummerNuke", priority = 1 },
                [5] = { spellLine = "SwarmDot", priority = 2 },
                [6] = { spellLine = "ShortSwarmDot", priority = 2 },
                [7] = { spellLine = "AEArrows", priority = 2 },
                [8] = { spellLine = "Protectionbuff", priority = 3 },
                [9] = { spellLine = "ShoutBuff", priority = 3 },
            },
        },
        melee = {
            name = "Melee Focused",
            gems = {
                [1] = { spellLine = "FocusedBlades", priority = 1 },
                [2] = { spellLine = "AEBlades", priority = 1 },
                [3] = { spellLine = "ReflexSlashHeal", priority = 1 },
                [4] = { spellLine = "DichoSpell", priority = 1 },
                [5] = { spellLine = "SwarmDot", priority = 2 },
                [6] = { spellLine = "SummerNuke", priority = 2 },
                [7] = { spellLine = "AggroKick", priority = 2 },
                [8] = { spellLine = "Protectionbuff", priority = 3 },
                [9] = { spellLine = "ShoutBuff", priority = 3 },
            },
        },
        heal = {
            name = "Healer Support",
            gems = {
                [1] = { spellLine = "Heal", priority = 1 },
                [2] = { spellLine = "Fastheal", priority = 1 },
                [3] = { spellLine = "Totheal", priority = 1 },
                [4] = { spellLine = "RegenSpells", priority = 2 },
                [5] = { spellLine = "FocusedArrows", priority = 2 },
                [6] = { spellLine = "DichoSpell", priority = 2 },
                [7] = { spellLine = "SnareSpells", priority = 3 },
                [8] = { spellLine = "Protectionbuff", priority = 3 },
            },
        },
        tank = {
            name = "Tank Mode",
            gems = {
                [1] = { spellLine = "AggroKick", priority = 1 },
                [2] = { spellLine = "AgroBuff", priority = 1 },
                [3] = { spellLine = "ReflexSlashHeal", priority = 1 },
                [4] = { spellLine = "Heal", priority = 2 },
                [5] = { spellLine = "FocusedBlades", priority = 2 },
                [6] = { spellLine = "DichoSpell", priority = 2 },
                [7] = { spellLine = "Protectionbuff", priority = 3 },
                [8] = { spellLine = "SkinLike", priority = 3 },
            },
        },
    },
    spellLines = {
        -- Arrow attacks
        ["FocusedArrows"] = {
            "Focused Frenzy of Arrows", "Focused Storm of Arrows",
            "Focused Tempest of Arrows", "Focused Arrow Swarm",
            "Focused Rain of Arrows", "Focused Arrowrain",
            "Focused Arrowgale", "Focused Blizzard of Arrows",
            "Focused Whirlwind of Arrows",
        },
        ["CalledShotsArrow"] = {
            "Inevitable Shots", "Claimed Shots", "Marked Shots",
            "Foreseen Shots", "Anticipated Shots", "Forecasted Shots",
            "Announced Shots", "Called Shots",
        },
        ["AEArrows"] = {
            "AE Arrows",
        },
        ["ArrowOpener"] = {
            "Silent Shot", "Stealthy Shot", "Concealed Shot",
        },
        ["PullOpener"] = {
            "Heartspike", "Heartrip", "Heartrend", "Heartpierce", "Deadfall",
        },
        -- Blade attacks
        ["FocusedBlades"] = {
            "Focused Blades",
        },
        ["AEBlades"] = {
            "AE Blades",
        },
        ["ReflexSlashHeal"] = {
            "Reflexive Rimestrike", "Reflexive Frostreave",
            "Reflexive Hoarfrost", "Reflexive Rime",
        },
        -- Kicks
        ["AggroKick"] = {
            "Kick", "Roundhouse Kick",
        },
        ["JoltingKicks"] = {
            "Jolting Roundhouse Kicks", "Jolting Kicks",
        },
        -- Nukes
        ["SummerNuke"] = {
            "Summer's Deluge", "Summer's Torrent", "Summer's Viridity",
            "Summer's Mist", "Summer's Storm", "Summer's Squall",
            "Summer's Gale", "Summer's Cyclone", "Summer's Tempest",
            "Summer's Sleet",
        },
        ["Fireboon"] = {
            "Fireboon",
        },
        ["Firenuke"] = {
            "Fire Nuke",
        },
        ["Iceboon"] = {
            "Iceboon",
        },
        ["Icenuke"] = {
            "Ice Nuke",
        },
        -- DOTs
        ["SwarmDot"] = {
            "Hotaria Swarm", "Bloodbeetle Swarm", "Ice Burrower Swarm",
            "Bonecrawler Swarm", "Blisterbeetle Swarm", "Dreadbeetle Swarm",
            "Vespid Swarm", "Scarab Swarm", "Beetle Swarm", "Hornet Swarm",
            "Wasp Swarm", "Locust Swarm", "Drifting Death", "Fire Swarm",
            "Drones of Doom", "Swarm of Pain", "Stinging Swarm",
        },
        ["ShortSwarmDot"] = {
            "Swarm of Fernflies", "Swarm of Bloodflies", "Swarm of Hyperboreads",
            "Swarm of Glistenwings", "Swarm of Vespines", "Swarm of Sand Wasps",
            "Swarm of Hornets", "Swarm of Bees",
        },
        -- Dicho
        ["DichoSpell"] = {
            "Reciprocal Fusillade", "Ecliptic Fusillade", "Composite Fusillade",
            "Dissident Fusillade", "Dichotomic Fusillade",
        },
        -- Heals
        ["Heal"] = {
            "Desperate Mending", "Desperate Healing", "Chloroblast",
        },
        ["Fastheal"] = {
            "Fast Heal",
        },
        ["Totheal"] = {
            "ToT Heal",
        },
        ["RegenSpells"] = {
            "Regeneration", "Regrowth",
        },
        -- Buffs
        ["Protectionbuff"] = {
            "Protection of the Valley", "Protection of the Wakening Land",
            "Protection of the Woodlands", "Protection of the Forest",
            "Protection of the Bosque", "Protection of the Copse",
            "Protection of the Vale", "Protection of the Paw",
            "Protection of the Kirkoten", "Protection of the Minohten",
            "Protection of the Wild", "Warder's Protection", "Force of Nature",
        },
        ["ShoutBuff"] = {
            "Shout of the Dusksage Stalker", "Shout of the Arbor Stalker",
            "Shout of the Wildstalker", "Shout of the Copsestalker",
            "Shout of the Bosquestalker", "Shout of the Predator",
        },
        ["AgroBuff"] = {
            "Devastating Steel", "Devastating Swords", "Devastating Impact",
            "Devastating Slashes", "Devastating Edges", "Devastating Blades",
        },
        ["AgroReducerBuff"] = {
            "Aggro Reducer",
        },
        ["ParryProcBuff"] = {
            "Parry Proc",
        },
        ["Eyes"] = {
            "Eyes",
        },
        ["GroupStrengthBuff"] = {
            "Group Strength",
        },
        ["GroupPredatorBuff"] = {
            "Group Predator",
        },
        ["GroupEnrichmentBuff"] = {
            "Group Enrichment",
        },
        ["Hunt"] = {
            "Hunt",
        },
        ["Cloak"] = {
            "Cloak",
        },
        ["Veil"] = {
            "Veil",
        },
        ["SkinLike"] = {
            "Skin Like",
        },
        ["DsBuff"] = {
            "DS Buff",
        },
        ["Coat"] = {
            "Coat",
        },
        ["Mask"] = {
            "Mask",
        },
        ["Rathe"] = {
            "Rathe",
        },
        -- Snare
        ["SnareSpells"] = {
            "Ensnare", "Snare",
        },
        -- Movement
        ["MoveSpells"] = {
            "Spirit of Wolf",
        },
        -- Unity
        ["UnityBuff"] = {
            "Bosquetender's Unity", "Copsestalker's Unity", "Wildstalker's Unity",
        },
        -- Alliance
        ["Alliance"] = {
            "Alliance",
        },
    },
}
