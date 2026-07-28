# sidekick-next

Standalone experimental copy of the `sidekick` script for visual redesign work (Approach C from the refactoring plan). Lives alongside the original — changes here do **not** affect the production `sidekick`.

Run with: `/lua run sidekick-next`

Parent: `F:\lua\CLAUDE.md` for shared mq/ImGui/actors patterns.

## Where to look

| For | Read |
|-----|------|
| User-facing behavior | `docs/USER_GUIDE.md` |
| How modules plug together | `docs/INTEGRATION_GUIDE.md` |
| In-flight redesign plans | `docs/plans/` |
| Removed legacy options (do not re-add) | `docs/removed-options.txt` |

## Conventions

- **Module require prefix:** `local BASE = 'sidekick-next.'` — modules under this tree are required as `sidekick-next.<path>`. Never mutate `BASE` from outside `init.lua`.
- Helper `_G.SK_NEXT_REQUIRE(path)` exists for one-line requires; modules can also use plain relative requires.
- **Feature flags** live in `_G.SIDEKICK_NEXT_CONFIG` (defaults in `config.lua`;
  `init.lua` applies UI-process overrides):
  - `USE_NEW_COLORS` — `ui/colors.lua` theme-aware colors.
  - `USE_NEW_COMPONENTS` — `ui/components/` reusable widgets.
  - `USE_NEW_SETTINGS` — `ui/settings/` modular tab system.
  - `VISUAL_REDESIGN` — placeholder for Approach C experiments.
  - `DEBUG_SETTINGS` — log ImGui setting interactions (dev-only).
- When adding a redesign experiment, gate it behind a new flag rather than replacing the existing path. The whole point of this tree is being able to A/B against the original.
- `CONSOLIDATED_WORKERS` defaults true for the ten-worker domain profile; set
  it false before startup to select the 18-worker legacy A/B profile.

## Coordination invariants (learned the hard way)

- **Actors addressing:** `{ mailbox = 'sidekick' }` with no `script` routes to
  `currentScript:sidekick` — it reaches the SAME script on other characters
  only, never sibling scripts. Peer producers call
  `ActorsCoordinator.publish()` and must declare their topic in
  `TOPIC_CONTRACTS`; the registry owns fleet versus same-script routing.
  Unknown topics fail closed. UI telemetry and manual actions use
  `worker:telemetry` and `worker:command`, not ad-hoc topic/address pairs.
- **The runtime cache is per-process.** Consolidated domain hosts tick once
  before their components. Standalone/legacy workers that consult cached data
  must still tick. Use `Cache.isReady()` or the readiness accessors: nil means
  uninitialized, while an empty ready snapshot means the scan found nothing.
- **CC priority order** (sk_cc, all at DEBUFF tier, preempts DPS casts via
  interrupt requests): charm break ladder (tash → AE stun → recharm; defers
  to mez while >CharmHoldUnmezzed mobs are loose) → charm acquisition
  (pretash → charm; pet FIRST on an incoming pull) → mez. Charm pet ID is
  broadcast fleet-wide (`cc:charmpet`); DPS/assist never attack it and the
  tank protects the enchanter with damageless Taunt only.
- **Spell resolution** (automation/cc): checks BOTH `spellLines` and
  `AbilitySets` vocabularies, memorized-gems-only, normalizes EQ backtick
  names (Boltran`s → Boltran's), and charm additionally falls back to a
  SPA-22 gem scan. Class-config spell lists must include classic/emu-era
  names, not just live-era.
- **Never gate on `AbilityReady`/interrupt while casting without care:**
  AbilityReady reads false during our own casts (tank taunt gates treat
  "unready only because casting" as usable), and an interrupt request from
  the current cast owner is treated as an owner self-cancel by the
  coordinator (guard with `self.currentRequestId` and `self:ownsLease()`).
- **Detrimental rotation casts** (discipline engine) require a live NPC
  current target unless the condition declares a `targetSelector`; the
  spellset executor excludes mez/charm SPAs entirely (CC owns those).
- **Orphan watchdog:** every worker + coordinator self-terminates ~10s after
  the parent UI script stops (`lib.isUiRunning()` poll) — a forced
  `/lua stop sidekick-next` takes the whole fleet down with it.

## Hard rules

- **Don't touch `F:\lua\sidekick`** (the production tree) from this branch. Cross-references should be read-only and ideally avoided.
- Removed options listed in `docs/removed-options.txt` are removed deliberately — don't reintroduce them without checking the doc.
- Keep `docs/INTEGRATION_GUIDE.md` in sync when you change module boundaries.
