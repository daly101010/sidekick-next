-- F:/lua/SideKick/sk_coordinator.lua
-- Central arbiter for SideKick multi-script system
-- Only this script issues /stopcast and broadcasts authoritative state

local mq = require('mq')
local actors = require('actors')
local lib = require('sidekick.sk_lib')

local M = {}

-- Module identity
M.MODULE_NAME = 'coordinator'

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
    moduleHeartbeats = {}, -- [module] = { sentAtMs, ready }

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

    -- Emergency takes precedence
    if ws.emergencyActive then
        return lib.Priority.EMERGENCY
    end

    -- Check for healing needs
    if ws.groupNeedsHealing then
        return lib.Priority.HEALING
    end

    -- Check for dead members needing rez
    if ws.deadCount > 0 then
        return lib.Priority.RESURRECTION
    end

    -- In combat, default to DPS
    if ws.inCombat then
        return lib.Priority.DPS
    end

    -- Out of combat, idle
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

local function expireOwners()
    local changed = false
    if State.castOwner and isOwnerExpired(State.castOwner) then
        lib.log('debug', M.MODULE_NAME, 'Cast owner expired: %s', State.castOwner.module)
        State.castOwner = nil
        changed = true
    end
    if State.targetOwner and isOwnerExpired(State.targetOwner) then
        lib.log('debug', M.MODULE_NAME, 'Target owner expired: %s', State.targetOwner.module)
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
            State.castOwner = nil
            changed = true
        end
    end

    -- Always clear target owner on priority change (except emergency)
    if State.targetOwner and State.targetOwner.priority ~= newPriority and State.targetOwner.priority ~= lib.Priority.EMERGENCY then
        lib.log('debug', M.MODULE_NAME, 'Revoking target owner on priority change: %s', State.targetOwner.module)
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

    -- Validate epochSeen
    if content.epochSeen ~= State.epoch then
        lib.log('debug', M.MODULE_NAME, 'Claim rejected (stale epoch): %s saw %d, current %d',
            content.module, content.epochSeen, State.epoch)
        return false
    end

    -- Validate priority
    if content.priority ~= State.activePriority and content.priority ~= lib.Priority.EMERGENCY then
        lib.log('debug', M.MODULE_NAME, 'Claim rejected (wrong priority): %s has %d, active %d',
            content.module, content.priority, State.activePriority)
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
        return false
    end
    if wantsCast and not canGrantResource(State.castOwner, content.priority) then
        lib.log('debug', M.MODULE_NAME, 'Claim rejected (cast not available): %s', content.module)
        return false
    end

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

    -- Higher priority requesting interrupt
    if content.requestingPriority < State.castOwner.priority then
        -- Emergency always interrupts
        if content.requestingPriority == lib.Priority.EMERGENCY then
            lib.log('info', M.MODULE_NAME, 'Emergency interrupt requested by %s', content.requestingModule)
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
            mq.cmd('/stopcast')
            State.castOwner = nil
            State.epoch = State.epoch + 1
            State.pendingBroadcast = true
            return true
        else
            lib.log('debug', M.MODULE_NAME, 'Interrupt delayed: letting cast finish (remaining=%.1fs <= threshold=%.1fs)',
                remainingSec, threshold)
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
    }
end

local function broadcastState()
    if not dropbox then return end

    State.tickId = State.tickId + 1
    local payload = buildStatePayload()

    pcall(function()
        dropbox:send({ mailbox = lib.Mailbox.STATE, absolute_mailbox = true }, payload)
    end)

    State.lastBroadcastAt = lib.getTimeMs()
    State.pendingBroadcast = false
end

-------------------------------------------------------------------------------
-- Message Handlers
-------------------------------------------------------------------------------

local function onMessage(message)
    local content = message()
    if type(content) ~= 'table' then return end

    local sender = message.sender or {}
    local mailbox = sender.mailbox or ''

    -- Route by mailbox
    if mailbox == lib.Mailbox.CLAIM or content.type == 'claim' then
        processClaim(content, sender)
    elseif mailbox == lib.Mailbox.RELEASE or content.type == 'release' then
        processRelease(content)
    elseif mailbox == lib.Mailbox.INTERRUPT or content.type == 'interrupt' then
        processInterrupt(content)
    elseif mailbox == lib.Mailbox.HEARTBEAT then
        -- Track module heartbeat
        if content.module then
            State.moduleHeartbeats[content.module] = {
                sentAtMs = content.sentAtMs or lib.getTimeMs(),
                ready = content.ready ~= false,
            }
        end
    elseif mailbox == lib.Mailbox.NEED then
        -- Track module need hints
        if content.module then
            State.moduleNeeds[content.module] = {
                priority = content.priority,
                needsAction = content.needsAction,
                ttlMs = content.ttlMs or 250,
                receivedAtMs = lib.getTimeMs(),
            }
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
    actors.register(lib.Mailbox.CLAIM, onMessage)
    actors.register(lib.Mailbox.RELEASE, onMessage)
    actors.register(lib.Mailbox.INTERRUPT, onMessage)
    actors.register(lib.Mailbox.HEARTBEAT, onMessage)
    actors.register(lib.Mailbox.NEED, onMessage)

    lib.log('info', M.MODULE_NAME, 'Coordinator ready')
end

local function tick()
    local now = lib.getTimeMs()

    -- Update world state
    updateWorldState()

    -- Compute active priority
    local newPriority = computeActivePriority()
    if newPriority ~= State.activePriority then
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
