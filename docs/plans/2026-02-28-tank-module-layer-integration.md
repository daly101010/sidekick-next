# Tank Module Layer Integration

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rewire the tank module to consume ability layer assignments from the rotation engine instead of its own ad-hoc `UseForAggro` flag system, so abilities configured in the existing grids UI (mode/layer/condition) and spell sets drive tank behavior.

**Architecture:** The tank module currently duplicates ability execution that the rotation engine already handles. We remove the duplication by having the rotation engine skip the `aggro` layer when in tank mode, and the tank module takes ownership of aggro-layer abilities with its domain-specific logic (AoE/single split, mob count thresholds, mez safety checks). Emergency, defenses, combat, and burn layers continue through the rotation engine for all classes. Spells remain in the spell set system untouched.

**Tech Stack:** Lua, MacroQuest TLO, rotation_engine.lua layer system, action_executor.lua channels

---

## Background

### Current Architecture (the problem)

```
SideKick.lua main loop:
  ├── RotationEngine.tick()         ← processes ALL layers including aggro
  │     ├── emergency layer         ← fires emergency AAs/discs
  │     ├── heal layer
  │     ├── aggro layer             ← fires aggro AAs/discs (ON_CONDITION + conditions)
  │     ├── defenses layer
  │     ├── ...
  │     └── SpellRotation.tick()    ← fires combat spells from spell lineup
  │
  └── Tank.tick()                   ← ALSO fires aggro abilities via UseForAggro flag
        ├── tryAoEAggroAbility()    ← reads UseForAggro flag, bypasses mode/condition gates
        ├── trySingleAggroAbility() ← same
        └── taunt chase + positioning
```

**The duplicate execution problem:**
- Rotation engine fires aggro-layer abilities for tanks (line 200: `state.combatMode == 'tank'`)
- Tank module fires aggro abilities via `getAggroAbilities()` using `UseForAggro` flags (line 304)
- An ability with both `UseForAggro=true` AND `aggro` layer assignment fires from BOTH paths
- Tank module bypasses mode gates (ON_CONDITION/ON_DEMAND) — fires abilities regardless of user mode setting

### Target Architecture (the fix)

```
SideKick.lua main loop:
  ├── RotationEngine.tick()         ← processes all layers EXCEPT aggro when tank mode
  │     ├── emergency layer         ← unchanged
  │     ├── heal layer              ← unchanged
  │     ├── aggro layer             ← SKIPPED when combatMode == 'tank'
  │     ├── defenses layer          ← unchanged
  │     ├── ...
  │     └── SpellRotation.tick()    ← unchanged (spells from spell set)
  │
  └── Tank.tick()                   ← OWNS aggro layer with domain-specific logic
        ├── aggroSweep()            ← reads aggro-layer abilities from categorizeByLayer()
        │     ├── AoE split         ← detectAggroType() on layer abilities
        │     ├── mob threshold     ← unmezzedCount >= TankAoEThreshold
        │     ├── mez safety        ← CC.hasAnyMezzedOnXTarget()
        │     ├── aggro deficit     ← cache.aggroDeficitCount
        │     └── mode+condition    ← rotation engine gate checks (reused)
        ├── taunt chase             ← unchanged state machine
        └── positioning             ← unchanged
```

### Configuration Flow (no new UI)

| Ability Type | Configured In | How |
|---|---|---|
| Aggro AAs/Discs | Abilities grid | Set mode=ON_CONDITION, layer=aggro, add conditions |
| Defensive discs | Abilities grid | Set mode=ON_CONDITION, layer=emergency or defenses |
| Combat AAs/Discs | Abilities grid | Set mode=ON_CONDITION, layer=combat |
| Combat spells | Spell set | Conditions + priority per gem slot |
| Tank behavior | Tank settings | TankMode, AutoTaunt, AoEThreshold, Positioning |

---

## Tasks

### Task 1: Add `skipLayers` support to rotation engine

The rotation engine needs a way to skip specific layers so the tank module can own the aggro layer.

**Files:**
- Modify: `utils/rotation_engine.lua` (lines 544-619, `tick()` function)

**Step 1: Add `skipLayers` option to `tick()`**

In `utils/rotation_engine.lua`, the `tick()` function receives an `opts` table. Add support for `opts.skipLayers` — a table of layer names to skip.

Find the loop at line 612:
```lua
    -- Process each layer in priority order
    for _, layer in ipairs(M.LAYERS) do
        if M.shouldLayerRun(layer, state) then
            local layerAbilities = byLayer[layer.name] or {}
            if #layerAbilities > 0 then
                M.runLayer(layer, layerAbilities, settings, state, ctx, classConfig)
            end
        end
    end
```

Replace with:
```lua
    -- Process each layer in priority order
    local skipLayers = opts.skipLayers or {}
    for _, layer in ipairs(M.LAYERS) do
        if skipLayers[layer.name] then
            if M.debugLogging and TL then
                TL.log('layer_ext_skip_' .. layer.name, 10, 'Layer %s SKIP: owned by external module', layer.name)
            end
        elseif M.shouldLayerRun(layer, state) then
            local layerAbilities = byLayer[layer.name] or {}
            if #layerAbilities > 0 then
                M.runLayer(layer, layerAbilities, settings, state, ctx, classConfig)
            end
        end
    end
```

**Step 2: Expose `categorizeByLayer` with gate checks for external consumers**

Add a new function that external modules (tank.lua) can call to get layer-categorized abilities with mode/condition gates pre-evaluated:

```lua
--- Get abilities for a specific layer that pass all gates
-- For use by external modules (e.g., tank) that own specific layers
-- @param layerName string Layer name (e.g., 'aggro')
-- @param opts table Options: abilities, settings
-- @return table Array of abilities that pass enabled + mode + condition gates
function M.getLayerAbilities(layerName, opts)
    opts = opts or {}
    local abilities = opts.abilities or {}
    local settings = opts.settings or {}
    local Abilities = getAbilities()
    if not Abilities then return {} end

    -- Get character class for config lookup
    local Cache = getCache()
    local myClass = (Cache and Cache.me and Cache.me.class) or ''
    if myClass == '' and mq.TLO.Me and mq.TLO.Me.Class and mq.TLO.Me.Class.ShortName then
        myClass = tostring(mq.TLO.Me.Class.ShortName() or ''):upper()
    end
    local classConfig = getClassConfig(myClass)

    -- Categorize all abilities by layer
    local byLayer = M.categorizeByLayer(abilities, settings, classConfig)
    local layerAbilities = byLayer[layerName] or {}
    if #layerAbilities == 0 then return {} end

    -- Build state and context for gate checks
    local state = {
        burnActive = opts.burnActive,
        combatMode = settings.CombatMode or 'off',
        myClass = myClass,
        emergencyHpThreshold = settings.EmergencyHpThreshold or 35,
    }
    local ctx = nil
    local ConditionContext = getConditionContext()
    if ConditionContext then
        ctx = ConditionContext.build()
    end

    -- Filter by all gates (enabled, master toggle, mode, condition)
    local passing = {}
    local sorted = Abilities.sortByPriority(layerAbilities)
    for _, def in ipairs(sorted) do
        if M.checkMasterToggle(def, settings) then
            local enabled = def.settingKey and settings[def.settingKey] == true
            if enabled and M.checkModeGate(def, settings, state, ctx, classConfig) then
                table.insert(passing, def)
            end
        end
    end

    return passing
end
```

**Step 3: Verify no tests break**

This project doesn't have a formal test suite. Verify by re-reading the modified file to check for scope errors, missing variables, and that the existing `tick()` behavior is unchanged when `skipLayers` is not provided.

**Step 4: Commit**

```bash
git add utils/rotation_engine.lua
git commit -m "feat(rotation): add skipLayers support and getLayerAbilities for external module consumption"
```

---

### Task 2: Pass `skipLayers` from main loop when tank mode active

**Files:**
- Modify: `SideKick.lua` (lines 1554-1559, rotation engine tick call)

**Step 1: Build skipLayers table based on combat mode**

Find the rotation engine tick call at line 1554:
```lua
        RotationEngine.tick({
            abilities = State.abilities,
            settings = Core.Settings,
            burnActive = Burn.active,
            priorityHealingActive = priorityHealingActive,
        })
```

Replace with:
```lua
        -- When tank mode is active, tank module owns the aggro layer
        local skipLayers = nil
        if (Core.Settings.CombatMode or 'off') == 'tank' then
            skipLayers = { aggro = true }
        end
        RotationEngine.tick({
            abilities = State.abilities,
            settings = Core.Settings,
            burnActive = Burn.active,
            priorityHealingActive = priorityHealingActive,
            skipLayers = skipLayers,
        })
```

**Step 2: Verify by re-reading the modified lines**

Ensure the change is syntactically correct and the table structure is right.

**Step 3: Commit**

```bash
git add SideKick.lua
git commit -m "feat(main): skip aggro layer in rotation engine when tank mode active"
```

---

### Task 3: Rewrite tank aggro sweep to use layer system

This is the core change. Replace the ad-hoc `getAggroAbilities` + `UseForAggro` approach with rotation engine layer consumption.

**Files:**
- Modify: `automation/tank.lua` (lines 1-365, significant rewrite of aggro functions)

**Step 1: Add rotation engine import**

At the top of `automation/tank.lua`, add:
```lua
local RotationEngine = require('sidekick-next.utils.rotation_engine')
```

After the existing `local Executor = require(...)` line (line 9).

**Step 2: Replace `tryAoEAggroAbility` and `trySingleAggroAbility`**

Remove the existing functions (lines 303-325):
```lua
function M.tryAoEAggroAbility(abilities, settings)
    ...
end

function M.trySingleAggroAbility(abilities, settings)
    ...
end
```

Replace with a single `aggroSweep` function that reads from the layer system:

```lua
--- Execute aggro abilities from the rotation engine's aggro layer
-- Applies tank-specific domain logic: AoE/single split, mob thresholds, mez safety
-- @param abilities table All ability definitions (passed to rotation engine)
-- @param settings table Settings table
-- @return boolean True if any ability was executed
function M.aggroSweep(abilities, settings)
    -- Get all aggro-layer abilities that pass enabled + mode + condition gates
    local aggroAbilities = RotationEngine.getLayerAbilities('aggro', {
        abilities = abilities,
        settings = settings,
    })
    if #aggroAbilities == 0 then return false end

    -- Split into AoE and single-target
    local aoe, single = {}, {}
    for _, def in ipairs(aggroAbilities) do
        if Abilities.detectAggroType(def) == 'aoe' then
            table.insert(aoe, def)
        else
            table.insert(single, def)
        end
    end

    -- AoE aggro: check mob count threshold + safety
    local unmezzedCount = Cache.unmezzedHaterCount()
    if unmezzedCount >= (settings.TankAoEThreshold or 3) then
        local shouldAoE = true

        if settings.TankRequireAggroDeficit then
            shouldAoE = (Cache.xtarget.aggroDeficitCount or 0) > 0
        end

        if shouldAoE and settings.TankSafeAECheck then
            if CC.hasAnyMezzedOnXTarget() then
                shouldAoE = false
            end
        end

        if shouldAoE then
            for _, def in ipairs(aoe) do
                if Executor.executeAbility(def) then
                    return true
                end
            end
        end
    end

    -- Single-target aggro: check if aggro lead is low
    if Cache.aggroLeadLow() then
        for _, def in ipairs(single) do
            if Executor.executeAbility(def) then
                return true
            end
        end
    end

    return false
end
```

**Step 3: Update `handleAggro` to call `aggroSweep`**

Replace the existing `handleAggro` function (lines 165-207):

```lua
function M.handleAggro(myId, abilities, settings)
    -- Run aggro ability sweep (reads from rotation engine layer system)
    M.aggroSweep(abilities, settings)

    -- Reactive taunt: only check when taunt is ready and not already taunting
    if _state.current == STATE.IDLE then
        if Aggro.canTaunt() and Aggro.isTauntReady() then
            local looseMob = Aggro.findMobAttackingGroup(myId)
            if looseMob and looseMob() then
                local dist = looseMob.Distance() or 999
                if dist <= Aggro.TAUNT_CHASE_RANGE then
                    M.startReactiveTaunt(looseMob)
                    return
                end
            end
        end
    end
end
```

**Step 4: Remove `isAbilityReady` and `activateAbility` local functions**

Lines 51-86 contain `isAbilityReady()` and `activateAbility()` — these are no longer needed since the rotation engine's gate checks and the action executor handle ready checks and cooldowns.

Remove:
```lua
-- Check if an ability is ready to use
local function isAbilityReady(def)
    ...
end

-- Safe ability activation with cooldown check
local function activateAbility(def)
    ...
end
```

Also remove the `_state.lastAbilityUse` field (line 39) and the `ABILITY_COOLDOWN` constant (line 43) since these are superseded by the action executor's channel lockouts.

**Step 5: Verify the full file**

Re-read the entire modified `automation/tank.lua` to check:
- No references to removed functions (`isAbilityReady`, `activateAbility`, `tryAoEAggroAbility`, `trySingleAggroAbility`)
- No references to removed state fields (`_state.lastAbilityUse`)
- `RotationEngine` import is present
- `aggroSweep` correctly references `Abilities`, `Cache`, `CC`, `Executor` (all existing imports)

**Step 6: Commit**

```bash
git add automation/tank.lua
git commit -m "feat(tank): replace UseForAggro flag with rotation engine layer consumption

Tank module now reads aggro-layer abilities from the rotation engine's
categorizeByLayer system instead of its own UseForAggro flag. Abilities
are configured in the existing grids UI with mode/layer/condition.
AoE/single split, mob threshold, and mez safety checks preserved."
```

---

### Task 4: Remove `UseForAggro` flag from ability definitions and settings

Now that tank.lua reads from the layer system, the `UseForAggro` flag is dead code. Clean it up.

**Files:**
- Modify: `utils/abilities.lua` (remove `getAggroAbilities` function, lines 156-174)
- Modify: `utils/rotation_engine.lua` (remove `UseForAggro` fallback, lines 150-154)
- Search: grep for `UseForAggro` across entire codebase to find all references

**Step 1: Search for all `UseForAggro` references**

```bash
grep -rn "UseForAggro" F:/lua/sidekick-next/ --include="*.lua"
```

**Step 2: Remove `getAggroAbilities` from `utils/abilities.lua`**

Remove the function (lines 156-174):
```lua
function M.getAggroAbilities(abilities, settings)
    ...
end
```

**Step 3: Remove `UseForAggro` fallback from rotation engine**

In `utils/rotation_engine.lua`, `getAbilityLayer()` at lines 150-154:
```lua
    -- Check if marked for aggro use (tank abilities)
    local aggroKey = def.settingKey and (def.settingKey .. 'UseForAggro')
    if aggroKey and settings and settings[aggroKey] == true then
        return 'aggro'
    end
```

Remove this block. Abilities should be assigned to the aggro layer via:
1. Explicit `Layer` setting in grids UI (primary)
2. `category` tag on ability definition
3. `Category` in class config Settings metadata

**Step 4: Remove any `UseForAggro` settings from class configs**

Check each class config file (`data/class_configs/WAR.lua`, `PAL.lua`, `SHD.lua`) for `UseForAggro` references and remove them. Also check `data/classes/*.lua` generated ability files.

**Step 5: Ensure aggro abilities have proper layer assignment**

After removing `UseForAggro`, verify that abilities that WERE flagged `UseForAggro=true` now have a proper layer assignment path. Check:
- Class config `categoryOverrides` maps them to 'aggro'
- OR ability definition has `category = 'aggro'`
- OR class config `Settings[key].Category = 'Aggro'`

If any aggro abilities would fall through to the default 'combat' layer, add `categoryOverrides` entries in the class configs.

**Step 6: Commit**

```bash
git add utils/abilities.lua utils/rotation_engine.lua data/class_configs/WAR.lua data/class_configs/PAL.lua data/class_configs/SHD.lua
git commit -m "refactor: remove UseForAggro flag, abilities use layer assignment instead

UseForAggro is replaced by the standard layer assignment system.
Aggro abilities are now assigned via category tags, categoryOverrides,
or explicit layer setting in the grids UI."
```

---

### Task 5: Verify class configs assign aggro abilities to aggro layer

Ensure WAR/PAL/SHD abilities that were previously `UseForAggro` have proper `categoryOverrides` pointing to `'aggro'`.

**Files:**
- Read: `data/class_configs/WAR.lua` — check `categoryOverrides`
- Read: `data/class_configs/PAL.lua` — check `categoryOverrides`
- Read: `data/class_configs/SHD.lua` — check `categoryOverrides`
- Modify if needed: add missing `categoryOverrides` entries

**Step 1: Read WAR class config**

Look for abilities that are clearly aggro-related (AE taunt abilities, bellow, hate discs). Check if `categoryOverrides` maps them to `'aggro'`.

Common WAR aggro abilities:
- Area Taunt (AE taunt AA)
- Bellow/Roar (AE hate)
- Phantom Aggressor (aggro AA)
- Hate's Attraction (pull ability)

**Step 2: Read PAL class config**

PAL aggro abilities:
- Righteous Fury / Hate spells
- Stun spells (also aggro)
- AE aggro AAs

**Step 3: Read SHD class config**

SHD aggro abilities:
- Terror spells (aggro + damage)
- Hate taps
- AE aggro AAs

**Step 4: Add missing categoryOverrides**

For any aggro ability that doesn't have a path to the `'aggro'` layer, add an entry to `categoryOverrides` in the class config:

```lua
categoryOverrides = {
    -- ... existing overrides ...
    ['doAreaTaunt'] = 'aggro',
    ['doBellow'] = 'aggro',
    -- etc.
},
```

**Step 5: Commit**

```bash
git add data/class_configs/WAR.lua data/class_configs/PAL.lua data/class_configs/SHD.lua
git commit -m "fix(configs): ensure aggro abilities have categoryOverrides for aggro layer"
```

---

### Task 6: Integration verification

**Step 1: Trace the full execution path**

Re-read these files in order and trace the call chain:
1. `SideKick.lua` — rotation engine tick with `skipLayers = { aggro = true }` when tank
2. `utils/rotation_engine.lua` — `tick()` skips aggro layer, `getLayerAbilities('aggro', ...)` returns gate-checked abilities
3. `automation/tank.lua` — `aggroSweep()` calls `getLayerAbilities`, splits AoE/single, applies domain checks, executes
4. `utils/action_executor.lua` — `executeAbility()` routes to correct channel

Verify:
- No ability fires from both rotation engine AND tank module (the duplicate execution bug)
- Abilities set to ON_DEMAND mode are NOT auto-fired by tank module (mode gate respected)
- Abilities set to ON_CONDITION with a failing condition are NOT fired (condition gate respected)
- AoE abilities only fire when mob count >= threshold AND mez safety passes
- Single-target abilities only fire when aggro lead is low

**Step 2: Check for any remaining `UseForAggro` references**

```bash
grep -rn "UseForAggro" F:/lua/sidekick-next/ --include="*.lua"
```

Should return zero results.

**Step 3: Check for any references to removed functions**

```bash
grep -rn "getAggroAbilities\|tryAoEAggroAbility\|trySingleAggroAbility\|isAbilityReady\|activateAbility" F:/lua/sidekick-next/ --include="*.lua"
```

Should return zero results (or only in comments/docs).

**Step 4: Final commit (if any cleanup needed)**

```bash
git add -A
git commit -m "chore: cleanup remaining UseForAggro references"
```

---

## Summary

| What | Before | After |
|------|--------|-------|
| Aggro ability selection | `UseForAggro` flag, no mode/condition gates | Layer assignment from grids UI, full gate checks |
| AoE/single split | Same | Same (preserved) |
| Mob threshold | Same | Same (preserved) |
| Mez safety | Same | Same (preserved) |
| Reactive taunt | Same | Same (preserved) |
| Positioning | Same | Same (preserved) |
| Duplicate execution | Yes (rotation engine + tank module both fire) | No (rotation engine skips aggro for tanks) |
| Combat spells | Spell set | Spell set (unchanged) |
| New UI needed | N/A | None |

## Risk Assessment

- **Low risk**: rotation engine `skipLayers` is additive (no behavior change when not provided)
- **Medium risk**: removing `UseForAggro` fallback could cause abilities to land in wrong layer if `categoryOverrides` are incomplete — Task 5 mitigates this
- **Low risk**: tank module `aggroSweep` reuses existing utilities (`Abilities.detectAggroType`, `Cache`, `CC`, `Executor`)
