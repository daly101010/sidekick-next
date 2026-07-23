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
-- Absolute HP layer: mob_hp_estimator learns real HP pools from damage messages,
-- and spell_damage_tracker learns what my nukes hit for. Together they power
-- overkill checks (don't spend a 30k nuke on 4k of remaining HP) - see overkillOk.

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

local getCombatAssessor = lazy('sidekick-next.healing.combat_assessor')
local getMobAssessor = lazy('sidekick-next.healing.mob_assessor')
local getCore = lazy('sidekick-next.utils.core')
local getHpEstimator = lazy('sidekick-next.utils.mob_hp_estimator')
local getSpellDamage = lazy('sidekick-next.utils.spell_damage_tracker')

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

--- Get the estimated remaining absolute HP for a mob (learned from damage messages)
-- @param mobId number Spawn ID
-- @return number|nil remainingHP (nil when no estimate yet)
-- @return number confidence Estimator weight (higher = more HP% observed)
function M.getRemainingHP(mobId)
    local est = getHpEstimator()
    if not est or not est.getRemainingHP then return nil, 0 end
    local ok, hp, weight = pcall(est.getRemainingHP, mobId)
    if not ok then return nil, 0 end
    return hp, weight or 0
end

--- Would this spell's expected damage be mostly wasted on this mob?
-- Skips a nuke when its typical hit exceeds the mob's estimated remaining HP by
-- the overkill factor - falling through to smaller/faster spells in the rotation.
-- Fails open when either the spell's damage or the mob's HP is still unknown.
-- @param mobId number Spawn ID
-- @param spellName string|nil Spell name (no-op when nil)
-- @return boolean True if the cast is NOT overkill (ok to cast)
function M.overkillOk(mobId, spellName)
    if not enabled() then return true end
    if not spellName or spellName == '' then return true end

    local SpellDamage = getSpellDamage()
    if not SpellDamage or not SpellDamage.getExpected then return true end
    local okE, expected = pcall(SpellDamage.getExpected, spellName)
    if not okE or not expected or expected <= 0 then return true end

    local remaining = M.getRemainingHP(mobId)
    if not remaining or remaining <= 0 then return true end

    local factor = tonumber(getSetting('DpsOverkillFactor', 1.5)) or 1.5
    return expected <= remaining * factor
end

--- Is a nuke worth starting on this mob?
-- Viable when the mob outlives cast time plus a landing margin (travel/latency),
-- and - when spellName is given and damage data exists - the hit isn't overkill.
-- @param mobId number Spawn ID
-- @param castTimeSec number|nil Cast time in seconds (default DpsDefaultNukeCastTime)
-- @param spellName string|nil Spell name for the overkill check (optional)
-- @return boolean
function M.nukeViable(mobId, castTimeSec, spellName)
    if not enabled() then return true end
    castTimeSec = tonumber(castTimeSec) or tonumber(getSetting('DpsDefaultNukeCastTime', 3.0)) or 3.0
    local margin = tonumber(getSetting('DpsNukeLandMargin', 1.0)) or 1.0
    if not M.willLive(mobId, castTimeSec + margin) then return false end
    return M.overkillOk(mobId, spellName)
end

--- Is a rain spell worth starting on this mob's location?
-- Rains deliver damage in waves over several seconds AFTER landing, so their
-- horizon is cast + margin + a payoff window for the waves to connect.
-- @param mobId number Spawn ID
-- @param castTimeSec number|nil Cast time in seconds (default DpsDefaultNukeCastTime)
-- @return boolean
function M.rainViable(mobId, castTimeSec)
    if not enabled() then return true end
    castTimeSec = tonumber(castTimeSec) or tonumber(getSetting('DpsDefaultNukeCastTime', 3.0)) or 3.0
    local margin = tonumber(getSetting('DpsNukeLandMargin', 1.0)) or 1.0
    local payoff = tonumber(getSetting('DpsRainPayoffSec', 4)) or 4
    return M.willLive(mobId, castTimeSec + margin + payoff)
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
