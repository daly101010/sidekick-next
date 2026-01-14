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
    ['doHPBuff'] = 'buff',
    ['doAura'] = 'buff',
    ['doSpireOfPaladin'] = 'burn',
}

-- AbilitySets: Spell/AA progressions (highest to lowest rank)
M.AbilitySets = {
    -- Crush Timer 5
    CrushTimer5 = {
        "Brilliant Castigation", "Devout Castigation", "Sincere Castigation",
        "Merciful Castigation", "Ardent Castigation", "Righteous Castigation",
    },
    -- Crush Timer 6
    CrushTimer6 = {
        "Brilliant Vindication", "Devout Vindication", "Sincere Vindication",
        "Merciful Vindication", "Ardent Vindication", "Righteous Vindication",
        "Earnest Vindication", "Crush of the Darkened Sea",
    },
    -- Stun
    Stun = {
        "Valiant Rebuke", "Valiant Deflection", "Valiant Disruption",
        "Force of Reverence", "Force of Akera", "Force of Nife", "Stun",
    },
    -- Wave (AE hate)
    Wave = {
        "Wave of Piety", "Wave of Propitiation", "Wave of Absolution",
        "Wave of Bereavement", "Wave of Grief", "Wave of Sorrow",
    },
    -- Heal Nuke
    HealNuke = {
        "Brilliant Denouncement", "Devout Denouncement", "Sincere Denouncement",
        "Merciful Denouncement", "Ardent Denouncement", "Righteous Denouncement",
    },
    -- Preservation (fast heal)
    Preservation = {
        "Anticipated Preservation", "Predicted Preservation",
        "Foretold Preservation", "Prophesied Preservation",
        "Foreseen Preservation", "Presaged Preservation",
    },
    -- Aurora (group heal)
    Aurora = {
        "Aurora of Sunrise", "Aurora of Daybreak", "Aurora of Dawn",
        "Aurora of Dawnlight", "Aurora of Sunlight", "Aurora of Grace",
    },
    -- Undead Nuke
    UndeadNuke = {
        "Glorious Expiation", "Glorious Denunciation", "Glorious Censure",
        "Glorious Rebuke", "Glorious Admonition", "Expiation",
    },
    -- Self Heal
    SelfHeal = {
        "Penitent Healing", "Sorrowful Healing", "Mournful Healing",
        "Woeful Healing", "Grief-Stricken Healing", "Touch of Nife",
    },
    -- HP Buff
    HPBuff = {
        "Guard of Righteousness", "Guard of Devotion", "Guard of Piety",
        "Guard of Gallantry", "Brell's Stalwart Shield",
    },
    -- Aura
    Aura = {
        "Aura of the Crusader", "Aura of the Reverent", "Aura of the Pious",
        "Aura of the Devout", "Aura of the Righteous",
    },
    -- AA: Lay on Hands
    LayOnHandsAA = { "Lay on Hands" },
    -- AA: Divine Call
    DivineCallAA = { "Divine Call" },
    -- AA: Beacon of Life
    BeaconAA = { "Beacon of Life" },
    -- AA: Hand of Marr
    MarrAA = { "Hand of Marr" },
    -- AA: Fortitude
    FortitudeAA = { "Fortitude" },
    -- AA: Group Armor of the Inquisitor
    GroupArmorAA = { "Group Armor of the Inquisitor" },
    -- AA: Spire of the Paladin
    SpireOfPaladinAA = { "Spire of the Paladin" },
}

-- SpellLoadouts: Role-based gem assignments with extended schema
M.SpellLoadouts = {
    tank = {
        name = "Tank Focused",
        description = "Focus on aggro and tanking",
        gems = {
            [1] = "CrushTimer5",
            [2] = "CrushTimer6",
            [3] = "Stun",
            [4] = "Wave",
            [5] = "HealNuke",
            [6] = "Aurora",
            [7] = "Preservation",
            [8] = "HPBuff",
        },
        defaults = {
            -- Tank
            DoCrush = true,
            DoStuns = true,
            DoWave = true,
            -- Healing
            DoHealing = true,
            DoGroupHeals = true,
            DoPreservation = true,
            -- DPS
            DoUndeadNuke = true,
            -- Buffs
            DoHPBuff = true,
            DoAura = true,
            -- Emergency
            UseLayOnHands = true,
            UseDivineCall = true,
            UseFortitude = true,
            UseDefenseDiscs = true,
            -- Burns
            UseSpireOfPaladin = true,
        },
        layerAssignments = {
            -- Emergency
            UseLayOnHands = "emergency",
            UseDivineCall = "emergency",
            -- Defenses
            UseFortitude = "defenses",
            UseDefenseDiscs = "defenses",
            -- Support (healing)
            DoHealing = "support",
            DoGroupHeals = "support",
            DoPreservation = "support",
            -- Combat (aggro)
            DoCrush = "combat",
            DoStuns = "combat",
            DoWave = "combat",
            DoUndeadNuke = "combat",
            -- Burn
            UseSpireOfPaladin = "burn",
            -- Buff
            DoHPBuff = "buff",
            DoAura = "buff",
        },
        layerOrder = {
            emergency = {"UseLayOnHands", "UseDivineCall"},
            defenses = {"UseFortitude", "UseDefenseDiscs"},
            support = {"DoHealing", "DoGroupHeals", "DoPreservation"},
            combat = {"DoCrush", "DoStuns", "DoWave", "DoUndeadNuke"},
            burn = {"UseSpireOfPaladin"},
            buff = {"DoHPBuff", "DoAura"},
        },
    },
    heal = {
        name = "Heal Support",
        description = "Focus on healing support",
        gems = {
            [1] = "Preservation",
            [2] = "Aurora",
            [3] = "HealNuke",
            [4] = "SelfHeal",
            [5] = "CrushTimer5",
            [6] = "Wave",
            [7] = "Stun",
            [8] = "HPBuff",
        },
        defaults = {
            -- Tank (minimal)
            DoCrush = true,
            DoStuns = true,
            DoWave = false,
            -- Healing (primary)
            DoHealing = true,
            DoGroupHeals = true,
            DoPreservation = true,
            -- DPS
            DoUndeadNuke = true,
            -- Buffs
            DoHPBuff = true,
            DoAura = true,
            -- Emergency
            UseLayOnHands = true,
            UseDivineCall = true,
            UseFortitude = true,
            UseDefenseDiscs = true,
            -- Burns
            UseSpireOfPaladin = true,
        },
        layerAssignments = {
            UseLayOnHands = "emergency",
            UseDivineCall = "emergency",
            UseFortitude = "defenses",
            UseDefenseDiscs = "defenses",
            DoHealing = "support",
            DoGroupHeals = "support",
            DoPreservation = "support",
            DoCrush = "combat",
            DoStuns = "combat",
            DoWave = "combat",
            DoUndeadNuke = "combat",
            UseSpireOfPaladin = "burn",
            DoHPBuff = "buff",
            DoAura = "buff",
        },
        layerOrder = {
            emergency = {"UseLayOnHands", "UseDivineCall"},
            defenses = {"UseFortitude", "UseDefenseDiscs"},
            support = {"DoHealing", "DoGroupHeals", "DoPreservation"},
            combat = {"DoStuns", "DoCrush", "DoUndeadNuke", "DoWave"},
            burn = {"UseSpireOfPaladin"},
            buff = {"DoHPBuff", "DoAura"},
        },
    },
    dps = {
        name = "DPS Focused",
        description = "Maximize damage output",
        gems = {
            [1] = "CrushTimer5",
            [2] = "CrushTimer6",
            [3] = "HealNuke",
            [4] = "UndeadNuke",
            [5] = "Stun",
            [6] = "Aurora",
            [7] = "Preservation",
            [8] = "HPBuff",
        },
        defaults = {
            -- Tank (minimal)
            DoCrush = true,
            DoStuns = true,
            DoWave = false,
            -- Healing (essential)
            DoHealing = true,
            DoGroupHeals = true,
            DoPreservation = false,
            -- DPS (primary)
            DoUndeadNuke = true,
            -- Buffs
            DoHPBuff = false,
            DoAura = false,
            -- Emergency
            UseLayOnHands = true,
            UseDivineCall = true,
            UseFortitude = true,
            UseDefenseDiscs = false,
            -- Burns
            UseSpireOfPaladin = true,
        },
        layerAssignments = {
            UseLayOnHands = "emergency",
            UseDivineCall = "emergency",
            UseFortitude = "defenses",
            UseDefenseDiscs = "defenses",
            DoHealing = "support",
            DoGroupHeals = "support",
            DoPreservation = "support",
            DoCrush = "combat",
            DoStuns = "combat",
            DoWave = "combat",
            DoUndeadNuke = "combat",
            UseSpireOfPaladin = "burn",
            DoHPBuff = "buff",
            DoAura = "buff",
        },
        layerOrder = {
            emergency = {"UseLayOnHands", "UseDivineCall"},
            defenses = {"UseFortitude", "UseDefenseDiscs"},
            support = {"DoHealing", "DoGroupHeals", "DoPreservation"},
            combat = {"DoCrush", "DoUndeadNuke", "DoStuns", "DoWave"},
            burn = {"UseSpireOfPaladin"},
            buff = {"DoHPBuff", "DoAura"},
        },
    },
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
    DoPreservation = {
        Default = true,
        Category = "Heal",
        DisplayName = "Preservation",
    },
    DoCrush = {
        Default = true,
        Category = "Combat",
        DisplayName = "Use Crush",
    },
    DoStuns = {
        Default = true,
        Category = "Combat",
        DisplayName = "Use Stuns",
    },
    DoWave = {
        Default = true,
        Category = "Tank",
        DisplayName = "AE Wave",
    },
    DoUndeadNuke = {
        Default = true,
        Category = "Combat",
        DisplayName = "Undead Nuke",
    },
    DoHPBuff = {
        Default = true,
        Category = "Buff",
        DisplayName = "HP Buff",
    },
    DoAura = {
        Default = true,
        Category = "Buff",
        DisplayName = "Aura",
    },
    UseLayOnHands = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Lay on Hands",
    },
    UseDivineCall = {
        Default = true,
        Category = "Emergency",
        DisplayName = "Divine Call",
    },
    UseFortitude = {
        Default = true,
        Category = "Defense",
        DisplayName = "Fortitude",
    },
    UseDefenseDiscs = {
        Default = true,
        Category = "Defense",
        DisplayName = "Defense Discs",
    },
    UseSpireOfPaladin = {
        Default = true,
        Category = "Burn",
        DisplayName = "Spire of Paladin",
    },
}

return M
