local mq = require('mq')
local Actors = require('sidekick-next.utils.actors_coordinator')
local Positioning = require('sidekick-next.utils.positioning')
local Targeting = require('sidekick-next.utils.targeting')
local CasterAssist = require('sidekick-next.automation.caster_assist')

local M = {}

-- Track recently skipped targets to avoid log spam
local _skippedTargetLog = {}  -- [spawnId] = lastLogTime
local SKIP_LOG_COOLDOWN = 5.0  -- Only log once per 5 seconds per target

M.enabled = false
M.primaryTargetId = nil    -- From tank broadcasts
M.currentTargetId = nil    -- Current engaged target
M.tankId = nil             -- Tank spawn ID (from broadcasts)
M.tankName = nil           -- Tank name (from broadcasts)
M.settings = nil
M.lastTankBroadcast = 0    -- Track when we last received tank data

local _Core = nil
local _CombatAssist = nil
local _Chase = nil

local function stopEngagement()
    if mq.TLO.Me and mq.TLO.Me.Combat and mq.TLO.Me.Combat() then
        mq.cmd('/attack off')
    end
    local stickActive = false
    pcall(function()
        stickActive = mq.TLO.Stick and mq.TLO.Stick.Active and mq.TLO.Stick.Active()
    end)
    if stickActive then
        mq.cmd('/squelch /stick off')
    end
end

function M.init(opts)
    opts = opts or {}
    _Core = opts.Core
    _CombatAssist = opts.CombatAssist
    _Chase = opts.Chase
    M.settings = opts.settings
    CasterAssist.init(opts)
end

function M.setEnabled(val)
    M.enabled = val and true or false
    CasterAssist.setEnabled(val)

    if _Core and _Core.set then
        _Core.set('AssistEnabled', M.enabled)
    elseif _Core and _Core.Settings then
        _Core.Settings.AssistEnabled = M.enabled
    end

    if not M.enabled then
        if _CombatAssist and _CombatAssist.stop then
            _CombatAssist.stop()
        else
            stopEngagement()
        end
        if _Chase then
            _Chase.setEnabled(false, { auto = true })
        end
        -- Clear target tracking when disabled
        M.currentTargetId = nil
    else
        if _Chase and not _Chase.state.userPaused then
            _Chase.setEnabled(true, { auto = true })
        end
    end
end

--- Update primary target from tank broadcasts via Actors
-- @return boolean True if tank data is fresh (< 5 seconds old)
function M.updateTargetFromTank()
    local tankState = Actors.getTankState()
    if not tankState then return false end

    M.tankId = tankState.tankId or M.tankId
    M.tankName = tankState.tankName or M.tankName

    -- Update primary from tank
    if tankState.primaryTargetId then
        M.primaryTargetId = tankState.primaryTargetId
        M.lastTankBroadcast = os.clock()
        return true
    end

    -- Check if tank data is stale (> 5 seconds)
    return (os.clock() - M.lastTankBroadcast) < 5
end

--- Check if we should engage the current target based on settings
-- @param settings table Settings containing engage conditions
-- @return boolean True if engage conditions are met
function M.shouldEngage(settings)
    local targetId = M.currentTargetId
    if not targetId or targetId == 0 then return false end

    local spawn = mq.TLO.Spawn(targetId)
    if not spawn or not spawn() then return false end
    if spawn.Dead and spawn.Dead() then return false end

    -- Safe targeting check (KS prevention)
    local isSafe, reason = Targeting.isSafeTarget(targetId, settings)
    if not isSafe then
        -- Log skipped target (with cooldown to avoid spam)
        local now = os.clock()
        local lastLog = _skippedTargetLog[targetId] or 0
        if (now - lastLog) >= SKIP_LOG_COOLDOWN then
            _skippedTargetLog[targetId] = now
            local name = spawn.CleanName() or 'Unknown'
            -- Debug echo disabled
        end
        return false
    end

    local condition = settings and settings.AssistEngageCondition or 'hp'

    if condition == 'hp' then
        local hp = spawn.PctHPs and spawn.PctHPs() or 100
        local threshold = settings and settings.AssistEngageHpThreshold or 97
        return hp <= threshold
    elseif condition == 'tank_aggro' then
        -- Engage only when the target is actually targeting the tank.
        local tankId = tonumber(M.tankId) or 0
        if tankId <= 0 then
            local tankName = tostring(M.tankName or '')
            if tankName ~= '' and mq and mq.TLO and mq.TLO.Spawn then
                local s = mq.TLO.Spawn('pc =' .. tankName)
                if s and s() and s.ID then
                    local ok, v = pcall(function() return s.ID() end)
                    if ok then
                        tankId = tonumber(v) or 0
                    end
                end
            end
        end

        if tankId <= 0 then
            return false
        end

        local totId = 0
        if spawn.TargetOfTarget and spawn.TargetOfTarget.ID then
            local ok, v = pcall(function() return spawn.TargetOfTarget.ID() end)
            if ok then totId = tonumber(v) or 0 end
        end

        return totId == tankId
    end

    -- Unknown engage condition: default to engage (legacy behavior).
    return true
end

--- Engage the specified target with stick and attack
-- @param targetId number The spawn ID to engage
-- @param settings table Settings containing stick command
function M.engageTarget(targetId, settings)
    if not targetId or targetId == 0 then return end

    local current = mq.TLO.Target
    local currentId = current and current() and current.ID() or 0

    if currentId ~= targetId then
        -- Wait for the target swap to actually land before sticking/attacking.
        -- /target id N does not take effect immediately; without the verify,
        -- /stick attaches to whatever was previously targeted and /attack on
        -- attacks the wrong mob.
        mq.cmdf('/target id %d', targetId)
        mq.delay(200, function()
            local t = mq.TLO.Target
            return t and t() and t.ID() == targetId
        end)
        local t = mq.TLO.Target
        if not (t and t() and t.ID() == targetId) then
            return  -- target swap failed; don't stick/attack on the wrong mob
        end
    end

    -- Don't stick if in soft pause (tank repositioning/taunt run)
    if not Positioning.isInSoftPause() then
        local stickCmd = settings and settings.StickCommand or '/stick snaproll behind 10 moveback uw'
        mq.cmd(stickCmd)
    end

    -- Attack
    if not mq.TLO.Me.Combat() then
        mq.cmd('/attack on')
    end
end

--- Run tank-broadcast assisted targeting (new system)
-- @param settings table Settings
-- @return boolean True if we handled targeting via tank broadcasts
function M.runTankBroadcastAssist(settings)
    -- Get tank's target from actors
    local hasTankData = M.updateTargetFromTank()
    if not hasTankData then return false end

    local assistMode = settings and settings.AssistTargetMode or 'sticky'

    -- Determine current target based on mode
    if assistMode == 'sticky' then
        -- Stay on current target until it dies
        if M.currentTargetId and M.currentTargetId > 0 then
            local spawn = mq.TLO.Spawn(M.currentTargetId)
            if not spawn or not spawn() or (spawn.Dead and spawn.Dead()) then
                -- Current target dead, pick up primary
                M.currentTargetId = M.primaryTargetId
            end
        else
            -- No current target, use primary
            M.currentTargetId = M.primaryTargetId
        end
    else
        -- Follow mode: always match tank's primary
        M.currentTargetId = M.primaryTargetId
    end

    -- Check engage conditions and engage
    if M.currentTargetId and M.shouldEngage(settings) then
        M.engageTarget(M.currentTargetId, settings)
    else
        stopEngagement()
    end

    return true
end

function M.tick(settings)
    settings = settings or (_Core and _Core.Settings) or M.settings
    if not M.enabled then return end

    -- Route pure casters to CasterAssist
    if CasterAssist.isPureCaster() then
        CasterAssist.setEnabled(true)
        CasterAssist.tick(settings)
        return
    end

    local combatMode = settings and settings.CombatMode or 'off'

    -- Combat Mode 'assist': use tank-broadcast targeting (new system)
    -- This is mutually exclusive with legacy CombatAssist to avoid conflicts
    if combatMode == 'assist' then
        local usedTankAssist = M.runTankBroadcastAssist(settings)
        -- If tank-broadcast assist handled it, don't run legacy
        -- Only fall back to legacy if no tank data available
        if usedTankAssist then
            return
        end
    end

    -- Legacy mode: delegate to CombatAssist for traditional MA-following
    -- This runs when:
    -- 1. CombatMode is 'off' or 'tank' (not 'assist')
    -- 2. Or CombatMode is 'assist' but no tank broadcast data available
    if _CombatAssist and _CombatAssist.tick then
        _CombatAssist.tick()
    end
end

return M
