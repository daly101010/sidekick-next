-- F:/lua/sidekick-next/sk_buffs.lua
-- Buff module for SideKick multi-script system
-- Priority 6: OOC buff casting through coordinator claims
-- Maintains cross-character coordination via Actors

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local lazy = require('sidekick-next.utils.lazy_require')

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
local CLAIM_TIMEOUT = 8.0                  -- Claims expire after 8 seconds
local PENDING_BUFF_WINDOW = 8.0            -- Seconds to treat a buff as present after cast
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

-------------------------------------------------------------------------------
-- Helper Functions
-------------------------------------------------------------------------------

local function diagLog(key, intervalSec, fmt, ...)
    if not _buffDebugEnabled then return end

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

local function traceLog(level, category, key, intervalSec, fmt, ...)
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
        if BuffLogger.init then BuffLogger.init({ level = _buffDebugEnabled and 'debug' or 'info', enabled = true }) end
        local writer = BuffLogger[level or 'info'] or BuffLogger.info
        if writer then writer(category or 'trace', '%s', msg) end
    end

    -- Keep normal operation quiet, but make failures visible without requiring
    -- the user to find a file. Debug mode mirrors the throttled trace stream to
    -- the MQ console so selection -> claim -> memorize -> cast can be followed.
    if _buffDebugEnabled or level == 'warn' or level == 'error' then
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
    elseif _buffDebugEnabled then
        lib.log('info', module.name, '%s', msg)
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
            local id = tonumber(member.ID()) or 0
            if id > 0 and id ~= myId then
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

    if _buffDebugEnabled then
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
    local previous = _buffFailures[category]
    local count = previous and (previous.count or 0) + 1 or 1
    local multiplier = 2 ^ math.min(count - 1, 4)
    local delayMs = math.min(BUFF_FAILURE_BACKOFF_MS * multiplier, BUFF_FAILURE_BACKOFF_MAX_MS)
    _buffFailures[category] = {
        count = count,
        retryAtMs = lib.getTimeMs() + delayMs,
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
        -- A completed retry window starts a fresh attempt. Keeping the old
        -- count made failures hours apart compound into multi-minute backoffs.
        clearBuffFailure(category)
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

    -- Check if stunned/mezzed
    if me.Stunned and me.Stunned() then return false, 'stunned' end
    if me.Mezzed and me.Mezzed() then return false, 'mezzed' end

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
                -- Self-only spells can only satisfy a request from us.
                if isSelfOnly and castableTarget ~= myId then
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
                    if _buffDebugEnabled then
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
    if _buffMemEvent.pendingBookClose then
        if closeSpellBookIfOpen('mem_event_end') then
            traceLog('info', 'action', 'mem_event_book_close', 1,
                'Closing spellbook after memorization event: spell=%s',
                tostring(_buffMemEvent.endSpell or _buffMemEvent.requestedSpell))
        else
            _buffMemEvent.pendingBookClose = false
        end
    end

    local settings = syncSettings()
    local Cache = getCache()
    if Cache then
        if Cache.setSettings then Cache.setSettings(settings) end
        if Cache.tick then Cache.tick() end
    end
    local Buff = getBuff()
    if Buff and Buff.tick then Buff.tick() end
    if not settings then
        debugLog('onTick: No settings, returning')
        _pendingAction = nil
        self:sendNeed(false, nil, 'no_settings')
        return
    end

    -- Check if buffing is enabled
    local buffingEnabled = settings.BuffingEnabled
    if buffingEnabled == false or buffingEnabled == 0 then
        _pendingAction = nil
        maybeRestoreBuffGem()
        self:sendNeed(false, nil, 'buffing_disabled')
        return
    end

    -- IMPORTANT: Check if we're actively casting a buff BEFORE anything else
    -- This ensures we keep sending need hints while casting, regardless of ownership state
    local isCasting = lib.isCasting()
    local hasActiveBuff = _activeBuff.category and _activeBuff.spellName
    local ownsCast = self:ownsCast()

    if hasActiveBuff or (_buffGemSwap.active and _buffGemSwap.requestedSpell ~= '') then
        holdSpellsetMemorizer('buff_hotswap_active', BUFF_SPELLSET_LEASE_MS)
    end

    if manualSpellBookOpen() and not hasActiveBuff then
        _pendingAction = nil
        self:sendNeed(false, nil, 'manual_spellbook_open')
        return
    end

    debugLog('onTick: isCasting=%s hasActiveBuff=%s ownsCast=%s activeBuff=%s',
        tostring(isCasting), tostring(hasActiveBuff), tostring(ownsCast),
        tostring(_activeBuff.spellName or 'nil'))

    if hasActiveBuff and isCasting then
        debugLog('onTick: Sending NEED=true (actively casting)')
        self:sendNeed(true, 5000, 'casting_buff')  -- Long TTL while casting
        return
    end

    -- An active local action is only allowed to live while its coordinator
    -- claim does. If the coordinator revoked/expired the claim before the cast
    -- began, discard the orphaned state so the next scan starts a clean attempt.
    if hasActiveBuff and not ownsCast then
        traceLog('warn', 'action', 'active_ownership_lost_' .. tostring(_activeBuff.category), 0,
            'Clearing orphaned buff action after ownership loss: spell=%s category=%s state=%s waitReason=%s',
            tostring(_activeBuff.spellName), tostring(_activeBuff.category), tostring(_activeBuff.state),
            tostring(_activeBuff.waitReason))
        _pendingAction = nil
        _pendingReason = nil
        _buffGemSwap.requestedSpell = ''
        clearActiveBuff()
        self:sendNeed(false, nil, 'buff_ownership_lost')
        return
    end

    -- Also check cast ownership (in case _activeBuff got cleared but we still own)
    if ownsCast then
        debugLog('onTick: Sending NEED=true (owns cast)')
        self:sendNeed(true, 5000, 'owns_cast')  -- Long TTL while casting
        return
    end

    -- Rate limit buff tick (only for finding new buffs, not for maintaining cast ownership)
    local now = os.clock()
    if (now - _lastBuffTick) < BUFF_TICK_INTERVAL then
        -- Still send need if we have pending action
        if _pendingAction then
            self:sendNeed(true, 1000, 'pending_buff')
        end
        return
    end
    _lastBuffTick = now

    -- Find if we have buff work to do
    local need, noNeedReason = findBuffNeed()

    _pendingAction = need
    _pendingReason = need and 'buff_needed' or nil

    local needsAction = need ~= nil
    debugLog('onTick: findBuffNeed=%s needsAction=%s',
        need and need.spellName or 'nil', tostring(needsAction))
    self:sendNeed(needsAction, needsAction and 1500 or nil, needsAction and 'buff_needed' or (noNeedReason or 'no_buff_needed'))

    -- Handle gem memorization while waiting
    if _buffGemSwap.active and _buffGemSwap.requestedSpell ~= '' then
        local reservedGem = getReservedBuffGem()
        local current = getGemSpellName(reservedGem)
        if current ~= _buffGemSwap.requestedSpell then
            if _activeBuff.category and _activeBuff.spellName then
                if activeBuffTimedOut() then return end
            end
            local _, waitReason = ensureBuffSpellMemorized(_buffGemSwap.requestedSpell)
            _activeBuff.waitReason = waitReason
            return
        end
    end

    -- Handle active buff timeout
    if _activeBuff.category and _activeBuff.spellName then
        if activeBuffTimedOut() then return end
    end

    -- Restore buff gem if no work
    if not needsAction then
        maybeRestoreBuffGem()
    end
end

module.shouldAct = function(self)
    local hasState = self:hasValidState()
    local isMyPrio = hasState and self:isMyPriority() or false
    local hasPending = _pendingAction ~= nil
    local result = hasState and isMyPrio and hasPending
    if hasPending then
        debugLog('shouldAct: hasState=%s isMyPriority=%s hasPending=%s -> %s',
            tostring(hasState), tostring(isMyPrio), tostring(hasPending), tostring(result))
    end
    if not hasState then return false end
    if not isMyPrio then return false end
    return hasPending
end

module.getAction = function(self)
    local action = _pendingAction
    if not action then return nil end

    local spellName = action.spellName
    local targetId = tonumber(action.targetId) or 0

    if not spellName or targetId <= 0 then
        return nil
    end

    local me = mq.TLO.Me
    local myId = me and me.ID and me.ID() or 0

    -- Determine claim type:
    -- - Self/group buffs: CAST-only (target is self or doesn't matter)
    -- - Single-target on others: Full ACTION claim (need target)
    local claimType = lib.ClaimType.CAST
    if not action.isSelfOnly and not action.isGroup and targetId ~= myId then
        claimType = lib.ClaimType.ACTION
    end

    return {
        kind = lib.ActionKind.CAST_SPELL,
        type = claimType,
        name = spellName,
        spellName = spellName,
        targetId = targetId,
        targetName = action.targetName,
        category = action.category,
        isSelfOnly = action.isSelfOnly,
        isGroup = action.isGroup,
        timeoutMs = BUFF_PRECAST_TIMEOUT_MS + BUFF_CAST_START_TIMEOUT_MS + 5000,
        idempotencyKey = string.format('buff:%s:%d', action.category or 'buff', targetId),
        reason = _pendingReason or 'buff',
    }
end

module.executeAction = function(self)
    debugLog('executeAction: ENTERED')

    -- For buff claims, we need to handle differently based on claim type
    -- NOTE: explicit nil checks required — actors state can update between
    -- the ownsAction() guard in module_base and this access (file I/O in
    -- debugLog above can allow actors callbacks to deliver new state).
    if not self.state then
        debugLog('executeAction: no state')
        traceLog('info', 'action', 'action_no_state', 10, 'No buff action: coordinator state unavailable')
        return false, 'no_action'
    end
    local castOwner = self.state.castOwner
    if not castOwner then
        debugLog('executeAction: no castOwner in state')
        traceLog('info', 'action', 'action_no_cast_owner', 10, 'No buff action: no cast owner in coordinator state')
        return false, 'no_action'
    end
    local action = castOwner.action
    if not action then
        debugLog('executeAction: no action in castOwner')
        traceLog('info', 'action', 'action_no_payload', 10, 'No buff action: cast owner has no action payload')
        return false, 'no_action'
    end

    debugLog('executeAction: action=%s target=%d category=%s',
        tostring(action.spellName or action.name),
        tonumber(action.targetId) or 0,
        tostring(action.category))

    -- Check ownership based on what we requested
    local needsTargetOwnership = action.type == lib.ClaimType.ACTION
    if needsTargetOwnership then
        if not self:ownsAction() then
            debugLog('executeAction: no action ownership')
            traceLog('info', 'action', 'action_no_ownership_' .. tostring(action.category), 5,
                'Skipping buff action: no action ownership spell=%s category=%s target=%s',
                tostring(action.spellName or action.name), tostring(action.category), tostring(action.targetId))
            return false, 'no_ownership'
        end
    else
        if not self:ownsCast() then
            debugLog('executeAction: no cast ownership')
            traceLog('info', 'action', 'action_no_cast_ownership_' .. tostring(action.category), 5,
                'Skipping buff action: no cast ownership spell=%s category=%s target=%s',
                tostring(action.spellName or action.name), tostring(action.category), tostring(action.targetId))
            return false, 'no_cast_ownership'
        end
    end
    debugLog('executeAction: ownership OK')

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
        self:sendNeed(false, nil, 'buff_level_too_low')
        traceLog('warn', 'action', 'action_level_too_low_' .. tostring(category), 0,
            'Buff action rejected before cast: spell=%s category=%s requiredLevel=%d currentLevel=%d',
            tostring(spellName), tostring(category), requiredLevel, currentLevel)
        return true, 'spell_level_too_low'
    end

    local Buff = getBuff()

    -- Check if we're already working on this buff (subsequent tick calls)
    if _activeBuff.category == category and _activeBuff.spellName == spellName then
        if activeBuffTimedOut() then
            local waitReason = _activeBuff.waitReason or _activeBuff.state or 'unknown'
            lib.log('warn', self.name,
                'Buff timed out: %s (state=%s reason=%s); releasing cast claim and backing off',
                spellName, tostring(_activeBuff.state), tostring(waitReason))
            traceLog('warn', 'action', 'timeout_' .. tostring(category), 0,
                'Buff action timed out: spell=%s category=%s target=%d state=%s waitReason=%s elapsedMs=%d',
                tostring(spellName), tostring(category), targetId, tostring(_activeBuff.state), tostring(waitReason),
                lib.getTimeMs() - (_activeBuff.startedAtMs or 0))
            recordBuffFailure(category, waitReason)
            _pendingAction = nil
            _pendingReason = nil
            _buffGemSwap.requestedSpell = ''
            clearActiveBuff()
            self:sendNeed(false, nil, 'buff_timeout:' .. tostring(spellName))
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

    -- Claim buff in cross-character system
    if Buff and Buff.claimBuff then
        if not Buff.claimBuff(targetId, category) then
            -- Already claimed by someone else
            debugLog('executeAction: Buff already claimed by another character')
            traceLog('info', 'action', 'already_claimed_' .. tostring(category), 5,
                'Buff already claimed by another character: spell=%s category=%s target=%d',
                tostring(spellName), tostring(category), targetId)
            return true, 'buff_claimed'
        end
    end

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

-------------------------------------------------------------------------------
-- Custom requestClaim that handles both CAST-only and ACTION claims
-------------------------------------------------------------------------------

local originalRequestClaim = module.requestClaim

module.requestClaim = function(self, action)
    debugLog('requestClaim: ENTERED for action=%s', tostring(action and (action.spellName or action.name) or 'nil'))

    if not self:hasValidState() then
        lib.log('debug', self.name, 'Cannot claim: no valid state')
        debugLog('requestClaim: No valid state')
        return false
    end

    if self.claimPending then
        local elapsed = lib.getTimeMs() - self.claimRequestedAt
        if elapsed < 200 then
            debugLog('requestClaim: Claim still pending (elapsed=%dms)', elapsed)
            return false
        end
        self.claimPending = false
    end

    self.claimCounter = self.claimCounter + 1
    self.currentClaimId = lib.generateClaimId(self.name, self.claimCounter)
    debugLog('requestClaim: Generated claimId=%s', self.currentClaimId)

    -- Determine claim type from action
    local claimType = action.type or lib.ClaimType.CAST
    self.currentClaimType = claimType
    local wants = claimType == lib.ClaimType.ACTION and { 'target', 'cast' } or { 'cast' }

    -- Calculate TTL based on spell cast time (buff casts can take several seconds)
    -- Keep the coordinator lease longer than the worker's complete pre-cast
    -- timeout. A shorter lease orphaned waiting_ready actions before their local
    -- timeout could release them, causing an endless claim/backoff cycle.
    local ttlMs = BUFF_PRECAST_TIMEOUT_MS + BUFF_CAST_START_TIMEOUT_MS + 2000
    local spellName = action.spellName or action.name
    if spellName then
        local spell = mq.TLO.Spell(spellName)
        if spell and spell() and spell.MyCastTime then
            local castTimeMs = tonumber(spell.MyCastTime()) or 3000
            ttlMs = math.max(ttlMs, BUFF_PRECAST_TIMEOUT_MS + castTimeMs + 2000)
        end
    end

    local claim = {
        msgType = 'claim',
        type = claimType,
        wants = wants,
        module = self.name,
        ownerName = lib.getMyName(),
        ownerServer = lib.getMyServer(),
        priority = self.priority,
        claimId = self.currentClaimId,
        epochSeen = self.state.epoch,
        ttlMs = ttlMs,
        -- Buffs may need to memorize a gem before the cast bar can appear, so
        -- use the operation's bounded TTL instead of the ordinary 1s window.
        expectsCastStart = true,
        castStartTimeoutMs = ttlMs,
        reason = action.reason or 'buff',
        action = action,
    }

    self.claimPending = true
    self.claimRequestedAt = lib.getTimeMs()
    self.claimEpochAtRequest = self.state.epoch

    local ok, err = pcall(function()
        self.dropbox:send({ mailbox = lib.Mailbox.CLAIM, script = lib.Scripts.COORDINATOR }, claim)
    end)

    if ok then
        debugLog('requestClaim: Claim sent successfully: %s type=%s epoch=%d ttlMs=%d',
            self.currentClaimId, claimType, self.state.epoch, ttlMs)
        traceLog('info', 'claim', 'claim_sent_' .. tostring(self.currentClaimId), 0,
            'Claim requested: id=%s type=%s spell=%s target=%s epoch=%d ttlMs=%d',
            tostring(self.currentClaimId), tostring(claimType), tostring(spellName),
            tostring(action.targetId), tonumber(self.state.epoch) or 0, ttlMs)
    else
        debugLog('requestClaim: Claim send FAILED: %s', tostring(err))
        traceLog('error', 'claim', 'claim_send_failed', 0,
            'Claim request failed: spell=%s target=%s error=%s',
            tostring(spellName), tostring(action.targetId), tostring(err))
    end

    lib.log('debug', self.name, 'Claim requested: %s (type=%s, epoch=%d)', self.currentClaimId, claimType, self.state.epoch)
    return true
end

-- Override ownsAction to handle CAST-only claims (buff module only needs cast, not target)
module.ownsAction = function(self)
    -- For CAST-only claims, we only need cast ownership (not target)
    local ownsCast = self:ownsCast()
    if not ownsCast then
        return false
    end

    -- Check if this is a CAST-only claim
    local owner = self.state.castOwner
    if owner and owner.action and owner.action.type == lib.ClaimType.CAST then
        debugLog('ownsAction: CAST-only claim, returning true')
        return true
    end

    -- For ACTION claims, also need target ownership
    local ownsTarget = self:ownsTarget()
    debugLog('ownsAction: ACTION claim, ownsTarget=%s', tostring(ownsTarget))
    return ownsTarget
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
        lib.log('info', module.name, 'running=%s, hasState=%s, isMyPriority=%s, ownsCast=%s, buffingEnabled=%s, defs=%d, reason=%s, active=%s:%s/%s, failures=%d',
            tostring(module.running),
            tostring(module:hasValidState()),
            tostring(module:isMyPriority()),
            tostring(module:ownsCast()),
            tostring(settings.BuffingEnabled),
            defCount,
            tostring(statusReason),
            tostring(_activeBuff.category),
            tostring(_activeBuff.spellName),
            tostring(_activeBuff.state),
            failureCount)
        commandEcho('running=%s hasState=%s priority=%s ownsCast=%s enabled=%s defs=%d reason=%s active=%s:%s/%s wait=%s failures=%d debug=%s',
            tostring(module.running),
            tostring(module:hasValidState()),
            tostring(module:isMyPriority()),
            tostring(module:ownsCast()),
            tostring(settings.BuffingEnabled),
            defCount,
            tostring(statusReason),
            tostring(_activeBuff.category),
            tostring(_activeBuff.spellName),
            tostring(_activeBuff.state),
            tostring(_activeBuff.waitReason),
            failureCount,
            tostring(_buffDebugEnabled))
        for category, failure in pairs(_buffFailures) do
            commandEcho('backoff category=%s reason=%s failures=%d retryInMs=%d',
                tostring(category), tostring(failure.reason), tonumber(failure.count) or 0,
                math.max(0, (tonumber(failure.retryAtMs) or 0) - lib.getTimeMs()))
        end
        traceLog('info', 'command', 'status', 0,
            'Status requested: running=%s hasState=%s isMyPriority=%s ownsCast=%s buffingEnabled=%s defs=%d reason=%s active=%s:%s state=%s wait=%s failures=%d',
            tostring(module.running), tostring(module:hasValidState()), tostring(module:isMyPriority()),
            tostring(module:ownsCast()), tostring(settings.BuffingEnabled), defCount, tostring(statusReason),
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
            clearActiveBuff()
            module:releaseClaim('manual_buff_retry')
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
    onFailure = function()
        _pendingAction = nil
        _pendingReason = nil
        maybeRestoreBuffGem()
        clearActiveBuff()
    end,
    onCancel = function()
        _pendingAction = nil
        _pendingReason = nil
        maybeRestoreBuffGem()
        clearActiveBuff()
    end,
})

module:enablePeerActors()
module:run(50)

return module
