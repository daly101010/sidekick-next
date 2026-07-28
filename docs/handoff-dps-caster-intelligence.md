# Handoff: DPS Caster Intelligence + Group Coordination

**Branch:** `claude/dps-caster-automation-tt0fic` (all work committed and pushed)
**Date:** 2026-07-23

This document summarizes everything built in this session so a local session can
continue where it left off — including the pending work that needs local repos
(99ui, group) that weren't available remotely.

---

## 1. What was built (by commit)

### `14fc54a` — Time-to-die (TTD) intelligence
The core fix for "% HP is the wrong currency for DPS decisions."
- **Bug fix:** `healing/combat_assessor.lua` treated `mq.gettime()` (ms) as
  seconds — measured mob TTK never had samples. Fixed; healing HoT/Promised TTK
  gates now get real data. Public `getMobTTKById(mobId)` added.
- **`utils/dps_intelligence.lua`** (new): `getTTD(mobId)` (measured TTK, else
  `pctHP * 0.5 * mobAssessorMultiplier` heuristic), `willLive`, `nukeViable`
  (TTD > cast + `DpsNukeLandMargin`), `dotViable` (TTD > duration ×
  `DpsDotBreakevenPct`). All fail open with no data; master toggle
  `UseDpsIntelligence`.
- **`utils/resist_tracker.lua`** (new): per-zone/mob/element landed-vs-resisted
  counters, fed by a new `SpellEngine.onCastComplete` chain hook +
  pending-attempt correlation with resist events. `shouldAvoid()` steers
  element choice. Persists to `SideKick/data/resist_tracker.lua`.
- `ctx.target` gains `ttd()`, `willLive(s)`, `nukeViable(castSec)`,
  `dotViable(durSec)` (utils/condition_context.lua). WIZ nukes and NEC DoTs
  converted (`data/class_configs/WIZ.lua`, `NEC.lua`). MAG/DRU/SHM not yet
  converted (trivial follow-up — same helpers).

### `9d31645` — Absolute HP estimation, partial resists, rain timing
- **`utils/damage_events.lua`** (new): parses OUTGOING damage chat (own nukes,
  DoT ticks, all group melee verbs, DS) and dispatches to listeners.
- **`utils/mob_hp_estimator.lua`** (new): `maxHP ≈ damage / pctDelta`,
  delta-weighted, per mob name, persisted per zone
  (`SideKick/data/mob_hp_estimates.lua`). `getMaxHP` / `getRemainingHP`.
- **`utils/spell_damage_tracker.lua`** (new): learns each spell's typical/max
  hit per character (`spell_damage_<server>_<char>.lua`). The tracker directly
  correlates own-nuke chat with `SpellEngine` completion in either arrival
  order; resist tracking consumes its baseline but no longer gates learning.
- **Overkill check:** `overkillOk(mobId, spellName)` — skip a nuke whose
  expected damage > remaining HP × `DpsOverkillFactor` (falls through to
  smaller nukes in rotation order).
- **Partial resists:** landed nuke damage vs spell baseline → per-mob/element
  efficiency average; `shouldAvoid()` also triggers below
  `ResistMinEfficiencyPct`.
- **Rain timing:** `rainViable()` = cast + margin + `DpsRainPayoffSec`.

### `dd5d10c` — Mob intel database + export
- **`utils/mob_intel.lua`** (new): per-zone/mob store of CC susceptibility
  (slow/snare/mez/charm/root/stun/fear: landed/resisted counts + immune flags
  from typed immunity messages), NPC casts observed ("X begins casting Y"),
  mob level, contributing classes. `getCCStatus()` ready for future CC
  automation.
- **`/skmobintel export`** merges mob_intel + resist tracker + HP estimator →
  `SideKick/export/mob_intel.csv` (Sheets-importable) and `.json` (versioned
  envelope `format: sidekick-mob-intel, version: 1` — the seam for the future
  Google Sheets sync). `/skmobintel mob [name]` prints what's known.
- **Future sync plan discussed:** MQ has lua-curl/luasocket, so the script can
  POST the JSON to a Google Apps Script web-app endpoint directly; counts-based
  schema chosen so multi-contributor merges are just sums.

### `db16fa3` — Caster/ranger standoff positioning
- `automation/caster_assist.lua`: when closer than `CasterStandoffMin` (35) in
  combat, nav once to a randomized spot at the configured retreat radius
  (`CasterStandoffMax`, default 60) on the character's own side of the mob.
  Being farther away never pulls the caster toward the mob. Desync =
  name-hash base angle (±45°) + per-move seeded RNG jitter; candidates
  validated for nav-mesh reachability + LoS; never
  interrupts a cast; `spell_engine` defers timed casts (reason
  `repositioning`) while moving. Rangers route here when
  `CasterStandoffEnabled`. Pure casters never use melee stick movement.

### `ccbb010` + `6959ae5` — Rain spell-set conditions + mez safety
- `isRainSpell()`: EQ `Rain` subcategory, fallback Targeted AE + AEDuration>0.
- Spell-set default condition for rains: `InCombat AND Target NPC AND
  XTargetHaterCount >= 3` (was raw HP%). Editable per spell in condition
  builder.
- **Mez safety** (`rainSafe`, from Calbus' MuleAssist config
  `SpawnCount[npc radius 35 loc target] == 1`): `DpsRainSafetyMode` =
  `mezzed` (default — block only if a mezzed XTarget mob is inside the rain
  radius), `solo` (exact MuleAssist parity), `off`. Radius from spell AERange
  else `DpsRainSafetyRadius`. In both cast paths + `ctx.target.rainSafe()`.

### `7cfb794` — Six group-intelligence features
1. **Death forensics** (`utils/death_forensics.lua`): 30s rolling black box
   (incoming damage via new `damage_parser.addListener`, my casts, member
   vitals 1/sec). Death → report in `SideKick/logs/deaths/` + chat summary.
2. **Session stats** (`utils/session_stats.lua`): `/sksession` (XP/hr with
   level-ups, kills/hr, per-member DPS by active seconds, deaths,
   casts/resists/mana efficiency), `export` (CSV incl. per-spell damage),
   `reset`.
3. **Tank auto-peel** (`utils/aggro.lua findPriorityPeelTarget`): reactive
   taunt ranks loose mobs by victim fragility CLR=6 DRU/SHM=5 ENC/WIZ/MAG/NEC=4
   RNG/BST/BRD=3 PAL/SHD=2 melee=1.
4. **Tank flee-handoff** (`sk_tank.lua updateFleeHandoff`): target ≤
   `TankFleeHpThreshold` and gaining distance + another add available → runner
   excluded from tank targeting (`selectBestTarget` gained `excludeId`) for
   `TankFleeHandoffWindowSec`; sticky-mode assisters finish it.
5. **Pull-landing pre-heal** (`healing/pull_monitor.lua` + healing/init.lua
   priority 1.5): XTarget-based inbound detection (works with non-sidekick
   bard puller), closing-rate ETA; HoT pre-cast on tank inside
   `PrePullHotEtaSec` window; big HoT if mob multiplier ≥ `PrePullHotBigMult`.
6. **Readiness coordinator** (`utils/readiness.lua`, opt-in
   `ReadinessEnabled`): class-aware hp/mana/end readiness across sidekick
   members from actors payloads; members without actor data never block
   (Medley bard). One deterministic announcer posts `<< READY to pull >>` to
   `/g`. `/skready` prints breakdown.

### `2c62f66` — Togglability + `/skset`
All features registry-backed (see settings table below). **`/skset <Key>
[value]`** — generic validated in-game setter for any registry setting; bare
bool key toggles; persists via `Core.set`.

### `c6c5dd3` — Tank-as-observer delegation (perf)
- **`DamageObserver`** setting (`auto`/`always`/`never`): third-person damage
  patterns (~18, the bulk of group combat spam) register only on the tank in
  `auto`. Own-damage patterns always register (personal signals).
  `ensureScope()` re-registers live on mode change.
- Observer broadcasts engaged mobs' HP estimates (`mobhp:update`, 2s);
  lean characters' `getMaxHP()` falls back to them (30s expiry).
- Pull monitoring delegated: `tank.tickPullBroadcast` (only tank scans,
  broadcasts `pull:incoming` 1/sec while inbound + one idle clear); healers
  consume, local scan only if no active sidekick tank.
- Caveat: per-member DPS in session stats is only complete on the observer.

---

## 2. Actors message contracts added this session

All on mailbox `sidekick`, zone-filtered, `fromMe`-filtered:

| id | direction | payload | getter |
|---|---|---|---|
| `pull:incoming` | tank → group | `phase ('inbound'/'idle'), mobId, mobName, eta, mult, dist, zone` | `Actors.getPullState()` (nil if >4s stale) |
| `mobhp:update` | observer → group | `estimates = { [mobName] = {maxHP, weight} }, zone` | `Actors.getRemoteMobHp(name)` (30s expiry) |

Existing (pre-session): `status:update` (hp/mana/endur/class/buffs/abilities,
5Hz change-deduped — see `actors/shareddata.lua buildStatusPayload`),
`target:primary`, `target:aggro`, `taunt:run/done`, heal claims/HoT states.

## 3. NEXT UP (needs local repos): centralized vitals hub

User direction: **one character (the tank) does the TLO data aggregation; the
rest of the group AND the other UI scripts (99ui, group/GroupTarget) feed off
the tank's actor data** instead of 3 scripts each polling
`Group.Member(i).PctHPs/PctMana/PctEndurance` per frame.

Agreed design (discussed, NOT yet implemented):
- Define a versioned consolidated message `vitals:group` (v1): one payload with
  all members' hp/mana/endur/level/class/casting/sitting, ~5Hz change-driven.
  The contract is the interface — publisher can later move to a standalone hub
  script without touching consumers.
- Publisher: tank's coordinator tick (data already in RuntimeCache /
  status payloads — this mostly consolidates per-character messages into one).
- Consumers: 99ui and group scripts subscribe (actors `register`), drop their
  own `Group.Member` polling, keep a poll fallback when no fresh feed (<2s).
- **Exception:** healers keep direct `target_monitor` polling for heal
  decisions — actor relay latency (100–400ms) is too much for emergency heals.
  The hub is for UIs and non-healer consumers.
- The 99ui + group repos live locally (F:/lua). Their polling sections need
  converting; sidekick side needs the `vitals:group` broadcast added to
  `utils/actors_coordinator.lua` (mirror `broadcastMobHp` pattern) fed from
  `actors/shareddata.lua` / RuntimeCache group data.

## 4. Other deferred items
- **Zone-aware spell loadout advisor** (auto fire/ice set from learned resist
  data) — user wants element data proven in play first.
- **CC priority + kill-order broadcast** from mob_intel — deferred until
  current features tested.
- **MAG/DRU/SHM/ENC class configs** — convert damage conditions to
  `nukeViable`/`dotViable` helpers (pattern: see WIZ/NEC).
- **Google Sheets sync** — `/skmobintel sync` POSTing the JSON envelope via
  lua-curl to an Apps Script endpoint; trust/weight-capping for community data.
- **Calbus' MuleAssist config** — user was going to provide more of it from
  `F:/config` for further condition parity (rain condition already done).

## 5. Settings added this session (all `/skset`-able)

DPS: `UseDpsIntelligence`, `DpsNukeLandMargin` (1.0), `DpsDotBreakevenPct`
(50), `DpsDefaultNukeCastTime` (3.0), `DpsDefaultDotDuration` (24),
`DpsOverkillFactor` (1.5), `DpsRainPayoffSec` (4), `DpsRainSafetyMode`
(mezzed), `DpsRainSafetyRadius` (35).
Resists: `UseResistTracker`, `ResistAvoidPct` (50), `ResistMinSamples` (4),
`ResistMinEfficiencyPct` (35).
Standoff: `CasterStandoffEnabled` (off), `CasterStandoffMin` (35),
`CasterStandoffMax` (60).
Tank: `TankAutoPeel`, `TankPeelMinPriority` (1), `TankFleeHandoff`,
`TankFleeHpThreshold` (20), `TankFleeHandoffWindowSec` (15), `TankFleeMinAdds`
(2).
Healer: `PrePullHotEnabled`, `PrePullHotEtaSec` (8), `PrePullHotBigMult` (2.0).
Readiness: `ReadinessEnabled` (off), `ReadinessAnnounce`, `ReadyHpPct` (90),
`ReadyManaPct` (80), `ReadyEndPct` (50).
Perf: `DamageObserver` (auto). Misc: `DeathForensicsEnabled`.

Commands: `/skset`, `/sksession [export|reset]`, `/skmobintel [export|mob]`,
`/skready`.

## 6. Verification status
- No test suite in repo; all pure logic covered by throwaway LuaJIT smoke
  harnesses during development (~140 assertions total, stubbed `mq`) — not
  committed. All files parse under LuaJIT (note: MQ's LuaJIT accepts
  `::label::` after `return`; stock LuaJIT doesn't — false positive when
  linting `spell_rotation.lua` outside MQ).
- **Nothing has run in-game yet.** First-run watch list:
  - Combat assessor TTK fix changes healing HoT/Promised gating behavior
    (it was silently using a crude fallback before).
  - Chat event patterns vs your server's exact message strings (damage_events
    verbs, mob_intel immunity lines, session_stats slain lines).
  - Flee detection distance heuristic vs actual mob flee speed.
  - Pre-pull ETA window vs puller speed; standoff min distance vs rain radius.
  - `healing/init.lua` pre-pull block assumes the healing tick body runs while
    out of combat — verify the pre-pull log line (`18a-PrePullHot`) appears.
