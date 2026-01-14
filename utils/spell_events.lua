-- F:/lua/SideKick/utils/spell_events.lua
-- Spell Events - Event handler registration for cast result detection
-- Follows rgmercs pattern with mq.event() for chat message parsing

local mq = require('mq')

local M = {}

-- Cast result constants (matching rgmercs pattern)
M.RESULT = {
    NONE        = 0,
    SUCCESS     = 1,   -- "You begin casting..."
    BLOCKED     = 2,
    IMMUNE      = 3,   -- Target immune
    FDFAIL      = 4,   -- Feign death failed
    COMPONENTS  = 5,   -- Missing reagents
    CANNOTSEE   = 6,   -- Can't see target
    TAKEHOLD    = 7,   -- Spell didn't take hold
    STUNNED     = 8,   -- Can't cast while stunned
    STANDING    = 9,   -- Must be standing
    RESISTED    = 10,  -- Target resisted
    RECOVER     = 11,  -- Spell recovery
    PENDING     = 12,
    OUTDOORS    = 13,  -- Must be outdoors
    OUTOFRANGE  = 14,  -- Out of range
    OUTOFMANA   = 15,  -- Insufficient mana
    NOTREADY    = 16,  -- Not ready
    NOTARGET    = 17,  -- No target
    INTERRUPTED = 18,  -- Interrupted
    FIZZLE      = 19,  -- Fizzled
    DISTRACTED  = 20,  -- Silenced/distracted
    COLLAPSE    = 21,  -- Gate collapsed
    OVERWRITTEN = 22,  -- Buff overwritten
}

-- Result name lookup
M.RESULT_NAMES = {}
for name, id in pairs(M.RESULT) do
    M.RESULT_NAMES[id] = name
end

-- Retriable results (cast again makes sense)
M.RETRIABLE = {
    [M.RESULT.FIZZLE] = true,
    [M.RESULT.RECOVER] = true,
    [M.RESULT.NOTREADY] = true,
}

-- Completed results (stop retrying, cast finished one way or another)
M.COMPLETED = {
    [M.RESULT.SUCCESS] = true,
    [M.RESULT.IMMUNE] = true,
    [M.RESULT.TAKEHOLD] = true,
    [M.RESULT.RESISTED] = true,
}

-- Failed results (cast failed, may or may not retry)
M.FAILED = {
    [M.RESULT.FIZZLE] = true,
    [M.RESULT.INTERRUPTED] = true,
    [M.RESULT.RESISTED] = true,
    [M.RESULT.IMMUNE] = true,
    [M.RESULT.OUTOFRANGE] = true,
    [M.RESULT.OUTOFMANA] = true,
    [M.RESULT.NOTARGET] = true,
    [M.RESULT.STUNNED] = true,
    [M.RESULT.DISTRACTED] = true,
    [M.RESULT.CANNOTSEE] = true,
}

-- Current result state
local _lastResult = M.RESULT.NONE
local _lastResultTime = 0
local _lastResistSpell = nil
local _lastResistTarget = nil

-- Callback for external notification
local _onResultCallback = nil

-- Internal: set result and notify
local function setResult(result, extra)
    _lastResult = result
    _lastResultTime = os.clock()
    if extra then
        if extra.spell then _lastResistSpell = extra.spell end
        if extra.target then _lastResistTarget = extra.target end
    end
    if _onResultCallback then
        pcall(_onResultCallback, result, extra)
    end
end

--- Get the last cast result
-- @return number Result code
-- @return number Time of result (os.clock())
function M.getLastResult()
    return _lastResult, _lastResultTime
end

--- Get result name from code
-- @param result number Result code
-- @return string Result name
function M.getResultName(result)
    return M.RESULT_NAMES[result] or 'UNKNOWN'
end

--- Set callback for result notifications
-- @param fn function Callback(result, extra)
function M.setResultCallback(fn)
    _onResultCallback = fn
end

--- Reset result state
function M.resetResult()
    _lastResult = M.RESULT.NONE
    _lastResultTime = 0
    _lastResistSpell = nil
    _lastResistTarget = nil
end

--- Check if result is retriable
-- @param result number Result code
-- @return boolean
function M.isRetriable(result)
    return M.RETRIABLE[result] == true
end

--- Check if result means cast completed (success or definitive failure)
-- @param result number Result code
-- @return boolean
function M.isCompleted(result)
    return M.COMPLETED[result] == true
end

--- Check if result is a failure
-- @param result number Result code
-- @return boolean
function M.isFailed(result)
    return M.FAILED[result] == true
end

--- Get last resist info
-- @return string|nil Spell name
-- @return string|nil Target name
function M.getLastResistInfo()
    return _lastResistSpell, _lastResistTarget
end

--- Register all spell-related events
function M.registerEvents()
    -- ============================================
    -- SUCCESS EVENTS (cast started)
    -- ============================================
    mq.event('sk_cast_begin1', "You begin casting#*#", function()
        setResult(M.RESULT.SUCCESS)
    end)

    mq.event('sk_cast_begin2', "You begin singing#*#", function()
        setResult(M.RESULT.SUCCESS)
    end)

    mq.event('sk_cast_begin3', "Your #1# begins to glow.#*#", function()
        setResult(M.RESULT.SUCCESS)
    end)

    -- ============================================
    -- FIZZLE EVENTS
    -- ============================================
    mq.event('sk_fizzle1', "Your spell fizzles#*#", function()
        setResult(M.RESULT.FIZZLE)
    end)

    mq.event('sk_fizzle2', "You miss a note, bringing your song to a close#*#", function()
        setResult(M.RESULT.FIZZLE)
    end)

    -- ============================================
    -- INTERRUPTED EVENTS
    -- ============================================
    mq.event('sk_interrupt1', "Your spell is interrupted#*#", function()
        setResult(M.RESULT.INTERRUPTED)
    end)

    mq.event('sk_interrupt2', "Your casting has been interrupted#*#", function()
        setResult(M.RESULT.INTERRUPTED)
    end)

    mq.event('sk_interrupt3', "Your song ends abruptly#*#", function()
        setResult(M.RESULT.INTERRUPTED)
    end)

    -- ============================================
    -- RESIST EVENTS
    -- ============================================
    mq.event('sk_resist1', "Your target resisted the #1# spell#*#", function(_, spell)
        setResult(M.RESULT.RESISTED, { spell = spell })
    end)

    mq.event('sk_resist2', "#2# resisted your #1#!", function(_, spell, target)
        setResult(M.RESULT.RESISTED, { spell = spell, target = target })
    end)

    -- ============================================
    -- NO TARGET EVENTS
    -- ============================================
    mq.event('sk_notarget1', "You must first select a target for this spell#*#", function()
        setResult(M.RESULT.NOTARGET)
    end)

    mq.event('sk_notarget2', "You must first click on the being you wish to attack#*#", function()
        setResult(M.RESULT.NOTARGET)
    end)

    -- ============================================
    -- OUT OF RANGE EVENTS
    -- ============================================
    mq.event('sk_oor1', "Your target is out of range, get closer#*#", function()
        setResult(M.RESULT.OUTOFRANGE)
    end)

    mq.event('sk_oor2', "You are too far away#*#", function()
        setResult(M.RESULT.OUTOFRANGE)
    end)

    -- ============================================
    -- OUT OF MANA EVENTS
    -- ============================================
    mq.event('sk_oom1', "Insufficient Mana to cast this spell#*#", function()
        setResult(M.RESULT.OUTOFMANA)
    end)

    -- ============================================
    -- STUNNED/CC EVENTS
    -- ============================================
    mq.event('sk_stunned1', "You can't cast spells while stunned#*#", function()
        setResult(M.RESULT.STUNNED)
    end)

    mq.event('sk_stunned2', "You are stunned#*#", function()
        setResult(M.RESULT.STUNNED)
    end)

    mq.event('sk_distracted1', "You are too distracted to cast a spell now#*#", function()
        setResult(M.RESULT.DISTRACTED)
    end)

    mq.event('sk_distracted2', "You *CANNOT* cast spells, you have been silenced#*#", function()
        setResult(M.RESULT.DISTRACTED)
    end)

    -- ============================================
    -- IMMUNE/TAKE HOLD EVENTS
    -- ============================================
    mq.event('sk_immune1', "Your target is immune#*#", function()
        setResult(M.RESULT.IMMUNE)
    end)

    mq.event('sk_immune2', "Your target has no mana to affect#*#", function()
        setResult(M.RESULT.IMMUNE)
    end)

    mq.event('sk_immune3', "Your target cannot be mesmerized#*#", function()
        setResult(M.RESULT.IMMUNE)
    end)

    mq.event('sk_immune4', "Your target looks unaffected#*#", function()
        setResult(M.RESULT.IMMUNE)
    end)

    mq.event('sk_takehold1', "Your spell did not take hold#*#", function()
        setResult(M.RESULT.TAKEHOLD)
    end)

    mq.event('sk_takehold2', "Your spell would not have taken hold#*#", function()
        setResult(M.RESULT.TAKEHOLD)
    end)

    -- ============================================
    -- ADDITIONAL IMMUNE PATTERNS (specific debuffs)
    -- ============================================
    mq.event('sk_immune_slow', "Your target is immune to changes in its attack speed#*#", function()
        setResult(M.RESULT.IMMUNE, { immuneType = 'slow' })
    end)

    mq.event('sk_immune_snare', "Your target is immune to changes in its run speed#*#", function()
        setResult(M.RESULT.IMMUNE, { immuneType = 'snare' })
    end)

    mq.event('sk_immune_root', "Your target cannot be rooted#*#", function()
        setResult(M.RESULT.IMMUNE, { immuneType = 'root' })
    end)

    mq.event('sk_immune_charm', "Your target cannot be charmed#*#", function()
        setResult(M.RESULT.IMMUNE, { immuneType = 'charm' })
    end)

    mq.event('sk_immune_stun', "Your target is immune to stun#*#", function()
        setResult(M.RESULT.IMMUNE, { immuneType = 'stun' })
    end)

    mq.event('sk_immune_fear', "Your target is immune to fear#*#", function()
        setResult(M.RESULT.IMMUNE, { immuneType = 'fear' })
    end)

    -- ============================================
    -- CAN'T SEE TARGET EVENTS
    -- ============================================
    mq.event('sk_cannotsee1', "You cannot see your target#*#", function()
        setResult(M.RESULT.CANNOTSEE)
    end)

    -- ============================================
    -- STANDING/POSITION EVENTS
    -- ============================================
    mq.event('sk_standing1', "You must be standing to cast a spell#*#", function()
        setResult(M.RESULT.STANDING)
    end)

    mq.event('sk_outdoors1', "This spell does not work here#*#", function()
        setResult(M.RESULT.OUTDOORS)
    end)

    -- ============================================
    -- COMPONENTS/REAGENTS EVENTS
    -- ============================================
    mq.event('sk_components1', "You are missing some required components#*#", function()
        setResult(M.RESULT.COMPONENTS)
    end)

    -- ============================================
    -- RECOVERY EVENTS
    -- ============================================
    mq.event('sk_recover1', "Spell recovery time not yet met#*#", function()
        setResult(M.RESULT.RECOVER)
    end)

    -- ============================================
    -- MEMORIZATION EVENTS (callbacks)
    -- ============================================
    mq.event('sk_mem_begin', "Beginning to memorize #1#...", function(_, spell)
        -- Notify listener if callback set
        if M.onMemBegin then
            pcall(M.onMemBegin, spell)
        end
    end)

    mq.event('sk_mem_end', "You have finished memorizing #1##*#", function(_, spell)
        if M.onMemEnd then
            pcall(M.onMemEnd, spell)
        end
    end)

    mq.event('sk_mem_abort', "Aborting memorization of spell.", function()
        if M.onMemAbort then
            pcall(M.onMemAbort)
        end
    end)
end

--- Unregister all spell-related events
function M.unregisterEvents()
    -- Success events
    mq.unevent('sk_cast_begin1')
    mq.unevent('sk_cast_begin2')
    mq.unevent('sk_cast_begin3')

    -- Fizzle events
    mq.unevent('sk_fizzle1')
    mq.unevent('sk_fizzle2')

    -- Interrupted events
    mq.unevent('sk_interrupt1')
    mq.unevent('sk_interrupt2')
    mq.unevent('sk_interrupt3')

    -- Resist events
    mq.unevent('sk_resist1')
    mq.unevent('sk_resist2')

    -- No target events
    mq.unevent('sk_notarget1')
    mq.unevent('sk_notarget2')

    -- Out of range events
    mq.unevent('sk_oor1')
    mq.unevent('sk_oor2')

    -- Out of mana events
    mq.unevent('sk_oom1')

    -- Stunned/CC events
    mq.unevent('sk_stunned1')
    mq.unevent('sk_stunned2')
    mq.unevent('sk_distracted1')
    mq.unevent('sk_distracted2')

    -- Immune/Take hold events
    mq.unevent('sk_immune1')
    mq.unevent('sk_immune2')
    mq.unevent('sk_immune3')
    mq.unevent('sk_immune4')
    mq.unevent('sk_takehold1')
    mq.unevent('sk_takehold2')

    -- Additional immune events
    mq.unevent('sk_immune_slow')
    mq.unevent('sk_immune_snare')
    mq.unevent('sk_immune_root')
    mq.unevent('sk_immune_charm')
    mq.unevent('sk_immune_stun')
    mq.unevent('sk_immune_fear')

    -- Can't see target events
    mq.unevent('sk_cannotsee1')

    -- Standing/Position events
    mq.unevent('sk_standing1')
    mq.unevent('sk_outdoors1')

    -- Components events
    mq.unevent('sk_components1')

    -- Recovery events
    mq.unevent('sk_recover1')

    -- Memorization events
    mq.unevent('sk_mem_begin')
    mq.unevent('sk_mem_end')
    mq.unevent('sk_mem_abort')
end

-- Memorization callbacks (optional listeners)
M.onMemBegin = nil
M.onMemEnd = nil
M.onMemAbort = nil

return M
