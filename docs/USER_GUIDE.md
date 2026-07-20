# SideKick-Next User Guide

A comprehensive automation framework for EverQuest via MacroQuest. SideKick provides intelligent class-specific automation, multi-character coordination, and a fully customizable ImGui interface.

**Supported classes:** BER, BRD, CLR, DRU, ENC, MAG, MNK, NEC, PAL, RNG, ROG, SHD, SHM, WAR

---

## Table of Contents

- [Part 1 - User Guide](#part-1---user-guide)
  - [Installation](#installation)
  - [Quick Start](#quick-start)
  - [UI Tour](#ui-tour)
  - [Configuration](#configuration)
  - [Automation Control](#automation-control)
  - [Class-Specific Features](#class-specific-features)
  - [Multi-Box Coordination](#multi-box-coordination)
  - [Commands Reference](#commands-reference)
- [Part 2 - Architecture Guide](#part-2---architecture-guide)
  - [System Overview](#system-overview)
  - [Startup Flow](#startup-flow)
  - [Priority Coordinator](#priority-coordinator)
  - [Main Loop](#main-loop)
  - [Healing Intelligence Pipeline](#healing-intelligence-pipeline)
  - [Actors Communication](#actors-communication)
  - [Spell Execution Flow](#spell-execution-flow)
  - [Module Architecture](#module-architecture)
  - [Settings Data Flow](#settings-data-flow)
- [Part 3 - Reference](#part-3---reference)
  - [Settings Reference](#settings-reference)
  - [Priority Tiers](#priority-tiers)
  - [File Map](#file-map)
  - [Glossary](#glossary)

---

# Part 1 - User Guide

## Installation

### Prerequisites

- **MacroQuest** (latest build) with Lua plugin enabled
- **MQ2DanNet** plugin loaded (for cross-character queries)
- **MQ2Nav** plugin recommended (for chase/navigation)

### File Placement

Place the `sidekick-next` folder in your MacroQuest `lua` directory:

```
MacroQuest/
  lua/
    sidekick-next/
      init.lua
      SideKick.lua
      registry.lua
      ...
```

### First Run

Log into EverQuest and type:

```
/lua run sidekick-next
```

The main window and ability bars will appear. Settings are auto-saved to:
```
<MQ Config Dir>/SideKick-Next/config/Server_CharacterName/<module>.ini
```

On the first run after upgrading, SideKick-Next imports the matching production
SideKick configuration into independently persisted module files. The combined
INI remains a read-only migration source. Every registered setting has one
declared module owner, each module file has one writer, and every save retains a
last-known-good `.bak`. On upgrade, settings found in the wrong module file are
moved to their registered owner before the files are combined.

## Quick Start

1. **Launch**: `/lua run sidekick-next` (or `/sidekick` if already running to toggle the window)
2. **Open settings**: `/sidekick settings` or click the cog icon
3. **Pick your theme**: Options > UI > General
4. **Confirm automation is not paused**: turn off the Pause button on the main bar
5. **Enable assist**: Options > Automation > Combat Mode, select `assist`, then choose the assist source
6. **Enable chase**: Options > Automation > Chase, then select MA, MT, Leader, a raid assist, or a named character

That's the minimum to get an automated character following and assisting.

## UI Tour

SideKick renders several ImGui windows, each independently positionable and anchorable.

### Main Bar

The primary ability bar showing your class's AAs, disciplines, and spells as icon buttons.

- **Cooldown overlays**: Grayed-out icons with timer countdown
- **Ready pulse**: Glowing animation when an ability comes off cooldown
- **Click to activate**: Left-click fires the ability
- **Hover tooltip**: Shows ability name, reuse time, and current state
- **Layout**: Configurable rows (1-6), cell size (32-120px), gap, and padding

### Special Bar

Class-specific special abilities displayed separately from the main bar. Berserker disciplines, tank defensives, etc. Supports single-row, single-column, or grid layouts.

### Disc Bar

Discipline-specific bar for melee/tank classes. Shows active and available disciplines with cooldown tracking.

### Item Bar

Clickable items (clicky gear) with cooldown tracking. Configure its contents under Options > Items and its layout under Options > UI > Item Bar.

### Skill Bar

Learned combat skills displayed as buttons with readiness and cooldown state. Configure visibility and layout under Options > Buttons > Skills.

### Settings Window

The SideKick Options window contains top-level Buttons, Options, Spell Set,
Healing or Resurrection, Items, and Buffs surfaces. The nested Options surface
contains modular UI, Automation, Resurrection, Integration, Animations,
Humanize, Pull, Remote, and diagnostic tabs.

### Healing Monitor

Real-time display of the healing intelligence system showing:
- Current heal targets and predicted incoming heals
- Combat assessment (fight phase, damage rate, survival risk)
- Heal efficiency analytics (overhealing %, casts per minute)
- HoT tracking across characters

Open with: `/sidekick healmonitor`

### Aggro Warning

Overlay that flashes when you have aggro above the configured threshold.

## Configuration

Settings are split between top-level feature tabs and the modular tabs inside
Options. Diagnostic tabs appear when their modules load successfully, so the
exact tab count is intentionally not fixed.

### UI Tab

Controls visual appearance and window positioning.

| Setting | Purpose |
|---------|---------|
| Theme | Color scheme: Classic, ClassicEQ, ClassicEQ Textured, Dark, Neon |
| Sync Theme with GT | Match theme to GroupTarget window |
| Manual Move/Resize | Allow dragging windows freely |
| Button Scale | Scale factor for all buttons (0.5x - 3.0x) |
| Font Scale | Scale factor for text (0.5x - 3.0x) |

Ability, Special, Discipline, Item, and Skill bars have dedicated layout controls with:
- **Cell size**: Button dimensions in pixels
- **Rows**: Number of rows in the grid
- **Gap / Padding**: Spacing between and around buttons
- **Background Alpha**: Bar background transparency (0 = invisible, 1 = opaque)
- **Anchor**: Snap to another window (none / left / right / above / below)
- **Anchor Target**: Which window to snap to (most bars default to `grouptarget`; Skill defaults to `none`)
- **Anchor Gap**: Pixel spacing from the anchor target

### Automation Tab

Controls all automated behaviors.

**Chase Section**
| Setting | Default | Purpose |
|---------|---------|---------|
| Enabled | off | Toggle chase automation |
| Role | MA | Who to follow: MA, MT, Leader, Raid1-3, or by name |
| Target | (empty) | Character name if Role = byname |
| Distance | 30 | Units to maintain from chase target |

**Combat Mode Section**

`CombatMode` is the single role and enable control. Select `off`, `tank`, or
`assist`; the main-bar Assist button is only a shortcut for this same setting,
not a second persisted gate.

**Assist Settings** (shown when Combat Mode is `assist`)

| Setting | Default | Purpose |
|---------|---------|---------|
| Assist Source | group | Fallback source: group, raid1-3, or byname |
| Assist Name | (empty) | Character name if Assist Source = byname |
| Target Mode | sticky | Keep the selected target until dead or follow tank switches |
| Engage Condition | hp | Engage by HP threshold or after the tank has aggro |
| Engage HP | 97% | Target HP% to start attacking when using the HP condition |
| Assist Range | 100 | Maximum fallback assist range |

**Meditation Section**
| Setting | Default | Purpose |
|---------|---------|---------|
| Mode | off | `off`, `ooc` (out of combat only), or `always` (in and out of combat) |
| HP Start/Stop | 70% / 95% | HP range that triggers sit/stand |
| Mana Start/Stop | 50% / 95% | Mana range that triggers sit/stand |
| End Start/Stop | 60% / 95% | Endurance range that triggers sit/stand |
| Aggro Check | on | Prevent sitting if aggro exceeds threshold |
| Aggro Threshold | 95% | Stand up if aggro exceeds this |
| Post-Combat Delay | 2s | Wait time after combat before sitting |

**Burn Section**
| Setting | Default | Purpose |
|---------|---------|---------|
| Duration | 30s | How long burn mode stays active |

### Healing Tab

For **Clerics, Druids, Shamans, and Paladins**, this opens Healing Intelligence
(see [Healing Intelligence](#healing-intelligence)). The main Healing toggle is
stored as `DoHeals`; pet healing, HoT behavior, heal selection thresholds,
incoming-heal coordination, and analytics are stored in the character's
`healing/config_<Server>_<Character>.lua` file and edited under Advanced Healing
Settings.

The older `MainHealPoint`, `BigHealPoint`, `GroupHealPoint`, `GroupInjureCnt`,
`HealUseHoTs`, and `HealCoordinateActors` registry keys remain only for
compatibility with the retired tiered healer. They are not the active controls
when Healing Intelligence is available.

### Resurrection

Rez-capable classes (CLR, DRU, SHM, PAL, and NEC) have resurrection settings
under **Options > Resurrection**. Healer classes can also reach the same
controls near the bottom of **Healing > Settings**. NEC receives the dedicated
resurrection surface without loading Healing Intelligence.

OOC and combat behavior are configured separately:

| Setting | Default | Purpose |
|---|---:|---|
| Auto-Rez Out of Combat | on | Enable group-corpse rez after combat |
| OOC Method | Auto | Auto, Spell, or configured Item |
| Auto-Rez In Combat | off | Allow combat rez attempts |
| Combat Method | Auto | Auto, AA, already-memorized Spell, or Item |
| Combat Target Classes | All | Restrict combat rez to selected classes |
| Rez Item Name | empty | Exact inventory item name to use for Item/Auto |
| Auto-Memorize OOC Rez Spell | on | Temporarily memorize the best learned rez spell |
| Temporary Gem | 0 | Gem used for rez; zero means the final gem |
| Restore Replaced Gem | on | Restore the prior gem after the attempt or restart |
| Coordinate via Actors | on | Elect one rezzer per corpse |
| Rezzer Priority | 50 | Lower number wins; name breaks exact ties |
| Navigate to OOC Corpses | off | Use MQ2Nav for an out-of-range corpse |

Auto mode prefers a configured, ready item. In combat it then tries the
class battle-rez AA and an already-memorized spell. Out of combat it falls
back to the best learned spell and may memorize it on demand. SideKick never
auto-memorizes or starts corpse navigation during combat.

The worker targets and drags only group-member corpses. Its Actor intent is
short-lived and deterministic, so a failed or disconnected primary rezzer
automatically yields to the next eligible character.

### Buffs Tab

Configure out-of-combat buff automation and each spell's condition and target.
Pet-only buffs are controlled by their spell profiles; there is no global
pet-buff switch. Actor claims prevent duplicate work automatically.

### Spell Sets and Manual Memorization

When SideKick is idle and out of combat, a manual gem change is adopted into
the active spell set shortly after the spellbook closes. SideKick saves the new
layout instead of restoring the old gem on the former 30-second watchdog.

Automation settings are archived by spell ID. If a configured spell is removed
and later memorized manually or dragged back into any combat gem, its condition,
priority, buff target, and utility flags are restored. A spell that has never
been configured receives the normal generated defaults.

If the set has OOC buffs, the final gem remains reserved for buff hot-swapping;
manual changes to that reserved gem are intentionally not adopted.

### Items Tab

Select which clickable items appear in the Item Bar.

### Integration Tab

| Setting | Default | Purpose |
|---------|---------|---------|
| Actors Enabled | on | Publish UI peer/status data and expose Actor integration controls |
| Enable Team Presence | on | Publish coordinator presence to the current Actor team |
| Team Mode | auto | Choose raid, group, solo, or a shared manual team |
| Team Name | empty | Case-insensitive team name used only in manual mode |

In coordinated mode, the local coordinator/worker Actor transport remains
active even if Actors Enabled is switched off. Use the feature-specific
coordination settings, such as resurrection coordination, to control those
behaviors. Actor Team presence has its own Enable Team Presence switch.

### Animations Tab

Toggle individual UI animation effects:
| Animation | Default | Description |
|-----------|---------|-------------|
| Hover Scale | on | Buttons grow slightly when hovered |
| Click Bounce | on | Buttons bounce when clicked |
| Toggle Pop | on | Pop animation when toggling abilities |
| Ready Pulse | on | Glow when ability comes off cooldown |
| Cooldown Color Tween | on | Smooth color transition during cooldowns |
| Toggle Color Tween | on | Smooth color on toggle state change |
| Stagger Animation | on | Buttons appear one-by-one on load |
| Low Resource Warning | on | Glow effect when HP/mana is low |
| Damage Flash | on | Flash effect when taking damage |

## Automation Control

Coordinated mode uses explicit feature settings: Assist, Chase, Healing, Cures,
Buffing, Mezzing, Resurrection, Pull, and the relevant spell/AA/disc toggles.
The Pause button, `/sk pause`, and `/sk resume` control the global
`AutomationPaused` setting and apply to every coordinated worker.

`AutomationLevel` is retained as a compatibility setting for the optional
monolithic runtime. Its old manual/hybrid/auto behavior is not a coordinated
worker control and is intentionally not shown in the current Automation tab.

## Class-Specific Features

### Healing Intelligence

CLR, DRU, SHM, and PAL characters use a dedicated healing intelligence subsystem with 15 specialized modules:

- **Combat Assessor**: Evaluates fight phase (opening, sustained, critical), damage rate, and survival risk
- **Target Monitor**: Real-time HP tracking for all group/raid members
- **Incoming Heals**: Predicts incoming heals from HoTs, other healers, and pending casts
- **Mob Assessor**: Identifies named mobs, difficulty tiers, and spell immunity
- **Heal Selector**: Picks the optimal heal (spell, AA, or disc) for the optimal target at the optimal time
- **Damage Attribution**: Tracks which mob is damaging which player
- **Analytics**: Efficiency metrics (overhealing %, casts per minute, mana efficiency)

Emergency abilities (Divine Arbitration, Celestial Regen, Sanctuary) trigger automatically when multiple members reach critical HP.

When you memorize a new healing spell, run `/sk_healing rescan` to merge it
into the current character's healing profile. Existing assignments are kept;
the same non-destructive merge also runs when the healing worker starts.

### Tank Classes (WAR, PAL, SHD)

- **Tank Mode**: Automatic AoE aggro management
- **AoE Threshold**: Configurable minimum mob count before using AoE abilities
- **Safe AE Check**: Skip AoE if mobs are mezzed
- **Repositioning**: Automatic positioning with cooldown
- **Dragon Positioning**: Special angle-based positioning for dragon fights

### Crowd Control (ENC, BRD, NEC)

- **Auto-Mez**: Mez targets on XTarget up to configurable max
- **AoE Mez**: Triggers when mob count exceeds threshold
- **Fast Mez**: Prioritize quick-casting mez spells
- **Refresh Window**: Re-mez before it drops (default: 6s before expiry)
- **Actor Coordination**: Prevents double-mezzing across characters

### Debuffers (SHM, ENC, MAG)

- **Class profiles**: Determine the supported slow, malo/tash, and cripple lines
- **Task Mob Debuffing**: Apply debuffs to all task mobs
- **Actor Coordination**: Prevents duplicate debuffs across characters

### Melee DPS (BER, MNK, ROG, RNG)

- **Discipline Bar**: Visual display of available discs with cooldowns
- **Burn Mode**: Timed burst DPS toggle
- **Stick Command**: Configurable positioning (`/stick snaproll behind 10 moveback uw`)
- **Dragon Positioning**: Angle-based positioning for large hitbox mobs

### Casters (MAG, NEC, WIZ, DRU)

- **Spell Rotation**: Cycle through configured spells by priority
- **Resist Type Preference**: Target specific resist types
- **Escape Range**: Back away from mobs when too close
- **Interrupt on Emergency**: Stop casting if self-HP drops critically low

## Multi-Box Coordination

SideKick uses the **Actors** messaging system for real-time inter-character communication. No external tools needed beyond MacroQuest's built-in Actors.

### What Gets Coordinated

| Data | Purpose |
|------|---------|
| Heal claims | Prevents two healers targeting the same player |
| HoT tracking | Tracks heal-over-time effects across all healers |
| Buff status | Prevents duplicate buffing |
| Debuff claims | Prevents duplicate slows/tashs/malos |
| Mez claims | Prevents double-mezzing |
| Target updates | Shares current target for assist chains |
| Tank broadcasts | Tank announces primary target to all assisters |
| Window bounds | Share window positions for UI anchoring |
| Team presence | Share coordinator state, active action, role, and module readiness |

### Setup

1. Leave Options > Integration > Actors Enabled on to publish UI status and expose the team controls
2. Leave Enable Team Presence on and Team Mode on `auto`, or give every intended character the same manual team name
3. Run SideKick on each character
4. Open Coordinator > Actor Team or use `/sk_coord team` to verify membership and leader election

Auto mode groups characters by raid leader, then group leader, and uses a solo
team when ungrouped. Team peers expire four seconds after their coordinator
stops responding. Team presence is currently diagnostic infrastructure;
feature-specific heal, rez, cure, buff, and CC coordination continues to work
through its existing Actor messages.

### Safe Targeting (KS Prevention)

SideKick checks targets against raid members and actor peers before engaging, preventing accidental kill stealing. Configure in Settings:

| Setting | Default | Purpose |
|---------|---------|---------|
| Safe Targeting | on | Check before engaging new targets |
| Check Raid | on | Verify against raid member targets |
| Check Peers | on | Verify against actor peer targets |

## Commands Reference

### Main Command

`/sidekick [subcommand]` or `/SideKick [subcommand]`

| Subcommand | Action |
|------------|--------|
| *(none)* | Toggle main window |
| `settings` / `options` / `config` | Toggle settings panel |
| `config audit` | Validate the registry and report unknown/invalid settings |
| `config get <key>` | Show a setting's value, owner, registration type, and file |
| `config set <key> <value>` | Validate and save a setting through its registered owner |
| `bar` | Toggle ability bar |
| `burn` | Activate burn mode |
| `burnoff` | Deactivate burn mode |
| `chase` | Toggle chase |
| `assist` | Toggle assist |
| `remote` | Toggle remote ability bar |
| `remoteconfig` | Open remote abilities settings |
| `healmonitor` | Toggle healing monitor (CLR/DRU/SHM/PAL) |
| `spellset` / `ss` | Open spell set editor |
| `assistme` | Broadcast assist request to peers |

### Shortcut Commands

| Command | Action |
|---------|--------|
| `/skchaseon` | Enable chase (broadcastable with `/dgge`) |
| `/skchaseoff` | Disable chase (broadcastable with `/dgge`) |
| `/skassistme` | Broadcast assist request |
| `/skactors` | Toggle actors debug window |
| `/sk_assist status\|stop` | Inspect the coordinated melee-assist target, lease owner, priority, and last decision |
| `/skspells [sub]` | Spellbook scanner commands |
| `/skcd [on\|off\|clear\|debug]` | Cooldown debugging |
| `/sk_next_meditation off\|ooc\|always\|status\|reload\|audit\|stop` | Set, control, and diagnose the SideKick-Next meditation worker without colliding with production SideKick |
| `/sk_buffs status\|reload\|retry\|dump\|clearcache\|debug on\|debug off\|stop` | Diagnose the buff worker; debug mode mirrors its throttled action trace to the MQ console, while failures always echo |
| `/sk_rez status\|debug on\|off\|retry\|now [name]\|stop` | Inspect or control the resurrection worker; `now` requests a group-member rez and bypasses the automatic enable/class gates for that attempt |
| `/sk_coord team` | Show Actor team mode, identity, elected leader, and live member count |

### Debug Commands

| Command | Action |
|---------|--------|
| `/sidekick debugsettings [on\|off]` | Log settings persistence events |
| `/sidekick actorsdebug` | Open actors debug window |
| `/sidekick coord` | Open coordinator debug window |
| `/sidekick debugcombat gems` | Show spell gems and their types |
| `/sidekick debugcombat state` | Show combat state and target info |
| `/sidekick debugcombat list` | Show castable spells (non-heal) |
| `/sidekick debugooc` | Reports that the legacy executor is retired; use `/sk coordinator` |

---

# Part 2 - Architecture Guide

## System Overview

SideKick is a priority-based automation framework where independent modules compete for casting authority through a central coordinator.

```mermaid
graph TB
    subgraph "Entry Points"
        INIT["init.lua"]
        SKSTART["sk_start.lua<br/>(multi-script launcher)"]
    end

    subgraph "Core"
        SK["SideKick.lua<br/>Main Loop & UI"]
        COORD["sk_coordinator.lua<br/>Priority Arbiter"]
        LIB["sk_lib.lua<br/>Constants & Types"]
        BASE["sk_module_base.lua<br/>Module Base Class"]
        REG["registry.lua<br/>Settings Registry"]
    end

    subgraph "Priority Modules"
        EMERG["sk_emergency.lua<br/>Priority 0"]
        HEAL["sk_healing.lua<br/>Priority 1"]
        CURES["sk_cures.lua<br/>Priority 2"]
        REZ["sk_resurrection.lua<br/>Priority 2"]
        CCWORKER["sk_cc.lua<br/>Priority 3"]
        ASSISTWORKER["sk_assist.lua<br/>Priority 4"]
        DPS["sk_dps.lua<br/>Priority 4"]
        RESOURCES["sk_resources.lua<br/>Priority 5"]
        BUFFS["sk_buffs.lua<br/>Priority 6"]
        MED["sk_meditation.lua<br/>Priority 7"]
    end

    subgraph "Healing Intelligence (healer classes)"
        HINIT["healing/init.lua"]
        HSEL["heal_selector.lua"]
        HTRK["heal_tracker.lua"]
        HTGT["target_monitor.lua"]
        HCOMBAT["combat_assessor.lua"]
        HMOB["mob_assessor.lua"]
        HHOT["hot_analyzer.lua"]
        HDMG["damage_attribution.lua"]
    end

    subgraph "Automation"
        ASSIST["automation/assist.lua"]
        CHASE["automation/chase.lua"]
        TANK["automation/tank.lua"]
        CC["automation/cc.lua"]
        DEBUFF["automation/debuff.lua"]
        CURES["automation/cures.lua"]
        BUFF["automation/buff.lua"]
        BURN["automation/burn.lua"]
    end

    subgraph "UI Layer"
        BAR["bar_animated.lua"]
        SBAR["special_bar_animated.lua"]
        DBAR["disc_bar_animated.lua"]
        IBAR["item_bar_animated.lua"]
        SETTINGS["ui/settings/init.lua"]
        MONITOR["healing/ui/monitor.lua"]
    end

    subgraph "Communication"
        ACTORS["utils/actors_coordinator.lua"]
        SHARED["actors/shareddata.lua"]
    end

    INIT --> SK
    SKSTART -->|spawns| COORD
    SKSTART -->|spawns| EMERG
    SKSTART -->|spawns| HEAL
    SKSTART -->|spawns| CURES
    SKSTART -->|spawns| REZ
    SKSTART -->|spawns| CCWORKER
    SKSTART -->|spawns| ASSISTWORKER
    SKSTART -->|spawns| DPS
    SKSTART -->|spawns| RESOURCES
    SKSTART -->|spawns| BUFFS
    SKSTART -->|spawns| MED

    SK --> BAR
    SK --> SBAR
    SK --> DBAR
    SK --> IBAR
    SK --> SETTINGS
    SK --> MONITOR

    SK --> ASSIST
    SK --> CHASE
    SK --> TANK
    SK --> CC
    SK --> DEBUFF
    SK --> BUFF
    SK --> BURN

    EMERG --> BASE
    HEAL --> BASE
    DPS --> BASE
    BUFFS --> BASE
    MED --> BASE
    BASE --> LIB

    HEAL --> HINIT
    HINIT --> HSEL
    HINIT --> HTRK
    HINIT --> HTGT
    HINIT --> HCOMBAT
    HINIT --> HMOB
    HINIT --> HHOT
    HINIT --> HDMG

    COORD <-->|Actors| EMERG
    COORD <-->|Actors| HEAL
    COORD <-->|Actors| DPS
    COORD <-->|Actors| BUFFS
    COORD <-->|Actors| MED

    ACTORS <-->|cross-character| SHARED
```

## Startup Flow

SideKick uses one canonical coordinated launch mode. The legacy `sk_start`
entry point is retained as an alias and forwards to `/lua run sidekick-next`.

```mermaid
flowchart TD
    USER["/lua run sidekick-next"]
    USER2["/lua run sidekick-next/sk_start<br/>(compatibility alias)"]
    INIT["init.lua + supervisor"]
    COORD["sk_coordinator.lua<br/>(priority arbiter)"]
    UI["SideKick.lua<br/>(UI, settings, state, Actors)"]
    WORKERS["Priority workers<br/>(emergency, healing, rez, DPS,<br/>disciplines, buffs, meditation)"]

    USER --> INIT
    USER2 --> USER
    INIT --> COORD
    INIT --> WORKERS
    INIT --> UI
    UI -->|"500ms heartbeat"| COORD
    WORKERS <-->|"claims + state"| COORD
```

The UI process supervises the session. Normal shutdown stops every managed
worker and the coordinator; loss of the UI heartbeat also causes the
coordinator and workers to shut down. Automatic casting and targeting belong
to claimed workers, while the UI process remains responsible for presentation,
configuration, cached state, and cross-character status.

## Priority Coordinator

The coordinator ensures only one module casts at a time, with higher-priority modules interrupting lower ones.

After a claim is granted, the unified action executor shows the action moving
through queued, dispatching, cast-start, running, and terminal phases. These
phases appear in Coordinator > Module Status. Hover the Action cell to see the
terminal reason and elapsed time. A stun, mez, silence, fear, stale claim, or
failed cast start cancels the lifecycle and releases its cast rights instead
of leaving another module waiting on a long lease.

```mermaid
sequenceDiagram
    participant E as Emergency (P0)
    participant H as Healing (P1)
    participant D as DPS (P4)
    participant C as Coordinator

    Note over C: Idle state - no active cast

    D->>C: claim_request(DPS, nuke, priority=4)
    C->>D: claim_granted(DPS)
    Note over D: Begins casting nuke...

    H->>C: claim_request(HEALING, groupheal, priority=1)
    Note over C: Priority 1 < 4 → preempt DPS
    C->>D: claim_revoked(DPS)
    C-->>D: /stopcast issued
    C->>H: claim_granted(HEALING)
    Note over H: Begins casting group heal...

    E->>C: claim_request(EMERGENCY, divine_arb, priority=0)
    Note over C: Priority 0 < 1 → preempt Healing
    C->>H: claim_revoked(HEALING)
    C-->>H: /stopcast issued
    C->>E: claim_granted(EMERGENCY)
    Note over E: Fires Divine Arbitration (instant)
    E->>C: claim_released(EMERGENCY)

    Note over C: Resume highest pending...
    C->>H: claim_granted(HEALING)
    Note over H: Re-casts group heal
    H->>C: claim_released(HEALING)
    C->>D: claim_granted(DPS)
    Note over D: Resumes nuke rotation
```

**Key rule**: The coordinator owns all cross-module preemption. A worker can
request cancellation of its own cast for healing ducking or a local safety
condition, but it cannot stop another module's cast directly.

## Main Loop

The main tick loop in `SideKick.lua` runs at approximately 60 FPS.

```mermaid
flowchart TD
    START["Main Loop Tick<br/>(every ~16ms)"]
    SETTINGS["Refresh settings<br/>(check INI changes)"]
    CLASS["Check class/abilities<br/>(reload if changed)"]
    QUEUE["Drain action queue<br/>(execute pending actions)"]
    PAUSED{"Automation<br/>paused?"}
    COMBAT{"In combat?"}

    subgraph "Combat Tick"
        ASSIST["Update assist target"]
        TANK["Tank broadcast check"]
        ROTATION["Combat spell executor<br/>(priority-based spell selection)"]
        HEAL["Healing module tick"]
        CC["Crowd control tick"]
        DEBUFF["Debuff tick"]
    end

    subgraph "OOC Tick"
        CHASE["Chase/follow tick"]
        MED["Meditation tick"]
        BUFF["OOC buff executor"]
        MEMGEMS["Memorize spell gems"]
    end

    RENDER["Render all ImGui windows<br/>(bars, settings, monitor)"]
    DELAY["mq.delay(16)<br/>yield to MQ"]

    START --> SETTINGS --> CLASS --> QUEUE --> PAUSED
    PAUSED -->|yes| RENDER
    PAUSED -->|no| COMBAT
    COMBAT -->|yes| ASSIST --> TANK --> ROTATION --> HEAL --> CC --> DEBUFF --> RENDER
    COMBAT -->|no| CHASE --> MED --> BUFF --> MEMGEMS --> RENDER
    RENDER --> DELAY --> START
```

## Healing Intelligence Pipeline

The healing intelligence system uses a multi-stage pipeline to select the optimal heal.

```mermaid
flowchart TD
    TICK["Healing Tick"]

    subgraph "Stage 1: Assessment"
        CA["Combat Assessor<br/>Fight phase, damage rate,<br/>survival risk"]
        MA["Mob Assessor<br/>Named mob detection,<br/>difficulty tier, immunities"]
        DA["Damage Attribution<br/>Which mob → which player"]
    end

    subgraph "Stage 2: Targeting"
        TM["Target Monitor<br/>Real-time HP for all<br/>group/raid members"]
        IH["Incoming Heals<br/>Predict pending heals:<br/>HoTs, other healers, casts"]
        HA["HoT Analyzer<br/>Trust HoT values,<br/>remaining ticks"]
    end

    subgraph "Stage 3: Selection"
        HS["Heal Selector<br/>Best heal × best target<br/>× best timing"]
        SPELLS{"Available spells?"}
        AA{"Available AAs?"}
        DISC{"Available discs?"}
        PICK["Select optimal action"]
    end

    subgraph "Stage 4: Execution"
        CLAIM["Request cast claim<br/>from coordinator"]
        GRANTED{"Claim<br/>granted?"}
        CAST["Execute heal"]
        TRACK["Update heal tracker<br/>+ analytics"]
    end

    TICK --> CA & MA & DA
    CA & MA & DA --> TM & IH & HA
    TM & IH & HA --> HS
    HS --> SPELLS & AA & DISC
    SPELLS & AA & DISC --> PICK
    PICK --> CLAIM --> GRANTED
    GRANTED -->|yes| CAST --> TRACK
    GRANTED -->|no, wait| TICK
```

### How Heal Selector Decides

The heal selector evaluates candidates using a scoring function:

1. **Urgency**: How close is the target to death? (HP%, damage rate, incoming damage)
2. **Efficiency**: Will this heal overheal? (predicted HP after pending heals + HoTs)
3. **Coverage**: Does a group heal cover more wounded members than a single target heal?
4. **Speed**: Is a fast heal needed (target dropping fast) or can we use a slow efficient heal?
5. **Coordination**: Is another healer already targeting this player? (via Actor claims)

## Actors Communication

Cross-character messaging uses MacroQuest's Actors system (mailbox-based message passing).

```mermaid
sequenceDiagram
    participant C1 as Character 1<br/>(Cleric)
    participant MB as Actors Mailbox<br/>"sidekick"
    participant C2 as Character 2<br/>(Shaman)
    participant C3 as Character 3<br/>(Warrior)

    Note over MB: All characters register<br/>on "sidekick" mailbox

    C3->>MB: target:primary<br/>{targetName: "a_gnoll_01", targetId: 42}
    MB->>C1: target:primary
    MB->>C2: target:primary
    Note over C1,C2: Both switch assist target

    C1->>MB: heal:claim<br/>{target: "Warrior", spell: "Complete Heal"}
    MB->>C2: heal:claim
    Note over C2: Warrior already claimed<br/>→ heal someone else

    C2->>MB: heal:hots<br/>{target: "Warrior", spell: "Regeneration", ticks: 12}
    MB->>C1: heal:hots
    Note over C1: Factor HoT into<br/>incoming heal prediction

    C1->>MB: buff:list<br/>{buffs: ["Symbol of Naltron", "Aegolism"]}
    MB->>C2: buff:list
    Note over C2: Skip duplicate buffs
```

### Message Types

| Message | Direction | Purpose |
|---------|-----------|---------|
| `status:req` / `status:rep` | Request/Reply | Health and status queries |
| `team:state` / `team:leave` | Broadcast | Versioned coordinator presence for the current Actor team |
| `heal:claim` | Broadcast | "I'm healing this target" |
| `heal:hots` | Broadcast | "I applied or am maintaining these HoTs" |
| `buff:list` / `buff:claim` / `buff:landed` | Broadcast | Buff availability, intent, and completion |
| `target:primary` | Broadcast | "This is the primary target" |
| `debuff:claim` | Broadcast | "I'm debuffing this mob" |
| `cc:claim` | Broadcast | "I'm mezzing this mob" |
| `window:bounds:req` / `window:bounds` | Request/Reply | UI window position sharing |

## Spell Execution Flow

From spell selection to landing, including gem management.

```mermaid
stateDiagram-v2
    [*] --> Idle

    Idle --> SpellSelected: Action queued

    SpellSelected --> CheckGem: Spell selected

    CheckGem --> GemReady: Spell memorized in gem
    CheckGem --> NeedMemorize: Wrong spell in gem

    NeedMemorize --> Memorizing: /memorize spell gem#
    Memorizing --> WaitMemorize: Wait up to 25s
    WaitMemorize --> GemReady: Memorized
    WaitMemorize --> Failed: Timeout

    GemReady --> RequestClaim: Request cast from coordinator
    RequestClaim --> WaitClaim: Waiting for grant
    WaitClaim --> Casting: Claim granted
    WaitClaim --> Idle: Claim denied (preempted)

    Casting --> CastCheck: /cast gem#
    CastCheck --> Success: Spell landed
    CastCheck --> Fizzled: Fizzled
    CastCheck --> Resisted: Resisted
    CastCheck --> Interrupted: Interrupted
    CastCheck --> Interrupted: Target died
    CastCheck --> Interrupted: Out of range

    Fizzled --> RetryCheck: Retry enabled?
    Resisted --> RetryCheck
    Interrupted --> RetryCheck

    RetryCheck --> SpellSelected: Retries remaining
    RetryCheck --> Failed: Max retries (3)

    Success --> CooldownTracking: Track reuse timer
    CooldownTracking --> ReleaseClaim: Release cast claim
    Failed --> ReleaseClaim
    ReleaseClaim --> Idle
```

## Module Architecture

All priority modules inherit from `ModuleBase`.

```mermaid
classDiagram
    class ModuleBase {
        +name: string
        +priority: number
        +state: "idle" | "claiming" | "casting"
        +create(name, priority) ModuleBase
        +shouldAct() bool
        +getAction() Action
        +executeAction(action)
        +onTick()
        +requestClaim()
        +releaseClaim()
        +handleMessage(msg)
    }

    class Emergency {
        +priority: 0
        +shouldAct() "multi-member critical HP"
        +getAction() "Divine Arb / Celestial Regen / Sanctuary"
    }

    class Healing {
        +priority: 1
        +healingInit: HealingIntelligence
        +shouldAct() "any member below threshold"
        +getAction() "best heal for best target"
    }

    class DPS {
        +priority: 4
        +combatExecutor: CombatSpellExecutor
        +shouldAct() "valid target, in combat"
        +getAction() "next spell in rotation"
    }

    class Buffs {
        +priority: 6
        +oocExecutor: OOCBuffExecutor
        +shouldAct() "out of combat, buffs missing"
        +getAction() "next buff to cast"
    }

    class Meditation {
        +priority: 7
        +shouldAct() "resources below threshold"
        +getAction() "sit or stand command"
    }

    ModuleBase <|-- Emergency
    ModuleBase <|-- Healing
    ModuleBase <|-- DPS
    ModuleBase <|-- Buffs
    ModuleBase <|-- Meditation

    class Coordinator {
        +activeClaim: Claim?
        +pendingClaims: Claim[]
        +grantClaim(module, priority)
        +revokeClaim(module)
        +processClaims()
    }

    Coordinator --> ModuleBase : manages
```

## Settings Data Flow

How settings move from file to UI and back.

```mermaid
flowchart LR
    INI["Per-module INIs<br/>Server_Character/module.ini"]
    REG["registry.lua<br/>schema + one explicit owner"]
    CORE["utils/core.lua<br/>canonicalize, validate, atomic save"]
    RUNTIME["Runtime State<br/>(in-memory settings table)"]
    UI["Settings UI<br/>(modular ImGui tabs)"]
    COORD["Supervisor / Coordinator<br/>committed settings revision"]
    MODULES["Worker Modules<br/>reload committed files"]

    REG -->|"owner + validation"| CORE
    INI -->|"load and migrate"| CORE
    CORE -->|"validated snapshot"| RUNTIME
    RUNTIME -->|"read"| UI
    UI -->|"Core.set / setMany"| CORE
    CORE -->|"atomic commit"| INI
    CORE -->|"revision after commit"| COORD
    COORD -->|"reload revision"| MODULES
```

**Key behavior**: UI changes update the local runtime immediately, then publish
a new revision only after the owning module INI commits successfully. Workers
reload that committed revision without requiring a Lua restart.

---

# Part 3 - Reference

## Settings Reference

### UI Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| SideKickTheme | text | Classic | Active color theme |
| SideKickSyncThemeWithGT | bool | true | Sync theme with GroupTarget |
| SideKickMainEnabled | bool | false | Show main bar window |
| SideKickOptionsManual | bool | true | Allow manual window move/resize |
| SideKickMainAnchor | text | none | Main bar anchor mode |
| SideKickMainButtonScale | float | 1.0 | Button size scale (0.5-3.0) |
| SideKickFontScale | float | 1.0 | Font size scale (0.5-3.0) |

### Bar Settings (Ability / Special / Discipline / Item / Skill)

Bar keys use the prefixes `SideKickBar`, `SideKickSpecial`,
`SideKickDiscBar`, `SideKickItemBar`, and `SideKickSkillBar`. The common
suffixes are:

| Suffix | Type | Default | Description |
|--------|------|---------|-------------|
| Enabled | bool | true | Show this bar |
| Cell | int | 40-65 | Button size in pixels; default depends on the bar |
| Rows | int | 1-2 | Number of rows; default depends on the bar |
| Gap | int | 4 | Gap between buttons |
| Pad | int | 6 | Padding inside bar |
| BgAlpha | float | 0.85 | Background opacity (0-1) |
| Anchor | text | none | Anchor mode |
| AnchorTarget | text | varies | GroupTarget for most bars; none for the Skill Bar |
| AnchorGap | int | 2 | Spacing from anchor (0-48) |

### Combat Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| CombatMode | text | off | Combat role (off/tank/assist) |
| StickCommand | text | /stick snaproll... | Melee positioning command |
| DragonPositioning | bool | false | Dragon fight positioning |
| EmergencyHpThreshold | int | 35 | Emergency HP% |
| UseSpells | bool | true | Enable spell usage |
| UseAAs | bool | true | Enable AA usage |
| UseDiscs | bool | true | Enable disc usage |
| SpellRotationEnabled | bool | false | Enable spell rotation |
| SpellAutoMemorize | bool | true | Auto-memorize spells |
| InterruptOnTargetDeath | bool | true | Stop cast if target dies |

### Automation Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| AutomationLevel | text | auto | Compatibility-only play style for monolithic mode |
| AutomationPaused | bool | false | Global pause |
| ChaseEnabled | bool | false | Chase toggle |
| ChaseRole | text | ma | Chase target role |
| ChaseDistance | int | 30 | Chase distance |
| AssistMode | text | group | Assist source |
| AssistAt | int | 97 | Engage HP% |
| MeditationMode | text | off | off/ooc/always |
| BurnDuration | int | 30 | Burn duration (seconds) |
| BuffingEnabled | bool | true | Buff automation |

### Current Healing and Cure Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| DoHeals | bool | true | Enable Healing Intelligence |
| DoCures | bool | true | Cure automation |
| CurePrioritySelf | bool | false | Cure self before other valid targets |
| CureInCombat | bool | true | Allow cures during combat |

Healing Intelligence stores pet, HoT, heal-selection, incoming-heal, and
analytics controls in `healing/config_<Server>_<Character>.lua` rather than the
registry. The following registry keys are compatibility-only and are hidden
when Healing Intelligence is active:

| Legacy key | Type | Default | Description |
|------------|------|---------|-------------|
| MainHealPoint | int | 80 | Main heal HP% |
| BigHealPoint | int | 50 | Big heal HP% |
| GroupHealPoint | int | 75 | Group heal HP% |
| GroupInjureCnt | int | 2 | Members for group heal |
| HealUseHoTs | bool | true | Use HoT spells |
| HealCoordinateActors | bool | true | Legacy cross-character heal coordination |

### Actor Integration Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| ActorsEnabled | bool | true | UI peer/status publishing and integration controls |
| ActorsTeamEnabled | bool | true | Actor Team presence publishing |
| ActorsTeamMode | text | auto | auto/group/raid/manual team selection |
| ActorsTeamName | text | empty | Shared name used by manual teams |

## Priority Tiers

| Priority | Name | Module | Behavior |
|----------|------|--------|----------|
| 0 | EMERGENCY | sk_emergency | Divine Arbitration, Celestial Regen, Sanctuary. Fires when multiple members are critical. |
| 1 | HEALING | sk_healing | Group and single-target heals. Interrupts DPS/buffs to heal. |
| 2 | RESURRECTION | sk_cures / sk_resurrection | Cures and rez. Lower than healing but above combat. |
| 3 | DEBUFF | sk_cc | Crowd control casting. |
| 4 | DPS | sk_dps | Nukes, stuns, combat spell rotations. |
| 5 | IDLE | (internal) | Idle-state actions when nothing else is needed. |
| 6 | BUFF | sk_buffs | OOC buff casting with gem swapping. |
| 7 | MEDITATION | sk_meditation | Sit/stand for resource regen. Lowest priority. |

Higher priority (lower number) always preempts lower priority. The coordinator issues `/stopcast` when preempting.

## File Map

| Path | Purpose |
|------|---------|
| `init.lua` | Main entry point |
| `SideKick.lua` | Main loop, UI rendering, automation orchestration |
| `sk_start.lua` | Multi-script launcher |
| `sk_coordinator.lua` | Priority-based cast claim arbiter |
| `sk_lib.lua` | Shared constants, types, mailbox names |
| `sk_module_base.lua` | Base class for priority modules |
| `sk_emergency.lua` | Emergency AA module (priority 0) |
| `sk_healing.lua` | Authoritative normal and emergency healing (dynamic priority 0/1) |
| `sk_cures.lua` | Coordinator-owned cure selection and casting (priority 2) |
| `sk_resurrection.lua` | Resurrection module (priority 2) |
| `sk_cc.lua` | Coordinator-owned mez selection and casting (priority 3) |
| `sk_assist.lua` | Coordinator-owned melee targeting and positioning (priority 4) |
| `sk_dps.lua` | DPS/combat module (priority 4) |
| `sk_resources.lua` | Resource conversion module (priority 5) |
| `sk_buffs.lua` | OOC buff module (priority 6) |
| `sk_meditation.lua` | Meditation module (priority 7) |
| `registry.lua` | Authoritative settings schema and ownership registry (currently 238 defaults) |
| `themes.lua` | Color theme presets |
| `healing/` | Healer-class intelligence (15 modules) |
| `healing/init.lua` | Healing orchestrator |
| `healing/heal_selector.lua` | Heal selection logic |
| `healing/combat_assessor.lua` | Fight phase assessment |
| `healing/target_monitor.lua` | Group HP tracking |
| `healing/ui/monitor.lua` | Healing monitor window |
| `automation/` | Automation subsystems (13 modules) |
| `automation/assist.lua` | Assist targeting |
| `automation/chase.lua` | Chase/follow |
| `automation/tank.lua` | Tank logic |
| `automation/cc.lua` | Crowd control |
| `automation/debuff.lua` | Debuffing |
| `automation/cures.lua` | Cure/cleanse |
| `automation/buff.lua` | Buff management |
| `automation/burn.lua` | Burn mode |
| `automation/meditation.lua` | Retired no-op compatibility shim |
| `utils/` | Core utilities (28 modules) |
| `utils/core.lua` | Settings I/O, INI parsing |
| `utils/actors_coordinator.lua` | Cross-character Actors messaging |
| `utils/actors_team.lua` | Coordinator-owned Actor Team presence and leader election |
| `utils/combat_spell_executor.lua` | Combat spell selection |
| `utils/spellset_manager.lua` | Spell set storage |
| `utils/spell_engine.lua` | Spell casting engine |
| `utils/rotation_engine.lua` | Combat rotation logic |
| `utils/immune_database.lua` | Spell immunity database |
| `abilities/` | Ability loading and cooldowns |
| `abilities/cooldowns.lua` | Cooldown timer smoothing |
| `data/class_configs/` | Per-class ability definitions (15 classes) |
| `actors/shareddata.lua` | Shared Actors data structures |
| `ui/` | UI components and settings tabs |
| `ui/settings/init.lua` | Active modular settings coordinator |
| `ui/bar_animated.lua` | Main ability bar |
| `ui/special_bar_animated.lua` | Special abilities bar |
| `ui/disc_bar_animated.lua` | Discipline bar |
| `ui/item_bar_animated.lua` | Item bar |
| `ui/anchor.lua` | Window anchoring system |
| `ui/settings/tab_*.lua` | Modular settings and diagnostic tab implementations |
| `ui/components/` | Reusable UI components |

## Glossary

| Term | Definition |
|------|------------|
| **AA** | Alternate Advancement - special abilities earned via experience |
| **Actors** | MacroQuest's inter-script message passing system (mailbox pattern) |
| **Anchor** | Snapping a window's position relative to another window |
| **Burn** | Timed mode where all DPS cooldowns are used aggressively |
| **CC** | Crowd Control - mesmerize, root, snare to neutralize mobs |
| **Claim** | Cast ownership token granted by the coordinator to a module |
| **DanNet** | MacroQuest plugin for cross-character data observation |
| **Disc** | Discipline - melee/tank special abilities with shared timers |
| **Gem** | Spell memorization slot (typically 8-13 slots) |
| **GroupTarget** | Companion MQ Lua script showing group/xtarget HUD |
| **HoT** | Heal over Time - heal that ticks for several seconds |
| **ImGui** | Dear ImGui - immediate-mode graphics library used for all UI |
| **INI** | Configuration file format used by MacroQuest |
| **KS** | Kill Stealing - attacking another player's target (prevented by Safe Targeting) |
| **MA** | Main Assist - the designated player whose target everyone assists |
| **Medley** | Companion MQ Lua script for bard song twist automation |
| **MQ** | MacroQuest - the EverQuest automation platform |
| **MT** | Main Tank - the designated tank in a group/raid |
| **OOC** | Out of Combat - state where no enemies are engaged |
| **Preempt** | Higher priority module interrupting a lower priority one |
| **Rotation** | Ordered sequence of spells to cast during combat |
| **Spell Set** | Named collection of spell gem assignments |
| **Stick** | MQ command that makes your character follow/position relative to target |
| **TLO** | Top Level Object - MacroQuest data access layer |
| **XTarget** | Extended Target - additional target slots showing nearby threats |
