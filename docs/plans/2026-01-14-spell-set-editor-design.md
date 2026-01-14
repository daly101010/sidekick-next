# Spell Set Editor Design

Supplementary design for user-facing spell set configuration. Complements the runtime behavior defined in `2026-01-13-multiscript-coordinator-fsm-spec.md`.

## Overview

Users create named Spell Sets that define:
1. Which spell lines to enable (from `sk_spells_clr.lua`)
2. Slot type for each line (`rotation` vs `buff_swap`)
3. Conditions that gate when each line can be used
4. Priority ordering within each section

The system auto-resolves the highest level spell from each enabled line and manages memorization.

## Data Model

### Spell Set Structure

```lua
SpellSet = {
  name = "Raid Healing",

  -- Rotation lines: memorized in gems 1..(NumGems-1), count against limit
  rotationLines = {
    { line = "Remedy", enabled = true, condition = nil, resolved = "Graceful Remedy", priority = 1 },
    { line = "Renewal", enabled = true, condition = {...}, resolved = "Sincere Renewal", priority = 2 },
    { line = "Intervention", enabled = true, condition = {...}, resolved = "Divine Intervention", priority = 3 },
    { line = "Yaulp", enabled = true, condition = nil, resolved = "Yaulp IX", priority = 4 },
  },

  -- Buff swap lines: use reserved gem OOC, don't count against limit
  buffSwapLines = {
    { line = "Symbol", enabled = true, condition = nil, resolved = "Symbol of Dannal", priority = 1 },
    { line = "Shining", enabled = true, condition = {...}, resolved = "Shining Bulwark", priority = 2 },
    { line = "Aura", enabled = true, condition = nil, resolved = "Aura of Divinity", priority = 3 },
  },

  -- Computed at load
  rotationCount = 7,
  maxRotationSlots = 12, -- NumGems - 1
}
```

### Slot Types

| slotType | Gem Usage | Counts Against Limit | When Cast |
|----------|-----------|---------------------|-----------|
| `rotation` | Gems 1..(NumGems-1), always memorized | Yes | Anytime (combat or OOC) |
| `buff_swap` | Reserved gem (NumGems), memorized on demand | No | OOC only |

Rule:
- Need it in combat? -> `slotType = rotation`
- Can wait for OOC? -> `slotType = buff_swap`

### Classification Logic

When user first enables a spell line, suggest a default `slotType` based on the category in `sk_spells_clr.lua`:

```lua
local DEFAULT_SLOT_TYPES = {
  -- Always rotation (combat essential)
  Heals = 'rotation',
  GroupHeals = 'rotation',
  HoT = 'rotation',
  DirectHeals = 'rotation',
  Reactive = 'rotation',
  Damage = 'rotation',
  Stuns = 'rotation',
  Debuffs = 'rotation',
  Cures = 'rotation',
  AEDamage = 'rotation',

  -- Default to buff_swap (OOC is acceptable)
  Buffs = 'buff_swap',
  Auras = 'buff_swap',
  SelfBuffs = 'buff_swap',
  Wards = 'buff_swap',
  GroupBuffs = 'buff_swap',
  Procs = 'buff_swap',
  Persistent = 'buff_swap',
}
```

Once set, `slotType` is persisted in INI and never re-derived. User can override at any time.

## Storage (INI)

Example:

```ini
[SideKick-SpellSet-RaidHealing]
; Rotation lines
line_Remedy_enabled=1
line_Remedy_slotType=rotation
line_Remedy_condition=
line_Remedy_priority=1

line_Renewal_enabled=1
line_Renewal_slotType=rotation
line_Renewal_condition=subject:target,prop:hp,op:below,val:50
line_Renewal_priority=2

line_Intervention_enabled=1
line_Intervention_slotType=rotation
line_Intervention_condition=subject:target,prop:hp,op:below,val:30
line_Intervention_priority=3

; Buff swap lines
line_Symbol_enabled=1
line_Symbol_slotType=buff_swap
line_Symbol_condition=subject:target,prop:class,op:is,val:WAR|PAL|SHD
line_Symbol_priority=1

line_Aura_enabled=1
line_Aura_slotType=buff_swap
line_Aura_condition=
line_Aura_priority=2
```

## UI Layout

### Main Editor

```
┌─────────────────────────────────────────────────────┐
│ Spell Set: [Raid Healing ▼]    [New] [Delete] [Apply]│
├─────────────────────────────────────────────────────┤
│ Rotation Spells (7/12 slots)            [+ Add Line] │
│ ≡ ☑ Remedy        → Graceful Remedy      [Condition]  │
│ ≡ ☑ Renewal       → Sincere Renewal      [Condition]  │
│ ≡ ☑ Intervention  → Divine Intervention  [Condition]  │
│ ≡ ☑ Word          → Word of Vivification [Condition]  │
│ ≡ ☑ Yaulp         → Yaulp IX             [Condition]  │
│ ≡ ☑ Contravention → Undying Contravention[Condition]  │
│ ≡ ☑ Sound         → Sound of Divinity    [Condition]  │
├─────────────────────────────────────────────────────┤
│ Buff Swap Spells (OOC only)             [+ Add Line] │
│ ≡ ☑ Symbol        → Symbol of Dannal     [Condition]  │
│ ≡ ☑ Shining       → Shining Bulwark      [Condition]  │
│ ≡ ☑ Aura          → Aura of Divinity     [Condition]  │
├─────────────────────────────────────────────────────┤
│ Category Filter: [All ▼]                             │
└─────────────────────────────────────────────────────┘

≡ = drag handle for reordering (priority)
```

### UI Elements

| Element | Action |
|---------|--------|
| Spell Set dropdown | Select/switch between saved sets |
| [New] | Create new spell set (prompts for name) |
| [Delete] | Delete current set (with confirmation) |
| [Apply] | Queue memorization (waits for OOC if in combat) |
| Slot counter | Shows `7/12 slots` at a glance |
| Checkbox | Enable/disable the line |
| Line name | Category from `sk_spells_clr.lua` |
| Resolved spell | Actual spell that will be memorized |
| [Condition] | Opens condition builder popup |
| `≡` drag handle | Reorder priority within section |
| Right-click | Context menu: Move to Rotation / Move to Buff Swap |
| [+ Add Line] | Opens picker showing available lines |

### Condition Popup

```
┌─────────────────────────────────────────────────────┐
│ Condition for: Renewal → Sincere Renewal        [X] │
├─────────────────────────────────────────────────────┤
│ [My Target's ▼] [HP ▼] [is below ▼] [50    ]         │
│                                         [+ AND]      │
│                                                     │
│ Preview: "My Target's HP is below 50"               │
│                                                     │
│ [Clear] [Save]                                      │
└─────────────────────────────────────────────────────┘
```

### Move to Rotation at Capacity Modal

```
┌─────────────────────────────────────────────────────┐
│ Cannot Add to Rotation                              │
├─────────────────────────────────────────────────────┤
│ All rotation slots are in use.                      │
│                                                     │
│ To add "Symbol" to rotation, select one to swap:    │
│                                                     │
│ ○ Remedy        → Graceful Remedy                    │
│ ○ Renewal       → Sincere Renewal                    │
│ ○ Intervention  → Divine Intervention                │
│ ○ Word          → Word of Vivification               │
│ ...                                                 │
│                                                     │
│ [Cancel]  [Swap Selected to Buff Swap]              │
└─────────────────────────────────────────────────────┘
```

## Gem Slot Enforcement

### Capacity Calculation

```lua
local function getRotationCapacity()
  local numGems = mq.TLO.Me.NumGems() or 8
  return numGems - 1 -- Last gem reserved for buff swap
end
```

Periodic check (every 30-60 seconds) updates capacity in case of level-up granting a new gem slot.

### Hard Limit

Users cannot enable more rotation lines than available slots:

```lua
if enabledRotationCount >= rotationCapacity then
  -- Disable all "enable" checkboxes for currently-disabled rotation lines
  -- Show tooltip: "Disable another spell line to enable this one (0 slots available)"
end
```

- Enabled lines always have active checkbox (can always disable)
- At capacity, disabled lines show grayed checkbox with tooltip
- Moving `buff_swap` -> `rotation` at capacity shows the swap modal above

## Conditions

### Purpose

Conditions are cast-time gates. They determine whether a spell line can be used in a given situation. Ordering defines preference: first passing line wins.

### Default

All conditions default to `true` (always eligible).

### Evaluation (pure)

```lua
function ConditionBuilder.evaluate(condition, ctx)
  if not condition then return true end
  return evaluateNode(condition, ctx)
end

local ctx = {
  targetId = targetId,
  targetHp = getSpawnHp(targetId),
  targetClass = getSpawnClass(targetId),
  myHp = mq.TLO.Me.PctHPs(),
  myMana = mq.TLO.Me.PctMana(),
  groupCount = mq.TLO.Group.Members() or 0,
  inCombat = inCombat(),
}

if ConditionBuilder.evaluate(entry.condition, ctx) then
  -- condition passes, this line is eligible
end
```

## Memorization Behavior

### Multi-Script Integration (Coordinator executes memorization)

In the multi-script coordinator/claims architecture:
- `/memspell` is OOC-only.
- The Coordinator is the only script that executes `/memspell`.
- SpellsetManager computes the desired rotation loadout and queues work; Coordinator executes it when safe.
- Never run memorization from actor handlers (store state, process in main loop).

### Triggers

| Trigger | Action |
|---------|--------|
| Script launch | Check if memorized spells match config; queue fix if needed |
| [Apply] button | Queue memorization of all enabled rotation lines |
| Set change | Queue memorization of new set's rotation lines |
| Spell scribed | Re-resolve lines, queue memorization if changes detected |

### OOC-Only Rule

```lua
function SpellsetManager.applySet(setName)
  if inCombat() then
    pendingSetApply = setName
    return 'queued'
  end
  doApplySet(setName)
end

function SpellsetManager.tick()
  if pendingSetApply and not inCombat() and not castBusy() then
    doApplySet(pendingSetApply)
    pendingSetApply = nil
  end
end
```

### Memorization Verification

```lua
function waitForMemorization(spellName, gem, timeoutMs)
  timeoutMs = timeoutMs or 10000
  local start = mq.gettime()

  while (mq.gettime() - start) < timeoutMs do
    local current = mq.TLO.Me.Gem(gem).Name()
    if current == spellName then return true end
    mq.delay(100)
  end
  return false
end
```

## Buff Swap Behavior

### Reserved Gem

The last gem (`NumGems`) is reserved for buff swap. It is not part of the rotation capacity.

### Batch Application

When a buff swap spell is memorized, cast it on all eligible targets before moving to the next buff.

```lua
function buffSwapTick()
  if inCombat() then return end
  if isCasting() or isMemorizing() then return end

  for _, entry in ipairs(buffSwapLines) do
    if not entry.enabled then goto continue end

    local targets = {}
    for _, t in ipairs(getBuffTargets()) do
      local ctx = buildContext(t.id)
      if ConditionBuilder.evaluate(entry.condition, ctx) then
        if shouldCastBuffLikeRGMercs(entry.resolved, t.id) then
          table.insert(targets, t)
        end
      end
    end

    if #targets > 0 then
      memSpell(reservedGem, entry.resolved)
      waitForMemorization(entry.resolved, reservedGem)

      for _, t in ipairs(targets) do
        castOnTarget(entry.resolved, t.id)
        waitForCastComplete()
      end

      return -- one spell line per tick
    end

    ::continue::
  end

  restoreReservedGem()
end
```

### Restore Semantics

Restore happens once at the end of the buff cycle, not after each individual buff. The `previousSpell` is captured at the first swap and restored when no more buffs need casting.

## Buff Detection (match rgmercs behavior)

For buff swap decisions, use the same logic rgmercs uses: check presence by spell ID, check trigger spells, and check stacking rules.

rgmercs reference: `rgmercs/utils/casting.lua` (`LocalBuffCheck`, `TargetBuffCheck`, `GroupBuffCheck`).

At a high level, you want a helper that answers:
- `true` => we should cast the buff (missing, or will stack/refresh)
- `false` => do not cast (already present and does not stack/refresh)

Simplified pseudocode:

```lua
function shouldCastBuffLikeRGMercs(spellNameOrId, targetId)
  local spell = mq.TLO.Spell(spellNameOrId)
  if not spell or not spell() then return false end
  local spellId = spell.ID()

  -- Self: use Me.FindBuff("id X") and Stacks()
  if targetId == mq.TLO.Me.ID() then
    if mq.TLO.Me.FindBuff("id " .. spellId)() then return false end
    -- If not found, check triggers for presence/stacking
    for i = 1, spell.NumEffects() do
      local trig = spell.Trigger(i)
      if trig and trig() and trig.ID() > 0 then
        if mq.TLO.Me.FindBuff("id " .. trig.ID())() then return false end
        if trig.Stacks() then return true end
      else
        break
      end
    end
    return spell.Stacks()
  end

  -- Non-self: ensure Target is the entity so Target.FindBuff works
  -- (must respect target ownership claims in the runtime design)
  if mq.TLO.Target.ID() ~= targetId then
    mq.cmdf('/target id %d', targetId)
    mq.delay(50, function() return mq.TLO.Target.ID() == targetId end)
  end

  if mq.TLO.Target.FindBuff("id " .. spellId)() then return false end

  for i = 1, spell.NumEffects() do
    local trig = spell.Trigger(i)
    if trig and trig() and trig.ID() > 0 then
      if mq.TLO.Target.FindBuff("id " .. trig.ID())() then return false end
      if trig.StacksTarget() then return true end
    else
      break
    end
  end

  return spell.StacksTarget()
end
```

Notes:
- rgmercs also considers blocked buff lists (`Me.BlockedBuff`) and DanNet peers; add those if you need them.
- In the claims-based system, any `/target` calls required for buff checking must only happen while holding `targetOwner`.

## Integration with Modules

### Module Query Pattern

```lua
-- In sk_healing.lua
local function pickBestHealSpell(targetId)
  local spellSet = SpellsetManager.getActiveSet()
  if not spellSet then return nil end

  local ctx = buildContext(targetId)

  -- Iterate in priority order
  for _, entry in ipairs(spellSet.rotationLines) do
    if entry.enabled and isHealLine(entry.line) then
      if ConditionBuilder.evaluate(entry.condition, ctx) then
        if isSpellReady(entry.resolved) then
          return entry.resolved
        end
      end
    end
  end

  return nil
end
```

### Component Responsibilities

| Component | Responsibility |
|-----------|----------------|
| `sk_spells_clr.lua` | Spell line definitions (static data) |
| `SpellsetManager` | Storage, resolution, set switching, compute memorization plan |
| Spell Set UI | Create/edit sets, enable lines, set conditions |
| `sk_coordinator` | Arbitrates all actions including OOC memorization execution |
| `sk_healing` | Queries enabled heal lines + conditions at cast time |
| `sk_buffs` (future) | OOC buff cycle using `buff_swap` lines |
| `ConditionBuilder` | Pure evaluation of conditions with passed context |

## Files to Create/Modify

| File | Action | Purpose |
|------|--------|---------|
| `ui/spell_set_editor.lua` | Create | New UI for spell set management |
| `utils/spellset_manager.lua` | Modify | Add spell set storage, resolution, apply logic |
| `sk_spells_clr.lua` | Exists | Spell line source data |
| `ui/condition_builder.lua` | Modify | Ensure pure `evaluate(condition, ctx)` signature |
| `sk_healing.lua` | Modify | Query spell set for enabled heal lines |
| `sk_dps.lua` | Modify | Query spell set for enabled damage lines |
| `sk_buffs.lua` | Create (future) | OOC buff swap scheduler |

## Acceptance Criteria

1. User can create, name, and delete spell sets
2. User can enable/disable spell lines from `sk_spells_clr.lua`
3. User cannot enable more rotation lines than available gem slots
4. System auto-resolves highest level spell from each enabled line
5. User can set conditions on any line (rotation or buff_swap)
6. User can reorder lines to set priority
7. User can move lines between rotation and buff_swap sections
8. [Apply] queues memorization until OOC
9. Script startup verifies memorized spells match config
10. Buff swap batches all targets per spell before moving to next
11. Reserved gem is restored after buff cycle completes
