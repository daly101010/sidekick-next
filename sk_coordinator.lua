-- F:/lua/sidekick-next/sk_coordinator.lua
-- Central arbiter for SideKick multi-script system
-- Only this script issues /stopcast and broadcasts authoritative state

local mq = require('mq')
local actors = require('actors')
local lib = require('sidekick-next.sk_lib')
local ActorsTeam = require('sidekick-next.utils.actors_team')

local M = {}

-- Module identity
M.MODULE_NAME = 'coordinator'

local debugLog = require('sidekick-next.utils.debug_log').module('sk_coordinator', 'SK_COORDINATOR')

-- Internal state
local State = {
    -- Monotonic counters
    tickId = 0,
    epoch = 0,

    -- Current active priority tier
    activePriority = lib.Priority.IDLE,

    -- Ownership claims
    castOwner = nil,   -- { module, claimId, priority, epoch, claimedAtMs, ttlMs, action }
    targetOwner = nil, -- { module, claimId, priority, epoch, claimedAtMs, ttlMs, targetId }

    -- Derived state
    castBusy = false,

    -- World snapshot
    worldState = {
        inGame = true,
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
    },

    -- Module heartbeats
    moduleHeartbeats = {}, -- [module] = { sentAtMs, ready, script, mailbox }
    moduleScripts = {},    -- [module] = last known script path (survives a crash)
    knownModules = {},     -- [module] = true once seen locally

    -- Need hints from modules
    moduleNeeds = {}, -- [module] = { priority, needsAction, ttlMs, receivedAtMs }

    -- Timing
    lastBroadcastAt = 0,
    lastEpochChangeAt = 0,
    pendingBroadcast = false,

    -- Running flag
    running = true,

    -- Canonical UI/supervisor liveness. The absence timer starts only after
    -- the first supervisor heartbeat arrives.
    supervisorSeen = false,
    supervisorLastSeenAt = 0,
    supervisorLastSentAt = 0,
    supervisorSessionId = nil,
    supervisorShutdownRequested = false,
    automationPaused = false,
    settingsRevision = 0,
}

-- Actor dropbox
local dropbox = nil
local mailboxDropboxes = {}
local _teamSettingsRevision = nil
local _teamSettings = {}

local function refreshTeamSettings()
    local revision = tonumber(State.settingsRevision) or 0
    if _teamSettingsRevision ~= revision then
        _teamSettings = lib.refreshSettings(revision) or lib.getSettings() or {}
        _teamSettingsRevision = revision
    end
    return _teamSettings
end

local function buildTeamTickSnapshot()
    local modules = {}
    local now = lib.getTimeMs()
    for moduleName in pairs(State.knownModules) do
        local hb = State.moduleHeartbeats[moduleName]
        local need = State.moduleNeeds[moduleName]
        local heartbeatAge = hb and (now - (hb.receivedAtMs or 0)) or 0
        modules[moduleName] = {
            ready = hb ~= nil and hb.ready ~= false and heartbeatAge <= lib.Timing.MODULE_CRASH_MS,
            needsAction = need ~= nil and need.needsAction == true
                and (now - (need.receivedAtMs or 0)) <= (need.ttlMs or 250),
            priority = need and tonumber(need.priority) or nil,
            reason = need and tostring(need.reason or '') or '',
        }
    end

    local action = nil
    if State.castOwner then
        local hb = State.moduleHeartbeats[State.castOwner.module]
        local lifecycle = hb and hb.action or nil
        local requested = State.castOwner.action or {}
        action = {
            module = tostring(State.castOwner.module or ''),
            claimId = tostring(State.castOwner.claimId or ''),
            kind = tostring((lifecycle and lifecycle.kind) or requested.kind or ''),
            name = tostring((lifecycle and lifecycle.name)
                or requested.spellName or requested.itemName or requested.discName or requested.name or ''),
            phase = tostring((lifecycle and lifecycle.phase) or 'claimed'),
            targetId = tonumber((lifecycle and lifecycle.targetId) or requested.targetId) or 0,
        }
    end

    local settings = refreshTeamSettings()
    return {
        zone = lib.getZone(),
        class = tostring(lib.safeTLO(function() return mq.TLO.Me.Class.ShortName() end, '') or ''),
        role = tostring(settings.CombatMode or 'off'),
        inGame = State.worldState.inGame ~= false,
        inCombat = State.worldState.inCombat == true,
        dead = State.worldState.selfDead == true,
        incapacitated = State.worldState.incapacitated == true,
        automationPaused = State.automationPaused == true,
        activePriority = State.activePriority,
        action = action,
        modules = modules,
    }
end

local function tickActorsTeam()
    ActorsTeam.tick(buildTeamTickSnapshot(), refreshTeamSettings())
end

local function parseSenderScript(senderMailbox)
    if type(senderMailbox) ~= 'string' then return nil end
    -- Mailbox format is: lua:sidekick-next/sk_buffs:buffs
    -- We want to extract: sidekick-next/sk_buffs (the script path between first and second colon)
    local scriptPath = senderMailbox:match('^[^:]+:([^:]+):')
    if scriptPath then
        return scriptPath
    end
    -- Fallback to old behavior
    return senderMailbox:match('^(.-):')
end

local function isLocalModuleMessage(content)
    if type(content) ~= 'table' then return false end
    local ownerName = tostring(content.ownerName or '')
    local ownerServer = tostring(content.ownerServer or '')
    -- Module-control mailboxes are shared across all running characters.
    -- Untagged legacy messages cannot be safely attributed, so reject them
    -- rather than letting another character's module state leak into this
    -- coordinator's dashboard or priority decisions.
    if ownerName == '' or ownerServer == '' then
        return false
    end
    if ownerName ~= '' and ownerName ~= tostring(lib.getMyName() or '') then
        return false
    end
    if ownerServer ~= '' and ownerServer ~= tostring(lib.getMyServer() or '') then
        return false
    end
    return true
end

-------------------------------------------------------------------------------
-- World State Evaluation
-------------------------------------------------------------------------------

local function updateWorldState()
    State.worldState.inGame = true
    local me = mq.TLO.Me
    if not (me and me()) then
        State.worldState.selfDead = true
        State.worldState.incapacitated = false
        State.worldState.incapacitationReason = nil
        State.worldState.stunned = false
        State.worldState.mezzed = false
        State.worldState.silenced = false
        State.worldState.feared = false
        State.castBusy = false
        return
    end

    State.worldState.selfDead = lib.isSelfDeadOrHovering and lib.isSelfDeadOrHovering() or false
    State.worldState.inCombat = lib.inCombat()
    State.worldState.myHpPct = lib.safeNum(function() return me.PctHPs() end, 100)
    State.worldState.myManaPct = lib.safeNum(function() return me.PctMana() end, 100)
    State.worldState.mainAssistId = lib.getMainAssistId()

    local control = lib.getIncapacitationState()
    State.worldState.incapacitated = control.incapacitated
    State.worldState.incapacitationReason = control.reason
    State.worldState.stunned = control.stunned
    State.worldState.mezzed = control.mezzed
    State.worldState.silenced = control.silenced
    State.worldState.feared = control.feared

    -- Count dead group members
    local deadCount = 0
    local groupCount = lib.getGroupCount()
    for i = 1, groupCount do
        local member = mq.TLO.Group.Member(i)
        if member and member() then
            local dead = lib.safeTLO(function() return member.Dead() end, false)
            if dead then deadCount = deadCount + 1 end
        end
    end
    State.worldState.deadCount = deadCount

    -- Check if anyone needs healing (simple threshold check)
    local needsHealing = false
    for i = 0, groupCount do
        local member = mq.TLO.Group.Member(i)
        if member and member() then
            local hp = lib.safeNum(function() return member.PctHPs() end, 100)
            if hp < 80 then
                needsHealing = true
                break
            end
        end
    end
    State.worldState.groupNeedsHealing = needsHealing

    -- Check for emergency (any group member critical)
    local emergency = false
    for i = 0, groupCount do
        local member = mq.TLO.Group.Member(i)
        if member and member() then
            local hp = lib.safeNum(function() return member.PctHPs() end, 100)
            if hp < 25 then
                emergency = true
                break
            end
        end
    end
    State.worldState.emergencyActive = emergency

    -- Update cast busy
    State.castBusy = lib.isCasting()
end

local function hasFreshHeartbeat(moduleName)
    local hb = State.moduleHeartbeats[moduleName]
    if not hb or not hb.receivedAtMs then return false end
    return (lib.getTimeMs() - hb.receivedAtMs) <= lib.Timing.MODULE_CRASH_MS
end

-------------------------------------------------------------------------------
-- Priority Evaluation
-------------------------------------------------------------------------------

local function computeActivePriority()
    local ws = State.worldState
    local now = lib.getTimeMs()

    if ws.selfDead then
        return lib.Priority.IDLE
    end

    -- Fresh, heartbeating module need hints are the only source of work.
    -- World-state fields are diagnostic/validation data; they must not select
    -- a priority for a category that is disabled or unavailable on this class.
    local bestNeed = nil
    local validNeeds = {}
    for moduleName, need in pairs(State.moduleNeeds) do
        if need and need.needsAction == true then
            local ttl = need.ttlMs or 250
            local receivedAt = need.receivedAtMs or 0
            local age = now - receivedAt
            local isValid = age <= ttl and hasFreshHeartbeat(moduleName)
            table.insert(validNeeds, string.format('%s:p%d:%s(age=%dms,ttl=%dms)',
                moduleName, need.priority or -1, isValid and 'VALID' or 'EXPIRED',
                age, ttl))
            if isValid then
                if bestNeed == nil or need.priority < bestNeed then
                    bestNeed = need.priority
                end
            end
        end
    end
    if #validNeeds > 0 then
        debugLog('computePriority: needs=[%s] bestNeed=%s',
            table.concat(validNeeds, ', '), tostring(bestNeed))
    end
    if bestNeed ~= nil then
        return bestNeed
    end

    -- Nothing actionable
    return lib.Priority.IDLE
end

-------------------------------------------------------------------------------
-- Ownership Management
-------------------------------------------------------------------------------

local function clearOwner(ownerType)
    if ownerType == 'cast' then
        State.castOwner = nil
    elseif ownerType == 'target' then
        State.targetOwner = nil
    end
end

local function isOwnerExpired(owner)
    if not owner then return true end
    local now = lib.getTimeMs()
    local leaseStartedAtMs = owner.castStartedAtMs or owner.claimedAtMs
    return (now - leaseStartedAtMs) > owner.ttlMs
end

local function clearMatchingOwners(owner, reason)
    if not owner then return false end
    local changed = false
    local moduleName = owner.module
    local claimId = owner.claimId
    if State.castOwner and State.castOwner.module == moduleName and State.castOwner.claimId == claimId then
        State.castOwner = nil
        changed = true
    end
    if State.targetOwner and State.targetOwner.module == moduleName and State.targetOwner.claimId == claimId then
        State.targetOwner = nil
        changed = true
    end
    if changed then
        debugLog('REVOKE: module=%s claimId=%s reason=%s',
            tostring(moduleName), tostring(claimId), tostring(reason or 'unknown'))
    end
    return changed
end

local function expireOwners()
    local changed = false
    -- Need hints describe scheduling demand; they never extend ownership.
    -- Snapshot cast ownership defensively against synchronous state changes.
    local castOwner = State.castOwner
    if castOwner then
        if castOwner.expectsCastStart and not castOwner.castStartedAtMs and State.castBusy then
            -- Move from the short acquisition window to the normal operation
            -- lease only after an actual cast bar is observed.
            castOwner.castStartedAtMs = lib.getTimeMs()
            State.pendingBroadcast = true
            debugLog('CAST STARTED: module=%s claimId=%s', castOwner.module, castOwner.claimId)
        elseif castOwner.expectsCastStart and not castOwner.castStartedAtMs
            and lib.getTimeMs() > (castOwner.castStartDeadlineMs or 0) then
            lib.log('warn', M.MODULE_NAME, 'Revoking cast claim that did not start: %s', castOwner.module)
            changed = clearMatchingOwners(castOwner, 'cast_start_timeout') or changed
        elseif isOwnerExpired(castOwner) and not State.castBusy then
            lib.log('debug', M.MODULE_NAME, 'Cast owner expired: %s', castOwner.module)
            changed = clearMatchingOwners(castOwner, 'claim_ttl_expired') or changed
        elseif isOwnerExpired(castOwner) and State.castBusy then
            debugLog('EXPIRE: Cast owner %s expired but castBusy=true, keeping', castOwner.module)
        end
    end
    -- Target ownership uses the same bounded lease.
    -- Preserve matching target ownership only while its cast is active.
    if State.targetOwner and isOwnerExpired(State.targetOwner) then
        local castingModuleOwns = State.castBusy and State.castOwner
            and State.castOwner.module == State.targetOwner.module
        if not castingModuleOwns then
            lib.log('debug', M.MODULE_NAME, 'Target owner expired: %s', State.targetOwner.module)
            debugLog('EXPIRE: Target owner %s expired (castBusy=%s)',
                State.targetOwner.module, tostring(State.castBusy))
            State.targetOwner = nil
            changed = true
        elseif castingModuleOwns then
            debugLog('EXPIRE: Target owner %s expired but same module is casting, keeping', State.targetOwner.module)
        end
    end
    return changed
end

local function clearOwnersForSelfDead()
    if not State.worldState.selfDead then return false end
    local changed = false
    if State.castOwner then
        debugLog('SELF_DEAD: Clearing cast owner %s', tostring(State.castOwner.module))
        State.castOwner = nil
        changed = true
    end
    if State.targetOwner then
        debugLog('SELF_DEAD: Clearing target owner %s', tostring(State.targetOwner.module))
        State.targetOwner = nil
        changed = true
    end
    State.castBusy = false
    return changed
end

local function clearOwnersForIncapacitation()
    if not State.worldState.incapacitated then return false end
    local changed = false
    local reason = State.worldState.incapacitationReason or 'incapacitated'
    if State.castOwner then
        changed = clearMatchingOwners(State.castOwner, reason) or changed
    end
    if State.targetOwner then
        debugLog('REVOKE: target owner=%s reason=%s', tostring(State.targetOwner.module), tostring(reason))
        State.targetOwner = nil
        changed = true
    end
    return changed
end

local function revokeOnPriorityChange(newPriority)
    local changed = false

    -- If not casting, clear both owners immediately
    if not State.castBusy then
        if State.castOwner and State.castOwner.priority ~= newPriority and State.castOwner.priority ~= lib.Priority.EMERGENCY then
            lib.log('debug', M.MODULE_NAME, 'Revoking cast owner on priority change: %s', State.castOwner.module)
            debugLog('REVOKE: Cast owner %s revoked on priority change (old=%d, new=%d, castBusy=%s)',
                State.castOwner.module, State.castOwner.priority, newPriority, tostring(State.castBusy))
            State.castOwner = nil
            changed = true
        end
    else
        if State.castOwner and State.castOwner.priority ~= newPriority then
            debugLog('REVOKE: Cast owner %s kept despite priority change (castBusy=true)', State.castOwner.module)
        end
    end

    -- Always clear target owner on priority change (except emergency)
    if State.targetOwner and State.targetOwner.priority ~= newPriority and State.targetOwner.priority ~= lib.Priority.EMERGENCY then
        lib.log('debug', M.MODULE_NAME, 'Revoking target owner on priority change: %s', State.targetOwner.module)
        debugLog('REVOKE: Target owner %s revoked on priority change', State.targetOwner.module)
        State.targetOwner = nil
        changed = true
    end

    return changed
end

-------------------------------------------------------------------------------
-- Claim Processing
-------------------------------------------------------------------------------

local function canGrantResource(owner, claimPriority)
    -- Resource is available if:
    -- 1. No current owner
    -- 2. Current owner expired
    -- 3. Requester has higher priority (lower number)
    if not owner then return true end
    if State.castBusy and State.castOwner
        and owner.module == State.castOwner.module
        and owner.claimId == State.castOwner.claimId then
        return false
    end
    if isOwnerExpired(owner) then return true end
    if claimPriority < owner.priority then return true end
    return false
end

local function processClaim(content, sender)
    local now = lib.getTimeMs()
    debugLog('processClaim: module=%s type=%s priority=%d epochSeen=%d currentEpoch=%d activePriority=%d',
        content.module, content.type or 'nil', content.priority, content.epochSeen, State.epoch, State.activePriority)

    if State.worldState.selfDead or State.worldState.incapacitated or State.worldState.inGame == false then
        debugLog('CLAIM REJECTED: local character unavailable (%s)',
            tostring(State.worldState.incapacitationReason
                or (State.worldState.selfDead and 'self_dead') or 'not_ingame'))
        return false
    end

    -- Validate epochSeen (allow small drift from async message delivery)
    -- In multi-module systems, other modules' claims/releases increment epoch between
    -- state broadcasts, causing valid claims to arrive with slightly stale epochs.
    -- The priority check and resource availability checks below are the real guards
    -- against genuinely stale claims.
    local epochDrift = State.epoch - content.epochSeen
    if epochDrift > 10 then
        lib.log('debug', M.MODULE_NAME, 'Claim rejected (very stale epoch): %s saw %d, current %d',
            content.module, content.epochSeen, State.epoch)
        debugLog('CLAIM REJECTED: very stale epoch (saw=%d, current=%d, drift=%d)', content.epochSeen, State.epoch, epochDrift)
        return false
    elseif epochDrift > 0 then
        debugLog('CLAIM epoch drift: module=%s saw=%d current=%d drift=%d (allowed)',
            content.module, content.epochSeen, State.epoch, epochDrift)
    end

    -- Validate priority
    if content.priority ~= State.activePriority and content.priority ~= lib.Priority.EMERGENCY then
        lib.log('debug', M.MODULE_NAME, 'Claim rejected (wrong priority): %s has %d, active %d',
            content.module, content.priority, State.activePriority)
        debugLog('CLAIM REJECTED: wrong priority (has=%d, active=%d)', content.priority, State.activePriority)
        return false
    end

    -- Determine what resources are requested
    local wantsTarget = false
    local wantsCast = false

    if content.type == lib.ClaimType.ACTION then
        wantsTarget = true
        wantsCast = true
    elseif content.type == lib.ClaimType.TARGET then
        wantsTarget = true
    elseif content.type == lib.ClaimType.CAST then
        wantsCast = true
    else
        -- Default to action
        wantsTarget = true
        wantsCast = true
    end

    -- Check if resources are grantable. A cast with no castOwner is
    -- external/manual; workers must wait for that cast bar to clear.
    if wantsCast and State.castBusy and not State.castOwner then
        debugLog('CLAIM REJECTED: unowned/manual cast is active')
        return false
    end
    if wantsTarget and not canGrantResource(State.targetOwner, content.priority) then
        lib.log('debug', M.MODULE_NAME, 'Claim rejected (target not available): %s', content.module)
        debugLog('CLAIM REJECTED: target not available (owner=%s)', State.targetOwner and State.targetOwner.module or 'nil')
        return false
    end
    if wantsCast and not canGrantResource(State.castOwner, content.priority) then
        lib.log('debug', M.MODULE_NAME, 'Claim rejected (cast not available): %s', content.module)
        debugLog('CLAIM REJECTED: cast not available (owner=%s)', State.castOwner and State.castOwner.module or 'nil')
        return false
    end
    debugLog('processClaim: Resources available, granting claim')

    -- Grant the claim
    State.epoch = State.epoch + 1

    local claimData = {
        module = content.module,
        claimId = content.claimId,
        priority = content.priority,
        epoch = State.epoch,
        claimedAtMs = now,
        ttlMs = content.ttlMs or lib.Timing.CLAIM_DEFAULT_TTL_MS,
        expectsCastStart = content.expectsCastStart == true,
        castStartDeadlineMs = content.expectsCastStart == true
            and (now + math.max(100,
                tonumber(content.castStartTimeoutMs) or lib.Timing.CLAIM_CAST_START_MS))
            or nil,
        castStartedAtMs = nil,
        action = content.action,
    }

    if wantsTarget then
        State.targetOwner = {
            module = content.module,
            claimId = content.claimId,
            priority = content.priority,
            epoch = State.epoch,
            claimedAtMs = now,
            ttlMs = content.ttlMs or lib.Timing.TARGET_CLAIM_TTL_MS,
            targetId = content.action and content.action.targetId or nil,
        }
    end

    if wantsCast then
        State.castOwner = claimData
    end

    lib.log('info', M.MODULE_NAME, 'Claim granted: %s (type=%s, claimId=%s, epoch=%d)',
        content.module, content.type or 'action', content.claimId, State.epoch)
    debugLog('CLAIM GRANTED: module=%s type=%s claimId=%s epoch=%d ttlMs=%d',
        content.module, content.type or 'action', content.claimId, State.epoch, content.ttlMs or 0)

    State.pendingBroadcast = true
    return true
end

-------------------------------------------------------------------------------
-- Release Processing
-------------------------------------------------------------------------------

local function processRelease(content)
    local changed = false

    -- Only release if the claim matches current owner
    if content.type == 'cast' or content.type == 'action' then
        if State.castOwner and State.castOwner.module == content.module and State.castOwner.claimId == content.claimId then
            lib.log('debug', M.MODULE_NAME, 'Release cast: %s', content.module)
            State.castOwner = nil
            changed = true
        end
    end

    if content.type == 'target' or content.type == 'action' then
        if State.targetOwner and State.targetOwner.module == content.module and State.targetOwner.claimId == content.claimId then
            lib.log('debug', M.MODULE_NAME, 'Release target: %s', content.module)
            State.targetOwner = nil
            changed = true
        end
    end

    if changed then
        State.epoch = State.epoch + 1
        State.pendingBroadcast = true
    end

    return changed
end

-------------------------------------------------------------------------------
-- Interrupt Processing
-------------------------------------------------------------------------------

local function processInterrupt(content)
    -- Only interrupt if there's an active cast
    if not State.castBusy then return false end
    if not State.castOwner then return false end

    local remainingSec = lib.getCastTimeRemaining()
    local threshold = lib.InterruptThreshold[content.requestingPriority] or 999

    -- Allow cast owner to request self-cancel (ducking or abort)
    if content.requestingModule == State.castOwner.module then
        lib.log('info', M.MODULE_NAME, 'Owner interrupt: %s (%s)', content.requestingModule, tostring(content.reason or 'owner_cancel'))
        debugLog('STOPCAST: Owner self-cancel by %s reason=%s', content.requestingModule, tostring(content.reason or 'owner_cancel'))
        mq.cmd('/stopcast')
        State.castOwner = nil
        State.epoch = State.epoch + 1
        State.pendingBroadcast = true
        return true
    end

    -- Higher priority requesting interrupt
    if content.requestingPriority < State.castOwner.priority then
        -- Emergency always interrupts
        if content.requestingPriority == lib.Priority.EMERGENCY then
            lib.log('info', M.MODULE_NAME, 'Emergency interrupt requested by %s', content.requestingModule)
            debugLog('STOPCAST: Emergency interrupt by %s', content.requestingModule)
            mq.cmd('/stopcast')
            State.castOwner = nil
            State.epoch = State.epoch + 1
            State.pendingBroadcast = true
            return true
        end

        -- Check threshold
        if remainingSec > threshold then
            lib.log('info', M.MODULE_NAME, 'Interrupt: %s interrupting %s (remaining=%.1fs, threshold=%.1fs)',
                content.requestingModule, State.castOwner.module, remainingSec, threshold)
            debugLog('STOPCAST: Priority interrupt by %s of %s (remaining=%.1fs, threshold=%.1fs)',
                content.requestingModule, State.castOwner.module, remainingSec, threshold)
            mq.cmd('/stopcast')
            State.castOwner = nil
            State.epoch = State.epoch + 1
            State.pendingBroadcast = true
            return true
        else
            lib.log('debug', M.MODULE_NAME, 'Interrupt delayed: letting cast finish (remaining=%.1fs <= threshold=%.1fs)',
                remainingSec, threshold)
            debugLog('STOPCAST delayed: remaining=%.1fs <= threshold=%.1fs', remainingSec, threshold)
        end
    end

    -- Lower priority invalidation (not implemented in v1)
    -- Would require validating the invalidation reason against current world state

    return false
end

-------------------------------------------------------------------------------
-- State Broadcast
-------------------------------------------------------------------------------

local function buildStatePayload()
    -- Build lightweight module diagnostics for UI consumption
    local now = lib.getTimeMs()
    local moduleDiag = {}
    local names = {}
    for moduleName in pairs(State.knownModules) do names[moduleName] = true end
    for moduleName in pairs(State.moduleHeartbeats) do names[moduleName] = true end
    for moduleName in pairs(State.moduleNeeds) do names[moduleName] = true end

    for moduleName in pairs(names) do
        local hb = State.moduleHeartbeats[moduleName]
        local need = State.moduleNeeds[moduleName]
        local heartbeatAge = hb and (now - (hb.receivedAtMs or 0)) or 0
        local heartbeatFresh = hb ~= nil and heartbeatAge <= lib.Timing.MODULE_CRASH_MS
        local needValid = false
        local needAge = 0
        if need then
            needAge = now - (need.receivedAtMs or 0)
            needValid = need.needsAction == true and needAge <= (need.ttlMs or 250) and heartbeatFresh
        end
        local ready = hb and hb.ready ~= false or false
        moduleDiag[moduleName] = {
            heartbeatAge = heartbeatAge,
            ready = ready,
            stale = not heartbeatFresh,
            needsAction = need and need.needsAction or false,
            needValid = needValid,
            needPriority = need and need.priority or nil,
            needAge = needAge,
            needTtl = need and need.ttlMs or 0,
            reason = need and need.reason or nil,
            action = hb and hb.action or nil,
        }
    end

    return {
        tickId = State.tickId,
        epoch = State.epoch,
        ownerName = lib.getMyName(),
        ownerServer = lib.getMyServer(),
        sentAtMs = lib.getTimeMs(),
        ttlMs = lib.Timing.STATE_TTL_MS,
        activePriority = State.activePriority,
        castOwner = State.castOwner,
        targetOwner = State.targetOwner,
        castBusy = State.castBusy,
        worldState = State.worldState,
        moduleDiag = moduleDiag,
        team = ActorsTeam.getSnapshot(),
        automationPaused = State.automationPaused == true,
        settingsRevision = tonumber(State.settingsRevision) or 0,
    }
end

local function broadcastState()
    if not dropbox then return end

    State.tickId = State.tickId + 1
    local payload = buildStatePayload()

    local sent = {}
    local heartbeatCount = 0
    for _ in pairs(State.moduleHeartbeats) do heartbeatCount = heartbeatCount + 1 end
    debugLog('broadcastState: tickId=%d epoch=%d priority=%d heartbeatCount=%d',
        State.tickId, State.epoch, State.activePriority, heartbeatCount)

    local function sendToScript(scriptName)
        if not scriptName or scriptName == '' then return end
        if sent[scriptName] then return end
        sent[scriptName] = true
        debugLog('broadcastState: Sending to script=%s', scriptName)
        pcall(function()
            dropbox:send({ mailbox = lib.Mailbox.STATE, script = scriptName }, payload)
        end)
    end

    local function sendToMailbox(mailbox)
        if not mailbox or mailbox == '' then return end
        if sent[mailbox] then return end
        sent[mailbox] = true
        pcall(function()
            dropbox:send({ mailbox = mailbox, absolute_mailbox = true }, payload)
        end)
    end

    for _, hb in pairs(State.moduleHeartbeats) do
        if hb then
            if hb.script then
                sendToScript(hb.script)
            elseif hb.mailbox then
                sendToMailbox(hb.mailbox)
            end
        end
    end

    if lib.Scripts and lib.Scripts.UI then
        if type(lib.Scripts.UI) == 'table' then
            for _, scriptName in ipairs(lib.Scripts.UI) do
                sendToScript(scriptName)
            end
        else
            sendToScript(lib.Scripts.UI)
        end
    end

    State.lastBroadcastAt = lib.getTimeMs()
    State.pendingBroadcast = false
end

-- Watchdog state (declared early so onModuleHeartbeatReceived can reference it)
local _restartTracker = {}  -- { [script] = { count, lastAttemptMs } }
local _lastWatchdogCheck = 0
local _pendingReload = nil  -- { module, script, restartAtMs } — deferred reload from /sk_coord reload
local _wasInGame = true

--- Reset restart counter for a module when it sends a fresh heartbeat
--- (called from onMessage heartbeat handler)
local function onModuleHeartbeatReceived(scriptPath)
    local tracker = scriptPath and _restartTracker[scriptPath] or nil
    if not tracker then return end
    local now = lib.getTimeMs()
    tracker.gaveUp = false
    tracker.stableSinceMs = tracker.stableSinceMs or now
    if (now - tracker.stableSinceMs) >= lib.Timing.RESTART_STABLE_MS then
        tracker.count = 0
        tracker.stableSinceMs = now
    end
end

-------------------------------------------------------------------------------
-- Message Handlers
-------------------------------------------------------------------------------

local function onMessage(message)
    local content = message()
    if type(content) ~= 'table' then return end

    local sender = message.sender or {}
    local mailbox = sender.mailbox or ''
    local senderScript = parseSenderScript(mailbox)
    local msgType = content.msgType

    if not msgType then
        if mailbox == lib.Mailbox.CLAIM then
            msgType = 'claim'
        elseif mailbox == lib.Mailbox.RELEASE then
            msgType = 'release'
        elseif mailbox == lib.Mailbox.INTERRUPT then
            msgType = 'interrupt'
        elseif mailbox == lib.Mailbox.HEARTBEAT then
            msgType = 'heartbeat'
        elseif mailbox == lib.Mailbox.NEED then
            msgType = 'need'
        end
    end

    -- Route by mailbox
    if msgType == 'supervisor_heartbeat' then
        if not isLocalModuleMessage(content) then return end
        local sentAtMs = tonumber(content.sentAtMs) or 0
        -- Actors delivery is asynchronous. Never let a delayed heartbeat from
        -- an older SideKick session replace the current supervisor session.
        if sentAtMs < State.supervisorLastSentAt then return end
        State.supervisorSeen = true
        State.supervisorLastSeenAt = lib.getTimeMs()
        State.supervisorLastSentAt = sentAtMs
        State.supervisorSessionId = content.sessionId
        local nextPaused = content.automationPaused == true
        local nextRevision = tonumber(content.settingsRevision) or 0
        if State.automationPaused ~= nextPaused or State.settingsRevision ~= nextRevision then
            State.automationPaused = nextPaused
            State.settingsRevision = nextRevision
            State.pendingBroadcast = true
        end
    elseif msgType == 'supervisor_shutdown' then
        if not isLocalModuleMessage(content) then return end
        -- Only the currently heartbeating parent session may request a
        -- destructive shutdown. Delayed cleanup from an older run is stale.
        if not State.supervisorSeen
            or not content.sessionId
            or content.sessionId ~= State.supervisorSessionId then
            debugLog('SUPERVISOR: ignored stale shutdown for session=%s (current=%s)',
                tostring(content.sessionId), tostring(State.supervisorSessionId))
            return
        end
        State.supervisorShutdownRequested = true
    elseif msgType == 'claim' then
        if not isLocalModuleMessage(content) then return end
        processClaim(content, sender)
    elseif msgType == 'release' then
        if not isLocalModuleMessage(content) then return end
        processRelease(content)
    elseif msgType == 'interrupt' then
        if not isLocalModuleMessage(content) then return end
        processInterrupt(content)
    elseif msgType == 'heartbeat' then
        if not isLocalModuleMessage(content) then return end
        -- Track module heartbeat
        if content.module then
            State.knownModules[content.module] = true
            debugLog('HEARTBEAT received: module=%s script=%s mailbox=%s',
                tostring(content.module), tostring(senderScript), tostring(mailbox))
            State.moduleHeartbeats[content.module] = {
                receivedAtMs = lib.getTimeMs(),  -- Use coordinator-local time for staleness (not sender time)
                sentAtMs = content.sentAtMs,      -- Keep sender time for diagnostics only
                ready = content.ready ~= false,
                action = type(content.action) == 'table' and content.action or nil,
                script = senderScript,
                mailbox = mailbox,
            }
            if senderScript and senderScript ~= '' then
                State.moduleScripts[content.module] = senderScript
            end
            -- Reset restart counter — module is alive
            onModuleHeartbeatReceived(senderScript)
        end
    elseif msgType == 'need' then
        if not isLocalModuleMessage(content) then return end
        -- Track module need hints
        if content.module then
            State.knownModules[content.module] = true
            State.moduleNeeds[content.module] = {
                priority = content.priority,
                needsAction = content.needsAction,
                ttlMs = content.ttlMs or 250,
                receivedAtMs = lib.getTimeMs(),
                reason = content.reason,
            }
            debugLog('NEED received: module=%s priority=%d needsAction=%s ttlMs=%d reason=%s',
                tostring(content.module), tonumber(content.priority) or -1,
                tostring(content.needsAction), tonumber(content.ttlMs) or 250,
                tostring(content.reason or ''))
        end
    end
end

-------------------------------------------------------------------------------
-- Module Crash Watchdog
-------------------------------------------------------------------------------

--- Revoke any claims owned by a crashed module
local function revokeCrashedModuleClaims(moduleName)
    local changed = false
    if State.castOwner and State.castOwner.module == moduleName then
        debugLog('WATCHDOG: Revoking cast claim from crashed module %s', moduleName)
        State.castOwner = nil
        changed = true
    end
    if State.targetOwner and State.targetOwner.module == moduleName then
        debugLog('WATCHDOG: Revoking target claim from crashed module %s', moduleName)
        State.targetOwner = nil
        changed = true
    end
    if changed then
        State.epoch = State.epoch + 1
        State.pendingBroadcast = true
    end
end

--- Attempt to restart a crashed module script
local function attemptRestart(moduleName, scriptPath)
    if not scriptPath or scriptPath == '' then
        debugLog('WATCHDOG: Cannot restart %s — no script path', moduleName)
        return false
    end

    local now = lib.getTimeMs()
    local tracker = _restartTracker[scriptPath] or { count = 0, lastAttemptMs = 0, stableSinceMs = nil }

    -- Enforce max restarts
    if tracker.count >= lib.MAX_MODULE_RESTARTS then
        tracker.gaveUp = true
        debugLog('WATCHDOG: %s exceeded max restarts (%d/%d), giving up',
            scriptPath, tracker.count, lib.MAX_MODULE_RESTARTS)
        return false
    end

    -- Enforce cooldown
    if (now - tracker.lastAttemptMs) < lib.Timing.RESTART_COOLDOWN_MS then
        return false  -- Still in cooldown, silently skip
    end

    tracker.count = tracker.count + 1
    tracker.lastAttemptMs = now
    tracker.stableSinceMs = nil
    _restartTracker[scriptPath] = tracker

    debugLog('WATCHDOG: Restarting %s (attempt %d/%d)',
        scriptPath, tracker.count, lib.MAX_MODULE_RESTARTS)
    -- print(string.format(
    --     '\ay[SK-Watchdog]\ax Restarting crashed module: %s (attempt %d/%d)',
    --     scriptPath, tracker.count, lib.MAX_MODULE_RESTARTS))

    mq.cmdf('/lua run %s', scriptPath)
    return true
end

--- Check all module heartbeats for staleness
local function checkModuleHealth()
    local now = lib.getTimeMs()

    -- Throttle checks
    if (now - _lastWatchdogCheck) < lib.Timing.WATCHDOG_CHECK_MS then return end
    _lastWatchdogCheck = now

    -- Collect stale modules first (don't mutate table during pairs iteration)
    local staleModules = {}
    for moduleName, hb in pairs(State.moduleHeartbeats) do
        if hb and hb.receivedAtMs then
            local age = now - hb.receivedAtMs
            if age > lib.Timing.MODULE_CRASH_MS then
                table.insert(staleModules, { name = moduleName, hb = hb, age = age })
            end
        end
    end

    -- Process stale modules
    for _, entry in ipairs(staleModules) do
        debugLog('WATCHDOG: Module %s heartbeat stale (%dms), presumed crashed',
            entry.name, entry.age)
        -- print(string.format(
        --     '\ar[SK-Watchdog]\ax Module "%s" has not sent a heartbeat in %.1fs — presumed crashed',
        --     entry.name, entry.age / 1000))

        -- Revoke any claims this module held
        revokeCrashedModuleClaims(entry.name)

        -- Attempt restart (logs user-facing message on max restarts too)
        local scriptPath = entry.hb.script
        local processAlive = scriptPath and lib.isLuaScriptRunning(scriptPath)
        if not processAlive and not attemptRestart(entry.name, scriptPath) and scriptPath then
            local tracker = _restartTracker[scriptPath]
            if tracker and tracker.count >= lib.MAX_MODULE_RESTARTS then
                -- print(string.format(
                --     '\ar[SK-Watchdog]\ax Module "%s" exceeded max restarts (%d) — giving up',
                --     entry.name, lib.MAX_MODULE_RESTARTS))
            end
        end

        if processAlive then
            -- Actors delivery can be delayed across zoning. MQ2Lua's process
            -- table is authoritative, so keep a confirmed-live worker and
            -- refresh its local watchdog timestamp instead of duplicating it.
            entry.hb.receivedAtMs = now
            debugLog('WATCHDOG: %s heartbeat stale but Lua process is %s; keeping it',
                scriptPath, lib.getLuaScriptStatus(scriptPath))
        else
            -- Remove a genuinely stale heartbeat while restart is pending.
            State.moduleHeartbeats[entry.name] = nil
        end
    end

    -- A script that dies before sending its first post-restart heartbeat has
    -- no heartbeat entry to become stale again. Retain its last script path
    -- and retry after the cooldown until the session limit is reached.
    for moduleName in pairs(State.knownModules) do
        if not State.moduleHeartbeats[moduleName] then
            local scriptPath = State.moduleScripts[moduleName]
            local tracker = scriptPath and _restartTracker[scriptPath] or nil
            if tracker and not tracker.gaveUp
                and (now - tracker.lastAttemptMs) >= lib.Timing.RESTART_COOLDOWN_MS
                and not lib.isLuaScriptRunning(scriptPath) then
                attemptRestart(moduleName, scriptPath)
            end
        end
    end
end

-------------------------------------------------------------------------------
-- Main Loop
-------------------------------------------------------------------------------

local function initialize()
    lib.log('info', M.MODULE_NAME, 'Initializing Coordinator v%s', lib.VERSION)

    -- Register actor
    dropbox = actors.register(M.MODULE_NAME, onMessage)

    -- Also listen on specific mailboxes
    mailboxDropboxes.claim = actors.register(lib.Mailbox.CLAIM, onMessage)
    mailboxDropboxes.release = actors.register(lib.Mailbox.RELEASE, onMessage)
    mailboxDropboxes.interrupt = actors.register(lib.Mailbox.INTERRUPT, onMessage)
    mailboxDropboxes.heartbeat = actors.register(lib.Mailbox.HEARTBEAT, onMessage)
    mailboxDropboxes.need = actors.register(lib.Mailbox.NEED, onMessage)
    mailboxDropboxes.supervisor = actors.register(lib.Mailbox.SUPERVISOR, onMessage)
    ActorsTeam.init()
    refreshTeamSettings()

    debugLog('Watchdog: crash=%dms, cooldown=%dms, maxRestarts=%d, checkInterval=%dms',
        lib.Timing.MODULE_CRASH_MS, lib.Timing.RESTART_COOLDOWN_MS,
        lib.MAX_MODULE_RESTARTS, lib.Timing.WATCHDOG_CHECK_MS)
    lib.log('info', M.MODULE_NAME, 'Coordinator ready')
end

local _lastStatusLog = 0

local function tick()
    local now = lib.getTimeMs()

    -- An explicit shutdown remains authoritative even if it arrives during a
    -- zone transition. Supervisor.stop() also directly stops the workers.
    if State.supervisorShutdownRequested then
        local reason = 'shutdown requested'
        debugLog('SUPERVISOR: %s; stopping managed workers', reason)
        lib.log('info', M.MODULE_NAME,
            'Stopping managed workers: current supervisor session requested shutdown')
        for _, script in ipairs(lib.Scripts.WORKERS) do
            mq.cmdf('/lua stop %s', script)
        end
        State.running = false
        return
    end

    -- A zone transition is a suspended automation state. Keep the coordinator
    -- and supervisor session alive, clear any in-flight ownership, and publish
    -- an idle snapshot without probing character/world TLOs or restarting
    -- workers whose normal work is also suspended.
    local inGame = lib.isInGame()
    if not inGame then
        _wasInGame = false
        local changed = false
        if State.worldState.inGame ~= false then
            State.worldState.inGame = false
            State.worldState.inCombat = false
            State.worldState.groupNeedsHealing = false
            State.worldState.emergencyActive = false
            State.worldState.deadCount = 0
            State.worldState.incapacitated = false
            State.worldState.incapacitationReason = nil
            State.worldState.stunned = false
            State.worldState.mezzed = false
            State.worldState.silenced = false
            State.worldState.feared = false
            State.castBusy = false
            changed = true
        end
        if State.castOwner or State.targetOwner then
            State.castOwner = nil
            State.targetOwner = nil
            changed = true
        end
        if State.activePriority ~= lib.Priority.IDLE then
            State.activePriority = lib.Priority.IDLE
            changed = true
        end
        if changed then
            State.epoch = State.epoch + 1
            State.pendingBroadcast = true
        end
        tickActorsTeam()
        if State.pendingBroadcast or (now - State.lastBroadcastAt) >= lib.Timing.STATE_BROADCAST_MS then
            broadcastState()
        end
        return
    end

    if not _wasInGame then
        -- All timestamps below were recorded before zoning. Rebase them on
        -- re-entry so the first in-game coordinator tick cannot declare the
        -- still-running supervisor/workers stale before their callbacks run.
        _wasInGame = true
        if State.supervisorSeen then
            State.supervisorLastSeenAt = now
        end
        for _, heartbeat in pairs(State.moduleHeartbeats) do
            if heartbeat then heartbeat.receivedAtMs = now end
        end
        _lastWatchdogCheck = now
        State.pendingBroadcast = true
        debugLog('ZONE: in-game resumed; watchdog timestamps rebased')
    end

    if State.supervisorSeen
        and (now - State.supervisorLastSeenAt) > lib.Timing.SUPERVISOR_ABSENCE_MS then
        local parentScript = type(lib.Scripts.UI) == 'table' and lib.Scripts.UI[1] or lib.Scripts.UI
        local parentStatus = lib.getLuaScriptStatus(parentScript)
        if parentStatus == 'EXITED' then
            debugLog('SUPERVISOR: heartbeat absent and parent exited; stopping managed workers')
            lib.log('warn', M.MODULE_NAME,
                'Stopping managed workers: SideKick parent process is EXITED')
            for _, script in ipairs(lib.Scripts.WORKERS) do
                mq.cmdf('/lua stop %s', script)
            end
            State.running = false
            return
        end

        -- A missed Actors heartbeat must not kill healthy local processes.
        -- Unknown status is also treated non-destructively.
        State.supervisorLastSeenAt = now
        debugLog('SUPERVISOR: heartbeat stale but parent status=%s; keeping workers',
            parentStatus ~= '' and parentStatus or 'UNKNOWN')
    end

    -- Handle pending module reload (deferred from /sk_coord reload bind)
    if _pendingReload and now >= _pendingReload.restartAtMs then
        local pr = _pendingReload
        _pendingReload = nil
        debugLog('RELOAD: Restarting %s (%s)', pr.module, pr.script)
        mq.cmdf('/lua run %s', pr.script)
    end

    -- Periodic status log every 5 seconds
    if (now - _lastStatusLog) >= 5000 then
        _lastStatusLog = now
        debugLog('STATUS: epoch=%d priority=%d castOwner=%s castBusy=%s needCount=%d',
            State.epoch, State.activePriority,
            State.castOwner and State.castOwner.module or 'nil',
            tostring(State.castBusy),
            (function()
                local count = 0
                for _ in pairs(State.moduleNeeds) do count = count + 1 end
                return count
            end)())
    end

    -- Update world state
    updateWorldState()

    if clearOwnersForSelfDead() then
        State.epoch = State.epoch + 1
        State.pendingBroadcast = true
    end

    if clearOwnersForIncapacitation() then
        State.epoch = State.epoch + 1
        State.pendingBroadcast = true
    end

    -- Compute active priority
    local newPriority = computeActivePriority()
    if newPriority ~= State.activePriority then
        debugLog('Priority CHANGE: %d -> %d (castBusy=%s, castOwner=%s)',
            State.activePriority, newPriority,
            tostring(State.castBusy),
            State.castOwner and State.castOwner.module or 'nil')
        lib.log('info', M.MODULE_NAME, 'Priority change: %d -> %d', State.activePriority, newPriority)
        local revoked = revokeOnPriorityChange(newPriority)
        State.activePriority = newPriority
        State.epoch = State.epoch + 1
        State.pendingBroadcast = true
    end

    -- Expire stale owners
    if expireOwners() then
        State.epoch = State.epoch + 1
        State.pendingBroadcast = true
    end

    -- Watchdog: check for crashed modules
    checkModuleHealth()

    -- Cross-character team presence is advanced from the coordinator coroutine.
    -- Its Actor callback only enqueues packets and never reads TLOs or yields.
    tickActorsTeam()

    -- Broadcast state
    local timeSinceBroadcast = now - State.lastBroadcastAt
    local shouldBroadcast = State.pendingBroadcast or (timeSinceBroadcast >= lib.Timing.STATE_BROADCAST_MS)

    -- Coalesce rapid changes (but always broadcast emergency immediately)
    if State.pendingBroadcast and State.activePriority ~= lib.Priority.EMERGENCY then
        local timeSinceEpochChange = now - State.lastEpochChangeAt
        if timeSinceEpochChange < lib.Timing.COALESCE_MS then
            shouldBroadcast = false
        end
    end

    if shouldBroadcast then
        broadcastState()
        if State.pendingBroadcast then
            State.lastEpochChangeAt = now
        end
    end
end

local function mainLoop()
    initialize()

    while State.running do
        tick()
        mq.delay(lib.Timing.COORDINATOR_TICK_MS)
    end

    lib.log('info', M.MODULE_NAME, 'Coordinator stopped')
end

-- Bind to /sk_coord command for stopping
mq.bind('/sk_coord', function(cmd, arg1)
    if cmd == 'stop' then
        State.running = false
        lib.log('info', M.MODULE_NAME, 'Stop requested')
    elseif cmd == 'status' then
        lib.log('info', M.MODULE_NAME, 'epoch=%d, priority=%d, castOwner=%s, targetOwner=%s',
            State.epoch, State.activePriority,
            State.castOwner and State.castOwner.module or 'nil',
            State.targetOwner and State.targetOwner.module or 'nil')
    elseif cmd == 'team' then
        local team = ActorsTeam.getSnapshot()
        printf('\ay[SK-Team]\ax enabled=%s ready=%s mode=%s team=%s leader=%s members=%d peers=%d reason=%s',
            tostring(team.enabled), tostring(team.ready), tostring(team.mode),
            tostring(team.label ~= '' and team.label or team.teamId),
            tostring(team.leader ~= '' and team.leader or '-'),
            tonumber(team.memberCount) or 0, tonumber(team.peerCount) or 0,
            tostring(team.reason or '-'))
    elseif cmd == 'reload' then
        -- Reload a module by name: /sk_coord reload <modulename>
        if not arg1 or arg1 == '' then
            printf('\ay[SK-Coord]\ax Usage: /sk_coord reload <module>')
            printf('\ay[SK-Coord]\ax Known modules:')
            for moduleName, hb in pairs(State.moduleHeartbeats) do
                printf('  \at%s\ax (%s)', moduleName, hb.script or '?')
            end
            return
        end
        -- Find module by partial match
        local targetModule, targetScript
        local searchLower = tostring(arg1):lower()
        for moduleName, hb in pairs(State.moduleHeartbeats) do
            if moduleName:lower():find(searchLower, 1, true) then
                targetModule = moduleName
                targetScript = hb.script
                break
            end
        end
        if targetModule and targetScript then
            printf('\ay[SK-Coord]\ax Reloading %s (%s)', targetModule, targetScript)
            -- Stop the module script
            mq.cmdf('/lua stop %s', targetScript)
            -- Clear heartbeat so it doesn't get marked as crashed during restart
            State.moduleHeartbeats[targetModule] = nil
            -- Clear any claims owned by this module
            if State.castOwner and State.castOwner.module == targetModule then
                State.castOwner = nil
            end
            if State.targetOwner and State.targetOwner.module == targetModule then
                State.targetOwner = nil
            end
            -- Reset restart tracker for this script
            _restartTracker[targetScript] = nil
            -- Schedule restart in tick() (non-blocking — avoids 500ms main loop stall)
            _pendingReload = { module = targetModule, script = targetScript, restartAtMs = lib.getTimeMs() + 500 }
            debugLog('RELOAD: %s (%s) scheduled for restart in 500ms', targetModule, targetScript)
        else
            printf('\ar[SK-Coord]\ax Module "%s" not found. Use /sk_coord reload for list.', tostring(arg1))
        end
    end
end)

-- Export for testing
M.State = State
M.tick = tick
M.processClaim = processClaim
M.processRelease = processRelease
M.broadcastState = broadcastState

-- Run main loop
mainLoop()
ActorsTeam.shutdown()

return M
