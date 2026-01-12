local mq = require('mq')

local RuntimeCache = require('utils.runtime_cache')
local ActionExecutor = require('utils.action_executor')

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

local function safeBool(fn)
    local ok, v = pcall(fn)
    return ok and v == true
end

local function normalize_mode(mode)
    mode = tostring(mode or 'off'):lower()
    if mode == 'off' or mode == '0' or mode == 'false' then return 'off' end
    if mode == 'ooc' or mode == 'out' or mode == 'outofcombat' then return 'ooc' end
    if mode == 'in combat' or mode == 'incombat' then return 'inout' end
    if mode == 'inout' or mode == 'in_and_out' or mode == 'inandout' or mode == 'both' then return 'inout' end
    return mode
end

local function movement_plugins_active()
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

local function i_have_aggro(cache, settings)
    if settings.MeditationAggroCheck ~= true then return false end
    local thresh = tonumber(settings.MeditationAggroPct) or 95

    local me = cache.me or {}
    if (me.pctAggro or 0) >= thresh then return true end
    if (me.secondaryPctAggro or 0) >= thresh then return true end

    for _, h in ipairs((cache.xtarget and cache.xtarget.haters) or {}) do
        if h and h.targetingMe == true then
            return true
        end
    end

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
            return not aboveStop()
        end
        return belowStart() or not aboveStop()
    end

    return belowStart()
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

function M.tick(settings)
    settings = settings or {}
    local mode = normalize_mode(settings.MeditationMode)
    if mode == 'off' then return end

    local cache = RuntimeCache
    local me = cache.me or {}
    if (me.id or 0) <= 0 then return end

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
    if hovering then return end

    if ActionExecutor and ActionExecutor.isSpellBusy and ActionExecutor.isSpellBusy() then return end
    if me.casting == true then return end

    local movementActive = movement_plugins_active()
    if movementActive and me.sitting == true and can_change_state(now, settings) then
        cmd_stand(now)
        return
    end

    local aggroUnsafe = i_have_aggro(cache, settings)
    if aggroUnsafe and me.sitting == true and can_change_state(now, settings) then
        cmd_stand(now)
        return
    end

    if inCombat and mode == 'ooc' then
        if me.sitting == true and can_change_state(now, settings) then
            cmd_stand(now)
        end
        return
    end

    if me.stunned == true then
        if me.sitting == true and can_change_state(now, settings) then
            cmd_stand(now)
        end
        return
    end

    -- Post-combat delay before sitting (reduces sit/stand churn when mobs re-aggro).
    if (mode == 'ooc' or mode == 'inout') and _state.combatEndedAt and _state.combatEndedAt > 0 then
        local delay = tonumber(settings.MeditationAfterCombatDelay) or 2.0
        local readyAt = _state.combatEndedAt + delay + (_state.postCombatJitter or 0)
        if now < readyAt then
            return
        end
    end

    if me.moving == true then return end

    local wantSit = should_sit(cache, settings)
    if wantSit and aggroUnsafe then
        wantSit = false
    end
    if wantSit and movementActive then
        wantSit = false
    end

    if wantSit and me.sitting ~= true then
        if can_change_state(now, settings) then
            cmd_sit(now)
        end
        return
    end

    if not wantSit and me.sitting == true and settings.MeditationStandWhenDone == true then
        if can_change_state(now, settings) then
            cmd_stand(now)
        end
        return
    end
end

return M
