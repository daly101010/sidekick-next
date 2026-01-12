-- F:/lua/SideKick/data/class_configs/SHD.lua
-- Shadow Knight Class Configuration with condition-based rotations

local mq = require('mq')

local M = {}

-- Spell Lines
M.spellLines = {
    -- Spear Nuke
    ['SpearNuke'] = {
        "Spear of Grelleth", "Spear of Vizat", "Spear of Tylix",
        "Spear of Bloodwretch", "Spear of Lazam", "Spear of Muram",
    },

    -- Life Tap
    ['LifeTap'] = {
        "Dire Confession", "Dire Covenant", "Dire Testimony",
        "Dire Declaration", "Dire Indictment", "Dire Accusation",
    },

    -- Terror (hate)
    ['Terror'] = {
        "Terror of Tarantella", "Terror of Teratoma", "Terror of Desolor",
        "Terror of Thule", "Terror of Discord", "Terror of Darkness",
    },

    -- Torrent (AE hate)
    ['Torrent'] = {
        "Torrent of Pain", "Torrent of Agony", "Torrent of Suffering",
        "Torrent of Misery", "Torrent of Hate", "Torrent of Anguish",
    },

    -- Poison DoT
    ['PoisonDoT'] = {
        "Dire Stenosis", "Dire Stricture", "Dire Convulsion",
        "Dire Seizure", "Dire Implication", "Dire Constriction",
    },

    -- Disease DoT
    ['DiseaseDoT'] = {
        "Blood of Laarthik", "Blood of Korihor", "Blood of Ikatiar",
        "Blood of Tearc", "Blood of Shoru", "Blood of Thule",
    },

    -- Corruption DoT
    ['CorruptionDoT'] = {
        "Spear of Grelleth", "Bond of Vulak", "Bond of Bynn",
        "Bond of Inruku", "Bond of Tatalros", "Bond of Mortality",
    },

    -- Hate Buff (buff that generates hate)
    ['HateBuff'] = {
        "Voice of Thule", "Voice of the Grave", "Voice of Death",
        "Shroud of Undeath", "Shroud of Discord",
    },

    -- Self Lifetap Proc
    ['LifetapProc'] = {
        "Lich Sting", "Mental Anguish", "Seething Hatred",
        "Touch of T`Vem", "Touch of Volatis", "Touch of the Warlord",
    },

    -- HP Buff
    ['HPBuff'] = {
        "Dire Shield", "Dark Shield", "Shadow Shield",
        "Unholy Guard", "Shroud of Pain",
    },

    -- Pet (skeletal servant)
    ['Pet'] = {
        "Servant of Darkness", "Minion of Darkness", "Child of Darkness",
        "Spawn of Darkness", "Specter of Darkness",
    },
}

-- Disc Lines
M.discLines = {
    ['Leechcurse'] = { "Leechcurse Discipline", "Vicious Bite of Chaos" },
    ['DeflectionDisc'] = { "Deflection Discipline" },
    ['UnholyAura'] = { "Unholy Aura Discipline" },
    ['DamageDisc'] = { "Reavers Bargain", "Insidious Denial" },
    ['AEAggroDisc'] = { "Explosion of Hatred", "Hateful Shock" },
}

-- AA Lines
M.aaLines = {
    ['ExplosionOfHatred'] = { "Explosion of Hatred" },
    ['ExplosionOfSpite'] = { "Explosion of Spite" },
    ['Leech'] = { "Leech Touch" },
    ['HarmTouch'] = { "Harm Touch" },
    ['ThoughtLeech'] = { "Thought Leech" },
    ['VisageOfDeath'] = { "Visage of Death" },
    ['SpireOfShadowKnight'] = { "Spire of the Reavers" },
}

-- Default conditions
M.defaultConditions = {
    ['doLeechcurse'] = function(ctx)
        return ctx.me.pctHPs < 35 and not ctx.me.activeDisc
    end,
    ['doDeflectionDisc'] = function(ctx)
        return ctx.me.pctHPs < 45 and ctx.me.xTargetCount > 4 and not ctx.me.activeDisc
    end,
    ['doUnholyAura'] = function(ctx)
        return ctx.me.pctHPs < 50 and ctx.target.named and not ctx.me.activeDisc
    end,
    ['doDamageDisc'] = function(ctx)
        return ctx.burn and not ctx.me.activeDisc
    end,
    ['doAEAggroDisc'] = function(ctx)
        return ctx.me.xTargetCount >= 3 and ctx.mode == 'Tank'
    end,

    ['doExplosionOfHatred'] = function(ctx)
        return ctx.me.xTargetCount >= 3 and ctx.spawn.npcRadius(50) > 1
    end,
    ['doExplosionOfSpite'] = function(ctx)
        return ctx.me.xTargetCount >= 2
    end,
    ['doLeech'] = function(ctx)
        return ctx.me.pctHPs < 60 and ctx.combat
    end,
    ['doHarmTouch'] = function(ctx)
        return ctx.target.named and ctx.burn
    end,
    ['doThoughtLeech'] = function(ctx)
        return ctx.me.pctMana < 40
    end,
    ['doVisageOfDeath'] = function(ctx)
        return ctx.me.pctHPs < 40 and ctx.combat
    end,

    ['doSpearNuke'] = function(ctx)
        return ctx.combat
    end,
    ['doLifeTap'] = function(ctx)
        return ctx.combat and ctx.me.pctHPs < 80
    end,
    ['doTerror'] = function(ctx)
        return ctx.mode == 'Tank' and not ctx.target.myBuff('Terror')
    end,
    ['doTorrent'] = function(ctx)
        return ctx.me.xTargetCount >= 2 and ctx.mode == 'Tank'
    end,
    ['doPoisonDoT'] = function(ctx)
        return ctx.target.named and not ctx.target.myBuff('Dire') and ctx.target.pctHPs > 30
    end,
    ['doDiseaseDoT'] = function(ctx)
        return ctx.target.named and not ctx.target.myBuff('Blood') and ctx.target.pctHPs > 30
    end,
    ['doCorruptionDoT'] = function(ctx)
        return ctx.target.named and not ctx.target.myBuff('Bond') and ctx.target.pctHPs > 30
    end,

    ['doHateBuff'] = function(ctx)
        return not ctx.me.buff('Voice') and ctx.mode == 'Tank'
    end,
    ['doLifetapProc'] = function(ctx)
        return not ctx.me.buff('Lich Sting') and not ctx.me.buff('Touch')
    end,
    ['doHPBuff'] = function(ctx)
        return not ctx.combat
    end,

    ['doSpireOfShadowKnight'] = function(ctx)
        return ctx.burn
    end,
}

-- Category overrides
M.categoryOverrides = {
    ['doLeechcurse'] = 'emergency',
    ['doDeflectionDisc'] = 'defenses',
    ['doUnholyAura'] = 'defenses',
    ['doDamageDisc'] = 'burn',
    ['doAEAggroDisc'] = 'aggro',
    ['doExplosionOfHatred'] = 'aggro',
    ['doExplosionOfSpite'] = 'aggro',
    ['doLeech'] = 'emergency',
    ['doHarmTouch'] = 'burn',
    ['doThoughtLeech'] = 'utility',
    ['doVisageOfDeath'] = 'defenses',
    ['doSpearNuke'] = 'combat',
    ['doLifeTap'] = 'combat',
    ['doTerror'] = 'aggro',
    ['doTorrent'] = 'aggro',
    ['doPoisonDoT'] = 'combat',
    ['doDiseaseDoT'] = 'combat',
    ['doCorruptionDoT'] = 'combat',
    ['doHateBuff'] = 'utility',
    ['doLifetapProc'] = 'utility',
    ['doHPBuff'] = 'utility',
    ['doSpireOfShadowKnight'] = 'burn',
}

M.Settings = {
    DoLifeTaps = {
        Default = true,
        Category = "Combat",
        DisplayName = "Use Life Taps",
    },
    DoDoTs = {
        Default = true,
        Category = "Combat",
        DisplayName = "Use DoTs",
    },
    DoTerror = {
        Default = true,
        Category = "Aggro",
        DisplayName = "Use Terror",
    },
    UseDefenseDiscs = {
        Default = true,
        Category = "Defense",
        DisplayName = "Defense Discs",
    },
}

return M
