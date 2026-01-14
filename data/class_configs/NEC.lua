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
    ['doThoughtLeech'] = 'buff',
    ['doPetHeal'] = 'support',
    ['doSwiftDoT'] = 'combat',
    ['doPoisonDoT'] = 'combat',
    ['doDiseaseDoT'] = 'combat',
    ['doFireDoT'] = 'combat',
    ['doCorruptionDoT'] = 'combat',
    ['doMagicDoT'] = 'combat',
    ['doLifeTap'] = 'combat',
    ['doMez'] = 'support',
    ['doShield'] = 'buff',
    ['doLich'] = 'buff',
    ['doLifeBurn'] = 'burn',
    ['doSpireOfNecro'] = 'burn',
    ['doFuryOfDeath'] = 'burn',
    ['doWakeTheDead'] = 'burn',
    ['doSwarmPet'] = 'burn',
    ['doHandOfDeath'] = 'burn',
    ['doImprovedTwincast'] = 'burn',
}

-- AbilitySets: Spell/AA progressions (highest to lowest rank)
M.AbilitySets = {
    -- Swift DoT
    SwiftDoT = {
        "Swift Deconstruction", "Swift Decomposition", "Swift Decay",
        "Swift Deterioration", "Swift Degeneracy", "Swift Dissolution",
    },
    -- Poison DoT
    PoisonDoT = {
        "Pyre of Jorobb", "Pyre of Klraggek", "Pyre of Mori",
        "Pyre of Ferora", "Pyre of Hazarak", "Pyre of Nos",
    },
    -- Disease DoT
    DiseaseDoT = {
        "Scourge of Fates", "Scourge of Destiny", "Scourge of Helix",
        "Scourge of Luna", "Scourge of the Moors", "Scourge of Death",
    },
    -- Fire DoT
    FireDoT = {
        "Pyre of the Forgotten", "Pyre of the Wretched", "Pyre of the Lost Hasty",
        "Pyre of the Lost", "Pyre of the Fereth", "Pyre of Marnek",
    },
    -- Corruption DoT
    CorruptionDoT = {
        "Absolute Corruption", "Ignominious Corruption", "Remorseless Corruption",
        "Merciless Corruption", "Relentless Corruption", "Pitiless Corruption",
    },
    -- Magic DoT
    MagicDoT = {
        "Grip of Jarati", "Grip of Kraz", "Grip of Mori",
        "Grip of Zorglim", "Grip of Zargo", "Grip of Morstin",
    },
    -- Life Tap
    LifeTap = {
        "Vampiric Draw", "Siphon Life", "Drain Soul",
        "Touch of Night", "Lifetap", "Siphon",
    },
    -- Pet
    Pet = {
        "Rekki`s Shades", "Bashi`s Shades", "Tylix`s Shades",
        "Gryme`s Shades", "Azeron`s Shades", "Cadcane`s Shades",
    },
    -- Pet Heal
    PetHeal = {
        "Mend Companion", "Convoke Shadow", "Renewal of Bones",
    },
    -- Mez
    Mez = {
        "Enslave Death", "Command Undead", "Control Undead",
        "Dominate Undead", "Subjugate Undead",
    },
    -- FD
    FeignDeath = {
        "Death Peace", "Feign Death",
    },
    -- Shield
    Shield = {
        "Bulwark of Shadows", "Shield of Darkness", "Dark Shield",
    },
    -- Lich
    Lich = {
        "Lich Unity", "Deathly Resolve", "Lich", "Call of Bones",
    },
    -- AA: Death Bloom
    DeathBloomAA = { "Death Bloom" },
    -- AA: Feign Death
    FeignDeathAA = { "Death Peace", "Feign Death" },
    -- AA: Life Burn
    LifeBurnAA = { "Life Burn" },
    -- AA: Spire of Necromancy
    SpireOfNecroAA = { "Spire of Necromancy" },
    -- AA: Fury of the Gods
    FuryOfDeathAA = { "Fury of the Gods" },
    -- AA: Wake the Dead
    WakeTheDeadAA = { "Wake the Dead" },
    -- AA: Rise of Bones
    SwarmPetAA = { "Rise of Bones" },
    -- AA: Thought Leech
    ThoughtLeechAA = { "Thought Leech" },
    -- AA: Hand of Death
    HandOfDeathAA = { "Hand of Death" },
    -- AA: Improved Twincast
    ImprovedTwincastAA = { "Improved Twincast" },
}

-- SpellLoadouts: Role-based gem assignments with extended schema
M.SpellLoadouts = {
    dot = {
        name = "DoT Focused",
        description = "Focus on damage over time",
        gems = {
            [1] = "SwiftDoT",
            [2] = "PoisonDoT",
            [3] = "DiseaseDoT",
            [4] = "FireDoT",
            [5] = "CorruptionDoT",
            [6] = "MagicDoT",
            [7] = "LifeTap",
            [8] = "Lich",
        },
        defaults = {
            -- DPS
            DoDoTs = true,
            DoSwiftDoT = true,
            DoLifeTaps = true,
            -- Support
            DoPetHeals = true,
            DoMez = true,
            -- Utility
            DoShield = true,
            DoLich = true,
            -- Emergency
            UseFeignDeath = true,
            UseDeathBloom = true,
            UseThoughtLeech = true,
            -- Burns
            UseLifeBurn = true,
            UseSpireOfNecro = true,
            UseFuryOfDeath = true,
            UseWakeTheDead = true,
            UseSwarmPet = true,
            UseHandOfDeath = true,
            UseImprovedTwincast = true,
        },
        layerAssignments = {
            -- Emergency
            UseFeignDeath = "emergency",
            UseDeathBloom = "emergency",
            -- Support
            DoPetHeals = "support",
            DoMez = "support",
            -- Combat
            DoDoTs = "combat",
            DoSwiftDoT = "combat",
            DoLifeTaps = "combat",
            -- Burn
            UseLifeBurn = "burn",
            UseSpireOfNecro = "burn",
            UseFuryOfDeath = "burn",
            UseWakeTheDead = "burn",
            UseSwarmPet = "burn",
            UseHandOfDeath = "burn",
            UseImprovedTwincast = "burn",
            -- Buff
            DoShield = "buff",
            DoLich = "buff",
            UseThoughtLeech = "buff",
        },
        layerOrder = {
            emergency = {"UseFeignDeath", "UseDeathBloom"},
            support = {"DoPetHeals", "DoMez"},
            combat = {"DoSwiftDoT", "DoDoTs", "DoLifeTaps"},
            burn = {"UseImprovedTwincast", "UseLifeBurn", "UseSpireOfNecro", "UseFuryOfDeath", "UseWakeTheDead", "UseSwarmPet", "UseHandOfDeath"},
            buff = {"DoLich", "DoShield", "UseThoughtLeech"},
        },
    },
    hybrid = {
        name = "Hybrid",
        description = "Balance DoTs and life taps",
        gems = {
            [1] = "SwiftDoT",
            [2] = "PoisonDoT",
            [3] = "DiseaseDoT",
            [4] = "LifeTap",
            [5] = "PetHeal",
            [6] = "Shield",
            [7] = "Lich",
            [8] = "Mez",
        },
        defaults = {
            DoDoTs = true,
            DoSwiftDoT = true,
            DoLifeTaps = true,
            DoPetHeals = true,
            DoMez = true,
            DoShield = true,
            DoLich = true,
            UseFeignDeath = true,
            UseDeathBloom = true,
            UseThoughtLeech = true,
            UseLifeBurn = true,
            UseSpireOfNecro = true,
            UseFuryOfDeath = true,
            UseWakeTheDead = true,
            UseSwarmPet = true,
            UseHandOfDeath = true,
            UseImprovedTwincast = true,
        },
        layerAssignments = {
            UseFeignDeath = "emergency",
            UseDeathBloom = "emergency",
            DoPetHeals = "support",
            DoMez = "support",
            DoDoTs = "combat",
            DoSwiftDoT = "combat",
            DoLifeTaps = "combat",
            UseLifeBurn = "burn",
            UseSpireOfNecro = "burn",
            UseFuryOfDeath = "burn",
            UseWakeTheDead = "burn",
            UseSwarmPet = "burn",
            UseHandOfDeath = "burn",
            UseImprovedTwincast = "burn",
            DoShield = "utility",
            DoLich = "utility",
            UseThoughtLeech = "utility",
        },
        layerOrder = {
            emergency = {"UseFeignDeath", "UseDeathBloom"},
            support = {"DoPetHeals", "DoMez"},
            combat = {"DoSwiftDoT", "DoDoTs", "DoLifeTaps"},
            burn = {"UseImprovedTwincast", "UseSpireOfNecro", "UseFuryOfDeath", "UseLifeBurn", "UseWakeTheDead", "UseSwarmPet", "UseHandOfDeath"},
            buff = {"DoLich", "DoShield", "UseThoughtLeech"},
        },
    },
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
    DoShield = {
        Default = true,
        Category = "Utility",
        DisplayName = "Self Shield",
    },
    DoLich = {
        Default = true,
        Category = "Utility",
        DisplayName = "Lich",
    },
    UseFeignDeath = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Feign Death",
    },
    UseDeathBloom = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Death Bloom",
    },
    UseThoughtLeech = {
        Default = true,
        Category = "Utility",
        DisplayName = "Thought Leech",
    },
    UseLifeBurn = {
        Default = true,
        Category = "Burn",
        DisplayName = "Life Burn",
    },
    UseSpireOfNecro = {
        Default = true,
        Category = "Burn",
        DisplayName = "Spire of Necro",
    },
    UseFuryOfDeath = {
        Default = true,
        Category = "Burn",
        DisplayName = "Fury of Death",
    },
    UseWakeTheDead = {
        Default = true,
        Category = "Burn",
        DisplayName = "Wake the Dead",
    },
    UseSwarmPet = {
        Default = true,
        Category = "Burn",
        DisplayName = "Swarm Pet",
    },
    UseHandOfDeath = {
        Default = true,
        Category = "Burn",
        DisplayName = "Hand of Death",
    },
    UseImprovedTwincast = {
        Default = true,
        Category = "Burn",
        DisplayName = "Improved Twincast",
    },
}

return M
