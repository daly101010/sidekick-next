local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local RuntimeCache = require('sidekick-next.utils.runtime_cache')
local ActionExecutor = require('sidekick-next.utils.action_executor')

local debugLog = require('sidekick-next.utils.debug_log').tagged('Med', 'SideKick_MedDebug.log')

-- Dedicated meditation logger (file-based) - for medLog calls
local _MedLogger = nil
local function getMedLogger()
    if not _MedLogger then
        local ok, logger = pcall(require, 'sidekick-next.automation.med_logger')
        if ok then
            _MedLogger = logger
            if _MedLogger and _MedLogger.init then
                _MedLogger.init()
            end
        end
    end
    return _MedLogger
end

local getBuff = lazy('sidekick-next.automation.buff')
local getSpellSetMemorize = lazy('sidekick-next.utils.spellset_memorize')

local M = {}

local _state = {
    lastCmdAt = 0,
    lastStateChangeAt = 0,
    lastMoveAt = 0,
    lastCombatAt = 0,
    combatEndedAt = 0,
    postCombatJitter = 0,
    wasInCombat = false,
    lastMaxProbeAt = 0,
    hasMana = true,
    hasEndurance = true,
}

local _lastLogAt = {}
local function medLog(key, intervalSec, fmt, ...)
    local now = os.clock()
    local last = _lastLogAt[key] or 0
    if (now - last) < (intervalSec or 0) then return end
    _lastLogAt[key] = now
    -- In-game echo disabled
    local log = getMedLogger()
    if log then
        log.info('tick', fmt, ...)
    end
end

local function safeBool(fn)
    local ok, v = pcall(fn)
    return ok and v == true
end

local function normalize_mode(mode)
    mode = tostring(mode or 'off'):lower()
    if mode == 'off' or mode == '0' or mode == 'false' then return 'off' end
    if mode == 'ooc' or mode == 'out' or mode == 'outofcombat' then return 'ooc' end
    if mode == 'in combat' or mode == 'incombat' then return 'inout' end
    if mode == 'inout' or mode == 'in_and_out' or mode == 'inandout' or mode == 'both' or mode == 'always' then return 'inout' end
    -- Unknown modes treated as 'inout' to be safe
    debugLog('[NormalizeMode] unknown mode=%s, defaulting to inout', mode)
    return 'inout'
end

local function movement_plugins_active()
    local stickActive = safeBool(function() return mq.TLO.Stick and mq.TLO.Stick.Active and mq.TLO.Stick.Active() end)
    if stickActive then return true end

    local navActive = safeBool(function()
        ---@diagnostic disable-next-line: undefined-field
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

local function count_xtarget_on_me(cache)
    local xt = cache.xtarget or {}
    local haters = xt.haters or {}
    local count = 0
    for _, h in pairs(haters) do
        if h and h.targetingMe == true then
            count = count + 1
        end
    end
    return count
end

local function i_have_aggro(cache, settings)
    if settings.MeditationAggroCheck ~= true then return false end
    local thresh = tonumber(settings.MeditationAggroPct) or 95
    local secThresh = tonumber(settings.MeditationSecondaryAggroPct) or 90

    local me = cache.me or {}
    if (me.pctAggro or 0) >= thresh then return true end

    local myId = me.id or (mq.TLO.Me.ID and mq.TLO.Me.ID()) or 0
    local holderId = getAggroHolderId()
    if myId > 0 and holderId > 0 and holderId == myId then
        return true
    end

    local xtOnMe = count_xtarget_on_me(cache)
    if xtOnMe > 0 then
        return true
    end

    local sec = tonumber(me.secondaryPctAggro) or 0
    -- Ignore default/invalid 100 for secondary aggro unless we also have a holder match
    if sec >= secThresh and sec < 100 then return true end
    return false
end

local function update_resource_flags(now)
    if (now - (_state.lastMaxProbeAt or 0)) < 5.0 then return end
    _state.lastMaxProbeAt = now

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

    _state.hasMana = maxMana > 0
    _state.hasEndurance = maxEnd > 0
end

local function should_sit(cache, settings)
    local me = cache.me or {}

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

    debugLog('[ShouldSit] hp=%d mana=%d endur=%d sitting=%s hasMana=%s hasEnd=%s',
        hp, mana, endur, tostring(sitting), tostring(_state.hasMana), tostring(_state.hasEndurance))
    debugLog('[ShouldSit] thresholds: hpStart=%d hpStop=%d manaStart=%d manaStop=%d endStart=%d endStop=%d',
        hpStart, hpStop, manaStart, manaStop, endStart, endStop)

    local function belowStart()
        if hp < hpStart then return true end
        if _state.hasMana and mana < manaStart then return true end
        if _state.hasEndurance and endur < endStart then return true end
        return false
    end

    local function aboveStop()
        if hp < hpStop then return false end
        if _state.hasMana and mana < manaStop then return false end
        if _state.hasEndurance and endur < endStop then return false end
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

local function can_change_state(now, settings)
    local minHold = tonumber(settings.MeditationMinStateSeconds) or 1.0
    local minCmd = 0.5
    if (now - (_state.lastCmdAt or 0)) < minCmd then return false end
    if (now - (_state.lastStateChangeAt or 0)) < minHold then return false end
    return true
end

local function cmd_sit(now)
    mq.cmd('/squelch /sit')
    _state.lastCmdAt = now
    _state.lastStateChangeAt = now
end

local function cmd_stand(now)
    mq.cmd('/squelch /stand')
    _state.lastCmdAt = now
    _state.lastStateChangeAt = now
end

local function spell_memorization_active()
    local Memorize = getSpellSetMemorize()
    if Memorize and Memorize.isBusy and Memorize.isBusy() then
        return true, 'spellset_memorize'
    end

    local bookOpen = safeBool(function()
        local wnd = mq.TLO.Window and mq.TLO.Window('SpellBookWnd')
        return wnd and wnd.Open and wnd.Open()
    end)
    if bookOpen then return true, 'spellbook_open' end

    return false, nil
end

function M.tick(settings)
    settings = settings or {}
    local mode = normalize_mode(settings.MeditationMode)

    debugLog('[MedTick] mode=%s', tostring(mode))

    if mode == 'off' then
        debugLog('[MedTick] skip: mode=off')
        medLog('mode_off', 5, 'tick skip: mode=off')
        return
    end

    local cache = RuntimeCache
    local me = cache.me or {}
    if (me.id or 0) <= 0 then
        debugLog('[MedTick] skip: no character in cache')
        medLog('no_me', 5, 'tick skip: no character')
        return
    end

    debugLog('[MedTick] me.id=%d mana=%d sitting=%s', me.id or 0, me.mana or 0, tostring(me.sitting))

    local now = os.clock()
    update_resource_flags(now)

    if me.moving == true then
        _state.lastMoveAt = now
    end

    local inCombat = cache.inCombat and cache.inCombat() or (me.combat == true)
    if inCombat then
        _state.lastCombatAt = now
        _state.combatEndedAt = 0
    elseif _state.wasInCombat == true then
        _state.combatEndedAt = now
        _state.postCombatJitter = math.random() * 0.75
    end
    _state.wasInCombat = inCombat == true

    local hovering = safeBool(function() return mq.TLO.Me.Hovering and mq.TLO.Me.Hovering() end)
    if hovering then
        medLog('hovering', 5, 'tick skip: hovering')
        return
    end

    if ActionExecutor and ActionExecutor.isSpellBusy and ActionExecutor.isSpellBusy() then
        medLog('spell_busy', 2, 'tick skip: spell busy')
        return
    end
    if me.casting == true then
        medLog('casting', 2, 'tick skip: casting')
        return
    end

    local movementActive = movement_plugins_active()
    local movementBlocking = movementActive and me.moving == true
    if movementBlocking and me.sitting == true and can_change_state(now, settings) then
        cmd_stand(now)
        medLog('stand_moving', 2, 'stand: movement active while moving')
        return
    end

    local aggroUnsafe = i_have_aggro(cache, settings)
    local aggroCheckEnabled = settings.MeditationAggroCheck == true
    local aggroThresh = tonumber(settings.MeditationAggroPct) or 95
    local aggroSecThresh = tonumber(settings.MeditationSecondaryAggroPct) or 90
    local aggroHolderId = getAggroHolderId()
    local xtOnMe = count_xtarget_on_me(cache)
    medLog('aggro_status', 2,
        'aggro check: enabled=%s pct=%s sec=%s thresh=%s/%s holderId=%s xtOnMe=%d unsafe=%s',
        tostring(aggroCheckEnabled), tostring(me.pctAggro or 0), tostring(me.secondaryPctAggro or 0),
        tostring(aggroThresh), tostring(aggroSecThresh), tostring(aggroHolderId), xtOnMe, tostring(aggroUnsafe))
    if aggroUnsafe and me.sitting == true and can_change_state(now, settings) then
        cmd_stand(now)
        medLog('stand_aggro', 2, 'stand: aggro unsafe')
        return
    end

    if inCombat and mode == 'ooc' then
        if me.sitting == true and can_change_state(now, settings) then
            cmd_stand(now)
            medLog('stand_ooc_combat', 2, 'stand: in combat, mode=ooc')
        end
        medLog('skip_ooc_combat', 2, 'tick skip: in combat, mode=ooc')
        return
    end

    if me.stunned == true then
        if me.sitting == true and can_change_state(now, settings) then
            cmd_stand(now)
            medLog('stand_stunned', 2, 'stand: stunned')
        end
        medLog('skip_stunned', 2, 'tick skip: stunned')
        return
    end

    -- Post-combat delay before sitting (reduces sit/stand churn when mobs re-aggro).
    if (mode == 'ooc' or mode == 'inout') and _state.combatEndedAt and _state.combatEndedAt > 0 then
        local delay = tonumber(settings.MeditationAfterCombatDelay) or 2.0
        local readyAt = _state.combatEndedAt + delay + (_state.postCombatJitter or 0)
        if now < readyAt then
            medLog('post_combat_delay', 2, 'tick skip: post-combat delay (%.2fs left)', readyAt - now)
            return
        end
    end

    if me.moving == true then
        medLog('moving', 2, 'tick skip: moving')
        return
    end

    local memActive, memReason = spell_memorization_active()
    if memActive then
        if me.sitting ~= true and can_change_state(now, settings) then
            cmd_sit(now)
            medLog('sit_memorize', 2, 'sit: spell memorization active (%s)', tostring(memReason))
        else
            medLog('hold_memorize', 2, 'hold posture: spell memorization active (%s)', tostring(memReason))
        end
        return
    end

    local wantSit, sitReason = should_sit(cache, settings)
    medLog('decision', 2, 'mode=%s inCombat=%s sitting=%s moving=%s wantSit=%s reason=%s hp=%d mana=%d end=%d hasMana=%s hasEnd=%s',
        tostring(mode), tostring(inCombat), tostring(me.sitting == true), tostring(me.moving == true), tostring(wantSit),
        tostring(sitReason), tonumber(me.hp) or 0, tonumber(me.mana) or 0, tonumber(me.endur) or 0,
        tostring(_state.hasMana), tostring(_state.hasEndurance))
    if wantSit and aggroUnsafe then
        wantSit = false
        medLog('block_aggro', 2, 'block sit: aggro unsafe (aggro=%s/%s)',
            tostring(me.pctAggro or 0), tostring(me.secondaryPctAggro or 0))
    end
    if wantSit and movementBlocking then
        wantSit = false
        medLog('block_movement', 2, 'block sit: movement active while moving')
    end

    if wantSit and me.sitting ~= true then
        local Buff = getBuff()
        if inCombat ~= true and Buff and Buff.isBuffingActive and Buff.isBuffingActive() then
            medLog('sit_block_buff', 2, 'sit blocked: buffing active')
            return
        end
        if can_change_state(now, settings) then
            cmd_sit(now)
            medLog('sit', 2, 'sit: below thresholds')
        else
            medLog('sit_hold', 2, 'sit hold: state/cmd cooldown')
        end
        return
    end

    if not wantSit and me.sitting == true and settings.MeditationStandWhenDone == true then
        local Buff = getBuff()
        if inCombat ~= true and Buff and Buff.isBuffingActive and Buff.isBuffingActive() then
            medLog('stand_block_buff', 2, 'stand blocked: buffing active')
            return
        end
        if can_change_state(now, settings) then
            cmd_stand(now)
            medLog('stand_done', 2, 'stand: done medding')
        else
            medLog('stand_hold', 2, 'stand hold: state/cmd cooldown')
        end
        return
    end

    medLog('no_change', 2, 'no state change')
end

return M
