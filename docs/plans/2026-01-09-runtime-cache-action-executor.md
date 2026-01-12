# Runtime Cache & Action Executor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create a shared runtime cache ("blackboard") for expensive TLO queries and a channel-based action executor to prevent ability spam and enable future spell/heal/CC integration.

**Architecture:** The runtime cache computes expensive game state queries on a cadence (250-500ms for heavy scans, 50-100ms for lightweight), then all modules read from it instead of doing redundant TLO calls. The action executor uses "channels" (melee, aa_disc, spell, item) with lockouts to ensure only one action per channel fires per tick, preventing spam bursts while maintaining responsiveness.

**Tech Stack:** MacroQuest Lua, mq.TLO for game state, os.clock() for timing

---

## Phase 1: Runtime Cache (Blackboard)

### Task 1.1: Create Runtime Cache Module Structure

**Files:**
- Create: `F:/lua/SideKick/utils/runtime_cache.lua`

**Step 1: Create the module skeleton**

```lua
-- F:/lua/SideKick/utils/runtime_cache.lua
-- Runtime Cache (Blackboard) - Centralized game state snapshot
-- Computes expensive TLO queries on a cadence, all modules read from here

local mq = require('mq')

local M = {}

-- Cache data
M.me = {}
M.target = {}
M.group = {}
M.xtarget = {}

-- Timing
local _lastHeavyUpdate = 0
local _lastLightUpdate = 0
local HEAVY_INTERVAL = 0.25  -- 250ms for expensive scans
local LIGHT_INTERVAL = 0.05  -- 50ms for lightweight checks

function M.init()
    M.me = {}
    M.target = {}
    M.group = {}
    M.xtarget = {}
end

function M.tick()
    local now = os.clock()

    -- Light update (every 50ms)
    if (now - _lastLightUpdate) >= LIGHT_INTERVAL then
        _lastLightUpdate = now
        M.updateLight()
    end

    -- Heavy update (every 250ms)
    if (now - _lastHeavyUpdate) >= HEAVY_INTERVAL then
        _lastHeavyUpdate = now
        M.updateHeavy()
    end
end

function M.updateLight()
    -- Lightweight checks - called frequently
end

function M.updateHeavy()
    -- Expensive scans - called less frequently
end

return M
```

**Step 2: Verify file created**

Run: `dir "F:\lua\SideKick\utils\runtime_cache.lua"`
Expected: File exists

**Step 3: Commit**

```bash
git add F:/lua/SideKick/utils/runtime_cache.lua
git commit -m "feat(cache): add runtime cache module skeleton"
```

---

### Task 1.2: Implement Me Snapshot (Light Update)

**Files:**
- Modify: `F:/lua/SideKick/utils/runtime_cache.lua`

**Step 1: Add Me snapshot to updateLight**

```lua
function M.updateLight()
    local me = mq.TLO.Me
    if not me or not me() then
        M.me = {}
        return
    end

    M.me = {
        id = me.ID() or 0,
        name = me.CleanName() or '',
        class = me.Class.ShortName() or '',
        level = me.Level() or 0,

        -- Resources (checked frequently for heals/burns)
        hp = me.PctHPs() or 0,
        mana = me.PctMana() or 0,
        endur = me.PctEndurance() or 0,

        -- Combat state
        combat = me.Combat() == true,
        casting = me.Casting() and me.Casting() ~= '' or false,
        moving = me.Moving() == true,
        sitting = me.Sitting() == true,

        -- Aggro (important for tank/assist decisions)
        pctAggro = me.PctAggro() or 0,
        secondaryPctAggro = me.SecondaryPctAggro() or 0,
    }
end
```

**Step 2: Test by adding debug print**

Add temporarily to verify:
```lua
-- In M.tick() after updateLight:
if M.me.id and M.me.id > 0 then
    -- print(string.format('[Cache] Me: %s HP:%d Mana:%d Combat:%s', M.me.name, M.me.hp, M.me.mana, tostring(M.me.combat)))
end
```

**Step 3: Commit**

```bash
git add F:/lua/SideKick/utils/runtime_cache.lua
git commit -m "feat(cache): add Me snapshot to light update"
```

---

### Task 1.3: Implement Target Snapshot (Light Update)

**Files:**
- Modify: `F:/lua/SideKick/utils/runtime_cache.lua`

**Step 1: Add Target snapshot to updateLight**

Add to `updateLight()` function:

```lua
    -- Target snapshot
    local target = mq.TLO.Target
    if target and target() and target.ID() > 0 then
        M.target = {
            id = target.ID() or 0,
            name = target.CleanName() or '',
            type = target.Type() or '',
            level = target.Level() or 0,
            hp = target.PctHPs() or 100,
            distance = target.Distance() or 999,
            los = target.LineOfSight() == true,
            named = target.Named() == true,

            -- Debuff state (for CC/tank decisions)
            mezzed = (target.Mezzed and target.Mezzed() and target.Mezzed() ~= '') or false,
            slowed = (target.Slowed and target.Slowed() and target.Slowed() ~= '') or false,
            rooted = (target.Rooted and target.Rooted() and target.Rooted() ~= '') or false,

            -- Target of target (for aggro decisions)
            totId = target.TargetOfTarget and target.TargetOfTarget.ID and target.TargetOfTarget.ID() or 0,
        }
    else
        M.target = {}
    end
```

**Step 2: Commit**

```bash
git add F:/lua/SideKick/utils/runtime_cache.lua
git commit -m "feat(cache): add Target snapshot to light update"
```

---

### Task 1.4: Implement Group Snapshot (Heavy Update)

**Files:**
- Modify: `F:/lua/SideKick/utils/runtime_cache.lua`

**Step 1: Add Group snapshot to updateHeavy**

```lua
function M.updateHeavy()
    -- Group snapshot
    local memberCount = mq.TLO.Group.Members() or 0
    local members = {}
    local injuredCount = 0
    local injuredThreshold = 80  -- Consider injured below 80%
    local centroidX, centroidY, centroidCount = 0, 0, 0
    local myId = M.me.id or 0

    for i = 1, memberCount do
        local member = mq.TLO.Group.Member(i)
        if member and member() then
            local hp = member.PctHPs() or 100
            local memberId = member.ID() or 0

            members[i] = {
                id = memberId,
                name = member.CleanName() or '',
                class = member.Class and member.Class.ShortName() or '',
                hp = hp,
                distance = member.Distance() or 999,
            }

            if hp < injuredThreshold then
                injuredCount = injuredCount + 1
            end

            -- Centroid calculation (exclude self)
            if memberId ~= myId and memberId > 0 then
                centroidX = centroidX + (member.X() or 0)
                centroidY = centroidY + (member.Y() or 0)
                centroidCount = centroidCount + 1
            end
        end
    end

    M.group = {
        count = memberCount,
        members = members,
        injuredCount = injuredCount,
        centroidX = centroidCount > 0 and (centroidX / centroidCount) or nil,
        centroidY = centroidCount > 0 and (centroidY / centroidCount) or nil,
    }
end
```

**Step 2: Commit**

```bash
git add F:/lua/SideKick/utils/runtime_cache.lua
git commit -m "feat(cache): add Group snapshot to heavy update"
```

---

### Task 1.5: Implement XTarget Snapshot (Heavy Update)

**Files:**
- Modify: `F:/lua/SideKick/utils/runtime_cache.lua`

**Step 1: Add XTarget snapshot to updateHeavy**

Add to `updateHeavy()` function:

```lua
    -- XTarget snapshot
    local xtCount = mq.TLO.Me.XTarget() or 0
    local haters = {}
    local haterCount = 0
    local aggroDeficitCount = 0
    local myId = M.me.id or 0

    for i = 1, xtCount do
        local xt = mq.TLO.Me.XTarget(i)
        if xt and xt.ID() and xt.ID() > 0 then
            local aggro = xt.PctAggro() or 100
            local totId = xt.TargetOfTarget and xt.TargetOfTarget.ID and xt.TargetOfTarget.ID() or 0

            haters[i] = {
                id = xt.ID(),
                name = xt.CleanName() or '',
                hp = xt.PctHPs() or 100,
                distance = xt.Distance() or 999,
                aggro = aggro,
                targetingMe = totId == myId,
                mezzed = (xt.Mezzed and xt.Mezzed() and xt.Mezzed() ~= '') or false,
            }
            haterCount = haterCount + 1

            if aggro < 100 then
                aggroDeficitCount = aggroDeficitCount + 1
            end
        end
    end

    M.xtarget = {
        count = haterCount,
        haters = haters,
        aggroDeficitCount = aggroDeficitCount,
    }
```

**Step 2: Commit**

```bash
git add F:/lua/SideKick/utils/runtime_cache.lua
git commit -m "feat(cache): add XTarget snapshot to heavy update"
```

---

### Task 1.6: Add Convenience Accessor Functions

**Files:**
- Modify: `F:/lua/SideKick/utils/runtime_cache.lua`

**Step 1: Add accessor functions**

Add at end of module before `return M`:

```lua
-- Convenience accessors

--- Check if player is in combat
function M.inCombat()
    return M.me.combat == true or (M.xtarget.count or 0) > 0
end

--- Check if target is named
function M.isTargetNamed()
    return M.target.named == true
end

--- Check if tank aggro lead is low (needs hate gen)
function M.aggroLeadLow()
    return (M.me.pctAggro or 100) < 100 or (M.me.secondaryPctAggro or 0) > 80
end

--- Get count of unmezzed mobs on XTarget
function M.unmezzedHaterCount()
    local count = 0
    for _, h in pairs(M.xtarget.haters or {}) do
        if not h.mezzed then
            count = count + 1
        end
    end
    return count
end

--- Check if Me has enough resources for ability
function M.hasResources(hpMin, manaMin, endurMin)
    hpMin = hpMin or 0
    manaMin = manaMin or 0
    endurMin = endurMin or 0
    return (M.me.hp or 0) >= hpMin
       and (M.me.mana or 0) >= manaMin
       and (M.me.endur or 0) >= endurMin
end

--- Get injured group member count below threshold
function M.injuredGroupCount(threshold)
    threshold = threshold or 80
    local count = 0
    for _, m in pairs(M.group.members or {}) do
        if (m.hp or 100) < threshold then
            count = count + 1
        end
    end
    return count
end
```

**Step 2: Commit**

```bash
git add F:/lua/SideKick/utils/runtime_cache.lua
git commit -m "feat(cache): add convenience accessor functions"
```

---

## Phase 2: Action Executor with Channels

### Task 2.1: Create Action Executor Module Structure

**Files:**
- Create: `F:/lua/SideKick/utils/action_executor.lua`

**Step 1: Create the module skeleton**

```lua
-- F:/lua/SideKick/utils/action_executor.lua
-- Action Executor - Channel-based action execution with lockouts
-- Prevents spam, ensures proper sequencing, enables future spell integration

local mq = require('mq')

local M = {}

-- Channels with independent lockouts
local CHANNELS = {
    melee = { lastAction = 0, lockout = 0.1 },    -- 100ms between melee actions
    aa_disc = { lastAction = 0, lockout = 0.1 },  -- 100ms between AA/disc
    spell = { lastAction = 0, lockout = 0.5 },    -- 500ms between spell casts (GCD)
    item = { lastAction = 0, lockout = 0.2 },     -- 200ms between item clicks
}

-- Global casting lock (can't do most actions while casting)
local _casting = false
local _castEndTime = 0

function M.init()
    for _, ch in pairs(CHANNELS) do
        ch.lastAction = 0
    end
    _casting = false
    _castEndTime = 0
end

--- Check if a channel is ready for action
-- @param channel string Channel name ('melee', 'aa_disc', 'spell', 'item')
-- @return boolean True if channel can execute
function M.isChannelReady(channel)
    local ch = CHANNELS[channel]
    if not ch then return false end

    local now = os.clock()

    -- Global casting lock (except melee)
    if channel ~= 'melee' and _casting and now < _castEndTime then
        return false
    end

    return (now - ch.lastAction) >= ch.lockout
end

--- Mark a channel as used (start lockout)
-- @param channel string Channel name
function M.markChannelUsed(channel)
    local ch = CHANNELS[channel]
    if ch then
        ch.lastAction = os.clock()
    end
end

--- Set casting state (blocks other channels during cast)
-- @param casting boolean Is currently casting
-- @param duration number Cast duration in seconds (optional)
function M.setCasting(casting, duration)
    _casting = casting
    if casting and duration then
        _castEndTime = os.clock() + duration
    elseif not casting then
        _castEndTime = 0
    end
end

--- Check if currently casting
function M.isCasting()
    if _casting and os.clock() >= _castEndTime then
        _casting = false
    end
    return _casting
end

return M
```

**Step 2: Commit**

```bash
git add F:/lua/SideKick/utils/action_executor.lua
git commit -m "feat(executor): add action executor module skeleton"
```

---

### Task 2.2: Add AA/Disc Execution Function

**Files:**
- Modify: `F:/lua/SideKick/utils/action_executor.lua`

**Step 1: Add execute function for AA/Disc**

```lua
--- Execute an AA ability
-- @param altId number Alt ability ID
-- @return boolean True if executed
function M.executeAA(altId)
    if not altId then return false end
    if not M.isChannelReady('aa_disc') then return false end

    local me = mq.TLO.Me
    if not me or not me() then return false end
    if not me.AltAbilityReady(altId)() then return false end

    mq.cmdf('/alt activate %d', altId)
    M.markChannelUsed('aa_disc')
    return true
end

--- Execute a discipline
-- @param discName string Discipline name
-- @return boolean True if executed
function M.executeDisc(discName)
    if not discName or discName == '' then return false end
    if not M.isChannelReady('aa_disc') then return false end

    local me = mq.TLO.Me
    if not me or not me() then return false end
    if not me.CombatAbilityReady(discName)() then return false end

    mq.cmdf('/disc %s', discName)
    M.markChannelUsed('aa_disc')
    return true
end

--- Execute an ability from definition table
-- @param def table Ability definition with kind, altID/discName
-- @return boolean True if executed
function M.executeAbility(def)
    if not def then return false end

    local kind = tostring(def.kind or 'aa')

    if kind == 'aa' then
        return M.executeAA(tonumber(def.altID))
    elseif kind == 'disc' then
        return M.executeDisc(def.discName or def.altName)
    end

    return false
end
```

**Step 2: Commit**

```bash
git add F:/lua/SideKick/utils/action_executor.lua
git commit -m "feat(executor): add AA/disc execution functions"
```

---

### Task 2.3: Add Item Execution Function

**Files:**
- Modify: `F:/lua/SideKick/utils/action_executor.lua`

**Step 1: Add execute function for items**

```lua
--- Execute an item click
-- @param itemName string Item name
-- @return boolean True if executed
function M.executeItem(itemName)
    if not itemName or itemName == '' then return false end
    if not M.isChannelReady('item') then return false end

    local item = mq.TLO.FindItem(itemName)
    if not item or not item() then return false end
    if item.TimerReady() ~= 0 then return false end  -- 0 means ready

    mq.cmdf('/useitem "%s"', itemName)
    M.markChannelUsed('item')
    return true
end

--- Execute an item click by slot
-- @param slotName string Slot name (e.g., 'charm', 'pack1')
-- @return boolean True if executed
function M.executeItemSlot(slotName)
    if not slotName or slotName == '' then return false end
    if not M.isChannelReady('item') then return false end

    local item = mq.TLO.InvSlot(slotName).Item
    if not item or not item() then return false end
    if item.TimerReady() ~= 0 then return false end

    mq.cmdf('/itemnotify %s rightmouseup', slotName)
    M.markChannelUsed('item')
    return true
end
```

**Step 2: Commit**

```bash
git add F:/lua/SideKick/utils/action_executor.lua
git commit -m "feat(executor): add item execution functions"
```

---

### Task 2.4: Add Melee Ability Execution

**Files:**
- Modify: `F:/lua/SideKick/utils/action_executor.lua`

**Step 1: Add melee ability execution**

```lua
--- Execute a melee ability (Taunt, Kick, Bash, etc.)
-- @param abilityName string Ability name
-- @return boolean True if executed
function M.executeMeleeAbility(abilityName)
    if not abilityName or abilityName == '' then return false end
    if not M.isChannelReady('melee') then return false end

    local me = mq.TLO.Me
    if not me or not me() then return false end
    if not me.AbilityReady(abilityName)() then return false end

    mq.cmdf('/doability %s', abilityName)
    M.markChannelUsed('melee')
    return true
end

--- Execute Taunt specifically (commonly used)
-- @return boolean True if executed
function M.executeTaunt()
    return M.executeMeleeAbility('Taunt')
end

--- Execute Kick
-- @return boolean True if executed
function M.executeKick()
    return M.executeMeleeAbility('Kick')
end
```

**Step 2: Commit**

```bash
git add F:/lua/SideKick/utils/action_executor.lua
git commit -m "feat(executor): add melee ability execution"
```

---

## Phase 3: Integration

### Task 3.1: Integrate Runtime Cache into Main Loop

**Files:**
- Modify: `F:/lua/SideKick/SideKick.lua`

**Step 1: Add require and init**

Near the top imports (around line 15):
```lua
local RuntimeCache = require('utils.runtime_cache')
```

In `main()` function after other inits (around line 1035):
```lua
    RuntimeCache.init()
```

**Step 2: Add tick to automation loop**

In `tickAutomation()` function (around line 813), add at the start:
```lua
    RuntimeCache.tick()
```

**Step 3: Commit**

```bash
git add F:/lua/SideKick/SideKick.lua
git commit -m "feat: integrate runtime cache into main loop"
```

---

### Task 3.2: Integrate Action Executor into Main Loop

**Files:**
- Modify: `F:/lua/SideKick/SideKick.lua`

**Step 1: Add require and init**

Near the top imports:
```lua
local ActionExecutor = require('utils.action_executor')
```

In `main()` function after other inits:
```lua
    ActionExecutor.init()
```

**Step 2: Commit**

```bash
git add F:/lua/SideKick/SideKick.lua
git commit -m "feat: integrate action executor into main loop"
```

---

### Task 3.3: Update Tank Module to Use Cache

**Files:**
- Modify: `F:/lua/SideKick/automation/tank.lua`

**Step 1: Add require**

```lua
local Cache = require('utils.runtime_cache')
```

**Step 2: Replace direct TLO calls with cache reads**

In `handleAggro()`, replace:
```lua
local unmezzedCount = Aggro.countUnmezzedMobs(100) or 0
```

With:
```lua
local unmezzedCount = Cache.unmezzedHaterCount()
```

In aggro deficit check, replace:
```lua
shouldAoE = Aggro.countMobsWithAggroDeficit() > 0
```

With:
```lua
shouldAoE = (Cache.xtarget.aggroDeficitCount or 0) > 0
```

In `aggroLeadLow()` calls, use:
```lua
Cache.aggroLeadLow()
```

**Step 3: Commit**

```bash
git add F:/lua/SideKick/automation/tank.lua
git commit -m "refactor(tank): use runtime cache instead of direct TLO calls"
```

---

### Task 3.4: Update Tank Module to Use Action Executor

**Files:**
- Modify: `F:/lua/SideKick/automation/tank.lua`

**Step 1: Add require**

```lua
local Executor = require('utils.action_executor')
```

**Step 2: Replace direct ability activation with executor**

In `tryAoEAggroAbility()` and `trySingleAggroAbility()`, replace:
```lua
activateAbility(def)
return true
```

With:
```lua
if Executor.executeAbility(def) then
    return true
end
```

In `stateTauntExecute()`, replace:
```lua
Aggro.doTaunt()
```

With:
```lua
Executor.executeTaunt()
```

**Step 3: Commit**

```bash
git add F:/lua/SideKick/automation/tank.lua
git commit -m "refactor(tank): use action executor for ability activation"
```

---

### Task 3.5: Update Condition Builder with Cache Properties

**Files:**
- Modify: `F:/lua/SideKick/ui/condition_builder.lua`

**Step 1: Add new properties for aggro/combat**

Find `M.properties` table and add to `["beneficial:Me"]`:

```lua
    { key = "PctAggro", label = "Aggro %", type = "numeric", isPercent = true, min = 0, max = 100 },
    { key = "SecondaryPctAggro", label = "Secondary Aggro %", type = "numeric", isPercent = true, min = 0, max = 100 },
    { key = "XTargetHaterCount", label = "XTarget Haters", type = "numeric", min = 0, max = 20 },
```

**Step 2: Update evaluate to use cache when available**

In `evaluateSingleCondition()`, add cache lookup fallback:

```lua
-- Try to get value from runtime cache first (if loaded)
local ok, Cache = pcall(require, 'utils.runtime_cache')
if ok and Cache and Cache.me then
    if propDef.key == 'PctAggro' then
        return Cache.me.pctAggro or 0
    elseif propDef.key == 'SecondaryPctAggro' then
        return Cache.me.secondaryPctAggro or 0
    elseif propDef.key == 'XTargetHaterCount' then
        return Cache.xtarget.count or 0
    end
end
```

**Step 3: Commit**

```bash
git add F:/lua/SideKick/ui/condition_builder.lua
git commit -m "feat(conditions): add aggro/combat properties from cache"
```

---

## Phase 4: Testing & Verification

### Task 4.1: Add Debug Commands

**Files:**
- Modify: `F:/lua/SideKick/SideKick.lua`

**Step 1: Add debug command for cache inspection**

In the bind command handler (around line 1029), add:

```lua
        elseif a1 == 'cache' then
            local Cache = require('utils.runtime_cache')
            print(string.format('[Cache] Me: %s HP:%d Mana:%d Aggro:%d Combat:%s',
                Cache.me.name or 'nil', Cache.me.hp or 0, Cache.me.mana or 0,
                Cache.me.pctAggro or 0, tostring(Cache.me.combat)))
            print(string.format('[Cache] Target: %s HP:%d Named:%s Mezzed:%s',
                Cache.target.name or 'none', Cache.target.hp or 0,
                tostring(Cache.target.named), tostring(Cache.target.mezzed)))
            print(string.format('[Cache] Group: %d members, %d injured',
                Cache.group.count or 0, Cache.group.injuredCount or 0))
            print(string.format('[Cache] XTarget: %d haters, %d aggro deficit',
                Cache.xtarget.count or 0, Cache.xtarget.aggroDeficitCount or 0))
```

**Step 2: Commit**

```bash
git add F:/lua/SideKick/SideKick.lua
git commit -m "feat: add /sidekick cache debug command"
```

---

### Task 4.2: Manual Testing Checklist

**Files:**
- None (manual testing)

**Testing Steps:**

1. **Load SideKick**
   - Run: `/lua run sidekick`
   - Expected: No errors on load

2. **Test Cache Updates**
   - Run: `/sidekick cache`
   - Expected: Cache data printed showing Me/Target/Group/XTarget snapshots
   - Verify HP/Mana values match actual values

3. **Test with Target**
   - Target an NPC
   - Run: `/sidekick cache`
   - Expected: Target data shows NPC name, HP, distance

4. **Test Combat Mode**
   - Engage a mob
   - Run: `/sidekick cache`
   - Expected: Combat=true, XTarget count > 0

5. **Test Tank Mode**
   - Set CombatMode to 'tank'
   - Engage multiple mobs
   - Expected: Tank uses abilities without spam (respects channel lockouts)

6. **Test Condition Builder**
   - Create condition with "My Aggro % < 100"
   - Expected: Condition evaluates correctly using cache data

---

## Summary

This plan implements:

1. **Runtime Cache (`runtime_cache.lua`)**
   - Me snapshot: HP/Mana/Endur, aggro %, combat state
   - Target snapshot: HP, named, mezzed, distance, target-of-target
   - Group snapshot: member HP, injured count, centroid
   - XTarget snapshot: hater count, aggro deficit count
   - Light update (50ms) for frequently-needed data
   - Heavy update (250ms) for expensive scans

2. **Action Executor (`action_executor.lua`)**
   - Channel-based lockouts: melee, aa_disc, spell, item
   - Prevents spam while maintaining responsiveness
   - Casting lock for spell channel integration (future)
   - Ready for spell engine expansion

3. **Integration**
   - Cache ticks in main automation loop
   - Tank module uses cache instead of redundant TLO calls
   - Tank module uses executor for ability activation
   - Condition builder can evaluate aggro-based conditions

**Future Expansion Points:**
- Spell channel for heals/nukes/buffs
- Heal engine using group snapshot
- CC engine using XTarget mezzed tracking
- Buff engine using light update timing
