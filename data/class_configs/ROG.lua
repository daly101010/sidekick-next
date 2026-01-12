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
}

return M
