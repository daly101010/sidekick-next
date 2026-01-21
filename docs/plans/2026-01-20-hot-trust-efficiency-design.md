# HoT Trust & Healing Efficiency Design

**Date:** 2026-01-20
**Status:** Design Complete
**Purpose:** Improve healing efficiency by properly trusting HoTs and sizing direct heals based on actual damage pressure.

## Problem Statement

The current healing system:
1. Applies HoTs then immediately follows with direct heals (doesn't trust HoT to handle damage)
2. Calculates `effectiveDeficit` without factoring in pending HoT healing
3. Doesn't compare HoT HPS vs incoming DPS to determine if HoT alone is sufficient
4. Applies HoTs in short fights where they can't deliver full value
5. Logs don't show the reasoning behind HoT vs direct heal decisions

## Solution Overview

Implement projected HP calculation that factors in:
- Attributed DPS on target (from damage_attribution module)
- HoT healing rate (HPS = tick amount / 6 seconds)
- Dynamic projection window based on combat pressure
- Role + pressure based thresholds
- TTK awareness for HoT application decisions

## Core Decision Logic

### Direct Heal Decision (when HoT is active)

```
1. Get attributed DPS for target (from damage_attribution module)
2. Get HoT HPS (tick amount / 6 seconds)
3. Calculate coverage ratio: HoT_HPS / attributed_DPS

4. Determine projection window:
   - Low pressure: 8 seconds
   - Normal pressure: 6 seconds
   - High/Survival: 3 seconds
   - Cap at remaining TTK (don't project past fight end)

5. Calculate projected HP:
   projected = currentHP - (DPS × window) + (HoT_HPS × window)
   projectedPct = projected / maxHP × 100

6. Look up threshold based on role + pressure (see matrix below)

7. Decision:
   - If projectedPct >= threshold → trust HoT, skip direct heal
   - If projectedPct < threshold → cast direct heal sized to the gap
```

### Heal Threshold Matrix

| Role | Low Pressure | Normal | High/Survival |
|------|--------------|--------|---------------|
| Tank | 50% | 60% | 70% |
| Healer | 60% | 70% | 80% |
| DPS | 55% | 65% | 75% |
| Squishy | 65% | 75% | 85% |

### HoT Application Logic

```
1. TTK Check (first gate):
   - Get HoT duration (e.g., 42s)
   - Get remaining TTK
   - Calculate usable_ticks = min(TTK, HoT_duration) / 6
   - If usable_ticks < 2 → skip HoT (won't get enough value)

2. DPS Ratio Check (second gate):
   - Get attributed DPS on target
   - Get HoT HPS (tick / 6)
   - Calculate ratio = DPS / HoT_HPS
   - Single mob: require ratio >= 0.8 (DPS must nearly match HoT healing)
   - Multi mob: require ratio >= 0.3 (sustained damage pattern)

3. Efficiency Check (final gate):
   - Calculate expected_healing = usable_ticks × tick_amount
   - Calculate expected_damage = DPS × TTK
   - If expected_healing > expected_damage × 1.5 → skip (too much overheal)
```

### HoT Application Examples

| TTK | Mobs | DPS | HoT HPS | Decision |
|-----|------|-----|---------|----------|
| 8s | 1 | 350 | 385 | Skip (only 1 tick possible) |
| 25s | 1 | 150 | 385 | Skip (ratio 0.39 < 0.8) |
| 25s | 1 | 350 | 385 | Apply (ratio 0.91 >= 0.8, 4 ticks) |
| 40s | 2 | 200 | 385 | Apply (ratio 0.52 >= 0.3, 6+ ticks) |
| 12s | 2 | 200 | 385 | Apply (ratio 0.52 >= 0.3, 2 ticks) |
| 6s | 2 | 200 | 385 | Skip (only 1 tick, not enough value) |

## Logging Design

### New Config Option

```lua
hotCoverageLogLevel = 2,  -- 0=off, 1=summary, 2=detailed, 3=verbose
```

### Log Category

New category: `hotCoverage` (added to existing logCategories in config)

### Log Output by Level

**Level 1 (Summary):**
```
[15:17:38][INFO][hotCoverage] Daallyy: HoT 45% coverage, projected 57% < 60% threshold → DIRECT_HEAL
[15:17:42][INFO][hotCoverage] Daallyy: HoT 85% coverage, projected 72% >= 60% threshold → TRUST_HOT
```

**Level 2 (Detailed):**
```
[15:17:38][INFO][hotCoverage] HOT_DECISION Daallyy:
  State: HP=72% DPS=850 HoT_HPS=385 coverage=45%
  Projection: window=6s projected=57% threshold=60% (tank/normal)
  Decision: CAST_DIRECT (gap=2790 HP)
```

**Level 3 (Verbose):**
```
[15:17:38][DEBUG][hotCoverage] HOT_DECISION Daallyy:
  Target: HP=72% (14100/19586) deficit=5486 role=tank
  Pressure: normal (mobs=2 TTK=25s survival=false)
  DPS Attribution: total=850 sources=2
    - "a frost giant" @520 DPS (primary)
    - "a frost giant scout" @330 DPS
  HoT Active: Sacred Elixir Rk. III
    - ticks_remaining=5 tick_amount=2310 HPS=385
    - expires_in=30s
  Coverage: HoT_HPS/DPS = 385/850 = 45.3%
  Projection: window=6s (normal pressure, capped by TTK=25s)
    - damage_in_window = 850 × 6 = 5100
    - healing_in_window = 385 × 6 = 2310
    - projected_HP = 14100 - 5100 + 2310 = 11310 (57.7%)
  Threshold: tank + normal = 60%
  Decision: CAST_DIRECT (57.7% < 60%)
  Spell sizing: uncovered_gap = 5100 - 2310 = 2790 HP → small heal
```

## Configuration

### New Config Settings

```lua
-- Projection windows (seconds)
projectionWindowLow = 8,
projectionWindowNormal = 6,
projectionWindowHigh = 3,

-- Thresholds matrix (role → pressure → threshold %)
healThresholds = {
    tank    = { low = 50, normal = 60, high = 70 },
    healer  = { low = 60, normal = 70, high = 80 },
    dps     = { low = 55, normal = 65, high = 75 },
    squishy = { low = 65, normal = 75, high = 85 },
},

-- HoT application
hotMinUsableTicks = 2,            -- Require at least 2 ticks to apply HoT
hotSingleMobMinDpsRatio = 0.8,    -- Single-mob: DPS must be >= 80% of HoT HPS
hotMultiMobMinDpsRatio = 0.3,     -- Multi-mob: DPS must be >= 30% of HoT HPS
hotMaxOverhealRatio = 1.5,        -- Skip if expected healing > damage × this

-- Logging
hotCoverageLogLevel = 2,          -- 0=off, 1=summary, 2=detailed, 3=verbose
```

## Implementation Changes

### Files to Modify

| File | Changes |
|------|---------|
| `healing/config.lua` | Add new config options (projection windows, thresholds, HoT ratios, log level) |
| `healing/init.lua` | Factor `incomingHotRemaining` into `effectiveDeficit`, integrate projection logic |
| `healing/proactive.lua` | Update `shouldApplyHoT()` with TTK + DPS ratio checks, add `getHotHps()` |
| `healing/heal_selector.lua` | Add `shouldTrustHoT()` check before scoring direct heals |
| `healing/logger.lua` | Add `logHotCoverageDecision()` with verbosity levels |
| `healing/damage_attribution.lua` | Ensure `getTargetDamageInfo()` returns per-source breakdown for verbose logging |

### New Functions

```lua
-- In heal_selector.lua or new healing/hot_analyzer.lua
function calculateProjectedHP(target, windowSec)
function getProjectionWindow(pressureLevel, ttk)
function getHealThreshold(role, pressureLevel)
function shouldTrustHoT(target, situation)
function getUncoveredGap(target, situation)

-- In proactive.lua
function getHotHps(spellName)
function calculateUsableTicks(hotDuration, ttk)
function shouldApplyHoTRevised(target, hotSpellName, situation)

-- In logger.lua
function logHotCoverageDecision(target, analysis, decision, level)
```

### Data Flow Change

```
Current:
  deficit → effectiveDeficit (minus incoming direct heals only)
          → score spells → cast

Proposed:
  deficit → effectiveDeficit (minus incoming direct + projected HoT healing)
          → shouldTrustHoT() check
          → if trust: skip direct heal, log decision
          → if not: calculate uncovered gap
                  → score spells sized to gap
                  → cast
```

## Summary

| Change | Benefit |
|--------|---------|
| Projected HP calculation | Know if HoT can sustain target without direct heals |
| Dynamic projection window | React faster in high pressure, trust more in low pressure |
| Role + pressure thresholds | Appropriate caution for squishies, trust tanks more |
| TTK-aware HoT application | Don't waste HoTs in short fights |
| DPS ratio for HoT application | Only HoT when damage justifies it |
| Verbose logging | Full visibility into decision reasoning for tuning |
