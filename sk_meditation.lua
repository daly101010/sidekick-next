-- F:/lua/sidekick-next/sk_meditation.lua
-- Leased meditation worker (sit/stand for resource regeneration).

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local ActionCounters = require('sidekick-next.utils.action_counters')

local M = ModuleBase.create('meditation', lib.Priority.MEDITATION)

local debugLog = require('sidekick-next.utils.debug_log').module('sk_meditation', 'SK_MEDITATION')

M.MODULE_NAME = 'meditation'

-- Internal state
local State = {
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

    lastNeedReason = 'init',
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
    local revision = tonumber(M.state and M.state.settingsRevision) or 0
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
    return M:hasValidState()
end

local function isWarmingUp()
    return M:isWarmingUp()
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

-- Event-driven "something is hitting me" detection. Chat combat events are
-- the ground truth: they fire regardless of XTarget configuration, target
-- selection, or buff-cache state. Any melee hit, spell hit, or melee miss
-- against me marks the character combat-unsafe for DAMAGE_HOLD_MS.
local DAMAGE_HOLD_MS = 8000
local _lastDamageAt = 0

local function onDamagedMe()
    _lastDamageAt = mq.gettime()
end

-- "A gnoll hits YOU for 15 points of damage." (all melee verbs + non-melee)
mq.event('skmed_hit_me', '#1# #2# YOU for #3# point#*# of damage#*#', onDamagedMe)
-- "A gnoll tries to hit YOU, but misses!" (and parry/dodge/riposte variants)
mq.event('skmed_miss_me', '#1# tries to #2# YOU, but#*#', onDamagedMe)

local function recentlyDamaged()
    return _lastDamageAt > 0 and (mq.gettime() - _lastDamageAt) < DAMAGE_HOLD_MS
end

--- True when any live XTarget hater is currently targeting me. This is the
--- only aggro signal that works for healers: PctAggro and AggroHolder are
--- both relative to the CURRENT TARGET, and a healer targets group members,
--- so those checks read nothing while a mob beats on them.
local function mobAttackingMe(myId)
    myId = tonumber(myId) or 0
    if myId <= 0 then return false end
    local ok, attacked = pcall(function()
        local count = tonumber(mq.TLO.Me.XTarget()) or 0
        for i = 1, count do
            local xt = mq.TLO.Me.XTarget(i)
            if xt and (tonumber(xt.ID()) or 0) > 0 then
                local dead = xt.Dead and xt.Dead() == true
                local tot = (xt.TargetOfTarget and tonumber(xt.TargetOfTarget.ID())) or 0
                if not dead and tot == myId then return true end
            end
        end
        return false
    end)
    return ok and attacked == true
end

local function iHaveAggro(me, settings)
    if settings.MeditationAggroCheck ~= true then return false end
    local thresh = tonumber(settings.MeditationAggroPct) or 95

    me = me or {}
    -- Combat log events are the strongest signal: if something swung at me
    -- in the last few seconds, do not sit, whatever the TLOs claim.
    if recentlyDamaged() then return true end

    if (me.pctAggro or 0) >= thresh then return true end

    local myId = me.id or 0
    local holderId = getAggroHolderId()
    if myId > 0 and holderId > 0 and holderId == myId then
        return true
    end

    -- NOTE: We intentionally do NOT count XTarget auto hater slots as aggro.
    -- 'Auto Hater' means "a mob hating someone in the group" — that would
    -- block ALL in-combat meditation for every member. But a hater whose
    -- target-of-target is ME is personal aggro regardless of what I have
    -- targeted, and is the only signal that works while targeting a PC.
    if mobAttackingMe(myId) then return true end

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
    ActionCounters.bump('sit')
    mq.cmd('/squelch /sit')
    State.lastCmdAt = now
    State.lastStateChangeAt = now
end

local function cmdStand(now)
    mq.cmd('/squelch /stand')
    State.lastCmdAt = now
    State.lastStateChangeAt = now
end

local function updateIntent(needsAction, ttlMs, reason)
    State.lastNeedReason = tostring(reason or (needsAction and 'ready' or 'idle'))
    M:setIntent(needsAction == true, ttlMs, State.lastNeedReason)
end

local function spellMemorizationActive()
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
local _pendingAction = nil

local function proposeState(command, reason, now, settings)
    if not canChangeState(now, settings) then
        updateIntent(false, nil, 'state_change_throttled:' .. tostring(reason or command))
        return false
    end
    _pendingAction = {
        kind = 'meditation_state',
        meditationCommand = command,
        name = command == 'sit' and 'Sit to meditate' or 'Stand',
        breaksInvis = false,
        skipBoundaryTarget = true,
        settleMs = 150,
        timeoutMs = 1500,
        idempotencyKey = 'meditation:' .. command,
        reason = tostring(reason or command),
    }
    updateIntent(true, nil, _pendingAction.reason)
    return true
end

M.onTick = function(self)
    _pendingAction = nil
    -- Remain loaded through zoning, but do not sit/stand or inspect character
    -- state until MacroQuest reports that the character is fully in game.
    if not lib.isInGame() then
        updateIntent(false, nil, 'not_ingame')
        return
    end

    local paused = self.state and self.state.automationPaused
    if paused == nil and lib.isAutomationPaused then paused = lib.isAutomationPaused() end
    if paused == true then
        updateIntent(false, nil, 'automation_paused')
        return
    end

    -- Safety: stop if no valid state
    if not hasValidState() then
        updateIntent(false, nil, 'no_state')
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
        updateIntent(false, nil, 'mode_off')
        return
    end

    -- Get character data directly from TLO (we run as separate script, cache may be empty)
    local me = getMeData()
    if not me or (me.id or 0) <= 0 then
        if shouldLog then debugLog('tick: no me data') end
        updateIntent(false, nil, 'no_me')
        return
    end

    local now = lib.getTimeMs()
    updateResourceFlags(now)

    local incapacitated, incapReason = lib.isIncapacitated()
    if incapacitated then
        if shouldLog then debugLog('tick: blocked by %s', tostring(incapReason)) end
        updateIntent(false, nil, 'incapacitated:' .. tostring(incapReason or 'unknown'))
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
        updateIntent(false, nil, 'hovering')
        return
    end

    -- Casting check - don't sit while casting
    if me.casting == true then
        if shouldLog then debugLog('tick: blocked by casting') end
        updateIntent(false, nil, 'casting')
        return
    end

    -- Movement plugins check
    local movementActive = movementPluginsActive()
    local movementBlocking = movementActive and me.moving == true
    if movementBlocking and me.sitting == true and canChangeState(now, settings) then
        if shouldLog then debugLog('tick: standing due to movement plugins') end
        proposeState('stand', 'movement_active', now, settings)
        return
    end

    -- Aggro check. Standing up is only half of it: never INITIATE a sit while
    -- a mob is on us either, or a healer chain-sits itself to death.
    local aggroUnsafe = iHaveAggro(me, settings)
    if aggroUnsafe then
        if me.sitting == true and canChangeState(now, settings) then
            if shouldLog then debugLog('tick: standing due to aggro') end
            ActionCounters.bump('aggro_stand')
            proposeState('stand', 'aggro_hold', now, settings)
            return
        end
        updateIntent(false, nil, 'aggro_hold')
        return
    end

    -- OOC mode: stand if in combat
    if inCombat and mode == 'ooc' then
        if me.sitting == true and canChangeState(now, settings) then
            if shouldLog then debugLog('tick: standing due to combat (ooc mode)') end
            proposeState('stand', 'ooc_in_combat', now, settings)
            return
        end
        updateIntent(false, nil, 'ooc_in_combat')
        return
    end

    -- Post-combat delay before sitting
    if (mode == 'ooc' or mode == 'inout') and State.combatEndedAt and State.combatEndedAt > 0 then
        local delay = (tonumber(settings.MeditationAfterCombatDelay) or 2.0) * 1000
        local readyAt = State.combatEndedAt + delay + (State.postCombatJitter or 0)
        if now < readyAt then
            if shouldLog then debugLog('tick: post-combat delay (%.1fs remaining)', (readyAt - now) / 1000) end
            updateIntent(false, nil, 'post_combat_delay')
            return
        end
    end

    -- Moving check
    if me.moving == true then
        if shouldLog then debugLog('tick: blocked by moving') end
        updateIntent(false, nil, 'moving')
        return
    end

    local memActive, memReason = spellMemorizationActive()
    if memActive then
        if shouldLog then debugLog('tick: spell memorization active (%s)', tostring(memReason)) end
        updateIntent(me.sitting ~= true, nil, 'spell_memorize:' .. tostring(memReason or 'active'))
        if me.sitting ~= true and canChangeState(now, settings) then
            proposeState('sit', 'spell_memorize:' .. tostring(memReason or 'active'),
                now, settings)
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
        debugLog('tick: needsAction=%s ownsLease=%s',
            tostring(needsAction), tostring(self:ownsLease()))
    end

    updateIntent(needsAction, nil, needReason)

    -- Sitting/standing doesn't use cast or target claims — it's just /sit or /stand.
    -- ensure we only sit when safe. The standard EQ healer loop is:
    --   sit → stand → cast heal → sit again

    if wantSit and me.sitting ~= true then
        proposeState('sit', needReason, now, settings)
        return
    end

    if not wantSit and me.sitting == true and settings.MeditationStandWhenDone == true then
        proposeState('stand', needReason, now, settings)
        return
    end
end

M.shouldAct = function()
    return _pendingAction ~= nil
end

M.getAction = function()
    return _pendingAction
end

M:enableUnifiedExecutor({
    preflight = function(action)
        local me = getMeData()
        if not me then return false, 'no_me' end
        if me.casting == true then return false, 'casting' end
        local command = tostring(action.meditationCommand or '')
        if command == 'sit' then
            if me.sitting == true then return false, 'already_sitting' end
            if me.moving == true then
                return false, 'movement_active'
            end
            if iHaveAggro(me, getSettings()) then return false, 'aggro_hold' end
        elseif command == 'stand' then
            if me.sitting ~= true then return false, 'already_standing' end
        else
            return false, 'invalid_meditation_command'
        end
        return true
    end,
    dispatch = function(action)
        local now = lib.getTimeMs()
        if action.meditationCommand == 'sit' then
            cmdSit(now)
        else
            cmdStand(now)
        end
        _pendingAction = nil
        return true, 'issued', 'settle'
    end,
})

                --     '\ar[SK-Watchdog]\ax Module "%s": Coordinator absent for %.1fs — shutting down gracefully',
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
        M:stop()
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
        lib.log('info', M.MODULE_NAME, 'running=%s, hasState=%s, ownsLease=%s, mode=%s, mana=%s, sitting=%s, lastReason=%s',
            tostring(M.running),
            tostring(hasValidState()),
            tostring(M:ownsLease()),
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
            tostring(M.state and M.state.worldState and M.state.worldState.castBusy == true),
            tostring(iHaveAggro(me, settings)),
            tostring(me.hp),
            tostring(me.endur),
            State.combatEndedAt > 0 and tostring(math.max(0, lib.getTimeMs() - State.combatEndedAt)) or 'none')
        commandEcho('script=sidekick-next/sk_meditation config=%s rawMode=%s normalized=%s reason=%s',
            tostring(_settingsPath or 'unknown'), tostring(settings.MeditationMode),
            tostring(normalizeMode(settings.MeditationMode)), tostring(State.lastNeedReason))
        commandEcho('state=%s ownsLease=%s mana=%s sitting=%s combat=%s moving=%s casting=%s castBusy=%s aggro=%s',
            tostring(hasValidState()), tostring(M:ownsLease()), tostring(me.mana), tostring(me.sitting),
            tostring(lib.inCombat()), tostring(me.moving == true), tostring(me.casting == true),
            tostring(M.state and M.state.worldState and M.state.worldState.castBusy == true),
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

M:run(100)

return M
