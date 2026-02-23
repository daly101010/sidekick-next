# Native ImAnim Migration & Enhancement Design

**Date:** 2026-02-23
**Approach:** Migrate-Per-System (Option C) — each enhancement migrates its system to native `require('ImAnim')` while adding the visual improvement.

## Decisions

- **Button shape:** Rounded square (rounding ~40% of cell size), not circular
- **Cooldown timer:** Radial clock-sweep overlay (reveals icon as cooldown expires)
- **Theme animation:** Global StyleTween crossfade only (no per-widget OKLAB)
- **Shake target:** HP resource bar only (not ability cells)
- **Migration:** Full native — delete `lib/imanim.lua` wrapper when complete
- **Priority:** Visual polish and native migration in parallel per-system

## Foundation: Native API Translation

Every file switches from `require('sidekick-next.lib.imanim')` to `require('ImAnim')`.

| Wrapper (current) | Native (target) |
|---|---|
| `ImAnim.tween_float(id, ch, target, dur, EASE.out_cubic, POLICY.crossfade, dt)` | `ImAnim.TweenFloat(id, ch, target, dur, ImAnim.EasePreset(IamEaseType.OutCubic), IamPolicy.Crossfade, dt)` |
| `ImAnim.spring(id, target, stiff, damp)` | `ImAnim.TweenFloat(id, ch, target, dur, ImAnim.EaseSpring(1.0, stiff, damp, 0), IamPolicy.Crossfade, dt)` |
| `ImAnim.oscillate(id, ch, amp, freq, phase, dt)` | `ImAnim.Oscillate(id, ch, amp, freq, phase, IamWaveType.Sine, dt)` |
| `ImAnim.trigger_shake(id)` / `ImAnim.shake(id, mag, decay, dt)` | `ImAnim.TriggerShake(id)` / `ImAnim.Shake(id, ch, mag, decay, dt)` |
| `ImAnim.tween_color(id, ch, r,g,b,a, dur, ease, cs, policy, dt)` | `ImAnim.TweenColor(id, ch, ImVec4(r,g,b,a), dur, ez, policy, cs, dt)` |
| `ImAnim.update_begin_frame()` / `ImAnim.clip_update(dt)` | **Removed** (MQ handles automatically) |

`lib/imanim.lua` deleted after all consumers migrated. `animation_helpers.lua` cache layer (dt caching, ID caching, early-exit checks) stays, just calls native.

---

## Enhancement 1: Rounded Buttons with Shadow & Glow

**Files:** `bar_animated.lua`, `animation_helpers.lua`, `constants.lua`

- `AddRectFilled` with rounding radius = `cellSize * LAYOUT.BUTTON_ROUNDING_PCT` (~40%, ~19px at 48px cell)
- Drop shadow: second `AddRectFilled` offset 2px down-right, dark translucent (`0,0,0,0.35`), same rounding, drawn behind main rect. Shadow alpha tweened on hover via `TweenFloat`.
- Glow on hover: outer `AddRect` (stroke) 2px larger, theme accent color, alpha 0->0.6 via `TweenFloat` with `EasePreset(OutCubic)`.
- Spring scale: replace Lua spring solver with `ImAnim.EaseSpring(1.0, 450, 28, 0.0)` through `TweenFloat`.
- Clipping: `ImGui.PushClipRect()` so icon textures and cooldown overlays respect rounded corners.
- New constant: `LAYOUT.BUTTON_ROUNDING_PCT = 0.4`

## Enhancement 2: Radial Sweep Cooldown Timer

**Files:** `bar_animated.lua`, `animation_helpers.lua`

Replaces bottom-up fill with clock-style circular sweep:

1. Darken the full rounded-rect with dark overlay
2. Draw a pie-slice arc from 12 o'clock (-pi/2) sweeping clockwise by `t * 2pi` using DrawList PathArcTo + PathLineTo + PathFillConvex
3. The swept area is clear/transparent, revealing the icon underneath as cooldown expires
4. Remaining dark area color transitions red->orange->yellow->green via `TweenColor` with OKLAB (same thresholds from `constants.lua`)
5. Countdown text stays as static overlay on top
6. Completion pulse stays (`TriggerShake` on 100%)

## Enhancement 3: Animated Theme Crossfade

**Files:** `themes.lua`, main render loop in `SideKick.lua`

- On init: iterate all themes, apply each via `pushWindowTheme`, call `ImAnim.StyleRegisterCurrent(ImGui.GetID(name))`
- On theme change: single call per frame: `ImAnim.StyleTween(themeAnimId, targetThemeId, 0.4, OutCubic, OKLAB, dt)`
- Replaces manual `PushStyleColor` calls during transitions

## Enhancement 4: Gradient Health/Resource Bars

**Files:** `resource_bar.lua`, `animation_helpers.lua`, `constants.lua`

- HP gradient: `IamGradient` with stops at 0% (red), 25% (orange), 50% (yellow), 100% (green), sampled via `hpGradient:Sample(hpPct, IamColorSpace.OKLAB)`
- Mana gradient: blue ramp. Endurance gradient: yellow ramp.
- Created once at init, sampled per-frame. Replaces manual if/elseif chain in `getCooldownColor`.
- HP damage shake: `TriggerShake('hpBar')` when HP drops > 5%, `ShakeVec2('hpBar', 'pos', ImVec2(6,3), ImVec2(0.2,0.2), dt)` applied as draw offset. HP bar only.

## Enhancement 5: Toast Notifications — Native Tweens

**Files:** `toast.lua`

- Replace manual `elapsed/duration` + hand-rolled ease-out-quad:
  - Fade: `TweenFloat('toast'..i, 'alpha', target, fadeInTime, OutCubic, Crossfade, dt)`
  - Slide: `TweenFloat('toast'..i, 'y', targetY, 0.25, OutCubic, Crossfade, dt)`
- Key improvement: when a mid-stack toast dismisses, remaining toasts smoothly reflow via crossfade policy (currently snap).

## Enhancement 6: Loading Spinners — Native Oscillators

**Files:** `loading_spinner.lua`

Replace `os.clock()` + `math.sin()`:
- Circular spinner rotation: `Oscillate('spinner', 'angle', pi*2, speed, 0, Sawtooth, dt)`
- Dot bounce: `Oscillate('dot'..i, 'y', 6.0, 2.0, phase, Sine, dt)`
- Pulse ring: `Oscillate('pulse', 'r', 4.0, 1.5, 0, Sine, dt)`

## Enhancement 7: Native Spring Easing

**Files:** `animation_helpers.lua`

Replace Lua Verlet spring solver with `ImAnim.EaseSpring(1.0, stiffness, damping, 0.0)`. Applies to:
- Button hover/press scale
- Toggle pop scale
- Completion pulse

Delete `springs` table, `updateSpring()`, velocity tracking from `lib/imanim.lua`.

## Enhancement 8: Clip-Based Entry Animations

**Files:** `animation_helpers.lua`

Replace separate `getStaggerAlpha`, `getStaggeredEntryScale`, `getStaggeredEntryOffsetY` with a single clip:

```lua
IamClip.Begin(ImGui.GetID('gridEntry'))
    :KeyFloat(ALPHA_CH, 0.0, 0.0, IamEaseType.Linear)
    :KeyFloat(ALPHA_CH, 0.45, 1.0, IamEaseType.OutCubic)
    :KeyFloat(SCALE_CH, 0.0, 0.85, IamEaseType.Linear)
    :KeyFloat(SCALE_CH, 0.45, 1.0, IamEaseType.OutBack)
    :KeyFloat(OFFSET_CH, 0.0, 15.0, IamEaseType.Linear)
    :KeyFloat(OFFSET_CH, 0.45, 0.0, IamEaseType.OutCubic)
    :End()
```

Per item: `PlayStagger(clipId, instId, index, total, STAGGER_DELAY)`. Read alpha/scale/offset from instance channels.

## Enhancement 9: Text Stagger Effects

**Files:** `status_badge.lua`, `toast.lua` (additive)

New feature — staggered character animation for status messages:

```lua
local opts = IamTextStaggerOpts()
opts.effect = IamTextStaggerEffect.Fade
opts.char_delay = 0.03
opts.char_duration = 0.2
opts.ease = ImAnim.EasePreset(IamEaseType.OutCubic)
ImAnim.TextStagger(ImGui.GetID('status'), text, progress, opts)
```

Usage: status badge state changes, toast message text, optionally bar labels.

## Enhancement 10: Smooth Scroll

**Files:** Settings UI files, scrollable lists

Drop-in for programmatic scroll jumps:
```lua
ImAnim.ScrollToY(targetY, 0.3)
```

## Enhancement 11: Idle Wiggle / Noise Drift

**Files:** `animation_helpers.lua`

Subtle organic movement on idle elements:
```lua
local drift = ImAnim.SmoothNoiseFloat('windowGlow', 0.3, 1.5, noiseOpts, dt)
```

Applied to window focus glow intensity and optionally ready-state glow pulsing.

## Enhancement 12: Per-Axis Toast Easing

**Files:** `toast.lua`

Enhancement to toast slide-in:
```lua
local perAxis = IamEasePerAxis(
    ImAnim.EasePreset(IamEaseType.OutCubic),
    ImAnim.EasePreset(IamEaseType.OutBack)
)
```

## Enhancement 13: Motion Path for Ready Shine

**Files:** `animation_helpers.lua`

Replace linear left-to-right shine with a curved path:
```lua
IamPath:Begin(ImVec2(minX, minY))
    :QuadraticTo(ImVec2(cx, minY - 5), ImVec2(maxX, minY))
    :LineTo(ImVec2(maxX, maxY))
    :QuadraticTo(ImVec2(cx, maxY + 5), ImVec2(minX, maxY))
    :End()
```

## Enhancement 14: Wrapper Deletion

**Files:** `lib/imanim.lua` (delete), main loop, any remaining require sites

- Delete `lib/imanim.lua`
- Remove `update_begin_frame()` and `clip_update(dt)` from main loop
- Update any remaining `require('sidekick-next.lib.imanim')` to `require('ImAnim')`
- Delete Lua state tables: `tweens`, `springs`, `oscillators`, `shakes`, `wiggles`, `noises`

---

## Implementation Phases

| Phase | Enhancements | System Migrated |
|-------|-------------|-----------------|
| 1 | Rounded buttons (#1) + Spring easing (#7) | Button scale springs |
| 2 | Radial cooldown sweep (#2) + Cooldown color gradients (#4) | Cooldown tweens + colors |
| 3 | Theme crossfade (#3) | Theme system |
| 4 | Toast native tweens (#5) + Per-axis easing (#12) + Text stagger in toasts (#9) | Toast animations |
| 5 | Spinner oscillators (#6) | Spinner animations |
| 6 | Clip-based staggers (#8) | Stagger system |
| 7 | Gradient HP bars (#4) + Damage shake (#4-HP) | Resource bar animations |
| 8 | Smooth scroll (#10) + Idle noise (#11) + Shine path (#13) | Remaining misc |
| 9 | Delete wrapper (#14) | Final cleanup |
