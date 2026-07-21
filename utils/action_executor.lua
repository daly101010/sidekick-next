-- F:/lua/SideKick/utils/action_executor.lua
-- Action Executor - Channel-based action execution with lockouts
-- Prevents spam, ensures proper sequencing, enables future spell integration

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')
local Core = require('sidekick-next.utils.core')
local Helpers = require('sidekick-next.lib.helpers')
local SkLib = require('sidekick-next.sk_lib')

local M = {}

-- Optional buff logger for tracing executor-level spell casts
local getBuffLogger = lazy('sidekick-next.automation.buff_logger')
local getHumanize = lazy.once('sidekick-next.humanize')

-- Humanize gate for ability-channel actions. Returns:
--   true  -> caller should proceed (after any delay applied here)
--   false -> caller should bail (SKIP rolled or layer told us to drop)
local function humanizeAbilityGate(ctx)
    local H = getHumanize()
    if not H or not H.gate then return true end
    local d = H.gate('ability', ctx or {})
    if d == H.SKIP then return false end
    if d and d > 0 then mq.delay(d) end
    return true
end

local function isBuffSpell(opts)
    if not opts then return false end
    local cat = tostring(opts.spellCategory or opts.category or ''):lower()
    if cat == 'buff' or cat == 'selfbuff' or cat == 'groupbuff' or cat == 'aura' then
        return true
    end
    return tostring(opts.sourceLayer or ''):lower() == 'buff'
end

-- Channels with independent lockouts
local CHANNELS = {
    melee = { lastAction = 0, lockout = 0.1 },    -- 100ms between melee actions
    aa_disc = { lastAction = 0, lockout = 0.1 },  -- 100ms between AA/disc
    spell = { lastAction = 0, lockout = 0.5 },    -- 500ms between spell casts (GCD)
    item = { lastAction = 0, lockout = 0.2 },     -- 200ms between item clicks
}

-- Global casting lock (can't do most actions while casting)
local _casting = false
local _castEndTime = 0

-- One coordinated worker runs in each Lua process, so one claimed action can
-- be active in this process at a time. Cross-process exclusion remains the
-- coordinator's responsibility; this state machine owns the local lifecycle.
local _job = nil
local _lastResult = nil
local _jobCounter = 0

M.PHASE = {
    QUEUED = 'queued',
    DISPATCHING = 'dispatching',
    WAITING_START = 'waiting_start',
    RUNNING = 'running',
    COMPLETED = 'completed',
    FAILED = 'failed',
    CANCELLED = 'cancelled',
}

-- Use centralized game state check from Core
local function can_query_items()
    return Core.CanQueryItems()
end

function M.init()
    for _, ch in pairs(CHANNELS) do
        ch.lastAction = 0
    end
    _casting = false
    _castEndTime = 0
    _job = nil
    _lastResult = nil
end

--- Check if a channel is ready for action
-- @param channel string Channel name ('melee', 'aa_disc', 'spell', 'item')
-- @return boolean True if channel can execute
function M.isChannelReady(channel)
    local ch = CHANNELS[channel]
    if not ch then return false end

    local now = os.clock()

    -- Global casting lock (except melee)
    if channel ~= 'melee' and _casting and now < _castEndTime then
        return false
    end

    return (now - ch.lastAction) >= ch.lockout
end

--- Mark a channel as used (start lockout)
-- @param channel string Channel name
function M.markChannelUsed(channel)
    local ch = CHANNELS[channel]
    if ch then
        ch.lastAction = os.clock()
    end
end

--- Set casting state (blocks other channels during cast)
-- @param casting boolean Is currently casting
-- @param duration number Cast duration in seconds (optional)
function M.setCasting(casting, duration)
    _casting = casting
    if casting and duration then
        _castEndTime = os.clock() + duration
    elseif not casting then
        _castEndTime = 0
    end
end

--- Check if currently casting
function M.isCasting()
    if _casting and os.clock() >= _castEndTime then
        _casting = false
    end
    return _casting
end

-- AA/Disc Execution

--- Execute an AA ability
-- @param altId number Alt ability ID
-- @return boolean True if executed
function M.executeAA(altId)
    if not altId then return false end
    if not M.isChannelReady('aa_disc') then return false end

    local me = mq.TLO.Me
    if not me or not me() then return false end
    if not me.AltAbilityReady(altId)() then return false end

    if not humanizeAbilityGate({ kind = 'aa', altId = altId }) then return false end

    mq.cmdf('/alt activate %d', altId)
    M.markChannelUsed('aa_disc')
    return true
end

--- Execute a discipline
-- @param discName string Discipline name
-- @return boolean True if executed
function M.executeDisc(discName)
    if not discName or discName == '' then return false end
    if not M.isChannelReady('aa_disc') then return false end

    local me = mq.TLO.Me
    if not me or not me() then return false end

    local readyName = nil
    for _, candidate in ipairs(Helpers.discNameCandidates(discName)) do
        local ok, ready = pcall(function()
            return me.CombatAbilityReady(candidate)() == true
        end)
        if ok and ready then
            readyName = candidate
            break
        end
    end
    if not readyName then return false end

    if not humanizeAbilityGate({ kind = 'disc', name = readyName }) then return false end

    mq.cmd('/disc ' .. readyName)
    M.markChannelUsed('aa_disc')
    return true
end

--- Execute an ability from definition table
-- @param def table Ability definition with kind, altID/discName/spellName
-- @return boolean True if executed
function M.executeAbility(def)
    if not def then return false end

    local kind = tostring(def.kind or 'aa')

    if kind == 'aa' then
        return M.executeAA(tonumber(def.altID))
    elseif kind == 'disc' then
        return M.executeDisc(def.discName or def.altName)
    elseif kind == 'spell' then
        return M.executeSpell(def.spellName, def.targetId, def)
    end

    return false
end

-- Spell Execution

--- Execute a spell through the spell engine
-- @param spellName string Spell name
-- @param targetId number|nil Target spawn ID
-- @param opts table|nil Options (allowMem, preferredGem, maxRetries, spellCategory)
-- @return boolean True if cast initiated
function M.executeSpell(spellName, targetId, opts)
    if not spellName or spellName == '' then return false end
    if not M.isChannelReady('spell') then return false, 'channel_not_ready' end

    -- Delegate to spell engine for full state machine handling
    local ok, SpellEngine = pcall(require, 'sidekick-next.utils.spell_engine')
    if not ok or not SpellEngine then return false, 'no_spell_engine' end

    -- Check if spell engine is already casting
    if SpellEngine.isBusy() then return false, 'busy' end

    local buffLog = isBuffSpell(opts) and getBuffLogger() or nil
    if buffLog then
        buffLog.info('executor', 'Execute spell: spell=%s targetId=%d sourceLayer=%s',
            tostring(spellName), tonumber(targetId) or 0, tostring(opts and opts.sourceLayer or ''))
    end
    local success, reason = SpellEngine.cast(spellName, targetId, opts)
    if buffLog then
        if success then
            buffLog.info('executor', 'Execute spell accepted: spell=%s targetId=%d',
                tostring(spellName), tonumber(targetId) or 0)
        else
            buffLog.warn('executor', 'Execute spell rejected: spell=%s targetId=%d reason=%s',
                tostring(spellName), tonumber(targetId) or 0, tostring(reason))
        end
    end
    return success == true, reason
end

--- Check if spell engine is busy
-- @return boolean True if currently casting a spell
function M.isSpellBusy()
    local ok, SpellEngine = pcall(require, 'sidekick-next.utils.spell_engine')
    if ok and SpellEngine then
        return SpellEngine.isBusy()
    end
    return false
end

-- Item Execution

--- Execute an item click
-- @param itemName string Item name
-- @return boolean True if executed
function M.executeItem(itemName)
    if not itemName or itemName == '' then return false end
    if not M.isChannelReady('item') then return false end

    if not can_query_items() then return false end
    local item = mq.TLO.FindItem(itemName)
    if not item or not item() then return false end
    if item.TimerReady() ~= 0 then return false end  -- 0 means ready

    if not humanizeAbilityGate({ kind = 'item', name = itemName }) then return false end

    mq.cmdf('/useitem "%s"', itemName)
    M.markChannelUsed('item')
    return true
end

--- Execute an item click by slot
-- @param slotName string Slot name (e.g., 'charm', 'pack1')
-- @return boolean True if executed
function M.executeItemSlot(slotName)
    if not slotName or slotName == '' then return false end
    if not M.isChannelReady('item') then return false end

    if not can_query_items() then return false end
    local item = mq.TLO.InvSlot(slotName).Item
    if not item or not item() then return false end
    if item.TimerReady() ~= 0 then return false end

    if not humanizeAbilityGate({ kind = 'itemslot', slot = slotName }) then return false end

    mq.cmdf('/itemnotify %s rightmouseup', slotName)
    M.markChannelUsed('item')
    return true
end

-- Melee Ability Execution

--- Execute a melee ability (Taunt, Kick, Bash, etc.)
-- @param abilityName string Ability name
-- @return boolean True if executed
function M.executeMeleeAbility(abilityName)
    if not abilityName or abilityName == '' then return false end
    if not M.isChannelReady('melee') then return false end

    local me = mq.TLO.Me
    if not me or not me() then return false end
    if not me.AbilityReady(abilityName)() then return false end

    if not humanizeAbilityGate({ kind = 'melee', name = abilityName }) then return false end

    mq.cmdf('/doability "%s"', abilityName)
    M.markChannelUsed('melee')
    return true
end

--- Execute Taunt specifically (commonly used)
-- @return boolean True if executed
function M.executeTaunt()
    return M.executeMeleeAbility('Taunt')
end

--- Execute Kick
-- @return boolean True if executed
function M.executeKick()
    return M.executeMeleeAbility('Kick')
end

-- Coordinated Action Lifecycle

local TERMINAL = {
    [M.PHASE.COMPLETED] = true,
    [M.PHASE.FAILED] = true,
    [M.PHASE.CANCELLED] = true,
}

local function nowMs()
    return mq.gettime and mq.gettime() or math.floor(os.clock() * 1000)
end

local function actualCastBusy()
    return SkLib.isCasting and SkLib.isCasting() or false
end

local function normalizeKind(kind)
    kind = tostring(kind or ''):lower()
    local aliases = {
        spell = 'cast_spell',
        aa = 'use_aa',
        alt = 'use_aa',
        disc = 'use_disc',
        discipline = 'use_disc',
        item = 'use_item',
        skill = 'use_skill',
        melee = 'use_skill',
    }
    return aliases[kind] or kind
end

local function publicStatus(job)
    if not job then return nil end
    local action = job.action or {}
    return {
        id = job.id,
        phase = job.phase,
        active = not TERMINAL[job.phase],
        kind = job.kind,
        name = tostring(action.spellName or action.name or action.itemName or action.discName or ''),
        targetId = tonumber(action.targetId) or 0,
        submittedAtMs = job.submittedAtMs,
        phaseAtMs = job.phaseAtMs,
        startedAtMs = job.startedAtMs,
        finishedAtMs = job.finishedAtMs,
        elapsedMs = math.max(0, (job.finishedAtMs or nowMs()) - (job.submittedAtMs or nowMs())),
        reason = job.reason,
        claimId = action.claimId,
        idempotencyKey = action.idempotencyKey,
    }
end

local function callHandler(job, name, ...)
    local handler = job and job.handlers and job.handlers[name]
    if type(handler) ~= 'function' then return true, nil end
    local ok, a, b, c = pcall(handler, job.action, job.context, job, ...)
    if not ok then return false, 'handler_error:' .. tostring(a) end
    return a, b, c
end

local function setPhase(job, phase, reason)
    job.phase = phase
    job.phaseAtMs = nowMs()
    if reason ~= nil then job.reason = tostring(reason) end
end

local function finish(job, phase, reason)
    if not job or TERMINAL[job.phase] then return end
    setPhase(job, phase, reason)
    job.finishedAtMs = nowMs()
    _lastResult = publicStatus(job)
    if phase == M.PHASE.COMPLETED then
        callHandler(job, 'onComplete', _lastResult)
    elseif phase == M.PHASE.CANCELLED then
        callHandler(job, 'onCancel', _lastResult)
    else
        callHandler(job, 'onFailure', _lastResult)
    end
end

local function getSpellEngine(initialize)
    local ok, engine = pcall(require, 'sidekick-next.utils.spell_engine')
    if not ok or not engine then return nil end
    if initialize and engine.init and engine.isInitialized and not engine.isInitialized() then
        local initOk = pcall(engine.init)
        if not initOk then return nil end
    end
    return engine
end

local function spellEngineBusy()
    local engine = getSpellEngine(false)
    return engine and engine.isBusy and engine.isBusy() == true or false
end

local function tickSpellEngine()
    local engine = getSpellEngine(false)
    if engine and engine.tick then pcall(engine.tick) end
end

local function abortSpellEngine()
    local engine = getSpellEngine(false)
    if engine and engine.abort then pcall(engine.abort) end
end

local function executeAAReference(reference)
    if reference == nil or tostring(reference) == '' then return false, 'no_aa' end
    if not M.isChannelReady('aa_disc') then return false, 'channel_not_ready' end
    local me = mq.TLO.Me
    if not (me and me()) then return false, 'no_character' end
    local ok, ready = pcall(function() return me.AltAbilityReady(reference)() == true end)
    if not ok or not ready then return false, 'aa_not_ready' end
    if not humanizeAbilityGate({ kind = 'aa', name = reference }) then return false, 'humanize_skip' end
    local numeric = tonumber(reference)
    if numeric then
        mq.cmdf('/alt activate %d', numeric)
    else
        mq.cmdf('/alt activate "%s"', tostring(reference))
    end
    M.markChannelUsed('aa_disc')
    return true
end

local function defaultDispatch(job)
    local action = job.action or {}
    local kind = job.kind
    if kind == 'cast_spell' then
        local engine = getSpellEngine(true)
        if not engine then return false, 'no_spell_engine' end
        local spellName = action.spellName or action.name
        local targetId = action.castTargetId
        if targetId == nil then targetId = action.targetId end
        local opts = action.castOptions or action.options or {}
        if opts.spellCategory == nil then opts.spellCategory = action.spellCategory or action.category end
        if opts.priority == nil then opts.priority = action.priority end
        local ok, reason = M.executeSpell(spellName, tonumber(targetId), opts)
        return ok, reason, 'spell_engine'
    elseif kind == 'use_aa' then
        local reference = action.aaId or action.altID or action.altId or action.name
        local ok, reason = executeAAReference(reference)
        return ok, reason, 'cast_or_settle'
    elseif kind == 'use_disc' then
        local ok = M.executeDisc(action.discName or action.name)
        return ok, ok and nil or 'disc_not_ready', 'settle'
    elseif kind == 'use_item' then
        local ok = action.slotName and M.executeItemSlot(action.slotName)
            or M.executeItem(action.itemName or action.name)
        return ok, ok and nil or 'item_not_ready', 'cast_or_settle'
    elseif kind == 'use_skill' then
        local ok = M.executeMeleeAbility(action.abilityName or action.name)
        return ok, ok and nil or 'skill_not_ready', 'settle'
    end
    return false, 'unsupported_kind:' .. tostring(kind)
end

--- Submit one action after the coordinator has granted its claim.
--- No command is issued until tick() runs in the worker's yieldable loop.
function M.submit(action, opts)
    if type(action) ~= 'table' then return false, 'action_required' end
    if _job and not TERMINAL[_job.phase] then return false, 'executor_busy' end

    local kind = normalizeKind(action.kind)
    if kind == '' then return false, 'action_kind_required' end
    _jobCounter = _jobCounter + 1
    local now = nowMs()
    _job = {
        id = string.format('action_%d_%d', now, _jobCounter),
        action = action,
        kind = kind,
        phase = M.PHASE.QUEUED,
        phaseAtMs = now,
        submittedAtMs = now,
        startedAtMs = nil,
        finishedAtMs = nil,
        startDeadlineMs = now + math.max(100, tonumber(action.castStartTimeoutMs) or 1500),
        deadlineMs = now + math.max(500, tonumber(action.timeoutMs) or 20000),
        settleMs = math.max(25, tonumber(action.settleMs) or 150),
        handlers = opts and opts.handlers or nil,
        context = opts and opts.context or nil,
        reason = 'accepted',
        monitor = nil,
        observedCast = false,
    }
    _lastResult = nil
    return true, _job.id
end

--- Advance the current action without blocking. Actor callbacks must never
--- call this; ModuleBase invokes it from each worker's main coroutine.
function M.tick(context)
    local job = _job
    if not job or TERMINAL[job.phase] then return publicStatus(job) end
    local now = nowMs()

    tickSpellEngine()

    if job.cancelRequestedReason and not actualCastBusy()
        and not (job.monitor == 'spell_engine' and spellEngineBusy()) then
        finish(job, M.PHASE.CANCELLED, job.cancelRequestedReason)
        return publicStatus(job)
    end

    local incapacitated, incapReason = SkLib.isIncapacitated()
    if incapacitated then
        abortSpellEngine()
        finish(job, M.PHASE.CANCELLED, 'incapacitated:' .. tostring(incapReason or 'unknown'))
        return publicStatus(job)
    end

    local owns = true
    if context and type(context.ownsAction) == 'function' then
        local ok, value = pcall(context.ownsAction)
        owns = ok and value == true
    end
    if not owns then
        local stillRunning = actualCastBusy()
            or (job.monitor == 'spell_engine' and spellEngineBusy())
        if job.phase == M.PHASE.RUNNING and job.observedCast and not stillRunning then
            -- A natural completion retains cast ownership until this executor
            -- releases it. If ownership disappeared first, the coordinator
            -- preempted/revoked the action and module completion hooks must not
            -- record it as landed.
            finish(job, M.PHASE.CANCELLED,
                job.cancelRequestedReason or 'ownership_lost_after_cast')
            return publicStatus(job)
        elseif not (job.phase == M.PHASE.RUNNING and stillRunning) then
            abortSpellEngine()
            finish(job, M.PHASE.CANCELLED, 'ownership_lost')
            return publicStatus(job)
        end
    end

    if now >= job.deadlineMs then
        abortSpellEngine()
        finish(job, M.PHASE.FAILED, 'action_timeout')
        return publicStatus(job)
    end

    if job.phase == M.PHASE.QUEUED then
        -- Custom spell dispatchers (CC/cures/buffs/rez) still rely on the
        -- shared spell events. Initialize them here before any handler can
        -- issue a cast command.
        if job.kind == 'cast_spell' and not getSpellEngine(true) then
            finish(job, M.PHASE.FAILED, 'no_spell_engine')
            return publicStatus(job)
        end
        local ok, reason = callHandler(job, 'preflight')
        if ok == false then
            finish(job, M.PHASE.FAILED, reason or 'preflight_failed')
            return publicStatus(job)
        end

        setPhase(job, M.PHASE.DISPATCHING, 'dispatching')
        local dispatched, dispatchReason, monitor
        if job.handlers and type(job.handlers.dispatch) == 'function' then
            dispatched, dispatchReason, monitor = callHandler(job, 'dispatch')
        else
            local dispatchOk, result, reason, resultMonitor = pcall(defaultDispatch, job)
            if dispatchOk then
                dispatched, dispatchReason, monitor = result, reason, resultMonitor
            else
                abortSpellEngine()
                dispatched, dispatchReason = false, 'dispatch_error:' .. tostring(result)
            end
        end
        if dispatched ~= true then
            finish(job, M.PHASE.FAILED, dispatchReason or 'dispatch_failed')
            return publicStatus(job)
        end
        -- Monitor modes: 'none' (complete immediately), 'custom' (handler
        -- onTick drives phases), 'settle' / 'cast_or_settle' (complete after
        -- settleMs; the latter treats an observed cast as the completion
        -- signal instead), 'spell_engine' (track the spell_engine job), and
        -- 'cast' (raw /cast issued outside spell_engine: wait for the cast bar
        -- until startDeadlineMs, complete when it finishes).
        job.monitor = type(monitor) == 'string' and monitor
            or (type(monitor) == 'table' and monitor.monitor)
            or (job.kind == 'cast_spell' and 'spell_engine' or 'settle')
        if job.monitor == 'none' then
            finish(job, M.PHASE.COMPLETED, dispatchReason or 'completed')
        else
            setPhase(job, M.PHASE.WAITING_START, dispatchReason or 'command_issued')
        end
        return publicStatus(job)
    end

    local hookOk, hookReason, hookState = callHandler(job, 'onTick', job.phase)
    if hookOk == false then
        abortSpellEngine()
        finish(job, M.PHASE.FAILED, hookReason or 'monitor_failed')
        return publicStatus(job)
    end
    if hookState == 'completed' then
        finish(job, M.PHASE.COMPLETED, hookReason or 'completed')
        return publicStatus(job)
    elseif hookState == 'failed' then
        abortSpellEngine()
        finish(job, M.PHASE.FAILED, hookReason or 'monitor_failed')
        return publicStatus(job)
    elseif hookState == 'cancelled' then
        abortSpellEngine()
        finish(job, M.PHASE.CANCELLED, hookReason or 'cancelled')
        return publicStatus(job)
    elseif hookState == 'interrupting' then
        job.cancelRequestedReason = tostring(hookReason or 'interrupt_requested')
        return publicStatus(job)
    end

    local castBusy = actualCastBusy()
    local engineBusy = job.monitor == 'spell_engine' and spellEngineBusy()
    if castBusy then
        job.observedCast = true
        if not job.startedAtMs then job.startedAtMs = now end
        if job.phase ~= M.PHASE.RUNNING then setPhase(job, M.PHASE.RUNNING, 'cast_started') end
        return publicStatus(job)
    end

    if job.phase == M.PHASE.RUNNING then
        if job.monitor == 'custom' then
            return publicStatus(job)
        elseif not engineBusy then
            finish(job, job.cancelRequestedReason and M.PHASE.CANCELLED or M.PHASE.COMPLETED,
                job.cancelRequestedReason or 'completed')
        end
        return publicStatus(job)
    end

    local phaseAge = now - job.phaseAtMs
    if job.monitor == 'settle' and phaseAge >= job.settleMs then
        finish(job, M.PHASE.COMPLETED, 'completed')
    elseif job.monitor == 'cast_or_settle' and phaseAge >= job.settleMs then
        finish(job, M.PHASE.COMPLETED, 'completed_instant')
    elseif job.monitor == 'spell_engine' and not engineBusy and phaseAge >= job.settleMs then
        finish(job, M.PHASE.FAILED, 'cast_did_not_start')
    elseif job.monitor == 'cast' and now >= job.startDeadlineMs then
        finish(job, M.PHASE.FAILED, 'cast_start_timeout')
    elseif job.monitor ~= 'custom' and now >= job.startDeadlineMs then
        abortSpellEngine()
        finish(job, M.PHASE.FAILED, 'cast_start_timeout')
    end
    return publicStatus(job)
end

function M.cancel(reason)
    if not _job or TERMINAL[_job.phase] then return false end
    abortSpellEngine()
    finish(_job, M.PHASE.CANCELLED, reason or 'cancelled')
    return true
end

function M.hasActiveJob()
    return _job ~= nil and not TERMINAL[_job.phase]
end

function M.hasJob()
    return _job ~= nil
end

function M.getStatus()
    return publicStatus(_job) or _lastResult
end

--- Rebase active lifecycle timers after the host Lua coroutine was suspended.
--- No action work occurred during the gap, so wall-clock deadline expiry would
--- be a false timeout on the first resumed frame.
function M.rebaseTimers(gapMs)
    gapMs = math.max(0, tonumber(gapMs) or 0)
    if gapMs <= 0 or not _job or TERMINAL[_job.phase] then return false end
    for _, field in ipairs({
        'submittedAtMs', 'phaseAtMs', 'startedAtMs', 'startDeadlineMs', 'deadlineMs',
    }) do
        if tonumber(_job[field]) then _job[field] = _job[field] + gapMs end
    end
    return true
end

function M.consumeResult()
    if not _job or not TERMINAL[_job.phase] then return nil end
    local result = publicStatus(_job)
    _lastResult = result
    _job = nil
    return result
end

return M
