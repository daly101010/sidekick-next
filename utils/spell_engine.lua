-- F:/lua/SideKick/utils/spell_engine.lua
-- Spell Engine - Core casting state machine
-- Blocking pre-checks, non-blocking cast monitoring, auto-interrupt

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

local debugLog = require('sidekick-next.utils.debug_log').tagged('SpellEngine', 'SideKick_SpellEngine.log')

-- Lazy-load dependencies to avoid circular requires
local getSpellEvents = lazy('sidekick-next.utils.spell_events')
local getCache = lazy('sidekick-next.utils.runtime_cache')
local getCore = lazy('sidekick-next.utils.core')
local getBuffLogger = lazy('sidekick-next.automation.buff_logger')
local getResistLog = lazy('sidekick-next.utils.resist_log')
local getHumanize = lazy.once('sidekick-next.humanize')

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

-- Current cast state (use setState() to update — tracks entry time for watchdog)
local _state = M.STATE.IDLE
local _castData = nil
local _initialized = false
local _stateEnteredAt = os.clock()

-- Maximum time any non-IDLE state can persist before forced reset (seconds)
local MAX_CASTING_TIME = 15.0   -- Longest EQ spell is ~12s, add buffer
local MAX_STATE_TIME = 20.0     -- Global watchdog for any stuck state

local function setState(newState)
    _state = newState
    _stateEnteredAt = os.clock()
end

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
    setState(M.STATE.IDLE)
    _castData = nil
end

--- Shutdown spell engine
function M.shutdown()
    local SpellEvents = getSpellEvents()
    if SpellEvents then
        SpellEvents.unregisterEvents()
    end
    _initialized = false
    setState(M.STATE.IDLE)
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

    -- Check not already casting. Casting() returns the spell name when active,
    -- empty string OR the literal "NULL" when idle — must reject both.
    local casting = me.Casting() or ''
    if casting ~= '' and casting ~= 'NULL' then
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

--- Check whether a spell is ready right now (no waiting).
--- The previous `waitSpellReady` polled for up to 5 seconds, which froze the
--- entire main loop (no healing, no defensives) whenever the rotation
--- dispatched a spell still on cooldown. The rotation/executor now treat
--- "not ready" as a soft skip and move on to the next ready spell.
local function isSpellReady(spellName)
    local me = mq.TLO.Me
    return me and me.SpellReady(spellName)() == true
end

local function shouldRecordResistCast(opts)
    opts = opts or {}
    local category = tostring(opts.spellCategory or opts.category or ''):lower()
    local layer = tostring(opts.sourceLayer or ''):lower()
    if category == 'heal' or category == 'buff' or category == 'selfbuff'
        or category == 'groupbuff' or category == 'aura' then
        return false
    end
    return category == 'nuke' or category == 'dot' or category == 'damage'
        or category == 'debuff' or layer == 'combat' or layer == 'support'
        or layer == 'aggro' or layer == 'burn'
end

local function recordResistCast(spellName, targetId, opts)
    if not shouldRecordResistCast(opts) then return end
    targetId = tonumber(targetId) or 0
    if targetId <= 0 then return end
    local ResistLog = getResistLog()
    if not (ResistLog and ResistLog.recordCast) then return end
    local target = mq.TLO.Spawn(targetId)
    local targetName = target and target() and target.CleanName and target.CleanName() or ''
    if spellName and spellName ~= '' and targetName ~= '' then
        ResistLog.recordCast(spellName, targetName)
    end
end

--- Main cast function (blocking pre-checks, then transitions to state machine)
-- @param spellName string Spell name to cast
-- @param targetId number|nil Target spawn ID (0 or nil for self/PB spells)
-- @param opts table|nil Options: allowDead, maxRetries, spellCategory
-- @return boolean True if cast initiated (not necessarily complete)
-- @return string|nil Failure reason if false
function M.cast(spellName, targetId, opts)
    opts = opts or {}

    local buffLog = (opts.spellCategory == 'buff') and getBuffLogger() or nil
    if buffLog then
        buffLog.info('spell_engine', 'Cast request: spell=%s targetId=%d category=%s',
            tostring(spellName), tonumber(targetId) or 0, tostring(opts.spellCategory))
    end

    -- Already casting something
    if _state ~= M.STATE.IDLE then
        if buffLog then
            buffLog.warn('spell_engine', 'Cast rejected: spell=%s reason=busy state=%s',
                tostring(spellName), tostring(M.STATE_NAMES[_state] or _state))
        end
        return false, 'busy'
    end

    -- Blocking pre-checks
    local ok, reason = preCastChecks(spellName, targetId, opts)
    if not ok then
        if buffLog then
            buffLog.warn('spell_engine', 'Cast rejected: spell=%s reason=%s',
                tostring(spellName), tostring(reason))
        end
        return false, reason
    end

    -- Check spell is memorized (no auto-memorization)
    ok, reason = checkMemorized(spellName)
    if not ok then
        if buffLog then
            buffLog.warn('spell_engine', 'Cast rejected: spell=%s reason=%s',
                tostring(spellName), tostring(reason))
        end
        return false, reason
    end

    -- Soft-skip if the spell isn't ready right now. Caller (rotation/executor)
    -- will move on to the next ready spell; trying to wait here used to stall
    -- the main loop for up to 5s.
    if not isSpellReady(spellName) then
        if buffLog then
            buffLog.warn('spell_engine', 'Cast rejected: spell=%s reason=not_ready',
                tostring(spellName))
        end
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
        local currentTargetId = currentTarget and currentTarget() and currentTarget.ID() or 0
        if currentTargetId ~= targetId then
            mq.cmdf('/target id %d', targetId)
            mq.delay(100, function()
                local t = mq.TLO.Target
                return t and t() and t.ID() == targetId
            end)
            local t = mq.TLO.Target
            if not (t and t() and t.ID() == targetId) then
                return false, 'target_failed'
            end
        end
    end

    -- Humanize gate: reaction + precast delay before issuing /cast.
    -- urgency='emergency' is set by emergency healers; runs through 'emergency' profile (fast tail).
    -- SKIP drops the cast attempt for this tick.
    local Humanize = getHumanize()
    if Humanize and Humanize.gate then
        local urgency = opts.urgency
        if not urgency and (opts.spellCategory == 'emergency' or opts.priority == 0) then
            urgency = 'emergency'
        end
        local d = Humanize.gate('cast', { target = targetId, spell = spellName, urgency = urgency })
        if d == Humanize.SKIP then
            if buffLog then
                buffLog.info('spell_engine', 'Cast humanize-skipped: spell=%s', tostring(spellName))
            end
            return false, 'humanize_skip'
        end
        if d and d > 0 then mq.delay(d) end
    end

    -- Issue cast command
    mq.cmdf('/cast "%s"', spellName)
    recordResistCast(spellName, targetId, opts)

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
    setState(M.STATE.WAITING_START)

    if buffLog then
        buffLog.info('spell_engine', 'Cast issued: spell=%s targetId=%d category=%s retries=%d',
            tostring(spellName), tonumber(targetId) or 0, tostring(_castData.spellCategory), _castData.retries or 0)
    end

    -- Mark spell channel as used
    local ok2, Executor = pcall(require, 'sidekick-next.utils.action_executor')
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

    local buffLog = (_castData and _castData.spellCategory == 'buff') and getBuffLogger() or nil

    -- Check if retriable
    if SpellEvents.isRetriable(result) and _castData and _castData.retries > 0 then
        -- Retry the cast
        if buffLog then
            buffLog.warn('spell_engine', 'Cast retry: spell=%s result=%s retriesLeft=%d',
                tostring(_castData.spellName), SpellEvents.getResultName(result), _castData.retries)
        end
        _castData.retries = _castData.retries - 1
        SpellEvents.resetResult()
        mq.cmdf('/cast "%s"', _castData.spellName)
        _castData.startTime = os.clock()
        setState(M.STATE.WAITING_START)
    else
        -- Cast complete (success or unrecoverable failure)
        if buffLog and _castData then
            buffLog.info('spell_engine', 'Cast completed: spell=%s result=%s',
                tostring(_castData.spellName), SpellEvents.getResultName(result))
        end
        setState(M.STATE.IDLE)
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
        debugLog('[Tick] no me, resetting to IDLE')
        setState(M.STATE.IDLE)
        _castData = nil
        return
    end

    local now = os.clock()

    -- Global stuck-state watchdog: force reset if any state persists too long
    local stateAge = now - _stateEnteredAt
    local timeout = (_state == M.STATE.CASTING) and MAX_CASTING_TIME or MAX_STATE_TIME
    if stateAge > timeout then
        local stateName = M.STATE_NAMES[_state] or 'UNKNOWN'
        debugLog('[Tick] WATCHDOG: state %s stuck for %.1fs (limit %.1fs), forcing IDLE',
            stateName, stateAge, timeout)
        print(string.format(
            '\ar[SpellEngine]\ax Watchdog: stuck in %s for %.1fs, resetting', stateName, stateAge))
        setState(M.STATE.IDLE)
        _castData = nil
        return
    end
    local SpellEvents = getSpellEvents()
    local result, resultTime = 0, 0
    if SpellEvents then
        result, resultTime = SpellEvents.getLastResult()
    end

    local stateName = M.STATE_NAMES[_state] or 'UNKNOWN'
    debugLog('[Tick] state=%s result=%s spell=%s', stateName, tostring(result), tostring(_castData and _castData.spellName or 'nil'))

    -- State: WAITING_START (waiting for "You begin casting...")
    if _state == M.STATE.WAITING_START then
        -- Check for cast begin event
        if SpellEvents and result == SpellEvents.RESULT.SUCCESS then
            debugLog('[Tick] WAITING_START -> CASTING (success event)')
            setState(M.STATE.CASTING)
            return
        end

        -- Check for immediate failure
        if SpellEvents and result ~= SpellEvents.RESULT.NONE then
            debugLog('[Tick] WAITING_START -> handleResult (failure result=%d)', result)
            handleResult(result)
            return
        end

        -- Timeout waiting for cast to start (1 second)
        if _castData and (now - _castData.startTime) > 1.0 then
            debugLog('[Tick] WAITING_START timeout (%.2fs elapsed)', now - _castData.startTime)
            -- No cast started, retry or fail
            if _castData.retries > 0 then
                _castData.retries = _castData.retries - 1
                if SpellEvents then SpellEvents.resetResult() end
                debugLog('[Tick] retrying cast, retries left=%d', _castData.retries)
                mq.cmdf('/cast "%s"', _castData.spellName)
                _castData.startTime = now
            else
                debugLog('[Tick] WAITING_START -> IDLE (no retries left)')
                setState(M.STATE.IDLE)
                _castData = nil
            end
        end
        return
    end

    -- State: CASTING (non-blocking monitoring)
    if _state == M.STATE.CASTING then
        -- Check if still casting (Casting() returns spell name string, empty
        -- or "NULL" when not casting).
        local castingSpell = me.Casting() or ''
        local isCasting = (castingSpell ~= '' and castingSpell ~= 'NULL')
            or mq.TLO.Window("CastingWindow").Open()
        if not isCasting then
            debugLog('[Tick] CASTING -> handleResult (cast finished)')
            -- Cast finished, check result
            handleResult(result)
            return
        end

        -- Check for failure events during cast
        if SpellEvents and result ~= SpellEvents.RESULT.NONE and result ~= SpellEvents.RESULT.SUCCESS then
            debugLog('[Tick] CASTING -> handleResult (failure during cast result=%d)', result)
            -- Failed during cast (interrupt, etc.)
            handleResult(result)
            return
        end

        -- Auto-interrupt checks
        local shouldStop, stopReason = M.shouldInterrupt()
        if shouldStop then
            debugLog('[Tick] CASTING interrupted reason=%s', tostring(stopReason))
            mq.TLO.Me.StopCast()
            setState(M.STATE.IDLE)
            _castData = nil
            return
        end

        -- Still casting, continue monitoring
        return
    end

    -- State: COMPLETED (cleanup)
    if _state == M.STATE.COMPLETED then
        debugLog('[Tick] COMPLETED -> IDLE')
        setState(M.STATE.IDLE)
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
        local casting = me and me.Casting() or ''
        if casting ~= '' and casting ~= 'NULL' then
            mq.TLO.Me.StopCast()
        end
        setState(M.STATE.IDLE)
        _castData = nil
    end
end

--- Check if initialized
-- @return boolean
function M.isInitialized()
    return _initialized
end

return M
