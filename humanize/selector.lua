-- humanize/selector.lua
-- Picks the active profile from world state, with hysteresis on transitions.
-- Reads TLO directly when consulted; refresh cadence gated by state.shouldRefresh.

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local State = require('sidekick-next.humanize.state')

-- Lazy: avoid pulling healing/* during humanize bootstrap if healing isn't loaded yet.
local getMobAssessor = lazy.once('sidekick-next.healing.mob_assessor')
local getHealingConfig = lazy.once('sidekick-next.healing.config')
local getSkLib = lazy.once('sidekick-next.sk_lib')

local M = {}

local function isFlagOn()
    local cfg = _G.SIDEKICK_NEXT_CONFIG
    return cfg and cfg.HUMANIZE_BEHAVIOR == true
end

local function getEmergencyPct()
    local cfg = getHealingConfig()
    if cfg and cfg.emergencyPct then return cfg.emergencyPct end
    return 25
end

local function anyGroupMemberCritical(emergencyPct)
    local groupSize = mq.TLO.Group.Members() or 0
    -- Index 0 is self in MQ Group TLO.
    for i = 0, groupSize do
        local member = mq.TLO.Group.Member(i)
        if member and member() then
            local hp = member.PctHPs() or 100
            if hp <= emergencyPct then return true end
        end
    end
    -- Check self too
    local meHp = mq.TLO.Me.PctHPs() or 100
    if meHp <= emergencyPct then return true end
    return false
end

local function targetIsNamedOrRaid()
    local tid = mq.TLO.Target.ID() or 0
    if tid == 0 then return false end
    local ma = getMobAssessor()
    if not ma then return false end
    -- Heuristic: getMobMultiplier returns >= 1.3 for named/elevated mobs.
    local mult = nil
    if ma.getMobMultiplier then
        local ok, v = pcall(ma.getMobMultiplier, tid)
        if ok then mult = v end
    end
    if type(mult) == 'number' and mult >= 1.3 then return true end
    return false
end

local function inCombat()
    local lib = getSkLib()
    if lib and lib.inCombat then
        local ok, v = pcall(lib.inCombat)
        if ok then return v == true end
    end
    -- Fallback if sk_lib unavailable.
    local me = mq.TLO.Me
    if not (me and me()) then return false end
    local cs = me.CombatState and me.CombatState() or ''
    return cs == 'COMBAT'
end

-- Compute the candidate profile from current world state.
-- Does not apply hysteresis; that's done in resolve().
function M.computeCandidate()
    if not isFlagOn() then return 'off' end

    local override = State.getOverride()
    if override == 'off' then return 'off' end
    if override == 'boss' then return 'named' end

    local emergencyPct = getEmergencyPct()
    if anyGroupMemberCritical(emergencyPct) then return 'emergency' end

    if targetIsNamedOrRaid() then return 'named' end

    if inCombat() then return 'combat' end

    if State.timeSinceLastAction() > State.IDLE_THRESHOLD_MS then return 'idle' end

    return 'farming'
end

-- Resolve the active profile, applying hysteresis. Call from gate() / perturbChoice().
-- emergency promotion is instant; demotion is gated by DWELL_MS.
function M.resolve()
    local now = State.now()
    if not State.shouldRefresh(now) then
        return State.getActive()
    end
    State.markSelected(now)

    local candidate = M.computeCandidate()
    local active = State.getActive()

    -- Instant promotion to/from emergency, off (kill switch), and override-driven states.
    if candidate == 'emergency' or candidate == 'off' or active == 'off' then
        State.setActive(candidate)
        State.clearCandidate()
        return candidate
    end

    -- Override boss -> always immediate.
    local override = State.getOverride()
    if override then
        State.setActive(candidate)
        State.clearCandidate()
        return candidate
    end

    -- Same as active: clear pending candidate.
    if candidate == active then
        State.clearCandidate()
        return active
    end

    -- Different from active: require dwell.
    local pending, since = State.getCandidate()
    if pending ~= candidate then
        State.setCandidate(candidate, now)
        return active
    end
    if (now - since) >= State.DWELL_MS then
        State.setActive(candidate)
        State.clearCandidate()
        return candidate
    end
    return active
end

return M
