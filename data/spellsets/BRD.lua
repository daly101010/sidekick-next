-- F:/lua/SideKick/data/spellsets/BRD.lua
-- Bard Spellsets - Role-based song loadouts with spell line definitions

return {
    roles = {
        dps = {
            name = "DPS Focused",
            gems = {
                [1] = { spellLine = "WarMarchSong", priority = 1 },
                [2] = { spellLine = "MainAriaSong", priority = 1 },
                [3] = { spellLine = "ArcaneSong", priority = 1 },
                [4] = { spellLine = "InsultSong", priority = 2 },
                [5] = { spellLine = "DichoSong", priority = 2 },
                [6] = { spellLine = "SufferingSong", priority = 2 },
                [7] = { spellLine = "MezSong", priority = 3 },
                [8] = { spellLine = "SlowSong", priority = 3 },
            },
        },
        cc = {
            name = "Crowd Control",
            gems = {
                [1] = { spellLine = "MezSong", priority = 1 },
                [2] = { spellLine = "MezAESong", priority = 1 },
                [3] = { spellLine = "SlowSong", priority = 1 },
                [4] = { spellLine = "AESlowSong", priority = 2 },
                [5] = { spellLine = "WarMarchSong", priority = 2 },
                [6] = { spellLine = "MainAriaSong", priority = 2 },
                [7] = { spellLine = "GroupRegenSong", priority = 3 },
                [8] = { spellLine = "CrescendoSong", priority = 3 },
            },
        },
        support = {
            name = "Support/Regen",
            gems = {
                [1] = { spellLine = "WarMarchSong", priority = 1 },
                [2] = { spellLine = "MainAriaSong", priority = 1 },
                [3] = { spellLine = "GroupRegenSong", priority = 1 },
                [4] = { spellLine = "CrescendoSong", priority = 1 },
                [5] = { spellLine = "ArcaneSong", priority = 2 },
                [6] = { spellLine = "AccelerandoSong", priority = 2 },
                [7] = { spellLine = "MezSong", priority = 3 },
                [8] = { spellLine = "SlowSong", priority = 3 },
            },
        },
    },
    spellLines = {
        -- Single target mez
        ["MezSong"] = {
            "Slumber of Suja", "Slumber of the Diabo", "Slumber of Zburator",
            "Slumber of Jembel", "Slumber of Silisia", "Slumber of Motlak",
            "Slumber of Kolain", "Slumber of Sionachie", "Slumber of the Mindshear",
            "Serenity of Oceangreen", "Amber's Last Lullaby", "Queen Eletyl's Screech",
            "Command of Queen Veneneu", "Aelfric's Last Lullaby", "Vulka's Lullaby",
            "Creeping Dreams", "Luvwen's Lullaby", "Lullaby of Morell",
            "Dreams of Terris", "Dreams of Thule", "Dreams of Ayonae",
            "Song of Twilight", "Sionachie's Dreams", "Crission's Pixie Strike",
            "Kelin's Lucid Lullaby",
        },
        -- PBAE mez
        ["MezAESong"] = {
            "Wave of Stupor", "Wave of Nocturn", "Wave of Sleep",
            "Wave of Somnolence", "Wave of Torpor", "Wave of Quietude",
            "Wave of the Conductor", "Wave of Dreams", "Wave of Slumber",
        },
        -- Slow
        ["SlowSong"] = {
            "Requiem of Time", "Angstlich's Assonance", "Largo's Assonant Binding",
            "Selo's Consonant Chain",
        },
        -- AE Slow
        ["AESlowSong"] = {
            "Zinnia's Melodic Binding", "Radiwol's Melodic Binding",
            "Dekloaz's Melodic Binding", "Protan's Melodic Binding",
            "Largo's Melodic Binding",
        },
        -- War March (melee haste/ds/str/atk)
        ["WarMarchSong"] = {
            "War March of Nokk", "War March of Centien Xi Va Xakra",
            "War March of Radiwol", "War March of Dekloaz",
            "War March of Jocelyn", "War March of Protan",
            "War March of Illdaera", "War March of Dagda",
            "War March of Brekt", "War March of Meldrath",
            "War March of Muram", "War March of the Mastruq",
            "Warsong of Zek", "McVaxius' Rousing Rondo",
            "Vilia's Chorus of Celerity", "Verses of Victory",
            "McVaxius' Berserker Crescendo", "Vilia's Verses of Celerity",
            "Anthem de Arms",
        },
        -- Main Aria (spell damage focus/haste v3)
        ["MainAriaSong"] = {
            "Aria of Tenisbre", "Aria of Pli Xin Liako", "Aria of Margidor",
            "Aria of Begalru", "Aria of Maetanrus", "Aria of Va'Ker",
            "Aria of the Orator", "Aria of the Composer", "Aria of the Poet",
            "Performer's Psalm of Pyrotechnics", "Ancient: Call of Power",
            "Aria of the Artist", "Yelhun's Mystic Call", "Eriki's Psalm of Power",
            "Echo of the Trusik", "Rizlona's Call of Flame",
            "Rizlona's Fire", "Rizlona's Embers",
        },
        -- Arcane Song (group melee/spell proc)
        ["ArcaneSong"] = {
            "Arcane Rhythm", "Arcane Harmony", "Arcane Symphony",
            "Arcane Ballad", "Arcane Melody", "Arcane Hymn",
            "Arcane Address", "Arcane Chorus", "Arcane Arietta",
            "Arcane Anthem", "Arcane Aria",
        },
        -- Insult (single target DD)
        ["InsultSong"] = {
            "Yaran's Disdain", "Eoreg's Insult", "Sogran's Insult",
            "Yelinak's Insult", "Sathir's Insult", "Tsaph's Insult",
            "Garath's Insult", "Hykast's Insult", "Lyrin's Insult",
            "Venimor's Insult",
        },
        -- Dicho
        ["DichoSong"] = {
            "Reciprocal Psalm", "Ecliptic Psalm", "Composite Psalm",
            "Dissident Psalm", "Dichotomic Psalm",
        },
        -- Suffering (melee proc with aggro reduction)
        ["SufferingSong"] = {
            "Kanghammer's Song of Suffering", "Shojralen's Song of Suffering",
            "Omorden's Song of Suffering", "Travenro's Song of Suffering",
            "Fjilnauk's Song of Suffering", "Kaficus' Song of Suffering",
            "Hykast's Song of Suffering", "Noira's Song of Suffering",
        },
        -- Group Regen
        ["GroupRegenSong"] = {
            "Pulse of August", "Pulse of Nikolas", "Pulse of Vhal`Sera",
            "Pulse of Xigam", "Pulse of Sionachie", "Pulse of Salarra",
            "Pulse of Lunanyn", "Pulse of Renewal", "Cantata of Rodcet",
            "Cantata of Restoration", "Erollisi's Cantata", "Cantata of Life",
            "Wind of Marr", "Cantata of Replenishment", "Cantata of Soothing",
            "Cassindra's Chorus of Clarity", "Cassindra's Chant of Clarity",
            "Hymn of Restoration",
        },
        -- Crescendo (group hp/mana)
        ["CrescendoSong"] = {
            "Regar's Lively Crescendo", "Zelinstein's Lively Crescendo",
            "Zburator's Lively Crescendo", "Jembel's Lively Crescendo",
            "Silisia's Lively Crescendo", "Motlak's Lively Crescendo",
            "Kolain's Lively Crescendo", "Lyssa's Lively Crescendo",
            "Gruber's Lively Crescendo", "Kaerra's Spirited Crescendo",
            "Veshma's Lively Crescendo",
        },
        -- Accelerando (reduce beneficial spell casttime)
        ["AccelerandoSong"] = {
            "Appeasing Accelerando", "Satisfying Accelerando",
            "Placating Accelerando", "Atoning Accelerando",
            "Allaying Accelerando", "Ameliorating Accelerando",
            "Assuaging Accelerando", "Alleviating Accelerando",
        },
        -- Run speed buff
        ["RunBuff"] = {
            "Selo's Accelerating Chorus", "Selo's Accelerato", "Selo's Accelerando",
        },
        -- DPS Aura
        ["DPSAura"] = {
            "Aura of Tenisbre", "Aura of Pli Xin Liako", "Aura of Margidor",
            "Aura of Begalru", "Aura of Maetanrus", "Aura of Va'Ker",
            "Aura of the Orator", "Aura of the Composer", "Aura of the Poet",
            "Aura of the Artist", "Aura of the Muse", "Aura of Insight",
        },
        -- Regen Aura
        ["RegenAura"] = {
            "Aura of Shalowain", "Aura of Shei Vinitras", "Aura of Vhal`Sera",
            "Aura of Xigam", "Aura of Sionachie", "Aura of Salarra",
            "Aura of Lunanyn", "Aura of Renewal", "Aura of Rodcet",
        },
    },
}
