-- F:\lua\SideKick\automation\buff.lua
-- Buff tracking and coordination
-- Tracks buffs applied by self and peers, coordinates to avoid duplicate casting

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

-- Logging
local getThrottledLog = lazy('sidekick-next.utils.throttled_log')

-- Dedicated buff logger (file-based)
local _BuffLogger = nil
local function getBuffLogger()
    if not _BuffLogger then
        local ok, logger = pcall(require, 'sidekick-next.automation.buff_logger')
        if ok then
            _BuffLogger = logger
            if _BuffLogger and _BuffLogger.init then
                _BuffLogger.init()
            end
        end
    end
    return _BuffLogger
end

local function isWindowOpen(name)
    if not name or name == '' then return false end
    local w = mq.TLO.Window(name)
    return w and w.Open and w.Open() == true
end

local _buffLogThrottle = {}
local function logInfoThrottled(log, key, intervalSec, fmt, ...)
    if not log then return end
    local now = os.clock()
    local last = _buffLogThrottle[key] or 0
    if (now - last) < (intervalSec or 0) then return end
    _buffLogThrottle[key] = now
    log.info('tick', fmt, ...)
end

M.debugBuffHotswap = false
M.debugBuffTick = false

-- Lazy-load dependencies to avoid circular requires
local getActors = lazy('sidekick-next.utils.actors_coordinator')
local getCache = lazy('sidekick-next.utils.runtime_cache')
local getCore = lazy('sidekick-next.utils.core')
local getSpellEngine = lazy('sidekick-next.utils.spell_engine')

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


-- Local buff tracking (buffs we've applied)
M.localBuffs = {}  -- { [targetId] = { [buffCategory] = { expiresAt, spellId, spellName } } }

-- Remote buff tracking (buffs others have applied)
M.remoteBuffs = {}  -- { [targetId] = { [buffCategory] = { expiresAt, caster } } }

-- Claims (before casting, claim to prevent duplicates)
M.localClaims = {}   -- { [targetId] = { [buffCategory] = { claimedAt } } }
M.remoteClaims = {}  -- { [targetId] = { [buffCategory] = { claimedAt, claimer } } }

-- Buff blocks (what buffs targets don't want)
M.remoteBlocks = {}  -- { [charName] = { [buffCategory] = true } }
M.pendingBuffs = {}  -- { [targetId] = { [buffCategory] = { expiresAt } } }
M.pendingGroupCasts = {}  -- { [buffCategory] = { expiresAt } }

-- Buff definitions loaded from class configs
M.buffDefinitions = {}  -- Loaded from class config

-- Full class config for spell line resolution
local _classConfig = nil

-- Timing
local _lastBuffListBroadcast = 0
local _lastBuffTick = 0
local _lastBuffEchoAt = 0
local _lastBlocksBroadcast = 0
local _lastCleanup = 0
local _lastBuffDefsRefresh = 0
local _lastInitialScanAttempt = 0
local _lastGroupCastAt = {}
local _selfName = ''
local _initialScanComplete = false  -- Prevents buffing until initial scan is done
local _lastBuffAudit = 0

local BUFF_LIST_BROADCAST_INTERVAL = 2.0   -- Broadcast buff list every 2 seconds
local BLOCKS_BROADCAST_INTERVAL = 5.0      -- Broadcast blocks every 5 seconds
local CLEANUP_INTERVAL = 1.0               -- Clean expired every 1 second
local CLAIM_TIMEOUT = 8.0                  -- Claims expire after 8 seconds
local BUFF_CHECK_INTERVAL = 60.0           -- How often to recheck buff status on targets (use cache otherwise)
local BUFF_INITIAL_CHECK_INTERVAL = 0.0    -- Always check if no state exists (immediate)
local BUFF_TICK_INTERVAL = 0.5             -- Casting tick interval (500ms)
local DEFAULT_REBUFF_WINDOW = 60           -- Default seconds before expiry to rebuff
local GROUP_BUFF_THRESHOLD = 2             -- Min members needing buff to use group version
local BUFF_DEFS_REFRESH_INTERVAL = 5.0     -- Refresh buff definitions if empty (5 seconds)
local BUFF_DEFS_PERIODIC_REFRESH = 30.0    -- Periodic refresh to pick up spell set changes (30 seconds)
local GROUP_CAST_COOLDOWN = 6.0            -- Cooldown to avoid immediate re-cast of group spells
local PENDING_BUFF_WINDOW = 8.0            -- Seconds to treat a buff as present after cast acceptance
local PENDING_GROUP_WINDOW = 15.0          -- Seconds to suppress repeat group casts per category
local BUFF_GEM_HOLD_WINDOW = 8.0           -- Seconds to hold buff gem after mem to avoid immediate unmem
local BUFF_AUDIT_INTERVAL = 120.0          -- Full buff state refresh interval (seconds)

-- Buff rotation gem state (last gem is reserved for hot-swapping buffs)
local _buffGemSwap = {
    active = false,
    reservedGem = 0,
    originalSpell = '',
    requestedSpell = '',
    lastRequestAt = 0,
    lastMemAt = 0,
}

-- Active buff cast state - tracks which buff we're committed to casting
local _activeBuff = {
    category = nil,        -- Which buff category we're working on
    spellName = nil,       -- Spell we're trying to cast
    startedAt = 0,         -- When we started this attempt
    timeout = 15.0,        -- Max seconds to wait for spell to be ready and cast
}

-- Forward declaration for helper used in buff state refresh
local getSpellId





local function resolveBestBookSpellFromLine(lineName)
    if not _classConfig or not _classConfig.spellLines or not lineName then return nil end
    local line = _classConfig.spellLines[lineName]
    if type(line) ~= 'table' then return nil end

    local me = mq.TLO.Me
    if not (me and me()) then return nil end

    -- me.Book(unrankedName) misses scribed ranks (Rk. II / Rk. III). Use
    -- me.Spell(name) which does SpellGroup substring matching against the
    -- spellbook, and return the actually-scribed ranked name so downstream
    -- /cast and gem comparisons line up with EQ's stored names.
    for _, spellName in ipairs(line) do
        local exact = me.Book(spellName)
        if exact and exact() then
            return spellName
        end
        local spell = me.Spell(spellName)
        if spell and spell() then
            local actual = tostring(spell.Name() or '')
            if actual ~= '' and actual ~= 'NULL' then
                return actual
            end
        end
    end
    return nil
end


-- rgmercs-style buff detection helpers (presence + triggers + stacking)
-- These return a table: { shouldCast, remaining, reason }
local BLOCKED_REMAINING = 99999

local function buildNameQuery(spellName)
    if not spellName or spellName == '' then return nil end
    return string.format('name "%s"', spellName)
end

local function getBuffDurationOnMe(spellId)
    local buff = mq.TLO.Me.FindBuff('id ' .. spellId)
    if buff and buff() then
        return tonumber(buff.Duration.TotalSeconds()) or 0
    end
    return nil
end

local function getBuffDurationByNameOnMe(spellName)
    if not spellName or spellName == '' then return nil end
    local query = buildNameQuery(spellName)
    local buff = query and mq.TLO.Me.FindBuff(query) or nil
    if buff and buff() then
        return tonumber(buff.Duration.TotalSeconds()) or 0
    end
    return nil
end

local function getBuffDurationOnTarget(spellId)
    local buff = mq.TLO.Target.FindBuff('id ' .. spellId)
    if buff and buff() then
        return tonumber(buff.Duration.TotalSeconds()) or 0
    end
    return nil
end

local function getBuffDurationByNameOnTarget(spellName)
    if not spellName or spellName == '' then return nil end
    local query = buildNameQuery(spellName)
    local buff = query and mq.TLO.Target.FindBuff(query) or nil
    if buff and buff() then
        return tonumber(buff.Duration.TotalSeconds()) or 0
    end
    return nil
end

local function isBlockedBuffByName(me, spellName)
    if not (me and me()) then return false end
    if not spellName or spellName == '' then return false end

    local count = 0
    if me.NumBlockedBuffs and me.NumBlockedBuffs() then
        count = tonumber(me.NumBlockedBuffs()) or 0
    end
    if count <= 0 or not me.BlockedBuff then return false end

    for i = 1, count do
        local b = me.BlockedBuff(i)
        if b and b() then
            local name = tostring(b())
            if name == spellName then
                return true
            end
        end
    end

    return false
end

local function rgmercsLocalBuffCheck(spellId)
    if not spellId then return { shouldCast = false, remaining = 0, reason = 'no_spell' } end
    local me = mq.TLO.Me
    if not (me and me()) then return { shouldCast = false, remaining = 0, reason = 'no_me' } end

    local spell = mq.TLO.Spell(spellId)
    if not (spell and spell()) then return { shouldCast = false, remaining = 0, reason = 'invalid_spell' } end

    local spellName = spell.Name()
    ---@diagnostic disable-next-line: undefined-field
    if isBlockedBuffByName(me, spellName) then
        return { shouldCast = false, remaining = BLOCKED_REMAINING, reason = 'blocked' }
    end

    local remaining = getBuffDurationOnMe(spellId)
    if remaining ~= nil then
        return { shouldCast = false, remaining = remaining, reason = 'found' }
    end

    local remainingByName = getBuffDurationByNameOnMe(spellName)
    if remainingByName ~= nil then
        return { shouldCast = false, remaining = remainingByName, reason = 'found_name' }
    end

    local numEffects = spell.NumEffects() or 0
    local triggerCount = 0
    local triggerFound = 0
    local triggerRemaining = nil
    for i = 1, numEffects do
        local trig = spell.Trigger(i)
        if trig and trig() and trig.ID() > 0 then
            triggerCount = triggerCount + 1
            local trigId = trig.ID()
            local trigRem = getBuffDurationOnMe(trigId)
            if trigRem ~= nil then
                triggerFound = triggerFound + 1
                triggerRemaining = triggerRemaining and math.min(triggerRemaining, trigRem) or trigRem
            else
                if trig.Stacks() then
                    return { shouldCast = true, remaining = 0, reason = 'trigger_stacks' }
                end
                triggerFound = triggerFound + 1
            end
        else
            break
        end
    end

    if triggerCount > 0 and triggerFound >= triggerCount then
        return { shouldCast = false, remaining = triggerRemaining or 0, reason = 'triggers_found' }
    end

    if spell.Stacks() then
        return { shouldCast = true, remaining = 0, reason = 'stacks' }
    end

    return { shouldCast = false, remaining = BLOCKED_REMAINING, reason = 'no_stack' }
end

local function rgmercsTargetBuffCheck(spellId, targetId, allowTargetChange)
    if not spellId then return { shouldCast = false, remaining = 0, reason = 'no_spell' } end
    if not targetId or targetId <= 0 then return { shouldCast = false, remaining = 0, reason = 'no_target' } end

    local spell = mq.TLO.Spell(spellId)
    if not (spell and spell()) then return { shouldCast = false, remaining = 0, reason = 'invalid_spell' } end

    local currentTargetId = mq.TLO.Target and mq.TLO.Target.ID and mq.TLO.Target.ID() or 0
    local needRetarget = (currentTargetId ~= targetId)

    if needRetarget and not allowTargetChange then
        return { shouldCast = false, remaining = 0, reason = 'no_target_change' }
    end

    local function restoreTarget()
        if not needRetarget then return end
        if currentTargetId and currentTargetId > 0 then
            mq.cmdf('/target id %d', currentTargetId)
        else
            mq.cmd('/target clear')
        end
    end

    if needRetarget then
        mq.cmdf('/target id %d', targetId)
        mq.delay(50)
    end

    local remaining = getBuffDurationOnTarget(spellId)
    if remaining ~= nil then
        restoreTarget()
        return { shouldCast = false, remaining = remaining, reason = 'found' }
    end

    local remainingByName = getBuffDurationByNameOnTarget(spell.Name())
    if remainingByName ~= nil then
        restoreTarget()
        return { shouldCast = false, remaining = remainingByName, reason = 'found_name' }
    end

    local numEffects = spell.NumEffects() or 0
    local triggerCount = 0
    local triggerFound = 0
    local triggerRemaining = nil
    for i = 1, numEffects do
        local trig = spell.Trigger(i)
        if trig and trig() and trig.ID() > 0 then
            triggerCount = triggerCount + 1
            local trigId = trig.ID()
            local trigRem = getBuffDurationOnTarget(trigId)
            if trigRem ~= nil then
                triggerFound = triggerFound + 1
                triggerRemaining = triggerRemaining and math.min(triggerRemaining, trigRem) or trigRem
            else
                if trig.StacksTarget() then
                    restoreTarget()
                    return { shouldCast = true, remaining = 0, reason = 'trigger_stacks' }
                end
                triggerFound = triggerFound + 1
            end
        else
            break
        end
    end

    if triggerCount > 0 and triggerFound >= triggerCount then
        restoreTarget()
        return { shouldCast = false, remaining = triggerRemaining or 0, reason = 'triggers_found' }
    end

    if spell.StacksTarget() then
        restoreTarget()
        return { shouldCast = true, remaining = 0, reason = 'stacks' }
    end

    restoreTarget()

    return { shouldCast = false, remaining = BLOCKED_REMAINING, reason = 'no_stack' }
end


local function markBuffStatePresent(targetId, buffCategory, spellId, remaining)
    local Cache = getCache()
    if not Cache or not Cache.buffState then return end
    local id = tonumber(targetId) or 0
    if id <= 0 then return end

    Cache.buffState[id] = Cache.buffState[id] or {}
    Cache.buffState[id][buffCategory] = {
        present = true,
        remaining = tonumber(remaining) or 0,
        pending = false,
        spellId = spellId,
        checkedAt = os.clock(),
    }
end

local function updateBuffStateMulti(targetId, buffCategory, spellIds, allowTargetChange)
    local Cache = getCache()
    if not Cache or not Cache.buffState then return nil end
    if not spellIds or #spellIds == 0 then return nil end

    local now = os.clock()
    local pending = M.pendingBuffs[targetId] and M.pendingBuffs[targetId][buffCategory]
    if pending and now < (pending.expiresAt or 0) then
        local ttl = (pending.expiresAt or 0) - now
        Cache.buffState[targetId] = Cache.buffState[targetId] or {}
        Cache.buffState[targetId][buffCategory] = {
            present = true,
            remaining = ttl,
            pending = true,
            spellId = spellIds[1],
            checkedAt = now,
        }
        return { shouldCast = false, remaining = ttl, reason = 'pending' }
    end

    -- Check LOCAL buffs first (buffs WE cast) - don't re-query if we recently cast this
    local localBuff = M.localBuffs[targetId] and M.localBuffs[targetId][buffCategory]
    if localBuff and now < (localBuff.expiresAt or 0) then
        local ttl = (localBuff.expiresAt or 0) - now
        Cache.buffState[targetId] = Cache.buffState[targetId] or {}
        Cache.buffState[targetId][buffCategory] = {
            present = true,
            remaining = ttl,
            pending = false,
            spellId = localBuff.spellId,
            checkedAt = now,
        }
        return { shouldCast = false, remaining = ttl, reason = 'local' }
    end

    -- Check REMOTE buffs (buffs cast by peers)
    local remoteBuff = M.remoteBuffs[targetId] and M.remoteBuffs[targetId][buffCategory]
    if remoteBuff and now < (remoteBuff.expiresAt or 0) then
        local ttl = (remoteBuff.expiresAt or 0) - now
        Cache.buffState[targetId] = Cache.buffState[targetId] or {}
        Cache.buffState[targetId][buffCategory] = {
            present = true,
            remaining = ttl,
            pending = false,
            spellId = remoteBuff.spellId,
            checkedAt = now,
        }
        return { shouldCast = false, remaining = ttl, reason = 'peer' }
    end

    local me = mq.TLO.Me
    local myId = me and me.ID and me.ID() or 0

    local best = nil
    local bestSpellId = nil
    local fallback = nil
    local fallbackSpellId = nil

    for _, spellId in ipairs(spellIds) do
        local res
        if targetId == myId then
            res = rgmercsLocalBuffCheck(spellId)
        else
            res = rgmercsTargetBuffCheck(spellId, targetId, allowTargetChange)
        end

        if res and res.reason ~= 'no_target_change' then
            if not fallback then
                fallback = res
                fallbackSpellId = spellId
            end
            if res.shouldCast == false then
                if (not best) or (tonumber(res.remaining) or 0) > (tonumber(best.remaining) or 0) then
                    best = res
                    bestSpellId = spellId
                end
            end
        end
    end

    local result = best or fallback
    local resultSpellId = bestSpellId or fallbackSpellId
    if result and result.reason ~= 'no_target_change' then
        Cache.buffState[targetId] = Cache.buffState[targetId] or {}
        Cache.buffState[targetId][buffCategory] = {
            present = not result.shouldCast,
            remaining = result.remaining or 0,
            pending = false,
            spellId = resultSpellId,
            checkedAt = os.clock(),
        }
    end

    return result
end



local function buildBuffCheckSpellIds(buffDef)
    if not buffDef then return {} end
    local ids = {}
    local seen = {}

    local function addLine(lineName)
        if not lineName then return end
        local spellName = resolveBestBookSpellFromLine(lineName)
        if not spellName then return end
        local spellId = getSpellId(spellName)
        if not spellId or spellId == 0 then return end
        if not seen[spellId] then
            seen[spellId] = true
            table.insert(ids, spellId)
        end
    end

    addLine(buffDef.spellLine)
    addLine(buffDef.groupSpellLine)
    return ids
end



-- Check if a memorized spell is ready to cast

-- Clear active buff state

-- Set active buff we're committing to

-- Check if we should continue with current active buff or give up



-- Initialization
function M.init()
    M.localBuffs = {}
    M.remoteBuffs = {}
    M.localClaims = {}
    M.remoteClaims = {}
    M.remoteBlocks = {}
    M.buffDefinitions = {}

    local log = getBuffLogger()
    if log then
        log.info('session', 'Buff automation init')
    end

    _selfName = (mq.TLO.Me and mq.TLO.Me.CleanName and mq.TLO.Me.CleanName()) or ''

    -- Load buff definitions from class config
    M.loadBuffDefinitions()

    -- Initial buff scan - check who already has buffs before we start casting
    M.initialBuffScan()
end

-- Initial buff scan on startup - checks current buff state for all group members
-- This prevents the script from immediately casting buffs on people who already have them
function M.initialBuffScan()
    local TL = getThrottledLog()
    local Cache = getCache()
    if not Cache then return end

    local log = getBuffLogger()
    if log then
        log.info('scan', 'Initial buff scan starting')
    end

    -- Force a cache update first
    if Cache.updateHeavy then
        Cache.updateHeavy()
    end

    local scannedCount = 0
    local foundBuffs = 0

    -- For each buff definition, check all group members
    for category, buffDef in pairs(M.buffDefinitions) do
        local checkSpellIds = buildBuffCheckSpellIds(buffDef)
        if #checkSpellIds == 0 then
            local spellId = buffDef.spellName and getSpellId(buffDef.spellName)
            if spellId then
                table.insert(checkSpellIds, spellId)
            end
        end

        if #checkSpellIds > 0 then
            -- Check self
            local myId = Cache.me and Cache.me.id or 0
            if myId > 0 then
                local result = updateBuffStateMulti(myId, category, checkSpellIds, false)
                scannedCount = scannedCount + 1
                if result and result.shouldCast == false then
                    foundBuffs = foundBuffs + 1
                end
            end

            -- Check group members
            for _, member in pairs(Cache.group.members or {}) do
                local memberId = member.id
                if memberId and memberId > 0 then
                    local result = updateBuffStateMulti(memberId, category, checkSpellIds, true)
                    scannedCount = scannedCount + 1
                    if result and result.shouldCast == false then
                        foundBuffs = foundBuffs + 1
                    end
                end
            end
        end
    end

    _initialScanComplete = true

    if TL then
        TL.log('buff_init_scan', 0, '[Buff] Initial scan complete: %d checks, %d existing buffs found', scannedCount, foundBuffs)
    end
    if log then
        log.info('scan', 'Initial buff scan complete: checks=%d found=%d', scannedCount, foundBuffs)
    end
end

-- Check if initial scan is complete (for external callers)

-- Check if buffing flow is active (mem/cast in progress)
function M.isBuffingActive()
    if _activeBuff and _activeBuff.category then
        return true
    end
    if _buffGemSwap and _buffGemSwap.active then
        return true
    end
    return false
end

-- Load buff definitions from spell set (buff_swap lines)
-- Called on init and can be refreshed when spell set changes
function M.loadBuffDefinitions()
    M.buffDefinitions = {}

    local sm = getSpellsetManager()
    if not sm or not sm.getBuffSwapLines then
        return
    end

    -- Get enabled buff_swap lines from active spell set
    local buffLines = sm.getBuffSwapLines()
    if not buffLines or #buffLines == 0 then
        return
    end

    for _, line in ipairs(buffLines) do
        -- Each line has: lineName, spellName, condition, priority
        M.buffDefinitions[line.lineName] = {
            spellName = line.spellName,      -- Already resolved
            lineName = line.lineName,
            condition = line.condition,
            priority = line.priority or 999,
            targets = 'group',               -- Default to group buffing
            rebuffWindow = DEFAULT_REBUFF_WINDOW,
        }
    end
end

-- Refresh buff definitions from spell set (call when set changes)

-- Check if a spell is memorized in any gem slot
-- @param spellName string Spell name
-- @return number|nil Gem slot number if memorized, nil otherwise

-- Resolve a spell line to the highest rank memorized spell
-- @param lineName string Spell line name (e.g., "Symbol")
-- @return string|nil Best memorized spell name, nil if none found

-- Find any memorized spell from a buff definition
-- Checks spellLine first, then groupSpellLine if provided
-- @param buffDef table Buff definition from buffLines
-- @param preferGroup boolean If true, prefer group spell when available
-- @return string|nil Spell name, nil if none memorized
-- @return boolean True if this is a group spell

-- Main tick function
function M.tick()
    local now = os.clock()

    -- Cleanup expired entries
    if (now - _lastCleanup) >= CLEANUP_INTERVAL then
        _lastCleanup = now
        M.cleanupExpired()
    end

    -- Broadcast our buff list
    if (now - _lastBuffListBroadcast) >= BUFF_LIST_BROADCAST_INTERVAL then
        _lastBuffListBroadcast = now
        M.broadcastBuffList()
    end

    -- Broadcast our blocked buffs
    if (now - _lastBlocksBroadcast) >= BLOCKS_BROADCAST_INTERVAL then
        _lastBlocksBroadcast = now
        M.broadcastBlocks()
    end
end

-- Cleanup expired buffs and claims
function M.cleanupExpired()
    local now = os.clock()

    -- Cleanup local buffs
    for targetId, categories in pairs(M.localBuffs) do
        for category, data in pairs(categories) do
            if now >= (data.expiresAt or 0) then
                categories[category] = nil
            end
        end
        if not next(categories) then
            M.localBuffs[targetId] = nil
        end
    end

    -- Cleanup remote buffs
    for targetId, categories in pairs(M.remoteBuffs) do
        for category, data in pairs(categories) do
            if now >= (data.expiresAt or 0) then
                categories[category] = nil
            end
        end
        if not next(categories) then
            M.remoteBuffs[targetId] = nil
        end
    end

    -- Cleanup local claims
    for targetId, categories in pairs(M.localClaims) do
        for category, data in pairs(categories) do
            if (now - (data.claimedAt or 0)) >= CLAIM_TIMEOUT then
                categories[category] = nil
            end
        end
        if not next(categories) then
            M.localClaims[targetId] = nil
        end
    end

    -- Cleanup remote claims
    for targetId, categories in pairs(M.remoteClaims) do
        for category, data in pairs(categories) do
            if (now - (data.claimedAt or 0)) >= CLAIM_TIMEOUT then
                categories[category] = nil
            end
        end
        if not next(categories) then
            M.remoteClaims[targetId] = nil
        end
    end
end

--- Broadcast our buff list to peers
function M.broadcastBuffList()
    if not next(M.localBuffs) then return end

    local Actors = getActors()
    if not Actors or not Actors.broadcast then return end

    local now = os.clock()
    local buffs = {}

    for targetId, categories in pairs(M.localBuffs) do
        buffs[targetId] = {}
        for category, data in pairs(categories) do
            local ttl = (data.expiresAt or 0) - now
            if ttl > 0 then
                buffs[targetId][category] = {
                    ttl = ttl,
                    spellId = data.spellId,
                    caster = _selfName,
                }
            end
        end
        if not next(buffs[targetId]) then
            buffs[targetId] = nil
        end
    end

    if not next(buffs) then return end

    Actors.broadcast('buff:list', {
        buffs = buffs,
        sender = _selfName,
        timestamp = now,
    })
end

local function applyRemoteBuffState(targetId, buffCategory, ttl, spellId)
    local id = tonumber(targetId)
    if not id or id == 0 then return end
    local Cache = getCache()
    if not Cache or not Cache.buffState then return end

    Cache.buffState[id] = Cache.buffState[id] or {}
    Cache.buffState[id][buffCategory] = {
        present = true,
        remaining = tonumber(ttl) or 0,
        spellId = spellId,
        checkedAt = os.clock(),
    }
end

--- Receive buff list from peer
function M.receiveBuffList(payload)
    local mobs = payload.buffs or {}
    local sender = payload.sender or payload.from or 'unknown'
    local recvNow = os.clock()

    for targetId, categories in pairs(mobs) do
        local id = tonumber(targetId)
        if id and id > 0 then
            M.remoteBuffs[id] = M.remoteBuffs[id] or {}
            for category, data in pairs(categories) do
                local ttl = tonumber(data.ttl) or 0
                if ttl > 0 then
                    M.remoteBuffs[id][category] = {
                        expiresAt = recvNow + ttl,
                        caster = data.caster or sender,
                        spellId = data.spellId,
                    }
                    applyRemoteBuffState(id, category, ttl, data.spellId)
                end
            end
        end
    end
end

--- Broadcast our blocked buffs
function M.broadcastBlocks()
    local Actors = getActors()
    if not Actors or not Actors.broadcast then return end

    local Core = getCore()
    if not Core or not Core.Settings then return end

    local blocked = {}
    for key, value in pairs(Core.Settings) do
        if key:match('^BuffBlock_') and value == true then
            local buffType = key:gsub('^BuffBlock_', '')
            table.insert(blocked, buffType)
        end
    end

    Actors.broadcast('buff:blocks', {
        charName = _selfName,
        blockedTypes = blocked,
    })
end

--- Receive blocked buffs from peer
function M.receiveBlocks(payload)
    local charName = payload.charName
    if not charName or charName == '' then return end

    M.remoteBlocks[charName] = {}
    for _, buffType in ipairs(payload.blockedTypes or {}) do
        M.remoteBlocks[charName][buffType] = true
    end
end

--- Claim a buff target before casting
-- @param targetId number Target spawn ID
-- @param buffCategory string Buff category
-- @return boolean True if claim successful
function M.claimBuff(targetId, buffCategory)
    if M.isBuffClaimed(targetId, buffCategory) then
        return false
    end

    local id = tonumber(targetId)
    if not id or id == 0 then return false end

    M.localClaims[id] = M.localClaims[id] or {}
    M.localClaims[id][buffCategory] = {
        claimedAt = os.clock(),
    }

    local Actors = getActors()
    if Actors and Actors.broadcast then
        Actors.broadcast('buff:claim', {
            targetId = id,
            buffType = buffCategory,
            claimer = _selfName,
        })
    end

    return true
end

--- Receive claim from peer
function M.receiveClaim(payload)
    local targetId = tonumber(payload.targetId)
    if not targetId or targetId == 0 then return end

    local buffType = payload.buffType
    if not buffType or buffType == '' then return end

    M.remoteClaims[targetId] = M.remoteClaims[targetId] or {}
    M.remoteClaims[targetId][buffType] = {
        claimedAt = os.clock(),
        claimer = payload.claimer or 'unknown',
    }
end

--- Release a claim (after buff lands or fails)
function M.releaseClaim(targetId, buffCategory)
    local id = tonumber(targetId)
    if not id then return end

    if M.localClaims[id] then
        M.localClaims[id][buffCategory] = nil
        if not next(M.localClaims[id]) then
            M.localClaims[id] = nil
        end
    end
end

--- Check if a buff is claimed by someone else
function M.isBuffClaimed(targetId, buffCategory)
    local id = tonumber(targetId)
    if not id then return false end

    local claim = M.remoteClaims[id] and M.remoteClaims[id][buffCategory]
    if claim and (os.clock() - (claim.claimedAt or 0)) < CLAIM_TIMEOUT then
        return true, claim.claimer
    end

    return false
end

--- Check if a target has blocked a buff type

--- Track a buff we just applied
function M.trackLocalBuff(targetId, buffCategory, spellId, spellName, duration)
    local id = tonumber(targetId)
    if not id or id == 0 then return end

    duration = tonumber(duration) or 0
    if duration <= 0 then
        duration = 1200  -- Default 20 minutes if unknown
    end
    local now = os.clock()

    M.localBuffs[id] = M.localBuffs[id] or {}
    M.localBuffs[id][buffCategory] = {
        expiresAt = now + duration,
        spellId = spellId,
        spellName = spellName,
    }

    -- Clear pending state when tracked
    if M.pendingBuffs[id] then
        M.pendingBuffs[id][buffCategory] = nil
        if not next(M.pendingBuffs[id]) then
            M.pendingBuffs[id] = nil
        end
    end

    -- Also update runtime cache's buffState so getMembersNeedingBuff sees it
    local Cache = getCache()
    if Cache and Cache.buffState then
        Cache.buffState[id] = Cache.buffState[id] or {}
        Cache.buffState[id][buffCategory] = {
            present = true,
            remaining = duration,
            spellId = spellId,
            checkedAt = now,
        }
    end

    local log = getBuffLogger()
    if log then
        log.info('state', 'Track buff: category=%s spell=%s targetId=%d duration=%ds',
            tostring(buffCategory), tostring(spellName), tonumber(id) or 0, tonumber(duration) or 0)
    end

    -- Release claim now that buff landed
    M.releaseClaim(id, buffCategory)

    -- Broadcast immediately
    local Actors = getActors()
    if Actors and Actors.broadcast then
        Actors.broadcast('buff:landed', {
            targetId = id,
            buffType = buffCategory,
            caster = _selfName,
            duration = duration,
            spellId = spellId,
        })
    end
end

--- Receive buff landed notification from peer
function M.receiveBuffLanded(payload)
    local targetId = tonumber(payload.targetId)
    if not targetId or targetId == 0 then return end

    local buffType = payload.buffType
    if not buffType or buffType == '' then return end

    local duration = tonumber(payload.duration) or 1200

    M.remoteBuffs[targetId] = M.remoteBuffs[targetId] or {}
    M.remoteBuffs[targetId][buffType] = {
        expiresAt = os.clock() + duration,
        caster = payload.caster or 'unknown',
        spellId = payload.spellId,
    }

    applyRemoteBuffState(targetId, buffType, duration, payload.spellId)

    -- Clear any claims for this target/buff
    if M.remoteClaims[targetId] then
        M.remoteClaims[targetId][buffType] = nil
    end
end

--- Check if target has a buff (from any source)

--- Check buff status on a target using Target.FindBuff
-- This requires briefly targeting the member
-- @param memberId number Target spawn ID
-- @param spellId number Spell ID to check for
-- @return table { present, remaining }

--- Should we buff now based on combat state?

--- Get all buff definitions for current class
function M.getBuffDefinitions()
    return M.buffDefinitions
end


--- Get the caster-specific duration (in seconds) for a spell. Uses
--- `Spell.MyDuration` which accounts for the character's level + focus
--- effects — this is what the buff will actually last for us. Falls back
--- to the base `Spell.Duration` if MyDuration isn't available, and to a
--- 1200s (20 min) default when neither is reachable.
---
--- Exposed so callers (e.g. sk_buffs) can pass an accurate duration to
--- trackLocalBuff instead of nil — which otherwise lands a 1200s phantom
--- expiry and suppresses rebuff far beyond the real spell duration.
function M.getMySpellDuration(spellName)
    if not spellName then return 1200 end
    local spell = mq.TLO.Spell(spellName)
    if not (spell and spell()) then return 1200 end

    -- MyDuration returns a Ticks type (1 tick = 6s); .TotalSeconds is the
    -- resolved seconds value.
    if spell.MyDuration and spell.MyDuration.TotalSeconds then
        local seconds = tonumber(spell.MyDuration.TotalSeconds()) or 0
        if seconds > 0 then return seconds end
    end

    -- Fallback to base Duration (level-capped, no focus).
    if spell.Duration then
        if spell.Duration.TotalSeconds then
            local seconds = tonumber(spell.Duration.TotalSeconds()) or 0
            if seconds > 0 then return seconds end
        end
        local ticks = tonumber(spell.Duration()) or 0
        if ticks > 0 then return ticks * 6 end
    end

    return 1200
end

-- Legacy alias — kept for any caller still on the older name.
M.getSpellDuration = M.getMySpellDuration


--- Get spell ID from spell name
-- @param spellName string Spell name
-- @return number|nil Spell ID
getSpellId = function(spellName)
    if not spellName then return nil end
    local spell = mq.TLO.Spell(spellName)
    if spell and spell() and spell.ID then
        return tonumber(spell.ID()) or nil
    end
    return nil
end


return M
