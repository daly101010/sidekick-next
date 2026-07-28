-- Dedicated spell-set memorization worker.
--
-- The UI sends only an Actor intent. All gem and spellbook mutations happen
-- here while this worker owns the coordinator's single local lease.

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local Memorize = require('sidekick-next.utils.spellset_memorize')

local module = ModuleBase.create('scribing', lib.Priority.SCRIBING)
local _lastReason = 'init'
local _lastResult = 'none'

local function commandEcho(fmt, ...)
    local ok, message = pcall(string.format, tostring(fmt), ...)
    print(string.format('\at[SK Scribing]\ax %s', ok and message or tostring(fmt)))
end

local function plannedWork()
    local work, reason = Memorize.inspectWork()
    _lastReason = tostring(reason or (work and 'ready' or 'idle'))
    return work, reason
end

module.onTick = function(self)
    local work, reason = plannedWork()
    local dirty = Memorize.hasDirtyEffects()
    self:markDirtyEffects(dirty,
        dirty and not self:ownsLease(self.currentRequestId))
    Memorize.publishWorkerStatus(reason, false)
    self:setIntent(work ~= nil, work and 1000 or nil, _lastReason)
end

module.shouldAct = function(self)
    if not self:hasValidState() then return false end
    local work = plannedWork()
    return work ~= nil
end

module.getAction = function()
    local work = plannedWork()
    if not work then return nil end
    local setName = tostring(work.setName or '')
    return {
        kind = 'spell_memorize',
        mode = tostring(work.mode or 'apply'),
        setName = setName,
        phase = tostring(work.phase or 'pending'),
        breaksInvis = false,
        skipBoundaryTarget = true,
        timeoutMs = 180000,
        idempotencyKey = string.format('scribing:%s:%s',
            tostring(work.mode or 'apply'), setName ~= '' and setName or 'cleanup'),
        reason = string.format('%s spell set %s (%s)',
            tostring(work.mode or 'apply'), setName ~= '' and setName or 'cleanup',
            tostring(work.phase or 'pending')),
    }
end

module.executeAction = function(self)
    local action = self:getLeaseAction()
    if not action then return true, 'no_action' end

    if action.mode == 'cleanup' then
        local done, reason = Memorize.drainOwnedEffects('leased_cleanup')
        self:markDirtyEffects(Memorize.hasDirtyEffects())
        _lastResult = tostring(reason or 'cleanup')
        Memorize.publishWorkerStatus(_lastResult, true)
        return done == true, reason
    end

    local terminal, reason = Memorize.advanceLeased()
    self:markDirtyEffects(Memorize.hasDirtyEffects())
    _lastResult = tostring(reason or (terminal and 'completed' or 'active'))
    Memorize.publishWorkerStatus(_lastResult, terminal == true)
    return terminal == true, reason
end

local function finalizeLease(self, _, reason)
    if Memorize.hasDirtyEffects() and not self:ownsLease(self.currentRequestId) then
        -- A stale lease snapshot may be released, but it cannot authorize a
        -- spellbook mutation. Advertise recovery need and wait for the
        -- coordinator's exact recovery lease.
        self:markDirtyEffects(true, true)
        Memorize.abortActive(reason or 'lease_lost', true)
        return true, 'recovery_required'
    end

    local done, detail = Memorize.drainOwnedEffects(reason or 'lease_finalized')
    self:markDirtyEffects(Memorize.hasDirtyEffects())
    if done then Memorize.publishWorkerStatus(detail or reason, true) end
    return done, detail
end

module.onLeaseFinalizing = finalizeLease
module.onSafetyDrain = finalizeLease
module:enablePeerActors()

mq.bind('/sk_scribing', function(cmd)
    cmd = tostring(cmd or ''):lower()
    if cmd == 'stop' then
        module:stop()
    elseif cmd == '' or cmd == 'status' then
        local work, reason = plannedWork()
        local lease = module.state and module.state.lease or nil
        commandEcho(
            'running=%s tier=%s ownsLease=%s pending=%s request=%s holder=%s work=%s set=%s phase=%s dirty=%s reason=%s last=%s',
            tostring(module.running), tostring(module.priority), tostring(module:ownsLease()),
            tostring(module.currentRequestId ~= nil and not module:ownsLease()),
            tostring(module.currentRequestId or 'none'),
            tostring(lease and lease.holderModule or 'none'),
            tostring(work and work.mode or 'none'),
            tostring(work and work.setName or 'none'),
            tostring(work and work.phase or 'none'),
            tostring(Memorize.hasDirtyEffects()), tostring(reason or _lastReason),
            tostring(_lastResult))
    else
        commandEcho('Usage: /sk_scribing status|stop')
    end
end)

Memorize.initializeWorker()
module:run(50)
Memorize.publishWorkerStatus('worker_exit', true)

return module
