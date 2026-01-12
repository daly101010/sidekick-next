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
    ['doHPBuff'] = 'utility',
    ['doFerocity'] = 'utility',
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

M.Settings = {
    DoHealing = {
        Default = true,
        Category = "Heal",
        DisplayName = "Enable Healing",
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
}

return M
