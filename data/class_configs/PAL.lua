-- F:/lua/SideKick/data/class_configs/PAL.lua
-- Paladin Class Configuration with condition-based rotations

local mq = require('mq')

local M = {}

-- Spell Lines
M.spellLines = {
    -- Crush (hate + nuke timer 6)
    ['CrushTimer6'] = {
        "Brilliant Vindication", "Devout Vindication", "Sincere Vindication",
        "Merciful Vindication", "Ardent Vindication", "Righteous Vindication",
        "Earnest Vindication", "Crush of the Darkened Sea",
    },

    -- Crush (timer 5)
    ['CrushTimer5'] = {
        "Brilliant Castigation", "Devout Castigation", "Sincere Castigation",
        "Merciful Castigation", "Ardent Castigation", "Righteous Castigation",
    },

    -- Heal + Nuke
    ['HealNuke'] = {
        "Brilliant Denouncement", "Devout Denouncement", "Sincere Denouncement",
        "Merciful Denouncement", "Ardent Denouncement", "Righteous Denouncement",
    },

    -- Wave (AE hate)
    ['Wave'] = {
        "Wave of Piety", "Wave of Propitiation", "Wave of Absolution",
        "Wave of Bereavement", "Wave of Grief", "Wave of Sorrow",
    },

    -- Preservation (fast heal)
    ['Preservation'] = {
        "Anticipated Preservation", "Predicted Preservation",
        "Foretold Preservation", "Prophesied Preservation",
        "Foreseen Preservation", "Presaged Preservation",
    },

    -- Aurora (group heal)
    ['Aurora'] = {
        "Aurora of Sunrise", "Aurora of Daybreak", "Aurora of Dawn",
        "Aurora of Dawnlight", "Aurora of Sunlight", "Aurora of Grace",
    },

    -- Undead Nuke
    ['UndeadNuke'] = {
        "Glorious Expiation", "Glorious Denunciation", "Glorious Censure",
        "Glorious Rebuke", "Glorious Admonition", "Expiation",
    },

    -- Stun
    ['Stun'] = {
        "Valiant Rebuke", "Valiant Deflection", "Valiant Disruption",
        "Force of Reverence", "Force of Akera", "Force of Nife", "Stun",
    },

    -- Self-Heal
    ['SelfHeal'] = {
        "Penitent Healing", "Sorrowful Healing", "Mournful Healing",
        "Woeful Healing", "Grief-Stricken Healing", "Touch of Nife",
    },

    -- HP Buff (Symbol equivalent)
    ['HPBuff'] = {
        "Guard of Righteousness", "Guard of Devotion", "Guard of Piety",
        "Guard of Gallantry", "Brell's Stalwart Shield",
    },

    -- Aura
    ['Aura'] = {
        "Aura of the Crusader", "Aura of the Reverent", "Aura of the Pious",
        "Aura of the Devout", "Aura of the Righteous",
    },
}

-- Disc Lines
M.discLines = {
    -- Defense
    ['DefenseDisc'] = {
        "Armor of the Inquisitor", "Armor of Reverence", "Armor of Piety",
        "Armor of Sincerity", "Armor of Devotion", "Guard of Humility",
    },
    -- AE Aggro
    ['AEAggroDisc'] = {
        "Righteous Vanguard", "Force of Acknowledgement", "Harmonious Blessing",
    },
    -- Burst
    ['BurstDisc'] = {
        "Brightfield's Vindication", "Vanquish the Fallen",
    },
}

-- AA Lines
M.aaLines = {
    ['LayOnHands'] = { "Lay on Hands" },
    ['DivineCall'] = { "Divine Call" },
    ['Beacon'] = { "Beacon of Life" },
    ['Marr'] = { "Hand of Marr" },
    ['Fortitude'] = { "Fortitude" },
    ['GroupArmor'] = { "Group Armor of the Inquisitor" },
    ['SpireOfPaladin'] = { "Spire of the Paladin" },
}

-- Default conditions
M.defaultConditions = {
    ['doLayOnHands'] = function(ctx)
        return ctx.me.pctHPs < 20 or ctx.group.tankHP < 15
    end,
    ['doDivineCall'] = function(ctx)
        return ctx.me.pctHPs < 35
    end,
    ['doBeacon'] = function(ctx)
        return ctx.group.injured(40) >= 3
    end,
    ['doFortitude'] = function(ctx)
        return ctx.me.pctHPs < 30 and not ctx.me.buff('Fortitude')
    end,
    ['doGroupArmor'] = function(ctx)
        return ctx.group.injured(50) >= 2 and not ctx.me.activeDisc
    end,

    ['doDefenseDisc'] = function(ctx)
        return ctx.me.pctHPs < 40 and not ctx.me.activeDisc
    end,
    ['doAEAggroDisc'] = function(ctx)
        return ctx.me.xTargetCount >= 3 and ctx.mode == 'Tank'
    end,

    ['doCrushTimer6'] = function(ctx)
        return ctx.combat
    end,
    ['doCrushTimer5'] = function(ctx)
        return ctx.combat and ctx.target.pctHPs > 20
    end,
    ['doHealNuke'] = function(ctx)
        return ctx.combat and ctx.target.pctHPs > 20 and ctx.group.lowestHP < 85
    end,
    ['doWave'] = function(ctx)
        return ctx.me.xTargetCount >= 2 and ctx.mode == 'Tank'
    end,
    ['doPreservation'] = function(ctx)
        return ctx.group.lowestHP < 75
    end,
    ['doAurora'] = function(ctx)
        return ctx.group.injured(70) >= 2
    end,
    ['doUndeadNuke'] = function(ctx)
        return ctx.target.body == 'Undead' and ctx.combat
    end,
    ['doStun'] = function(ctx)
        return ctx.combat and ctx.target.pctHPs > 20
    end,
    ['doSelfHeal'] = function(ctx)
        return ctx.me.pctHPs < 60
    end,

    ['doHPBuff'] = function(ctx)
        return not ctx.combat
    end,
    ['doAura'] = function(ctx)
        return not ctx.me.song('Aura')
    end,

    ['doSpireOfPaladin'] = function(ctx)
        return ctx.burn
    end,
}

-- Category overrides
M.categoryOverrides = {
    ['doLayOnHands'] = 'emergency',
    ['doDivineCall'] = 'emergency',
    ['doBeacon'] = 'emergency',
    ['doFortitude'] = 'defenses',
    ['doGroupArmor'] = 'defenses',
    ['doDefenseDisc'] = 'defenses',
    ['doAEAggroDisc'] = 'aggro',
    ['doCrushTimer6'] = 'combat',
    ['doCrushTimer5'] = 'combat',
    ['doHealNuke'] = 'combat',
    ['doWave'] = 'aggro',
    ['doPreservation'] = 'support',
    ['doAurora'] = 'support',
    ['doUndeadNuke'] = 'combat',
    ['doStun'] = 'combat',
    ['doSelfHeal'] = 'support',
    ['doHPBuff'] = 'utility',
    ['doAura'] = 'utility',
    ['doSpireOfPaladin'] = 'burn',
}

M.Settings = {
    DoHealing = {
        Default = true,
        Category = "Heal",
        DisplayName = "Enable Healing",
    },
    DoGroupHeals = {
        Default = true,
        Category = "Heal",
        DisplayName = "Use Group Heals",
    },
    DoStuns = {
        Default = true,
        Category = "Combat",
        DisplayName = "Use Stuns",
    },
    DoUndeadNuke = {
        Default = true,
        Category = "Combat",
        DisplayName = "Undead Nuke",
    },
    UseDefenseDiscs = {
        Default = true,
        Category = "Defense",
        DisplayName = "Defense Discs",
    },
}

return M
