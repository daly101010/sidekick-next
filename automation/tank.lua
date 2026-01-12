local mq = require('mq')
local Targeting = require('utils.targeting')
local Aggro = require('utils.aggro')
local Positioning = require('utils.positioning')
local Actors = require('utils.actors_coordinator')
local Abilities = require('utils.abilities')
local Helpers = require('lib.helpers')
local Cache = require('utils.runtime_cache')
local Executor = require('utils.action_executor')
local CC = require('automation.cc')

local M = {}

M.primaryTargetId = nil
M.settings = nil

-- State machine states
local STATE = {
    IDLE = 'idle',
    TAUNT_ACQUIRE = 'taunt_acquire',
    TAUNT_MOVING = 'taunt_moving',
    TAUNT_EXECUTE = 'taunt_execute',
    TAUNT_RETURN = 'taunt_return',
    REPOSITION_SETTLING = 'reposition_settling',
}

-- State machine context
local _state = {
    current = STATE.IDLE,
    taunt = {
        targetId = nil,
        savedTargetId = nil,
        startTime = 0,
        moveTimeout = 0,
    },
    reposition = {
        settleUntil = 0,
    },
    lastAbilityUse = 0,
}

-- Minimum time between ability activations (prevents spam)
local ABILITY_COOLDOWN = 0.05  -- 50ms

function M.init(settings)
    M.settings = settings or {}
    _state.current = STATE.IDLE
end

-- Check if an ability is ready to use
local function isAbilityReady(def)
    local me = mq.TLO.Me
    if not me or not me() then return false end

    local kind = tostring(def.kind or 'aa')

    if kind == 'aa' then
        if def.altID and me.AltAbilityReady then
            return me.AltAbilityReady(tonumber(def.altID))() == true
        elseif def.altName and me.AltAbilityReady then
            return me.AltAbilityReady(def.altName)() == true
        end
    elseif kind == 'disc' then
        local discName = tostring(def.discName or def.altName or '')
        if discName ~= '' and me.CombatAbilityReady then
            for _, candidate in ipairs(Helpers.discNameCandidates(discName)) do
                local ok, ready = pcall(function()
                    return me.CombatAbilityReady(candidate)() == true
                end)
                if ok and ready then return true end
            end
        end
    end
    return false
end

-- Safe ability activation with cooldown check
local function activateAbility(def)
    local now = os.clock()
    if (now - _state.lastAbilityUse) < ABILITY_COOLDOWN then
        return false
    end
    Abilities.activate(def)
    _state.lastAbilityUse = now
    return true
end

function M.tick(abilities, settings)
    M.settings = settings or M.settings
    if not M.settings then return end
    if M.settings.CombatMode ~= 'tank' then return end

    local me = mq.TLO.Me
    if not me or not me() then return end
    local myId = me.ID()

    -- Run state machine
    M.runStateMachine(myId, abilities, settings)
end

function M.runStateMachine(myId, abilities, settings)
    local state = _state.current

    -- Handle taunt state machine
    if state == STATE.TAUNT_ACQUIRE then
        M.stateTauntAcquire()
        return  -- Don't do normal operations during taunt sequence
    elseif state == STATE.TAUNT_MOVING then
        M.stateTauntMoving()
        return
    elseif state == STATE.TAUNT_EXECUTE then
        M.stateTauntExecute()
        return
    elseif state == STATE.TAUNT_RETURN then
        M.stateTauntReturn()
        return
    end

    -- Handle reposition state machine
    if state == STATE.REPOSITION_SETTLING then
        M.stateRepositionSettling()
        return
    end

    -- Normal IDLE state operations
    if M.settings.TankTargetMode == 'manual' then
        M.runManualMode()
    else
        M.runAutoMode(myId, abilities, settings)
    end
end

function M.runManualMode()
    local target = mq.TLO.Target
    if target and target() and target.ID() > 0 then
        if target.ID() ~= M.primaryTargetId then
            M.primaryTargetId = target.ID()
            Actors.broadcastTargetPrimary(target.ID(), target.CleanName())
        end
    end
end

function M.runAutoMode(myId, abilities, settings)
    -- Select best target based on priority (with safe targeting / KS prevention)
    local bestTarget = Targeting.selectBestTarget(myId, 100, settings)

    if bestTarget and bestTarget() then
        local targetId = bestTarget.ID()

        -- Update primary target if changed
        if targetId ~= M.primaryTargetId then
            M.primaryTargetId = targetId
            Targeting.targetSpawn(bestTarget)
            Actors.broadcastTargetPrimary(targetId, bestTarget.CleanName())
        end
    end

    -- Handle aggro management
    M.handleAggro(myId, abilities, settings)

    -- Handle positioning (non-blocking)
    M.handlePositioning()
end

function M.handleAggro(myId, abilities, settings)
    -- Use runtime cache for mob counts
    local unmezzedCount = Cache.unmezzedHaterCount()

    -- AoE hate gen if 3+ mobs (or configured threshold)
    if unmezzedCount >= (settings.TankAoEThreshold or 3) then
        local shouldAoE = true

        if settings.TankRequireAggroDeficit then
            shouldAoE = (Cache.xtarget.aggroDeficitCount or 0) > 0
        end

        -- Safety check: don't AoE if mezzed mobs on XTarget
        if shouldAoE and settings.TankSafeAECheck then
            if CC.hasAnyMezzedOnXTarget() then
                shouldAoE = false
            end
        end

        if shouldAoE then
            M.tryAoEAggroAbility(abilities, settings)
        end
    end

    -- Reactive taunt: only check when taunt is ready and not already taunting
    if _state.current == STATE.IDLE then
        if Aggro.canTaunt() and Aggro.isTauntReady() then
            local looseMob = Aggro.findMobAttackingGroup(myId)
            if looseMob and looseMob() then
                local dist = looseMob.Distance() or 999
                if dist <= Aggro.TAUNT_CHASE_RANGE then
                    M.startReactiveTaunt(looseMob)
                    return  -- Exit to let state machine handle it
                end
            end
        end
    end

    -- Single-target hate gen if aggro lead is low (use cache)
    if Cache.aggroLeadLow() then
        M.trySingleAggroAbility(abilities, settings)
    end
end

-- Start reactive taunt state machine
function M.startReactiveTaunt(looseMob)
    -- Save state
    local target = mq.TLO.Target
    _state.taunt.savedTargetId = (target and target() and target.ID()) or 0
    _state.taunt.targetId = looseMob.ID()
    _state.taunt.startTime = mq.gettime()
    _state.taunt.moveTimeout = mq.gettime() + 3000  -- 3 second timeout

    -- Broadcast taunt run so assisters soft-pause
    Actors.broadcastTauntRun()

    -- Transition to acquire state
    _state.current = STATE.TAUNT_ACQUIRE
end

function M.stateTauntAcquire()
    -- Target the loose mob
    local looseMob = mq.TLO.Spawn(_state.taunt.targetId)
    if not looseMob or not looseMob() then
        -- Target gone, abort
        M.finishTaunt()
        return
    end

    Targeting.targetSpawn(looseMob)

    -- Check distance
    local dist = looseMob.Distance() or 999
    if dist <= Aggro.TAUNT_RANGE then
        -- In range, go straight to execute
        _state.current = STATE.TAUNT_EXECUTE
    else
        -- Need to move, start nav
        mq.cmdf('/nav id %d', _state.taunt.targetId)
        _state.current = STATE.TAUNT_MOVING
    end
end

function M.stateTauntMoving()
    local looseMob = mq.TLO.Spawn(_state.taunt.targetId)
    if not looseMob or not looseMob() then
        -- Target gone, abort
        mq.cmd('/nav stop')
        M.finishTaunt()
        return
    end

    local dist = looseMob.Distance() or 999

    -- Check if in range
    if dist <= Aggro.TAUNT_RANGE then
        mq.cmd('/nav stop')
        _state.current = STATE.TAUNT_EXECUTE
        return
    end

    -- Check timeout
    if mq.gettime() >= _state.taunt.moveTimeout then
        mq.cmd('/nav stop')
        M.finishTaunt()
        return
    end

    -- Still moving, wait for next tick
end

function M.stateTauntExecute()
    -- Execute taunt via action executor
    Executor.executeTaunt()

    -- Transition to return state
    _state.current = STATE.TAUNT_RETURN
end

function M.stateTauntReturn()
    -- Return to saved target
    if _state.taunt.savedTargetId and _state.taunt.savedTargetId > 0 then
        mq.cmdf('/target id %d', _state.taunt.savedTargetId)
    end

    M.finishTaunt()
end

function M.finishTaunt()
    -- Broadcast taunt done so assisters resume
    Actors.broadcastTauntDone()

    -- Reset state
    _state.taunt.targetId = nil
    _state.taunt.savedTargetId = nil
    _state.current = STATE.IDLE
end

function M.tryAoEAggroAbility(abilities, settings)
    local aoe, _ = Abilities.getAggroAbilities(abilities, settings)
    local sorted = Abilities.sortByPriority(aoe)
    for _, def in ipairs(sorted) do
        -- Use action executor which handles ready checks and lockouts
        if Executor.executeAbility(def) then
            return true
        end
    end
    return false
end

function M.trySingleAggroAbility(abilities, settings)
    local _, single = Abilities.getAggroAbilities(abilities, settings)
    local sorted = Abilities.sortByPriority(single)
    for _, def in ipairs(sorted) do
        -- Use action executor which handles ready checks and lockouts
        if Executor.executeAbility(def) then
            return true
        end
    end
    return false
end

function M.handlePositioning()
    if not M.settings.TankRepositionEnabled then return end
    if not Positioning.shouldReposition() then return end

    local cx, cy = Positioning.calculateGroupCentroid()
    if not cx then return end

    -- Broadcast repositioning so assisters soft-pause
    Actors.broadcastTankRepositioning()

    -- Mark that we repositioned (updates cooldown)
    Positioning.markRepositioned()

    -- Set settle timer (non-blocking)
    _state.reposition.settleUntil = mq.gettime() + 1500
    _state.current = STATE.REPOSITION_SETTLING
end

function M.stateRepositionSettling()
    -- Check if settle time has passed
    if mq.gettime() >= _state.reposition.settleUntil then
        Actors.broadcastTankSettled()
        _state.current = STATE.IDLE
    end
    -- Otherwise, wait for next tick
end

-- Get current state (for debugging/UI)
function M.getState()
    return _state.current
end

-- Check if tank is busy (in a state machine sequence)
function M.isBusy()
    return _state.current ~= STATE.IDLE
end

return M
