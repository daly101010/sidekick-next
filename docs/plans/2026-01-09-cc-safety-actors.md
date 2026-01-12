# Milestone 4a: CC Safety via Actors

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement mez safety across the group via Actors messaging, preventing tanks/DPS from breaking mez with AoE abilities or target swaps.

**Architecture:** The mezzer broadcasts a live "do-not-break" list of mezzed mob IDs with expiry times. All SideKick instances receive this via Actors and integrate it into their runtime cache. The rotation engine and tank module then skip AoE abilities when mezzed mobs are on XTarget.

**Tech Stack:** MacroQuest Lua, Actors messaging (`require('actors')`), runtime_cache integration

---

## Phase 1: CC Tracking Module

### Task 1.1: Create CC Module Structure

**Files:**
- Create: `F:\lua\SideKick\automation\cc.lua`

**Step 1: Create the module skeleton**

```lua
-- F:\lua\SideKick\automation\cc.lua
-- Crowd Control tracking and broadcasting
-- Broadcasts mezzed mob list to group, receives from other mezzers

local mq = require('mq')
local Actors = require('utils.actors_coordinator')

local M = {}

-- Local mez tracking (mobs we mezzed)
M.localMezzes = {}  -- { [mobId] = { expires = os.clock(), name = 'mob name' } }

-- Remote mez tracking (mobs others mezzed)
M.remoteMezzes = {}  -- { [mobId] = { expires = os.clock(), name = 'mob name', mezzer = 'name' } }

-- Combined view (for checking)
M.allMezzes = {}  -- merged view, updated each tick

-- Timing
local _lastBroadcast = 0
local _lastCleanup = 0
local BROADCAST_INTERVAL = 1.0  -- Broadcast every 1 second
local CLEANUP_INTERVAL = 0.5    -- Clean expired every 500ms
local MEZ_DURATION_DEFAULT = 18 -- Default mez duration if unknown

function M.init()
    M.localMezzes = {}
    M.remoteMezzes = {}
    M.allMezzes = {}
end

function M.tick()
    local now = os.clock()

    -- Cleanup expired mezzes
    if (now - _lastCleanup) >= CLEANUP_INTERVAL then
        _lastCleanup = now
        M.cleanupExpired()
    end

    -- Broadcast local mezzes if we have any
    if (now - _lastBroadcast) >= BROADCAST_INTERVAL then
        _lastBroadcast = now
        M.broadcastMezList()
    end

    -- Merge local + remote into allMezzes
    M.mergeAllMezzes()
end

function M.cleanupExpired()
    local now = os.clock()

    for mobId, data in pairs(M.localMezzes) do
        if now >= data.expires then
            M.localMezzes[mobId] = nil
        end
    end

    for mobId, data in pairs(M.remoteMezzes) do
        if now >= data.expires then
            M.remoteMezzes[mobId] = nil
        end
    end
end

function M.mergeAllMezzes()
    M.allMezzes = {}

    for mobId, data in pairs(M.localMezzes) do
        M.allMezzes[mobId] = data
    end

    for mobId, data in pairs(M.remoteMezzes) do
        if not M.allMezzes[mobId] or data.expires > M.allMezzes[mobId].expires then
            M.allMezzes[mobId] = data
        end
    end
end

function M.broadcastMezList()
    -- Only broadcast if we have local mezzes
    if not next(M.localMezzes) then return end

    local mezList = {}
    for mobId, data in pairs(M.localMezzes) do
        mezList[mobId] = {
            expires = data.expires,
            name = data.name,
        }
    end

    Actors.broadcast('cc:mezlist', {
        mobs = mezList,
        sender = mq.TLO.Me.CleanName(),
        timestamp = os.clock(),
    })
end

return M
```

**Step 2: Verify file created**

Run: `dir "F:\lua\SideKick\automation\cc.lua"`
Expected: File exists

---

### Task 1.2: Add Mez Detection Logic

**Files:**
- Modify: `F:\lua\SideKick\automation\cc.lua`

**Step 1: Add mez detection from spell cast**

Add after `M.broadcastMezList()`:

```lua
--- Track a mez we just cast
-- @param mobId number Mob spawn ID
-- @param mobName string Mob name
-- @param duration number Mez duration in seconds (optional)
function M.trackLocalMez(mobId, mobName, duration)
    if not mobId or mobId == 0 then return end

    duration = duration or MEZ_DURATION_DEFAULT

    M.localMezzes[mobId] = {
        expires = os.clock() + duration,
        name = mobName or '',
    }
end

--- Remove a mez (mob died or mez broken)
-- @param mobId number Mob spawn ID
function M.removeMez(mobId)
    M.localMezzes[mobId] = nil
    M.remoteMezzes[mobId] = nil
    M.allMezzes[mobId] = nil
end

--- Check if a mob is mezzed (by anyone)
-- @param mobId number Mob spawn ID
-- @return boolean True if mezzed
function M.isMobMezzed(mobId)
    if not mobId then return false end
    local data = M.allMezzes[mobId]
    if not data then return false end
    return os.clock() < data.expires
end

--- Check if any XTarget mob is mezzed
-- @return boolean True if any XTarget mob is mezzed
function M.hasAnyMezzedOnXTarget()
    local Cache = require('utils.runtime_cache')
    if not Cache or not Cache.xtarget or not Cache.xtarget.haters then
        return false
    end

    for _, hater in pairs(Cache.xtarget.haters) do
        if hater.id and M.isMobMezzed(hater.id) then
            return true
        end
    end

    return false
end

--- Get list of mezzed mob IDs on XTarget
-- @return table Array of mezzed mob IDs
function M.getMezzedOnXTarget()
    local Cache = require('utils.runtime_cache')
    local result = {}

    if not Cache or not Cache.xtarget or not Cache.xtarget.haters then
        return result
    end

    for _, hater in pairs(Cache.xtarget.haters) do
        if hater.id and M.isMobMezzed(hater.id) then
            table.insert(result, hater.id)
        end
    end

    return result
end
```

---

### Task 1.3: Add Actors Message Handler

**Files:**
- Modify: `F:\lua\SideKick\utils\actors_coordinator.lua`

**Step 1: Find the message handler switch**

Look for the mailbox callback where messages are dispatched.

**Step 2: Add cc:mezlist handler**

Add to the message type switch:

```lua
    elseif msgType == 'cc:mezlist' then
        -- Receive mez list from another player
        local CC = require('automation.cc')
        local mobs = payload.mobs or {}
        local sender = payload.sender or 'unknown'
        local now = os.clock()

        for mobId, data in pairs(mobs) do
            local id = tonumber(mobId)
            if id and id > 0 then
                CC.remoteMezzes[id] = {
                    expires = data.expires,
                    name = data.name or '',
                    mezzer = sender,
                }
            end
        end
```

---

## Phase 2: Integration with Runtime Cache

### Task 2.1: Add Mez State to Cache

**Files:**
- Modify: `F:\lua\SideKick\utils\runtime_cache.lua`

**Step 1: Add mez helper functions**

Add before `return M`:

```lua
-- CC Integration

--- Check if any XTarget mob is mezzed
-- Uses CC module if available, falls back to TLO check
function M.hasAnyMezzedOnXTarget()
    local ok, CC = pcall(require, 'automation.cc')
    if ok and CC and CC.hasAnyMezzedOnXTarget then
        return CC.hasAnyMezzedOnXTarget()
    end

    -- Fallback: check TLO directly (less reliable)
    for _, h in pairs(M.xtarget.haters or {}) do
        if h.mezzed then
            return true
        end
    end

    return false
end

--- Check if a specific mob is mezzed
-- @param mobId number Mob spawn ID
-- @return boolean True if mezzed
function M.isMobMezzed(mobId)
    local ok, CC = pcall(require, 'automation.cc')
    if ok and CC and CC.isMobMezzed then
        return CC.isMobMezzed(mobId)
    end

    -- Fallback: check xtarget cache
    for _, h in pairs(M.xtarget.haters or {}) do
        if h.id == mobId and h.mezzed then
            return true
        end
    end

    return false
end
```

---

### Task 2.2: Add Condition Builder Property

**Files:**
- Modify: `F:\lua\SideKick\ui\condition_builder.lua`

**Step 1: Add XTarget.HasMezzedMob property**

Find the `["beneficial:Me"]` section and add:

```lua
    { key = "XTargetHasMezzed", label = "XTarget Has Mezzed Mob", type = "boolean" },
```

**Step 2: Add evaluation logic**

In `evaluateSingleCondition()`, add to the cache lookup section:

```lua
        elseif cond.property == 'XTargetHasMezzed' then
          local ok, CC = pcall(require, 'automation.cc')
          if ok and CC and CC.hasAnyMezzedOnXTarget then
            value = CC.hasAnyMezzedOnXTarget()
          else
            value = false
          end
```

---

## Phase 3: Tank/DPS Safety Gates

### Task 3.1: Add AoE Safety Gate in Tank

**Files:**
- Modify: `F:\lua\SideKick\automation\tank.lua`

**Step 1: Add CC require**

Add to imports:

```lua
local CC = require('automation.cc')
```

**Step 2: Modify handleAggro to check mez state**

In `handleAggro()`, update the AoE section:

```lua
    -- AoE hate gen if 3+ mobs (or configured threshold)
    if unmezzedCount >= (settings.TankAoEThreshold or 3) then
        local shouldAoE = true

        if settings.TankRequireAggroDeficit then
            shouldAoE = (Cache.xtarget.aggroDeficitCount or 0) > 0
        end

        -- Safety check: don't AoE if mezzed mobs on XTarget
        if settings.TankSafeAECheck and CC.hasAnyMezzedOnXTarget() then
            shouldAoE = false
        end

        if shouldAoE then
            M.tryAoEAggroAbility(abilities, settings)
        end
    end
```

---

### Task 3.2: Add Safety Gate in Rotation Engine

**Files:**
- Modify: `F:\lua\SideKick\utils\rotation_engine.lua`

**Step 1: Add CC-aware layer condition for aggro**

Update `shouldLayerRun()` for the aggro layer:

```lua
    -- Aggro: only when tanking and in combat
    if name == 'aggro' then
        local isTanking = state.combatMode == 'tank'
        local inCombat = Cache and Cache.inCombat() or false
        if not isTanking or not inCombat then return false end

        -- Check if safe AE mode is on and we have mezzed mobs
        if state.tankSafeAECheck then
            local ok, CC = pcall(require, 'automation.cc')
            if ok and CC and CC.hasAnyMezzedOnXTarget and CC.hasAnyMezzedOnXTarget() then
                -- Still allow single-target aggro, skip layer for now
                -- (single-target abilities can check individually)
            end
        end

        return true
    end
```

**Step 2: Update state initialization**

In `M.tick()`, add to state:

```lua
    local state = {
        burnActive = opts.burnActive or opts.burn,
        combatMode = settings.CombatMode or 'off',
        emergencyHpThreshold = settings.EmergencyHpThreshold or 35,
        defenseHpThreshold = settings.DefenseHpThreshold or 70,
        tankSafeAECheck = settings.TankSafeAECheck or false,
    }
```

---

## Phase 4: Main Loop Integration

### Task 4.1: Integrate CC Module into Main Loop

**Files:**
- Modify: `F:\lua\SideKick\SideKick.lua`

**Step 1: Add require**

Add to imports:

```lua
local CC = require('automation.cc')
```

**Step 2: Add init**

In `main()`, after other inits:

```lua
    CC.init()
```

**Step 3: Add tick**

In `tickAutomation()`, after RuntimeCache.tick():

```lua
    CC.tick()
```

---

### Task 4.2: Add Debug Command for CC State

**Files:**
- Modify: `F:\lua\SideKick\SideKick.lua`

**Step 1: Add debug command**

In the bind command handler, add:

```lua
        elseif a1 == 'cc' then
            -- Debug command: show CC/mez state
            local CC = require('automation.cc')
            local localCount = 0
            local remoteCount = 0
            for _ in pairs(CC.localMezzes) do localCount = localCount + 1 end
            for _ in pairs(CC.remoteMezzes) do remoteCount = remoteCount + 1 end

            print(string.format('[CC] Local mezzes: %d, Remote mezzes: %d', localCount, remoteCount))
            print(string.format('[CC] Has mezzed on XTarget: %s', tostring(CC.hasAnyMezzedOnXTarget())))

            for mobId, data in pairs(CC.allMezzes) do
                local remaining = data.expires - os.clock()
                print(string.format('  [%d] %s - %.1fs remaining (by %s)',
                    mobId, data.name or 'unknown', remaining, data.mezzer or 'self'))
            end
```

---

## Phase 5: Testing

### Task 5.1: Manual Testing Checklist

**Files:**
- None (manual testing)

**Testing Steps:**

1. **Load SideKick on multiple characters**
   - Run: `/lua run sidekick` on tank and mezzer
   - Expected: No errors on load

2. **Test CC Broadcast (Mezzer)**
   - Mez a mob manually
   - Run: `/sidekick cc`
   - Expected: Shows local mez with expiry time

3. **Test CC Receive (Tank)**
   - Have mezzer mez a mob
   - On tank, run: `/sidekick cc`
   - Expected: Shows remote mez from mezzer's name

4. **Test AoE Safety Gate**
   - Enable TankSafeAECheck in settings
   - Have mezzer mez a mob on XTarget
   - Verify tank doesn't use AoE abilities
   - After mez expires, verify AoE resumes

5. **Test Condition Builder**
   - Create ability with condition "XTarget Has Mezzed Mob"
   - Verify ability fires only when no mezzed mobs

---

## Summary

This plan implements CC safety via Actors messaging:

1. **CC Module** (`automation/cc.lua`): Tracks local and remote mezzes with expiry
2. **Actors Integration**: Broadcasts `cc:mezlist` messages, receives from other mezzers
3. **Cache Integration**: `hasAnyMezzedOnXTarget()` and `isMobMezzed()` helpers
4. **Tank Safety**: Skips AoE abilities when TankSafeAECheck is enabled and mezzed mobs present
5. **Condition Builder**: New `XTargetHasMezzed` property for user-defined conditions
6. **Debug Commands**: `/sidekick cc` to inspect mez state

The system is designed to be:
- **Non-intrusive**: Tank/DPS characters don't need to actively track mezzes
- **Fault-tolerant**: Falls back to TLO checks if CC module unavailable
- **User-configurable**: TankSafeAECheck toggle, plus condition builder for custom logic
