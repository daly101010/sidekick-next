-- Coordinator-owned crowd-control worker (mez + charm).
-- Selection is side-effect free; all targeting/casting begins only after the
-- central coordinator grants exclusive cast ownership.
--
-- Action arbitration each tick, most to least urgent:
--   1. charm break recovery (tash -> AE stun -> recharm) — a loose ex-pet
--      is eating the enchanter
--   2. charm acquisition (pretash -> charm) — the pet comes FIRST on an
--      incoming pull: charming removes a mob from the fight AND adds DPS,
--      so it beats spending those casts on mez
--   3. mez the rest
-- All at DEBUFF tier: sequencing between them is decided HERE, and every
-- CC action outranks DPS casting for the bar.

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local Core = require('sidekick-next.utils.core')
local CC = require('sidekick-next.automation.cc')
local Cache = require('sidekick-next.utils.runtime_cache')
local Counters = require('sidekick-next.utils.action_counters')
local Logger = require('sidekick-next.utils.logger')

local module = ModuleBase.create('cc', lib.Priority.DEBUFF)
local _pendingAction = nil
local _pendingReason = 'init'
local _lastCharmReason = '-'
local _lastMezReason = '-'
local _lastDispatch = '-'

-- Decision trace (/sk_cc debug): change-gated one-liners for every CC
-- decision transition. Off by default — combat spam otherwise.
local _debug = false
local _lastTraceLine = ''
local decisionLog = Logger.new('cc')
local function trace(fmt, ...)
    local persistedDebug = decisionLog.isLevel('debug')
    if not _debug and not persistedDebug then return end
    local line = string.format(fmt, ...)
    if line == _lastTraceLine then return end
    _lastTraceLine = line
    if persistedDebug then
        decisionLog.debug('%s @%.1fs', line, os.clock() % 1000)
    else
        print(string.format('\am[CC-Trace]\ax %s @%.1fs', line, os.clock() % 1000))
    end
end

Core.load()
CC.init()
CC.trace = trace

-- Mob intelligence must observe the SpellEngine that actually casts mez/charm.
-- Only mez-capable characters own this process-local observer in coordinated
-- mode; the UI host remains presentation-only.
local _mobIntel = nil
if CC.isMezClass() then
    local ok, mod = pcall(require, 'sidekick-next.utils.mob_intel')
    if ok and mod then
        _mobIntel = mod
        if mod.init then
            local initOk = pcall(mod.init)
            if not initOk then _mobIntel = nil end
        end
    end
end

local function settings()
    return Core.Settings or {}
end

local function spellEngine()
    local ok, engine = pcall(require, 'sidekick-next.utils.spell_engine')
    return ok and engine or nil
end

local function computePending()
    local s = settings()
    local charmAction, charmReason = CC.selectCharmAction(s)
    if charmReason and charmReason ~= 'throttled' then _lastCharmReason = charmReason end

    -- Charm first, break recovery or acquisition alike: the pet is both a
    -- removed enemy and added DPS, so its casts (pretash -> charm) go out
    -- before any mez. Mez picks up whatever is still loose right after.
    if charmAction then
        return charmAction, lib.Priority.DEBUFF, charmReason
    end

    local mezAction, mezReason = CC.selectMezAction(s)
    if mezReason and mezReason ~= 'throttled' then _lastMezReason = mezReason end
    if mezAction then
        return mezAction, lib.Priority.DEBUFF, mezReason
    end

    if mezReason == 'throttled' or charmReason == 'throttled' then
        return nil, lib.Priority.DEBUFF, 'throttled'
    end
    return nil, lib.Priority.DEBUFF, mezReason or charmReason or 'no_cc_needed'
end

module.onTick = function(self)
    -- The runtime cache is per-process and nothing else ticks it here —
    -- without this, Cache.xtarget.haters stays empty forever and every
    -- mez/charm selection returns no_target.
    Cache.tick()
    CC.tick()
    local petAction = CC.charmTick(settings())
    -- Drain the process-local spell engine whenever it's mid-state: once an
    -- executor job ends, nothing else ticks it, and a post-cast state that
    -- never advances leaves isBusy() true forever — selection then starves
    -- on spell_engine_busy and DPS holds the bar by forfeit.
    if _mobIntel then
        if _mobIntel.loadZone then pcall(_mobIntel.loadZone) end
        if _mobIntel.tick then pcall(_mobIntel.tick) end
    end
    mq.doevents()
    local action, _, reason
    local eng = spellEngine()
    if not self.currentRequestId and eng and eng.isBusy and eng.isBusy() then
        action = {
            kind = 'cc_engine_recovery',
            reason = 'orphan_spell_engine',
            targetId = 0,
            targetName = '',
        }
        reason = action.reason
    else
        action, _, reason = computePending()
    end
    if petAction and (petAction.petCommand == 'backoff' or not action) then
        action = petAction
        reason = petAction.reason
    end
    if action then
        trace('decide: %s spell=%s target=%s(%d) step=%s',
            tostring(action.reason or reason), tostring(action.spellName or '?'),
            tostring(action.targetName or '?'), tonumber(action.targetId) or 0,
            tostring(action.charmStep or '-'))
    else
        trace('idle: mez=%s charm=%s', tostring(_lastMezReason), tostring(_lastCharmReason))
    end
    if action then
        _pendingAction = action
    elseif reason ~= 'throttled' then
        _pendingAction = nil
    end
    _pendingReason = reason

    -- The coordinator alone decides whether this fixed-tier CC request is
    -- urgent enough to revoke the current lease. This worker advertises only
    -- local intent and never issues cross-worker interrupts.
    self:setIntent(_pendingAction ~= nil, _pendingAction and 750 or nil,
        _pendingReason or 'no_cc_needed')
end

module.shouldAct = function()
    return _pendingAction ~= nil
end

module.getAction = function()
    local action = _pendingAction
    if not action then return nil end
    return {
        kind = action.kind == 'cc_engine_recovery'
            and 'cc_engine_recovery'
            or (action.kind == 'pet_command'
                and 'pet_command' or lib.ActionKind.CAST_SPELL),
        name = action.spellName,
        spellName = action.spellName,
        castStartTimeoutMs = 4000,
        targetId = action.targetId,
        targetName = action.targetName,
        charmStep = action.charmStep,
        petCommand = action.petCommand,
        skipBoundaryTarget = action.kind == 'cc_engine_recovery',
        breaksInvis = action.kind ~= 'cc_engine_recovery',
        reason = action.reason or 'mez',
        idempotencyKey = string.format('cc:%s:%d:%s',
            tostring(action.reason or 'mez'),
            tonumber(action.targetId) or 0, tostring(action.spellName or '')),
    }
end

local function dispatchAction(action)
    local reasonTag = tostring(action.reason or 'mez')
    local success, reason
    if action.kind == 'pet_command' or action.petCommand then
        success, reason = CC.executePetCommand(action)
    elseif reasonTag:find('charm', 1, true) then
        success, reason = CC.castCharmAction({
            targetId = action.targetId,
            targetName = action.targetName,
            spellName = action.spellName or action.name,
            charmStep = action.charmStep,
            reason = reasonTag,
        })
        if success then Counters.bump(reasonTag) end
    else
        success, reason = CC.castMez(
            tonumber(action.targetId) or 0,
            tostring(action.targetName or ''),
            tostring(action.spellName or action.name or ''))
        if success then Counters.bump('mez_cast') end
    end
    _lastDispatch = string.format('%s=%s%s', reasonTag,
        success and 'ok' or 'FAIL', success and '' or (':' .. tostring(reason)))
    trace('dispatch: %s', _lastDispatch)
    return success, reason
end

module.executeAction = function(self)
    if not self:ownsLease() then return false, 'no_ownership' end
    local action = self:getLeaseAction()
    if not action then return true, 'no_action' end

    local success, reason = dispatchAction(action)
    if not success then return true, reason or 'cast_failed' end

    local engine = spellEngine()
    local deadline = lib.getTimeMs() + 15000
    repeat
        mq.delay(25)
        if engine and engine.tick then engine.tick() end
        mq.doevents()
        self:renewLease()
        if not self:ownsLease() then return true, 'ownership_lost' end
    until (not lib.isCasting() and not (engine and engine.isBusy and engine.isBusy()))
        or lib.getTimeMs() >= deadline

    if lib.getTimeMs() >= deadline then return true, 'cast_timeout' end
    return true, 'completed'
end


module:enableUnifiedExecutor({
    dispatch = function(action)
        if action.kind == 'cc_engine_recovery' then
            local engine = spellEngine()
            if engine and engine.abort then engine.abort() end
            return true, 'engine_recovered', 'none'
        end
        local success, reason = dispatchAction(action)
        if success then
            return true, reason,
                (action.kind == 'pet_command' or action.petCommand) and 'none' or 'spell_engine'
        end
        if reason == 'already_casting' or reason == 'spell_engine_busy' then
            -- A cast (often an OOC buff) is still on the bar when our claim
            -- lands. Hold the claim and wait it out — the cc_pending
            -- interrupt request in onTick clears long casts — instead of
            -- failing and rejoining the claim queue behind everyone else.
            return false, 'external_cast_active', 'spell_engine'
        end
        return false, reason, 'spell_engine'
    end,
    onTick = function(action, self, job)
        local st = job.cc
        -- No wait state means dispatch succeeded first-try and the job is
        -- monitored by the spell engine — bare `true` lets the executor's
        -- normal monitor ride the cast. Returning 'failed' here (the old
        -- behavior) aborted our OWN cast ~0.3s after every clean dispatch;
        -- it went unnoticed while the bar was always blocked pre-claim-fix.
        if not st then return true end
        if lib.getTimeMs() > st.deadline then
            return true, 'cast_bar_timeout', 'failed'
        end
        local engine = spellEngine()
        if engine and engine.tick then engine.tick() end
        if st.castStarted then
            -- Our cast was issued; ride it to completion.
            if not lib.isCasting() and not (engine and engine.isBusy and engine.isBusy()) then
                trace('cast-end: %s (bar clear, engine idle)', tostring(action.spellName or '?'))
                return true, 'completed', 'completed'
            end
            return true, 'casting'
        end
        -- We hold the cast resource but a leftover cast (usually an orphaned
        -- OOC buff) still occupies the bar. As the cast owner, our interrupt
        -- request is an owner self-cancel — the coordinator /stopcasts it.
        if not st.interruptSent and lib.isCasting() then
            return true, 'external_cast_active', 'failed'
        end
        local success, reason = dispatchAction(action)
        if success then
            st.castStarted = true
            st.deadline = lib.getTimeMs() + 15000
            trace('cast-start: %s on %s(%d)', tostring(action.spellName or '?'),
                tostring(action.targetName or '?'), tonumber(action.targetId) or 0)
            return true, 'casting'
        end
        if reason ~= 'already_casting' and reason ~= 'spell_engine_busy' then
            trace('cast-abort: %s (%s)', tostring(action.spellName or '?'), tostring(reason))
            return true, reason, 'failed'
        end
        return true, 'waiting_cast_bar'
    end,
    onFailure = function(action, _, _, result)
        trace('action-failed: %s target=%d why=%s (claim released)',
            tostring(action and action.reason or '?'), tonumber(action and action.targetId) or 0,
            tostring(result and result.reason or '?'))
        if action and action.targetId then CC.releaseClaim(tonumber(action.targetId) or 0) end
    end,
    onCancel = function(action)
        trace('action-cancelled: %s target=%d (ownership lost/superseded)',
            tostring(action and action.reason or '?'), tonumber(action and action.targetId) or 0)
        if action and action.targetId then CC.releaseClaim(tonumber(action.targetId) or 0) end
    end,
})

mq.bind('/sk_cc', function(cmd)
    if tostring(cmd or ''):lower() == 'debug' then
        _debug = not _debug
        CC.trace = trace
        print(string.format('\at[SK CC]\ax decision trace %s', _debug and 'ON' or 'OFF'))
        return
    end
    local s = settings()
    local function echo(fmt, ...)
        print(string.format('\at[SK CC]\ax ' .. fmt, ...))
    end
    local charm = CC.charm or {}
    local steps = charm.breakSteps and table.concat(charm.breakSteps, '>') or '-'
    local localCount, remoteCount, totalCount = CC.getCounts()
    local engState = '-'
    do
        local eng = spellEngine()
        if eng and eng.getState then
            local _, name = eng.getState()
            engState = tostring(name or '-')
        end
    end
    echo('mez=%s charm=%s pending=%s reason=%s priority=%s engine=%s',
        tostring(s.MezzingEnabled == true), tostring(s.CharmEnabled == true),
        tostring(_pendingAction and (_pendingAction.reason or _pendingAction.spellName) or '-'),
        tostring(_pendingReason), tostring(module.priority), engState)
    echo('pet=%d(%s) breakSteps=%s pendingCharm=%d attempts=%s mezReason=%s charmReason=%s',
        tonumber(charm.petId) or 0, tostring(charm.petName or ''),
        steps, tonumber(charm.pendingCharmTargetId) or 0,
        tostring(charm.petId and charm.attempts and charm.attempts[charm.petId] or 0),
        tostring(_lastMezReason), tostring(_lastCharmReason))
    local haterCount = 0
    for _ in pairs(Cache.xtarget.haters or {}) do haterCount = haterCount + 1 end
    echo('mezzes local=%d remote=%d total=%d haters=%d requestId=%s leasePending=%s lastDispatch=%s',
        tonumber(localCount) or 0, tonumber(remoteCount) or 0, tonumber(totalCount) or 0,
        haterCount, tostring(module.currentRequestId or '-'), tostring(module.requestPending or '-'),
        tostring(_lastDispatch))
end)

module:enablePeerActors()
module:run(50)
if _mobIntel and _mobIntel.shutdown then pcall(_mobIntel.shutdown) end

return module
