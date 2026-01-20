-- healing/damage_attribution.lua
local mq = require('mq')

local M = {}

local Config = nil

-- Combat timeout tracking
local _lastDamageEvent = 0
local COMBAT_TIMEOUT = 5  -- seconds
local WINDOW_DURATION = 3  -- seconds for DPS calculation

-- Per-target damage attribution
local _targetDamage = {}  -- [targetId] = { sources = {}, sourceCount, totalDps, ... }

-- AE damage tracking (same mob hitting multiple targets)
local _aeDamage = {}  -- [mobId] = { targets = {}, isAE, totalDps }

-- Mob name-to-ID resolution cache
local _mobNameCache = {}  -- [mobName] = { id, lastSeen }

function M.init(config)
    Config = config
    COMBAT_TIMEOUT = Config and Config.combatTimeoutSec or 5
    WINDOW_DURATION = Config and Config.dpsWindowSec or 3
    _targetDamage = {}
    _aeDamage = {}
    _mobNameCache = {}
    _lastDamageEvent = 0
end

-- Refresh mob name cache from XTarget
local function refreshMobCache()
    local now = mq.gettime()
    local me = mq.TLO.Me
    if not me or not me() then return end

    local xtCount = tonumber(me.XTarget()) or 0
    for i = 1, xtCount do
        local xt = me.XTarget(i)
        if xt and xt() and xt.ID() and xt.ID() > 0 then
            local name = xt.CleanName() or xt.Name()
            local id = xt.ID()
            if name and id then
                _mobNameCache[name] = { id = id, lastSeen = now }
            end
        end
    end
end

-- Resolve attacker name to mob ID
local function resolveMobId(attackerName)
    if not attackerName then return nil end

    local cached = _mobNameCache[attackerName]
    if cached then return cached.id end

    -- Fallback: direct spawn lookup
    local spawn = mq.TLO.Spawn('npc "' .. attackerName .. '"')
    if spawn and spawn() and spawn.ID() > 0 then
        return spawn.ID()
    end

    return nil
end

return M
