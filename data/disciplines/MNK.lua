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

-- Source: https://www.raidloot.com/class/monk?level=130#/spell/Disciplines and Timer_01 through Timer_22
local DISCS = {
    -- Timer 01 - Auras
    { name = 'Master\'s Aura', level = 70, timer = 1, desc = 'Increases your companions\' chance to dodge, parry, and riposte attacks. Grants +10% riposte, +10% parry, and +10% block chance.' },
    { name = 'Fists of Wu', level = 68, timer = 1, desc = 'Grants your companions the fists of Wu, increasing the frequency they will execute double attacks by 6%.' },
    { name = 'Disciple\'s Aura', level = 55, timer = 1, desc = 'Increases your companions\' chance to dodge, parry, and riposte attacks. Grants +5% riposte, +5% parry, and +5% block chance.' },

    -- Timer 02 - Defensive Disciplines
    { name = 'Earthforce Discipline', level = 96, timer = 2, desc = 'Joins your body with the strength of the earth, strengthening your attacks and causing you to take greatly decreased melee damage with 90% mitigation and stun immunity.' },
    { name = 'Impenetrable Discipline', level = 72, timer = 2, desc = 'Provides 90% melee mitigation, stun immunity, and 50-70% chances to absorb strikes.' },
    { name = 'Earthwalk Discipline', level = 65, timer = 2, desc = 'Grants 90% melee mitigation and complete stun resistance.' },
    { name = 'Voiddance Discipline', level = 54, timer = 2, desc = 'Focuses your combat reflexes, allowing you to avoid melee attacks with 10000% avoidance boost.' },
    { name = 'Whirlwind Discipline', level = 53, timer = 2, desc = 'Enables riposting with 10000% riposte chance increase.' },
    { name = 'Stonestance Discipline', level = 51, timer = 2, desc = 'Offers 90% melee damage mitigation.' },

    -- Timer 03 - Palm/Damage Disciplines
    { name = 'Terrorpalm Discipline', level = 99, timer = 3, desc = 'Increases melee damage output by 138% with 736% minimum hit boost for 30 seconds.' },
    { name = 'Diamondpalm Discipline', level = 94, timer = 3, desc = 'Boosts all melee attacks by 105% damage and 593% minimum damage for 30 seconds.' },
    { name = 'Crystalpalm Discipline', level = 79, timer = 3, desc = 'Raises melee damage by 67% with 468% minimum hit increase.' },
    { name = 'Hundred Fists Discipline', level = 57, timer = 3, desc = 'Reduces weapon delay by 33.8% for increased attack rate.' },
    { name = 'Innerflame Discipline', level = 56, timer = 3, desc = 'Boosts melee damage by 50% with 400% minimum damage increase.' },

    -- Timer 04 - Special Attack Enhancement
    { name = 'Ironfist Discipline', level = 88, timer = 4, desc = 'Enhances special attacks (Dragon Punch, Eagle Strike, Flying Kick, Round Kick, Tiger Claw, Kick) by 215% for 60 seconds.' },
    { name = 'Scaledfist Discipline', level = 74, timer = 4, desc = 'Strengthens special attacks by 180% for 60 seconds.' },
    { name = 'Ashenhand Discipline', level = 60, timer = 4, desc = 'All special attacks (Dragon Punch, Eagle Strike, Flying Kick, Round Kick, Tiger Claw, Kick) gain 150% damage for 60 seconds.' },
    { name = 'Silentfist Discipline', level = 59, timer = 4, desc = 'Dragon punch receives 65% damage boost and 10000% hit chance increase.' },
    { name = 'Thunderkick Discipline', level = 52, timer = 4, desc = 'Flying kick damage increases by 75% with 20% accuracy boost.' },

    -- Timer 05 - Movement/Utility
    { name = 'Dreamwalk Discipline', level = 66, timer = 5, desc = 'Grants 125% movement speed and 100% spell resistance.' },
    { name = 'Healing Will Discipline', level = 63, timer = 5, desc = 'Heals 100 HP per tick while out of combat.' },
    { name = 'Planeswalk Discipline', level = 61, timer = 5, desc = 'Increases movement speed by 125%.' },
    { name = 'Fearless Discipline', level = 40, timer = 5, desc = 'Provides 10000% fear resistance for complete immunity.' },
    { name = 'Resistant Discipline', level = 30, timer = 5, desc = 'Increases all resistances by 20 points.' },
    { name = 'Focused Will Discipline', level = 10, timer = 5, desc = 'Heals 3 HP per tick, canceled by aggressive actions.' },

    -- Timer 06 - Heel/Kick Disciplines
    { name = 'Heel of Zagali', level = 100, timer = 6, desc = 'Flying kicks gain 67% damage increase, 131% hit chance boost, 7-second timer reduction.' },
    { name = 'Heel of Kojai', level = 95, timer = 6, desc = 'Flying kicks receive 54% damage boost, 103% hit increase, 7-second cooldown reduction.' },
    { name = 'Heel of Kai', level = 90, timer = 6, desc = 'Flying kicks gain 35% damage, 78% hit chance improvement, 7-second timer decrease.' },
    { name = 'Heel of Kanji', level = 70, timer = 6, desc = 'Flying kicks boosted by 30% damage, 50% hit increase, 7-second cooldown reduction.' },
    { name = 'Rapid Kick Discipline', level = 70, timer = 6, desc = 'Decreases flying kick timer by 7 seconds.' },

    -- Timer 07 - Counterforce Disciplines
    { name = 'Counterforce Discipline V', level = 129, timer = 7, desc = 'Focuses your energy, allowing you to respond to opponent\'s attacks with Counterforce Discipline Effect V Azia and absorb 15% of incoming melee damage (2089000 total).' },
    { name = 'Counterblow Discipline', level = 119, timer = 7, desc = 'Focuses your energy, allowing you to respond to opponent\'s attacks with Counterblow Discipline Effect and absorb 15% of incoming melee damage (621000 total damage absorption).' },
    { name = 'Counterstrike Discipline', level = 109, timer = 7, desc = 'Triggers counterstrike response on attacks while absorbing 15% melee damage (436375 maximum).' },
    { name = 'Contraforce Discipline', level = 99, timer = 7, desc = 'Focuses your energy to attempt to slow and weaken your opponent\'s attacks any time you are attacked and absorb 15% of incoming melee damage (316700 total absorption).' },
    { name = 'Counterforce Discipline', level = 68, timer = 7, desc = 'Applies slowing effect on incoming attacks at 150% rate modifier.' },

    -- Timer 08 - Death Prevention
    { name = 'Defy Death', level = 125, timer = 8, desc = 'Increases the amount of punishment you can absorb before death by 75578 with healing scaling from 7428 to 22278 HP per tick based on health threshold.' },
    { name = 'Repeal Death', level = 120, timer = 8, desc = 'Offers 62319 negative HP buffer and tiered healing from 6125 to 18370 HP per tick.' },
    { name = 'Rescind Death', level = 115, timer = 8, desc = 'Grants 45220 negative HP with healing ranging from 5050 to 15148 HP per tick.' },
    { name = 'Reject Death', level = 110, timer = 8, desc = 'Provides 37287 negative HP and healing from 3983 to 11948 HP per tick at low health.' },
    { name = 'Refuse Death', level = 105, timer = 8, desc = 'Greatly increases the amount of punishment you can absorb before death with regenerative benefits.' },
    { name = 'Forestall Death', level = 100, timer = 8, desc = 'Enhances survivability through negative HP increase and regenerative capabilities at reduced health.' },
    { name = 'Protection of the Shadewalker', level = 100, timer = 8, desc = 'Defensive stance enabling wound mending through successful blocks, parries, and ripostes.' },
    { name = 'Decry Death', level = 95, timer = 8, desc = 'Survival discipline with defensive and regenerative effects.' },
    { name = 'Deny Death', level = 90, timer = 8, desc = 'Mid-tier death prevention ability.' },
    { name = 'Defer Death', level = 85, timer = 8, desc = 'Lower-level death-prevention mechanics.' },
    { name = 'Delay Death', level = 80, timer = 8, desc = 'Entry-level survival discipline.' },

    -- Timer 09 - Synergy/Sting Abilities
    { name = 'Sting of the Spider', level = 128, timer = 9, desc = 'Quickly throw three shuriken of base damage 3751 with 10000% accuracy.' },
    { name = 'Lifewalker\'s Synergy', level = 126, timer = 9, desc = 'Delivers three flying kicks (base 1863) and applies vulnerability increasing flying kick damage by 125%.' },
    { name = 'Fatewalker\'s Synergy', level = 121, timer = 9, desc = 'Three flying kicks (base 1502) with effect causing 125% increased flying kick damage taken.' },
    { name = 'Bloodwalker\'s Synergy', level = 116, timer = 9, desc = 'Three flying kicks (base 1043) inflicting vulnerability to flying kicks.' },
    { name = 'Sting of the Netherbian', level = 116, timer = 9, desc = 'Three shuriken throws (base 900) with 10000% accuracy modifier.' },
    { name = 'Icewalker\'s Synergy', level = 111, timer = 9, desc = 'Three flying kicks (base 902) applying 125% flying kick damage vulnerability.' },
    { name = 'Firewalker\'s Synergy', level = 106, timer = 9, desc = 'Three flying kicks (base 818) with debuff increasing flying kick damage taken.' },
    { name = 'Sting of the Scorpikis', level = 106, timer = 9, desc = 'Three shuriken attacks (base 779 damage).' },
    { name = 'Doomwalker\'s Synergy', level = 101, timer = 9, desc = 'Three flying kicks (base 771) weakening target against flying kicks.' },
    { name = 'Shadewalker\'s Synergy', level = 96, timer = 9, desc = 'Three flying kicks (base 692) with 122% flying kick damage vulnerability.' },
    { name = 'Sting of the Wasp', level = 96, timer = 9, desc = 'Three shuriken throws at opponent.' },
    { name = 'Veilwalker\'s Synergy', level = 91, timer = 9, desc = 'Three flying kicks (base 532) causing 116% flying kick damage weakness.' },
    { name = 'Dreamwalker\'s Synergy', level = 86, timer = 9, desc = 'Three flying kicks (base 381) with 101% flying kick damage vulnerability.' },
    { name = 'Calanin\'s Synergy', level = 81, timer = 9, desc = 'Three flying kicks (base 346) creating 100% flying kick damage weakness.' },
    { name = 'Dragon Fang', level = 69, timer = 9, desc = 'Infuses your body with the power of the dragon for extra magical damage.' },
    { name = 'Leopard Claw', level = 61, timer = 9, desc = 'Grants extra magical damage through leopard power infusion.' },
    { name = 'Elbow Strike', level = 5, timer = 9, desc = 'Strikes your opponent with an elbow, dealing 5 damage.' },
    { name = 'Throw Stone', level = 1, timer = 9, desc = 'Strikes your target with a thrown stone, causing 1 damage.' },

    -- Timer 10 - Block/Riposte Enhancement
    { name = 'Reflex', level = 98, timer = 10, desc = 'Increases block chance by 60% for 12 seconds, followed by mitigation decrease via Reflex Recourse fade effect.' },
    { name = 'Intercepting Fist', level = 90, timer = 10, desc = 'Boosts riposte chance by 75% with subsequent mitigation penalty.' },
    { name = 'Flinch', level = 85, timer = 10, desc = 'Raises block chance by 45% followed by 45% mitigation reduction.' },

    -- Timer 11 - Attack Speed
    { name = 'Speed Focus Discipline', level = 63, timer = 11, desc = 'Decreases weapon delay by 56.3%.' },

    -- Timer 12 - Fist Flurries/Patterns
    { name = 'Flurry of Fists', level = 125, timer = 12, desc = 'Three successive Tiger Claw attacks of 760 base damage.' },
    { name = 'Buffeting of Fists', level = 120, timer = 12, desc = 'Three successive Tiger Claw attacks of 658 base damage.' },
    { name = 'Perforate', level = 119, timer = 12, desc = 'Increase Chance to Hit by 10000% with max 62 hit attempts.' },
    { name = 'Barrage of Fists', level = 115, timer = 12, desc = 'Three successive Tiger Claw attacks of 569 base damage.' },
    { name = 'Firestorm of Fists', level = 110, timer = 12, desc = 'Three successive Tiger Claw attacks of 516 base damage.' },
    { name = 'Strike Through', level = 104, timer = 12, desc = 'Increase Chance to Hit by 10000% with max 53 hit attempts.' },
    { name = 'Torrent of Fists', level = 104, timer = 12, desc = 'Three successive tiger claw punches at 487 base damage.' },
    { name = 'Eight-Step Pattern', level = 99, timer = 12, desc = 'Three successive Eagle Strike attacks at 822 base damage.' },
    { name = 'Seven-Step Pattern', level = 94, timer = 12, desc = 'Three successive tiger claw punches at 678 base damage.' },
    { name = 'Veiled Body', level = 94, timer = 12, desc = 'Increase Chance to Dodge by 58%.' },
    { name = 'Jab Through', level = 89, timer = 12, desc = 'Increase Chance to Hit by 10000% with max 40 hit attempts.' },
    { name = 'Six-Step Pattern', level = 89, timer = 12, desc = 'Three successive tiger claw punches at 556 base damage.' },
    { name = 'Void Body', level = 89, timer = 12, desc = 'Increase Chance to Dodge by 46%.' },
    { name = 'Punch Through', level = 84, timer = 12, desc = 'Increase Chance to Hit by 10000% with max 35 hit attempts.' },
    { name = 'Whorl of Fists', level = 84, timer = 12, desc = 'Three successive tiger claw punches at 432 base damage.' },
    { name = 'Wheel of Fists', level = 79, timer = 12, desc = 'Three successive tiger claw punches at 351 base damage.' },
    { name = 'Clawstriker\'s Flurry', level = 74, timer = 12, desc = 'Three successive tiger claw punches at 288 base damage.' },

    -- Timer 13 - Endurance Recovery
    { name = 'Hiatus V', level = 126, timer = 13, desc = 'You rest your arms, slowing melee attacks by 1000% for 48 seconds. Adds 27719 endurance to your pool every six seconds until you reach 30% of your maximum or 491000 total, whichever is lower.' },
    { name = 'Convalesce', level = 121, timer = 13, desc = 'Restores 12893 endurance per tick (capped at 30% or 270000) while reducing attack speed by 1000%.' },
    { name = 'Night\'s Calming', level = 116, timer = 13, desc = 'Generates 11137 endurance per tick (capped at 30% or 163000) with 1000% weapon delay increase.' },
    { name = 'Relax', level = 111, timer = 13, desc = 'Adds 9621 endurance per tick (capped at 30% or 118000) while slowing attacks 1000%.' },
    { name = 'Hiatus', level = 106, timer = 13, desc = 'Restores 8640 endurance per tick (capped at 30% or 92500) with 1000% attack slowdown.' },
    { name = 'Breather', level = 101, timer = 13, desc = 'Restores endurance only when reserves fall below 21%, starting at 3812 per tick, decaying to 1268.' },
    { name = 'Seventh Wind', level = 97, timer = 13, desc = 'Provides 498 endurance restoration per tick for 2 minutes.' },
    { name = 'Rest', level = 96, timer = 13, desc = 'Adds 1546 endurance per tick when endurance is below 21%.' },
    { name = 'Sixth Wind', level = 92, timer = 13, desc = 'Grants 410 endurance per tick over 2 minutes.' },
    { name = 'Reprieve', level = 91, timer = 13, desc = 'Activates endurance restoration when below 21% maximum at 1274 per tick.' },
    { name = 'Fifth Wind', level = 87, timer = 13, desc = 'Delivers 268 endurance per tick for 2 minutes.' },
    { name = 'Respite', level = 86, timer = 13, desc = 'Restores 845 endurance per tick when reserves drop below 21% maximum.' },
    { name = 'Fourth Wind', level = 82, timer = 13, desc = 'Generates 196 endurance per tick across 2 minutes.' },
    { name = 'Third Wind', level = 77, timer = 13, desc = 'Restores 161 endurance per tick over 2 minutes.' },
    { name = 'Second Wind', level = 72, timer = 13, desc = 'Provides 144 endurance per tick for 2 minutes every 6 seconds.' },

    -- Timer 14 - Stance/Healing
    { name = 'Heron Stance', level = 112, timer = 14, desc = 'A risky stance that will result in two very strong Flying Kick attacks of 6702 base damage each.' },
    { name = 'Inner Rejuvenation', level = 93, timer = 14, desc = 'Allows you to heal yourself for up to 29000 or 35% of your life, whichever is lower. This can only occur when you are at peace.' },
    { name = 'Crane Stance', level = 93, timer = 14, desc = 'A risky stance that will generate two very strong flying kicks.' },

    -- Timer 16 - Balance/Symmetry Disciplines
    { name = 'Eagle\'s Symmetry', level = 127, timer = 16, desc = 'Add Melee Proc: Eagle\'s Symmetry Strike with 500% Rate Mod and reduce damage shield damage by 38059.' },
    { name = 'Tiger\'s Symmetry', level = 122, timer = 16, desc = 'Add Melee Proc: Tiger\'s Symmetry Strike with 500% Rate Mod and reduce damage shield damage by 761.' },
    { name = 'Dragon\'s Poise', level = 117, timer = 16, desc = 'Add Melee Proc: Dragon\'s Poised Strike with 500% Rate Mod and reduce damage shield damage by 628.' },
    { name = 'Eagle\'s Poise', level = 112, timer = 16, desc = 'Add Melee Proc: Eagle\'s Poised Strike with 500% Rate Mod and reduce damage shield damage by 518.' },
    { name = 'Tiger\'s Poise', level = 107, timer = 16, desc = 'Triggers extra Tiger Claw attacks through melee procs at 500% rate.' },
    { name = 'Dragon\'s Balance', level = 102, timer = 16, desc = 'Activates balanced dragon stance that adds extra attacks when striking.' },
    { name = 'Eagle\'s Balance', level = 97, timer = 16, desc = 'Activates balanced eagle stance that adds extra attacks when striking.' },
    { name = 'Tiger\'s Balance', level = 92, timer = 16, desc = 'Activates balanced tiger stance that adds extra attacks when striking.' },

    -- Timer 17 - Phantom/Fang Abilities
    { name = 'Phantom Afterimage', level = 125, timer = 17, desc = 'Your hands blur and merge with other threads of reality, creating 1 phantasmal attacker that strikes with fists and Phantom Kick VI Azia.' },
    { name = 'Uncia\'s Fang', level = 124, timer = 17, desc = 'Dragon-infused strike combining hand-to-hand attack (base 1648) with magical damage (base 22020). Generates 828 hate.' },
    { name = 'Phantom Fisticuffs', level = 115, timer = 17, desc = 'Your hands blur and merge with other threads of reality, creating 1 phantasmal attacker that strikes with fists and Phantom Kick V Azia.' },
    { name = 'Zlexak\'s Fang', level = 114, timer = 17, desc = 'Dragon-infused strike combining hand-to-hand attack (base 1145) with magical damage (base 14579). Generates 683 hate.' },
    { name = 'Hoshkar\'s Fang', level = 109, timer = 17, desc = 'Dragon-infused strike combining hand-to-hand attack (base 1037) with magical damage (base 12022). Generates 653 hate.' },
    { name = 'Phantom Pummeling', level = 105, timer = 17, desc = 'Your hands blur and merge with other threads of reality, pummeling your opponent multiple times.' },
    { name = 'Phantom Partisan', level = 100, timer = 17, desc = 'Your hands blur and merge with other threads of reality, pummeling your opponent multiple times.' },
    { name = 'Zalikor\'s Fang', level = 99, timer = 17, desc = 'Dragon-infused strike combining physical and magical attacks (hand-to-hand base 932, magical base 9913). Generates 622 hate.' },
    { name = 'Cloud of Fists', level = 87, timer = 17, desc = 'Your hands blur, pummeling your opponent with seemingly endless fists.' },

    -- Timer 18 - Dodge/Reflexes
    { name = 'Disciplined Reflexes', level = 117, timer = 18, desc = 'Quickens your reflexes, allowing you to block 3 attacks if you are struck by a melee strike dealing 25000 damage or more.' },
    { name = 'Eye of the Storm', level = 98, timer = 18, desc = 'Adds 340 damage bonus plus 45% damage boost and 160% minimum damage increase.' },
    { name = 'Shaded Step', level = 97, timer = 18, desc = 'Increases dodge chance by 636 points.' },
    { name = 'Void Step', level = 92, timer = 18, desc = 'Boosts dodge chance by 524 points.' },

    -- Timer 19 - Projection
    { name = 'Chrono Projection', level = 82, timer = 19, desc = 'Eye of Zomm - Separates consciousness from physical body to scout dangerous areas undetected through meditation.' },
    { name = 'Astral Projection', level = 77, timer = 19, desc = 'Eye of Zomm - Consciousness detaches via meditation to allow undetected exploration of hazardous locations.' },

    -- Timer 20 - Form Disciplines
    { name = 'Reciprocal Form', level = 121, timer = 20, desc = 'Activates the highest rank you know of Reciprocal Form Trigger 1.' },
    { name = 'Ecliptic Form', level = 116, timer = 20, desc = 'Activates the highest rank you know of Ecliptic Form Trigger 1.' },
    { name = 'Composite Form', level = 111, timer = 20, desc = 'Activates the highest rank you know of Composite Form Trigger 1.' },
    { name = 'Dissident Form', level = 106, timer = 20, desc = 'Activates the highest rank you know of Dissident Form Trigger 1.' },
    { name = 'Dichotomic Form', level = 101, timer = 20, desc = 'Stand in dual realities to boost melee damage across all attack types.' },

    -- Breath Disciplines (Quick Restoration) - Timer 5
    { name = 'Moment of Stillness', level = 123, timer = 5, desc = 'Instantly restores 23236 endurance.' },
    { name = 'Breath of Stillness', level = 118, timer = 5, desc = 'Immediately restores 19160 endurance.' },
    { name = 'Breath of Tranquility', level = 113, timer = 5, desc = 'Quickly restores 15799 endurance.' },
    { name = 'Nine Breaths', level = 108, timer = 5, desc = 'Immediately restores 14189 endurance.' },
    { name = 'Eight Breaths', level = 105, timer = 5, desc = 'Quickly refreshes 12277 endurance.' },
    { name = 'Seven Breaths', level = 100, timer = 5, desc = 'Restores 10865 endurance.' },
    { name = 'Six Breaths', level = 95, timer = 5, desc = 'Refreshes 8547 endurance.' },
    { name = 'Five Breaths', level = 90, timer = 5, desc = 'Restores 6193 endurance.' },
    { name = 'Moment of Placidity', level = 85, timer = 5, desc = 'Refreshes 4895 endurance.' },
    { name = 'Moment of Tranquility', level = 80, timer = 5, desc = 'Triggers endurance restoration on duration fade with combat cancellation.' },
    { name = 'Moment of Calm', level = 75, timer = 5, desc = 'Restores endurance upon duration fade with combat cancellation.' },
}

local defs = {}
for _, d in ipairs(DISCS) do
    table.insert(defs, discDef(d))
end

return { disciplines = defs }
