# Paladin Healing Intelligence Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Give paladins hybrid tank-aware healing intelligence by extending the existing CLR healing system with mode-aware target filtering, Target's Target spell support, and a hint interface for tank module cooperation.

**Architecture:** Open the healing intelligence gate to PAL, add HealMode setting (off/tank/full), restrict heal targets in target_monitor based on mode, add `nukeHeal` category for TT spells with NPC-preferred targeting, expose heal hints for future tank module integration. See `docs/plans/2026-02-28-paladin-healing-intelligence-design.md` for full design.

**Tech Stack:** MQ Lua, existing healing intelligence modules (heal_selector, config, target_monitor, init), spell_engine, rotation_engine skipLayers, PAL class config.

---

## Important Context

### Codebase conventions
- `F:\lua\sidekick-next` is the repo root. Use relative paths in requires.
- MQ Lua uses `mq.TLO` for game data, `mq.cmd`/`mq.cmdf` for commands.
- No test framework — verification is manual in-game or via code review of logic.
- Healing modules live in `healing/` directory. Class configs in `data/class_configs/`.
- The healing system has two tracks: legacy (`automation/healing.lua`) and new intelligence (`healing/init.lua` + submodules). CLR uses new; all others use legacy. PAL currently excluded from both.

### Key files you'll touch
- `healing/init.lua` — Main healing orchestrator (gate + TT cast path + hints)
- `healing/config.lua` — Spell categorization and auto-assignment
- `healing/heal_selector.lua` — Deficit-based spell selection and scoring
- `healing/target_monitor.lua` — Target scanning with mode filtering
- `healing/tt_tracker.lua` — **NEW** — Target's Target heal tracking
- `automation/healing.lua` — Legacy healing (remove PAL exclusion, add profile)
- `utils/spell_engine.lua` — Targeting logic for TT spells
- `data/class_configs/PAL.lua` — HealMode setting + nukeHeal override
- `ui/settings/tab_healing.lua` — HealMode dropdown + TT stats
- `SideKick.lua` — getHealingModule gate + skipLayers when HealMode active

---

## Task 1: Open the Healing Intelligence Gate to PAL

Open both gates that currently block PAL from using the healing system.

**Files:**
- Modify: `healing/init.lua:94-99` (isHealerClass function)
- Modify: `automation/healing.lua:87-89,279-282` (PAL exclusion + profile)
- Modify: `SideKick.lua:36-40` (getHealingModule class check)

**Step 1: Open healing/init.lua gate**

In `healing/init.lua`, find the `isHealerClass()` function at line 94:

```lua
-- Current (line 99):
    return classShort == 'CLR'  -- Only CLR for now
```

Change to:

```lua
    return classShort == 'CLR' or classShort == 'PAL'
```

**Step 2: Open SideKick.lua gate**

In `SideKick.lua`, find `getHealingModule()` at line 36. The class check at line 40:

```lua
-- Current (line 40):
    if classShort:upper() ~= 'CLR' then return LegacyHealing end
```

Change to:

```lua
    local upper = classShort:upper()
    if upper ~= 'CLR' and upper ~= 'PAL' then return LegacyHealing end
```

**Step 3: Remove PAL exclusion from legacy healing**

In `automation/healing.lua`, remove the PAL exclusion at line 87-89:

```lua
-- REMOVE these lines:
    -- Exclude PAL explicitly.
    if classShort == 'PAL' then return nil end
```

Replace with a PAL profile:

```lua
    if classShort == 'PAL' then
        return {
            main = { 'Preservation', 'HealNuke', 'SelfHeal' },
            big = { 'HealNuke', 'Preservation', 'SelfHeal' },
            group = { 'Aurora' },
            hotSingle = {},
            hotGroup = {},
        }
    end
```

**Step 4: Remove second PAL exclusion in legacy tick()**

In `automation/healing.lua`, find the second exclusion at lines 279-282:

```lua
-- REMOVE these lines:
    if classShort == 'PAL' then
        _state.priorityActive = false
        return false
    end
```

**Step 5: Commit**

```bash
git add healing/init.lua automation/healing.lua SideKick.lua
git commit -m "feat(pal): open healing intelligence gate to paladin"
```

---

## Task 2: Add HealMode Setting to PAL Config

Add the HealMode setting and ensure healing category overrides are correct.

**Files:**
- Modify: `data/class_configs/PAL.lua:460-531` (Settings table)
- Modify: `data/class_configs/PAL.lua:172-193` (categoryOverrides)

**Step 1: Add HealMode setting to PAL.lua Settings table**

In `data/class_configs/PAL.lua`, add to the `M.Settings` table (after the existing `DoHealing` entry at line 461):

```lua
    HealMode = {
        Default = 'tank',
        Category = "Heal",
        DisplayName = "Heal Mode",
        Options = { 'off', 'tank', 'full' },
        Tooltip = "off = rotation conditions only, tank = self + emergency group + critical target, full = deficit-based healing like CLR",
    },
```

**Step 2: Update categoryOverrides for healing spells**

The current `categoryOverrides` at lines 172-193 map `doPreservation`, `doAurora`, `doSelfHeal` to `'support'` and `doHealNuke` to `'combat'`. When HealMode is active, these rotation-engine conditions should be superseded. Change `doPreservation`, `doAurora`, and `doSelfHeal` from `'support'` to `'heal'` so `skipLayers` can disable them:

```lua
    ['doPreservation'] = 'heal',
    ['doAurora'] = 'heal',
    ['doSelfHeal'] = 'heal',
```

Keep `doHealNuke` as `'combat'` — it does damage too, and the healing intelligence will handle the heal-via-TT aspect.

**Step 3: Commit**

```bash
git add data/class_configs/PAL.lua
git commit -m "feat(pal): add HealMode setting and update heal category overrides"
```

---

## Task 3: Add nukeHeal Category to Healing Config

Add the `nukeHeal` spell category for Target's Target spells and update auto-assignment.

**Files:**
- Modify: `healing/config.lua:193-204` (spells table)
- Modify: `healing/config.lua:330-378` (categorizeHealSpell function)
- Modify: `healing/config.lua:392-403` (autoAssignFromSpellBar spells init)
- Modify: `healing/config.lua:543-569` (getAssignmentSummary)

**Step 1: Add nukeHeal to the spells table**

In `healing/config.lua`, find the `spells` table at line 194. Add `nukeHeal` after `promised`:

```lua
    spells = {
        fast = {},
        small = {},
        medium = {},
        large = {},
        group = {},
        hot = {},
        hotLight = {},
        groupHot = {},
        promised = {},
        nukeHeal = {},  -- Target's Target heals (cast on NPC, heals NPC's target)
    },
```

**Step 2: Detect Target's Target spells in categorizeHealSpell**

In `healing/config.lua`, find the `categorizeHealSpell` function at line 331. After the `isHealSpell` check (line 341), add TT detection BEFORE the existing category checks:

```lua
    if not isHealSpell then return nil end

    -- Check for Target's Target spells (e.g., Paladin Denouncement line)
    -- These have TargetType containing "Target's Target"
    if targetType:find("target's target") or targetType:find('targettarget') then
        return 'nukeHeal', getSpellLevel(spell)
    end

    local singleTarget = isSingleTarget(targetType)
```

This goes right after line 341, before line 343. The normalized `targetType` is already computed at line 336.

**Step 3: Add nukeHeal to auto-assignment spells init**

In `autoAssignFromSpellBar()` at line 393, add `nukeHeal` to the cleared spells table:

```lua
    M.spells = {
        fast = {},
        small = {},
        medium = {},
        large = {},
        group = {},
        hot = {},
        hotLight = {},
        groupHot = {},
        promised = {},
        nukeHeal = {},
    }
```

**Step 4: Handle nukeHeal in the auto-assignment loop**

In the gem scanning loop (around line 428), add a case for `nukeHeal` alongside `direct_single` and `hot_single`:

```lua
                if category == 'direct_single' then
                    table.insert(directHeals, { name = spellName, level = value or 0 })
                    assigned[spellName] = true
                elseif category == 'hot_single' then
                    table.insert(hotHeals, { name = spellName, manaCost = value or 0 })
                    assigned[spellName] = true
                elseif category == 'nukeHeal' then
                    -- Target's Target heals go directly to nukeHeal category
                    table.insert(M.spells.nukeHeal, spellName)
                    assigned[spellName] = 'nukeHeal'
                elseif category and M.spells[category] then
```

**Step 5: Add nukeHeal to assignment summary**

In `getAssignmentSummary()` at line 544, add to `categoryLabels`:

```lua
        nukeHeal = "Nuke+Heal (Target's Target)",
```

And add to `categoryOrder` after `'promised'`:

```lua
    local categoryOrder = { 'fast', 'small', 'medium', 'large', 'group', 'hot', 'hotLight', 'groupHot', 'promised', 'nukeHeal' }
```

**Step 6: Add nukeHeal to IsValidSpellForCategory**

In `IsValidSpellForCategory()` at line 252, add a case for `nukeHeal` before the `return true` at line 289:

```lua
    elseif category == 'nukeHeal' then
        -- Target's Target spells: targetType contains "target's target"
        return targetType:find("target's target") ~= nil or targetType:find('targettarget') ~= nil
    end
```

**Step 7: Commit**

```bash
git add healing/config.lua
git commit -m "feat(pal): add nukeHeal spell category for Target's Target spells"
```

---

## Task 4: Add Mode-Aware Target Filtering to Target Monitor

Add `getHealPolicy()` and mode-aware filtering to `target_monitor.lua`.

**Files:**
- Modify: `healing/target_monitor.lua` (add heal policy, modify getInjuredTargets)

**Step 1: Add heal policy function**

Add after `M.init()` (after line 105):

```lua
-- Heal policy based on HealMode setting
local _healPolicy = nil

function M.setHealPolicy(policy)
    _healPolicy = policy
end

function M.getHealPolicy()
    return _healPolicy
end

--- Build heal policy from settings
-- @param settings table Core.Settings
-- @return table policy { mode, selfHealPct, criticalPct, groupHealThreshold }
function M.buildHealPolicy(settings)
    local healMode = settings and settings.HealMode or 'off'
    local combatMode = settings and settings.CombatMode or 'off'

    -- Default: use HealMode setting directly
    -- If HealMode not explicitly set, infer from CombatMode
    if healMode == 'off' and settings.DoHeals == true then
        healMode = combatMode == 'tank' and 'tank' or 'full'
    end

    if healMode == 'tank' then
        return {
            mode = 'tank',
            selfHealPct = 70,        -- Heal self at 70%
            criticalPct = 40,        -- Heal others only below 40%
            groupHealThreshold = 2,  -- Group heal when 2+ at 40%
            groupHealPct = 40,       -- Group heal HP trigger
        }
    elseif healMode == 'full' then
        return {
            mode = 'full',
            selfHealPct = 80,        -- Normal heal threshold
            criticalPct = 80,        -- Normal heal threshold for all
            groupHealThreshold = 2,  -- Group heal when 2+ at 75%
            groupHealPct = 75,       -- Group heal HP trigger
        }
    else
        return { mode = 'off' }
    end
end
```

**Step 2: Add filtered target getter**

Add after `getInjuredTargets()` (after line 387):

```lua
--- Get injured targets filtered by heal policy
-- @param maxPctHP number Maximum HP% to include
-- @param policy table|nil Heal policy (from buildHealPolicy). If nil, no filtering.
-- @return table Array of eligible injured targets
function M.getFilteredTargets(maxPctHP, policy)
    if not policy or policy.mode == 'off' then
        return {}
    end
    if policy.mode == 'full' then
        return M.getInjuredTargets(maxPctHP or policy.criticalPct)
    end

    -- Tank mode: restricted targeting
    local myId = mq.TLO.Me.ID()
    local eligible = {}
    for _, target in pairs(_targets) do
        if target.deficit > 0 then
            if target.id == myId then
                -- Self: use higher threshold
                if target.pctHP < (policy.selfHealPct or 70) then
                    table.insert(eligible, target)
                end
            else
                -- Others: only if critically low
                if target.pctHP < (policy.criticalPct or 40) then
                    table.insert(eligible, target)
                end
            end
        end
    end

    -- Sort by priority then HP%
    table.sort(eligible, function(a, b)
        local pa, pb = M.getPriority(a), M.getPriority(b)
        if pa ~= pb then return pa < pb end
        return a.pctHP < b.pctHP
    end)
    return eligible
end
```

**Step 3: Commit**

```bash
git add healing/target_monitor.lua
git commit -m "feat(pal): add mode-aware target filtering to target monitor"
```

---

## Task 5: Add nukeHeal Scoring to Heal Selector

Add Target's Target spell support to the heal selector, including NPC search and castTargetId.

**Files:**
- Modify: `healing/heal_selector.lua` (add nukeHeal scoring, NPC lookup)

**Step 1: Read heal_selector.lua SelectHeal function**

Read the full `SelectHeal` function to understand where to add nukeHeal candidates. The function is the main entry point that returns `{ spell, expected, details }`. We need to add nukeHeal as an additional candidate alongside direct heals.

**Step 2: Add NPC target lookup helper**

Add near the top of `heal_selector.lua`, after the module variables (around line 50):

```lua
--- Find an NPC on XTarget whose current target matches the heal recipient
-- @param healTargetId number Spawn ID of the person who needs healing
-- @return number|nil NPC spawn ID to cast on, or nil if none found
local function findNpcTargeting(healTargetId)
    if not healTargetId or healTargetId <= 0 then return nil end
    local me = mq.TLO.Me
    if not me or not me() then return nil end
    local xtCount = tonumber(me.XTarget()) or 0
    for i = 1, xtCount do
        local xt = me.XTarget(i)
        if xt and xt.ID() and xt.ID() > 0 then
            local npcTarget = xt.TargetOfTarget
            if npcTarget and npcTarget() then
                local npcTargetId = tonumber(npcTarget.ID()) or 0
                if npcTargetId == healTargetId then
                    return xt.ID()
                end
            end
        end
    end
    return nil
end
```

**Step 3: Add nukeHeal evaluation function**

Add after the NPC lookup helper:

```lua
--- Evaluate nukeHeal (Target's Target) spells for a target
-- @param targetInfo table Target data from target_monitor
-- @param situation table Combat situation from buildHealingContext
-- @return table|nil { spell, expected, details, castTargetId, isNukeHeal } or nil
local function evaluateNukeHeal(targetInfo, situation)
    if not Config or not Config.spells or not Config.spells.nukeHeal then return nil end
    local nukeHeals = Config.spells.nukeHeal
    if #nukeHeals == 0 then return nil end

    -- Find an NPC targeting the heal recipient
    local castTargetId = findNpcTargeting(targetInfo.id)

    -- Check current target as fallback (tank mode: already targeting an NPC)
    if not castTargetId then
        local currentTarget = mq.TLO.Target
        if currentTarget and currentTarget() and currentTarget.Type() == 'NPC' then
            local tt = currentTarget.TargetOfTarget
            if tt and tt() and tonumber(tt.ID()) == targetInfo.id then
                castTargetId = currentTarget.ID()
            end
        end
    end

    -- If no NPC is targeting the heal recipient, nukeHeal via NPC path unavailable
    -- Could still cast on the PC directly, but that's handled by normal heal categories
    if not castTargetId then return nil end

    -- Score the first available nukeHeal spell
    for _, spellName in ipairs(nukeHeals) do
        local spell = mq.TLO.Spell(spellName)
        if spell and spell() then
            local me = mq.TLO.Me
            if me and me() and me.Gem(spellName)() and me.SpellReady(spellName)() then
                local expected = 0
                if HealTracker and HealTracker.getExpected then
                    expected = HealTracker.getExpected(spellName)
                end
                if expected <= 0 then
                    -- Estimate from spell data
                    local calcVal = spell.Calc and spell.Calc(1) and tonumber(spell.Calc(1)()) or 0
                    expected = math.abs(calcVal)
                end
                return {
                    spell = spellName,
                    expected = expected,
                    details = string.format('nukeHeal via NPC %d -> heals %s', castTargetId, targetInfo.name or '?'),
                    castTargetId = castTargetId,
                    isNukeHeal = true,
                }
            end
        end
    end
    return nil
end
```

**Step 4: Integrate nukeHeal into SelectHeal**

Find the `SelectHeal` function (it calls `FindEfficientHeal` and returns the best option). After the main heal selection but before returning, add nukeHeal as a competing candidate:

In the `SelectHeal` function, after the direct heal is selected but before returning, add:

```lua
    -- Check nukeHeal (Target's Target) as competing candidate
    local nukeResult = evaluateNukeHeal(targetInfo, situation)
    if nukeResult then
        -- If no direct heal found, use nukeHeal
        if not bestHeal then
            return nukeResult, 'nukeHeal_only_option'
        end
        -- If direct heal found, prefer nukeHeal for efficiency (heals + damages in one GCD)
        -- Give nukeHeal a small bonus since it also does damage
        if nukeResult.expected >= (bestHeal.expected or 0) * 0.7 then
            return nukeResult, 'nukeHeal_preferred'
        end
    end
```

The exact insertion point depends on SelectHeal's structure — it needs to go after `bestHeal` is determined but before the `return bestHeal, reason` statement. Read the full SelectHeal function to find the right spot.

**Step 5: Commit**

```bash
git add healing/heal_selector.lua
git commit -m "feat(pal): add nukeHeal scoring and NPC target lookup to heal selector"
```

---

## Task 6: Add Target's Target Cast Path to healing/init.lua

Handle the TT casting path in `executeHeal` and expose heal hints.

**Files:**
- Modify: `healing/init.lua` (executeHeal TT path, heal hints, buildHealAction nukeHeal)

**Step 1: Add heal hint state**

At the top of `healing/init.lua`, add after module variables (around line 46):

```lua
-- Heal hints for tank module cooperation
local _healHint = nil
local _healHintExpiry = 0
local HEAL_HINT_TTL = 3.0  -- seconds

function M.getHealHint()
    if _healHint and os.clock() < _healHintExpiry then
        return _healHint
    end
    _healHint = nil
    return nil
end

function M.clearHealHint()
    _healHint = nil
end
```

**Step 2: Modify executeHeal for TT spells**

In `executeHeal()` (starting at line 188), add TT-aware targeting before the SpellEngine.cast call.

Find the targeting section (around line 229-230 where `SpellEngine.cast` is called):

```lua
    if ok and SpellEngine and SpellEngine.cast then
        success = SpellEngine.cast(spellName, targetId, { spellCategory = 'heal' })
```

Replace with TT-aware version:

```lua
    if ok and SpellEngine and SpellEngine.cast then
        -- For nukeHeal (Target's Target) spells, target the NPC instead
        local castId = targetId
        if opts and opts.castTargetId then
            castId = opts.castTargetId
            debugLog('[ExecuteHeal] nukeHeal: casting %s on NPC %d to heal target %d', spellName, castId, targetId)
        end
        success = SpellEngine.cast(spellName, castId, { spellCategory = 'heal' })
```

The `executeHeal` function signature needs to accept opts. Change from:

```lua
local function executeHeal(spellName, targetId, tier, isHoT)
```

To:

```lua
local function executeHeal(spellName, targetId, tier, isHoT, opts)
```

**Step 3: Pass castTargetId through buildHealAction**

In `buildHealActionForTarget()` (line 381), add castTargetId to the action:

```lua
    return {
        spellName = spellName,
        targetId = targetInfo.id,
        targetName = targetInfo.name,
        tier = tier,
        isHoT = is_hot_spell(spellName),
        expected = heal.expected,
        details = heal.details,
        reason = reason,
        castTargetId = heal.castTargetId,  -- NPC ID for TT spells (nil for normal heals)
        isNukeHeal = heal.isNukeHeal,      -- Flag for TT tracking
    }
```

**Step 4: Set heal hints for unfulfilled TT opportunities**

In `buildHealAction()`, after the target selection logic, if a nukeHeal was identified but the PAL can't cast right now (wrong target, spell busy), set a hint:

```lua
    -- If nukeHeal was best but we couldn't cast, set hint for tank module
    if action and action.isNukeHeal and action.castTargetId then
        _healHint = {
            mobId = action.castTargetId,
            healTargetId = action.targetId,
            spellName = action.spellName,
            timestamp = os.clock(),
        }
        _healHintExpiry = os.clock() + HEAL_HINT_TTL
    end
```

**Step 5: Pass opts through to executeHeal call**

Find where `executeHeal` is called in the tick function. It currently passes 4 args:

```lua
executeHeal(action.spellName, action.targetId, action.tier, action.isHoT)
```

Change to pass opts with castTargetId:

```lua
executeHeal(action.spellName, action.targetId, action.tier, action.isHoT, {
    castTargetId = action.castTargetId,
    isNukeHeal = action.isNukeHeal,
})
```

**Step 6: Commit**

```bash
git add healing/init.lua
git commit -m "feat(pal): add TT cast path and heal hints to healing orchestrator"
```

---

## Task 7: Handle TT Target Type in Spell Engine

Add `"Single Friendly (or Target's Target)"` to the spell engine's target type handling.

**Files:**
- Modify: `utils/spell_engine.lua:42-47` (SELF_TARGET_TYPES)
- Modify: `utils/spell_engine.lua:176-205` (preCastChecks targeting logic)

**Step 1: Update preCastChecks for TT spells**

The spell engine currently checks `SELF_TARGET_TYPES` and requires a valid target for everything else. For TT spells, the target is an NPC (not the heal recipient), so the standard checks (not dead, in range, line of sight) apply to the NPC, which is correct.

The only change needed: `"Single Friendly (or Target's Target)"` spells should pass the existing targeting checks without special handling, because when we cast on the NPC, the NPC IS the target and standard validation works.

However, we should ensure the target type string doesn't cause issues. In `preCastChecks` at line 177-178:

```lua
    local targetType = spell.TargetType() or ''
    if not SELF_TARGET_TYPES[targetType] then
```

This checks if targetType is in SELF_TARGET_TYPES. Since `"Single Friendly (or Target's Target)"` is NOT in SELF_TARGET_TYPES, it will proceed to the target validation block, which is correct — we need a target (the NPC).

**No code changes needed in spell_engine.lua** — the existing logic handles TT spells correctly because:
1. We pass `castTargetId` (the NPC) as the targetId to `SpellEngine.cast()`
2. The NPC is a valid target (not dead, in range, LOS)
3. The spell engine targets the NPC and casts
4. EQ's spell system handles the "heals NPC's target" mechanic

**Step 2: Verify and commit (no-op commit if no changes needed)**

If testing reveals issues with the target type string, add handling here. For now, skip this task.

---

## Task 8: Create Target's Target Heal Tracker

Create `healing/tt_tracker.lua` for tracking TT heal effectiveness.

**Files:**
- Create: `healing/tt_tracker.lua`

**Step 1: Create the tt_tracker module**

Create `healing/tt_tracker.lua`:

```lua
-- healing/tt_tracker.lua
-- Tracks Target's Target (nukeHeal) spell cast attempts, outcomes, and effectiveness.
local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

-- Rolling window (seconds)
local WINDOW_SEC = 300  -- 5 minutes

-- Per-attempt record
-- { timestamp, spellName, castTargetName, castTargetId, healTargetName, healTargetId,
--   targetingPath ('npc'|'pc'), outcome ('landed'|'fizzle'|'resist'|'interrupt'|'pending'),
--   healAmount, hintDriven }
local _attempts = {}

-- Aggregate stats (recomputed on demand)
local _statsCache = nil
local _statsCacheAt = 0
local STATS_TTL = 1.0  -- recompute at most once per second

--- Record a TT heal attempt (call before cast)
-- @param info table { spellName, castTargetId, castTargetName, healTargetId, healTargetName, targetingPath, hintDriven }
-- @return number attemptIndex for later result recording
function M.recordAttempt(info)
    info = info or {}
    local entry = {
        timestamp = os.clock(),
        spellName = info.spellName or '',
        castTargetName = info.castTargetName or '',
        castTargetId = info.castTargetId or 0,
        healTargetName = info.healTargetName or '',
        healTargetId = info.healTargetId or 0,
        targetingPath = info.targetingPath or 'npc',
        outcome = 'pending',
        healAmount = 0,
        hintDriven = info.hintDriven == true,
    }
    table.insert(_attempts, entry)
    _statsCache = nil  -- Invalidate cache
    return #_attempts
end

--- Record the result of a TT heal attempt
-- @param index number Attempt index from recordAttempt
-- @param outcome string 'landed'|'fizzle'|'resist'|'interrupt'
-- @param healAmount number|nil Actual heal amount if landed
function M.recordResult(index, outcome, healAmount)
    local entry = _attempts[index]
    if not entry then return end
    entry.outcome = outcome or 'unknown'
    entry.healAmount = healAmount or 0
    _statsCache = nil  -- Invalidate cache
end

--- Prune old attempts outside the rolling window
local function prune()
    local cutoff = os.clock() - WINDOW_SEC
    local fresh = {}
    for _, a in ipairs(_attempts) do
        if a.timestamp >= cutoff then
            table.insert(fresh, a)
        end
    end
    _attempts = fresh
end

--- Get aggregate stats for the rolling window
-- @return table { attempted, landed, successRate, npcPathCount, pcPathCount,
--                 npcPathPct, totalHealed, hintsUsed, recentCasts }
function M.getStats()
    local now = os.clock()
    if _statsCache and (now - _statsCacheAt) < STATS_TTL then
        return _statsCache
    end

    prune()

    local attempted = #_attempts
    local landed = 0
    local npcPath = 0
    local pcPath = 0
    local totalHealed = 0
    local hintsUsed = 0

    for _, a in ipairs(_attempts) do
        if a.outcome == 'landed' then
            landed = landed + 1
            totalHealed = totalHealed + (a.healAmount or 0)
        end
        if a.targetingPath == 'npc' then
            npcPath = npcPath + 1
        else
            pcPath = pcPath + 1
        end
        if a.hintDriven then
            hintsUsed = hintsUsed + 1
        end
    end

    -- Last 5 casts for UI display
    local recentCasts = {}
    local start = math.max(1, #_attempts - 4)
    for i = start, #_attempts do
        local a = _attempts[i]
        table.insert(recentCasts, {
            spell = a.spellName,
            target = a.castTargetName,
            healTarget = a.healTargetName,
            outcome = a.outcome,
            path = a.targetingPath,
            amount = a.healAmount,
        })
    end

    _statsCache = {
        attempted = attempted,
        landed = landed,
        successRate = attempted > 0 and (landed / attempted * 100) or 0,
        npcPathCount = npcPath,
        pcPathCount = pcPath,
        npcPathPct = attempted > 0 and (npcPath / attempted * 100) or 0,
        totalHealed = totalHealed,
        hintsUsed = hintsUsed,
        recentCasts = recentCasts,
    }
    _statsCacheAt = now
    return _statsCache
end

--- Reset all tracking data
function M.reset()
    _attempts = {}
    _statsCache = nil
end

return M
```

**Step 2: Commit**

```bash
git add healing/tt_tracker.lua
git commit -m "feat(pal): create Target's Target heal tracker module"
```

---

## Task 9: Integrate TT Tracker into Healing Init

Wire up the TT tracker to record attempts and results in the healing orchestrator.

**Files:**
- Modify: `healing/init.lua` (lazy-load tt_tracker, record around executeHeal)

**Step 1: Add lazy-load for tt_tracker**

At the top of `healing/init.lua`, alongside other lazy-loads (around line 26):

```lua
local getTTTracker = lazy.once('sidekick-next.healing.tt_tracker')
```

**Step 2: Record TT attempts in executeHeal**

In `executeHeal()`, after determining this is a nukeHeal cast (where we log the TT path), add tracking:

```lua
        if opts and opts.castTargetId then
            castId = opts.castTargetId
            debugLog('[ExecuteHeal] nukeHeal: casting %s on NPC %d to heal target %d', spellName, castId, targetId)

            -- Track TT attempt
            local TTTracker = getTTTracker()
            if TTTracker then
                local npcSpawn = mq.TLO.Spawn(castId)
                opts._ttAttemptIndex = TTTracker.recordAttempt({
                    spellName = spellName,
                    castTargetId = castId,
                    castTargetName = npcSpawn and npcSpawn() and npcSpawn.CleanName() or '',
                    healTargetId = targetId,
                    healTargetName = targetName,
                    targetingPath = 'npc',
                    hintDriven = opts.hintDriven or false,
                })
            end
        end
```

**Step 3: Record TT results after cast**

After the `SpellEngine.cast` call and success check, add result recording:

```lua
    if success and opts and opts._ttAttemptIndex then
        -- Result will be updated when spell event fires (landed/fizzled/resisted)
        -- For now mark as pending; SpellEvents callback can update later
    elseif not success and opts and opts._ttAttemptIndex then
        local TTTracker = getTTTracker()
        if TTTracker then
            TTTracker.recordResult(opts._ttAttemptIndex, 'failed', 0)
        end
    end
```

**Step 4: Expose tt_tracker for UI**

Add a getter to healing/init.lua:

```lua
function M.getTTTracker()
    return getTTTracker()
end
```

**Step 5: Commit**

```bash
git add healing/init.lua
git commit -m "feat(pal): integrate TT tracker into healing orchestrator"
```

---

## Task 10: Add HealMode to Main Loop (skipLayers)

Pass `skipLayers = { heal = true }` to the rotation engine when HealMode is active.

**Files:**
- Modify: `SideKick.lua:1554-1559` (RotationEngine.tick call)

**Step 1: Build skipLayers based on HealMode**

Find the RotationEngine.tick call at line 1554. Currently:

```lua
        RotationEngine.tick({
            abilities = State.abilities,
            settings = Core.Settings,
            burnActive = Burn.active,
            priorityHealingActive = priorityHealingActive,
        })
```

Change to:

```lua
        -- When PAL HealMode is active, skip the heal layer (healing intelligence handles it)
        local skipLayers = nil
        local healMode = Core.Settings.HealMode
        if healMode and healMode ~= 'off' and Core.Settings.DoHeals == true then
            skipLayers = { heal = true }
        end

        RotationEngine.tick({
            abilities = State.abilities,
            settings = Core.Settings,
            burnActive = Burn.active,
            priorityHealingActive = priorityHealingActive,
            skipLayers = skipLayers,
        })
```

**Step 2: Verify rotation_engine supports skipLayers**

Check if `rotation_engine.lua` already has `skipLayers` support from the tank module plan. If it does, this just works. If not, add to the tick function's layer loop:

In `rotation_engine.lua`, find the `tick()` function (around line 544). In the layer processing loop, add:

```lua
    local skipLayers = opts.skipLayers or {}
    -- ... in the layer loop:
    for _, layerDef in ipairs(M.LAYERS) do
        if skipLayers[layerDef.name] then
            goto nextLayer
        end
        -- ... existing layer processing
        ::nextLayer::
    end
```

**Step 3: Commit**

```bash
git add SideKick.lua utils/rotation_engine.lua
git commit -m "feat(pal): skip heal layer in rotation engine when HealMode active"
```

---

## Task 11: Add HealMode Dropdown and TT Stats to Healing Tab UI

Add the HealMode dropdown and TT tracking stats to the settings UI.

**Files:**
- Modify: `ui/settings/tab_healing.lua`

**Step 1: Add HealMode dropdown after the main healing toggle**

In `tab_healing.lua`, after the healing toggle section (around line 119, after `doHeals = healVal`), add:

```lua
    -- HealMode dropdown (PAL only)
    if myClass == 'PAL' and doHeals then
        local healModes = { 'off', 'tank', 'full' }
        local healModeLabels = {
            off = 'Off (Rotation Only)',
            tank = 'Tank (Self + Emergency)',
            full = 'Full (Deficit-Based)',
        }
        local currentMode = settings.HealMode or 'tank'
        local currentIdx = 1
        for i, mode in ipairs(healModes) do
            if mode == currentMode then currentIdx = i break end
        end

        imgui.Spacing()
        imgui.Text('Heal Intelligence Mode:')
        imgui.SameLine()
        local labels = {}
        for _, mode in ipairs(healModes) do
            table.insert(labels, healModeLabels[mode])
        end
        local newIdx = imgui.Combo('##HealMode', currentIdx, labels, #labels)
        if newIdx ~= currentIdx then
            local newMode = healModes[newIdx]
            if onChange then onChange('HealMode', newMode) end
        end
    end
```

**Step 2: Add TT tracking stats section**

At the bottom of the function, before the closing `end`, add:

```lua
    -- ========== TARGET'S TARGET TRACKING (PAL only) ==========
    if myClass == 'PAL' and doHeals then
        local TTTracker = nil
        if _healingMod and _healingMod.getTTTracker then
            TTTracker = _healingMod.getTTTracker()
        end
        if TTTracker then
            imgui.Spacing()
            if imgui.CollapsingHeader("Target's Target Healing") then
                local stats = TTTracker.getStats()
                if stats.attempted > 0 then
                    imgui.Text(string.format('Attempted: %d  Landed: %d  (%.0f%%)',
                        stats.attempted, stats.landed, stats.successRate))
                    imgui.Text(string.format('NPC Path: %.0f%%  PC Fallback: %.0f%%',
                        stats.npcPathPct, 100 - stats.npcPathPct))
                    imgui.Text(string.format('Total Healed: %s  Hints Used: %d',
                        Helpers and Helpers.formatNumber and Helpers.formatNumber(stats.totalHealed) or tostring(stats.totalHealed),
                        stats.hintsUsed))

                    imgui.Spacing()
                    imgui.Text('Recent Casts:')
                    for _, cast in ipairs(stats.recentCasts or {}) do
                        local color = cast.outcome == 'landed' and { 0.3, 1, 0.3, 1 } or { 1, 0.5, 0.3, 1 }
                        imgui.TextColored(color[1], color[2], color[3], color[4],
                            string.format('  %s -> %s (%s, %s)',
                                cast.spell, cast.healTarget, cast.outcome, cast.path))
                    end
                else
                    imgui.TextDisabled('No TT heals recorded yet.')
                end
            end
        end
    end
```

**Step 3: Commit**

```bash
git add ui/settings/tab_healing.lua
git commit -m "feat(pal): add HealMode dropdown and TT tracking stats to healing UI"
```

---

## Task 12: Integration Verification

Verify all pieces connect correctly via code review.

**Files:**
- Read all modified files for consistency

**Step 1: Trace the PAL healing flow end-to-end**

Verify this path works:

1. `SideKick.lua:getHealingModule()` — returns new healing module for PAL (not legacy)
2. `healing/init.lua:isHealerClass()` — returns true for PAL
3. `healing/config.lua:autoAssignFromSpellBar()` — Preservation → fast, Aurora → group, HealNuke → nukeHeal
4. `healing/target_monitor.lua` — filters targets based on HealMode policy
5. `healing/heal_selector.lua` — scores nukeHeal alongside direct heals, returns castTargetId
6. `healing/init.lua:executeHeal()` — passes castTargetId to SpellEngine for NPC targeting
7. `healing/tt_tracker.lua` — records attempt and result
8. `SideKick.lua` — passes `skipLayers = { heal = true }` to prevent rotation double-cast
9. `ui/settings/tab_healing.lua` — HealMode dropdown + TT stats visible for PAL

**Step 2: Grep for dead references**

```bash
cd F:/lua/sidekick-next
grep -rn "classShort == 'PAL'" --include="*.lua" | grep -v class_configs
grep -rn "Exclude PAL" --include="*.lua"
grep -rn "nukeHeal" --include="*.lua"
```

Verify:
- No remaining PAL exclusions outside class_configs
- nukeHeal referenced consistently across config, selector, tracker, UI

**Step 3: Verify HealMode setting flows through**

```bash
grep -rn "HealMode" --include="*.lua"
```

Ensure HealMode is:
- Defined in PAL.lua Settings
- Read in target_monitor.lua buildHealPolicy
- Read in SideKick.lua for skipLayers
- Displayed in tab_healing.lua UI

**Step 4: Final commit (if any fixes needed)**

```bash
git add -A
git commit -m "fix(pal): integration fixes for paladin healing intelligence"
```

---

## Execution Order Summary

| Task | Description | Dependencies | Effort |
|------|-------------|-------------|--------|
| 1 | Open healing gate to PAL | None | 10 min |
| 2 | Add HealMode setting to PAL config | None | 5 min |
| 3 | Add nukeHeal category to config | None | 15 min |
| 4 | Mode-aware target filtering | Task 2 | 15 min |
| 5 | nukeHeal scoring in heal selector | Task 3 | 20 min |
| 6 | TT cast path + heal hints in init | Tasks 3, 5 | 20 min |
| 7 | Spell engine TT handling | None (likely no-op) | 5 min |
| 8 | Create TT tracker | None | 10 min |
| 9 | Integrate TT tracker into init | Tasks 6, 8 | 10 min |
| 10 | skipLayers in main loop | Task 2 | 10 min |
| 11 | HealMode UI + TT stats | Tasks 2, 8, 9 | 15 min |
| 12 | Integration verification | All | 15 min |

**Parallelizable groups:**
- Tasks 1, 2, 3, 7, 8 can run in parallel (no dependencies)
- Tasks 4, 5 depend on 2, 3 respectively
- Tasks 6, 9 depend on earlier tasks
- Tasks 10, 11 depend on settings/tracker
- Task 12 is the final verification pass
