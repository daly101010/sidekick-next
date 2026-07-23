-- utils/dps_intelligence.lua
-- DPS Intelligence - Time-to-die (TTD) reasoning for damage spell decisions
--
-- Mobs don't expose absolute HP (Spawn.MaxHPs() is percent-scale for NPCs), so
-- damage viability works in seconds-to-die instead: combat_assessor measures each
-- XTarget mob's HP% loss rate, and TTD = remaining % / rate. This answers the two
-- questions raw pctHPs thresholds can't:
--   * Nuke: will the mob still be alive when my cast lands? (nukeViable)
--   * DoT:  will the mob live long enough for the DoT to pay off? (dotViable)
--
-- Extension point: getTTD returns a second value 'measured'|'estimated'. A future
-- absolute-HP estimator (damage-message parsing) can add overkill checks on top.

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

local getCombatAssessor = lazy('sidekick-next.healing.combat_assessor')
local getMobAssessor = lazy('sidekick-next.healing.mob_assessor')
local getCore = lazy('sidekick-next.utils.core')

-- Fallback kill rate when no measured data exists yet (fight start): assume a
-- normal group mob dies at ~2% HP/sec, scaled down by the mob difficulty
-- multiplier (raid/named mobs have far bigger pools, so they die slower).
local FALLBACK_PCT_PER_SEC = 2.0

local function getSetting(key, default)
    local Core = getCore()
    local v = Core and Core.Settings and Core.Settings[key]
    if v == nil then return default end
    return v
end

local function enabled()
    return getSetting('UseDpsIntelligence', true) ~= false
end

--- Get estimated time-to-die for a mob
-- @param mobId number Spawn ID
-- @return number|nil TTD in seconds (nil if mob unknown/dead)
-- @return string source 'measured' (HP decline tracking) or 'estimated' (heuristic)
function M.getTTD(mobId)
    mobId = tonumber(mobId) or 0
    if mobId <= 0 then return nil, 'unknown' end

    -- Measured: HP%-decline tracking from combat_assessor (XTarget mobs)
    local ca = getCombatAssessor()
    if ca and ca.getMobTTKById then
        local ok, ttk = pcall(ca.getMobTTKById, mobId)
        if ok and ttk and ttk > 0 then
            return ttk, 'measured'
        end
    end

    -- Fallback: estimate from remaining HP% and mob difficulty tier
    local spawn = mq.TLO.Spawn(mobId)
    if not spawn or not spawn() then return nil, 'unknown' end

    local okHp, pctHP = pcall(function() return spawn.PctHPs() end)
    pctHP = okHp and tonumber(pctHP) or nil
    if not pctHP then return nil, 'unknown' end

    local mult = 1.0
    local ma = getMobAssessor()
    if ma and ma.getMobMultiplier then
        local okM, m = pcall(ma.getMobMultiplier, mobId)
        if okM and tonumber(m) then mult = tonumber(m) end
    end

    return (pctHP / FALLBACK_PCT_PER_SEC) * mult, 'estimated'
end

--- Will the mob still be alive N seconds from now?
-- Fails open (true) when disabled or no data - never blocks casting blind.
-- @param mobId number Spawn ID
-- @param seconds number Horizon in seconds
-- @return boolean
function M.willLive(mobId, seconds)
    if not enabled() then return true end
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then return true end

    local ttd = M.getTTD(mobId)
    if not ttd then return true end
    return ttd > seconds
end

--- Is a nuke worth starting on this mob?
-- Viable when the mob outlives cast time plus a landing margin (travel/latency).
-- @param mobId number Spawn ID
-- @param castTimeSec number|nil Cast time in seconds (default DpsDefaultNukeCastTime)
-- @return boolean
function M.nukeViable(mobId, castTimeSec)
    if not enabled() then return true end
    castTimeSec = tonumber(castTimeSec) or tonumber(getSetting('DpsDefaultNukeCastTime', 3.0)) or 3.0
    local margin = tonumber(getSetting('DpsNukeLandMargin', 1.0)) or 1.0
    return M.willLive(mobId, castTimeSec + margin)
end

--- Is a DoT worth applying to this mob?
-- Viable when the mob will live at least DpsDotBreakevenPct% of the DoT's duration
-- (a DoT that ticks for under half its duration usually loses to a nuke).
-- @param mobId number Spawn ID
-- @param durationSec number|nil Full DoT duration in seconds (default DpsDefaultDotDuration)
-- @return boolean
function M.dotViable(mobId, durationSec)
    if not enabled() then return true end
    durationSec = tonumber(durationSec) or tonumber(getSetting('DpsDefaultDotDuration', 24)) or 24
    local breakevenPct = tonumber(getSetting('DpsDotBreakevenPct', 50)) or 50
    return M.willLive(mobId, durationSec * (breakevenPct / 100))
end

return M
