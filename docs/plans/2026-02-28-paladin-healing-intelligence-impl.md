# Paladin Healing Intelligence Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Extend the deficit-based healing intelligence system to support PAL as a tank/off-healer, replacing zero automated healing with intelligent deficit-based spell selection.

**Architecture:** Minimal gate changes to existing `healing/` subsystem. Add PAL to class checks, add `selfHeal` spell category, add class profile defaults. No structural changes to healing intelligence core.

**Reference:** See `docs/plans/2026-02-28-paladin-healing-intelligence-design.md` for full design.

---

## Phase 1: Gate Changes (Enable PAL in Healing System)

### Task 1: Add PAL to isHealerClass() in healing/init.lua

**File:** `healing/init.lua`

**Change:** Line 99, extend the class check:

```lua
-- Before:
return classShort == 'CLR'  -- Only CLR for now

-- After:
return classShort == 'CLR' or classShort == 'PAL'
```

### Task 2: Add PAL to getHealingModule() in SideKick.lua

**File:** `SideKick.lua`

**Change:** Line 40, extend the class check:

```lua
-- Before:
if classShort:upper() ~= 'CLR' then return LegacyHealing end

-- After:
local upper = classShort:upper()
if upper ~= 'CLR' and upper ~= 'PAL' then return LegacyHealing end
```

### Task 3: Enable Healing Monitor tab for PAL in SideKick.lua

**File:** `SideKick.lua`

**Change:** Line 1355, extend the CLR-only check for the Monitor sub-tab fallback:

```lua
-- Before:
elseif State.classShort == 'CLR' then

-- After:
elseif State.classShort == 'CLR' or State.classShort == 'PAL' then
```

### Task 4: Remove PAL exclusion from legacy healing

**File:** `automation/healing.lua`

**Changes:**
1. Line 88-89: Remove PAL exclusion from `get_profile()`:
```lua
-- Remove these lines:
if classShort == 'PAL' then return nil end
```

2. Lines 279-282: Remove early return for PAL in `M.tick()`:
```lua
-- Remove these lines:
if classShort == 'PAL' then
    _state.priorityActive = false
    return false
end
```

**Rationale:** PAL now uses NewHealing so LegacyHealing won't be called for PAL, but removing the explicit exclusion prevents confusion if someone changes getHealingModule later.

---

## Phase 2: Self-Heal Category

### Task 5: Add selfHeal category to config.lua spell table

**File:** `healing/config.lua`

**Change:** Add `selfHeal` to the spells table (around line 194-204):

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
    selfHeal = {},  -- Self-only heals (PAL SelfHeal line)
},
```

Also add new config keys after the pet healing section:

```lua
-- Self-healing (PAL off-tank use case)
selfHealEnabled = false,     -- Whether to include selfHeal spells
selfHealPct = 60,            -- HP% threshold for self-heal consideration
```

### Task 6: Add self-target detection to auto-assignment in config.lua

**File:** `healing/config.lua`

**Change 1:** Add `isSelfTarget` helper near the other target type helpers (around line 230):

```lua
local function isSelfTarget(targetType)
    return targetType == 'self'
end
```

**Change 2:** In `categorizeHealSpell()` (around line 370), add self-target detection BEFORE the single target direct heal check:

```lua
-- Self-target heals (PAL SelfHeal line)
if subcategory == 'heals' and isSelfTarget(targetType) then
    return 'selfHeal', getSpellLevel(spell)
end
```

**Change 3:** In `autoAssignFromSpellBar()` (around line 393), add `selfHeal` to the cleared spells table:

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
    selfHeal = {},  -- Added
}
```

**Change 4:** In the same function, handle `selfHeal` category from categorization. The `selfHeal` category flows through the same path as other simple categories (not `direct_single` or `hot_single`), so it will be handled by the existing `elseif category and M.spells[category]` branch. No additional code needed.

### Task 7: Add selfHeal validation to IsValidSpellForCategory in config.lua

**File:** `healing/config.lua`

**Change:** In `IsValidSpellForCategory()` (around line 252-290), add validation for the `selfHeal` category:

```lua
elseif category == 'selfHeal' then
    return (subcategory == 'heals' or subcategory == 'quick heal') and isSelfTarget(targetType)
```

### Task 8: Add selfHeal to FilterSpells scope

**File:** `healing/config.lua`

No explicit change needed — `FilterSpells()` iterates `M.spells` which now includes `selfHeal`. The validation in Task 7 handles correctness.

---

## Phase 3: Heal Selector Self-Heal Support

### Task 9: Include selfHeal category in FindFastestHeal

**File:** `healing/heal_selector.lua`

**Change:** In `FindFastestHeal()` (around line 996-1033), accept an optional `isSelf` parameter and include selfHeal when targeting self:

```lua
function M.FindFastestHeal(deficit, isSelf)
    local config = Config or { spells = {} }
    config.spells = config.spells or {}
    local tracker = HealTracker
    local candidates = {}
    local categories = { 'fast', 'small', 'medium', 'large' }
    if isSelf and config.selfHealEnabled then
        table.insert(categories, 'selfHeal')
    end
    -- ... rest unchanged
```

### Task 10: Include selfHeal category in FindEfficientHeal

**File:** `healing/heal_selector.lua`

**Change:** In `FindEfficientHeal()` (around line 1076), check if target is self and include selfHeal:

```lua
function M.FindEfficientHeal(targetInfo, allowFast, situation)
    local config = Config or { spells = {} }
    config.spells = config.spells or {}
    -- ...
    local allSpells = {}
    local categories = { 'small', 'medium', 'large' }
    if allowFast then
        table.insert(categories, 1, 'fast')
    end
    -- Include selfHeal when target is self
    local isSelf = targetInfo._isSelf
    if isSelf and config.selfHealEnabled then
        table.insert(categories, 'selfHeal')
    end
    -- ... rest unchanged
```

### Task 11: Include selfHeal in GetMinExpectedHeal

**File:** `healing/heal_selector.lua`

**Change:** In `GetMinExpectedHeal()` (around line 976), add selfHeal to categories if enabled:

```lua
local categories = { 'fast', 'small', 'medium', 'large' }
if config.selfHealEnabled then
    table.insert(categories, 'selfHeal')
end
```

### Task 12: Tag self-targets in healing/init.lua tick

**File:** `healing/init.lua`

**Change:** In `M.tick()`, when building `allTargets` (around line 949-966), tag self targets:

```lua
local myId = mq.TLO.Me.ID and mq.TLO.Me.ID() or 0
-- ... in the loop:
local entry = cloneTarget(t)
entry._isSelf = (entry.id == myId)
```

Also: when calling `FindFastestHeal` for emergency targets (around line 1020-1035), pass `isSelf`:

```lua
-- In the emergency loop:
local heal = HealSelector.FindFastestHeal(t, t._isSelf)
-- Note: FindFastestHeal takes (deficit, isSelf), not targetInfo.
-- Actually it takes deficit as first arg. Pass the deficit and isSelf flag:
local heal, reason = HealSelector.SelectHeal(t, situation)
-- SelectHeal calls FindFastestHeal internally for emergencies.
```

Wait — `SelectHeal` calls `FindFastestHeal(deficit)` internally. We need to thread the `_isSelf` flag through `SelectHeal` → `FindFastestHeal`. The simplest approach:

In `SelectHeal()`, extract `isSelf` from targetInfo and pass it to internal calls:

```lua
function M.SelectHeal(targetInfo, situation)
    -- ... existing code ...
    local isSelf = targetInfo._isSelf or false

    if targetInfo.pctHP < config.emergencyPct then
        local heal = M.FindFastestHeal(deficit, isSelf)
        -- ... rest unchanged
    end
    -- ... and later:
    local heal = M.FindEfficientHeal(targetInfo, false, situation)
    -- FindEfficientHeal already reads targetInfo._isSelf
```

---

## Phase 4: Class Profile Defaults

### Task 13: Add class profile defaults to config.lua

**File:** `healing/config.lua`

**Change:** Add a class defaults table and apply it during `M.load()`:

```lua
-- After the main M table definition, before load():
local CLASS_DEFAULTS = {
    PAL = {
        emergencyPct = 30,
        groupHealMinCount = 2,
        hotEnabled = false,
        selfHealEnabled = true,
        selfHealPct = 60,
        healPetsEnabled = false,
    },
}

-- In M.load(), after loading user config, apply class defaults for any keys
-- the user hasn't explicitly set:
function M.applyClassDefaults()
    local me = mq.TLO.Me
    if not me or not me() then return end
    local classShort = (me.Class and me.Class.ShortName and me.Class.ShortName() or ''):upper()
    local defaults = CLASS_DEFAULTS[classShort]
    if not defaults then return end
    for k, v in pairs(defaults) do
        -- Only apply if the key exists in M (don't add unknown keys)
        -- and only if the user hasn't saved a value for this key
        if M[k] ~= nil and M['_userSet_' .. k] == nil then
            M[k] = v
        end
    end
end
```

**Note:** The `_userSet_` tracking is optional complexity. Simpler approach: apply class defaults BEFORE loading user config, so user overrides always win:

```lua
function M.load()
    -- 1. Apply class defaults first (sets PAL-specific values)
    M.applyClassDefaults()
    -- 2. Then load user config (overrides class defaults)
    local path = getConfigPath()
    -- ... existing load logic ...
end
```

---

## Phase 5: Cleanup & Testing

### Task 14: Verify auto-assignment handles PAL spells

After all code changes, verify by reading the auto-assignment log output:
- Preservation should be categorized as `fast`
- HealNuke (Denouncement) should be categorized as `medium` (single target, "heals" subcategory)
- Aurora should be categorized as `group`
- SelfHeal should be categorized as `selfHeal`

If HealNuke has an unexpected subcategory (e.g., it might be a hybrid spell with a non-standard subcategory), we may need to add explicit spell line recognition. This is a runtime verification step.

### Task 15: Verify rotation engine interaction

Confirm that when `priorityHealingActive = true` for PAL:
- Emergency layer (LayOnHands, DivineCall) still runs
- Aggro layer (Wave) still runs
- Defenses layer (Fortitude, DefenseDisc) still runs
- Combat layer (Crush, Stun) is correctly SKIPPED
- Buff layer (HPBuff, Aura) still runs

This is verified by reading the rotation engine code — no changes needed there. The `priorityHealingActive` flag already skips only `combat` and `burn` layers.

---

## Summary of All File Changes

| File | Lines Changed | Change Description |
|---|---|---|
| `healing/init.lua` | ~99, ~949 | Add PAL to isHealerClass(), tag self targets |
| `healing/config.lua` | ~194-204, ~230, ~252, ~370, ~393, new section | Add selfHeal category, self-target detection, class defaults |
| `healing/heal_selector.lua` | ~690, ~976, ~1001, ~1076 | Include selfHeal in candidate lists when target is self |
| `SideKick.lua` | ~40, ~1355 | Add PAL to getHealingModule(), show monitor for PAL |
| `automation/healing.lua` | ~88-89, ~279-282 | Remove PAL exclusion |
