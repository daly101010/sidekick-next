-- F:/lua/sidekick-next/sk_buffs.lua
-- Buff module for SideKick multi-script system
-- Priority 6: OOC buff casting through the single local coordinator lease
-- Maintains cross-character coordination via Actors

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local ActionExecutor = require('sidekick-next.utils.action_executor')
local lazy = require('sidekick-next.utils.lazy_require')
local Logger = require('sidekick-next.utils.logger')

-- Create module instance
local module = ModuleBase.create('buffs', lib.Priority.BUFF)

local debugLog = require('sidekick-next.utils.debug_log').module('sk_buffs', 'SK_BUFFS')

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

local BUFF_TICK_INTERVAL = 0.5             -- Casting tick interval (500ms)
local DEFAULT_REBUFF_WINDOW = 60           -- Default seconds before expiry to rebuff
local BUFF_CHECK_INTERVAL = 60.0           -- How often to recheck buff status on targets
local BUFF_DEFS_REFRESH_INTERVAL = 5.0     -- Refresh buff definitions if empty
local BUFF_DEFS_PERIODIC_REFRESH = 5.0     -- Periodic refresh to pick up spell set changes
local BUFF_GEM_HOLD_WINDOW_MS = 8000       -- Milliseconds to hold buff gem after mem
local BUFF_POST_MEM_SETTLE_MS = 1200       -- Let spellbook/cast gem UI settle before casting
local BUFF_MEMORIZE_TIMEOUT_MS = 20000     -- Bound memorization + spell-ready wait
local BUFF_PRECAST_TIMEOUT_MS = 30000      -- Includes extra time for the spellbook to close
local BUFF_CAST_START_TIMEOUT_MS = 4000    -- Bound waiting for /cast to actually begin
local BUFF_CAST_TIMEOUT_MS = 30000         -- Bound a cast that never reports completion
local BUFF_FAILURE_BACKOFF_MS = 5000       -- Retry transient failures promptly
local BUFF_FAILURE_BACKOFF_MAX_MS = 30000  -- Never hide a needed buff for minutes
local BUFF_SPELLSET_LEASE_MS = 6000        -- Pause spellset enforcement while hotswapping reserved gem
local GROUP_CAST_COOLDOWN = 6.0            -- Cooldown to avoid immediate re-cast of group spells

-------------------------------------------------------------------------------
-- Internal State
-------------------------------------------------------------------------------

local _coreLoaded = false
local _pendingAction = nil
local _pendingReason = nil
local _lastBuffScanReason = 'not_scanned'
local _lastBuffTick = 0
local _lastBuffDefsRefresh = 0
local _initialScanComplete = false
local _lastInitialScanAttempt = 0
local _selfName = ''
local _buffDebugEnabled = false
local _diagThrottle = {}
local _traceThrottle = {}
local _lastSpellsetLeaseWriteMs = 0
local _lastSpellBookCloseAttemptMs = 0
local _lastStandAttemptMs = 0
local _memEventsRegistered = false
local _buffMemEvent = {
    active = false,
    requestedSpell = '',
    beginSpell = '',
    beginAtMs = 0,
    endSpell = '',
    endAtMs = 0,
    abortAtMs = 0,
    pendingBookClose = false,
}

-- Cross-character buff coordination is a separate domain from the local
-- coordinator lease.  Reserve the target/category with peers before asking the
-- local coordinator for its one lease, then retain that reservation until the
-- local action is finalized.
local _actorBuffClaim = {
    targetId = 0,
    category = nil,
    acquired = false,
}

-- Buff definitions from spell set
local _buffDefinitions = {}
local groupBuffCandidates

-- Gem hot-swap state
local _buffGemSwap = {
    active = false,
    reservedGem = 0,
    originalSpell = '',
    requestedSpell = '',
    lastRequestAt = 0,
    lastMemAt = 0,
}

-- Per-category failure state. A single spell that cannot be memorized or
-- become ready must not monopolize the coordinator's cast ownership.
local _buffFailures = {}

-- Active buff cast state
local _activeBuff = {
    category = nil,
    spellName = nil,
    targetId = nil,
    startedAtMs = 0,
    waitReason = nil,
    state = nil,  -- 'memorizing', 'waiting_ready', 'cast_starting', 'casting', or nil
}

-- Group cast cooldowns
local _lastGroupCastAt = {}

-------------------------------------------------------------------------------
-- Lazy-load Dependencies
-------------------------------------------------------------------------------

local getCore = lazy('sidekick-next.utils.core')
local getCache = lazy('sidekick-next.utils.runtime_cache')
local getSpellEngine = lazy('sidekick-next.utils.spell_engine')
local getConditionBuilder = lazy('sidekick-next.ui.condition_builder')
local getBuffLogger = lazy('sidekick-next.automation.buff_logger')

local _SpellsetManager = nil
local function getSpellsetManager()
    if not _SpellsetManager then
        local ok, sm = pcall(require, 'sidekick-next.utils.spellset_manager')
        if ok then
            if not sm.initialized and sm.init then
                sm.init()
            end
            _SpellsetManager = sm
        end
    end
    return _SpellsetManager
end

local getBuff = lazy('sidekick-next.automation.buff')
local getSpellsetMemorize = lazy('sidekick-next.utils.spellset_memorize')
local getSpellEvents = lazy('sidekick-next.utils.spell_events')
local traceLog

local function actorClaimCoordinates(action)
    if type(action) ~= 'table' then return 0, nil end
    local targetId = tonumber(action.needTargetId) or tonumber(action.targetId) or 0
    local category = tostring(action.category or '')
    if targetId <= 0 or category == '' then return 0, nil end
    return targetId, category
end

local function actorClaimMatches(action)
    local targetId, category = actorClaimCoordinates(action)
    return targetId > 0
        and targetId == tonumber(_actorBuffClaim.targetId)
        and category == tostring(_actorBuffClaim.category or '')
end

local function releaseActorBuffClaim(reason)
    local targetId = tonumber(_actorBuffClaim.targetId) or 0
    local category = _actorBuffClaim.category
    if targetId > 0 and category and _actorBuffClaim.acquired then
        local Buff = getBuff()
        if Buff and Buff.releaseClaim then
            pcall(Buff.releaseClaim, targetId, category)
        end
        traceLog('info', 'coordination',
            'actor_claim_release_' .. tostring(category), 0,
            'Released peer buff reservation: target=%d category=%s reason=%s',
            targetId, tostring(category), tostring(reason or 'finalized'))
    end
    _actorBuffClaim.targetId = 0
    _actorBuffClaim.category = nil
    _actorBuffClaim.acquired = false
end

local function acquireActorBuffClaim(action)
    local targetId, category = actorClaimCoordinates(action)
    if targetId <= 0 or not category then return false, 'invalid_actor_claim' end

    local Buff = getBuff()
    if actorClaimMatches(action) then
        if _actorBuffClaim.acquired and Buff and Buff.renewClaim then
            local ok, renewed = pcall(Buff.renewClaim, targetId, category)
            if ok and renewed == true then return true end
        elseif _actorBuffClaim.acquired then
            return true
        end
        -- The local peer reservation aged out. Reacquire it before retaining
        -- or requesting a local coordinator lease.
        _actorBuffClaim.acquired = false
    else
        releaseActorBuffClaim('action_changed')
    end

    -- Keep the worker usable if peer Actors are unavailable, matching the
    -- previous best-effort behavior. When the coordination API is present it
    -- must grant the domain reservation before local lease admission.
    if not (Buff and Buff.claimBuff) then
        _actorBuffClaim.targetId = targetId
        _actorBuffClaim.category = category
        _actorBuffClaim.acquired = true
        return true
    end

    local ok, acquired = pcall(Buff.claimBuff, targetId, category)
    if not ok or acquired ~= true then
        return false, ok and 'peer_claimed' or ('actor_claim_error:' .. tostring(acquired))
    end

    _actorBuffClaim.targetId = targetId
    _actorBuffClaim.category = category
    _actorBuffClaim.acquired = true
    traceLog('info', 'coordination',
        'actor_claim_acquire_' .. tostring(category), 0,
        'Reserved buff with peers before local lease: target=%d category=%s',
        targetId, tostring(category))
    return true
end

local function renewActorBuffClaim()
    local targetId = tonumber(_actorBuffClaim.targetId) or 0
    local category = _actorBuffClaim.category
    if targetId <= 0 or not category then return false end
    if not _actorBuffClaim.acquired then return false end

    local Buff = getBuff()
    if not (Buff and Buff.renewClaim) then return true end
    local ok, renewed = pcall(Buff.renewClaim, targetId, category)
    return ok and renewed == true
end

-------------------------------------------------------------------------------
-- Helper Functions
-------------------------------------------------------------------------------

local function buffDebugEnabled()
    return _buffDebugEnabled or Logger.wouldLog('buffs', 'debug')
end

local function diagLog(key, intervalSec, fmt, ...)
    if not buffDebugEnabled() then return end

    local now = os.clock()
    key = tostring(key or 'diag')
    intervalSec = tonumber(intervalSec) or 0
    if intervalSec > 0 and (now - (_diagThrottle[key] or 0)) < intervalSec then return end
    _diagThrottle[key] = now

    local msg
    if select('#', ...) > 0 then
        local ok, formatted = pcall(string.format, fmt, ...)
        msg = ok and formatted or tostring(fmt)
    else
        msg = tostring(fmt)
    end

    debugLog('[diag] %s', msg)

    local BuffLogger = getBuffLogger()
    if BuffLogger then
        if BuffLogger.init then BuffLogger.init({ level = 'debug', enabled = true }) end
        if BuffLogger.info then BuffLogger.info('diagnostic', '%s', msg) end
    end
end

traceLog = function(level, category, key, intervalSec, fmt, ...)
    local now = os.clock()
    key = tostring(key or category or 'trace')
    intervalSec = tonumber(intervalSec) or 0
    if intervalSec > 0 and (now - (_traceThrottle[key] or 0)) < intervalSec then return end
    _traceThrottle[key] = now

    local msg
    if select('#', ...) > 0 then
        local ok, formatted = pcall(string.format, fmt, ...)
        msg = ok and formatted or tostring(fmt)
    else
        msg = tostring(fmt)
    end

    local BuffLogger = getBuffLogger()
    if BuffLogger then
        if BuffLogger.init then BuffLogger.init({ level = buffDebugEnabled() and 'debug' or 'info', enabled = true }) end
        local writer = BuffLogger[level or 'info'] or BuffLogger.info
        if writer then writer(category or 'trace', '%s', msg) end
    end

    -- The unified logger owns normal console/file routing. Preserve the legacy
    -- runtime-only debug command as a fallback when the persisted module level
    -- would otherwise suppress the line.
    local unifiedLevel = (level == 'warn' or level == 'error') and level or 'debug'
    if _buffDebugEnabled and not Logger.wouldLog('buffs', unifiedLevel) then
        local color = level == 'error' and '\ar' or (level == 'warn' and '\ay' or '\at')
        pcall(function()
            printf('%s[SK Buffs][%s][%s]\ax %s', color,
                tostring(level or 'info'):upper(), tostring(category or 'trace'), msg)
        end)
    end

    if level == 'warn' then
        lib.log('warn', module.name, '%s', msg)
    elseif level == 'error' then
        lib.log('error', module.name, '%s', msg)
    elseif buffDebugEnabled() then
        lib.log('debug', module.name, '%s', msg)
    end
end

local function spellTraceInfo(spellName, spellId)
    local inBook = false
    if spellName and spellName ~= '' then
        local me = mq.TLO.Me
        if me and me() and me.Book then
            local ok, known = pcall(function()
                local bookSpell = me.Book(spellName)
                return bookSpell and bookSpell() and true or false
            end)
            inBook = (not ok) or known == true
        end
    end
    local info = {
        spellName = tostring(spellName or ''),
        spellId = tostring(spellId or ''),
        targetType = '',
        subcategory = '',
        duration = '',
        mana = '',
        inBook = tostring(inBook),
    }
    if spellName and spellName ~= '' then
        local spell = mq.TLO.Spell(spellName)
        if spell and spell() then
            pcall(function() info.targetType = tostring(spell.TargetType and spell.TargetType() or '') end)
            pcall(function() info.subcategory = tostring(spell.Subcategory and spell.Subcategory() or '') end)
            pcall(function() info.duration = tostring(spell.Duration and spell.Duration() or '') end)
            pcall(function() info.mana = tostring(spell.Mana and spell.Mana() or '') end)
        end
    end
    return string.format('spell="%s" id=%s targetType="%s" subcategory="%s" duration=%s mana=%s inBook=%s',
        info.spellName, info.spellId, info.targetType, info.subcategory, info.duration, info.mana, info.inBook)
end

local function countBuffDefinitions()
    local count = 0
    for _ in pairs(_buffDefinitions) do count = count + 1 end
    return count
end

local function normalizeSpellName(name)
    return tostring(name or ''):lower():gsub('%s+rk%.%s*%a+$', ''):gsub('%s+rk%.%s*%d+$', ''):gsub('%s+', ' '):match('^%s*(.-)%s*$') or ''
end

local function ownsMemorizationEvent(spell, allowEmptySpell)
    if not _buffGemSwap.active then return false end

    local requested = normalizeSpellName(_buffMemEvent.requestedSpell ~= ''
        and _buffMemEvent.requestedSpell or _buffGemSwap.requestedSpell)
    if requested == '' then return false end

    local requestAgeMs = lib.getTimeMs() - (_buffGemSwap.lastRequestAt or 0)
    if requestAgeMs < 0 or requestAgeMs > 12000 then return false end

    local observed = normalizeSpellName(spell)
    if observed == '' then return allowEmptySpell == true end
    return observed == requested
        or observed:find(requested, 1, true) ~= nil
        or requested:find(observed, 1, true) ~= nil
end

local function registerMemorizationEvents()
    if _memEventsRegistered then return end
    local SpellEvents = getSpellEvents()
    if not (SpellEvents and SpellEvents.registerEvents) then return end

    SpellEvents.onMemBegin = function(spell)
        if not ownsMemorizationEvent(spell, false) then
            traceLog('info', 'action', 'external_mem_event_begin', 1,
                'Manual/external memorization begin observed; buff worker will not claim it: spell=%s',
                tostring(spell))
            return
        end
        _buffMemEvent.active = true
        _buffMemEvent.beginSpell = tostring(spell or '')
        _buffMemEvent.beginAtMs = lib.getTimeMs()
        _buffMemEvent.endSpell = ''
        _buffMemEvent.endAtMs = 0
        _buffMemEvent.abortAtMs = 0
        traceLog('info', 'action', 'mem_event_begin', 0,
            'Memorization event begin: spell=%s requested=%s',
            tostring(spell), tostring(_buffMemEvent.requestedSpell))
    end

    SpellEvents.onMemEnd = function(spell)
        if not ownsMemorizationEvent(spell, false) then
            traceLog('info', 'action', 'external_mem_event_end', 1,
                'Manual/external memorization completed; leaving spellbook and gems to the user: spell=%s',
                tostring(spell))
            return
        end
        _buffMemEvent.active = false
        _buffMemEvent.endSpell = tostring(spell or '')
        _buffMemEvent.endAtMs = lib.getTimeMs()
        _buffMemEvent.pendingBookClose = true
        _buffGemSwap.lastMemAt = _buffMemEvent.endAtMs
        traceLog('info', 'action', 'mem_event_end', 0,
            'Memorization event end: spell=%s requested=%s',
            tostring(spell), tostring(_buffMemEvent.requestedSpell))
    end

    SpellEvents.onMemAbort = function()
        if not ownsMemorizationEvent(nil, true) then
            traceLog('info', 'action', 'external_mem_event_abort', 1,
                'Manual/external memorization abort observed; buff worker ignored it')
            return
        end
        _buffMemEvent.active = false
        _buffMemEvent.abortAtMs = lib.getTimeMs()
        traceLog('warn', 'action', 'mem_event_abort', 0,
            'Memorization event abort: requested=%s', tostring(_buffMemEvent.requestedSpell))
    end

    SpellEvents.registerEvents()
    _memEventsRegistered = true
end

local function memorizationEventPending(spellName)
    local requested = normalizeSpellName(_buffMemEvent.requestedSpell)
    local wanted = normalizeSpellName(spellName)
    if requested == '' or wanted == '' or requested ~= wanted then return false end
    if _buffMemEvent.abortAtMs and _buffMemEvent.abortAtMs > (_buffMemEvent.beginAtMs or 0) then return false end

    local ended = normalizeSpellName(_buffMemEvent.endSpell)
    if ended ~= '' and (ended == wanted or wanted:find(ended, 1, true) or ended:find(wanted, 1, true)) then
        return false
    end

    local elapsedSinceRequest = lib.getTimeMs() - (_buffGemSwap.lastRequestAt or 0)
    if _buffMemEvent.active and elapsedSinceRequest < 8000 then
        return true
    end
    if elapsedSinceRequest < 2500 then
        return true
    end

    return false
end

local function holdSpellsetMemorizer(reason, ttlMs)
    local nowMs = lib.getTimeMs()
    ttlMs = ttlMs or BUFF_SPELLSET_LEASE_MS

    -- Cross-script lease: sk_buffs and the main SideKick spellset memorizer
    -- run in separate Lua states, so a module-level flag is not enough.
    -- Use epoch seconds so the value is comparable across Lua processes.
    if (nowMs - (_lastSpellsetLeaseWriteMs or 0)) >= 1000 then
        _lastSpellsetLeaseWriteMs = nowMs
        local leasePath = string.format('%s/SideKick_buff_gem_lease.txt', tostring(mq.configDir or 'config'))
        local fh = io.open(leasePath, 'w')
        if fh then
            fh:write(string.format('%d %s\n', os.time() + math.max(1, math.ceil(ttlMs / 1000)), tostring(reason or 'buff_hotswap')))
            fh:close()
        end
    end

    local SpellsetMemorize = getSpellsetMemorize()
    if SpellsetMemorize and SpellsetMemorize.suspend then
        SpellsetMemorize.suspend(ttlMs, reason or 'buff_hotswap')
    end
end

local function clearSpellsetMemorizerHold()
    local leasePath = string.format('%s/SideKick_buff_gem_lease.txt', tostring(mq.configDir or 'config'))
    pcall(os.remove, leasePath)

    local SpellsetMemorize = getSpellsetMemorize()
    if SpellsetMemorize and SpellsetMemorize.clearSuspend then
        SpellsetMemorize.clearSuspend()
    end
end

local function commandEcho(fmt, ...)
    local msg
    if select('#', ...) > 0 then
        local ok, formatted = pcall(string.format, fmt, ...)
        msg = ok and formatted or tostring(fmt)
    else
        msg = tostring(fmt)
    end
    pcall(function() printf('\ag[SK Buffs]\ax %s', msg) end)
end

local function dumpBuffDefinitions()
    local count = countBuffDefinitions()
    traceLog('info', 'dump', 'dump_header', 0,
        'Buff dump: definitions=%d lastReason=%s active=%s:%s state=%s wait=%s failureCount=%d',
        count, tostring(_lastBuffScanReason), tostring(_activeBuff.category), tostring(_activeBuff.spellName),
        tostring(_activeBuff.state), tostring(_activeBuff.waitReason), (function()
            local failures = 0
            for _ in pairs(_buffFailures) do failures = failures + 1 end
            return failures
        end)())
    local sorted = {}
    for category, def in pairs(_buffDefinitions) do
        table.insert(sorted, { category = category, def = def, priority = def.priority or 999 })
    end
    table.sort(sorted, function(a, b)
        if a.priority == b.priority then return tostring(a.category) < tostring(b.category) end
        return a.priority < b.priority
    end)
    for _, entry in ipairs(sorted) do
        local def = entry.def
        local failure = _buffFailures[entry.category]
        traceLog('info', 'dump', 'dump_' .. tostring(entry.category), 0,
            'Buff definition: category=%s priority=%s targetRule=%s rebuffWindow=%s failureReason=%s retryInMs=%s %s',
            tostring(entry.category), tostring(def.priority), tostring(def.buffTarget and def.buffTarget.type or 'group'),
            tostring(def.rebuffWindow), tostring(failure and failure.reason or ''),
            tostring(failure and math.max(0, (failure.retryAtMs or 0) - lib.getTimeMs()) or ''),
            spellTraceInfo(def.spellName, def.spellId))
    end
end

local function clearBuffTrackingCache()
    local categories = {}
    for category in pairs(_buffDefinitions) do
        categories[category] = true
    end

    local myId = lib.safeNum(function() return mq.TLO.Me.ID() end, 0)
    local ids = {}
    for _, candidate in ipairs(groupBuffCandidates(myId)) do
        local id = tonumber(candidate.id) or 0
        if id > 0 then ids[id] = true end
    end

    local Buff = getBuff()
    local Cache = getCache()
    for id in pairs(ids) do
        for category in pairs(categories) do
            if Buff then
                if Buff.localBuffs and Buff.localBuffs[id] then Buff.localBuffs[id][category] = nil end
                if Buff.pendingBuffs and Buff.pendingBuffs[id] then Buff.pendingBuffs[id][category] = nil end
                if Buff.localClaims and Buff.localClaims[id] then Buff.localClaims[id][category] = nil end
            end
            if Cache and Cache.buffState and Cache.buffState[id] then
                Cache.buffState[id][category] = nil
            end
        end
        if Buff then
            if Buff.localBuffs and Buff.localBuffs[id] and not next(Buff.localBuffs[id]) then Buff.localBuffs[id] = nil end
            if Buff.pendingBuffs and Buff.pendingBuffs[id] and not next(Buff.pendingBuffs[id]) then Buff.pendingBuffs[id] = nil end
            if Buff.localClaims and Buff.localClaims[id] and not next(Buff.localClaims[id]) then Buff.localClaims[id] = nil end
        end
        if Cache and Cache.buffState and Cache.buffState[id] and not next(Cache.buffState[id]) then
            Cache.buffState[id] = nil
        end
    end

    traceLog('info', 'command', 'clearcache', 0,
        'Cleared local buff tracking cache: ids=%d categories=%d',
        (function() local n = 0 for _ in pairs(ids) do n = n + 1 end return n end)(),
        (function() local n = 0 for _ in pairs(categories) do n = n + 1 end return n end)())
end

local function ensureCoreLoaded()
    if not _coreLoaded then
        local Core = getCore()
        if Core and Core.load then
            Core.load()
        end
        _coreLoaded = true
    end
end

local function syncSettings()
    ensureCoreLoaded()
    local Core = getCore()
    return Core and Core.Settings or {}
end

local function getNumGems()
    local me = mq.TLO.Me
    if not (me and me()) then return 0 end
    return tonumber(me.NumGems()) or 0
end

local function getReservedBuffGem()
    local numGems = getNumGems()
    if numGems <= 0 then return 0 end
    return numGems
end

local function getGemSpellName(gemNum)
    local me = mq.TLO.Me
    if not (me and me()) then return '' end
    if gemNum <= 0 then return '' end
    local gem = me.Gem(gemNum)
    if gem and gem() then
        return gem.Name and gem.Name() or ''
    end
    return ''
end

local function isWindowOpen(name)
    if not name or name == '' then return false end
    return lib.safeTLO(function()
        local wnd = mq.TLO.Window(name)
        return wnd and wnd.Open and wnd.Open() == true
    end, false) == true
end

local function closeSpellBookIfOpen(reason)
    if not isWindowOpen('SpellBookWnd') then return false end

    local now = lib.getTimeMs()
    if (now - (_lastSpellBookCloseAttemptMs or 0)) < 750 then return true end
    _lastSpellBookCloseAttemptMs = now

    traceLog('info', 'action', 'close_spellbook_' .. tostring(reason or 'unknown'), 1,
        'Closing spellbook before buff cast: reason=%s', tostring(reason or 'unknown'))

    -- rgmercs uses the window TLO method directly; this avoids relying on
    -- skin-specific button names and avoids Escape hitting the wrong window.
    lib.safeTLO(function()
        local wnd = mq.TLO.Window('SpellBookWnd')
        if wnd and wnd.Open and wnd.Open() and wnd.DoClose then
            wnd.DoClose()
        end
        return true
    end, false)
    return true
end

local function manualSpellBookOpen()
    if not isWindowOpen('SpellBookWnd') then return false end
    if _buffGemSwap.active then return false end
    if _buffMemEvent.active == true then return false end
    return true
end

local function getSpellId(spellName)
    if not spellName then return nil end
    local spell = mq.TLO.Spell(spellName)
    if spell and spell() and spell.ID then
        return tonumber(spell.ID()) or nil
    end
    return nil
end

local function buildNameQuery(spellName)
    if not spellName or spellName == '' then return nil end
    return string.format('name "%s"', spellName)
end

local function tloPresent(accessor)
    local ok, value = pcall(accessor)
    if not (ok and value) then return false end
    local okValue, present = pcall(function() return value() end)
    return okValue and present and true or false
end

local function actorHasBuffBySpell(actor, spellName, spellId)
    if not actor then return false end

    if spellId then
        if tloPresent(function() return actor.FindBuff and actor.FindBuff('id ' .. spellId) end) then return true end
        if tloPresent(function() return actor.FindSong and actor.FindSong('id ' .. spellId) end) then return true end
        if tloPresent(function() return actor.Buff and actor.Buff('id ' .. spellId) end) then return true end
        if tloPresent(function() return actor.Song and actor.Song('id ' .. spellId) end) then return true end
    end

    local query = buildNameQuery(spellName)
    if query then
        if tloPresent(function() return actor.FindBuff and actor.FindBuff(query) end) then return true end
        if tloPresent(function() return actor.FindSong and actor.FindSong(query) end) then return true end
    end

    if spellName and spellName ~= '' then
        if tloPresent(function() return actor.Buff and actor.Buff(spellName) end) then return true end
        if tloPresent(function() return actor.Song and actor.Song(spellName) end) then return true end
    end

    return false
end

local function buffProbe(actor, spellName, spellId)
    local probe = {
        findBuffId = false,
        findSongId = false,
        buffId = false,
        songId = false,
        findBuffName = false,
        findSongName = false,
        buffName = false,
        songName = false,
    }
    if not actor then return probe end

    if spellId then
        probe.findBuffId = tloPresent(function() return actor.FindBuff and actor.FindBuff('id ' .. spellId) end)
        probe.findSongId = tloPresent(function() return actor.FindSong and actor.FindSong('id ' .. spellId) end)
        probe.buffId = tloPresent(function() return actor.Buff and actor.Buff('id ' .. spellId) end)
        probe.songId = tloPresent(function() return actor.Song and actor.Song('id ' .. spellId) end)
    end

    local query = buildNameQuery(spellName)
    if query then
        probe.findBuffName = tloPresent(function() return actor.FindBuff and actor.FindBuff(query) end)
        probe.findSongName = tloPresent(function() return actor.FindSong and actor.FindSong(query) end)
    end

    if spellName and spellName ~= '' then
        probe.buffName = tloPresent(function() return actor.Buff and actor.Buff(spellName) end)
        probe.songName = tloPresent(function() return actor.Song and actor.Song(spellName) end)
    end

    return probe
end

local function probeSummary(probe)
    return string.format('findBuffId=%s findSongId=%s buffId=%s songId=%s findBuffName=%s findSongName=%s buffName=%s songName=%s',
        tostring(probe and probe.findBuffId),
        tostring(probe and probe.findSongId),
        tostring(probe and probe.buffId),
        tostring(probe and probe.songId),
        tostring(probe and probe.findBuffName),
        tostring(probe and probe.findSongName),
        tostring(probe and probe.buffName),
        tostring(probe and probe.songName))
end

local function actorHasTriggeredEffect(actor, spellName)
    if not actor or not spellName or spellName == '' then return false end
    local spell = mq.TLO.Spell(spellName)
    if not (spell and spell()) then return false end

    local okCount, rawCount = pcall(function()
        return spell.NumEffects and spell.NumEffects() or 0
    end)
    local numEffects = okCount and tonumber(rawCount or 0) or 0
    for i = 1, numEffects do
        local okTrigger, trigger = pcall(function()
            return spell.Trigger and spell.Trigger(i) or nil
        end)
        if not okTrigger then trigger = nil end
        local okPresent, triggerPresent = pcall(function()
            return trigger and trigger()
        end)
        if okPresent and triggerPresent then
            local okId, rawId = pcall(function()
                return trigger.ID and trigger.ID() or 0
            end)
            local triggerId = okId and tonumber(rawId or 0) or 0
            local okName, rawName = pcall(function()
                return trigger.Name and trigger.Name() or ''
            end)
            local triggerName = okName and tostring(rawName or '') or ''
            if triggerId > 0 and actorHasBuffBySpell(actor, triggerName, triggerId) then
                return true
            end
        end
    end

    return false
end

local function getCachedBuffState(targetId, category, rebuffWindow)
    local id = tonumber(targetId) or 0
    if id <= 0 or not category then return nil end

    local Cache = getCache()
    local state = Cache and Cache.buffState and Cache.buffState[id] and Cache.buffState[id][category]
    if not state then return nil end
    if state.pending then return state end
    if state.present and (tonumber(state.remaining) or 0) >= (rebuffWindow or DEFAULT_REBUFF_WINDOW) then
        return state
    end
    return nil
end

local function getSpellTargetType(spellName)
    if not spellName then return '' end
    local spell = mq.TLO.Spell(spellName)
    if spell and spell() and spell.TargetType then
        return tostring(spell.TargetType() or '')
    end
    return ''
end

local function isSpellInBook(spellName)
    if not spellName or spellName == '' then return false end
    local me = mq.TLO.Me
    if not (me and me() and me.Book) then return true end
    local ok, known = pcall(function()
        local bookSpell = me.Book(spellName)
        return bookSpell and bookSpell() and true or false
    end)
    return (not ok) or known == true
end

local function spellUsableAtCurrentLevel(spellOrName)
    local spell = type(spellOrName) == 'string' and mq.TLO.Spell(spellOrName) or spellOrName
    if not (spell and spell()) then return true, 0, 0 end

    local requiredLevel = lib.safeNum(function()
        return spell.Level and spell.Level() or 0
    end, 0)
    local currentLevel = lib.safeNum(function()
        return mq.TLO.Me.Level()
    end, 0)

    -- Treat unavailable level metadata as unknown instead of suppressing a
    -- valid spell. A positive required/current pair is authoritative.
    if requiredLevel <= 0 or currentLevel <= 0 then
        return true, requiredLevel, currentLevel
    end
    return currentLevel >= requiredLevel, requiredLevel, currentLevel
end

local function isOocBuffLikeSpell(spellName)
    if not spellName or spellName == '' then return false end
    local spell = mq.TLO.Spell(spellName)
    if not (spell and spell()) then return false end

    local subcategory = ''
    local targetType = ''
    pcall(function() subcategory = tostring(spell.Subcategory and spell.Subcategory() or ''):lower() end)
    pcall(function() targetType = tostring(spell.TargetType and spell.TargetType() or ''):lower() end)

    -- Healing spells can be beneficial and target players, but they are not
    -- persistent OOC buffs. Let the healing worker own them.
    if subcategory:find('heal', 1, true) or subcategory == 'delayed' then
        return false
    end
    -- A spell with no duration (Harvest, instant utilities) leaves no buff
    -- icon to verify — observe-after-cast always fails and the worker
    -- recast it every retry window forever. Zero-duration spells are not
    -- buffs; the rotation/utility paths own them (e.g. WIZ doHarvest).
    local durationTicks = 0
    pcall(function()
        durationTicks = tonumber(spell.Duration and spell.Duration() or 0) or 0
    end)
    if durationTicks <= 0 then
        return false
    end
    if targetType == 'target' or targetType == 'single' or targetType:find('group', 1, true)
        or targetType:find('self', 1, true) or targetType == 'pb ae' then
        return true
    end
    return false
end

local function isSelfOnlySpell(spellName)
    local targetType = getSpellTargetType(spellName)
    return targetType == 'Self' or targetType == 'Self Only' or targetType == 'PB AE'
end

local function isGroupSpell(spellName)
    local targetType = getSpellTargetType(spellName)
    return targetType:match('^Group') ~= nil
end

local function isSpellReady(spellName)
    if not spellName or spellName == '' then return false end
    local me = mq.TLO.Me
    if not (me and me()) then return false end

    local gem = me.Gem(spellName)
    if not gem or not gem() or gem() == 0 then return false end

    local ready = me.SpellReady(spellName)
    return ready and ready() == true
end

local function getSpellGemIndex(spellName)
    if not spellName or spellName == '' then return 0 end
    local me = mq.TLO.Me
    if not (me and me()) then return 0 end
    return lib.safeNum(function() return me.Gem(spellName)() end, 0)
end

local function issueBuffCast(spellName)
    local gemIndex = getSpellGemIndex(spellName)
    if gemIndex <= 0 then return false, 'spell_not_memorized' end

    local SpellEvents = getSpellEvents()
    if SpellEvents and SpellEvents.resetResult then SpellEvents.resetResult() end

    -- Cast the verified gem rather than reparsing a spell name after a hot swap.
    mq.cmdf('/cast %d', gemIndex)
    return true, nil, gemIndex
end

local function getBuffCastEventFailure()
    local SpellEvents = getSpellEvents()
    if not (SpellEvents and SpellEvents.getLastResult and SpellEvents.RESULT) then return nil end
    local result = SpellEvents.getLastResult()
    if result == SpellEvents.RESULT.NONE or result == SpellEvents.RESULT.SUCCESS then return nil end
    local name = SpellEvents.getResultName and SpellEvents.getResultName(result) or tostring(result)
    return 'cast_' .. tostring(name):lower()
end

local function canCastAfterMemorize(spellName)
    if memorizationEventPending(spellName) then
        return false, 'memorizing_event_wait'
    end

    if isWindowOpen('SpellBookWnd') then
        if manualSpellBookOpen() then
            return false, 'manual_spellbook_open'
        end
        closeSpellBookIfOpen('spellbook_open')
        return false, 'spellbook_open'
    end

    local me = mq.TLO.Me
    if me and me() and me.Standing and not me.Standing() then
        local now = lib.getTimeMs()
        if (now - (_lastStandAttemptMs or 0)) >= 500 then
            _lastStandAttemptMs = now
            mq.cmd('/squelch /stand')
        end
        return false, 'standing'
    end

    if lib.safeTLO(function() return mq.TLO.Me.SpellInCooldown() end, false) == true then
        return false, 'global_cooldown'
    end

    if not isSpellReady(spellName) then
        return false, 'spell_not_ready'
    end

    local elapsedSinceMem = lib.getTimeMs() - (_buffGemSwap.lastMemAt or 0)
    if elapsedSinceMem < BUFF_POST_MEM_SETTLE_MS then
        return false, 'post_mem_settle'
    end

    return true, nil
end

--- Ensure we are targeting the given spawn ID before casting
--- @param id number Spawn ID to target
--- @return boolean True if current target matches id
local function ensureTarget(id)
    if not id or id <= 0 then return false end
    local currentTargetId = lib.safeNum(function() return mq.TLO.Target.ID() end, 0)
    if currentTargetId == id then return true end
    mq.cmdf('/target id %d', id)
    mq.delay(50)
    currentTargetId = lib.safeNum(function() return mq.TLO.Target.ID() end, 0)
    return currentTargetId == id
end

--- Return whether a spawn still represents a living buff recipient.
--- Group.Member.ID can resolve to the member's corpse after death, so a
--- positive spawn ID alone is not sufficient.
local function isLiveBuffSpawn(id)
    id = tonumber(id) or 0
    if id <= 0 then return false, 'missing_spawn' end

    local spawn = mq.TLO.Spawn(id)
    if not spawn or not spawn() then return false, 'missing_spawn' end

    local spawnType = tostring(lib.safeTLO(function() return spawn.Type() end, '') or ''):lower()
    if spawnType == 'corpse' then return false, 'target_is_corpse' end
    if lib.safeTLO(function() return spawn.Dead() end, false) == true then
        return false, 'target_is_dead'
    end
    return true, nil
end

local function selfHasBuff(spellName, spellId)
    if not spellName then return false end

    local me = mq.TLO.Me
    if not me or not me() then return false end

    if actorHasBuffBySpell(me, spellName, spellId) then return true end
    if actorHasTriggeredEffect(me, spellName) then return true end

    -- Check Aura slots
    for i = 1, 5 do
        local aura = me.Aura(i)
        if aura and aura() then
            local auraName = aura.Name and aura.Name() or ""
            if auraName ~= "" then
                -- Check exact match or partial match for auras
                if auraName:lower() == spellName:lower() then
                    return true
                end
                if auraName:lower():find(spellName:lower(), 1, true) then
                    return true
                end
                if spellName:lower():find(auraName:lower(), 1, true) then
                    return true
                end
            end
        end
    end

    return false
end

local function getGroupRoleNames()
    local roles = {}
    local function readRole(roleName, accessor)
        local ok, name = pcall(accessor)
        name = ok and tostring(name or ''):lower() or ''
        if name ~= '' and name ~= 'null' then
            roles[name] = roleName
        end
    end

    readRole('MainTank', function()
        local role = mq.TLO.Group.MainTank
        return role and role.CleanName and role.CleanName() or ''
    end)
    readRole('MainAssist', function()
        local role = mq.TLO.Group.MainAssist
        return role and role.CleanName and role.CleanName() or ''
    end)
    readRole('Puller', function()
        local role = mq.TLO.Group.Puller
        return role and role.CleanName and role.CleanName() or ''
    end)

    return roles
end

function groupBuffCandidates(myId)
    local candidates = {}
    local roleNames = getGroupRoleNames()
    local me = mq.TLO.Me

    if me and me() and myId > 0 then
        local name = me.CleanName and me.CleanName() or _selfName
        table.insert(candidates, {
            id = myId,
            name = name,
            class = me.Class and me.Class.ShortName and me.Class.ShortName() or '',
            hp = me.PctHPs and me.PctHPs() or 100,
            mana = me.PctMana and me.PctMana() or 100,
            role = roleNames[tostring(name or ''):lower()],
            isSelf = true,
            tlo = me,
        })
    end

    local memberCount = tonumber(mq.TLO.Group.Members()) or 0
    for i = 1, memberCount do
        local member = mq.TLO.Group.Member(i)
        if member and member() then
            local id = lib.safeNum(function() return member.ID() end, 0)
            local dead = lib.safeTLO(function() return member.Dead() end, false) == true
            local offline = lib.safeTLO(function() return member.Offline() end, false) == true
            local otherZone = lib.safeTLO(function() return member.OtherZone() end, false) == true
            local liveSpawn = select(1, isLiveBuffSpawn(id))
            if id > 0 and id ~= myId and liveSpawn and not dead and not offline and not otherZone then
                local name = member.CleanName and member.CleanName() or ''
                table.insert(candidates, {
                    id = id,
                    name = name,
                    class = member.Class and member.Class.ShortName and member.Class.ShortName() or '',
                    hp = member.PctHPs and member.PctHPs() or 100,
                    mana = member.PctMana and member.PctMana() or 100,
                    distance = member.Distance and tonumber(member.Distance()) or 999,
                    role = roleNames[tostring(name or ''):lower()],
                    isSelf = false,
                    tlo = member,
                })
            end
        end
    end

    return candidates
end

local function targetMatchesBuffTarget(candidate, buffTarget)
    if not candidate then return false end
    local targetType = tostring(buffTarget and buffTarget.type or 'group'):lower()
    local targetValue = tostring(buffTarget and buffTarget.value or ''):lower()

    if targetType == '' or targetType == 'group' then
        return true
    elseif targetType == 'self' then
        return candidate.isSelf == true
    elseif targetType == 'pet' then
        -- Pet candidates are not part of the OOC group rotation yet. Do not
        -- fall through and cast a pet-only buff on a player.
        return false
    elseif targetType == 'role' then
        return tostring(candidate.role or ''):lower() == targetValue
    elseif targetType == 'class' then
        return targetValue == '' or tostring(candidate.class or ''):lower() == targetValue
    elseif targetType == 'name' then
        return targetValue == '' or tostring(candidate.name or ''):lower() == targetValue
    end

    return true
end

local function conditionPassesForTarget(buffDef, candidate)
    local condition = buffDef and buffDef.condition
    -- Spellset persistence stores conditions as SERIALIZED STRINGS.
    -- Indexing the string for `.conditions` returned nil, so the
    -- "no conditions = always pass" guard silently ignored EVERY OOC buff
    -- condition (Harvest cast at full mana). Deserialize once per
    -- definition; an unparseable configured condition fails CLOSED — the
    -- user expressed intent we cannot honor, so don't cast.
    if type(condition) == 'string' then
        if buffDef._parsedCondition == nil then
            local CB = getConditionBuilder()
            buffDef._parsedCondition = (CB and CB.deserialize and CB.deserialize(condition)) or false
            if buffDef._parsedCondition == false then
                traceLog('warn', 'conditions', 'cond_parse_' .. tostring(buffDef.category), 30,
                    'OOC buff condition failed to deserialize; buff withheld: category=%s spell=%s',
                    tostring(buffDef.category), tostring(buffDef.spellName))
            end
        end
        if buffDef._parsedCondition == false then return false end
        condition = buffDef._parsedCondition
    end
    if not condition or not condition.conditions or #condition.conditions == 0 then return true end

    local ConditionBuilder = getConditionBuilder()
    if not (ConditionBuilder and ConditionBuilder.evaluateWithContext) then return true end

    local cls = tostring(candidate.class or '')
    local ctx = {
        myHp = mq.TLO.Me.PctHPs() or 100,
        myMana = mq.TLO.Me.PctMana() or 100,
        myEndurance = mq.TLO.Me.PctEndurance() or 100,
        inCombat = lib.inCombat(),
        isInvis = mq.TLO.Me.Invis() == true,
        buffTarget = candidate.tlo,
        buffTargetClass = cls,
        buffTargetRole = candidate.role,
        buffTargetHp = candidate.hp or 100,
        buffTargetMana = candidate.mana or 100,
        buffTargetIsMe = candidate.isSelf == true,
        buffTargetIsTank = (cls == 'WAR' or cls == 'PAL' or cls == 'SHD'),
        buffTargetIsHealer = (cls == 'CLR' or cls == 'DRU' or cls == 'SHM'),
        buffTargetIsMelee = (cls == 'WAR' or cls == 'PAL' or cls == 'SHD' or cls == 'MNK' or cls == 'ROG' or cls == 'BER' or cls == 'RNG' or cls == 'BST'),
        buffTargetIsCaster = (cls == 'WIZ' or cls == 'MAG' or cls == 'ENC' or cls == 'NEC' or cls == 'CLR' or cls == 'DRU' or cls == 'SHM'),
    }

    local ok, result = pcall(ConditionBuilder.evaluateWithContext, condition, ctx)
    if not ok then
        debugLog('conditionPassesForTarget: condition failed for %s: %s', tostring(candidate.name), tostring(result))
        return false
    end
    return result == true
end

local function candidateHasBuff(candidate, spellName, spellId, category, rebuffWindow)
    if not candidate then return false end

    local cached = getCachedBuffState(candidate.id, category, rebuffWindow)
    local direct = false
    local triggered = false
    local aura = false

    if candidate.isSelf then
        local me = mq.TLO.Me
        if me and me() then
            direct = actorHasBuffBySpell(me, spellName, spellId)
            triggered = actorHasTriggeredEffect(me, spellName)
            aura = (not direct and not triggered) and selfHasBuff(spellName, spellId) or false
        end
    else
        direct = actorHasBuffBySpell(candidate.tlo, spellName, spellId)
        triggered = actorHasTriggeredEffect(candidate.tlo, spellName)
    end

    if buffDebugEnabled() then
        local probe = buffProbe(candidate.isSelf and mq.TLO.Me or candidate.tlo, spellName, spellId)
        local stateText = cached and string.format('present=%s pending=%s remaining=%s spellId=%s',
            tostring(cached.present), tostring(cached.pending), tostring(cached.remaining), tostring(cached.spellId)) or 'nil'
        diagLog('candidate_has_' .. tostring(category) .. '_' .. tostring(candidate.id), 0.5,
            'candidateHasBuff spell="%s" spellId=%s category=%s target=%s(%s) self=%s cached={%s} direct=%s triggered=%s aura=%s probe={%s}',
            tostring(spellName), tostring(spellId), tostring(category), tostring(candidate.name), tostring(candidate.id),
            tostring(candidate.isSelf), stateText, tostring(direct), tostring(triggered), tostring(aura), probeSummary(probe))
    end

    return cached ~= nil or direct or triggered or aura
end

local function directBuffPresentOnTarget(targetId, spellName, spellId, isGroup)
    if not spellName or spellName == '' then return false, 'invalid_spell' end

    local me = mq.TLO.Me
    local myId = lib.safeNum(function() return me.ID() end, 0)

    -- Group buffs should always land on the caster too. Use self as the
    -- reliable landing confirmation for group casts.
    if isGroup or tonumber(targetId) == myId then
        return selfHasBuff(spellName, spellId), 'self'
    end

    for _, candidate in ipairs(groupBuffCandidates(myId)) do
        if tonumber(candidate.id) == tonumber(targetId) then
            local direct = actorHasBuffBySpell(candidate.tlo, spellName, spellId)
                or actorHasTriggeredEffect(candidate.tlo, spellName)
            return direct == true, 'group_member'
        end
    end

    return false, 'target_not_observable'
end

local function pickBuffTarget(buffDef, spellName, category, rebuffWindow, isGroup, myId)
    local spellId = buffDef and buffDef.spellId or getSpellId(spellName)
    for _, candidate in ipairs(groupBuffCandidates(myId)) do
        -- NOTE: invis candidates are NOT skipped — buffs land on invis group
        -- members as long as the buffer can see them (see-invis), and
        -- Spawn.Invis only reports their state, not our visibility of them.
        -- A truly unseeable target fails the cast and the normal
        -- buff_not_observed_after_cast backoff handles it.
        if targetMatchesBuffTarget(candidate, buffDef and buffDef.buffTarget)
            and conditionPassesForTarget(buffDef, candidate) then
            local hasBuff = candidateHasBuff(candidate, spellName, spellId, category, rebuffWindow)
            debugLog('pickBuffTarget: %s candidate=%s id=%d hasBuff=%s isGroup=%s',
                spellName, tostring(candidate.name), tonumber(candidate.id) or 0, tostring(hasBuff), tostring(isGroup))
            if not hasBuff then
                return candidate
            end
        end
    end
    return nil
end

--- Check if a spell would stack (not blocked by existing buffs)
---@param spellName string The spell name to check
---@return boolean True if spell would stack/land
local function spellWouldStack(spellName)
    if not spellName then return false end

    local spell = mq.TLO.Spell(spellName)
    if not spell or not spell() then return false end

    -- Check if spell stacks on self
    -- Stacks() returns true if the spell would land (not blocked by existing buffs)
    local stacks = spell.Stacks
    if stacks then
        local result = stacks()
        if result == false then
            debugLog('spellWouldStack: %s would NOT stack', spellName)
            return false
        end
    end

    return true
end

--- Check if we have enough mana to cast a spell
---@param spellName string The spell name to check
---@return boolean True if we have enough mana
local function hasEnoughMana(spellName)
    if not spellName then return false end

    local me = mq.TLO.Me
    if not me or not me() then return false end

    local spell = mq.TLO.Spell(spellName)
    if not spell or not spell() then return false end

    local manaCost = spell.Mana and spell.Mana() or 0
    local currentMana = me.CurrentMana and me.CurrentMana() or 0

    if manaCost > currentMana then
        debugLog('hasEnoughMana: %s needs %d mana, have %d', spellName, manaCost, currentMana)
        return false
    end

    return true
end

-------------------------------------------------------------------------------
-- Buff Definitions Management
-------------------------------------------------------------------------------

local _persistenceLoaded = false

local function loadBuffDefinitions()
    local nextDefinitions = {}
    local stats = {
        enabled = 0,
        accepted = 0,
        skippedBook = 0,
        skippedLevel = 0,
        skippedType = 0,
        unresolved = 0,
    }

    -- Get SpellSetData and Persistence to access oocBuffs
    local SpellSetData = nil
    local Persistence = nil
    pcall(function()
        SpellSetData = require('sidekick-next.utils.spellset_data')
    end)
    pcall(function()
        Persistence = require('sidekick-next.utils.spellset_persistence')
    end)

    if not SpellSetData or not Persistence then
        debugLog('loadBuffDefinitions: SpellSetData or Persistence not available')
        traceLog('warn', 'definitions', 'defs_no_modules', 10,
            'Unable to load buff definitions: SpellSetData or Persistence unavailable')
        _lastBuffScanReason = 'no_spellset_modules'
        return
    end

    -- sk_buffs.lua runs as a separate script, so we need to load spell sets from disk
    -- This is only done once per session to avoid repeated disk reads
    if not _persistenceLoaded then
        debugLog('loadBuffDefinitions: Loading spell sets from disk (first time)')
        local ok, loadedOrErr = pcall(function()
            return Persistence.load()
        end)
        if not ok or loadedOrErr ~= true then
            debugLog('loadBuffDefinitions: Persistence.load() failed: %s', tostring(loadedOrErr))
            traceLog('warn', 'definitions', 'defs_load_failed', 10,
                'Unable to load buff definitions: Persistence.load failed: %s', tostring(loadedOrErr))
            _lastBuffScanReason = 'spellset_load_failed'
            return
        else
            _persistenceLoaded = true
            debugLog('loadBuffDefinitions: Spell sets loaded, activeSetName=%s', tostring(Persistence.activeSetName))
            traceLog('info', 'definitions', 'defs_loaded_disk', 30,
                'Loaded spell sets from disk; activeSet=%s', tostring(Persistence.activeSetName))
        end
    end

    local spellSet = Persistence.getActiveSet()
    if not spellSet then
        debugLog('loadBuffDefinitions: No active spell set (activeSetName=%s)', tostring(Persistence.activeSetName))
        traceLog('warn', 'definitions', 'defs_no_active_set', 10,
            'No active spell set; activeSetName=%s', tostring(Persistence.activeSetName))
        _lastBuffScanReason = 'no_active_spell_set'
        _persistenceLoaded = false
        return
    end

    local enabledBuffs = SpellSetData.getEnabledOocBuffs(spellSet)
    stats.enabled = enabledBuffs and #enabledBuffs or 0
    if not enabledBuffs or #enabledBuffs == 0 then
        debugLog('loadBuffDefinitions: No enabled OOC buffs in spell set')
        _buffDefinitions = {}
        _lastBuffScanReason = 'no_enabled_ooc_buffs'
        traceLog('info', 'definitions', 'defs_none_enabled', 10,
            'No enabled OOC buffs in activeSet=%s', tostring(Persistence.activeSetName))
        return
    end

    debugLog('loadBuffDefinitions: Found %d enabled OOC buffs', #enabledBuffs)
    traceLog('info', 'definitions', 'defs_start_' .. tostring(Persistence.activeSetName), 5,
        'Scanning %d enabled OOC buff entries from activeSet=%s', #enabledBuffs, tostring(Persistence.activeSetName))

    for _, buffConfig in ipairs(enabledBuffs) do
        local spell = mq.TLO.Spell(buffConfig.spellId)
        local spellName = spell and spell.Name() or nil
        if spellName then
            local levelUsable, requiredLevel, currentLevel = spellUsableAtCurrentLevel(spell)
            if not isSpellInBook(spellName) then
                stats.skippedBook = stats.skippedBook + 1
                debugLog('loadBuffDefinitions: Skipping %s (id=%s): not in spellbook',
                    tostring(spellName), tostring(buffConfig.spellId))
                traceLog('info', 'definitions', 'skip_book_' .. tostring(buffConfig.spellId), 30,
                    'Skipped buff definition: reason=not_in_spellbook %s priority=%s target=%s',
                    spellTraceInfo(spellName, buffConfig.spellId), tostring(buffConfig.priority),
                    tostring(buffConfig.buffTarget and buffConfig.buffTarget.type or 'group'))
            elseif not levelUsable then
                stats.skippedLevel = stats.skippedLevel + 1
                debugLog('loadBuffDefinitions: Skipping %s (id=%s): requires level %d, current level %d',
                    tostring(spellName), tostring(buffConfig.spellId), requiredLevel, currentLevel)
                traceLog('warn', 'definitions', 'skip_level_' .. tostring(buffConfig.spellId), 30,
                    'Skipped buff definition: reason=level_too_low spell=%s id=%s requiredLevel=%d currentLevel=%d',
                    tostring(spellName), tostring(buffConfig.spellId), requiredLevel, currentLevel)
            elseif not isOocBuffLikeSpell(spellName) then
                stats.skippedType = stats.skippedType + 1
                debugLog('loadBuffDefinitions: Skipping %s (id=%s): not an OOC buff',
                    tostring(spellName), tostring(buffConfig.spellId))
                traceLog('info', 'definitions', 'skip_type_' .. tostring(buffConfig.spellId), 30,
                    'Skipped buff definition: reason=not_ooc_buff %s priority=%s target=%s',
                    spellTraceInfo(spellName, buffConfig.spellId), tostring(buffConfig.priority),
                    tostring(buffConfig.buffTarget and buffConfig.buffTarget.type or 'group'))
            else
                local category = string.format('oocbuff_%d', buffConfig.spellId)
                nextDefinitions[category] = {
                    spellId = buffConfig.spellId,
                    spellName = spellName,
                    category = category,
                    condition = buffConfig.condition,
                    buffTarget = buffConfig.buffTarget,
                    priority = buffConfig.priority or 999,
                    rebuffWindow = DEFAULT_REBUFF_WINDOW,
                }
                stats.accepted = stats.accepted + 1
                debugLog('loadBuffDefinitions: Added buff %s (id=%d, priority=%d)',
                    spellName, buffConfig.spellId, buffConfig.priority or 999)
                traceLog('info', 'definitions', 'accept_' .. tostring(buffConfig.spellId), 30,
                    'Accepted buff definition: category=%s %s priority=%s target=%s',
                    category, spellTraceInfo(spellName, buffConfig.spellId), tostring(buffConfig.priority or 999),
                    tostring(buffConfig.buffTarget and buffConfig.buffTarget.type or 'group'))
            end
        else
            stats.unresolved = stats.unresolved + 1
            debugLog('loadBuffDefinitions: Spell id %s did not resolve to a spell name', tostring(buffConfig.spellId))
            traceLog('warn', 'definitions', 'unresolved_' .. tostring(buffConfig.spellId), 30,
                'Skipped buff definition: reason=spell_id_unresolved id=%s priority=%s',
                tostring(buffConfig.spellId), tostring(buffConfig.priority))
        end
    end

    _buffDefinitions = nextDefinitions
    if next(_buffDefinitions) then
        _lastBuffScanReason = string.format('loaded_%d_ooc_buffs', stats.accepted)
    elseif stats.skippedLevel > 0 then
        _lastBuffScanReason = 'no_level_eligible_ooc_buffs'
    else
        _lastBuffScanReason = 'no_resolved_ooc_buffs'
    end
    traceLog('info', 'definitions', 'defs_summary_' .. tostring(Persistence.activeSetName), 5,
        'Buff definition summary: activeSet=%s enabled=%d accepted=%d skippedBook=%d skippedLevel=%d skippedType=%d unresolved=%d reason=%s',
        tostring(Persistence.activeSetName), stats.enabled, stats.accepted, stats.skippedBook, stats.skippedLevel,
        stats.skippedType, stats.unresolved, tostring(_lastBuffScanReason))
end

local function refreshBuffDefinitionsIfNeeded()
    local now = os.clock()
    local hasDefinitions = next(_buffDefinitions) ~= nil

    local needsRefresh = false
    local isPeriodicRefresh = false

    if not hasDefinitions then
        if (now - _lastBuffDefsRefresh) >= BUFF_DEFS_REFRESH_INTERVAL then
            needsRefresh = true
        end
    else
        if (now - _lastBuffDefsRefresh) >= BUFF_DEFS_PERIODIC_REFRESH then
            needsRefresh = true
            isPeriodicRefresh = true
        end
    end

    if needsRefresh then
        _lastBuffDefsRefresh = now
        -- For periodic refresh, force reload from disk to pick up user changes
        if isPeriodicRefresh then
            _persistenceLoaded = false
            debugLog('refreshBuffDefinitionsIfNeeded: Periodic refresh, forcing disk reload')
        end
        loadBuffDefinitions()
    end
end

local function getSortedBuffDefinitions()
    local sorted = {}
    for category, def in pairs(_buffDefinitions) do
        table.insert(sorted, { category = category, def = def })
    end
    table.sort(sorted, function(a, b)
        return (a.def.priority or 999) < (b.def.priority or 999)
    end)
    return sorted
end

-------------------------------------------------------------------------------
-- Gem Hot-Swap Management
-------------------------------------------------------------------------------

local function ensureBuffSpellMemorized(spellName)
    if not spellName or spellName == '' then return false, 'invalid_spell' end
    holdSpellsetMemorizer('buff_hotswap_memorize', BUFF_SPELLSET_LEASE_MS)

    local reservedGem = getReservedBuffGem()
    if reservedGem <= 0 then return false, 'no_reserved_gem' end

    local me = mq.TLO.Me
    if not (me and me()) then return false, 'no_character' end
    local inBook = me.Book(spellName)
    if not (inBook and inBook()) then
        return false, 'not_in_spellbook'
    end

    if _buffGemSwap.reservedGem ~= reservedGem then
        _buffGemSwap.reservedGem = reservedGem
    end

    local current = getGemSpellName(reservedGem)

    -- Start of a buff rotation
    if not _buffGemSwap.active then
        _buffGemSwap.active = true
        _buffGemSwap.originalSpell = current
        _buffGemSwap.requestedSpell = ''
        _buffGemSwap.lastRequestAt = 0
        _buffGemSwap.lastMemAt = 0
    end

    -- Already memorized
    if current == spellName then
        if memorizationEventPending(spellName) then
            return false, 'memorizing_event_wait'
        end
        _buffGemSwap.requestedSpell = ''
        if _buffMemEvent.endAtMs and _buffMemEvent.endAtMs > 0 then
            _buffGemSwap.lastMemAt = _buffMemEvent.endAtMs
        else
            _buffGemSwap.lastMemAt = lib.getTimeMs()
        end
        return true, 'memorized'
    end

    -- An open spellbook is not evidence that another memorization owns the
    -- operation. /memspell works with the book already open, and the cast
    -- coordinator plus the request cooldown below prevent command spam.

    local now = lib.getTimeMs()
    local requestCooldownMs = 1000
    if _buffGemSwap.requestedSpell == spellName and (now - (_buffGemSwap.lastRequestAt or 0)) < requestCooldownMs then
        return false, 'request_cooldown'
    end

    -- Retry if waiting too long
    if _buffGemSwap.requestedSpell == spellName and (now - (_buffGemSwap.lastRequestAt or 0)) >= 8000 then
        holdSpellsetMemorizer('buff_hotswap_retry', BUFF_SPELLSET_LEASE_MS)
        _buffGemSwap.lastRequestAt = now
        _buffMemEvent.requestedSpell = spellName
        _buffMemEvent.active = true
        _buffMemEvent.endSpell = ''
        _buffMemEvent.endAtMs = 0
        _buffMemEvent.abortAtMs = 0
        mq.cmdf('/memspell %d "%s"', reservedGem, spellName)
        return false, 'retry_sent'
    end

    _buffGemSwap.requestedSpell = spellName
    _buffGemSwap.lastRequestAt = now
    _buffMemEvent.requestedSpell = spellName
    _buffMemEvent.active = true
    _buffMemEvent.beginSpell = ''
    _buffMemEvent.beginAtMs = 0
    _buffMemEvent.endSpell = ''
    _buffMemEvent.endAtMs = 0
    _buffMemEvent.abortAtMs = 0
    _buffMemEvent.pendingBookClose = false
    holdSpellsetMemorizer('buff_hotswap_request', BUFF_SPELLSET_LEASE_MS)
    mq.cmdf('/memspell %d "%s"', reservedGem, spellName)
    return false, 'request_sent'
end

local function maybeRestoreBuffGem()
    if not _buffGemSwap.active then return end

    local reservedGem = getReservedBuffGem()
    if reservedGem <= 0 then
        _buffGemSwap.active = false
        _buffGemSwap.originalSpell = ''
        _buffGemSwap.requestedSpell = ''
        _buffGemSwap.lastRequestAt = 0
        _buffGemSwap.lastMemAt = 0
        _buffGemSwap.reservedGem = 0
        clearSpellsetMemorizerHold()
        return
    end

    -- The last gem is reserved for OOC buff hot-swaps when the active spell
    -- set has OOC buffs. Do not restore the previous spell here; doing so
    -- fights the buff worker and looks like immediate mem/unmem churn. The
    -- active spellset memorizer ignores the reserved gem during dirty checks.
    _buffGemSwap.active = false
    _buffGemSwap.originalSpell = ''
    _buffGemSwap.requestedSpell = ''
    _buffGemSwap.lastRequestAt = 0
    _buffGemSwap.lastMemAt = 0
    clearSpellsetMemorizerHold()
end

-------------------------------------------------------------------------------
-- Active Buff State
-------------------------------------------------------------------------------

local function clearActiveBuff()
    _activeBuff.category = nil
    _activeBuff.spellName = nil
    _activeBuff.targetId = nil
    _activeBuff.startedAtMs = 0
    _activeBuff.waitReason = nil
    _activeBuff.state = nil
end

local function clearOwnedMemorizationState()
    _buffMemEvent.active = false
    _buffMemEvent.requestedSpell = ''
    _buffMemEvent.beginSpell = ''
    _buffMemEvent.beginAtMs = 0
    _buffMemEvent.endSpell = ''
    _buffMemEvent.endAtMs = 0
    _buffMemEvent.abortAtMs = 0
    _buffMemEvent.pendingBookClose = false
end

local function setActiveBuff(category, spellName, targetId, state)
    _activeBuff.category = category
    _activeBuff.spellName = spellName
    _activeBuff.targetId = targetId
    _activeBuff.startedAtMs = lib.getTimeMs()
    _activeBuff.waitReason = nil
    _activeBuff.state = state or 'memorizing'
end

local function activeBuffTimedOut()
    if not _activeBuff.category then return false end
    local timeoutMs = (_activeBuff.state == 'casting' or _activeBuff.state == 'cast_starting')
        and BUFF_CAST_TIMEOUT_MS or BUFF_PRECAST_TIMEOUT_MS
    return (lib.getTimeMs() - (_activeBuff.startedAtMs or 0)) > timeoutMs
end

local function recordBuffFailure(category, reason)
    if not category or category == '' then return end
    local now = lib.getTimeMs()
    local previous = _buffFailures[category]
    -- Preserve escalation across immediate retries, but not across unrelated
    -- failures separated by ten minutes or more.
    if previous and (now - (previous.lastFailureAtMs or now)) >= 600000 then
        previous = nil
    end
    local count = previous and (previous.count or 0) + 1 or 1
    local multiplier = 2 ^ math.min(count - 1, 4)
    local delayMs = math.min(BUFF_FAILURE_BACKOFF_MS * multiplier, BUFF_FAILURE_BACKOFF_MAX_MS)
    _buffFailures[category] = {
        count = count,
        retryAtMs = now + delayMs,
        lastFailureAtMs = now,
        reason = reason,
    }
    traceLog('warn', 'failure', 'record_' .. tostring(category), 0,
        'Recorded buff failure: category=%s reason=%s count=%d retryInMs=%d',
        tostring(category), tostring(reason), count, delayMs)
end

local function clearBuffFailure(category)
    if category and _buffFailures[category] then
        traceLog('info', 'failure', 'clear_' .. tostring(category), 0,
            'Cleared buff failure: category=%s previousReason=%s',
            tostring(category), tostring(_buffFailures[category].reason))
        _buffFailures[category] = nil
    elseif category then
        _buffFailures[category] = nil
    end
end

local function clearAllBuffFailures()
    local count = 0
    for category in pairs(_buffFailures) do
        _buffFailures[category] = nil
        count = count + 1
    end
    return count
end

local function buffFailureActive(category)
    local failure = category and _buffFailures[category] or nil
    if not failure then return false end
    if lib.getTimeMs() >= (failure.retryAtMs or 0) then
        return false
    end
    return true
end

-------------------------------------------------------------------------------
-- Blocking Condition Checks
-------------------------------------------------------------------------------

local function canBuffNow()
    local me = mq.TLO.Me
    if not (me and me()) then return false, 'no_character' end

    -- Check combat state (buffing only allowed OOC)
    -- Use lib.inCombat() which checks XTarget haters directly,
    -- not RuntimeCache which may not be ticked in this script process
    local inCombat = lib.inCombat()
    if inCombat then return false, 'in_combat' end

    -- Check invis
    if me.Invis and me.Invis() then return false, 'invis' end

    local moving = me.Moving() == true

    -- Check movement plugins. Active stick/nav alone should not suppress
    -- OOC buffing forever; only block while the character is actually moving.
    local movementPluginActive = (mq.TLO.MoveTo and mq.TLO.MoveTo.Moving and mq.TLO.MoveTo.Moving())
        or (mq.TLO.Navigation and mq.TLO.Navigation.Active and mq.TLO.Navigation.Active())
        or (mq.TLO.AdvPath and mq.TLO.AdvPath.Following and mq.TLO.AdvPath.Following())
        or (mq.TLO.Stick and mq.TLO.Stick.Active and mq.TLO.Stick.Active())
    if movementPluginActive and moving then
        return false, 'movement_plugin'
    end

    -- Check if moving
    if moving then return false, 'moving' end

    -- Check if already casting
    local casting = me.Casting() or ''
    if casting ~= '' and casting ~= 'NULL' then return false, 'casting' end

    -- Check if hovering (dead)
    if me.Hovering and me.Hovering() then return false, 'dead' end

    -- Check if stunned/mezzed. me.Mezzed is a Spell TLO that stringifies to
    -- "NULL" on some builds when not mezzed — always truthy; gate on its ID
    -- instead (same fix as cc.lua's selectMezAction).
    if me.Stunned and me.Stunned() then return false, 'stunned' end
    if me.Mezzed and me.Mezzed.ID and (tonumber(me.Mezzed.ID()) or 0) > 0 then
        return false, 'mezzed'
    end

    -- Check SpellEngine availability
    local SpellEngine = getSpellEngine()
    if SpellEngine and SpellEngine.isBusy and SpellEngine.isBusy() then
        return false, 'spell_engine_busy'
    end

    return true, nil
end

-------------------------------------------------------------------------------
-- Buff Need Detection
-------------------------------------------------------------------------------

local function findBuffNeed()
    local Cache = getCache()
    if not Cache then
        debugLog('findBuffNeed: No Cache')
        traceLog('warn', 'scan', 'scan_no_cache', 10, 'Cannot scan buffs: runtime cache unavailable')
        return nil, 'no_cache'
    end

    local settings = syncSettings()

    -- Check if buffing is enabled
    local buffingEnabled = settings.BuffingEnabled
    if buffingEnabled == false or buffingEnabled == 0 then
        debugLog('findBuffNeed: Buffing disabled')
        traceLog('info', 'scan', 'scan_disabled', 30, 'Buff scan skipped: BuffingEnabled=%s', tostring(settings.BuffingEnabled))
        return nil, 'buffing_disabled'
    end

    -- Check if we can buff now
    local canBuff, reason = canBuffNow()
    if not canBuff then
        debugLog('findBuffNeed: Cannot buff now: %s', tostring(reason))
        traceLog('info', 'scan', 'scan_blocked_' .. tostring(reason), 10,
            'Buff scan blocked: reason=%s activeBuff=%s:%s state=%s',
            tostring(reason), tostring(_activeBuff.category), tostring(_activeBuff.spellName), tostring(_activeBuff.state))
        return nil, 'blocked_' .. tostring(reason or 'unknown')
    end

    refreshBuffDefinitionsIfNeeded()

    if not next(_buffDefinitions) then
        debugLog('findBuffNeed: No buff definitions')
        traceLog('info', 'scan', 'scan_no_defs', 10,
            'Buff scan skipped: no definitions loaded; reason=%s', tostring(_lastBuffScanReason))
        return nil, _lastBuffScanReason or 'no_buff_definitions'
    end

    -- NOTE: Initial scan check removed - we no longer depend on the old buff module
    -- The coordinator system uses Cache for buff state tracking instead

    debugLog('findBuffNeed: Checking %d buff definitions', #getSortedBuffDefinitions())

    local now = os.clock()
    local me = mq.TLO.Me
    local myId = me and me.ID and me.ID() or 0

    -- Pending peer requests jump ahead of normal scan order. Pick the highest
    -- priority request whose category we can actually cast.
    local okR, BuffReqs = pcall(require, 'sidekick-next.utils.buff_requests')
    if okR and BuffReqs and BuffReqs.peekHighestPriority then
        local req = BuffReqs.peekHighestPriority()
        if req and req.category and _buffDefinitions[req.category] and not buffFailureActive(req.category) then
            local buffDef = _buffDefinitions[req.category]
            local spellName = buffDef.spellName
            if spellName and spellName ~= '' then
                local isSelfOnly = isSelfOnlySpell(spellName)
                local isGroup = isGroupSpell(spellName)
                local castableTarget = req.targetId
                local requestTargetLive, requestTargetReason = isLiveBuffSpawn(castableTarget)
                if not requestTargetLive then
                    -- Death can leave a request keyed by the old spawn/corpse
                    -- ID. Remove it now so it cannot dominate every normal
                    -- scan until its 30-60 second lease expires.
                    if BuffReqs.clearRequest then
                        BuffReqs.clearRequest(castableTarget, req.category)
                    end
                    traceLog('info', 'scan', 'request_dead_target_' .. tostring(req.category), 0,
                        'Discarded buff request: spell=%s category=%s target=%s(%d) reason=%s',
                        tostring(spellName), tostring(req.category), tostring(req.from),
                        tonumber(castableTarget) or 0, tostring(requestTargetReason))
                -- Self-only spells can only satisfy a request from us.
                elseif isSelfOnly and castableTarget ~= myId then
                    -- skip self-only request from someone else
                else
                    if spellWouldStack(spellName) and hasEnoughMana(spellName) then
                        debugLog('findBuffNeed: REQUEST priority — %s for %s (category=%s urgency=%s)',
                            spellName, tostring(req.from), req.category, req.urgency or 'normal')
                        return {
                            category = req.category,
                            spellName = spellName,
                            targetId = castableTarget,
                            targetName = req.from,
                            isSelfOnly = isSelfOnly,
                            isGroup = isGroup,
                            fromRequest = true,
                        }
                    end
                end
            end
        end
    end

    local sortedBuffs = getSortedBuffDefinitions()

    for _, entryDef in ipairs(sortedBuffs) do
        local category = entryDef.category
        local buffDef = entryDef.def
        local spellName = buffDef.spellName

        if buffFailureActive(category) then
            local failure = _buffFailures[category]
            _lastBuffScanReason = 'buff_backoff:' .. tostring(spellName)
            debugLog('findBuffNeed: Backing off %s after %s (retry in %dms)',
                tostring(spellName), tostring(failure and failure.reason or 'failure'),
                math.max(0, (failure and failure.retryAtMs or 0) - lib.getTimeMs()))
            traceLog('info', 'scan', 'backoff_' .. tostring(category), 10,
                'Skipping buff due to backoff: spell=%s category=%s reason=%s retryInMs=%d failures=%s',
                tostring(spellName), tostring(category), tostring(failure and failure.reason or 'failure'),
                math.max(0, (failure and failure.retryAtMs or 0) - lib.getTimeMs()),
                tostring(failure and failure.count or 0))
            goto continue_buff
        end

        if spellName and spellName ~= '' then
            local rebuffWindow = buffDef.rebuffWindow or DEFAULT_REBUFF_WINDOW
            local isSelfOnly = isSelfOnlySpell(spellName)
            local isGroup = isGroupSpell(spellName)

            debugLog('findBuffNeed: Checking %s (isSelfOnly=%s, isGroup=%s)', spellName, tostring(isSelfOnly), tostring(isGroup))

            if isSelfOnly then
                -- Self-only buff: check directly if we have the buff
                if myId > 0 then
                    local spellId = buffDef.spellId or getSpellId(spellName)
                    local cached = getCachedBuffState(myId, category, rebuffWindow)
                    local hasSelf = selfHasBuff(spellName, spellId)
                    local hasBuff = cached ~= nil or hasSelf
                    if buffDebugEnabled() then
                        local probe = buffProbe(mq.TLO.Me, spellName, spellId)
                        local stateText = cached and string.format('present=%s pending=%s remaining=%s spellId=%s',
                            tostring(cached.present), tostring(cached.pending), tostring(cached.remaining), tostring(cached.spellId)) or 'nil'
                        diagLog('self_only_' .. tostring(category), 0.5,
                            'selfOnlyCheck spell="%s" spellId=%s category=%s cached={%s} selfHas=%s probe={%s}',
                            tostring(spellName), tostring(spellId), tostring(category), stateText, tostring(hasSelf), probeSummary(probe))
                    end
                    debugLog('findBuffNeed: Self-buff %s hasBuff=%s', spellName, tostring(hasBuff))

                    if not hasBuff then
                        -- Check if spell would stack (not blocked by existing buffs)
                        local wouldStack = spellWouldStack(spellName)
                        diagLog('self_only_stack_' .. tostring(category), 0.5,
                            'selfOnlyStack spell="%s" spellId=%s stacks=%s', tostring(spellName), tostring(spellId), tostring(wouldStack))
                        if not wouldStack then
                            debugLog('findBuffNeed: Self-buff %s would not stack, skipping', spellName)
                            traceLog('info', 'scan', 'self_stack_' .. tostring(category), 30,
                                'Skipping self buff: reason=would_not_stack spell=%s category=%s',
                                tostring(spellName), tostring(category))
                            goto continue_buff
                        end

                        -- Check if we have enough mana
                        if not hasEnoughMana(spellName) then
                            debugLog('findBuffNeed: Self-buff %s not enough mana, skipping', spellName)
                            traceLog('info', 'scan', 'self_mana_' .. tostring(category), 10,
                                'Skipping self buff: reason=not_enough_mana spell=%s category=%s',
                                tostring(spellName), tostring(category))
                            goto continue_buff
                        end

                        debugLog('findBuffNeed: FOUND self-buff %s (category=%s)', spellName, category)
                        traceLog('info', 'scan', 'found_self_' .. tostring(category), 5,
                            'Selected self buff: spell=%s category=%s targetId=%d',
                            tostring(spellName), tostring(category), myId)
                        return {
                            category = category,
                            spellName = spellName,
                            targetId = myId,
                            isSelfOnly = true,
                            isGroup = false,
                        }
                    else
                        _lastBuffScanReason = 'already_has_self_buff:' .. spellName
                    end
                end
            else
                -- Check group cast cooldown first
                if isGroup then
                    local lastCast = _lastGroupCastAt[category] or 0
                    if (now - lastCast) < GROUP_CAST_COOLDOWN then
                        debugLog('findBuffNeed: Group buff %s on cooldown', spellName)
                        _lastBuffScanReason = 'group_cooldown:' .. spellName
                        traceLog('info', 'scan', 'group_cooldown_' .. tostring(category), 5,
                            'Skipping group buff: reason=group_cooldown spell=%s category=%s remainingSec=%.1f',
                            tostring(spellName), tostring(category), GROUP_CAST_COOLDOWN - (now - lastCast))
                        goto continue_buff
                    end
                end

                -- Check if we have enough mana
                if not hasEnoughMana(spellName) then
                    debugLog('findBuffNeed: Group/single buff %s not enough mana, skipping', spellName)
                    _lastBuffScanReason = 'not_enough_mana:' .. spellName
                    traceLog('info', 'scan', 'target_mana_' .. tostring(category), 10,
                        'Skipping buff: reason=not_enough_mana spell=%s category=%s',
                        tostring(spellName), tostring(category))
                    goto continue_buff
                end

                local target = pickBuffTarget(buffDef, spellName, category, rebuffWindow, isGroup, myId)
                if not target then
                    debugLog('findBuffNeed: No eligible target needs %s', spellName)
                    _lastBuffScanReason = 'no_eligible_target:' .. spellName
                    traceLog('info', 'scan', 'no_target_' .. tostring(category), 10,
                        'No eligible target needs buff: spell=%s category=%s targetRule=%s candidateCount=%d isGroupSpell=%s',
                        tostring(spellName), tostring(category),
                        tostring(buffDef.buffTarget and buffDef.buffTarget.type or 'group'),
                        #groupBuffCandidates(myId), tostring(isGroup))
                    goto continue_buff
                end

                -- Only use self Stacks() as a blocker when the selected target
                -- is self. A self stack failure should not suppress buffing
                -- another group member who is missing the buff.
                if target.isSelf and not spellWouldStack(spellName) then
                    debugLog('findBuffNeed: Group/single buff %s would not stack on self, skipping', spellName)
                    diagLog('target_stack_' .. tostring(category), 0.5,
                        'targetStack spell="%s" category=%s target=%s(%s) self=%s stacks=false -> skip',
                        tostring(spellName), tostring(category), tostring(target.name), tostring(target.id), tostring(target.isSelf))
                    _lastBuffScanReason = 'would_not_stack:' .. spellName
                    traceLog('info', 'scan', 'target_stack_' .. tostring(category), 30,
                        'Skipping buff: reason=would_not_stack spell=%s category=%s target=%s(%s)',
                        tostring(spellName), tostring(category), tostring(target.name), tostring(target.id))
                    goto continue_buff
                end

                diagLog('found_need_' .. tostring(category), 0.5,
                    'FOUND need spell="%s" category=%s target=%s(%s) isGroup=%s isSelf=%s',
                    tostring(spellName), tostring(category), tostring(target.name), tostring(target.id),
                    tostring(isGroup), tostring(target.isSelf))
                debugLog('findBuffNeed: FOUND buff %s on %s (category=%s, isGroup=%s)',
                    spellName, tostring(target.name), category, tostring(isGroup))
                traceLog('info', 'scan', 'found_target_' .. tostring(category), 5,
                    'Selected buff: spell=%s category=%s target=%s(%s) castTarget=%s isGroupSpell=%s',
                    tostring(spellName), tostring(category), tostring(target.name), tostring(target.id),
                    tostring(isGroup and myId or target.id), tostring(isGroup))
                return {
                    category = category,
                    spellName = spellName,
                    targetId = isGroup and myId or target.id,
                    targetName = isGroup and _selfName or target.name,
                    -- Preserve the candidate that caused a group spell to be
                    -- selected. Group casts target self, so targetId alone
                    -- cannot detect that the original recipient died while a
                    -- hot-swap or local coordinator lease was pending.
                    needTargetId = target.id,
                    needTargetName = target.name,
                    isSelfOnly = false,
                    isGroup = isGroup,
                }
            end
        end
        ::continue_buff::
    end

    debugLog('findBuffNeed: No buffs needed')
    traceLog('info', 'scan', 'scan_none_needed', 15,
        'No buffs needed after scanning %d definitions; lastReason=%s',
        #getSortedBuffDefinitions(), tostring(_lastBuffScanReason or 'no_buff_needed'))
    return nil, _lastBuffScanReason or 'no_buff_needed'
end

-------------------------------------------------------------------------------
-- Module Callbacks
-------------------------------------------------------------------------------

module.onTick = function(self)
    debugLog('onTick: ENTERED hasValidState=%s', tostring(self:hasValidState()))

    registerMemorizationEvents()
    pcall(mq.doevents)

    local settings = syncSettings()
    local Cache = getCache()
    if Cache then
        if Cache.setSettings then Cache.setSettings(settings) end
        if Cache.tick then Cache.tick() end
    end
    local Buff = getBuff()
    if Buff and Buff.tick then Buff.tick() end

    local hasActiveBuff = _activeBuff.category and _activeBuff.spellName
    local ownsLease = self.currentRequestId ~= nil
        and self:ownsLease(self.currentRequestId)
    local isCasting = lib.isCasting()

    if hasActiveBuff or (_buffGemSwap.active and _buffGemSwap.requestedSpell ~= '') then
        holdSpellsetMemorizer('buff_hotswap_active', BUFF_SPELLSET_LEASE_MS)
    end

    -- Once admitted, the executor owns the entire bounded workflow.  The
    -- sensor tick may renew the already-acquired peer reservation, but it must
    -- not rescan, retarget, memorize, close windows, or otherwise mutate game
    -- state outside the exact lease boundary.
    if ownsLease then
        local action = self:getLeaseAction()
        if not actorClaimMatches(action) or not renewActorBuffClaim() then
            self:setIntent(false, nil, 'peer_buff_reservation_lost')
        else
            self:setIntent(true, nil,
                hasActiveBuff and 'buff_workflow_active' or 'buff_lease_granted')
        end
        return
    end

    -- A local memorize/cast effect without the exact lease is quarantined for
    -- coordinator recovery. Do not issue cleanup commands here; a recovery
    -- lease will invoke onLeaseFinalizing before any other worker mutates.
    local previouslyHeldLease = self.activeLeaseSnapshot ~= nil
    if hasActiveBuff or _buffGemSwap.active or previouslyHeldLease then
        local dirtyEffects = (hasActiveBuff and isCasting)
            or _buffGemSwap.active
            or _buffMemEvent.active == true
            or _buffMemEvent.pendingBookClose == true
            or tostring(_buffMemEvent.requestedSpell or '') ~= ''
        _pendingAction = nil
        _pendingReason = nil
        releaseActorBuffClaim('lease_lost')
        self:markDirtyEffects(dirtyEffects)
        if not dirtyEffects then
            self:cancelUnifiedAction('lease_lost')
            ActionExecutor.consumeResult()
            maybeRestoreBuffGem()
            clearActiveBuff()
            clearOwnedMemorizationState()
        end
        self:setIntent(false, nil,
            dirtyEffects and 'buff_effects_need_recovery' or 'buff_lease_lost')
        return
    end

    if not settings then
        debugLog('onTick: No settings, returning')
        _pendingAction = nil
        _pendingReason = nil
        releaseActorBuffClaim('no_settings')
        self:setIntent(false, nil, 'no_settings')
        return
    end

    -- Check if buffing is enabled
    local buffingEnabled = settings.BuffingEnabled
    if buffingEnabled == false or buffingEnabled == 0 then
        _pendingAction = nil
        _pendingReason = nil
        releaseActorBuffClaim('buffing_disabled')
        maybeRestoreBuffGem()
        self:setIntent(false, nil, 'buffing_disabled')
        return
    end

    if manualSpellBookOpen() and not hasActiveBuff then
        _pendingAction = nil
        _pendingReason = nil
        releaseActorBuffClaim('manual_spellbook_open')
        self:setIntent(false, nil, 'manual_spellbook_open')
        return
    end

    debugLog('onTick: isCasting=%s hasActiveBuff=%s ownsLease=%s activeBuff=%s',
        tostring(isCasting), tostring(hasActiveBuff), tostring(ownsLease),
        tostring(_activeBuff.spellName or 'nil'))

    -- Keep a queued request bound to the exact locally-selected action. This
    -- avoids replacing its peer reservation while the coordinator is deciding
    -- when to grant the local lease.
    if self.currentRequestId then
        local reserved = _pendingAction
            and actorClaimMatches(_pendingAction)
            and acquireActorBuffClaim(_pendingAction)
        if not reserved then
            _pendingAction = nil
            _pendingReason = nil
        end
        self:setIntent(reserved == true, nil,
            reserved and 'buff_lease_pending' or 'peer_buff_reservation_lost')
        return
    end

    -- Rate limit selection while keeping a pre-lease peer reservation alive.
    local now = os.clock()
    if (now - _lastBuffTick) < BUFF_TICK_INTERVAL then
        if _pendingAction then
            local reserved, reserveReason = acquireActorBuffClaim(_pendingAction)
            if not reserved then
                _pendingAction = nil
                _pendingReason = nil
                self:setIntent(false, nil, reserveReason or 'peer_buff_reserved')
                return
            end
        end
        self:setIntent(_pendingAction ~= nil, nil,
            _pendingAction and 'pending_buff' or 'scan_throttled')
        return
    end
    _lastBuffTick = now

    -- Find if we have buff work to do
    local need, noNeedReason = findBuffNeed()

    if need then
        local reserved, reserveReason = acquireActorBuffClaim(need)
        if reserved then
            _pendingAction = need
            _pendingReason = 'buff_needed'
        else
            _pendingAction = nil
            _pendingReason = nil
            noNeedReason = reserveReason or 'peer_buff_reserved'
        end
    else
        _pendingAction = nil
        _pendingReason = nil
        releaseActorBuffClaim(noNeedReason or 'no_buff_needed')
    end

    local needsAction = _pendingAction ~= nil
    debugLog('onTick: findBuffNeed=%s needsAction=%s',
        need and need.spellName or 'nil', tostring(needsAction))
    self:setIntent(needsAction, nil,
        needsAction and 'buff_needed' or (noNeedReason or 'no_buff_needed'))

    -- Restore buff gem if no work
    if not needsAction then
        maybeRestoreBuffGem()
    end
end

module.shouldAct = function(self)
    local hasPending = _pendingAction ~= nil
    if hasPending then
        debugLog('shouldAct: hasState=%s hasPending=%s actorReserved=%s',
            tostring(self:hasValidState()), tostring(hasPending),
            tostring(actorClaimMatches(_pendingAction)))
    end
    return self:hasValidState()
        and hasPending
        and actorClaimMatches(_pendingAction)
end

module.getAction = function(self)
    local action = _pendingAction
    if not action then return nil end

    local spellName = action.spellName
    local targetId = tonumber(action.targetId) or 0

    if not spellName or targetId <= 0 then
        return nil
    end

    return {
        kind = lib.ActionKind.CAST_SPELL,
        name = spellName,
        spellName = spellName,
        targetId = targetId,
        targetName = action.targetName,
        needTargetId = action.needTargetId,
        needTargetName = action.needTargetName,
        category = action.category,
        isSelfOnly = action.isSelfOnly,
        isGroup = action.isGroup,
        breaksInvis = true,
        timeoutMs = BUFF_PRECAST_TIMEOUT_MS + BUFF_CAST_TIMEOUT_MS + 5000,
        idempotencyKey = string.format('buff:%s:%d', action.category or 'buff', targetId),
        reason = _pendingReason or 'buff',
    }
end

module.executeAction = function(self)
    debugLog('executeAction: ENTERED')

    -- Revalidate the exact request/lease pair at the execution boundary.
    if not self.currentRequestId or not self:ownsLease(self.currentRequestId) then
        debugLog('executeAction: exact lease not held')
        traceLog('info', 'action', 'action_no_lease', 5,
            'Skipping buff action: exact local lease not held')
        return false, 'no_lease'
    end

    -- The coordinator is action-blind. The selected spell and target remain in
    -- this worker and are recovered only through the exact local request.
    local action = self:getLeaseAction()
    if not action then
        debugLog('executeAction: no local action for lease')
        traceLog('info', 'action', 'action_no_payload', 10,
            'No buff action: local request payload unavailable')
        return false, 'no_action'
    end

    debugLog('executeAction: action=%s target=%d category=%s',
        tostring(action.spellName or action.name),
        tonumber(action.targetId) or 0,
        tostring(action.category))

    if not actorClaimMatches(action) or not renewActorBuffClaim() then
        traceLog('warn', 'coordination',
            'actor_claim_lost_' .. tostring(action.category), 0,
            'Buff action cancelled: peer reservation lost before mutation spell=%s category=%s target=%s',
            tostring(action.spellName or action.name), tostring(action.category),
            tostring(action.needTargetId or action.targetId))
        return true, 'peer_buff_reservation_lost'
    end
    self:renewLease()
    debugLog('executeAction: exact lease and peer reservation OK')

    local settings = syncSettings()
    if not settings or settings.BuffingEnabled == false or settings.BuffingEnabled == 0 then
        traceLog('info', 'action', 'action_disabled', 10,
            'Buff action cancelled: BuffingEnabled=%s', tostring(settings and settings.BuffingEnabled))
        return true, 'disabled'
    end

    local spellName = action.spellName or action.name
    local targetId = tonumber(action.targetId) or 0
    local category = action.category

    if not spellName or targetId <= 0 then
        traceLog('warn', 'action', 'action_invalid', 10,
            'Buff action invalid: spell=%s category=%s target=%s',
            tostring(spellName), tostring(category), tostring(targetId))
        return true, 'invalid_action'
    end

    local recipientId = tonumber(action.needTargetId) or targetId
    if not action.isSelfOnly then
        local recipientLive, recipientReason = isLiveBuffSpawn(recipientId)
        if not recipientLive then
            traceLog('info', 'action', 'action_dead_target_' .. tostring(category), 0,
                'Buff action cancelled: spell=%s category=%s recipient=%s(%d) reason=%s',
                tostring(spellName), tostring(category),
                tostring(action.needTargetName or action.targetName), recipientId,
                tostring(recipientReason))
            _pendingAction = nil
            _pendingReason = nil
            _buffGemSwap.requestedSpell = ''
            maybeRestoreBuffGem()
            clearActiveBuff()
            self:setIntent(false, nil, 'buff_target_invalid:' .. tostring(recipientReason))
            return true, recipientReason
        end
    end

    local levelUsable, requiredLevel, currentLevel = spellUsableAtCurrentLevel(spellName)
    if not levelUsable then
        if category then _buffDefinitions[category] = nil end
        _lastBuffScanReason = string.format('level_too_low:%s:%d/%d',
            tostring(spellName), currentLevel, requiredLevel)
        clearBuffFailure(category)
        _pendingAction = nil
        _pendingReason = nil
        _buffGemSwap.requestedSpell = ''
        clearActiveBuff()
        self:setIntent(false, nil, 'buff_level_too_low')
        traceLog('warn', 'action', 'action_level_too_low_' .. tostring(category), 0,
            'Buff action rejected before cast: spell=%s category=%s requiredLevel=%d currentLevel=%d',
            tostring(spellName), tostring(category), requiredLevel, currentLevel)
        return true, 'spell_level_too_low'
    end

    local Buff = getBuff()

    -- Check if we're already working on this buff (subsequent tick calls)
    if _activeBuff.category == category and _activeBuff.spellName == spellName then
        renewActorBuffClaim()
        self:renewLease()
        if activeBuffTimedOut() then
            local waitReason = _activeBuff.waitReason or _activeBuff.state or 'unknown'
            lib.log('warn', self.name,
                'Buff timed out: %s (state=%s reason=%s); releasing lease and backing off',
                spellName, tostring(_activeBuff.state), tostring(waitReason))
            traceLog('warn', 'action', 'timeout_' .. tostring(category), 0,
                'Buff action timed out: spell=%s category=%s target=%d state=%s waitReason=%s elapsedMs=%d',
                tostring(spellName), tostring(category), targetId, tostring(_activeBuff.state), tostring(waitReason),
                lib.getTimeMs() - (_activeBuff.startedAtMs or 0))
            recordBuffFailure(category, waitReason)
            _pendingAction = nil
            _pendingReason = nil
            _buffGemSwap.requestedSpell = ''
            self:setIntent(false, nil, 'buff_timeout:' .. tostring(spellName))
            return true, 'buff_timeout'
        end

        local isCasting = lib.isCasting()
        debugLog('executeAction: Checking active buff, state=%s isCasting=%s', tostring(_activeBuff.state), tostring(isCasting))

        if _activeBuff.state == 'memorizing' then
            -- Still waiting for spell to memorize
            local memorized, waitReason = ensureBuffSpellMemorized(spellName)
            _activeBuff.waitReason = waitReason
            if not memorized then
                debugLog('executeAction: Still memorizing (%s)', tostring(waitReason))
                traceLog('info', 'action', 'memorizing_' .. tostring(category) .. '_' .. tostring(waitReason), 5,
                    'Waiting on buff memorization: spell=%s category=%s target=%d reason=%s',
                    tostring(spellName), tostring(category), targetId, tostring(waitReason))
                return false, waitReason or 'memorizing'
            end
            _activeBuff.state = 'waiting_ready'
            _activeBuff.waitReason = 'spell_not_ready'
            traceLog('info', 'action', 'memorized_' .. tostring(category), 0,
                'Buff spell memorized: spell=%s category=%s target=%d', tostring(spellName), tostring(category), targetId)
        end

        if _activeBuff.state == 'waiting_ready' then
            -- Invis re-check at the last gate before the cast. canBuffNow()
            -- blocks SELECTION while invis, but the memorize/gem-swap workflow
            -- can run for many seconds — an invis applied mid-workflow (e.g.
            -- the group invises up to travel) would be silently broken by the
            -- cast. Abort without a category backoff: it's not the spell's
            -- fault, and selection stays blocked until invis drops.
            if mq.TLO.Me.Invis and mq.TLO.Me.Invis() then
                traceLog('info', 'action', 'invis_hold_' .. tostring(category), 0,
                    'Buff cast aborted: we are invis; spell=%s category=%s target=%d',
                    tostring(spellName), tostring(category), targetId)
                _pendingAction = nil
                _pendingReason = nil
                maybeRestoreBuffGem()
                clearActiveBuff()
                return true, 'invis_hold'
            end
            -- Memorization completed; wait for the gem refresh separately so
            -- we do not keep treating a ready-delay as another mem request.
            local canCast, castWaitReason = canCastAfterMemorize(spellName)
            _activeBuff.waitReason = castWaitReason
            if not canCast then
                debugLog('executeAction: Memorized but not ready yet')
                traceLog('info', 'action', 'not_ready_' .. tostring(category) .. '_' .. tostring(castWaitReason), 1,
                    'Waiting before buff cast: spell=%s category=%s target=%d reason=%s spellReady=%s spellBookOpen=%s elapsedSinceMemMs=%d',
                    tostring(spellName), tostring(category), targetId, tostring(castWaitReason),
                    tostring(isSpellReady(spellName)), tostring(isWindowOpen('SpellBookWnd')),
                    lib.getTimeMs() - (_buffGemSwap.lastMemAt or 0))
                return false, castWaitReason or 'spell_not_ready'
            end
            -- Ready to cast - ensure correct target first
            if not action.isGroup then
                if not ensureTarget(targetId) then
                    debugLog('executeAction: Failed to target %d for cast', targetId)
                    traceLog('warn', 'action', 'target_failed_' .. tostring(category), 5,
                        'Buff cast target failed: spell=%s category=%s target=%d',
                        tostring(spellName), tostring(category), targetId)
                    return false, 'target_failed'
                end
            end
            debugLog('executeAction: Spell ready, sending cast command')
            traceLog('info', 'action', 'cast_start_' .. tostring(category), 0,
                'Sending buff cast command: spell=%s category=%s target=%d isGroup=%s',
                tostring(spellName), tostring(category), targetId, tostring(action.isGroup))
            _activeBuff.state = 'cast_starting'
            _activeBuff.startedAtMs = lib.getTimeMs()
            _activeBuff.waitReason = nil
            local issued, issueReason, gemIndex = issueBuffCast(spellName)
            if not issued then
                recordBuffFailure(category, issueReason)
                _pendingAction = nil
                _pendingReason = nil
                clearActiveBuff()
                return true, issueReason
            end
            traceLog('info', 'action', 'cast_issued_gem_' .. tostring(category), 0,
                'Buff cast issued from gem: spell=%s category=%s gem=%d',
                tostring(spellName), tostring(category), gemIndex)
            return false, 'cast_starting'

        elseif _activeBuff.state == 'cast_starting' then
            if isCasting then
                _activeBuff.state = 'casting'
                _activeBuff.startedAtMs = lib.getTimeMs()
                traceLog('info', 'action', 'cast_confirmed_' .. tostring(category), 0,
                    'Buff cast confirmed started: spell=%s category=%s target=%d',
                    tostring(spellName), tostring(category), targetId)
                return false, 'casting'
            end

            local eventFailure = getBuffCastEventFailure()
            if eventFailure then
                traceLog('warn', 'action', 'cast_event_failure_' .. tostring(category), 0,
                    'Buff cast rejected by game: spell=%s category=%s target=%d reason=%s',
                    tostring(spellName), tostring(category), targetId, tostring(eventFailure))
                recordBuffFailure(category, eventFailure)
                _pendingAction = nil
                _pendingReason = nil
                clearActiveBuff()
                return true, eventFailure
            end

            local elapsedMs = lib.getTimeMs() - (_activeBuff.startedAtMs or 0)
            if elapsedMs < BUFF_CAST_START_TIMEOUT_MS then
                traceLog('info', 'action', 'cast_start_wait_' .. tostring(category), 1,
                    'Waiting for buff cast to start: spell=%s category=%s target=%d elapsedMs=%d',
                    tostring(spellName), tostring(category), targetId, elapsedMs)
                return false, 'cast_starting'
            end

            traceLog('warn', 'action', 'cast_not_started_' .. tostring(category), 0,
                'Buff cast did not start after /cast: spell=%s category=%s target=%d elapsedMs=%d spellReady=%s spellBookOpen=%s',
                tostring(spellName), tostring(category), targetId, elapsedMs, tostring(isSpellReady(spellName)),
                tostring(isWindowOpen('SpellBookWnd')))
            recordBuffFailure(category, 'cast_did_not_start')
            _pendingAction = nil
            _pendingReason = nil
            clearActiveBuff()
            return true, 'cast_did_not_start'

        elseif _activeBuff.state == 'casting' then
            -- Check if still casting
            if isCasting then
                debugLog('executeAction: Still casting')
                traceLog('info', 'action', 'casting_' .. tostring(category), 5,
                    'Buff cast in progress: spell=%s category=%s target=%d',
                    tostring(spellName), tostring(category), targetId)
                return false, 'casting'
            else
                -- Cast finished (or was interrupted)
                debugLog('executeAction: Cast finished, completing')
                local spellId = getSpellId(spellName)
                local landed, verifySource = directBuffPresentOnTarget(targetId, spellName, spellId, action.isGroup)
                if not landed then
                    traceLog('warn', 'action', 'cast_no_landing_' .. tostring(category), 0,
                        'Buff cast ended but buff was not observed: spell=%s category=%s target=%d isGroup=%s verifySource=%s',
                        tostring(spellName), tostring(category), targetId, tostring(action.isGroup), tostring(verifySource))
                    recordBuffFailure(category, 'buff_not_observed_after_cast')
                    _pendingAction = nil
                    _pendingReason = nil
                    clearActiveBuff()
                    return true, 'buff_not_observed_after_cast'
                end

                lib.log('info', self.name, 'Buff cast completed: %s on %d', spellName, targetId)
                traceLog('info', 'action', 'cast_complete_' .. tostring(category), 0,
                    'Buff cast completed: spell=%s category=%s target=%d isGroup=%s',
                    tostring(spellName), tostring(category), targetId, tostring(action.isGroup))

                -- Track the buff with the caster-specific duration (accounts
                -- for our level + focus). Passing nil here used to fall through
                -- to trackLocalBuff's 1200s default, which suppressed rebuff
                -- for up to 20 min regardless of the real spell duration.
                if Buff and Buff.trackLocalBuff then
                    local duration = Buff.getMySpellDuration and Buff.getMySpellDuration(spellName) or nil
                    if action.isGroup then
                        local tracked = 0
                        local myId = lib.safeNum(function() return mq.TLO.Me.ID() end, 0)
                        for _, candidate in ipairs(groupBuffCandidates(myId)) do
                            local candidateId = tonumber(candidate.id) or 0
                            if candidateId > 0 then
                                Buff.trackLocalBuff(candidateId, category, spellId, spellName, duration)
                                tracked = tracked + 1
                            end
                        end
                        diagLog('track_local_' .. tostring(category), 0,
                            'trackLocalBuff group spell="%s" spellId=%s category=%s tracked=%d duration=%s castTargetId=%s',
                            tostring(spellName), tostring(spellId), tostring(category), tracked,
                            tostring(duration), tostring(targetId))
                    else
                        diagLog('track_local_' .. tostring(category), 0,
                            'trackLocalBuff spell="%s" spellId=%s category=%s targetId=%s duration=%s isGroup=%s',
                            tostring(spellName), tostring(spellId), tostring(category), tostring(targetId),
                            tostring(duration), tostring(action.isGroup))
                        Buff.trackLocalBuff(targetId, category, spellId, spellName, duration)
                    end
                end

                -- Track group cast cooldown
                if action.isGroup then
                    _lastGroupCastAt[category] = os.clock()
                end

                clearBuffFailure(category)
                clearActiveBuff()
                return true, 'completed'
            end
        else
            -- Unknown state, restart
            debugLog('executeAction: Unknown state, clearing')
            traceLog('warn', 'action', 'unknown_state_' .. tostring(category), 0,
                'Clearing buff action with unknown active state: spell=%s category=%s state=%s',
                tostring(spellName), tostring(category), tostring(_activeBuff.state))
            clearActiveBuff()
        end
    end

    -- First time executing this action - set up and start cast
    debugLog('executeAction: First time - setting up cast for %s', spellName)
    traceLog('info', 'action', 'action_start_' .. tostring(category), 0,
        'Starting buff action: spell=%s category=%s target=%d targetName=%s isGroup=%s fromRequest=%s',
        tostring(spellName), tostring(category), targetId, tostring(action.targetName),
        tostring(action.isGroup), tostring(action.fromRequest))

    -- Set active buff state to 'memorizing' - the state machine above will handle the rest
    setActiveBuff(category, spellName, targetId, 'memorizing')
    debugLog('executeAction: Active buff set, starting memorization')
    traceLog('info', 'action', 'mem_start_' .. tostring(category), 0,
        'Requesting buff memorization: spell=%s category=%s target=%d reservedGem=%d',
        tostring(spellName), tostring(category), targetId, getReservedBuffGem())

    -- Start memorizing the spell
    local memorized, waitReason = ensureBuffSpellMemorized(spellName)
    _activeBuff.waitReason = waitReason
    if not memorized then
        debugLog('executeAction: Spell not memorized yet (%s)', tostring(waitReason))
        traceLog('info', 'action', 'mem_wait_' .. tostring(category) .. '_' .. tostring(waitReason), 5,
            'Buff spell not memorized yet: spell=%s category=%s target=%d reason=%s',
            tostring(spellName), tostring(category), targetId, tostring(waitReason))
        return false, waitReason or 'memorizing'
    end

    -- If already memorized, check if ready to cast
    _activeBuff.state = 'waiting_ready'
    _activeBuff.waitReason = 'spell_not_ready'
    local canCast, castWaitReason = canCastAfterMemorize(spellName)
    _activeBuff.waitReason = castWaitReason
    if canCast then
        -- Ensure correct target before casting
        if not action.isGroup then
            if not ensureTarget(targetId) then
                debugLog('executeAction: Failed to target %d for cast', targetId)
                traceLog('warn', 'action', 'target_failed_ready_' .. tostring(category), 5,
                    'Buff cast target failed after ready: spell=%s category=%s target=%d',
                    tostring(spellName), tostring(category), targetId)
                return false, 'target_failed'
            end
        end
        debugLog('executeAction: Spell already ready, sending cast command')
        traceLog('info', 'action', 'cast_start_ready_' .. tostring(category), 0,
            'Sending buff cast command immediately: spell=%s category=%s target=%d isGroup=%s',
            tostring(spellName), tostring(category), targetId, tostring(action.isGroup))
        _activeBuff.state = 'cast_starting'
        _activeBuff.startedAtMs = lib.getTimeMs()
        _activeBuff.waitReason = nil
        local issued, issueReason, gemIndex = issueBuffCast(spellName)
        if not issued then
            recordBuffFailure(category, issueReason)
            _pendingAction = nil
            _pendingReason = nil
            clearActiveBuff()
            return true, issueReason
        end
        traceLog('info', 'action', 'cast_issued_gem_' .. tostring(category), 0,
            'Buff cast issued from gem: spell=%s category=%s gem=%d',
            tostring(spellName), tostring(category), gemIndex)
        return false, 'cast_starting'
    end

    debugLog('executeAction: Spell memorized but not ready/safe, returning false/%s', tostring(castWaitReason))
    traceLog('info', 'action', 'mem_ready_wait_' .. tostring(category) .. '_' .. tostring(castWaitReason), 1,
        'Buff spell memorized but not safe to cast: spell=%s category=%s target=%d reason=%s spellReady=%s spellBookOpen=%s elapsedSinceMemMs=%d',
        tostring(spellName), tostring(category), targetId, tostring(castWaitReason),
        tostring(isSpellReady(spellName)), tostring(isWindowOpen('SpellBookWnd')),
        lib.getTimeMs() - (_buffGemSwap.lastMemAt or 0))
    return false, castWaitReason or 'spell_not_ready'
end

local function ownedBuffCastInProgress()
    if not lib.isCasting() or not _activeBuff.category then return false end
    if _activeBuff.state == 'casting' or _activeBuff.state == 'cast_starting' then
        return true
    end

    local expected = normalizeSpellName(_activeBuff.spellName)
    local actual = normalizeSpellName(lib.safeTLO(function()
        return mq.TLO.Me.Casting()
    end, ''))
    return expected ~= ''
        and actual ~= ''
        and (actual == expected
            or actual:find(expected, 1, true) ~= nil
            or expected:find(actual, 1, true) ~= nil)
end

module.onLeaseFinalizing = function(self, _, reason)
    local exactLease = self.currentRequestId ~= nil
        and self:ownsLease(self.currentRequestId)
    local ownedCasting = ownedBuffCastInProgress()
    local ownsSpellbookEffect = _buffGemSwap.active
        or _buffMemEvent.active == true
        or _buffMemEvent.pendingBookClose == true
        or tostring(_buffMemEvent.requestedSpell or '') ~= ''
    local spellbookOpen = ownsSpellbookEffect and isWindowOpen('SpellBookWnd')

    -- A stale snapshot is sufficient to report/release an old lease, but not
    -- to mutate the game. Preserve effect markers and ask the coordinator for
    -- a recovery lease; that lease will re-enter this finalizer with exact
    -- ownership.
    if not exactLease and (ownedCasting or spellbookOpen or _buffGemSwap.active) then
        self:markDirtyEffects(true)
        releaseActorBuffClaim(reason or 'lease_lost')
        return true
    end

    if exactLease and ownedCasting then
        self:markDirtyEffects(true)
        lib.safeTLO(function()
            local me = mq.TLO.Me
            if me and me() and me.StopCast then me.StopCast() end
            return true
        end, false)
        return false, 'stopping_buff_cast'
    end

    if exactLease and spellbookOpen then
        self:markDirtyEffects(true)
        closeSpellBookIfOpen('lease_finalizing')
        if isWindowOpen('SpellBookWnd') then
            return false, 'closing_buff_spellbook'
        end
    end

    if exactLease and ActionExecutor.hasActiveJob() then
        ActionExecutor.cancel(reason or 'lease_finalized')
    end
    if exactLease then ActionExecutor.consumeResult() end

    releaseActorBuffClaim(reason or 'lease_finalized')
    _pendingAction = nil
    _pendingReason = nil
    maybeRestoreBuffGem()
    clearActiveBuff()
    clearOwnedMemorizationState()
    self:markDirtyEffects(false)
    return true
end

local baseWithdrawLeaseRequest = module.withdrawLeaseRequest
module.withdrawLeaseRequest = function(self, reason)
    if not self.currentRequestId or not self:ownsLease(self.currentRequestId) then
        releaseActorBuffClaim(reason or 'lease_request_withdrawn')
        _pendingAction = nil
        _pendingReason = nil
    end
    return baseWithdrawLeaseRequest(self, reason)
end

-------------------------------------------------------------------------------
-- Command Binding
-------------------------------------------------------------------------------

mq.bind('/sk_buffs', function(cmd, arg)
    cmd = tostring(cmd or '')
    arg = tostring(arg or '')
    if arg == '' and cmd:find('%s') then
        local first, rest = cmd:match('^(%S+)%s+(.+)$')
        cmd = first or cmd
        arg = rest or ''
    end
    cmd = cmd:lower()
    arg = arg:lower()
    if cmd == 'stop' then
        module:stop()
        lib.log('info', module.name, 'Stop requested')
        commandEcho('Stop requested')
    elseif cmd == 'status' then
        local settings = syncSettings()
        local defCount = countBuffDefinitions()
        local failureCount = 0
        for _ in pairs(_buffFailures) do failureCount = failureCount + 1 end
        local statusReason = _lastBuffScanReason
        if _activeBuff.category then
            statusReason = string.format('active_%s:%s',
                tostring(_activeBuff.state or 'unknown'),
                tostring(_activeBuff.waitReason or _activeBuff.spellName or 'unknown'))
        end
        local ownsLease = module:ownsLease(module.currentRequestId)
        local actorClaim = string.format('%s:%s/%s',
            tostring(_actorBuffClaim.targetId or 0),
            tostring(_actorBuffClaim.category or 'none'),
            tostring(_actorBuffClaim.acquired))
        lib.log('info', module.name, 'running=%s, hasState=%s, tier=%s, requestId=%s, leasePending=%s, ownsLease=%s, actorClaim=%s, buffingEnabled=%s, defs=%d, reason=%s, active=%s:%s/%s, failures=%d',
            tostring(module.running),
            tostring(module:hasValidState()),
            tostring(module.priority),
            tostring(module.currentRequestId),
            tostring(module.requestPending),
            tostring(ownsLease),
            actorClaim,
            tostring(settings.BuffingEnabled),
            defCount,
            tostring(statusReason),
            tostring(_activeBuff.category),
            tostring(_activeBuff.spellName),
            tostring(_activeBuff.state),
            failureCount)
        commandEcho('running=%s hasState=%s tier=%s requestId=%s leasePending=%s ownsLease=%s actorClaim=%s enabled=%s defs=%d reason=%s active=%s:%s/%s wait=%s failures=%d debug=%s',
            tostring(module.running),
            tostring(module:hasValidState()),
            tostring(module.priority),
            tostring(module.currentRequestId),
            tostring(module.requestPending),
            tostring(ownsLease),
            actorClaim,
            tostring(settings.BuffingEnabled),
            defCount,
            tostring(statusReason),
            tostring(_activeBuff.category),
            tostring(_activeBuff.spellName),
            tostring(_activeBuff.state),
            tostring(_activeBuff.waitReason),
            failureCount,
            tostring(buffDebugEnabled()))
        for category, failure in pairs(_buffFailures) do
            commandEcho('backoff category=%s reason=%s failures=%d retryInMs=%d',
                tostring(category), tostring(failure.reason), tonumber(failure.count) or 0,
                math.max(0, (tonumber(failure.retryAtMs) or 0) - lib.getTimeMs()))
        end
        traceLog('info', 'command', 'status', 0,
            'Status requested: running=%s hasState=%s tier=%s requestId=%s leasePending=%s ownsLease=%s actorClaim=%s buffingEnabled=%s defs=%d reason=%s active=%s:%s state=%s wait=%s failures=%d',
            tostring(module.running), tostring(module:hasValidState()), tostring(module.priority),
            tostring(module.currentRequestId), tostring(module.requestPending), tostring(ownsLease),
            actorClaim, tostring(settings.BuffingEnabled), defCount, tostring(statusReason),
            tostring(_activeBuff.category), tostring(_activeBuff.spellName), tostring(_activeBuff.state),
            tostring(_activeBuff.waitReason), failureCount)
    elseif cmd == 'reload' then
        local clearedFailures = clearAllBuffFailures()
        _persistenceLoaded = false
        loadBuffDefinitions()
        clearBuffTrackingCache()
        lib.log('info', module.name, 'Buff definitions reloaded: defs=%d reason=%s', countBuffDefinitions(), tostring(_lastBuffScanReason))
        commandEcho('Reloaded buff definitions/cache and cleared %d backoff(s): defs=%d reason=%s',
            clearedFailures, countBuffDefinitions(), tostring(_lastBuffScanReason))
        traceLog('info', 'command', 'reload', 0,
            'Reload requested: defs=%d reason=%s clearedFailures=%d',
            countBuffDefinitions(), tostring(_lastBuffScanReason), clearedFailures)
    elseif cmd == 'retry' then
        local clearedFailures = clearAllBuffFailures()
        if not lib.isCasting() then
            _pendingAction = nil
            _pendingReason = nil
            module:setIntent(false, nil, 'manual_buff_retry')
            module:cancelUnifiedAction('manual_buff_retry')
            if module.currentRequestId then
                if module:ownsLease(module.currentRequestId) then
                    module:finishAction({
                        phase = 'cancelled',
                        reason = 'manual_buff_retry',
                    })
                else
                    module:withdrawLeaseRequest('manual_buff_retry')
                end
            else
                releaseActorBuffClaim('manual_buff_retry')
                if (_buffGemSwap.active
                        or _buffMemEvent.active == true
                        or _buffMemEvent.pendingBookClose == true)
                    and isWindowOpen('SpellBookWnd') then
                    closeSpellBookIfOpen('manual_buff_retry')
                end
                maybeRestoreBuffGem()
                clearActiveBuff()
                clearOwnedMemorizationState()
                module:markDirtyEffects(false)
            end
        end
        commandEcho('Cleared %d buff backoff(s); buff scan will retry', clearedFailures)
        traceLog('info', 'command', 'retry', 0,
            'Manual retry requested: clearedFailures=%d casting=%s',
            clearedFailures, tostring(lib.isCasting()))
    elseif cmd == 'dump' then
        dumpBuffDefinitions()
        lib.log('info', module.name, 'Buff dump written to BuffLogs')
        commandEcho('Buff dump written to %s/BuffLogs', tostring(mq.configDir or 'config'))
    elseif cmd == 'clearcache' then
        clearBuffTrackingCache()
        commandEcho('Cleared local buff tracking cache')
    elseif cmd == 'debug' then
        _buffDebugEnabled = (arg == 'on' or arg == '1' or arg == 'true')
        _diagThrottle = {}
        _traceThrottle = {}
        local BuffLogger = getBuffLogger()
        if BuffLogger and BuffLogger.init then
            BuffLogger.init({ level = 'debug', enabled = true })
        end
        lib.log('info', module.name, 'Buff diagnostics %s', _buffDebugEnabled and 'enabled' or 'disabled')
        commandEcho('Buff diagnostics %s', _buffDebugEnabled and 'enabled' or 'disabled')
        traceLog('info', 'command', 'debug', 0,
            'Buff diagnostics %s', _buffDebugEnabled and 'enabled' or 'disabled')
    else
        lib.log('info', module.name, 'Usage: /sk_buffs status|reload|retry|dump|clearcache|debug on|debug off|stop')
        commandEcho('Usage: /sk_buffs status|reload|retry|dump|clearcache|debug on|debug off|stop')
    end
end)

-------------------------------------------------------------------------------
-- Initialize and Run
-------------------------------------------------------------------------------

-- Get self name on load
local me = mq.TLO.Me
if me and me() then
    _selfName = me.CleanName and me.CleanName() or ''
end

-- Load initial buff definitions
registerMemorizationEvents()
loadBuffDefinitions()

module:enableUnifiedExecutor({
    dispatch = function(_, self)
        local completed, reason = self.executeAction(self)
        if completed then return true, reason or 'completed', 'none' end
        return true, reason or 'buff_workflow_started', 'custom'
    end,
    onTick = function(_, self)
        local completed, reason = self.executeAction(self)
        if completed then return true, reason or 'completed', 'completed' end
        return true, reason
    end,
    onFailure = function(_, self)
        _pendingAction = nil
        _pendingReason = nil
        self:setIntent(false, nil, 'buff_executor_failed')
    end,
    onCancel = function(_, self)
        _pendingAction = nil
        _pendingReason = nil
        self:setIntent(false, nil, 'buff_executor_cancelled')
    end,
})

module:enablePeerActors()
module:run(50)

return module
