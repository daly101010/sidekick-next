local Scheduler = dofile('utils/lease_scheduler.lua')

local registry = {
    { module = 'emergency', script = 'sk_emergency', tier = 0, order = 1, canPreempt = true },
    { module = 'healing', script = 'sk_healing', tier = 1, order = 2, canPreempt = true },
    { module = 'assist', script = 'sk_assist', tier = 7, order = 3 },
    { module = 'dps', script = 'sk_dps', tier = 7, order = 4 },
}
local sequences = setmetatable({}, { __mode = 'k' })

local function newScheduler(bootId)
    return Scheduler.new({
        bootId = bootId,
        protocolVersion = 2,
        registry = registry,
        defaultRequestTtlMs = 2000,
        defaultLeaseTtlMs = 5000,
        revocationGraceMs = 2000,
        nowMs = 0,
    })
end

local function request(scheduler, moduleName, requestId, nowMs, extra)
    sequences[scheduler] = sequences[scheduler] or {}
    local seq = (sequences[scheduler][moduleName] or 0) + 1
    sequences[scheduler][moduleName] = seq
    local content = {
        version = 2,
        coordinatorBootId = scheduler.bootId,
        module = moduleName,
        workerSessionId = moduleName .. '-session',
        requestId = requestId,
        requestTtlMs = 2000,
        operationSeq = seq,
    }
    for key, value in pairs(extra or {}) do content[key] = value end
    local ok, reason = scheduler:request(content, 'sk_' .. moduleName, nowMs)
    assert(ok, reason)
end

local function releaseCurrent(scheduler, nowMs, overrides)
    local lease = assert(scheduler.lease)
    local content = {
        version = 2,
        coordinatorBootId = scheduler.bootId,
        module = lease.holderModule,
        workerSessionId = lease.workerSessionId,
        requestId = lease.requestId,
        token = lease.token,
    }
    for key, value in pairs(overrides or {}) do content[key] = value end
    return scheduler:release(content, 'sk_' .. lease.holderModule, nowMs)
end

local function withdraw(scheduler, moduleName, requestId, nowMs, operationSeq)
    return scheduler:withdraw({
        version = 2,
        coordinatorBootId = scheduler.bootId,
        module = moduleName,
        workerSessionId = moduleName .. '-session',
        requestId = requestId,
        operationSeq = operationSeq,
    }, 'sk_' .. moduleName, nowMs)
end

-- Same-tier order is registry order, never request arrival or worker priority.
do
    local scheduler = newScheduler('order')
    request(scheduler, 'dps', 'dps-1', 1, { priority = -100, action = { forged = true } })
    request(scheduler, 'assist', 'assist-1', 2, { priority = 999 })
    scheduler:tick(3)
    assert(scheduler.lease.holderModule == 'assist')
    assert(scheduler.lease.tier == 7)
    assert(scheduler.lease.action == nil)
end

-- A withdrawal arriving before its delayed request leaves an ordering
-- tombstone, so stale intent cannot resurrect.
do
    local scheduler = newScheduler('withdraw-order')
    assert(withdraw(scheduler, 'dps', 'dps-1', 1, 2))
    local ok, reason = scheduler:request({
        version = 2,
        coordinatorBootId = scheduler.bootId,
        module = 'dps',
        workerSessionId = 'dps-session',
        requestId = 'dps-1',
        requestTtlMs = 2000,
        operationSeq = 1,
    }, 'sk_dps', 2)
    assert(ok == false and reason == 'stale_operation_sequence')
    scheduler:tick(3)
    assert(scheduler.lease == nil)
end

-- Urgent work creates a revocation barrier; no replacement grant occurs until release.
do
    local scheduler = newScheduler('preempt')
    request(scheduler, 'dps', 'dps-1', 1)
    scheduler:tick(2)
    request(scheduler, 'healing', 'heal-1', 3)
    scheduler:tick(4)
    assert(scheduler.lease.holderModule == 'dps')
    assert(scheduler.lease.status == 'revoking')
    assert(scheduler.lease.revokeReason == 'preempted_by:healing')
    assert(releaseCurrent(scheduler, 5))
    scheduler:tick(6)
    assert(scheduler.lease.holderModule == 'healing')
end

-- The preemption toggle makes urgent requests wait.
do
    local scheduler = newScheduler('no-preempt')
    scheduler:setPreemptionEnabled(false, 0)
    request(scheduler, 'dps', 'dps-1', 1)
    scheduler:tick(2)
    request(scheduler, 'emergency', 'emergency-1', 3)
    scheduler:tick(4)
    assert(scheduler.lease.holderModule == 'dps')
    assert(scheduler.lease.status == 'active')
end

-- Exact boot/session/request/token validation fences stale holders.
do
    local scheduler = newScheduler('fencing')
    request(scheduler, 'dps', 'dps-1', 1)
    scheduler:tick(2)
    local ok = releaseCurrent(scheduler, 3, { coordinatorBootId = 'old-boot' })
    assert(ok == false)
    ok = releaseCurrent(scheduler, 3, { workerSessionId = 'old-session' })
    assert(ok == false)
    ok = releaseCurrent(scheduler, 3, { requestId = 'old-request' })
    assert(ok == false)
    ok = releaseCurrent(scheduler, 3, { token = 'old-token' })
    assert(ok == false)
    assert(scheduler.lease ~= nil)
end

-- Pause drains the holder and never grants queued ordinary work.
do
    local scheduler = newScheduler('pause')
    request(scheduler, 'dps', 'dps-1', 1)
    scheduler:tick(2)
    scheduler:setPaused(true, 'automation_paused', 3)
    assert(scheduler.lifecycle == 'pausing')
    assert(scheduler.lease.status == 'revoking')
    assert(releaseCurrent(scheduler, 4))
    scheduler:tick(5)
    assert(scheduler.lifecycle == 'paused')
    assert(scheduler.lease == nil)
end

-- Forced expiry fences the old token and blocks all normal grants during recovery.
do
    local scheduler = newScheduler('recovery')
    request(scheduler, 'dps', 'dps-1', 1)
    scheduler:tick(2)
    local oldToken = scheduler.lease.token
    request(scheduler, 'healing', 'heal-1', 3)
    scheduler:tick(5003)
    assert(scheduler.lease.holderModule == 'dps')
    assert(scheduler.lease.status == 'recovering')
    assert(scheduler.lease.token ~= oldToken)
end

-- Coordinators on separate characters have independent local leases.
do
    local left = newScheduler('character-a')
    local right = newScheduler('character-b')
    request(left, 'assist', 'left', 1)
    request(right, 'dps', 'right', 1)
    left:tick(2)
    right:tick(2)
    assert(left.lease and right.lease)
    assert(left.lease.token ~= right.lease.token)
end

print('lease_scheduler_test: ok')
