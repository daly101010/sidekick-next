# Paladin Healing Intelligence Design

Extend the deficit-based healing intelligence system to support PAL as a tank/off-healer.

## Summary

PAL is tanking primarily and heals reactively when group members are hurt. The same scoring, deficit tracking, incoming heal coordination, and spell ducking used by CLR applies, but with PAL-specific defaults and a smaller spell toolkit (no HoTs). Currently PAL has zero automated healing — LegacyHealing explicitly excludes PAL, NewHealing is CLR-only, and PAL isn't in the rotation engine's SUPPORT_CLASSES.

## Key Decisions

| Decision | Choice |
|----------|--------|
| Approach | Minimal gate change — extend existing system to PAL |
| PAL role | Dual role: tank + off-heal (reactive) |
| Integration | Healing intelligence replaces support layer heals |
| HoT support | None — PAL has no HoTs, hot categories stay empty |
| Self-heal | New `selfHeal` spell category for self-only heals |
| Config | Class profile defaults applied before user overrides |
| Scoring | Same deficit-based scoring — fewer spell options handled naturally |

## PAL Healing Spells

| Spell Line | EQ Subcategory | Target Type | Auto-Assigned Category |
|---|---|---|---|
| Preservation | `quick heal` | Single | `fast` |
| HealNuke (Denouncement) | `heals` | Single | `medium` (by level) |
| Aurora | `heals` | Group V1 | `group` |
| SelfHeal | `heals` | Self | `selfHeal` (new) |

Empty categories: `small`, `large`, `hot`, `hotLight`, `groupHot`, `promised` — selector skips these.

## Gate Changes

Three hardcoded class checks block PAL from the healing intelligence system:

1. `healing/init.lua:99` — `isHealerClass()` returns true only for CLR
2. `SideKick.lua:40` — `getHealingModule()` returns LegacyHealing for non-CLR
3. `SideKick.lua:1355` — Healing Monitor tab restricted to CLR

All three need PAL added.

## New Feature: Self-Heal Category

PAL has a dedicated self-heal line (Penitent Healing etc.) with `TargetType = "Self"`. Current categories assume targetable heals, so a new `selfHeal` category is needed.

### Config
- Add `selfHeal = {}` to the spells table
- Add `selfHealEnabled = true` and `selfHealPct = 60` to defaults

### Auto-Assignment
- Spells with `TargetType = "Self"` and heal subcategory go to `selfHeal`

### Selector Logic
- When evaluating self as target: include `selfHeal` category as candidates
- When evaluating other targets: exclude `selfHeal` spells

## Class Profile Defaults

| Setting | CLR Default | PAL Default | Rationale |
|---|---|---|---|
| `emergencyPct` | 25 | 30 | Off-healer needs more headroom |
| `groupHealMinCount` | 3 | 2 | Aurora is PAL's strongest heal |
| `hotEnabled` | true | false | PAL has no HoTs |
| `selfHealEnabled` | false | true | PAL needs self-heal while tanking |
| `selfHealPct` | 0 | 60 | Matches PAL config condition |
| `duckEnabled` | true | true | Duck if target topped off |
| `healPetsEnabled` | false | false | Limited heal bandwidth |

Scoring weights stay the same — deficit-based system handles fewer options naturally.

## Integration Flow

```
SideKick.lua main loop
    │
    ├─► getHealingModule() → NewHealing for PAL
    │       └─► healing/init.lua tick()
    │           ├─► TargetMonitor → group HP, deficit
    │           ├─► HealSelector → scores: fast, medium, group, selfHeal
    │           └─► Returns priorityHealingActive
    │
    └─► RotationEngine.tick(priorityHealingActive)
        ├─► emergency (LayOnHands, DivineCall) ← always runs
        ├─► aggro (Wave) ← always runs
        ├─► defenses (Fortitude, DefenseDisc) ← always runs
        ├─► combat (Crush, Stun) ← SKIPPED when priorityHealingActive
        └─► buff (HPBuff, Aura) ← always runs
```

When healing intelligence returns `priorityHealingActive = true`, the rotation engine skips combat and burn layers but continues running emergency, aggro, defenses, and buff layers. This means PAL keeps generating hate and using defensive cooldowns while healing.

## Files Modified

| File | Change |
|---|---|
| `healing/init.lua` | Add PAL to `isHealerClass()` |
| `healing/config.lua` | Add `selfHeal` category, class defaults for PAL, auto-assign self-target spells |
| `healing/heal_selector.lua` | Support `selfHeal` category in spell scoring |
| `SideKick.lua` | Add PAL to `getHealingModule()`, show monitor for PAL |
| `automation/healing.lua` | Remove PAL exclusion (cleanup) |

## What Stays the Same

- Core healing intelligence (deficit scoring, incoming heals, analytics, spell ducking)
- Rotation engine layers and priority
- Multi-healer Actors coordination
- Learning system (learns PAL heal amounts)
- HoT modules remain dormant for PAL
