-- F:/lua/SideKick/data/class_configs/WIZ.lua
-- Wizard Class Configuration with condition-based rotations

local mq = require('mq')

local M = {}

-- Spell Lines
M.spellLines = {
    -- Fire Nuke
    ['FireNuke'] = {
        "Ethereal Skyfire", "Ethereal Inferno", "Ethereal Conflagration",
        "Ethereal Incandescence", "Ethereal Blaze", "Ethereal Combustion",
        "Skyfire", "Pillar of Fire", "Fire Bolt",
    },

    -- Ice Nuke
    ['IceNuke'] = {
        "Glacial Cascade", "Glacial Freeze", "Glacial Ice",
        "Claw of Travenro", "Claw of Vox", "Ice Comet",
    },

    -- Magic Nuke
    ['MagicNuke'] = {
        "Ethereal Braid", "Ethereal Twist", "Ethereal Weave",
        "Force of Will", "Force of Flame", "Shock of Lightning",
    },

    -- Ethereal Nuke (fast cast)
    ['EtherealNuke'] = {
        "Ethereal Hoarfrost", "Ethereal Frost", "Ethereal Rime",
        "Ethereal Rimeblast", "Remote Skyblaze", "Remote Moonfire",
    },

    -- Rain (AE)
    ['RainSpell'] = {
        "Tears of Prexus", "Tears of the Sun", "Tears of Drysa",
        "Tears of Solusek", "Rain of Skyfire", "Ice Rain",
    },

    -- AE Fire
    ['AEFire'] = {
        "Circle of Firestorm", "Circle of Flashfire", "Circle of Inferno",
        "Column of Fire", "Pillar of Flame", "Rain of Fire",
    },

    -- AE Ice
    ['AEIce'] = {
        "Frore Storm", "Freezing Hail", "Ice Storm",
    },

    -- Jolt (aggro dump)
    ['Jolt'] = {
        "Concussion", "Phantasmal Recourse", "Mind Crash",
        "Claw of Frost", "Jolt",
    },

    -- Harvest (mana recovery)
    ['Harvest'] = {
        "Ethereal Harvest", "Arcane Harvest", "Mystic Harvest",
        "Contemplation", "Harvest of Druzzil", "Harvest",
    },

    -- Self Shield
    ['SelfShield'] = {
        "Shield of Consequence", "Shield of Order", "Shield of Dreams",
        "Shield of Shadow", "Shield of the Arcane", "Shield of the Magi",
    },

    -- Familiar
    ['Familiar'] = {
        "Greater Familiar", "Improved Familiar", "Familiar",
    },
}

-- AA Lines
M.aaLines = {
    ['ImprovedTwincast'] = { "Improved Twincast" },
    ['FuryOfMagic'] = { "Fury of the Gods" },
    ['Harvest'] = { "Harvest of Druzzil" },
    ['ForcefulRejuvenation'] = { "Forceful Rejuvenation" },
    ['Concussion'] = { "Concussion", "Mind Crash" },
    ['SpireOfWizard'] = { "Spire of Arcanum" },
    ['IntensityOfResolute'] = { "Intensity of the Resolute" },
    ['ArcaneFury'] = { "Arcane Fury" },
    ['Firebound'] = { "Firebound Orb" },
    ['Icebound'] = { "Icebound Orb" },
}

-- Default conditions
M.defaultConditions = {
    ['doHarvest'] = function(ctx)
        return ctx.me.pctMana < 30
    end,
    ['doForcefulRejuvenation'] = function(ctx)
        return ctx.me.pctMana < 20
    end,
    ['doConcussion'] = function(ctx)
        return ctx.me.pctAggro > 85
    end,
    ['doJolt'] = function(ctx)
        return ctx.me.pctAggro > 90
    end,

    ['doFireNuke'] = function(ctx)
        return ctx.combat and ctx.me.pctMana > 30
    end,
    ['doIceNuke'] = function(ctx)
        return ctx.combat and ctx.me.pctMana > 30
    end,
    ['doMagicNuke'] = function(ctx)
        return ctx.combat and ctx.me.pctMana > 30
    end,
    ['doEtherealNuke'] = function(ctx)
        return ctx.combat and ctx.target.named
    end,
    ['doRainSpell'] = function(ctx)
        return ctx.combat and ctx.me.xTargetCount >= 3 and ctx.me.pctMana > 40
    end,
    ['doAEFire'] = function(ctx)
        return ctx.combat and ctx.me.xTargetCount >= 3 and ctx.me.pctMana > 40
    end,
    ['doAEIce'] = function(ctx)
        return ctx.combat and ctx.me.xTargetCount >= 3 and ctx.me.pctMana > 40
    end,

    ['doSelfShield'] = function(ctx)
        return not ctx.me.buff('Shield') and not ctx.combat
    end,
    ['doFamiliar'] = function(ctx)
        return not ctx.me.buff('Familiar') and not ctx.combat
    end,

    ['doImprovedTwincast'] = function(ctx)
        return ctx.burn and not ctx.me.buff('Improved Twincast') and not ctx.me.buff('Twincast')
    end,
    ['doFuryOfMagic'] = function(ctx)
        return ctx.burn
    end,
    ['doSpireOfWizard'] = function(ctx)
        return ctx.burn
    end,
    ['doIntensityOfResolute'] = function(ctx)
        return ctx.burn
    end,
    ['doArcaneFury'] = function(ctx)
        return ctx.burn
    end,
    ['doFirebound'] = function(ctx)
        return ctx.burn
    end,
    ['doIcebound'] = function(ctx)
        return ctx.burn
    end,
}

-- Category overrides
M.categoryOverrides = {
    ['doHarvest'] = 'emergency',
    ['doForcefulRejuvenation'] = 'emergency',
    ['doConcussion'] = 'aggro',
    ['doJolt'] = 'aggro',
    ['doFireNuke'] = 'combat',
    ['doIceNuke'] = 'combat',
    ['doMagicNuke'] = 'combat',
    ['doEtherealNuke'] = 'combat',
    ['doRainSpell'] = 'combat',
    ['doAEFire'] = 'combat',
    ['doAEIce'] = 'combat',
    ['doSelfShield'] = 'buff',
    ['doFamiliar'] = 'buff',
    ['doImprovedTwincast'] = 'burn',
    ['doFuryOfMagic'] = 'burn',
    ['doSpireOfWizard'] = 'burn',
    ['doIntensityOfResolute'] = 'burn',
    ['doArcaneFury'] = 'burn',
    ['doFirebound'] = 'burn',
    ['doIcebound'] = 'burn',
}

-- AbilitySets: Spell/AA progressions (highest to lowest rank)
M.AbilitySets = {
    -- Fire Nuke
    FireNuke = {
        "Ethereal Skyfire", "Ethereal Inferno", "Ethereal Conflagration",
        "Ethereal Incandescence", "Ethereal Blaze", "Ethereal Combustion",
        "Skyfire", "Pillar of Fire", "Fire Bolt",
    },
    -- Ice Nuke
    IceNuke = {
        "Glacial Cascade", "Glacial Freeze", "Glacial Ice",
        "Claw of Travenro", "Claw of Vox", "Ice Comet",
    },
    -- Magic Nuke
    MagicNuke = {
        "Ethereal Braid", "Ethereal Twist", "Ethereal Weave",
        "Force of Will", "Force of Flame", "Shock of Lightning",
    },
    -- Ethereal Nuke (fast cast)
    EtherealNuke = {
        "Ethereal Hoarfrost", "Ethereal Frost", "Ethereal Rime",
        "Ethereal Rimeblast", "Remote Skyblaze", "Remote Moonfire",
    },
    -- Rain (AE)
    RainSpell = {
        "Tears of Prexus", "Tears of the Sun", "Tears of Drysa",
        "Tears of Solusek", "Rain of Skyfire", "Ice Rain",
    },
    -- AE Fire
    AEFire = {
        "Circle of Firestorm", "Circle of Flashfire", "Circle of Inferno",
        "Column of Fire", "Pillar of Flame", "Rain of Fire",
    },
    -- AE Ice
    AEIce = {
        "Frore Storm", "Freezing Hail", "Ice Storm",
    },
    -- Jolt
    Jolt = {
        "Concussion", "Phantasmal Recourse", "Mind Crash",
        "Claw of Frost", "Jolt",
    },
    -- Harvest
    Harvest = {
        "Ethereal Harvest", "Arcane Harvest", "Mystic Harvest",
        "Contemplation", "Harvest of Druzzil", "Harvest",
    },
    -- Self Shield
    SelfShield = {
        "Shield of Consequence", "Shield of Order", "Shield of Dreams",
        "Shield of Shadow", "Shield of the Arcane", "Shield of the Magi",
    },
    -- Familiar
    Familiar = {
        "Greater Familiar", "Improved Familiar", "Familiar",
    },
    -- AA: Improved Twincast
    ImprovedTwincastAA = { "Improved Twincast" },
    -- AA: Fury of the Gods
    FuryOfMagicAA = { "Fury of the Gods" },
    -- AA: Harvest
    HarvestAA = { "Harvest of Druzzil" },
    -- AA: Forceful Rejuvenation
    ForcefulRejuvenationAA = { "Forceful Rejuvenation" },
    -- AA: Concussion
    ConcussionAA = { "Concussion", "Mind Crash" },
    -- AA: Spire of Arcanum
    SpireOfWizardAA = { "Spire of Arcanum" },
    -- AA: Intensity
    IntensityAA = { "Intensity of the Resolute" },
    -- AA: Arcane Fury
    ArcaneFuryAA = { "Arcane Fury" },
    -- AA: Firebound Orb
    FireboundAA = { "Firebound Orb" },
    -- AA: Icebound Orb
    IceboundAA = { "Icebound Orb" },
}

-- SpellLoadouts: Role-based gem assignments with extended schema
M.SpellLoadouts = {
    fire = {
        name = "Fire Focus",
        description = "Focus on fire nukes",
        gems = {
            [1] = "FireNuke",
            [2] = "EtherealNuke",
            [3] = "AEFire",
            [4] = "RainSpell",
            [5] = "Jolt",
            [6] = "Harvest",
            [7] = "SelfShield",
            [8] = "Familiar",
        },
        defaults = {
            -- DPS
            DoFireNukes = true,
            DoIceNukes = false,
            DoMagicNukes = false,
            DoEtherealNukes = true,
            DoAENukes = true,
            -- Aggro
            DoJolt = true,
            -- Utility
            DoHarvest = true,
            DoSelfShield = true,
            DoFamiliar = true,
            -- Emergency
            UseForcefulRejuvenation = true,
            -- Burns
            UseImprovedTwincast = true,
            UseFuryOfMagic = true,
            UseSpireOfWizard = true,
            UseIntensity = true,
            UseArcaneFury = true,
            UseFirebound = true,
            UseIcebound = false,
        },
        layerAssignments = {
            -- Emergency
            UseForcefulRejuvenation = "emergency",
            -- Aggro
            DoJolt = "aggro",
            -- Combat
            DoFireNukes = "combat",
            DoIceNukes = "combat",
            DoMagicNukes = "combat",
            DoEtherealNukes = "combat",
            DoAENukes = "combat",
            -- Burn
            UseImprovedTwincast = "burn",
            UseFuryOfMagic = "burn",
            UseSpireOfWizard = "burn",
            UseIntensity = "burn",
            UseArcaneFury = "burn",
            UseFirebound = "burn",
            UseIcebound = "burn",
            -- Buff
            DoHarvest = "buff",
            DoSelfShield = "buff",
            DoFamiliar = "buff",
        },
        layerOrder = {
            emergency = {"UseForcefulRejuvenation"},
            aggro = {"DoJolt"},
            combat = {"DoFireNukes", "DoEtherealNukes", "DoAENukes", "DoMagicNukes", "DoIceNukes"},
            burn = {"UseImprovedTwincast", "UseFuryOfMagic", "UseArcaneFury", "UseFirebound", "UseSpireOfWizard", "UseIntensity", "UseIcebound"},
            buff = {"DoHarvest", "DoSelfShield", "DoFamiliar"},
        },
    },
    ice = {
        name = "Ice Focus",
        description = "Focus on ice nukes",
        gems = {
            [1] = "IceNuke",
            [2] = "EtherealNuke",
            [3] = "AEIce",
            [4] = "RainSpell",
            [5] = "Jolt",
            [6] = "Harvest",
            [7] = "SelfShield",
            [8] = "Familiar",
        },
        defaults = {
            DoFireNukes = false,
            DoIceNukes = true,
            DoMagicNukes = false,
            DoEtherealNukes = true,
            DoAENukes = true,
            DoJolt = true,
            DoHarvest = true,
            DoSelfShield = true,
            DoFamiliar = true,
            UseForcefulRejuvenation = true,
            UseImprovedTwincast = true,
            UseFuryOfMagic = true,
            UseSpireOfWizard = true,
            UseIntensity = true,
            UseArcaneFury = true,
            UseFirebound = false,
            UseIcebound = true,
        },
        layerAssignments = {
            UseForcefulRejuvenation = "emergency",
            DoJolt = "aggro",
            DoFireNukes = "combat",
            DoIceNukes = "combat",
            DoMagicNukes = "combat",
            DoEtherealNukes = "combat",
            DoAENukes = "combat",
            UseImprovedTwincast = "burn",
            UseFuryOfMagic = "burn",
            UseSpireOfWizard = "burn",
            UseIntensity = "burn",
            UseArcaneFury = "burn",
            UseFirebound = "burn",
            UseIcebound = "burn",
            DoHarvest = "buff",
            DoSelfShield = "buff",
            DoFamiliar = "buff",
        },
        layerOrder = {
            emergency = {"UseForcefulRejuvenation"},
            aggro = {"DoJolt"},
            combat = {"DoIceNukes", "DoEtherealNukes", "DoAENukes", "DoMagicNukes", "DoFireNukes"},
            burn = {"UseImprovedTwincast", "UseFuryOfMagic", "UseArcaneFury", "UseIcebound", "UseSpireOfWizard", "UseIntensity", "UseFirebound"},
            buff = {"DoHarvest", "DoSelfShield", "DoFamiliar"},
        },
    },
    hybrid = {
        name = "Hybrid",
        description = "Mix of fire, ice, and magic",
        gems = {
            [1] = "FireNuke",
            [2] = "IceNuke",
            [3] = "MagicNuke",
            [4] = "EtherealNuke",
            [5] = "Jolt",
            [6] = "Harvest",
            [7] = "SelfShield",
            [8] = "AEFire",
        },
        defaults = {
            DoFireNukes = true,
            DoIceNukes = true,
            DoMagicNukes = true,
            DoEtherealNukes = true,
            DoAENukes = true,
            DoJolt = true,
            DoHarvest = true,
            DoSelfShield = true,
            DoFamiliar = true,
            UseForcefulRejuvenation = true,
            UseImprovedTwincast = true,
            UseFuryOfMagic = true,
            UseSpireOfWizard = true,
            UseIntensity = true,
            UseArcaneFury = true,
            UseFirebound = true,
            UseIcebound = true,
        },
        layerAssignments = {
            UseForcefulRejuvenation = "emergency",
            DoJolt = "aggro",
            DoFireNukes = "combat",
            DoIceNukes = "combat",
            DoMagicNukes = "combat",
            DoEtherealNukes = "combat",
            DoAENukes = "combat",
            UseImprovedTwincast = "burn",
            UseFuryOfMagic = "burn",
            UseSpireOfWizard = "burn",
            UseIntensity = "burn",
            UseArcaneFury = "burn",
            UseFirebound = "burn",
            UseIcebound = "burn",
            DoHarvest = "buff",
            DoSelfShield = "buff",
            DoFamiliar = "buff",
        },
        layerOrder = {
            emergency = {"UseForcefulRejuvenation"},
            aggro = {"DoJolt"},
            combat = {"DoFireNukes", "DoIceNukes", "DoMagicNukes", "DoEtherealNukes", "DoAENukes"},
            burn = {"UseImprovedTwincast", "UseFuryOfMagic", "UseArcaneFury", "UseFirebound", "UseIcebound", "UseSpireOfWizard", "UseIntensity"},
            buff = {"DoHarvest", "DoSelfShield", "DoFamiliar"},
        },
    },
}

M.Settings = {
    DoFireNukes = {
        Default = true,
        Category = "DPS",
        DisplayName = "Fire Nukes",
    },
    DoIceNukes = {
        Default = true,
        Category = "DPS",
        DisplayName = "Ice Nukes",
    },
    DoMagicNukes = {
        Default = true,
        Category = "DPS",
        DisplayName = "Magic Nukes",
    },
    DoEtherealNukes = {
        Default = true,
        Category = "DPS",
        DisplayName = "Ethereal Nukes",
    },
    DoAENukes = {
        Default = true,
        Category = "DPS",
        DisplayName = "AE Nukes",
    },
    DoJolt = {
        Default = true,
        Category = "Aggro",
        DisplayName = "Auto-Jolt",
    },
    DoHarvest = {
        Default = true,
        Category = "Utility",
        DisplayName = "Harvest",
    },
    DoSelfShield = {
        Default = true,
        Category = "Utility",
        DisplayName = "Self Shield",
    },
    DoFamiliar = {
        Default = true,
        Category = "Utility",
        DisplayName = "Familiar",
    },
    UseForcefulRejuvenation = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Forceful Rejuvenation",
    },
    UseImprovedTwincast = {
        Default = true,
        Category = "Burn",
        DisplayName = "Improved Twincast",
    },
    UseFuryOfMagic = {
        Default = true,
        Category = "Burn",
        DisplayName = "Fury of Magic",
    },
    UseSpireOfWizard = {
        Default = true,
        Category = "Burn",
        DisplayName = "Spire of Wizard",
    },
    UseIntensity = {
        Default = true,
        Category = "Burn",
        DisplayName = "Intensity",
    },
    UseArcaneFury = {
        Default = true,
        Category = "Burn",
        DisplayName = "Arcane Fury",
    },
    UseFirebound = {
        Default = true,
        Category = "Burn",
        DisplayName = "Firebound",
    },
    UseIcebound = {
        Default = true,
        Category = "Burn",
        DisplayName = "Icebound",
    },
}

return M
