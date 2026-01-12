-- F:/lua/SideKick/data/spellsets/SHM.lua
-- Shaman Spellsets - Role-based spell loadouts with spell line definitions

return {
    roles = {
        heal = {
            name = "Healing Focused",
            gems = {
                [1] = { spellLine = "RecklessHeal1", priority = 1 },
                [2] = { spellLine = "RecklessHeal2", priority = 1 },
                [3] = { spellLine = "RecourseHeal", priority = 1 },
                [4] = { spellLine = "InterventionHeal", priority = 1 },
                [5] = { spellLine = "GroupRenewalHoT", priority = 2 },
                [6] = { spellLine = "SlowSpell", priority = 2 },
                [7] = { spellLine = "MaloSpell", priority = 2 },
                [8] = { spellLine = "CanniSpell", priority = 3 },
                [9] = { spellLine = "WardBuff", priority = 3 },
            },
        },
        hybrid = {
            name = "Hybrid DPS/Heal",
            gems = {
                [1] = { spellLine = "RecklessHeal1", priority = 1 },
                [2] = { spellLine = "RecourseHeal", priority = 1 },
                [3] = { spellLine = "DichoSpell", priority = 1 },
                [4] = { spellLine = "SlowSpell", priority = 1 },
                [5] = { spellLine = "MaloSpell", priority = 2 },
                [6] = { spellLine = "GroupRenewalHoT", priority = 2 },
                [7] = { spellLine = "CanniSpell", priority = 2 },
                [8] = { spellLine = "MeleeProcBuff", priority = 3 },
                [9] = { spellLine = "SlowProcBuff", priority = 3 },
            },
        },
        buff = {
            name = "Buff/Support",
            gems = {
                [1] = { spellLine = "GroupFocusSpell", priority = 1 },
                [2] = { spellLine = "TempHPBuff", priority = 1 },
                [3] = { spellLine = "RecklessHeal1", priority = 1 },
                [4] = { spellLine = "SlowSpell", priority = 2 },
                [5] = { spellLine = "MaloSpell", priority = 2 },
                [6] = { spellLine = "MeleeProcBuff", priority = 2 },
                [7] = { spellLine = "SlowProcBuff", priority = 3 },
                [8] = { spellLine = "CanniSpell", priority = 3 },
            },
        },
    },
    spellLines = {
        -- Heals (Reckless line)
        ["RecklessHeal1"] = {
            "Reckless Reinvigoration", "Reckless Resurgence", "Reckless Renewal",
            "Reckless Rejuvenation", "Reckless Regeneration", "Reckless Restoration",
            "Reckless Remedy", "Reckless Mending", "Qirik's Mending",
            "Dannal's Mending", "Gemmi's Mending", "Ahnkaul's Mending",
            "Ancient: Wilslik's Mending", "Yoppa's Mending", "Daluda's Mending",
            "Tnarg's Mending", "Chloroblast", "Superior Healing",
        },
        ["RecklessHeal2"] = {
            "Reckless Reinvigoration", "Reckless Resurgence", "Reckless Renewal",
            "Reckless Rejuvenation", "Reckless Regeneration", "Reckless Restoration",
            "Reckless Remedy", "Reckless Mending", "Qirik's Mending",
        },
        ["RecourseHeal"] = {
            "Grayleaf's Recourse", "Rowain's Recourse", "Zrelik's Recourse",
            "Eyrzekla's Recourse", "Krasir's Recourse", "Blezon's Recourse",
            "Gotikan's Recourse", "Qirik's Recourse",
        },
        ["InterventionHeal"] = {
            "Immortal Intervention", "Primordial Intervention",
            "Prehistoric Intervention", "Historian's Intervention",
            "Antecessor's Intervention", "Progenitor's Intervention",
            "Ascendant's Intervention", "Antecedent's Intervention",
            "Ancestral Intervention", "Antediluvian Intervention",
        },
        ["AESpiritualHeal"] = {
            "Spiritual Shower", "Spiritual Squall", "Spiritual Swell", "Spiritual Surge",
        },
        -- HoT
        ["GroupRenewalHoT"] = {
            "Reverie of Renewal", "Spirit of Renewal", "Spectre of Renewal",
            "Cloud of Renewal", "Shear of Renewal", "Wisp of Renewal",
            "Phantom of Renewal", "Penumbra of Renewal", "Shadow of Renewal",
            "Shade of Renewal", "Specter of Renewal", "Ghost of Renewal",
            "Spiritual Serenity", "Breath of Trushar", "Quiescence", "Torpor",
        },
        -- Ward
        ["WardBuff"] = {
            "Ward of Heroic Deeds", "Ward of Recuperation", "Ward of Remediation",
            "Ward of Regeneration", "Ward of Rejuvenation", "Ward of Reconstruction",
            "Ward of Recovery", "Ward of Restoration", "Ward of Resurgence",
        },
        -- Slow
        ["SlowSpell"] = {
            "Balance of Discord", "Balance of the Nihil", "Turgur's Insects",
            "Togor's Insects", "Tagar's Insects",
        },
        ["AESlowSpell"] = {
            "Tigir's Insects",
        },
        ["DiseaseSlow"] = {
            "Cloud of Grummus", "Plague of Insects",
        },
        -- Malo
        ["MaloSpell"] = {
            "Malosinera", "Malosinetra", "Malosinise", "Malos", "Malosinia",
            "Malo", "Malosini", "Malosi", "Malaisement", "Malaise",
        },
        ["AEMaloSpell"] = {
            "Wind of Malisene", "Wind of Malis",
        },
        -- Canni
        ["CanniSpell"] = {
            "Hoary Agreement", "Ancient Bargain", "Tribal Bargain", "Tribal Pact",
            "Ancestral Pact", "Ancestral Arrangement", "Ancestral Covenant",
        },
        -- Dicho
        ["DichoSpell"] = {
            "Reciprocal Roar", "Ecliptic Roar", "Composite Roar",
            "Dissident Roar", "Roar of the Lion",
        },
        -- Buffs
        ["GroupFocusSpell"] = {
            "Talisman of the Heroic", "Talisman of the Usurper",
            "Talisman of the Ry'Gorr", "Talisman of the Wulthan",
            "Talisman of the Doomscale", "Talisman of the Courageous",
            "Talisman of Kolos' Unity", "Talisman of Soul's Unity",
            "Talisman of Unity", "Talisman of the Bloodworg",
            "Talisman of the Dire", "Talisman of Wunshi",
        },
        ["TempHPBuff"] = {
            "Overwhelming Growth", "Fervent Growth", "Frenzied Growth",
            "Savage Growth", "Ferocious Growth", "Rampant Growth",
            "Unfettered Growth", "Untamed Growth", "Wild Growth",
        },
        ["MeleeProcBuff"] = {
            "Talisman of the Manul", "Talisman of the Kerran",
            "Talisman of the Lioness", "Talisman of the Sabretooth",
            "Talisman of the Leopard", "Talisman of the Snow Leopard",
            "Talisman of the Lion", "Talisman of the Tiger",
            "Talisman of the Lynx", "Talisman of the Cougar",
            "Talisman of the Panther", "Spirit of the Panther",
        },
        ["SlowProcBuff"] = {
            "Moroseness", "Melancholy", "Ennui", "Incapacity", "Sluggishness",
            "Fatigue", "Apathy", "Lethargy", "Listlessness", "Languor",
            "Lassitude", "Lingering Sloth",
        },
        ["GroupHealProcBuff"] = {
            "Mindful Spirit", "Watchful Spirit", "Attentive Spirit", "Responsive Spirit",
        },
        ["PackSelfBuff"] = {
            "Pack of Ancestral Beasts", "Pack of Lunar Wolves",
            "Pack of The Black Fang", "Pack of Mirtuk", "Pack of Olesira",
            "Pack of Kriegas", "Pack of Hilnaah", "Pack of Wurt",
        },
        -- Haste/Run Speed
        ["HasteBuff"] = {
            "Talisman of Celerity", "Swift Like the Wind", "Celerity", "Quickness",
        },
        ["RunSpeedBuff"] = {
            "Spirit of Tala'Tak", "Spirit of Bih`Li", "Pack Shrew", "Spirit of Wolf",
        },
        -- Cripple
        ["CrippleSpell"] = {
            "Crippling Spasm", "Cripple", "Incapacitate", "Listless Power",
        },
        -- Cure spells
        ["CureDisease"] = {
            "Disinfecting Aura", "Cure Disease", "Remove Disease", "Counteract Disease",
        },
        ["CurePoison"] = {
            "Abolish Poison", "Counteract Poison", "Cure Poison", "Remove Poison",
        },
        ["CureAll"] = {
            "Blood of Rivans", "Blood of Sanera", "Blood of Corbeth", "Blood of Klar",
            "Purified Spirits", "Purify Soul",
        },
    },
}
