-- F:/lua/sidekick-next/sk_lib.lua
-- Shared constants, types, and utilities for SideKick multi-script system

local mq = require('mq')

local M = {}

-- Version for compatibility checks
M.VERSION = '2.0.0'

-- Priority tiers (lower = higher priority)
M.Priority = {
    EMERGENCY = 0,
    HEALING = 1,
    RESURRECTION = 2,
    DEBUFF = 3,
    DPS = 4,
    IDLE = 5,
    BUFF = 6,        -- OOC buffs
    MEDITATION = 7,  -- Lowest priority (sit/stand)
}

-- Interrupt thresholds (seconds remaining to let cast finish)
-- Lower threshold = cast can be interrupted sooner
-- 999 = effectively never interrupt based on time
M.InterruptThreshold = {
    [0] = 0.0,   -- Emergency: immediate
    [1] = 0.5,   -- Healing: 0.5s
    [2] = 1.0,   -- Resurrection: 1.0s
    [3] = 1.0,   -- Debuff: 1.0s
    [4] = 999,   -- DPS: never interrupt (lowest combat priority)
    [5] = 999,   -- Idle: never interrupt
    [6] = 1.0,   -- Buff: can be interrupted (OOC, higher priorities like DPS can interrupt)
    [7] = 999,   -- Meditation: never interrupt (no casts)
}

-- Mailbox names
M.Mailbox = {
    STATE = 'sk:state',
    CLAIM = 'sk:claim',
    RELEASE = 'sk:release',
    INTERRUPT = 'sk:interrupt',
    HEARTBEAT = 'sk:hb',
    NEED = 'sk:need',
}

-- Script names used for routing between multi-script modules
M.Scripts = {
    COORDINATOR = 'sidekick-next/sk_coordinator',
    UI = { 'sidekick-next', 'sidekick-next/init' },
}

-- Timing constants (milliseconds)
M.Timing = {
    COORDINATOR_TICK_MS = 50,
    STATE_BROADCAST_MS = 200,
    STATE_TTL_MS = 750,
    MODULE_HEARTBEAT_MS = 500,
    CLAIM_DEFAULT_TTL_MS = 1000,
    TARGET_CLAIM_TTL_MS = 2000,
    WARMUP_MS = 500,
    COALESCE_MS = 20,

    -- Watchdog thresholds
    MODULE_CRASH_MS = 10000,        -- 10s without heartbeat = module presumed crashed (zone loads can stall 3-5s)
    COORDINATOR_ABSENCE_MS = 10000, -- 10s without state = coordinator presumed crashed
    RESTART_COOLDOWN_MS = 15000,    -- 15s between restart attempts for same module
    WATCHDOG_CHECK_MS = 1000,       -- 1s between watchdog scans
}

-- Watchdog limits
M.MAX_MODULE_RESTARTS = 3  -- Max restart attempts per module per session

-- Action kinds
M.ActionKind = {
    CAST_SPELL = 'cast_spell',
    USE_AA = 'use_aa',
    USE_ITEM = 'use_item',
}

-- Claim types
M.ClaimType = {
    ACTION = 'action',  -- target + cast together (default)
    TARGET = 'target',  -- target only
    CAST = 'cast',      -- cast only
}

--- Generate a unique claim ID
-- @param module string Module name
-- @param counter number Monotonic counter
-- @return string Unique claim ID
function M.generateClaimId(module, counter)
    return string.format('%s_%d_%d', module, os.time(), counter)
end

--- Get current time in milliseconds
-- @return number Current time in ms
function M.getTimeMs()
    return mq.gettime()
end

--- Check if a timestamp is stale
-- @param sentAtMs number When the state was sent
-- @param ttlMs number Time-to-live in ms
-- @return boolean True if stale
function M.isStale(sentAtMs, ttlMs)
    local now = M.getTimeMs()
    return (now - sentAtMs) > ttlMs
end

--- Safe TLO access with fallback
-- @param fn function Function that accesses TLO
-- @param fallback any Fallback value on error
-- @return any Result or fallback
function M.safeTLO(fn, fallback)
    local ok, result = pcall(fn)
    if not ok then return fallback end
    return result ~= nil and result or fallback
end

--- Safe number conversion from TLO
-- @param fn function Function that returns a number
-- @param fallback number Fallback value
-- @return number
function M.safeNum(fn, fallback)
    local ok, v = pcall(fn)
    if not ok then return fallback end
    return tonumber(v) or fallback
end

--- Check if Me TLO is valid
-- @return boolean
function M.isMeValid()
    return mq.TLO.Me and mq.TLO.Me() ~= nil
end

--- Check whether the local character cannot act because they are dead/hovering.
-- @return boolean
function M.isSelfDeadOrHovering()
    if not M.isMeValid() then return true end
    if M.safeTLO(function() return mq.TLO.Me.Hovering() end, false) == true then
        return true
    end
    return M.safeTLO(function() return mq.TLO.Me.Dead() end, false) == true
end

--- Get my character name
-- @return string
function M.getMyName()
    if not M.isMeValid() then return '' end
    return M.safeTLO(function() return mq.TLO.Me.CleanName() end, '') or ''
end

--- Get current server name normalized the same way config paths do.
-- @return string
function M.getMyServer()
    return M.safeTLO(function() return mq.TLO.EverQuest.Server() end, '') or ''
end

--- Build identity fields for local module/coordinator messages.
-- These are intentionally simple strings so older receivers can ignore them.
-- @return table
function M.getMessageIdentity()
    return {
        ownerName = M.getMyName(),
        ownerServer = M.getMyServer(),
    }
end

--- Get current zone short name
-- @return string
function M.getZone()
    return M.safeTLO(function() return mq.TLO.Zone.ShortName() end, '') or ''
end

--- Check if currently casting
-- @return boolean
function M.isCasting()
    if not M.isMeValid() then return false end
    local casting = M.safeTLO(function() return mq.TLO.Me.Casting() end, nil)
    local castText = tostring(casting or '')
    if castText ~= '' and castText:upper() ~= 'NULL' then
        return true
    end

    if M.safeNum(function() return mq.TLO.Me.CastTimeLeft() end, 0) > 0 then
        return true
    end

    return M.safeTLO(function()
        local wnd = mq.TLO.Window and mq.TLO.Window('CastingWindow')
        return wnd and wnd.Open and wnd.Open()
    end, false) == true
end

--- Get remaining cast time in seconds
-- @return number Seconds remaining, 0 if not casting
function M.getCastTimeRemaining()
    if not M.isCasting() then return 0 end
    local ms = M.safeNum(function() return mq.TLO.Me.CastTimeLeft() end, 0)
    return ms / 1000
end

--- Check if in combat (XTarget haters OR auto-attack active)
-- Me.Combat() only returns true when auto-attack is on, which is always false
-- for casters/healers. Check XTarget hater count for actual combat detection.
-- @return boolean
function M.inCombat()
    if not M.isMeValid() then return false end
    -- Auto-attack active counts as combat
    if M.safeTLO(function() return mq.TLO.Me.Combat() end, false) == true then
        return true
    end
    -- Check XTarget for aggressive mobs (reliable for all classes)
    local xtCount = M.safeNum(function() return mq.TLO.Me.XTarget() end, 0)
    for i = 1, xtCount do
        local xt = mq.TLO.Me.XTarget(i)
        if xt and xt() and xt.ID and xt.ID() and xt.ID() > 0 then
            local targetType = M.safeTLO(function() return xt.TargetType() end, '') or ''
            if targetType:lower():find('hater') then
                return true
            end
        end
    end
    return false
end

--- Get group member count
-- @return number
function M.getGroupCount()
    return M.safeNum(function() return mq.TLO.Group.Members() end, 0)
end

--- Get main assist ID
-- @return number Spawn ID or 0
function M.getMainAssistId()
    local ma = mq.TLO.Group.MainAssist
    if not ma or not ma() then return 0 end
    return M.safeNum(function() return ma.ID() end, 0)
end

-- Log levels: 0=none, 1=error, 2=warn, 3=info, 4=debug
M.LogLevel = 1  -- Set to 1 to only show errors, 4 for all messages

local logLevelValue = {
    error = 1,
    warn = 2,
    info = 3,
    debug = 4,
}

--- Log with prefix
-- @param level string 'debug', 'info', 'warn', 'error'
-- @param module string Module name
-- @param fmt string Format string
-- @param ... any Format args
function M.log(level, module, fmt, ...)
    local levelVal = logLevelValue[level] or 4
    if levelVal > M.LogLevel then
        return
    end
    -- In-game echo disabled
end

return M
