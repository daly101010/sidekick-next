-- Consolidates several mature worker scripts behind one coordinator identity.
-- Components keep their existing sensors, selectors, slash commands, and
-- executor handlers. Only this host requests and owns the action-blind lease.

local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local ActionExecutor = require('sidekick-next.utils.action_executor')
local RuntimeCache = require('sidekick-next.utils.runtime_cache')
local FeignSafety = require('sidekick-next.utils.feign_safety')

local M = {}

local function nowMs()
    return lib.getTimeMs()
end

local function loadComponent(name)
    local previous = _G.SK_COMPONENT_MODE
    _G.SK_COMPONENT_MODE = true
    local ok, result = pcall(require, 'sidekick-next.sk_' .. name)
    _G.SK_COMPONENT_MODE = previous
    if not ok then error('failed to load ' .. name .. ' component: ' .. tostring(result), 0) end
    if type(result) ~= 'table' then
        error('component ' .. name .. ' did not return its ModuleBase instance', 0)
    end
    result.componentName = name
    result.componentSuspended = result.componentDisabled == true
    result.componentIntent = { active = false, reason = 'init', updatedAtMs = 0 }
    return result
end

local function actionName(action)
    return tostring(action and (action.name or action.spellName
        or action.itemName or action.discName) or '')
end

local function makeAssistHandlers(component)
    return {
        dispatch = function()
            local terminal, reason = component.executeAction(component)
            if terminal == true then return true, reason or 'completed', 'none' end
            return true, reason or 'running', 'custom'
        end,
        onTick = function()
            local terminal, reason = component.executeAction(component)
            if terminal == true then return true, reason or 'completed', 'completed' end
            return true, reason or 'running'
        end,
    }
end

local function componentHandlers(component)
    if type(component.actionHandlers) == 'table'
        and next(component.actionHandlers) ~= nil then
        return component.actionHandlers
    end
    if type(component.executeAction) == 'function' then
        return makeAssistHandlers(component)
    end
    return {}
end

local function installComponentFacade(host, component)
    local original = {
        onTick = component.onTick,
        shouldAct = component.shouldAct,
        getAction = component.getAction,
        onSchedulerResume = component.onSchedulerResume,
        onRequestWithdrawn = component.onRequestWithdrawn,
        onLeaseFinalizing = component.onLeaseFinalizing,
        onSafetyDrain = component.onSafetyDrain,
        handlers = componentHandlers(component),
    }
    component._domainOriginal = original

    component.setIntent = function(self, active, _, reason)
        self.componentIntent.active = active == true
        self.componentIntent.reason = tostring(reason or (active and 'ready' or 'idle'))
        self.componentIntent.updatedAtMs = nowMs()
    end
    component.canRequestLease = function()
        return not component.componentSuspended and host:canRequestLease()
    end
    component.getLease = function()
        return host:getLease()
    end
    component.ownsLease = function()
        return host:ownsLease()
            and host.currentAction
            and host.currentAction.component == component.componentName
    end
    component.getLeaseAction = function()
        return component:ownsLease() and host:getLeaseAction() or nil
    end
    component.renewLease = function(_, force)
        return component:ownsLease() and host:renewLease(force) or false
    end
    component.markDirtyEffects = function(_, value, recoveryRequired)
        component.dirtyEffects = value == true
        if value == true then
            host.domainRecoveryComponent = component.componentName
            host:markDirtyEffects(true, recoveryRequired)
        elseif host.domainRecoveryComponent == component.componentName then
            host:markDirtyEffects(false)
            host.domainRecoveryComponent = nil
        end
    end
    component.finishAction = function(_, result)
        return component:ownsLease() and host:finishAction(result) or false
    end
    component.withdrawLeaseRequest = function(_, reason)
        return component:ownsLease() and host:withdrawLeaseRequest(reason) or false
    end
    component.cancelUnifiedAction = function(_, reason)
        return component:ownsLease() and host:cancelUnifiedAction(reason) or false
    end
    component.stop = function()
        component.componentSuspended = true
        component.running = false
        component.componentIntent.active = false
        if component:ownsLease() then
            host:cancelUnifiedAction('component_stopped')
            host:finishAction({ phase = 'cancelled', reason = 'component_stopped' })
        end
    end

    return original
end

local function syncComponent(host, component, active)
    component.state = host.state
    component.stateReceivedAt = host.stateReceivedAt
    component.coordinatorBootId = host.coordinatorBootId
    component.peerActors = host.peerActors
    component.settingsRevision = host.settingsRevision
    component.initialized = host.initialized
    component.warmupUntil = host.warmupUntil
    component.priority = host.priority
    if active then
        component.currentRequestId = host.currentRequestId
        component.currentAction = host.currentAction
        component.currentActionKey = host.currentActionKey
        component.requestPending = host.requestPending
        component.requestRequestedAt = host.requestRequestedAt
        component.requestLastSentAt = host.requestLastSentAt
        component.lastRequestSendOk = host.lastRequestSendOk
        component.lastRequestSendError = host.lastRequestSendError
        component.activeLeaseSnapshot = host.activeLeaseSnapshot
        component.dirtyEffects = host.dirtyEffects
        component.needsRecovery = host.needsRecovery
    else
        component.currentRequestId = nil
        component.currentAction = nil
        component.currentActionKey = nil
        component.requestPending = false
        component.activeLeaseSnapshot = nil
    end
end

local function callComponent(host, component, fn, ...)
    if type(fn) ~= 'function' then return true end
    local active = host.currentAction
        and host.currentAction.component == component.componentName
    syncComponent(host, component, active)
    return pcall(fn, component, ...)
end

local function routedHandler(host, name)
    return function(action, _, job, ...)
        local component = host.componentsByName[action and action.component or '']
        if not component then return false, 'component_missing' end
        syncComponent(host, component, true)
        local handler = component._domainOriginal.handlers[name]
        if type(handler) ~= 'function' then
            if name == 'dispatch' then
                return nil, ActionExecutor.USE_DEFAULT_DISPATCH
            end
            return true
        end
        return handler(action, component, job, ...)
    end
end

local function copyAction(action, componentName)
    local copy = {}
    for key, value in pairs(action or {}) do copy[key] = value end
    copy.component = componentName
    copy.domainActionName = actionName(action)
    return copy
end

function M.create(opts)
    opts = opts or {}
    local components = {}
    for _, name in ipairs(opts.components or {}) do
        components[#components + 1] = loadComponent(name)
    end

    -- Create the host last because ModuleBase.create resets the process-local
    -- ActionExecutor singleton.
    local host = ModuleBase.create(opts.name, opts.priority)
    host.components = components
    host.componentsByName = {}
    host.domainCandidate = nil
    host.domainReason = 'init'
    host.domainActiveComponent = nil
    host.domainRecoveryComponent = nil

    for _, component in ipairs(components) do
        host.componentsByName[component.componentName] = component
        installComponentFacade(host, component)
    end

    if opts.cache == true then
        host.domainUsesCache = true
    end

    local function scanCandidates()
        local candidates = {}
        for index, component in ipairs(components) do
            if not component.componentSuspended then
                local original = component._domainOriginal
                local tickOk, tickErr = callComponent(host, component, original.onTick)
                if not tickOk then
                    lib.log('error', host.name, '%s sensor failed: %s',
                        component.componentName, tostring(tickErr))
                end
                local active = false
                if type(original.shouldAct) == 'function' then
                    local ok, result = callComponent(host, component, original.shouldAct)
                    active = ok and result == true
                end
                if active and type(original.getAction) == 'function' then
                    local ok, action = callComponent(host, component, original.getAction)
                    if ok and type(action) == 'table' then
                        candidates[#candidates + 1] = {
                            component = component,
                            action = copyAction(action, component.componentName),
                            rank = index,
                        }
                    end
                end
            end
        end
        if type(opts.selectCandidate) == 'function' then
            local selected = opts.selectCandidate(host, candidates)
            if selected == false then return {} end
            if selected then
                for index, candidate in ipairs(candidates) do
                    if candidate == selected then
                        table.remove(candidates, index)
                        table.insert(candidates, 1, candidate)
                        break
                    end
                end
            end
        end
        return candidates
    end

    host.onTick = function(self)
        if type(opts.prepareTick) == 'function' then
            local ok, err = pcall(opts.prepareTick, self, components)
            if not ok then
                lib.log('error', host.name, 'Domain gate failed: %s',
                    tostring(err))
            end
        end
        if self.domainUsesCache and self.domainCacheEnabled ~= false then
            RuntimeCache.setSettings(lib.getSettings())
            RuntimeCache.tick()
        end
        local candidates = scanCandidates()
        local winner = candidates[1]
        local activeName = self.currentAction and self.currentAction.component or nil
        self.domainDeferredInterrupt = nil

        if activeName and type(opts.shouldSuppressActive) == 'function'
            and opts.shouldSuppressActive(self, activeName, winner) == true then
            self:cancelUnifiedAction('domain_safety_hold')
            self:finishAction({
                phase = 'cancelled',
                reason = 'domain_safety_hold',
            })
            self.domainCandidate = winner and winner.action or nil
            self.domainReason = 'safety_hold'
            return
        end

        if activeName and winner and winner.component.componentName ~= activeName
            and type(opts.shouldInterrupt) == 'function'
            and opts.shouldInterrupt(self, activeName,
                winner.component.componentName, candidates) == true then
            self:cancelUnifiedAction('domain_preempted_by:' ..
                winner.component.componentName)
            self:finishAction({
                phase = 'preempted',
                reason = 'domain_preempted_by:' .. winner.component.componentName,
            })
            self.domainCandidate = winner.action
            self.domainReason = 'preempted:' .. winner.component.componentName
            return
        end

        -- Never replace an action while its request is queued or leased.
        if self.currentRequestId then
            self.domainReason = 'active:' .. tostring(activeName or 'unknown')
            if self.domainDeferredInterrupt then
                self.domainReason = self.domainReason .. ';deferred:'
                    .. tostring(self.domainDeferredInterrupt)
            end
            return
        end
        self.domainCandidate = winner and winner.action or nil
        local idleReason = nil
        if not winner and type(opts.getIdleReason) == 'function' then
            local ok, reason = pcall(opts.getIdleReason, self)
            if ok then idleReason = reason end
        end
        self.domainReason = winner
            and ('ready:' .. winner.component.componentName)
            or tostring(idleReason or 'idle')
        self:setIntent(self.domainCandidate ~= nil, nil, self.domainReason)
    end

    host.shouldAct = function(self)
        return self.domainCandidate ~= nil
    end

    host.getAction = function(self)
        return self.domainCandidate
    end

    host.onRequestWithdrawn = function(self, action, reason)
        local component = self.componentsByName[action and action.component or '']
        if component then
            callComponent(self, component,
                component._domainOriginal.onRequestWithdrawn, action, reason)
        end
        self.domainCandidate = nil
    end

    local function finalize(self, action, reason, result)
        local componentName = action and action.component
            or self.domainRecoveryComponent
        local component = self.componentsByName[componentName or '']
        if not component then return true end
        local callback = component._domainOriginal.onLeaseFinalizing
            or component._domainOriginal.onSafetyDrain
        local ok, done, detail = callComponent(self, component, callback,
            action, reason, result)
        if not ok then return false, tostring(done) end
        if done ~= false then
            component.dirtyEffects = false
            if self.domainRecoveryComponent == component.componentName then
                self.domainRecoveryComponent = nil
            end
            self.domainCandidate = nil
        end
        return done, detail
    end
    host.onLeaseFinalizing = finalize
    host.onSafetyDrain = finalize

    host.onSchedulerResume = function(self, gapMs)
        for _, component in ipairs(self.components) do
            callComponent(self, component,
                component._domainOriginal.onSchedulerResume, gapMs)
        end
    end

    host:enableUnifiedExecutor({
        preflight = routedHandler(host, 'preflight'),
        dispatch = routedHandler(host, 'dispatch'),
        onTick = routedHandler(host, 'onTick'),
        onComplete = routedHandler(host, 'onComplete'),
        onFailure = routedHandler(host, 'onFailure'),
        onCancel = routedHandler(host, 'onCancel'),
    })
    host:enablePeerActors()
    return host
end

function M.feignManaged()
    return FeignSafety.isManagedFeign(lib.getSettings())
end

return M
