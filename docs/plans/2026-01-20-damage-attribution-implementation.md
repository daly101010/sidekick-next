# Damage Attribution System Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Track which mobs are attacking which group members, validate DPS accuracy, and detect AE damage patterns to improve healing decisions.

**Architecture:** New `damage_attribution.lua` module handles mob-to-target tracking with XTarget-based name resolution. Integrates with existing `target_monitor.lua` for HP delta comparison and `heal_selector.lua` for enhanced scoring.

**Tech Stack:** MQ Lua, mq.event for damage parsing, mq.TLO.XTarget for mob resolution

---

## Task 1: Create damage_attribution.lua Core Structure

**Files:**
- Create: `healing/damage_attribution.lua`

**Step 1: Create the module with data structures and initialization**

```lua
-- healing/damage_attribution.lua
local mq = require('mq')

local M = {}

local Config = nil

-- Combat timeout tracking
local _lastDamageEvent = 0
local COMBAT_TIMEOUT = 5  -- seconds
local WINDOW_DURATION = 3  -- seconds for DPS calculation

-- Per-target damage attribution
local _targetDamage = {}  -- [targetId] = { sources = {}, sourceCount, totalDps, ... }

-- AE damage tracking (same mob hitting multiple targets)
local _aeDamage = {}  -- [mobId] = { targets = {}, isAE, totalDps }

-- Mob name-to-ID resolution cache
local _mobNameCache = {}  -- [mobName] = { id, lastSeen }

function M.init(config)
    Config = config
    COMBAT_TIMEOUT = Config and Config.combatTimeoutSec or 5
    WINDOW_DURATION = Config and Config.dpsWindowSec or 3
    _targetDamage = {}
    _aeDamage = {}
    _mobNameCache = {}
    _lastDamageEvent = 0
end

return M
```

**Step 2: Verify module loads**

Run in-game: `/lua run sidekick` and check no errors in MQ console.

**Step 3: Commit**

```bash
git add healing/damage_attribution.lua
git commit -m "feat(healing): add damage_attribution module skeleton"
```

---

## Task 2: Add Mob Name Resolution

**Files:**
- Modify: `healing/damage_attribution.lua`

**Step 1: Add mob cache refresh function**

Add after the init function:

```lua
-- Refresh mob name cache from XTarget
local function refreshMobCache()
    local now = mq.gettime()
    local me = mq.TLO.Me
    if not me or not me() then return end

    local xtCount = tonumber(me.XTarget()) or 0
    for i = 1, xtCount do
        local xt = me.XTarget(i)
        if xt and xt() and xt.ID() and xt.ID() > 0 then
            local name = xt.CleanName() or xt.Name()
            local id = xt.ID()
            if name and id then
                _mobNameCache[name] = { id = id, lastSeen = now }
            end
        end
    end
end

-- Resolve attacker name to mob ID
local function resolveMobId(attackerName)
    if not attackerName then return nil end

    local cached = _mobNameCache[attackerName]
    if cached then return cached.id end

    -- Fallback: direct spawn lookup
    local spawn = mq.TLO.Spawn('npc "' .. attackerName .. '"')
    if spawn and spawn() and spawn.ID() > 0 then
        return spawn.ID()
    end

    return nil
end
```

**Step 2: Commit**

```bash
git add healing/damage_attribution.lua
git commit -m "feat(healing): add mob name-to-ID resolution via XTarget"
```

---

## Task 3: Add Target Name Resolution

**Files:**
- Modify: `healing/damage_attribution.lua`

**Step 1: Add target resolution function**

Add after resolveMobId:

```lua
-- Find target ID by name (group members only)
local function findTargetIdByName(name)
    if not name or name == '' then return nil end

    -- Handle "YOU" as self
    if name == 'YOU' or name == 'you' then
        local me = mq.TLO.Me
        if me and me() and me.ID() then
            return me.ID()
        end
        return nil
    end

    -- Check self
    local me = mq.TLO.Me
    if me and me() then
        local myName = me.CleanName()
        if myName and myName == name then
            return me.ID()
        end
    end

    -- Check group members
    local groupCount = tonumber(mq.TLO.Group.Members()) or 0
    for i = 1, groupCount do
        local member = mq.TLO.Group.Member(i)
        if member and member() then
            local memberName = member.CleanName() or member.Name()
            if memberName and memberName == name then
                local spawn = member.Spawn and member.Spawn() or member
                if spawn and spawn() and spawn.ID then
                    return spawn.ID()
                end
            end
        end
    end

    return nil
end
```

**Step 2: Commit**

```bash
git add healing/damage_attribution.lua
git commit -m "feat(healing): add target name resolution for group members"
```

---

## Task 4: Add Combat Timeout Check

**Files:**
- Modify: `healing/damage_attribution.lua`

**Step 1: Add combat timeout function**

Add after findTargetIdByName:

```lua
-- Check if combat has timed out (no damage for N seconds)
local function checkCombatTimeout()
    local now = mq.gettime()
    if _lastDamageEvent > 0 and (now - _lastDamageEvent) > COMBAT_TIMEOUT then
        -- Clear all attribution data
        _targetDamage = {}
        _aeDamage = {}
        _mobNameCache = {}
        _lastDamageEvent = 0
    end
end
```

**Step 2: Commit**

```bash
git add healing/damage_attribution.lua
git commit -m "feat(healing): add combat timeout to clear attribution data"
```

---

## Task 5: Add Damage Recording Function

**Files:**
- Modify: `healing/damage_attribution.lua`

**Step 1: Add recordDamage function**

Add after checkCombatTimeout:

```lua
-- Record a damage event
function M.recordDamage(targetName, amount, attackerName, dmgType)
    if not amount or amount <= 0 then return end

    local now = mq.gettime()
    _lastDamageEvent = now

    -- Ignore outgoing damage (we're the attacker)
    if attackerName == 'You' or attackerName == 'you' then
        return
    end

    -- Resolve target
    local targetId = findTargetIdByName(targetName)
    if not targetId then return end  -- Not a group member we track

    -- Resolve mob
    local mobId = resolveMobId(attackerName)
    local sourceKey = mobId or ('unknown_' .. (attackerName or '?'))

    -- Initialize target tracking
    if not _targetDamage[targetId] then
        _targetDamage[targetId] = {
            sources = {},
            sourceCount = 0,
            totalDps = 0,
            primarySourceId = nil,
            primarySourceDps = 0,
            isMultiSource = false,
        }
    end

    local targetData = _targetDamage[targetId]

    -- Initialize source tracking
    if not targetData.sources[sourceKey] then
        targetData.sources[sourceKey] = {
            mobId = mobId,
            mobName = attackerName,
            lastHit = now,
            dps = 0,
            entries = {},
        }
    end

    local sourceData = targetData.sources[sourceKey]
    sourceData.lastHit = now
    table.insert(sourceData.entries, {
        time = now,
        amount = amount,
        dmgType = dmgType,
    })

    -- Track for AE detection (only if we have a mobId)
    if mobId then
        if not _aeDamage[mobId] then
            _aeDamage[mobId] = {
                targets = {},
                activeTargetCount = 0,
                isAE = false,
                totalDps = 0,
            }
        end
        _aeDamage[mobId].targets[targetId] = now
    end
end
```

**Step 2: Commit**

```bash
git add healing/damage_attribution.lua
git commit -m "feat(healing): add damage recording with mob attribution"
```

---

## Task 6: Add DPS Calculation

**Files:**
- Modify: `healing/damage_attribution.lua`

**Step 1: Add DPS calculation function**

Add after recordDamage:

```lua
-- Calculate DPS for a specific target
local function calculateTargetDps(targetId)
    local targetData = _targetDamage[targetId]
    if not targetData then return end

    local now = mq.gettime()
    local cutoff = now - WINDOW_DURATION

    local activeSourceCount = 0
    local totalDps = 0
    local primaryId = nil
    local primaryDps = 0

    for sourceKey, sourceData in pairs(targetData.sources) do
        -- Prune old entries, sum recent damage
        local recentDamage = 0
        local recentEntries = {}

        for _, entry in ipairs(sourceData.entries) do
            if entry.time >= cutoff then
                table.insert(recentEntries, entry)
                recentDamage = recentDamage + entry.amount
            end
        end
        sourceData.entries = recentEntries

        -- Calculate this source's DPS
        local sourceDps = recentDamage / WINDOW_DURATION
        sourceData.dps = sourceDps

        if #recentEntries > 0 then
            activeSourceCount = activeSourceCount + 1
            totalDps = totalDps + sourceDps

            if sourceDps > primaryDps then
                primaryDps = sourceDps
                primaryId = sourceKey
            end
        end
    end

    -- Update aggregate fields
    targetData.sourceCount = activeSourceCount
    targetData.totalDps = totalDps
    targetData.primarySourceId = primaryId
    targetData.primarySourceDps = primaryDps
    targetData.isMultiSource = activeSourceCount >= 2
end
```

**Step 2: Commit**

```bash
git add healing/damage_attribution.lua
git commit -m "feat(healing): add per-target DPS calculation"
```

---

## Task 7: Add AE Detection

**Files:**
- Modify: `healing/damage_attribution.lua`

**Step 1: Add AE calculation and query functions**

Add after calculateTargetDps:

```lua
-- Calculate AE status for all tracked mobs
local function calculateAeStatus()
    local now = mq.gettime()
    local cutoff = now - WINDOW_DURATION

    for mobId, aeData in pairs(_aeDamage) do
        -- Count targets hit recently
        local activeTargets = {}
        for targetId, lastHit in pairs(aeData.targets) do
            if lastHit >= cutoff then
                table.insert(activeTargets, targetId)
            else
                aeData.targets[targetId] = nil  -- Prune stale
            end
        end

        aeData.activeTargetCount = #activeTargets
        aeData.isAE = #activeTargets >= 2

        -- Sum DPS this mob is doing across all targets
        local totalMobDps = 0
        for _, targetId in ipairs(activeTargets) do
            local targetData = _targetDamage[targetId]
            if targetData and targetData.sources[mobId] then
                totalMobDps = totalMobDps + (targetData.sources[mobId].dps or 0)
            end
        end
        aeData.totalDps = totalMobDps
    end
end

-- Query: Is this target taking AE damage?
function M.isTargetInAE(targetId)
    for mobId, aeData in pairs(_aeDamage) do
        if aeData.isAE and aeData.targets[targetId] then
            return true, mobId, aeData.activeTargetCount
        end
    end
    return false, nil, 0
end

-- Query: Is there any active AE damage?
function M.hasActiveAE()
    for mobId, aeData in pairs(_aeDamage) do
        if aeData.isAE and aeData.totalDps > 0 then
            return true
        end
    end
    return false
end
```

**Step 2: Commit**

```bash
git add healing/damage_attribution.lua
git commit -m "feat(healing): add AE detection for multi-target damage"
```

---

## Task 8: Add DPS Validation

**Files:**
- Modify: `healing/damage_attribution.lua`

**Step 1: Add validation function**

Add after hasActiveAE:

```lua
-- Validate log-based DPS against HP delta DPS
function M.validateDps(targetId, hpDeltaDps)
    calculateTargetDps(targetId)
    local targetData = _targetDamage[targetId]

    local logDps = targetData and targetData.totalDps or 0
    hpDeltaDps = hpDeltaDps or 0

    local maxDps = math.max(logDps, hpDeltaDps, 1)
    local variance = math.abs(logDps - hpDeltaDps) / maxDps * 100
    local threshold = Config and Config.dpsVarianceThreshold or 25

    return {
        logDps = logDps,
        hpDeltaDps = hpDeltaDps,
        variance = variance,
        isReliable = variance <= threshold,
    }
end
```

**Step 2: Commit**

```bash
git add healing/damage_attribution.lua
git commit -m "feat(healing): add DPS validation (log vs HP delta)"
```

---

## Task 9: Add Public API

**Files:**
- Modify: `healing/damage_attribution.lua`

**Step 1: Add getTargetDamageInfo and tick functions**

Add after validateDps:

```lua
-- Get damage attribution summary for a target
function M.getTargetDamageInfo(targetId)
    calculateTargetDps(targetId)
    calculateAeStatus()

    local data = _targetDamage[targetId]
    if not data then
        return {
            totalDps = 0,
            sourceCount = 0,
            isMultiSource = false,
            primarySourceDps = 0,
            primarySourceName = nil,
            isInAE = false,
            aeTargetCount = 0,
        }
    end

    local isInAE, aeMobId, aeTargetCount = M.isTargetInAE(targetId)
    local primaryName = nil
    if data.primarySourceId and data.sources[data.primarySourceId] then
        primaryName = data.sources[data.primarySourceId].mobName
    end

    return {
        totalDps = data.totalDps,
        sourceCount = data.sourceCount,
        isMultiSource = data.isMultiSource,
        primarySourceDps = data.primarySourceDps,
        primarySourceName = primaryName,
        isInAE = isInAE,
        aeTargetCount = aeTargetCount,
    }
end

-- Tick function - call each frame
function M.tick()
    checkCombatTimeout()
    refreshMobCache()
end
```

**Step 2: Commit**

```bash
git add healing/damage_attribution.lua
git commit -m "feat(healing): add public API for damage attribution"
```

---

## Task 10: Register Damage Events (Part 1 - High Frequency)

**Files:**
- Modify: `healing/damage_attribution.lua`

**Step 1: Add event registration function with high-frequency verbs**

Add after tick, before `return M`:

```lua
local _eventsRegistered = false

function M.registerEvents()
    if _eventsRegistered then return end
    _eventsRegistered = true

    -- === HIGH FREQUENCY MELEE VERBS ===

    -- punches (46,846)
    mq.event('DmgAttrPunch', '#1# punches #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'punch')
    end)

    -- hits (42,663)
    mq.event('DmgAttrHit', '#1# hits #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'hit')
    end)

    -- slashes (36,683)
    mq.event('DmgAttrSlash', '#1# slashes #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'slash')
    end)

    -- bites (13,985)
    mq.event('DmgAttrBite', '#1# bites #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'bite')
    end)

    -- pierces (9,973)
    mq.event('DmgAttrPierce', '#1# pierces #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'pierce')
    end)

    -- kicks (9,887)
    mq.event('DmgAttrKick', '#1# kicks #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'kick')
    end)

    -- strikes (7,632)
    mq.event('DmgAttrStrike', '#1# strikes #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'strike')
    end)

    -- bashes (7,201)
    mq.event('DmgAttrBash', '#1# bashes #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'bash')
    end)

    -- frenzies on (4,748)
    mq.event('DmgAttrFrenzy', '#1# frenzies on #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'frenzy')
    end)

    -- claws (4,076)
    mq.event('DmgAttrClaw', '#1# claws #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'claw')
    end)

    -- shoots (3,464)
    mq.event('DmgAttrShoot', '#1# shoots #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'shoot')
    end)
end
```

**Step 2: Commit**

```bash
git add healing/damage_attribution.lua
git commit -m "feat(healing): register high-frequency damage events (11 verbs)"
```

---

## Task 11: Register Damage Events (Part 2 - Medium/Low Frequency)

**Files:**
- Modify: `healing/damage_attribution.lua`

**Step 1: Add remaining melee verbs to registerEvents**

Add inside registerEvents function, after the shoot event:

```lua
    -- === MEDIUM FREQUENCY MELEE VERBS ===

    -- backstabs (2,685)
    mq.event('DmgAttrBackstab', '#1# backstabs #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'backstab')
    end)

    -- crushes (2,556)
    mq.event('DmgAttrCrush', '#1# crushes #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'crush')
    end)

    -- smashes (828)
    mq.event('DmgAttrSmash', '#1# smashes #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'smash')
    end)

    -- === LOW FREQUENCY MELEE VERBS ===

    -- stings (377)
    mq.event('DmgAttrSting', '#1# stings #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'sting')
    end)

    -- slices (146)
    mq.event('DmgAttrSlice', '#1# slices #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'slice')
    end)

    -- gores (78)
    mq.event('DmgAttrGore', '#1# gores #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'gore')
    end)

    -- rends (21)
    mq.event('DmgAttrRend', '#1# rends #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'rend')
    end)

    -- mauls (1)
    mq.event('DmgAttrMaul', '#1# mauls #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'maul')
    end)
```

**Step 2: Commit**

```bash
git add healing/damage_attribution.lua
git commit -m "feat(healing): register medium/low frequency damage events (8 verbs)"
```

---

## Task 12: Register Spell/DoT Damage Events

**Files:**
- Modify: `healing/damage_attribution.lua`

**Step 1: Add spell and DoT event handlers**

Add inside registerEvents function, after maul event:

```lua
    -- === SPELL/DOT DAMAGE ===

    -- Spell damage
    mq.event('DmgAttrSpell', '#1# hit #2# for #3# points of #4# damage by #5#.', function(_, caster, target, amount, dmgType, spell)
        M.recordDamage(target, tonumber(amount) or 0, caster, 'spell')
    end)

    -- DoT damage
    mq.event('DmgAttrDot', '#1# has taken #2# damage from #3# by #4#.', function(_, target, amount, spell, caster)
        M.recordDamage(target, tonumber(amount) or 0, caster, 'dot')
    end)

    -- Non-melee to self (no attacker specified)
    mq.event('DmgAttrNonMeleeSelf', 'You were hit by non-melee for #1# damage.', function(_, amount)
        local myName = mq.TLO.Me.CleanName()
        M.recordDamage(myName, tonumber(amount) or 0, 'unknown', 'nonmelee')
    end)

    -- Non-melee to others
    mq.event('DmgAttrNonMeleeOther', '#1# was hit by non-melee for #2# points of damage.', function(_, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, 'unknown', 'nonmelee')
    end)
```

**Step 2: Commit**

```bash
git add healing/damage_attribution.lua
git commit -m "feat(healing): register spell/DoT/non-melee damage events"
```

---

## Task 13: Integrate with target_monitor.lua

**Files:**
- Modify: `healing/target_monitor.lua`

**Step 1: Add DamageAttribution require and usage**

At the top of the file, after existing requires, add:

```lua
-- Lazy-load DamageAttribution
local DamageAttribution = nil
local function getDamageAttribution()
    if DamageAttribution == nil then
        local ok, da = pcall(require, 'healing.damage_attribution')
        DamageAttribution = ok and da or false
    end
    return DamageAttribution or nil
end
```

**Step 2: Update updateTargetData function**

Find the section that calculates `combinedDps` and update it. Replace:

```lua
    -- Weighted combination (weights from config)
    local hpDpsWeight = (Config and Config.hpDpsWeight ~= nil) and Config.hpDpsWeight or 0.4
    local logDpsWeight = (Config and Config.logDpsWeight ~= nil) and Config.logDpsWeight or 0.6
    local combinedDps = (hpDeltaDps * hpDpsWeight) + (logDps * logDpsWeight)
```

With:

```lua
    -- Get attribution data if available
    local da = getDamageAttribution()
    local attrInfo = da and da.getTargetDamageInfo(spawnId) or nil
    local validation = da and da.validateDps(spawnId, hpDeltaDps) or nil

    -- Use attributed DPS when reliable, fall back to weighted combo when drifting
    local combinedDps
    if validation and validation.isReliable then
        combinedDps = attrInfo.totalDps
    else
        -- Fall back to weighted combo
        local hpDpsWeight = (Config and Config.hpDpsWeight ~= nil) and Config.hpDpsWeight or 0.6
        local attrDps = attrInfo and attrInfo.totalDps or logDps
        combinedDps = (hpDeltaDps * hpDpsWeight) + (attrDps * (1 - hpDpsWeight))
    end
```

**Step 3: Add attribution fields to data table**

In the same function, after `burstDetected = burstDetected,` add:

```lua
        -- Attribution data
        sourceCount = attrInfo and attrInfo.sourceCount or 0,
        isMultiSource = attrInfo and attrInfo.isMultiSource or false,
        isInAE = attrInfo and attrInfo.isInAE or false,
        dpsValidation = validation,
```

**Step 4: Commit**

```bash
git add healing/target_monitor.lua
git commit -m "feat(healing): integrate damage attribution into target_monitor"
```

---

## Task 14: Update heal_selector.lua with Source Count Scaling

**Files:**
- Modify: `healing/heal_selector.lua`

**Step 1: Update scoreSingle function**

Find the section in `scoreSingle` where `adjustedDps` is calculated. Replace:

```lua
    local adjustedDps = dps
    local burst = false
    if targetInfo and targetInfo.burstDetected then
        local scale = config and config.burstDpsScale or 1.5
        burst = true
        adjustedDps = dps * scale
    end
```

With:

```lua
    local adjustedDps = dps
    local burst = false

    -- Scale up if multiple sources (being swarmed = sustained damage)
    if targetInfo and targetInfo.isMultiSource then
        local sourceScale = 1 + ((targetInfo.sourceCount or 1) - 1) * 0.1
        adjustedDps = adjustedDps * math.min(sourceScale, 1.5)
    end

    -- Burst detection
    if targetInfo and targetInfo.burstDetected then
        local scale = config and config.burstDpsScale or 1.5
        burst = true
        adjustedDps = adjustedDps * scale
    end
```

**Step 2: Commit**

```bash
git add healing/heal_selector.lua
git commit -m "feat(healing): scale DPS scoring based on source count"
```

---

## Task 15: Update heal_selector.lua with AE Detection for Group Heals

**Files:**
- Modify: `healing/heal_selector.lua`

**Step 1: Update ShouldUseGroupHeal function**

Find the section in `ShouldUseGroupHeal` where `groupHealMinCount` is used. Add AE detection before the threshold check:

```lua
    -- Check for AE damage pattern
    local aeDetected = false
    for _, t in ipairs(hurtTargets) do
        if t.isInAE then
            aeDetected = true
            break
        end
    end

    -- Lower threshold if AE detected (damage pattern will continue)
    local minCount = config.groupHealMinCount or 3
    if aeDetected then
        minCount = math.max(2, minCount - 1)
    end
```

Then use `minCount` instead of `config.groupHealMinCount or 3` in the comparison.

**Step 2: Commit**

```bash
git add healing/heal_selector.lua
git commit -m "feat(healing): lower group heal threshold on AE detection"
```

---

## Task 16: Update combat_assessor.lua High Pressure Detection

**Files:**
- Modify: `healing/combat_assessor.lua`

**Step 1: Add DamageAttribution require**

At the top of the file, after existing requires:

```lua
-- Lazy-load DamageAttribution
local DamageAttribution = nil
local function getDamageAttribution()
    if DamageAttribution == nil then
        local ok, da = pcall(require, 'healing.damage_attribution')
        DamageAttribution = ok and da or false
    end
    return DamageAttribution or nil
end
```

**Step 2: Update checkHighPressure function**

Replace the existing `checkHighPressure` function:

```lua
local function checkHighPressure(totalDps)
    local minDps = (Config and Config.highPressureMinDps) or 3000

    -- Primary check: Total incoming DPS to group
    if totalDps >= minDps then
        return true
    end

    local da = getDamageAttribution()
    if not da then
        return false
    end

    -- Check if tank is being swarmed (actively hit by multiple sources)
    if TargetMonitor then
        local targets = TargetMonitor.getAllTargets()
        for _, target in pairs(targets) do
            if target.role == 'tank' then
                local attrInfo = da.getTargetDamageInfo(target.id)
                if attrInfo.sourceCount >= 3 then
                    return true
                end
                break
            end
        end
    end

    -- Check for active AE damage hitting group
    if da.hasActiveAE() then
        return true
    end

    return false
end
```

**Step 3: Update the call to checkHighPressure**

Find where `checkHighPressure` is called in the `tick` function and update it to only pass `totalDps`:

```lua
    _state.highPressure = checkHighPressure(_state.totalIncomingDps)
```

**Step 4: Commit**

```bash
git add healing/combat_assessor.lua
git commit -m "feat(healing): use damage attribution for high pressure detection"
```

---

## Task 17: Update proactive.lua with Source Count for HoT Decisions

**Files:**
- Modify: `healing/proactive.lua`

**Step 1: Update shouldApplyHoT function**

Find the coverage ratio calculation in `shouldApplyHoT` and add source count adjustment. After:

```lua
    local coverageRatio = hotHps / incomingDps
```

Add:

```lua
    -- Multiple sources = more sustained damage pattern, HoT more valuable
    local sourceCount = target.sourceCount or 1
    if sourceCount >= 2 then
        coverageRatio = coverageRatio * 1.2  -- Effective 20% boost to coverage
    end
```

**Step 2: Commit**

```bash
git add healing/proactive.lua
git commit -m "feat(healing): boost HoT coverage ratio for multi-source damage"
```

---

## Task 18: Initialize DamageAttribution in healing/init.lua

**Files:**
- Modify: `healing/init.lua`

**Step 1: Add DamageAttribution initialization**

Find the initialization section and add:

```lua
-- Initialize damage attribution
local okDa, DamageAttribution = pcall(require, 'healing.damage_attribution')
if okDa and DamageAttribution then
    DamageAttribution.init(Config)
    DamageAttribution.registerEvents()
end
```

**Step 2: Add tick call**

Find the tick function and add:

```lua
    -- Tick damage attribution
    if DamageAttribution and DamageAttribution.tick then
        DamageAttribution.tick()
    end
```

**Step 3: Commit**

```bash
git add healing/init.lua
git commit -m "feat(healing): initialize damage attribution in healing module"
```

---

## Task 19: Add Logging for DPS Validation

**Files:**
- Modify: `healing/logger.lua`

**Step 1: Add DPS validation logging function**

Add after existing logging functions:

```lua
function M.logDpsValidation(targetName, validation, attrInfo)
    if not shouldLog('debug', 'dpsValidation') then return end

    local status = validation.isReliable and 'OK' or 'DRIFT'

    write('debug', 'dpsValidation',
        'DPS_CHECK [%s] %s: logDps=%.0f hpDeltaDps=%.0f variance=%.1f%% sources=%d %s',
        targetName or '?',
        status,
        validation.logDps or 0,
        validation.hpDeltaDps or 0,
        validation.variance or 0,
        attrInfo and attrInfo.sourceCount or 0,
        attrInfo and attrInfo.isMultiSource and 'MULTI' or 'SINGLE'
    )
end

function M.logDpsAttributionSummary(targetName, attrInfo, validation)
    if not shouldLog('info', 'dpsAttribution') then return end

    local lines = { string.format('DPS_ATTRIBUTION [%s]:', targetName or '?') }
    table.insert(lines, string.format('  Total: %.0f DPS from %d source(s)',
        attrInfo.totalDps or 0, attrInfo.sourceCount or 0))

    if attrInfo.primarySourceName then
        table.insert(lines, string.format('  Primary: %s @ %.0f DPS',
            attrInfo.primarySourceName, attrInfo.primarySourceDps or 0))
    end

    if attrInfo.isInAE then
        table.insert(lines, string.format('  AE DETECTED: %d targets hit', attrInfo.aeTargetCount or 0))
    end

    if validation then
        table.insert(lines, string.format('  Validation: log=%.0f hp=%.0f var=%.1f%% [%s]',
            validation.logDps or 0, validation.hpDeltaDps or 0, validation.variance or 0,
            validation.isReliable and 'RELIABLE' or 'DRIFT'))
    end

    write('info', 'dpsAttribution', table.concat(lines, '\n'))
end
```

**Step 2: Commit**

```bash
git add healing/logger.lua
git commit -m "feat(healing): add DPS validation and attribution logging"
```

---

## Task 20: Add Config Options

**Files:**
- Modify: `healing/config.lua`

**Step 1: Add attribution config options**

Find the config defaults section and add:

```lua
    -- Damage Attribution
    dpsWindowSec = 3,              -- Rolling window for DPS calculation
    combatTimeoutSec = 5,          -- Clear data after N seconds of no combat
    dpsVarianceThreshold = 25,     -- Log DRIFT warning above this %
```

**Step 2: Commit**

```bash
git add healing/config.lua
git commit -m "feat(healing): add damage attribution config options"
```

---

## Task 21: Final Integration Test

**Files:**
- No file changes

**Step 1: Verify in-game**

1. Run `/lua run sidekick` in EQ
2. Engage mobs in combat
3. Check MQ console for any errors
4. Verify healing still works

**Step 2: Check logs**

1. Look in `F:\Config\HealingLogs\` for today's log
2. Search for `DPS_CHECK` entries
3. Verify variance is reasonable (< 25% = RELIABLE)

**Step 3: Final commit**

```bash
git add -A
git status
git commit -m "feat(healing): complete damage attribution system

- Per-mob damage tracking with XTarget resolution
- 19 melee + 4 spell damage event patterns
- 3-second DPS window, 5-second combat timeout
- AE detection for group damage patterns
- DPS validation (log vs HP delta)
- Integration with heal_selector, combat_assessor, proactive"
```

---

## Summary

| Task | Description |
|------|-------------|
| 1 | Create damage_attribution.lua skeleton |
| 2 | Add mob name resolution |
| 3 | Add target name resolution |
| 4 | Add combat timeout |
| 5 | Add damage recording |
| 6 | Add DPS calculation |
| 7 | Add AE detection |
| 8 | Add DPS validation |
| 9 | Add public API |
| 10 | Register high-freq damage events |
| 11 | Register med/low-freq damage events |
| 12 | Register spell/DoT events |
| 13 | Integrate with target_monitor |
| 14 | Update heal_selector scoring |
| 15 | Update heal_selector group heals |
| 16 | Update combat_assessor |
| 17 | Update proactive HoT decisions |
| 18 | Initialize in healing/init |
| 19 | Add logging functions |
| 20 | Add config options |
| 21 | Final integration test |
