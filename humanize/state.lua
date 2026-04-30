-- humanize/state.lua
-- Active profile cache, recent gate-decision log, per-target rolls, RNG seeding.
--
-- Designed so consumers don't have to wire a tick(); selector lazy-refreshes
-- when consulted if the cached profile is older than REFRESH_TTL_MS.

local mq = require('mq')

local M = {}

local REFRESH_TTL_MS = 50           -- selector refresh cadence
local RECENT_LOG_CAP = 100          -- last-N gate decisions for /skfullbore debug
local IDLE_THRESHOLD_MS = 10000     -- 10s since last action -> idle profile candidate
local DWELL_MS = 800                -- hysteresis for non-emergency profile transitions

local State = {
    -- Active profile name + the time it was selected.
    activeProfile = 'off',
    activeSince = 0,

    -- Candidate profile + when the candidate first appeared (for hysteresis).
    candidateProfile = nil,
    candidateSince = 0,

    -- Last selector eval timestamp.
    lastSelectAt = 0,

    -- Manual override: nil | 'off' | 'boss'
    override = nil,

    -- Last action stamp (set by gate() callers).
    lastActionAt = 0,

    -- Recent decisions ring buffer.
    recent = {},
    recentIdx = 1,

    -- Per-target engagement rolls: { [targetId] = { stickVariant=..., engageThreshold=... } }
    targetRolls = {},

    -- Debug log toggle.
    debugLog = false,
}

-- Public constants
M.REFRESH_TTL_MS = REFRESH_TTL_MS
M.IDLE_THRESHOLD_MS = IDLE_THRESHOLD_MS
M.DWELL_MS = DWELL_MS

local _seeded = false
local function seedRng()
    if _seeded then return end
    -- mq.gettime() is high-resolution; xor with os.time for variance across process restarts.
    local t = (mq.gettime and mq.gettime() or 0)
    local s = bit32 and bit32.bxor(os.time(), t % 2147483647) or ((os.time() + t) % 2147483647)
    math.randomseed(s)
    -- discard a few values; some RNG impls produce a poor first sample after seeding
    for _ = 1, 3 do math.random() end
    _seeded = true
end

function M.now() return mq.gettime() end

function M.init()
    seedRng()
    State.activeProfile = 'off'
    State.activeSince = M.now()
    State.lastSelectAt = 0
end

function M.getActive() return State.activeProfile end

function M.setActive(name)
    if State.activeProfile ~= name then
        State.activeProfile = name
        State.activeSince = M.now()
    end
end

function M.getCandidate() return State.candidateProfile, State.candidateSince end

function M.setCandidate(name, atMs)
    State.candidateProfile = name
    State.candidateSince = atMs or M.now()
end

function M.clearCandidate()
    State.candidateProfile = nil
    State.candidateSince = 0
end

function M.shouldRefresh(nowMs)
    return (nowMs - State.lastSelectAt) >= REFRESH_TTL_MS
end

function M.markSelected(nowMs) State.lastSelectAt = nowMs end

function M.setOverride(o)
    if o == nil or o == 'off' or o == 'boss' then
        State.override = o
    end
end

function M.getOverride() return State.override end

function M.markAction(nowMs) State.lastActionAt = nowMs or M.now() end

function M.timeSinceLastAction(nowMs)
    nowMs = nowMs or M.now()
    if State.lastActionAt == 0 then return math.huge end
    return nowMs - State.lastActionAt
end

function M.recordDecision(entry)
    State.recent[State.recentIdx] = entry
    State.recentIdx = State.recentIdx + 1
    if State.recentIdx > RECENT_LOG_CAP then State.recentIdx = 1 end
end

function M.dumpRecent()
    -- Returns oldest-first array snapshot.
    local out = {}
    local n = 0
    for i = 1, RECENT_LOG_CAP do
        local idx = ((State.recentIdx - 1 + i - 1) % RECENT_LOG_CAP) + 1
        local e = State.recent[idx]
        if e then n = n + 1; out[n] = e end
    end
    return out
end

function M.setDebug(on) State.debugLog = on and true or false end
function M.debugEnabled() return State.debugLog end

-- Per-target rolls. Cleared on target change/death by the engagement module.
function M.getTargetRoll(targetId)
    if not targetId or targetId == 0 then return nil end
    return State.targetRolls[targetId]
end

function M.setTargetRoll(targetId, roll)
    if not targetId or targetId == 0 then return end
    State.targetRolls[targetId] = roll
end

function M.clearTargetRoll(targetId)
    if not targetId then return end
    State.targetRolls[targetId] = nil
end

function M.clearAllTargetRolls() State.targetRolls = {} end

return M
