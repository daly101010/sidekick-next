-- Coordinator-owned cure worker.

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local Core = require('sidekick-next.utils.core')
local Cures = require('sidekick-next.automation.cures')

local module = ModuleBase.create('cures', lib.Priority.HEALING)
local _pendingAction = nil
local _pendingReason = 'init'

Core.load()
Cures.init()

local function spellEngine()
    local ok, engine = pcall(require, 'sidekick-next.utils.spell_engine')
    return ok and engine or nil
end

module.onTick = function(self)
    mq.doevents()
    local action, reason = Cures.selectCureAction(Core.Settings or {})
    if action then
        _pendingAction = action
    elseif reason ~= 'throttled' then
        _pendingAction = nil
    end
    _pendingReason = reason
    self:setIntent(_pendingAction ~= nil, _pendingAction and 750 or nil,
        _pendingReason or 'no_cure_needed')
end

module.shouldAct = function()
    return _pendingAction ~= nil
end

module.getAction = function()
    local action = _pendingAction
    if not action then return nil end
    return {
        kind = lib.ActionKind.CAST_SPELL,
        name = action.cureSpell,
        spellName = action.cureSpell,
        castStartTimeoutMs = 4000,
        targetId = action.targetId,
        debuffType = action.debuffType,
        reason = string.format('cure:%s', tostring(action.debuffType or 'unknown')),
        idempotencyKey = string.format('cure:%d:%s',
            tonumber(action.targetId) or 0, tostring(action.debuffType or '')),
    }
end

module.executeAction = function(self)
    if not self:ownsLease() then return false, 'no_ownership' end
    local action = self:getLeaseAction()
    if not action then return true, 'no_action' end

    local success, reason = Cures.castCure(
        tonumber(action.targetId) or 0,
        tostring(action.debuffType or ''),
        tostring(action.spellName or action.name or ''))
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
    local confirmed = Cures.confirmCureEffect
        and Cures.confirmCureEffect(action.targetId, action.debuffType, action.spellName)
    return true, confirmed and 'effect_confirmed' or 'effect_unconfirmed'
end


-- The legacy callback above is retained only as migration reference and must
-- never be selected by ModuleBase.
module.executeAction = nil
module:enableUnifiedExecutor({
    dispatch = function(action)
        local success, reason = Cures.castCure(
            tonumber(action.targetId) or 0,
            tostring(action.debuffType or ''),
            tostring(action.spellName or action.name or ''))
        return success, reason, 'spell_engine'
    end,
    onComplete = function(action)
        local confirmed = Cures.confirmCureEffect
            and Cures.confirmCureEffect(action.targetId, action.debuffType, action.spellName)
        action.effectConfirmed = confirmed == true
    end,
    onFailure = function(action)
        if Cures.cancelCureAttempt then
            Cures.cancelCureAttempt(action.targetId, action.debuffType)
        end
    end,
    onCancel = function(action)
        if Cures.cancelCureAttempt then
            Cures.cancelCureAttempt(action.targetId, action.debuffType)
        end
    end,
})

module:enablePeerActors()
module:run(50)

return module
