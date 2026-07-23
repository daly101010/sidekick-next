# SideKick-Next Integration Guide

## Runtime ownership

`init.lua` starts the UI/state host (`SideKick.lua`) through `utils/supervisor.lua`.
The supervisor owns the lifetime of the coordinator and every worker listed in
`sk_lib.lua`.
It also checks coordinator process liveness on its normal heartbeat cadence and
restarts an exited coordinator before worker state leases reach their absence
timeout. This closes the asynchronous `/lua stop` then `/lua run` race that can
otherwise leave all still-running workers reporting `state_stale`.
For the first state-TTL window after startup, the coordinator also seeds state
directly to every canonical worker script instead of waiting for the reverse
heartbeat route to discover recipients. Duplicate routes are coalesced per
broadcast.
Every state payload includes a coordinator boot ID. Workers apply tick-order
guards only within that boot, reset local claims when a new boot appears, and
tombstone the retired boot so delayed pre-restart packets cannot switch them
back. Supervisor coordinator recovery uses the same capped restart count,
cooldown, and stable-period reset as worker recovery.

The UI host owns presentation, user input, settings writes, chase movement,
manual button actions, coordinated item requests, rez-dialog acceptance, and
spell-set memorization. In coordinated mode it must not initialize an automatic
cast subsystem merely to
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
| `sk_resurrection.lua` | 2 | Group/Actor-Team resurrection, resource/gem workflow, corpse navigation, and distributed corpse intents |
| `sk_cc.lua` | 3 | Mez selection and casts |
| `sk_tank.lua` | 0/2.5/3.25/4 | Tank emergency defenses, loose-mob recovery, routine hate tools, stable kill-target engagement, and Actor target broadcasts |
| `sk_pull.lua` | 3.5 | Read-only target scan followed by claimed navigation, targeting, and pull execution |
| `sk_assist.lua` | 4 | Target-only melee assist, positioning, and auto-attack |
| `sk_dps.lua` | 4 | Combat rotation |
| `sk_items.lua` | 4/6 | Configured clicky selection plus queued manual item-bar uses |
| `sk_resources.lua` | 5 | Resource conversion |
| `sk_buffs.lua` | 6 | OOC buffs and buff spell swaps |
| `sk_meditation.lua` | 7 | Sit/stand state |
| `sk_disciplines.lua` | varies | Class discipline actions |
| `sk_fidget.lua` | 5 auxiliary | Humanize profile/fidget timing; never requests target or cast ownership |

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

Coordinator-state freshness is measured from the worker's local Actor receipt
time, not the coordinator's `sentAtMs`; the processes may have different clock
origins and transport latency. Within one coordinator boot, workers reject
decreasing `tickId` values before updating state or its freshness window. The
five-second state window tolerates
normal background-client frame throttling while the ten-second process watchdog
remains the hard coordinator-failure boundary. If a Lua loop resumes after a
longer scheduler pause, it holds any in-flight action without advancing or
cancelling it until a newer coordinator tick arrives.

Coordinator broadcasts target each worker's script-scoped `sk:state` mailbox;
the canonical route comes from the Actor sender's `script` address, which the
coordinator preserves when it queues callback messages. A supervised
module-to-script map is the fallback for shared mailboxes such as `sk:hb`; the
coordinator never treats the mailbox prefix `sk` as a script name.
`/sk_coord status` reports state-send attempts and immediate routing failures.
Worker heartbeats advertise `ready=false` whenever their coordinator snapshot
is stale or they are waiting for a post-resume snapshot. The coordinator cannot
promote an old need from a not-ready worker, and the worker actively clears that
need instead of leaving a long cast-time TTL displayed as actionable. Healing
heartbeats additionally expose the selected pre-claim spell as
`waiting_priority`, `awaiting_claim`, or `claim_pending`, so an empty executor is
not mistaken for an empty healing decision.

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
The shared spell-event registry is reference-counted so a custom adapter and the
native spell executor can observe the same event set without duplicate names.

Healing action construction requires a positive spawn ID before advertising a
need. If a target-monitor entry has only a name, it attempts an exact visible
PC, mercenary, or pet resolution and verifies the returned clean name. An
unresolved target is skipped so `priority_targets` cannot remain asserted while
`ModuleBase:getAction()` silently returns no claim.

Before a worker sends a coordinator claim, ModuleBase copies the action into an
Actors-safe scalar/table payload; runtime functions, userdata, cyclic references,
and unsupported keys cannot poison claim delivery. Immediate serialization or
routing failures clear `claimPending` and are exposed by the worker status.
`/sk_coord status` reports aggregate claim receipts, grants, rejections, and the
last admission result without requiring per-tick debug-file logging.

`sk_items.lua` is the sole coordinated owner of configured item clicks. Combat,
out-of-combat, and saved-condition modes are selected in its normal worker tick;
the UI item bar sends a local `item:manual` Actor request instead of issuing
`/useitem` from the ImGui callback. Manual requests are bounded, revalidated for
inventory readiness, and prioritized ahead of automatic item candidates, but
still wait for the coordinator's cast lease. Monolithic mode retains the direct
item compatibility path.

Resurrection is a non-blocking pre-cast workflow. Targeting, corpse dragging,
optional MQ2Nav movement, temporary spell memorization, spell/item/AA use, and
gem restoration each advance as bounded phases while worker heartbeats remain
live. Its action may request a longer bounded `claimTtlMs`; the coordinator
still revokes on heartbeat loss, incapacitation, or a higher-priority claim.
Corpse distance is validated against the selected resource before Actor election
or coordinator admission. Only OOC navigation candidates within
`RezNavMaxDistance` may proceed while outside the resource's direct range.
Candidate discovery prefers EQ group members and then fresh members from the
coordinator's Actor Team snapshot. For Actor Team candidates, an exact locally
visible PC corpse is authoritative because the peer death flag can lag while a
client is hovering and its live zone changes after releasing to bind.

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

`sk_tank.lua` is the coordinated owner of tank-mode targeting, auto-attack,
positioning stick commands, tank emergency/defensive abilities, hate tools,
and reactive Taunt. Following the split-target model used by mature combat
automation, it keeps a stable primary kill target for Actor broadcasts while
using a separate temporary recovery target for a loose mob. Recovery completion,
failure, cancellation, ownership loss, pause, and incapacitation all stop Nav
and restore the primary target. The worker refreshes its primary broadcast once
per second so background assisters do not age out a still-valid target.

Tank class predicates in the `emergency`, `defenses`, and `aggro` categories
are excluded from `sk_disciplines.lua` while the character is in tank mode;
`sk_tank.lua` is their sole owner and permits AA, discipline, and memorized
spell resources. Emergency/defense actions claim at priority 0, loose-mob
recovery at 2.5, routine hate at 3.25, and ordinary engagement at 4. Active mez
is an unconditional AE prohibition and mezzed mobs are never fallback kill
targets. `TankSafeAECheck` additionally suppresses AE hate when the nearby NPC
count exceeds the active XTarget-hater count.

The primary `status:update` Actor heartbeat and coordinator-owned Actor Team
state include the sender's current target ID/type/name.
`utils/actors_coordinator.lua` merges partial worker heartbeats so they cannot
erase that target telemetry. `sk_dps.lua` prefers fresh explicit target
broadcasts, then the configured/EQ-designated main assist, then a deterministic
same-zone Actor Team NPC-target vote, before local group/TLO and XTarget
fallbacks. This lets pure casters and healers build their DPS condition context
from the assist mob without requiring melee assist to own a target.
The local character is excluded from the team vote because its current heal or
manual target is already covered by local fallbacks. A fresh remote member's
`inCombat` state is carried with the chosen target as engagement evidence for
OOG clients that do not share local XTarget state. Team leader election remains
a presence responsibility and does not designate the combat main assist.

`sk_pull.lua` separates candidate selection from side effects. The underlying
pull state machine may scan and enter `READY` without ownership, but it cannot
stand, navigate, retarget, attack, or use the configured pull ability until the
worker receives its target claim. Pull priority sits just above normal DPS
assist, so Assist releases its target lease for the complete outbound/return
workflow. The worker retains bounded target validation and navigation/targeting
timeouts, and the `pullRespectMedState` gate prevents a new pull from standing a
character that is intentionally meditating.
`READY` claim wait is bounded, cancellation or ownership loss records the normal
pull cooldown, and a humanize `SKIP` refreshes the short pull-command window so
delay rolls cannot manufacture a target timeout.
The worker publishes local-only `pull:telemetry` so the Pull settings tab shows
the authoritative worker phase, target, reason, and ownership state rather than
the UI process's inert compatibility copy.

`sk_fidget.lua` is a supervised auxiliary worker. It heartbeats through
`ModuleBase` but never advertises actionable coordinator work. This keeps idle
humanization alive in coordinated mode without competing for target or cast
ownership. The fidget state machine uses the documented chat edit-box
`Highlighted` and `Text` members to block new synthetic input. A movement key
that was already held is always released even if chat gains focus, humanize is
disabled, or the worker exits; chained movement and other follow-up input remain
suppressed.

Adaptive resist tracking is initialized by each process-local spell engine.
Cast-result listeners record resisted combat/support spells, normal completion
breaks the current consecutive-resist streak, and the throttled log is loaded,
ticked, and flushed on spell-engine shutdown.

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

`utils/logger.lua` applies its persisted level, file-output flag, and filter
during each process-local settings reload. The Logging tab and `/skloglevel`,
`/sklogfile`, and `/sklogfilter` therefore propagate to the coordinator and all
workers on the next settings revision instead of changing only the UI process.
Healing Intelligence retains its separate detailed logger and categories.

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
Saves are serialized to a sibling staging file, parsed and schema-checked, then
promoted with same-directory renames. The prior live file remains as `.bak` and
`load()` falls back to it after a corrupt primary write or when the live file is
missing because promotion stopped between the live-to-backup and stage-to-live
renames.

`utils/spellset_memorize.lua` is the owner of manual gem adoption. Only its main
loop samples live gems; it does not mutate state from memorization event
callbacks. It waits for a stable layout with the spellbook closed, excludes the
reserved OOC-buff gem, and saves changes to the active set. The buff worker may
close the spellbook only for a recent `/memspell` request it owns; unrelated
manual memorization events are observational and must not change buff-swap
state.

The coordinated DPS worker accepts only `direct_damage`, `dot`, and `debuff`
spell-set entries. Beneficial `buff` entries remain visible in their physical
gem slots but are routed away from DPS; automatic maintenance requires explicit
selection in the OOC Buffs list. Pet and other utility spells similarly require
their explicit utility mode and are owned by the resource worker.

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
that snapshot without initializing another healing runtime. Telemetry includes
plain-table target HP provenance (`maxHPKnown` / `maxHPSource`), combat pressure,
the last target-specific scoring pass, and analytics so the UI can visibly distinguish Actor,
DanNet, spawn, self, and estimated Max HP values.

Routine single-target selection excludes fast direct heals (base cast time at
or below the configured fast-heal boundary) and Complete Heal, then maximizes
effective healing per mana after projected overheal. A fast heal is selected
only for an HP emergency or when measured high pressure shows the efficient
heal cannot catch up before landing. Estimated Max HP follows this same policy;
it must never silently route to a separate smallest-heal fallback.

Direct group heals retain their minimum-wounded-member and projected-coverage
gates, but eligibility no longer gives them automatic priority. The selector
scores useful healing across every affected local group member, including
projected damage at landing and trusted incoming HoT coverage, then compares
that effective HPM with the best stable single-target direct heal. High-DPS
catch-up overrides this efficiency comparison so the normal fast-heal guard
can protect the endangered target. Out-of-group Actor teammates are not
included because local group heals cannot land on them.

Distributed `heal:claim` messages include expected heal, cast time, and the
projected deficit at landing. Every healer sorts the same deterministic
coverage queue. Character name is only the final exact-tie breaker.

Damage attribution resolves combat-log attacker names against a throttled
XTarget cache. When multiple live NPCs have the same name, their log damage is
marked ambiguous and is not assigned to a particular spawn or used as exact
per-spawn AE evidence. Named detection caches plugin availability briefly and
per-spawn results for less than one second to keep target scoring off the TLO
plugin-query hot path without allowing stale spawn IDs to linger.

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

The Actor Team protocol itself is presence and shared state only; it does not
grant remote cast rights. Resurrection probes fresh team members for an exact
PC corpse visible in the rezzer's current zone instead of requiring the Actor
death or zone hints, while its per-corpse rezzer election continues using the
feature-specific intent transport. Existing heal, cure, CC, and buff messages
continue using their current transports until explicitly migrated.
An offline, dead, or other-zone Group entry does not suppress that Actor Team
corpse probe; this covers a member who remains grouped after releasing to bind.
For an Actor Team target, the rezzer sends a character-targeted consent request
to the target's rez worker. The recipient grants `/consent` only when both names
belong to the same current team and the requesting rezzer is fresh; the request
is drained in the normal worker loop rather than the non-yieldable Actor callback.

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

## Actors message contracts

### `vitals:group` (v1) — tank → UI scripts

The designated tank (`CombatMode == 'tank'`, gate `VitalsHubEnabled`) publishes
one consolidated group-vitals message at ≤5Hz (change-driven, 2s heartbeat)
from `utils/vitals_hub.lua` via `ActorsCoordinator.sendVitalsGroup`. Fan-out is
script-addressed: `{ mailbox = 'grouptarget', script = 'group' }` and
`{ mailbox = 'medley_remote', script = 'eq_ui_rebuild_classic' }`.

Payload: `{ id='vitals:group', v=1, seq, from, server, zone, members }` where
`members[name] = { id, level, class, hp, mana, endur, petHp, dead, sitting,
casting, present }`. `present` is from the TANK's perspective; when false the
volatile fields are absent. `casting` is only populated for the publisher.
Consumers treat every field as optional, use the feed only while fresh (<2s),
and keep their own TLO polling as fallback. Distance / LineOfSight / viewer
zone logic must stay locally polled (relative to the viewer, not the tank).
Healing decisions never consume this feed (latency).
