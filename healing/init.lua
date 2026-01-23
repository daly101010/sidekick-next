-- healing/init.lua (full implementation)
local mq = require('mq')

-- Debug logging to file (using centralized Paths)
local _Paths = nil
local function getPaths()
    if not _Paths then
        local ok, p = pcall(require, 'sidekick-next.utils.paths')
        if ok then _Paths = p end
    end
    return _Paths
end

local function debugLog(fmt, ...)
    local msg = string.format(fmt, ...)
    local Paths = getPaths()
    local logPath = Paths and Paths.getLogPath('debug') or (mq.configDir .. '/SideKick_HealDebug.log')
    local f = io.open(logPath, 'a')
    if f then
        f:write(string.format('[%s] [Heal] %s\n', os.date('%H:%M:%S'), msg))
        f:close()
    end
end

local Config = require('sidekick-next.healing.config')
local HealTracker = require('sidekick-next.healing.heal_tracker')
local TargetMonitor = require('sidekick-next.healing.target_monitor')
local IncomingHeals = require('sidekick-next.healing.incoming_heals')
local CombatAssessor = require('sidekick-next.healing.combat_assessor')
local HealSelector = require('sidekick-next.healing.heal_selector')
local Analytics = require('sidekick-next.healing.analytics')
local SpellEvents = require('sidekick-next.healing.spell_events')
local Logger = require('sidekick-next.healing.logger')

-- Lazy-load UI modules
local Monitor = nil
local function getMonitor()
    if Monitor == nil then
        local ok, m = pcall(require, 'sidekick-next.healing.ui.monitor')
        Monitor = ok and m or false
    end
    return Monitor or nil
end

local Settings = nil
local function getSettings()
    if Settings == nil then
        local ok, s = pcall(require, 'sidekick-next.healing.ui.settings')
        Settings = ok and s or false
    end
    return Settings or nil
end

-- Lazy-load Proactive module (may not exist yet)
local Proactive = nil
local function getProactive()
    if Proactive == nil then
        local ok, p = pcall(require, 'sidekick-next.healing.proactive')
        Proactive = ok and p or false
    end
    return Proactive or nil
end

-- Lazy-load HotAnalyzer (HoT trust calculations)
local HotAnalyzer = nil
local function getHotAnalyzer()
    if HotAnalyzer == nil then
        local ok, ha = pcall(require, 'sidekick-next.healing.hot_analyzer')
        HotAnalyzer = ok and ha or false
    end
    return HotAnalyzer or nil
end

-- Lazy-load MobAssessor (named mob detection and consider-based tier assessment)
local MobAssessor = nil
local function getMobAssessor()
    if MobAssessor == nil then
        local ok, ma = pcall(require, 'sidekick-next.healing.mob_assessor')
        if ok and ma then
            MobAssessor = ma
            ma.init()
        else
            MobAssessor = false
        end
    end
    return MobAssessor or nil
end

local M = {}

local _initialized = false
local _lastHealAttempt = 0
local _priorityActive = false
local ActorsCoordinator = nil

-- Lazy-load DamageParser (optional dual-source DPS tracking)
local DamageParser = nil
local function getDamageParser()
    if DamageParser == nil then
        local ok, dp = pcall(require, 'sidekick-next.healing.damage_parser')
        if ok and dp then
            DamageParser = dp
            dp.init(Config)
        else
            DamageParser = false  -- Mark as unavailable
        end
    end
    return DamageParser or nil
end

-- Lazy-load DamageAttribution (mob-specific damage attribution)
local DamageAttribution = nil
local function getDamageAttribution()
    if DamageAttribution == nil then
        local ok, da = pcall(require, 'sidekick-next.healing.damage_attribution')
        if ok and da then
            DamageAttribution = da
            da.init(Config)
            da.registerEvents()
        else
            DamageAttribution = false  -- Mark as unavailable
        end
    end
    return DamageAttribution or nil
end

-- Check if we're a healing class
local function isHealerClass()
    local me = mq.TLO.Me
    if not me or not me() then return false end
    local classShort = me.Class and me.Class.ShortName and me.Class.ShortName() or ''
    classShort = classShort:upper()
    return classShort == 'CLR'  -- Only CLR for now
end

-- Check if we can heal right now
local function canHealNow()
    local me = mq.TLO.Me
    if not me or not me() then
        debugLog('[CanHealNow] FAIL: no me')
        return false
    end

    -- Dead or hovering
    if me.Hovering and me.Hovering() then
        debugLog('[CanHealNow] FAIL: hovering')
        return false
    end

    -- Already casting (Casting() returns spell name string, empty if not casting)
    local casting = me.Casting and me.Casting() or ''
    if casting ~= '' then
        debugLog('[CanHealNow] FAIL: casting spell=%s', casting)
        return false
    end

    -- Moving
    if me.Moving and me.Moving() then
        debugLog('[CanHealNow] FAIL: moving')
        return false
    end

    -- Check spell engine busy
    local ok, SpellEngine = pcall(require, 'sidekick-next.utils.spell_engine')
    if ok and SpellEngine and SpellEngine.isBusy and SpellEngine.isBusy() then
        debugLog('[CanHealNow] FAIL: spell engine busy')
        return false
    end

    debugLog('[CanHealNow] PASS: can heal now')
    return true
end

-- Check if we should duck the current cast
local function shouldDuck(castInfo)
    if not Config or not Config.duckEnabled then return false end
    if not castInfo then return false end

    local target = TargetMonitor.getTarget(castInfo.targetId)
    if not target then return false end

    local threshold
    if castInfo.tier == 'emergency' then
        threshold = (Config and Config.duckEmergencyThreshold ~= nil) and Config.duckEmergencyThreshold or 70
    elseif castInfo.isHoT then
        threshold = (Config and Config.duckHotThreshold ~= nil) and Config.duckHotThreshold or 92
    else
        threshold = (Config and Config.duckHpThreshold ~= nil) and Config.duckHpThreshold or 85
    end

    local buffer = (Config and Config.duckBufferPct ~= nil) and Config.duckBufferPct or 0.5
    local thresholdWithBuffer = threshold + buffer

    if target.pctHP >= thresholdWithBuffer then
        return true, 'target_full', thresholdWithBuffer
    end

    if Config.considerIncomingHot and target.effectiveDeficit <= 0 then
        return true, 'incoming_covers', thresholdWithBuffer
    end

    return false, nil, thresholdWithBuffer
end

-- Execute a heal
local function executeHeal(spellName, targetId, tier, isHoT)
    local spell = mq.TLO.Spell(spellName)
    if not spell or not spell() then return false end

    local me = mq.TLO.Me
    ---@diagnostic disable-next-line: undefined-field
    local mySpell = me and me() and me.Spell and me.Spell(spellName)
    local castTimeMs = mySpell and tonumber(mySpell.MyCastTime()) or tonumber(spell.CastTime()) or 2000
    local manaCost = tonumber(spell.Mana()) or 0
    local expected = HealTracker.getExpected(spellName)

    -- Get target name for logging
    local targetName = 'Unknown'
    local targetInfo = TargetMonitor.getTarget(targetId)
    if targetInfo and targetInfo.name then
        targetName = targetInfo.name
    else
        -- Fallback to spawn lookup
        local ok, spawn = pcall(function() return mq.TLO.Spawn(targetId) end)
        if ok and spawn and spawn() and spawn.CleanName then
            targetName = spawn.CleanName() or 'Unknown'
        end
    end

    -- Set cast info for ducking (before cast attempt)
    local startTime = mq.gettime()
    SpellEvents.setCastInfo({
        spellName = spellName,
        targetId = targetId,
        targetName = targetName,
        tier = tier,
        isHoT = isHoT,
        manaCost = manaCost,
        startTime = startTime,  -- Use mq.gettime() for wall-clock accuracy
        expectedEnd = startTime + castTimeMs + 1000,
    })

    -- Use SpellEngine if available
    local ok, SpellEngine = pcall(require, 'sidekick-next.utils.spell_engine')
    local success = false

    if ok and SpellEngine and SpellEngine.cast then
        success = SpellEngine.cast(spellName, targetId, { spellCategory = 'heal' })
    else
        -- Fallback to direct command
        mq.cmdf('/cast "%s"', spellName)
        success = true  -- Assume success for direct command
    end

    -- IMPORTANT: Only register incoming heal AFTER cast was accepted
    if success then
        local castSec = castTimeMs / 1000
        local hotTickAmount = nil
        local hotDuration = nil

        if isHoT then
            hotTickAmount = HealTracker.getExpected(spellName, 'tick')
            if hotTickAmount <= 0 then
                ---@diagnostic disable-next-line: undefined-field
                local calcVal = tonumber(spell.Calc and spell.Calc(1) and spell.Calc(1)()) or 0
                if calcVal > 0 then
                    hotTickAmount = math.abs(calcVal)
                end
            end
            if spell.Duration and spell.Duration.TotalSeconds then
                hotDuration = tonumber(spell.Duration.TotalSeconds()) or 0
            end
        end

        IncomingHeals.registerMyCast(targetId, spellName, expected, castSec, isHoT, hotTickAmount, hotDuration)
        M.broadcastIncoming(targetId, spellName, expected, mq.gettime() + castTimeMs, isHoT)

        -- Track HoT presence for proactive logic + peers
        if isHoT then
            local proactive = getProactive()
            if proactive and proactive.recordHoT then
                proactive.recordHoT(targetName, spellName, hotDuration or 18)
            end
            if SpellEvents and SpellEvents.registerHotCast then
                SpellEvents.registerHotCast(targetName, spellName, hotTickAmount, hotDuration, mq.gettime())
            end
            if ActorsCoordinator and ActorsCoordinator.broadcast and Config and Config.broadcastEnabled then
                local exp = mq.gettime() + castTimeMs + ((hotDuration or 18) * 1000)
                ActorsCoordinator.broadcast('heal:hots', {
                    targetId = targetId,
                    spellName = spellName,
                    expiresAt = exp,
                })
            end
        end

        -- Track promised heals
        local subcat = tostring(spell.Subcategory and spell.Subcategory() or ''):lower()
        if subcat == 'delayed' then
            local proactive = getProactive()
            if proactive and proactive.recordPromised then
                local promisedDelay = (Config and Config.promisedDelaySeconds) or 18
                local duration = 0
                if spell.Duration and spell.Duration.TotalSeconds then
                    duration = tonumber(spell.Duration.TotalSeconds()) or 0
                end
                proactive.recordPromised(targetName, spellName, duration, expected, promisedDelay)
            end
        end

        -- Record for UI display
        HealSelector.recordLastAction(spellName, targetName, expected)
    else
        -- Cast failed, clear cast info
        SpellEvents.setCastInfo(nil)
    end

    return success
end

-- Main duck monitoring during cast
local function monitorDuck()
    local castInfo = SpellEvents.getCastInfo()
    if not castInfo then return end

    local me = mq.TLO.Me
    local currentlyCasting = me and me() and me.Casting and (me.Casting() or '') ~= ''
    if not currentlyCasting then
        -- Cast ended naturally - DON'T clear cast info here!
        -- Let the heal event (onHealLanded) clear it so analytics can record properly.
        -- Add a short timeout (2s) to clear stale cast info if heal event doesn't fire.
        local now = mq.gettime()
        local castStart = castInfo.startTime or now
        local expectedEnd = castInfo.expectedEnd or (castStart + 2.5)
        local staleTimeout = 2.0  -- Wait 2 seconds after expected end before clearing
        if now > (expectedEnd + staleTimeout) then
            -- Stale cast info - heal event probably didn't fire, clear it
            SpellEvents.setCastInfo(nil)
        end
        return
    end

    local duck, reason, threshold = shouldDuck(castInfo)
    if duck then
        -- Log duck decision with details
        local targetInfo = TargetMonitor.getTarget(castInfo.targetId)
        local details = string.format('targetHP=%d%% incoming=%d threshold=%d',
            targetInfo and targetInfo.pctHP or 0,
            targetInfo and targetInfo.incomingTotal or 0,
            threshold or ((Config and Config.duckHpThreshold ~= nil) and Config.duckHpThreshold or 85))
        Logger.logDuckDecision(castInfo.spellName, castInfo.targetName or '?', reason, details)

        mq.cmd('/stopcast')

        -- IMPORTANT: Clear SpellEngine busy state to allow new casts
        local ok, SpellEngine = pcall(require, 'sidekick-next.utils.spell_engine')
        if ok and SpellEngine and SpellEngine.abort then
            SpellEngine.abort()
        end

        IncomingHeals.unregisterMyCast(castInfo.targetId)
        Analytics.recordDuck(castInfo.spellName, castInfo.manaCost)
        SpellEvents.setCastInfo(nil)

        -- Broadcast cancellation to other healers
        M.broadcastCancelled(castInfo.targetId, castInfo.spellName, reason)

        Logger.info('ducking', 'Ducked %s - %s', castInfo.spellName, reason)
    end
end

function M.init()
    if _initialized then return end

    local ok, err = pcall(function()
        Config.load()
        Config.autoAssignFromSpellBar()  -- Re-scan spell bar to update spell categories
        Logger.init(Config)  -- Initialize logging first for troubleshooting
        HealTracker.init(Config)
        TargetMonitor.init(Config)
        IncomingHeals.init(Config, TargetMonitor)
        CombatAssessor.init(Config, TargetMonitor)
        HealSelector.init(Config, HealTracker, TargetMonitor, IncomingHeals, CombatAssessor)
        Analytics.init()
        SpellEvents.init(HealTracker, IncomingHeals, Analytics, Config)

        -- Set broadcast callbacks for SpellEvents (avoids circular require)
        SpellEvents.setBroadcastCallbacks(
            function(targetId, spellName) M.broadcastLanded(targetId, spellName) end,
            function(targetId, spellName, reason) M.broadcastCancelled(targetId, spellName, reason) end
        )

        -- Initialize Proactive if available
        local proactive = getProactive()
        if proactive and proactive.init then
            proactive.init(Config, HealTracker, TargetMonitor, CombatAssessor)
        end

        -- Initialize HotAnalyzer
        local ha = getHotAnalyzer()
        if ha and ha.init then
            ha.init(Config, HealTracker, CombatAssessor, proactive)
        end

        -- Initialize DamageParser early (registers damage events)
        getDamageParser()

        -- Initialize DamageAttribution (registers damage events for mob attribution)
        getDamageAttribution()

        -- Load ActorsCoordinator for multi-healer coordination
        local acOk, ac = pcall(require, 'sidekick-next.utils.actors_coordinator')
        if acOk and ac then
            ActorsCoordinator = ac
            -- Register callbacks to receive heal coordination messages (avoids circular require)
            if ac.registerHealingCallback then
                ac.registerHealingCallback('heal:incoming', function(content, senderName)
                    M.handleActorMessage('heal:incoming', content, senderName)
                end)
                ac.registerHealingCallback('heal:landed', function(content, senderName)
                    M.handleActorMessage('heal:landed', content, senderName)
                end)
                ac.registerHealingCallback('heal:cancelled', function(content, senderName)
                    M.handleActorMessage('heal:cancelled', content, senderName)
                end)
            end
        end

        -- Initialize MobAssessor for named mob detection
        getMobAssessor()

        -- Initialize UI modules if available
        local monitor = getMonitor()
        if monitor and monitor.init then
            local mobAssessor = getMobAssessor()
            monitor.init(Config, TargetMonitor, IncomingHeals, CombatAssessor, Analytics, HealTracker, HealSelector, mobAssessor)
        end

        local settings = getSettings()
        if settings and settings.init then
            settings.init(Config)
            -- Wire up the toggle monitor callback
            if settings.setToggleMonitorCallback then
                settings.setToggleMonitorCallback(function()
                    local mon = getMonitor()
                    if mon and mon.toggle then mon.toggle() end
                end)
            end
        end
    end)

    if not ok then
        Logger.error('session', 'Init error: %s', tostring(err))
        return
    end

    _initialized = true
    Logger.info('session', 'Healing Intelligence initialized - fileLogging=%s', tostring(Config.fileLogging))
end

function M.tick(settings)
    -- DEBUG: Track which module stalls (logs to file)
    local _tickDbg = true
    local function tickLog(msg)
        if _tickDbg then debugLog('[HealTick] %s', msg) end
    end

    -- Update all modules
    tickLog('1-TargetMonitor')
    TargetMonitor.tick()
    tickLog('2-IncomingHeals')
    IncomingHeals.tick()
    tickLog('3-CombatAssessor')
    CombatAssessor.tick()
    tickLog('4-SpellEvents')
    SpellEvents.tick()
    tickLog('5-HealTracker')
    HealTracker.tick()

    tickLog('6-Proactive')
    local proactive = getProactive()
    if proactive and proactive.tick then
        proactive.tick()
    end

    -- Update DamageParser for dual-source DPS tracking
    tickLog('7-DamageParser')
    local dp = getDamageParser()
    if dp and dp.tick then dp.tick() end

    -- Update DamageAttribution for mob-specific damage tracking
    tickLog('8-DamageAttribution')
    local da = getDamageAttribution()
    if da and da.tick then da.tick() end

    -- Update MobAssessor for named mob scanning (runs when safe/idle)
    tickLog('9-MobAssessor')
    local ma = getMobAssessor()
    if ma and ma.tick then ma.tick() end
    tickLog('10-MobAssessor done')

    -- Check if healing is enabled (Config.enabled is the single source of truth)
    tickLog('11-CheckEnabled')
    if Config.enabled == false then
        _priorityActive = false
        return false
    end

    -- Check if we're a healer class
    tickLog('12-CheckHealerClass')
    if not isHealerClass() then
        _priorityActive = false
        return false
    end

    -- Monitor for ducking during cast
    tickLog('13-CheckCasting')
    if SpellEvents.isCasting() then
        monitorDuck()
        _priorityActive = true
        return true
    end

    -- Throttle heal attempts (use mq.gettime() for wall-clock accuracy)
    local now = mq.gettime()
    if (now - _lastHealAttempt) < 0.1 then
        return _priorityActive
    end
    _lastHealAttempt = now

    -- Can we heal?
    tickLog('14-CanHealNow')
    if not canHealNow() then
        return _priorityActive
    end
    tickLog('15-PastCanHealNow')

    local function cloneTarget(t)
        local out = {}
        for k, v in pairs(t) do out[k] = v end
        return out
    end

    local allTargets = {}
    local priorityTargets = {}
    local groupTargets = {}

    local targets = TargetMonitor.getAllTargets() or {}
    tickLog(string.format('16-Targets count=%d', #targets))
    for _, t in pairs(targets) do
        if Config.healPetsEnabled or t.role ~= 'pet' then
            local entry = cloneTarget(t)
            local incomingTotal = IncomingHeals.sumForTarget(entry.id)
            entry.incomingTotal = incomingTotal
            entry.deficit = math.max(0, (entry.deficit or 0) - incomingTotal)
            entry.effectiveDeficit = entry.deficit
            if proactive and proactive.getIncomingHotRemaining then
                entry.incomingHotRemaining = proactive.getIncomingHotRemaining(entry.name or entry.id)
            end
            table.insert(allTargets, entry)
            if entry.role == 'tank' then
                table.insert(priorityTargets, entry)
            else
                table.insert(groupTargets, entry)
            end
        end
    end

    table.sort(allTargets, function(a, b)
        local pa = TargetMonitor.getPriority(a) or 99
        local pb = TargetMonitor.getPriority(b) or 99
        if pa ~= pb then return pa < pb end
        return (a.pctHP or 100) < (b.pctHP or 100)
    end)

    local situation = {
        hasEmergency = false,
        multipleHurt = 0,
    }

    for _, t in ipairs(allTargets) do
        if (t.pctHP or 100) < (Config.emergencyPct or 25) then
            situation.hasEmergency = true
        end
        if (t.deficit or 0) > 0 then
            situation.multipleHurt = situation.multipleHurt + 1
        end
    end
    situation.multipleHurt = situation.multipleHurt > 1

    local combatState = CombatAssessor and CombatAssessor.getState and CombatAssessor.getState() or {}
    local activeMobs = math.max(0, (combatState.activeMobCount or 0) - (combatState.mezzedMobCount or 0))
    local maxLowMobs = Config.lowPressureMobCount or 1
    situation.lowPressure = (not situation.hasEmergency) and (not situation.multipleHurt) and (activeMobs <= maxLowMobs)
    situation.combatAssessment = combatState
    situation.survivalMode = combatState.survivalMode == true
    situation.fightPhase = combatState.fightPhase or 'none'
    situation.estimatedFightDuration = combatState.estimatedTTK or 0

    -- Raid/named fight detection
    situation.hasRaidMob = combatState.hasRaidMob == true
    situation.hasNamedMob = combatState.hasNamedMob == true
    situation.mobDpsMultiplier = combatState.mobDpsMultiplier or 1.0
    situation.raidFight = situation.hasRaidMob or (situation.hasNamedMob and situation.mobDpsMultiplier >= 2.0)

    -- Log situation summary
    local hurtCount = 0
    local lowestHp = 100
    for _, t in ipairs(allTargets) do
        if (t.deficit or 0) > 0 then hurtCount = hurtCount + 1 end
        if (t.pctHP or 100) < lowestHp then lowestHp = t.pctHP or 100 end
    end
    tickLog(string.format('17-Situation: targets=%d hurt=%d lowestHP=%d emergency=%s',
        #allTargets, hurtCount, lowestHp, tostring(situation.hasEmergency)))

    -- Priority 1: emergency
    tickLog('18-CheckEmergency')
    for _, t in ipairs(allTargets) do
        if (t.pctHP or 100) < (Config.emergencyPct or 25) then
            tickLog(string.format('19-EmergencyTarget: %s HP=%d', tostring(t.name), t.pctHP or 0))
            local heal, reason = HealSelector.SelectHeal(t, situation)
            tickLog(string.format('20-EmergencyHeal: spell=%s reason=%s', tostring(heal and heal.spell), tostring(reason)))
            if heal then
                local spellInfo = mq.TLO.Spell(heal.spell)
                local isHoT = false
                if spellInfo and spellInfo() and spellInfo.HasSPA then
                    local okSpa, vSpa = pcall(function() return spellInfo.HasSPA(79)() end)
                    isHoT = okSpa and vSpa == true
                end
                if executeHeal(heal.spell, t.id, 'emergency', isHoT) then
                    _priorityActive = true
                    return true
                end
            end
        end
    end

    -- Priority 2: group heal
    local useGroup, groupHeal = HealSelector.ShouldUseGroupHeal(allTargets)
    if useGroup and groupHeal then
        local myId = mq.TLO.Me.ID()
        if executeHeal(groupHeal.spell, myId, 'group', false) then
            _priorityActive = true
            return true
        end
    end

    -- Priority 2.5: group HoT
    if proactive and proactive.ShouldApplyGroupHot then
        local useGroupHot, groupHot, totalDeficit, hurtCount = proactive.ShouldApplyGroupHot(allTargets, situation)
        if useGroupHot and groupHot then
            local myId = mq.TLO.Me.ID()
            if executeHeal(groupHot.spell, myId, 'groupHot', true) then
                if SpellEvents and SpellEvents.registerGroupHotCast then
                    local targetNames = {}
                    for _, t in ipairs(allTargets) do
                        if (t.deficit or 0) > 0 then
                            table.insert(targetNames, t.name)
                        end
                    end
                    local spell = mq.TLO.Spell(groupHot.spell)
                    local duration = 0
                    if spell and spell() and spell.Duration and spell.Duration.TotalSeconds then
                        duration = tonumber(spell.Duration.TotalSeconds()) or 0
                    end
                    SpellEvents.registerGroupHotCast(targetNames, groupHot.spell, groupHot.expected or 0, duration, mq.gettime())
                end
                _priorityActive = true
                return true
            end
        end
    end

    local function tryHealList(list)
        for _, t in ipairs(list) do
            if (t.deficit or 0) > 0 then
                tickLog(string.format('21-TryHeal: %s HP=%d deficit=%d', tostring(t.name), t.pctHP or 0, t.deficit or 0))
                local heal, reason = HealSelector.SelectHeal(t, situation)
                tickLog(string.format('22-HealSelected: spell=%s reason=%s', tostring(heal and heal.spell), tostring(reason)))
                if heal then
                    if heal.category == 'hot' and proactive and proactive.HasActiveHot and proactive.HasActiveHot(t.name) then
                        local canRefresh = proactive.ShouldRefreshHot and proactive.ShouldRefreshHot(t.name, Config) or false
                        if not canRefresh then
                            local deficitPct = (t.maxHP and t.maxHP > 0) and (t.deficit / t.maxHP * 100) or 0
                            local fallbackMinPct = Config.minHealPct or 10
                            if not t.isSquishy and Config.nonSquishyMinHealPct then
                                fallbackMinPct = math.max(fallbackMinPct, Config.nonSquishyMinHealPct)
                            end
                            if deficitPct < fallbackMinPct then
                                heal = nil
                            else
                                heal = HealSelector.FindEfficientHeal(t, false, situation)
                            end
                        end
                    end
                end

                if heal then
                    local spellInfo = mq.TLO.Spell(heal.spell)
                    local isHoT = false
                    if spellInfo and spellInfo() and spellInfo.HasSPA then
                        local okSpa, vSpa = pcall(function() return spellInfo.HasSPA(79)() end)
                        isHoT = okSpa and vSpa == true
                    end

                    -- Validate HoT with proactive.shouldApplyHoT before executing
                    if isHoT and proactive and proactive.shouldApplyHoT then
                        local shouldApply, hotReason = proactive.shouldApplyHoT(t, heal.spell)
                        if not shouldApply then
                            -- Log the rejection and skip this HoT
                            Logger.logHotDecision(t.name, heal.spell, false, hotReason)
                            heal = nil  -- Clear to fall through to next target
                        else
                            Logger.logHotDecision(t.name, heal.spell, true, hotReason)
                        end
                    end

                    if heal and executeHeal(heal.spell, t.id, 'priority', isHoT) then
                        _priorityActive = true
                        return true
                    end
                end
            end
        end
        return false
    end

    tickLog('23-TryPriorityTargets')
    if tryHealList(priorityTargets) then return true end
    tickLog('24-TryGroupTargets')
    if tryHealList(groupTargets) then return true end

    tickLog('25-NoHealNeeded')
    _priorityActive = false
    return false
end

function M.tickActors()
    if not ActorsCoordinator then return end
    -- Actor message processing happens via handleActorMessage() which is called
    -- by actors_coordinator when heal:incoming/landed/cancelled messages arrive.
    -- Broadcasts are triggered by executeHeal() and SpellEvents on specific events.
    -- IncomingHeals.prune() handles cleanup and runs in M.tick().
    -- This function is kept for potential future periodic health checks or state sync.
end

function M.isPriorityActive()
    return _priorityActive
end

-- Broadcast functions for multi-healer coordination
function M.broadcastIncoming(targetId, spellName, expectedAmount, landsAt, isHoT)
    if not ActorsCoordinator or not ActorsCoordinator.broadcast then return end
    if not Config.broadcastEnabled then return end

    ActorsCoordinator.broadcast('heal:incoming', {
        targetId = targetId,
        spellName = spellName,
        expectedAmount = expectedAmount,
        landsAt = landsAt,
        isHoT = isHoT,
    })
end

function M.broadcastLanded(targetId, spellName)
    if not ActorsCoordinator or not ActorsCoordinator.broadcast then return end
    if not Config.broadcastEnabled then return end

    ActorsCoordinator.broadcast('heal:landed', {
        targetId = targetId,
        spellName = spellName,
    })
end

function M.broadcastCancelled(targetId, spellName, reason)
    if not ActorsCoordinator or not ActorsCoordinator.broadcast then return end
    if not Config.broadcastEnabled then return end

    ActorsCoordinator.broadcast('heal:cancelled', {
        targetId = targetId,
        spellName = spellName,
        reason = reason,
    })
end

-- Handler for incoming messages from other healers
function M.handleActorMessage(msgType, data, senderId)
    if msgType == 'heal:incoming' then
        IncomingHeals.add(senderId, data.targetId, data)
    elseif msgType == 'heal:landed' then
        IncomingHeals.remove(senderId, data.targetId)
    elseif msgType == 'heal:cancelled' then
        IncomingHeals.remove(senderId, data.targetId)
    end
end

function M.shutdown()
    if not _initialized then return end

    -- Log session summary before shutdown
    Logger.logSessionSummary({
        duration = Analytics.getSessionDuration and Analytics.getSessionDuration() or '?',
        totalCasts = Analytics.getStats and Analytics.getStats().totalCasts or 0,
        totalHealed = Analytics.getStats and Analytics.getStats().totalHealed or 0,
        overHealPct = Analytics.getStats and Analytics.getStats().overHealPct or 0,
        duckedCasts = Analytics.getStats and Analytics.getStats().duckedCasts or 0,
        duckSavings = Analytics.getStats and Analytics.getStats().duckSavingsEstimate or 0,
        incomingHonored = Analytics.getStats and Analytics.getStats().incomingHealHonored or 0,
        incomingExpired = Analytics.getStats and Analytics.getStats().incomingHealExpired or 0,
    })

    -- Log analytics summary before closing logger
    Logger.info('analytics', 'Session summary: %s', Analytics.getSummary())

    HealTracker.shutdown()
    Config.save()

    -- Shutdown MobAssessor (saves any dirty data)
    local ma = getMobAssessor()
    if ma and ma.shutdown then
        ma.shutdown()
    end

    Logger.shutdown()  -- Close log file
    _initialized = false
end

-- UI functions
function M.toggleMonitor()
    local monitor = getMonitor()
    if monitor and monitor.toggle then
        monitor.toggle()
    end
end

function M.drawMonitor()
    local monitor = getMonitor()
    if monitor and monitor.draw then
        monitor.draw()
    end
end

function M.drawSettings()
    local settings = getSettings()
    if settings and settings.draw then
        settings.draw()
    end
end

function M.isMonitorOpen()
    local monitor = getMonitor()
    return monitor and monitor.isOpen and monitor.isOpen() or false
end

-- Expose modules
M.Config = Config
M.HealTracker = HealTracker
M.TargetMonitor = TargetMonitor
M.IncomingHeals = IncomingHeals
M.CombatAssessor = CombatAssessor
M.HealSelector = HealSelector
M.Analytics = Analytics
M.SpellEvents = SpellEvents
M.Logger = Logger

-- UI modules are exposed via getter functions to allow late binding
function M.getMonitor() return getMonitor() end
function M.getSettings() return getSettings() end
function M.getMobAssessor() return getMobAssessor() end

return M
