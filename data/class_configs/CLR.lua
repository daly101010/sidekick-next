-- F:/lua/SideKick/data/class_configs/CLR.lua
-- Cleric Class Configuration
-- Ported from RGMercs with condition-based rotations

local mq = require('mq')

local M = {}

-- Spell Lines: Ordered newest to oldest for resolution
M.spellLines = {
    -- === HEALING SPELLS ===

    -- Light Heal Line (fast cast, small heal)
    ['HealingLight'] = {
        "Avowed Light", "Fervent Light", "Sincere Light", "Merciful Light",
        "Ardent Light", "Reverent Light", "Zealous Light", "Earnest Light",
        "Devout Light", "Solemn Light", "Sacred Light", "Ancient: Hallowed Light",
        "Pious Light", "Holy Light", "Supernal Light", "Ethereal Light",
        "Divine Light", "Healing Light", "Superior Healing", "Greater Healing",
        "Healing", "Light Healing", "Minor Healing",
    },

    -- Remedy Line (fast cast, efficient)
    ['RemedyHeal'] = {
        "Avowed Remedy", "Guileless Remedy", "Sincere Remedy", "Merciful Remedy",
        "Spiritual Remedy", "Graceful Remedy", "Faithful Remedy", "Earnest Remedy",
        "Devout Remedy", "Solemn Remedy", "Sacred Remedy", "Pious Remedy",
        "Supernal Remedy", "Ethereal Remedy", "Remedy",
    },
    ['RemedyHeal2'] = {
        "Avowed Remedy", "Guileless Remedy", "Sincere Remedy", "Merciful Remedy",
        "Spiritual Remedy", "Graceful Remedy",
    },

    -- Renewal Line (large heal, slower cast)
    ['Renewal'] = {
        "Heroic Renewal", "Determined Renewal", "Dire Renewal", "Furial Renewal",
        "Fraught Renewal", "Fervent Renewal", "Frenzied Renewal", "Frenetic Renewal",
        "Frantic Renewal", "Desperate Renewal",
    },
    ['Renewal2'] = {
        "Heroic Renewal", "Determined Renewal", "Dire Renewal", "Furial Renewal",
        "Fraught Renewal", "Fervent Renewal", "Frenzied Renewal", "Frenetic Renewal",
        "Frantic Renewal", "Desperate Renewal",
    },

    -- Intervention Line (Heal + Nuke target's target)
    ['HealNuke'] = {
        "Avowed Intervention", "Atoned Intervention", "Sincere Intervention",
        "Merciful Intervention", "Mystical Intervention", "Virtuous Intervention",
        "Elysian Intervention", "Celestial Intervention", "Holy Intervention",
    },
    ['HealNuke2'] = {
        "Avowed Intervention", "Atoned Intervention", "Sincere Intervention",
        "Merciful Intervention", "Mystical Intervention", "Virtuous Intervention",
        "Elysian Intervention", "Celestial Intervention", "Holy Intervention",
    },

    -- Contravention Line (Nuke + Heal target's target)
    ['NukeHeal'] = {
        "Avowed Contravention", "Divine Contravention", "Sincere Contravention",
        "Merciful Contravention", "Ardent Contravention", "Virtuous Contravention",
        "Elysian Contravention", "Celestial Contravention", "Holy Contravention",
    },
    ['NukeHeal2'] = {
        "Avowed Contravention", "Divine Contravention", "Sincere Contravention",
        "Merciful Contravention", "Ardent Contravention", "Virtuous Contravention",
        "Elysian Contravention", "Celestial Contravention", "Holy Contravention",
    },

    -- Dichotomic/Dissident Line
    ['DichoHeal'] = {
        "Reciprocal Blessing", "Ecliptic Blessing", "Composite Blessing",
        "Dissident Blessing", "Undying Life",
    },

    -- Clutch Heal Line (requires target < 35-45% HP)
    ['ClutchHeal'] = {
        "Nineteenth Commandment", "Eighteenth Rejuvenation", "Seventeenth Rejuvenation",
        "Sixteenth Serenity", "Fifteenth Emblem", "Fourteenth Catalyst",
        "Thirteenth Salve", "Twelfth Night", "Eleventh-Hour",
    },

    -- Complete Heal
    ['CompleteHeal'] = { "Complete Heal" },

    -- === GROUP HEALS ===

    -- Group Heal with Cure (Word of Greater line)
    ['GroupHealCure'] = {
        "Word of Greater Vivification", "Word of Greater Rejuvenation",
        "Word of Greater Replenishment", "Word of Greater Restoration",
        "Word of Greater Reformation", "Word of Reformation", "Word of Rehabilitation",
        "Word of Resurgence", "Word of Recovery", "Word of Vivacity",
        "Word of Vivification", "Word of Replenishment", "Word of Restoration",
    },

    -- Group Heal No Cure (Word of line)
    ['GroupHealNoCure'] = {
        "Word of Acceptance", "Word of Redress", "Word of Soothing", "Word of Mending",
        "Word of Convalescence", "Word of Renewal", "Word of Recuperation",
        "Word of Awakening", "Word of Recovery", "Word of Vivacity",
        "Word of Vivification", "Word of Replenishment", "Word of Restoration",
        "Word of Vigor", "Word of Healing", "Word of Health",
    },

    -- Group Fast Heal (Syllable line)
    ['GroupFastHeal'] = {
        "Syllable of Renewal", "Syllable of Invigoration", "Syllable of Soothing",
        "Syllable of Mending", "Syllable of Convalescence", "Syllable of Acceptance",
    },

    -- === HEAL OVER TIME ===

    -- Single Target HoT (Elixir line)
    ['SingleElixir'] = {
        "Earnest Elixir", "Devout Elixir", "Solemn Elixir", "Sacred Elixir",
        "Pious Elixir", "Holy Elixir", "Supernal Elixir", "Celestial Elixir",
        "Celestial Healing", "Celestial Health", "Celestial Remedy",
    },

    -- Group HoT (Elixir line)
    ['GroupElixir'] = {
        "Elixir of Realization", "Elixir of Benevolence", "Elixir of Transcendence",
        "Elixir of Wulthan", "Elixir of the Seas", "Elixir of the Acquittal",
        "Elixir of the Beneficent", "Elixir of the Ardent", "Elixir of Expiation",
        "Elixir of Atonement", "Elixir of Redemption", "Elixir of Divinity",
        "Ethereal Elixir",
    },

    -- Group HoT with Cure (Acquittal line)
    ['GroupAcquittal'] = {
        "Avowed Acquittal", "Devout Acquittal", "Sincere Acquittal",
        "Merciful Acquittal", "Ardent Acquittal", "Cleansing Acquittal",
    },

    -- === BUFFS ===

    -- Ward Buff (self rune)
    ['WardBuff'] = {
        "Ward of Commitment", "Ward of Persistence", "Ward of Righteousness",
        "Ward of Assurance", "Ward of Surety", "Ward of Certitude",
    },

    -- HP Buff (Aegolism -> Unified Hand line)
    ['AegoBuff'] = {
        "Unified Hand of Infallibility", "Unified Hand of Persistence",
        "Unified Hand of Righteousness", "Unified Hand of Assurance",
        "Unified Hand of Surety", "Unified Hand of Certitude",
        "Unified Hand of Credence", "Hand of Reliance", "Hand of Gallantry",
        "Hand Of Temerity", "Hand of Tenacity", "Hand of Conviction",
        "Hand of Virtue", "Blessing of Aegolism", "Blessing of Temperance",
        "Temperance", "Valor", "Bravery", "Daring", "Center", "Courage",
    },

    -- Symbol Buff (Unified Hand line)
    ['GroupSymbolBuff'] = {
        "Unified Hand of Helmsbane", "Unified Hand of the Diabo",
        "Unified Hand of Assurance", "Unified Hand of Jorlleag",
        "Unified Hand of Emra", "Unified Hand of Nonia",
        "Unified Hand of Gezat", "Unified Hand of the Triumvirate",
        "Ealdun's Mark", "Darianna's Mark", "Kaerra's Mark", "Elushar's Mark",
        "Balikor's Mark", "Kazad's Mark", "Marzin's Mark", "Naltron's Mark",
        "Symbol of Marzin", "Symbol of Naltron", "Symbol of Pinzarn",
        "Symbol of Ryltan", "Symbol of Transal",
    },

    -- AC Buff (Ward/Order line)
    ['ACBuff'] = {
        "Ward of the Avowed", "Ward of the Guileless", "Ward of Sincerity",
        "Ward of the Merciful", "Ward of the Earnest", "Order of the Earnest",
        "Ward of the Devout", "Order of the Devout", "Ward of the Resolute",
        "Order of the Resolute", "Ward of the Dauntless", "Ward of Valliance",
        "Ward of Gallantry", "Bulwark of Faith", "Shield of Words",
        "Armor of Faith", "Guard", "Spirit Armor", "Holy Armor",
    },

    -- Shining Buff (tank armor)
    ['ShiningBuff'] = {
        "Shining Steel", "Shining Fortitude", "Shining Aegis", "Shining Fortress",
        "Shining Bulwark", "Shining Bastion", "Shining Armor", "Shining Rampart",
    },

    -- Vie Buff (melee damage absorb)
    ['SingleVieBuff'] = {
        "Ward of Vie", "Guard of Vie", "Protection of Vie", "Bulwark of Vie",
        "Panoply of Vie", "Aegis of Vie",
    },
    ['GroupVieBuff'] = {
        "Rallied Greater Aegis of Vie", "Rallied Greater Protection of Vie",
        "Rallied Greater Guard of Vie", "Rallied Greater Ward of Vie",
        "Rallied Bastion of Vie", "Rallied Armor of Vie", "Rallied Rampart of Vie",
        "Rallied Palladium of Vie", "Rallied Shield of Vie", "Rallied Aegis of Vie",
    },

    -- Reverse Damage Shield
    ['ReverseDS'] = {
        "Hazuri's Retort", "Axoeviq's Retort", "Jorlleag's Retort",
        "Curate's Retort", "Vicarum's Retort", "Olsif's Retort",
        "Galvos' Retort", "Fintar's Retort", "Erud's Retort",
    },

    -- Divine Buff (death save)
    ['DivineBuff'] = {
        "Divine Interference", "Divine Intermediation", "Divine Imposition",
        "Divine Indemnification", "Divine Interposition", "Divine Invocation",
        "Divine Intercession", "Divine Intervention", "Death Pact",
    },

    -- Self HP/Mana Buff (Armor line)
    ['SelfHPBuff'] = {
        "Armor of the Avowed", "Armor of Penance", "Armor of Sincerity",
        "Armor of the Merciful", "Armor of the Ardent", "Armor of the Reverent",
        "Armor of the Zealous", "Armor of the Earnest", "Armor of the Devout",
        "Armor of the Solemn", "Armor of the Sacred", "Armor of the Pious",
        "Armor of the Zealot", "Ancient: High Priest's Bulwark",
        "Blessed Armor of the Risen", "Armor of Protection",
    },

    -- Group Heal Proc Buff
    ['GroupHealProcBuff'] = {
        "Divine Rejoinder", "Divine Contingency", "Divine Response",
        "Divine Reaction", "Divine Consequence",
    },

    -- Spell Haste Buff (Blessing line)
    ['SpellBlessing'] = {
        "Hand of Zeal", "Benediction of Piety", "Hand of Fervor",
        "Blessing of Fervor", "Hand of Will", "Blessing of Will",
        "Aura of Loyalty", "Blessing of Loyalty", "Aura of Resolve",
        "Blessing of Resolve", "Aura of Purpose", "Blessing of Purpose",
        "Aura of Devotion", "Blessing of Devotion", "Aura of Reverence",
        "Blessing of Reverence", "Blessing of Faith", "Blessing of Piety",
    },

    -- Group Infusion Buff (mana regen)
    ['GroupInfusionBuff'] = {
        "Hand of Avowed Infusion", "Hand of Unyielding Infusion",
        "Hand of Sincere Infusion", "Hand of Merciful Infusion",
        "Hand of Graceful Infusion", "Hand of Faithful Infusion",
    },

    -- Yaulp (self buff)
    ['YaulpSpell'] = {
        "Yaulp IX", "Yaulp VIII", "Yaulp VII", "Yaulp VI", "Yaulp V",
    },

    -- === AURAS ===

    -- Absorb Aura
    ['AbsorbAura'] = {
        "Aura of the Persistent", "Aura of the Reverent",
        "Aura of the Zealot", "Aura of the Pious",
    },

    -- HP Aura
    ['HPAura'] = {
        "Aura of Divinity", "Circle of Divinity", "Bastion of Divinity",
    },

    -- === CURES ===

    ['CureAll'] = {
        "Perfected Blood", "Cleansed Blood", "Unblemished Blood",
        "Expurgated Blood", "Sanctified Blood", "Purged Blood", "Purified Blood",
    },
    ['CureCorrupt'] = {
        "Expunge Corruption", "Vitiate Corruption",
        "Abolish Corruption", "Dissolve Corruption",
    },
    ['CurePoison'] = {
        "Cure Poison", "Counteract Poison", "Abolish Poison",
        "Eradicate Poison", "Antidote",
    },
    ['CureDisease'] = {
        "Cure Disease", "Counteract Disease", "Eradicate Disease",
    },
    ['CureCurse'] = {
        "Remove Minor Curse", "Remove Lesser Curse", "Remove Curse",
        "Remove Greater Curse", "Eradicate Curse",
    },

    -- === NUKES/DPS ===

    -- Undead Nuke
    ['UndeadNuke'] = {
        "Ward Undead", "Expulse Undead", "Dismiss Undead", "Expel Undead",
        "Banish Undead", "Exile Undead", "Destroy Undead", "Desolate Undead",
        "Annihilate the Undead", "Abolish the Undead", "Abrogate the Undead",
        "Eradicate the Undead", "Repudiate the Undead", "Obliterate the Undead",
        "Extirpate the Undead", "Banish the Undead",
    },

    -- Magic Nuke
    ['MagicNuke'] = {
        "Decree", "Divine Writ", "Injunction", "Sanction", "Justice",
        "Castigation", "Remonstrance", "Rebuke", "Reprehend", "Reproval",
        "Reproach", "Order", "Condemnation", "Judgment", "Retribution",
        "Wrath", "Smite", "Furor", "Strike",
    },

    -- Twin Heal Nuke
    ['TwinHealNuke'] = {
        "Unyielding Admonition", "Unyielding Rebuke", "Unyielding Censure",
        "Unyielding Judgment", "Glorious Judgment", "Glorious Rebuke",
        "Glorious Admonition", "Glorious Censure", "Glorious Denunciation",
    },

    -- Stun (Timer 6)
    ['StunTimer6'] = {
        "Sound of Divinity", "Sound of Zeal", "Sound of Resonance",
        "Sound of Reverberance", "Sound of Fury", "Sound of Fervor",
        "Sound of Plangency", "Sound of Thunder", "Sound of Wrath",
        "Sound of Rebuke", "Sound of Providence", "Sound of Heroism",
        "Tarnation", "Force", "Holy Might",
    },
    ['LowLevelStun'] = { "Stun" },

    -- Hammer Pet
    ['HammerPet'] = {
        "Unrelenting Hammer of Zeal", "Incorruptible Hammer of Obliteration",
        "Unyielding Hammer of Obliteration", "Unyielding Hammer of Zeal",
        "Ardent Hammer of Zeal", "Infallible Hammer of Reverence",
        "Infallible Hammer of Zeal", "Devout Hammer of Zeal",
        "Unwavering Hammer of Zeal", "Indomitable Hammer of Zeal",
        "Unflinching Hammer of Zeal", "Unswerving Hammer of Retribution",
        "Unswerving Hammer of Faith",
    },

    -- === RESURRECTION ===

    ['RezSpell'] = {
        "Reanimation", "Reconstitution", "Reparation", "Revive", "Renewal",
        "Resuscitate", "Restoration", "Resurrection", "Reviviscence",
    },
    ['AERezSpell'] = {
        "Larger Reviviscence", "Greater Reviviscence",
        "Eminent Reviviscence", "Superior Reviviscence",
    },
}

-- AA Lines
M.aaLines = {
    -- Emergency
    ['DivineArbitration'] = { "Divine Arbitration" },
    ['CelestialRegen'] = { "Celestial Regeneration" },
    ['Sanctuary'] = { "Sanctuary" },
    ['DivineAura'] = { "Divine Aura" },

    -- Healing
    ['BeaconOfLife'] = { "Beacon of Life" },
    ['Exquisite'] = { "Exquisite Benediction" },
    ['WardOfSurety'] = { "Ward of Surety" },
    ['CelestialHammer'] = { "Celestial Hammer" },
    ['VeturikasPresence'] = { "Veturika's Presence" },
    ['QuietPrayer'] = { "Quiet Prayer" },

    -- Cures
    ['RadiantCure'] = { "Radiant Cure" },
    ['GroupPurifySoul'] = { "Group Purify Soul" },
    ['PurifySoul'] = { "Purify Soul" },
    ['PurifiedSpirits'] = { "Purified Spirits" },

    -- Rezzing
    ['BlessingOfRes'] = { "Blessing of Resurrection" },
    ['CallOfTheHero'] = { "Call of the Hero" },

    -- Burns
    ['FuryOfTheGods'] = { "Fury of the Gods" },
    ['SpireOfCleric'] = { "Spire of the Vicar" },
    ['ImprovedTwincast'] = { "Improved Twincast" },
    ['FocusedCelestialRegen'] = { "Focused Celestial Regeneration" },
    ['SpiritMastery'] = { "Spirit Mastery" },
    ['IntensityOfResolute'] = { "Intensity of the Resolute" },

    -- Utility
    ['Yaulp'] = { "Yaulp" },
}

-- Disc Lines (Clerics don't have many)
M.discLines = {}

-- Default Conditions
M.defaultConditions = {
    -- === EMERGENCY ===
    ['doDivineArbitration'] = function(ctx)
        return ctx.group.injured(25) >= 3
    end,
    ['doCelestialRegen'] = function(ctx)
        return ctx.me.pctHPs < 35 or ctx.group.tankHP < 25
    end,
    ['doSanctuary'] = function(ctx)
        return ctx.me.pctHPs < 20
    end,
    ['doDivineAura'] = function(ctx)
        return ctx.me.pctHPs < 15
    end,

    -- === HEALING ===
    ['doHealingLight'] = function(ctx)
        return ctx.group.lowestHP < 85
    end,
    ['doRemedyHeal'] = function(ctx)
        return ctx.group.lowestHP < 80
    end,
    ['doRemedyHeal2'] = function(ctx)
        return ctx.group.lowestHP < 70 and ctx.group.injured(80) >= 2
    end,
    ['doRenewal'] = function(ctx)
        return ctx.group.lowestHP < 50
    end,
    ['doRenewal2'] = function(ctx)
        return ctx.group.injured(50) >= 2
    end,
    ['doHealNuke'] = function(ctx)
        return ctx.combat and ctx.group.lowestHP < 60
    end,
    ['doHealNuke2'] = function(ctx)
        return ctx.combat and ctx.group.injured(65) >= 2
    end,
    ['doNukeHeal'] = function(ctx)
        return ctx.combat and ctx.target.pctHPs > 20 and ctx.me.pctMana > 50
    end,
    ['doDichoHeal'] = function(ctx)
        return ctx.group.injured(50) >= 3
    end,
    ['doClutchHeal'] = function(ctx)
        return ctx.group.lowestHP < 35
    end,
    ['doCompleteHeal'] = function(ctx)
        return ctx.group.tankHP < 80 and ctx.group.tankHP > 20
    end,

    -- === GROUP HEALS ===
    ['doGroupHealCure'] = function(ctx)
        return ctx.group.injured(75) >= 3
    end,
    ['doGroupHealNoCure'] = function(ctx)
        return ctx.group.injured(70) >= 3
    end,
    ['doGroupFastHeal'] = function(ctx)
        return ctx.group.injured(70) >= 2
    end,

    -- === HOTS ===
    ['doSingleElixir'] = function(ctx)
        return ctx.group.lowestHP < 85 and not ctx.combat
    end,
    ['doGroupElixir'] = function(ctx)
        return ctx.group.injured(85) >= 2
    end,
    ['doGroupAcquittal'] = function(ctx)
        return ctx.group.injured(80) >= 2
    end,

    -- === BUFFS (OOC) ===
    ['doWardBuff'] = function(ctx)
        return not ctx.combat and not ctx.me.buff('Ward')
    end,
    ['doAegoBuff'] = function(ctx)
        return not ctx.combat
    end,
    ['doGroupSymbolBuff'] = function(ctx)
        return not ctx.combat
    end,
    ['doACBuff'] = function(ctx)
        return not ctx.combat
    end,
    ['doShiningBuff'] = function(ctx)
        return not ctx.combat
    end,
    ['doGroupVieBuff'] = function(ctx)
        return not ctx.combat
    end,
    ['doDivineBuff'] = function(ctx)
        return not ctx.combat
    end,
    ['doSelfHPBuff'] = function(ctx)
        return not ctx.combat and not ctx.me.buff('Armor')
    end,
    ['doYaulpSpell'] = function(ctx)
        return not ctx.me.buff('Yaulp')
    end,

    -- === DPS ===
    ['doTwinHealNuke'] = function(ctx)
        return ctx.combat and ctx.me.pctMana > 40
    end,
    ['doUndeadNuke'] = function(ctx)
        return ctx.combat and ctx.target.body == 'Undead' and ctx.me.pctMana > 40
    end,
    ['doMagicNuke'] = function(ctx)
        return ctx.combat and ctx.me.pctMana > 50 and ctx.target.pctHPs > 30
    end,
    ['doStunTimer6'] = function(ctx)
        return ctx.combat and ctx.target.pctHPs > 20
    end,
    ['doHammerPet'] = function(ctx)
        return ctx.combat and ctx.target.named
    end,

    -- === BURNS ===
    ['doFuryOfTheGods'] = function(ctx)
        return ctx.burn
    end,
    ['doSpireOfCleric'] = function(ctx)
        return ctx.burn
    end,
    ['doImprovedTwincast'] = function(ctx)
        return ctx.burn and not ctx.me.buff('Improved Twincast') and not ctx.me.buff('Twincast')
    end,
    ['doIntensityOfResolute'] = function(ctx)
        return ctx.burn
    end,
}

-- Category Overrides
M.categoryOverrides = {
    -- Emergency layer
    ['doDivineArbitration'] = 'emergency',
    ['doCelestialRegen'] = 'emergency',
    ['doSanctuary'] = 'emergency',
    ['doDivineAura'] = 'emergency',
    ['doClutchHeal'] = 'emergency',

    -- Support layer (heals)
    ['doHealingLight'] = 'support',
    ['doRemedyHeal'] = 'support',
    ['doRemedyHeal2'] = 'support',
    ['doRenewal'] = 'support',
    ['doRenewal2'] = 'support',
    ['doHealNuke'] = 'support',
    ['doHealNuke2'] = 'support',
    ['doDichoHeal'] = 'support',
    ['doCompleteHeal'] = 'support',
    ['doGroupHealCure'] = 'support',
    ['doGroupHealNoCure'] = 'support',
    ['doGroupFastHeal'] = 'support',
    ['doSingleElixir'] = 'support',
    ['doGroupElixir'] = 'support',
    ['doGroupAcquittal'] = 'support',

    -- Combat layer (DPS)
    ['doNukeHeal'] = 'combat',
    ['doTwinHealNuke'] = 'combat',
    ['doUndeadNuke'] = 'combat',
    ['doMagicNuke'] = 'combat',
    ['doStunTimer6'] = 'combat',
    ['doHammerPet'] = 'combat',

    -- Buff layer (buffs)
    ['doWardBuff'] = 'buff',
    ['doAegoBuff'] = 'buff',
    ['doGroupSymbolBuff'] = 'buff',
    ['doACBuff'] = 'buff',
    ['doShiningBuff'] = 'buff',
    ['doGroupVieBuff'] = 'buff',
    ['doDivineBuff'] = 'buff',
    ['doSelfHPBuff'] = 'buff',
    ['doYaulpSpell'] = 'buff',

    -- Burn layer
    ['doFuryOfTheGods'] = 'burn',
    ['doSpireOfCleric'] = 'burn',
    ['doImprovedTwincast'] = 'burn',
    ['doIntensityOfResolute'] = 'burn',
}

-- AbilitySets: Spell/AA progressions (highest to lowest rank)
M.AbilitySets = {
    -- Fast heals (Remedy line)
    RemedyHeal = {
        "Avowed Remedy", "Guileless Remedy", "Sincere Remedy", "Merciful Remedy",
        "Spiritual Remedy", "Graceful Remedy", "Faithful Remedy", "Earnest Remedy",
        "Devout Remedy", "Solemn Remedy", "Sacred Remedy", "Pious Remedy",
        "Supernal Remedy", "Ethereal Remedy", "Remedy",
    },
    RemedyHeal2 = {
        "Avowed Remedy", "Guileless Remedy", "Sincere Remedy", "Merciful Remedy",
        "Spiritual Remedy", "Graceful Remedy",
    },
    -- Big heals (Renewal line)
    Renewal = {
        "Heroic Renewal", "Determined Renewal", "Dire Renewal", "Furial Renewal",
        "Fraught Renewal", "Fervent Renewal", "Frenzied Renewal", "Frenetic Renewal",
        "Frantic Renewal", "Desperate Renewal",
    },
    -- Heal + Nuke (Intervention line)
    HealNuke = {
        "Avowed Intervention", "Atoned Intervention", "Sincere Intervention",
        "Merciful Intervention", "Mystical Intervention", "Virtuous Intervention",
        "Elysian Intervention", "Celestial Intervention", "Holy Intervention",
    },
    -- Nuke + Heal (Contravention line)
    NukeHeal = {
        "Avowed Contravention", "Divine Contravention", "Sincere Contravention",
        "Merciful Contravention", "Ardent Contravention", "Virtuous Contravention",
        "Elysian Contravention", "Celestial Contravention", "Holy Contravention",
    },
    -- Dichotomic heal
    DichoHeal = {
        "Reciprocal Blessing", "Ecliptic Blessing", "Composite Blessing",
        "Dissident Blessing", "Undying Life",
    },
    -- Clutch heal
    ClutchHeal = {
        "Nineteenth Commandment", "Eighteenth Rejuvenation", "Seventeenth Rejuvenation",
        "Sixteenth Serenity", "Fifteenth Emblem", "Fourteenth Catalyst",
        "Thirteenth Salve", "Twelfth Night", "Eleventh-Hour",
    },
    -- Group heal with cure
    GroupHealCure = {
        "Word of Greater Vivification", "Word of Greater Rejuvenation",
        "Word of Greater Replenishment", "Word of Greater Restoration",
        "Word of Greater Reformation", "Word of Reformation", "Word of Rehabilitation",
        "Word of Resurgence", "Word of Recovery", "Word of Vivacity",
        "Word of Vivification", "Word of Replenishment", "Word of Restoration",
    },
    -- Group fast heal (Syllable line)
    GroupFastHeal = {
        "Syllable of Renewal", "Syllable of Invigoration", "Syllable of Soothing",
        "Syllable of Mending", "Syllable of Convalescence", "Syllable of Acceptance",
    },
    -- Group HoT (Acquittal)
    GroupAcquittal = {
        "Avowed Acquittal", "Devout Acquittal", "Sincere Acquittal",
        "Merciful Acquittal", "Ardent Acquittal", "Cleansing Acquittal",
    },
    -- Symbol buff
    GroupSymbolBuff = {
        "Unified Hand of Helmsbane", "Unified Hand of the Diabo",
        "Unified Hand of Assurance", "Unified Hand of Jorlleag",
        "Unified Hand of Emra", "Unified Hand of Nonia",
        "Unified Hand of Gezat", "Unified Hand of the Triumvirate",
    },
    -- Shining buff
    ShiningBuff = {
        "Shining Fortress", "Shining Aegis", "Shining Bulwark",
        "Shining Rampart", "Shining Bastion",
    },
    -- Self HP buff
    SelfHPBuff = {
        "Armor of the Avowed", "Armor of Penance", "Armor of Sincerity",
        "Armor of the Merciful", "Armor of the Ardent", "Armor of the Reverent",
    },
    -- Divine buff
    DivineBuff = {
        "Divine Interference", "Divine Intermediation", "Divine Imposition",
        "Divine Indemnification", "Divine Interposition", "Divine Invocation",
    },
    -- Stun
    StunTimer6 = {
        "Sound of Divinity", "Sound of Zeal", "Sound of Resonance",
        "Sound of Reverberance", "Sound of Fury", "Sound of Fervor",
    },
    -- Twin Heal Nuke
    TwinHealNuke = {
        "Unyielding Admonition", "Unyielding Rebuke", "Unyielding Censure",
        "Unyielding Judgment", "Glorious Judgment", "Glorious Rebuke",
    },
    -- Undead nuke
    UndeadNuke = {
        "Ward Undead", "Expulse Undead", "Dismiss Undead", "Expel Undead",
        "Banish Undead", "Exile Undead", "Destroy Undead", "Desolate Undead",
    },
    -- Magic nuke
    MagicNuke = {
        "Decree", "Divine Writ", "Injunction", "Sanction", "Justice",
        "Castigation", "Remonstrance", "Rebuke", "Reprehend", "Reproval",
    },
    -- Yaulp
    YaulpSpell = {
        "Yaulp XI", "Yaulp X", "Yaulp IX", "Yaulp VIII", "Yaulp VII",
        "Yaulp VI", "Yaulp V",
    },
    -- Cure All
    CureAllSpell = {
        "Perfected Blood", "Cleansed Blood", "Unblemished Blood",
        "Expurgated Blood", "Sanctified Blood", "Purged Blood", "Purified Blood",
    },
    -- AA: Divine Arbitration
    DivineArbitrationAA = { "Divine Arbitration" },
    -- AA: Celestial Regeneration
    CelestialRegenAA = { "Celestial Regeneration" },
    -- AA: Sanctuary
    SanctuaryAA = { "Sanctuary" },
    -- AA: Fury of the Gods
    FuryOfTheGodsAA = { "Fury of the Gods" },
    -- AA: Spire of the Vicar
    SpireOfClericAA = { "Spire of the Vicar" },
    -- AA: Improved Twincast
    ImprovedTwincastAA = { "Improved Twincast" },
    -- AA: Intensity of the Resolute
    IntensityOfResoluteAA = { "Intensity of the Resolute" },
    -- AA: Radiant Cure
    RadiantCureAA = { "Radiant Cure" },
    -- AA: Beacon of Life
    BeaconOfLifeAA = { "Beacon of Life" },
    -- AC Buff (Ward/Order line)
    ACBuff = {
        "Ward of the Avowed", "Ward of the Guileless", "Ward of Sincerity",
        "Ward of the Merciful", "Ward of the Earnest", "Order of the Earnest",
        "Ward of the Devout", "Order of the Devout", "Ward of the Resolute",
    },
    -- Vie Buff (melee absorb)
    VieBuff = {
        "Rallied Greater Aegis of Vie", "Rallied Greater Protection of Vie",
        "Rallied Greater Guard of Vie", "Rallied Greater Ward of Vie",
        "Ward of Vie", "Guard of Vie", "Protection of Vie",
    },
    -- Cure All spell
    CureSpell = {
        "Perfected Blood", "Cleansed Blood", "Unblemished Blood",
        "Expurgated Blood", "Sanctified Blood", "Purged Blood", "Purified Blood",
    },
    -- Rez spell
    RezSpell = {
        "Reanimation", "Reconstitution", "Reparation", "Revive", "Renewal",
        "Resuscitate", "Restoration", "Resurrection", "Reviviscence",
    },
    -- AA: Blessing of Resurrection
    BlessingOfResAA = { "Blessing of Resurrection" },
    -- Mana restore AAs
    VeturikasPresenceAA = { "Veturika's Presence" },
    QuietPrayerAA = { "Quiet Prayer" },
}

-- SpellLoadouts: Role-based gem assignments with extended schema
M.SpellLoadouts = {
    heal = {
        name = "Healing Focused",
        description = "Focus on single target and emergency healing",
        gems = {
            [1] = "RemedyHeal",
            [2] = "RemedyHeal2",
            [3] = "HealNuke",
            [4] = "GroupHealCure",
            [5] = "Renewal",
            [6] = "DichoHeal",
            [7] = "NukeHeal",
            [8] = "GroupAcquittal",
            [9] = "GroupSymbolBuff",
        },
        defaults = {
            -- Healing
            DoHealing = true,
            DoGroupHeals = true,
            DoHoTs = true,
            DoDichoHeal = true,
            DoCompleteHeal = false,
            DoIntervention = true,
            -- Buffs
            DoACBuff = false,
            DoVieBuff = true,
            DoShining = true,
            DoDivineBuff = true,
            -- Cures
            DoCures = true,
            DoCureAA = true,
            DoCureSpells = true,
            -- DPS (minimal)
            DoDPS = false,
            DoContravention = true,
            DoTwinHealNuke = false,
            DoHealStun = true,
            DoUndeadNuke = false,
            DoMagicNuke = false,
            -- Emergency
            UseDivineArbitration = true,
            UseCelestialRegen = true,
            UseSanctuary = true,
            -- Burns
            UseBurns = true,
            DoVetAA = true,
            -- Rezzing
            DoBattleRez = true,
        },
        layerAssignments = {
            -- Emergency
            UseDivineArbitration = "emergency",
            UseCelestialRegen = "emergency",
            UseSanctuary = "emergency",
            -- Support (healing primary)
            DoHealing = "support",
            DoGroupHeals = "support",
            DoHoTs = "support",
            DoDichoHeal = "support",
            DoCompleteHeal = "support",
            DoIntervention = "support",
            DoCures = "support",
            DoCureAA = "support",
            DoCureSpells = "support",
            -- Combat
            DoDPS = "combat",
            DoContravention = "combat",
            DoTwinHealNuke = "combat",
            DoHealStun = "combat",
            DoUndeadNuke = "combat",
            DoMagicNuke = "combat",
            -- Burn
            UseBurns = "burn",
            DoVetAA = "burn",
            -- Buff
            DoACBuff = "buff",
            DoVieBuff = "buff",
            DoShining = "buff",
            DoDivineBuff = "buff",
            DoBattleRez = "buff",
        },
        layerOrder = {
            emergency = {"UseDivineArbitration", "UseCelestialRegen", "UseSanctuary"},
            support = {"DoHealing", "DoGroupHeals", "DoDichoHeal", "DoIntervention", "DoHoTs", "DoCompleteHeal", "DoCures", "DoCureAA", "DoCureSpells"},
            combat = {"DoContravention", "DoHealStun", "DoTwinHealNuke", "DoDPS", "DoUndeadNuke", "DoMagicNuke"},
            burn = {"UseBurns", "DoVetAA"},
            buff = {"DoVieBuff", "DoShining", "DoDivineBuff", "DoACBuff", "DoBattleRez"},
        },
    },
    group = {
        name = "Group Healing",
        description = "Focus on group healing and HoTs",
        gems = {
            [1] = "RemedyHeal",
            [2] = "GroupHealCure",
            [3] = "GroupFastHeal",
            [4] = "GroupAcquittal",
            [5] = "HealNuke",
            [6] = "Renewal",
            [7] = "DichoHeal",
            [8] = "GroupSymbolBuff",
            [9] = "NukeHeal",
        },
        defaults = {
            -- Healing
            DoHealing = true,
            DoGroupHeals = true,
            DoHoTs = true,
            DoDichoHeal = true,
            DoCompleteHeal = false,
            DoIntervention = true,
            -- Buffs
            DoACBuff = false,
            DoVieBuff = true,
            DoShining = true,
            DoDivineBuff = true,
            -- Cures
            DoCures = true,
            DoCureAA = true,
            DoCureSpells = true,
            -- DPS (minimal)
            DoDPS = false,
            DoContravention = true,
            DoTwinHealNuke = false,
            DoHealStun = false,
            DoUndeadNuke = false,
            DoMagicNuke = false,
            -- Emergency
            UseDivineArbitration = true,
            UseCelestialRegen = true,
            UseSanctuary = true,
            -- Burns
            UseBurns = true,
            DoVetAA = true,
            -- Rezzing
            DoBattleRez = true,
        },
        layerAssignments = {
            UseDivineArbitration = "emergency",
            UseCelestialRegen = "emergency",
            UseSanctuary = "emergency",
            DoHealing = "support",
            DoGroupHeals = "support",
            DoHoTs = "support",
            DoDichoHeal = "support",
            DoCompleteHeal = "support",
            DoIntervention = "support",
            DoCures = "support",
            DoCureAA = "support",
            DoCureSpells = "support",
            DoDPS = "combat",
            DoContravention = "combat",
            DoTwinHealNuke = "combat",
            DoHealStun = "combat",
            DoUndeadNuke = "combat",
            DoMagicNuke = "combat",
            UseBurns = "burn",
            DoVetAA = "burn",
            DoACBuff = "buff",
            DoVieBuff = "buff",
            DoShining = "buff",
            DoDivineBuff = "buff",
            DoBattleRez = "buff",
        },
        layerOrder = {
            emergency = {"UseDivineArbitration", "UseCelestialRegen", "UseSanctuary"},
            support = {"DoGroupHeals", "DoHoTs", "DoHealing", "DoDichoHeal", "DoIntervention", "DoCompleteHeal", "DoCures", "DoCureAA", "DoCureSpells"},
            combat = {"DoContravention", "DoHealStun", "DoTwinHealNuke", "DoDPS", "DoUndeadNuke", "DoMagicNuke"},
            burn = {"UseBurns", "DoVetAA"},
            buff = {"DoVieBuff", "DoShining", "DoDivineBuff", "DoACBuff", "DoBattleRez"},
        },
    },
    dps = {
        name = "DPS/Battle Cleric",
        description = "Maximize damage while maintaining essential healing",
        gems = {
            [1] = "NukeHeal",
            [2] = "TwinHealNuke",
            [3] = "StunTimer6",
            [4] = "HealNuke",
            [5] = "RemedyHeal",
            [6] = "GroupHealCure",
            [7] = "GroupSymbolBuff",
            [8] = "SelfHPBuff",
        },
        defaults = {
            -- Healing (essential only)
            DoHealing = true,
            DoGroupHeals = true,
            DoHoTs = false,
            DoDichoHeal = true,
            DoCompleteHeal = false,
            DoIntervention = true,
            -- Buffs
            DoACBuff = false,
            DoVieBuff = false,
            DoShining = false,
            DoDivineBuff = false,
            -- Cures
            DoCures = true,
            DoCureAA = true,
            DoCureSpells = false,
            -- DPS (primary)
            DoDPS = true,
            DoContravention = true,
            DoTwinHealNuke = true,
            DoHealStun = true,
            DoUndeadNuke = true,
            DoMagicNuke = true,
            -- Emergency
            UseDivineArbitration = true,
            UseCelestialRegen = true,
            UseSanctuary = true,
            -- Burns
            UseBurns = true,
            DoVetAA = true,
            -- Rezzing
            DoBattleRez = true,
        },
        layerAssignments = {
            UseDivineArbitration = "emergency",
            UseCelestialRegen = "emergency",
            UseSanctuary = "emergency",
            DoHealing = "support",
            DoGroupHeals = "support",
            DoHoTs = "support",
            DoDichoHeal = "support",
            DoCompleteHeal = "support",
            DoIntervention = "support",
            DoCures = "support",
            DoCureAA = "support",
            DoCureSpells = "support",
            DoDPS = "combat",
            DoContravention = "combat",
            DoTwinHealNuke = "combat",
            DoHealStun = "combat",
            DoUndeadNuke = "combat",
            DoMagicNuke = "combat",
            UseBurns = "burn",
            DoVetAA = "burn",
            DoACBuff = "buff",
            DoVieBuff = "buff",
            DoShining = "buff",
            DoDivineBuff = "buff",
            DoBattleRez = "buff",
        },
        layerOrder = {
            emergency = {"UseDivineArbitration", "UseCelestialRegen", "UseSanctuary"},
            support = {"DoHealing", "DoGroupHeals", "DoDichoHeal", "DoIntervention", "DoCures", "DoCureAA", "DoHoTs", "DoCompleteHeal", "DoCureSpells"},
            combat = {"DoContravention", "DoTwinHealNuke", "DoHealStun", "DoUndeadNuke", "DoMagicNuke", "DoDPS"},
            burn = {"UseBurns", "DoVetAA"},
            buff = {"DoBattleRez", "DoVieBuff", "DoShining", "DoDivineBuff", "DoACBuff"},
        },
    },
}

-- Buff Lines: Definitions for automatic buff casting
-- Used by automation/buff.lua to know what to buff on group/self
M.buffLines = {
    -- AC Buff (tank)
    ACBuff = {
        spellLine = 'ACBuff',
        targets = 'group',
        rebuffWindow = 120,
        outOfCombatOnly = true,
        settingKey = 'DoACBuff',
    },
    -- Vie Buff (melee damage absorb)
    VieBuff = {
        spellLine = 'SingleVieBuff',
        groupSpellLine = 'GroupVieBuff',
        targets = 'group',
        rebuffWindow = 120,
        outOfCombatOnly = true,
        settingKey = 'DoVieBuff',
    },
    -- Shining Buff (tank armor)
    ShiningBuff = {
        spellLine = 'ShiningBuff',
        targets = 'group',
        rebuffWindow = 120,
        outOfCombatOnly = true,
        settingKey = 'DoShining',
    },
    -- Divine Buff (death save)
    DivineBuff = {
        spellLine = 'DivineBuff',
        targets = 'group',
        rebuffWindow = 120,
        outOfCombatOnly = true,
        settingKey = 'DoDivineBuff',
    },
    -- Symbol (HP/mana regen)
    SymbolBuff = {
        spellLine = 'GroupSymbolBuff',
        targets = 'group',
        rebuffWindow = 120,
        outOfCombatOnly = true,
    },
    -- Aegolism (HP buff)
    AegoBuff = {
        spellLine = 'AegoBuff',
        targets = 'group',
        rebuffWindow = 120,
        outOfCombatOnly = true,
    },
    -- Ward (self rune)
    WardBuff = {
        spellLine = 'WardBuff',
        targets = 'self',
        rebuffWindow = 60,
        outOfCombatOnly = true,
    },
}

-- Class-specific Settings
-- AbilitySet links to spellLines for spell resolution and icon display
M.Settings = {
    -- === Healing ===
    DoHealing = {
        Default = true,
        Category = "Heal",
        DisplayName = "Enable Healing",
        Tooltip = "Enable automatic healing",
        AbilitySet = "RemedyHeal",  -- Primary single target heal line
    },
    DoGroupHeals = {
        Default = true,
        Category = "Heal",
        DisplayName = "Use Group Heals",
        Tooltip = "Use group heal spells when multiple injured",
        AbilitySet = "GroupHealCure",  -- Primary group heal line
    },
    DoHoTs = {
        Default = true,
        Category = "Heal",
        DisplayName = "Use HoTs",
        Tooltip = "Use heal-over-time spells",
        AbilitySet = "GroupElixir",  -- Group HoT line
    },
    DoDichoHeal = {
        Default = true,
        Category = "Heal",
        DisplayName = "Use Dicho Heal",
        Tooltip = "Use Dichotomic/Dissident healing line",
        AbilitySet = "DichoHeal",
    },
    DoCompleteHeal = {
        Default = false,
        Category = "Heal",
        DisplayName = "Use Complete Heal",
        Tooltip = "Use Complete Heal on tank",
        AbilitySet = "CompleteHeal",
    },
    CompleteHealPct = {
        Default = 80,
        Category = "Heal",
        DisplayName = "Complete Heal Pct",
        Tooltip = "HP % to use Complete Heal",
        Min = 1,
        Max = 99,
    },
    DoIntervention = {
        Default = true,
        Category = "Heal",
        DisplayName = "Use Intervention",
        Tooltip = "Use Intervention heal+nuke line",
        AbilitySet = "HealNuke",
    },

    -- === Buffs ===
    AegoSymbol = {
        Default = 1,
        Category = "Buff",
        DisplayName = "Aego/Symbol Choice",
        Tooltip = "1=Aegolism, 2=Both, 3=Symbol, 4=None",
        Min = 1,
        Max = 4,
    },
    DoACBuff = {
        Default = false,
        Category = "Buff",
        DisplayName = "Use AC Buff",
        Tooltip = "Use AC buff on tank",
        AbilitySet = "ACBuff",
    },
    DoVieBuff = {
        Default = true,
        Category = "Buff",
        DisplayName = "Use Vie Buff",
        Tooltip = "Use melee damage absorb buff",
        AbilitySet = "VieBuff",
    },
    DoShining = {
        Default = true,
        Category = "Buff",
        DisplayName = "Use Shining",
        Tooltip = "Use Shining armor buff on tank",
        AbilitySet = "ShiningBuff",
    },
    DoDivineBuff = {
        Default = true,
        Category = "Buff",
        DisplayName = "Use Divine",
        Tooltip = "Use Divine Intervention death save buff",
        AbilitySet = "DivineBuff",
    },
    UseAura = {
        Default = 1,
        Category = "Buff",
        DisplayName = "Aura Choice",
        Tooltip = "1=Absorb, 2=HP, 3=None",
        Min = 1,
        Max = 3,
    },

    -- === Cures ===
    DoCures = {
        Default = true,
        Category = "Cure",
        DisplayName = "Enable Cures",
        Tooltip = "Automatically cure detrimental effects",
        AbilitySet = "CureSpell",
    },
    DoCureAA = {
        Default = true,
        Category = "Cure",
        DisplayName = "Use Cure AAs",
        Tooltip = "Use AA cures (Radiant Cure, etc.)",
        AbilitySet = "RadiantCureAA",
    },
    DoCureSpells = {
        Default = true,
        Category = "Cure",
        DisplayName = "Use Cure Spells",
        Tooltip = "Use spell-based cures",
        AbilitySet = "CureSpell",
    },

    -- === DPS ===
    DoDPS = {
        Default = false,
        Category = "DPS",
        DisplayName = "Enable DPS",
        Tooltip = "Cast damage spells when healing not needed",
        AbilitySet = "NukeHeal",
    },
    DoContravention = {
        Default = true,
        Category = "DPS",
        DisplayName = "Use Contravention",
        Tooltip = "Use nuke+heal spell",
        AbilitySet = "NukeHeal",
    },
    DoTwinHealNuke = {
        Default = true,
        Category = "DPS",
        DisplayName = "Twin Heal Nuke",
        Tooltip = "Use Twin Heal Nuke line",
        AbilitySet = "TwinHealNuke",
    },
    DoHealStun = {
        Default = true,
        Category = "DPS",
        DisplayName = "ToT-Heal Stun",
        Tooltip = "Use Timer 6 stun with ToT heal",
        AbilitySet = "StunTimer6",
    },
    DoUndeadNuke = {
        Default = false,
        Category = "DPS",
        DisplayName = "Undead Nuke",
        Tooltip = "Use undead damage spells",
        AbilitySet = "UndeadNuke",
    },
    DoMagicNuke = {
        Default = false,
        Category = "DPS",
        DisplayName = "Magic Nuke",
        Tooltip = "Use magic damage spells",
        AbilitySet = "MagicNuke",
    },

    -- === Emergency ===
    UseDivineArbitration = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Divine Arbitration",
        Tooltip = "Use when multiple group members critical",
        AbilitySet = "DivineArbitrationAA",
    },
    UseCelestialRegen = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Celestial Regeneration",
        Tooltip = "Use when self HP critical",
        AbilitySet = "CelestialRegenAA",
    },
    UseSanctuary = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Sanctuary",
        Tooltip = "Emergency invulnerability",
        AbilitySet = "SanctuaryAA",
    },

    -- === Mana ===
    DoManaRestore = {
        Default = true,
        Category = "Mana",
        DisplayName = "Use Mana Restore",
        Tooltip = "Use Veturika's Presence or Quiet Prayer",
        AbilitySet = "VeturikasPresenceAA",
    },
    ManaRestorePct = {
        Default = 10,
        Category = "Mana",
        DisplayName = "Mana Restore Pct",
        Tooltip = "Mana % to use restore abilities",
        Min = 1,
        Max = 99,
    },

    -- === Burns ===
    UseBurns = {
        Default = true,
        Category = "Burn",
        DisplayName = "Enable Burns",
        Tooltip = "Use burn abilities when burn active",
        AbilitySet = "FuryOfTheGodsAA",  -- Primary burn AA
    },
    DoVetAA = {
        Default = true,
        Category = "Burn",
        DisplayName = "Use Vet AA",
        Tooltip = "Use Veteran AAs during burns",
        AbilitySet = "IntensityOfResoluteAA",
    },
    DoSpireOfCleric = {
        Default = true,
        Category = "Burn",
        DisplayName = "Spire of the Vicar",
        Tooltip = "Use Spire of the Vicar during burns",
        AbilitySet = "SpireOfClericAA",
    },
    DoImprovedTwincast = {
        Default = true,
        Category = "Burn",
        DisplayName = "Improved Twincast",
        Tooltip = "Use Improved Twincast during burns",
        AbilitySet = "ImprovedTwincastAA",
    },

    -- === Rezzing ===
    DoBattleRez = {
        Default = true,
        Category = "Rez",
        DisplayName = "Battle Rez",
        Tooltip = "Rez during combat using AA",
        AbilitySet = "BlessingOfResAA",
    },
}

return M
