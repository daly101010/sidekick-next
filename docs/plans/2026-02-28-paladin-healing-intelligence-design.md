# Paladin Healing Intelligence Design

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Give paladins hybrid tank-aware healing intelligence by extending the existing CLR healing system with mode-aware target filtering, Target's Target spell support, and a hint interface for tank module cooperation.

**Architecture:** Open the healing intelligence gate to PAL, add HealMode setting (off/tank/full), restrict heal targets in target_monitor based on mode, add `nukeHeal` category for TT spells with NPC-preferred targeting, expose heal hints for future tank module integration.

**Tech Stack:** Existing healing intelligence modules (heal_selector, config, target_monitor, init), spell_engine, rotation_engine skipLayers, PAL class config.

---

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Healing intelligence level | Hybrid tank-aware | PAL is a tank/healer hybrid — healing must adapt to role |
| Mode switching | Separate HealMode toggle | Independent of CombatMode — allows tank+heal, assist+heal, etc. |
| Tank mode healing scope | Self + group + lowest-HP target | Tank heals self, does group heals when needed, throws a single heal at critically injured |
| Architecture | Reuse CLR modules directly | Healing system is 95% class-agnostic — just open the gate |
| Tank-awareness location | Target filtering in target_monitor | Restricts candidate pool by mode; heal_selector runs unchanged |
| Target's Target spells | Full support with NPC-preferred path | Avoids target switching; bonus damage + hate |
| Tank+heal integration | Heal hints (loose coupling) | Healing brain exposes hints; tank module consumes them independently |
| TT tracking | Dedicated tt_tracker with UI | Validates NPC-targeting path is working; measures effectiveness |

---

## 1. Settings & HealMode Toggle

**New setting: `HealMode`** added to PAL class config:

| Value | Behavior |
|-------|----------|
| `off` | No healing intelligence. Rotation engine conditions only (like today) |
| `tank` | Restricted healing: self + emergency group + critical single target |
| `full` | Full deficit-based healing intelligence (same brain as CLR) |

- **Default**: `tank` when CombatMode='tank', `full` when CombatMode='assist'
- **Master toggle**: Existing `DoHealing` setting acts as kill switch — if false, no healing regardless of HealMode
- **Rotation engine interaction**: When HealMode != `off`, rotation engine skips the `heal` layer for PAL via `skipLayers = { heal = true }`. Prevents double-casting between condition-based rotation heals and the intelligence system.

**Healing tab UI**: PAL is already recognized as a healer in `tab_healing.lua`. Add HealMode dropdown at the top of the tab. Existing healing config UI appears once the gate opens.

---

## 2. Healing System Gate Opening

**Two gates to open:**

### healing/init.lua (line 99)
```lua
-- Current:
return classShort == 'CLR'
-- Change to:
return classShort == 'CLR' or classShort == 'PAL'
```

### automation/healing.lua (lines 89, 280)
Remove PAL exclusion. Add PAL legacy profile for fallback:
```lua
if classShort == 'PAL' then
    return {
        main = { 'Preservation', 'HealNuke', 'SelfHeal' },
        big = { 'HealNuke', 'Preservation', 'SelfHeal' },
        group = { 'Aurora' },
        hotSingle = {},
        hotGroup = {},
    }
end
```

**Phased loading**: PAL gets the same 5-phase loading as CLR. No PAL-specific change — phased loading is class-agnostic once the gate opens.

---

## 3. PAL Spell Categorization

The existing `config.lua` categorizes spells by metadata (subcategory + target type). PAL spells should auto-categorize:

| PAL Spell Line | EQ Subcategory | Expected Category | Notes |
|---|---|---|---|
| Preservation | 'quick heal' + single | `fast` | PAL's bread-and-butter heal |
| Aurora | 'heals' + Group V1 | `group` | Group direct heal |
| HealNuke | 'heals' + "Single Friendly (or Target's Target)" | `nukeHeal` (new) | Dual-mode: heal PC directly OR nuke NPC to heal its target |
| SelfHeal | 'heals' + single (self-only?) | Needs verification | May need explicit override |

**Verification at implementation time**: Check actual EQ spell metadata via `mq.TLO.Spell('Anticipated Preservation').SubCategory()` and `.TargetType()`. If auto-categorization fails, add explicit overrides in PAL class config.

---

## 4. Target Monitor Mode-Awareness

`target_monitor.lua` gains a target filter based on HealMode.

### Filtering rules by mode:

| HealMode | Eligible Targets | HP Threshold | Group Heal Trigger |
|---|---|---|---|
| `full` | All group members, XTarget allies, self | Normal (~80%) | 2+ injured at 75% |
| `tank` | Self (always at higher threshold), group members below critical %, group heal if 2+ critical | Critical (~40%) for others, ~70% for self | 2+ at 40% |
| `off` | None (system disabled) | N/A | N/A |

### Implementation:
- New function: `getHealPolicy(settings)` returns `{ mode, criticalPct, selfHealPct, groupHealThreshold }`
- Existing `findBestTarget()` checks policy before adding candidates to pool
- In `tank` mode: self checked first (always). Others only if below criticalPct
- In `full` mode: all candidates compete equally via deficit scoring (same as CLR)

### Role detection:
- PAL stays as `'tank'` role in target_monitor — correct for how OTHER healers see the PAL
- PAL's own HealMode only affects what the PAL's healing brain does

### Incoming heal coordination:
- PAL in both modes: broadcasts outgoing heals, receives incoming heal data
- Prevents double-healing between PAL and CLR box characters
- Class-agnostic — works automatically once PAL is in the healing system

---

## 5. Rotation Engine Integration

When HealMode != `off`, rotation engine skips the `heal` layer to prevent double-casting.

**Main loop flow in SideKick.lua:**
1. **Healing intelligence tick** (runs first, returns `priorityHealingActive`)
2. **Rotation engine tick** (receives `skipLayers = { heal = true }` when HealMode active)
3. **Tank module tick** (unchanged, handles aggro/positioning)

**Emergency AAs** (LayOnHands, DivineCall, Beacon): Stay in rotation engine's `emergency` layer. Fire before healing intelligence. No conflict — instant AAs, no cast time.

**Spell channel contention**: Healing uses the `spell` channel (500ms GCD). Tank uses `aa_disc` and `melee` channels. Independent lockouts — heal cast doesn't block taunt. Only contention: heal spell vs aggro spell wanting `spell` channel simultaneously. Resolved by execution order (healing ticks first).

---

## 6. Target's Target Spell Support

### Dual-mode target type
`"Single Friendly (or Target's Target)"` spells work two ways:
- **Cast on PC**: Direct heal (requires target switch to friendly)
- **Cast on NPC**: Heals whoever the NPC is targeting (preferred — no target switch, bonus damage, bonus hate)

### New spell category: `nukeHeal`
- Detected via `spell.TargetType()` containing `"Target's Target"`
- Tagged with `targetMode = 'preferNPC'`
- If auto-detection fails: PAL class config explicit override maps Denouncement line to `nukeHeal`

### Heal selector integration
- `nukeHeal` spells are eligible candidates alongside regular heals when scoring for a target
- **NPC search**: For each NPC on XTarget, check if `NPC.Target.ID == healTargetId`. If found, that NPC becomes `castTargetId`
- **Efficiency bonus**: nukeHeal does damage + healing in one GCD — small scoring bonus in combat
- **Constraint**: If no NPC is currently targeting the heal recipient, nukeHeal via NPC path is ineligible. Falls back to direct PC cast.
- **Return value**: Selector returns `{ spell, healTargetId, castTargetId }` — castTargetId is the NPC (or nil for PC fallback)

### Spell engine targeting
- New handling in `spell_engine.lua` for TT casts:
  - If `castTargetId` provided and differs from `healTargetId`: target the NPC, cast spell
  - The heal component lands on the NPC's target automatically (EQ mechanic)
- Add `"Single Friendly (or Target's Target)"` to known target types

### Tank mode shortcut
- PAL is already targeting an NPC while tanking
- Check if current target's target needs healing → cast Denouncement on current target
- Zero target switching — most efficient path

---

## 7. Tank Heal Hints

Healing intelligence exposes hints for future tank module consumption.

### Hint interface
```lua
-- healing/init.lua exposes:
M.getHealHint()  -- returns { mobId, healTargetId, spellName, timestamp } or nil
M.clearHealHint()  -- called by tank module after acting on hint
```

### Hint lifecycle
- Healing brain sets hint when it identifies a nukeHeal opportunity but the PAL isn't targeting the right NPC
- Meaning: "If you target mob X, I have a Denouncement ready for the person it's attacking"
- Hint expires after ~3 seconds (stale data guard)
- Tank module reads hints when choosing which loose mob to taunt — all else equal, prioritize the mob with a heal opportunity
- Tank module clears hint after acting on it

### Separation of concerns
- Healing intelligence works fully independently — hints are optional output
- Tank module works independently — hint consumption is a follow-up enhancement
- Simple shared table, no actors/events needed (same process)

### Future tank integration (not this design)
```
1. Tank detects loose mob attacking healer
2. Checks healHint — healing brain wants Denouncement on this mob
3. Target loose mob → Taunt → Denouncement (heal + hate + damage)
4. Return to original target
```

---

## 8. Target's Target Heal Tracking

Dedicated tracking to validate TT healing is working and measure effectiveness.

### Per-attempt metrics
- Timestamp
- Spell name (which Denouncement rank)
- Cast target (NPC name + ID)
- Intended heal recipient (who the NPC was attacking)
- Targeting path used: NPC (preferred) vs PC (fallback)
- Outcome: landed / fizzled / resisted / interrupted
- Heal amount (from heal_tracker empirical data)
- Hint-driven: was this cast triggered by tank module consuming a hint

### Aggregate stats (rolling 5-minute window)
- TT casts attempted vs landed (success rate)
- NPC-path vs PC-fallback ratio (preferred path usage %)
- Total HP healed via TT path
- Hints generated vs consumed (cooperation rate, future metric)

### Implementation
- New file: `healing/tt_tracker.lua` (~80 lines)
- `healing/init.lua` calls `tt_tracker.recordAttempt()` before cast and `tt_tracker.recordResult()` after
- Feeds into existing healing logger for file output

### UI visibility
- Collapsible section in healing tab: TT success rate, preferred-path %, last few casts
- Glanceable confirmation that Denouncement NPC-targeting is working

---

## Files Changed

| File | Change | Effort |
|------|--------|--------|
| `healing/init.lua` | Add PAL gate, TT cast path, heal hint exposure, tt_tracker calls | ~60 lines |
| `healing/config.lua` | Add `nukeHeal` category, detect TT target type | ~20 lines |
| `healing/heal_selector.lua` | Score nukeHeal, NPC search, return castTargetId | ~50 lines |
| `healing/target_monitor.lua` | `getHealPolicy()`, mode-aware filtering | ~40 lines |
| `healing/tt_tracker.lua` | New — attempt/result tracking, rolling stats | ~80 lines |
| `automation/healing.lua` | Remove PAL exclusion, add PAL legacy profile | ~15 lines |
| `utils/spell_engine.lua` | Handle TT target type in targeting logic | ~10 lines |
| `data/class_configs/PAL.lua` | HealMode setting, HealNuke → nukeHeal override | ~10 lines |
| `ui/settings/tab_healing.lua` | HealMode dropdown, TT stats collapsible section | ~35 lines |
| `SideKick.lua` | Pass skipLayers when HealMode active | ~5 lines |

**Total**: ~325 lines across 10 files. No new architectural patterns — extends existing systems.

## Unchanged Files
- `heal_tracker.lua` — learns PAL spell amounts automatically
- `incoming_heals.lua` — class-agnostic coordination
- `combat_assessor.lua` — class-agnostic pressure detection
- `hot_analyzer.lua` — PAL has no HoTs, categories stay empty
- `rotation_engine.lua` — already has skipLayers from tank plan
- `action_executor.lua` — channel system works as-is
- Tank module (`automation/tank.lua`) — hint consumption is a follow-up

## Verification
1. Check EQ spell metadata for Preservation/Aurora/HealNuke/SelfHeal target types and subcategories
2. Test HealMode=off: verify no healing intelligence fires, rotation conditions work as before
3. Test HealMode=tank: verify only self + critical targets get heals
4. Test HealMode=full: verify full deficit-based healing like CLR
5. Test TT targeting: verify Denouncement prefers NPC path, falls back to PC
6. Test TT tracking: verify stats update in UI, success rate accurate
7. Test incoming heal coordination: verify PAL broadcasts + receives heal data
8. Test skipLayers: verify rotation engine doesn't double-cast heal layer spells
