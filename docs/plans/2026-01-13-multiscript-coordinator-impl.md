# SideKick Multi-Script Coordinator Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement the v2 multi-script cleric automation system with centralized Coordinator, epoch-based claims, and priority-tier modules.

**Architecture:** Multiple independent Lua scripts communicate via MQ2 Actors. The Coordinator arbitrates ownership of target/cast resources using epoch-versioned claims. Modules request claims before acting; only the Coordinator issues `/stopcast`.

**Tech Stack:** MQ2 Lua, MQ2 Actors (`require('actors')`), MQ TLOs for game state

**Reference Spec:** `docs/plans/2026-01-13-multiscript-coordinator-fsm-spec.md`

---

## Phase 1: Shared Library

### Task 1.1: Create sk_lib.lua (Constants and Types)

**Files:**
- Create: `F:/lua/SideKick/sk_lib.lua`

**Step 1: Write the shared library**

```lua
-- F:/lua/SideKick/sk_lib.lua
-- Shared constants, types, and utilities for SideKick multi-script system

local mq = require('mq')

local M = {}

-- Version for compatibility checks
M.VERSION = '2.0.0'

-- Priority tiers (lower = higher priority)
M.Priority = {
    EMERGENCY = 0,
    HEALING = 1,
    RESURRECTION = 2,
    DEBUFF = 3,
    DPS = 4,
    IDLE = 5,
}

-- Interrupt thresholds (seconds remaining to let cast finish)
M.InterruptThreshold = {
    [0] = 0.0,   -- Emergency: immediate
    [1] = 0.5,   -- Healing: 0.5s
    [2] = 1.0,   -- Resurrection: 1.0s
    [3] = 1.0,   -- Debuff: 1.0s
    [4] = 999,   -- DPS: never interrupt (lowest priority)
    [5] = 999,   -- Idle: never interrupt
}

-- Mailbox names
M.Mailbox = {
    STATE = 'sk:state',
    CLAIM = 'sk:claim',
    RELEASE = 'sk:release',
    INTERRUPT = 'sk:interrupt',
    HEARTBEAT = 'sk:hb',
    NEED = 'sk:need',
}

-- Timing constants (milliseconds)
M.Timing = {
    COORDINATOR_TICK_MS = 50,
    STATE_BROADCAST_MS = 200,
    STATE_TTL_MS = 750,
    MODULE_HEARTBEAT_MS = 500,
    CLAIM_DEFAULT_TTL_MS = 1000,
    TARGET_CLAIM_TTL_MS = 2000,
    WARMUP_MS = 500,
    COALESCE_MS = 20,
}

-- Action kinds
M.ActionKind = {
    CAST_SPELL = 'cast_spell',
    USE_AA = 'use_aa',
    USE_ITEM = 'use_item',
}

-- Claim types
M.ClaimType = {
    ACTION = 'action',  -- target + cast together (default)
    TARGET = 'target',  -- target only
    CAST = 'cast',      -- cast only
}

--- Generate a unique claim ID
-- @param module string Module name
-- @param counter number Monotonic counter
-- @return string Unique claim ID
function M.generateClaimId(module, counter)
    return string.format('%s_%d_%d', module, os.time(), counter)
end

--- Get current time in milliseconds
-- @return number Current time in ms
function M.getTimeMs()
    return mq.gettime()
end

--- Check if a timestamp is stale
-- @param sentAtMs number When the state was sent
-- @param ttlMs number Time-to-live in ms
-- @return boolean True if stale
function M.isStale(sentAtMs, ttlMs)
    local now = M.getTimeMs()
    return (now - sentAtMs) > ttlMs
end

--- Safe TLO access with fallback
-- @param fn function Function that accesses TLO
-- @param fallback any Fallback value on error
-- @return any Result or fallback
function M.safeTLO(fn, fallback)
    local ok, result = pcall(fn)
    if not ok then return fallback end
    return result ~= nil and result or fallback
end

--- Safe number conversion from TLO
-- @param fn function Function that returns a number
-- @param fallback number Fallback value
-- @return number
function M.safeNum(fn, fallback)
    local ok, v = pcall(fn)
    if not ok then return fallback end
    return tonumber(v) or fallback
end

--- Check if Me TLO is valid
-- @return boolean
function M.isMeValid()
    return mq.TLO.Me and mq.TLO.Me() ~= nil
end

--- Get my character name
-- @return string
function M.getMyName()
    if not M.isMeValid() then return '' end
    return M.safeTLO(function() return mq.TLO.Me.CleanName() end, '') or ''
end

--- Get current zone short name
-- @return string
function M.getZone()
    return M.safeTLO(function() return mq.TLO.Zone.ShortName() end, '') or ''
end

--- Check if currently casting
-- @return boolean
function M.isCasting()
    if not M.isMeValid() then return false end
    local casting = M.safeTLO(function() return mq.TLO.Me.Casting() end, nil)
    return casting ~= nil
end

--- Get remaining cast time in seconds
-- @return number Seconds remaining, 0 if not casting
function M.getCastTimeRemaining()
    if not M.isCasting() then return 0 end
    local ms = M.safeNum(function() return mq.TLO.Me.CastTimeLeft() end, 0)
    return ms / 1000
end

--- Check if in combat
-- @return boolean
function M.inCombat()
    if not M.isMeValid() then return false end
    return M.safeTLO(function() return mq.TLO.Me.Combat() end, false) == true
end

--- Get group member count
-- @return number
function M.getGroupCount()
    return M.safeNum(function() return mq.TLO.Group.Members() end, 0)
end

--- Get main assist ID
-- @return number Spawn ID or 0
function M.getMainAssistId()
    local ma = mq.TLO.Group.MainAssist
    if not ma or not ma() then return 0 end
    return M.safeNum(function() return ma.ID() end, 0)
end

--- Log with prefix
-- @param level string 'debug', 'info', 'warn', 'error'
-- @param module string Module name
-- @param fmt string Format string
-- @param ... any Format args
function M.log(level, module, fmt, ...)
    local msg = string.format(fmt, ...)
    local prefix = string.format('[SK:%s][%s]', module, level:upper())
    mq.cmdf('/echo %s %s', prefix, msg)
end

return M
```

**Step 2: Verify the library loads**

Run in-game:
```
/lua run sk_lib
```

Expected: No errors. Script exits immediately (no main loop).

**Step 3: Commit**

```bash
git add F:/lua/SideKick/sk_lib.lua
git commit -m "feat(sk): add shared library with constants and utilities

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Phase 2: Coordinator Core

### Task 2.1: Create sk_coordinator.lua (State Machine)

**Files:**
- Create: `F:/lua/SideKick/sk_coordinator.lua`

**Step 1: Write the Coordinator skeleton**

```lua
-- F:/lua/SideKick/sk_coordinator.lua
-- Central arbiter for SideKick multi-script system
-- Only this script issues /stopcast and broadcasts authoritative state

local mq = require('mq')
local actors = require('actors')
local lib = require('sk_lib')

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
```

**Step 2: Test Coordinator loads and runs**

Run in-game:
```
/lua run sk_coordinator
```

Expected:
- Console shows: `[SK:coordinator][INFO] Initializing Coordinator v2.0.0`
- Console shows: `[SK:coordinator][INFO] Coordinator ready`
- Script continues running (check with `/lua list`)

**Step 3: Test status command**

```
/sk_coord status
```

Expected: Shows current epoch, priority, and owner status.

**Step 4: Test stop command**

```
/sk_coord stop
```

Expected: Coordinator stops gracefully.

**Step 5: Commit**

```bash
git add F:/lua/SideKick/sk_coordinator.lua
git commit -m "feat(sk): add Coordinator with state machine and claim processing

- Epoch-based state versioning
- Priority tier evaluation from world state
- Claim/release/interrupt processing
- Periodic + on-change state broadcast
- Revocation on priority change

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Phase 3: Module Base Class

### Task 3.1: Create sk_module_base.lua (Shared Module Logic)

**Files:**
- Create: `F:/lua/SideKick/sk_module_base.lua`

**Step 1: Write the module base**

```lua
-- F:/lua/SideKick/sk_module_base.lua
-- Base class for SideKick priority modules
-- Handles state reception, claim requests, and execution guards

local mq = require('mq')
local actors = require('actors')
local lib = require('sk_lib')

local M = {}

--- Create a new module instance
-- @param moduleName string Unique module name
-- @param priority number Module's priority tier
-- @return table Module instance
function M.create(moduleName, priority)
    local self = {
        name = moduleName,
        priority = priority,

        -- State from Coordinator
        state = nil,
        stateReceivedAt = 0,

        -- Claim tracking
        claimCounter = 0,
        currentClaimId = nil,
        claimPending = false,
        claimRequestedAt = 0,

        -- Running flag
        running = true,
        initialized = false,
        warmupUntil = 0,

        -- Actor dropbox
        dropbox = nil,

        -- Callbacks (override these)
        onTick = nil,          -- Called each tick when active
        shouldAct = nil,       -- Returns true if module needs to act
        getAction = nil,       -- Returns action details for claim
        executeAction = nil,   -- Executes the action after claim granted
    }

    ---------------------------------------------------------------------------
    -- State Management
    ---------------------------------------------------------------------------

    function self:hasValidState()
        if not self.state then return false end
        return not lib.isStale(self.state.sentAtMs, self.state.ttlMs)
    end

    function self:isMyPriority()
        if not self:hasValidState() then return false end
        return self.state.activePriority == self.priority or self.priority == lib.Priority.EMERGENCY
    end

    function self:isWarmingUp()
        return lib.getTimeMs() < self.warmupUntil
    end

    ---------------------------------------------------------------------------
    -- Ownership Checks
    ---------------------------------------------------------------------------

    function self:ownsCast()
        if not self:hasValidState() then return false end
        local owner = self.state.castOwner
        if not owner then return false end
        return owner.module == self.name
            and owner.claimId == self.currentClaimId
            and owner.epoch == self.state.epoch
    end

    function self:ownsTarget()
        if not self:hasValidState() then return false end
        local owner = self.state.targetOwner
        if not owner then return false end
        return owner.module == self.name
            and owner.claimId == self.currentClaimId
            and owner.epoch == self.state.epoch
    end

    function self:ownsAction()
        return self:ownsCast() and self:ownsTarget()
    end

    ---------------------------------------------------------------------------
    -- Claim Management
    ---------------------------------------------------------------------------

    function self:requestClaim(action)
        if not self:hasValidState() then
            lib.log('debug', self.name, 'Cannot claim: no valid state')
            return false
        end

        if self.claimPending then
            -- Check for timeout
            local elapsed = lib.getTimeMs() - self.claimRequestedAt
            if elapsed < 200 then
                return false -- Still waiting
            end
            -- Timeout, reset
            self.claimPending = false
        end

        self.claimCounter = self.claimCounter + 1
        self.currentClaimId = lib.generateClaimId(self.name, self.claimCounter)

        local claim = {
            type = lib.ClaimType.ACTION,
            wants = { 'target', 'cast' },
            module = self.name,
            priority = self.priority,
            claimId = self.currentClaimId,
            epochSeen = self.state.epoch,
            ttlMs = lib.Timing.CLAIM_DEFAULT_TTL_MS,
            reason = action.reason or 'action',
            action = action,
        }

        self.claimPending = true
        self.claimRequestedAt = lib.getTimeMs()

        pcall(function()
            self.dropbox:send({ mailbox = lib.Mailbox.CLAIM, absolute_mailbox = true }, claim)
        end)

        lib.log('debug', self.name, 'Claim requested: %s (epoch=%d)', self.currentClaimId, self.state.epoch)
        return true
    end

    function self:releaseClaim(reason)
        if not self.currentClaimId then return end

        local release = {
            type = 'action',
            module = self.name,
            claimId = self.currentClaimId,
            epochSeen = self.state and self.state.epoch or 0,
            reason = reason or 'completed',
        }

        pcall(function()
            self.dropbox:send({ mailbox = lib.Mailbox.RELEASE, absolute_mailbox = true }, release)
        end)

        lib.log('debug', self.name, 'Release sent: %s (%s)', self.currentClaimId, reason)
        self.currentClaimId = nil
        self.claimPending = false
    end

    function self:requestInterrupt(reason)
        if not self:hasValidState() then return end

        local interrupt = {
            requestingModule = self.name,
            requestingPriority = self.priority,
            reason = reason or 'preempt',
        }

        pcall(function()
            self.dropbox:send({ mailbox = lib.Mailbox.INTERRUPT, absolute_mailbox = true }, interrupt)
        end)

        lib.log('debug', self.name, 'Interrupt requested: %s', reason)
    end

    function self:sendHeartbeat()
        pcall(function()
            self.dropbox:send({ mailbox = lib.Mailbox.HEARTBEAT, absolute_mailbox = true }, {
                module = self.name,
                sentAtMs = lib.getTimeMs(),
                ready = true,
            })
        end)
    end

    ---------------------------------------------------------------------------
    -- Message Handling
    ---------------------------------------------------------------------------

    function self:onStateReceived(content)
        self.state = content
        self.stateReceivedAt = lib.getTimeMs()

        -- Start warmup on first state
        if not self.initialized then
            self.warmupUntil = lib.getTimeMs() + lib.Timing.WARMUP_MS
            self.initialized = true
            lib.log('info', self.name, 'First state received, warming up for %dms', lib.Timing.WARMUP_MS)
        end

        -- Check if our claim was granted or rejected
        if self.claimPending then
            if self:ownsAction() then
                lib.log('debug', self.name, 'Claim granted: %s', self.currentClaimId)
                self.claimPending = false
            elseif self.state.epoch > (self.claimRequestedAt and self.state.epoch or 0) then
                -- Epoch changed but we don't own - claim was rejected or someone else got it
                local elapsed = lib.getTimeMs() - self.claimRequestedAt
                if elapsed > 100 then
                    lib.log('debug', self.name, 'Claim likely rejected (epoch changed): %s', self.currentClaimId)
                    self.claimPending = false
                    self.currentClaimId = nil
                end
            end
        end
    end

    ---------------------------------------------------------------------------
    -- Main Loop Logic
    ---------------------------------------------------------------------------

    function self:tick()
        -- Safety: stop if no valid state
        if not self:hasValidState() then
            if self.currentClaimId then
                lib.log('warn', self.name, 'State stale, releasing claim')
                self:releaseClaim('state_stale')
            end
            return
        end

        -- Skip during warmup
        if self:isWarmingUp() then
            return
        end

        -- Call custom tick handler
        if self.onTick then
            self.onTick(self)
        end

        -- Check if we should act
        if not self:isMyPriority() then
            return
        end

        -- If we already own the action, execute
        if self:ownsAction() then
            if self.executeAction then
                local success, reason = self.executeAction(self)
                if success or reason == 'completed' then
                    self:releaseClaim(reason or 'completed')
                end
            end
            return
        end

        -- Check if we should request a claim
        if self.shouldAct and self.shouldAct(self) then
            if self.getAction then
                local action = self.getAction(self)
                if action then
                    self:requestClaim(action)
                end
            end
        end
    end

    ---------------------------------------------------------------------------
    -- Initialization
    ---------------------------------------------------------------------------

    function self:initialize()
        lib.log('info', self.name, 'Initializing module (priority=%d)', self.priority)

        -- Register actor to receive state broadcasts
        self.dropbox = actors.register(self.name, function(message)
            local content = message()
            if type(content) ~= 'table' then return end

            -- Check if this is a state broadcast
            if content.tickId and content.epoch then
                self:onStateReceived(content)
            end
        end)

        -- Also listen on state mailbox
        actors.register(lib.Mailbox.STATE, function(message)
            local content = message()
            if type(content) == 'table' and content.tickId and content.epoch then
                self:onStateReceived(content)
            end
        end)

        lib.log('info', self.name, 'Module ready, waiting for Coordinator state...')
    end

    function self:run(tickDelayMs)
        tickDelayMs = tickDelayMs or 50

        self:initialize()

        local lastHeartbeat = 0

        while self.running do
            self:tick()

            -- Send heartbeat periodically
            local now = lib.getTimeMs()
            if (now - lastHeartbeat) >= lib.Timing.MODULE_HEARTBEAT_MS then
                self:sendHeartbeat()
                lastHeartbeat = now
            end

            mq.delay(tickDelayMs)
        end

        lib.log('info', self.name, 'Module stopped')
    end

    function self:stop()
        self.running = false
        if self.currentClaimId then
            self:releaseClaim('shutdown')
        end
    end

    return self
end

return M
```

**Step 2: Verify the base loads**

Run in-game:
```
/lua parse local base = require('sk_module_base'); print('Loaded:', base)
```

Expected: No errors, shows table address.

**Step 3: Commit**

```bash
git add F:/lua/SideKick/sk_module_base.lua
git commit -m "feat(sk): add module base class with claim lifecycle

- State reception and validation
- Ownership checking (cast/target/action)
- Claim request with timeout handling
- Release and interrupt helpers
- Warmup period after first state
- Heartbeat sending

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Phase 4: Healing Module

### Task 4.1: Create sk_healing.lua (Priority 1 Healing)

**Files:**
- Create: `F:/lua/SideKick/sk_healing.lua`

**Step 1: Write the healing module**

```lua
-- F:/lua/SideKick/sk_healing.lua
-- Healing module for SideKick multi-script system
-- Priority 1: Fast heals, group heals, HoTs

local mq = require('mq')
local lib = require('sk_lib')
local ModuleBase = require('sk_module_base')

-- Create module instance
local module = ModuleBase.create('healing', lib.Priority.HEALING)

-------------------------------------------------------------------------------
-- Healing Configuration
-------------------------------------------------------------------------------

local Config = {
    -- HP thresholds
    mainHealPct = 80,
    bigHealPct = 50,
    groupHealPct = 75,
    groupInjuredCount = 2,

    -- Spell preferences (resolve from memorized)
    spellLines = {
        main = { 'Guileless Remedy', 'Sincere Remedy', 'Merciful Remedy', 'Spiritual Remedy' },
        big = { 'Determined Renewal', 'Dire Renewal', 'Furial Renewal' },
        group = { 'Word of Greater Vivification', 'Word of Greater Rejuvenation' },
    },
}

-------------------------------------------------------------------------------
-- Spell Resolution
-------------------------------------------------------------------------------

local function isSpellMemorized(spellName)
    if not spellName or spellName == '' then return false end
    local me = mq.TLO.Me
    if not (me and me()) then return false end
    local gems = lib.safeNum(function() return me.NumGems() end, 13)
    for i = 1, gems do
        local gem = me.Gem(i)
        if gem and gem() and (gem.Name() or '') == spellName then
            return true
        end
    end
    return false
end

local function resolveSpell(lineKey)
    local line = Config.spellLines[lineKey]
    if not line then return nil end
    for _, name in ipairs(line) do
        if isSpellMemorized(name) then
            return name
        end
    end
    return nil
end

local function isSpellReady(spellName)
    if not spellName then return false end
    local me = mq.TLO.Me
    if not (me and me()) then return false end
    return lib.safeTLO(function() return me.SpellReady(spellName)() end, false) == true
end

local function getSpellCastTime(spellName)
    if not spellName then return 0 end
    local spell = mq.TLO.Spell(spellName)
    if not (spell and spell()) then return 0 end
    return lib.safeNum(function() return spell.MyCastTime() end, 0) / 1000
end

-------------------------------------------------------------------------------
-- Heal Target Selection
-------------------------------------------------------------------------------

local function getGroupMemberHP(index)
    local member = mq.TLO.Group.Member(index)
    if not (member and member()) then return nil end
    local id = lib.safeNum(function() return member.ID() end, 0)
    if id <= 0 then return nil end
    local hp = lib.safeNum(function() return member.PctHPs() end, 100)
    local name = lib.safeTLO(function() return member.CleanName() end, '') or ''
    return { id = id, hp = hp, name = name, index = index }
end

local function findHealTarget()
    local candidates = {}

    -- Check self (index 0)
    local me = mq.TLO.Me
    if me and me() then
        local myHp = lib.safeNum(function() return me.PctHPs() end, 100)
        local myId = lib.safeNum(function() return me.ID() end, 0)
        if myHp < Config.mainHealPct and myId > 0 then
            table.insert(candidates, { id = myId, hp = myHp, name = lib.getMyName(), index = 0 })
        end
    end

    -- Check group members
    local groupCount = lib.getGroupCount()
    for i = 1, groupCount do
        local member = getGroupMemberHP(i)
        if member and member.hp < Config.mainHealPct then
            table.insert(candidates, member)
        end
    end

    -- Sort by HP (lowest first)
    table.sort(candidates, function(a, b) return a.hp < b.hp end)

    return candidates[1]
end

local function countInjured(threshold)
    local count = 0

    -- Check self
    local me = mq.TLO.Me
    if me and me() then
        local myHp = lib.safeNum(function() return me.PctHPs() end, 100)
        if myHp < threshold then count = count + 1 end
    end

    -- Check group
    local groupCount = lib.getGroupCount()
    for i = 1, groupCount do
        local member = getGroupMemberHP(i)
        if member and member.hp < threshold then
            count = count + 1
        end
    end

    return count
end

-------------------------------------------------------------------------------
-- Module Callbacks
-------------------------------------------------------------------------------

-- Called each tick to check if we should act
module.shouldAct = function(self)
    if not self:hasValidState() then return false end

    -- Check if anyone needs healing
    local target = findHealTarget()
    if target then return true end

    -- Check for group heal need
    local injured = countInjured(Config.groupHealPct)
    if injured >= Config.groupInjuredCount then return true end

    return false
end

-- Returns action details for claim request
module.getAction = function(self)
    -- Determine heal type needed
    local target = findHealTarget()
    local injured = countInjured(Config.groupHealPct)
    local needGroup = injured >= Config.groupInjuredCount

    local spellName = nil
    local targetId = 0
    local tier = 'main'

    if needGroup then
        spellName = resolveSpell('group')
        targetId = lib.safeNum(function() return mq.TLO.Me.ID() end, 0)
        tier = 'group'
    elseif target then
        targetId = target.id
        if target.hp < Config.bigHealPct then
            spellName = resolveSpell('big') or resolveSpell('main')
            tier = 'big'
        else
            spellName = resolveSpell('main')
            tier = 'main'
        end
    end

    if not spellName or targetId <= 0 then
        return nil
    end

    if not isSpellReady(spellName) then
        lib.log('debug', self.name, 'Spell not ready: %s', spellName)
        return nil
    end

    return {
        kind = lib.ActionKind.CAST_SPELL,
        name = spellName,
        targetId = targetId,
        idempotencyKey = string.format('heal:%s:%s', tier, targetId),
        reason = string.format('%s heal on %d', tier, targetId),
        tier = tier,
    }
end

-- Executes the action after claim is granted
module.executeAction = function(self)
    if not self:ownsAction() then
        return false, 'no_ownership'
    end

    local action = self.state.castOwner and self.state.castOwner.action
    if not action then
        return false, 'no_action'
    end

    local spellName = action.name
    local targetId = action.targetId

    -- Verify spell is still ready
    if not isSpellReady(spellName) then
        lib.log('debug', self.name, 'Spell no longer ready: %s', spellName)
        return true, 'spell_not_ready'
    end

    -- Target the heal target
    lib.log('info', self.name, 'Targeting %d for %s', targetId, spellName)
    mq.cmdf('/target id %d', targetId)
    mq.delay(50) -- Brief delay for target to update

    -- Verify target
    local currentTarget = lib.safeNum(function() return mq.TLO.Target.ID() end, 0)
    if currentTarget ~= targetId then
        lib.log('warn', self.name, 'Target mismatch: wanted %d, got %d', targetId, currentTarget)
        return true, 'target_failed'
    end

    -- Cast the spell
    lib.log('info', self.name, 'Casting %s on %d', spellName, targetId)
    mq.cmdf('/cast "%s"', spellName)

    -- Wait for cast to start (brief)
    mq.delay(100)

    -- Check if cast started
    if lib.isCasting() then
        local castTime = getSpellCastTime(spellName)
        lib.log('info', self.name, 'Cast started: %s (%.1fs)', spellName, castTime)

        -- Wait for cast to complete (with periodic ownership checks)
        local startTime = lib.getTimeMs()
        local maxWait = (castTime + 1) * 1000

        while lib.isCasting() do
            mq.delay(50)

            -- Check if we still own the action
            if not self:ownsAction() then
                lib.log('warn', self.name, 'Lost ownership during cast')
                return true, 'ownership_lost'
            end

            -- Timeout safety
            if (lib.getTimeMs() - startTime) > maxWait then
                lib.log('warn', self.name, 'Cast timeout')
                break
            end
        end

        lib.log('info', self.name, 'Cast completed: %s', spellName)
        return true, 'completed'
    else
        lib.log('warn', self.name, 'Cast did not start: %s', spellName)
        return true, 'cast_failed'
    end
end

-------------------------------------------------------------------------------
-- Command Binding
-------------------------------------------------------------------------------

mq.bind('/sk_healing', function(cmd)
    if cmd == 'stop' then
        module:stop()
        lib.log('info', module.name, 'Stop requested')
    elseif cmd == 'status' then
        lib.log('info', module.name, 'running=%s, hasState=%s, isMyPriority=%s, ownsAction=%s',
            tostring(module.running),
            tostring(module:hasValidState()),
            tostring(module:isMyPriority()),
            tostring(module:ownsAction()))
    end
end)

-------------------------------------------------------------------------------
-- Run
-------------------------------------------------------------------------------

module:run(50)

return module
```

**Step 2: Test healing module loads**

First, ensure Coordinator is running:
```
/lua run sk_coordinator
```

Then start healing module:
```
/lua run sk_healing
```

Expected:
- Console shows: `[SK:healing][INFO] Initializing module (priority=1)`
- Console shows: `[SK:healing][INFO] Module ready, waiting for Coordinator state...`
- Shortly after: `[SK:healing][INFO] First state received, warming up for 500ms`

**Step 3: Test status command**

```
/sk_healing status
```

Expected: Shows running status, state validity, priority match, ownership.

**Step 4: Verify claim flow (in-game with injured group member)**

1. Damage a group member below 80% HP
2. Watch console for:
   - `[SK:coordinator][INFO] Priority change: X -> 1`
   - `[SK:healing][DEBUG] Claim requested: ...`
   - `[SK:coordinator][INFO] Claim granted: healing ...`
   - `[SK:healing][INFO] Casting ... on ...`

**Step 5: Commit**

```bash
git add F:/lua/SideKick/sk_healing.lua
git commit -m "feat(sk): add healing module with claim-based casting

- HP threshold detection for heal targets
- Spell resolution from memorized gems
- Group heal when multiple injured
- Full claim lifecycle (request, execute, release)
- Cast monitoring with ownership checks

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Phase 5: Emergency Module

### Task 5.1: Create sk_emergency.lua (Priority 0 Emergency)

**Files:**
- Create: `F:/lua/SideKick/sk_emergency.lua`

**Step 1: Write the emergency module**

```lua
-- F:/lua/SideKick/sk_emergency.lua
-- Emergency module for SideKick multi-script system
-- Priority 0: Divine Arbitration, Celestial Regen, Sanctuary

local mq = require('mq')
local lib = require('sk_lib')
local ModuleBase = require('sk_module_base')

-- Create module instance
local module = ModuleBase.create('emergency', lib.Priority.EMERGENCY)

-------------------------------------------------------------------------------
-- Emergency Configuration
-------------------------------------------------------------------------------

local Config = {
    -- Thresholds
    arbitrationThreshold = 3,  -- Number of group members below 25% to trigger
    arbitrationHpPct = 25,
    celestialRegenHpPct = 35,
    sanctuaryHpPct = 20,

    -- AA names
    divineArbitration = 'Divine Arbitration',
    celestialRegen = 'Celestial Regeneration',
    sanctuary = 'Sanctuary',
}

-------------------------------------------------------------------------------
-- AA Readiness
-------------------------------------------------------------------------------

local function isAAReady(aaName)
    if not aaName then return false end
    local me = mq.TLO.Me
    if not (me and me()) then return false end
    return lib.safeTLO(function() return me.AltAbilityReady(aaName)() end, false) == true
end

-------------------------------------------------------------------------------
-- Emergency Detection
-------------------------------------------------------------------------------

local function countCritical(threshold)
    local count = 0

    -- Check self
    local me = mq.TLO.Me
    if me and me() then
        local myHp = lib.safeNum(function() return me.PctHPs() end, 100)
        if myHp < threshold then count = count + 1 end
    end

    -- Check group
    local groupCount = lib.getGroupCount()
    for i = 1, groupCount do
        local member = mq.TLO.Group.Member(i)
        if member and member() then
            local hp = lib.safeNum(function() return member.PctHPs() end, 100)
            if hp < threshold then
                count = count + 1
            end
        end
    end

    return count
end

local function getMyHpPct()
    return lib.safeNum(function() return mq.TLO.Me.PctHPs() end, 100)
end

local function detectEmergency()
    local myHp = getMyHpPct()

    -- Sanctuary: self HP critical
    if myHp < Config.sanctuaryHpPct and isAAReady(Config.sanctuary) then
        return 'sanctuary', Config.sanctuary
    end

    -- Celestial Regen: self HP low
    if myHp < Config.celestialRegenHpPct and isAAReady(Config.celestialRegen) then
        return 'celestial', Config.celestialRegen
    end

    -- Divine Arbitration: multiple critical
    local criticalCount = countCritical(Config.arbitrationHpPct)
    if criticalCount >= Config.arbitrationThreshold and isAAReady(Config.divineArbitration) then
        return 'arbitration', Config.divineArbitration
    end

    return nil, nil
end

-------------------------------------------------------------------------------
-- Module Callbacks
-------------------------------------------------------------------------------

module.shouldAct = function(self)
    local kind, aa = detectEmergency()
    return kind ~= nil
end

module.getAction = function(self)
    local kind, aaName = detectEmergency()
    if not kind or not aaName then return nil end

    local myId = lib.safeNum(function() return mq.TLO.Me.ID() end, 0)

    return {
        kind = lib.ActionKind.USE_AA,
        name = aaName,
        targetId = myId,
        idempotencyKey = string.format('emergency:%s', kind),
        reason = string.format('emergency %s', kind),
        emergencyKind = kind,
    }
end

module.executeAction = function(self)
    if not self:ownsAction() then
        return false, 'no_ownership'
    end

    local action = self.state.castOwner and self.state.castOwner.action
    if not action then
        return false, 'no_action'
    end

    local aaName = action.name

    -- Verify AA is still ready
    if not isAAReady(aaName) then
        lib.log('debug', self.name, 'AA no longer ready: %s', aaName)
        return true, 'aa_not_ready'
    end

    -- Fire the AA
    lib.log('info', self.name, 'EMERGENCY: Using %s', aaName)
    mq.cmdf('/alt activate "%s"', aaName)

    -- Brief delay for activation
    mq.delay(100)

    -- Check if we're casting (some AAs have cast time)
    if lib.isCasting() then
        local startTime = lib.getTimeMs()
        while lib.isCasting() do
            mq.delay(50)
            if (lib.getTimeMs() - startTime) > 5000 then
                lib.log('warn', self.name, 'AA cast timeout')
                break
            end
        end
    end

    lib.log('info', self.name, 'Emergency action completed: %s', aaName)
    return true, 'completed'
end

-- Emergency module should also request interrupt when it detects emergency
module.onTick = function(self)
    if not self:hasValidState() then return end

    -- If we detect an emergency and someone else is casting, request interrupt
    local kind, _ = detectEmergency()
    if kind and self.state.castBusy and not self:ownsCast() then
        if self.state.castOwner and self.state.castOwner.priority > lib.Priority.EMERGENCY then
            self:requestInterrupt(string.format('emergency_%s', kind))
        end
    end
end

-------------------------------------------------------------------------------
-- Command Binding
-------------------------------------------------------------------------------

mq.bind('/sk_emergency', function(cmd)
    if cmd == 'stop' then
        module:stop()
        lib.log('info', module.name, 'Stop requested')
    elseif cmd == 'status' then
        local kind, aa = detectEmergency()
        lib.log('info', module.name, 'running=%s, hasState=%s, emergency=%s, aa=%s',
            tostring(module.running),
            tostring(module:hasValidState()),
            tostring(kind or 'none'),
            tostring(aa or 'none'))
    end
end)

-------------------------------------------------------------------------------
-- Run
-------------------------------------------------------------------------------

module:run(50)

return module
```

**Step 2: Test emergency module loads**

With Coordinator running:
```
/lua run sk_emergency
```

Expected:
- Console shows initialization messages
- Module waits for state

**Step 3: Commit**

```bash
git add F:/lua/SideKick/sk_emergency.lua
git commit -m "feat(sk): add emergency module for critical situations

- Divine Arbitration when multiple critical
- Celestial Regeneration when self HP low
- Sanctuary when self HP critical
- Proactive interrupt requests for preemption

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Phase 6: DPS Module

### Task 6.1: Create sk_dps.lua (Priority 4 DPS)

**Files:**
- Create: `F:/lua/SideKick/sk_dps.lua`

**Step 1: Write the DPS module**

```lua
-- F:/lua/SideKick/sk_dps.lua
-- DPS module for SideKick multi-script system
-- Priority 4: Nukes, stuns, meditation when idle

local mq = require('mq')
local lib = require('sk_lib')
local ModuleBase = require('sk_module_base')

-- Create module instance
local module = ModuleBase.create('dps', lib.Priority.DPS)

-------------------------------------------------------------------------------
-- DPS Configuration
-------------------------------------------------------------------------------

local Config = {
    -- Mana threshold to nuke
    minManaPct = 40,

    -- Target HP threshold (don't nuke nearly dead targets)
    minTargetHpPct = 20,

    -- Spell preferences
    spellLines = {
        nuke = { 'Divine Contravention', 'Sincere Contravention', 'Merciful Contravention' },
        stun = { 'Sound of Divinity', 'Sound of Zeal', 'Sound of Resonance' },
    },
}

-------------------------------------------------------------------------------
-- Spell Resolution
-------------------------------------------------------------------------------

local function isSpellMemorized(spellName)
    if not spellName or spellName == '' then return false end
    local me = mq.TLO.Me
    if not (me and me()) then return false end
    local gems = lib.safeNum(function() return me.NumGems() end, 13)
    for i = 1, gems do
        local gem = me.Gem(i)
        if gem and gem() and (gem.Name() or '') == spellName then
            return true
        end
    end
    return false
end

local function resolveSpell(lineKey)
    local line = Config.spellLines[lineKey]
    if not line then return nil end
    for _, name in ipairs(line) do
        if isSpellMemorized(name) then
            return name
        end
    end
    return nil
end

local function isSpellReady(spellName)
    if not spellName then return false end
    local me = mq.TLO.Me
    if not (me and me()) then return false end
    return lib.safeTLO(function() return me.SpellReady(spellName)() end, false) == true
end

local function getSpellCastTime(spellName)
    if not spellName then return 0 end
    local spell = mq.TLO.Spell(spellName)
    if not (spell and spell()) then return 0 end
    return lib.safeNum(function() return spell.MyCastTime() end, 0) / 1000
end

-------------------------------------------------------------------------------
-- Target Selection
-------------------------------------------------------------------------------

local function getMATarget()
    local maId = lib.getMainAssistId()
    if maId <= 0 then return nil end

    local ma = mq.TLO.Spawn(maId)
    if not (ma and ma()) then return nil end

    local targetId = lib.safeNum(function() return ma.TargetOfTarget.ID() end, 0)
    if targetId <= 0 then
        -- Try MA's target directly
        targetId = lib.safeNum(function() return ma.Target.ID() end, 0)
    end

    if targetId <= 0 then return nil end

    local target = mq.TLO.Spawn(targetId)
    if not (target and target()) then return nil end

    local hp = lib.safeNum(function() return target.PctHPs() end, 100)
    local type = lib.safeTLO(function() return target.Type() end, '') or ''

    -- Only attack NPCs
    if type:lower() ~= 'npc' then return nil end

    return { id = targetId, hp = hp }
end

-------------------------------------------------------------------------------
-- Module Callbacks
-------------------------------------------------------------------------------

module.shouldAct = function(self)
    if not self:hasValidState() then return false end

    -- Only DPS in combat
    if not lib.inCombat() then return false end

    -- Check mana
    local mana = lib.safeNum(function() return mq.TLO.Me.PctMana() end, 0)
    if mana < Config.minManaPct then return false end

    -- Check for valid target
    local target = getMATarget()
    if not target then return false end
    if target.hp < Config.minTargetHpPct then return false end

    -- Check if we have a spell ready
    local nuke = resolveSpell('nuke')
    local stun = resolveSpell('stun')
    if not nuke and not stun then return false end
    if nuke and not isSpellReady(nuke) then nuke = nil end
    if stun and not isSpellReady(stun) then stun = nil end

    return nuke or stun
end

module.getAction = function(self)
    local target = getMATarget()
    if not target then return nil end

    -- Prefer nuke, fall back to stun
    local spellName = resolveSpell('nuke')
    local kind = 'nuke'
    if not spellName or not isSpellReady(spellName) then
        spellName = resolveSpell('stun')
        kind = 'stun'
    end

    if not spellName or not isSpellReady(spellName) then
        return nil
    end

    return {
        kind = lib.ActionKind.CAST_SPELL,
        name = spellName,
        targetId = target.id,
        idempotencyKey = string.format('dps:%s:%d', kind, target.id),
        reason = string.format('%s on %d', kind, target.id),
    }
end

module.executeAction = function(self)
    if not self:ownsAction() then
        return false, 'no_ownership'
    end

    local action = self.state.castOwner and self.state.castOwner.action
    if not action then
        return false, 'no_action'
    end

    local spellName = action.name
    local targetId = action.targetId

    -- Verify spell is still ready
    if not isSpellReady(spellName) then
        lib.log('debug', self.name, 'Spell no longer ready: %s', spellName)
        return true, 'spell_not_ready'
    end

    -- Target
    lib.log('info', self.name, 'Targeting %d for %s', targetId, spellName)
    mq.cmdf('/target id %d', targetId)
    mq.delay(50)

    -- Verify target
    local currentTarget = lib.safeNum(function() return mq.TLO.Target.ID() end, 0)
    if currentTarget ~= targetId then
        lib.log('warn', self.name, 'Target mismatch: wanted %d, got %d', targetId, currentTarget)
        return true, 'target_failed'
    end

    -- Cast
    lib.log('info', self.name, 'Casting %s on %d', spellName, targetId)
    mq.cmdf('/cast "%s"', spellName)
    mq.delay(100)

    if lib.isCasting() then
        local castTime = getSpellCastTime(spellName)
        lib.log('info', self.name, 'Cast started: %s (%.1fs)', spellName, castTime)

        local startTime = lib.getTimeMs()
        local maxWait = (castTime + 1) * 1000

        while lib.isCasting() do
            mq.delay(50)

            if not self:ownsAction() then
                lib.log('warn', self.name, 'Lost ownership during cast')
                return true, 'ownership_lost'
            end

            if (lib.getTimeMs() - startTime) > maxWait then
                lib.log('warn', self.name, 'Cast timeout')
                break
            end
        end

        lib.log('info', self.name, 'Cast completed: %s', spellName)
        return true, 'completed'
    else
        lib.log('warn', self.name, 'Cast did not start: %s', spellName)
        return true, 'cast_failed'
    end
end

-------------------------------------------------------------------------------
-- Command Binding
-------------------------------------------------------------------------------

mq.bind('/sk_dps', function(cmd)
    if cmd == 'stop' then
        module:stop()
        lib.log('info', module.name, 'Stop requested')
    elseif cmd == 'status' then
        local target = getMATarget()
        lib.log('info', module.name, 'running=%s, hasState=%s, isMyPriority=%s, target=%s',
            tostring(module.running),
            tostring(module:hasValidState()),
            tostring(module:isMyPriority()),
            target and tostring(target.id) or 'none')
    end
end)

-------------------------------------------------------------------------------
-- Run
-------------------------------------------------------------------------------

module:run(50)

return module
```

**Step 2: Test DPS module loads**

With Coordinator running:
```
/lua run sk_dps
```

**Step 3: Commit**

```bash
git add F:/lua/SideKick/sk_dps.lua
git commit -m "feat(sk): add DPS module for combat nuking

- MA target following
- Nuke and stun spell resolution
- Mana threshold enforcement
- Target HP minimum check

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Phase 7: Startup Script

### Task 7.1: Create sk_start.lua (Convenience Launcher)

**Files:**
- Create: `F:/lua/SideKick/sk_start.lua`

**Step 1: Write the startup script**

```lua
-- F:/lua/SideKick/sk_start.lua
-- Convenience script to launch all SideKick modules

local mq = require('mq')

local function log(msg)
    mq.cmdf('/echo [SK:start] %s', msg)
end

local modules = {
    'sk_coordinator',
    'sk_emergency',
    'sk_healing',
    'sk_dps',
}

local function startAll()
    log('Starting SideKick multi-script system...')

    for _, mod in ipairs(modules) do
        log(string.format('Starting %s...', mod))
        mq.cmdf('/lua run %s', mod)
        mq.delay(100) -- Brief delay between launches
    end

    log('All modules launched. Use /lua list to verify.')
end

local function stopAll()
    log('Stopping SideKick multi-script system...')

    for _, mod in ipairs(modules) do
        log(string.format('Stopping %s...', mod))
        mq.cmdf('/lua stop %s', mod)
    end

    log('All modules stopped.')
end

-- Command binding
mq.bind('/sidekick', function(cmd)
    if cmd == 'start' then
        startAll()
    elseif cmd == 'stop' then
        stopAll()
    elseif cmd == 'restart' then
        stopAll()
        mq.delay(500)
        startAll()
    elseif cmd == 'status' then
        log('Use /lua list to see running modules')
    else
        log('Usage: /sidekick start|stop|restart|status')
    end
end)

log('SideKick launcher loaded. Use /sidekick start|stop|restart')
```

**Step 2: Test launcher**

```
/lua run sk_start
/sidekick start
```

Expected: All modules start in sequence.

```
/sidekick stop
```

Expected: All modules stop.

**Step 3: Commit**

```bash
git add F:/lua/SideKick/sk_start.lua
git commit -m "feat(sk): add convenience startup script

- /sidekick start - launch all modules
- /sidekick stop - stop all modules
- /sidekick restart - restart all modules

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Phase 8: Integration Testing

### Task 8.1: Manual Integration Test

**Test 1: Basic Startup**
1. `/lua run sk_start`
2. `/sidekick start`
3. `/lua list` - Verify all 4 modules running
4. `/sk_coord status` - Verify coordinator state

**Test 2: Healing Flow**
1. In a group, let someone take damage below 80%
2. Watch for:
   - Coordinator priority change to 1
   - Healing module claim request
   - Healing module cast

**Test 3: Emergency Preemption**
1. While healing is casting
2. Damage self below 35% HP
3. Watch for:
   - Emergency module interrupt request
   - Coordinator /stopcast
   - Emergency module claim and AA use

**Test 4: DPS Flow**
1. Engage combat with full HP group
2. Set MA and have MA target mob
3. Watch for:
   - Coordinator priority at 4 (DPS)
   - DPS module claim and cast

**Test 5: Graceful Shutdown**
1. `/sidekick stop`
2. `/lua list` - Verify all modules stopped
3. No error messages

---

## Summary

| Phase | Task | Description |
|-------|------|-------------|
| 1 | 1.1 | sk_lib.lua - shared constants and utilities |
| 2 | 2.1 | sk_coordinator.lua - central arbiter |
| 3 | 3.1 | sk_module_base.lua - module base class |
| 4 | 4.1 | sk_healing.lua - healing module |
| 5 | 5.1 | sk_emergency.lua - emergency module |
| 6 | 6.1 | sk_dps.lua - DPS module |
| 7 | 7.1 | sk_start.lua - startup script |
| 8 | 8.1 | Integration testing |

**Future Phases (v1.1+):**
- sk_resurrection.lua - Priority 2
- sk_debuff.lua - Priority 3
- sk_idle.lua - Priority 5 (meditation)
- sk:result message for debugging
- Hysteresis on priority changes
- Target restore after healing
