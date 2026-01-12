-- F:/lua/SideKick/data/spellsets/CLR.lua
-- Cleric Spellsets - Role-based spell loadouts with spell line definitions

return {
    roles = {
        heal = {
            name = "Healing Focused",
            gems = {
                [1] = { spellLine = "Remedy", priority = 1 },
                [2] = { spellLine = "Remedy2", priority = 1 },
                [3] = { spellLine = "Intervention", priority = 1 },
                [4] = { spellLine = "GroupHealCure", priority = 1 },
                [5] = { spellLine = "Renewal", priority = 2 },
                [6] = { spellLine = "PromisedHeal", priority = 2 },
                [7] = { spellLine = "Contravention", priority = 2 },
                [8] = { spellLine = "Yaulp", priority = 3 },
                [9] = { spellLine = "Symbol", priority = 3 },
                [10] = { spellLine = "SingleHoT", priority = 3 },
                [11] = { spellLine = "GroupHoT", priority = 3 },
                [12] = { spellLine = "Shining", priority = 3 },
            },
        },
        group = {
            name = "Group Healing",
            gems = {
                [1] = { spellLine = "Remedy", priority = 1 },
                [2] = { spellLine = "GroupHealCure", priority = 1 },
                [3] = { spellLine = "GroupFastHeal", priority = 1 },
                [4] = { spellLine = "GroupHoT", priority = 1 },
                [5] = { spellLine = "Intervention", priority = 2 },
                [6] = { spellLine = "Renewal", priority = 2 },
                [7] = { spellLine = "PromisedHeal", priority = 2 },
                [8] = { spellLine = "Yaulp", priority = 3 },
                [9] = { spellLine = "Symbol", priority = 3 },
                [10] = { spellLine = "Contravention", priority = 3 },
            },
        },
        dps = {
            name = "DPS/Battle Cleric",
            gems = {
                [1] = { spellLine = "Contravention", priority = 1 },
                [2] = { spellLine = "UndeadNuke", priority = 1 },
                [3] = { spellLine = "MagicNuke", priority = 1 },
                [4] = { spellLine = "Intervention", priority = 2 },
                [5] = { spellLine = "Remedy", priority = 2 },
                [6] = { spellLine = "GroupHealCure", priority = 2 },
                [7] = { spellLine = "Yaulp", priority = 3 },
                [8] = { spellLine = "Symbol", priority = 3 },
            },
        },
    },
    spellLines = {
        -- Fast heals (Remedy line)
        ["Remedy"] = {
            "Avowed Remedy", "Guileless Remedy", "Sincere Remedy", "Merciful Remedy",
            "Spiritual Remedy", "Graceful Remedy", "Faithful Remedy", "Earnest Remedy",
            "Devout Remedy", "Solemn Remedy", "Sacred Remedy", "Pious Remedy",
            "Supernal Remedy", "Ethereal Remedy", "Remedy",
        },
        ["Remedy2"] = {
            "Avowed Remedy", "Guileless Remedy", "Sincere Remedy", "Merciful Remedy",
            "Spiritual Remedy", "Graceful Remedy",
        },
        -- Big heals (Renewal line)
        ["Renewal"] = {
            "Heroic Renewal", "Determined Renewal", "Dire Renewal", "Furial Renewal",
            "Fraught Renewal", "Fervent Renewal", "Frenzied Renewal", "Frenetic Renewal",
            "Frantic Renewal", "Desperate Renewal",
        },
        -- Heal + Nuke (Intervention line)
        ["Intervention"] = {
            "Avowed Intervention", "Atoned Intervention", "Sincere Intervention",
            "Merciful Intervention", "Mystical Intervention", "Virtuous Intervention",
            "Elysian Intervention", "Celestial Intervention", "Holy Intervention",
        },
        -- Nuke + Heal (Contravention line)
        ["Contravention"] = {
            "Avowed Contravention", "Divine Contravention", "Sincere Contravention",
            "Merciful Contravention", "Ardent Contravention", "Virtuous Contravention",
            "Elysian Contravention", "Celestial Contravention", "Holy Contravention",
        },
        -- Group heal with cure
        ["GroupHealCure"] = {
            "Word of Greater Vivification", "Word of Greater Rejuvenation",
            "Word of Greater Replenishment", "Word of Greater Restoration",
            "Word of Greater Reformation", "Word of Reformation", "Word of Rehabilitation",
            "Word of Resurgence", "Word of Recovery", "Word of Vivacity",
            "Word of Vivification", "Word of Replenishment", "Word of Restoration",
        },
        -- Group fast heal (Syllable line)
        ["GroupFastHeal"] = {
            "Syllable of Renewal", "Syllable of Invigoration", "Syllable of Soothing",
            "Syllable of Mending", "Syllable of Convalescence", "Syllable of Acceptance",
        },
        -- Promised heal
        ["PromisedHeal"] = {
            "Promised Reformation", "Promised Rehabilitation", "Promised Renewal",
            "Promised Mending", "Promised Recovery", "Promised Remedy",
        },
        -- Single target HoT
        ["SingleHoT"] = {
            "Devout Elixir", "Earnest Elixir", "Solemn Elixir", "Sacred Elixir",
            "Pious Elixir", "Holy Elixir", "Supernal Elixir", "Celestial Elixir",
            "Celestial Healing", "Celestial Health", "Celestial Remedy",
        },
        -- Group HoT (Elixir/Acquittal)
        ["GroupHoT"] = {
            "Avowed Acquittal", "Devout Acquittal", "Sincere Acquittal",
            "Merciful Acquittal", "Ardent Acquittal", "Cleansing Acquittal",
            "Elixir of Realization", "Elixir of Benevolence", "Elixir of Transcendence",
        },
        -- Self buff (Yaulp)
        ["Yaulp"] = {
            "Yaulp XI", "Yaulp X", "Yaulp IX", "Yaulp VIII", "Yaulp VII",
            "Yaulp VI", "Yaulp V", "Yaulp IV", "Yaulp III", "Yaulp II", "Yaulp",
        },
        -- HP buff (Symbol)
        ["Symbol"] = {
            "Unified Hand of Helmsbane", "Unified Hand of the Diabo",
            "Unified Hand of Assurance", "Unified Hand of Jorlleag",
            "Unified Hand of Emra", "Unified Hand of Nonia",
            "Unified Hand of Gezat", "Unified Hand of the Triumvirate",
        },
        -- Shining (damage shield/armor)
        ["Shining"] = {
            "Shining Fortress", "Shining Aegis", "Shining Bulwark",
            "Shining Rampart", "Shining Bastion",
        },
        -- Undead nuke
        ["UndeadNuke"] = {
            "Unyielding Admonition", "Unyielding Rebuke", "Unyielding Censure",
            "Unyielding Judgment", "Glorious Judgment", "Glorious Rebuke",
            "Glorious Admonition", "Glorious Censure", "Glorious Denunciation",
        },
        -- Magic nuke
        ["MagicNuke"] = {
            "Burst of Retribution", "Burst of Sunrise", "Burst of Daybreak",
            "Burst of Dawnlight", "Burst of Sunlight",
        },
        -- Cure spells
        ["CureDisease"] = {
            "Expurgare", "Ameliorate", "Purify Body", "Cure Disease", "Remove Disease",
        },
        ["CurePoison"] = {
            "Antidote", "Counteract Poison", "Abolish Poison", "Cure Poison", "Remove Poison",
        },
        ["CureCurse"] = {
            "Remove Greater Curse", "Remove Curse", "Abolish Curse",
        },
        ["CureCorruption"] = {
            "Disinfecting Aura", "Pristine Sanctity", "Pure Sanctity", "Sanctify",
            "Dissident Sanctity", "Composite Sanctity", "Ecliptic Sanctity", "Eradicate Corruption",
        },
        ["CureAll"] = {
            "Word of Greater Reformation", "Word of Reformation", "Word of Rehabilitation",
            "Word of Greater Vivification", "Word of Greater Rejuvenation",
            "Purified Spirits", "Purify Soul",
        },
        ["CureDiseaseGroup"] = {
            "Wave of Expiation", "Cleansing Wave", "Purifying Wave",
        },
    },

    -- Buff definitions for BuffEngine
    buffLines = {
        -- HP buff (Symbol line)
        ["symbol"] = {
            category = "symbol",
            spellLine = "Symbol",  -- References spellLines above
            targets = "group",     -- "self", "group", "tank", "casters", "melees"
            rebuffWindow = 60,     -- Seconds before expiry to rebuff
            combatOnly = false,
            outOfCombatOnly = true,  -- Long cast, wait for downtime
            range = 100,
            duration = 7200,       -- 2 hours
        },
        -- Shining (damage shield/armor)
        ["shining"] = {
            category = "shining",
            spellLine = "Shining",
            targets = "group",
            rebuffWindow = 45,
            combatOnly = false,
            outOfCombatOnly = true,
            range = 100,
            duration = 3600,       -- 1 hour
        },
        -- Self buff (Yaulp)
        ["yaulp"] = {
            category = "yaulp",
            spellLine = "Yaulp",
            targets = "self",
            rebuffWindow = 30,
            combatOnly = false,
            outOfCombatOnly = false,  -- Can cast anytime
            range = 0,
            duration = 540,        -- 9 minutes
        },
    },
}
