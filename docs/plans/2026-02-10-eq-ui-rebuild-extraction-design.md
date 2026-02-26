# EQ UI Rebuild — Standalone Extraction & Refactor

**Date:** 2026-02-10
**Status:** Approved

## Goal

Extract the eq_ui_rebuild project from sidekick-next into a fully self-contained standalone project at `F:/eq_ui_rebuild/`, refactor the 7,674-line monolith into focused modules, remove dead code, and identify ImGui enhancements.

## Decisions

- **Location:** `F:/eq_ui_rebuild/` (top-level standalone)
- **Textures:** Copy all 536 files from `F:/lua/UI/upscaled_4x_combined/` into `textures/`
- **Export snapshots:** Leave behind (~50 timestamped files stay in sidekick-next)
- **Dependencies:** Copy `imanim.lua` and `cooldowns.lua` into `lib/` for full self-containment
- **Original code:** Preserved as-is in sidekick-next

## Phase 1: Extract to F:/eq_ui_rebuild/

### Directory Structure

```
F:/eq_ui_rebuild/
├── init.lua                  -- Entry point (lifecycle, commands, main loop)
├── eq_ui_data.lua            -- Auto-generated screen/control data (unchanged)
├── eq_ui_offsets.lua         -- User layout overrides (unchanged)
├── eq_ui_export.lua          -- Export template (unchanged)
│
├── core/
│   ├── state.lua             -- Global state, presets, config constants
│   ├── textures.lua          -- Texture loading/caching, icon sheet loaders
│   ├── layout.lua            -- Offsets, priorities, selection, dirty tracking, batch ops
│   └── persistence.lua       -- LoadOffsets, SaveOffsets, serialization helpers
│
├── rendering/
│   ├── drawlist.lua          -- DrawList safety wrappers (pcall/ImVec2 fallback)
│   ├── text.lua              -- Text measurement, scaled/centered/wrapped rendering
│   ├── icons.lua             -- Spell, gem, item icon rendering
│   ├── elements.lua          -- Tiled textures, anims, gauges, borders, titlebars
│   └── controls.lua          -- DrawControl dispatcher + per-type renderers
│
├── live/
│   └── gamedata.lua          -- Live TLO integration (gauges, buffs, spells, inventory)
│
├── editor/
│   ├── settings.lua          -- Settings panel UI
│   ├── analysis.lua          -- Unused asset/piece/texture analysis
│   └── clipboard.lua         -- Copy/paste, export operations
│
├── ui/
│   └── overlay.lua           -- Main RenderUI (fullscreen overlay, interaction, drag-drop)
│
├── lib/
│   ├── imanim.lua            -- Animation helpers (from sidekick-next)
│   └── cooldowns.lua         -- Cooldown tracking (from sidekick-next)
│
├── textures/                 -- Full copy of F:/lua/UI/upscaled_4x_combined/
│   ├── previous spell icons/
│   ├── window_pieces01.tga ... window_pieces08.tga
│   ├── dragitem1.tga ... dragitem376.tga
│   └── ... (536 total files)
│
└── assets/
    └── window_pieces02_live.tga
```

### Files Copied As-Is
- `eq_ui_data.lua` — auto-generated, no changes needed
- `eq_ui_offsets.lua` — user overrides, no changes needed
- `eq_ui_export.lua` — export template

### Path Updates Required
- `UI_PATH`: `"F:/lua/UI/upscaled_4x_combined/"` → relative path to `textures/`
- `require('sidekick-next.eq_ui_data')` → `require('eq_ui_rebuild.eq_ui_data')`
- `require('sidekick-next.lib.imanim')` → `require('eq_ui_rebuild.lib.imanim')`
- `require('sidekick-next.abilities.cooldowns')` → `require('eq_ui_rebuild.lib.cooldowns')`
- Hardcoded `F:/lua/sidekick-next/eq_ui_offsets.lua` → relative path
- Hardcoded `F:/lua/sidekick-next/eq_ui_export.lua` → relative path
- Drop `require('ui.texture_workbench.pixel_buffer')` (missing optional dependency)

## Phase 2: Refactor — Split the Monolith

### Module Breakdown

| Module | ~Lines | Source (eq_ui_rebuild.lua) | Purpose |
|--------|--------|---------------------------|---------|
| `init.lua` | 85 | Lines 7589-7674 + glue | Entry point, command binds, main loop |
| `core/state.lua` | 200 | Lines 1-276 | State table, ClassicPreset, config constants |
| `core/textures.lua` | 120 | Lines 278-400 | GetTexture, icon sheet loaders, cache |
| `core/layout.lua` | 1100 | Lines 401-1561 | Offsets, priorities, selection, dirty tracking, batch ops |
| `core/persistence.lua` | 400 | Lines 1562-1950 | LoadOffsets, SaveOffsets, serialization |
| `rendering/drawlist.lua` | 90 | Lines 3124-3210 | pcall wrappers, ImVec2 fallback |
| `rendering/text.lua` | 160 | Lines 3211-3371 | Text sizing, scaled/centered/wrapped rendering |
| `rendering/icons.lua` | 270 | Lines 3372-3638 | Spell, gem, item icon drawing |
| `rendering/elements.lua` | 700 | Lines 3639-4346 | Tiled textures, anims, gauges, borders, titlebars, buttons |
| `rendering/controls.lua` | 650 | Lines 4347-4996 | DrawControl + SpellGem, Buff, HotButton, Label renderers |
| `live/gamedata.lua` | 650 | Lines 1991-2640 | TLO reads, gauge values, buff/spell/inventory tracking |
| `editor/settings.lua` | 700 | Lines 5347-6042 | Settings panel collapsing headers, edit mode, batch UI |
| `editor/analysis.lua` | 480 | Lines 2641-3122 | Unused asset/piece/texture scanning |
| `editor/clipboard.lua` | 350 | Lines 4997-5345 | Selection mgmt, copy/paste, export |
| `ui/overlay.lua` | 1550 | Lines 6044-7588 | RenderUI, fullscreen overlay, interaction, drag-drop |

### Cross-Module Dependencies

```
init.lua
  └─ core/state         (State table)
  └─ core/persistence   (LoadOffsets on startup)
  └─ ui/overlay         (RenderUI callback)

ui/overlay
  └─ core/state, layout, textures
  └─ rendering/*        (all rendering modules)
  └─ live/gamedata      (live TLO data)
  └─ editor/settings    (settings panel toggle)

rendering/controls
  └─ rendering/drawlist, text, icons, elements
  └─ core/state, layout
  └─ live/gamedata      (for dynamic text, gauge values)

editor/settings
  └─ core/state, layout, persistence
  └─ editor/analysis, clipboard
```

### Shared State Pattern

All modules share a single `State` table created in `core/state.lua` and passed during initialization:

```lua
-- core/state.lua
local State = { ... }
return State

-- Other modules receive State via init or require
local State = require('eq_ui_rebuild.core.state')
```

## Phase 3: Code Review — Dead Code

### Known Dead Code Candidates
1. **`dl_add_spell_icon_gem()`** — Deprecated, replaced by `dl_add_gem_icon()`. Comments say "wrong approach."
2. **`pixel_buffer` integration** — Optional brush editing feature with missing dependency. Strip references.
3. **Unused local variables** — Identify during refactoring (variables assigned but never read).
4. **Redundant fallback paths** — Some functions have multiple fallback strategies; consolidate where possible.

### Review Checklist
- [ ] Every exported function is called by at least one other module
- [ ] No variables assigned but never read
- [ ] No unreachable code branches
- [ ] No commented-out code blocks (remove or convert to documented alternatives)
- [ ] `autoSaveEdits = false` preserved and documented

## Phase 4: ImGui Enhancements (Post-Refactor)

Evaluate and prioritize after clean refactor:
- Tooltip improvements for hovered controls
- Visual drag-drop feedback (ghost/outline of dragged element)
- Keyboard shortcuts for editor operations (arrow keys for nudge, Delete for remove)
- Minimap/overview showing all window positions at a glance
- Undo/redo stack for layout changes
- Search/filter bar in the settings panel
- Color picker for tint overrides
- Grid snap for alignment

## Implementation Order

1. Create `F:/eq_ui_rebuild/` directory structure
2. Copy data files (`eq_ui_data.lua`, `eq_ui_offsets.lua`, `eq_ui_export.lua`)
3. Copy textures (`F:/lua/UI/upscaled_4x_combined/` → `textures/`)
4. Copy assets and lib dependencies
5. Split `eq_ui_rebuild.lua` into modules (the main work)
6. Update all paths and require statements
7. Verify script loads and runs
8. Dead code review and cleanup
9. ImGui enhancement evaluation
