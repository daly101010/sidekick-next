# SideKick Enhancements Design

## Overview

Enhance SideKick with three major features:
1. Remote Ability Bar - execute abilities on boxed characters from driver
2. UI Animations - polish existing UI with animations using ImAnim
3. Aggro Warning System - alert non-tanks when they have aggro in raids

---

## Feature 1: Remote Ability Bar

### Purpose
Allow the driver character to see and execute key abilities from boxed characters via a floating bar UI.

### Data Flow

```
[Boxed Char] SideKick broadcasts via actors:
  - Character name
  - Available abilities (name, icon, cooldown, ready state, type, ID)

[Driver Char] Remote Ability Bar:
  - Receives broadcasts
  - Displays user-selected abilities
  - Click triggers /dex command
```

### Execution Logic

```lua
local function executeRemoteAbility(charName, ability)
    local kind = ability.kind or 'aa'
    if kind == 'aa' then
        mq.cmdf('/dex %s /alt activate %d', charName, ability.altID)
    elseif kind == 'disc' then
        mq.cmdf('/dex %s /disc %s', charName, ability.discName)
    elseif kind == 'ability' then
        mq.cmdf('/dex %s /doability %s', charName, ability.abilityName)
    elseif kind == 'item' then
        mq.cmdf('/dex %s /useitem "%s"', charName, ability.itemName)
    end
end
```

### UI Layout

Grouped by character with name header:

```
+-----------------------------------------------------+
| Healbot        | Tankguy       | Wizzy             |
| [Rez] [DI]     | [Fortify]     | [Harvest] [Mana]  |
+-----------------------------------------------------+
```

- Ability buttons show cooldown sweep animation
- Hover tooltip shows full ability name
- Click executes via /dex

### Settings

- Located in SideKick settings panel under "Remote Abilities" tab
- Each connected character shows their available abilities
- User checks which abilities to display on the bar
- Configuration persists per-driver character

### Actor Message Format

```lua
{
    type = 'sidekick_abilities',
    character = 'Healbot',
    class = 'CLR',
    abilities = {
        {
            name = 'Divine Resurrection',
            shortName = 'Rez',
            kind = 'aa',
            altID = 1234,
            icon = 123,
            ready = true,
            cooldown = 0,
            cooldownTotal = 300
        },
        -- ...
    }
}
```

---

## Feature 2: UI Animations

### Animation Library
Uses existing `ImAnim` library from the group project with tweens, springs, oscillators, clips, and easings.

### Ability Bars

| Effect | Implementation | Trigger |
|--------|---------------|---------|
| Cooldown sweep | Radial or vertical fill overlay | While ability on cooldown |
| Ready pulse | `ImAnim.oscillate('sine', 0.8, 1.0, 2.0)` on glow alpha | When ability ready |
| Click bounce | Spring with snap on scale | On button click |
| Hover glow | Tween brightness on hover | Mouse enter/leave |

### Resource Bars (HP/Mana/End)

| Effect | Implementation | Trigger |
|--------|---------------|---------|
| Smooth transitions | `ImAnim.tween` on bar width | Any resource change |
| Low resource warning | Color tween to red + pulse | Below 20% threshold |
| Damage flash | Brief red overlay flash | HP drops suddenly (>5% in one tick) |

### Toggle Buttons (Assist, Chase, Burn)

| Effect | Implementation | Trigger |
|--------|---------------|---------|
| State change | Color tween between states | On toggle |
| Activation pop | Scale spring (1.0 -> 1.15 -> 1.0) | When toggled ON |
| Hover lift | Scale tween to 1.05 | Mouse hover |

### Integration Points

- `SideKick.lua`: Main bar buttons, ability bars
- `group_core.lua`: Group member rows, resource bars
- Shared animation state management to avoid conflicts

---

## Feature 3: Aggro Warning System

### Purpose
Alert non-tank players when they unexpectedly have aggro during raid encounters.

### Trigger Conditions

All must be true:
1. `mq.TLO.Raid.Members() > 0` - Player is in a raid
2. Player has aggro (target is targeting player, or detected via XTarget)
3. `mq.TLO.Target.PctHPs() < 98` - Target HP below threshold
4. Player class is NOT: Warrior, Paladin, Shadowknight

### Detection Logic

```lua
local tankClasses = { WAR = true, PAL = true, SHD = true }

local function shouldShowAggroWarning()
    -- Not in raid
    if (mq.TLO.Raid.Members() or 0) == 0 then return false end

    -- Is a tank class
    local myClass = mq.TLO.Me.Class.ShortName()
    if tankClasses[myClass] then return false end

    -- No target
    local target = mq.TLO.Target
    if not target or not target.ID() then return false end

    -- Target HP too high (probably not a real fight)
    if (target.PctHPs() or 100) >= Settings.aggroWarningThreshold then return false end

    -- Check if we have aggro
    local hasAggro = target.AggroHolder.ID() == mq.TLO.Me.ID()
    if not hasAggro then
        -- Also check XTarget for aggro indication
        for i = 1, 13 do
            local xt = mq.TLO.Me.XTarget(i)
            if xt and xt.TargetType() == 'Auto Hater' and xt.ID() == target.ID() then
                hasAggro = true
                break
            end
        end
    end

    return hasAggro
end
```

### Visual Display

- Large center-screen text: **"AGGRO!"**
- Animation sequence:
  1. Scale in from 0 -> 1.2 -> 1.0 (spring)
  2. Shake effect (ImAnim.shake)
  3. Pulsing red glow
- Auto-dismiss after 3 seconds or when aggro lost
- Does not spam - cooldown between repeated warnings

### Settings

```lua
Settings.aggroWarningEnabled = true      -- Master toggle
Settings.aggroWarningThreshold = 98      -- HP% threshold
Settings.aggroWarningDuration = 3.0      -- Display time in seconds
Settings.aggroWarningCooldown = 5.0      -- Min time between warnings
```

### UI Location

Settings toggle in SideKick settings panel under a "Warnings" or "Alerts" section.

---

## Implementation Notes

### Dependencies
- Existing actors infrastructure (from group project)
- ImAnim library (copy from group/lib or share)
- ImGui for rendering

### Files to Modify
- `SideKick/SideKick.lua` - Main UI, settings, aggro warning
- `SideKick/actors/shareddata.lua` - Add ability broadcast data
- `SideKick/utils/actors_coordinator.lua` - Handle ability messages

### Files to Create
- `SideKick/ui/remote_abilities.lua` - Remote ability bar UI
- `SideKick/ui/animations.lua` - Animation helpers/state
- `SideKick/ui/aggro_warning.lua` - Aggro warning overlay

### Shared Resources
- Copy or reference ImAnim from `group/lib/imanim.lua`
- Leverage existing actor message patterns from group project
