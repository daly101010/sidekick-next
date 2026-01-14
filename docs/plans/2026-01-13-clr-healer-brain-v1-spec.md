# CLR Healer Brain v1 — Spec (Live + TLP)

This document is a **fresh-start** specification for building a “healer brain” (CLR-first) automation system.
It does **not** assume any existing SideKick architecture, but it is written in Lua/MacroQuest terms for practicality.

## Goals (v1)

- CLR-only, **Live + TLP** compatible (spell availability varies; config must degrade gracefully).
- “Healer brain” prioritizes **triage/patch/DPS tradeoffs** with **human-like target stability** and **cast interruption rules**.
- Single process owns all conflicting resources (targeting/casting/memming/movement).
- Debuggability: answer “why did it do that?” every tick.

Non-goals (v1):
- Full raid healing logic, cure sophistication, CC logic, buff system, editor UI.
- Multi-script parallelism (v1 is single process; cross-character coordination can come later).

---

## Core Architecture

### Single Tick Loop

Each tick:
1. Build `WorldState` snapshot (read-only).
2. Tick Behavior Tree: `status, decision = Root:tick(ctx)`.
3. Executor advances (or starts) the chosen action; returns `Running/Success/Fail`.
4. Persist to `Blackboard` (target lock, current action, last results).

Tick cadence target: 50–100ms, but must be safe if ticks slip.

### Status Values

All nodes and actions return:
- `SUCCESS`
- `FAILURE`
- `RUNNING`

---

## Data Model

### WorldState (read-only snapshot)

Lua table, rebuilt each tick:

```lua
WorldState = {
  now = os.clock(),
  zone = mq.TLO.Zone.ShortName() or '',

  me = {
    id = mq.TLO.Me.ID() or 0,
    name = mq.TLO.Me.CleanName() or '',
    class = mq.TLO.Me.Class.ShortName() or '',
    level = mq.TLO.Me.Level() or 1,
    hpPct = mq.TLO.Me.PctHPs() or 100,
    manaPct = mq.TLO.Me.PctMana() or 100,
    endPct = mq.TLO.Me.PctEndurance() or 100,
    inCombat = (tostring(mq.TLO.Me.CombatState() or ''):lower() == 'combat'),
    casting = mq.TLO.Me.Casting() == true,
    moving = mq.TLO.Me.Moving() == true,
    stunned = mq.TLO.Me.Stunned() == true,
    silenced = (mq.TLO.Me.Silenced and mq.TLO.Me.Silenced() == true) or false,
    mezzed = (mq.TLO.Me.Mezzed and mq.TLO.Me.Mezzed() == true) or false,
    numGems = mq.TLO.Me.NumGems() or 8,
  },

  group = {
    members = {
      -- array, includes self as member[1]
      -- values are stable primitives (avoid keeping raw MQ userdata)
      {
        id = 123,
        name = "Tankname",
        class = "WAR",
        hpPct = 72,
        distance = 32.1,
        los = true,
        inZone = true,
        dead = false,
      },
    },
    count = 6,
  },

  assist = {
    name = "<AssistName string>",
    id = 0,          -- best resolved
    exists = false,
  },

  pressure = {
    -- “good enough” proxy for incoming damage; refine later
    xTargets = mq.TLO.Me.XTarget() or 0,
  },
}
```

#### Assist/Tank Resolution Rule (v1)

Tank is “whoever main assist is set to”.

Resolution order:
1. `AssistName` config string → `mq.TLO.Spawn(("pc =%s"):format(AssistName))`
2. `mq.TLO.Group.MainAssist.ID()` (if available)
3. fallback: self

Store into:
```lua
WorldState.assist = { name, id, exists }
```

### Blackboard (persistent)

Lua table stored in memory and saved optionally:

```lua
Blackboard = {
  heal = {
    lockedTargetId = 0,
    lockUntil = 0,                -- os.clock timestamp
    lastHpPct = {},               -- [memberId] = last hp%
    lastHealAt = {},              -- [memberId] = os.clock
  },

  action = {
    current = nil,                -- CurrentAction or nil
    lastResultByKey = {},         -- [actionKey] = { at, result, reason }
  },

  debug = {
    lastDecision = nil,           -- filled each tick
  },
}
```

### ActionSpec (static)

Defines a heal-capability without hardcoding exact spell names:

```lua
ActionSpec = {
  key = "fast_heal",                 -- unique
  type = "spell" | "aa" | "item",
  lines = { "RemedyHeal", "HealingLight" }, -- for spells: prioritized alternatives
  aaName = "Divine Arbitration",     -- for aa
  itemName = "Some Clicky",          -- for item
  target = "single" | "self" | "group",
  minManaPct = 0,
  gcdSensitive = true,               -- future
  castBudget = {                     -- used for interrupt policy
    isLong = false,
    minCommitSec = 0.4,
  },
}
```

### ResolvedAction (per tick)

Produced by resolver:

```lua
ResolvedAction = {
  key = "fast_heal",
  type = "spell",
  name = "Guileless Remedy",         -- concrete spell/aa/item
  targetId = 123,
  expectedCastMs = 1200,             -- optional
  canInterrupt = true|false,         -- policy output
  debug = { nodePath="Root>Emergency>FastHeal", score=123.4 },
}
```

---

## Spell/AA/Item Resolution (Live + TLP safe)

### SpellLine Resolution

Given a line name like `RemedyHeal`:
- Look it up in CLR’s `spellLines` table (newest → oldest).
- Return the **first spell** present in spellbook:
  - `mq.TLO.Me.Book(spellName)() == true`
- If line is missing or none in book → nil (tree falls back to other lines).

### “Heal Kit” for CLR v1

Define a single configuration object:

```lua
ClrHealKit = {
  fastSingle = { key="fast_single", type="spell", lines={"RemedyHeal", "HealingLight"}, target="single" },
  bigSingle  = { key="big_single",  type="spell", lines={"Renewal", "HealingLight"},    target="single", castBudget={isLong=true, minCommitSec=1.0} },
  groupHeal  = { key="group_heal",  type="spell", lines={"GroupFastHeal", "GroupHealCure"}, target="group" },
  complete   = { key="complete",    type="spell", lines={"CompleteHeal"}, target="single", castBudget={isLong=true, minCommitSec=2.0} },
  -- v1 optional:
  healNuke   = { key="heal_nuke",   type="spell", lines={"HealNuke", "NukeHeal"}, target="enemy" },
}
```

TLP support comes from the fact that missing lines just resolve nil.

---

## Triage (Target Selection)

### Candidate Filter

Exclude members who are:
- dead
- not in zone (if detectable)
- out of range (optional v1), or LoS false (optional v1)

### Score Function (v1)

For each candidate:

```
deficit = 100 - hpPct
tankBonus = (id == assistId) ? TankWeight : 0
spikeBonus = max(0, (lastHpPct[id] - hpPct)) * SpikeWeight
distancePenalty = distance > MaxHealRange ? VeryLargePenalty : distance * DistanceWeight
score = deficit * DeficitWeight + tankBonus + spikeBonus - distancePenalty
```

Defaults:
- `TankWeight`: 25–60 (tunable)
- `DeficitWeight`: 1.0
- `SpikeWeight`: 2.0 (tunable)
- `MaxHealRange`: 200 (spell range varies; refine later)

### Target Lock (anti-thrash)

If `Blackboard.heal.lockedTargetId` is set and `now < lockUntil`:
- keep current target **unless** a new candidate exceeds current by `LockBreakDelta`.

Example:
- `LockDurationSec = 0.8`
- `LockBreakDelta = 30`

---

## Behavior Tree (CLR v1)

### Node Types Needed (minimum)

- `Selector(children...)`
- `Sequence(children...)`
- `Condition(fn)` returns SUCCESS/FAILURE
- `Action(fn)` returns RUNNING/SUCCESS/FAILURE
- `Throttle(seconds, child)` (optional but recommended for expensive checks)

### Root Shape (v1)

`Root = Selector( Emergency, StabilizeTank, GroupHeal, EfficiencySingle, OptionalDps, Idle )`

#### Emergency

Sequence:
1. Condition: any member `hpPct <= EmergencyPct` (defaults 30)
2. Action: choose target by triage (but tank gets extra bias)
3. Action: cast best available “fast” heal on that target
   - `fastSingle` first, else `bigSingle`, else `complete`

#### StabilizeTank

Sequence:
1. Condition: tank exists AND tank hp <= TankStabilizePct (defaults 75)
2. Condition: pressure high (e.g. xtarget >= 2) OR tank spike detected
3. Action: cast `fastSingle` on tank (or fallback)

#### GroupHeal

Sequence:
1. Condition: `count(hpPct <= GroupHealPct) >= GroupHealCount` (defaults 3 @ 70%)
2. Action: cast `groupHeal`

#### EfficiencySingle

Sequence:
1. Condition: any member hpPct <= HealPct (defaults 85)
2. Action: triage pick
3. Action: if deficit large → `bigSingle` else `fastSingle`

#### OptionalDps (disabled by default)

Sequence:
1. Condition: `EnableDpsWhenStable == true`
2. Condition: no one below HealPct
3. Condition: manaPct >= DpsMinManaPct (defaults 50)
4. Action: cast `healNuke` (if resolved)

#### Idle

Action:
- return SUCCESS (do nothing)

---

## Executor + Interrupt Policy

### Locks (v1)

Hard locks:
- `cast`: only one cast/mem pipeline at a time
- `target`: only one owner per tick; target changes must be deliberate
- `mem`: reserved for later (buff swapping)

### Preemption (interrupt) Policy (v1)

If an action is currently RUNNING (casting):
- Prefer to continue unless:
  - target invalid (dead/out of range/LoS lost)
  - new emergency target appears and time-to-finish is “too long”

Heuristic:
```
remaining = estimatedRemainingCastSec()
if newAction.isEmergency and remaining > InterruptIfRemainingGreaterThanSec then interrupt
else continue
```

Defaults:
- `InterruptIfRemainingGreaterThanSec = 1.0`

### Action Keying (for logging + backoff)

Use stable keys like:
- `spell:Guileless Remedy@targetId`
- `spell:Group Heal@self`

Store last result in `Blackboard.action.lastResultByKey` for retry throttling.

---

## Configuration (minimal v1)

```lua
Config = {
  AssistName = "MainTankName",

  EmergencyPct = 30,
  HealPct = 85,
  TankStabilizePct = 75,

  GroupHealPct = 70,
  GroupHealCount = 3,

  TankWeight = 45,
  LockDurationSec = 0.8,
  LockBreakDelta = 30,

  EnableDpsWhenStable = false,
  DpsMinManaPct = 50,
}
```

---

## Debug/Observability (required)

Every tick, record `Blackboard.debug.lastDecision`:

```lua
Blackboard.debug.lastDecision = {
  at = WorldState.now,
  chosenNode = "Emergency>FastHeal",
  chosenTargetId = 123,
  chosenTargetName = "Tankname",
  targetScore = 142.3,
  action = { key="fast_single", name="Guileless Remedy", type="spell" },
  currentAction = Blackboard.action.current and { ... } or nil,
  reasons = {
    emergency = "tank hp=28",
    groupHeal = "skipped count=1",
  },
}
```

Add a single toggle to emit `/echo` lines at a throttled rate (e.g., 1/sec).

---

## Development Milestones (implementation order)

1. Implement `WorldState` snapshot + group iteration.
2. Implement `Blackboard` + triage score + target lock.
3. Implement spell line resolver + CLR heal kit.
4. Implement executor for `castSpell(name, targetId)` with RUNNING status.
5. Implement the BT root + nodes.
6. Add interrupt policy.
7. Add debug pane (or `/echo`).

---

## Acceptance Checks (v1)

- Picks MA as “tank” and prioritizes them when injured.
- Does not thrash targets every tick (lock works).
- Casts the best available spell from spell lines (Live/TLP safe).
- Interrupts only when a new emergency truly requires it.
- Debug output clearly explains which node fired and why.

