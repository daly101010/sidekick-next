-- F:/lua/SideKick/data/class_configs/NEC.lua
-- Necromancer Class Configuration with condition-based rotations

local mq = require('mq')

local M = {}

-- Spell Lines
M.spellLines = {
    -- Swift DoT (fast cast)
    ['SwiftDoT'] = {
        "Swift Deconstruction", "Swift Decomposition", "Swift Decay",
        "Swift Deterioration", "Swift Degeneracy", "Swift Dissolution",
    },

    -- Poison DoT
    ['PoisonDoT'] = {
        "Pyre of Jorobb", "Pyre of Klraggek", "Pyre of Mori",
        "Pyre of Ferora", "Pyre of Hazarak", "Pyre of Nos",
    },

    -- Disease DoT
    ['DiseaseDoT'] = {
        "Scourge of Fates", "Scourge of Destiny", "Scourge of Helix",
        "Scourge of Luna", "Scourge of the Moors", "Scourge of Death",
    },

    -- Fire DoT
    ['FireDoT'] = {
        "Pyre of the Forgotten", "Pyre of the Wretched", "Pyre of the Lost Hasty",
        "Pyre of the Lost", "Pyre of the Fereth", "Pyre of Marnek",
    },

    -- Corruption DoT
    ['CorruptionDoT'] = {
        "Absolute Corruption", "Ignominious Corruption", "Remorseless Corruption",
        "Merciless Corruption", "Relentless Corruption", "Pitiless Corruption",
    },

    -- Magic DoT
    ['MagicDoT'] = {
        "Grip of Jarati", "Grip of Kraz", "Grip of Mori",
        "Grip of Zorglim", "Grip of Zargo", "Grip of Morstin",
    },

    -- Life Tap
    ['LifeTap'] = {
        "Vampiric Draw", "Siphon Life", "Drain Soul",
        "Touch of Night", "Lifetap", "Siphon",
    },

    -- Pet
    ['Pet'] = {
        "Rekki`s Shades", "Bashi`s Shades", "Tylix`s Shades",
        "Gryme`s Shades", "Azeron`s Shades", "Cadcane`s Shades",
    },

    -- Pet Heal
    ['PetHeal'] = {
        "Mend Companion", "Convoke Shadow", "Renewal of Bones",
    },

    -- Mez (undead)
    ['Mez'] = {
        "Enslave Death", "Command Undead", "Control Undead",
        "Dominate Undead", "Subjugate Undead",
    },

    -- FD
    ['FeignDeath'] = {
        "Death Peace", "Feign Death",
    },

    -- Self Shield
    ['Shield'] = {
        "Bulwark of Shadows", "Shield of Darkness", "Dark Shield",
    },

    -- Lich
    ['Lich'] = {
        "Lich Unity", "Deathly Resolve", "Lich", "Call of Bones",
    },
}

-- AA Lines
M.aaLines = {
    ['DeathBloom'] = { "Death Bloom" },
    ['FeignDeath'] = { "Death Peace", "Feign Death" },
    ['LifeBurn'] = { "Life Burn" },
    ['SpireOfNecro'] = { "Spire of Necromancy" },
    ['FuryOfDeath'] = { "Fury of the Gods" },
    ['WakeTheDead'] = { "Wake the Dead" },
    ['SwarmPet'] = { "Rise of Bones" },
    ['ThoughtLeech'] = { "Thought Leech" },
    ['HandOfDeath'] = { "Hand of Death" },
    ['ImprovedTwincast'] = { "Improved Twincast" },
}

-- Default conditions
M.defaultConditions = {
    ['doDeathBloom'] = function(ctx)
        return ctx.me.pctMana < 30 and ctx.me.pctHPs > 50
    end,
    ['doFeignDeath'] = function(ctx)
        return ctx.me.pctHPs < 20 or ctx.me.pctAggro > 95
    end,
    ['doThoughtLeech'] = function(ctx)
        return ctx.me.pctMana < 40
    end,

    ['doPetHeal'] = function(ctx)
        return ctx.pet.pctHPs and ctx.pet.pctHPs < 60
    end,

    ['doSwiftDoT'] = function(ctx)
        return ctx.combat and not ctx.target.myBuff('Swift')
    end,
    ['doPoisonDoT'] = function(ctx)
        return ctx.combat and not ctx.target.myBuff('Pyre') and ctx.target.pctHPs > 20
    end,
    ['doDiseaseDoT'] = function(ctx)
        return ctx.combat and not ctx.target.myBuff('Scourge') and ctx.target.pctHPs > 20
    end,
    ['doFireDoT'] = function(ctx)
        return ctx.combat and not ctx.target.myBuff('Pyre of the') and ctx.target.pctHPs > 20
    end,
    ['doCorruptionDoT'] = function(ctx)
        return ctx.combat and ctx.target.named and not ctx.target.myBuff('Corruption') and ctx.target.pctHPs > 30
    end,
    ['doMagicDoT'] = function(ctx)
        return ctx.combat and ctx.target.named and not ctx.target.myBuff('Grip') and ctx.target.pctHPs > 30
    end,
    ['doLifeTap'] = function(ctx)
        return ctx.combat and ctx.me.pctHPs < 70
    end,

    ['doMez'] = function(ctx)
        return ctx.me.xTargetCount >= 2 and ctx.target.body == 'Undead'
    end,

    ['doShield'] = function(ctx)
        return not ctx.me.buff('Shield') and not ctx.combat
    end,
    ['doLich'] = function(ctx)
        return not ctx.me.buff('Lich') and ctx.me.pctMana < 80
    end,

    ['doLifeBurn'] = function(ctx)
        return ctx.burn and ctx.target.named and ctx.me.pctHPs > 50
    end,
    ['doSpireOfNecro'] = function(ctx)
        return ctx.burn
    end,
    ['doFuryOfDeath'] = function(ctx)
        return ctx.burn
    end,
    ['doWakeTheDead'] = function(ctx)
        return ctx.burn and ctx.target.named
    end,
    ['doSwarmPet'] = function(ctx)
        return ctx.burn and ctx.combat
    end,
    ['doHandOfDeath'] = function(ctx)
        return ctx.burn and ctx.target.named
    end,
    ['doImprovedTwincast'] = function(ctx)
        return ctx.burn and not ctx.me.buff('Improved Twincast') and not ctx.me.buff('Twincast')
    end,
}

-- Category overrides
M.categoryOverrides = {
    ['doDeathBloom'] = 'emergency',
    ['doFeignDeath'] = 'emergency',
    ['doThoughtLeech'] = 'utility',
    ['doPetHeal'] = 'support',
    ['doSwiftDoT'] = 'combat',
    ['doPoisonDoT'] = 'combat',
    ['doDiseaseDoT'] = 'combat',
    ['doFireDoT'] = 'combat',
    ['doCorruptionDoT'] = 'combat',
    ['doMagicDoT'] = 'combat',
    ['doLifeTap'] = 'combat',
    ['doMez'] = 'support',
    ['doShield'] = 'utility',
    ['doLich'] = 'utility',
    ['doLifeBurn'] = 'burn',
    ['doSpireOfNecro'] = 'burn',
    ['doFuryOfDeath'] = 'burn',
    ['doWakeTheDead'] = 'burn',
    ['doSwarmPet'] = 'burn',
    ['doHandOfDeath'] = 'burn',
    ['doImprovedTwincast'] = 'burn',
}

M.Settings = {
    DoDoTs = {
        Default = true,
        Category = "DPS",
        DisplayName = "Use DoTs",
    },
    DoSwiftDoT = {
        Default = true,
        Category = "DPS",
        DisplayName = "Swift DoT",
    },
    DoLifeTaps = {
        Default = true,
        Category = "DPS",
        DisplayName = "Life Taps",
    },
    DoPetHeals = {
        Default = true,
        Category = "Pet",
        DisplayName = "Heal Pet",
    },
    DoMez = {
        Default = true,
        Category = "CC",
        DisplayName = "Mez Undead",
    },
}

return M
