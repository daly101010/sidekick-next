-- F:/lua/SideKick/data/class_configs/SHM.lua
-- Shaman Class Configuration with condition-based rotations

local mq = require('mq')

local M = {}

-- Spell Lines: Ordered newest to oldest for resolution
M.spellLines = {
    -- Reckless Heal 1 (fast heal)
    ['RecklessHeal1'] = {
        "Reckless Reinvigoration", "Reckless Resurgence", "Reckless Renewal",
        "Reckless Regeneration", "Reckless Rejuvenation", "Reckless Restoration",
        "Reckless Mending", "Reckless Remedy", "Reckless Healing",
    },

    -- Reckless Heal 2 (second fast heal)
    ['RecklessHeal2'] = {
        "Reckless Reinvigoration", "Reckless Resurgence", "Reckless Renewal",
        "Reckless Regeneration", "Reckless Rejuvenation", "Reckless Restoration",
    },

    -- Recourse Heal
    ['RecourseHeal'] = {
        "Grayleaf's Recourse", "Krasir's Recourse", "Blezon's Recourse",
        "Qirik's Recourse", "Gotikan's Recourse", "Eyrzekla's Recourse",
        "Zrelik's Recourse", "Rowain's Recourse", "Dannal's Recourse",
    },

    -- Intervention Heal (big heal)
    ['InterventionHeal'] = {
        "Immortal Intervention", "Antediluvian Intervention", "Primordial Intervention",
        "Prehistoric Intervention", "Ancestral Intervention", "Preternatural Intervention",
    },

    -- AE Spiritual Heal
    ['AESpiritualHeal'] = {
        "Spiritual Shower", "Spiritual Swell", "Spiritual Surge",
        "Spiritual Squall", "Spiritual Serenity", "Spiritual Salve",
    },

    -- Group Renewal HoT
    ['GroupRenewalHoT'] = {
        "Reverie of Renewal", "Spirit of Renewal", "Specter of Renewal",
        "Shadow of Renewal", "Phantom of Renewal", "Penumbra of Renewal",
    },

    -- Slow (single target)
    ['Slow'] = {
        "Turgur's Swarm", "Turgur's Virulent Swarm", "Turgur's Insects",
        "Balance of Discord", "Balance of the Nihil", "Turgur's Insects",
        "Drowsy", "Walking Sleep", "Tagar's Insects",
    },

    -- Malo (magic resist debuff)
    ['Malo'] = {
        "Wind of Malosinera", "Wind of Malaise", "Malosinara",
        "Malosinete", "Malosinia", "Malosini", "Malo",
    },

    -- Cripple (stat debuff)
    ['Cripple'] = {
        "Crippling Spasm", "Crippling Parasite", "Listless Power",
        "Incapacity", "Cripple",
    },

    -- Poison DoT
    ['PoisonDoT'] = {
        "Nectar of Agony", "Nectar of Suffering", "Nectar of Pain",
        "Nectar of Torment", "Nectar of Affliction", "Nectar of Misery",
        "Sting of the Queen", "Venom of the Snake", "Poison",
    },

    -- Disease DoT
    ['DiseaseDoT'] = {
        "Malady of Mori", "Malady of the Priest", "Scourge of Fates",
        "Scourge of Destiny", "Breath of Ultor", "Plague",
    },

    -- Poison Nuke
    ['PoisonNuke'] = {
        "Oka's Venom", "Bledrek's Venom", "Yoppa's Venom",
        "Nexona's Venom", "Serpent's Venom", "Venomous Blast",
    },

    -- Cure Disease
    ['CureDisease'] = {
        "Blood of Corbeth", "Blood of Sanera", "Blood of Nadox",
        "Cure Disease", "Counteract Disease", "Remove Disease",
    },

    -- Cure Poison
    ['CurePoison'] = {
        "Blood of Corbeth", "Blood of Sanera", "Blood of Nadox",
        "Cure Poison", "Counteract Poison", "Remove Poison",
    },

    -- Cannibalize
    ['Cannibalize'] = {
        "Cannibalize VIII", "Cannibalize VII", "Cannibalize VI",
        "Cannibalize V", "Cannibalize IV", "Cannibalize III",
        "Cannibalize II", "Cannibalize",
    },

    -- Pet
    ['Pet'] = {
        "Spirit of Zehkes", "Spirit of Oroshar", "Spirit of Averc",
        "Spirit of Rashara", "Spirit of Kolos", "Spirit of Lachemit",
        "Companion Spirit", "Spirit Servant",
    },

    -- Pet Heal
    ['PetHeal'] = {
        "Mend Companion", "Aid of Jorlleag", "Savage Spirit",
    },

    -- Haste
    ['Haste'] = {
        "Talisman of the Faithful", "Talisman of the Devoted",
        "Talisman of Celerity", "Talisman of Alacrity",
        "Talisman of the Raptor", "Celerity",
    },

    -- HP Buff
    ['HPBuff'] = {
        "Talisman of the Resolute", "Talisman of the Steadfast",
        "Talisman of the Enduring", "Focus of Soul",
        "Talisman of Fortuna", "Talisman of Jasinth",
    },

    -- Regen Buff
    ['RegenBuff'] = {
        "Talisman of the Tenacious", "Talisman of the Unwavering",
        "Talisman of the Unflinching", "Talisman of the Stoic",
        "Chloroblast", "Regeneration",
    },
}

-- AA Lines
M.aaLines = {
    ['AncestralGuard'] = { "Ancestral Guard" },
    ['UnionOfSpirits'] = { "Union of Spirits" },
    ['SpiritGuardian'] = { "Spirit Guardian" },
    ['CallOfTheAncients'] = { "Call of the Ancients" },
    ['RabidBear'] = { "Rabid Bear" },
    ['SpireOfAncestors'] = { "Spire of the Ancestors" },
    ['EpicClick'] = { "Prophet's Gift of the Ruchu", "Blessed Spiritstaff of the Heyokah" },
}

-- Default conditions
M.defaultConditions = {
    -- Emergency
    ['doAncestralGuard'] = function(ctx)
        return ctx.me.pctHPs < 30
    end,
    ['doUnionOfSpirits'] = function(ctx)
        return ctx.group.lowestHP < 40 and ctx.group.injured(60) >= 2
    end,

    -- Healing
    ['doRecklessHeal1'] = function(ctx)
        return ctx.group.lowestHP < 75
    end,
    ['doRecklessHeal2'] = function(ctx)
        return ctx.group.lowestHP < 65 and ctx.group.injured(80) >= 2
    end,
    ['doRecourseHeal'] = function(ctx)
        return ctx.group.lowestHP < 80
    end,
    ['doInterventionHeal'] = function(ctx)
        return ctx.group.lowestHP < 50
    end,
    ['doAESpiritualHeal'] = function(ctx)
        return ctx.group.injured(70) >= 3
    end,
    ['doGroupRenewalHoT'] = function(ctx)
        return ctx.group.injured(85) >= 2 and not ctx.combat
    end,

    -- Debuffs
    ['doSlow'] = function(ctx)
        return ctx.combat and not ctx.target.myBuff('Turgur') and ctx.target.pctHPs > 50
    end,
    ['doMalo'] = function(ctx)
        return ctx.combat and not ctx.target.myBuff('Malo') and (ctx.target.named or ctx.me.xTargetCount >= 2)
    end,
    ['doCripple'] = function(ctx)
        return ctx.combat and not ctx.target.myBuff('Cripple') and ctx.target.named
    end,

    -- DoTs
    ['doPoisonDoT'] = function(ctx)
        return ctx.combat and ctx.target.named and not ctx.target.myBuff('Nectar') and ctx.target.pctHPs > 30
    end,
    ['doDiseaseDoT'] = function(ctx)
        return ctx.combat and ctx.target.named and not ctx.target.myBuff('Scourge') and ctx.target.pctHPs > 30
    end,

    -- Nukes
    ['doPoisonNuke'] = function(ctx)
        return ctx.combat and ctx.me.pctMana > 40 and ctx.target.pctHPs > 20
    end,

    -- Self
    ['doCannibalize'] = function(ctx)
        return ctx.me.pctMana < 50 and ctx.me.pctHPs > 60 and not ctx.combat
    end,

    -- Buffs
    ['doHaste'] = function(ctx)
        return not ctx.combat
    end,
    ['doHPBuff'] = function(ctx)
        return not ctx.combat
    end,
    ['doRegenBuff'] = function(ctx)
        return not ctx.combat
    end,

    -- Burn
    ['doSpireOfAncestors'] = function(ctx)
        return ctx.burn
    end,
    ['doRabidBear'] = function(ctx)
        return ctx.burn and ctx.combat
    end,
}

-- Category overrides
M.categoryOverrides = {
    ['doAncestralGuard'] = 'emergency',
    ['doUnionOfSpirits'] = 'emergency',
    ['doRecklessHeal1'] = 'support',
    ['doRecklessHeal2'] = 'support',
    ['doRecourseHeal'] = 'support',
    ['doInterventionHeal'] = 'support',
    ['doAESpiritualHeal'] = 'support',
    ['doGroupRenewalHoT'] = 'support',
    ['doSlow'] = 'support',
    ['doMalo'] = 'support',
    ['doCripple'] = 'support',
    ['doPoisonDoT'] = 'combat',
    ['doDiseaseDoT'] = 'combat',
    ['doPoisonNuke'] = 'combat',
    ['doCannibalize'] = 'buff',
    ['doHaste'] = 'buff',
    ['doHPBuff'] = 'buff',
    ['doRegenBuff'] = 'buff',
    ['doSpireOfAncestors'] = 'burn',
    ['doRabidBear'] = 'burn',
}

-- AbilitySets: Spell/AA progressions (highest to lowest rank)
M.AbilitySets = {
    -- Heals (Reckless line)
    RecklessHeal1 = {
        "Reckless Reinvigoration", "Reckless Resurgence", "Reckless Renewal",
        "Reckless Regeneration", "Reckless Rejuvenation", "Reckless Restoration",
        "Reckless Mending", "Reckless Remedy", "Reckless Healing",
    },
    RecklessHeal2 = {
        "Reckless Reinvigoration", "Reckless Resurgence", "Reckless Renewal",
        "Reckless Regeneration", "Reckless Rejuvenation", "Reckless Restoration",
    },
    -- Recourse Heal
    RecourseHeal = {
        "Grayleaf's Recourse", "Krasir's Recourse", "Blezon's Recourse",
        "Qirik's Recourse", "Gotikan's Recourse", "Eyrzekla's Recourse",
        "Zrelik's Recourse", "Rowain's Recourse", "Dannal's Recourse",
    },
    -- Intervention Heal
    InterventionHeal = {
        "Immortal Intervention", "Antediluvian Intervention", "Primordial Intervention",
        "Prehistoric Intervention", "Ancestral Intervention", "Preternatural Intervention",
    },
    -- AE Spiritual Heal
    AESpiritualHeal = {
        "Spiritual Shower", "Spiritual Swell", "Spiritual Surge",
        "Spiritual Squall", "Spiritual Serenity", "Spiritual Salve",
    },
    -- Group Renewal HoT
    GroupRenewalHoT = {
        "Reverie of Renewal", "Spirit of Renewal", "Specter of Renewal",
        "Shadow of Renewal", "Phantom of Renewal", "Penumbra of Renewal",
    },
    -- Slow
    SlowSpell = {
        "Turgur's Swarm", "Turgur's Virulent Swarm", "Turgur's Insects",
        "Balance of Discord", "Balance of the Nihil", "Drowsy", "Walking Sleep",
    },
    -- Malo
    MaloSpell = {
        "Wind of Malosinera", "Wind of Malaise", "Malosinara",
        "Malosinete", "Malosinia", "Malosini", "Malo",
    },
    -- Cripple
    CrippleSpell = {
        "Crippling Spasm", "Crippling Parasite", "Listless Power",
        "Incapacity", "Cripple",
    },
    -- Poison DoT
    PoisonDoT = {
        "Nectar of Agony", "Nectar of Suffering", "Nectar of Pain",
        "Nectar of Torment", "Nectar of Affliction", "Nectar of Misery",
    },
    -- Disease DoT
    DiseaseDoT = {
        "Malady of Mori", "Malady of the Priest", "Scourge of Fates",
        "Scourge of Destiny", "Breath of Ultor", "Plague",
    },
    -- Poison Nuke
    PoisonNuke = {
        "Oka's Venom", "Bledrek's Venom", "Yoppa's Venom",
        "Nexona's Venom", "Serpent's Venom", "Venomous Blast",
    },
    -- Cannibalize
    Cannibalize = {
        "Cannibalize VIII", "Cannibalize VII", "Cannibalize VI",
        "Cannibalize V", "Cannibalize IV", "Cannibalize III",
        "Cannibalize II", "Cannibalize",
    },
    -- Pet
    Pet = {
        "Spirit of Zehkes", "Spirit of Oroshar", "Spirit of Averc",
        "Spirit of Rashara", "Spirit of Kolos", "Spirit of Lachemit",
    },
    -- Haste
    Haste = {
        "Talisman of the Faithful", "Talisman of the Devoted",
        "Talisman of Celerity", "Talisman of Alacrity",
    },
    -- HP Buff
    HPBuff = {
        "Talisman of the Resolute", "Talisman of the Steadfast",
        "Talisman of the Enduring", "Focus of Soul",
    },
    -- Regen Buff
    RegenBuff = {
        "Talisman of the Tenacious", "Talisman of the Unwavering",
        "Talisman of the Unflinching", "Talisman of the Stoic",
    },
    -- Cure All
    CureAllSpell = {
        "Blood of Rivans", "Blood of Sanera", "Blood of Corbeth", "Blood of Klar",
    },
    -- AA: Ancestral Guard
    AncestralGuardAA = { "Ancestral Guard" },
    -- AA: Union of Spirits
    UnionOfSpiritsAA = { "Union of Spirits" },
    -- AA: Spirit Guardian
    SpiritGuardianAA = { "Spirit Guardian" },
    -- AA: Call of the Ancients
    CallOfTheAncientsAA = { "Call of the Ancients" },
    -- AA: Rabid Bear
    RabidBearAA = { "Rabid Bear" },
    -- AA: Spire of the Ancestors
    SpireOfAncestorsAA = { "Spire of the Ancestors" },
}

-- SpellLoadouts: Role-based gem assignments with extended schema
M.SpellLoadouts = {
    heal = {
        name = "Healing Focused",
        description = "Focus on healing and HoTs",
        gems = {
            [1] = "RecklessHeal1",
            [2] = "RecklessHeal2",
            [3] = "InterventionHeal",
            [4] = "AESpiritualHeal",
            [5] = "GroupRenewalHoT",
            [6] = "SlowSpell",
            [7] = "MaloSpell",
            [8] = "Cannibalize",
        },
        defaults = {
            -- Healing
            DoHealing = true,
            DoGroupHeals = true,
            DoHoTs = true,
            -- Debuffs
            DoSlow = true,
            DoMalo = true,
            DoCripple = false,
            -- DPS (minimal)
            DoDoTs = false,
            DoNukes = false,
            -- Utility
            DoCannibalize = true,
            DoHaste = true,
            DoHPBuff = true,
            DoRegenBuff = true,
            -- Emergency
            UseAncestralGuard = true,
            UseUnionOfSpirits = true,
            -- Burns
            UseSpireOfAncestors = true,
            UseRabidBear = true,
        },
        layerAssignments = {
            -- Emergency
            UseAncestralGuard = "emergency",
            UseUnionOfSpirits = "emergency",
            -- Support (healing primary)
            DoHealing = "support",
            DoGroupHeals = "support",
            DoHoTs = "support",
            DoSlow = "support",
            DoMalo = "support",
            DoCripple = "support",
            -- Combat
            DoDoTs = "combat",
            DoNukes = "combat",
            -- Burn
            UseSpireOfAncestors = "burn",
            UseRabidBear = "burn",
            -- Buff
            DoCannibalize = "buff",
            DoHaste = "buff",
            DoHPBuff = "buff",
            DoRegenBuff = "buff",
        },
        layerOrder = {
            emergency = {"UseAncestralGuard", "UseUnionOfSpirits"},
            support = {"DoHealing", "DoGroupHeals", "DoHoTs", "DoSlow", "DoMalo", "DoCripple"},
            combat = {"DoDoTs", "DoNukes"},
            burn = {"UseSpireOfAncestors", "UseRabidBear"},
            buff = {"DoCannibalize", "DoHaste", "DoHPBuff", "DoRegenBuff"},
        },
    },
    debuff = {
        name = "Debuff Focused",
        description = "Focus on slowing and debuffing",
        gems = {
            [1] = "SlowSpell",
            [2] = "MaloSpell",
            [3] = "CrippleSpell",
            [4] = "RecklessHeal1",
            [5] = "AESpiritualHeal",
            [6] = "PoisonDoT",
            [7] = "DiseaseDoT",
            [8] = "Cannibalize",
        },
        defaults = {
            -- Healing (essential)
            DoHealing = true,
            DoGroupHeals = true,
            DoHoTs = false,
            -- Debuffs (primary)
            DoSlow = true,
            DoMalo = true,
            DoCripple = true,
            -- DPS
            DoDoTs = true,
            DoNukes = false,
            -- Utility
            DoCannibalize = true,
            DoHaste = true,
            DoHPBuff = true,
            DoRegenBuff = false,
            -- Emergency
            UseAncestralGuard = true,
            UseUnionOfSpirits = true,
            -- Burns
            UseSpireOfAncestors = true,
            UseRabidBear = true,
        },
        layerAssignments = {
            UseAncestralGuard = "emergency",
            UseUnionOfSpirits = "emergency",
            DoHealing = "support",
            DoGroupHeals = "support",
            DoHoTs = "support",
            DoSlow = "support",
            DoMalo = "support",
            DoCripple = "support",
            DoDoTs = "combat",
            DoNukes = "combat",
            UseSpireOfAncestors = "burn",
            UseRabidBear = "burn",
            DoCannibalize = "utility",
            DoHaste = "utility",
            DoHPBuff = "utility",
            DoRegenBuff = "utility",
        },
        layerOrder = {
            emergency = {"UseAncestralGuard", "UseUnionOfSpirits"},
            support = {"DoSlow", "DoMalo", "DoCripple", "DoHealing", "DoGroupHeals", "DoHoTs"},
            combat = {"DoDoTs", "DoNukes"},
            burn = {"UseSpireOfAncestors", "UseRabidBear"},
            buff = {"DoCannibalize", "DoHaste", "DoHPBuff", "DoRegenBuff"},
        },
    },
    dps = {
        name = "DPS Focused",
        description = "Maximize damage with DoTs and nukes",
        gems = {
            [1] = "PoisonNuke",
            [2] = "PoisonDoT",
            [3] = "DiseaseDoT",
            [4] = "SlowSpell",
            [5] = "MaloSpell",
            [6] = "RecklessHeal1",
            [7] = "AESpiritualHeal",
            [8] = "Cannibalize",
        },
        defaults = {
            -- Healing (essential)
            DoHealing = true,
            DoGroupHeals = true,
            DoHoTs = false,
            -- Debuffs
            DoSlow = true,
            DoMalo = true,
            DoCripple = false,
            -- DPS (primary)
            DoDoTs = true,
            DoNukes = true,
            -- Utility
            DoCannibalize = true,
            DoHaste = false,
            DoHPBuff = false,
            DoRegenBuff = false,
            -- Emergency
            UseAncestralGuard = true,
            UseUnionOfSpirits = true,
            -- Burns
            UseSpireOfAncestors = true,
            UseRabidBear = true,
        },
        layerAssignments = {
            UseAncestralGuard = "emergency",
            UseUnionOfSpirits = "emergency",
            DoHealing = "support",
            DoGroupHeals = "support",
            DoHoTs = "support",
            DoSlow = "support",
            DoMalo = "support",
            DoCripple = "support",
            DoDoTs = "combat",
            DoNukes = "combat",
            UseSpireOfAncestors = "burn",
            UseRabidBear = "burn",
            DoCannibalize = "utility",
            DoHaste = "utility",
            DoHPBuff = "utility",
            DoRegenBuff = "utility",
        },
        layerOrder = {
            emergency = {"UseAncestralGuard", "UseUnionOfSpirits"},
            support = {"DoSlow", "DoMalo", "DoHealing", "DoGroupHeals", "DoCripple", "DoHoTs"},
            combat = {"DoDoTs", "DoNukes"},
            burn = {"UseRabidBear", "UseSpireOfAncestors"},
            buff = {"DoCannibalize", "DoHaste", "DoHPBuff", "DoRegenBuff"},
        },
    },
}

-- Class-specific settings
M.Settings = {
    DoHealing = {
        Default = true,
        Category = "Heal",
        DisplayName = "Enable Healing",
        Tooltip = "Enable automatic healing",
        AbilitySet = "RecklessHeal1",
    },
    DoGroupHeals = {
        Default = true,
        Category = "Heal",
        DisplayName = "Use Group Heals",
        Tooltip = "Use group heal spells",
        AbilitySet = "AESpiritualHeal",
    },
    DoHoTs = {
        Default = true,
        Category = "Heal",
        DisplayName = "Use HoTs",
        Tooltip = "Use heal-over-time spells",
        AbilitySet = "GroupRenewalHoT",
    },
    DoIntervention = {
        Default = true,
        Category = "Heal",
        DisplayName = "Use Intervention",
        Tooltip = "Use intervention heal line",
        AbilitySet = "InterventionHeal",
    },
    DoSlow = {
        Default = true,
        Category = "Debuff",
        DisplayName = "Auto-Slow",
        Tooltip = "Automatically slow targets",
        AbilitySet = "SlowSpell",
    },
    DoMalo = {
        Default = true,
        Category = "Debuff",
        DisplayName = "Auto-Malo",
        Tooltip = "Automatically malo targets",
        AbilitySet = "MaloSpell",
    },
    DoCripple = {
        Default = false,
        Category = "Debuff",
        DisplayName = "Auto-Cripple",
        Tooltip = "Automatically cripple named targets",
        AbilitySet = "CrippleSpell",
    },
    DoDoTs = {
        Default = true,
        Category = "DPS",
        DisplayName = "Use DoTs",
        Tooltip = "Use damage-over-time spells",
        AbilitySet = "PoisonDoT",
    },
    DoNukes = {
        Default = true,
        Category = "DPS",
        DisplayName = "Use Nukes",
        Tooltip = "Use direct damage spells",
        AbilitySet = "PoisonNuke",
    },
    DoCures = {
        Default = true,
        Category = "Cure",
        DisplayName = "Enable Cures",
        Tooltip = "Automatically cure detrimental effects",
        AbilitySet = "CureAllSpell",
    },
    DoCannibalize = {
        Default = true,
        Category = "Self",
        DisplayName = "Cannibalize",
        Tooltip = "Convert HP to mana when low",
        AbilitySet = "Cannibalize",
    },
    DoPet = {
        Default = true,
        Category = "Pet",
        DisplayName = "Use Pet",
        Tooltip = "Summon and control pet",
        AbilitySet = "Pet",
    },
}

return M
