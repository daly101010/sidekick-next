-- healing/config.lua
-- Configuration module for Healing Intelligence subsystem
-- Provides defaults, load/save functionality for healing settings

local mq = require('mq')

local M = {}

-------------------------------------------------------------------------------
-- Default Configuration
-------------------------------------------------------------------------------

M.defaults = {
    -- Master enable toggle
    enabled = true,

    ---------------------------------------------------------------------------
    -- Core Thresholds
    ---------------------------------------------------------------------------
    -- Emergency HP threshold - below this we use fastest available heal regardless of efficiency
    emergencyPct = 25,
    -- Minimum heal percentage - don't heal if deficit is less than this % of max HP
    minHealPct = 10,
    -- Group heal minimum count - number of injured members needed to consider group heal
    groupHealMinCount = 3,
    -- Near-dead mob percentage - if mob HP below this, skip non-emergency heals (dying soon anyway)
    nearDeadMobPct = 10,

    ---------------------------------------------------------------------------
    -- Squishy Class Handling
    ---------------------------------------------------------------------------
    -- Classes considered "squishy" (lower HP pool, need faster response)
    squishyClasses = { 'WIZ', 'ENC', 'NEC', 'MAG' },
    -- Squishy coverage percentage - heal squishies when deficit exceeds this % of heal amount
    squishyCoveragePct = 70,

    ---------------------------------------------------------------------------
    -- Scoring Presets
    -- Weights for scoring formula: score = w_deficit * deficit_coverage + w_efficiency * mana_efficiency + w_time * time_factor
    ---------------------------------------------------------------------------
    scoringPresets = {
        -- Emergency: prioritize speed, ignore efficiency
        emergency = {
            deficitWeight = 1.0,
            efficiencyWeight = 0.0,
            timeWeight = 0.8,
            overhealPenalty = 0.0,
        },
        -- Normal: balanced approach
        normal = {
            deficitWeight = 0.6,
            efficiencyWeight = 0.3,
            timeWeight = 0.4,
            overhealPenalty = 0.3,
        },
        -- Low pressure: maximize efficiency when not urgent
        lowPressure = {
            deficitWeight = 0.3,
            efficiencyWeight = 0.6,
            timeWeight = 0.2,
            overhealPenalty = 0.5,
        },
    },
    -- Active scoring preset (key into scoringPresets)
    activeScoringPreset = 'normal',

    ---------------------------------------------------------------------------
    -- Spell Ducking (Cancel cast if target healed by someone else)
    ---------------------------------------------------------------------------
    -- Enable spell ducking
    duckEnabled = true,
    -- HP threshold above which we duck (target no longer needs heal)
    duckHpThreshold = 85,
    -- Emergency threshold - never duck if target still below this HP
    duckEmergencyThreshold = 70,
    -- Minimum cast time remaining (ms) to consider ducking
    duckMinCastTimeRemaining = 500,
    -- Duck window - only duck in first N% of cast time (avoid late ducks)
    duckWindowPct = 60,

    ---------------------------------------------------------------------------
    -- HoT (Heal over Time) Behavior
    ---------------------------------------------------------------------------
    -- Enable HoT usage
    hotEnabled = true,
    -- Minimum coverage ratio for HoTs - only use if HoT will cover at least this % of deficit
    hotMinCoverageRatio = 0.3,
    -- Only apply HoTs to tanks
    hotTankOnly = true,
    -- HoT refresh window (seconds) - refresh HoT when this many seconds remain
    hotRefreshWindow = 6,
    -- Stack HoTs - allow multiple HoTs on same target
    hotAllowStacking = false,

    ---------------------------------------------------------------------------
    -- Combat Assessment / DPS Tracking
    ---------------------------------------------------------------------------
    -- Time window for damage rate calculation (seconds)
    damageWindowSec = 6,
    -- Weight for HP-based DPS estimate (direct HP changes)
    hpDpsWeight = 0.4,
    -- Weight for combat log based DPS estimate
    logDpsWeight = 0.6,
    -- Burst detection - multiplier of stddev above mean to flag as burst damage
    burstStddevMultiplier = 1.5,
    -- Minimum samples needed for DPS calculation
    dpsMinSamples = 3,
    -- Decay factor for older samples (0-1, lower = faster decay)
    dpsDecayFactor = 0.85,

    ---------------------------------------------------------------------------
    -- Pet Healing
    ---------------------------------------------------------------------------
    -- Enable pet healing
    healPetsEnabled = false,
    -- Minimum HP % before healing pets
    petHealMinPct = 40,
    -- Pet priority relative to players (0.0 = never, 1.0 = equal priority)
    petPriorityMultiplier = 0.5,
    -- Only heal group member pets (not random pets)
    petGroupOnly = true,

    ---------------------------------------------------------------------------
    -- Learning System
    ---------------------------------------------------------------------------
    -- Enable learning (track actual heal amounts)
    learningEnabled = true,
    -- Minimum casts before trusting learned values
    learningMinCasts = 5,
    -- Decay factor for older observations (exponential moving average)
    learningDecayFactor = 0.1,
    -- Maximum age (seconds) before discarding learned data on load
    learningMaxAge = 604800, -- 7 days

    ---------------------------------------------------------------------------
    -- Multi-Healer Coordination
    ---------------------------------------------------------------------------
    -- Enable coordination via Actors
    coordinationEnabled = true,
    -- Claim timeout (seconds) - how long a heal claim is valid
    claimTimeoutSec = 5.0,
    -- Overlap window (seconds) - allow overlapping claims if cast times differ by more than this
    claimOverlapWindow = 1.0,
    -- Trust remote claims (defer to other healers' claims)
    trustRemoteClaims = true,
    -- Announce own casts for coordination
    announceOwnCasts = true,

    ---------------------------------------------------------------------------
    -- Logging
    ---------------------------------------------------------------------------
    -- Enable file logging for healing decisions
    fileLogging = true,
    -- Log file path (relative to mq.configDir)
    logFilePath = 'SideKick_Healing.log',
    -- Log categories - enable/disable specific log types
    logCategories = {
        targetSelection = true,   -- Log target selection decisions
        spellSelection = true,    -- Log spell selection decisions
        ducking = true,           -- Log spell ducking events
        coordination = true,      -- Log multi-healer coordination
        learning = true,          -- Log learning updates
        dps = false,              -- Log DPS calculations (verbose)
        scoring = false,          -- Log scoring details (verbose)
        hotTracking = true,       -- Log HoT application/tracking
        emergency = true,         -- Log emergency heal decisions
    },
    -- Console log level (0=off, 1=errors, 2=warnings, 3=info, 4=debug)
    consoleLogLevel = 2,

    ---------------------------------------------------------------------------
    -- Spell Assignments
    -- Maps spell categories to spell names/lines
    -- These are populated by class-specific configuration
    ---------------------------------------------------------------------------
    spells = {
        -- Fast heals (low cast time, moderate heal)
        fast = {},
        -- Small heals (efficient, low mana cost)
        small = {},
        -- Medium heals (balanced)
        medium = {},
        -- Large heals (big heal, longer cast)
        large = {},
        -- Group heals (AE heal)
        group = {},
        -- Single target HoT
        hot = {},
        -- Light HoT (shorter duration, faster cast)
        hotLight = {},
        -- Group HoT
        groupHot = {},
    },
}

-------------------------------------------------------------------------------
-- Runtime Configuration State
-------------------------------------------------------------------------------

-- Active configuration (merged defaults + saved settings)
M.config = {}

-- Deep copy helper
local function deepCopy(orig)
    local copy
    if type(orig) == 'table' then
        copy = {}
        for k, v in pairs(orig) do
            copy[k] = deepCopy(v)
        end
    else
        copy = orig
    end
    return copy
end

-- Merge tables (source overwrites dest)
local function mergeTables(dest, source)
    for k, v in pairs(source) do
        if type(v) == 'table' and type(dest[k]) == 'table' then
            mergeTables(dest[k], v)
        else
            dest[k] = deepCopy(v)
        end
    end
end

-------------------------------------------------------------------------------
-- File Path Helpers
-------------------------------------------------------------------------------

local function getConfigPath()
    local server = 'Server'
    local charName = 'Character'

    if mq.TLO.EverQuest and mq.TLO.EverQuest.Server then
        server = mq.TLO.EverQuest.Server() or 'Server'
    end
    if mq.TLO.Me and mq.TLO.Me.CleanName then
        charName = mq.TLO.Me.CleanName() or 'Character'
    end

    return string.format('%s\\SideKick_Healing_%s_%s.lua', mq.configDir, server, charName)
end

-------------------------------------------------------------------------------
-- Serialization Helpers
-------------------------------------------------------------------------------

local function serializeValue(value, indent)
    indent = indent or ''
    local t = type(value)

    if t == 'nil' then
        return 'nil'
    elseif t == 'boolean' then
        return value and 'true' or 'false'
    elseif t == 'number' then
        return tostring(value)
    elseif t == 'string' then
        return string.format('%q', value)
    elseif t == 'table' then
        local lines = {}
        table.insert(lines, '{')
        local nextIndent = indent .. '    '

        -- Check if array-like
        local isArray = true
        local maxIndex = 0
        for k, _ in pairs(value) do
            if type(k) ~= 'number' or k < 1 or math.floor(k) ~= k then
                isArray = false
                break
            end
            if k > maxIndex then maxIndex = k end
        end
        if isArray and maxIndex > 0 then
            for i = 1, maxIndex do
                local v = value[i]
                local comma = i < maxIndex and ',' or ''
                table.insert(lines, nextIndent .. serializeValue(v, nextIndent) .. comma)
            end
        else
            local keys = {}
            for k in pairs(value) do
                table.insert(keys, k)
            end
            table.sort(keys, function(a, b)
                if type(a) == type(b) then
                    return tostring(a) < tostring(b)
                end
                return type(a) < type(b)
            end)
            for i, k in ipairs(keys) do
                local v = value[k]
                local keyStr
                if type(k) == 'string' and k:match('^[%a_][%w_]*$') then
                    keyStr = k
                else
                    keyStr = '[' .. serializeValue(k, nextIndent) .. ']'
                end
                local comma = i < #keys and ',' or ''
                table.insert(lines, nextIndent .. keyStr .. ' = ' .. serializeValue(v, nextIndent) .. comma)
            end
        end
        table.insert(lines, indent .. '}')
        return table.concat(lines, '\n')
    else
        return 'nil -- unsupported type: ' .. t
    end
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

--- Load configuration from file, merging with defaults
-- @return table The loaded configuration
function M.load()
    -- Start with defaults
    M.config = deepCopy(M.defaults)

    local path = getConfigPath()
    local file = io.open(path, 'r')
    if file then
        local content = file:read('*all')
        file:close()

        if content and content ~= '' then
            local fn, err = load('return ' .. content, 'config', 't', {})
            if fn then
                local ok, saved = pcall(fn)
                if ok and type(saved) == 'table' then
                    mergeTables(M.config, saved)
                    print(string.format('[Healing] Config loaded from %s', path))
                else
                    print(string.format('[Healing] Config parse error: %s', tostring(saved)))
                end
            else
                print(string.format('[Healing] Config load error: %s', tostring(err)))
            end
        end
    else
        print(string.format('[Healing] No config found, using defaults'))
    end

    return M.config
end

--- Save current configuration to file
-- @return boolean True if save succeeded
function M.save()
    local path = getConfigPath()
    local content = serializeValue(M.config)

    local file, err = io.open(path, 'w')
    if not file then
        print(string.format('[Healing] Config save error: %s', tostring(err)))
        return false
    end

    file:write(content)
    file:close()
    print(string.format('[Healing] Config saved to %s', path))
    return true
end

--- Get a configuration value
-- @param key string The configuration key (supports dot notation for nested keys)
-- @return any The configuration value
function M.get(key)
    if not key then return nil end

    local value = M.config
    for part in key:gmatch('[^.]+') do
        if type(value) ~= 'table' then return nil end
        value = value[part]
    end
    return value
end

--- Set a configuration value
-- @param key string The configuration key (supports dot notation for nested keys)
-- @param value any The value to set
function M.set(key, value)
    if not key then return end

    local parts = {}
    for part in key:gmatch('[^.]+') do
        table.insert(parts, part)
    end

    local target = M.config
    for i = 1, #parts - 1 do
        local part = parts[i]
        if type(target[part]) ~= 'table' then
            target[part] = {}
        end
        target = target[part]
    end

    target[parts[#parts]] = value
end

--- Reset configuration to defaults
function M.reset()
    M.config = deepCopy(M.defaults)
end

--- Get scoring weights for current combat pressure
-- @param isEmergency boolean True if in emergency healing mode
-- @param pressure number Combat pressure level (0.0 to 1.0)
-- @return table Scoring weights
function M.getScoringWeights(isEmergency, pressure)
    if isEmergency then
        return deepCopy(M.config.scoringPresets.emergency)
    elseif pressure and pressure < 0.3 then
        return deepCopy(M.config.scoringPresets.lowPressure)
    else
        return deepCopy(M.config.scoringPresets.normal)
    end
end

return M
