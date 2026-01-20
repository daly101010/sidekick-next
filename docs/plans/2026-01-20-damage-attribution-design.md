# Damage Attribution System Design

**Date:** 2026-01-20
**Status:** Design Complete
**Purpose:** Improve healing intelligence by tracking which mobs are attacking which characters and validating DPS accuracy.

## Goals

1. **Damage attribution** - Track which mobs are attacking which characters and the DPS each mob generates
2. **DPS accuracy validation** - Ensure log-based DPS matches actual HP deficits observed on characters
3. **AE detection** - Identify when one mob is hitting multiple group members
4. **Enhanced logging** - Provide diagnostic data to identify missing damage events

## Data Structures

### Per-Target Damage Attribution

```lua
_targetDamage = {
    [targetId] = {
        sources = {
            [mobId] = {
                mobId = number,           -- Resolved mob ID (or nil if unknown)
                mobName = string,         -- Attacker name from log
                lastHit = timestamp,
                dps = number,             -- Calculated DPS from this source
                entries = {
                    { time = timestamp, amount = number, dmgType = string },
                    ...
                }
            },
        },
        sourceCount = number,             -- Active sources hitting this target
        totalDps = number,                -- Combined DPS from all sources
        primarySourceId = mobId,          -- Mob doing most damage
        primarySourceDps = number,
        isMultiSource = boolean,          -- True if 2+ sources active
    }
}
```

### AE Damage Tracking

```lua
_aeDamage = {
    [mobId] = {
        targets = { [targetId] = lastHitTimestamp, ... },
        activeTargetCount = number,
        isAE = boolean,                   -- True if hitting 2+ targets
        totalDps = number,                -- Combined DPS across all targets
    }
}
```

### Mob Name Resolution Cache

```lua
_mobNameCache = {
    ["mob name"] = { id = mobId, lastSeen = timestamp },
}
```

## Configuration

| Setting | Default | Description |
|---------|---------|-------------|
| `dpsWindowSec` | 3 | Rolling window for DPS calculation |
| `combatTimeoutSec` | 5 | Clear all data after N seconds of no damage |
| `dpsVarianceThreshold` | 25 | Log drift warning when variance exceeds N% |

## Combat Timeout

All attribution data clears after 5 seconds of no damage events:

```lua
local _lastDamageEvent = 0
local COMBAT_TIMEOUT = Config.combatTimeoutSec or 5

local function checkCombatTimeout()
    local now = mq.gettime()
    if _lastDamageEvent > 0 and (now - _lastDamageEvent) > COMBAT_TIMEOUT then
        _targetDamage = {}
        _aeDamage = {}
        _mobNameCache = {}
        _lastDamageEvent = 0
    end
end
```

## Mob Name-to-ID Resolution

Resolve attacker names to mob IDs using XTarget data:

```lua
local function refreshMobCache()
    local now = mq.gettime()
    local me = mq.TLO.Me
    local xtCount = tonumber(me.XTarget()) or 0

    for i = 1, xtCount do
        local xt = me.XTarget(i)
        if xt and xt() and xt.ID() > 0 then
            local name = xt.CleanName() or xt.Name()
            local id = xt.ID()
            if name and id then
                _mobNameCache[name] = { id = id, lastSeen = now }
            end
        end
    end
end

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

**Limitation:** Same-named mobs (e.g., "a goblin" x3) cannot be distinguished. Cache maps to whichever one XTarget saw last. Acceptable for per-fight healing prioritization.

## DPS Calculation

3-second rolling window for responsive DPS tracking:

```lua
local WINDOW_DURATION = Config.dpsWindowSec or 3

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
        local recentDamage = 0
        local recentEntries = {}

        for _, entry in ipairs(sourceData.entries) do
            if entry.time >= cutoff then
                table.insert(recentEntries, entry)
                recentDamage = recentDamage + entry.amount
            end
        end
        sourceData.entries = recentEntries

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

    targetData.sourceCount = activeSourceCount
    targetData.totalDps = totalDps
    targetData.primarySourceId = primaryId
    targetData.primarySourceDps = primaryDps
    targetData.isMultiSource = activeSourceCount >= 2
end
```

## AE Detection

Detect when one mob is hitting multiple group members:

```lua
local function calculateAeStatus()
    local now = mq.gettime()
    local cutoff = now - WINDOW_DURATION

    for mobId, aeData in pairs(_aeDamage) do
        local activeTargets = {}
        for targetId, lastHit in pairs(aeData.targets) do
            if lastHit >= cutoff then
                table.insert(activeTargets, targetId)
            else
                aeData.targets[targetId] = nil
            end
        end

        aeData.activeTargetCount = #activeTargets
        aeData.isAE = #activeTargets >= 2

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

function M.isTargetInAE(targetId)
    for mobId, aeData in pairs(_aeDamage) do
        if aeData.isAE and aeData.targets[targetId] then
            return true, mobId, aeData.activeTargetCount
        end
    end
    return false, nil, 0
end

function M.hasActiveAE()
    for mobId, aeData in pairs(_aeDamage) do
        if aeData.isAE and aeData.totalDps > 0 then
            return true
        end
    end
    return false
end
```

## DPS Validation

Compare log-based DPS to HP delta DPS to identify missing damage events:

```lua
function M.validateDps(targetId, targetInfo)
    local now = mq.gettime()
    local attrInfo = M.getTargetDamageInfo(targetId)

    local logDps = attrInfo.totalDps or 0
    local hpDeltaDps = targetInfo.hpDeltaDps or 0

    local maxDps = math.max(logDps, hpDeltaDps, 1)
    local variance = math.abs(logDps - hpDeltaDps) / maxDps * 100

    return {
        logDps = logDps,
        hpDeltaDps = hpDeltaDps,
        variance = variance,
        isReliable = variance <= 25,
    }
end
```

**Interpretation:**
- `variance < 10%` - Excellent, logs capture nearly all damage
- `variance 10-25%` - Acceptable, minor gaps
- `variance > 25%` - Missing damage events or HP tracking issue (DRIFT warning)

## API for Consumers

```lua
function M.getTargetDamageInfo(targetId)
    calculateTargetDps(targetId)
    local data = _targetDamage[targetId]
    if not data then
        return {
            totalDps = 0,
            sourceCount = 0,
            isMultiSource = false,
            primarySourceDps = 0,
            isInAE = false,
        }
    end

    local isInAE, aeMobId, aeTargetCount = M.isTargetInAE(targetId)

    return {
        totalDps = data.totalDps,
        sourceCount = data.sourceCount,
        isMultiSource = data.isMultiSource,
        primarySourceDps = data.primarySourceDps,
        primarySourceName = data.sources[data.primarySourceId] and
                           data.sources[data.primarySourceId].mobName or nil,
        isInAE = isInAE,
        aeTargetCount = aeTargetCount,
    }
end
```

## Integration Points

### 1. target_monitor.lua

Add attribution data to target info:

```lua
local DamageAttribution = require('healing.damage_attribution')

-- In updateTargetData()
local attrInfo = DamageAttribution.getTargetDamageInfo(spawnId)
local validation = DamageAttribution.validateDps(spawnId, { hpDeltaDps = hpDeltaDps })

-- Use attributed DPS when reliable, fall back to weighted combo when drifting
local recentDps
if validation.isReliable then
    recentDps = attrInfo.totalDps
else
    recentDps = (hpDeltaDps * 0.6) + (attrInfo.totalDps * 0.4)
end

data.recentDps = recentDps
data.sourceCount = attrInfo.sourceCount
data.isMultiSource = attrInfo.isMultiSource
data.isInAE = attrInfo.isInAE
data.dpsValidation = validation
```

### 2. heal_selector.lua

Enhance spell scoring with source count:

```lua
-- In scoreSingle()
local adjustedDps = dps

-- Scale up if multiple sources (being swarmed = sustained damage)
if targetInfo.isMultiSource then
    local sourceScale = 1 + (targetInfo.sourceCount - 1) * 0.1
    adjustedDps = adjustedDps * math.min(sourceScale, 1.5)
end

if targetInfo.burstDetected then
    adjustedDps = adjustedDps * (config.burstDpsScale or 1.5)
end
```

Enhance group heal decisions with AE detection:

```lua
-- In ShouldUseGroupHeal()
local aeDetected = false
for _, t in ipairs(hurtTargets) do
    if t.isInAE then
        aeDetected = true
        break
    end
end

local minCount = config.groupHealMinCount or 3
if aeDetected then
    minCount = math.max(2, minCount - 1)
end
```

### 3. combat_assessor.lua

Remove mob count from high pressure check, use DPS and attribution:

```lua
local function checkHighPressure(totalDps)
    local minDps = Config.highPressureMinDps or 3000

    if totalDps >= minDps then
        return true
    end

    local tankId = M.getTankId()
    if tankId then
        local attrInfo = DamageAttribution.getTargetDamageInfo(tankId)
        if attrInfo.sourceCount >= 3 then
            return true
        end
    end

    if DamageAttribution.hasActiveAE() then
        return true
    end

    return false
end
```

### 4. proactive.lua

Enhance HoT decisions with source count:

```lua
-- In shouldApplyHoT()
local sourceCount = target.sourceCount or 1

-- Multiple sources = more sustained damage pattern, HoT more valuable
if sourceCount >= 2 then
    coverageRatio = coverageRatio * 1.2
end
```

## Damage Event Patterns

### Official Verbs from eqstr_us.txt

19 damage verbs extracted from the EQ client string file, sorted by observed frequency in logs:

| String ID | Verb | Log Count | Priority |
|-----------|------|-----------|----------|
| 12182 | punches | 46,846 | High |
| 12184 | hits | 42,663 | High |
| 12180 | slashes | 36,683 | High |
| 12166 | bites | 13,985 | High |
| 12194 | pierces | 9,973 | High |
| 12196 | kicks | 9,887 | High |
| 12198 | strikes | 7,632 | High |
| 12202 | bashes | 7,201 | High |
| 5839 | frenzies on | 4,748 | High |
| 12168 | claws | 4,076 | High |
| 9284 | shoots | 3,464 | High |
| 12200 | backstabs | 2,685 | Medium |
| 12192 | crushes | 2,556 | Medium |
| 12176 | smashes | 828 | Medium |
| 12172 | stings | 377 | Low |
| 12173 | slices | 146 | Low |
| 12170 | gores | 78 | Low |
| 12178 | rends | 21 | Low |
| 12165 | mauls | 1 | Low |

### Damage Suffixes (Metadata)

These appear in parentheses after the damage amount - not separate patterns:

- `(Critical)` - Critical hit
- `(Rampage)` - Rampage attack
- `(Wild Rampage)` - Wild rampage attack
- `(Riposte)` - Riposte damage
- `(Strikethrough)` - Strikethrough attack
- `(Riposte Strikethrough)` - Combined

### Event Registration

```lua
function M.registerEvents()
    -- === MELEE DAMAGE (19 verbs from eqstr_us.txt) ===

    -- punches (46,846 - most common)
    mq.event('DmgPunch', '#1# punches #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'punch')
    end)

    -- hits (42,663)
    mq.event('DmgHit', '#1# hits #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'hit')
    end)

    -- slashes (36,683)
    mq.event('DmgSlash', '#1# slashes #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'slash')
    end)

    -- bites (13,985)
    mq.event('DmgBite', '#1# bites #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'bite')
    end)

    -- pierces (9,973)
    mq.event('DmgPierce', '#1# pierces #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'pierce')
    end)

    -- kicks (9,887)
    mq.event('DmgKick', '#1# kicks #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'kick')
    end)

    -- strikes (7,632)
    mq.event('DmgStrike', '#1# strikes #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'strike')
    end)

    -- bashes (7,201)
    mq.event('DmgBash', '#1# bashes #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'bash')
    end)

    -- frenzies on (4,748) - note the "on" in pattern
    mq.event('DmgFrenzy', '#1# frenzies on #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'frenzy')
    end)

    -- claws (4,076)
    mq.event('DmgClaw', '#1# claws #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'claw')
    end)

    -- shoots (3,464)
    mq.event('DmgShoot', '#1# shoots #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'shoot')
    end)

    -- backstabs (2,685)
    mq.event('DmgBackstab', '#1# backstabs #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'backstab')
    end)

    -- crushes (2,556)
    mq.event('DmgCrush', '#1# crushes #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'crush')
    end)

    -- smashes (828)
    mq.event('DmgSmash', '#1# smashes #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'smash')
    end)

    -- stings (377)
    mq.event('DmgSting', '#1# stings #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'sting')
    end)

    -- slices (146)
    mq.event('DmgSlice', '#1# slices #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'slice')
    end)

    -- gores (78)
    mq.event('DmgGore', '#1# gores #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'gore')
    end)

    -- rends (21)
    mq.event('DmgRend', '#1# rends #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'rend')
    end)

    -- mauls (1)
    mq.event('DmgMaul', '#1# mauls #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'maul')
    end)

    -- === SPELL/DOT DAMAGE ===

    -- Spell damage (caster hit target)
    mq.event('DmgSpell', '#1# hit #2# for #3# points of #4# damage by #5#.', function(_, caster, target, amount, dmgType, spell)
        M.recordDamage(target, tonumber(amount) or 0, caster, 'spell')
    end)

    -- DoT damage
    mq.event('DmgDot', '#1# has taken #2# damage from #3# by #4#.', function(_, target, amount, spell, caster)
        M.recordDamage(target, tonumber(amount) or 0, caster, 'dot')
    end)

    -- Non-melee (generic, no attacker specified)
    mq.event('DmgNonMelee', 'You were hit by non-melee for #1# damage.', function(_, amount)
        local myName = mq.TLO.Me.CleanName()
        M.recordDamage(myName, tonumber(amount) or 0, 'unknown', 'nonmelee')
    end)

    -- Non-melee to others
    mq.event('DmgNonMeleeOther', '#1# was hit by non-melee for #2# points of damage.', function(_, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, 'unknown', 'nonmelee')
    end)
end
```

## Logging Enhancements

### DPS Validation Log

```lua
function M.logDpsValidation(targetName, validation, details)
    if not shouldLog('debug', 'dpsValidation') then return end

    local status = validation.isReliable and 'OK' or 'DRIFT'

    write('debug', 'dpsValidation',
        'DPS_CHECK [%s] %s: logDps=%.0f hpDeltaDps=%.0f variance=%.1f%% sources=%d %s',
        targetName or '?',
        status,
        validation.logDps or 0,
        validation.hpDeltaDps or 0,
        validation.variance or 0,
        details.sourceCount or 0,
        details.isMultiSource and 'MULTI' or 'SINGLE'
    )
end
```

### Attribution Summary Log

```lua
function M.logDpsAttributionSummary(targetId, targetName, attrInfo, validation)
    if not shouldLog('info', 'dpsAttribution') then return end

    local lines = { string.format('DPS_ATTRIBUTION [%s]:', targetName or '?') }
    table.insert(lines, string.format('  Total: %.0f DPS from %d source(s)',
        attrInfo.totalDps, attrInfo.sourceCount))

    if attrInfo.primarySourceName then
        table.insert(lines, string.format('  Primary: %s @ %.0f DPS',
            attrInfo.primarySourceName, attrInfo.primarySourceDps))
    end

    if attrInfo.isInAE then
        table.insert(lines, string.format('  AE DETECTED: %d targets hit', attrInfo.aeTargetCount))
    end

    table.insert(lines, string.format('  Validation: log=%.0f hp=%.0f var=%.1f%% [%s]',
        validation.logDps, validation.hpDeltaDps, validation.variance,
        validation.isReliable and 'RELIABLE' or 'DRIFT'))

    write('info', 'dpsAttribution', table.concat(lines, '\n'))
end
```

### Example Log Output

```
[14:32:15][INFO][dpsAttribution] DPS_ATTRIBUTION [Tankname]:
  Total: 2850 DPS from 3 source(s)
  Primary: a frost giant @ 1200 DPS
  AE DETECTED: 4 targets hit
  Validation: log=2850 hp=2650 var=7.0% [RELIABLE]
```

## New File Structure

```
healing/
├── damage_attribution.lua    # NEW - Core attribution logic
├── damage_parser.lua         # MODIFIED - Enhanced event patterns (19 verbs + spell/dot)
├── target_monitor.lua        # MODIFIED - Integration
├── heal_selector.lua         # MODIFIED - Integration
├── combat_assessor.lua       # MODIFIED - Integration
├── proactive.lua             # MODIFIED - Integration
└── logger.lua                # MODIFIED - New logging functions
```

## Summary

| Feature | Benefit |
|---------|---------|
| Per-source DPS tracking | Know which mob is the threat |
| Source count per target | Detect swarm situations |
| AE detection | Identify group damage patterns |
| DPS validation | Catch missing damage events |
| 3-second window | Responsive to fast fights |
| 5-second combat timeout | Clean slate between pulls |
| 19 melee + 3 spell patterns | Comprehensive log parsing from official EQ strings |
