# SideKick Multi-Script Architecture - Design Spec v2 (Coordinator + Claims)

Cleric automation using multiple independent Lua scripts communicating via MQ2 Actors.

Modules execute `/target` and `/cast` directly only when holding a valid ownership claim.
The Coordinator arbitrates ownership, centralizes `/stopcast`, and broadcasts authoritative state.

Scope: CLR first (Live + TLP). "Tank" is whoever `Group.MainAssist` is set to.

## Why Claims Exist (even with one active tier)

Even if only one `activePriority` is "valid" at a time, distributed scripts still have race windows:
- A module can act on a stale broadcast (priority flipped, but it has not received the update yet).
- Two scripts can both pass "it's my turn" checks during the same tick and issue conflicting `/target` + `/cast`.
- Interrupt events are not reliable attribution: "spell name interrupted" does not tell you which script owned the cast, and names can overlap (spells vs items vs AAs, same spell name used by multiple lines, etc).

Claims give a single, monotonically-versioned truth for who may touch the cast bar/target right now.

## Priority Tiers

Lower number = higher priority.

| Priority | Module         | Interrupt Threshold | Description |
|----------|----------------|---------------------|-------------|
| 0        | Emergency      | 0.0s (immediate)    | Divine Arb, Sanctuary, etc. |
| 1        | Healing        | 0.5s                | Fast heals, group heals, HoTs |
| 2        | Resurrection   | 1.0s                | Class-priority rez |
| 3        | Debuff         | 1.0s                | Mark, Atone, Tarnish |
| 4        | DPS            | N/A (lowest)        | Nukes, meditation |
| 5        | Idle           | N/A                 | OOC med/stand behavior |

### Interrupt Threshold Semantics (make this explicit)

`Interrupt Threshold` is defined as: the maximum remaining cast time you are willing to *let finish* before preempting.

Coordinator behavior when a higher priority tier wants to preempt the current cast:
- Let `remainingSec = cast_time_remaining()`.
- Let `thresholdSec = InterruptThreshold[requestingPriority]`.
- If `remainingSec > thresholdSec`: interrupt now (`/stopcast`), reassign ownership, and proceed.
- If `remainingSec <= thresholdSec`: do not interrupt; let the cast complete, then the higher priority tier will claim next.

Special case: `Emergency` uses `0.0s`, which means it interrupts immediately whenever `remainingSec > 0` (no "wait 0.3s").

## Who Decides `activePriority` (Transitions)

The Coordinator is the only authority that sets `activePriority`.

Recommended v2 behavior:
- Coordinator recomputes `activePriority` every tick from its `worldState` snapshot.
- Modules do not "change priority"; they only act (or claim) when `activePriority` matches them.

Optional (useful to keep Coordinator generic and modules class-smart):
- Modules send lightweight "need" hints (Coordinator still validates and decides).

Example message: `sk:need` (Module -> Coordinator)

```lua
{
  module = "healing",
  priority = 1,
  needsAction = true,
  ttlMs = 250,
  reason = "tank hp=32",
}
```

Coordinator should treat stale `sk:need` as false and still apply global gates (e.g., if `castBusy` is true, or if the module is not loaded/heartbeating).

## State Broadcast Protocol

Coordinator broadcasts `sk:state` on two paths:

1) Fast path (responsiveness): broadcast immediately on `epoch` change (claims, releases, priority changes, stopcast).
2) Slow path (liveness + drift correction): periodic broadcast at a modest rate (suggest 200ms).

Coordinator can still tick internally at 50ms (for world evaluation), but it does not need to broadcast every tick.

```lua
{
  tickId = 12345,           -- monotonic, increments each broadcast
  epoch = 42,               -- increments on (priority change) OR (ownership change) OR (stopcast)
  sentAtMs = mq.gettime(),  -- sender time
  ttlMs = 750,              -- receivers must ignore state older than this (>= 3x periodic interval)

  activePriority = 1,       -- current highest priority needing action

  castOwner = nil | {
    module = "healing",
    claimId = "heal_001",
    priority = 1,
    epoch = 42,             -- must equal top-level epoch
    claimedAtMs = 1234567,
    ttlMs = 1000,
    -- optional attribution/context for validation/debug
    action = {
      kind = "cast_spell" | "use_aa" | "use_item",
      name = "Guileless Remedy",
      targetId = 123,
      idempotencyKey = "heal:tank:fast",
    },
  },

  targetOwner = nil | {
    module = "healing",
    claimId = "target_001",
    priority = 1,
    epoch = 42,
    claimedAtMs = 1234567,
    ttlMs = 2000,
    targetId = 123,         -- optional: what the owner intends to target
  },

  castBusy = false,         -- derived (Me.Casting() or casting window open)
  memBusy = false,          -- true while /memspell operations are in progress (OOC only)

  worldState = {
    inCombat = true,
    myHpPct = 85,
    myManaPct = 60,
    groupNeedsHealing = true,
    emergencyActive = false,
    deadCount = 0,
    mainAssistId = 123,
    -- ... other shared state as needed
  },
}
```

### Suggested Rates (v2 defaults)

- Coordinator evaluation tick: 50ms
- `sk:state` periodic broadcast: 200ms (plus immediate-on-epoch-change)
- Module heartbeat `sk:hb`: 500ms (module -> coordinator)
- `sk:need` hints (if used): 100-250ms (module -> coordinator)

### Coalescing / Debounce

If multiple changes happen in quick succession (e.g., claim accepted then immediate stopcast), Coordinator should coalesce
into a single broadcast when possible (e.g., "broadcast at most once per 20ms"), while still guaranteeing "immediate"
visibility for emergency.

## Claim Protocol

### Default: Atomic Action Claim (Target + Cast together)

By default, modules should claim an "action" (target + cast) atomically. This removes two-phase latency and avoids
half-owned states (holding target but not cast, or vice versa).

### Memorization Policy (OOC-only)

To avoid downtime during combat, `/memspell` is only allowed out of combat:
- If `worldState.inCombat == true`: do not memorize (even if config changed). Queue a pending reconciliation.
- If `worldState.inCombat == false`: memorization is allowed only when `castBusy == false` (and ideally not moving).

This keeps combat behavior stable: combat uses whatever is already memorized in rotation gems; OOC is where we repair and
refresh the gem loadout and perform buff-swap casting.

Coordinator ownership:
- The Coordinator is the only script that executes `/memspell`.
- Modules never call `/memspell` (even OOC). They may only request/queue changes via data (SpellsetManager config) and/or
  send a non-conflicting message (e.g., "apply requested").

State visibility:
- Coordinator should publish `memBusy` (true while any memorization is in progress) so modules avoid claiming/casting
  during mem operations.

### Message: `sk:claim` (Module -> Coordinator)

```lua
{
  type = "action",
  wants = { "target", "cast" }, -- optional extension: include "mem" for OOC-only memorization actions
  module = "healing",
  priority = 1,
  claimId = "heal_001",      -- unique per request
  epochSeen = 42,            -- last epoch the module observed
  ttlMs = 1000,
  reason = "fast_heal_on_tank",
  -- optional attribution/context so Coordinator can validate/interrupt intelligently
  action = {
    kind = "cast_spell",
    name = "Guileless Remedy",
    targetId = 123,
    idempotencyKey = "heal:tank:fast",
  },
}
```

### Coordinator Grant Rules (minimal but safe)

Coordinator accepts a claim only if all:
1) `claim.epochSeen == coordinator.epoch` (reject stale claims)
2) `claim.priority == state.activePriority` OR `claim.priority == 0` (emergency override)
3) Ownership is grantable for the requested resources:
   - for `type="action"`: both `castOwner` and `targetOwner` must be grantable; otherwise reject
   - for `type="cast"` or `type="target"`: that single resource must be grantable (see "Fallback" below)

On accept:
1) Set `castOwner` and `targetOwner` to the new claim data (same `claimId` / same `epoch`)
2) Increment `epoch` exactly once
3) Broadcast updated `sk:state` immediately

On reject:
- No change; module will see unchanged state and either wait or retry

### Revocation on `activePriority` Change (core)

When `activePriority` changes, Coordinator must immediately revoke any ownership that no longer matches policy, instead of
waiting for TTL expiry. Otherwise you can block the next tier for up to the previous TTL.

Required behavior:
- If `activePriority` changes and `castBusy == false`: clear `castOwner` and `targetOwner` immediately.
- If `activePriority` changes and `castBusy == true`: keep `castOwner` only for attribution/interrupt decisions, but
  clear `targetOwner` immediately.

Coordinator should coalesce this with the `activePriority` change into a single `epoch` increment + broadcast.

### Expiry (deadlock prevention)

Coordinator clears owners when TTL expires:
- if `(nowMs - owner.claimedAtMs) > owner.ttlMs` -> clear owner + increment epoch + broadcast

### Module Execution Rules

Module may execute `/target` or `/cast` only when all are true:
1) `state` is fresh: `(nowMs - state.sentAtMs) <= state.ttlMs`
2) `state.targetOwner` matches the module + claim (`module`, `claimId`, `epoch`)
3) `state.castOwner` matches the module + claim (`module`, `claimId`, `epoch`)

If any condition becomes false, the module immediately stops issuing commands and returns to waiting.

### Fallback: Single-Resource Claims (optional, advanced)

If you find a real need to claim only one resource (e.g., pre-targeting while waiting for cast bar), you can allow:
- `type = "target"` (only affects `targetOwner`)
- `type = "cast"` (only affects `castOwner`)

If you support these, keep the same safety rules (`epochSeen`, TTL, fresh-state checks) and require modules to avoid
issuing `/cast` unless they hold `castOwner`, and avoid issuing `/target` unless they hold `targetOwner`.

## Spell Memorization and Reconciliation (rotation vs buff-swap)

### Rotation memorization (gems 1..NumGems-1)

Goal: enabled `slotType=rotation` lines are always memorized in gems `1..(NumGems-1)`.

When to reconcile:
- On script launch (after receiving the first fresh `sk:state`)
- On UI `[Apply]`
- On spellbook changes (scribe/unscribe), if detectable

Rules:
- If in combat: do not reconcile; mark `pendingMemFix=true` and defer until OOC.
- If out of combat and `castBusy == false`: reconcile immediately.

Recommended reconcile algorithm (minimize swaps):
- Compute expected ordered list of resolved spells from enabled rotation lines.
- Compare against current `Me.Gem(i).Name()` for `i=1..(NumGems-1)`.
- Keep any correct matches already present; only mem spells that are missing/misplaced.

### Buff-swap memorization (reserved hot-swap gem)

Goal: enabled `slotType=buff_swap` lines are never "kept memorized"; they are memorized on demand into the reserved gem
and restored after casting.

Rules:
- Only run out of combat.
- Batch per spell line: when you mem a buff-swap spell, cast it on every eligible target that needs it before moving on.
- "Needs it" detection should follow rgmercs-style buff checks (spell ID + triggers + stacking), not simple name matching.

Pseudo-flow:

```lua
-- OOC only
for _, entry in ipairs(buffSwapLines) do
  if entry.enabled and conditionPasses(entry, ctxFor("group")) then
    local targets = collectTargetsNeedingBuff(entry.resolved)
    if #targets > 0 then
      memIntoReservedGem(entry.resolved)      -- (NumGems)
      for _, t in ipairs(targets) do
        if not t.inCombat and t.inRange and t.inLineOfSight then
          targetAndCastReservedGem(t.id)      -- one at a time, respecting claims
        end
      end
      restoreReservedGem()
    end
  end
end
```

## Startup Ordering + Warm-up (avoid race conditions)
## Interrupt Protocol (Coordinator Centralized)

Only the Coordinator issues `/stopcast`.

### Message: `sk:interrupt` (Module -> Coordinator)

```lua
{
  requestingModule = "healing",
  requestingPriority = 1,
  reason = "emergency_heal_needed",

  -- Optional: used for lower-priority invalidation requests
  invalidation = nil | {
    idempotencyKey = "heal:tank:fast",
    reason = "target is now >= 95% hp",
  },
}
```

### Coordinator Interrupt Decision

If a cast is in-flight (by TLO), and `castOwner` is non-nil:

Higher priority interrupting lower:
- If `requestingPriority < castOwner.priority`, use the Interrupt Threshold semantics (see above).

Lower priority canceling invalid higher:
- If `requestingPriority > castOwner.priority`, only interrupt when Coordinator can validate invalidation using:
  - current world snapshot, and
  - `castOwner.action` context (e.g., targetId / idempotencyKey)

On interrupt:
- `/stopcast`
- clear `castOwner`
- increment epoch and broadcast immediately

## Implementation Notes (important)

1) Claims are the minimal "lease subset": `epoch + TTL + fresh-state check` is what removes the worst races.
2) If modules ever need to `/memspell`, treat it as another claimed resource (`memOwner`) or force it through Coordinator only.
3) To prevent target thrash, require a target claim for any module that issues `/target` (including DPS).
4) Prefer explicit "release" after completion:
   - module sends `sk:release { type="cast", claimId=... }` when cast ends (or on failure)
   - Coordinator clears owner early and increments epoch (reduces latency vs TTL waiting)

## Additional Recommendations (low complexity, high value)

### 0) Yielding Rules (must-follow for MQ2 Actors)

MQ2 Actor handlers run with yielding disabled. Do not call `mq.delay()` (or any yielding call) inside an actor callback.

Rule of thumb:
- Actor handler: store/update state, enqueue work, return immediately.
- Main loop: evaluate state, claim, and execute `/target` + `/cast` (and any `mq.delay`) from here.

Wrong (will error / misbehave):

```lua
actors.register('sk:state', function(message)
  if shouldHeal(message.content) then
    mq.delay(10) -- ERROR: cannot yield inside actor handler
    mq.cmd('/cast "Remedy"')
  end
end)
```

Right (queue and process in the main loop):

```lua
State.latest = nil

actors.register('sk:state', function(message)
  State.latest = message.content
end)

while true do
  if State.latest and shouldHeal(State.latest) then
    -- claim/target/cast here (outside the actor handler)
  end
  mq.delay(50)
end
```

### 1) Add `sk:release` (early unlock)

TTL is the safety net; `sk:release` is what makes the system feel responsive (especially for long casts like Complete Heal).

Module -> Coordinator:

```lua
{
  type = "cast" | "target",
  module = "healing",
  claimId = "heal_001",
  epochSeen = 42,
  reason = "cast_finished" | "cast_failed" | "no_longer_needed",
}
```

Coordinator should ignore releases for non-current owners.

### 2) Add `sk:result` (attribution + debugging)

When something fails in MQ (resists, fizzles, out of range, no LoS, gem not ready), you want one place to see:
- who owned the cast bar
- what action they thought they were doing
- whether MQ actually started casting

Coordinator -> Module (optional broadcast, or direct reply):

```lua
{
  claimId = "heal_001",
  epoch = 42,
  ok = true|false,
  reason = "started_cast" | "spell_not_ready" | "bad_target" | "stopcast" | "unknown",
}
```

### 3) Atomic "action claim" (avoid 2-phase deadlocks)

This is the default in v2 (see Claim Protocol). Keep `castOwner` and `targetOwner` in state, but treat them as a single
logical "action lease" by ensuring they are granted/revoked together for normal casting flows.

### 4) Revocation rule on priority change (prevent stale ownership)

This is core spec behavior (see "Revocation on `activePriority` Change").

### 5) Hysteresis / cooldown on `activePriority` (prevent thrash)

For healing, HP thresholds can oscillate around a boundary. Add one of:
- a minimum dwell time per tier (e.g., keep Healing active for 250ms once entered), or
- per-target heal cooldown (e.g., do not re-enter Healing unless someone is below X% for Y ms).

### 6) Target restore policy (quality of life)

Cleric healing usually requires retargeting a group member. Decide and standardize:
- whether modules restore previous target after a heal cast, and
- whether DPS uses MA's target and should re-acquire it after healing.

If you do restore, store `previousTargetId` in Coordinator state when granting a healing action claim.

### 7) Coordinator liveness rule (safety)

Every module should stop issuing commands if it has not received a fresh `sk:state` within `ttlMs`.
This prevents "headless" modules from continuing after Coordinator crashes or stops.

## Module Files

| File                   | Priority | Needs Cast Claim | Needs Target Claim |
|------------------------|----------|------------------|--------------------|
| `sk_coordinator.lua`   | N/A      | Arbiter          | Arbiter            |
| `sk_emergency.lua`     | 0        | Yes              | Yes                |
| `sk_healing.lua`       | 1        | Yes              | Yes                |
| `sk_resurrection.lua`  | 2        | Yes              | Yes                |
| `sk_debuff.lua`        | 3        | Yes              | Yes                |
| `sk_dps.lua`           | 4        | Yes              | Yes                |
| `sk_items.lua`         | N/A      | See "Items and Clickies" | See "Items and Clickies" |
| `sk_movement.lua`      | N/A      | No               | No                 |

## Items and Clickies (clarify scope)

Clickies can be "critical" and often consume the cast bar (or otherwise collide with spell casting).
To avoid hidden contention, treat item usage like any other action:

- Critical / combat-relevant clickies belong to the appropriate priority module:
  - Emergency: defensives, self-saves, instant heals, "oh no" items
  - Healing: heal clickies, focus effects that must be maintained
  - DPS: damage clickies
  These actions should be requested via `sk:claim` as `type="action"` with `action.kind="use_item"`.

- `sk_items.lua` (optional in v1) is for QoL and out-of-combat utilities that you explicitly agree do not compete:
  - Only run when Coordinator state is fresh
  - Only act when `activePriority == Idle` (or when explicitly allowed by Coordinator)
  - Must still obey `castBusy` and should avoid changing target unless it also claims

If you want `sk_items.lua` to fire combat clickies, then it must participate as a normal priority module with claims
(or you will reintroduce contention).

## Startup Sequence

```text
/lua run sk_coordinator
/lua run sk_emergency
/lua run sk_healing
/lua run sk_resurrection
/lua run sk_debuff
/lua run sk_dps
/lua run sk_items
/lua run sk_movement
```

### Startup Ordering + Warm-up (avoid race conditions)

Modules may start before the Coordinator. Required behavior:
- Modules must not claim or execute any commands until they have received at least one fresh `sk:state`.
- Modules should enter a short warm-up window after first state (suggest 500-1000ms) where they only observe and build
  their local caches (spell availability, AA readiness, etc), then begin claiming.
- If `sk:state` becomes stale (no fresh state within `ttlMs`), modules must immediately stop acting and return to wait.

Also required:
- If the script starts and the current memorized gems do not match the configured rotation loadout, record a pending
  reconciliation and apply it as soon as you are out of combat and `castBusy == false`.

## v1 Acceptance Criteria

- Only one cast attempt is in-flight at a time, and it is attributable to `castOwner.module + claimId + epoch`.
- Emergency can preempt healing immediately.
- No target thrash (or it is limited to the current `targetOwner`).
- Items never fire at the expense of emergency/healing casts.
- OOC idle meditation works; DPS meds between casts in combat.
