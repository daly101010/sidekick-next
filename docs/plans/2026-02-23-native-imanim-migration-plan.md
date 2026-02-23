# Native ImAnim Migration & Enhancement Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Migrate all animation from the pure-Lua wrapper (`lib/imanim.lua`) to the native `require('ImAnim')` C++ module, adding 14 visual enhancements along the way (rounded buttons, radial cooldown sweep, theme crossfade, gradients, text stagger, etc.).

**Architecture:** Migrate-per-system — each task migrates its animation system to native while adding the visual enhancement. The `animation_helpers.lua` integration layer stays as the bridge between game logic and native ImAnim, keeping its dt cache, ID cache, and early-exit settings checks. The 871-line `lib/imanim.lua` wrapper is deleted at the end.

**Tech Stack:** Native `require('ImAnim')` C++ module (PascalCase API), global enums (`IamEaseType`, `IamPolicy`, `IamColorSpace`, `IamWaveType`, etc.), `IamEaseDesc` objects, `IamClip` keyframe system, `IamGradient`, `IamPath`, `IamTextStaggerOpts`.

**Design Doc:** `docs/plans/2026-02-23-native-imanim-migration-design.md`

**Import sites to migrate** (7 files):
- `SideKick.lua:76`
- `ui/bar_animated.lua:3`
- `ui/disc_bar_animated.lua:3`
- `ui/special_bar_animated.lua:2`
- `ui/item_bar_animated.lua:3`
- `ui/remote_abilities.lua:3`
- `ui/aggro_warning.lua:3`

---

## Task 1: Phase 1A — Migrate animation_helpers.lua to Native ImAnim

**Files:**
- Modify: `ui/animation_helpers.lua`

This is the core migration — `animation_helpers.lua` is the single integration layer that ALL bar files call. Once this file speaks native, every consumer benefits.

**Step 1: Add native ImAnim require at top of animation_helpers.lua**

Replace the injection pattern. Currently `_ImAnim` is passed via `M.init(ImAnim, settings)`. Add a direct native require at module scope:

```lua
-- At top of file, after existing requires
local iam = require('ImAnim')
```

Keep the `M.init(ImAnim, settings)` function for backward compat during migration, but internally all animation calls will use `iam` (the native module).

**Step 2: Create cached ease descriptors at module scope**

These are expensive to create per-frame. Cache them once:

```lua
-- Cached ease descriptors (created once at module load)
local _ezOutCubic = iam.EasePreset(IamEaseType.OutCubic)
local _ezOutBack = iam.EasePreset(IamEaseType.OutBack)
local _ezOutElastic = iam.EasePreset(IamEaseType.OutElastic)
local _ezOutSine = iam.EasePreset(IamEaseType.OutSine)
local _ezLinear = iam.EasePreset(IamEaseType.Linear)

-- Spring ease descriptors (match existing constants from constants.lua)
local _ezSpringNormal = iam.EaseSpring(1.0, C.ANIMATION.SPRING_STIFFNESS, C.ANIMATION.SPRING_DAMPING, 0.0)
local _ezSpringFast = iam.EaseSpring(1.0, C.ANIMATION.SPRING_STIFFNESS_FAST, C.ANIMATION.SPRING_DAMPING_FAST, 0.0)
local _ezSpringSlow = iam.EaseSpring(1.0, C.ANIMATION.SPRING_STIFFNESS_SLOW, C.ANIMATION.SPRING_DAMPING_SLOW, 0.0)
```

**Step 3: Migrate `getButtonScale()` to native spring**

Replace the `_ImAnim.spring()` call:

```lua
function M.getButtonScale(uniqueId, isHovered, isActive)
    if not _settings or not _settings.SideKickAnimateButtons then return 1.0 end
    local dt = M.get_dt()
    local target = isActive and C.ANIMATION.PRESS_SCALE
                or isHovered and C.ANIMATION.HOVER_SCALE
                or 1.0
    local ez = isActive and _ezSpringFast or _ezSpringNormal
    return iam.TweenFloat(uniqueId, imgui.GetID('scale'), target, 0.5, ez, IamPolicy.Crossfade, dt)
end
```

**Step 4: Migrate `checkCooldownCompletion()` and `getCompletionPulse()` to native shake**

```lua
function M.checkCooldownCompletion(uniqueId, onCooldown)
    if not _settings or not _settings.SideKickAnimateButtons then return end
    local prev = _cooldownStates[uniqueId]
    _cooldownStates[uniqueId] = onCooldown
    if prev and not onCooldown then
        iam.TriggerShake(uniqueId)
    end
end

function M.getCompletionPulse(uniqueId)
    if not _settings or not _settings.SideKickAnimateButtons then return 0 end
    local dt = M.get_dt()
    return iam.Shake(uniqueId, imgui.GetID('pulse'), C.ANIMATION.SHAKE_MAGNITUDE, C.ANIMATION.SHAKE_DECAY, dt)
end
```

**Step 5: Migrate `getToggleScale()` and `getTogglePop()` to native**

```lua
function M.getToggleScale(uniqueId, isActive)
    if not _settings or not _settings.SideKickAnimateButtons then return 1.0 end
    local dt = M.get_dt()
    local prev = _toggleStates[uniqueId]
    _toggleStates[uniqueId] = isActive
    if prev ~= nil and prev ~= isActive and isActive then
        iam.TriggerShake(uniqueId .. '_toggle')
    end
    local target = 1.0
    local ez = isActive and _ezSpringFast or _ezSpringSlow
    return iam.TweenFloat(uniqueId, imgui.GetID('tscale'), target, 0.5, ez, IamPolicy.Crossfade, dt)
end

function M.getTogglePop(uniqueId)
    if not _settings or not _settings.SideKickAnimateButtons then return 0 end
    local dt = M.get_dt()
    return iam.Shake(uniqueId .. '_toggle', imgui.GetID('tpop'), C.ANIMATION.SHAKE_MAGNITUDE * 0.5, C.ANIMATION.SHAKE_DECAY, dt)
end
```

**Step 6: Migrate `getToggleColor()` to native TweenColor**

```lua
function M.getToggleColor(uniqueId, isActive, onColor, offColor)
    if not _settings or not _settings.SideKickAnimateButtons then
        return isActive and onColor or offColor
    end
    local dt = M.get_dt()
    local target = isActive and onColor or offColor
    local col = iam.TweenColor(
        uniqueId, imgui.GetID('tcol'),
        ImVec4(target[1], target[2], target[3], target[4] or 1.0),
        C.ANIMATION.TWEEN_FAST, _ezOutCubic, IamPolicy.Crossfade,
        IamColorSpace.OKLAB, dt
    )
    return { col.x, col.y, col.z, col.w }
end
```

**Step 7: Migrate `getCooldownColor()` to native TweenColor**

```lua
function M.getCooldownColor(uniqueId, pct)
    local dt = M.get_dt()
    local r, g, b = Colors.cooldownRGB(pct)
    local col = iam.TweenColor(
        uniqueId, imgui.GetID('cdcol'),
        ImVec4(r, g, b, 1.0),
        C.ANIMATION.TWEEN_FAST, _ezOutCubic, IamPolicy.Crossfade,
        IamColorSpace.OKLAB, dt
    )
    return col.x, col.y, col.z, col.w
end
```

**Step 8: Migrate `getReadyPulseAlpha()` to native Oscillate**

```lua
function M.getReadyPulseAlpha(uniqueId, isReady)
    if not isReady then return 1.0 end
    local dt = M.get_dt()
    local wave = iam.Oscillate(uniqueId, imgui.GetID('rpulse'),
        0.15, C.ANIMATION.READY_PULSE_FREQ, 0.0, IamWaveType.Sine, dt)
    return 0.85 + wave  -- oscillates 0.7 to 1.0
end
```

**Step 9: Migrate `getLowResourcePulse()` to native Oscillate**

```lua
function M.getLowResourcePulse(uniqueId, currentPct, threshold)
    if not _settings or not _settings.SideKickAnimateLowResource then return 0, nil end
    threshold = threshold or C.RESOURCE.LOW_THRESHOLD
    if currentPct > threshold then return 0, nil end
    local dt = M.get_dt()
    local severity = 1 - (currentPct / threshold)
    local freq = C.ANIMATION.LOW_RESOURCE_PULSE_FREQ_MIN +
                 severity * (C.ANIMATION.LOW_RESOURCE_PULSE_FREQ_MAX - C.ANIMATION.LOW_RESOURCE_PULSE_FREQ_MIN)
    local pulse = iam.Oscillate(uniqueId, imgui.GetID('lrpulse'),
        0.5, freq, 0.0, IamWaveType.Sine, dt)
    pulse = (pulse + 0.5) * severity  -- normalize to 0..severity
    local color = Colors.lowResource(severity)
    return pulse, color
end
```

**Step 10: Migrate stagger functions to native**

Remove `updateStaggerFrame()` (no longer needed — MQ handles frame updates). Migrate `getStaggerAlpha()`:

```lua
function M.updateStaggerFrame()
    -- No-op: native ImAnim handles frame updates automatically
end

function M.getStaggerAlpha(gridKey, idx, total, delay)
    if not _settings or not _settings.SideKickAnimateStagger then return 1.0 end
    local dt = M.get_dt()
    delay = delay or C.ANIMATION.STAGGER_DELAY
    local staggerOffset = iam.StaggerDelay(idx, total, delay)
    local elapsed = M.getGridEntryElapsed(gridKey)
    if elapsed > C.ANIMATION.STAGGER_DURATION + (total * delay) then return 1.0 end
    local t = math.max(0, math.min(1, (elapsed - staggerOffset) / C.ANIMATION.STAGGER_DURATION))
    return iam.EvalPreset(IamEaseType.OutCubic, t)
end
```

**Step 11: Remove GC calls for wrapper state**

In `maybeRunGc()`, remove calls to `_ImAnim.gc()` and `_ImAnim.clip_gc()` — native C++ manages its own memory. Keep the ID cache clearing and tracking table cleanup.

**Step 12: Commit**

```bash
git add ui/animation_helpers.lua
git commit -m "feat: migrate animation_helpers.lua to native ImAnim API

Replace all wrapper calls (spring, tween_float, tween_color, oscillate,
trigger_shake, shake, stagger) with native require('ImAnim') equivalents.
Cache ease descriptors at module scope for performance."
```

---

## Task 2: Phase 1B — Rounded Buttons with Shadow & Glow

**Files:**
- Modify: `ui/constants.lua`
- Modify: `ui/bar_animated.lua`
- Modify: `ui/draw_helpers.lua` (add PathArcTo wrappers — needed for Task 3 too)

**Step 1: Add rounded button constants**

In `ui/constants.lua`, add to `M.LAYOUT`:

```lua
    -- Button rounding (% of cell size, 0.0 = square, 0.5 = pill)
    BUTTON_ROUNDING_PCT = 0.4,

    -- Shadow
    SHADOW_OFFSET_X = 2,
    SHADOW_OFFSET_Y = 3,
    SHADOW_ALPHA_NORMAL = 75,    -- 0-255
    SHADOW_ALPHA_HOVER = 120,

    -- Glow
    GLOW_EXPAND = 2,             -- pixels larger than cell
    GLOW_ALPHA_MAX = 150,        -- 0-255
```

**Step 2: Add PathArcTo and PathFillConvex wrappers to draw_helpers.lua**

Add before the `return M` at end of `ui/draw_helpers.lua`:

```lua
-- PathArcTo wrapper (for radial cooldown sweep)
function M.pathArcTo(dl, cx, cy, radius, a_min, a_max, segments)
    if not dl then return false end
    segments = segments or 32
    if _useImVec2 and _imVec2Func then
        local ok = pcall(function() dl:PathArcTo(_imVec2Func(cx, cy), radius, a_min, a_max, segments) end)
        if ok then return true end
    end
    local ok = pcall(function() dl:PathArcTo(cx, cy, radius, a_min, a_max, segments) end)
    return ok == true
end

-- PathLineTo wrapper
function M.pathLineTo(dl, x, y)
    if not dl then return false end
    if _useImVec2 and _imVec2Func then
        local ok = pcall(function() dl:PathLineTo(_imVec2Func(x, y)) end)
        if ok then return true end
    end
    local ok = pcall(function() dl:PathLineTo(x, y) end)
    return ok == true
end

-- PathFillConvex wrapper
function M.pathFillConvex(dl, col)
    if not dl then return false end
    local ok = pcall(function() dl:PathFillConvex(col) end)
    return ok == true
end

-- PathClear wrapper
function M.pathClear(dl)
    if not dl then return false end
    local ok = pcall(function() dl:PathClear() end)
    return ok == true
end
```

**Step 3: Modify bar_animated.lua cell rendering for rounding, shadow, and glow**

Replace the flat `AddRectFilled` call at the cell draw site with the new layered rendering. In `bar_animated.lua`, require native ImAnim and update the cell draw loop (around the `minX, minY, sw, sh` usage after `scaleFromCenter`):

At top of file, change:
```lua
local ImAnim = require('sidekick-next.lib.imanim')
```
to:
```lua
local iam = require('ImAnim')
```

In the cell rendering section (after computing `minX, minY, sw, sh` from `scaleFromCenter` and applying `pulse`), add shadow, background, and glow:

```lua
local rounding = math.floor(cell * C.LAYOUT.BUTTON_ROUNDING_PCT)
local dt = AnimHelpers.get_dt()

-- Shadow (drawn first, behind everything)
local shadowAlpha = iam.TweenFloat(
    uniqueId, imgui.GetID('shadow'),
    hovered and C.LAYOUT.SHADOW_ALPHA_HOVER or C.LAYOUT.SHADOW_ALPHA_NORMAL,
    0.15, _ezOutCubic, IamPolicy.Crossfade, dt)
local shadowCol = Draw.IM_COL32(0, 0, 0, math.floor(shadowAlpha))
Draw.addRectFilled(dl,
    minX + C.LAYOUT.SHADOW_OFFSET_X,
    minY + C.LAYOUT.SHADOW_OFFSET_Y,
    minX + sw + C.LAYOUT.SHADOW_OFFSET_X,
    minY + sh + C.LAYOUT.SHADOW_OFFSET_Y,
    shadowCol, rounding)

-- Button background
Draw.addRectFilled(dl, minX, minY, minX + sw, minY + sh,
    Draw.IM_COL32(30, 30, 30, 220), rounding)

-- Glow on hover (drawn around cell, 2px larger)
local glowAlpha = iam.TweenFloat(
    uniqueId, imgui.GetID('glow'),
    hovered and C.LAYOUT.GLOW_ALPHA_MAX or 0,
    0.15, _ezOutCubic, IamPolicy.Crossfade, dt)
if glowAlpha > 1 then
    local accentColor = Colors.ready(themeName)
    local glowCol = Draw.IM_COL32(accentColor[1], accentColor[2], accentColor[3], math.floor(glowAlpha))
    local expand = C.LAYOUT.GLOW_EXPAND
    Draw.addRect(dl,
        minX - expand, minY - expand,
        minX + sw + expand, minY + sh + expand,
        glowCol, rounding + expand, 0, 2)
end

-- Clip to rounded rect for icon and overlays
imgui.PushClipRect(minX, minY, minX + sw, minY + sh, true)
```

After all icon and overlay drawing, pop the clip:
```lua
imgui.PopClipRect()
```

**Step 4: Cache ease descriptors at module scope in bar_animated.lua**

```lua
local _ezOutCubic = iam.EasePreset(IamEaseType.OutCubic)
```

**Step 5: Commit**

```bash
git add ui/constants.lua ui/bar_animated.lua ui/draw_helpers.lua
git commit -m "feat: rounded buttons with shadow and glow hover effect

Add BUTTON_ROUNDING_PCT, shadow offset, and glow constants.
Add DrawList PathArcTo/PathLineTo/PathFillConvex wrappers.
Render button cells with rounding, drop shadow (alpha tweened on hover),
and accent-colored glow ring on hover using native TweenFloat."
```

---

## Task 3: Phase 2 — Radial Sweep Cooldown Timer

**Files:**
- Modify: `ui/animation_helpers.lua` (rewrite `drawCooldownOverlay`)

**Step 1: Rewrite `drawCooldownOverlay()` with radial sweep**

Replace the bottom-up fill with a clock-style pie sweep. The **dark overlay covers the full cell**, then a **clear pie-slice reveals the icon** as cooldown expires:

```lua
function M.drawCooldownOverlay(dl, minX, minY, maxX, maxY, rem, total, uniqueId, helpers, IM_COL32_fn, dlAddRectFilled, dlAddRect, themeName)
    if not dl then return end
    if not rem or not total or total <= 0 then return end

    local dt = M.get_dt()
    local rounding = math.floor((maxX - minX) * C.LAYOUT.BUTTON_ROUNDING_PCT)
    local pct = rem / total  -- 1.0 = full cooldown, 0.0 = ready
    local isReady = pct <= 0

    if isReady then
        -- Ready state: glow overlay
        if _settings and _settings.SideKickAnimateReadyGlow then
            local glow = M.getReadyGlow()
            local accentColor = Colors.ready(themeName)
            local glowCol = Draw.IM_COL32(accentColor[1], accentColor[2], accentColor[3],
                math.floor(glow * C.COLORS.READY_GLOW_ALPHA_MAX))
            Draw.addRectFilled(dl, minX, minY, maxX, maxY, glowCol, rounding)
        end
        return
    end

    -- Cooldown active: draw radial sweep
    local cx = (minX + maxX) / 2
    local cy = (minY + maxY) / 2
    local radius = math.max(maxX - minX, maxY - minY) * 0.71  -- diagonal to cover corners

    -- Get animated cooldown color (OKLAB blended)
    local cr, cg, cb = M.getCooldownColor(uniqueId, pct)

    -- 1. Dark overlay on the ENTIRE cell
    local overlayAlpha = C.COLORS.COOLDOWN_OVERLAY_ALPHA
    Draw.addRectFilled(dl, minX, minY, maxX, maxY,
        Draw.IM_COL32(0, 0, 0, overlayAlpha), rounding)

    -- 2. Tinted color overlay on the ENTIRE cell (shows cooldown color)
    local tintAlpha = math.floor(C.COLORS.COOLDOWN_FILL_ALPHA * 0.5)
    Draw.addRectFilled(dl, minX, minY, maxX, maxY,
        Draw.IM_COL32(math.floor(cr * 255), math.floor(cg * 255), math.floor(cb * 255), tintAlpha),
        rounding)

    -- 3. Clear pie-slice revealing the icon (clockwise from 12 o'clock)
    -- completePct = how much of the cooldown has ELAPSED (0 = just started, 1 = done)
    local completePct = 1.0 - pct
    if completePct > 0.001 then
        local startAngle = -math.pi / 2  -- 12 o'clock
        local endAngle = startAngle + completePct * math.pi * 2

        -- Draw transparent pie slice using PathArcTo
        -- We draw the "clear" area by overlaying with the dark+tint colors inverted
        -- Actually: draw the REVEALED portion as a matching dark rect, then overdraw
        -- Simpler approach: clip and re-draw the icon area
        -- Simplest: draw the UNREVEALED portion as a dark pie
        -- Flip: draw dark pie for the REMAINING cooldown portion
        local remainStart = startAngle + completePct * math.pi * 2
        local remainEnd = startAngle + math.pi * 2

        if completePct < 0.999 then
            Draw.pathClear(dl)
            Draw.pathLineTo(dl, cx, cy)
            Draw.pathArcTo(dl, cx, cy, radius, remainStart, remainEnd, 32)
            Draw.pathFillConvex(dl,
                Draw.IM_COL32(0, 0, 0, overlayAlpha))

            -- Tinted color on remaining portion
            Draw.pathClear(dl)
            Draw.pathLineTo(dl, cx, cy)
            Draw.pathArcTo(dl, cx, cy, radius, remainStart, remainEnd, 32)
            Draw.pathFillConvex(dl,
                Draw.IM_COL32(math.floor(cr * 255), math.floor(cg * 255), math.floor(cb * 255), tintAlpha))
        end
    end

    -- 4. Cooldown border (matches cooldown color)
    local borderCol = Draw.IM_COL32(
        math.floor(cr * 255), math.floor(cg * 255), math.floor(cb * 255),
        C.COLORS.COOLDOWN_BORDER_ALPHA)
    Draw.addRect(dl, minX, minY, maxX, maxY, borderCol, rounding, 0, 1)

    -- 5. Countdown text
    if rem > 0 then
        local text = string.format('%.1f', rem)
        if rem >= 10 then text = string.format('%d', math.ceil(rem)) end
        local textW = imgui.CalcTextSize(text)
        local textX = cx - textW / 2
        local textY = cy - imgui.GetTextLineHeight() / 2
        Draw.addText(dl, textX, textY, Draw.IM_COL32(255, 255, 255, 220), text)
    end
end
```

**Step 2: Update `drawCooldownOverlaySimple` wrapper**

Ensure it passes `themeName` through:

```lua
function M.drawCooldownOverlaySimple(dl, minX, minY, maxX, maxY, rem, total, uniqueId, helpers, themeName)
    return M.drawCooldownOverlay(dl, minX, minY, maxX, maxY, rem, total, uniqueId, helpers,
        Draw.IM_COL32, Draw.addRectFilled, Draw.addRect, themeName)
end
```

**Step 3: Commit**

```bash
git add ui/animation_helpers.lua
git commit -m "feat: radial sweep cooldown timer with clock-style pie reveal

Replace bottom-up fill with clockwise pie sweep from 12 o'clock.
Dark overlay covers full cell, pie slice reveals icon as cooldown expires.
Cooldown color transitions via OKLAB TweenColor (red->orange->yellow->green)."
```

---

## Task 4: Phase 3 — Animated Theme Crossfade

**Files:**
- Modify: `themes.lua`
- Modify: `SideKick.lua` (main render loop)

**Step 1: Add style registration to themes.lua**

Add a function to register all themes as ImAnim style snapshots:

```lua
local iam = require('ImAnim')

-- Track registered styles
local _stylesRegistered = false
local _currentThemeTarget = nil

function M.registerAllStyles()
    if _stylesRegistered then return end
    _stylesRegistered = true
    for _, name in ipairs(M.getThemeNames()) do
        M.pushWindowTheme(imgui, name)
        iam.StyleRegisterCurrent(imgui.GetID(name))
        M.popWindowTheme(imgui, name)
    end
end

function M.tweenToTheme(themeName, dt)
    if not _stylesRegistered then M.registerAllStyles() end
    if _currentThemeTarget ~= themeName then
        _currentThemeTarget = themeName
    end
    iam.StyleTween(
        imgui.GetID('sk_theme'),
        imgui.GetID(themeName),
        0.4,
        iam.EasePreset(IamEaseType.OutCubic),
        IamColorSpace.OKLAB,
        dt
    )
end

function M.getCurrentThemeTarget()
    return _currentThemeTarget
end
```

**Step 2: Call theme tween in main render loop**

In `SideKick.lua`, in the ImGui render callback, replace the theme push with the tween call:

```lua
-- Instead of: Themes.pushWindowTheme(imgui, currentTheme)
-- Use:
Themes.tweenToTheme(currentTheme, imgui.GetIO().DeltaTime)
```

**Step 3: Update SideKick.lua import**

Change the ImAnim import:
```lua
-- Old: local ImAnim = require('sidekick-next.lib.imanim')
local iam = require('ImAnim')
```

Remove calls to `ImAnim.update_begin_frame()` — MQ handles this natively.

**Step 4: Commit**

```bash
git add themes.lua SideKick.lua
git commit -m "feat: animated theme crossfade with OKLAB blending

Register all themes as ImAnim style snapshots on init.
Theme changes smoothly blend over 0.4s via StyleTween with OKLAB
color space for perceptually uniform transitions."
```

---

## Task 5: Phase 4A — Toast Notifications with Native Tweens

**Files:**
- Modify: `ui/components/toast.lua`

**Step 1: Add native ImAnim require and cached ease descriptors**

At top of `toast.lua`:

```lua
local iam = require('ImAnim')
local imgui = require('ImGui')

local _ezOutCubic = iam.EasePreset(IamEaseType.OutCubic)
local _ezOutBack = iam.EasePreset(IamEaseType.OutBack)
local _ezPerAxis = IamEasePerAxis(_ezOutCubic, _ezOutBack)
```

**Step 2: Replace manual animation math in render()**

Replace the manual `elapsed / duration` calculations with native tweens. In the toast render loop, for each active toast:

```lua
local dt = imgui.GetIO().DeltaTime

-- Target alpha: 1.0 while visible, 0.0 when fading out
local isFadingOut = (os.clock() - toast.startTime) > (toast.duration - CONFIG.fadeOutTime)
local targetAlpha = isFadingOut and 0.0 or 1.0
local alpha = iam.TweenFloat(
    'toast_' .. toast.id, imgui.GetID('alpha'),
    targetAlpha, isFadingOut and CONFIG.fadeOutTime or CONFIG.fadeInTime,
    _ezOutCubic, IamPolicy.Crossfade, dt)

-- Target Y position (smooth reflow when toasts above dismiss)
local targetY = calculateToastY(idx)  -- compute based on current stack position
local posY = iam.TweenFloat(
    'toast_' .. toast.id, imgui.GetID('y'),
    targetY, 0.25, _ezOutCubic, IamPolicy.Crossfade, dt)

-- Slide-in X offset using per-axis easing (OutBack for slight overshoot)
local slideTarget = 0  -- final position (no offset)
local slideX = iam.TweenFloat(
    'toast_' .. toast.id, imgui.GetID('slideX'),
    slideTarget, 0.3, _ezOutBack, IamPolicy.Crossfade, dt,
    CONFIG.slideDistance)  -- init value: start offset
```

**Step 3: Remove the manual easing functions**

Delete the hand-rolled `easeOutQuad()` and manual elapsed tracking code.

**Step 4: Commit**

```bash
git add ui/components/toast.lua
git commit -m "feat: toast notifications with native ImAnim tweens

Replace manual elapsed/duration math with native TweenFloat.
Add per-axis easing (OutBack on Y for slight overshoot).
Smooth stack reflow when mid-stack toasts dismiss via Crossfade policy."
```

---

## Task 6: Phase 4B — Text Stagger in Toast Messages

**Files:**
- Modify: `ui/components/toast.lua`

**Step 1: Add text stagger to toast message rendering**

After the toast background is drawn, replace `imgui.Text(toast.message)` with staggered text:

```lua
-- Text stagger for message
local textElapsed = os.clock() - toast.startTime
local textDuration = iam.TextStaggerDuration(toast.message, _textStaggerOpts)
local textProgress = math.min(1.0, textElapsed / textDuration)

local staggerOpts = IamTextStaggerOpts()
staggerOpts.pos = ImVec2(textX, textY)
staggerOpts.effect = IamTextStaggerEffect.Fade
staggerOpts.char_delay = 0.02
staggerOpts.char_duration = 0.15
staggerOpts.ease = _ezOutCubic
staggerOpts.color = imgui.GetColorU32(ImGuiCol.Text)

iam.TextStagger(imgui.GetID('toast_text_' .. toast.id), toast.message, textProgress, staggerOpts)
```

**Step 2: Commit**

```bash
git add ui/components/toast.lua
git commit -m "feat: text stagger effect on toast message reveal

Toast messages now fade in character-by-character using native
TextStagger with Fade effect for a polished entrance."
```

---

## Task 7: Phase 5 — Loading Spinners with Native Oscillators

**Files:**
- Modify: `ui/components/loading_spinner.lua`

**Step 1: Add native ImAnim require**

```lua
local iam = require('ImAnim')
```

**Step 2: Replace circular spinner math.sin with Oscillate**

In `M.circular()`, replace `os.clock()` angle calculation:

```lua
local dt = imgui.GetIO().DeltaTime
-- Sawtooth wave for continuous rotation (0 to 2pi)
local angle = iam.Oscillate('spinner_circ', imgui.GetID('angle'),
    math.pi, speed, 0.0, IamWaveType.Sawtooth, dt)
```

**Step 3: Replace dots bounce with Oscillate**

In `M.dots()`:

```lua
local dt = imgui.GetIO().DeltaTime
for i = 1, dotCount do
    local phase = (i - 1) / dotCount * math.pi * 2
    local bounceY = iam.Oscillate('spinner_dot_' .. i, imgui.GetID('y'),
        6.0, speed, phase, IamWaveType.Sine, dt)
    -- use bounceY for dot vertical offset
end
```

**Step 4: Replace pulse with Oscillate**

In `M.pulse()`:

```lua
local dt = imgui.GetIO().DeltaTime
local pulseScale = iam.Oscillate('spinner_pulse', imgui.GetID('r'),
    0.3, 1.5, 0.0, IamWaveType.Sine, dt)
local currentRadius = radius * (1.0 + pulseScale)
```

**Step 5: Commit**

```bash
git add ui/components/loading_spinner.lua
git commit -m "feat: loading spinners with native ImAnim oscillators

Replace os.clock() + math.sin() with native Oscillate.
Consistent timing with rest of animation system."
```

---

## Task 8: Phase 6 — Clip-Based Stagger Entry Animations

**Files:**
- Modify: `ui/animation_helpers.lua`

**Step 1: Define the grid entry clip at module scope**

```lua
-- Grid entry animation clip (defined once)
local _gridEntryClipDefined = false
local _ALPHA_CH = nil
local _SCALE_CH = nil
local _OFFSET_CH = nil
local _gridEntryClipId = nil

local function ensureGridEntryClip()
    if _gridEntryClipDefined then return end
    _gridEntryClipDefined = true
    _ALPHA_CH = imgui.GetID('ge_alpha')
    _SCALE_CH = imgui.GetID('ge_scale')
    _OFFSET_CH = imgui.GetID('ge_offset')
    _gridEntryClipId = imgui.GetID('gridEntry')

    IamClip.Begin(_gridEntryClipId)
        :KeyFloat(_ALPHA_CH, 0.0, 0.0, IamEaseType.Linear)
        :KeyFloat(_ALPHA_CH, C.ANIMATION.STAGGER_DURATION, 1.0, IamEaseType.OutCubic)
        :KeyFloat(_SCALE_CH, 0.0, 0.85, IamEaseType.Linear)
        :KeyFloat(_SCALE_CH, C.ANIMATION.STAGGER_DURATION, 1.0, IamEaseType.OutBack)
        :KeyFloat(_OFFSET_CH, 0.0, 15.0, IamEaseType.Linear)
        :KeyFloat(_OFFSET_CH, C.ANIMATION.STAGGER_DURATION, 0.0, IamEaseType.OutCubic)
        :End()
end
```

**Step 2: Replace getStaggeredEntryTransform with clip playback**

```lua
function M.getStaggeredEntryTransform(gridKey, idx, total, opts)
    if not _settings or not _settings.SideKickAnimateStagger then
        return 1.0, 0, 0, 1.0
    end
    ensureGridEntryClip()
    local instId = imgui.GetID(gridKey .. '_' .. idx)
    local inst = iam.PlayStagger(_gridEntryClipId, instId, idx, total, C.ANIMATION.STAGGER_DELAY)

    if not inst or not inst:Valid() then
        return 1.0, 0, 0, 1.0
    end

    local ok_a, alpha = inst:GetFloat(_ALPHA_CH)
    local ok_s, scale = inst:GetFloat(_SCALE_CH)
    local ok_o, offsetY = inst:GetFloat(_OFFSET_CH)

    return ok_s and scale or 1.0,
           0,
           ok_o and offsetY or 0,
           ok_a and alpha or 1.0
end
```

**Step 3: Simplify getStaggeredEntryScale and getStaggeredEntryOffsetY**

These can delegate to `getStaggeredEntryTransform`:

```lua
function M.getStaggeredEntryScale(gridKey, idx, total)
    local scale, _, _, _ = M.getStaggeredEntryTransform(gridKey, idx, total)
    return scale
end

function M.getStaggeredEntryOffsetY(gridKey, idx, total, maxOffset)
    local _, _, offsetY, _ = M.getStaggeredEntryTransform(gridKey, idx, total)
    return offsetY
end
```

**Step 4: Commit**

```bash
git add ui/animation_helpers.lua
git commit -m "feat: clip-based stagger entry animations

Replace manual stagger math with IamClip keyframe timeline.
Single clip defines alpha + scale + offsetY channels.
PlayStagger handles per-item delay automatically."
```

---

## Task 9: Phase 7 — Gradient Resource Bars + Damage Shake

**Files:**
- Modify: `ui/components/resource_bar.lua`
- Modify: `ui/colors.lua`
- Modify: `ui/animation_helpers.lua`

**Step 1: Add native gradients to colors.lua**

```lua
local iam = require('ImAnim')

-- Cached gradient objects (created once)
local _hpGradient = nil
local _manaGradient = nil
local _endGradient = nil

function M.getHpGradient()
    if not _hpGradient then
        _hpGradient = IamGradient()
            :Add(0.0, ImVec4(0.8, 0.1, 0.1, 1.0))    -- red at 0%
            :Add(0.25, ImVec4(0.9, 0.4, 0.1, 1.0))   -- orange at 25%
            :Add(0.50, ImVec4(0.9, 0.8, 0.2, 1.0))   -- yellow at 50%
            :Add(0.75, ImVec4(0.5, 0.85, 0.3, 1.0))   -- yellow-green at 75%
            :Add(1.0, ImVec4(0.2, 0.8, 0.2, 1.0))     -- green at 100%
    end
    return _hpGradient
end

function M.getManaGradient()
    if not _manaGradient then
        _manaGradient = IamGradient()
            :Add(0.0, ImVec4(0.1, 0.1, 0.3, 1.0))
            :Add(0.5, ImVec4(0.2, 0.4, 0.8, 1.0))
            :Add(1.0, ImVec4(0.4, 0.6, 1.0, 1.0))
    end
    return _manaGradient
end

function M.getEndGradient()
    if not _endGradient then
        _endGradient = IamGradient()
            :Add(0.0, ImVec4(0.4, 0.3, 0.1, 1.0))
            :Add(0.5, ImVec4(0.7, 0.6, 0.2, 1.0))
            :Add(1.0, ImVec4(0.9, 0.8, 0.3, 1.0))
    end
    return _endGradient
end

-- Sample HP color from gradient (returns ImVec4)
function M.healthBarGradient(hpPct)
    local grad = M.getHpGradient()
    return grad:Sample(math.max(0, math.min(1, hpPct / 100)), IamColorSpace.OKLAB)
end
```

**Step 2: Update resource_bar.lua to use gradient sampling**

In the health bar color calculation, replace the stepped `if/elseif`:

```lua
-- Old: local barColor = Colors.healthBar(hpPct)
-- New:
local gradColor = Colors.healthBarGradient(hpPct)
local barColor = { gradColor.x, gradColor.y, gradColor.z, gradColor.w }
```

**Step 3: Add HP damage shake to animation_helpers.lua**

```lua
function M.getHpBarShake(uniqueId, currentHp)
    local dt = M.get_dt()
    -- Detect significant HP drop
    local prev = _lastHpValues[uniqueId]
    _lastHpValues[uniqueId] = currentHp
    if prev and prev > 0 and currentHp < prev then
        local dropPct = (prev - currentHp) / prev * 100
        if dropPct >= C.RESOURCE.DAMAGE_FLASH_THRESHOLD then
            iam.TriggerShake(uniqueId .. '_hpshake')
        end
    end
    -- Return shake offset (decays naturally)
    local offsetX = iam.Shake(uniqueId .. '_hpshake', imgui.GetID('sx'), 6, 0.2, dt)
    local offsetY = iam.Shake(uniqueId .. '_hpshake', imgui.GetID('sy'), 3, 0.2, dt)
    return offsetX, offsetY
end
```

**Step 4: Apply shake offset in resource_bar.lua**

In the health bar draw function, offset the bar position:

```lua
local shakeX, shakeY = AnimHelpers.getHpBarShake('hpbar', hpPct)
local drawX = x + shakeX
local drawY = y + shakeY
-- Use drawX, drawY instead of x, y for all bar drawing
```

**Step 5: Commit**

```bash
git add ui/colors.lua ui/components/resource_bar.lua ui/animation_helpers.lua
git commit -m "feat: gradient resource bars with OKLAB sampling and HP shake

Replace stepped color thresholds with IamGradient continuous sampling.
HP bars use OKLAB perceptual blending for smooth color transitions.
Add ShakeVec2 on HP bar when damage exceeds 5% threshold."
```

---

## Task 10: Phase 8A — Smooth Scroll

**Files:**
- Modify: `ui/settings/` (any settings panel with programmatic scroll)

**Step 1: Add smooth scroll calls**

In any settings tab-click handler that jumps to a section:

```lua
local iam = require('ImAnim')
-- When clicking a settings section:
iam.ScrollToY(targetSectionY, 0.3)
```

**Step 2: Commit**

```bash
git add ui/settings/
git commit -m "feat: smooth scroll for settings panel navigation

Use native ImAnim.ScrollToY for eased scrolling when jumping
between settings sections."
```

---

## Task 11: Phase 8B — Idle Noise Drift on Window Focus Glow

**Files:**
- Modify: `ui/animation_helpers.lua`

**Step 1: Add noise-modulated focus glow**

Update `drawWindowFocusGlow()` to add organic drift:

```lua
function M.drawWindowFocusGlow(dl, x, y, w, h, themeName, isFocused)
    if not isFocused or not _settings or not _settings.SideKickAnimateFocusGlow then return end
    local dt = M.get_dt()

    local noiseOpts = IamNoiseOpts()
    noiseOpts.type = IamNoiseType.Perlin
    noiseOpts.octaves = 2

    -- Organic glow intensity drift
    local basePulse = iam.Oscillate('focusGlow', imgui.GetID('pulse'),
        0.15, 1.2, 0.0, IamWaveType.Sine, dt)
    local drift = iam.SmoothNoiseFloat('focusGlow', 0.3, 0.08, noiseOpts, dt)
    local intensity = 0.5 + basePulse + drift

    local accentColor = Colors.ready(themeName)
    -- Draw 3 layers of outer glow with varying intensity
    for i = 3, 1, -1 do
        local alpha = math.floor(intensity * 20 * (i / 3))
        local col = Draw.IM_COL32(accentColor[1], accentColor[2], accentColor[3], alpha)
        Draw.addRect(dl, x - i, y - i, x + w + i, y + h + i, col, C.LAYOUT.DEFAULT_ROUNDING + i, 0, 1)
    end
end
```

**Step 2: Commit**

```bash
git add ui/animation_helpers.lua
git commit -m "feat: organic noise drift on window focus glow

Add Perlin noise modulation to focus glow intensity for
natural-feeling luminance variation."
```

---

## Task 12: Phase 8C — Motion Path for Ready Shine

**Files:**
- Modify: `ui/animation_helpers.lua`

**Step 1: Replace linear shine sweep with curved path**

Update `getReadyShineOffset()` to use a native motion path:

```lua
-- Cached paths per cell width
local _shinePaths = {}

local function getOrCreateShinePath(cellWidth, cellHeight)
    local key = cellWidth .. 'x' .. cellHeight
    if _shinePaths[key] then return _shinePaths[key] end

    local cx = cellWidth / 2
    local pathId = imgui.GetID('shine_' .. key)
    IamPath:Begin(ImVec2(-10, 0))
        :QuadraticTo(ImVec2(cx, -3), ImVec2(cellWidth + 10, 0))
        :End()

    iam.PathBuildArcLut(pathId)
    _shinePaths[key] = pathId
    return pathId
end

function M.getReadyShineOffset(uniqueId, cellWidth, isReady)
    if not isReady or not _settings or not _settings.SideKickAnimateReadyShine then return nil end
    local dt = M.get_dt()

    local cellHeight = cellWidth  -- square cells
    local pathId = getOrCreateShinePath(cellWidth, cellHeight)
    local ez = iam.EasePreset(IamEaseType.InOutSine)

    local pos = iam.TweenPath(uniqueId, imgui.GetID('shine'), pathId, 2.5, ez, IamPolicy.Crossfade, dt)
    return pos.x, pos.y
end
```

**Step 2: Commit**

```bash
git add ui/animation_helpers.lua
git commit -m "feat: curved motion path for ready shine sweep

Replace linear shine with QuadraticTo path for gentle arc.
Cached per cell-width. Uses InOutSine easing for smooth rhythm."
```

---

## Task 13: Phase 9A — Migrate Remaining Import Sites

**Files:**
- Modify: `ui/disc_bar_animated.lua`
- Modify: `ui/special_bar_animated.lua`
- Modify: `ui/item_bar_animated.lua`
- Modify: `ui/remote_abilities.lua`
- Modify: `ui/aggro_warning.lua`

**Step 1: Replace require in each file**

In each file, change line 2 or 3:

```lua
-- Old:
local ImAnim = require('sidekick-next.lib.imanim')
-- New:
local iam = require('ImAnim')
```

And update any direct calls from `ImAnim.xxx` to `iam.Xxx` (PascalCase). Most of these files delegate to `AnimHelpers` so changes should be minimal — mainly the require line and any direct `ImAnim.update_begin_frame()` or `ImAnim.update_stagger_frame()` calls (remove them).

**Step 2: Commit**

```bash
git add ui/disc_bar_animated.lua ui/special_bar_animated.lua ui/item_bar_animated.lua ui/remote_abilities.lua ui/aggro_warning.lua
git commit -m "feat: migrate remaining bar files to native ImAnim require

Update disc_bar, special_bar, item_bar, remote_abilities, and
aggro_warning to use require('ImAnim') directly."
```

---

## Task 14: Phase 9B — Delete Wrapper & Final Cleanup

**Files:**
- Delete: `lib/imanim.lua`
- Modify: `SideKick.lua` (remove any remaining wrapper references)

**Step 1: Delete the wrapper file**

```bash
git rm lib/imanim.lua
```

**Step 2: Final grep to ensure no references remain**

```bash
grep -r "sidekick-next.lib.imanim" --include="*.lua" .
```

Should return zero results (except possibly in docs/plans).

**Step 3: Remove update_begin_frame and clip_update from main loop**

In `SideKick.lua`, remove any lines like:
```lua
ImAnim.update_begin_frame()
ImAnim.update_stagger_frame(dt)
ImAnim.clip_update(dt)
```

These are handled automatically by the native MQ runtime.

**Step 4: Clean up animation_helpers.lua**

Remove the `M.init(ImAnim, settings)` backward-compat pattern. The module now requires ImAnim directly at the top. Settings can still be passed via `M.setSettings(settings)`.

Remove any references to the old `_ImAnim` variable.

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: delete lib/imanim.lua wrapper, complete native migration

Remove 871-line pure-Lua animation wrapper. All animation now runs
through native require('ImAnim') C++ module. Remove manual frame
updates (MQ handles automatically). Clean up backward-compat init."
```

---

## Text Stagger in Status Badges (Optional — Low Priority)

**Files:**
- Modify: `ui/components/status_badge.lua`

This is additive and can be done anytime after Task 6. Add text stagger to badge labels on state transitions:

```lua
local iam = require('ImAnim')

-- In badge rendering, when state changes:
local staggerOpts = IamTextStaggerOpts()
staggerOpts.effect = IamTextStaggerEffect.Fade
staggerOpts.char_delay = 0.02
staggerOpts.char_duration = 0.12
staggerOpts.ease = iam.EasePreset(IamEaseType.OutCubic)
staggerOpts.color = imgui.GetColorU32(ImGuiCol.Text)
staggerOpts.pos = ImVec2(textX, textY)

iam.TextStagger(imgui.GetID('badge_' .. label), label, progress, staggerOpts)
```

---

## Verification Checklist

After each task, verify in-game:

- [ ] Script loads without errors (`/lua run sidekick-next`)
- [ ] Ability bar renders correctly with the new feature
- [ ] No visual regressions in existing animations
- [ ] Theme switching works (after Task 4)
- [ ] Performance feels the same or better (native should be faster)
- [ ] Settings toggles still disable animations properly
- [ ] Textured themes (ClassicEQ) still render correctly
- [ ] All bar types work: main, special, disc, item

## Reference Files

| File | Purpose |
|------|---------|
| `ui/animation_helpers.lua` | Integration layer (main migration target) |
| `ui/bar_animated.lua` | Main ability bar rendering |
| `ui/draw_helpers.lua` | DrawList API wrappers |
| `ui/constants.lua` | Animation/layout constants |
| `ui/colors.lua` | Theme-aware color functions |
| `themes.lua` | Theme definitions and switching |
| `ui/components/toast.lua` | Toast notification rendering |
| `ui/components/loading_spinner.lua` | Spinner animations |
| `ui/components/resource_bar.lua` | HP/mana/endurance bars |
| `ui/components/status_badge.lua` | Status indicators |
| `SideKick.lua` | Main entry point and render loop |
| `lib/imanim.lua` | **DELETE** — old pure-Lua wrapper |

## Native API Quick Reference

| Task | Native Call |
|------|------------|
| Float tween | `iam.TweenFloat(id, ch, target, dur, easeDesc, policy, dt)` |
| Color tween | `iam.TweenColor(id, ch, ImVec4, dur, easeDesc, policy, colorSpace, dt)` |
| Spring | `iam.TweenFloat(id, ch, target, dur, iam.EaseSpring(m,k,c,v0), policy, dt)` |
| Oscillate | `iam.Oscillate(id, ch, amp, freq, phase, waveType, dt)` |
| Shake trigger | `iam.TriggerShake(id)` |
| Shake read | `iam.Shake(id, ch, magnitude, decay, dt)` |
| Noise | `iam.SmoothNoiseFloat(id, freq, amp, noiseOpts, dt)` |
| Ease eval | `iam.EvalPreset(IamEaseType.OutCubic, t)` |
| Clip define | `IamClip.Begin(id):KeyFloat(ch, time, val, ease):End()` |
| Clip play | `iam.PlayStagger(clipId, instId, idx, count, delay)` |
| Gradient | `IamGradient():Add(t, ImVec4):Sample(t, colorSpace)` |
| Path define | `IamPath:Begin(ImVec2):QuadraticTo(c, p):End()` |
| Path tween | `iam.TweenPath(id, ch, pathId, dur, ez, policy, dt)` |
| Style tween | `iam.StyleTween(animId, targetId, dur, ez, colorSpace, dt)` |
| Scroll | `iam.ScrollToY(target, dur)` |
| Text stagger | `iam.TextStagger(id, text, progress, opts)` |
