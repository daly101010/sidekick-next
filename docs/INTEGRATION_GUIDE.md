# SideKick Enhancements Integration Guide

## Files Created

These new files have been created and need to be integrated:

1. `utils/actors_coordinator_v2.lua` - Replace `actors_coordinator.lua` with this
2. `ui/remote_abilities.lua` - New remote ability bar module
3. `ui/aggro_warning.lua` - New aggro warning overlay module
4. `ui/animation_helpers_v2.lua` - Replace `animation_helpers.lua` with this

## File Replacements

```bash
cd F:/lua/SideKick

# Backup originals
cp utils/actors_coordinator.lua utils/actors_coordinator_backup.lua
cp ui/animation_helpers.lua ui/animation_helpers_backup.lua

# Replace with new versions
mv utils/actors_coordinator_v2.lua utils/actors_coordinator.lua
mv ui/animation_helpers_v2.lua ui/animation_helpers.lua
```

## SideKick.lua Integration

Add these changes to `SideKick.lua`:

### 1. Add Requires (near line 25, after other requires)

```lua
local RemoteAbilities = require('ui.remote_abilities')
local AggroWarning = require('ui.aggro_warning')
```

### 2. Add Initialization (in main() function, after line 826)

```lua
RemoteAbilities.init()
AggroWarning.init()
```

### 3. Add to ImGui Render Callback (inside mq.imgui.init, after line 916)

```lua
-- Remote Abilities Bar
RemoteAbilities.draw()
RemoteAbilities.drawSettings()

-- Aggro Warning Overlay
AggroWarning.draw()
```

### 4. Add to Main Loop (inside while true loop, after line 923)

```lua
-- Update aggro warning state
AggroWarning.update()
```

### 5. Add Settings UI (in the settings panel draw code)

Add a "Remote Abilities" section:
```lua
if imgui.CollapsingHeader('Remote Abilities') then
    local raOpen = RemoteAbilities.isOpen()
    if imgui.Checkbox('Show Remote Ability Bar', raOpen) then
        RemoteAbilities.setOpen(not raOpen)
    end
    if imgui.Button('Configure Remote Abilities') then
        RemoteAbilities.toggleSettings()
    end
end
```

Add a "Warnings" section:
```lua
if imgui.CollapsingHeader('Warnings') then
    AggroWarning.drawSettings()
end
```

## New Features Summary

### Remote Ability Bar
- Shows abilities from other SideKick instances
- Click to execute via `/dex` commands
- Open settings to select which abilities to display
- Requires SideKick running on multiple characters

### Aggro Warning
- Center-screen "AGGRO!" overlay for non-tanks
- Triggers in raids when you have aggro and target HP < 98%
- Configurable threshold, duration, and cooldown
- Auto-dismisses when aggro is lost

### Animation Enhancements (in animation_helpers_v2.lua)
- `getReadyPulseAlpha(id, isReady)` - Pulsing glow for ready abilities
- `getReadyGlowColor(id, isReady, baseColor)` - Color shift for ready state
- `getLowResourcePulse(id, pct, threshold)` - Warning pulse for low HP/mana
- `getDamageFlash(id, currentHp, duration)` - Red flash on damage
- `getToggleScale(id, isActive)` - Pop animation for toggle buttons
- `getToggleColor(id, isActive, onColor, offColor)` - Color transition for toggles

## Testing

1. Start SideKick on two characters
2. On driver, open SideKick settings
3. Find "Remote Abilities" section, click "Configure"
4. Select abilities from the other character
5. Verify the remote bar appears and buttons work

For aggro warning:
1. Join a raid on a non-tank character
2. Gain aggro on a mob below 98% HP
3. Verify "AGGRO!" appears with animation
