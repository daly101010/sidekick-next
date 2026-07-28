-- Leased automatic-stand worker for Monk and Necromancer feign death.
--
-- FeignSafety owns the read-only survival decision. This worker is the only
-- automatic path allowed to issue /stand, and it does so under the same
-- action-blind coordinator lease used by every other worker.

local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local FeignSafety = require('sidekick-next.utils.feign_safety')

local module = ModuleBase.create('feign', lib.Priority.MEDITATION)
local _pendingAction = nil
local _lastReason = 'init'

local function settings()
    return lib.getSettings() or {}
end

module.onTick = function(self)
    local current = settings()
    if not FeignSafety.isManagedFeign(current) then
        _pendingAction = nil
        _lastReason = 'not_managed_feign'
        self:setIntent(false, nil, _lastReason)
        return
    end

    local canStand, reason = FeignSafety.evaluate(current)
    _lastReason = tostring(reason or 'feign_hold')
    if not canStand then
        _pendingAction = nil
        self:setIntent(false, nil, _lastReason)
        return
    end

    _pendingAction = {
        kind = 'feign_stand',
        name = 'Safely stand from feign',
        skipBoundaryTarget = true,
        breaksInvis = false,
        settleMs = 250,
        timeoutMs = 1500,
        idempotencyKey = 'feign:stand',
        reason = _lastReason,
    }
    self:setIntent(true, nil, _lastReason)
end

module.shouldAct = function()
    return _pendingAction ~= nil
end

module.getAction = function()
    return _pendingAction
end

module:enableUnifiedExecutor({
    preflight = function()
        local current = settings()
        if not FeignSafety.isManagedFeign(current) then
            return false, 'feign_ended'
        end
        local canStand, reason = FeignSafety.evaluate(current)
        return canStand == true, tostring(reason or 'unsafe_to_stand')
    end,
    dispatch = function()
        local issued, reason = FeignSafety.performStand(settings())
        if not issued then return false, reason end
        _pendingAction = nil
        return true, reason or 'stand_issued', 'settle'
    end,
})

module.onLeaseFinalizing = function()
    _pendingAction = nil
    return true
end

module:run(50)

return module
