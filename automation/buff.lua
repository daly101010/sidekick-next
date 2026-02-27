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

local function isSpellsetLineEnabled(lineName)
    local sm = getSpellsetManager()
    if not sm or not sm.isLineEnabled then
        return true
    end
    return sm.isLineEnabled(lineName)
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

local function isSelfOnlySpell(spellName)
    if not spellName or spellName == '' then return false end
    local spell = mq.TLO.Spell(spellName)
    if not (spell and spell() and spell.TargetType) then return false end
    local targetType = tostring(spell.TargetType() or '')
    return targetType == 'Self' or targetType == 'Self Only' or targetType == 'PB AE'
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

local function resolveBestBookSpellFromLine(lineName)
    if not _classConfig or not _classConfig.spellLines or not lineName then return nil end
    local line = _classConfig.spellLines[lineName]
    if type(line) ~= 'table' then return nil end

    local me = mq.TLO.Me
    if not (me and me()) then return nil end

    for _, spellName in ipairs(line) do
        local inBook = me.Book(spellName)
        if inBook and inBook() then
            return spellName
        end
    end
    return nil
end

local function findBestBuffSpell(buffDef, preferGroup)
    if not buffDef then return nil, false end

    if preferGroup and buffDef.groupSpellLine then
        local s = resolveBestBookSpellFromLine(buffDef.groupSpellLine)
        if s then return s, true end
    end
    if buffDef.spellLine then
        local s = resolveBestBookSpellFromLine(buffDef.spellLine)
        if s then return s, false end
    end
    if (not preferGroup) and buffDef.groupSpellLine then
        local s = resolveBestBookSpellFromLine(buffDef.groupSpellLine)
        if s then return s, true end
    end
    return nil, false
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

local function updateBuffState(targetId, buffCategory, spellId, allowTargetChange)
    local Cache = getCache()
    if not Cache or not Cache.buffState then return nil end

    local now = os.clock()
    local pending = M.pendingBuffs[targetId] and M.pendingBuffs[targetId][buffCategory]
    if pending and now < (pending.expiresAt or 0) then
        local ttl = (pending.expiresAt or 0) - now
        Cache.buffState[targetId] = Cache.buffState[targetId] or {}
        Cache.buffState[targetId][buffCategory] = {
            present = true,
            remaining = ttl,
            pending = true,
            spellId = spellId,
            checkedAt = now,
        }
        return { shouldCast = false, remaining = ttl, reason = 'pending' }
    end
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

    local result
    if targetId == myId then
        result = rgmercsLocalBuffCheck(spellId)
    else
        result = rgmercsTargetBuffCheck(spellId, targetId, allowTargetChange)
    end

    if result and result.reason ~= 'no_target_change' then
        Cache.buffState[targetId] = Cache.buffState[targetId] or {}
        Cache.buffState[targetId][buffCategory] = {
            present = not result.shouldCast,
            remaining = result.remaining or 0,
            pending = false,
            spellId = spellId,
            checkedAt = os.clock(),
        }
    end

    return result
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

local function refreshBuffStateForCategory(buffCategory, spellId, maxAge, skipSelf)
    local Cache = getCache()
    if not Cache or not Cache.isBuffStateStale then return end
    if not spellId then return end

    maxAge = maxAge or BUFF_CHECK_INTERVAL

    -- Self
    if not skipSelf then
        local myId = Cache.me and Cache.me.id or 0
        if myId > 0 and Cache.isBuffStateStale(myId, buffCategory, maxAge) then
            updateBuffState(myId, buffCategory, spellId, false)
        end
    end

    -- Group members
    for _, member in pairs(Cache.group.members or {}) do
        local memberId = member.id
        if memberId and memberId > 0 then
            if Cache.isBuffStateStale(memberId, buffCategory, maxAge) then
                updateBuffState(memberId, buffCategory, spellId, true)
            end
        end
    end
end

local function refreshBuffStateForCategoryMulti(buffCategory, spellIds, maxAge, skipSelf)
    local Cache = getCache()
    if not Cache or not Cache.isBuffStateStale then return end
    if not spellIds or #spellIds == 0 then return end

    maxAge = maxAge or BUFF_CHECK_INTERVAL

    -- Self
    if not skipSelf then
        local myId = Cache.me and Cache.me.id or 0
        if myId > 0 and Cache.isBuffStateStale(myId, buffCategory, maxAge) then
            updateBuffStateMulti(myId, buffCategory, spellIds, false)
        end
    end

    -- Group members
    for _, member in pairs(Cache.group.members or {}) do
        local memberId = member.id
        if memberId and memberId > 0 then
            if Cache.isBuffStateStale(memberId, buffCategory, maxAge) then
                updateBuffStateMulti(memberId, buffCategory, spellIds, true)
            end
        end
    end
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

local function refreshSelfBuffStateForCategory(buffCategory, spellIds, maxAge)
    local Cache = getCache()
    if not Cache or not Cache.isBuffStateStale then return end
    if not spellIds or #spellIds == 0 then return end

    maxAge = maxAge or BUFF_CHECK_INTERVAL

    local myId = Cache.me and Cache.me.id or 0
    if myId <= 0 or not Cache.isBuffStateStale(myId, buffCategory, maxAge) then return end

    local best = nil
    local bestSpellId = nil
    local fallback = nil
    local fallbackSpellId = nil

    for _, spellId in ipairs(spellIds) do
        local res = rgmercsLocalBuffCheck(spellId)
        if not fallback then
            fallback = res
            fallbackSpellId = spellId
        end
        if res and res.shouldCast == false then
            if (not best) or (tonumber(res.remaining) or 0) > (tonumber(best.remaining) or 0) then
                best = res
                bestSpellId = spellId
            end
        end
    end

    local result = best or fallback
    local resultSpellId = bestSpellId or fallbackSpellId
    if not result then return end

    Cache.buffState[myId] = Cache.buffState[myId] or {}
    Cache.buffState[myId][buffCategory] = {
        present = not result.shouldCast,
        remaining = result.remaining or 0,
        spellId = resultSpellId,
        checkedAt = os.clock(),
    }
end

local function refreshBuffStateForPets(buffCategory, spellId, maxAge)
    local Cache = getCache()
    if not Cache or not Cache.isBuffStateStale then return end
    if not spellId then return end

    maxAge = maxAge or BUFF_CHECK_INTERVAL

    -- Self pet
    if Cache.me and Cache.me.pet and Cache.me.pet.id and Cache.me.pet.id > 0 then
        local petId = Cache.me.pet.id
        if Cache.isBuffStateStale(petId, buffCategory, maxAge) then
            updateBuffState(petId, buffCategory, spellId, true)
        end
    end

    -- Group pets
    for _, member in pairs(Cache.group.members or {}) do
        local pet = member.pet
        if pet and pet.id and pet.id > 0 then
            if Cache.isBuffStateStale(pet.id, buffCategory, maxAge) then
                updateBuffState(pet.id, buffCategory, spellId, true)
            end
        end
    end
end

-- Check if a memorized spell is ready to cast
local function isSpellReady(spellName)
    if not spellName or spellName == '' then return false end
    local me = mq.TLO.Me
    if not (me and me()) then return false end

    -- Check if spell is memorized
    local gem = me.Gem(spellName)
    if not gem or not gem() or gem() == 0 then return false end

    -- Check if spell is ready (not on cooldown)
    local ready = me.SpellReady(spellName)
    return ready and ready() == true
end

-- Clear active buff state
local function clearActiveBuff()
    _activeBuff.category = nil
    _activeBuff.spellName = nil
    _activeBuff.startedAt = 0
end

-- Set active buff we're committing to
local function setActiveBuff(category, spellName)
    _activeBuff.category = category
    _activeBuff.spellName = spellName
    _activeBuff.startedAt = os.clock()
end

-- Check if we should continue with current active buff or give up
local function shouldContinueActiveBuff()
    if not _activeBuff.category then return false end

    local now = os.clock()
    local elapsed = now - _activeBuff.startedAt

    -- Timeout - give up on this buff
    if elapsed > _activeBuff.timeout then
        local TL = getThrottledLog()
        if M.debugBuffTick and TL then
            TL.log('buff_timeout_' .. _activeBuff.category, 5,
                'Buff %s timed out after %.1fs, moving on', _activeBuff.spellName or 'unknown', elapsed)
        end
        clearActiveBuff()
        return false
    end

    return true
end

local function ensureBuffSpellMemorized(spellName)
    local TL = getThrottledLog()
    local log = getBuffLogger()
    if not spellName or spellName == '' then return false end
    local reservedGem = getReservedBuffGem()
    if reservedGem <= 0 then return false end

    local me = mq.TLO.Me
    if not (me and me()) then return false end
    local inBook = me.Book(spellName)
    if not (inBook and inBook()) then
        if log then
            log.warn('tick', 'Mem skipped: spell not in book (spell=%s)', tostring(spellName))
        end
        return false
    end

    if isWindowOpen('SpellBookWnd') or isWindowOpen('SpellBookWindow') then
        logInfoThrottled(log, 'mem_book_open_' .. tostring(spellName), 2,
            'Mem wait: spellbook open (spell=%s)', tostring(spellName))
        return false
    end

    if _buffGemSwap.reservedGem ~= reservedGem then
        _buffGemSwap.reservedGem = reservedGem
    end

    local current = getGemSpellName(reservedGem)

    -- Start of a buff rotation: remember what was in the reserved gem.
    if not _buffGemSwap.active then
        _buffGemSwap.active = true
        _buffGemSwap.originalSpell = current
        _buffGemSwap.requestedSpell = ''
        _buffGemSwap.lastRequestAt = 0
        _buffGemSwap.lastMemAt = 0
        if M.debugBuffHotswap and TL then
            TL.log('buff_hotswap_begin', 2, 'Buff hotswap: NumGems=%d reservedGem=%d original=%s', getNumGems(), reservedGem, tostring(_buffGemSwap.originalSpell))
        end
    end

    -- Already memorized.
    if current == spellName then
        _buffGemSwap.requestedSpell = ''
        _buffGemSwap.lastMemAt = os.clock()
        logInfoThrottled(log, 'mem_ok_' .. tostring(spellName), 2,
            'Mem complete: spell=%s gem=%d', tostring(spellName), reservedGem)
        return true
    end

    local now = os.clock()
    local requestCooldown = 1.0
    if _buffGemSwap.requestedSpell == spellName and (now - (_buffGemSwap.lastRequestAt or 0)) < requestCooldown then
        if M.debugBuffHotswap and TL then
            TL.log('buff_hotswap_wait_' .. spellName, 2, 'Buff hotswap: waiting for mem %s in gem %d (current=%s)', spellName, reservedGem, tostring(current))
        end
        logInfoThrottled(log, 'mem_wait_' .. tostring(spellName), 2,
            'Mem wait: spell=%s gem=%d current=%s', tostring(spellName), reservedGem, tostring(current))
        return false
    end

    -- If we keep waiting too long, retry the mem request
    if _buffGemSwap.requestedSpell == spellName and (now - (_buffGemSwap.lastRequestAt or 0)) >= 8.0 then
        if log then
            log.warn('tick', 'Mem retry timeout: spell=%s gem=%d current=%s', tostring(spellName), reservedGem, tostring(current))
        end
        _buffGemSwap.lastRequestAt = now
        mq.cmdf('/memspell %d "%s"', reservedGem, spellName)
        logInfoThrottled(log, 'mem_retry_' .. tostring(spellName), 2,
            'Mem retry: spell=%s gem=%d current=%s', tostring(spellName), reservedGem, tostring(current))
        return false
    end

    _buffGemSwap.requestedSpell = spellName
    _buffGemSwap.lastRequestAt = now
    mq.cmdf('/memspell %d "%s"', reservedGem, spellName)
    if M.debugBuffHotswap and TL then
        TL.log('buff_hotswap_mem_' .. spellName, 0, 'Buff hotswap: /memspell %d "%s" (current=%s)', reservedGem, spellName, tostring(current))
    end
    logInfoThrottled(log, 'mem_cmd_' .. tostring(spellName), 2,
        'Mem request: spell=%s gem=%d current=%s', tostring(spellName), reservedGem, tostring(current))
    return false
end

local function maybeRestoreBuffGem()
    if not _buffGemSwap.active then return end

    local TL = getThrottledLog()
    local reservedGem = getReservedBuffGem()
    if reservedGem <= 0 then
        _buffGemSwap.active = false
        _buffGemSwap.originalSpell = ''
        _buffGemSwap.requestedSpell = ''
        _buffGemSwap.lastRequestAt = 0
        _buffGemSwap.lastMemAt = 0
        _buffGemSwap.reservedGem = 0
        return
    end

    local current = getGemSpellName(reservedGem)
    local original = tostring(_buffGemSwap.originalSpell or '')
    if original == '' then
        if M.debugBuffHotswap and TL then
            TL.log('buff_hotswap_end_blank', 2, 'Buff hotswap: ending (no original spell to restore)')
        end
        _buffGemSwap.active = false
        _buffGemSwap.originalSpell = ''
        _buffGemSwap.requestedSpell = ''
        _buffGemSwap.lastRequestAt = 0
        _buffGemSwap.lastMemAt = 0
        _buffGemSwap.reservedGem = 0
        return
    end

    -- Hold the buff gem briefly after memorization to allow casts
    local now = os.clock()
    if _buffGemSwap.lastMemAt and (now - (_buffGemSwap.lastMemAt or 0)) < BUFF_GEM_HOLD_WINDOW then
        return
    end

    if current ~= original then
        local requestCooldown = 1.0
        if _buffGemSwap.requestedSpell == original and (now - (_buffGemSwap.lastRequestAt or 0)) < requestCooldown then
            return
        end

        _buffGemSwap.requestedSpell = original
        _buffGemSwap.lastRequestAt = now
        mq.cmdf('/memspell %d "%s"', reservedGem, original)
        if M.debugBuffHotswap and TL then
            TL.log('buff_hotswap_restore', 0, 'Buff hotswap: restoring %s to gem %d (current=%s)', original, reservedGem, tostring(current))
        end
        return
    end

    if M.debugBuffHotswap and TL then
        TL.log('buff_hotswap_end', 2, 'Buff hotswap: restored, ending rotation (gem %d = %s)', reservedGem, original)
    end
    _buffGemSwap.active = false
    _buffGemSwap.originalSpell = ''
    _buffGemSwap.requestedSpell = ''
    _buffGemSwap.lastRequestAt = 0
    _buffGemSwap.lastMemAt = 0
    _buffGemSwap.reservedGem = 0
end

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
function M.isInitialScanComplete()
    return _initialScanComplete
end

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
function M.refreshBuffDefinitions()
    M.loadBuffDefinitions()
end

-- Check if a spell is memorized in any gem slot
-- @param spellName string Spell name
-- @return number|nil Gem slot number if memorized, nil otherwise
local function isSpellMemorized(spellName)
    if not spellName or spellName == '' then return nil end
    local me = mq.TLO.Me
    if not (me and me()) then return nil end
    local gem = me.Gem(spellName)
    if gem and gem() and gem() > 0 then
        return gem()
    end
    return nil
end

-- Resolve a spell line to the highest rank memorized spell
-- @param lineName string Spell line name (e.g., "Symbol")
-- @return string|nil Best memorized spell name, nil if none found
function M.resolveSpellFromLine(lineName)
    if not _classConfig or not _classConfig.spellLines or not lineName then return nil end

    local line = _classConfig.spellLines[lineName]
    if type(line) ~= 'table' then return nil end

    -- Iterate through spells in order (highest rank first)
    for _, spellName in ipairs(line) do
        if isSpellMemorized(spellName) then
            return spellName
        end
    end

    return nil
end

-- Find any memorized spell from a buff definition
-- Checks spellLine first, then groupSpellLine if provided
-- @param buffDef table Buff definition from buffLines
-- @param preferGroup boolean If true, prefer group spell when available
-- @return string|nil Spell name, nil if none memorized
-- @return boolean True if this is a group spell
function M.findMemorizedBuffSpell(buffDef, preferGroup)
    if not buffDef then return nil, false end

    -- If preferring group and groupSpellLine is defined, try that first
    if preferGroup and buffDef.groupSpellLine then
        local groupSpell = M.resolveSpellFromLine(buffDef.groupSpellLine)
        if groupSpell then
            return groupSpell, true
        end
    end

    -- Try single target spell line
    if buffDef.spellLine then
        local singleSpell = M.resolveSpellFromLine(buffDef.spellLine)
        if singleSpell then
            return singleSpell, false
        end
    end

    -- Fallback: try group spell if not preferring single
    if not preferGroup and buffDef.groupSpellLine then
        local groupSpell = M.resolveSpellFromLine(buffDef.groupSpellLine)
        if groupSpell then
            return groupSpell, true
        end
    end

    return nil, false
end

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
function M.isBuffBlocked(targetName, buffCategory)
    if not targetName or not buffCategory then return false end

    -- Check self blocks
    if targetName == _selfName then
        local Core = getCore()
        if Core and Core.Settings then
            return Core.Settings['BuffBlock_' .. buffCategory] == true
        end
    end

    -- Check remote blocks
    local blocks = M.remoteBlocks[targetName]
    return blocks and blocks[buffCategory] == true
end

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
function M.hasBuffFromAnySource(targetId, buffCategory)
    local id = tonumber(targetId)
    if not id then return false, 0 end

    local now = os.clock()

    -- Check local buffs
    local localBuff = M.localBuffs[id] and M.localBuffs[id][buffCategory]
    if localBuff and now < (localBuff.expiresAt or 0) then
        return true, localBuff.expiresAt - now
    end

    -- Check remote buffs
    local remoteBuff = M.remoteBuffs[id] and M.remoteBuffs[id][buffCategory]
    if remoteBuff and now < (remoteBuff.expiresAt or 0) then
        return true, remoteBuff.expiresAt - now
    end

    return false, 0
end

--- Check buff status on a target using Target.FindBuff
-- This requires briefly targeting the member
-- @param memberId number Target spawn ID
-- @param spellId number Spell ID to check for
-- @return table { present, remaining }
function M.checkBuffOnTarget(memberId, spellId)
    if not memberId or not spellId then
        return { present = false, remaining = 0 }
    end

    local Cache = getCache()
    if Cache and Cache.checkBuff then
        return Cache.checkBuff(memberId, spellId, '__direct_check')
    end

    return { present = false, remaining = 0 }
end

--- Should we buff now based on combat state?
function M.shouldBuffNow(buffDef)
    local Cache = getCache()
    if not Cache then return true end

    local inCombat = Cache.inCombat and Cache.inCombat() or (Cache.me and Cache.me.combat)

    -- Combat-only buffs
    if buffDef.combatOnly and not inCombat then
        return false
    end

    -- Out-of-combat buffs
    if buffDef.outOfCombatOnly and inCombat then
        return false
    end

    return true
end

--- Get all buff definitions for current class
function M.getBuffDefinitions()
    return M.buffDefinitions
end

local function getSortedBuffDefinitions()
    local list = {}
    for category, buffDef in pairs(M.buffDefinitions) do
        table.insert(list, {
            category = category,
            def = buffDef,
            priority = tonumber(buffDef.priority) or 999,
        })
    end
    table.sort(list, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        return tostring(a.category) < tostring(b.category)
    end)
    return list
end

-- ============================================================================
-- BUFF CASTING EXECUTION
-- ============================================================================

--- Check if we can cast buffs now
-- @return boolean True if we can cast
-- @return string|nil Reason if we cannot
local function canBuffNow()
    local me = mq.TLO.Me
    if not (me and me()) then return false, 'no_character' end

    -- Check combat state (buffing/memorization only allowed OOC)
    local Cache = getCache()
    local inCombat = Cache and Cache.inCombat and Cache.inCombat() or false
    if inCombat then return false, 'in_combat' end

    -- Check invis (rgmercs: don't break invis to buff)
    if me.Invis and me.Invis() then return false, 'invis' end

    -- Check movement plugins / navigation
    if (mq.TLO.MoveTo and mq.TLO.MoveTo.Moving and mq.TLO.MoveTo.Moving())
        or (mq.TLO.Navigation and mq.TLO.Navigation.Active and mq.TLO.Navigation.Active())
        or (mq.TLO.AdvPath and mq.TLO.AdvPath.Following and mq.TLO.AdvPath.Following())
        or (mq.TLO.Stick and mq.TLO.Stick.Active and mq.TLO.Stick.Active()) then
        return false, 'movement_plugin'
    end

    -- Check if moving
    if me.Moving() then return false, 'moving' end

    -- Check if already casting (Casting() returns spell name string, empty if not)
    local casting = me.Casting() or ''
    if casting ~= '' then return false, 'casting' end

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

local function isSpawnValidForBuff(spawn)
    if not (spawn and spawn()) then return false, 'no_spawn' end
    if spawn.Dead and spawn.Dead() then return false, 'dead' end
    if spawn.OtherZone and spawn.OtherZone() then return false, 'other_zone' end
    local st = spawn.Type and tostring(spawn.Type() or '') or ''
    if st:lower() == 'corpse' then return false, 'corpse' end
    return true, nil
end

--- Get spell duration from spell data
-- @param spellName string Spell name
-- @return number Duration in seconds (default 1200 = 20 min)
local function getSpellDuration(spellName)
    if not spellName then return 1200 end
    local spell = mq.TLO.Spell(spellName)
    if spell and spell() and spell.Duration then
        local dur = spell.Duration.TotalSeconds
        if dur and dur() then
            local seconds = tonumber(dur()) or 0
            if seconds > 0 then
                return seconds
            end
        end
        local ticks = tonumber(spell.Duration()) or 0
        if ticks > 0 then
            return ticks * 6
        end
    end
    return 1200
end

local function getSpellRange(spellName)
    if not spellName then return 0 end
    local spell = mq.TLO.Spell(spellName)
    if not (spell and spell()) then return 0 end
    local myRange = spell.MyRange and spell.MyRange() or 0
    if myRange and myRange > 0 then return myRange end
    local aeRange = spell.AERange and spell.AERange() or 0
    if aeRange and aeRange > 0 then return aeRange end
    return 250
end

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

--- Cast a buff spell on a target
-- @param targetId number Target spawn ID
-- @param buffCategory string Buff category (e.g., "symbol")
-- @param spellName string Spell name to cast
-- @param buffDef table Buff definition
-- @return boolean True if cast was initiated
-- @return string|nil Failure reason if false
function M.castBuff(targetId, buffCategory, spellName, buffDef)
    if not targetId or not buffCategory or not spellName then
        return false, 'missing_params'
    end

    local SpellEngine = getSpellEngine()
    if not SpellEngine or not SpellEngine.cast then
        return false, 'no_spell_engine'
    end

    local TL = getThrottledLog()

    -- Prevent self-only buffs from being cast on group members
    local me = mq.TLO.Me
    local myId = me and me.ID and me.ID() or 0
    local spell = mq.TLO.Spell(spellName)
    if spell and spell() and spell.TargetType then
        local targetType = tostring(spell.TargetType() or '')
        local selfOnly = targetType == 'Self' or targetType == 'Self Only' or targetType == 'PB AE'
        if selfOnly and myId > 0 and targetId ~= myId then
            local log = getBuffLogger()
            if log then
                log.warn('cast', 'Self-only block: spell=%s targetType=%s targetId=%d myId=%d category=%s',
                    tostring(spellName), targetType, tonumber(targetId) or 0, tonumber(myId) or 0, tostring(buffCategory))
            end
            if TL then
                TL.log('buff_self_only_block_' .. tostring(buffCategory), 5,
                    'Buff self-only block: spell=%s targetType=%s targetId=%d myId=%d category=%s',
                    tostring(spellName), targetType, tonumber(targetId) or 0, tonumber(myId) or 0, tostring(buffCategory))
            end
            return false, 'self_only'
        end
    end

    -- Cast the spell
    local success, reason = SpellEngine.cast(spellName, targetId, {
        spellCategory = 'buff',
        maxRetries = 0,
    })

    local log = getBuffLogger()
    if success then
        if log then
            log.info('cast', 'Cast accepted: spell=%s category=%s targetId=%d',
                tostring(spellName), tostring(buffCategory), tonumber(targetId) or 0)
        end
        -- Mark as pending only; verify actual buff presence on subsequent checks.
        -- This prevents a failed/interrupted cast from being treated as landed.
        local now = os.clock()
        M.pendingBuffs[targetId] = M.pendingBuffs[targetId] or {}
        M.pendingBuffs[targetId][buffCategory] = { expiresAt = now + PENDING_BUFF_WINDOW }
        local Cache = getCache()
        if Cache and Cache.buffState then
            local spellId = getSpellId(spellName)
            Cache.buffState[targetId] = Cache.buffState[targetId] or {}
            Cache.buffState[targetId][buffCategory] = {
                present = true,
                remaining = PENDING_BUFF_WINDOW,
                pending = true,
                spellId = spellId,
                checkedAt = now,
            }
        end
    else
        if log then
            log.warn('cast', 'Cast failed: spell=%s category=%s targetId=%d reason=%s',
                tostring(spellName), tostring(buffCategory), tonumber(targetId) or 0, tostring(reason))
        end
    end

    return success, reason
end

--- Count how many group members need a specific buff
-- @param buffCategory string Buff category
-- @param rebuffWindow number Seconds before expiry to consider needing rebuff
-- @return number Count of members needing the buff
function M.countMembersNeedingBuff(buffCategory, rebuffWindow)
    local Cache = getCache()
    if not Cache or not Cache.getMembersNeedingBuff then return 0 end

    local needing = Cache.getMembersNeedingBuff(buffCategory, rebuffWindow)
    return #needing
end

--- Main buff tick - check and cast buffs on targets
-- Called from main loop when buffing is enabled
function M.buffTick()
    local now = os.clock()
    local TL = getThrottledLog()
    local log = getBuffLogger()

    -- Don't start buffing until initial scan is complete
    -- This prevents casting on people who already have buffs
    if not _initialScanComplete then
        if (now - _lastInitialScanAttempt) >= 2.0 then
            _lastInitialScanAttempt = now
            if next(M.buffDefinitions) ~= nil then
                M.initialBuffScan()
            end
        end
        if log then
            log.debug('tick', 'BuffTick skip: waiting for initial scan')
        end
        if M.debugBuffTick and TL then
            TL.log('buff_tick_wait_scan', 5, 'BuffTick SKIP: Waiting for initial buff scan')
        end
        return
    end

    -- Debug echo disabled

    -- Rate limit
    if (now - _lastBuffTick) < BUFF_TICK_INTERVAL then
        return
    end
    _lastBuffTick = now

    -- Check if buffing is enabled
    local Core = getCore()
    if not Core or not Core.Settings then
        if log then
            log.warn('tick', 'BuffTick skip: Core or Core.Settings not available')
        end
        if M.debugBuffTick and TL then
            TL.log('buff_tick_no_core', 10, 'BuffTick SKIP: Core or Core.Settings not available')
        end
        return
    end

    -- Check if explicitly disabled (false) or disabled via 0
    local buffingEnabledValue = Core.Settings.BuffingEnabled

    -- Temporary debug: uncomment next line to see the value
    -- mq.cmdf('/echo [Buff] BuffingEnabled=%s type=%s', tostring(buffingEnabledValue), type(buffingEnabledValue))

    if buffingEnabledValue == false or buffingEnabledValue == 0 then
        if log then
            log.debug('tick', 'BuffTick skip: BuffingEnabled=%s', tostring(buffingEnabledValue))
        end
        if M.debugBuffTick and TL then
            TL.log('buff_tick_disabled', 30, 'BuffTick SKIP: BuffingEnabled=%s', tostring(buffingEnabledValue))
        end
        maybeRestoreBuffGem()
        return
    end

    -- Check if we can cast
    local canCast, reason = canBuffNow()
    if not canCast then
        if log then
            log.debug('tick', 'BuffTick skip: canBuffNow=false reason=%s', tostring(reason))
            logInfoThrottled(log, 'cannot_cast_' .. tostring(reason), 2,
                'BuffTick skip: canBuffNow=false reason=%s', tostring(reason))
        end
        -- Debug echo disabled
        if M.debugBuffTick and TL then
            TL.log('buff_tick_cannot_cast', 10, 'BuffTick SKIP: canBuffNow()=false, reason=%s', tostring(reason))
        end
        return
    end

    -- Get cache for target info
    local Cache = getCache()
    if not Cache then
        if log then
            log.warn('tick', 'BuffTick skip: Cache not available')
        end
        if M.debugBuffTick and TL then
            TL.log('buff_tick_no_cache', 10, 'BuffTick SKIP: Cache not available')
        end
        return
    end

    -- Refresh buff definitions if empty (fast interval) or periodically (slow interval)
    local needsRefresh = false
    local hasDefinitions = next(M.buffDefinitions) ~= nil

    if not hasDefinitions then
        -- No definitions - refresh quickly to pick up newly enabled lines
        if (now - _lastBuffDefsRefresh) >= BUFF_DEFS_REFRESH_INTERVAL then
            needsRefresh = true
        end
    else
        -- Has definitions - periodic refresh to pick up spell set changes
        if (now - _lastBuffDefsRefresh) >= BUFF_DEFS_PERIODIC_REFRESH then
            needsRefresh = true
        end
    end

    if needsRefresh then
        local hadDefinitions = hasDefinitions
        _lastBuffDefsRefresh = now
        M.loadBuffDefinitions()
        hasDefinitions = next(M.buffDefinitions) ~= nil

        if log then
            local count = 0
            for _ in pairs(M.buffDefinitions) do count = count + 1 end
            log.info('defs', 'Buff definitions refresh: had=%s now=%s count=%d',
                tostring(hadDefinitions), tostring(hasDefinitions), count)
        end

        -- If we just got definitions after having none, do initial scan
        if hasDefinitions and not hadDefinitions then
            M.initialBuffScan()
        end

        if M.debugBuffTick and TL then
            local count = 0
            for _ in pairs(M.buffDefinitions) do count = count + 1 end
            TL.log('buff_defs_refresh', 5, 'BuffTick: Refreshed buff definitions, found %d', count)
        end
    end

    -- Still no definitions after refresh attempt
    if not hasDefinitions then
        if log then
            log.warn('tick', 'BuffTick skip: No buff definitions loaded')
        end
        if M.debugBuffTick and TL then
            TL.log('buff_tick_no_defs', 30, 'BuffTick SKIP: No buffDefinitions (enable buff_swap lines in spell set)')
        end
        maybeRestoreBuffGem()
        return
    end

    if M.debugBuffTick and TL then
        local defCount = 0
        for _ in pairs(M.buffDefinitions) do defCount = defCount + 1 end
        TL.log('buff_tick_running', 10, 'BuffTick: Running with %d buff definitions', defCount)
    end

    -- Periodic full refresh to detect dispels or external buff losses
    if (now - (_lastBuffAudit or 0)) >= BUFF_AUDIT_INTERVAL then
        _lastBuffAudit = now
        if log then
            log.info('state', 'Buff audit: full refresh start')
        end
        for category, buffDef in pairs(M.buffDefinitions) do
            local checkSpellIds = buildBuffCheckSpellIds(buffDef)
            if #checkSpellIds == 0 then
                local spellId = buffDef.spellName and getSpellId(buffDef.spellName)
                if spellId then
                    table.insert(checkSpellIds, spellId)
                end
            end
            if #checkSpellIds > 0 then
                refreshSelfBuffStateForCategory(category, checkSpellIds, 0)
                refreshBuffStateForCategoryMulti(category, checkSpellIds, 0, true)
            end
        end
        if log then
            log.info('state', 'Buff audit: full refresh complete')
        end
    end

    -- If we're currently waiting for a spell to memorize, don't switch to another buff
    -- This prevents the loop where we keep requesting different spells
    if _buffGemSwap.active and _buffGemSwap.requestedSpell ~= '' then
        local reservedGem = getReservedBuffGem()
        local current = getGemSpellName(reservedGem)
        if current ~= _buffGemSwap.requestedSpell then
            -- Respect active buff timeout while waiting on memorization
            if _activeBuff.category and _activeBuff.spellName then
                if not shouldContinueActiveBuff() then
                    -- Timed out; allow the loop to pick another buff next tick
                    _buffGemSwap.requestedSpell = ''
                    return
                end
            end
            -- Re-issue mem request if needed (covers mem interruptions)
            ensureBuffSpellMemorized(_buffGemSwap.requestedSpell)
            -- Still waiting for memorization
            if M.debugBuffTick and TL then
                TL.log('buff_tick_wait_mem', 5, 'BuffTick: Waiting for %s to memorize (current=%s)',
                    _buffGemSwap.requestedSpell, current)
            end
            logInfoThrottled(log, 'buff_tick_wait_mem_' .. tostring(_buffGemSwap.requestedSpell), 2,
                'Waiting for mem: spell=%s gem=%d current=%s',
                tostring(_buffGemSwap.requestedSpell), reservedGem, tostring(current))
            return
        end
    end

    -- If we have an active buff we're committed to, wait for spell to be ready
    if _activeBuff.category and _activeBuff.spellName then
        if shouldContinueActiveBuff() then
            -- Check if spell is ready to cast
            if not isSpellReady(_activeBuff.spellName) then
                if M.debugBuffTick and TL then
                    local elapsed = now - _activeBuff.startedAt
                    TL.log('buff_tick_wait_ready', 5, 'BuffTick: Waiting for %s to be ready (%.1fs elapsed)',
                        _activeBuff.spellName, elapsed)
                end
                logInfoThrottled(log, 'spell_ready_wait_' .. tostring(_activeBuff.spellName), 2,
                    'Wait spell ready: spell=%s (bookOpen=%s)',
                    tostring(_activeBuff.spellName), tostring(isWindowOpen('SpellBookWnd') or isWindowOpen('SpellBookWindow')))
                return  -- Keep waiting
            end
            -- Spell is ready, let the normal iteration find and cast it
            if M.debugBuffTick and TL then
                TL.log('buff_tick_spell_ready', 5, 'BuffTick: %s is ready, proceeding to cast',
                    _activeBuff.spellName)
            end
        end
        -- If shouldContinueActiveBuff returned false, it already cleared the state
    end

    local sortedBuffs = getSortedBuffDefinitions()

    -- Iterate through each buff definition from spell set (sorted by priority)
    for _, entryDef in ipairs(sortedBuffs) do
        local category = entryDef.category  -- lineName from spell set
        local buffDef = entryDef.def

        -- Get the spell name directly (already resolved by spell set manager)
        local spellName = buffDef.spellName
        if not spellName or spellName == '' then
            goto continue_buff
        end

        -- Check combat state for this buff
        if not M.shouldBuffNow(buffDef) then
            goto continue_buff
        end

        -- Get spell ID for buff state checks
        local spellId = getSpellId(spellName)
        if not spellId then
            goto continue_buff
        end

        -- Build check spell IDs (single + group lines) for accurate buff detection
        local checkSpellIds = buildBuffCheckSpellIds(buffDef)
        if (#checkSpellIds == 0) and spellId then
            table.insert(checkSpellIds, spellId)
        end

        -- Refresh buff state for self and group members
        refreshSelfBuffStateForCategory(category, checkSpellIds, BUFF_CHECK_INTERVAL)
        refreshBuffStateForCategoryMulti(category, checkSpellIds, BUFF_CHECK_INTERVAL, true)

        -- Get rebuff window
        local rebuffWindow = buffDef.rebuffWindow or DEFAULT_REBUFF_WINDOW

        -- Check if spell is self-only
        local isSelfOnly = isSelfOnlySpell(spellName)

        if isSelfOnly then
            -- Self-only buff
            local myId = Cache.me and Cache.me.id or 0
            if myId > 0 then
                local state = Cache.getBuffState and Cache.getBuffState(myId, category) or
                    (Cache.buffState and Cache.buffState[myId] and Cache.buffState[myId][category])
                local hasBuff = state and state.present or false
                local remaining = state and state.remaining or 0

                if (not hasBuff) or remaining < rebuffWindow then
                    -- Fresh check before memorizing
                    local freshCheck = rgmercsLocalBuffCheck(spellId)
                    if freshCheck and freshCheck.shouldCast == false then
                        if M.debugBuffTick and TL then
                            TL.log('buff_skip_self_' .. category, 10,
                                'Self buff %s skipped (%s)', spellName, freshCheck.reason or 'unknown')
                        end
                        goto continue_buff
                    end

                    -- Claim and cast
                    if not M.isBuffClaimed(myId, category) and M.claimBuff(myId, category) then
                        setActiveBuff(category, spellName)
                        if not ensureBuffSpellMemorized(spellName) then
                            return
                        end
                        local success = M.castBuff(myId, category, spellName, buffDef)
                        if success then
                            clearActiveBuff()
                            return  -- One cast per tick
                        else
                            M.releaseClaim(myId, category)
                        end
                    end
                end
            end
        else
            -- Group/single buff - find targets that need it
            local needing = Cache.getMembersNeedingBuff(category, rebuffWindow)
            if #needing == 0 then
                goto continue_buff
            end

            if log then
                log.info('decision', 'Buff need: category=%s spell=%s needing=%d rebuffWindow=%ds',
                    tostring(category), tostring(spellName), #needing, tonumber(rebuffWindow) or 0)
            end

            -- Check if this spell is a group spell by examining its target type
            local spell = mq.TLO.Spell(spellName)
            local spellTargetType = spell and spell() and spell.TargetType and tostring(spell.TargetType() or '') or ''
            local isGroupSpell = spellTargetType:match('^Group') ~= nil

            if isGroupSpell then
                local pg = M.pendingGroupCasts[category]
                if pg and now < (pg.expiresAt or 0) then
                    if log then
                        log.debug('decision', 'Skip group cast: category=%s pendingGroup=%.1fs',
                            tostring(category), (pg.expiresAt or 0) - now)
                        logInfoThrottled(log, 'group_pending_' .. tostring(category), 2,
                            'Skip group cast: category=%s pendingGroup=%.1fs',
                            tostring(category), (pg.expiresAt or 0) - now)
                    end
                    goto continue_buff
                end
                local lastCastAt = _lastGroupCastAt[category] or 0
                local since = now - lastCastAt
                if since < GROUP_CAST_COOLDOWN then
                    if log then
                        log.debug('decision', 'Skip group cast: category=%s cooldown=%.1fs remaining=%.1fs',
                            tostring(category), GROUP_CAST_COOLDOWN, GROUP_CAST_COOLDOWN - since)
                        logInfoThrottled(log, 'group_cooldown_' .. tostring(category), 2,
                            'Skip group cast: category=%s cooldown=%.1fs remaining=%.1fs',
                            tostring(category), GROUP_CAST_COOLDOWN, GROUP_CAST_COOLDOWN - since)
                    end
                    goto continue_buff
                end
            end

            if M.debugBuffTick and TL then
                local firstName = needing[1] and needing[1].member and needing[1].member.name or 'n/a'
                TL.log('buff_group_resolve_' .. category, 5,
                    'Buff resolve: spell=%s targetType=%s isGroup=%s targets=%d first=%s',
                    tostring(spellName), spellTargetType, tostring(isGroupSpell), #needing, tostring(firstName))
            end
            if log then
                log.info('decision', 'Buff resolve: category=%s spell=%s targetType=%s isGroup=%s targets=%d',
                    tostring(category), tostring(spellName), tostring(spellTargetType), tostring(isGroupSpell), #needing)
            end

            -- Filter out blocked, claimed targets, and do fresh check on each
            -- This ensures we don't try to buff people who already have the buff
            local validTargets = {}
            local spellRange = getSpellRange(spellName)
            for _, entry in ipairs(needing) do
                local member = entry.member
                if member and member.id and member.id > 0 then
                    local targetName = member.name or ''

                    if M.isBuffBlocked(targetName, category) then
                        if log then
                            log.debug('decision', 'Skip target: %s blocked for category=%s',
                                tostring(targetName), tostring(category))
                        end
                        goto continue_member
                    end

                    local claimed = M.isBuffClaimed(member.id, category)
                    if claimed then
                        if log then
                            log.debug('decision', 'Skip target: id=%d claimed for category=%s',
                                tonumber(member.id) or 0, tostring(category))
                        end
                        goto continue_member
                    end

                    if spellRange > 0 then
                        local spawn = mq.TLO.Spawn(member.id)
                        local okTarget, reason = isSpawnValidForBuff(spawn)
                        if not okTarget then
                            if log then
                                log.debug('decision', 'Skip target: %s invalid (%s)',
                                    tostring(targetName), tostring(reason or 'unknown'))
                            end
                            if M.debugBuffTick and TL then
                                TL.log('buff_skip_target_' .. category .. '_' .. tostring(member.id), 15,
                                    'Buff %s: %s invalid target (%s)', spellName, targetName, reason or 'unknown')
                            end
                            goto continue_member
                        end
                        local distance = spawn and spawn.Distance and tonumber(spawn.Distance()) or 0
                        if distance > spellRange then
                            if log then
                                log.debug('decision', 'Skip target: %s out of range (dist=%.1f > range=%.1f)',
                                    tostring(targetName), distance, spellRange)
                            end
                            if M.debugBuffTick and TL then
                                TL.log('buff_skip_range_' .. category .. '_' .. tostring(member.id), 15,
                                    'Buff %s: %s out of range (dist=%.1f > range=%.1f)',
                                    spellName, targetName, distance, spellRange)
                            end
                            goto continue_member
                        end
                    end

                    -- Rely on cached buff state (already refreshed) to avoid extra target flips
                    table.insert(validTargets, entry)
                end
                ::continue_member::
            end

            if #validTargets == 0 then
                if log then
                    log.debug('decision', 'No valid targets after filtering: category=%s', tostring(category))
                end
                goto continue_buff
            end

            -- Commit to this buff until cast completes or times out
            setActiveBuff(category, spellName)

            -- Ensure the buff spell is memorized in the reserved gem before casting
            if not ensureBuffSpellMemorized(spellName) then
                logInfoThrottled(log, 'mem_wait_' .. tostring(spellName), 2,
                    'Waiting for mem: spell=%s category=%s', tostring(spellName), tostring(category))
                return
            end

            if isGroupSpell then
                -- Group buff: target self (PB AE or group-targeted)
                local myId = Cache.me and Cache.me.id or 0
                if myId > 0 then
                    -- Claim all targets that will receive group buff
                    local claimedIds = {}
                    for _, entry in ipairs(validTargets) do
                        local memberId = entry.member.id
                        if M.claimBuff(memberId, category) then
                            table.insert(claimedIds, memberId)
                        end
                    end

                    if #claimedIds > 0 then
                        -- Cast group buff (target self for PB/group spells)
                        if M.debugBuffTick and TL then
                            TL.log('buff_cast_group_' .. category, 5,
                                'Buff cast attempt (group): spell=%s category=%s targetId=%d',
                                tostring(spellName), tostring(category), tonumber(myId) or 0)
                        end
                        if log then
                            log.info('cast', 'Group buff cast attempt: spell=%s category=%s targets=%d',
                                tostring(spellName), tostring(category), #claimedIds)
                        end
                        -- Mark pending group cast on attempt to avoid rapid repeats
                        M.pendingGroupCasts[category] = { expiresAt = now + PENDING_GROUP_WINDOW }
                        local success, castReason = M.castBuff(myId, category, spellName, buffDef)
                        if success then
                            clearActiveBuff()
                            _lastGroupCastAt[category] = now
                            M.pendingGroupCasts[category] = { expiresAt = now + PENDING_GROUP_WINDOW }
                            -- Track for all group members (group buffs hit everyone)
                            local targets = {}
                            local castSpellId = getSpellId(spellName)
                            local mySpawnId = mq.TLO.Me.ID()
                            if mySpawnId and mySpawnId > 0 then targets[mySpawnId] = true end
                            local groupCount = tonumber(mq.TLO.Group.Members()) or 0
                            for i = 1, groupCount do
                                local member = mq.TLO.Group.Member(i)
                                if member and member() then
                                    local memberId = tonumber(member.ID()) or 0
                                    if memberId > 0 then
                                        targets[memberId] = true
                                    end
                                end
                            end
                            local count = 0
                            local Cache = getCache()
                            for memberId, _ in pairs(targets) do
                                count = count + 1
                                -- Mark pending for each target to prevent immediate re-cast
                                M.pendingBuffs[memberId] = M.pendingBuffs[memberId] or {}
                                M.pendingBuffs[memberId][category] = { expiresAt = now + PENDING_BUFF_WINDOW }
                                if Cache and Cache.buffState then
                                    Cache.buffState[memberId] = Cache.buffState[memberId] or {}
                                    Cache.buffState[memberId][category] = {
                                        present = true,
                                        remaining = PENDING_BUFF_WINDOW,
                                        pending = true,
                                        spellId = castSpellId,
                                        checkedAt = now,
                                    }
                                end
                            end
                            if log then
                                log.info('state', 'Group buff applied: category=%s spell=%s targets=%d',
                                    tostring(category), tostring(spellName), count)
                            end
                            -- Force immediate buff state refresh after group cast
                            if checkSpellIds and #checkSpellIds > 0 then
                                refreshSelfBuffStateForCategory(category, checkSpellIds, 0)
                                refreshBuffStateForCategoryMulti(category, checkSpellIds, 0, true)
                                if log then
                                    log.info('state', 'Group buff refresh: category=%s checks=%d',
                                        tostring(category), #checkSpellIds)
                                end
                            end
                            return -- One cast per tick
                        else
                            -- Release claims on failure
                            for _, memberId in ipairs(claimedIds) do
                                M.releaseClaim(memberId, category)
                            end
                            -- Don't clear active buff yet - might need retry
                        end
                    end
                end
            else
                -- Single target buff: pick highest priority target
                local target = validTargets[1]
                if target and target.member then
                    local memberId = target.member.id
                    if M.claimBuff(memberId, category) then
                        if M.debugBuffTick and TL then
                            TL.log('buff_cast_single_' .. category, 5,
                                'Buff cast attempt (single): spell=%s category=%s targetId=%d',
                                tostring(spellName), tostring(category), tonumber(memberId) or 0)
                        end
                        if log then
                            log.info('cast', 'Single buff cast attempt: spell=%s category=%s target=%s(%d)',
                                tostring(spellName), tostring(category), tostring(target.member.name or '?'), tonumber(memberId) or 0)
                        end
                        local success, castReason = M.castBuff(memberId, category, spellName, buffDef)
                        if success then
                            clearActiveBuff()
                            return -- One cast per tick
                        else
                            M.releaseClaim(memberId, category)
                            -- Don't clear active buff yet - might need retry
                        end
                    end
                end
            end
        end

        ::continue_buff::
    end

    -- Pet buffing (separate pass)
    if M.buffPetsTick() then
        return
    end

    -- Nothing to do (no casts/mems requested); restore the reserved gem if we had swapped it.
    maybeRestoreBuffGem()
end

--- Tick for pet buffing
function M.buffPetsTick()
    local Core = getCore()
    if not Core or not Core.Settings then return false end

    -- Check if pet buffing is enabled
    if Core.Settings.BuffPetsEnabled == false then return false end

    local Cache = getCache()
    if not Cache or not Cache.getPetsNeedingBuff then return false end

    local sortedBuffs = getSortedBuffDefinitions()

    -- Look for pet-specific buffs
    for _, entryDef in ipairs(sortedBuffs) do
        local category = entryDef.category
        local buffDef = entryDef.def
        -- Check if this buff targets pets
        local targets = buffDef.targets or 'group'
        if targets ~= 'pets' and not buffDef.includePets then
            goto continue_pet_buff
        end

        -- Check if this buff is disabled via settingKey (runtime check)
        local settingKey = buffDef.settingKey
        if settingKey then
            local enabled = Core.Settings[settingKey]
            if enabled == false or enabled == 0 then
                goto continue_pet_buff
            end
        end

        -- Check combat state
        if not M.shouldBuffNow(buffDef) then
            goto continue_pet_buff
        end

        local rebuffWindow = buffDef.rebuffWindow or DEFAULT_REBUFF_WINDOW

        -- Resolve spell first so we can refresh buff state for pets
        local lineName = buffDef.petSpellLine or buffDef.spellLine
        local checkSpell = lineName and resolveBestBookSpellFromLine(lineName) or nil
        local checkSpellId = checkSpell and getSpellId(checkSpell) or nil
        if checkSpellId then
            refreshBuffStateForPets(category, checkSpellId, BUFF_CHECK_INTERVAL)
        end

        local needing = Cache.getPetsNeedingBuff(category, rebuffWindow)

        for _, entry in ipairs(needing) do
            local pet = entry.pet
            if pet and pet.id and pet.id > 0 then
                -- Check not blocked (use owner name)
                local ownerName = entry.owner and entry.owner.name or ''
                local petBlockKey = category .. '_pet'
                if not (M.isBuffBlocked(ownerName, petBlockKey) or M.isBuffBlocked(ownerName, category)) then
                    -- Check not claimed
                    if not M.isBuffClaimed(pet.id, category) then
                        -- Get spell
                        local spellName = resolveBestBookSpellFromLine(lineName)
                        if spellName then
                            if not ensureBuffSpellMemorized(spellName) then
                                return true
                            end
                            if M.claimBuff(pet.id, category) then
                                local success, reason = M.castBuff(pet.id, category, spellName, buffDef)
                                if success then
                                    return true -- One cast per tick
                                else
                                    M.releaseClaim(pet.id, category)
                                end
                            end
                        end
                    end
                end
            end
        end

        ::continue_pet_buff::
    end

    return false
end

return M
