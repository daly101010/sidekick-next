# Resurrection Module — Design

**Date:** 2026-04-28
**Status:** Approved (sections 1-4)
**Implementer next step:** see writing-plans skill / impl doc

## Context

The coordinator already exposes a `RESURRECTION = 2` priority slot
([sk_lib.lua:15](../../sk_lib.lua)) and yields it when `deadCount > 0`
([sk_coordinator.lua:177-179](../../sk_coordinator.lua)), but no module
listens on that priority — so the priority gets routed to nothing and dead
group members never get rezzed automatically. The class data is also already
in place (rez spell lines in [sk_spells_clr.lua:507-514](../../sk_spells_clr.lua)
and [data/class_configs/CLR.lua:332](../../data/class_configs/CLR.lua)). The
2026-01-22 cleanup removed `DoCombatRez` / `DoOutOfCombatRez` settings
because they had no implementation backing.

This design adds the missing module + UI + data so dead group members get
auto-rezzed when sidekick-next runs on a rez-class character.

## Scope

- **Group only** — never rezzes raid members, strangers, or pets.
- **Classes supported:** CLR, DRU, SHM, PAL, NEC.
- **First-to-cast wins** — no cross-box claim arbitration. The EQ engine
  serializes (the second cast hits an already-rezzed corpse and fails
  harmlessly).
- **Auto-accept** — every character (rez-class or not) auto-accepts rez
  offers it receives, gated by a setting.
- **Out of scope:** raid rez, AE rez, Necromancer rez-self-pet flows, manual
  slash commands, dashboard UI, actor request API. (User explicitly chose
  "Settings panel toggles" as the only surface.)

## Components

### New files

#### `sk_resurrection.lua` — priority-2 module
Follows the existing `sk_module_base` pattern — same shape as
[sk_emergency.lua](../../sk_emergency.lua). Auto-launched at SideKick
startup only for rez classes (gated on `mq.TLO.Me.Class.ShortName()`
match against the class set above).

Module callbacks:
- `shouldAct(self)` — returns true iff:
  - `state.activePriority == RESURRECTION`
  - configured to act for current combat state (`AutoRezOOC` if OOC,
    `AutoRezInCombat` if in combat)
  - a dead group member exists with a findable corpse spawn
  - that corpse isn't suppressed in `_lastAttempt[corpseId]` (10s window)
  - in combat: AA `Blessing of Resurrection` (or class equivalent) is ready
- `getAction(self)` — returns `{ kind, name, targetId, idempotencyKey }`
  picking the best-available rez line (OOC) or the AA (in combat).
- `executeAction(self)` — see "Cast sequence" below.

#### `utils/rez_data.lua` — per-class rez tables
```lua
local M = {}
M.spells = {
    CLR = { 'Resurrection', 'Reviviscence', 'Resuscitate', 'Restoration', 'Revive', 'Reanimation' },
    DRU = { 'Reviviscence', 'Reanimation' },
    SHM = { 'Incarnate Anew', 'Renewal of Life', 'Reviviscence' },
    PAL = { 'Wake the Dead', 'Reviviscence' },
    NEC = { 'Convergence', 'Reanimation' },
}
M.aas = {
    CLR = 'Blessing of Resurrection',
    -- DRU/SHM/PAL/NEC: no instant-rez AA equivalent; battle-rez only fires
    -- on classes that have one.
}
function M.getSpells(classShort) return M.spells[classShort] or {} end
function M.getAA(classShort) return M.aas[classShort] end
return M
```

Best-available picking: walk the class list and pick the first spell where
both `mq.TLO.Me.Book(name)()` (learned) and `mq.TLO.Me.Gem(name)()`
(currently memorized) are true. **v1 does not auto-memorize**: if no rez line
is currently in a gem slot, the module logs once per corpse and skips.
Players who want auto-rez are expected to keep their preferred rez line
memorized in their normal spell set. (Memorize-on-demand can be added later
without disturbing this contract — see "Out of scope" below.)

#### `utils/rez_accept.lua` — auto-accept watcher
Registers an MQ event on the rez-offer chat line:
```
mq.event('SideKick_RezOffer',
  '#1# is attempting to resurrect you. Do you wish to be revived?',
  function(_, casterName) handler(casterName) end)
```
Handler runs on every character (not just rez classes) and, if
`AutoAcceptRez=true`, fires:
```
mq.delay(300)
mq.cmd('/notify ConfirmationDialogBox Yes_Button leftmouseup')
```
The 300ms delay gives the dialog time to actually open after the chat line.
Failsafe: a 1Hz poll of `mq.TLO.Window('ConfirmationDialogBox').Open()` with
title-text inspection covers cases where the chat line is suppressed.

Lives in the always-running [SideKick.lua](../../SideKick.lua) main loop —
`mq.doevents()` already drains events per tick.

### Files modified

#### `registry.lua`
Three new settings keys, all `Category = 'Heal/Rez'`, alongside the existing
heal/rez entries (~lines 170-250):

| Key | Type | Default | DisplayName |
|---|---|---|---|
| `AutoRezOOC` | bool | true | Auto-Rez Out of Combat |
| `AutoRezInCombat` | bool | false | Auto Battle-Rez (AA only) |
| `AutoAcceptRez` | bool | true | Auto-Accept Rez Offers |

#### `ui/settings/tab_healing.lua`
The live Settings UI lives here (the old `ui/settings.lua` is dead code
overshadowed by `ui/settings/init.lua` — was edited initially by mistake,
later reverted). Add a "Resurrection" `Components.SettingGroup.section`
after the "Cures" section, using the same `Components.CheckboxRow.draw` +
`onChange` pattern as the surrounding rows. The Healing tab is gated to
healer classes (CLR/DRU/SHM/PAL) by [SideKick.lua:1325](../../SideKick.lua),
so NEC characters don't get a UI surface — they keep the default behavior
(auto-OOC on, auto-in-combat off, auto-accept on). Documented as a future
follow-up below.

#### `SideKick.lua`
- Always-on init of `rez_accept` (every character).
- Class-conditional auto-launch of `sk_resurrection` (only rez classes).
  Mirrors how other priority modules are started.

### No changes
- `sk_coordinator.lua` — already counts `deadCount` and yields RESURRECTION.
- `sk_lib.lua` — priority slot already defined.
- `data/class_configs/CLR.lua` — rez data already there (kept for future
  per-class overrides; module reads class-agnostic data from
  `utils/rez_data.lua`).

## Behavior matrix

| Situation | `AutoRezOOC` | `AutoRezInCombat` | What `sk_resurrection` does |
|---|---|---|---|
| OOC, group corpse in zone, rez learned | true | — | Mem-swap if needed → cast sequence below. |
| OOC, group corpse out of drag range or not in zone | true | — | Skip. One log line per corpse, suppressed for 10s. |
| OOC | false | — | Nothing (priority routed to no-op). |
| Combat, class-AA ready | — | true | Fire AA. Modern Blessing of Resurrection has a real ~5s cast time, not instant — toggle is opt-in. |
| Combat, AA on cooldown | — | true | Skip. **Never spell-rez during combat.** |
| Combat | — | false | Nothing during fight. Cleanup on next OOC tick. |
| Rez offer dialog open | — | — | If `AutoAcceptRez=true`, auto-click Yes. |

## Cast sequence (in `executeAction`)

1. `/target id <corpseId>` and verify target.
2. `/corpse` — pulls a consented (group) corpse to the rezzer's feet.
3. Wait ~300ms for the drag.
4. Re-verify corpse distance is in cast range. If still out of range, abort
   + log + 10s suppression cache.
5. `/cast "<rez spell>"` (OOC) or `/alt activate "<class AA>"` (battle-rez).
6. Wait for cast bar to complete or fail, capped at the spell's cast time +
   2s safety margin.
7. Release claim. Update `_lastAttempt[corpseId] = now`.

## Edge cases

- **Dead member, corpse not in zone:** member is at bind in another zone.
  Skip + log once.
- **Dead member, corpse in zone but >drag range:** out of `/corpse` reach.
  Skip + log once.
- **Two clerics decide simultaneously:** both cast. First-landing rez takes
  the corpse. Second cleric's cast aborts on "target invalid" and the local
  10s cache prevents retry. (Per first-to-claim-wins user choice.)
- **Cast bar interrupted (stun, push):** module releases claim with
  reason='interrupted'. 10s suppress prevents thrash.
- **Re-trigger guard:** `_lastAttempt[corpseId]` keyed by spawn ID
  (corpses are unique spawns per death event), TTL 10s. Cleared on
  successful rez (target gone).
- **Auto-accept when at bind:** the dead character may already be at bind
  when the rez offer arrives. Auto-accept still works — the dialog appears
  whether you're at corpse or bind.

## Data flow

```
Coordinator updateWorldState() — counts dead group members [existing]
    ↓
Coordinator computeActivePriority() — yields RESURRECTION when deadCount > 0 [existing]
    ↓
sk_resurrection.tick() — sees state.activePriority == RESURRECTION [existing base class]
    ↓
shouldAct() — gates on settings + corpse availability + AA/spell readiness [new]
    ↓
getAction() — picks best rez spell or AA, returns claim payload [new]
    ↓
Coordinator grants claim (cast + target ownership) [existing]
    ↓
executeAction() — /target, /corpse, /cast or /alt activate, await cast [new]
    ↓
releaseClaim() [existing base class]

In parallel, on every box:
mq.event('SideKick_RezOffer', ...) — fires when corpse receives offer [new]
    ↓
If AutoAcceptRez=true: /notify ConfirmationDialogBox Yes_Button leftmouseup
```

## Verification

1. With one cleric box: kill a group member, run sidekick-next on both. After
   combat ends, cleric should auto-cast Resurrection on the corpse (after a
   `/corpse` drag). Dead member's box should auto-accept. Group member
   stands up.
2. With two cleric boxes: same setup, both clerics see corpse. Both start
   casting. First to land wins; second hits "target invalid" and silently
   gives up.
3. Toggle `AutoRezOOC` off in settings: kill member, observe no rez fires.
   Toggle back on: rez fires within ~1s of OOC transition.
4. Battle-rez: enable `AutoRezInCombat`, kill member during a long fight.
   Cleric should fire Blessing of Resurrection AA the moment its cooldown
   permits; should NOT spell-rez during the fight.
5. Auto-accept off: rez fires from another cleric, dialog stays open until
   user clicks. Manually re-enable; second test confirms auto-click resumes.

No formal unit tests — sidekick-next has no test harness for behavior
modules. Verification is in-game.

## Out of scope (revisit later if needed)

- Cross-box rez_claim coordination (currently first-cast-wins via EQ
  engine).
- Per-character rez priority (settings expose nothing today).
- Auto-nav to corpse if out of `/corpse` drag range.
- Memorize-on-demand for rez spells (gem-swap before cast). v1 requires
  rez to be already in a gem slot.
- UI surface for NEC rez settings. The Healing tab is healer-class-only;
  NEC characters get the rez module's default behavior but no toggles.
  Could be addressed by extending the Healing tab visibility to all rez
  classes, or adding a separate "Utility" tab.
- Manual slash commands (`/sidekick rez <name>`).
- Dashboard "Dead: N" indicator.
- Actor message API for "rez me" requests from other boxes.
