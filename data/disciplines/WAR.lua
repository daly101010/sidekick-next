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

-- Source: https://www.raidloot.com/class/warrior?level=130#/spell/Disciplines and Timer_01 through Timer_22
local DISCS = {
    -- Timer 02 - Defensive Stand Disciplines
    { name = 'Climactic Stand', level = 123, timer = 2, desc = 'Adopt a defensive combat stance, reducing incoming base melee damage by 45%. Physical attacks trigger Climactic Stand Effect, which absorbs up to 51300 melee damage before dissipating.' },
    { name = 'Resolute Stand', level = 118, timer = 2, desc = 'Adopt a defensive combat stance, reducing incoming base melee damage by 45%. Physical attacks trigger Resolute Stand Effect, absorbing up to 42300 melee damage.' },
    { name = 'Ultimate Stand Discipline', level = 113, timer = 2, desc = 'Adopt a defensive combat stance, reducing incoming base melee damage by 45%. Physical attacks trigger Ultimate Stand Effect, absorbing up to 30399 melee damage.' },
    { name = 'Culminating Stand Discipline', level = 108, timer = 2, desc = 'Adopt a defensive combat stance, reducing incoming base melee damage by 45%. Physical attacks trigger Culminating Stand Effect, absorbing up to 22058 melee damage.' },
    { name = 'Last Stand Discipline', level = 98, timer = 2, desc = 'Tighten your muscles and adopt a defensive combat stance, reducing harm from physical attacks. Physical attacks trigger mystical runes to absorb further incoming damage.' },
    { name = 'Offensive Discipline', level = 97, timer = 2, desc = 'Grants increased offensive capabilities, increasing your damage output by 45% minimum hit damage boost by 160%, and 287 hit damage bonus. Increases damage you take from melee strikes by 35%.' },
    { name = 'Final Stand Discipline', level = 72, timer = 2, desc = 'Tighten your muscles and adopt a defensive combat stance, reducing harm done to you by physical attacks for a while.' },
    { name = 'Stonewall Discipline', level = 65, timer = 2, desc = 'Place yourself in a defensive combat stance that causes you to take less damage, but slows your movement rate by 70%.' },
    { name = 'Defensive Discipline', level = 55, timer = 2, desc = 'Place yourself in a defensive combat stance that causes you to take 45% less damage and take 55% lower damage output, but also lowers your critical strike chance.' },
    { name = 'Evasive Discipline', level = 52, timer = 2, desc = 'Place yourself in an evasive combat stance, increasing your chance to avoid attacks by 50%, but also lowering your hit rate by 33%.' },

    -- Timer 03 - Fortitude/Furious
    { name = 'Fortitude Discipline', level = 59, timer = 3, desc = 'Heighten your combat reflexes, increasing your chance of evading attacks with 10000% avoidance boost.' },
    { name = 'Furious Discipline', level = 56, timer = 3, desc = 'Allow you to perfectly time your counter attacks, riposting every incoming blow with 10000% riposte chance.' },

    -- Timer 04 - Offensive Disciplines
    { name = 'Razor Tongue Discipline', level = 122, timer = 4, desc = 'Taunts trigger Razor Tongue Strike, dealing 28607 damage to your target in addition to your taunt\'s normal effect.' },
    { name = 'Biting Tongue Discipline', level = 107, timer = 4, desc = 'Taunts trigger Biting Tongue Strike, dealing 4603 damage to your target and generating 5959 hatred in addition to normal taunt effects.' },
    { name = 'Barbed Tongue Discipline', level = 94, timer = 4, desc = 'Your taunts deal damage and generate even more hatred.' },
    { name = 'Aggressive Discipline', level = 60, timer = 4, desc = 'Place yourself in an aggressive combat stance that increases your damage output by 30%, but also causes you to take more damage.' },
    { name = 'Fellstrike Discipline', level = 58, timer = 4, desc = 'Increase the damage of melee attacks by 50%, with a 400% minimum hit damage boost.' },
    { name = 'Precision Discipline', level = 57, timer = 4, desc = 'Place yourself in a precise combat stance that increases your hit rate, but also lowers your chance of avoiding attacks.' },
    { name = 'Mighty Strike Discipline', level = 54, timer = 4, desc = 'Fill your arms with rage, causing every attack to land as a critical hit.' },
    { name = 'Charge Discipline', level = 53, timer = 4, desc = 'Increase your chances to hit with any melee attack.' },

    -- Timer 05 - Utility/Armor Runes
    { name = 'Armor of Rallosian Runes', level = 121, timer = 5, desc = 'Physical attacks trigger Rallosian Rune Effect, which prevents you from taking 42591 points of damage.' },
    { name = 'Armor of Akhevan Runes', level = 116, timer = 5, desc = 'Physical attacks trigger Akhevan Rune Effect, preventing you from taking 35119 points of damage.' },
    { name = 'Armor of Relentless Runes', level = 111, timer = 5, desc = 'Physical attacks trigger Relentless Rune Effect, preventing you from taking 25238 points of damage.' },
    { name = 'Armor of Tenacious Runes', level = 106, timer = 5, desc = 'Physical attacks trigger Tenacious Rune Effect, preventing you from taking 18313 points of damage.' },
    { name = 'Armor of Darkened Runes', level = 101, timer = 5, desc = 'Physical attacks trigger one of these runes and prevent you from taking an amount of damage.' },
    { name = 'Armor of Stalwart Runes', level = 96, timer = 5, desc = 'Physical attacks trigger one of these runes and prevent you from taking an amount of damage.' },
    { name = 'Armor of Mystical Runes', level = 91, timer = 5, desc = 'Physical attacks trigger one of these runes and prevent you from taking an amount of damage.' },
    { name = 'Armor of Phantasmic Runes', level = 86, timer = 5, desc = 'Phantasmic symbols surround you. Physical attacks trigger one of these runes and prevent you from taking an amount of damage.' },
    { name = 'Armor of Timeworn Runes', level = 81, timer = 5, desc = 'Timeworn symbols surround you. Physical attacks trigger one of these runes and prevent you from taking an amount of damage.' },
    { name = 'Armor of Draconic Runes', level = 76, timer = 5, desc = 'Draconic symbols surround you. Physical attacks trigger one of these runes and prevent you from taking an amount of damage.' },
    { name = 'Aura of Draconic Runes', level = 71, timer = 5, desc = 'Draconic symbols surround you. Physical attacks trigger one of these runes and prevent you from taking an amount of damage.' },
    { name = 'Aura of Runes Discipline', level = 66, timer = 5, desc = 'Focus your energy in an attempt to absorb an amount of damage any time you are attacked.' },
    { name = 'Healing Will Discipline', level = 63, timer = 5, desc = 'Focus the power of your will to heal your wounds.' },
    { name = 'Spirit of Rage Discipline', level = 61, timer = 5, desc = 'Fill your body with a spirit of rage, causing your attacks to generate increased anger in your opponents by 50%.' },
    { name = 'Fearless Discipline', level = 40, timer = 5, desc = 'Strengthen your resolve, rendering you immune to fear.' },
    { name = 'Resistant Discipline', level = 30, timer = 5, desc = 'Focus your will, increasing your resistances by 20 for a short time.' },
    { name = 'Focused Will Discipline', level = 10, timer = 5, desc = 'Focus the energy of your will to heal your wounds. Any aggressive action you take will break your concentration.' },

    -- Timer 06 - Onslaught Disciplines
    { name = 'Brightfeld\'s Onslaught Discipline', level = 117, timer = 6, desc = 'Adds 797 minimum melee damage, increases critical strike chance by 270%, grants 160% critical damage increase, and makes critical attacks crippling blows for 30 seconds.' },
    { name = 'Brutal Onslaught Discipline', level = 74, timer = 6, desc = 'Increase critical strike chance by 270%, grant a 140% non-cumulative increase to critical damage, and cause all critical melee attacks to be crippling blows for 30 seconds.' },
    { name = 'Savage Onslaught Discipline', level = 68, timer = 6, desc = 'Increase critical strike chance by 270%, grant a 100% non-cumulative increase to critical damage, and cause all critical attacks to be crippling blows for 30 seconds.' },

    -- Timer 07 - Defense Stun Disciplines
    { name = 'Levincrash Defense Discipline', level = 120, timer = 7, desc = 'Incoming melee attacks have a chance to stun your opponent for up to 2.5 seconds, affecting creatures up to level 118.' },
    { name = 'Stormstrike Defense Discipline', level = 110, timer = 7, desc = 'Incoming melee attacks have a chance to stun your opponent for up to 2.5 seconds, affecting creatures up to level 113.' },
    { name = 'Tempestuous Defense Discipline', level = 100, timer = 7, desc = 'Focus your energy to attempt to stun your opponent any time you are attacked.' },
    { name = 'Shocking Defense Discipline', level = 70, timer = 7, desc = 'Focus your energy to attempt to stun your opponent any time you are attacked.' },

    -- Timer 09 - Provoke/Hate Abilities
    { name = 'Provoke XIX', level = 128, timer = 9, desc = 'Increase Hate with recourse reflecting damage reduction on next 2 hits.' },
    { name = 'Infuriate', level = 123, timer = 9, desc = 'Generates hatred while reflecting recourse providing 50% melee damage absorption.' },
    { name = 'Bristle', level = 118, timer = 9, desc = 'Incites opponent hatred; recourse absorbs melee damage up to 38155 total.' },
    { name = 'Aggravate', level = 113, timer = 9, desc = 'Incites hatred (17456) with recourse absorbing 50% melee damage for 2 hits.' },
    { name = 'Slander', level = 108, timer = 9, desc = 'Generates hatred (13732); reflects recourse with damage absorption capability.' },
    { name = 'Insult', level = 103, timer = 9, desc = 'Incites hatred (10379) with defensive recourse providing damage mitigation.' },
    { name = 'Ridicule', level = 98, timer = 9, desc = 'Incites hatred (8757); recourse absorbs melee damage up to 7086.' },
    { name = 'Scorn', level = 95, timer = 9, desc = 'Incites hatred (3651) with recourse absorbing 50% incoming melee damage.' },
    { name = 'Scoff', level = 90, timer = 9, desc = 'Generates hatred (1314); reflects recourse with 50% melee damage absorption.' },
    { name = 'Jeer', level = 85, timer = 9, desc = 'Incites hatred (1958) with recourse providing damage absorption.' },
    { name = 'Sneer', level = 80, timer = 9, desc = 'Generates hatred (1605); recourse absorbs melee damage up to 689.' },
    { name = 'Scowl', level = 75, timer = 9, desc = 'Incites hatred (1440) with defensive recourse effect.' },
    { name = 'Mock', level = 70, timer = 9, desc = 'Increases defensive positioning; recourse absorbs 50% melee damage.' },

    -- Timer 10 - Blade/Knuckle Abilities
    { name = 'Cyclone Blades XIV', level = 127, timer = 10, desc = '1H Slash Attack for 324 with 10000% Accuracy Mod hitting up to 30 nearby targets.' },
    { name = 'Spiraling Blades', level = 124, timer = 10, desc = '1H Slash Attack for 237 with 10000% Accuracy Mod affecting 30 targets.' },
    { name = 'Hurricane Blades', level = 119, timer = 10, desc = '1H Slash Attack for 215 with 10000% Accuracy Mod to nearby enemies.' },
    { name = 'Tempest Blades', level = 114, timer = 10, desc = '1H Slash Attack for 185 with 10000% Accuracy Mod in radius.' },
    { name = 'Dragonstrike Blades', level = 109, timer = 10, desc = '1H Slash Attack for 160 with 10000% Accuracy Mod damage attack.' },
    { name = 'Stormstrike Blades', level = 104, timer = 10, desc = '1H Slash Attack for 150 with 10000% Accuracy Mod multi-target strike.' },
    { name = 'Stormwheel Blades', level = 99, timer = 10, desc = '1H Slash Attack for 132 with 10000% Accuracy Mod ability.' },
    { name = 'Knuckle Break', level = 95, timer = 10, desc = 'Decrease Hit Damage by 6% for next 5 attacks.' },
    { name = 'Cyclonic Blades', level = 94, timer = 10, desc = '1H Slash Attack for 109 with 10000% Accuracy Mod attack.' },
    { name = 'Knuckle Snap', level = 90, timer = 10, desc = 'Decrease Hit Damage by 5% for 5 hits.' },
    { name = 'Forceful Attraction', level = 89, timer = 10, desc = 'Gradual Pull to 30\' away affecting up to 6 targets.' },
    { name = 'Wheeling Blades', level = 89, timer = 10, desc = '1H Slash Attack for 90 with 10000% Accuracy Mod strike.' },
    { name = 'Knuckle Crush', level = 85, timer = 10, desc = 'Decrease Hit Damage by 5% effect.' },
    { name = 'Maelstrom Blade', level = 84, timer = 10, desc = '1H Slash Attack for 90 with 10000% Accuracy Mod ability.' },
    { name = 'Knuckle Smash', level = 80, timer = 10, desc = 'Decrease Hit Damage by 5% for next 5 attacks.' },
    { name = 'Whorl Blade', level = 79, timer = 10, desc = '1H Slash Attack for 74 with 10000% Accuracy Mod attack.' },
    { name = 'Vortex Blade', level = 74, timer = 10, desc = '1H Slash Attack for 60 with 10000% Accuracy Mod strike.' },
    { name = 'Cyclone Blade', level = 69, timer = 10, desc = '1H Slash Attack for 50 with 10000% Accuracy Mod ability.' },
    { name = 'Whirlwind Blade', level = 61, timer = 10, desc = '1H Slash Attack for 35 with 10000% Accuracy Mod attack.' },

    -- Timer 11 - Flash of Anger
    { name = 'Flash of Anger', level = 87, timer = 11, desc = 'A brief flash of anger allows you to parry all incoming attacks for up to 6 seconds. You may not activate this ability when you are in your two-handed stance.' },

    -- Timer 12 - Accuracy/Wade Abilities
    { name = 'Perforate', level = 120, timer = 12, desc = 'Increase Chance to Hit by 10000% with 62 max hit attempts. Grants weight to attacks penetrating opponent defenses.' },
    { name = 'Wade into Conflict', level = 119, timer = 12, desc = 'Activates defensive proc causing enemy melee strikes to trigger shouts (max 24) drawing nearby foe attention over 60 seconds.' },
    { name = 'Strike Through', level = 105, timer = 12, desc = 'Increase Chance to Hit by 10000% with 53 max hit attempts. Provides attack weight to breach opponent defenses.' },
    { name = 'Wade into Battle', level = 99, timer = 12, desc = 'Steels character so enemy melee strikes trigger shouts (max 24) attracting surrounding foes for up to 60 seconds.' },
    { name = 'Determined Reprisal', level = 97, timer = 12, desc = 'Focuses will to respond to opponent attacks with recourse adding 77% to all of your melee attacks for 60 seconds.' },
    { name = 'Jab Through', level = 89, timer = 12, desc = 'Increase Chance to Hit by 10000% with 40 max hit attempts. Permits jabbing through opponent defenses.' },
    { name = 'Punch Through', level = 84, timer = 12, desc = 'Increase Chance to Hit by 10000% with 35 max hit attempts. Permits punching through opponent defenses.' },

    -- Timer 13 - Endurance Recovery
    { name = 'Hiatus V', level = 126, timer = 13, desc = 'Rest your arms, slowing melee attacks by 1000% for 48 seconds. Adds 27719 endurance to your pool every six seconds until you reach 30% of your maximum or 491000 total, whichever is lower.' },
    { name = 'Convalesce', level = 121, timer = 13, desc = 'Rest your arms, slowing melee attacks by 1000%. Adds 12893 endurance every six seconds until reaching 30% maximum or 270000 total.' },
    { name = 'Night\'s Calming', level = 116, timer = 13, desc = 'Rest your arms, slowing melee attacks by 1000%. Adds 11137 endurance every six seconds until reaching 30% maximum or 163000 total.' },
    { name = 'Relax', level = 111, timer = 13, desc = 'Rest your arms, slowing melee attacks by 1000%. Adds 9621 endurance every six seconds until reaching 30% maximum or 118000 total.' },
    { name = 'Hiatus', level = 106, timer = 13, desc = 'Rest your arms, slowing melee attacks by 1000%. Adds 8640 endurance every six seconds until reaching 30% maximum or 92500 total.' },
    { name = 'Breather', level = 101, timer = 13, desc = 'Quickens endurance recovery when reserves are lower than 21% of your maximum, restoring most quickly when ability begins.' },
    { name = 'Seventh Wind', level = 97, timer = 13, desc = 'Sacrifice endurance to receive an increased endurance regeneration of 498 every six seconds for 2 minutes.' },
    { name = 'Rest', level = 96, timer = 13, desc = 'Quicken endurance recovery when reserves are lower than 21% of your maximum.' },
    { name = 'Sixth Wind', level = 92, timer = 13, desc = 'Sacrifice endurance to receive an increased endurance regeneration of 410 every six seconds for 2 minutes.' },
    { name = 'Reprieve', level = 91, timer = 13, desc = 'Quicken endurance recovery when reserves are lower than 21% of your maximum.' },
    { name = 'Fifth Wind', level = 87, timer = 13, desc = 'Sacrifice endurance to receive an increased endurance regeneration of 268 every six seconds for 2 minutes.' },
    { name = 'Respite', level = 86, timer = 13, desc = 'Quicken endurance recovery when reserves are lower than 21% of your maximum.' },
    { name = 'Fourth Wind', level = 82, timer = 13, desc = 'Sacrifice endurance to receive an increased endurance regeneration of 196 every six seconds for 2 minutes.' },
    { name = 'Third Wind', level = 77, timer = 13, desc = 'Sacrifice endurance to receive an increased endurance regeneration of 161 every six seconds for 2 minutes.' },
    { name = 'Second Wind', level = 72, timer = 13, desc = 'Sacrifice endurance to receive an increased endurance regeneration of 144 every 6 seconds for 2 minutes.' },

    -- Timer 14 - Roar/Healing
    { name = 'Roar of Challenge', level = 93, timer = 14, desc = 'A mighty roar will lower the accuracy of up to three nearby enemies and increase their hatred of you by 1946.' },
    { name = 'Inner Rejuvenation', level = 93, timer = 14, desc = 'Heal yourself for up to 29000 or 35% of your life, whichever is lower. Can only occur when you are at peace.' },
    { name = 'Rallying Roar', level = 88, timer = 14, desc = 'A mighty roar will lower the accuracy of up to three nearby enemies and increase their hatred of you by 1430.' },

    -- Timer 15 - Attention Disciplines
    { name = 'Unquestioned Attention', level = 127, timer = 15, desc = 'Gains your target\'s undivided attention for 18 seconds. During this period your armor class will increase by 15431, you will generate 55% more hatred than normal, and your allies will generate 95% less hatred than normal. Works on targets up to level 135.' },
    { name = 'Unconditional Attention', level = 122, timer = 15, desc = 'Gains your target\'s undivided attention for 18 seconds. AC increases by 6362, 55% more hate generation, allies generate 95% less hate. Works up to level 130.' },
    { name = 'Unrelenting Attention', level = 117, timer = 15, desc = 'AC increases by 5247, 55% more hate generation, allies generate 95% less hate. Works up to level 125.' },
    { name = 'Unending Attention', level = 112, timer = 15, desc = 'AC increases by 4327, 55% more hate generation, allies generate 95% less hate. Works up to level 120.' },
    { name = 'Unyielding Attention', level = 107, timer = 15, desc = 'AC increases by 3270, 55% more hate generation, allies generate 95% less hate. Works up to level 115.' },
    { name = 'Unflinching Attention', level = 102, timer = 15, desc = 'Increased AC, more hate generation, reduced ally hate. Works up to level 110.' },
    { name = 'Unbroken Attention', level = 97, timer = 15, desc = 'Increased AC, more hate generation, reduced ally hate. Works up to level 105.' },
    { name = 'Undivided Attention', level = 92, timer = 15, desc = 'Increased AC, more hate generation, reduced ally hate. Works up to level 100.' },

    -- Timer 16 - Warrior's Resolve/Runes
    { name = 'Warrior\'s Resolve', level = 124, timer = 16, desc = 'Generates 12134 hatred in your target and grants a rune that protects against incoming melee hits that inflict at least 45000 damage, absorbing 80% of the damage that exceeds 45000 for 4 minutes. Total capacity: 1186000 damage.' },
    { name = 'Warrior\'s Aegis', level = 119, timer = 16, desc = 'Generates 10006 hatred in your target and grants a rune that protects against incoming melee hits that inflict at least 40000 damage, absorbing 80% of the damage that exceeds 40000 for 4 minutes. Total capacity: 962333 damage.' },
    { name = 'Warrior\'s Rampart', level = 114, timer = 16, desc = 'Generates 8067 hatred in your target and grants a rune that protects against incoming melee hits that inflict at least 31000 damage, absorbing 80% of the damage that exceeds 31000 for 4 minutes. Total capacity: 686667 damage.' },
    { name = 'Warrior\'s Bastion', level = 109, timer = 16, desc = 'Generates 6346 hatred in your target and grants a rune that protects against incoming melee hits that inflict at least 20000 damage, absorbing 80% of the damage that exceeds 20000 for 4 minutes. Total capacity: 268292 damage.' },
    { name = 'Warrior\'s Bulwark', level = 104, timer = 16, desc = 'Creates a moderate hatred-generating rune that absorbs incoming melee damage (80% over 19000 threshold; max 91672).' },
    { name = 'Warrior\'s Auspice', level = 99, timer = 16, desc = 'Creates a moderate hatred-generating auspice that absorbs incoming melee damage (75% over 18500 threshold; max 77348).' },

    -- Timer 18 - Absorption Disciplines
    { name = 'End of the Line', level = 122, timer = 18, desc = 'Max Hits: 600 Incoming Hits Or Spells Or DS. Absorb Melee Damage: 100%, Max Per Hit: 8292, Total: 3830500.' },
    { name = 'Finish the Fight', level = 112, timer = 18, desc = 'Max Hits: 600 Incoming Hits Or Spells Or DS. Absorb Melee Damage: 100%, Max Per Hit: 5650, Total: 2486000.' },
    { name = 'Pain Doesn\'t Hurt', level = 102, timer = 18, desc = 'Triggers Pain Doesn\'t Hurt Effect, which absorbs melee and spell damage up to 4270 per hit with 1879000 total capacity.' },
    { name = 'No Time to Bleed', level = 96, timer = 18, desc = 'Triggers No Time to Bleed Effect, which absorbs melee and spell damage up to 3098 per hit with 1549000 total capacity.' },

    -- Timer 19 - Phantom
    { name = 'Phantom Aggressor', level = 100, timer = 19, desc = 'Summons an alternate-reality version of yourself to attack a target. The spell generates significant threat and deals minor damage, with the summoned doppelganger contributing ongoing hatred accumulation against the enemy.' },

    -- Timer 20 - Shield Disciplines
    { name = 'Reciprocal Shield', level = 121, timer = 20, desc = 'Activates the highest rank you know of Reciprocal Shielding 1.' },
    { name = 'Ecliptic Shield', level = 116, timer = 20, desc = 'Activates the highest rank you know of Ecliptic Shielding 1.' },
    { name = 'Composite Shield', level = 111, timer = 20, desc = 'Activates the highest rank you know of Composite Shielding 1.' },
    { name = 'Dissident Shield', level = 106, timer = 20, desc = 'Activates the highest rank you know of Dissident Shielding 1.' },
    { name = 'Dichotomic Shield', level = 101, timer = 20, desc = 'Raises a protective barrier reducing damage and increasing threat.' },

    -- Timer 22 - Shield Attack Disciplines
    { name = 'Shield Split', level = 125, timer = 22, desc = '2H Slash Attack for 1686 with 10000% Accuracy Mod triggering Bracing Stance VIII, which absorbs 40% of melee damage up to 69000 across 2 attacks.' },
    { name = 'Shield Rupture', level = 120, timer = 22, desc = '2H Slash Attack for 1390 with 10000% Accuracy Mod triggering Bracing Stance VII, which absorbs 40% of melee damage up to 59000 across 2 attacks.' },
    { name = 'Shield Splinter', level = 115, timer = 22, desc = '2H Slash Attack for 1147 with 10000% Accuracy Mod triggering Bracing Stance VI, which absorbs 40% of melee damage up to 45539 across 2 attacks.' },
    { name = 'Shield Sunder', level = 110, timer = 22, desc = '2H Slash Attack for 946 with 10000% Accuracy Mod triggering Bracing Stance V, which absorbs 40% of melee damage up to 36431 across 2 attacks.' },
    { name = 'Shield Break', level = 104, timer = 22, desc = 'Strikes opponent with shield damage (687 base), triggering Bracing Stance that absorbs 40% melee damage up to 29145 across 2 attacks.' },
    { name = 'Shield Topple', level = 83, timer = 22, desc = 'Strikes opponent with shield damage (246 base), triggering Bracing Stance absorbing 40% melee damage up to 413 across 2 attacks.' },

    -- Weapon Covenant Disciplines (Timer 5)
    { name = 'Weapon Covenant', level = 97, timer = 5, desc = 'Your weapon becomes an extension of your body, greatly increasing the rate at which its combat effects will be triggered.' },
    { name = 'Weapon Bond', level = 92, timer = 5, desc = 'Your weapon becomes an extension of your body, greatly increasing the rate at which its combat effects will be triggered.' },
    { name = 'Weapon Affiliation', level = 87, timer = 5, desc = 'Your weapon becomes an extension of your body, greatly increasing the rate at which its combat effects will be triggered.' },
}

local defs = {}
for _, d in ipairs(DISCS) do
    table.insert(defs, discDef(d))
end

return { disciplines = defs }
