-- F:/lua/SideKick/data/class_configs/CLR.lua
-- Cleric Class Configuration with condition-based rotations

local mq = require('mq')

local M = {}

-- Spell Lines: Ordered newest to oldest for resolution
M.spellLines = {
    -- Fast heals (Remedy line)
    ['Remedy'] = {
        "Avowed Remedy", "Guileless Remedy", "Sincere Remedy", "Merciful Remedy",
        "Spiritual Remedy", "Graceful Remedy", "Faithful Remedy", "Earnest Remedy",
        "Devout Remedy", "Solemn Remedy", "Sacred Remedy", "Pious Remedy",
        "Supernal Remedy", "Ethereal Remedy", "Remedy",
    },
    ['Remedy2'] = {
        "Avowed Remedy", "Guileless Remedy", "Sincere Remedy", "Merciful Remedy",
        "Spiritual Remedy", "Graceful Remedy",
    },

    -- Big heals (Renewal line)
    ['Renewal'] = {
        "Heroic Renewal", "Determined Renewal", "Dire Renewal", "Furial Renewal",
        "Fraught Renewal", "Fervent Renewal", "Frenzied Renewal", "Frenetic Renewal",
        "Frantic Renewal", "Desperate Renewal",
    },

    -- Heal + Nuke (Intervention line)
    ['Intervention'] = {
        "Avowed Intervention", "Atoned Intervention", "Sincere Intervention",
        "Merciful Intervention", "Mystical Intervention", "Virtuous Intervention",
        "Elysian Intervention", "Celestial Intervention", "Holy Intervention",
    },

    -- Nuke + Heal (Contravention line)
    ['Contravention'] = {
        "Avowed Contravention", "Divine Contravention", "Sincere Contravention",
        "Merciful Contravention", "Ardent Contravention", "Virtuous Contravention",
        "Elysian Contravention", "Celestial Contravention", "Holy Contravention",
    },

    -- Group heal with cure
    ['GroupHealCure'] = {
        "Word of Greater Vivification", "Word of Greater Rejuvenation",
        "Word of Greater Replenishment", "Word of Greater Restoration",
        "Word of Greater Reformation", "Word of Reformation", "Word of Rehabilitation",
        "Word of Resurgence", "Word of Recovery", "Word of Vivacity",
        "Word of Vivification", "Word of Replenishment", "Word of Restoration",
    },

    -- Group fast heal (Syllable line)
    ['GroupFastHeal'] = {
        "Syllable of Renewal", "Syllable of Invigoration", "Syllable of Soothing",
        "Syllable of Mending", "Syllable of Convalescence", "Syllable of Acceptance",
    },

    -- Promised heal
    ['PromisedHeal'] = {
        "Promised Reformation", "Promised Rehabilitation", "Promised Renewal",
        "Promised Mending", "Promised Recovery", "Promised Remedy",
    },

    -- Single target HoT
    ['SingleHoT'] = {
        "Devout Elixir", "Earnest Elixir", "Solemn Elixir", "Sacred Elixir",
        "Pious Elixir", "Holy Elixir", "Supernal Elixir", "Celestial Elixir",
        "Celestial Healing", "Celestial Health", "Celestial Remedy",
    },

    -- Group HoT (Elixir/Acquittal)
    ['GroupHoT'] = {
        "Avowed Acquittal", "Devout Acquittal", "Sincere Acquittal",
        "Merciful Acquittal", "Ardent Acquittal", "Cleansing Acquittal",
        "Elixir of Realization", "Elixir of Benevolence", "Elixir of Transcendence",
    },

    -- Self buff (Yaulp)
    ['Yaulp'] = {
        "Yaulp XI", "Yaulp X", "Yaulp IX", "Yaulp VIII", "Yaulp VII",
        "Yaulp VI", "Yaulp V", "Yaulp IV", "Yaulp III", "Yaulp II", "Yaulp",
    },

    -- HP buff (Symbol)
    ['Symbol'] = {
        "Unified Hand of Helmsbane", "Unified Hand of the Diabo",
        "Unified Hand of Assurance", "Unified Hand of Jorlleag",
        "Unified Hand of Emra", "Unified Hand of Nonia",
        "Unified Hand of Gezat", "Unified Hand of the Triumvirate",
    },

    -- Shining (damage shield/armor)
    ['Shining'] = {
        "Shining Fortress", "Shining Aegis", "Shining Bulwark",
        "Shining Rampart", "Shining Bastion",
    },

    -- Undead nuke
    ['UndeadNuke'] = {
        "Unyielding Admonition", "Unyielding Rebuke", "Unyielding Censure",
        "Unyielding Judgment", "Glorious Judgment", "Glorious Rebuke",
        "Glorious Admonition", "Glorious Censure", "Glorious Denunciation",
    },

    -- Magic nuke
    ['MagicNuke'] = {
        "Burst of Retribution", "Burst of Sunrise", "Burst of Daybreak",
        "Burst of Dawnlight", "Burst of Sunlight",
    },

    -- Cure spells
    ['CureDisease'] = {
        "Expurgare", "Ameliorate", "Purify Body", "Cure Disease", "Remove Disease",
    },
    ['CurePoison'] = {
        "Antidote", "Counteract Poison", "Abolish Poison", "Cure Poison", "Remove Poison",
    },
    ['CureCurse'] = {
        "Remove Greater Curse", "Remove Curse", "Abolish Curse",
    },
    ['CureCorruption'] = {
        "Disinfecting Aura", "Pristine Sanctity", "Pure Sanctity", "Sanctify",
        "Dissident Sanctity", "Composite Sanctity", "Ecliptic Sanctity", "Eradicate Corruption",
    },

    -- Stun
    ['Stun'] = {
        "Sound of Affirmation", "Sound of Constriction", "Sound of Divinity",
        "Sound of Wrath", "Sound of Resonance", "Sound of Might", "Stun",
    },
}

-- AA Lines: Ordered by progression
M.aaLines = {
    ['DivineArbitration'] = { "Divine Arbitration" },
    ['CelestialRegen'] = { "Celestial Regeneration" },
    ['Sanctuary'] = { "Sanctuary" },
    ['DivineAura'] = { "Divine Aura" },
    ['Exquisite'] = { "Exquisite Benediction" },
    ['QuestCure'] = { "Radiant Cure" },
    ['GroupCure'] = { "Group Purified Soul", "Purified Spirits" },
    ['Burst'] = { "Burst of Life" },
    ['WardOfSurety'] = { "Ward of Surety" },
    ['VetticityAA'] = { "Vetticity" },
    ['FuryOfTheGods'] = { "Fury of the Gods" },
    ['SpireOfCleric'] = { "Spire of the Vicar" },
    ['ImprovedTwincast'] = { "Improved Twincast" },
}

-- Disc Lines
M.discLines = {
    ['Soothsayer'] = { "Soothsayer's Intervention" },
}

-- Default conditions: Used when user hasn't set a custom condition (ON_CONDITION mode)
-- These are evaluated by rotation_engine.evaluateConditionGate()
M.defaultConditions = {
    -- Emergency AAs
    ['doDivineArbitration'] = function(ctx)
        return ctx.group.injured(25) >= 3
    end,
    ['doCelestialRegen'] = function(ctx)
        return ctx.me.pctHPs < 35
    end,
    ['doSanctuary'] = function(ctx)
        return ctx.me.pctHPs < 20
    end,
    ['doDivineAura'] = function(ctx)
        return ctx.me.pctHPs < 15
    end,

    -- Heal spells
    ['doRemedy'] = function(ctx)
        return ctx.group.lowestHP < 80
    end,
    ['doRemedy2'] = function(ctx)
        return ctx.group.lowestHP < 70 and ctx.group.injured(80) >= 2
    end,
    ['doRenewal'] = function(ctx)
        return ctx.group.lowestHP < 50
    end,
    ['doIntervention'] = function(ctx)
        return ctx.group.lowestHP < 60
    end,
    ['doContravention'] = function(ctx)
        return ctx.combat and ctx.target.pctHPs > 20 and ctx.me.pctMana > 50
    end,
    ['doGroupHealCure'] = function(ctx)
        return ctx.group.injured(75) >= 3
    end,
    ['doGroupFastHeal'] = function(ctx)
        return ctx.group.injured(70) >= 2
    end,
    ['doPromisedHeal'] = function(ctx)
        return ctx.group.tankHP < 85 and ctx.combat
    end,
    ['doSingleHoT'] = function(ctx)
        return ctx.group.lowestHP < 85 and not ctx.combat
    end,
    ['doGroupHoT'] = function(ctx)
        return ctx.group.injured(85) >= 2 and not ctx.combat
    end,

    -- Cure spells
    ['doCureDisease'] = function(ctx)
        -- Would need buff detection for detrimental buffs
        return false
    end,
    ['doCurePoison'] = function(ctx)
        return false
    end,
    ['doCureCurse'] = function(ctx)
        return false
    end,
    ['doCureCorruption'] = function(ctx)
        return false
    end,

    -- Buff spells (OOC)
    ['doSymbol'] = function(ctx)
        return not ctx.combat
    end,
    ['doShining'] = function(ctx)
        return not ctx.combat
    end,
    ['doYaulp'] = function(ctx)
        return not ctx.me.buff('Yaulp')
    end,

    -- DPS spells
    ['doUndeadNuke'] = function(ctx)
        return ctx.combat and ctx.target.body == 'Undead' and ctx.me.pctMana > 40
    end,
    ['doMagicNuke'] = function(ctx)
        return ctx.combat and ctx.me.pctMana > 50 and ctx.target.pctHPs > 30
    end,
    ['doStun'] = function(ctx)
        return ctx.combat and ctx.target.pctHPs > 20
    end,

    -- Burn AAs
    ['doFuryOfTheGods'] = function(ctx)
        return ctx.burn
    end,
    ['doSpireOfCleric'] = function(ctx)
        return ctx.burn
    end,
    ['doImprovedTwincast'] = function(ctx)
        return ctx.burn and not ctx.me.buff('Improved Twincast') and not ctx.me.buff('Twincast')
    end,
}

-- Category overrides: Which rotation layer each ability belongs to
M.categoryOverrides = {
    -- Emergency layer
    ['doDivineArbitration'] = 'emergency',
    ['doCelestialRegen'] = 'emergency',
    ['doSanctuary'] = 'emergency',
    ['doDivineAura'] = 'emergency',

    -- Support layer (heals)
    ['doRemedy'] = 'support',
    ['doRemedy2'] = 'support',
    ['doRenewal'] = 'support',
    ['doIntervention'] = 'support',
    ['doGroupHealCure'] = 'support',
    ['doGroupFastHeal'] = 'support',
    ['doPromisedHeal'] = 'support',
    ['doSingleHoT'] = 'support',
    ['doGroupHoT'] = 'support',
    ['doCureDisease'] = 'support',
    ['doCurePoison'] = 'support',
    ['doCureCurse'] = 'support',
    ['doCureCorruption'] = 'support',

    -- Combat layer (DPS)
    ['doContravention'] = 'combat',
    ['doUndeadNuke'] = 'combat',
    ['doMagicNuke'] = 'combat',
    ['doStun'] = 'combat',

    -- Utility layer (buffs)
    ['doSymbol'] = 'utility',
    ['doShining'] = 'utility',
    ['doYaulp'] = 'utility',

    -- Burn layer
    ['doFuryOfTheGods'] = 'burn',
    ['doSpireOfCleric'] = 'burn',
    ['doImprovedTwincast'] = 'burn',
}

-- Gem loadouts by mode
M.gemLoadouts = {
    ['Heal'] = {
        [1] = 'Remedy',
        [2] = 'Remedy2',
        [3] = 'Intervention',
        [4] = 'GroupHealCure',
        [5] = 'Renewal',
        [6] = 'PromisedHeal',
        [7] = 'Contravention',
        [8] = 'Yaulp',
        [9] = 'Symbol',
        [10] = 'SingleHoT',
        [11] = 'GroupHoT',
        [12] = 'Shining',
    },
    ['Group'] = {
        [1] = 'Remedy',
        [2] = 'GroupHealCure',
        [3] = 'GroupFastHeal',
        [4] = 'GroupHoT',
        [5] = 'Intervention',
        [6] = 'Renewal',
        [7] = 'PromisedHeal',
        [8] = 'Yaulp',
        [9] = 'Symbol',
        [10] = 'Contravention',
    },
    ['DPS'] = {
        [1] = 'Contravention',
        [2] = 'UndeadNuke',
        [3] = 'MagicNuke',
        [4] = 'Intervention',
        [5] = 'Remedy',
        [6] = 'GroupHealCure',
        [7] = 'Yaulp',
        [8] = 'Symbol',
    },
}

-- Class-specific settings
M.Settings = {
    -- Healing settings
    DoHealing = {
        Default = true,
        Category = "Heal",
        DisplayName = "Enable Healing",
        Tooltip = "Enable automatic healing",
    },
    DoGroupHeals = {
        Default = true,
        Category = "Heal",
        DisplayName = "Use Group Heals",
        Tooltip = "Use group heal spells when multiple injured",
    },
    DoHoTs = {
        Default = true,
        Category = "Heal",
        DisplayName = "Use HoTs",
        Tooltip = "Use heal-over-time spells",
    },
    DoPromisedHeals = {
        Default = true,
        Category = "Heal",
        DisplayName = "Use Promised Heals",
        Tooltip = "Use promised heal spells on tank",
    },

    -- Cure settings
    DoCures = {
        Default = true,
        Category = "Cure",
        DisplayName = "Enable Cures",
        Tooltip = "Automatically cure detrimental effects",
    },
    DoCureDisease = {
        Default = true,
        Category = "Cure",
        DisplayName = "Cure Disease",
        Tooltip = "Cure disease effects",
    },
    DoCurePoison = {
        Default = true,
        Category = "Cure",
        DisplayName = "Cure Poison",
        Tooltip = "Cure poison effects",
    },
    DoCureCurse = {
        Default = true,
        Category = "Cure",
        DisplayName = "Cure Curse",
        Tooltip = "Cure curse effects",
    },
    DoCureCorruption = {
        Default = true,
        Category = "Cure",
        DisplayName = "Cure Corruption",
        Tooltip = "Cure corruption effects",
    },

    -- Buff settings
    DoSymbol = {
        Default = true,
        Category = "Buff",
        DisplayName = "Cast Symbol",
        Tooltip = "Maintain HP buff on group",
    },
    DoShining = {
        Default = true,
        Category = "Buff",
        DisplayName = "Cast Shining",
        Tooltip = "Maintain armor buff on group",
    },
    DoYaulp = {
        Default = true,
        Category = "Buff",
        DisplayName = "Cast Yaulp",
        Tooltip = "Maintain Yaulp self-buff",
    },

    -- DPS settings
    DoDPS = {
        Default = false,
        Category = "DPS",
        DisplayName = "Enable DPS",
        Tooltip = "Cast damage spells when healing not needed",
    },
    DoContravention = {
        Default = true,
        Category = "DPS",
        DisplayName = "Use Contravention",
        Tooltip = "Use nuke+heal spell",
    },
    DoUndeadNuke = {
        Default = true,
        Category = "DPS",
        DisplayName = "Undead Nuke",
        Tooltip = "Use undead damage spells",
    },

    -- Emergency AA settings
    UseDivineArbitration = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Divine Arbitration",
        Tooltip = "Use when multiple group members critical",
    },
    UseCelestialRegen = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Celestial Regeneration",
        Tooltip = "Use when self HP critical",
    },
    UseSanctuary = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Sanctuary",
        Tooltip = "Emergency invulnerability",
    },

    -- Burn settings
    UseBurns = {
        Default = true,
        Category = "Burn",
        DisplayName = "Enable Burns",
        Tooltip = "Use burn abilities when burn active",
    },
}

return M
