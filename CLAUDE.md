# sidekick-next

Standalone experimental copy of the `sidekick` script for visual redesign work (Approach C from the refactoring plan). Lives alongside the original — changes here do **not** affect the production `sidekick`.

Run with: `/lua run sidekick-next`

Parent: `F:\lua\CLAUDE.md` for shared mq/ImGui/actors patterns.

## Where to look

| For | Read |
|-----|------|
| User-facing behavior | `docs/USER_GUIDE.md` |
| How modules plug together | `docs/INTEGRATION_GUIDE.md` |
| In-flight redesign plans | `docs/plans/` |
| Removed legacy options (do not re-add) | `docs/removed-options.txt` |

## Conventions

- **Module require prefix:** `local BASE = 'sidekick-next.'` — modules under this tree are required as `sidekick-next.<path>`. Never mutate `BASE` from outside `init.lua`.
- Helper `_G.SK_NEXT_REQUIRE(path)` exists for one-line requires; modules can also use plain relative requires.
- **Feature flags** live in `_G.SIDEKICK_NEXT_CONFIG` (set in `init.lua`):
  - `USE_NEW_COLORS` — `ui/colors.lua` theme-aware colors.
  - `USE_NEW_COMPONENTS` — `ui/components/` reusable widgets.
  - `USE_NEW_SETTINGS` — `ui/settings/` modular tab system.
  - `VISUAL_REDESIGN` — placeholder for Approach C experiments.
  - `DEBUG_SETTINGS` — log ImGui setting interactions (dev-only).
- When adding a redesign experiment, gate it behind a new flag rather than replacing the existing path. The whole point of this tree is being able to A/B against the original.

## Hard rules

- **Don't touch `F:\lua\sidekick`** (the production tree) from this branch. Cross-references should be read-only and ideally avoided.
- Removed options listed in `docs/removed-options.txt` are removed deliberately — don't reintroduce them without checking the doc.
- Keep `docs/INTEGRATION_GUIDE.md` in sync when you change module boundaries.
