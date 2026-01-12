-- F:/lua/SideKick/data/spellsets/NEC.lua
-- Necromancer Spellsets - Role-based spell loadouts with spell line definitions

return {
    roles = {
        dps = {
            name = "DPS Focused",
            gems = {
                [1] = { spellLine = "FireDot1", priority = 1 },
                [2] = { spellLine = "FireDot2", priority = 1 },
                [3] = { spellLine = "FireDot4", priority = 1 },
                [4] = { spellLine = "Magic2", priority = 1 },
                [5] = { spellLine = "PoisonNuke1", priority = 2 },
                [6] = { spellLine = "DichoSpell", priority = 2 },
                [7] = { spellLine = "SwarmPet", priority = 2 },
                [8] = { spellLine = "HealthTaps", priority = 3 },
                [9] = { spellLine = "DurationTap", priority = 3 },
            },
        },
        dot = {
            name = "DOT Heavy",
            gems = {
                [1] = { spellLine = "FireDot1", priority = 1 },
                [2] = { spellLine = "FireDot2", priority = 1 },
                [3] = { spellLine = "FireDot3", priority = 1 },
                [4] = { spellLine = "FireDot4", priority = 1 },
                [5] = { spellLine = "Magic1", priority = 2 },
                [6] = { spellLine = "Magic2", priority = 2 },
                [7] = { spellLine = "Magic3", priority = 2 },
                [8] = { spellLine = "DurationTap", priority = 3 },
                [9] = { spellLine = "HealthTaps", priority = 3 },
            },
        },
        utility = {
            name = "Utility/Pet",
            gems = {
                [1] = { spellLine = "HealthTaps", priority = 1 },
                [2] = { spellLine = "DurationTap", priority = 1 },
                [3] = { spellLine = "GroupLeech", priority = 1 },
                [4] = { spellLine = "FireDot2", priority = 2 },
                [5] = { spellLine = "Magic2", priority = 2 },
                [6] = { spellLine = "SwarmPet", priority = 2 },
                [7] = { spellLine = "SelfRune1", priority = 3 },
                [8] = { spellLine = "SelfHPBuff", priority = 3 },
            },
        },
    },
    spellLines = {
        -- Fire DOTs
        ["FireDot1"] = {
            "Raging Shadow", "Scalding Shadow", "Broiling Shadow",
            "Burning Shadow", "Smouldering Shadow", "Coruscating Shadow",
            "Blazing Shadow", "Blistering Shadow", "Scorching Shadow", "Searing Shadow",
        },
        ["FireDot2"] = {
            "Pyre of Illandrin", "Pyre of Va Xakra", "Pyre of Klraggek",
            "Pyre of the Shadewarden", "Pyre of Jorobb", "Pyre of Marnek",
            "Pyre of Hazarak", "Pyre of Nos", "Soul Reaper's Pyre",
            "Reaver's Pyre", "Ashengate Pyre", "Dread Pyre", "Night Fire",
            "Funeral Pyre of Kelador", "Pyrocruor", "Ignite Blood",
        },
        ["FireDot3"] = {
            "Arcanaforged's Flashblaze", "Thall Va Kelun's Flashblaze",
            "Otatomik's Flashblaze", "Azeron's Flashblaze", "Mazub's Flashblaze",
            "Osalur's Flashblaze", "Brimtav's Flashblaze", "Tenak's Flashblaze",
        },
        ["FireDot4"] = {
            "Pyre of the Abandoned", "Pyre of the Neglected", "Pyre of the Wretched",
            "Pyre of the Fereth", "Pyre of the Lost", "Pyre of the Forsaken",
            "Pyre of the Piq'a", "Pyre of the Bereft", "Pyre of the Forgotten",
            "Pyre of the Lifeless", "Pyre of the Fallen",
        },
        -- Magic DOTs
        ["Magic1"] = {
            "Putrefying Wounds", "Infected Wounds", "Septic Wounds",
            "Cytotoxic Wounds", "Mortiferous Wounds", "Pernicious Wounds",
            "Necrotizing Wounds", "Splirt", "Splart", "Splort", "Splurt",
        },
        ["Magic2"] = {
            "Extermination", "Extinction", "Oblivion", "Inevitable End",
            "Annihilation", "Termination", "Doom", "Demise", "Mortal Coil",
            "Anathema of Life", "Curse of Mortality", "Ancient: Curse of Mori",
            "Dark Nightmare", "Horror",
        },
        ["Magic3"] = {
            "Extermination", "Extinction", "Oblivion", "Inevitable End",
        },
        -- Poison Nukes
        ["PoisonNuke1"] = {
            "Necrotizing Venin", "Embalming Venin", "Searing Venin",
            "Effluvial Venin", "Liquefying Venin", "Dissolving Venin",
            "Blighted Venin", "Withering Venin", "Ruinous Venin", "Venin",
            "Acikin", "Neurotoxin", "Torbas' Venom Blast",
        },
        ["PoisonNuke2"] = {
            "Decree for Blood", "Proclamation for Blood", "Assert for Blood",
            "Refute for Blood", "Impose for Blood", "Impel for Blood",
            "Provocation for Blood", "Compel for Blood", "Exigency for Blood",
        },
        -- Lifetaps
        ["HealthTaps"] = {
            "Soullash", "Extort Essence", "Soulflay", "Maraud Essence",
            "Soulgouge", "Draw Essence", "Soulsiphon", "Consume Essence",
            "Soulrend", "Hemorrhage Essence", "Plunder Essence", "Bleed Essence",
            "Divert Essence", "Drain Essence", "Siphon Essence", "Drain Life",
            "Soulspike", "Touch of Mujaki", "Touch of Night",
        },
        ["DurationTap"] = {
            "Helmsbane's Grasp", "The Protector's Grasp", "Tserrina's Grasp",
            "Bomoda's Grasp", "Plexipharia's Grasp", "Halstor's Grasp",
            "Ivrikdal's Grasp", "Arachne's Grasp", "Fellid's Grasp",
            "Visziaj's Grasp", "Dyn`leth's Grasp", "Fang of Death",
            "Night's Beckon", "Saryrn's Kiss", "Vexing Mordinia",
        },
        ["GroupLeech"] = {
            "Ghastly Leech", "Twilight Leech", "Frozen Leech",
            "Ashen Leech", "Dark Leech", "Leech",
        },
        -- Swarm Pet
        ["SwarmPet"] = {
            "Call Ravening Skeleton", "Call Roiling Skeleton",
            "Call Riotous Skeleton", "Call Reckless Skeleton",
            "Call Remorseless Skeleton", "Call Relentless Skeleton",
            "Call Ruthless Skeleton", "Call Ruinous Skeleton",
            "Call Rumbling Skeleton", "Call Skeleton Thrall",
        },
        -- Dicho
        ["DichoSpell"] = {
            "Reciprocal Paroxysm", "Ecliptic Paroxysm", "Composite Paroxysm",
            "Dissident Paroxysm", "Dichotomic Paroxysm",
        },
        -- Self Buffs
        ["SelfHPBuff"] = {
            "Shield of Memories", "Shield of Shadow", "Shield of Restless Ice",
            "Shield of Scales", "Shield of the Pellarus", "Shield of the Dauntless",
            "Shield of Bronze", "Shield of Dreams", "Shield of the Void",
            "Bulwark of the Crystalwing", "Shield of the Crystalwing",
        },
        ["SelfRune1"] = {
            "Golemskin", "Carrion Skin", "Frozen Skin", "Ashen Skin",
            "Deadskin", "Zombieskin", "Ghoulskin", "Grimskin",
            "Corpseskin", "Shadowskin", "Wraithskin",
        },
        ["SelfSpellShield1"] = {
            "Shield of Inescapability", "Shield of Inevitability",
            "Shield of Destiny", "Shield of Order",
            "Shield of Consequence", "Shield of Fate",
        },
        -- Charm (Undead only)
        ["CharmSpell"] = {
            "Enslave Death", "Thrall of Bones", "Cajole Undead",
            "Beguile Undead", "Dominate Undead",
        },
        -- Fear (alternative CC - not true mez, mobs run around)
        ["FearSpell"] = {
            "Dread Gaze", "Invoke Fear", "Chase the Moon", "Fear",
            "Spook the Dead", -- undead only fear
        },
        -- Screaming Terror (PBAE Fear)
        ["ScreamingTerror"] = {
            "Screaming Terror",
        },
        -- FD
        ["FDSpell"] = {
            "Death Peace",
        },
        -- Alliance
        ["AllianceSpell"] = {
            "Malevolent Covariance", "Malevolent Conjunction",
            "Malevolent Coalition", "Malevolent Covenant", "Malevolent Alliance",
        },
    },
}
