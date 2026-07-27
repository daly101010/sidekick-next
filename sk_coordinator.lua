-- Central, action-blind single-lease coordinator for SideKick-Next.
--
-- Workers decide what to do. This process knows only registered worker
-- identity, deterministic scheduler policy, request identity, and lease
-- lifecycle. Actor callbacks copy/enqueue only; all state mutation, TLO reads,
-- process control, and Actor-team work occurs from the normal coroutine.

local mq = require('mq')
local actors = require('actors')
local lib = require('sidekick-next.sk_lib')
local LeaseScheduler = require('sidekick-next.utils.lease_scheduler')
local ActorsTeam = require('sidekick-next.utils.actors_team')

local M = {}
M.MODULE_NAME = 'coordinator'

local debugLog =
    require('sidekick-next.utils.debug_log').module('sk_coordinator', 'SK_COORDINATOR')

local function makeBootId()
    return string.format('%s:%s:%d:%d',
        tostring(lib.getMyServer() or ''),
        tostring(lib.getMyName() or ''),
        os.time(),
        tonumber(lib.getTimeMs()) or 0)
end

local State = {
    coordinatorBootId = makeBootId(),
    tickId = 0,
    running = true,
    startedAtMs = lib.getTimeMs(),

    worldState = {
        inGame = lib.isInGame(),
        inCombat = false,
        selfDead = false,
        incapacitated = false,
        incapacitationReason = nil,
        stunned = false,
        mezzed = false,
        silenced = false,
        feared = false,
        myHpPct = 100,
        myManaPct = 100,
        groupNeedsHealing = false,
        emergencyActive = false,
        deadCount = 0,
        mainAssistId = 0,
        castBusy = false,
    },

    moduleHeartbeats = {},
    moduleScripts = {},
    knownModules = {},

    lastBroadcastAt = 0,
    lastEpochBroadcast = -1,
    pendingBroadcast = true,
    stateSendAttempts = 0,
    stateSendFailures = 0,
    lastStateSendError = nil,
    lastWorkerStateSendAt = {},

    supervisorSeen = false,
    supervisorLastSeenAt = 0,
    supervisorLastSentAt = 0,
    supervisorSessionId = nil,
    supervisorReplyMailbox = nil,
    supervisorShutdownRequested = false,
    supervisorShutdownAckSent = false,

    automationPaused = false,
    settingsRevision = 0,
    humanizeOverride = 'auto',
    leasePreemptionEnabled = true,
}

State.scheduler = LeaseScheduler.new({
    bootId = State.coordinatorBootId,
    protocolVersion = lib.LEASE_PROTOCOL_VERSION,
    registry = lib.WorkerRegistry,
    defaultRequestTtlMs = lib.Timing.LEASE_REQUEST_TTL_MS,
    defaultLeaseTtlMs = lib.Timing.LEASE_TTL_MS,
    revocationGraceMs = lib.Timing.LEASE_REVOCATION_GRACE_MS,
    recoveryTtlMs = lib.Timing.LEASE_RECOVERY_TTL_MS,
    preemptionEnabled = true,
    nowMs = State.startedAtMs,
})

local dropbox = nil
local mailboxDropboxes = {}
local pendingActorMessages = {}
local MAX_PENDING_ACTOR_MESSAGES = 2000
local pendingLatestByKey = {}
local COALESCE_TYPES = {
    heartbeat = true,
    ['lease:request'] = true,
    ['lease:renew'] = true,
}

local _localIdentityName = ''
local _localIdentityServer = ''
local _teamSettingsRevision = nil
local _teamSettings = {}
local _lastTeamTickAt = 0
local TEAM_TICK_INTERVAL_MS = 250
local _lastWorldStateAt = 0
local _lastWatchdogCheck = 0
local _restartTracker = {}
local _pendingReload = nil
local _lastCoordinatorTickAt = State.startedAtMs
local _wasInGame = State.worldState.inGame

local function refreshLocalIdentity()
    _localIdentityName = tostring(lib.getMyName() or '')
    _localIdentityServer = tostring(lib.getMyServer() or '')
end

local function copyWireValue(value, depth, seen)
    local valueType = type(value)
    if valueType == 'string' or valueType == 'number' or valueType == 'boolean' then
        return value
    end
    if valueType ~= 'table' then return nil end
    depth = tonumber(depth) or 0
    if depth >= 8 then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true

    local result = {}
    local count = 0
    for key, child in pairs(value) do
        if count >= 512 then break end
        local keyType = type(key)
        if keyType == 'string'
            or (keyType == 'number' and key >= 0 and key % 1 == 0) then
            local copy = copyWireValue(child, depth + 1, seen)
            if copy ~= nil then
                result[key] = copy
                count = count + 1
            end
        end
    end
    seen[value] = nil
    return result
end

local function enqueueActorMessage(message)
    -- Actor handlers run with yielding disabled. Copy only serializable values
    -- and queue them for the coordinator coroutine.
    local content = copyWireValue(message(), 0, {})
    if type(content) ~= 'table' then return end
    local sender = message.sender or {}
    local senderCopy = {
        mailbox = tostring(sender.mailbox or ''),
        script = tostring(sender.script or ''),
        account = tostring(sender.account or ''),
        server = tostring(sender.server or ''),
        character = tostring(sender.character or ''),
        pid = tostring(sender.pid or ''),
        uuid = tostring(sender.uuid or ''),
        name = tostring(sender.name or ''),
    }
    local msgType = tostring(content.msgType or '')
    local entry = { content = content, sender = senderCopy }
    if COALESCE_TYPES[msgType] and content.module ~= nil then
        local key = string.format('%s|%s|%s|%s|%s', msgType,
            tostring(content.module), tostring(content.workerSessionId or ''),
            tostring(content.ownerServer or ''), tostring(content.ownerName or ''))
        local existing = pendingLatestByKey[key]
        if existing then
            existing.content = content
            existing.sender = senderCopy
            return
        end
        entry.key = key
        pendingLatestByKey[key] = entry
    end
    if #pendingActorMessages >= MAX_PENDING_ACTOR_MESSAGES then
        local dropped = table.remove(pendingActorMessages, 1)
        if dropped and dropped.key then pendingLatestByKey[dropped.key] = nil end
    end
    pendingActorMessages[#pendingActorMessages + 1] = entry
end

local function parseSenderScript(mailbox)
    if type(mailbox) ~= 'string' then return nil end
    local script = mailbox:match('^[^:]+:([^:]+):')
    if script and script:find('/', 1, true) then return script end
    return nil
end

local function resolveSenderScript(sender)
    sender = type(sender) == 'table' and sender or {}
    local script = tostring(sender.script or '')
    if script ~= '' then return script end
    return parseSenderScript(sender.mailbox)
end

local function isLocalMessage(content, sender)
    if type(content) ~= 'table' then return false end
    local ownerName = tostring(content.ownerName or '')
    local ownerServer = tostring(content.ownerServer or '')
    if ownerName == '' or ownerServer == '' then return false end
    if _localIdentityName == '' or _localIdentityServer == '' then
        refreshLocalIdentity()
    end
    if ownerName ~= _localIdentityName or ownerServer ~= _localIdentityServer then
        return false
    end

    sender = type(sender) == 'table' and sender or {}
    local senderCharacter = tostring(sender.character or '')
    local senderServer = tostring(sender.server or '')
    if senderCharacter ~= '' and senderCharacter ~= _localIdentityName then
        return false
    end
    if senderServer ~= '' and senderServer ~= _localIdentityServer then
        return false
    end
    return true
end

local function isRegisteredWorkerMessage(content, sender)
    if not isLocalMessage(content, sender) then return false, nil, nil end
    if tonumber(content.version) ~= tonumber(lib.LEASE_PROTOCOL_VERSION) then
        return false, nil, nil
    end
    local spec = lib.getWorkerSpec(content.module)
    local senderScript = resolveSenderScript(sender)
    if not spec or not senderScript or senderScript ~= spec.script then
        return false, spec, senderScript
    end
    return true, spec, senderScript
end

local function isUiSender(sender)
    local senderScript = resolveSenderScript(sender)
    if not senderScript then return false end
    for _, script in ipairs(lib.Scripts.UI or {}) do
        if senderScript == script then return true end
    end
    return false
end

local function refreshTeamSettings()
    local revision = tonumber(State.settingsRevision) or 0
    if _teamSettingsRevision ~= revision then
        _teamSettings = lib.refreshSettings(revision) or lib.getSettings() or {}
        _teamSettingsRevision = revision
    end
    return _teamSettings
end

local function heartbeatFresh(heartbeat, nowMs)
    return heartbeat ~= nil
        and heartbeat.ready ~= false
        and (nowMs - (tonumber(heartbeat.receivedAtMs) or 0))
            <= lib.Timing.MODULE_CRASH_MS
end

local function buildTeamTickSnapshot()
    local now = lib.getTimeMs()
    local modules = {}
    for _, spec in ipairs(lib.WorkerRegistry) do
        local heartbeat = State.moduleHeartbeats[spec.module]
        local request = State.scheduler.requests[spec.module]
        modules[spec.module] = {
            ready = heartbeatFresh(heartbeat, now),
            requested = request ~= nil,
            tier = spec.tier,
        }
    end

    local schedulerState = State.scheduler:getSnapshot()
    local lease = schedulerState.lease
    local leaseSummary = lease and {
        holderModule = lease.holderModule,
        requestId = lease.requestId,
        status = lease.status,
        tier = lease.tier,
    } or nil

    local settings = refreshTeamSettings()
    local targetId, targetType, targetName = 0, '', ''
    local target = mq.TLO.Target
    if target and lib.safeTLO(function() return target() ~= nil end, false) then
        targetId = tonumber(lib.safeTLO(function() return target.ID() end, 0)) or 0
        if targetId > 0 then
            targetType = tostring(lib.safeTLO(function() return target.Type() end, '') or '')
            targetName = tostring(lib.safeTLO(function() return target.CleanName() end, '') or '')
        end
    end

    return {
        zone = lib.getZone(),
        class = tostring(lib.safeTLO(function()
            return mq.TLO.Me.Class.ShortName()
        end, '') or ''),
        role = tostring(settings.CombatMode or 'off'),
        inGame = State.worldState.inGame == true,
        inCombat = State.worldState.inCombat == true,
        dead = State.worldState.selfDead == true,
        incapacitated = State.worldState.incapacitated == true,
        automationPaused = State.automationPaused == true,
        activePriority = schedulerState.activePriority,
        targetId = targetId,
        targetType = targetType,
        targetName = targetName,
        lease = leaseSummary,
        modules = modules,
    }
end

local function tickActorsTeam()
    local now = os.clock() * 1000
    if (now - _lastTeamTickAt) < TEAM_TICK_INTERVAL_MS then return end
    _lastTeamTickAt = now
    ActorsTeam.tick(buildTeamTickSnapshot(), refreshTeamSettings())
end

local function updateWorldState()
    local world = State.worldState
    world.inGame = lib.isInGame()
    if not world.inGame then
        world.inCombat = false
        world.castBusy = false
        return
    end

    local me = mq.TLO.Me
    if not (me and lib.safeTLO(function() return me() ~= nil end, false)) then
        world.selfDead = true
        world.inCombat = false
        world.castBusy = false
        return
    end

    world.selfDead = lib.isSelfDeadOrHovering()
    world.inCombat = lib.inCombat()
    world.myHpPct = lib.safeNum(function() return me.PctHPs() end, 100)
    world.myManaPct = lib.safeNum(function() return me.PctMana() end, 100)
    world.mainAssistId = lib.getMainAssistId()
    world.castBusy = lib.isCasting()

    local control = lib.getIncapacitationState()
    world.incapacitated = control.incapacitated == true
    world.incapacitationReason = control.reason
    world.stunned = control.stunned == true
    world.mezzed = control.mezzed == true
    world.silenced = control.silenced == true
    world.feared = control.feared == true

    local deadCount = 0
    local needsHealing = world.myHpPct < 80
    local emergency = world.myHpPct < 25
    local groupCount = lib.getGroupCount()
    for index = 1, groupCount do
        local member = mq.TLO.Group.Member(index)
        if member and lib.safeTLO(function() return member() ~= nil end, false) then
            if lib.safeTLO(function() return member.Dead() end, false) == true then
                deadCount = deadCount + 1
            end
            local hp = lib.safeNum(function() return member.PctHPs() end, 100)
            if hp < 80 then needsHealing = true end
            if hp < 25 then emergency = true end
        end
    end
    world.deadCount = deadCount
    world.groupNeedsHealing = needsHealing
    world.emergencyActive = emergency
end

local function noteSchedulerResult(kind, moduleName, ok, reason)
    State.lastLeaseOperation = {
        kind = tostring(kind or ''),
        module = tostring(moduleName or ''),
        ok = ok == true,
        reason = tostring(reason or ''),
        atMs = lib.getTimeMs(),
    }
    if ok then
        State.pendingBroadcast = true
    else
        debugLog('%s rejected: module=%s reason=%s',
            tostring(kind), tostring(moduleName), tostring(reason))
    end
end

local function processSupervisorHeartbeat(content, sender, nowMs)
    if not isLocalMessage(content, sender) or not isUiSender(sender) then return end
    local sentAtMs = tonumber(content.sentAtMs) or 0
    if sentAtMs <= State.supervisorLastSentAt then return end
    local sessionId = tostring(content.sessionId or '')
    if sessionId == '' then return end

    State.supervisorSeen = true
    State.supervisorLastSeenAt = nowMs
    State.supervisorLastSentAt = sentAtMs
    State.supervisorSessionId = sessionId
    if tostring(sender.mailbox or '') ~= '' then
        State.supervisorReplyMailbox = tostring(sender.mailbox)
    end

    local paused = content.automationPaused == true
    local revision = tonumber(content.settingsRevision) or 0
    local override = tostring(content.humanizeOverride or 'auto')
    local preemption = content.leasePreemptionEnabled ~= false
    if State.automationPaused ~= paused
        or State.settingsRevision ~= revision
        or State.humanizeOverride ~= override
        or State.leasePreemptionEnabled ~= preemption then
        State.automationPaused = paused
        State.settingsRevision = revision
        State.humanizeOverride = override
        State.leasePreemptionEnabled = preemption
        State.scheduler:setPreemptionEnabled(preemption, nowMs)
        State.scheduler:setPaused(paused, 'automation_paused', nowMs)
        State.pendingBroadcast = true
    end
end

local function processSupervisorShutdown(content, sender, nowMs)
    if not isLocalMessage(content, sender) or not isUiSender(sender) then return end
    if not State.supervisorSeen
        or tostring(content.sessionId or '') == ''
        or content.sessionId ~= State.supervisorSessionId then
        return
    end
    if tostring(sender.mailbox or '') ~= '' then
        State.supervisorReplyMailbox = tostring(sender.mailbox)
    end
    State.supervisorShutdownRequested = true
    State.scheduler:setPaused(true, 'supervisor_shutdown', nowMs)
    State.pendingBroadcast = true
end

local function processHeartbeat(content, sender, nowMs)
    local valid, spec, senderScript = isRegisteredWorkerMessage(content, sender)
    if not valid then return end
    local workerSessionId = tostring(content.workerSessionId or '')
    if workerSessionId == '' then return end

    local previous = State.moduleHeartbeats[spec.module]
    local sentAtMs = tonumber(content.sentAtMs) or 0
    if previous and sentAtMs <= (tonumber(previous.sentAtMs) or 0) then
        return
    end
    State.knownModules[spec.module] = true
    State.moduleScripts[spec.module] = spec.script
    State.moduleHeartbeats[spec.module] = {
        receivedAtMs = nowMs,
        sentAtMs = sentAtMs,
        ready = content.ready ~= false,
        workerSessionId = workerSessionId,
        script = spec.script,
        mailbox = tostring(sender.mailbox or ''),
        counters = type(content.counters) == 'table'
            and copyWireValue(content.counters, 0, {}) or nil,
    }

    State.scheduler:observeWorkerSession(
        spec.module, workerSessionId, senderScript, nowMs)
    if content.dirtyEffects == true or content.needsRecovery == true then
        State.scheduler:requestRecovery(
            spec.module, workerSessionId, senderScript, nowMs)
    end

    local tracker = _restartTracker[spec.script]
    if tracker then
        tracker.gaveUp = false
        tracker.stableSinceMs = tracker.stableSinceMs or nowMs
        if (nowMs - tracker.stableSinceMs) >= lib.Timing.RESTART_STABLE_MS then
            tracker.count = 0
            tracker.stableSinceMs = nowMs
        end
    end
    if not previous or previous.workerSessionId ~= workerSessionId then
        State.pendingBroadcast = true
    end
end

local function processLeaseMessage(kind, content, sender, nowMs)
    local valid, spec, senderScript = isRegisteredWorkerMessage(content, sender)
    if not valid then return end
    local heartbeat = State.moduleHeartbeats[spec.module]
    if not heartbeat
        or tostring(heartbeat.workerSessionId or '')
            ~= tostring(content.workerSessionId or '') then
        noteSchedulerResult(kind, content.module, false, 'unrecognized_worker_session')
        return
    end
    local ok, reason
    if kind == 'request' then
        ok, reason = State.scheduler:request(content, senderScript, nowMs)
    elseif kind == 'withdraw' then
        ok, reason = State.scheduler:withdraw(content, senderScript, nowMs)
    elseif kind == 'renew' then
        ok, reason = State.scheduler:renew(content, senderScript, nowMs)
    elseif kind == 'release' then
        ok, reason = State.scheduler:release(content, senderScript, nowMs)
    elseif kind == 'recovered' then
        ok, reason = State.scheduler:recovered(content, senderScript, nowMs)
    end
    noteSchedulerResult(kind, content.module, ok, reason)
end

local function processMessage(content, sender, nowMs)
    if type(content) ~= 'table' then return end
    local msgType = tostring(content.msgType or '')
    local mailbox = tostring(sender and sender.mailbox or '')
    if msgType == '' then
        if mailbox == lib.Mailbox.LEASE_REQUEST then msgType = 'lease:request'
        elseif mailbox == lib.Mailbox.LEASE_WITHDRAW then msgType = 'lease:withdraw'
        elseif mailbox == lib.Mailbox.LEASE_RENEW then msgType = 'lease:renew'
        elseif mailbox == lib.Mailbox.LEASE_RELEASE then msgType = 'lease:release'
        elseif mailbox == lib.Mailbox.LEASE_RECOVERED then msgType = 'lease:recovered'
        elseif mailbox == lib.Mailbox.HEARTBEAT then msgType = 'heartbeat'
        end
    end

    if msgType == 'supervisor_heartbeat' then
        processSupervisorHeartbeat(content, sender, nowMs)
    elseif msgType == 'supervisor_shutdown' then
        processSupervisorShutdown(content, sender, nowMs)
    elseif msgType == 'heartbeat' then
        processHeartbeat(content, sender, nowMs)
    elseif msgType == 'lease:request' then
        processLeaseMessage('request', content, sender, nowMs)
    elseif msgType == 'lease:withdraw' then
        processLeaseMessage('withdraw', content, sender, nowMs)
    elseif msgType == 'lease:renew' then
        processLeaseMessage('renew', content, sender, nowMs)
    elseif msgType == 'lease:release' then
        processLeaseMessage('release', content, sender, nowMs)
    elseif msgType == 'lease:recovered' then
        processLeaseMessage('recovered', content, sender, nowMs)
    end
end

local function drainActorMessages()
    if #pendingActorMessages == 0 then return end
    local pending = pendingActorMessages
    pendingActorMessages = {}
    pendingLatestByKey = {}
    refreshLocalIdentity()
    local nowMs = lib.getTimeMs()
    State.lastDrainCount = #pending
    for _, entry in ipairs(pending) do
        processMessage(entry.content, entry.sender, nowMs)
    end
end

local function buildModuleDiagnostics(nowMs)
    local diagnostics = {}
    for _, spec in ipairs(lib.WorkerRegistry) do
        local heartbeat = State.moduleHeartbeats[spec.module]
        local age = heartbeat
            and math.max(0, nowMs - (tonumber(heartbeat.receivedAtMs) or 0)) or 0
        local request = State.scheduler.requests[spec.module]
        diagnostics[spec.module] = {
            script = spec.script,
            tier = spec.tier,
            order = spec.order,
            canPreempt = spec.canPreempt == true,
            canActDead = spec.canActDead == true,
            ready = heartbeatFresh(heartbeat, nowMs),
            heartbeatAge = age,
            stale = heartbeat ~= nil and not heartbeatFresh(heartbeat, nowMs),
            workerSessionId = heartbeat and heartbeat.workerSessionId or nil,
            requestId = request and request.requestId or nil,
            requestAge = request
                and math.max(0, nowMs - (request.receivedAtMs or 0)) or 0,
            requestTtl = request and request.requestTtlMs or 0,
            counters = heartbeat and heartbeat.counters or nil,
        }
    end
    return diagnostics
end

local function buildStatePayload()
    local nowMs = lib.getTimeMs()
    local schedulerState = State.scheduler:getSnapshot()
    return {
        version = lib.LEASE_PROTOCOL_VERSION,
        coordinatorBootId = State.coordinatorBootId,
        tickId = State.tickId,
        epoch = schedulerState.epoch,
        ownerName = lib.getMyName(),
        ownerServer = lib.getMyServer(),
        sentAtMs = nowMs,
        ttlMs = lib.Timing.STATE_TTL_MS,
        lifecycle = schedulerState.lifecycle,
        lease = schedulerState.lease,
        activePriority = schedulerState.activePriority,
        requestCount = schedulerState.requestCount,
        recoveryRequestCount = schedulerState.recoveryRequestCount,
        leasePreemptionEnabled = schedulerState.preemptionEnabled,
        schedulerAvailable = schedulerState.available,
        schedulerUnavailableReason = schedulerState.unavailableReason,
        schedulerFault = schedulerState.faultReason,
        worldState = State.worldState,
        moduleDiag = buildModuleDiagnostics(nowMs),
        team = ActorsTeam.getSnapshot(),
        automationPaused = State.automationPaused == true,
        settingsRevision = tonumber(State.settingsRevision) or 0,
        humanizeOverride = tostring(State.humanizeOverride or 'auto'),
    }
end

local function sendState(address, payload, key, sent)
    if sent[key] then return true end
    sent[key] = true
    State.stateSendAttempts = State.stateSendAttempts + 1
    local ok, result = pcall(function()
        return dropbox:send(address, payload)
    end)
    if not ok or result == false then
        State.stateSendFailures = State.stateSendFailures + 1
        State.lastStateSendError = string.format('%s: %s', key, tostring(result))
        return false
    end
    return true
end

local function broadcastState()
    if not dropbox then return end
    State.tickId = State.tickId + 1
    local payload = buildStatePayload()
    local workerPayload = {}
    for key, value in pairs(payload) do
        if key ~= 'moduleDiag' then workerPayload[key] = value end
    end

    local sent = {}
    local function toScript(script, body)
        if not script or script == '' then return false end
        return sendState({
            mailbox = lib.Mailbox.STATE,
            script = script,
            character = lib.localCharacter(),
        }, body or payload, 'script:' .. script, sent)
    end

    for _, script in ipairs(lib.Scripts.UI or {}) do toScript(script, payload) end

    local schedulerState = State.scheduler:getSnapshot()
    local leaseModule = schedulerState.lease and schedulerState.lease.holderModule or nil
    local nowMs = lib.getTimeMs()
    for _, spec in ipairs(lib.WorkerRegistry) do
        local heartbeat = State.moduleHeartbeats[spec.module]
        local active = leaseModule == spec.module
            or State.scheduler.requests[spec.module] ~= nil
            or State.scheduler.recoveryRequests[spec.module] ~= nil
        local seed = nowMs <= (State.startedAtMs + lib.Timing.STATE_TTL_MS)
        local lastAt = State.lastWorkerStateSendAt[spec.module] or 0
        if seed or (heartbeat
            and (active or (nowMs - lastAt) >= 2000)) then
            State.lastWorkerStateSendAt[spec.module] = nowMs
            toScript(spec.script, workerPayload)
        end
    end

    State.lastBroadcastAt = nowMs
    State.lastEpochBroadcast = schedulerState.epoch
    State.pendingBroadcast = false
end

local function attemptRestart(moduleName, scriptPath)
    if not scriptPath or scriptPath == '' then return false end
    local nowMs = lib.getTimeMs()
    local tracker = _restartTracker[scriptPath]
        or { count = 0, lastAttemptMs = 0, stableSinceMs = nil }
    _restartTracker[scriptPath] = tracker
    if tracker.count >= lib.MAX_MODULE_RESTARTS then
        tracker.gaveUp = true
        local lease = State.scheduler.lease
        if lease and lease.status == 'recovering'
            and lease.holderModule == moduleName then
            State.scheduler:faultRecovery('worker_restart_limit', nowMs)
            State.pendingBroadcast = true
        end
        return false
    end
    if tracker.count > 0
        and (nowMs - tracker.lastAttemptMs) < lib.Timing.RESTART_COOLDOWN_MS then
        return false
    end
    tracker.count = tracker.count + 1
    tracker.lastAttemptMs = nowMs
    tracker.stableSinceMs = nil
    printf('\ay[SK-Watchdog]\ax Restarting %s (attempt %d/%d)',
        scriptPath, tracker.count, lib.MAX_MODULE_RESTARTS)
    mq.cmdf('/lua run %s', scriptPath)
    return true
end

local function checkModuleHealth()
    local nowMs = lib.getTimeMs()
    if not lib.isInGame() then
        _lastWatchdogCheck = nowMs
        return
    end
    if (nowMs - _lastWatchdogCheck) < lib.Timing.WATCHDOG_CHECK_MS then return end
    _lastWatchdogCheck = nowMs

    for _, spec in ipairs(lib.WorkerRegistry) do
        local heartbeat = State.moduleHeartbeats[spec.module]
        local age = heartbeat
            and nowMs - (tonumber(heartbeat.receivedAtMs) or 0) or math.huge
        if age > lib.Timing.MODULE_CRASH_MS
            and (heartbeat or (nowMs - State.startedAtMs) > lib.Timing.MODULE_CRASH_MS) then
            local status = lib.getLuaScriptStatus(spec.script)
            local lease = State.scheduler.lease
            if lease and lease.holderModule == spec.module
                and lease.status ~= 'recovering' then
                State.scheduler:beginRecovery(
                    status == 'EXITED' and 'worker_exited' or 'heartbeat_stale', nowMs)
                State.pendingBroadcast = true
            end

            if status == 'EXITED' then
                attemptRestart(spec.module, spec.script)
                State.moduleHeartbeats[spec.module] = nil
            elseif heartbeat then
                -- MQ2Lua process state is authoritative for restart decisions;
                -- keep the process, but never restore its fenced lease.
                heartbeat.receivedAtMs = nowMs
            end
        end
    end
end

local function handleRecoveryTimeout(nowMs)
    local lease = State.scheduler.lease
    if not lease or lease.status ~= 'recovering'
        or lease.recoveryTimedOut ~= true
        or lease.recoveryRestartIssued == true then
        return
    end
    local spec = lib.getWorkerSpec(lease.holderModule)
    if not spec then
        State.scheduler:faultRecovery('recovery_worker_unregistered', nowMs)
        State.pendingBroadcast = true
        return
    end

    lease.recoveryRestartIssued = true
    printf('\ar[SK-Recovery]\ax Cleanup timed out; restarting %s under the fenced recovery lease',
        tostring(spec.script))
    mq.cmdf('/lua stop %s', spec.script)
    State.moduleHeartbeats[spec.module] = nil
    if not attemptRestart(spec.module, spec.script) then
        local tracker = _restartTracker[spec.script]
        if tracker and tracker.gaveUp then
            State.scheduler:faultRecovery('recovery_restart_limit', nowMs)
        end
    end
    State.pendingBroadcast = true
end

local function sendSupervisorShutdownAck()
    if State.supervisorShutdownAckSent or not dropbox then return end
    local mailbox = tostring(State.supervisorReplyMailbox or '')
    if mailbox == '' then return end
    local payload = {
        msgType = 'supervisor_shutdown_drained',
        ownerName = lib.getMyName(),
        ownerServer = lib.getMyServer(),
        sessionId = State.supervisorSessionId,
        coordinatorBootId = State.coordinatorBootId,
        sentAtMs = lib.getTimeMs(),
    }
    local ok, result = pcall(function()
        return dropbox:send({ mailbox = mailbox, absolute_mailbox = true }, payload)
    end)
    State.supervisorShutdownAckSent = ok and result ~= false
end

local function requestSafeShutdown(reason, nowMs)
    if not State.supervisorShutdownRequested then
        State.supervisorShutdownRequested = true
        State.scheduler:setPaused(true, reason or 'shutdown', nowMs)
        State.pendingBroadcast = true
    end
end

local function rebaseAfterLongSchedulerPause(gapMs)
    if gapMs <= lib.Timing.STATE_TTL_MS then return end
    if State.supervisorSeen then
        State.supervisorLastSeenAt = State.supervisorLastSeenAt + gapMs
    end
    for _, heartbeat in pairs(State.moduleHeartbeats) do
        heartbeat.receivedAtMs = (heartbeat.receivedAtMs or 0) + gapMs
    end
    for _, request in pairs(State.scheduler.requests) do
        request.receivedAtMs = (request.receivedAtMs or 0) + gapMs
        request.expiresAtMs = (request.expiresAtMs or 0) + gapMs
    end
    local lease = State.scheduler.lease
    if lease then
        for _, key in ipairs({
            'grantedAtMs', 'renewedAtMs', 'revokedAtMs',
            'revocationDeadlineAtMs', 'recoveryStartedAtMs',
            'recoveryDeadlineAtMs',
        }) do
            if lease[key] then lease[key] = lease[key] + gapMs end
        end
    end
    _lastWatchdogCheck = _lastWatchdogCheck + gapMs
    State.pendingBroadcast = true
end

local function handlePendingReload(nowMs)
    if not _pendingReload then return end
    local reload = _pendingReload
    local lease = State.scheduler.lease
    if lease and lease.holderModule == reload.module then
        State.scheduler:revoke('manual_reload', nowMs)
        return
    end
    if nowMs < reload.stopAtMs then return end
    _pendingReload = nil
    mq.cmdf('/lua stop %s', reload.script)
    State.moduleHeartbeats[reload.module] = nil
    _restartTracker[reload.script] = nil
    mq.cmdf('/lua run %s', reload.script)
end

local function tick()
    local nowMs = lib.getTimeMs()
    local gapMs = nowMs - _lastCoordinatorTickAt
    _lastCoordinatorTickAt = nowMs
    rebaseAfterLongSchedulerPause(gapMs)
    drainActorMessages()
    nowMs = lib.getTimeMs()

    local inGame = lib.isInGame()
    if not inGame then
        _wasInGame = false
        State.worldState.inGame = false
        State.worldState.inCombat = false
        State.worldState.castBusy = false
        State.scheduler:setAvailable(false,
            lib.isZoning() and 'zoning' or 'not_ingame', nowMs)
    else
        if not _wasInGame then
            _wasInGame = true
            for _, heartbeat in pairs(State.moduleHeartbeats) do
                heartbeat.receivedAtMs = nowMs
            end
            State.pendingBroadcast = true
        end
        if (nowMs - _lastWorldStateAt) >= 150 then
            _lastWorldStateAt = nowMs
            updateWorldState()
        end
        State.scheduler:setSelfDead(State.worldState.selfDead, nowMs)
        State.scheduler:setAvailable(not State.worldState.incapacitated,
            State.worldState.incapacitationReason, nowMs)
    end

    if State.supervisorSeen
        and (nowMs - State.supervisorLastSeenAt) > lib.Timing.SUPERVISOR_ABSENCE_MS then
        local parentScript = type(lib.Scripts.UI) == 'table'
            and lib.Scripts.UI[1] or lib.Scripts.UI
        if lib.getLuaScriptStatus(parentScript) == 'EXITED' then
            requestSafeShutdown('parent_exited', nowMs)
        else
            State.supervisorLastSeenAt = nowMs
        end
    end

    State.scheduler:tick(nowMs)
    handleRecoveryTimeout(nowMs)
    handlePendingReload(nowMs)
    checkModuleHealth()
    tickActorsTeam()

    local schedulerState = State.scheduler:getSnapshot()
    if State.supervisorShutdownRequested and schedulerState.lifecycle == 'paused' then
        broadcastState()
        sendSupervisorShutdownAck()
        for _, script in ipairs(lib.Scripts.WORKERS) do
            mq.cmdf('/lua stop %s', script)
        end
        State.running = false
        return
    end

    local epochChanged = schedulerState.epoch ~= State.lastEpochBroadcast
    local due = (nowMs - State.lastBroadcastAt) >= lib.Timing.STATE_BROADCAST_MS
    if State.pendingBroadcast or epochChanged or due then broadcastState() end
end

local function initialize()
    lib.log('info', M.MODULE_NAME,
        'Initializing single-lease Coordinator v%s boot=%s',
        lib.VERSION, State.coordinatorBootId)
    dropbox = actors.register(M.MODULE_NAME, enqueueActorMessage)
    mailboxDropboxes.leaseRequest =
        actors.register(lib.Mailbox.LEASE_REQUEST, enqueueActorMessage)
    mailboxDropboxes.leaseWithdraw =
        actors.register(lib.Mailbox.LEASE_WITHDRAW, enqueueActorMessage)
    mailboxDropboxes.leaseRenew =
        actors.register(lib.Mailbox.LEASE_RENEW, enqueueActorMessage)
    mailboxDropboxes.leaseRelease =
        actors.register(lib.Mailbox.LEASE_RELEASE, enqueueActorMessage)
    mailboxDropboxes.leaseRecovered =
        actors.register(lib.Mailbox.LEASE_RECOVERED, enqueueActorMessage)
    mailboxDropboxes.heartbeat =
        actors.register(lib.Mailbox.HEARTBEAT, enqueueActorMessage)
    mailboxDropboxes.supervisor =
        actors.register(lib.Mailbox.SUPERVISOR, enqueueActorMessage)
    ActorsTeam.init()
    refreshTeamSettings()
    refreshLocalIdentity()
end

local function shutdown()
    ActorsTeam.shutdown()
    for _, actor in pairs(mailboxDropboxes) do
        if actor and actor.unregister then
            pcall(function() actor:unregister() end)
        end
    end
    if dropbox and dropbox.unregister then
        pcall(function() dropbox:unregister() end)
    end
    lib.log('info', M.MODULE_NAME, 'Coordinator stopped')
end

mq.bind('/sk_coord', function(command, argument)
    local nowMs = lib.getTimeMs()
    command = tostring(command or ''):lower()
    if command == 'stop' then
        requestSafeShutdown('coordinator_stop', nowMs)
    elseif command == 'status' then
        local schedulerState = State.scheduler:getSnapshot()
        local lease = schedulerState.lease
        printf('\ay[SK-Coordinator]\ax boot=%s lifecycle=%s epoch=%d preemption=%s',
            State.coordinatorBootId, schedulerState.lifecycle,
            schedulerState.epoch, tostring(schedulerState.preemptionEnabled))
        printf('\ay[SK-Coordinator]\ax lease=%s token=%s request=%s status=%s tier=%s',
            tostring(lease and lease.holderModule or '-'),
            tostring(lease and lease.token or '-'),
            tostring(lease and lease.requestId or '-'),
            tostring(lease and lease.status or '-'),
            tostring(lease and lease.tier or '-'))
        printf('\ay[SK-Coordinator]\ax requests=%d recoveryRequests=%d queue=%d sends=%d failures=%d fault=%s',
            schedulerState.requestCount, schedulerState.recoveryRequestCount,
            #pendingActorMessages, State.stateSendAttempts,
            State.stateSendFailures, tostring(schedulerState.faultReason or '-'))
    elseif command == 'team' then
        local team = ActorsTeam.getSnapshot()
        printf('\ay[SK-Team]\ax enabled=%s ready=%s team=%s leader=%s members=%d peers=%d',
            tostring(team.enabled), tostring(team.ready),
            tostring(team.label or team.teamId or '-'),
            tostring(team.leader or '-'), tonumber(team.memberCount) or 0,
            tonumber(team.peerCount) or 0)
    elseif command == 'reload' then
        local moduleName = tostring(argument or ''):lower()
        local spec = lib.getWorkerSpec(moduleName)
        if not spec then
            printf('\ar[SK-Coord]\ax Unknown module "%s"', moduleName)
            return
        end
        State.scheduler:withdrawWorker(moduleName, 'manual_reload', nowMs)
        _pendingReload = {
            module = moduleName,
            script = spec.script,
            stopAtMs = nowMs + 500,
        }
    else
        printf('\ay[SK-Coord]\ax Usage: /sk_coord status|team|reload <module>|stop')
    end
end)

M.State = State
M.Scheduler = State.scheduler
M.tick = tick
M.processMessage = processMessage
M.broadcastState = broadcastState

initialize()
while State.running do
    tick()
    mq.delay(lib.Timing.COORDINATOR_TICK_MS)
end
shutdown()

return M
