# HoT Trust & Healing Efficiency Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Improve healing efficiency by properly trusting HoTs and sizing direct heals based on actual damage pressure.

**Architecture:** Add projected HP calculation that compares HoT HPS vs attributed DPS, with dynamic projection windows based on pressure level. Gate HoT application on TTK and DPS ratio checks. Add verbose logging for tuning.

**Tech Stack:** Lua, MacroQuest TLO, mq.event for damage parsing

---

## Task 1: Add Configuration Options

**Files:**
- Modify: `healing/config.lua:158-173` (after logCategories, before spells)

**Step 1: Add new config options after logCategories block**

In `healing/config.lua`, add these options after line 159 (after `attribution = false`):

```lua
    -- HoT Coverage Logging (new)
    hotCoverage = true,           -- HoT vs direct heal decision logging
},

-- HoT Trust & Efficiency Settings (new)
hotCoverageLogLevel = 2,          -- 0=off, 1=summary, 2=detailed, 3=verbose

-- Projection windows (seconds) for HoT trust calculation
projectionWindowLow = 8,
projectionWindowNormal = 6,
projectionWindowHigh = 3,

-- Heal thresholds by role and pressure (projected HP % to trigger direct heal)
healThresholds = {
    tank    = { low = 50, normal = 60, high = 70 },
    healer  = { low = 60, normal = 70, high = 80 },
    dps     = { low = 55, normal = 65, high = 75 },
    squishy = { low = 65, normal = 75, high = 85 },
},

-- HoT application gates
hotMinUsableTicks = 2,            -- Require at least 2 ticks to apply HoT
hotSingleMobMinDpsRatio = 0.8,    -- Single-mob: DPS must be >= 80% of HoT HPS
hotMultiMobMinDpsRatio = 0.3,     -- Multi-mob: DPS must be >= 30% of HoT HPS
hotMaxOverhealRatio = 1.5,        -- Skip HoT if expected healing > damage × this
```

**Step 2: Verify config loads correctly**

Run SideKick, check for Lua errors on load. Config should merge new defaults.

**Step 3: Commit**

```bash
git add healing/config.lua
git commit -m "feat(healing): add HoT trust configuration options"
```

---

## Task 2: Add HoT Coverage Logging Functions

**Files:**
- Modify: `healing/logger.lua` (add new logging functions at end, before `return M`)

**Step 1: Add logHotCoverageDecision function**

Add before `return M` in `healing/logger.lua`:

```lua
-- HoT Coverage decision logging with configurable verbosity
-- Level 0: off, 1: summary, 2: detailed, 3: verbose
function M.logHotCoverageDecision(targetName, analysis, decision, level)
    local configLevel = Config and Config.hotCoverageLogLevel or 2
    if configLevel == 0 then return end
    if not shouldLog('info', 'hotCoverage') then return end

    local a = analysis or {}
    local decisionText = decision or 'UNKNOWN'

    if configLevel == 1 then
        -- Summary: one line
        local line = string.format('%s: HoT %.0f%% coverage, projected %.0f%% %s %.0f%% threshold -> %s',
            targetName or '?',
            (a.coverageRatio or 0) * 100,
            a.projectedPct or 0,
            (a.projectedPct or 0) >= (a.threshold or 0) and '>=' or '<',
            a.threshold or 0,
            decisionText)
        write('info', 'hotCoverage', line)
        return
    end

    if configLevel == 2 then
        -- Detailed: multi-line with key values
        local lines = { string.format('HOT_DECISION %s:', targetName or '?') }
        table.insert(lines, string.format('  State: HP=%.0f%% DPS=%.0f HoT_HPS=%.0f coverage=%.0f%%',
            a.currentPct or 0, a.dps or 0, a.hotHps or 0, (a.coverageRatio or 0) * 100))
        table.insert(lines, string.format('  Projection: window=%.0fs projected=%.0f%% threshold=%.0f%% (%s/%s)',
            a.windowSec or 0, a.projectedPct or 0, a.threshold or 0, a.role or '?', a.pressure or '?'))
        table.insert(lines, string.format('  Decision: %s%s',
            decisionText,
            a.uncoveredGap and string.format(' (gap=%.0f HP)', a.uncoveredGap) or ''))
        write('info', 'hotCoverage', table.concat(lines, '\n'))
        return
    end

    -- Level 3: Verbose with full breakdown
    local lines = { string.format('HOT_DECISION %s:', targetName or '?') }
    table.insert(lines, string.format('  Target: HP=%.0f%% (%.0f/%.0f) deficit=%.0f role=%s',
        a.currentPct or 0, a.currentHP or 0, a.maxHP or 0, a.deficit or 0, a.role or '?'))
    table.insert(lines, string.format('  Pressure: %s (mobs=%d TTK=%.0fs survival=%s)',
        a.pressure or '?', a.mobCount or 0, a.ttk or 0, tostring(a.survivalMode or false)))

    -- DPS Attribution breakdown
    table.insert(lines, string.format('  DPS Attribution: total=%.0f sources=%d',
        a.dps or 0, a.sourceCount or 0))
    if a.sources and #a.sources > 0 then
        for _, src in ipairs(a.sources) do
            local primary = src.isPrimary and ' (primary)' or ''
            table.insert(lines, string.format('    - "%s" @%.0f DPS%s', src.name or '?', src.dps or 0, primary))
        end
    end

    -- HoT info
    if a.hotSpell then
        table.insert(lines, string.format('  HoT Active: %s', a.hotSpell))
        table.insert(lines, string.format('    - ticks_remaining=%d tick_amount=%.0f HPS=%.0f',
            a.ticksRemaining or 0, a.tickAmount or 0, a.hotHps or 0))
        table.insert(lines, string.format('    - expires_in=%.0fs', a.hotRemainingSec or 0))
    else
        table.insert(lines, '  HoT Active: none')
    end

    -- Coverage calculation
    table.insert(lines, string.format('  Coverage: HoT_HPS/DPS = %.0f/%.0f = %.1f%%',
        a.hotHps or 0, a.dps or 0, (a.coverageRatio or 0) * 100))

    -- Projection breakdown
    table.insert(lines, string.format('  Projection: window=%.0fs (%s pressure, capped by TTK=%.0fs)',
        a.windowSec or 0, a.pressure or '?', a.ttk or 0))
    table.insert(lines, string.format('    - damage_in_window = %.0f x %.0fs = %.0f',
        a.dps or 0, a.windowSec or 0, a.damageInWindow or 0))
    table.insert(lines, string.format('    - healing_in_window = %.0f x %.0fs = %.0f',
        a.hotHps or 0, a.windowSec or 0, a.healingInWindow or 0))
    table.insert(lines, string.format('    - projected_HP = %.0f - %.0f + %.0f = %.0f (%.1f%%)',
        a.currentHP or 0, a.damageInWindow or 0, a.healingInWindow or 0,
        a.projectedHP or 0, a.projectedPct or 0))

    -- Threshold lookup
    table.insert(lines, string.format('  Threshold: %s + %s = %.0f%%',
        a.role or '?', a.pressure or '?', a.threshold or 0))

    -- Final decision
    table.insert(lines, string.format('  Decision: %s (%.1f%% %s %.0f%%)',
        decisionText,
        a.projectedPct or 0,
        (a.projectedPct or 0) >= (a.threshold or 0) and '>=' or '<',
        a.threshold or 0))

    if a.uncoveredGap and a.uncoveredGap > 0 then
        table.insert(lines, string.format('  Spell sizing: uncovered_gap = %.0f - %.0f = %.0f HP -> %s',
            a.damageInWindow or 0, a.healingInWindow or 0, a.uncoveredGap, a.recommendedSize or 'small heal'))
    end

    write('info', 'hotCoverage', table.concat(lines, '\n'))
end

-- Log HoT application decision (when deciding whether to cast a HoT)
function M.logHotApplicationDecision(targetName, analysis, decision, reason)
    local configLevel = Config and Config.hotCoverageLogLevel or 2
    if configLevel == 0 then return end
    if not shouldLog('info', 'hotCoverage') then return end

    local a = analysis or {}

    if configLevel == 1 then
        write('info', 'hotCoverage', string.format('HOT_APPLY %s: %s (%s)',
            targetName or '?', decision and 'YES' or 'NO', reason or '?'))
        return
    end

    local lines = { string.format('HOT_APPLICATION %s:', targetName or '?') }
    table.insert(lines, string.format('  TTK: %.0fs | HoT duration: %.0fs | Usable ticks: %d (min: %d)',
        a.ttk or 0, a.hotDuration or 0, a.usableTicks or 0, a.minUsableTicks or 2))
    table.insert(lines, string.format('  DPS: %.0f | HoT HPS: %.0f | Ratio: %.2f (need: %.2f for %s)',
        a.dps or 0, a.hotHps or 0, a.dpsRatio or 0, a.requiredRatio or 0, a.mobType or '?'))
    table.insert(lines, string.format('  Expected healing: %.0f | Expected damage: %.0f | Overheal ratio: %.2f',
        a.expectedHealing or 0, a.expectedDamage or 0, a.overhealRatio or 0))
    table.insert(lines, string.format('  Decision: %s (%s)', decision and 'APPLY_HOT' or 'SKIP_HOT', reason or '?'))

    write('info', 'hotCoverage', table.concat(lines, '\n'))
end
```

**Step 2: Verify logging compiles**

Run SideKick, ensure no Lua errors.

**Step 3: Commit**

```bash
git add healing/logger.lua
git commit -m "feat(healing): add HoT coverage logging functions with verbosity levels"
```

---

## Task 3: Create HoT Analyzer Module

**Files:**
- Create: `healing/hot_analyzer.lua`

**Step 1: Create the hot_analyzer module**

```lua
-- healing/hot_analyzer.lua
-- Analyzes whether to trust active HoTs or cast direct heals
local mq = require('mq')

local M = {}

local Config = nil
local HealTracker = nil
local CombatAssessor = nil
local Proactive = nil
local DamageAttribution = nil
local Logger = nil

function M.init(config, healTracker, combatAssessor, proactive)
    Config = config
    HealTracker = healTracker
    CombatAssessor = combatAssessor
    Proactive = proactive

    -- Lazy load damage attribution
    local ok, da = pcall(require, 'healing.damage_attribution')
    DamageAttribution = ok and da or nil

    -- Lazy load logger
    ok, Logger = pcall(require, 'healing.logger')
    if not ok then Logger = nil end
end

-- Get pressure level from combat state
local function getPressureLevel()
    if not CombatAssessor or not CombatAssessor.getState then
        return 'normal', 0, 0, false
    end
    local state = CombatAssessor.getState()
    if not state then return 'normal', 0, 999, false end

    local mobs = state.activeMobCount or 0
    local ttk = state.estimatedTTK or 999
    local survival = state.survivalMode == true

    if survival then
        return 'high', mobs, ttk, survival
    end

    local highPressure = CombatAssessor.isHighPressure and CombatAssessor.isHighPressure()
    if highPressure then
        return 'high', mobs, ttk, survival
    end

    -- Check low pressure conditions
    local maxLowMobs = Config and Config.lowPressureMobCount or 1
    if mobs <= maxLowMobs then
        return 'low', mobs, ttk, survival
    end

    return 'normal', mobs, ttk, survival
end

-- Get projection window based on pressure
local function getProjectionWindow(pressure, ttk)
    local cfg = Config or {}
    local window
    if pressure == 'low' then
        window = cfg.projectionWindowLow or 8
    elseif pressure == 'high' then
        window = cfg.projectionWindowHigh or 3
    else
        window = cfg.projectionWindowNormal or 6
    end
    -- Cap at TTK
    return math.min(window, ttk)
end

-- Get heal threshold based on role and pressure
local function getHealThreshold(role, pressure)
    local cfg = Config or {}
    local thresholds = cfg.healThresholds or {
        tank    = { low = 50, normal = 60, high = 70 },
        healer  = { low = 60, normal = 70, high = 80 },
        dps     = { low = 55, normal = 65, high = 75 },
        squishy = { low = 65, normal = 75, high = 85 },
    }

    local roleThresholds = thresholds[role] or thresholds.dps
    return roleThresholds[pressure] or roleThresholds.normal or 60
end

-- Get HoT HPS for a spell
local function getHotHps(spellName)
    if not spellName then return 0 end

    local tickAmount = 0
    if HealTracker and HealTracker.getExpected then
        tickAmount = HealTracker.getExpected(spellName, 'tick') or 0
    end

    if tickAmount <= 0 then
        -- Fallback to spell data
        local spell = mq.TLO.Spell(spellName)
        if spell and spell() and spell.Base then
            tickAmount = math.abs(tonumber(spell.Base(1)()) or 0)
        end
    end

    return tickAmount / 6  -- 6 second tick interval
end

-- Get attributed DPS for target (with source breakdown for verbose logging)
local function getAttributedDps(targetId)
    if not DamageAttribution or not DamageAttribution.getTargetDamageInfo then
        return 0, 0, {}
    end

    local info = DamageAttribution.getTargetDamageInfo(targetId)
    if not info then
        return 0, 0, {}
    end

    -- Build source list for verbose logging
    local sources = {}
    -- Note: damage_attribution may not expose per-source details publicly
    -- This is a placeholder for when that data is available

    return info.totalDps or 0, info.sourceCount or 0, sources
end

-- Main function: Should we trust the HoT or cast a direct heal?
function M.shouldTrustHoT(targetInfo, situation)
    if not targetInfo then return false, nil, 'no_target' end
    if not Config then return false, nil, 'no_config' end

    local targetId = targetInfo.id
    local targetName = targetInfo.name or '?'

    -- Check if target has an active HoT
    local hasHoT, hotSpell, hotRemaining = false, nil, 0
    if Proactive and Proactive.hasActiveHoT then
        hasHoT, hotSpell, hotRemaining = Proactive.hasActiveHoT(targetId)
    end

    if not hasHoT then
        return false, nil, 'no_active_hot'
    end

    -- Get pressure and combat state
    local pressure, mobs, ttk, survival = getPressureLevel()

    -- Get projection window
    local windowSec = getProjectionWindow(pressure, ttk)

    -- Get HoT healing rate
    local hotHps = getHotHps(hotSpell)
    if hotHps <= 0 then
        return false, nil, 'no_hot_hps_data'
    end

    -- Get attributed DPS
    local dps, sourceCount, sources = getAttributedDps(targetId)

    -- Fallback to targetInfo.recentDps if attribution not available
    if dps <= 0 then
        dps = targetInfo.recentDps or 0
    end

    -- Calculate coverage ratio
    local coverageRatio = dps > 0 and (hotHps / dps) or 999

    -- Calculate projected HP
    local currentHP = targetInfo.currentHP or 0
    local maxHP = targetInfo.maxHP or 1
    local currentPct = (currentHP / maxHP) * 100

    local damageInWindow = dps * windowSec
    local healingInWindow = hotHps * windowSec
    local projectedHP = currentHP - damageInWindow + healingInWindow
    projectedHP = math.max(0, math.min(projectedHP, maxHP))
    local projectedPct = (projectedHP / maxHP) * 100

    -- Get role
    local role = targetInfo.role or 'dps'
    if targetInfo.isSquishy then
        role = 'squishy'
    end

    -- Get threshold
    local threshold = getHealThreshold(role, pressure)

    -- Calculate uncovered gap if we need to heal
    local uncoveredGap = 0
    local recommendedSize = nil
    if projectedPct < threshold then
        uncoveredGap = math.max(0, damageInWindow - healingInWindow)
        -- Recommend heal size based on gap
        if uncoveredGap < maxHP * 0.15 then
            recommendedSize = 'small'
        elseif uncoveredGap < maxHP * 0.30 then
            recommendedSize = 'medium'
        else
            recommendedSize = 'large'
        end
    end

    -- Build analysis data for logging
    local ticksRemaining = math.floor(hotRemaining / 6)
    local tickAmount = hotHps * 6

    local analysis = {
        -- Target info
        currentHP = currentHP,
        maxHP = maxHP,
        currentPct = currentPct,
        deficit = targetInfo.deficit or 0,
        role = role,

        -- Combat state
        pressure = pressure,
        mobCount = mobs,
        ttk = ttk,
        survivalMode = survival,

        -- DPS info
        dps = dps,
        sourceCount = sourceCount,
        sources = sources,

        -- HoT info
        hotSpell = hotSpell,
        hotHps = hotHps,
        ticksRemaining = ticksRemaining,
        tickAmount = tickAmount,
        hotRemainingSec = hotRemaining,

        -- Coverage
        coverageRatio = coverageRatio,

        -- Projection
        windowSec = windowSec,
        damageInWindow = damageInWindow,
        healingInWindow = healingInWindow,
        projectedHP = projectedHP,
        projectedPct = projectedPct,

        -- Threshold
        threshold = threshold,

        -- Gap
        uncoveredGap = uncoveredGap,
        recommendedSize = recommendedSize,
    }

    -- Make decision
    local trustHoT = projectedPct >= threshold
    local decision = trustHoT and 'TRUST_HOT' or 'CAST_DIRECT'

    -- Log the decision
    if Logger and Logger.logHotCoverageDecision then
        Logger.logHotCoverageDecision(targetName, analysis, decision)
    end

    return trustHoT, analysis, decision
end

-- Check if HoT should be applied (TTK and DPS ratio gates)
function M.shouldApplyHoT(targetInfo, hotSpellName, situation)
    if not targetInfo or not hotSpellName then
        return false, nil, 'missing_params'
    end
    if not Config then
        return false, nil, 'no_config'
    end

    local targetId = targetInfo.id
    local targetName = targetInfo.name or '?'

    -- Get HoT duration
    local spell = mq.TLO.Spell(hotSpellName)
    if not spell or not spell() then
        return false, nil, 'invalid_spell'
    end

    local hotDuration = 0
    if spell.Duration and spell.Duration.TotalSeconds then
        hotDuration = tonumber(spell.Duration.TotalSeconds()) or 0
    end
    if hotDuration <= 0 then
        hotDuration = 36  -- Default assumption
    end

    -- Get combat state
    local pressure, mobs, ttk, survival = getPressureLevel()

    -- Gate 1: TTK check - enough time for HoT to deliver value?
    local usableTicks = math.floor(math.min(ttk, hotDuration) / 6)
    local minUsableTicks = Config.hotMinUsableTicks or 2

    if usableTicks < minUsableTicks then
        local analysis = {
            ttk = ttk,
            hotDuration = hotDuration,
            usableTicks = usableTicks,
            minUsableTicks = minUsableTicks,
        }
        if Logger and Logger.logHotApplicationDecision then
            Logger.logHotApplicationDecision(targetName, analysis, false, 'ttk_too_short')
        end
        return false, analysis, 'ttk_too_short'
    end

    -- Get HoT HPS
    local hotHps = getHotHps(hotSpellName)
    if hotHps <= 0 then
        return false, nil, 'no_hot_hps_data'
    end

    -- Get DPS
    local dps, sourceCount, _ = getAttributedDps(targetId)
    if dps <= 0 then
        dps = targetInfo.recentDps or 0
    end

    -- Gate 2: DPS ratio check
    local dpsRatio = dps > 0 and (dps / hotHps) or 0
    local mobType = mobs <= 1 and 'single' or 'multi'
    local requiredRatio = mobType == 'single'
        and (Config.hotSingleMobMinDpsRatio or 0.8)
        or (Config.hotMultiMobMinDpsRatio or 0.3)

    if dpsRatio < requiredRatio then
        local analysis = {
            ttk = ttk,
            hotDuration = hotDuration,
            usableTicks = usableTicks,
            minUsableTicks = minUsableTicks,
            dps = dps,
            hotHps = hotHps,
            dpsRatio = dpsRatio,
            requiredRatio = requiredRatio,
            mobType = mobType,
        }
        if Logger and Logger.logHotApplicationDecision then
            Logger.logHotApplicationDecision(targetName, analysis, false, 'dps_ratio_too_low')
        end
        return false, analysis, 'dps_ratio_too_low'
    end

    -- Gate 3: Efficiency check - don't massively overheal
    local expectedHealing = usableTicks * (hotHps * 6)
    local expectedDamage = dps * math.min(ttk, hotDuration)
    local overhealRatio = expectedDamage > 0 and (expectedHealing / expectedDamage) or 999
    local maxOverhealRatio = Config.hotMaxOverhealRatio or 1.5

    if overhealRatio > maxOverhealRatio then
        local analysis = {
            ttk = ttk,
            hotDuration = hotDuration,
            usableTicks = usableTicks,
            minUsableTicks = minUsableTicks,
            dps = dps,
            hotHps = hotHps,
            dpsRatio = dpsRatio,
            requiredRatio = requiredRatio,
            mobType = mobType,
            expectedHealing = expectedHealing,
            expectedDamage = expectedDamage,
            overhealRatio = overhealRatio,
        }
        if Logger and Logger.logHotApplicationDecision then
            Logger.logHotApplicationDecision(targetName, analysis, false, 'overheal_ratio_too_high')
        end
        return false, analysis, 'overheal_ratio_too_high'
    end

    -- All gates passed
    local analysis = {
        ttk = ttk,
        hotDuration = hotDuration,
        usableTicks = usableTicks,
        minUsableTicks = minUsableTicks,
        dps = dps,
        hotHps = hotHps,
        dpsRatio = dpsRatio,
        requiredRatio = requiredRatio,
        mobType = mobType,
        expectedHealing = expectedHealing,
        expectedDamage = expectedDamage,
        overhealRatio = overhealRatio,
    }

    if Logger and Logger.logHotApplicationDecision then
        Logger.logHotApplicationDecision(targetName, analysis, true, 'gates_passed')
    end

    return true, analysis, 'apply_hot'
end

-- Get the uncovered healing gap for sizing direct heals
function M.getUncoveredGap(targetInfo)
    local trustHoT, analysis, _ = M.shouldTrustHoT(targetInfo, nil)
    if trustHoT then
        return 0, analysis
    end
    return analysis and analysis.uncoveredGap or targetInfo.deficit, analysis
end

return M
```

**Step 2: Verify module loads**

Run SideKick, ensure no Lua errors.

**Step 3: Commit**

```bash
git add healing/hot_analyzer.lua
git commit -m "feat(healing): add hot_analyzer module for HoT trust calculations"
```

---

## Task 4: Initialize HoT Analyzer in init.lua

**Files:**
- Modify: `healing/init.lua`

**Step 1: Add HotAnalyzer require and init**

Find the module requires section (around lines 1-50) and add:

```lua
local HotAnalyzer = nil
local function getHotAnalyzer()
    if HotAnalyzer == nil then
        local ok, ha = pcall(require, 'healing.hot_analyzer')
        HotAnalyzer = ok and ha or false
    end
    return HotAnalyzer or nil
end
```

**Step 2: Initialize HotAnalyzer in M.init()**

Find the `M.init()` function and add after other module inits:

```lua
    -- Initialize HotAnalyzer
    local ha = getHotAnalyzer()
    if ha and ha.init then
        ha.init(Config, HealTracker, CombatAssessor, proactive)
    end
```

**Step 3: Commit**

```bash
git add healing/init.lua
git commit -m "feat(healing): initialize hot_analyzer module"
```

---

## Task 5: Integrate HoT Trust Check into Heal Selection

**Files:**
- Modify: `healing/init.lua` (tick function, target processing)

**Step 1: Factor HoT healing into effective deficit**

Find the target processing loop in tick() (around line 451-461) where `effectiveDeficit` is calculated. Modify to include HoT healing projection:

```lua
            entry.incomingTotal = incomingTotal
            entry.deficit = math.max(0, (entry.deficit or 0) - incomingTotal)

            -- Factor in HoT healing for effective deficit
            local hotAnalyzer = getHotAnalyzer()
            if hotAnalyzer and hotAnalyzer.shouldTrustHoT then
                local trustHoT, analysis, _ = hotAnalyzer.shouldTrustHoT(entry, situation)
                if trustHoT and analysis then
                    -- HoT is handling the healing, reduce effective deficit
                    entry.effectiveDeficit = 0
                    entry.hotTrusted = true
                    entry.hotAnalysis = analysis
                elseif analysis and analysis.uncoveredGap then
                    -- HoT can't keep up, effective deficit is the uncovered gap
                    entry.effectiveDeficit = analysis.uncoveredGap
                    entry.hotTrusted = false
                    entry.hotAnalysis = analysis
                else
                    entry.effectiveDeficit = entry.deficit
                end
            else
                entry.effectiveDeficit = entry.deficit
            end

            if proactive and proactive.getIncomingHotRemaining then
                entry.incomingHotRemaining = proactive.getIncomingHotRemaining(entry.name or entry.id)
            end
```

**Step 2: Skip healing for targets where HoT is trusted**

In the healing priority sections (emergency, tank, group), add check:

```lua
            -- Skip if HoT is trusted to handle this target
            if entry.hotTrusted then
                -- Log skip at debug level
                -- Continue to next target
            end
```

**Step 3: Commit**

```bash
git add healing/init.lua
git commit -m "feat(healing): integrate HoT trust check into heal selection"
```

---

## Task 6: Update HoT Application Logic in proactive.lua

**Files:**
- Modify: `healing/proactive.lua` (shouldApplyHoT function)

**Step 1: Add HotAnalyzer integration to shouldApplyHoT**

At the start of `shouldApplyHoT()` function (around line 580), add check for new gates:

```lua
function M.shouldApplyHoT(target, hotSpellName)
    if not Config or not Config.hotEnabled then
        return false, 'disabled'
    end

    -- Use HotAnalyzer for TTK and DPS ratio gates
    local ok, HotAnalyzer = pcall(require, 'healing.hot_analyzer')
    if ok and HotAnalyzer and HotAnalyzer.shouldApplyHoT then
        local shouldApply, analysis, reason = HotAnalyzer.shouldApplyHoT(target, hotSpellName, nil)
        if not shouldApply then
            return false, reason
        end
        -- Analysis passed new gates, continue with existing checks
    end

    -- ... rest of existing function
```

**Step 2: Commit**

```bash
git add healing/proactive.lua
git commit -m "feat(healing): integrate HoT analyzer gates into shouldApplyHoT"
```

---

## Task 7: Update heal_selector.lua to Use Uncovered Gap

**Files:**
- Modify: `healing/heal_selector.lua`

**Step 1: Add HotAnalyzer integration to SelectHeal**

In `SelectHeal()` function, after the HoT supplement section (around line 793), add:

```lua
    -- Check HoT trust before selecting direct heal
    local ok, HotAnalyzer = pcall(require, 'healing.hot_analyzer')
    if ok and HotAnalyzer and HotAnalyzer.shouldTrustHoT then
        local trustHoT, analysis, decision = HotAnalyzer.shouldTrustHoT(targetInfo, situation)
        if trustHoT then
            return nil, 'hot_trusted|' .. (analysis and string.format('projected=%.0f%% threshold=%.0f%%',
                analysis.projectedPct or 0, analysis.threshold or 0) or '')
        end

        -- Use uncovered gap for sizing the heal
        if analysis and analysis.uncoveredGap and analysis.uncoveredGap > 0 then
            deficit = analysis.uncoveredGap
            deficitPct = (deficit / (targetInfo.maxHP or 1)) * 100
        end
    end
```

**Step 2: Commit**

```bash
git add healing/heal_selector.lua
git commit -m "feat(healing): use HoT analyzer uncovered gap for heal sizing"
```

---

## Task 8: Test and Verify

**Step 1: Enable verbose logging**

Set in config or manually:
```lua
hotCoverageLogLevel = 3
```

**Step 2: Run in combat**

- Engage mobs with tank taking sustained damage
- Apply a HoT to tank
- Observe logs for HOT_DECISION entries
- Verify direct heals are sized to uncovered gap, not full deficit

**Step 3: Check log output**

Verify logs show:
- Pressure level detection
- DPS attribution
- HoT HPS calculation
- Projection calculation
- Threshold lookup
- Final decision

**Step 4: Adjust thresholds if needed**

Based on observed behavior, tune:
- `healThresholds` values
- `projectionWindow*` values
- `hotSingleMobMinDpsRatio` / `hotMultiMobMinDpsRatio`

**Step 5: Final commit**

```bash
git add -A
git commit -m "feat(healing): complete HoT trust and efficiency implementation"
```

---

## Summary

| Task | Description | Files |
|------|-------------|-------|
| 1 | Add configuration options | config.lua |
| 2 | Add logging functions | logger.lua |
| 3 | Create HoT analyzer module | hot_analyzer.lua (new) |
| 4 | Initialize HoT analyzer | init.lua |
| 5 | Integrate trust check | init.lua |
| 6 | Update HoT application | proactive.lua |
| 7 | Use uncovered gap | heal_selector.lua |
| 8 | Test and verify | - |
