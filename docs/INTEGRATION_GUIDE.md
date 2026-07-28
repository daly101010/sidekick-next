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
and tombstone a bounded set of retired boots so delayed pre-restart packets
cannot switch them back without allowing that history to grow forever.
Supervisor coordinator recovery uses the same capped restart count,
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
| 2 | `sk_support.lua` | 1 HEALING | Healing, cures, and resurrection |
| 3 | `sk_tank.lua` | 3 TANK | Tank targeting, positioning, defenses, hate tools, and Actor target broadcasts |
| 4 | `sk_combat.lua` | 4 CROWD_CONTROL | CC, managed feign, debuff, assist, disciplines, and DPS |
| 5 | `sk_pull.lua` | 6 PULL | Pull workflow (mechanical lease migration only; see below) |
| 6 | `sk_chase.lua` | 7 DPS | Out-of-combat chase movement |
| 7 | `sk_maintenance.lua` | 7 DPS | Resource conversion and buffs |
| 8 | `sk_items.lua` | 7 DPS | Configured clickies and queued manual UI actions |
| 9 | `sk_meditation.lua` | 9 MEDITATION | Sit/stand resource recovery |
| 10 | `sk_scribing.lua` | 10 SCRIBING | Automatic spell-gem and scribing workflow |

Tier 99 IDLE is reserved for internal scheduler state and is not a worker tier.
Because there is one lease, an Assist targeting episode and a DPS casting
episode cannot run concurrently.

The consolidated profile is enabled by default with
`SIDEKICK_NEXT_CONFIG.CONSOLIDATED_WORKERS=true`. The old 18-worker split
profile remains available by setting the flag false before startup for A/B
diagnosis. `sk_fidget.lua` remains in the source tree but is absent from both
profiles and its Humanize subsystem is forced off.

Domain ordering is local and deterministic. Support evaluates Healing, Cures,
then Resurrection and may interrupt an active resurrection workflow for a new
heal or cure. Combat gives managed feign exclusive control; otherwise it
evaluates CC, Debuff, Assist, Disciplines, then DPS. Only managed-feign safety
or a new CC action may interrupt another active Combat component. Once a spell
has issued `/cast` and entered executor `waiting_start` or `running`, CC is
deferred until that bounded cast finishes; it never creates an interrupt loop
by repeatedly stopping eligible DPS spells. CC may still replace queued
pre-dispatch work, Assist positioning, disciplines, or other non-cast actions.
Maintenance
evaluates Resources before Buffs and does not interrupt an active buff
workflow for a resource action. Any internal interruption finalizes and
releases the current lease before the domain requests another one.
CC participates in Combat arbitration only when the active spell set contains
a configured SPA 31 mez spell. Characters without that capability return
`no_loaded_mez_spell` before CC upkeep, discovery, claims, or executor recovery.
An already-established charm remains a narrow safety exception so its
publication and break-recovery state are not abandoned mid-effect. In the
consolidated worker, CC never interprets the shared SpellEngine activity of DPS,
Debuff, or another component as an orphaned CC cast; host recovery owns that
lifecycle.
Components with custom executor hooks but no custom dispatch handler explicitly
fall through to the shared executor's native spell/AA/disc/item/skill
dispatcher. The domain host must not treat a missing component dispatcher as a
successful no-op. Activity failure counters include both component and terminal
reason so failures remain attributable after consolidation.

Tank reads configured `Auto Hater` XTarget slot 1 as its cheap
hostile-activity sentinel. A populated sentinel admits the full XTarget scan;
an empty sentinel suppresses that expensive snapshot, clears old hostile rows,
and prevents new tank combat actions.
Combat wakes from either its local Auto-Hater sentinel or a fresh authorized
Tank primary publication; requiring both would deadlock a DPS client before its
local aggro list populates. The sentinel is only scan admission and is never
group kill intent. CC charm-state upkeep, charm-break recovery, managed feign
safety, and cleanup of already-owned effects remain live independently.
Tank may publish a positive declared primary with `killAuthorized=false` before
the mob reaches camp so CC can exclude it. Debuff, Assist, Disciplines, and DPS
require the same fresh primary with `killAuthorized=true`, which Tank publishes
only after verifying the EQ target, auto-attack, melee range/LOS, and configured
Stick ownership. A failed approach or unconfirmed command never authorizes
offense.
Their
mutation boundary also verifies that detrimental work still names that exact
ID; authorization for one primary never permits acting on the tank's temporary
or manually selected target.

The worker keeps the selected action beside its request ID and crosses the
final mutation boundary only after `ownsLease()` validates the coordinator
boot, lease token, holder module, worker session, and request ID. Workers renew
long-running episodes and finalize owned effects before releasing the lease.
The coordinator broadcasts incapacitation, death, zoning, pause, and lifecycle
state; workers also sample local control state immediately before execution.

Urgent preemption is coordinator-owned and can be disabled with
`LeasePreemptionEnabled` ("Allow Urgent Lease Preemption"). Only the registered
Emergency, Support, and Tank workers may trigger it, and
only when their fixed tier is numerically lower than the active holder's tier.
The coordinator marks the current lease `revoking`; it never issues
`/stopcast`. The holder observes that state, cancels or drains its own effects
through its finalizer, and releases. If the revocation grace or lease TTL
expires, the scheduler fences the old token and grants a recovery lease before
new work. Recovery requests outrank ordinary requests. This setting controls
ordinary urgent-worker preemption only: mandatory dirty-effect recovery may
revoke a current lease independently because restoring the one-action invariant
is a fencing requirement, not a scheduling preference.
An active effect reported by the exact current holder is not itself an orphan:
workers report active dirty effects separately from `needsRecovery`. The latter
is asserted only after authority is lost or startup discovers an abandoned
effect. A mismatched dirty-effect heartbeat still fails closed into fenced
recovery.
Recovery completion is idempotent across asynchronous coordinator snapshots:
the worker records the completed recovery request and retries its
`lease:recovered` report at heartbeat cadence without re-running cleanup or
emitting duplicate lease transitions. Once accepted, the coordinator records
the report's worker-local send timestamp. A delayed dirty heartbeat from the
same worker session at or before that timestamp is counted and ignored for
recovery scheduling, while later dirty heartbeats can still request a new
recovery normally.

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
`/sk_coord status` reports state-send attempts, immediate routing failures,
bounded Actor-queue overflows, and rejected worker/supervisor protocol packets.
Worker heartbeats advertise `ready=false` whenever their coordinator snapshot
is stale or they are waiting for a post-resume snapshot. The coordinator cannot
grant a stale request from a not-ready worker, and the worker withdraws obsolete
intent rather than leaving it displayed as actionable.

`utils/action_executor.lua` owns the local lifecycle after a lease is granted.
Every cast-capable coordinated worker opts in through
`ModuleBase:enableUnifiedExecutor()`. Actions advance through `queued`,
`dispatching`, `waiting_start`, `running`, and one terminal state
(`completed`, `failed`, or `cancelled`). `ModuleBase` ticks this lifecycle from
the worker coroutine and releases the lease on every terminal result. Every
lease-exit path, including revocation and mutation-boundary rejection, first
cancels and consumes any remaining executor job; a fenced worker instead marks
dirty effects and preserves the job until its recovery lease can safely clean
it. The
action remains private to the worker and never enters scheduler policy.
Transition-only `action:trace` packets go directly from each worker to the
local UI with component, action, target, queue time, hold time, and terminal
reason. Queue diagnostics split the worker-observed total into coordinator-only
`schedulerWaitMs` and `transportObserveMs`, the remaining combined request
ingress, grant broadcast, and worker-observation time. They also record the
first lease holder/status observed while the request was queued and the number
of request refreshes. Ingress and grant delivery are intentionally
not reported as separate one-way values because Lua processes may have
different clock origins. Request refreshes extend the TTL without resetting the
first-receipt timestamp or blocker attribution. The UI sequence-gates these
packets and keeps a bounded 100-event history per worker. Actor callbacks only
copy and enqueue state; they never tick or dispatch the executor.
Each worker also emits one info-level in-game log when it first observes its
grant and one when it sends the terminal release. These lines include the
hosted component, action, target, queue or hold time, and release reason.

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
Coordinator Module Status distinguishes process health from worker activation:
heartbeats include the worker's current intent flag and reason, so an inert but
supervised worker is shown as `Active: no` with reasons such as `mode_off` or
`not_tank_class`.
The UI host clears persisted `AutomationPaused` immediately after loading
settings, before its first supervisor tick, so every new fleet session starts
resumed while runtime pause/resume behavior remains unchanged.
Workers gate global pause on the coordinator state packet, not their
process-local persisted settings snapshot. This prevents a worker that loaded
during startup from remaining paused after the fleet has resumed.

`sk_items.lua` is the sole coordinated owner of configured item clicks and
manual UI activations. The item bar sends a local `item:manual` Actor request;
AA, discipline, spell, and skill buttons send `action:manual`. ImGui callbacks
only copy scalar request data and enqueue transport: TLO revalidation and every
mutating command occur later in the worker's yieldable loop after it receives
the coordinator's single action lease. Manual requests share one bounded FIFO,
take precedence over automatic item candidates, and are removed on terminal
success/failure. Preemption preserves a live request for retry. There is no
direct UI compatibility path. The Remote Abilities window targets the same
worker mailbox on the selected Actor Team character; the destination worker,
not `/dex`, obtains that character's lease and performs the action.
The Items worker also owns global cursor cleanup independently of configured
automatic items and automation level. It observes `Cursor.ID` without mutating
state and starts a five-second grace period for that exact item identity. If the
same item remains, Items requests the normal lease, revalidates the cursor
identity at the mutation boundary, issues `/autoinventory`, and verifies that
the item leaves the cursor. Clearing or changing the cursor resets the grace
period; an inventory-full failure waits another five seconds before retrying.

Resurrection is a non-blocking pre-cast workflow. Targeting, corpse dragging,
optional MQ2Nav movement, temporary spell memorization, spell/item/AA use, and
gem restoration each advance as bounded phases while worker heartbeats remain
live and the worker renews its lease. The coordinator still starts revocation
on heartbeat loss, incapacitation, or an eligible higher-tier urgent request.
The same Resurrection worker runs on every character and owns automatic
acceptance of a resurrection offer: dialog detection is read-only, while the
confirmation click is revalidated and issued only after this worker receives
the single action lease. The UI host never clicks the dialog automatically.
Corpse distance is validated against the selected resource before Actor election
or coordinator admission. Candidate discovery collects eligible EQ group
members first and then fresh members from the coordinator's Actor Team snapshot.
Selection evaluates the entire list: a corpse already inside the resource's
direct range wins over a corpse that would require navigation, so an unreachable
roster corpse cannot pin the worker while another eligible corpse is nearby.
The workflow does not issue `/corpse` for a target already inside the selected
resource's range, avoiding an unnecessary consent-dependent drag before rez.
Only OOC navigation candidates within `RezNavMaxDistance` may proceed when no
direct-range candidate exists. For Actor Team candidates, an exact locally
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
are the CC, Cures, and Debuff components hosted by `sk_combat.lua` or
`sk_support.lua`. The legacy `sk_cc.lua`, `sk_cures.lua`, and `sk_debuff.lua`
entry points remain component implementations and A/B profile workers.
`automation/meditation.lua` is a no-op shim;
`sk_meditation.lua` is the only meditation owner. Automatic spell-gem/scribing
work belongs to the separate `sk_scribing.lua` worker. `sk_disciplines.lua`
excludes mez and debuff predicates owned by those domain workers.

The Feign component inside `sk_combat.lua` is the sole automatic stand owner
while a Monk or Necromancer is feigning. `utils/feign_safety.lua` performs
read-only HP/group-support evaluation; Combat revalidates it after receiving
the action lease and only
then issues `/stand`. Every other worker withdraws or finalizes its intent while
managed feign is active so casting, movement, targeting, and implicit stand
paths cannot release the protected state. Recovery cleanup still runs first
when the coordinator has fenced an old lease.

The Assist component inside `sk_combat.lua` owns melee assist targeting and
positioning. Combat holds the one action lease for the entire owned episode,
so its DPS component cannot cast during that Assist episode.
`automation/assist.lua` is a helper library — it must not run automatic
assist actions from the UI host; the worker owns that.

Ranged Standoff is also an Assist component action. A fresh authorized Tank
primary admits its initial positioning before the local caster has entered
`CombatState=COMBAT`; the target-selection turn and subsequent Nav turn remain
separate leased mutations. Its toggle can activate this narrow component path
while Combat Mode is off; the underlying `CombatAssist` engine remains disabled
so standoff cannot enable attack or stick. Once planted, only crossing the
configured minimum distance requests another movement lease. The configured
retreat distance is a destination, not a maximum-radius trigger, so standoff
never moves a caster toward a distant primary.

`sk_chase.lua` is the dedicated out-of-combat chase worker. It uses
`automation/chase.lua` for read-only intent selection, records an exact target
fingerprint, and requests its fixed DPS-tier lease only when movement is
needed. A granted movement slice is bounded to 15 seconds. Stalls, start
failures, and timeouts use an exponential one-to-thirty-second requeue backoff,
with at most two recovery attempts per slice. Backend availability and Nav path
existence are checked read-only before requesting a lease; a character without
a usable Nav, MoveTo, or Stick route reports `no_movement_backend` and does not
churn the scheduler. Finalization stops Nav, MoveTo, follow/stick, and any held
movement keys before release. `/sk_chase status` reports the selected backend,
backend capabilities, active movement phase, failure streak, and backoff.
Chase is not a catch-all utility worker, and the UI host does not tick chase
movement. If a prior process leaves a valid chase ownership
marker, read-only inspection marks the worker dirty and the coordinator grants
a fenced recovery lease even when Chase is disabled or automation is paused.
Only that leased recovery path stops owned movement and clears the marker.

`sk_tank.lua` is the coordinated owner of tank-mode targeting, auto-attack,
positioning stick commands, tank emergency/defensive abilities, hate tools,
and reactive Taunt. Following the split-target model used by mature combat
automation, it keeps a stable primary kill target for Actor broadcasts while
using a separate temporary recovery target for a loose mob. Recovery completion,
failure, cancellation, ownership loss, pause, and incapacitation all stop Nav
and restore the primary target. The worker refreshes its primary broadcast once
per second so background assisters do not age out a still-valid target. A zero
primary is broadcast only when the state changes to hold; it is not refreshed
as a fleet-wide heartbeat. When no configured XTarget slot contains a nearby
live aggressive entry, Tank cancels an offensive episode, publishes that zero,
and performs no new tank combat action.

Runner handoff is separately toggleable and requires a non-named primary below
the configured HP threshold to exceed the configured outward movement rate.
Rate is normalized by elapsed sample time rather than assuming a fixed Lua tick.
The private working-target selector makes two passes: eligible unmezzed adds
first, then a mezzed add only when `TankBreakMez` permits it. The runner remains
the published kill target throughout the bounded handoff window. Runner
handoff is one long-lived Tank action, not a short engage followed by an
unowned movement effect: Tank retains its local action lease while Nav,
targeting, attack, or `/stick id` controls the private working target. Other
characters continue consuming the published runner ID, but the Tank
character's Combat worker cannot retarget or cast on the runner until the
handoff ends or a higher tier preempts it. Completion, timeout, cancellation,
and preemption stop a Stick only when `${Stick.StickTarget}` still matches the
working target, stop attack only while that target is still selected, restore
the published primary, and then release the lease.

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
erase that target telemetry. A fresh `target:primary` publication from the
authorized tank/assist authority carries both the declared ID and an explicit
`killAuthorized` bit. CC protects the declared ID immediately; offensive Combat
components require a positive ID plus `killAuthorized=true`. A fresh zero,
unverified declaration, stale/absent publication, invalid/dead spawn, or
protected charm ID means no new offense.
Exactly one character is selected as the fleet kill-intent authority. An
explicit `AssistMode=byname` selects `AssistName`; `raid1` through `raid3`
select the corresponding EQ raid assist. While raided, the default `group`
mode adopts Raid Assist 1, then falls back to Group Main Assist and Group Main
Tank. A second Tank-mode character may still peel and use hate tools locally,
but its `target:primary` packets cannot replace the selected assist's target.
When no EQ/configured authority exists, only the receiving character's own
Tank worker is accepted as a solo safety fallback.

An authenticated `sk_tank:sidekick` sender matching that selected authority is
admitted independently of Actor-Team membership. Worker-route authorization
reuses the script and actor parsed from MQ's canonical fully-qualified sender
mailbox; it does not reinterpret that qualified mailbox as a bare actor name.
`Raid.MainAssist` is a `raidmember`, so identity and chase/assist consumers
resolve its `Spawn` member before reading spawn-only fields. Generic peer state
still requires the configured Actor Team.
Same-zone and instance checks apply after admission.
The local diagnostic gateway keeps a bounded, last-event trace for
`target:primary`. It records receipt, transport rejection, topic rejection, or
successful state update together with the authenticated sender route, claimed
Tank ID, local EQ Main Tank/Main Assist identities, zone/team values, session,
sequence, and per-reason counts. The Coordinator window exposes this under
**Primary Target Transport**; `no_target_primary_packet` distinguishes routing
failure from an admission failure without enabling per-tick log spam.
The panel also shows the selected authority, its source, and assist mode.
`/sk_combat status` prints the trace from the actual offensive receiver
process, while `/sk_tank status` prints the source process's fleet-send
attempts and immediate Actor errors.
The consolidated Combat host uses configured Auto-Hater XTarget slot 1 only as
a cheap wake-up sentinel for its local heavy scan. A fresh Tank publication,
including a deliberate zero hold, remains authoritative and prevents damage
from following a tank's private peel or runner-handoff target. If no fresh
Tank publication exists, Combat may resolve only the selected Group/Raid/
by-name main assist's live target. This supports a non-tank raid main assist
without reopening XTarget/current-target/Actor-vote fallbacks. Team leader
election remains a presence responsibility and does not designate the combat
main assist.

GroupTarget's command bar shows an **MA** button only while raided. It invokes
`/sk_next_set_raid_assist <name>` locally and through the existing DanNet raid
command path. Each SideKick UI writes `AssistMode=byname`, the clicker's
character name, and the raid-override marker as the single settings writer for
its character; workers observe the resulting settings revision through the
coordinator. The write marks the selection as a
raid-scoped override. After `Raid.Members` remains empty for three seconds,
each UI persists `AssistMode=group` and clears the marker, returning target
resolution to `Group.MainAssist`. Manually choosing `byname` in settings clears
the marker and remains an ordinary persistent out-of-group configuration.

The charmer publishes its successfully established pet's spawn ID and an
`active` pet-slot bit through `cc:charmpet`. That same ID remains protected
while charm is holding and while the pet is loose during the recharm ladder; a
break does not clear it. Tank excludes the ID from primary selection and may
use explicitly damageless Taunt only while the protected pet is broken. A
recharm transition immediately cancels that Taunt and drains attack, Stick,
navigation, primary publication, and target state under Tank's current lease.
Simply targeting a protected pet does not activate Tank on a disabled or
non-tank character; only an enabled Tank can request a new protection lease.
Every offensive selector rejects the protected ID independently.
Protection is explicitly released only when the pet dies, recharm is abandoned,
or the recovery ladder has no usable charm step; a bounded heartbeat TTL
prevents a crashed owner from reserving an ID forever.

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

`sk_fidget.lua` is retained for future work but is not supervised or scheduled
in either worker profile. The Humanize fidget subsystem is forced off, so this
build does not emit idle camera, jump, strafe, window, pitch, or med-cycle
input.

`utils/actors_coordinator.lua` validates the v2 peer envelope before feature
dispatch, preserves validated sender provenance for local telemetry consumers,
and drains only a bounded number of queued messages per worker tick. Ordinary
workers publish a two-second same-role heartbeat; Support may publish faster
when health changes. Distributed claim consumers share
`utils/coordination_policy.lua`: an unknown first-contact peer remains usable
until the claim expires, but a previously observed peer fails closed while its
heartbeat is stale, unavailable, dead, outside the expected zone/team, or
otherwise inconsistent. Observed identity is retained longer than the UI's
fresh-status view so a crashed sender cannot briefly become “unknown” and
reactivate an outstanding claim.

`utils/runtime_cache.lua` is process-local. A consolidated domain ticks one
cache before evaluating its components, so Combat shares a single Group and
XTarget scan and Maintenance shares a single maintenance snapshot.
`isReady(section)` and the `getSelfSnapshot`, `getGroupSnapshot`, and
`getXTargetHaters` accessors return `cache_not_ready` before the owning process
has scanned that section; an empty list therefore means an actual empty scan,
not an uninitialized cache. Final action validation still reads live TLOs.

Every transport plane counts drops by reason. Coordinator state exposes
malformed packets, route/owner rejects, protocol rejects, stale sessions or
ticks, TTL/scheduler rejects, and queue overflow. Worker heartbeats include
their state-inbox drop map, the supervisor reports its acknowledgement inbox,
and the peer gateway exposes its reason map in transport diagnostics. Logging
of these counters occurs later from normal coroutines, never Actor callbacks.

Actor sender authentication uses `message.sender.mailbox`, which MacroQuest
returns as a fully-qualified address (`lua:script:actor`, with some builds also
reporting `script:actor`). MacroQuest does not expose a separate
`message.sender.script` field. `sk_lib.actorSenderMatches()` is the shared
parser and exact route check; coordinator state must originate from the
coordinator actor, worker control packets from that worker's actor, and peer
traffic from the `sidekick` actor.

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

Direct-damage learning is owned by `utils/spell_damage_tracker.lua`. It
correlates the DPS worker's `SpellEngine` terminal cast records with own-nuke
chat events in either arrival order. Resist learning consumes the resulting
baseline but does not own or gate damage samples; unresistable nukes therefore
learn normally. The UI receives correlation counters with DPS intelligence
telemetry so an empty catalog distinguishes no observed events from unmatched
events.

The buff worker adds locally visible `Spawn.Pet` candidates only when the
spell's target override is `pet` or its condition references
`BuffTarget.IsPet`. Ordinary group/default buffs therefore retain their
player-only candidate list. Pet candidates carry their own spawn ID and buff
state through the same target revalidation, duplicate-suppression, and leased
cast path as player recipients.

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

The coordinated healing sensor pass is read-only. Combat and mob assessment
may inspect current TLO state but must not issue `/mqtar`, `/consider`, or any
other gameplay command before lease admission. A future assessment that truly
requires a target-changing refresh must model that refresh as its own leased
action.

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
to the target's Support worker (the legacy profile routes to Resurrection).
The recipient grants `/consent` only when both names
belong to the same current team and the requesting rezzer is fresh; the request
is drained in the normal worker loop rather than the non-yieldable Actor callback.

## Actor callback safety

Actor callbacks perform only non-yielding envelope checks and bounded
copy/enqueue work. They must not read TLOs, call `mq.delay`, reload files,
target, cast, issue gameplay commands, or invoke other yielding code. Normal
coordinator/worker ticks consume the copied state, validate identity,
authorization, freshness, and sequence, and perform all yielding work.

## Adding a worker or domain component

1. Implement selection without game-changing side effects.
2. Prefer adding related behavior as a component of Support, Combat, or
   Maintenance. Add a new registry worker only when it needs an independent
   coordinator tier or lifecycle boundary.
3. Register a new worker once in `sk_lib.lua` with a fixed tier,
   deterministic order, script route, and any urgent-preemption/enable
   metadata. Register a component in its domain entry point instead.
4. Create a `ModuleBase` worker/component. Keep the selected action local, expose intent
   with `setIntent()`, and request a lease only while that action remains valid.
5. Include a stable idempotency key in the local action.
6. Call `enableUnifiedExecutor()` and provide hooks only for behavior the
   native spell/AA/disc/item/skill paths cannot represent.
7. Cross the final mutation boundary only after exact `ownsLease()` validation.
   Use `onLeaseFinalizing()` to stop or drain owned effects before every release,
   and mark dirty effects that require a recovery lease after a crash or timeout.
8. Confirm the UI host does not also initialize or tick the subsystem, update
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
priority. Worker and supervisor packets carry the shared lease protocol
version; mismatches are rejected and counted rather than silently accepted or
dropped. Callback ingress queues are bounded rings with oldest-entry eviction
and overflow telemetry. The plane is handled inside `sk_coordinator.lua`,
`sk_module_base.lua`, and
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

- `target:primary` — tank identity, declared primary, and verified
  `killAuthorized` state. The
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
