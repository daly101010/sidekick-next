# Active Discipline Duration Strip

Date: 2026-04-30

## Goal

When the user activates a discipline (with non-zero Duration) via the disc button bar, render a countdown strip at the top of the disc bar showing the discipline name and a right→left draining progress bar.

## Scope

- **In:** disciplines only (`def.kind == 'disc'`).
- **Out:** AAs, items, spells (per user clarification).
- **One active timer at a time.** Newer disc activation replaces any prior active strip.
- **Click hook only.** No TLO polling for "is buff still up." Duration is captured at click time and counted down locally.

## Components

### `ui/active_duration_strip.lua` (new)

Singleton state + renderer.

```
state: { name, durationS, startMs } | nil

API:
  M.register(name, durationS)   -- replaces any current active
  M.getActive()                 -- → name, remainingS, totalS  (auto-clears expired)
  M.clear()                     -- forget current
  M.HEIGHT                      -- nominal strip pixel height (≈ 18)
  M.draw(width)                 -- → consumed pixel height (0 if nothing active)
```

`draw` advances the ImGui cursor via `imgui.Dummy` so the caller can render the icon grid below it without manual offset math.

### Hook in `utils/abilities.lua`

In `M.activate(def)`, in the `kind == 'disc'` branch, after `mq.cmd('/disc ' .. chosen)`:

1. Read `mq.TLO.Spell(chosen).Duration.TotalSeconds()`.
2. If > 0, call `ActiveDurations.register(chosen, durationS)`.

Wrapped in `pcall` to match existing defensive style.

### Render injection in `ui/disc_bar_animated.lua`

- Probe `ActiveDurations.getActive()` while computing window dimensions; if active, add `ActiveDurations.HEIGHT + spacing` to `winH`.
- Inside the `imgui.Begin(...)` block, before the icon-grid loop (~line 385), call `ActiveDurations.draw(winW - pad*2)`.

## Visual (matches in-game Combat Abilities header)

- **Always visible** when the disc bar renders — no collapse-when-idle.
- Top line: centered text. `"<Disc Name>"` while active, `"No Effect"` while idle.
- Below the text: thin segmented progress bar.
  - Idle: empty (dark fill, faint border).
  - Active: gold/yellow segments fill from the **left**, recede right→left as time elapses.
- Strip height ≈ text line + bar (≈ 26 px total including spacing).

## Non-goals

- No persistence across `/lua run` reloads.
- No detection if the disc was resisted/interrupted — strip still drains naturally; user can `/sk cleartimer` if needed (out of scope unless requested).
- No multi-row stacking; replace-on-new is intentional.
