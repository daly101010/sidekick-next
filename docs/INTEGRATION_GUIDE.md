# SideKick-Next Integration Guide

## Runtime ownership

`init.lua` starts the UI/state host (`SideKick.lua`) through `utils/supervisor.lua`.
The supervisor owns the lifetime of the coordinator and every worker listed in
`sk_lib.lua`.
It also checks coordinator process liveness on its normal heartbeat cadence and
restarts an exited coordinator before worker coordinator-state snapshots reach
their absence timeout. This closes the asynchronous `/lua stop` then `/lua run`
race that can otherwise leave all still-running workers reporting
`state_stale`.
For the first state-TTL window after startup, the coordinator also seeds state
directly to every canonical worker script instead of waiting for the reverse
heartbeat route to discover recipients. Duplicate routes are coalesced per
broadcast.
Every state payload includes a coordinator boot ID. Workers apply tick-order
guards only within that boot, reset local lease state when a new boot appears,
and tombstone the retired boot so delayed pre-restart packets cannot switch
them back. Supervisor coordinator recovery uses the same capped restart count,
cooldown, and stable-period reset as worker recovery.

The UI host owns presentation, user input, settings writes, and submission of
manual requests. In coordinated mode it does not tick automatic casting,
targeting, movement, meditation, or spell-scribing behavior merely to display
status. The dedicated workers own those effects; worker telemetry and
coordinator state are read-only UI data sources.

`sk_coordinator.lua` grants exactly one local action lease at a time. The lease
is deliberately action-blind: it serializes any game-changing episode, whether
that episode casts, targets, moves, attacks, clicks an item, sits, or memorizes
a spell. A worker selects and retains its action locally. Its
`lease:request` contains protocol and identity/session/request data, not the
action or a worker-selected priority. Lease request/withdraw operations also
carry a worker-session monotonic `operationSeq`; a withdrawal advances the
sequence even when its request has not arrived, preventing delayed packets from
resurrecting abandoned intent.

The coordinator derives a fixed tier and deterministic order from the single
`sk_lib.lua` worker registry. Lower tiers run first; registry order breaks ties
within a tier independently of request arrival. Workers cannot transmit or
override either value.

| Order | Worker | Fixed tier | Owned behavior |
|---:|---|---:|---|
| 1 | `sk_emergency.lua` | 0 EMERGENCY | Non-heal emergency actions |
| 2 | `sk_healing.lua` | 1 HEALING | Healing selection and execution |
| 3 | `sk_cures.lua` | 1 HEALING | Cure selection and execution |
| 4 | `sk_resurrection.lua` | 2 RESURRECTION | Group/Actor-Team rez, corpse movement, resource/gem workflow |
| 5 | `sk_tank.lua` | 3 TANK | Tank targeting, positioning, defenses, hate tools, and Actor target broadcasts |
| 6 | `sk_cc.lua` | 4 CROWD_CONTROL | Mez selection and execution |
| 7 | `sk_debuff.lua` | 5 DEBUFF | Automatic debuff selection and execution |
| 8 | `sk_pull.lua` | 6 PULL | Pull workflow (mechanical lease migration only; see below) |
| 9 | `sk_assist.lua` | 7 DPS | Melee assist, positioning, and auto-attack |
| 10 | `sk_chase.lua` | 7 DPS | Out-of-combat chase movement |
| 11 | `sk_resources.lua` | 7 DPS | Resource conversion |
| 12 | `sk_disciplines.lua` | 7 DPS | Class discipline actions |
| 13 | `sk_items.lua` | 7 DPS | Configured clickies and queued manual item-bar uses |
| 14 | `sk_dps.lua` | 7 DPS | Combat rotation |
| 15 | `sk_buffs.lua` | 8 BUFF | OOC buffs and bounded buff spell swaps |
| 16 | `sk_meditation.lua` | 9 MEDITATION | Sit/stand resource recovery |
| 17 | `sk_scribing.lua` | 10 SCRIBING | Automatic spell-gem and scribing workflow |
| 18 | `sk_fidget.lua` | 11 AMBIENT | Safe idle-humanization episodes |

Tier 99 IDLE is reserved for internal scheduler state and is not a worker tier.
Because there is one lease, an Assist targeting episode and a DPS casting
episode cannot run concurrently.

The worker keeps the selected action beside its request ID and crosses the
final mutation boundary only after `ownsLease()` validates the coordinator
boot, lease token, holder module, worker session, and request ID. Workers renew
long-running episodes and finalize owned effects before releasing the lease.
The coordinator broadcasts incapacitation, death, zoning, pause, and lifecycle
state; workers also sample local control state immediately before execution.

Urgent preemption is coordinator-owned and can be disabled with
`LeasePreemptionEnabled` ("Allow Urgent Lease Preemption"). Only the registered
Emergency, Healing, Cures, Resurrection, and Tank workers may trigger it, and
only when their fixed tier is numerically lower than the active holder's tier.
The coordinator marks the current lease `revoking`; it never issues
`/stopcast`. The holder observes that state, cancels or drains its own effects
through its finalizer, and releases. If the revocation grace or lease TTL
expires, the scheduler fences the old token and grants a recovery lease before
new work. Recovery requests outrank ordinary requests.

Coordinator-state freshness is measured from the worker's local Actor receipt
time, not the coordinator's `sentAtMs`; the processes may have different clock
origins and transport latency. Workers require the exact local coordinator
sender route and protocol version, clamp the advertised TTL, and reject
non-increasing `tickId` values before updating state or its freshness window. The
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
grant a stale request from a not-ready worker, and the worker withdraws obsolete
intent rather than leaving it displayed as actionable.

`utils/action_executor.lua` owns the local lifecycle after a lease is granted.
Every cast-capable coordinated worker opts in through
`ModuleBase:enableUnifiedExecutor()`. Actions advance through `queued`,
`dispatching`, `waiting_start`, `running`, and one terminal state
(`completed`, `failed`, or `cancelled`). `ModuleBase` ticks this lifecycle from
the worker coroutine and releases the lease on every terminal result. The
result remains local to the worker; only aggregate activity counters ride the
heartbeat for diagnostics. Actor callbacks only copy state; they never tick or
dispatch the executor.

Spell, AA, discipline, item, and skill actions use the executor's native
dispatch and monitoring. Healing adds hooks for incoming-heal registration,
ducking, emergency switching, and analytics. Buff and resurrection retain
their existing bounded multi-phase state machines as custom executor adapters;
their steps still run once per worker tick, so memorization, navigation, and
gem restoration do not block heartbeats. Incapacitation cancels a queued or
running lifecycle immediately. Cross-module preemption remains coordinator
owned; a worker may cancel only effects that it owns for ducking or safety.
The shared spell-event registry is reference-counted so a custom adapter and the
native spell executor can observe the same event set without duplicate names.

Healing action construction requires a positive spawn ID before requesting a
lease. If a target-monitor entry has only a name, it attempts an exact visible
PC, mercenary, or pet resolution and verifies the returned clean name. An
unresolved target is skipped so `priority_targets` cannot remain asserted while
`ModuleBase:getAction()` silently returns no lease request.

Actions are never serialized into the local lease protocol. Immediate routing
failures leave the local action unexecuted and are exposed by worker status.
`/sk_coord status` reports aggregate request receipts, grants, rejections, and
the last admission result without requiring per-tick debug-file logging.

`sk_items.lua` is the sole coordinated owner of configured item clicks. Combat,
out-of-combat, and saved-condition modes are selected in its normal worker tick;
the UI item bar sends a local `item:manual` Actor request instead of issuing
`/useitem` from the ImGui callback. Manual requests are bounded, revalidated for
inventory readiness, and prioritized ahead of automatic item candidates, but
still wait for the coordinator's single action lease. Monolithic mode retains
the direct item compatibility path.

Resurrection is a non-blocking pre-cast workflow. Targeting, corpse dragging,
optional MQ2Nav movement, temporary spell memorization, spell/item/AA use, and
gem restoration each advance as bounded phases while worker heartbeats remain
live and the worker renews its lease. The coordinator still starts revocation
on heartbeat loss, incapacitation, or an eligible higher-tier urgent request.
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

`automation/cc.lua`, `automation/cures.lua`, and `automation/debuff.lua`
provide domain selection/execution helpers. Their automatic execution owners
are `sk_cc.lua`, `sk_cures.lua`, and the separate `sk_debuff.lua` worker,
respectively. `automation/meditation.lua` is a no-op shim;
`sk_meditation.lua` is the only meditation owner. Automatic spell-gem/scribing
work belongs to the separate `sk_scribing.lua` worker. `sk_disciplines.lua`
excludes mez and debuff predicates owned by those domain workers.

`sk_assist.lua` is the coordinated owner of melee assist targeting and
positioning. It holds the one action lease for the entire owned episode, so
`sk_dps.lua` cannot cast during that Assist episode.
`automation/assist.lua` is a helper library — it must not run automatic
assist actions from the UI host; the worker owns that.

`sk_chase.lua` is the dedicated out-of-combat chase worker. It uses
`automation/chase.lua` for read-only intent selection, records an exact target
fingerprint, and requests its fixed DPS-tier lease only when movement is
needed. A granted movement slice is bounded to 15 seconds. Stalls, start
failures, and timeouts use a 500 ms requeue backoff, with at most two recovery
attempts. Finalization stops Nav, MoveTo, follow/stick, and any held movement
keys before release. Chase is not a catch-all utility worker, and the UI host
does not tick chase movement.

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
spell resources. Emergency/defense, loose-mob recovery, routine hate, and
ordinary engagement may retain internal action rankings, but all requests
enter the coordinator at the fixed Tank tier. Active mez is an unconditional
AE prohibition and mezzed mobs are never fallback kill targets.
`TankSafeAECheck` additionally suppresses AE hate when the nearby NPC count
exceeds the active XTarget-hater count.

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

`sk_pull.lua` was mechanically migrated to the same one-lease lifecycle.
Candidate selection remains read-only before admission; standing, navigation,
retargeting, attacking, and the configured pull ability may run only while the
worker holds the fixed Pull-tier lease. The pull worker finalizes its owned
movement and targeting effects before release.

This migration deliberately did not redesign pull behavior. Candidate
selection, election, pathing, state-machine strategy, and pull-specific tuning
remain as they were and are deferred behind the core coordination work.
The worker publishes local-only `pull:telemetry` so the Pull settings tab shows
the authoritative worker phase, target, reason, and ownership state rather than
the UI process's inert compatibility copy.

`sk_fidget.lua` is the supervised lowest-tier Ambient worker. It plans
read-only, bounded idle-humanization episodes and requests the single action
lease before producing input. The fidget state machine uses the documented
chat edit-box `Highlighted` and `Text` members to block new synthetic input. A
movement key that was already held is always released even if chat gains focus,
humanize is disabled, its lease is revoked, or the worker exits; chained
movement and other follow-up input remain suppressed.

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
state. This manual-observation path is separate from automatic spell-gem and
scribing actions, which are owned by `sk_scribing.lua` under the action lease.

The coordinated DPS worker accepts only `direct_damage` and `dot` spell-set
entries. `debuff` entries are routed to the separate `sk_debuff.lua` worker.
Beneficial `buff` entries remain visible in their physical gem slots but are
routed away from DPS; automatic maintenance requires explicit selection in the
OOC Buffs list. Pet and other utility spells similarly require their explicit
utility mode and are owned by the resource worker.

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
the active lease's fixed tier and holder identity, and summarized worker
readiness. The action itself remains private to the local worker.
Peers expire after four seconds without a heartbeat.

Team identity defaults to the current raid leader, then group leader, then the
local character. Settings under `integration.ini` can force group, raid, or a
case-insensitive manual team name. Members elect the observed EQ group/raid
leader when available and otherwise use a deterministic server/character key.
The team snapshot is included in coordinator state and rendered under
Coordinator > Actor Team. `/sk_coord team` prints the local summary.

The Actor Team protocol itself is presence and shared state only; it cannot
grant a local action lease. Resurrection probes fresh team members for an exact
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

Actor callbacks perform only non-yielding envelope checks and bounded
copy/enqueue work. They must not read TLOs, call `mq.delay`, reload files,
target, cast, issue gameplay commands, or invoke other yielding code. Normal
coordinator/worker ticks consume the copied state, validate identity,
authorization, freshness, and sequence, and perform all yielding work.

## Adding a worker

1. Implement selection without game-changing side effects.
2. Register the worker once in `sk_lib.lua` with a fixed tier, deterministic
   order, script route, and any urgent-preemption/enable metadata.
3. Create a `ModuleBase` worker. Keep the selected action local, expose intent
   with `setIntent()`, and request a lease only while that action remains valid.
4. Include a stable idempotency key in the local action.
5. Call `enableUnifiedExecutor()` and provide hooks only for behavior the
   native spell/AA/disc/item/skill paths cannot represent.
6. Cross the final mutation boundary only after exact `ownsLease()` validation.
   Use `onLeaseFinalizing()` to stop or drain owned effects before every release,
   and mark dirty effects that require a recovery lease after a crash or timeout.
7. Confirm the UI host does not also initialize or tick the subsystem, update
   this document, and add lifecycle/failure-path tests.

## Actor topic conventions

sidekick-next currently uses two disjoint Actors planes; keeping them apart
is intentional but the split is easy to miss on first read.

**Local control plane.** Mailboxes `lease:request`, `lease:withdraw`,
`lease:renew`, `lease:release`, `lease:recovered`, `sk:state`, `sk:hb`,
`sk:supervisor`, and `sk:team`. The coordinator and workers use this plane for
the action-blind local lease lifecycle, fixed registry tiers, state,
supervision, and presence. Envelope key is `msgType`; a lease request carries
identity/session/request fields but never the action or a caller-selected
priority. It is handled inside `sk_coordinator.lua`, `sk_module_base.lua`, and
`utils/actors_team.lua`.

**`sidekick` peer plane.** Mailbox `sidekick`, ~30 topics fanned out via
`ActorsCoordinator.broadcastFleet(topic, payload)`. Envelope key is `id`.
This is the plane for cross-character feature state — target selection, mez
lists, buff status, cure requests, tank positioning, charm-pet identity,
healing HoT snapshots, and domain-specific `heal:claim`, `buff:claim`,
`debuff:claim`, and `cc:claim` messages. These claims coordinate peer intent;
they neither grant nor subdivide the coordinator's one local action lease. If
you are adding "everyone should know X", this is the plane.

Full protocol unification (single envelope, single topic namespace) is
deferred. The local plane validates the Actor sender route together with
module, script, owner, session, and request identity; the peer plane uses
`from = <char name>` plus its feature-specific identity and sequencing rules.

### Guarded topics — sender identity + sequence

A subset of peer-plane topics is last-write-wins state that would flip if
same-sender packets arrived out of order (network jitter, MQ delay):

- `target:primary` — tank identity + authoritative group kill target. The
  tank's temporary working target for taunts/hate tools is never a DPS target;
  a fresh `targetId = 0` explicitly suppresses live-target fallbacks.
- `tank:repositioning`, `tank:settled`, `tank:taunt_run`, `tank:taunt_done`
- `tank:mode`
- `tank:camp_anchor` — tank's live idle position
- `cc:charmpet` — the enchanter's protected charm pet
- `pull:intent` — cooperative puller election

`ActorsCoordinator.broadcastFleet` wraps SideKick peer payloads in the v2
Actor envelope with a per-sender session and monotonic sequence.
Receivers call `isStaleGuardedMessage(id, content, sender)` and drop same-
session packets with sequence ≤ last accepted. A new `sessionId` (sender
restart) resets the sequence gate. SideKick peer messages without a valid
envelope, canonical sender script/mailbox, and coordinator-owned team context
fail closed.

To add a new guarded topic:
1. Add the id to `GUARDED_TOPICS` in `utils/actors_coordinator.lua`.
2. In the receiver block, call `if isStaleGuardedMessage(id, content, sender) then return end`
   after your zone / authorization gates.
3. Send via `broadcastFleet` — the augmentation is automatic.

### Camp anchor and puller election

`sk_tank.lua` broadcasts `tank:camp_anchor` whenever its idle anchor
re-anchors (~every 5s while OOC and stationary).
`ActorsCoordinator.getTankCampAnchor(maxAgeSec)` returns the freshest
value. `automation/pull.lua` prefers it over its own snapshot so
`RETURN_CAMP` tracks tank drift.

`automation/pull.lua` broadcasts `pull:intent` every 2s while
`Config.enabled == true`, carrying `startedAt` (seconds since epoch).
`ActorsCoordinator.getEarliestPullPeer()` returns the earliest-startedAt
same-zone peer within a 6s TTL. When another peer's startedAt is earlier
than ours, we yield (skip pulls, keep ticking sensors). Mid-pull work
runs to completion to avoid stranded mobs.

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
