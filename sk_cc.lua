-- Coordinator-owned crowd-control worker.
-- Selection is side-effect free; all targeting/casting begins only after the
-- central coordinator grants exclusive cast ownership.

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local Core = require('sidekick-next.utils.core')
local CC = require('sidekick-next.automation.cc')

local module = ModuleBase.create('cc', lib.Priority.DEBUFF)
local _pendingAction = nil
local _pendingReason = 'init'

Core.load()
CC.init()

local function settings()
    return Core.Settings or {}
end

local function spellEngine()
    local ok, engine = pcall(require, 'sidekick-next.utils.spell_engine')
    return ok and engine or nil
end

module.onTick = function(self)
    CC.tick()
    mq.doevents()
    local action, reason = CC.selectMezAction(settings())
    if action then
        _pendingAction = action
    elseif reason ~= 'throttled' then
        _pendingAction = nil
    end
    _pendingReason = reason
    self:sendNeed(_pendingAction ~= nil, _pendingAction and 750 or nil,
        _pendingReason or 'no_mez_needed')
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
        reason = action.reason or 'mez',
        idempotencyKey = string.format('cc:%d:%s',
            tonumber(action.targetId) or 0, tostring(action.spellName or '')),
    }
end

module.executeAction = function(self)
    if not self:ownsAction() then return false, 'no_ownership' end
    local owner = self.state and self.state.castOwner
    local action = owner and owner.action or nil
    if not action then return true, 'no_action' end

    local success, reason = CC.castMez(
        tonumber(action.targetId) or 0,
        tostring(action.targetName or ''),
        tostring(action.spellName or action.name or ''))
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
    dispatch = function(action)
        local success, reason = CC.castMez(
            tonumber(action.targetId) or 0,
            tostring(action.targetName or ''),
            tostring(action.spellName or action.name or ''))
        return success, reason, 'spell_engine'
    end,
    onFailure = function(action)
        if action and action.targetId then CC.releaseClaim(tonumber(action.targetId) or 0) end
    end,
    onCancel = function(action)
        if action and action.targetId then CC.releaseClaim(tonumber(action.targetId) or 0) end
    end,
})

module:enablePeerActors()
module:run(50)

return module
