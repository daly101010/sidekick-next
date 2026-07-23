-- healing/pull_monitor.lua
-- Pull Monitor - detects an inbound pull: a new XTarget hater appearing while
-- the group is out of combat, closing distance toward camp. Gives the healer a
-- window to pre-cast a HoT on the tank so it's already ticking when the mob
-- arrives (see healing/init.lua pre-pull priority).
--
-- Deliberately does NOT rely on the actors system or any sidekick-side puller
-- role: the puller is often a non-sidekick character (e.g. a bard on Medley),
-- so detection is purely from XTarget + spawn distance.

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

M.state = {
    phase = 'idle',   -- idle, inbound, landed
    mobId = 0,
    mobName = '',
    dist = 0,
    closingRate = 0,  -- units/sec toward us (EMA)
    mult = 1.0,       -- mob difficulty multiplier
    lastT = 0,
    stallSince = 0,
    ignoreMobId = 0,   -- stalled mob we've given up on (static aggro)
    ignoreUntil = 0,
}

-- Consider the pull "landed" inside this range (fight about to start)
local ENGAGE_RADIUS = 40

-- Give up on an inbound mob that stops approaching for this long (ms)
local STALL_MS = 6000

local getMobAssessor = lazy('sidekick-next.healing.mob_assessor')

local function firstHater()
    local xtCount = tonumber(mq.TLO.Me.XTarget()) or 0
    for i = 1, xtCount do
        local xt = mq.TLO.Me.XTarget(i)
        if xt and xt() and xt.ID() and xt.ID() > 0 then
            local tt = (xt.TargetType and xt.TargetType() or ''):lower()
            if tt:find('hater') then
                return xt.ID(), (xt.CleanName and xt.CleanName()) or '',
                    tonumber(xt.Distance and xt.Distance() or nil) or 999
            end
        end
    end
    return nil
end

local function reset(ignoreStalledMob)
    if ignoreStalledMob and M.state.mobId > 0 then
        -- Static aggro that never approached; don't re-trigger on it right away
        M.state.ignoreMobId = M.state.mobId
        M.state.ignoreUntil = mq.gettime() + 30000
    end
    M.state.phase = 'idle'
    M.state.mobId = 0
    M.state.mobName = ''
    M.state.closingRate = 0
    M.state.stallSince = 0
end

function M.tick()
    local now = mq.gettime()
    local s = M.state

    local inCombat = tostring(mq.TLO.Me.CombatState() or '') == 'COMBAT'
    local mobId, mobName, dist = firstHater()

    if s.phase == 'idle' then
        if mobId and mobId == s.ignoreMobId then
            if now < s.ignoreUntil then return end
            s.ignoreMobId = 0
        end
        if not inCombat and mobId and dist > ENGAGE_RADIUS then
            s.phase = 'inbound'
            s.mobId = mobId
            s.mobName = mobName
            s.dist = dist
            s.closingRate = 0
            s.lastT = now
            s.stallSince = 0

            local ma = getMobAssessor()
            s.mult = 1.0
            if ma and ma.getMobMultiplier then
                local ok, mult = pcall(ma.getMobMultiplier, mobId)
                if ok and tonumber(mult) then s.mult = tonumber(mult) end
            end
        end
        return
    end

    if s.phase == 'inbound' then
        -- Pull dropped (FD, leash, death) or mob vanished
        if not mobId then
            reset()
            return
        end
        -- Track the original mob if still present; otherwise follow the first hater
        if mobId ~= s.mobId then
            s.mobId = mobId
            s.mobName = mobName
        end

        if inCombat or dist <= ENGAGE_RADIUS then
            s.phase = 'landed'
            return
        end

        local dt = (now - s.lastT) / 1000
        if dt >= 0.5 then
            local rate = (s.dist - dist) / dt
            s.closingRate = s.closingRate == 0 and rate or (s.closingRate + 0.4 * (rate - s.closingRate))
            s.dist = dist
            s.lastT = now

            if s.closingRate <= 0.5 then
                -- Not actually approaching (static aggro, stuck mob)
                if s.stallSince == 0 then
                    s.stallSince = now
                elseif (now - s.stallSince) > STALL_MS then
                    reset(true)
                end
            else
                s.stallSince = 0
            end
        end
        return
    end

    -- landed: clear once combat ends or the hater list empties
    if s.phase == 'landed' then
        if not mobId then
            reset()
        elseif not inCombat and dist > ENGAGE_RADIUS then
            -- Mob wandered back out without engaging
            s.phase = 'inbound'
        end
    end
end

--- Is a pull currently inbound (mob approaching, fight not started)?
function M.isPullInbound()
    return M.state.phase == 'inbound' and M.state.closingRate > 0.5
end

--- Get inbound pull info
-- @return table|nil { mobId, mobName, dist, eta (sec), mult }
function M.getInbound()
    if not M.isPullInbound() then return nil end
    local s = M.state
    return {
        mobId = s.mobId,
        mobName = s.mobName,
        dist = s.dist,
        eta = s.dist / math.max(s.closingRate, 1),
        mult = s.mult,
    }
end

return M
