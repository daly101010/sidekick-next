# Healing Intelligence Design

Merging DeficitHealer's intelligence into SideKick's healing module.

## Summary

Port DeficitHealer's sophisticated healing logic to SideKick, replacing simple HP-percentage thresholds with deficit-based heal selection, learned heal amounts, spell ducking, and multi-healer coordination via incoming heal tracking.

## Key Decisions

| Decision | Choice |
|----------|--------|
| Coordination system | Incoming heal tracking (not claims) |
| Class scope | CLR first, with abstraction for future classes |
| Config | Separate file (`SideKick_Healing_<server>_<char>.lua`) |
| Heal learning | Yes - essential for accurate predictions |
| Analytics | Yes - needed to verify effectiveness |
| UI | Settings in SideKick tab + optional floating monitor |
| Enable toggle | `Config.enabled` (healing module's own config, not Core.Settings) |
| Timing | `mq.gettime()` for wall-clock time (not `os.clock()` which is CPU time) |

## Architecture

### File Structure

```
SideKick/
  healing/
    init.lua           -- Entry point, orchestrator
    config.lua         -- Healing-specific settings
    heal_tracker.lua   -- Learning system
    target_monitor.lua -- HP/DPS tracking
    heal_selector.lua  -- Scoring and selection
    proactive.lua      -- HoT/timing decisions
    combat_assessor.lua -- Fight phase, survival mode
    analytics.lua      -- Efficiency tracking
    persistence.lua    -- Save/load data
    incoming_heals.lua -- Multi-healer coordination
    damage_parser.lua  -- Chat log damage event parsing
    ui/
      settings.lua     -- Settings tab content
      monitor.lua      -- Floating monitor window
```

### Data Flow

```
Main Loop (SideKick.lua)
    │
    ▼
healing/init.lua (orchestrator)
    │
    ├─► target_monitor.lua ──► Scans group HP, calculates DPS
    │       │
    │       └─► damage_parser.lua ──► Chat log damage events
    │
    ├─► combat_assessor.lua ──► Fight phase, survival mode, TTK
    │
    ├─► heal_selector.lua ──► Scores spells, picks best heal
    │       │
    │       └─► heal_tracker.lua ──► Learned heal amounts
    │
    ├─► proactive.lua ──► HoT/timing decisions (called from selector)
    │
    ├─► incoming_heals.lua ──► Tracks pending heals (local + remote)
    │
    └─► SpellEngine.cast() ──► Executes the heal
```

## Target Scope

### Tracked Targets

- Self
- Group members (1-5)
- Group member pets (if `Config.healPetsEnabled`)

### Not Tracked (Future Work)

- Raid members (requires different UI/coordination approach)
- XTarget slots (these are enemies, not heal targets)

## Incoming Heal Tracking

Replaces claim system. Healers broadcast expected heal details; other healers factor incoming heals into deficit calculations.

### Data Structure

```lua
incomingHeals[targetId] = {
    [healerId] = {
        spellName = "Sincere Remedy",
        expectedAmount = 45000,
        castStartTime = 1705612345.5,  -- mq.gettime()
        castDuration = 1.5,
        landsAt = 1705612347.0,        -- mq.gettime() + castDuration
        isHoT = false,
        hotTickAmount = nil,
        hotExpiresAt = nil,
    },
}
```

### Message Types

- `heal:incoming` - Cast started, expected amount and land time
- `heal:landed` - Cast completed successfully
- `heal:cancelled` - Cast ducked, interrupted, or fizzled

**Note:** These are NEW message types. ActorsCoordinator must be updated to register handlers for these. See [ActorsCoordinator Integration](#actorscoordinator-integration).

### Effective Deficit

```lua
function getEffectiveDeficit(targetId, targetInfo)
    local rawDeficit = targetInfo.maxHP - targetInfo.currentHP
    local incoming = sumIncomingHeals(targetId)
    return math.max(0, rawDeficit - incoming)
end
```

When a healer sees a target's effective deficit is covered by incoming heals, they move on to find other targets that need healing.

### Registration Timing

**Critical:** Incoming heal is registered AFTER `SpellEngine.cast()` returns success, not before. If cast fails to start, no incoming entry is created.

```lua
local success = SpellEngine.cast(spellName, targetId, opts)
if success then
    IncomingHeals.registerMyCast(...)  -- Only after confirmed
    broadcastIncoming(...)
end
```

## Heal Selector & Scoring

Picks right-sized heals based on deficit, not just HP percentage.

### Spell Categories (CLR)

- `fast` - Remedy line (emergency)
- `small` - Light line (small deficit)
- `medium` - Intervention/Contravention
- `large` - Renewal line
- `group` - Word/Syllable
- `hot` - Elixir single target
- `hotLight` - Lower rank HoT for non-tanks
- `groupHot` - Acquittal line

### Scoring Formula

```lua
function scoreHeal(spell, targetInfo, situation)
    local expected = healTracker.getExpected(spell.name)

    -- Fallback to spell base data, NOT mana cost
    if expected <= 0 then
        local spellData = mq.TLO.Spell(spell.name)
        if spellData and spellData() and spellData.Base then
            expected = math.abs(tonumber(spellData.Base(1)()) or 0)
        end
    end

    -- Cannot score without heal amount data
    if expected <= 0 then
        return -999
    end

    local effectiveDeficit = getEffectiveDeficit(targetId, targetInfo)

    local coverage = math.min(expected / effectiveDeficit, 1.5)
    local overheal = math.max(0, expected - effectiveDeficit) / expected
    local manaEff = expected / spell.manaCost

    local weights = situation.weights

    return (coverage * weights.coverage)
         + (manaEff * weights.manaEff)
         + (overheal * weights.overheal)
end
```

### Situational Weights

| Situation | Coverage | Mana Eff | Overheal |
|-----------|----------|----------|----------|
| Emergency | 4.0 | 0.1 | -0.5 |
| Normal | 2.0 | 1.0 | -1.5 |
| Low Pressure | 1.0 | 2.0 | -2.0 |

### Selection Flow

1. Get all potential targets (group members + pets)
2. Calculate effective deficit for each (raw deficit - incoming heals)
3. Filter to targets with healable effective deficit
4. Sort by priority (emergency > tank > healer > squishy > others) then by effective deficit
5. For first target needing healing, score candidate spells
6. Pick highest scoring spell above threshold
7. If all targets covered, check proactive HoT opportunities
8. If no healing needed, return false (allow DPS rotation)

### Proactive HoT Integration

When no urgent healing needed, selector calls `Proactive.shouldApplyHoT()` for tanks/targets taking sustained damage:

```lua
if not urgentTarget and Config.hotEnabled then
    local hotTarget = findProactiveHotTarget()
    if hotTarget then
        local hotSpell = getBestHotSpell(hotTarget)
        local shouldApply, reason = Proactive.shouldApplyHoT(hotTarget, hotSpell)
        if shouldApply then
            -- Cast HoT and record it
            if executeHeal(hotSpell, hotTarget.id, 'hot', true) then
                Proactive.recordHoT(hotTarget.id, hotSpell, hotDuration)
            end
        end
    end
end
```

## Target Monitoring

### Tracked Data Per Target

```lua
targets[spawnId] = {
    name = "Tankname",
    class = "WAR",
    role = "tank",           -- tank|healer|dps
    isSquishy = false,       -- WIZ/ENC/NEC/MAG

    currentHP = 180000,
    maxHP = 200000,
    pctHP = 90,
    deficit = 20000,

    -- DPS tracking (dual-source)
    recentDamage = {},       -- HP delta entries
    logDamage = {},          -- Chat log entries
    recentDps = 1500,        -- Combined weighted DPS
    burstDetected = false,   -- Statistical burst detection

    -- Incoming heal tracking
    incomingTotal = 15000,
    effectiveDeficit = 5000,

    -- HoT state
    activeHoTs = {},         -- {spellName = expiresAt}
    incomingHoTRemaining = 8000,

    lastUpdate = 0,          -- mq.gettime()
}
```

### DPS Calculation (Dual-Source)

Two independent damage sources combined for accuracy:

**1. HP Delta Tracking:**
- Records HP changes each tick
- Catches all damage including from heals by others
- Rolling window (default 6 seconds)

**2. Chat Log Damage Events:**
- Parses damage messages for exact hit amounts
- More accurate for individual hits
- Misses damage while out of log range

**Combined Calculation:**
```lua
local hpDps = calculateHpDeltaDps(target.recentDamage, windowSec)
local logDps = calculateLogDps(target.logDamage, windowSec)

-- Weighted combination
local combinedDps = (hpDps * Config.hpDpsWeight) + (logDps * Config.logDpsWeight)
-- Default weights: hpDpsWeight = 0.4, logDpsWeight = 0.6
```

**Burst Detection (Statistical):**
```lua
local mean = calculateMean(dpsHistory)
local stddev = calculateStdDev(dpsHistory, mean)
local threshold = mean + (stddev * Config.burstStddevMultiplier)  -- default 1.5

target.burstDetected = currentDps > threshold
```

### Damage Event Patterns

```lua
-- Melee damage
mq.event('MeleeDmg', '#1# hits #2# for #3# points of damage.', handler)
mq.event('MeleeCrit', '#1# scores a critical hit! (#2#)', handler)

-- Spell damage
mq.event('SpellDmg', '#1# hit #2# for #3# points of #4# damage by #5#.', handler)

-- DoT damage
mq.event('DotDmg', '#1# has taken #2# damage from #3# by #4#.', handler)

-- DS damage (on self)
mq.event('DsDmg', '#1# is burned by YOUR #2# for #3# points of damage.', handler)
```

### Priority Order

1. Emergency (any target < emergencyPct)
2. Tank
3. Healer
4. Squishy (cloth classes)
5. Non-squishy DPS
6. Pets (when `healPetsEnabled`)

**Pet Priority Notes:**
- Pets are always lower priority than any player character
- Pet role is always 'pet' (no tank/healer/squishy classification)
- Pets use the same deficit-based heal selection but with lower priority
- Main assist's pet may be treated higher priority than other pets (future enhancement)

## Heal Tracker (Learning)

Learns actual heal values from observed results.

### Stored Data Per Spell

```lua
healData[spellName] = {
    sampleCount = 47,
    baseAvg = 42000,
    critCount = 12,
    critAvg = 60000,
    critRate = 0.255,
    expected = 46590,
    reliable = true,
    lastUpdated = 1705612345,  -- os.time() for persistence

    -- HoT-specific
    isHoT = false,
    tickAvg = nil,
}
```

### Learning Algorithm

- Exponential moving average (weight = 0.1)
- Separate tracking for crits vs non-crits
- Expected = baseAvg × (1-critRate) + critAvg × critRate
- Unreliable until minSamplesForReliable reached

### Events

```lua
-- Direct heals
mq.event('HealLanded', 'You healed #1# for #2# (#3#) hit points by #4#.', handler)
mq.event('HealLandedCrit', 'You healed #1# for #2# (#3#) hit points by #4#. (Critical)', handler)
mq.event('HealLandedNoFull', 'You healed #1# for #2# hit points by #3#.', handler)
mq.event('HealLandedNoFullCrit', 'You healed #1# for #2# hit points by #3#. (Critical)', handler)

-- "You have healed" variants
mq.event('HealLandedHave', 'You have healed #1# for #2# (#3#) hit points by #4#.', handler)
mq.event('HealLandedHaveCrit', 'You have healed #1# for #2# (#3#) hit points by #4#. (Critical)', handler)
mq.event('HealLandedHaveNoFull', 'You have healed #1# for #2# hit points by #3#.', handler)
mq.event('HealLandedHaveNoFullCrit', 'You have healed #1# for #2# hit points by #3#. (Critical)', handler)

-- HoT ticks
mq.event('HotLanded', 'You healed #1# over time for #2# (#3#) hit points by #4#.', handler)
mq.event('HotLandedCrit', 'You healed #1# over time for #2# (#3#) hit points by #4#. (Critical)', handler)
mq.event('HotLandedNoFull', 'You healed #1# over time for #2# hit points by #3#.', handler)
mq.event('HotLandedNoFullCrit', 'You healed #1# over time for #2# hit points by #3#. (Critical)', handler)

-- Interrupts
mq.event('SpellInterrupted', 'Your spell is interrupted.', interruptHandler)
mq.event('SpellFizzle', 'Your spell fizzles!', interruptHandler)
```

### HoT Detection

Must use pcall pattern due to TLO quirks:

```lua
local function isHotSpell(spellName)
    local spell = mq.TLO.Spell(spellName)
    if not spell or not spell() then return false end

    if spell.HasSPA then
        local ok, v = pcall(function() return spell.HasSPA(79)() end)
        return ok and v == true
    end
    return false
end
```

### Persistence

- Saved to `SideKick_HealData_<server>_<char>.lua`
- Loaded on startup, continues learning across sessions
- Uses `os.time()` for timestamps (persisted data)

## Combat Assessor

### Assessed State

```lua
combatState = {
    fightPhase = "mid",      -- none|starting|mid|ending
    inCombat = true,
    survivalMode = false,
    avgMobHP = 45,
    estimatedTTK = 35,
    activeMobCount = 3,
    totalIncomingDps = 4500,
    tankDpsPct = 3.2,
}
```

### Fight Phase Detection

- Starting: avgMobHP > 70%
- Mid: between starting and ending
- Ending: avgMobHP < 25% OR TTK < 20s

Mobs below `nearDeadMobPct` (default 10%) are excluded from average calculation.

### Survival Mode

Triggered when tank DPS as % of max HP >= 5% per second (and tank not near full).

### Impact on Decisions

| State | Effect |
|-------|--------|
| survivalMode | Emergency weights, fast heals, limit HoT duration |
| fightPhase = starting | Allow proactive HoTs |
| fightPhase = ending | Skip long HoTs, conserve mana |
| activeMobCount <= 1 | Low pressure weights |

## Proactive Healing

### HoT Application Logic

```lua
function shouldApplyHot(target, hotSpellName)
    if not Config.hotEnabled then return false, 'disabled' end

    -- No HoTs during emergency
    if target.pctHP < Config.emergencyPct then
        return false, 'emergency'
    end

    -- Fight duration check
    local hotDuration = getHotDuration(hotSpellName)
    if combatState.estimatedTTK < hotDuration * (Config.hotMinFightDurationPct / 100) then
        return false, 'fight_ending'
    end

    -- Already has HoT
    if hasActiveHot(target.id) and not shouldRefreshHot(target.id) then
        return false, 'hot_active'
    end

    -- Compare HoT healing rate to incoming DPS
    local hotHps = getHotHps(hotSpellName)
    local coverageRatio = hotHps / math.max(1, target.recentDps)

    if coverageRatio >= Config.hotMinCoverageRatio then
        return true, 'sustained_damage'
    elseif coverageRatio >= Config.hotUselessRatio then
        return true, 'supplement'
    end

    return false, 'hot_insufficient'
end
```

### Coverage Ratio Interpretation

| Ratio | Action |
|-------|--------|
| >= 1.0 | HoT alone may suffice |
| 0.3 - 1.0 | Apply HoT + direct heals |
| 0.1 - 0.3 | HoT as supplement |
| < 0.1 | Skip HoT, direct heals only |

### Recording Applied HoTs

When a HoT is successfully cast, record it for refresh tracking:

```lua
function recordHoT(targetId, spellName, duration)
    activeHoTs[targetId] = activeHoTs[targetId] or {}
    activeHoTs[targetId][spellName] = mq.gettime() + duration
end
```

## Spell Ducking

### Duck Decision

```lua
function shouldDuck(castInfo, targetInfo)
    if not Config.duckEnabled then return false end

    local threshold
    if castInfo.tier == 'emergency' then
        threshold = Config.duckEmergencyThreshold  -- 70
    elseif castInfo.isHoT then
        threshold = Config.duckHotThreshold        -- 92
    else
        threshold = Config.duckHpThreshold         -- 85
    end

    threshold = threshold + Config.duckBufferPct   -- +0.5

    if targetInfo.pctHP >= threshold then
        return true, 'target_full'
    end

    if Config.considerIncomingHot then
        local effectiveDeficit = getEffectiveDeficit(targetInfo.id, targetInfo)
        if effectiveDeficit <= 0 then
            return true, 'incoming_covers'
        end
    end

    return false
end
```

### Duck Execution

**Critical:** Must clear SpellEngine state to prevent `isBusy()` stall:

```lua
function executeDuck(castInfo)
    -- 1. Stop the cast
    mq.cmd('/stopcast')

    -- 2. Clear SpellEngine state
    local ok, SpellEngine = pcall(require, 'utils.spell_engine')
    if ok and SpellEngine and SpellEngine.abort then
        SpellEngine.abort()
    end

    -- 3. Broadcast cancellation
    broadcastCancelled(castInfo.targetId, castInfo.spellName, 'ducked')

    -- 4. Remove from incoming heals tracking
    IncomingHeals.unregisterMyCast(castInfo.targetId)

    -- 5. Log for analytics
    Analytics.recordDuck(castInfo.spellName, castInfo.manaCost)

    -- 6. Clear cast info
    SpellEvents.setCastInfo(nil)
end
```

## Analytics

### Session Metrics

```lua
sessionStats = {
    totalCasts = 0,
    completedCasts = 0,
    duckedCasts = 0,
    interruptedCasts = 0,

    totalHealed = 0,
    totalOverheal = 0,
    overHealPct = 0,

    totalManaSpent = 0,
    healPerMana = 0,

    avgReactionTimeMs = 0,
    duckSavingsEstimate = 0,

    incomingHealHonored = 0,
    incomingHealExpired = 0,

    bySpell = {},

    sessionStart = 0,      -- os.time()
    lastUpdate = 0,        -- os.time()
}
```

### Display Format

```
Session: 45m | Casts: 127 | Ducked: 18 (14%)
Efficiency: 92.3% | Overheal: 7.7%
Heal/Mana: 4.2 HP/mp | Mana Saved: ~45k
```

## Configuration

### File Location

```
mq.configDir/SideKick_Healing_<server>_<char>.lua
```

### Key Settings

```lua
{
    -- Master enable (read by healing module, not Core.Settings)
    enabled = true,

    -- Thresholds
    emergencyPct = 25,
    minHealPct = 10,
    groupHealMinCount = 3,
    nearDeadMobPct = 10,     -- Ignore mobs below this for TTK calc

    -- Squishy handling
    squishyClasses = { WIZ = true, ENC = true, NEC = true, MAG = true },
    squishyCoveragePct = 70,
    nonSquishyMinHealPct = 15,

    -- Scoring weights
    scoringPresets = {
        emergency = { coverage = 4.0, manaEff = 0.1, overheal = -0.5 },
        normal = { coverage = 2.0, manaEff = 1.0, overheal = -1.5 },
        lowPressure = { coverage = 1.0, manaEff = 2.0, overheal = -2.0 },
    },

    -- Ducking
    duckEnabled = true,
    duckHpThreshold = 85,
    duckEmergencyThreshold = 70,
    duckHotThreshold = 92,
    duckBufferPct = 0.5,
    considerIncomingHot = true,

    -- HoT behavior
    hotEnabled = true,
    hotMinCoverageRatio = 0.3,
    hotUselessRatio = 0.1,
    hotMaxDeficitPct = 25,
    hotRefreshWindowPct = 0,
    hotTankOnly = true,
    hotMinFightDurationPct = 50,

    -- Combat assessment
    survivalModeDpsPct = 5,
    survivalModeTankFullPct = 90,
    fightPhaseStartingPct = 70,
    fightPhaseEndingPct = 25,
    fightPhaseEndingTTK = 20,

    -- DPS tracking
    damageWindowSec = 6,
    hpDpsWeight = 0.4,
    logDpsWeight = 0.6,
    burstStddevMultiplier = 1.5,

    -- Learning
    learningWeight = 0.1,
    minSamplesForReliable = 10,

    -- Coordination
    incomingHealTimeoutSec = 10,
    broadcastEnabled = true,

    -- Pets
    healPetsEnabled = false,
    petHealMinPct = 40,          -- Minimum HP% to heal pets (lower priority than players)

    -- Logging
    debugLogging = false,
    fileLogging = false,
    fileLogLevel = 'info',

    -- Spells (user assigns)
    spells = {
        fast = {},
        small = {},
        medium = {},
        large = {},
        group = {},
        hot = {},
        hotLight = {},
        groupHot = {},
    },
}
```

## UI

### Settings Tab

Integrated into SideKick Options panel:
- Enable toggle (writes to `Config.enabled`)
- Thresholds section
- Spell assignment dropdowns (per category)
- Ducking settings
- HoT behavior settings
- Advanced (logging, coordination)
- Button to open monitor window

### Monitor Window

Optional floating window showing:
- Status line (active, fight phase, survival mode)
- Target list with HP%, deficit, incoming, DPS
- Current cast status
- Incoming heals from other healers
- Session analytics summary
- Recent heal log

### Anchoring

Uses SideKick's existing anchor system:
```lua
HealMonitorAnchor = "none",              -- none|left|right|above|below
HealMonitorAnchorTarget = "grouptarget", -- grouptarget|sidekick_main|sidekick_bar
HealMonitorAnchorGap = 2,
```

## Integration Points

### Main Loop (SideKick.lua)

Class-based module switching:

```lua
-- In tickAutomation()
local priorityHealingActive = false

if playStyle ~= 'manual' then
    local classShort = getClassShort()

    if classShort == 'CLR' then
        -- Use new healing intelligence module
        local HealingIntel = require('healing')
        -- NOTE: Must call init() first to load config, then check enabled
        HealingIntel.init()  -- Safe to call multiple times (idempotent)
        if HealingIntel.Config.enabled ~= false then
            priorityHealingActive = HealingIntel.tick() == true
        end
    else
        -- Use legacy healing module for other classes
        if settings.DoHeals then
            local LegacyHealing = require('automation.healing')
            priorityHealingActive = LegacyHealing.tick(settings) == true
        end
    end
end
```

Init and shutdown must handle both paths:

```lua
-- In main()
local classShort = getClassShort()
if classShort == 'CLR' then
    local HealingIntel = require('healing')
    HealingIntel.init()
end

-- In shutdown
if classShort == 'CLR' then
    local HealingIntel = require('healing')
    HealingIntel.shutdown()
end
```

### SpellEngine Integration

SpellEngine is used for cast initiation only. Cast results are detected via `mq.event()` handlers in `spell_events.lua`, NOT via SpellEngine callbacks (which don't exist).

```lua
function castHeal(spellName, targetId, tier, isHoT)
    -- Set cast info for duck monitoring BEFORE cast
    SpellEvents.setCastInfo({
        spellName = spellName,
        targetId = targetId,
        tier = tier,
        isHoT = isHoT,
        manaCost = manaCost,
        startTime = mq.gettime(),
    })

    local success = SpellEngine.cast(spellName, targetId, { spellCategory = 'heal' })

    if success then
        -- Register incoming AFTER cast confirmed
        IncomingHeals.registerMyCast(targetId, spellName, expected, castDuration, isHoT)
        broadcastIncoming(targetId, spellName, expected, mq.gettime() + castDuration, isHoT)
        return true
    else
        -- Cast failed, clear cast info
        SpellEvents.setCastInfo(nil)
        return false
    end
end
```

### ActorsCoordinator Integration

**Requires ActorsCoordinator changes.** New message handlers must be registered.

**Avoiding Circular Require:**
The handlers use `pcall(require, 'healing')` to lazy-load the healing module only when a message is received. This avoids circular dependency issues since:
1. ActorsCoordinator loads first during SideKick init
2. Healing module loads later (only for CLR)
3. Handlers resolve the reference at runtime, not at require time

```lua
-- In utils/actors_coordinator.lua

local function onHealIncoming(data, senderId)
    -- Lazy-load to avoid circular require
    local ok, Healing = pcall(require, 'healing')
    if ok and Healing and Healing.handleActorMessage then
        Healing.handleActorMessage('heal:incoming', data, senderId)
    end
end

local function onHealLanded(data, senderId)
    local ok, Healing = pcall(require, 'healing')
    if ok and Healing and Healing.handleActorMessage then
        Healing.handleActorMessage('heal:landed', data, senderId)
    end
end

local function onHealCancelled(data, senderId)
    local ok, Healing = pcall(require, 'healing')
    if ok and Healing and Healing.handleActorMessage then
        Healing.handleActorMessage('heal:cancelled', data, senderId)
    end
end

-- Register in init:
registerHandler('heal:incoming', onHealIncoming)
registerHandler('heal:landed', onHealLanded)
registerHandler('heal:cancelled', onHealCancelled)
```

### Migration Strategy

| Class | Module |
|-------|--------|
| CLR | New `healing/` module |
| SHM, DRU, RNG, BST | Legacy `automation/healing.lua` |

Future: Migrate other classes by adding spell category mappings to their class configs.

## Timing Considerations

All elapsed-time calculations use `mq.gettime()` (wall-clock time), NOT `os.clock()` (CPU time which drifts when client idles).

**Use `mq.gettime()` for:**
- Cast timing (start, duration, lands at)
- DPS window calculations
- Incoming heal expiration
- HoT expiration tracking
- Duck monitoring
- Throttle timers

**Use `os.time()` for:**
- Persistence timestamps (heal data lastUpdated)
- Session start time
- Logging timestamps

### Unit Consistency

All time-related fields must use consistent units:

| Field | Unit | Source |
|-------|------|--------|
| `castStartTime` | seconds (float) | `mq.gettime()` |
| `castDuration` | seconds (float) | `MyCastTime() / 1000` |
| `landsAt` | seconds (float) | `castStartTime + castDuration` |
| `hotExpiresAt` | seconds (float) | `mq.gettime() + hotDuration` |
| `lastUpdated` | seconds (integer) | `os.time()` |

**Important:** `MyCastTime()` returns milliseconds, so always divide by 1000 before storing or using in calculations.

## Future Work

- Migrate SHM, DRU, RNG, BST to new system
- Raid healing support (different UI/coordination)
- Add promised heal support if relevant spells exist
- Cross-character analytics aggregation
- Heal assignment suggestions based on learned data
