-- F:/lua/sidekick-next/sk_lib.lua
-- Shared constants, types, and utilities for SideKick multi-script system

local mq = require('mq')

local M = {}

local _Core = nil
local _coreLoadedAtMs = 0
local _settingsRevision = nil

-- Version for compatibility checks
M.VERSION = '3.0.0'
M.LEASE_PROTOCOL_VERSION = 2

-- Fixed coordinator tiers. Workers never send or override these values.
-- Lower numbers run first.
M.Priority = {
    EMERGENCY = 0,
    HEALING = 1,
    RESURRECTION = 2,
    TANK = 3,
    CROWD_CONTROL = 4,
    DEBUFF = 5,
    PULL = 6,
    DPS = 7,
    BUFF = 8,
    MEDITATION = 9,
    SCRIBING = 10,
    AMBIENT = 11,
    IDLE = 99,
}
-- Internal tank action rankings may continue to use these names, but the
-- coordinator collapses all of them to the registered Tank tier.
M.Priority.TANK_RECOVERY = M.Priority.TANK
M.Priority.TANK_ENGAGE = M.Priority.TANK
M.Priority.TANK_AGGRO = M.Priority.TANK

-- Reverse lookup for coordinator diagnostics.
local _priorityNames = nil
function M.priorityName(value)
    if not _priorityNames then
        _priorityNames = {}
        for name, v in pairs(M.Priority) do _priorityNames[v] = name end
    end
    local v = tonumber(value)
    if v == nil then return tostring(value) end
    local name = _priorityNames[v]
    return name and string.format('%s(%g)', name, v) or string.format('?(%g)', v)
end

-- Mailbox names
M.Mailbox = {
    STATE = 'sk:state',
    LEASE_REQUEST = 'lease:request',
    LEASE_WITHDRAW = 'lease:withdraw',
    LEASE_RENEW = 'lease:renew',
    LEASE_RELEASE = 'lease:release',
    LEASE_RECOVERED = 'lease:recovered',
    HEARTBEAT = 'sk:hb',
    SUPERVISOR = 'sk:supervisor',
    TEAM = 'sk:team',
}

-- The single worker registry is the source of truth for scheduling,
-- supervision, routing, and UI diagnostics. `order` is a global deterministic
-- tiebreaker; it is intentionally independent of request arrival order.
M.WorkerRegistry = {
    { module = 'emergency',    script = 'sidekick-next/sk_emergency',    tier = M.Priority.EMERGENCY,    order = 1,  canPreempt = true,  enableSetting = 'DoHeals' },
    { module = 'healing',      script = 'sidekick-next/sk_healing',      tier = M.Priority.HEALING,      order = 2,  canPreempt = true,  enableSetting = 'DoHeals' },
    { module = 'cures',        script = 'sidekick-next/sk_cures',        tier = M.Priority.HEALING,      order = 3,  canPreempt = true,  enableSetting = 'DoCures' },
    { module = 'resurrection', script = 'sidekick-next/sk_resurrection', tier = M.Priority.RESURRECTION, order = 4,  canPreempt = true,  canActDead = true },
    { module = 'tank',         script = 'sidekick-next/sk_tank',         tier = M.Priority.TANK,         order = 5,  canPreempt = true },
    { module = 'cc',           script = 'sidekick-next/sk_cc',           tier = M.Priority.CROWD_CONTROL,order = 6,  enableSetting = 'MezzingEnabled' },
    { module = 'debuff',       script = 'sidekick-next/sk_debuff',       tier = M.Priority.DEBUFF,       order = 7,  enableSetting = 'DpsEnabled' },
    { module = 'pull',         script = 'sidekick-next/sk_pull',         tier = M.Priority.PULL,         order = 8 },
    { module = 'assist',       script = 'sidekick-next/sk_assist',       tier = M.Priority.DPS,          order = 9 },
    { module = 'chase',        script = 'sidekick-next/sk_chase',        tier = M.Priority.DPS,          order = 10, enableSetting = 'ChaseEnabled' },
    { module = 'resources',    script = 'sidekick-next/sk_resources',    tier = M.Priority.DPS,          order = 11 },
    { module = 'disciplines',  script = 'sidekick-next/sk_disciplines',  tier = M.Priority.DPS,          order = 12, enableSetting = 'AutoAbilitiesEnabled' },
    { module = 'items',        script = 'sidekick-next/sk_items',        tier = M.Priority.DPS,          order = 13, enableSetting = 'AutoItemsEnabled' },
    { module = 'dps',          script = 'sidekick-next/sk_dps',          tier = M.Priority.DPS,          order = 14, enableSetting = 'DpsEnabled' },
    { module = 'buffs',        script = 'sidekick-next/sk_buffs',        tier = M.Priority.BUFF,         order = 15, enableSetting = 'BuffingEnabled' },
    { module = 'meditation',   script = 'sidekick-next/sk_meditation',   tier = M.Priority.MEDITATION,   order = 16, enableSetting = 'MeditationMode' },
    { module = 'scribing',     script = 'sidekick-next/sk_scribing',     tier = M.Priority.SCRIBING,     order = 17 },
    { module = 'fidget',       script = 'sidekick-next/sk_fidget',       tier = M.Priority.AMBIENT,      order = 18 },
}

M.WorkerByModule = {}
local _workerScripts = {}
for _, spec in ipairs(M.WorkerRegistry) do
    M.WorkerByModule[spec.module] = spec
    _workerScripts[#_workerScripts + 1] = spec.script
end

function M.getWorkerSpec(moduleName)
    return M.WorkerByModule[tostring(moduleName or '')]
end

function M.getWorkerScripts()
    local result = {}
    for i, script in ipairs(_workerScripts) do result[i] = script end
    return result
end

-- Script names used for routing between multi-script modules.
M.Scripts = {
    COORDINATOR = 'sidekick-next/sk_coordinator',
    UI = { 'sidekick-next', 'sidekick-next/init' },
    WORKERS = M.getWorkerScripts(),
}

-- Timing constants (milliseconds)
M.Timing = {
    COORDINATOR_TICK_MS = 50,
    STATE_BROADCAST_MS = 200,
    -- Background EQ clients can advance Lua at roughly one frame per second.
    -- Keep snapshots valid across that expected cadence; the separate 10s
    -- coordinator watchdog remains the hard failure boundary.
    STATE_TTL_MS = 5000,
    MODULE_HEARTBEAT_MS = 500,
    SUPERVISOR_HEARTBEAT_MS = 500,
    SUPERVISOR_ABSENCE_MS = 10000,
    LEASE_REQUEST_TTL_MS = 2000,
    LEASE_REQUEST_REFRESH_MS = 500,
    LEASE_TTL_MS = 5000,
    LEASE_RENEW_MS = 500,
    LEASE_REVOCATION_GRACE_MS = 2000,
    LEASE_RECOVERY_TTL_MS = 5000,
    WARMUP_MS = 500,
    COALESCE_MS = 20,

    -- Watchdog thresholds
    MODULE_CRASH_MS = 10000,        -- 10s of in-game heartbeat silence = module presumed crashed
    COORDINATOR_ABSENCE_MS = 10000, -- 10s without state = coordinator presumed crashed
    RESTART_COOLDOWN_MS = 15000,    -- 15s between restart attempts for same module
    WATCHDOG_CHECK_MS = 1000,       -- 1s between watchdog scans
    RESTART_STABLE_MS = 60000,      -- Reset crash-loop count only after 60s healthy
}

-- Watchdog limits
M.MAX_MODULE_RESTARTS = 3  -- Max restart attempts per module per session

-- Action kinds
M.ActionKind = {
    CAST_SPELL = 'cast_spell',
    USE_AA = 'use_aa',
    USE_DISC = 'use_disc',
    USE_ITEM = 'use_item',
    USE_SKILL = 'use_skill',
}

--- Generate a unique request ID.
-- @param module string Module name
-- @param counter number Monotonic counter
-- @param workerSessionId string Worker process session
-- @return string Unique request ID
function M.generateRequestId(module, counter, workerSessionId)
    return string.format('%s:%s:%d', tostring(module or ''),
        tostring(workerSessionId or ''), tonumber(counter) or 0)
end

--- Get current time in milliseconds
-- @return number Current time in ms
function M.getTimeMs()
    return mq.gettime()
end

--- Return MacroQuest's current status for a Lua script.
--- This queries MQ2Lua directly and does not depend on Actors delivery.
-- @param scriptName string Canonical script name, e.g. sidekick-next/sk_healing
-- @return string STARTING, RUNNING, PAUSED, EXITED, or empty when unavailable
function M.getLuaScriptStatus(scriptName)
    if not scriptName or scriptName == '' then return '' end
    local status = M.safeTLO(function()
        return mq.TLO.Lua.Script(tostring(scriptName)).Status()
    end, '')
    return tostring(status or ''):upper()
end

--- True when MQ2Lua confirms that a script currently has a live process.
-- @param scriptName string
-- @return boolean
function M.isLuaScriptRunning(scriptName)
    local status = M.getLuaScriptStatus(scriptName)
    return status == 'STARTING' or status == 'RUNNING' or status == 'PAUSED'
end

--- True if the parent SideKick UI script is running (under either name it
--- can be launched as). Workers use this as an orphan watchdog: a forced
--- `/lua stop sidekick-next` kills the parent at its current mq.delay, so
--- init.lua's post-main Supervisor.stop() never runs and the fleet would
--- otherwise live on headless.
function M.isUiRunning()
    for _, name in ipairs(M.Scripts.UI or {}) do
        if M.isLuaScriptRunning(name) then return true end
    end
    return false
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

--- Read MacroQuest's current game state without allowing a transient TLO
--- failure to terminate a long-running SideKick script.
-- @return string Uppercase game-state name, or an empty string if unavailable
function M.getGameState()
    local state = M.safeTLO(function()
        return mq.TLO.MacroQuest.GameState()
    end, '')
    return tostring(state or ''):upper()
end

--- True while MacroQuest reports that the character is changing zones.
--- GameState can remain INGAME during part of a zone transition, so callers
--- must also consult Me.Zoning before touching world/character TLOs.
function M.isZoning()
    if M.getGameState() ~= 'INGAME' then return false end
    return M.safeTLO(function()
        return mq.TLO.Me and mq.TLO.Me.Zoning and mq.TLO.Me.Zoning() == true
    end, false) == true
end

--- True only while the local character is fully available for automation.
function M.isInGame()
    if M.getGameState() ~= 'INGAME' then return false end
    return M.safeTLO(function()
        return not (mq.TLO.Me and mq.TLO.Me.Zoning and mq.TLO.Me.Zoning() == true)
    end, false) == true
end

--- Read the persisted global automation pause flag.
--- Coordinated workers are separate Lua processes, so they cannot rely on the
--- UI script's in-memory Core.Settings table. Reload the shared config on a
--- short throttle so /sidekick pause/resume propagates to every worker.
---@param force boolean|nil
---@return boolean
function M.refreshSettings(revision)
    if revision ~= nil and _Core and _settingsRevision == revision then return _Core.Settings end
    do
        local ok, core = pcall(require, 'sidekick-next.utils.core')
        if ok and core then
            _Core = core
            if core.load then pcall(core.load) end
            local loggerOk, Logger = pcall(require, 'sidekick-next.utils.logger')
            if loggerOk and Logger and Logger.configure then
                Logger.configure(core.Settings)
            end
            _coreLoadedAtMs = M.getTimeMs()
            _settingsRevision = revision
            -- Humanize applies its persisted knobs (master flag, subsystem
            -- toggles, profile tuning) only once at load. Re-apply after every
            -- settings reload so /sk_humanize on|off and subsystem changes made
            -- in the UI process reach workers at runtime, not just at startup.
            local H = package.loaded['sidekick-next.humanize']
            if H and H.applySettings then pcall(H.applySettings) end
        end
    end
    return _Core and _Core.Settings or nil
end

function M.getSettings()
    if not _Core then M.refreshSettings() end
    return _Core and _Core.Settings or nil
end

function M.isAutomationPaused(force)
    if force == true or not _Core then M.refreshSettings() end
    return _Core and _Core.Settings and _Core.Settings.AutomationPaused == true or false
end

--- States that represent leaving the character rather than a transient zone.
--- Unknown/empty states are deliberately non-terminal because MQ TLOs can be
--- briefly unavailable while zoning.
function M.isTerminalGameState(state)
    state = tostring(state or M.getGameState()):upper()
    return state == 'CHARSELECT'
        or state == 'PRECHARSELECT'
        or state == 'SERVERSELECT'
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

local _cachedMyName = ''
local _cachedMyServer = ''
local _myNameRefreshedAt = 0
local _myServerRefreshedAt = 0
local IDENTITY_TTL_MS = 5000

--- Get my character name. Preserve the last valid identity while zoning so
--- Actors heartbeats remain attributable to this character.
--- Memoized: identity is session-stable, and these getters sit on per-message
--- hot paths (isLocalModuleMessage runs for every drained actor message) where
--- per-call TLO reads measurably dominate coordinator tick time.
-- @return string
-- Diagnostic: hit/miss counts for the identity memo (read via /sk_coord bench).
M._identityStats = { hits = 0, misses = 0 }

function M.getMyName()
    local now = mq.gettime()
    if _cachedMyName ~= '' and (now - _myNameRefreshedAt) < IDENTITY_TTL_MS then
        M._identityStats.hits = M._identityStats.hits + 1
        return _cachedMyName
    end
    M._identityStats.misses = M._identityStats.misses + 1
    if M.isMeValid() then
        local name = M.safeTLO(function() return mq.TLO.Me.CleanName() end, '') or ''
        if name ~= '' and name ~= 'NULL' then
            _cachedMyName = tostring(name)
            _myNameRefreshedAt = now
        end
    end
    return _cachedMyName
end

--- Character field for local-only actor addresses. The launcher's post office
--- fans script-addressed messages out to EVERY client running that script;
--- adding the local character name keeps coordinator<->worker control traffic
--- on this client only. Returns nil (= leave unaddressed) while identity is
--- unknown so early messages still deliver rather than silently matching
--- nothing.
-- @return string|nil
function M.localCharacter()
    local name = M.getMyName()
    if name ~= '' then return name end
    return nil
end

--- Get current server name. Preserve the last valid value while zoning for
--- the same reason as getMyName(). Memoized like getMyName.
-- @return string
function M.getMyServer()
    local now = mq.gettime()
    if _cachedMyServer ~= '' and (now - _myServerRefreshedAt) < IDENTITY_TTL_MS then
        return _cachedMyServer
    end
    local server = M.safeTLO(function() return mq.TLO.EverQuest.Server() end, '') or ''
    if server ~= '' and server ~= 'NULL' then
        _cachedMyServer = tostring(server)
        _myServerRefreshedAt = now
    end
    return _cachedMyServer
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

--- Return the local character states that prevent starting or owning an action.
--- Keep this TLO sampling in normal ticks; Actor callbacks consume copied state only.
-- @return table { incapacitated, reason, stunned, mezzed, silenced, feared }
function M.getIncapacitationState()
    local result = {
        incapacitated = false,
        reason = nil,
        stunned = false,
        mezzed = false,
        silenced = false,
        feared = false,
    }

    if not M.isMeValid() then
        return result
    end

    local me = mq.TLO.Me
    result.stunned = M.safeTLO(function() return me.Stunned() end, false) == true
    result.mezzed = M.safeNum(function() return me.Mezzed.ID() end, 0) > 0
        or M.safeTLO(function() return me.Mezzed() end, false) == true
    result.silenced = M.safeTLO(function() return me.Silenced() end, false) == true
    result.feared = M.safeTLO(function() return me.Feared() end, false) == true

    if result.stunned then
        result.reason = 'stunned'
    elseif result.mezzed then
        result.reason = 'mezzed'
    elseif result.silenced then
        result.reason = 'silenced'
    elseif result.feared then
        result.reason = 'feared'
    end
    result.incapacitated = result.reason ~= nil
    return result
end

--- True when the local character cannot safely begin or retain an action claim.
-- @return boolean, string|nil
function M.isIncapacitated()
    local state = M.getIncapacitationState()
    return state.incapacitated, state.reason
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

-- Kept for compatibility with older callers. The unified logger now owns
-- effective global and per-module levels.
M.LogLevel = 1
local _unifiedLogger = nil
local _moduleLoggers = {}

--- Log with prefix
-- @param level string 'verbose', 'debug', 'info', 'warn', 'error'
-- @param module string Module name
-- @param fmt string Format string
-- @param ... any Format args
function M.log(level, module, fmt, ...)
    if not _unifiedLogger then
        local ok, logger = pcall(require, 'sidekick-next.utils.logger')
        if not ok or not logger then return end
        _unifiedLogger = logger
    end
    module = tostring(module or 'unknown')
    local logger = _moduleLoggers[module]
    if not logger then
        logger = _unifiedLogger.new(module, 1)
        _moduleLoggers[module] = logger
    end
    local writer = logger[tostring(level or 'debug'):lower()] or logger.debug
    writer(fmt, ...)
end

return M
