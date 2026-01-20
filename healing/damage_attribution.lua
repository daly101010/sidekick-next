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

return M
