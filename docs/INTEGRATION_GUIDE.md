# SideKick-Next Integration Guide

## Runtime ownership

`init.lua` starts the UI/state host (`SideKick.lua`) through `utils/supervisor.lua`.
The supervisor owns the lifetime of the coordinator and every worker listed in
`sk_lib.lua`.

The UI host owns presentation, user input, settings writes, chase movement,
manual button actions, rez-dialog acceptance, and spell-set memorization. In
coordinated mode it must not initialize an automatic cast subsystem merely to
display status. Worker telemetry and coordinator state are the read-only UI
data sources.

`sk_coordinator.lua` is the exclusive cast/target arbiter. Automatic action
selection can happen in a worker only; targeting or casting starts after that
worker receives the matching claim. The current workers are:

| Worker | Priority | Ownership |
|---|---:|---|
| `sk_emergency.lua` | 0 | Non-heal emergency actions |
| `sk_healing.lua` | 0/1 | Emergency and normal healing |
| `sk_cures.lua` | 2 | Cure target selection and casts |
| `sk_resurrection.lua` | 2 | Group resurrection, resource/gem workflow, corpse navigation, and distributed corpse intents |
| `sk_cc.lua` | 3 | Mez selection and casts |
| `sk_assist.lua` | 4 | Target-only melee assist, positioning, and auto-attack |
| `sk_dps.lua` | 4 | Combat rotation |
| `sk_resources.lua` | 5 | Resource conversion |
| `sk_buffs.lua` | 6 | OOC buffs and buff spell swaps |
| `sk_meditation.lua` | 7 | Sit/stand state |
| `sk_disciplines.lua` | varies | Class discipline actions |

The coordinator broadcasts stunned, mezzed, silenced, and feared state and
revokes both cast and target ownership while the local character is
incapacitated, dead, or zoning. Workers also sample the local control state in
their normal tick immediately before executing a granted action.

Spell claims have two lease phases. Ordinary spell actions must produce an
observable cast bar within 1000 ms of the grant or the coordinator revokes the
claim. Deliberate pre-cast workflows declare their own bounded window: DPS/CC
humanization, corpse preparation, and buff gem memorization. Once a cast is
observed, the normal action TTL starts; an active cast is allowed to finish,
then stale ownership is cleared. Repeated need hints never extend ownership.
Workers retain a tombstone for the last claim they released so an older Actor
snapshot cannot resurrect and execute that claim again.

`utils/action_executor.lua` owns the local lifecycle after a claim is granted.
Every cast-capable coordinated worker opts in through
`ModuleBase:enableUnifiedExecutor()`. Actions advance through `queued`,
`dispatching`, `waiting_start`, `running`, and one terminal state
(`completed`, `failed`, or `cancelled`). `ModuleBase` ticks this lifecycle from
the worker coroutine, releases the claim on every terminal result, and includes
the current or most recent result in its heartbeat. Actor callbacks only copy
state; they never tick or dispatch the executor.

Spell, AA, discipline, item, and skill actions use the executor's native
dispatch and monitoring. Healing adds hooks for incoming-heal registration,
ducking, emergency switching, and analytics. Buff and resurrection retain
their existing bounded multi-phase state machines as custom executor adapters;
their steps still run once per worker tick, so memorization, navigation, and
gem restoration do not block heartbeats. Incapacitation cancels a queued or
running lifecycle immediately. Cross-module preemption remains coordinator
owned; a worker may request cancellation of its own cast for ducking or safety.

Resurrection is a non-blocking pre-cast workflow. Targeting, corpse dragging,
optional MQ2Nav movement, temporary spell memorization, spell/item/AA use, and
gem restoration each advance as bounded phases while worker heartbeats remain
live. Its action may request a longer bounded `claimTtlMs`; the coordinator
still revokes on heartbeat loss, incapacitation, or a higher-priority claim.

Rez-capable peers broadcast `rez:claim` intents through
`utils/actors_coordinator.lua`. Actor callbacks only enqueue/copy scalar state.
The worker elects the lowest configured `RezPriority`, then character name,
after a short settle window. `rez:completed` suppresses duplicate casts while
the winner restores its temporary gem. The UI receives local-only
`rez:telemetry` and renders it in Coordinator > Resurrection Status.
The shared resurrection settings renderer is exposed through both
`ui/settings/tab_resurrection.lua` (Options > Resurrection) and the healer
settings surface; both entry points write the same registry keys.

Temporary rez memorization uses the shared external spell-gem lease already
observed by `utils/spellset_memorize.lua`, preventing the manual-gem adopter
from persisting the temporary rez spell. A small recovery record stores the
displaced gem and is consumed after a worker restart. Combat never
auto-memorizes or initiates navigation.

`automation/cc.lua` and `automation/cures.lua` expose side-effect-free
selection functions plus explicit execution functions. Their compatibility
`tick`/`mezTick` entry points exist only for the feature-flagged monolithic
mode. `automation/meditation.lua` is a no-op compatibility shim; the worker is
the only meditation owner. `sk_disciplines.lua` excludes all mez predicates so
it cannot become a second CC caster.

`sk_assist.lua` is the coordinated owner of melee assist targeting and
positioning. It requests only the target resource at DPS priority, allowing
`sk_dps.lua` to hold the cast resource concurrently. Higher-priority healing,
cure, resurrection, or CC work revokes the assist target lease before those
workers retarget. The UI-host `automation/assist.lua` tick remains monolithic
compatibility code and must not run automatic assist actions in coordinated
mode.

## Settings persistence

`registry.lua` is the authoritative schema and ownership registry. Every
registered setting has exactly one explicit module owner; duplicate ownership
or a registered key without an owner fails the registry audit. Generated key
families such as abilities, pull, humanize, and discovered skills use declared
namespaces. `utils/config_modules.lua` remains only as compatibility routing for
unregistered legacy keys and non-settings INI sections.

`utils/core.lua` stores settings under:

```text
<MQ Config Dir>/SideKick-Next/config/<Server>_<Character>/<module>.ini
```

The UI Lua process is the only writer. `utils/atomic_ini.lua` stages and
validates each write, replaces the destination, and retains `.bak`. Workers
load their files at startup and reload only after the UI reports a successfully
committed `settingsRevision` through the supervisor/coordinator state. Do not
publish a revision before the disk write succeeds, and never reload settings in
an Actor callback.

The old combined character INI is migration input only. A worker that needs to
change a user setting must route the request to a UI-owned command or message;
it must not call `LIP.save` or write a character module INI.

Before overlaying module files, Core canonicalizes registered keys into their
declared owner. If the same key remains in an older module file, the owner's
copy wins and the stale copy is removed during the next successful primary
writer save. `Core.setMany()` validates the complete batch before changing
memory, so a rejected value cannot leave a partially applied configuration.
The settings UI and `/sk config set` both write through this path.

Use `/sk config audit` to inspect registry health, `/sk config get <key>` to see
the current value, owner, and file, and `/sk config set <key> <value>` for a
validated command-line write.

`CombatMode` is the sole combat-role and assist enable setting: `off`, `tank`,
or `assist`. The former `AssistEnabled` gate is tombstoned, and `AssistAt` is
the single HP engage threshold for Actor-broadcast and fallback MA targeting.
On first load, Core migrates an enabled legacy assist gate to
`CombatMode=assist`, adopts the old Actor engage threshold into `AssistAt`, and
removes both retired keys from module files.

All `Rez*`, `AutoRez*`, and `AutoAcceptRez` settings are explicitly owned by
`resurrection.ini`. On the first load after this split, values previously held
in `healing.ini` or the combined migration source are moved into the new module
file.

The active settings UI is `ui/settings/init.lua` with modules under
`ui/settings/`. `ui/settings.lua` is only a compatibility forwarder to that
module. Healing Intelligence controls write `healing/config.lua` directly
rather than similarly named legacy registry keys.

Spell-set persistence is separate from module INIs. Version 3 of the spell-set
file stores both the active gem layout and `spellProfiles`, an archive keyed by
spell ID containing condition, priority, buff-target, and utility metadata.
Version 2 files migrate in memory by seeding profiles from their configured
gems and are written as version 3 on the next save.

`utils/spellset_memorize.lua` is the owner of manual gem adoption. Only its main
loop samples live gems; it does not mutate state from memorization event
callbacks. It waits for a stable layout with the spellbook closed, excludes the
reserved OOC-buff gem, and saves changes to the active set. The buff worker may
close the spellbook only for a recent `/memspell` request it owns; unrelated
manual memorization events are observational and must not change buff-swap
state.

## Healing persistence and telemetry

Canonical Healing Intelligence files are:

```text
<MQ Config Dir>/SideKick-Next/healing/config_<Server>_<Character>.lua
<MQ Config Dir>/SideKick-Next/healing/data_<Server>_<Character>.lua
```

`utils/paths.lua` owns both paths. On first use it copies, but never deletes or
overwrites, a matching old flat `SideKick_Healing_*` / `SideKick_HealData_*`
file or a production `SideKick/healing` file.

The healing worker is the sole owner of healing sensors, decisions, learned
data, and incoming-heal claims. It sends a pre-aggregated `heal:telemetry`
snapshot to the same character's UI once per second. The monitor must render
that snapshot without initializing another healing runtime.

Distributed `heal:claim` messages include expected heal, cast time, and the
projected deficit at landing. Every healer sorts the same deterministic
coverage queue. Character name is only the final exact-tie breaker.

## Actor teams

`utils/actors_team.lua` is owned and ticked exclusively by `sk_coordinator.lua`.
It adds a versioned `sk:team` protocol above the existing feature-specific
Actor messages. A team member publishes character identity, zone, class, role,
local coordinator priority, active action, and summarized worker readiness.
Peers expire after four seconds without a heartbeat.

Team identity defaults to the current raid leader, then group leader, then the
local character. Settings under `integration.ini` can force group, raid, or a
case-insensitive manual team name. Members elect the observed EQ group/raid
leader when available and otherwise use a deterministic server/character key.
The team snapshot is included in coordinator state and rendered under
Coordinator > Actor Team. `/sk_coord team` prints the local summary.

This first protocol version is presence and shared state only. It does not
grant remote cast rights or execute commands. Existing heal, cure, CC, buff,
and resurrection messages continue using their current transports until their
election logic is explicitly migrated to team scope.

## Actor callback safety

Actor callbacks validate the local server/character identity and copy message
state only. They must not call `mq.delay`, reload files, target, cast, or invoke
other yielding code. Normal worker ticks consume the copied state and perform
all yielding work.

## Adding a worker

1. Implement selection without game-changing side effects.
2. Create a `ModuleBase` worker and send a need hint only when an action exists.
3. Include a stable idempotency key in its requested action.
4. Call `enableUnifiedExecutor()` and provide hooks only for behavior the
   native spell/AA/disc/item/skill paths cannot represent.
5. Execute only after `ownsClaim()` admission; the executor follows the cast
   lease and releases it on every terminal path.
6. Add the script to `sk_lib.lua`, the coordinator debug ordering, and this
   document.
7. Confirm the UI host does not also initialize or tick the subsystem.
