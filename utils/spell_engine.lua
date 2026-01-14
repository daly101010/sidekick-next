-- F:/lua/SideKick/utils/spell_engine.lua
-- Spell Engine - Core casting state machine
-- Blocking pre-checks, non-blocking cast monitoring, auto-interrupt

local mq = require('mq')

local M = {}

-- Lazy-load dependencies to avoid circular requires
local _SpellEvents = nil
local function getSpellEvents()
    if not _SpellEvents then
        local ok, se = pcall(require, 'utils.spell_events')
        if ok then _SpellEvents = se end
    end
    return _SpellEvents
end

local _Cache = nil
local function getCache()
    if not _Cache then
        local ok, c = pcall(require, 'utils.runtime_cache')
        if ok then _Cache = c end
    end
    return _Cache
end

local _Core = nil
local function getCore()
    if not _Core then
        local ok, c = pcall(require, 'utils.core')
        if ok then _Core = c end
    end
    return _Core
end

-- Cast states
M.STATE = {
    IDLE = 0,
    PRE_CHECKS = 1,
    MEMORIZING = 2,
    WAITING_READY = 3,
    CAST_ISSUED = 4,
    WAITING_START = 5,
    CASTING = 6,
    COMPLETED = 7,
}

-- State names for debugging
M.STATE_NAMES = {
    [0] = 'IDLE',
    [1] = 'PRE_CHECKS',
    [2] = 'MEMORIZING',
    [3] = 'WAITING_READY',
    [4] = 'CAST_ISSUED',
    [5] = 'WAITING_START',
    [6] = 'CASTING',
    [7] = 'COMPLETED',
}

-- Spell target types that don't require a target
local SELF_TARGET_TYPES = {
    ['Self'] = true,
    ['PB AE'] = true,
    ['Self Only'] = true,
}

-- Current cast state
local _state = M.STATE.IDLE
local _castData = nil
local _initialized = false

-- Settings cache
local _settings = nil
local function getSettings()
    if not _settings then
        local Core = getCore()
        if Core and Core.Settings then
            _settings = Core.Settings
        end
    end
    return _settings or {}
end

-- Get setting value with default
local function getSetting(key, default)
    local settings = getSettings()
    local value = settings[key]
    if value == nil then return default end
    return value
end

--- Initialize spell engine
function M.init()
    local SpellEvents = getSpellEvents()
    if SpellEvents then
        SpellEvents.registerEvents()
    end
    _initialized = true
    _state = M.STATE.IDLE
    _castData = nil
end

--- Shutdown spell engine
function M.shutdown()
    local SpellEvents = getSpellEvents()
    if SpellEvents then
        SpellEvents.unregisterEvents()
    end
    _initialized = false
    _state = M.STATE.IDLE
    _castData = nil
end

--- Pre-cast validation checks (BLOCKING)
-- @param spellName string Spell name to cast
-- @param targetId number|nil Target spawn ID
-- @param opts table|nil Options: allowDead, allowMem, preferredGem, spellCategory
-- @return boolean Success
-- @return string|nil Failure reason
local function preCastChecks(spellName, targetId, opts)
    opts = opts or {}
    local me = mq.TLO.Me
    if not me or not me() then
        return false, 'no_character'
    end

    -- Get spell info
    local spell = mq.TLO.Spell(spellName)
    if not spell or not spell() then
        return false, 'invalid_spell'
    end

    -- Check if we have the spell in spellbook
    local inBook = me.Book(spellName)
    if not inBook or not inBook() then
        return false, 'not_in_book'
    end

    -- Check mana
    local manaCost = tonumber(spell.Mana()) or 0
    local currentMana = tonumber(me.CurrentMana()) or 0
    if manaCost > 0 and currentMana < manaCost then
        return false, 'insufficient_mana'
    end

    -- Check endurance (for some spells)
    local endCost = tonumber(spell.EnduranceCost()) or 0
    local currentEnd = tonumber(me.CurrentEndurance()) or 0
    if endCost > 0 and currentEnd < endCost then
        return false, 'insufficient_endurance'
    end

    -- Check not already casting
    if me.Casting() then
        return false, 'already_casting'
    end

    -- Check window not open
    if mq.TLO.Window("CastingWindow").Open() then
        return false, 'casting_window_open'
    end

    -- Check not stunned/mezzed/silenced
    if me.Stunned() then
        return false, 'stunned'
    end
    if me.Mezzed and me.Mezzed() then
        return false, 'mezzed'
    end
    if me.Silenced and me.Silenced() then
        return false, 'silenced'
    end

    -- Check standing (stand up if sitting)
    if me.Sitting() then
        mq.cmd('/stand')
        mq.delay(100, function() return me.Standing() end)
        if not me.Standing() then
            return false, 'not_standing'
        end
    end

    -- Check target for targeted spells
    local targetType = spell.TargetType() or ''
    if not SELF_TARGET_TYPES[targetType] then
        if targetId and targetId > 0 then
            local target = mq.TLO.Spawn(targetId)
            if not target or not target() then
                return false, 'invalid_target'
            end
            -- Check target not dead (unless allowDead)
            if target.Dead() and not opts.allowDead then
                return false, 'target_dead'
            end
            -- Range check
            local range = tonumber(spell.MyRange()) or 200
            local distance = tonumber(target.Distance()) or 999
            if distance > range then
                return false, 'out_of_range'
            end
            -- Line of sight check
            if not target.LineOfSight() then
                return false, 'no_line_of_sight'
            end
        elseif spell.TargetType() ~= 'AE Target' then
            -- Need a target but don't have one
            local currentTarget = mq.TLO.Target
            if not currentTarget or not currentTarget() then
                return false, 'no_target'
            end
        end
    end

    return true, nil
end

--- Check if spell is memorized (no auto-memorization)
-- @param spellName string Spell name
-- @return boolean Success
-- @return string|nil Failure reason
local function checkMemorized(spellName)
    local me = mq.TLO.Me

    -- Check if memorized in any gem slot
    local gemSlot = me.Gem(spellName)()
    if gemSlot and gemSlot > 0 then
        return true, nil
    end

    -- Not memorized - spell must already be in gems
    return false, 'not_memorized'
end

--- Wait for spell to be ready
-- @param spellName string Spell name
-- @param maxWait number Maximum wait time in ms
-- @return boolean Success
local function waitSpellReady(spellName, maxWait)
    local me = mq.TLO.Me
    maxWait = maxWait or 5000
    local startTime = mq.gettime()

    while (mq.gettime() - startTime) < maxWait do
        if me.SpellReady(spellName)() then
            return true
        end
        mq.delay(50)
        mq.doevents()
    end

    return me.SpellReady(spellName)() == true
end

--- Main cast function (blocking pre-checks, then transitions to state machine)
-- @param spellName string Spell name to cast
-- @param targetId number|nil Target spawn ID (0 or nil for self/PB spells)
-- @param opts table|nil Options: allowDead, maxRetries, spellCategory
-- @return boolean True if cast initiated (not necessarily complete)
-- @return string|nil Failure reason if false
function M.cast(spellName, targetId, opts)
    opts = opts or {}

    -- Already casting something
    if _state ~= M.STATE.IDLE then
        return false, 'busy'
    end

    -- Blocking pre-checks
    local ok, reason = preCastChecks(spellName, targetId, opts)
    if not ok then
        return false, reason
    end

    -- Check spell is memorized (no auto-memorization)
    ok, reason = checkMemorized(spellName)
    if not ok then
        return false, reason
    end

    -- Wait for spell to be ready (blocking)
    if not waitSpellReady(spellName, getSetting('SpellReadyTimeout', 5000)) then
        return false, 'not_ready'
    end

    -- Get spell info for tracking
    local spell = mq.TLO.Spell(spellName)
    local castTime = spell and tonumber(spell.MyCastTime()) or 0
    local range = spell and tonumber(spell.MyRange()) or 200

    -- Reset event state
    local SpellEvents = getSpellEvents()
    if SpellEvents then
        SpellEvents.resetResult()
    end

    -- Target if needed
    if targetId and targetId > 0 then
        local currentTarget = mq.TLO.Target
        if not currentTarget or currentTarget.ID() ~= targetId then
            mq.cmdf('/target id %d', targetId)
            mq.delay(100, function()
                local t = mq.TLO.Target
                return t and t.ID() == targetId
            end)
        end
    end

    -- Issue cast command
    mq.cmdf('/cast "%s"', spellName)

    -- Set up cast tracking
    _castData = {
        spellName = spellName,
        spellId = spell and tonumber(spell.ID()) or 0,
        targetId = targetId or 0,
        startTime = os.clock(),
        castTime = castTime / 1000,  -- Convert to seconds
        range = range,
        retries = opts.maxRetries or getSetting('SpellMaxRetries', 3),
        opts = opts,
        spellCategory = opts.spellCategory or opts.category or 'unknown',
    }
    _state = M.STATE.WAITING_START

    -- Mark spell channel as used
    local ok2, Executor = pcall(require, 'utils.action_executor')
    if ok2 and Executor then
        Executor.markChannelUsed('spell')
        Executor.setCasting(true, _castData.castTime + 0.5)
    end

    return true, nil
end

--- Check auto-interrupt conditions
-- @return boolean True if should interrupt
-- @return string|nil Reason for interrupt
function M.shouldInterrupt()
    if not _castData then return false end

    local Cache = getCache()
    local settings = getSettings()
    local me = mq.TLO.Me

    -- Check target death (for targeted spells)
    if _castData.targetId and _castData.targetId > 0 then
        if settings.InterruptOnTargetDeath ~= false then
            local target = mq.TLO.Spawn(_castData.targetId)
            if not target or not target() then
                return true, 'target_gone'
            end
            if target.Dead() then
                return true, 'target_dead'
            end
        end

        -- Check out of range
        if settings.InterruptOnOutOfRange ~= false then
            local target = mq.TLO.Spawn(_castData.targetId)
            if target and target() then
                local distance = tonumber(target.Distance()) or 999
                if distance > _castData.range * 1.1 then
                    return true, 'out_of_range'
                end
            end
        end
    end

    -- Check self HP emergency
    if settings.InterruptOnSelfEmergency ~= false then
        local threshold = tonumber(settings.InterruptHpThreshold) or 20
        local myHp = Cache and Cache.me.hp or (me.PctHPs and tonumber(me.PctHPs())) or 100
        if myHp < threshold then
            return true, 'self_emergency'
        end
    end

    -- Raid-specific: Stop heals if target HP above threshold
    local category = _castData.spellCategory
    if category == 'heal' and settings.RaidHealStopEnabled then
        local threshold = tonumber(settings.RaidHealStopHpThreshold) or 90
        if _castData.targetId and _castData.targetId > 0 then
            local target = mq.TLO.Spawn(_castData.targetId)
            if target and target() then
                local targetHp = tonumber(target.PctHPs()) or 100
                if targetHp >= threshold then
                    return true, 'heal_target_full'
                end
            end
        end
    end

    -- Raid-specific: Stop damage if mob HP below threshold
    if (category == 'nuke' or category == 'dot' or category == 'damage') and settings.RaidDamageStopEnabled then
        local threshold = tonumber(settings.RaidDamageStopHpThreshold) or 2
        if _castData.targetId and _castData.targetId > 0 then
            local target = mq.TLO.Spawn(_castData.targetId)
            if target and target() then
                local targetHp = tonumber(target.PctHPs()) or 100
                if targetHp <= threshold then
                    return true, 'damage_target_low'
                end
            end
        end
    end

    return false, nil
end

--- Handle cast result and decide retry
-- @param result number Result code from SpellEvents
local function handleResult(result)
    local SpellEvents = getSpellEvents()
    if not SpellEvents then return end

    -- Check if retriable
    if SpellEvents.isRetriable(result) and _castData and _castData.retries > 0 then
        -- Retry the cast
        _castData.retries = _castData.retries - 1
        SpellEvents.resetResult()
        mq.cmdf('/cast "%s"', _castData.spellName)
        _castData.startTime = os.clock()
        _state = M.STATE.WAITING_START
    else
        -- Cast complete (success or unrecoverable failure)
        _state = M.STATE.IDLE
        _castData = nil
    end
end

--- Non-blocking tick (called each frame)
function M.tick()
    if _state == M.STATE.IDLE then
        return
    end

    local me = mq.TLO.Me
    if not me or not me() then
        _state = M.STATE.IDLE
        _castData = nil
        return
    end

    local now = os.clock()
    local SpellEvents = getSpellEvents()
    local result, resultTime = 0, 0
    if SpellEvents then
        result, resultTime = SpellEvents.getLastResult()
    end

    -- State: WAITING_START (waiting for "You begin casting...")
    if _state == M.STATE.WAITING_START then
        -- Check for cast begin event
        if SpellEvents and result == SpellEvents.RESULT.SUCCESS then
            _state = M.STATE.CASTING
            return
        end

        -- Check for immediate failure
        if SpellEvents and result ~= SpellEvents.RESULT.NONE then
            handleResult(result)
            return
        end

        -- Timeout waiting for cast to start (1 second)
        if _castData and (now - _castData.startTime) > 1.0 then
            -- No cast started, retry or fail
            if _castData.retries > 0 then
                _castData.retries = _castData.retries - 1
                if SpellEvents then SpellEvents.resetResult() end
                mq.cmdf('/cast "%s"', _castData.spellName)
                _castData.startTime = now
            else
                _state = M.STATE.IDLE
                _castData = nil
            end
        end
        return
    end

    -- State: CASTING (non-blocking monitoring)
    if _state == M.STATE.CASTING then
        -- Check if still casting
        local isCasting = me.Casting() or mq.TLO.Window("CastingWindow").Open()
        if not isCasting then
            -- Cast finished, check result
            handleResult(result)
            return
        end

        -- Check for failure events during cast
        if SpellEvents and result ~= SpellEvents.RESULT.NONE and result ~= SpellEvents.RESULT.SUCCESS then
            -- Failed during cast (interrupt, etc.)
            handleResult(result)
            return
        end

        -- Auto-interrupt checks
        local shouldStop, stopReason = M.shouldInterrupt()
        if shouldStop then
            mq.TLO.Me.StopCast()
            _state = M.STATE.IDLE
            _castData = nil
            return
        end

        -- Still casting, continue monitoring
        return
    end

    -- State: COMPLETED (cleanup)
    if _state == M.STATE.COMPLETED then
        _state = M.STATE.IDLE
        _castData = nil
    end
end

--- Check if currently casting
-- @return boolean
function M.isCasting()
    return _state ~= M.STATE.IDLE
end

--- Check if busy (casting or processing)
-- @return boolean
function M.isBusy()
    return _state ~= M.STATE.IDLE
end

--- Get current state
-- @return number State code
-- @return string State name
function M.getState()
    return _state, M.STATE_NAMES[_state] or 'UNKNOWN'
end

--- Get current cast info
-- @return table|nil Cast data
function M.getCastInfo()
    if _castData then
        return {
            spellName = _castData.spellName,
            spellId = _castData.spellId,
            targetId = _castData.targetId,
            startTime = _castData.startTime,
            castTime = _castData.castTime,
            retriesLeft = _castData.retries,
            category = _castData.spellCategory,
        }
    end
    return nil
end

--- Abort current cast
function M.abort()
    if _state ~= M.STATE.IDLE then
        local me = mq.TLO.Me
        if me and me.Casting() then
            mq.TLO.Me.StopCast()
        end
        _state = M.STATE.IDLE
        _castData = nil
    end
end

--- Check if initialized
-- @return boolean
function M.isInitialized()
    return _initialized
end

return M
