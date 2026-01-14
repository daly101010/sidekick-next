-- F:/lua/SideKick/data/class_configs/ROG.lua
-- Rogue Class Configuration with condition-based rotations

local mq = require('mq')

local M = {}

-- No spell lines for rogue

-- Disc Lines
M.discLines = {
    ['PoisonDisc'] = { "Asp Strike", "Viper's Bite", "Nerve Strike" },
    ['SneakAttack'] = { "Sneak Attack Discipline", "Thief's Eyes" },
    ['TwistedShank'] = { "Twisted Shank Discipline" },
    ['RoguesFury'] = { "Rogue's Fury" },
    ['Frenzied'] = { "Frenzied Stabbing Discipline" },
    ['BlindingSpeed'] = { "Blinding Speed" },
    ['Pinpoint'] = { "Pinpoint Vulnerability Discipline" },
    ['Executioner'] = { "Executioner Discipline" },
    ['UnseenAssailant'] = { "Unseen Assailant's Guile" },
}

-- AA Lines
M.aaLines = {
    ['Escape'] = { "Escape" },
    ['Assassinate'] = { "Assassinate" },
    ['ThiefsEyes'] = { "Thief's Eyes" },
    ['Backstab'] = { "Backstab" },
    ['SpireOfRogue'] = { "Spire of the Rake" },
    ['Pinpoint'] = { "Pinpoint Weaknesses" },
    ['Intensity'] = { "Intensity of the Resolute" },
    ['TwistedChance'] = { "Twisted Chance Discipline" },
    ['AspStrike'] = { "Asp Strike" },
    ['ShadowHunter'] = { "Shadow Hunter's Blade" },
}

-- Default conditions
M.defaultConditions = {
    ['doEscape'] = function(ctx)
        return ctx.me.pctHPs < 25
    end,

    ['doBackstab'] = function(ctx)
        return ctx.combat
    end,
    ['doPoisonDisc'] = function(ctx)
        return ctx.combat
    end,
    ['doSneakAttack'] = function(ctx)
        return ctx.combat and ctx.me.buff('Hide')
    end,

    ['doTwistedShank'] = function(ctx)
        return ctx.burn and not ctx.me.activeDisc
    end,
    ['doRoguesFury'] = function(ctx)
        return ctx.burn and not ctx.me.activeDisc
    end,
    ['doFrenzied'] = function(ctx)
        return ctx.burn and not ctx.me.activeDisc
    end,
    ['doBlindingSpeed'] = function(ctx)
        return ctx.burn
    end,
    ['doPinpoint'] = function(ctx)
        return ctx.burn and ctx.target.named
    end,
    ['doExecutioner'] = function(ctx)
        return ctx.burn and ctx.target.named
    end,
    ['doUnseenAssailant'] = function(ctx)
        return ctx.burn
    end,

    ['doAssassinate'] = function(ctx)
        return ctx.burn
    end,
    ['doThiefsEyes'] = function(ctx)
        return ctx.burn
    end,
    ['doSpireOfRogue'] = function(ctx)
        return ctx.burn
    end,
    ['doIntensity'] = function(ctx)
        return ctx.burn
    end,
    ['doTwistedChance'] = function(ctx)
        return ctx.burn
    end,
    ['doAspStrike'] = function(ctx)
        return ctx.combat
    end,
    ['doShadowHunter'] = function(ctx)
        return ctx.burn and ctx.combat
    end,
}

-- Category overrides
M.categoryOverrides = {
    ['doEscape'] = 'emergency',
    ['doBackstab'] = 'combat',
    ['doPoisonDisc'] = 'combat',
    ['doSneakAttack'] = 'combat',
    ['doTwistedShank'] = 'burn',
    ['doRoguesFury'] = 'burn',
    ['doFrenzied'] = 'burn',
    ['doBlindingSpeed'] = 'burn',
    ['doPinpoint'] = 'burn',
    ['doExecutioner'] = 'burn',
    ['doUnseenAssailant'] = 'burn',
    ['doAssassinate'] = 'burn',
    ['doThiefsEyes'] = 'burn',
    ['doSpireOfRogue'] = 'burn',
    ['doIntensity'] = 'burn',
    ['doTwistedChance'] = 'burn',
    ['doAspStrike'] = 'combat',
    ['doShadowHunter'] = 'burn',
}

-- AbilitySets: Disc/AA progressions (highest to lowest rank)
-- Rogue has no spells
M.AbilitySets = {
    -- Poison Disc
    PoisonDisc = { "Asp Strike", "Viper's Bite", "Nerve Strike" },
    -- Sneak Attack
    SneakAttack = { "Sneak Attack Discipline", "Thief's Eyes" },
    -- Twisted Shank
    TwistedShank = { "Twisted Shank Discipline" },
    -- Rogue's Fury
    RoguesFury = { "Rogue's Fury" },
    -- Frenzied Stabbing
    Frenzied = { "Frenzied Stabbing Discipline" },
    -- Blinding Speed
    BlindingSpeed = { "Blinding Speed" },
    -- Pinpoint Vulnerability
    Pinpoint = { "Pinpoint Vulnerability Discipline" },
    -- Executioner
    Executioner = { "Executioner Discipline" },
    -- Unseen Assailant
    UnseenAssailant = { "Unseen Assailant's Guile" },
    -- AA: Escape
    EscapeAA = { "Escape" },
    -- AA: Assassinate
    AssassinateAA = { "Assassinate" },
    -- AA: Thief's Eyes
    ThiefsEyesAA = { "Thief's Eyes" },
    -- AA: Spire of the Rake
    SpireOfRogueAA = { "Spire of the Rake" },
    -- AA: Intensity
    IntensityAA = { "Intensity of the Resolute" },
    -- AA: Twisted Chance
    TwistedChanceAA = { "Twisted Chance Discipline" },
    -- AA: Asp Strike
    AspStrikeAA = { "Asp Strike" },
    -- AA: Shadow Hunter's Blade
    ShadowHunterAA = { "Shadow Hunter's Blade" },
}

-- SpellLoadouts: Role-based configurations with extended schema
-- Rogue has no spells, so gems are empty
M.SpellLoadouts = {
    dps = {
        name = "DPS Focused",
        description = "Maximize damage output",
        gems = {},
        defaults = {
            -- Combat
            DoBackstab = true,
            DoPoison = true,
            DoSneakAttack = true,
            DoAspStrike = true,
            -- Emergency
            UseEscape = true,
            -- Burns
            UseTwistedShank = true,
            UseRoguesFury = true,
            UseFrenzied = true,
            UseBlindingSpeed = true,
            UsePinpoint = true,
            UseExecutioner = true,
            UseUnseenAssailant = true,
            UseAssassinate = true,
            UseThiefsEyes = true,
            UseSpireOfRogue = true,
            UseIntensity = true,
            UseTwistedChance = true,
            UseShadowHunter = true,
        },
        layerAssignments = {
            -- Emergency
            UseEscape = "emergency",
            -- Combat
            DoBackstab = "combat",
            DoPoison = "combat",
            DoSneakAttack = "combat",
            DoAspStrike = "combat",
            -- Burn
            UseTwistedShank = "burn",
            UseRoguesFury = "burn",
            UseFrenzied = "burn",
            UseBlindingSpeed = "burn",
            UsePinpoint = "burn",
            UseExecutioner = "burn",
            UseUnseenAssailant = "burn",
            UseAssassinate = "burn",
            UseThiefsEyes = "burn",
            UseSpireOfRogue = "burn",
            UseIntensity = "burn",
            UseTwistedChance = "burn",
            UseShadowHunter = "burn",
        },
        layerOrder = {
            emergency = {"UseEscape"},
            combat = {"DoBackstab", "DoPoison", "DoSneakAttack", "DoAspStrike"},
            burn = {"UseTwistedShank", "UseRoguesFury", "UseFrenzied", "UseBlindingSpeed", "UsePinpoint", "UseExecutioner", "UseUnseenAssailant", "UseAssassinate", "UseThiefsEyes", "UseSpireOfRogue", "UseIntensity", "UseTwistedChance", "UseShadowHunter"},
        },
    },
}

M.Settings = {
    DoPoison = {
        Default = true,
        Category = "Combat",
        DisplayName = "Use Poison",
    },
    DoBackstab = {
        Default = true,
        Category = "Combat",
        DisplayName = "Backstab",
    },
    DoSneakAttack = {
        Default = true,
        Category = "Combat",
        DisplayName = "Sneak Attack",
    },
    DoAspStrike = {
        Default = true,
        Category = "Combat",
        DisplayName = "Asp Strike",
    },
    UseEscape = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Escape",
    },
    UseTwistedShank = {
        Default = true,
        Category = "Burn",
        DisplayName = "Twisted Shank",
    },
    UseRoguesFury = {
        Default = true,
        Category = "Burn",
        DisplayName = "Rogue's Fury",
    },
    UseFrenzied = {
        Default = true,
        Category = "Burn",
        DisplayName = "Frenzied",
    },
    UseBlindingSpeed = {
        Default = true,
        Category = "Burn",
        DisplayName = "Blinding Speed",
    },
    UsePinpoint = {
        Default = true,
        Category = "Burn",
        DisplayName = "Pinpoint",
    },
    UseExecutioner = {
        Default = true,
        Category = "Burn",
        DisplayName = "Executioner",
    },
    UseUnseenAssailant = {
        Default = true,
        Category = "Burn",
        DisplayName = "Unseen Assailant",
    },
    UseAssassinate = {
        Default = true,
        Category = "Burn",
        DisplayName = "Assassinate",
    },
    UseThiefsEyes = {
        Default = true,
        Category = "Burn",
        DisplayName = "Thief's Eyes",
    },
    UseSpireOfRogue = {
        Default = true,
        Category = "Burn",
        DisplayName = "Spire of Rogue",
    },
    UseIntensity = {
        Default = true,
        Category = "Burn",
        DisplayName = "Intensity",
    },
    UseTwistedChance = {
        Default = true,
        Category = "Burn",
        DisplayName = "Twisted Chance",
    },
    UseShadowHunter = {
        Default = true,
        Category = "Burn",
        DisplayName = "Shadow Hunter",
    },
}

return M
