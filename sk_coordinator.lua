-- F:/lua/sidekick-next/sk_coordinator.lua
-- Central arbiter for SideKick multi-script system
-- Only this script issues /stopcast and broadcasts authoritative state

local mq = require('mq')
local actors = require('actors')
local lib = require('sidekick-next.sk_lib')

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
        inCombat = false,
        myHpPct = 100,
        myManaPct = 100,
        groupNeedsHealing = false,
        emergencyActive = false,
        deadCount = 0,
        mainAssistId = 0,
    },

    -- Module heartbeats
    moduleHeartbeats = {}, -- [module] = { sentAtMs, ready, script, mailbox }

    -- Need hints from modules
    moduleNeeds = {}, -- [module] = { priority, needsAction, ttlMs, receivedAtMs }

    -- Timing
    lastBroadcastAt = 0,
    lastEpochChangeAt = 0,
    pendingBroadcast = false,

    -- Running flag
    running = true,
}

-- Actor dropbox
local dropbox = nil
local mailboxDropboxes = {}

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

-------------------------------------------------------------------------------
-- World State Evaluation
-------------------------------------------------------------------------------

local function updateWorldState()
    local me = mq.TLO.Me
    if not (me and me()) then return end

    State.worldState.inCombat = lib.inCombat()
    State.worldState.myHpPct = lib.safeNum(function() return me.PctHPs() end, 100)
    State.worldState.myManaPct = lib.safeNum(function() return me.PctMana() end, 100)
    State.worldState.mainAssistId = lib.getMainAssistId()

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

-------------------------------------------------------------------------------
-- Priority Evaluation
-------------------------------------------------------------------------------

local function computeActivePriority()
    local ws = State.worldState
    local now = lib.getTimeMs()

    -- Emergency takes precedence
    if ws.emergencyActive then
        return lib.Priority.EMERGENCY
    end

    -- Check module need hints (authoritative for HI thresholds)
    local bestNeed = nil
    local validNeeds = {}
    for moduleName, need in pairs(State.moduleNeeds) do
        if need and need.needsAction == true then
            local ttl = need.ttlMs or 250
            local receivedAt = need.receivedAtMs or 0
            local age = now - receivedAt
            local isValid = age <= ttl
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

    -- Check for healing needs
    if ws.groupNeedsHealing then
        return lib.Priority.HEALING
    end

    -- Check for dead members needing rez
    if ws.deadCount > 0 then
        return lib.Priority.RESURRECTION
    end

    -- In combat, default to DPS only if a DPS module can actually act.
    -- Without this check, classes with no DPS spells (e.g. clerics) get stuck
    -- at a dead DPS priority where no module requests claims.
    if ws.inCombat then
        local dpsNeed = State.moduleNeeds['dps']
        local dpsCanAct = dpsNeed and dpsNeed.needsAction == true
            and (now - (dpsNeed.receivedAtMs or 0)) <= (dpsNeed.ttlMs or 250)
        if dpsCanAct then
            return lib.Priority.DPS
        end
    end

    -- Check if meditation module needs to act (mana/hp/end regen)
    local medNeed = State.moduleNeeds['meditation']
    if medNeed and medNeed.needsAction == true
        and (now - (medNeed.receivedAtMs or 0)) <= (medNeed.ttlMs or 500) then
        return lib.Priority.MEDITATION
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
    return (now - owner.claimedAtMs) > owner.ttlMs
end

--- Check if a module has a valid (non-expired) need hint requesting action
local function hasValidNeed(moduleName)
    local need = State.moduleNeeds[moduleName]
    if not need or not need.needsAction then return false end
    local ttl = need.ttlMs or 250
    local age = lib.getTimeMs() - (need.receivedAtMs or 0)
    return age <= ttl
end

local function expireOwners()
    local changed = false
    -- Don't expire cast owner while actively casting - let the cast complete
    -- Also don't expire if the owning module still has an active need hint
    -- (covers multi-step operations like gem memorization where castBusy is
    --  still false but the module is actively working toward a cast)
    if State.castOwner then
        local expired = isOwnerExpired(State.castOwner)
        local moduleHasNeed = hasValidNeed(State.castOwner.module)
        if expired and not State.castBusy and not moduleHasNeed then
            lib.log('debug', M.MODULE_NAME, 'Cast owner expired: %s', State.castOwner.module)
            debugLog('EXPIRE: Cast owner %s expired (castBusy=%s, moduleHasNeed=%s)',
                State.castOwner.module, tostring(State.castBusy), tostring(moduleHasNeed))
            State.castOwner = nil
            changed = true
        elseif expired and State.castBusy then
            debugLog('EXPIRE: Cast owner %s expired but castBusy=true, keeping', State.castOwner.module)
        elseif expired and moduleHasNeed then
            debugLog('EXPIRE: Cast owner %s expired but module has active need, keeping', State.castOwner.module)
        end
    end
    -- Target owner: same logic — extend if owning module has valid need OR castBusy
    -- castBusy must protect BOTH cast and target owners to prevent epoch drift that
    -- causes the casting module to lose ownership mid-cast via the epoch check
    if State.targetOwner and isOwnerExpired(State.targetOwner) then
        local moduleHasNeed = hasValidNeed(State.targetOwner.module)
        local castingModuleOwns = State.castBusy and State.castOwner
            and State.castOwner.module == State.targetOwner.module
        if not moduleHasNeed and not castingModuleOwns then
            lib.log('debug', M.MODULE_NAME, 'Target owner expired: %s', State.targetOwner.module)
            debugLog('EXPIRE: Target owner %s expired (castBusy=%s, moduleHasNeed=%s)',
                State.targetOwner.module, tostring(State.castBusy), tostring(moduleHasNeed))
            State.targetOwner = nil
            changed = true
        elseif castingModuleOwns then
            debugLog('EXPIRE: Target owner %s expired but same module is casting, keeping', State.targetOwner.module)
        else
            debugLog('EXPIRE: Target owner %s expired but module has active need, keeping', State.targetOwner.module)
        end
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
    if isOwnerExpired(owner) then return true end
    if claimPriority < owner.priority then return true end
    return false
end

local function processClaim(content, sender)
    local now = lib.getTimeMs()
    debugLog('processClaim: module=%s type=%s priority=%d epochSeen=%d currentEpoch=%d activePriority=%d',
        content.module, content.type or 'nil', content.priority, content.epochSeen, State.epoch, State.activePriority)

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

    -- Check if resources are grantable
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
    for moduleName, hb in pairs(State.moduleHeartbeats) do
        local need = State.moduleNeeds[moduleName]
        local needValid = false
        local needAge = 0
        if need then
            needAge = now - (need.receivedAtMs or 0)
            needValid = need.needsAction == true and needAge <= (need.ttlMs or 250)
        end
        moduleDiag[moduleName] = {
            heartbeatAge = now - (hb.receivedAtMs or 0),
            ready = hb.ready ~= false,
            needsAction = need and need.needsAction or false,
            needValid = needValid,
            needPriority = need and need.priority or nil,
            needAge = needAge,
            needTtl = need and need.ttlMs or 0,
            reason = need and need.reason or nil,
        }
    end

    return {
        tickId = State.tickId,
        epoch = State.epoch,
        sentAtMs = lib.getTimeMs(),
        ttlMs = lib.Timing.STATE_TTL_MS,
        activePriority = State.activePriority,
        castOwner = State.castOwner,
        targetOwner = State.targetOwner,
        castBusy = State.castBusy,
        worldState = State.worldState,
        moduleDiag = moduleDiag,
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

--- Reset restart counter for a module when it sends a fresh heartbeat
--- (called from onMessage heartbeat handler)
local function onModuleHeartbeatReceived(scriptPath)
    if scriptPath and _restartTracker[scriptPath] then
        -- Module is alive again — reset its restart counter
        _restartTracker[scriptPath].count = 0
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
    if msgType == 'claim' then
        processClaim(content, sender)
    elseif msgType == 'release' then
        processRelease(content)
    elseif msgType == 'interrupt' then
        processInterrupt(content)
    elseif msgType == 'heartbeat' then
        -- Track module heartbeat
        if content.module then
            debugLog('HEARTBEAT received: module=%s script=%s mailbox=%s',
                tostring(content.module), tostring(senderScript), tostring(mailbox))
            State.moduleHeartbeats[content.module] = {
                receivedAtMs = lib.getTimeMs(),  -- Use coordinator-local time for staleness (not sender time)
                sentAtMs = content.sentAtMs,      -- Keep sender time for diagnostics only
                ready = content.ready ~= false,
                script = senderScript,
                mailbox = mailbox,
            }
            -- Reset restart counter — module is alive
            onModuleHeartbeatReceived(senderScript)
        end
    elseif msgType == 'need' then
        -- Track module need hints
        if content.module then
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
    local tracker = _restartTracker[scriptPath] or { count = 0, lastAttemptMs = 0 }

    -- Enforce max restarts
    if tracker.count >= lib.MAX_MODULE_RESTARTS then
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
    _restartTracker[scriptPath] = tracker

    debugLog('WATCHDOG: Restarting %s (attempt %d/%d)',
        scriptPath, tracker.count, lib.MAX_MODULE_RESTARTS)
    print(string.format(
        '\ay[SK-Watchdog]\ax Restarting crashed module: %s (attempt %d/%d)',
        scriptPath, tracker.count, lib.MAX_MODULE_RESTARTS))

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
        print(string.format(
            '\ar[SK-Watchdog]\ax Module "%s" has not sent a heartbeat in %.1fs — presumed crashed',
            entry.name, entry.age / 1000))

        -- Revoke any claims this module held
        revokeCrashedModuleClaims(entry.name)

        -- Attempt restart (logs user-facing message on max restarts too)
        local scriptPath = entry.hb.script
        if not attemptRestart(entry.name, scriptPath) and scriptPath then
            local tracker = _restartTracker[scriptPath]
            if tracker and tracker.count >= lib.MAX_MODULE_RESTARTS then
                print(string.format(
                    '\ar[SK-Watchdog]\ax Module "%s" exceeded max restarts (%d) — giving up',
                    entry.name, lib.MAX_MODULE_RESTARTS))
            end
        end

        -- Remove stale heartbeat so we don't re-detect next scan
        State.moduleHeartbeats[entry.name] = nil
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

    debugLog('Watchdog: crash=%dms, cooldown=%dms, maxRestarts=%d, checkInterval=%dms',
        lib.Timing.MODULE_CRASH_MS, lib.Timing.RESTART_COOLDOWN_MS,
        lib.MAX_MODULE_RESTARTS, lib.Timing.WATCHDOG_CHECK_MS)
    lib.log('info', M.MODULE_NAME, 'Coordinator ready')
end

local _lastStatusLog = 0

local function tick()
    local now = lib.getTimeMs()

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
mq.bind('/sk_coord', function(cmd)
    if cmd == 'stop' then
        State.running = false
        lib.log('info', M.MODULE_NAME, 'Stop requested')
    elseif cmd == 'status' then
        lib.log('info', M.MODULE_NAME, 'epoch=%d, priority=%d, castOwner=%s, targetOwner=%s',
            State.epoch, State.activePriority,
            State.castOwner and State.castOwner.module or 'nil',
            State.targetOwner and State.targetOwner.module or 'nil')
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

return M
