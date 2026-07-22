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

local module = ModuleBase.create('cc', lib.Priority.DEBUFF)
local _pendingAction = nil
local _pendingReason = 'init'
local _lastCharmReason = '-'
local _lastMezReason = '-'
local _lastDispatch = '-'

Core.load()
CC.init()

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

local _lastInterruptReqAt = 0

module.onTick = function(self)
    -- The runtime cache is per-process and nothing else ticks it here —
    -- without this, Cache.xtarget.haters stays empty forever and every
    -- mez/charm selection returns no_target.
    Cache.tick()
    CC.tick()
    CC.charmTick(settings())
    mq.doevents()
    local action, priority, reason = computePending()
    if action then
        _pendingAction = action
        self.priority = priority
    elseif reason ~= 'throttled' then
        _pendingAction = nil
        self.priority = lib.Priority.DEBUFF
    end
    _pendingReason = reason

    -- CC outranks DPS casting: with a mez or charm-break pending while some
    -- other module's cast is in flight (our own nukes included), ask the
    -- coordinator to interrupt. The DEBUFF InterruptThreshold (1s) lets a
    -- nearly-finished cast land; without this the cast owner's claim is
    -- undisplacable and the mez waits out every nuke.
    -- currentClaimId guard: once OUR claim is granted the in-flight cast is
    -- (or is about to be) our own — ownsCast() lags the state broadcast, and
    -- an interrupt request from the cast owner is treated as a self-cancel:
    -- without this guard we stopcast our own mez in a loop.
    if _pendingAction and self.priority <= lib.Priority.DEBUFF
        and not self.currentClaimId
        and lib.isCasting() and not self:ownsCast() then
        local nowMs = lib.getTimeMs()
        if (nowMs - _lastInterruptReqAt) >= 1000 then
            _lastInterruptReqAt = nowMs
            self:requestInterrupt('cc_pending')
        end
    end

    self:sendNeed(_pendingAction ~= nil, _pendingAction and 750 or nil,
        _pendingReason or 'no_cc_needed')
end

module.shouldAct = function()
    return _pendingAction ~= nil
end

module.getAction = function()
    local action = _pendingAction
    if not action then return nil end
    return {
        type = lib.ClaimType.ACTION,
        kind = lib.ActionKind.CAST_SPELL,
        name = action.spellName,
        spellName = action.spellName,
        castStartTimeoutMs = 4000,
        targetId = action.targetId,
        targetName = action.targetName,
        charmStep = action.charmStep,
        reason = action.reason or 'mez',
        idempotencyKey = string.format('cc:%s:%d:%s',
            tostring(action.reason or 'mez'),
            tonumber(action.targetId) or 0, tostring(action.spellName or '')),
    }
end

local function dispatchAction(action)
    local reasonTag = tostring(action.reason or 'mez')
    local success, reason
    if reasonTag:find('charm', 1, true) then
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
    return success, reason
end

module.executeAction = function(self)
    if not self:ownsAction() then return false, 'no_ownership' end
    local owner = self.state and self.state.castOwner
    local action = owner and owner.action or nil
    if not action then return true, 'no_action' end

    local success, reason = dispatchAction(action)
    if not success then return true, reason or 'cast_failed' end

    local engine = spellEngine()
    local deadline = lib.getTimeMs() + 15000
    repeat
        mq.delay(25)
        if engine and engine.tick then engine.tick() end
        mq.doevents()
        if not self:ownsClaim() then return true, 'ownership_lost' end
    until (not lib.isCasting() and not (engine and engine.isBusy and engine.isBusy()))
        or lib.getTimeMs() >= deadline

    if lib.getTimeMs() >= deadline then return true, 'cast_timeout' end
    return true, 'completed'
end


module:enableUnifiedExecutor({
    dispatch = function(action, _, job)
        local success, reason = dispatchAction(action)
        if success then return true, reason, 'spell_engine' end
        if reason == 'already_casting' or reason == 'spell_engine_busy' then
            -- A cast (often an OOC buff) is still on the bar when our claim
            -- lands. Hold the claim and wait it out — the cc_pending
            -- interrupt request in onTick clears long casts — instead of
            -- failing and rejoining the claim queue behind everyone else.
            job.cc = { deadline = lib.getTimeMs() + 8000 }
            return true, 'waiting_cast_bar', 'custom'
        end
        return false, reason, 'spell_engine'
    end,
    onTick = function(action, self, job)
        local st = job.cc
        if not st then return true, 'no_wait_state', 'failed' end
        if lib.getTimeMs() > st.deadline then
            return true, 'cast_bar_timeout', 'failed'
        end
        local engine = spellEngine()
        if engine and engine.tick then engine.tick() end
        if st.castStarted then
            -- Our cast was issued; ride it to completion.
            if not lib.isCasting() and not (engine and engine.isBusy and engine.isBusy()) then
                return true, 'completed', 'completed'
            end
            return true, 'casting'
        end
        -- We hold the cast resource but a leftover cast (usually an orphaned
        -- OOC buff) still occupies the bar. As the cast owner, our interrupt
        -- request is an owner self-cancel — the coordinator /stopcasts it.
        if not st.interruptSent and lib.isCasting() then
            st.interruptSent = true
            self:requestInterrupt('cc_clearing_bar')
        end
        local success, reason = dispatchAction(action)
        if success then
            st.castStarted = true
            st.deadline = lib.getTimeMs() + 15000
            return true, 'casting'
        end
        if reason ~= 'already_casting' and reason ~= 'spell_engine_busy' then
            return true, reason, 'failed'
        end
        return true, 'waiting_cast_bar'
    end,
    onFailure = function(action)
        if action and action.targetId then CC.releaseClaim(tonumber(action.targetId) or 0) end
    end,
    onCancel = function(action)
        if action and action.targetId then CC.releaseClaim(tonumber(action.targetId) or 0) end
    end,
})

mq.bind('/sk_cc', function()
    local s = settings()
    local function echo(fmt, ...)
        print(string.format('\at[SK CC]\ax ' .. fmt, ...))
    end
    local charm = CC.charm or {}
    local steps = charm.breakSteps and table.concat(charm.breakSteps, '>') or '-'
    local localCount, remoteCount, totalCount = CC.getCounts()
    echo('mez=%s charm=%s pending=%s reason=%s priority=%s',
        tostring(s.MezzingEnabled == true), tostring(s.CharmEnabled == true),
        tostring(_pendingAction and (_pendingAction.reason or _pendingAction.spellName) or '-'),
        tostring(_pendingReason), tostring(module.priority))
    echo('pet=%d(%s) breakSteps=%s pendingCharm=%d attempts=%s mezReason=%s charmReason=%s',
        tonumber(charm.petId) or 0, tostring(charm.petName or ''),
        steps, tonumber(charm.pendingCharmTargetId) or 0,
        tostring(charm.petId and charm.attempts and charm.attempts[charm.petId] or 0),
        tostring(_lastMezReason), tostring(_lastCharmReason))
    local haterCount = 0
    for _ in pairs(Cache.xtarget.haters or {}) do haterCount = haterCount + 1 end
    echo('mezzes local=%d remote=%d total=%d haters=%d claimHeld=%s claimPending=%s lastDispatch=%s',
        tonumber(localCount) or 0, tonumber(remoteCount) or 0, tonumber(totalCount) or 0,
        haterCount, tostring(module.currentClaimId or '-'), tostring(module.claimPending or '-'),
        tostring(_lastDispatch))
end)

module:enablePeerActors()
module:run(50)

return module
