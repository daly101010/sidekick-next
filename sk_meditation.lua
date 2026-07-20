-- F:/lua/sidekick-next/sk_meditation.lua
-- Meditation module for SideKick multi-script system
-- Priority 7: Lowest priority (sit/stand for resource regeneration)
-- Does not use claim system - just issues /sit and /stand commands

local mq = require('mq')
local actors = require('actors')
local lib = require('sidekick-next.sk_lib')

local M = {}

local debugLog = require('sidekick-next.utils.debug_log').module('sk_meditation', 'SK_MEDITATION')

-- Module identity
-- Keep the actor/coordinator identity distinct from production SideKick's
-- `meditation` worker. Both trees can be installed or running concurrently.
M.MODULE_NAME = 'next_meditation'

-- Internal state
local State = {
    -- State from Coordinator
    coordState = nil,
    stateReceivedAt = 0,

    -- Meditation state
    lastCmdAt = 0,
    lastStateChangeAt = 0,
    lastMoveAt = 0,
    combatEndedAt = 0,
    postCombatJitter = 0,
    wasInCombat = false,
    lastMaxProbeAt = 0,
    hasMana = true,
    hasEndurance = true,

    -- Running flag
    running = true,
    initialized = false,
    warmupUntil = 0,

    -- Need tracking
    lastNeedSentAt = 0,
    lastNeedValue = nil,

    -- Actor dropbox
    dropbox = nil,
    stateDropbox = nil,
}

-- Load settings directly from INI (we run as separate script)
local _settings = nil
local _settingsRevision = nil
local _settingsPath = nil

local function toBool(v, default)
    if v == nil then return default end
    local t = type(v)
    if t == 'boolean' then return v end
    if t == 'number' then return v ~= 0 end
    if t == 'string' then
        v = v:lower()
        return (v == '1' or v == 'true' or v == 'yes' or v == 'on')
    end
    return default or false
end

local function loadSettingsFromIni()
    local settings = {}

    -- Get INI path
    local Paths = nil
    pcall(function() Paths = require('sidekick-next.utils.paths') end)
    if not Paths then return settings end

    local iniPath = Paths.getModuleConfigPath('meditation')
    _settingsPath = iniPath
    local section = {}
    local okAtomic, AtomicIni = pcall(require, 'sidekick-next.utils.atomic_ini')
    if okAtomic and AtomicIni then
        local ini = AtomicIni.load(iniPath)
        section = type(ini) == 'table' and (ini.Settings or {}) or {}
    end

    -- During first-run migration the UI may not have created the module file
    -- yet. Fall back to the combined legacy source without ever writing it.
    if next(section) == nil then
        local okLip, lip = pcall(require, 'LIP')
        if okLip and lip then
            local okLegacy, legacy = pcall(lip.load, Paths.getMainConfigPath())
            if okLegacy and type(legacy) == 'table' then
                section = legacy.SideKick or legacy['SideKick'] or {}
            end
        end
    end

    -- Meditation settings. Prefer the SideKick mode field, but honor legacy
    -- MedOn if present so imported configs cannot report mode_off while the
    -- character was configured to med.
    local legacyMedOn = toBool(section['MedOn'], nil)
    settings.MeditationMode = section['MeditationMode'] or (legacyMedOn == true and 'ooc' or 'inout')
    if tostring(settings.MeditationMode):lower() == 'off' and legacyMedOn == true then
        settings.MeditationMode = 'ooc'
    end
    settings.MeditationHPStartPct = tonumber(section['MeditationHPStartPct']) or 70
    settings.MeditationHPStopPct = tonumber(section['MeditationHPStopPct']) or 95
    settings.MeditationManaStartPct = tonumber(section['MeditationManaStartPct']) or 50
    settings.MeditationManaStopPct = tonumber(section['MeditationManaStopPct']) or 95
    settings.MeditationEndStartPct = tonumber(section['MeditationEndStartPct']) or 60
    settings.MeditationEndStopPct = tonumber(section['MeditationEndStopPct']) or 95
    settings.MeditationStandWhenDone = toBool(section['MeditationStandWhenDone'], true)
    settings.MeditationAggroCheck = toBool(section['MeditationAggroCheck'], true)
    settings.MeditationAggroPct = tonumber(section['MeditationAggroPct']) or 95
    settings.MeditationAfterCombatDelay = tonumber(section['MeditationAfterCombatDelay']) or 2.0
    settings.MeditationMinStateSeconds = tonumber(section['MeditationMinStateSeconds']) or 1.0

    debugLog('loadSettingsFromIni: MeditationMode raw=%s MedOn=%s parsed=%s StandWhenDone raw=%s parsed=%s',
        tostring(section['MeditationMode']), tostring(section['MedOn']), tostring(settings.MeditationMode),
        tostring(section['MeditationStandWhenDone']), tostring(settings.MeditationStandWhenDone))

    return settings
end

local function getSettings()
    local revision = tonumber(State.coordState and State.coordState.settingsRevision) or 0
    if not _settings or revision ~= _settingsRevision then
        _settings = loadSettingsFromIni()
        _settingsRevision = revision
        debugLog('getSettings: Loaded from INI, MeditationMode=%s', tostring(_settings.MeditationMode))
    end
    return _settings
end

-- Build me data directly from TLO (since we run as separate script)
local function getMeData()
    local me = mq.TLO.Me
    if not me or not me() then return nil end

    local data = {}
    pcall(function() data.id = me.ID() end)
    pcall(function() data.hp = me.PctHPs() end)
    pcall(function() data.mana = me.PctMana() end)
    pcall(function() data.endur = me.PctEndurance() end)
    pcall(function() data.sitting = me.Sitting() end)
    pcall(function() data.standing = me.Standing() end)
    pcall(function() data.moving = me.Moving() end)
    pcall(function() data.casting = me.Casting() and me.Casting.ID() and me.Casting.ID() > 0 end)
    pcall(function() data.combat = me.Combat() end)
    pcall(function() data.pctAggro = me.PctAggro() end)

    return data
end

-------------------------------------------------------------------------------
-- Helper Functions
-------------------------------------------------------------------------------

local function safeBool(fn)
    local ok, v = pcall(fn)
    return ok and v == true
end

local function hasValidState()
    if not State.coordState then return false end
    return not lib.isStale(State.coordState.sentAtMs, State.coordState.ttlMs)
end

local function isWarmingUp()
    return lib.getTimeMs() < State.warmupUntil
end

local function normalizeMode(mode)
    mode = tostring(mode or 'off'):lower()
    if mode == 'off' or mode == '0' or mode == 'false' then return 'off' end
    if mode == 'ooc' or mode == 'out' or mode == 'outofcombat' then return 'ooc' end
    if mode == 'in combat' or mode == 'incombat' then return 'inout' end
    if mode == 'inout' or mode == 'in_and_out' or mode == 'inandout' or mode == 'both' or mode == 'always' then return 'inout' end
    return 'inout'
end

local function movementPluginsActive()
    local stickActive = safeBool(function() return mq.TLO.Stick and mq.TLO.Stick.Active and mq.TLO.Stick.Active() end)
    if stickActive then return true end

    local navActive = safeBool(function()
        return (mq.TLO.Nav and mq.TLO.Nav.Active and mq.TLO.Nav.Active())
            or (mq.TLO.Navigation and mq.TLO.Navigation.Active and mq.TLO.Navigation.Active())
    end)
    if navActive then return true end

    local moveToMoving = safeBool(function() return mq.TLO.MoveTo and mq.TLO.MoveTo.Moving and mq.TLO.MoveTo.Moving() end)
    if moveToMoving then return true end

    local advPathActive = safeBool(function() return mq.TLO.AdvPath and mq.TLO.AdvPath.Active and mq.TLO.AdvPath.Active() end)
    if advPathActive then return true end

    return false
end

local function getAggroHolderId()
    local ok, id = pcall(function()
        local holder = mq.TLO.Target and mq.TLO.Target.AggroHolder
        return holder and holder.ID and holder.ID() or 0
    end)
    if ok then return tonumber(id) or 0 end
    return 0
end

local function iHaveAggro(me, settings)
    if settings.MeditationAggroCheck ~= true then return false end
    local thresh = tonumber(settings.MeditationAggroPct) or 95

    me = me or {}
    if (me.pctAggro or 0) >= thresh then return true end

    local myId = me.id or 0
    local holderId = getAggroHolderId()
    if myId > 0 and holderId > 0 and holderId == myId then
        return true
    end

    -- NOTE: We intentionally do NOT check XTarget auto hater slots here.
    -- XTarget 'Auto Hater' means "a mob hating someone in the group" — NOT
    -- "a mob targeting the player."  For a cleric/healer in a group the tank
    -- has aggro, but XTarget still shows auto haters.  Using that check would
    -- block ALL in-combat meditation for every group member.
    --
    -- The pctAggro threshold and AggroHolder checks above are sufficient to
    -- detect personal aggro.

    return false
end

local function updateResourceFlags(now)
    if (now - (State.lastMaxProbeAt or 0)) < 5000 then return end
    State.lastMaxProbeAt = now

    local me = mq.TLO.Me
    if not (me and me()) then return end

    local maxMana = 0
    if me.MaxMana then
        local ok, v = pcall(function() return me.MaxMana() end)
        if ok then maxMana = tonumber(v) or 0 end
    end
    local maxEnd = 0
    if me.MaxEndurance then
        local ok, v = pcall(function() return me.MaxEndurance() end)
        if ok then maxEnd = tonumber(v) or 0 end
    end

    State.hasMana = maxMana > 0
    State.hasEndurance = maxEnd > 0
end

local function shouldSit(me, settings)
    me = me or {}

    local hp = tonumber(me.hp) or 0
    local mana = tonumber(me.mana) or 0
    local endur = tonumber(me.endur) or 0

    local hpStart = tonumber(settings.MeditationHPStartPct) or 70
    local hpStop = tonumber(settings.MeditationHPStopPct) or 95
    local manaStart = tonumber(settings.MeditationManaStartPct) or 50
    local manaStop = tonumber(settings.MeditationManaStopPct) or 95
    local endStart = tonumber(settings.MeditationEndStartPct) or 60
    local endStop = tonumber(settings.MeditationEndStopPct) or 95

    local sitting = me.sitting == true

    local function belowStart()
        if hp < hpStart then return true end
        if State.hasMana and mana < manaStart then return true end
        if State.hasEndurance and endur < endStart then return true end
        return false
    end

    local function aboveStop()
        if hp < hpStop then return false end
        if State.hasMana and mana < manaStop then return false end
        if State.hasEndurance and endur < endStop then return false end
        return true
    end

    if sitting then
        if settings.MeditationStandWhenDone == true then
            if aboveStop() then
                return false, 'above_stop_stand_when_done'
            end
            return true, 'below_stop'
        end
        if belowStart() then return true, 'below_start' end
        if not aboveStop() then return true, 'below_stop' end
        return false, 'above_stop'
    end

    if belowStart() then return true, 'below_start' end
    return false, 'above_start'
end

local function canChangeState(now, settings)
    local minHold = (tonumber(settings.MeditationMinStateSeconds) or 1.0) * 1000
    local minCmd = 500
    if (now - (State.lastCmdAt or 0)) < minCmd then return false end
    if (now - (State.lastStateChangeAt or 0)) < minHold then return false end
    return true
end

local function cmdSit(now)
    mq.cmd('/squelch /sit')
    State.lastCmdAt = now
    State.lastStateChangeAt = now
end

local function cmdStand(now)
    mq.cmd('/squelch /stand')
    State.lastCmdAt = now
    State.lastStateChangeAt = now
end

-------------------------------------------------------------------------------
-- Need Hint Communication
-------------------------------------------------------------------------------

local function sendNeed(needsAction, ttlMs, reason)
    if not State.dropbox then return end
    local now = lib.getTimeMs()
    local value = needsAction == true
    local reasonChanged = reason ~= State.lastNeedReason
    if not reasonChanged and State.lastNeedValue == value and (now - (State.lastNeedSentAt or 0)) < 100 then
        return
    end
    State.lastNeedValue = value
    State.lastNeedSentAt = now
    State.lastNeedReason = reason
    pcall(function()
        State.dropbox:send({ mailbox = lib.Mailbox.NEED, script = lib.Scripts.COORDINATOR }, {
            msgType = 'need',
            module = M.MODULE_NAME,
            ownerName = lib.getMyName(),
            ownerServer = lib.getMyServer(),
            priority = lib.Priority.MEDITATION,
            needsAction = value,
            ttlMs = ttlMs or 500,
            reason = reason,
        })
    end)
end

local function sendHeartbeat()
    if not State.dropbox then return end
    pcall(function()
        State.dropbox:send({ mailbox = lib.Mailbox.HEARTBEAT, script = lib.Scripts.COORDINATOR }, {
            msgType = 'heartbeat',
            module = M.MODULE_NAME,
            ownerName = lib.getMyName(),
            ownerServer = lib.getMyServer(),
            sentAtMs = lib.getTimeMs(),
            ready = true,
        })
    end)
end

-------------------------------------------------------------------------------
-- Coordinator Communication
-------------------------------------------------------------------------------

local function isMyPriority()
    if not hasValidState() then return false end
    return State.coordState.activePriority == lib.Priority.MEDITATION
end

local function isCastOwnerActive()
    if not hasValidState() then return false end
    -- Only block when actively casting (castBusy), not just for having a claim.
    -- A module can hold a cast claim while preparing (gem memorization, targeting)
    -- and we should be able to sit during that prep time.
    return State.coordState.castBusy == true
end

-- Check if we should block meditation due to other activity
-- Block ONLY when someone is actively casting or has a cast claim.
-- We can safely sit between casts regardless of active priority.
-- The casting check and castOwner check already handle "don't sit WHILE
-- casting" individually, but this catches cast claims about to start.
local function shouldBlockForOtherActivity()
    if not hasValidState() then return false end
    -- Block if actively casting
    if State.coordState.castBusy then return true end
    -- Block during active buff casting (buff module holds long TTL claims)
    local ap = State.coordState.activePriority
    if ap == lib.Priority.BUFF and State.coordState.castOwner then
        return true
    end
    -- Allow meditation between casts for all other priorities
    return false
end

local function spellMemorizationActive()
    if hasValidState() then
        local diag = State.coordState.moduleDiag or {}
        local mem = diag.spell_memorize
        if mem and mem.needValid == true and mem.needsAction == true then
            return true, mem.reason or 'spell_memorize'
        end
    end

    local bookOpen = safeBool(function()
        local wnd = mq.TLO.Window and mq.TLO.Window('SpellBookWnd')
        return wnd and wnd.Open and wnd.Open() == true
    end)
    if bookOpen then return true, 'spellbook_open' end

    return false, nil
end

-------------------------------------------------------------------------------
-- Main Tick Logic
-------------------------------------------------------------------------------

local _lastTickLog = 0

local function tick()
    -- Remain loaded through zoning, but do not sit/stand or inspect character
    -- state until MacroQuest reports that the character is fully in game.
    if not lib.isInGame() then
        sendNeed(false, nil, 'not_ingame')
        return
    end

    local paused = State.coordState and State.coordState.automationPaused
    if paused == nil and lib.isAutomationPaused then paused = lib.isAutomationPaused() end
    if paused == true then
        sendNeed(false, nil, 'automation_paused')
        return
    end

    -- Safety: stop if no valid state
    if not hasValidState() then
        sendNeed(false, nil, 'no_state')
        return
    end

    -- Skip during warmup
    if isWarmingUp() then
        return
    end

    local settings = getSettings()
    local mode = normalizeMode(settings.MeditationMode)

    -- Log periodically (every 2 seconds of wall-clock time)
    local now = lib.getTimeMs()
    local shouldLog = (now - _lastTickLog) >= 2000
    if shouldLog then
        _lastTickLog = now
        debugLog('tick: rawMode=%s normalizedMode=%s', tostring(settings.MeditationMode), mode)
    end

    if mode == 'off' then
        if shouldLog then debugLog('tick: mode is off, skipping') end
        sendNeed(false, nil, 'mode_off')
        return
    end

    -- Get character data directly from TLO (we run as separate script, cache may be empty)
    local me = getMeData()
    if not me or (me.id or 0) <= 0 then
        if shouldLog then debugLog('tick: no me data') end
        sendNeed(false, nil, 'no_me')
        return
    end

    local now = lib.getTimeMs()
    updateResourceFlags(now)

    local incapacitated, incapReason = lib.isIncapacitated()
    if incapacitated then
        if shouldLog then debugLog('tick: blocked by %s', tostring(incapReason)) end
        sendNeed(false, nil, 'incapacitated:' .. tostring(incapReason or 'unknown'))
        return
    end

    -- Track movement
    if me.moving == true then
        State.lastMoveAt = now
    end

    -- Track combat state (use lib.inCombat for XTarget hater detection,
    -- not me.combat which only checks auto-attack state)
    local inCombat = lib.inCombat()
    if inCombat then
        State.combatEndedAt = 0
    elseif State.wasInCombat == true then
        State.combatEndedAt = now
        State.postCombatJitter = math.random() * 750
    end
    State.wasInCombat = inCombat == true

    -- Blocking conditions (can't sit when any are true)
    local hovering = safeBool(function() return mq.TLO.Me.Hovering and mq.TLO.Me.Hovering() end)
    if hovering then
        if shouldLog then debugLog('tick: blocked by hovering') end
        sendNeed(false, nil, 'hovering')
        return
    end

    -- Casting check - don't sit while casting
    if me.casting == true then
        if shouldLog then debugLog('tick: blocked by casting') end
        sendNeed(false, nil, 'casting')
        return
    end

    -- Don't sit while cast owner is active (someone is casting)
    if isCastOwnerActive() then
        if shouldLog then debugLog('tick: blocked by castOwner active') end
        sendNeed(false, nil, 'cast_owner_active')
        return
    end

    -- Don't sit while actively casting spells or buff module is casting
    if shouldBlockForOtherActivity() then
        if shouldLog then debugLog('tick: blocked by other activity (priority=%s)', tostring(State.coordState and State.coordState.activePriority)) end
        sendNeed(false, nil, 'cast_busy')
        return
    end

    -- Movement plugins check
    local movementActive = movementPluginsActive()
    local movementBlocking = movementActive and me.moving == true
    if movementBlocking and me.sitting == true and canChangeState(now, settings) then
        if shouldLog then debugLog('tick: standing due to movement plugins') end
        cmdStand(now)
        return
    end

    -- Aggro check
    local aggroUnsafe = iHaveAggro(me, settings)
    if aggroUnsafe and me.sitting == true and canChangeState(now, settings) then
        if shouldLog then debugLog('tick: standing due to aggro') end
        cmdStand(now)
        return
    end

    -- OOC mode: stand if in combat
    if inCombat and mode == 'ooc' then
        if me.sitting == true and canChangeState(now, settings) then
            if shouldLog then debugLog('tick: standing due to combat (ooc mode)') end
            cmdStand(now)
        end
        sendNeed(false, nil, 'ooc_in_combat')
        return
    end

    -- Post-combat delay before sitting
    if (mode == 'ooc' or mode == 'inout') and State.combatEndedAt and State.combatEndedAt > 0 then
        local delay = (tonumber(settings.MeditationAfterCombatDelay) or 2.0) * 1000
        local readyAt = State.combatEndedAt + delay + (State.postCombatJitter or 0)
        if now < readyAt then
            if shouldLog then debugLog('tick: post-combat delay (%.1fs remaining)', (readyAt - now) / 1000) end
            sendNeed(false, nil, 'post_combat_delay')
            return
        end
    end

    -- Moving check
    if me.moving == true then
        if shouldLog then debugLog('tick: blocked by moving') end
        sendNeed(false, nil, 'moving')
        return
    end

    local memActive, memReason = spellMemorizationActive()
    if memActive then
        if shouldLog then debugLog('tick: spell memorization active (%s)', tostring(memReason)) end
        sendNeed(me.sitting ~= true, nil, 'spell_memorize:' .. tostring(memReason or 'active'))
        if me.sitting ~= true and canChangeState(now, settings) then
            cmdSit(now)
        end
        return
    end

    -- Determine if we should sit
    local wantSit, sitReason = shouldSit(me, settings)

    if shouldLog then
        debugLog('tick: wantSit=%s reason=%s sitting=%s hp=%s mana=%s end=%s standWhenDone=%s',
            tostring(wantSit), tostring(sitReason), tostring(me.sitting),
            tostring(me.hp), tostring(me.mana), tostring(me.endur),
            tostring(settings.MeditationStandWhenDone))
    end

    -- Block sit if aggro or movement unsafe
    local blockedBy = nil
    if wantSit and aggroUnsafe then
        wantSit = false
        blockedBy = 'aggro'
        if shouldLog then debugLog('tick: blocked by aggro') end
    end
    if wantSit and movementBlocking then
        wantSit = false
        blockedBy = 'movement'
        if shouldLog then debugLog('tick: blocked by movement') end
    end

    -- Send need hint based on whether we want to change state
    local needsAction = false
    local needReason = blockedBy
        and string.format('blocked:%s(%s)', blockedBy, sitReason or '?')
        or (sitReason or 'no_change')
    if wantSit and me.sitting ~= true then
        needsAction = true
        needReason = 'want_sit:' .. (sitReason or '?')
    elseif not wantSit and me.sitting == true and settings.MeditationStandWhenDone == true then
        needsAction = true
        needReason = 'want_stand:' .. (sitReason or '?')
    elseif me.sitting == true then
        needReason = 'sitting:' .. (sitReason or 'ok')
    end

    if shouldLog then
        debugLog('tick: needsAction=%s isMyPriority=%s', tostring(needsAction), tostring(isMyPriority()))
    end

    sendNeed(needsAction, nil, needReason)

    -- Meditation acts independently of activePriority.
    -- Sitting/standing doesn't use cast or target claims — it's just /sit or /stand.
    -- The blocking checks above (castBusy, casting, hovering, aggro, movement) already
    -- ensure we only sit when safe. The standard EQ healer loop is:
    --   sit → stand → cast heal → sit again
    -- Standing is instant so there's no delay if a heal needs to fire.

    -- Execute sit/stand
    if wantSit and me.sitting ~= true then
        if canChangeState(now, settings) then
            cmdSit(now)
        end
        return
    end

    if not wantSit and me.sitting == true and settings.MeditationStandWhenDone == true then
        if canChangeState(now, settings) then
            cmdStand(now)
        end
        return
    end
end

-------------------------------------------------------------------------------
-- Message Handling
-------------------------------------------------------------------------------

local function onStateReceived(content)
    if type(content) ~= 'table' then return end
    if tostring(content.ownerName or '') ~= tostring(lib.getMyName() or '') then return end
    if tostring(content.ownerServer or '') ~= tostring(lib.getMyServer() or '') then return end

    State.coordState = content
    State.stateReceivedAt = lib.getTimeMs()

    -- Start warmup on first state
    if not State.initialized then
        State.warmupUntil = lib.getTimeMs() + lib.Timing.WARMUP_MS
        State.initialized = true
        lib.log('info', M.MODULE_NAME, 'First state received, warming up for %dms', lib.Timing.WARMUP_MS)
    end
end

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

local function initialize()
    lib.log('info', M.MODULE_NAME, 'Initializing Meditation module (priority=%d)', lib.Priority.MEDITATION)

    -- Register actor to receive state broadcasts
    State.dropbox = actors.register(M.MODULE_NAME, function(message)
        local content = message()
        if type(content) ~= 'table' then return end

        -- Check if this is a state broadcast
        if content.tickId and content.epoch then
            onStateReceived(content)
        end
    end)

    -- Also listen on state mailbox
    State.stateDropbox = actors.register(lib.Mailbox.STATE, function(message)
        local content = message()
        if type(content) == 'table' and content.tickId and content.epoch then
            onStateReceived(content)
        end
    end)

    lib.log('info', M.MODULE_NAME, 'Meditation module ready, waiting for Coordinator state...')
end

--- Check if coordinator has been absent too long
local function isCoordinatorAbsent()
    if not lib.isInGame() then return false end
    -- Not initialized yet or never received state
    if not State.initialized then return false end
    if State.stateReceivedAt == 0 then return false end

    local now = lib.getTimeMs()
    local absence = now - State.stateReceivedAt
    if absence <= lib.Timing.COORDINATOR_ABSENCE_MS then return false end

    local status = lib.getLuaScriptStatus(lib.Scripts.COORDINATOR)
    if status ~= 'EXITED' then
        State.stateReceivedAt = now
        debugLog('WATCHDOG: coordinator actor state stale but Lua status=%s; keeping worker',
            status ~= '' and status or 'UNKNOWN')
        return false
    end
    return true
end

local function mainLoop()
    initialize()

    local lastHeartbeat = 0
    local tickDelayMs = 100  -- Meditation can tick slower
    local _coordinatorAbsentLogged = false
    local wasInGame = lib.isInGame()

    while State.running do
        tick()

        -- Send heartbeat periodically
        local now = lib.getTimeMs()
        local inGame = lib.isInGame()
        if inGame and not wasInGame then
            -- Give the coordinator's first post-zone state broadcast time to
            -- arrive before applying the absence watchdog.
            State.stateReceivedAt = now
        end
        wasInGame = inGame
        if (now - lastHeartbeat) >= lib.Timing.MODULE_HEARTBEAT_MS then
            sendHeartbeat()
            lastHeartbeat = now
        end

        -- Watchdog: check for coordinator absence
        if isCoordinatorAbsent() then
            if not _coordinatorAbsentLogged then
                _coordinatorAbsentLogged = true
                local absence = now - State.stateReceivedAt
                -- print(string.format(
                --     '\ar[SK-Watchdog]\ax Module "%s": Coordinator absent for %.1fs — shutting down gracefully',
                --     M.MODULE_NAME, absence / 1000))
                debugLog('WATCHDOG: Coordinator absent for %dms, shutting down', now - State.stateReceivedAt)
                lib.log('warn', M.MODULE_NAME,
                    'Stopping worker: coordinator Lua process is EXITED')
            end
            -- Meditation does not use claims, so no releaseClaim needed
            State.running = false
        else
            _coordinatorAbsentLogged = false
        end

        mq.delay(tickDelayMs)
    end

    lib.log('info', M.MODULE_NAME, 'Meditation module stopped')
end

-------------------------------------------------------------------------------
-- Command Binding
-------------------------------------------------------------------------------

local function commandEcho(fmt, ...)
    local ok, message = pcall(string.format, tostring(fmt or ''), ...)
    if not ok then message = tostring(fmt or '') end
    if mq and mq.cmd then
        -- MQ chat parsing treats backslash sequences as formatting codes.
        message = message:gsub('\\', '/')
        mq.cmd('/echo \\ag[SK-Next Meditation]\\ax ' .. message)
    else
        print('[SK-Next Meditation] ' .. message)
    end
end

local function echoLastSettingsAudit()
    local Paths = require('sidekick-next.utils.paths')
    local path = Paths.getModuleConfigDir() .. '/settings-audit.log'
    local file = io.open(path, 'r')
    if not file then
        commandEcho('No settings audit entries at %s', path)
        return
    end
    local last = nil
    for line in file:lines() do
        if line ~= '' then last = line end
    end
    file:close()
    commandEcho('Last settings write: %s', tostring(last or 'none'))
end

local function handleCommand(cmd)
    cmd = tostring(cmd or ''):lower():match('^%s*(.-)%s*$')
    if cmd == 'on' then cmd = 'ooc' end

    if cmd == 'off' or cmd == 'ooc' or cmd == 'always' or cmd == 'in combat' or cmd == 'incombat' then
        local mode = cmd
        if mode == 'incombat' then mode = 'in combat' end
        -- The worker is read-only for the shared character INI. Route the
        -- change to the UI process, which is the sole settings writer.
        mq.cmdf('/sk_next_set_meditation %s', mode)
        _settings = nil
        _settingsRevision = nil
        commandEcho('Requested mode=%s through the primary settings writer', mode)
    elseif cmd == 'audit' then
        echoLastSettingsAudit()
    elseif cmd == 'stop' then
        State.running = false
        lib.log('info', M.MODULE_NAME, 'Stop requested')
        commandEcho('Stop requested')
    elseif cmd == 'reload' then
        _settings = nil
        _settingsRevision = nil
        local settings = getSettings()
        lib.log('info', M.MODULE_NAME, 'Reloaded settings: mode=%s manaStart=%s manaStop=%s',
            tostring(normalizeMode(settings.MeditationMode)),
            tostring(settings.MeditationManaStartPct),
            tostring(settings.MeditationManaStopPct))
        commandEcho('Reloaded config=%s rawMode=%s normalized=%s',
            tostring(_settingsPath or 'unknown'), tostring(settings.MeditationMode),
            tostring(normalizeMode(settings.MeditationMode)))
    elseif cmd == 'status' then
        local settings = getSettings()
        local me = getMeData() or {}
        lib.log('info', M.MODULE_NAME, 'script=sidekick-next/sk_meditation config=%s rawMode=%s',
            tostring(_settingsPath or 'unknown'), tostring(settings.MeditationMode))
        lib.log('info', M.MODULE_NAME, 'running=%s, hasState=%s, isMyPriority=%s, mode=%s, mana=%s, sitting=%s, lastReason=%s',
            tostring(State.running),
            tostring(hasValidState()),
            tostring(isMyPriority()),
            tostring(normalizeMode(settings.MeditationMode)),
            tostring(me.mana),
            tostring(me.sitting),
            tostring(State.lastNeedReason))
        lib.log('info', M.MODULE_NAME,
            'combat=%s moving=%s movePlugin=%s casting=%s castBusy=%s aggroUnsafe=%s hp=%s end=%s postCombatMs=%s',
            tostring(lib.inCombat()),
            tostring(me.moving == true),
            tostring(movementPluginsActive()),
            tostring(me.casting == true),
            tostring(State.coordState and State.coordState.castBusy == true),
            tostring(iHaveAggro(me, settings)),
            tostring(me.hp),
            tostring(me.endur),
            State.combatEndedAt > 0 and tostring(math.max(0, lib.getTimeMs() - State.combatEndedAt)) or 'none')
        commandEcho('script=sidekick-next/sk_meditation config=%s rawMode=%s normalized=%s reason=%s',
            tostring(_settingsPath or 'unknown'), tostring(settings.MeditationMode),
            tostring(normalizeMode(settings.MeditationMode)), tostring(State.lastNeedReason))
        commandEcho('state=%s priority=%s mana=%s sitting=%s combat=%s moving=%s casting=%s castBusy=%s aggro=%s',
            tostring(hasValidState()), tostring(isMyPriority()), tostring(me.mana), tostring(me.sitting),
            tostring(lib.inCombat()), tostring(me.moving == true), tostring(me.casting == true),
            tostring(State.coordState and State.coordState.castBusy == true),
            tostring(iHaveAggro(me, settings)))
        commandEcho('thresholds mana=%s/%s hp=%s/%s end=%s/%s',
            tostring(settings.MeditationManaStartPct), tostring(settings.MeditationManaStopPct),
            tostring(settings.MeditationHPStartPct), tostring(settings.MeditationHPStopPct),
            tostring(settings.MeditationEndStartPct), tostring(settings.MeditationEndStopPct))
    else
        lib.log('info', M.MODULE_NAME, 'Usage: /sk_next_meditation off|ooc|always|status|reload|audit|stop')
        commandEcho('Usage: /sk_next_meditation off|ooc|always|status|reload|audit|stop')
    end
end

-- Next-only command. The legacy alias remains for compatibility, but may be
-- shadowed when production SideKick is also running.
mq.bind('/sk_next_meditation', handleCommand)
mq.bind('/sk_meditation', handleCommand)

-------------------------------------------------------------------------------
-- Run
-------------------------------------------------------------------------------

mainLoop()

return M
