-- F:/lua/SideKick/data/class_configs/BST.lua
-- Beastlord Class Configuration with condition-based rotations

local mq = require('mq')

local M = {}

-- Spell Lines
M.spellLines = {
    -- Poison Nuke
    ['PoisonNuke'] = {
        "Vkjen's Maelstrom", "Kreig's Maelstrom", "Venon's Maelstrom",
        "Tuvan's Maelstrom", "Sekmoset's Maelstrom", "Isochronism",
    },

    -- Frost Nuke
    ['FrostNuke'] = {
        "Rimeclaw's Cataclysm", "Kron's Cataclysm", "Beramos' Cataclysm",
        "Nak's Cataclysm", "Griklor's Cataclysm", "Tuzil's Cataclysm",
    },

    -- Poison DoT
    ['PoisonDoT'] = {
        "Bloodlust Bite", "Fevered Bite", "Savage Bite",
        "Blistering Bite", "Searing Bite", "Baleful Bite",
    },

    -- Disease DoT
    ['DiseaseDoT'] = {
        "Kron's Malady", "Natureskin Blight", "Festering Malady",
        "Putrid Decay", "Livid Decay", "Fevered Affliction",
    },

    -- Slow
    ['Slow'] = {
        "Sha's Revenge", "Sha's Lethargy", "Sha's Legacy",
        "Drowsy", "Sha's Ferocity",
    },

    -- Pet
    ['Pet'] = {
        "Spirit of Kashek", "Spirit of Lachemit", "Spirit of Kolos",
        "Spirit of Rashara", "Spirit of Oroshar", "Spirit of Alladnu",
    },

    -- Pet Heal
    ['PetHeal'] = {
        "Mend Companion", "Aid of Jorlleag", "Salve of Felicity",
        "Healing of Sorsha", "Mend Warder",
    },

    -- Self Heal
    ['SelfHeal'] = {
        "Trushar's Mending", "Krasir's Mending", "Cadcane's Mending",
        "Sabretooth's Mending", "Salve of Artikla",
    },

    -- Group Heal
    ['GroupHeal'] = {
        "Spiritual Channeling", "Spiritual Swell", "Spiritual Surge",
    },

    -- HP Buff
    ['HPBuff'] = {
        "Peerless Penchant", "Restless Penchant", "Unswerving Penchant",
        "Tenacious Penchant", "Steadfast Penchant",
    },

    -- Ferocity (melee buff)
    ['Ferocity'] = {
        "Ferocity of the Great Bear", "Omakin's Alacrity",
        "Savage Ferocity", "Ferocity",
    },
}

-- Disc Lines
M.discLines = {
    ['SavageRancor'] = { "Savage Rancor" },
    ['Ferociousness'] = { "Ferociousness Discipline" },
    ['Ruaabri'] = { "Ruaabri's Fury" },
    ['Bestial'] = { "Bestial Alignment" },
}

-- AA Lines
M.aaLines = {
    ['Feral'] = { "Feral Swipe" },
    ['GroupBestial'] = { "Group Bestial Alignment" },
    ['Ferociousness'] = { "Ferociousness" },
    ['SpireOfBeastlord'] = { "Spire of the Savage Lord" },
    ['Intensity'] = { "Intensity of the Resolute" },
    ['SavageRage'] = { "Savage Rage" },
    ['Bloodlust'] = { "Bloodlust" },
    ['RoarOfThunder'] = { "Roar of Thunder" },
}

-- Default conditions
M.defaultConditions = {
    ['doFeral'] = function(ctx)
        return ctx.me.pctHPs < 35
    end,

    ['doPetHeal'] = function(ctx)
        return ctx.pet.pctHPs and ctx.pet.pctHPs < 50
    end,
    ['doSelfHeal'] = function(ctx)
        return ctx.me.pctHPs < 60
    end,
    ['doGroupHeal'] = function(ctx)
        return ctx.group.injured(70) >= 2
    end,

    ['doSlow'] = function(ctx)
        return ctx.combat and not ctx.target.myBuff('Sha') and ctx.target.pctHPs > 50
    end,

    ['doPoisonNuke'] = function(ctx)
        return ctx.combat and ctx.me.pctMana > 40
    end,
    ['doFrostNuke'] = function(ctx)
        return ctx.combat
    end,
    ['doPoisonDoT'] = function(ctx)
        return ctx.combat and ctx.target.named and not ctx.target.myBuff('Bite') and ctx.target.pctHPs > 30
    end,
    ['doDiseaseDoT'] = function(ctx)
        return ctx.combat and ctx.target.named and not ctx.target.myBuff('Malady') and ctx.target.pctHPs > 30
    end,

    ['doHPBuff'] = function(ctx)
        return not ctx.combat
    end,
    ['doFerocity'] = function(ctx)
        return not ctx.me.buff('Ferocity') and not ctx.combat
    end,

    ['doSavageRancor'] = function(ctx)
        return ctx.combat and not ctx.pet.buff('Savage')
    end,
    ['doFerociousness'] = function(ctx)
        return ctx.burn and not ctx.me.activeDisc
    end,
    ['doRuaabri'] = function(ctx)
        return ctx.burn
    end,
    ['doBestial'] = function(ctx)
        return ctx.burn
    end,

    ['doGroupBestial'] = function(ctx)
        return ctx.burn
    end,
    ['doSpireOfBeastlord'] = function(ctx)
        return ctx.burn
    end,
    ['doIntensity'] = function(ctx)
        return ctx.burn
    end,
    ['doSavageRage'] = function(ctx)
        return ctx.burn and ctx.combat
    end,
    ['doBloodlust'] = function(ctx)
        return ctx.burn
    end,
    ['doRoarOfThunder'] = function(ctx)
        return ctx.combat and ctx.target.named
    end,
}

-- Category overrides
M.categoryOverrides = {
    ['doFeral'] = 'emergency',
    ['doPetHeal'] = 'support',
    ['doSelfHeal'] = 'support',
    ['doGroupHeal'] = 'support',
    ['doSlow'] = 'support',
    ['doPoisonNuke'] = 'combat',
    ['doFrostNuke'] = 'combat',
    ['doPoisonDoT'] = 'combat',
    ['doDiseaseDoT'] = 'combat',
    ['doHPBuff'] = 'buff',
    ['doFerocity'] = 'buff',
    ['doSavageRancor'] = 'combat',
    ['doFerociousness'] = 'burn',
    ['doRuaabri'] = 'burn',
    ['doBestial'] = 'burn',
    ['doGroupBestial'] = 'burn',
    ['doSpireOfBeastlord'] = 'burn',
    ['doIntensity'] = 'burn',
    ['doSavageRage'] = 'burn',
    ['doBloodlust'] = 'burn',
    ['doRoarOfThunder'] = 'burn',
}

-- AbilitySets: Spell/AA progressions (highest to lowest rank)
M.AbilitySets = {
    -- Poison Nuke
    PoisonNuke = {
        "Vkjen's Maelstrom", "Kreig's Maelstrom", "Venon's Maelstrom",
        "Tuvan's Maelstrom", "Sekmoset's Maelstrom", "Isochronism",
    },
    -- Frost Nuke
    FrostNuke = {
        "Rimeclaw's Cataclysm", "Kron's Cataclysm", "Beramos' Cataclysm",
        "Nak's Cataclysm", "Griklor's Cataclysm", "Tuzil's Cataclysm",
    },
    -- Poison DoT
    PoisonDoT = {
        "Bloodlust Bite", "Fevered Bite", "Savage Bite",
        "Blistering Bite", "Searing Bite", "Baleful Bite",
    },
    -- Disease DoT
    DiseaseDoT = {
        "Kron's Malady", "Natureskin Blight", "Festering Malady",
        "Putrid Decay", "Livid Decay", "Fevered Affliction",
    },
    -- Slow
    Slow = {
        "Sha's Revenge", "Sha's Lethargy", "Sha's Legacy",
        "Drowsy", "Sha's Ferocity",
    },
    -- Pet
    Pet = {
        "Spirit of Kashek", "Spirit of Lachemit", "Spirit of Kolos",
        "Spirit of Rashara", "Spirit of Oroshar", "Spirit of Alladnu",
    },
    -- Pet Heal
    PetHeal = {
        "Mend Companion", "Aid of Jorlleag", "Salve of Felicity",
        "Healing of Sorsha", "Mend Warder",
    },
    -- Self Heal
    SelfHeal = {
        "Trushar's Mending", "Krasir's Mending", "Cadcane's Mending",
        "Sabretooth's Mending", "Salve of Artikla",
    },
    -- Group Heal
    GroupHeal = {
        "Spiritual Channeling", "Spiritual Swell", "Spiritual Surge",
    },
    -- HP Buff
    HPBuff = {
        "Peerless Penchant", "Restless Penchant", "Unswerving Penchant",
        "Tenacious Penchant", "Steadfast Penchant",
    },
    -- Ferocity
    Ferocity = {
        "Ferocity of the Great Bear", "Omakin's Alacrity",
        "Savage Ferocity", "Ferocity",
    },
    -- AA: Feral Swipe
    FeralAA = { "Feral Swipe" },
    -- AA: Group Bestial Alignment
    GroupBestialAA = { "Group Bestial Alignment" },
    -- AA: Ferociousness
    FerociousnessAA = { "Ferociousness" },
    -- AA: Spire of the Savage Lord
    SpireOfBeastlordAA = { "Spire of the Savage Lord" },
    -- AA: Intensity
    IntensityAA = { "Intensity of the Resolute" },
    -- AA: Savage Rage
    SavageRageAA = { "Savage Rage" },
    -- AA: Bloodlust
    BloodlustAA = { "Bloodlust" },
    -- AA: Roar of Thunder
    RoarOfThunderAA = { "Roar of Thunder" },
}

-- SpellLoadouts: Role-based gem assignments with extended schema
M.SpellLoadouts = {
    dps = {
        name = "DPS Focused",
        description = "Maximize damage output",
        gems = {
            [1] = "PoisonNuke",
            [2] = "FrostNuke",
            [3] = "PoisonDoT",
            [4] = "DiseaseDoT",
            [5] = "Slow",
            [6] = "SelfHeal",
            [7] = "PetHeal",
            [8] = "HPBuff",
        },
        defaults = {
            -- DPS
            DoNukes = true,
            DoDoTs = true,
            -- Support
            DoSlow = true,
            DoHealing = true,
            DoPetHeals = true,
            DoGroupHeal = false,
            -- Utility
            DoHPBuff = true,
            DoFerocity = true,
            -- Emergency
            UseFeral = true,
            -- Burns
            UseFerociousness = true,
            UseRuaabri = true,
            UseBestial = true,
            UseGroupBestial = true,
            UseSpireOfBeastlord = true,
            UseIntensity = true,
            UseSavageRage = true,
            UseBloodlust = true,
            UseRoarOfThunder = true,
        },
        layerAssignments = {
            -- Emergency
            UseFeral = "emergency",
            -- Support
            DoSlow = "support",
            DoHealing = "support",
            DoPetHeals = "support",
            DoGroupHeal = "support",
            -- Combat
            DoNukes = "combat",
            DoDoTs = "combat",
            -- Burn
            UseFerociousness = "burn",
            UseRuaabri = "burn",
            UseBestial = "burn",
            UseGroupBestial = "burn",
            UseSpireOfBeastlord = "burn",
            UseIntensity = "burn",
            UseSavageRage = "burn",
            UseBloodlust = "burn",
            UseRoarOfThunder = "burn",
            -- Buff
            DoHPBuff = "buff",
            DoFerocity = "buff",
        },
        layerOrder = {
            emergency = {"UseFeral"},
            support = {"DoSlow", "DoHealing", "DoPetHeals", "DoGroupHeal"},
            combat = {"DoNukes", "DoDoTs"},
            burn = {"UseFerociousness", "UseRuaabri", "UseBestial", "UseGroupBestial", "UseSpireOfBeastlord", "UseIntensity", "UseSavageRage", "UseBloodlust", "UseRoarOfThunder"},
            buff = {"DoHPBuff", "DoFerocity"},
        },
    },
    hybrid = {
        name = "Hybrid Support",
        description = "Balance damage and healing",
        gems = {
            [1] = "PoisonNuke",
            [2] = "Slow",
            [3] = "SelfHeal",
            [4] = "GroupHeal",
            [5] = "PetHeal",
            [6] = "HPBuff",
            [7] = "Ferocity",
            [8] = "PoisonDoT",
        },
        defaults = {
            DoNukes = true,
            DoDoTs = true,
            DoSlow = true,
            DoHealing = true,
            DoPetHeals = true,
            DoGroupHeal = true,
            DoHPBuff = true,
            DoFerocity = true,
            UseFeral = true,
            UseFerociousness = true,
            UseRuaabri = true,
            UseBestial = true,
            UseGroupBestial = true,
            UseSpireOfBeastlord = true,
            UseIntensity = true,
            UseSavageRage = true,
            UseBloodlust = true,
            UseRoarOfThunder = true,
        },
        layerAssignments = {
            UseFeral = "emergency",
            DoSlow = "support",
            DoHealing = "support",
            DoPetHeals = "support",
            DoGroupHeal = "support",
            DoNukes = "combat",
            DoDoTs = "combat",
            UseFerociousness = "burn",
            UseRuaabri = "burn",
            UseBestial = "burn",
            UseGroupBestial = "burn",
            UseSpireOfBeastlord = "burn",
            UseIntensity = "burn",
            UseSavageRage = "burn",
            UseBloodlust = "burn",
            UseRoarOfThunder = "burn",
            DoHPBuff = "utility",
            DoFerocity = "utility",
        },
        layerOrder = {
            emergency = {"UseFeral"},
            support = {"DoSlow", "DoHealing", "DoGroupHeal", "DoPetHeals"},
            combat = {"DoNukes", "DoDoTs"},
            burn = {"UseGroupBestial", "UseFerociousness", "UseRuaabri", "UseBestial", "UseSpireOfBeastlord", "UseIntensity", "UseSavageRage", "UseBloodlust", "UseRoarOfThunder"},
            buff = {"DoHPBuff", "DoFerocity"},
        },
    },
}

M.Settings = {
    DoHealing = {
        Default = true,
        Category = "Heal",
        DisplayName = "Enable Healing",
    },
    DoGroupHeal = {
        Default = false,
        Category = "Heal",
        DisplayName = "Group Heal",
    },
    DoSlow = {
        Default = true,
        Category = "Debuff",
        DisplayName = "Auto-Slow",
    },
    DoNukes = {
        Default = true,
        Category = "DPS",
        DisplayName = "Use Nukes",
    },
    DoDoTs = {
        Default = true,
        Category = "DPS",
        DisplayName = "Use DoTs",
    },
    DoPetHeals = {
        Default = true,
        Category = "Pet",
        DisplayName = "Heal Pet",
    },
    DoHPBuff = {
        Default = true,
        Category = "Buff",
        DisplayName = "HP Buff",
    },
    DoFerocity = {
        Default = true,
        Category = "Buff",
        DisplayName = "Ferocity",
    },
    UseFeral = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Feral",
    },
    UseFerociousness = {
        Default = true,
        Category = "Burn",
        DisplayName = "Ferociousness",
    },
    UseRuaabri = {
        Default = true,
        Category = "Burn",
        DisplayName = "Ruaabri's Fury",
    },
    UseBestial = {
        Default = true,
        Category = "Burn",
        DisplayName = "Bestial Alignment",
    },
    UseGroupBestial = {
        Default = true,
        Category = "Burn",
        DisplayName = "Group Bestial",
    },
    UseSpireOfBeastlord = {
        Default = true,
        Category = "Burn",
        DisplayName = "Spire of Beastlord",
    },
    UseIntensity = {
        Default = true,
        Category = "Burn",
        DisplayName = "Intensity",
    },
    UseSavageRage = {
        Default = true,
        Category = "Burn",
        DisplayName = "Savage Rage",
    },
    UseBloodlust = {
        Default = true,
        Category = "Burn",
        DisplayName = "Bloodlust",
    },
    UseRoarOfThunder = {
        Default = true,
        Category = "Burn",
        DisplayName = "Roar of Thunder",
    },
}

return M
