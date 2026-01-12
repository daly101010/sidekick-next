# SideKick Enhancements Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add remote ability execution bar, enhanced UI animations, and aggro warning system to SideKick.

**Architecture:** Extend existing actors infrastructure to broadcast full ability data. Create a new remote ability bar UI on driver character. Enhance animation_helpers with ready pulse/damage flash effects. Add aggro detection module with center-screen overlay.

**Tech Stack:** Lua, MacroQuest ImGui, ImAnim animation library, MQ actors messaging

---

## Task 1: Extend SharedData for Remote Ability Broadcasting

**Files:**
- Modify: `F:/lua/SideKick/actors/shareddata.lua`

**Step 1: Add complete ability data to buildStatusPayload**

Add execution details (kind, altID, discName, itemName) to each ability entry so remote characters can execute them via /dex:

```lua
-- In buildAbilityStatus function, replace the minimal payload with full data:
out[def.altName] = {
    ready = ready,
    cooldown = cooldown,
    cooldownTotal = def.cooldownTotal or 0,
    kind = def.kind or 'aa',
    altID = def.altID,
    altName = def.altName,
    discName = def.discName,
    itemName = def.itemName,
    shortName = def.shortName or def.altName,
    icon = def.icon,
}
```

**Step 2: Verify the change**

Run SideKick and confirm the status broadcast includes the new fields by checking `_G.GroupTargetBounds` or actor message logging.

**Step 3: Commit**

```bash
git add actors/shareddata.lua
git commit -m "feat(actors): include full ability data in status broadcast for remote execution"
```

---

## Task 2: Add Remote Ability Receiver to ActorsCoordinator

**Files:**
- Modify: `F:/lua/SideKick/utils/actors_coordinator.lua`

**Step 1: Add storage for remote character abilities**

At the top of the module, add state storage:

```lua
local _remoteCharacters = {}  -- { [charName] = { class, abilities, lastSeen } }
```

**Step 2: Handle incoming status:update messages from other SideKick instances**

Inside the `_dropbox` message handler, add a case for status updates:

```lua
if id == 'status:update' then
    if fromMe then return end  -- Ignore our own broadcasts
    local charName = sender.character
    if charName == '' then return end

    _remoteCharacters[charName] = {
        class = content.class or '',
        abilities = content.abilities or {},
        chase = content.chase,
        hp = content.hp,
        mana = content.mana,
        endur = content.endur,
        lastSeen = os.clock(),
    }
    return
end
```

**Step 3: Add getter function for remote characters**

```lua
function M.getRemoteCharacters()
    -- Prune stale entries (not seen in 10 seconds)
    local now = os.clock()
    for name, data in pairs(_remoteCharacters) do
        if (now - (data.lastSeen or 0)) > 10 then
            _remoteCharacters[name] = nil
        end
    end
    return _remoteCharacters
end
```

**Step 4: Commit**

```bash
git add utils/actors_coordinator.lua
git commit -m "feat(actors): receive and store remote character ability data"
```

---

## Task 3: Create Remote Ability Bar UI Module

**Files:**
- Create: `F:/lua/SideKick/ui/remote_abilities.lua`

**Step 1: Create the module skeleton**

```lua
local mq = require('mq')
local imgui = require('ImGui')
local ImAnim = require('lib.imanim')
local AnimHelpers = require('ui.animation_helpers')
local Core = require('utils.core')
local ActorsCoordinator = require('utils.actors_coordinator')

local M = {}

local State = {
    open = false,
    selectedAbilities = {},  -- { [charName] = { [abilityName] = true } }
    settingsOpen = false,
}

-- Load saved selections from INI
local function loadSelections()
    local sec = Core.Ini['RemoteAbilities'] or {}
    for charName, csv in pairs(sec) do
        State.selectedAbilities[charName] = {}
        for abilityName in string.gmatch(csv or '', '([^,]+)') do
            abilityName = abilityName:match('^%s*(.-)%s*$')
            if abilityName ~= '' then
                State.selectedAbilities[charName][abilityName] = true
            end
        end
    end
end

-- Save selections to INI
local function saveSelections()
    Core.Ini['RemoteAbilities'] = Core.Ini['RemoteAbilities'] or {}
    for charName, abilities in pairs(State.selectedAbilities) do
        local list = {}
        for abilityName, enabled in pairs(abilities) do
            if enabled then table.insert(list, abilityName) end
        end
        Core.Ini['RemoteAbilities'][charName] = table.concat(list, ',')
    end
    Core.save()
end

return M
```

**Step 2: Add the executeRemoteAbility function**

```lua
local function executeRemoteAbility(charName, ability)
    local kind = ability.kind or 'aa'
    if kind == 'aa' and ability.altID then
        mq.cmdf('/dex %s /alt activate %d', charName, ability.altID)
    elseif kind == 'disc' and ability.discName then
        mq.cmdf('/dex %s /disc %s', charName, ability.discName)
    elseif kind == 'ability' and ability.altName then
        mq.cmdf('/dex %s /doability %s', charName, ability.altName)
    elseif kind == 'item' and ability.itemName then
        mq.cmdf('/dex %s /useitem "%s"', charName, ability.itemName)
    end
end
```

**Step 3: Add the main bar draw function**

```lua
function M.draw()
    if not State.open then return end

    local remoteChars = ActorsCoordinator.getRemoteCharacters()
    if not next(remoteChars) then return end

    imgui.SetNextWindowSize(400, 100, ImGuiCond.FirstUseEver)
    local open, show = imgui.Begin('Remote Abilities##SideKick', true, ImGuiWindowFlags.NoScrollbar)
    if not open then
        State.open = false
        imgui.End()
        return
    end

    for charName, data in pairs(remoteChars) do
        local selected = State.selectedAbilities[charName] or {}
        local hasAny = false
        for abilityName, _ in pairs(selected) do
            if data.abilities[abilityName] then hasAny = true break end
        end

        if hasAny then
            imgui.Text(charName)
            imgui.SameLine()

            for abilityName, enabled in pairs(selected) do
                if enabled then
                    local ability = data.abilities[abilityName]
                    if ability then
                        local label = ability.shortName or abilityName
                        local ready = ability.ready == true

                        if not ready then
                            imgui.BeginDisabled()
                        end

                        if imgui.Button(label .. '##' .. charName .. '_' .. abilityName) then
                            executeRemoteAbility(charName, ability)
                        end

                        if not ready then
                            imgui.EndDisabled()
                        end

                        if imgui.IsItemHovered() then
                            imgui.SetTooltip('%s: %s%s', charName, abilityName,
                                ready and '' or string.format(' (CD: %.1fs)', ability.cooldown or 0))
                        end

                        imgui.SameLine()
                    end
                end
            end
            imgui.NewLine()
        end
    end

    imgui.End()
end
```

**Step 4: Add settings panel for ability selection**

```lua
function M.drawSettings()
    if not State.settingsOpen then return end

    local remoteChars = ActorsCoordinator.getRemoteCharacters()

    imgui.SetNextWindowSize(350, 400, ImGuiCond.FirstUseEver)
    local open, show = imgui.Begin('Remote Abilities Settings##SideKick', true)
    if not open then
        State.settingsOpen = false
        saveSelections()
        imgui.End()
        return
    end

    if not next(remoteChars) then
        imgui.Text('No remote SideKick instances detected.')
        imgui.End()
        return
    end

    for charName, data in pairs(remoteChars) do
        if imgui.CollapsingHeader(charName .. ' (' .. (data.class or '?') .. ')') then
            State.selectedAbilities[charName] = State.selectedAbilities[charName] or {}

            for abilityName, ability in pairs(data.abilities or {}) do
                local enabled = State.selectedAbilities[charName][abilityName] == true
                local changed
                enabled, changed = imgui.Checkbox(ability.shortName or abilityName .. '##' .. charName, enabled)
                if changed then
                    State.selectedAbilities[charName][abilityName] = enabled
                end
            end
        end
    end

    imgui.Separator()
    if imgui.Button('Save & Close') then
        saveSelections()
        State.settingsOpen = false
    end

    imgui.End()
end

function M.toggleSettings()
    State.settingsOpen = not State.settingsOpen
end

function M.setOpen(open)
    State.open = open
end

function M.isOpen()
    return State.open
end

function M.init()
    loadSelections()
end
```

**Step 5: Commit**

```bash
git add ui/remote_abilities.lua
git commit -m "feat(ui): add remote ability bar for executing abilities on boxed characters"
```

---

## Task 4: Integrate Remote Abilities into SideKick.lua

**Files:**
- Modify: `F:/lua/SideKick/SideKick.lua`

**Step 1: Require the new module**

Near the top with other requires:

```lua
local RemoteAbilities = require('ui.remote_abilities')
```

**Step 2: Initialize in the init section**

Find where other modules are initialized and add:

```lua
RemoteAbilities.init()
```

**Step 3: Add draw calls in the main render function**

Find the ImGui render callback and add:

```lua
RemoteAbilities.draw()
RemoteAbilities.drawSettings()
```

**Step 4: Add toggle in settings UI**

In the settings panel, add a checkbox and button:

```lua
-- In settings section
if imgui.Checkbox('Show Remote Ability Bar', RemoteAbilities.isOpen()) then
    RemoteAbilities.setOpen(not RemoteAbilities.isOpen())
end
if imgui.Button('Configure Remote Abilities') then
    RemoteAbilities.toggleSettings()
end
```

**Step 5: Commit**

```bash
git add SideKick.lua
git commit -m "feat: integrate remote ability bar into main SideKick UI"
```

---

## Task 5: Enhance Animation Helpers with Ready Pulse

**Files:**
- Modify: `F:/lua/SideKick/ui/animation_helpers.lua`

**Step 1: Add ready pulse oscillation function**

```lua
function M.getReadyPulseAlpha(uniqueId, isReady)
    if not isReady then return 1.0 end

    if _ImAnim and _ImAnim.oscillate then
        -- Gentle glow oscillation between 0.7 and 1.0 at 2Hz
        return _ImAnim.oscillate(uniqueId .. '_ready_pulse', 'sine', 0.7, 1.0, 2.0)
    end
    return 1.0
end
```

**Step 2: Add ready glow color function**

```lua
function M.getReadyGlowColor(uniqueId, isReady, baseColor)
    if not isReady then return baseColor end

    local pulse = M.getReadyPulseAlpha(uniqueId, true)
    -- Interpolate toward a brighter/golden color when ready
    local r = baseColor[1] + (1.0 - baseColor[1]) * (1.0 - pulse) * 0.3
    local g = baseColor[2] + (0.9 - baseColor[2]) * (1.0 - pulse) * 0.3
    local b = baseColor[3]
    local a = baseColor[4] or 1.0

    return {r, g, b, a}
end
```

**Step 3: Commit**

```bash
git add ui/animation_helpers.lua
git commit -m "feat(animation): add ready pulse glow effect for abilities"
```

---

## Task 6: Add Low Resource Warning Animation

**Files:**
- Modify: `F:/lua/SideKick/ui/animation_helpers.lua`

**Step 1: Add low resource pulse function**

```lua
local _lowResourceThreshold = 0.20  -- 20%

function M.getLowResourcePulse(uniqueId, currentPct, threshold)
    threshold = threshold or _lowResourceThreshold
    if currentPct >= threshold then return 1.0, nil end

    -- Pulse faster as resource gets lower
    local urgency = 1.0 - (currentPct / threshold)
    local freq = 1.5 + urgency * 2.0  -- 1.5Hz to 3.5Hz

    if _ImAnim and _ImAnim.oscillate then
        local pulse = _ImAnim.oscillate(uniqueId .. '_low_res', 'sine', 0.5, 1.0, freq)
        -- Return pulse value and warning color (red)
        return pulse, {1.0, 0.2, 0.2, pulse}
    end
    return 1.0, nil
end
```

**Step 2: Commit**

```bash
git add ui/animation_helpers.lua
git commit -m "feat(animation): add low resource warning pulse"
```

---

## Task 7: Add Damage Flash Detection

**Files:**
- Modify: `F:/lua/SideKick/ui/animation_helpers.lua`

**Step 1: Add damage tracking state**

```lua
local _lastHpValues = {}
local _damageFlashState = {}
```

**Step 2: Add damage flash function**

```lua
function M.getDamageFlash(uniqueId, currentHp, flashDuration)
    flashDuration = flashDuration or 0.3
    local now = os.clock()

    local lastHp = _lastHpValues[uniqueId] or currentHp
    local flashState = _damageFlashState[uniqueId] or { active = false, startTime = 0 }

    -- Detect significant HP drop (>5%)
    local hpDrop = lastHp - currentHp
    if hpDrop > 5 then
        flashState.active = true
        flashState.startTime = now
    end

    _lastHpValues[uniqueId] = currentHp

    -- Calculate flash intensity
    local intensity = 0
    if flashState.active then
        local elapsed = now - flashState.startTime
        if elapsed < flashDuration then
            intensity = 1.0 - (elapsed / flashDuration)
        else
            flashState.active = false
        end
    end

    _damageFlashState[uniqueId] = flashState

    -- Return flash color overlay (red with fading alpha)
    if intensity > 0 then
        return {1.0, 0.0, 0.0, intensity * 0.5}
    end
    return nil
end
```

**Step 3: Commit**

```bash
git add ui/animation_helpers.lua
git commit -m "feat(animation): add damage flash detection and overlay"
```

---

## Task 8: Add Toggle Button Animations

**Files:**
- Modify: `F:/lua/SideKick/ui/animation_helpers.lua`

**Step 1: Add toggle state tracking**

```lua
local _toggleStates = {}
```

**Step 2: Add toggle animation functions**

```lua
function M.getToggleScale(uniqueId, isActive)
    local prevState = _toggleStates[uniqueId]
    local justActivated = isActive and not prevState
    _toggleStates[uniqueId] = isActive

    -- Trigger pop animation when toggled on
    if justActivated and _ImAnim and _ImAnim.trigger_shake then
        _ImAnim.trigger_shake(uniqueId .. '_toggle_pop')
    end

    -- Spring-based pop effect
    if _ImAnim and _ImAnim.spring then
        local target = isActive and 1.0 or 1.0
        if justActivated then
            -- Temporarily target larger scale for pop
            return _ImAnim.spring(uniqueId .. '_toggle_scale', 1.15, 500, 20)
        end
        return _ImAnim.spring(uniqueId .. '_toggle_scale', target, 300, 25)
    end
    return 1.0
end

function M.getToggleColor(uniqueId, isActive, onColor, offColor)
    if not _ImAnim or not _ImAnim.tween_vec4 then
        return isActive and onColor or offColor
    end

    local target = isActive and onColor or offColor
    return _ImAnim.tween_vec4(uniqueId .. '_toggle_color', target, 0.2, _ImAnim.EASE.out_cubic)
end
```

**Step 3: Commit**

```bash
git add ui/animation_helpers.lua
git commit -m "feat(animation): add toggle button pop and color transition effects"
```

---

## Task 9: Create Aggro Warning Module

**Files:**
- Create: `F:/lua/SideKick/ui/aggro_warning.lua`

**Step 1: Create the module with detection logic**

```lua
local mq = require('mq')
local imgui = require('ImGui')
local ImAnim = require('lib.imanim')
local Core = require('utils.core')

local M = {}

local TANK_CLASSES = { WAR = true, PAL = true, SHD = true }

local State = {
    enabled = true,
    threshold = 98,
    duration = 3.0,
    cooldown = 5.0,

    showing = false,
    showStartTime = 0,
    lastWarningTime = 0,
}

local function loadSettings()
    local sec = Core.Ini['AggroWarning'] or {}
    State.enabled = sec.enabled ~= false and sec.enabled ~= 'false'
    State.threshold = tonumber(sec.threshold) or 98
    State.duration = tonumber(sec.duration) or 3.0
    State.cooldown = tonumber(sec.cooldown) or 5.0
end

local function saveSettings()
    Core.Ini['AggroWarning'] = {
        enabled = State.enabled,
        threshold = State.threshold,
        duration = State.duration,
        cooldown = State.cooldown,
    }
    Core.save()
end

local function shouldShowWarning()
    if not State.enabled then return false end

    local me = mq.TLO.Me
    if not me or not me() then return false end

    -- Not in raid
    local raidMembers = mq.TLO.Raid and mq.TLO.Raid.Members and mq.TLO.Raid.Members() or 0
    if (tonumber(raidMembers) or 0) == 0 then return false end

    -- Is a tank class
    local myClass = me.Class and me.Class.ShortName and me.Class.ShortName() or ''
    if TANK_CLASSES[myClass:upper()] then return false end

    -- No target
    local target = mq.TLO.Target
    if not target or not target.ID or not target.ID() then return false end

    -- Target HP too high
    local targetHp = target.PctHPs and target.PctHPs() or 100
    if (tonumber(targetHp) or 100) >= State.threshold then return false end

    -- Check if we have aggro
    local aggroHolderId = target.AggroHolder and target.AggroHolder.ID and target.AggroHolder.ID()
    local myId = me.ID and me.ID() or 0

    if aggroHolderId == myId then return true end

    -- Also check XTarget
    for i = 1, 13 do
        local xt = me.XTarget and me.XTarget(i)
        if xt and xt.TargetType then
            local targetType = xt.TargetType()
            if targetType == 'Auto Hater' then
                local xtId = xt.ID and xt.ID() or 0
                local targetId = target.ID and target.ID() or -1
                if xtId == targetId then
                    return true
                end
            end
        end
    end

    return false
end

return M
```

**Step 2: Add the update and draw functions**

```lua
function M.update()
    if not State.enabled then
        State.showing = false
        return
    end

    local now = os.clock()

    -- Check if we should trigger warning
    if not State.showing then
        if shouldShowWarning() then
            -- Respect cooldown
            if (now - State.lastWarningTime) >= State.cooldown then
                State.showing = true
                State.showStartTime = now
                State.lastWarningTime = now

                -- Trigger shake animation
                if ImAnim and ImAnim.trigger_shake then
                    ImAnim.trigger_shake('aggro_warning')
                end
            end
        end
    else
        -- Check if we should hide
        local elapsed = now - State.showStartTime
        if elapsed >= State.duration then
            State.showing = false
        elseif not shouldShowWarning() then
            -- Aggro lost, hide early
            State.showing = false
        end
    end
end

function M.draw()
    if not State.showing then return end

    local now = os.clock()
    local elapsed = now - State.showStartTime
    local progress = elapsed / State.duration

    -- Get screen center
    local displaySize = imgui.GetIO().DisplaySize
    local centerX = displaySize.x / 2
    local centerY = displaySize.y / 2

    -- Calculate scale (spring in, then settle)
    local scale = 1.0
    if ImAnim and ImAnim.spring then
        local targetScale = progress < 0.1 and 1.2 or 1.0
        scale = ImAnim.spring('aggro_scale', targetScale, 400, 20)
    end

    -- Calculate shake offset
    local shakeX, shakeY = 0, 0
    if ImAnim and ImAnim.shake then
        shakeX = ImAnim.shake('aggro_warning', 15, 0.5)
        shakeY = ImAnim.shake('aggro_warning_y', 10, 0.5)
    end

    -- Calculate pulse for glow
    local pulse = 1.0
    if ImAnim and ImAnim.oscillate then
        pulse = ImAnim.oscillate('aggro_pulse', 'sine', 0.7, 1.0, 4.0)
    end

    -- Calculate fade out near end
    local alpha = 1.0
    if progress > 0.7 then
        alpha = 1.0 - ((progress - 0.7) / 0.3)
    end

    -- Draw the warning
    local text = 'AGGRO!'
    local fontSize = 72 * scale

    imgui.SetNextWindowPos(centerX + shakeX, centerY + shakeY, ImGuiCond.Always, 0.5, 0.5)
    imgui.SetNextWindowBgAlpha(0)
    imgui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, 0)

    local flags = ImGuiWindowFlags.NoTitleBar + ImGuiWindowFlags.NoResize +
                  ImGuiWindowFlags.NoMove + ImGuiWindowFlags.NoScrollbar +
                  ImGuiWindowFlags.NoInputs + ImGuiWindowFlags.AlwaysAutoResize

    if imgui.Begin('##AggroWarning', true, flags) then
        -- Red pulsing text
        local r, g, b = 1.0, 0.1 * pulse, 0.1 * pulse
        imgui.PushStyleColor(ImGuiCol.Text, r, g, b, alpha)
        imgui.SetWindowFontScale(scale * 3)
        imgui.Text(text)
        imgui.SetWindowFontScale(1.0)
        imgui.PopStyleColor()
    end
    imgui.End()
    imgui.PopStyleVar()
end
```

**Step 3: Add settings functions**

```lua
function M.drawSettings()
    local changed = false

    local enabled, e1 = imgui.Checkbox('Enable Aggro Warning', State.enabled)
    if e1 then State.enabled = enabled; changed = true end

    if State.enabled then
        imgui.Indent()

        local threshold, t1 = imgui.SliderInt('HP Threshold##aggro', State.threshold, 50, 100)
        if t1 then State.threshold = threshold; changed = true end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Only warn if target HP is below this %%')
        end

        local duration, d1 = imgui.SliderFloat('Display Duration##aggro', State.duration, 1.0, 10.0, '%.1f sec')
        if d1 then State.duration = duration; changed = true end

        local cooldown, c1 = imgui.SliderFloat('Cooldown##aggro', State.cooldown, 1.0, 30.0, '%.1f sec')
        if c1 then State.cooldown = cooldown; changed = true end

        imgui.Unindent()
    end

    if changed then saveSettings() end
end

function M.init()
    loadSettings()
end

function M.isEnabled()
    return State.enabled
end

function M.setEnabled(enabled)
    State.enabled = enabled
    saveSettings()
end
```

**Step 4: Commit**

```bash
git add ui/aggro_warning.lua
git commit -m "feat(ui): add aggro warning overlay for non-tanks in raids"
```

---

## Task 10: Integrate Aggro Warning into SideKick.lua

**Files:**
- Modify: `F:/lua/SideKick/SideKick.lua`

**Step 1: Require the module**

```lua
local AggroWarning = require('ui.aggro_warning')
```

**Step 2: Initialize**

```lua
AggroWarning.init()
```

**Step 3: Add to main loop tick**

In the main tick/update function:

```lua
AggroWarning.update()
```

**Step 4: Add to render function**

```lua
AggroWarning.draw()
```

**Step 5: Add settings section**

In the settings UI, add a new section:

```lua
if imgui.CollapsingHeader('Warnings') then
    AggroWarning.drawSettings()
end
```

**Step 6: Commit**

```bash
git add SideKick.lua
git commit -m "feat: integrate aggro warning system into SideKick"
```

---

## Task 11: Apply Animations to Existing Ability Bars

**Files:**
- Modify: `F:/lua/SideKick/ui/bar_animated.lua`

**Step 1: Add ready pulse to ability buttons**

Find the button rendering code and enhance with:

```lua
local isReady = not onCooldown
local pulseAlpha = AnimHelpers.getReadyPulseAlpha(uniqueId, isReady)

-- Apply pulse to button or glow overlay
if isReady and pulseAlpha < 1.0 then
    -- Draw subtle glow behind button
    local glowColor = {0.4, 0.8, 0.2, (1.0 - pulseAlpha) * 0.3}
    -- Draw glow rect slightly larger than button
end
```

**Step 2: Verify animations work**

Run SideKick, ensure abilities pulse when ready, and buttons scale on hover/click.

**Step 3: Commit**

```bash
git add ui/bar_animated.lua
git commit -m "feat(ui): apply ready pulse animation to ability bar"
```

---

## Task 12: Final Integration Testing

**Step 1: Test Remote Ability Bar**

1. Start SideKick on two characters
2. On driver, open Remote Abilities settings
3. Select abilities from the other character
4. Verify clicking executes via /dex

**Step 2: Test Animations**

1. Verify cooldown sweep displays correctly
2. Verify ready pulse on available abilities
3. Verify toggle button pop effect
4. Verify hover scaling

**Step 3: Test Aggro Warning**

1. Join a raid
2. On a non-tank character, gain aggro on a mob below 98% HP
3. Verify center-screen "AGGRO!" appears with animation
4. Verify it auto-dismisses and respects cooldown

**Step 4: Final commit**

```bash
git add .
git commit -m "feat: complete SideKick enhancements - remote abilities, animations, aggro warning"
```

---

## Summary

| Task | Feature | Files |
|------|---------|-------|
| 1 | Remote Abilities | actors/shareddata.lua |
| 2 | Remote Abilities | utils/actors_coordinator.lua |
| 3-4 | Remote Abilities | ui/remote_abilities.lua, SideKick.lua |
| 5-8 | UI Animations | ui/animation_helpers.lua |
| 9-10 | Aggro Warning | ui/aggro_warning.lua, SideKick.lua |
| 11 | UI Animations | ui/bar_animated.lua |
| 12 | Integration | All |
