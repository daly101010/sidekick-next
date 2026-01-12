local mq = require('mq')

local function sanitizeId(s)
    s = tostring(s or ''):gsub('%W', ' ')
    s = s:gsub('^%s+', ''):gsub('%s+$', '')
    if s == '' then return 'Disc' end
    local t = {}
    for w in s:gmatch('%S+') do
        table.insert(t, w:sub(1, 1):upper() .. w:sub(2):lower())
    end
    return table.concat(t, '')
end

local function discDef(d)
    local name = tostring(d.name or '')
    local key = 'doDisc' .. sanitizeId(name)
    local icon = 0
    local sp = mq.TLO.Spell(name)
    if sp and sp() and sp.SpellIcon then icon = sp.SpellIcon() or 0 end
    return {
        settingKey = key,
        modeKey = key .. 'Mode',
        kind = 'disc',
        discName = name,
        altName = name,
        icon = icon,
        type = 'offensive',
        visible = true,
        level = tonumber(d.level) or 0,
        timer = (d.timer ~= nil) and tonumber(d.timer) or nil,
        description = tostring(d.desc or ''),
    }
end

-- Source: https://www.raidloot.com/class/rogue?level=130#/spell/Disciplines and Timer_01 through Timer_22
local DISCS = {
    -- Timer 01 - Escape/Bleed Abilities
    { name = 'Desperate Escape X', level = 130, timer = 1, desc = 'Befuddles your target for up to 6 seconds, giving an opportunity to sneak away with mesmerize and hatred reduction effects.' },
    { name = 'Bleed X', level = 128, timer = 1, desc = 'Inflicts damage over time, dealing 143237 damage every six seconds for 12 seconds with hatred removal.' },
    { name = 'Storied Escape', level = 125, timer = 1, desc = 'Confuses the target, triggering invisibility and movement speed boost upon duration end.' },
    { name = 'Carve', level = 123, timer = 1, desc = 'Causes bleeding damage at 86613 damage every six seconds for 12 seconds.' },
    { name = 'Gutsy Escape', level = 120, timer = 1, desc = 'Provides escape via mesmerize with 105% chance to forget all hatred.' },
    { name = 'Lance', level = 118, timer = 1, desc = 'Delivers 61616 damage every six seconds for 12 seconds with hate reduction.' },
    { name = 'Bold Escape', level = 115, timer = 1, desc = 'Befuddles opponent and grants invisibility with movement enhancement.' },
    { name = 'Slash', level = 113, timer = 1, desc = 'Slashing attack dealing 48598 damage every six seconds.' },
    { name = 'Brazen Escape', level = 110, timer = 1, desc = 'Provides escape capability through target confusion and movement buff.' },
    { name = 'Slice', level = 108, timer = 1, desc = 'Bleeding strike inflicting 38330 damage every six seconds.' },
    { name = 'Audacious Escape', level = 105, timer = 1, desc = 'Escape discipline with mesmerize effect.' },
    { name = 'Hack', level = 103, timer = 1, desc = 'Damage-over-time attack lasting 12 seconds.' },
    { name = 'Daring Escape', level = 100, timer = 1, desc = 'Escape ability with confusion mechanic.' },
    { name = 'Gash', level = 98, timer = 1, desc = 'Bleeding wound causing periodic damage.' },
    { name = 'Wild Escape', level = 95, timer = 1, desc = 'Escape discipline with befuddling effect.' },
    { name = 'Lacerate', level = 93, timer = 1, desc = 'Damage-over-time attack.' },
    { name = 'Reckless Escape', level = 90, timer = 1, desc = 'Allows the caster to potentially escape danger by befuddling the opponent.' },
    { name = 'Wound', level = 88, timer = 1, desc = 'Bleeding attack dealing periodic damage.' },
    { name = 'Desperate Escape', level = 85, timer = 1, desc = 'Escape ability with confusion mechanic.' },
    { name = 'Procure Sap', level = 84, timer = 1, desc = 'Procures a slender wooden sap, which can be used to incapacitate and rob your enemies.' },
    { name = 'Bleed', level = 83, timer = 1, desc = 'Causes 2503 damage every six seconds for 12 seconds.' },

    -- Timer 02 - Defensive/Evasion Disciplines
    { name = 'Agile-Footed Discipline', level = 99, timer = 2, desc = 'Places you in an extended evasive combat stance, increasing your chance to avoid attacks with 78% evasion boost.' },
    { name = 'Spell Evasion Discipline', level = 97, timer = 2, desc = 'Avoid the next two magical attacks that would affect you with 4381 damage shield feedback to casters.' },
    { name = 'Quick-Footed Discipline', level = 94, timer = 2, desc = 'Defensive stance providing 74% melee avoidance chance.' },
    { name = 'Fleet-Footed Discipline', level = 89, timer = 2, desc = 'Evasive stance with 60% avoidance against melee attacks.' },
    { name = 'Lithe Discipline', level = 74, timer = 2, desc = 'Defensive stance providing 50% melee avoidance.' },
    { name = 'Spelldodge Discipline', level = 72, timer = 2, desc = 'Attempt to avoid the next magical attack that would affect you with 92% resistance.' },
    { name = 'Nimble Discipline', level = 55, timer = 2, desc = 'Increase your combat reflexes, allowing you to avoid most attacks with dodge boost.' },
    { name = 'Counterattack Discipline', level = 53, timer = 2, desc = 'Perfectly time your counter attacks, riposting every incoming blow.' },

    -- Timer 03 - Melee Damage Disciplines
    { name = 'Executioner Discipline', level = 100, timer = 3, desc = 'Increases the damage of all of your melee attacks with 130% damage boost and 669% minimum hit damage.' },
    { name = 'Eradicator\'s Discipline', level = 95, timer = 3, desc = 'Melee damage enhancement providing 99% increase plus 542% minimum damage.' },
    { name = 'Assassin Discipline', level = 75, timer = 3, desc = 'Provides 67% melee damage increase with 468% minimum damage.' },
    { name = 'Duelist Discipline', level = 59, timer = 3, desc = 'Provides 50% melee damage increase with 400% minimum damage.' },
    { name = 'Kinesthetics Discipline', level = 57, timer = 3, desc = 'Allow you to dual wield and double attack every round with 10000% chance.' },

    -- Timer 04 - Attack Speed/Accuracy Disciplines
    { name = 'Shadowed Speed Discipline', level = 122, timer = 4, desc = 'Increases the speed with which you can attack with your weapons by 35%, and adds a chance for them to trigger Shadowed Speed Shock.' },
    { name = 'Cloaking Speed Discipline', level = 112, timer = 4, desc = 'Increase the speed with which you can attack with your weapons by 35% with poison effect.' },
    { name = 'Shrouding Speed Discipline', level = 102, timer = 4, desc = 'Weapon speed boost with additional damaging poison proc.' },
    { name = 'Twisted Chance Discipline', level = 65, timer = 4, desc = 'Causes you to fall into a battle trance, increasing your chance to hit, chance to critical, as well as your dual wield and double attack chances.' },
    { name = 'Deadly Precision Discipline', level = 63, timer = 4, desc = 'Greatly increases your chances of hitting your target with backstab focus.' },
    { name = 'Blinding Speed Discipline', level = 58, timer = 4, desc = 'Focuses energy into your arms, increasing your attack speed with 33.8% weapon delay reduction.' },
    { name = 'Deadeye Discipline', level = 54, timer = 4, desc = 'Focuses your vision on your opponent, vastly increasing your hit rate with 10000% accuracy boost.' },

    -- Timer 05 - Hatred Reduction/Utility
    { name = 'Indiscernible Discipline IV', level = 127, timer = 5, desc = 'Focuses your energy to imbue your attacks with a strike that lowers hatred in your opponent by 56803.' },
    { name = 'Unseeable Discipline', level = 117, timer = 5, desc = 'Imbue your attacks with a strike that lowers hatred in your opponent by 10733.' },
    { name = 'Undetectable Discipline', level = 107, timer = 5, desc = 'Imbue your attacks with a strike that lowers hatred in your opponent by 7788.' },
    { name = 'Indiscernible Discipline', level = 97, timer = 5, desc = 'Imbue your attacks with a strike that causes your opponent to forget some of the damage.' },
    { name = 'Imperceptible Discipline', level = 66, timer = 5, desc = 'Imbue your attacks with a strike that causes your opponent to forget some of the damage.' },
    { name = 'Healing Will Discipline', level = 63, timer = 5, desc = 'Focus the power of your will to heal your wounds with 100 HP per tick.' },
    { name = 'Fearless Discipline', level = 40, timer = 5, desc = 'Rendering you immune to fear through resolve strengthening.' },
    { name = 'Resistant Discipline', level = 30, timer = 5, desc = 'Increase your resistances for a short time with +20 all resists.' },
    { name = 'Focused Will Discipline', level = 10, timer = 5, desc = 'Heal your wounds with 3 HP per tick when at peace.' },

    -- Timer 06 - Frenzied Stabbing
    { name = 'Frenzied Stabbing Discipline', level = 70, timer = 6, desc = 'Substantially increase how often you can backstab with 6-second timer reduction.' },

    -- Timer 07 - Ambush/Stun Abilities
    { name = 'Bamboozle', level = 121, timer = 7, desc = 'Strikes an unsuspecting opponent with a focused blow, stunning them for up to 5 seconds. Works on targets up to level 125.' },
    { name = 'Ambuscade', level = 116, timer = 7, desc = 'Strikes an unsuspecting opponent with a focused blow, stunning them for up to 5 seconds. Works on targets up to level 120.' },
    { name = 'Bushwhack', level = 111, timer = 7, desc = 'Strikes an unsuspecting opponent with a focused blow, stunning them for up to 5 seconds. Works on targets up to level 115.' },
    { name = 'Lie in Wait', level = 106, timer = 7, desc = 'Strikes an unsuspecting opponent with a focused blow, stunning them for up to 5 seconds. Works on targets up to level 110.' },
    { name = 'Surprise Attack', level = 101, timer = 7, desc = 'Strikes an unsuspecting opponent with a focused blow, stunning them. Works on targets up to level 105.' },
    { name = 'Beset', level = 96, timer = 7, desc = 'Strikes an unsuspecting opponent with a focused blow, stunning them. Works on targets up to level 100.' },
    { name = 'Accost', level = 91, timer = 7, desc = 'Strikes an unsuspecting opponent with a focused blow, stunning them. Works on targets up to level 95.' },
    { name = 'Assail', level = 86, timer = 7, desc = 'Strikes an unsuspecting opponent with a focused blow, stunning them. Works on targets up to level 90.' },
    { name = 'Ambush', level = 81, timer = 7, desc = 'Strikes an unsuspecting opponent with a focused blow, stunning them. Requires being out of combat; works on targets up to level 85.' },
    { name = 'Waylay', level = 76, timer = 7, desc = 'Strikes an unsuspecting opponent with a focused blow, stunning them. Requires being out of combat; works on targets up to level 80.' },

    -- Timer 11 - Misdirection Abilities
    { name = 'Misdirection IX', level = 129, timer = 11, desc = 'Strikes your target with a blunt strike of base value 445, reducing its hatred for you by 31560.' },
    { name = 'Trickery', level = 124, timer = 11, desc = 'Hatred manipulation ability reducing personal threat.' },
    { name = 'Beguile', level = 119, timer = 11, desc = 'Hatred manipulation ability.' },
    { name = 'Cozen', level = 114, timer = 11, desc = 'Hatred manipulation ability.' },
    { name = 'Diversion', level = 109, timer = 11, desc = 'Hatred manipulation ability.' },
    { name = 'Disorientation', level = 104, timer = 11, desc = 'Hatred manipulation ability.' },
    { name = 'Deceit', level = 99, timer = 11, desc = 'Hatred manipulation ability.' },
    { name = 'Delusion', level = 94, timer = 11, desc = 'Hatred manipulation ability.' },
    { name = 'Distraction', level = 92, timer = 11, desc = 'You throw a stone, making quite a lot of noise and causing enemies to turn towards its source.' },
    { name = 'Misdirection', level = 89, timer = 11, desc = 'Hatred manipulation ability.' },

    -- Timer 12 - Puncture Abilities
    { name = 'Invidious Puncture', level = 124, timer = 12, desc = 'Backstab Attack for 3295 with 10000% Accuracy Mod, reduces hate by 5%, and 30% chance to move to bottom of rampage list.' },
    { name = 'Disorienting Puncture', level = 119, timer = 12, desc = 'Backstab dealing 2716 damage, decreases current hate by 5%, 30% chance to lower rampage position.' },
    { name = 'Vindictive Puncture', level = 114, timer = 12, desc = 'Backstab for 2239 damage with hate reduction and 30% rampage list relocation chance.' },
    { name = 'Vexatious Puncture', level = 109, timer = 12, desc = 'Backstab Attack for 1846 with 10000% Accuracy Mod, 5% hate decrease, 30% rampage effect.' },
    { name = 'Disassociative Puncture', level = 104, timer = 12, desc = 'Backstab dealing 1557 damage, reduces hate by 5%, 25% chance to affect rampage list.' },

    -- Timer 13 - Endurance Recovery
    { name = 'Hiatus V', level = 126, timer = 13, desc = 'Rest your arms, slowing melee attacks by 1000% for 48 seconds. Adds 27719 endurance per tick until reaching 30% max or 491000 total.' },
    { name = 'Convalesce', level = 121, timer = 13, desc = 'Rest your arms, slowing melee attacks by 1000%. Adds 12893 endurance per tick until capped at 30% or 270000.' },
    { name = 'Night\'s Calming', level = 116, timer = 13, desc = 'Rest your arms, slowing melee attacks by 1000%. Adds 11137 endurance per tick until capped at 30% or 163000.' },
    { name = 'Relax', level = 111, timer = 13, desc = 'Rest your arms, slowing melee attacks by 1000%. Adds 9621 endurance per tick until capped at 30% or 118000.' },
    { name = 'Hiatus', level = 106, timer = 13, desc = 'Rest your arms, slowing melee attacks by 1000%. Adds 8640 endurance per tick until capped at 30% or 92500.' },
    { name = 'Breather', level = 101, timer = 13, desc = 'Quickens the rate at which you regain endurance, but only if your reserves are lower than 21%. Restoring 3812 per tick initially.' },
    { name = 'Seventh Wind', level = 97, timer = 13, desc = 'Increased endurance regeneration of 498 every six seconds for 2 minutes.' },
    { name = 'Rest', level = 96, timer = 13, desc = 'Quickens endurance recovery when below 21% maximum, adding 1546 per tick.' },
    { name = 'Sixth Wind', level = 92, timer = 13, desc = 'Endurance recovery providing 410 regeneration per tick.' },
    { name = 'Reprieve', level = 91, timer = 13, desc = 'Quickens endurance recovery when below 21% maximum, adding 1274 per tick.' },
    { name = 'Fifth Wind', level = 87, timer = 13, desc = 'Mid-tier endurance recovery ability providing 268 per tick.' },
    { name = 'Respite', level = 86, timer = 13, desc = 'Quickens endurance recovery when below 21% maximum, adding 845 per tick.' },
    { name = 'Fourth Wind', level = 82, timer = 13, desc = 'Endurance regeneration discipline providing 196 per tick.' },
    { name = 'Third Wind', level = 77, timer = 13, desc = 'Recovery ability with 161 endurance per tick.' },
    { name = 'Second Wind', level = 72, timer = 13, desc = 'Increased endurance regeneration of 144 every 6 seconds for 2 minutes.' },

    -- Timer 14 - Accuracy/Healing
    { name = 'Reckless Edge Discipline', level = 121, timer = 14, desc = 'Increases your accuracy by 10000% for up to 60 seconds but increases the damage you take if you get hit. Spell damage +1-20%, melee damage +12%.' },
    { name = 'Ragged Edge Discipline', level = 107, timer = 14, desc = 'Increases your accuracy by 10000% for up to 60 seconds but increases the damage you take if you get hit. Spell damage +1-25%, melee damage +15%.' },
    { name = 'Inner Rejuvenation', level = 93, timer = 14, desc = 'Allows you to heal yourself for up to 29000 or 35% of your life, whichever is lower. This can only occur when you are at peace.' },
    { name = 'Razor\'s Edge Discipline', level = 92, timer = 14, desc = 'Increases your accuracy by 10000% for up to 60 seconds but increases the damage you take if you get hit.' },

    -- Timer 15 - Poison Disciplines
    { name = 'Visaphen Discipline', level = 129, timer = 15, desc = 'Add 39819 damage to your poisons and increase weapon innate spell fire rate by 50%.' },
    { name = 'Crinotoxin Discipline', level = 124, timer = 15, desc = 'Poison damage boost of 12899 with melee proc enhancement.' },
    { name = 'Exotoxin Discipline', level = 119, timer = 15, desc = 'Poison damage addition of 10636 points.' },
    { name = 'Chelicerae Discipline', level = 114, timer = 15, desc = 'Poison enhancement adding 8770 damage with 604% worn proc rate increase.' },
    { name = 'Aculeus Discipline', level = 109, timer = 15, desc = 'Poison boost providing 7231 damage increase with 569% worn proc rate.' },
    { name = 'Arcwork Discipline', level = 104, timer = 15, desc = 'Poison damage enhancement of 5963 points.' },
    { name = 'Aspbleeder Discipline', level = 99, timer = 15, desc = 'Poison augmentation adding 5151 damage with 510% worn proc rate.' },

    -- Timer 16 - Fatal Aim/Throwing
    { name = 'Fatal Aim Discipline IV', level = 130, timer = 16, desc = 'Increases your Throwing damage by 150% and imbues your Throwing attacks with a poisonous effect that deals 41639 damage.' },
    { name = 'Baleful Aim Discipline', level = 116, timer = 16, desc = 'Increases your Throwing damage by 150% and imbues your Throwing attacks with a poisonous effect that deals 5723 damage.' },
    { name = 'Lethal Aim Discipline', level = 108, timer = 16, desc = 'Increases your Throwing damage by 150% and imbues your Throwing attacks with a poisonous effect that deals 4719 damage.' },
    { name = 'Knifeplay Discipline', level = 98, timer = 16, desc = 'Increase your chance to hit with all melee skills as well as your melee damage for 3 minutes. +100% hit, +61% crit, +124% damage, +164% min damage.' },
    { name = 'Fatal Aim Discipline', level = 98, timer = 16, desc = 'Boosts throwing damage with poisonous weapon effect.' },
    { name = 'Deadly Aim Discipline', level = 68, timer = 16, desc = 'Enhances throwing damage with poison application.' },

    -- Timer 17 - Mark Abilities
    { name = 'Easy Mark X', level = 126, timer = 17, desc = 'Stun for 3s up to level 130 plus 30% backstab damage increase.' },
    { name = 'Unsuspecting Mark', level = 121, timer = 17, desc = 'Stun for 3s up to level 125 plus 30% backstab damage increase.' },
    { name = 'Foolish Mark', level = 116, timer = 17, desc = 'Stun for 3s up to level 120 plus 30% backstab damage increase.' },
    { name = 'Naive Mark', level = 111, timer = 17, desc = 'Stun for 3s up to level 115 plus 30% backstab damage increase.' },
    { name = 'Dim-Witted Mark', level = 106, timer = 17, desc = 'Stun for 3s up to level 110 plus 28% backstab damage increase.' },
    { name = 'Wide-Eyed Mark', level = 101, timer = 17, desc = 'Stun for 3s up to level 105 plus piercing damage increase.' },
    { name = 'Gullible Mark', level = 96, timer = 17, desc = 'Stun for 3s up to level 100 plus piercing damage increase.' },
    { name = 'Simple Mark', level = 91, timer = 17, desc = 'Stun for 3s up to level 95 plus piercing damage increase.' },
    { name = 'Easy Mark', level = 86, timer = 17, desc = 'Stun for 3s up to level 90 plus piercing damage increase.' },

    -- Timer 18 - Jugular Abilities
    { name = 'Jugular Hew', level = 122, timer = 18, desc = 'Strikes an unsuspecting opponent with a bloodletting slice, causing 30867 damage every six seconds for 48 seconds. Reduces threat generation.' },
    { name = 'Jugular Rend', level = 117, timer = 18, desc = 'Strikes an unsuspecting opponent with a bloodletting slice, causing 25452 damage every six seconds for 48 seconds. Produces less hatred than standard attacks.' },
    { name = 'Jugular Cut', level = 112, timer = 18, desc = 'Strikes an unsuspecting opponent with a bloodletting slice, causing 20987 damage every six seconds for 48 seconds. Threat reduction ability.' },
    { name = 'Jugular Strike', level = 107, timer = 18, desc = 'Strikes an unsuspecting opponent with a bloodletting slice, causing 17305 damage every six seconds for 48 seconds. Low threat generation.' },
    { name = 'Jugular Hack', level = 102, timer = 18, desc = 'Strikes an unsuspecting opponent with a bloodletting slice, causing 13649 damage every six seconds for 48 seconds. Minimal threat output.' },
    { name = 'Jugular Lacerate', level = 97, timer = 18, desc = 'Strikes an unsuspecting opponent with a bloodletting slice, causing 10316 damage every six seconds for 48 seconds. Threat management included.' },
    { name = 'Jugular Gash', level = 92, timer = 18, desc = 'Strikes an unsuspecting opponent with a bloodletting slice, causing 7486 damage every six seconds for 48 seconds. Reduced threat variant.' },
    { name = 'Jugular Sever', level = 87, timer = 18, desc = 'Strikes an unsuspecting opponent with a bloodletting slice, causing 5432 damage every six seconds for 48 seconds. Threat reduction feature.' },
    { name = 'Jugular Slice', level = 82, timer = 18, desc = 'Strikes an unsuspecting opponent with a bloodletting slice, causing 1493 damage every six seconds for 48 seconds. Requires out-of-combat status.' },
    { name = 'Jugular Slash', level = 77, timer = 18, desc = 'Strikes an unsuspecting opponent with a bloodletting slice, causing 1014 damage every six seconds for 48 seconds. Out-of-combat requirement applies.' },

    -- Timer 19 - Phantom
    { name = 'Phantom Assassin', level = 100, timer = 19, desc = 'Summons an alternate version of yourself to attack your target. The doppelganger works to reduce the target\'s hatred toward you while dealing damage.' },

    -- Timer 20 - Blade Procs
    { name = 'Veiled Blade', level = 124, timer = 20, desc = 'Add Melee Proc: Veiled Blade Stab with 280% Rate Mod - grants three extra 1H Pierce strikes (305 base damage) with 27% refresh chance.' },
    { name = 'Obfuscated Blade', level = 119, timer = 20, desc = 'Add Melee Proc: Obfuscated Blade Stab with 280% Rate Mod - grants three extra 1H Pierce strikes (263 base damage) with 27% refresh chance.' },
    { name = 'Cloaked Blade', level = 114, timer = 20, desc = 'Add Melee Proc: Cloaked Blade Stab with 280% Rate Mod - grants three extra 1H Pierce strikes (227 base damage) with 27% refresh chance.' },
    { name = 'Secret Blade', level = 109, timer = 20, desc = 'Add Melee Proc: Secret Blade Stab with 280% Rate Mod - grants three extra 1H Pierce strikes (196 base damage) with 27% refresh chance.' },
    { name = 'Hidden Blade', level = 104, timer = 20, desc = 'Casts Hidden Blade Effect to provide supplementary bladed strikes during melee combat.' },
    { name = 'Holdout Blade', level = 99, timer = 20, desc = 'Casts Holdout Blade Effect to provide supplementary bladed strikes during melee combat.' },

    -- Timer 22 - Weapon Enhancement
    { name = 'Reciprocal Weapons', level = 121, timer = 22, desc = 'Cast: Highest Rank of Reciprocal Weapon Trigger for damage boost. 1H weapons gain +2454 damage; Backstab gains +3069.' },
    { name = 'Ecliptic Weapons', level = 116, timer = 22, desc = 'Cast: Highest Rank of Ecliptic Weapon Trigger for damage boost. 1H weapons gain +2120 damage; Backstab gains +2651.' },
    { name = 'Composite Weapons', level = 111, timer = 22, desc = 'Cast: Highest Rank of Composite Weapon Trigger for damage boost. 1H weapons gain +1831 damage; Backstab gains +2290.' },
    { name = 'Dissident Weapons', level = 106, timer = 22, desc = 'Cast: Highest Rank of Dissident Weapon Trigger for damage boost.' },
    { name = 'Dichotomic Weapons', level = 101, timer = 22, desc = 'Connects your weapons to two realities, greatly increasing the amount of damage you deal.' },

    -- Weapon Covenant Disciplines (Timer 5)
    { name = 'Weapon Covenant', level = 97, timer = 5, desc = 'Your weapon becomes an extension of your body, greatly increasing the rate at which its combat effects will be triggered.' },
    { name = 'Weapon Bond', level = 92, timer = 5, desc = 'Weapon effect trigger boost with 310% worn proc rate increase.' },
    { name = 'Weapon Affiliation', level = 87, timer = 5, desc = 'Weapon enhancement providing 230% proc rate increase.' },
}

local defs = {}
for _, d in ipairs(DISCS) do
    table.insert(defs, discDef(d))
end

return { disciplines = defs }
