# Caster Assist Mode & Spell Rotation Integration Design

## Overview

Two interconnected features for SideKick:
1. **Caster Assist Mode** - MA-following with stay-put casting and rooted-mob escape logic
2. **Spell Rotation Integration** - Wire spell engine into rotation engine with failure handling and immune tracking

---

## Part 1: Caster Assist Mode

### Target Acquisition

- Same as melee - follow Main Assist's target
- Uses existing `get_assist_target()` logic from `combatassist.lua`
- Respects assist mode setting (group MA, raid MA 1-3, by-name)

### Positioning Toggle

- New setting: `CasterUseStick` (boolean, default: false)
- **When enabled:** Use stick command like melee (existing behavior)
- **When disabled:** Stay put, cast from current position
- No automatic range-seeking - caster positions themselves manually

### Class Behavior Rules

**Pure Casters (escape logic applies):**
- ENC, WIZ, MAG, NEC, CLR, DRU, SHM

**Hybrid Melee-Casters (no escape logic, use stick):**
- PAL, SHD, RNG, BST, BRD - These classes melee and cast; they stick to target like other melee

| Class Type | Stick Default | Escape on Rooted Mob |
|------------|---------------|----------------------|
| Pure melee (WAR, MNK, ROG, BER) | Yes | N/A |
| Hybrid melee (PAL, SHD, RNG, BST, BRD) | Yes | No |
| Pure caster (ENC, WIZ, MAG, NEC, CLR, DRU, SHM) | No (configurable) | Yes |

**Override:**
- Pure casters can enable `CasterUseStick` to behave like melee (disables escape logic)
- Hybrids always use stick, setting is ignored for them

---

## Part 2: Caster Safety - Rooted Mob Escape

### Detection

- Trigger condition: Mob is targeting me (or I'm on its hate list) AND mob has root debuff (`spawn.Rooted()`)
- Check runs each tick when `CasterUseStick` is false
- Only applies to pure caster classes

### Escape Priority

1. **Find safe groupmate** - Nearest group member with no hostile mobs within 30 units of them
2. **Fallback kite** - If no safe groupmate exists, move 30 units away from the rooted mob

### Cast Completion Exceptions

- **Mez** - Let complete (might solve the problem)
- **Heal** - Let complete (keeping yourself/group alive)
- All other spell types interrupt immediately for safety movement

### Navigation

- Use existing nav system (`/nav id X` or `/moveto`)
- Once safe (rooted mob no longer in range or dead), resume casting from new position

---

## Part 3: Spell Rotation Integration

### Layer Assignment

Spells use same category system as AAs/discs. Category tags map to rotation layers:

| Category | Layer | Examples |
|----------|-------|----------|
| `cc`, `mez` | support | Single mez, AE mez, stun |
| `debuff`, `slow`, `malo`, `tash` | support | Slow, Cripple, Tash, Malo |
| `selfheal`, `groupheal` | support | Heals, HoTs |
| `nuke`, `dot` | combat | Direct damage, DoTs |
| `burn` | burn | Big nukes, twincast spells |
| `buff` | utility | Out-of-combat buffs |

### Resist Type Selection

- New setting: `PreferredResistType` (enum: Magic/Fire/Cold/Poison/Disease/Chromatic/Any)
- Default: `Any` (use whatever's available)
- When set, only load nukes matching that resist type
- Doesn't affect non-damage spells (debuffs, heals, CC)

### Execution Order

- AAs/discs fire first (instant)
- Spell rotation runs after, using remaining tick time

---

## Part 4: Spell Failure Handling & Immune Tracking

### Retry Behavior

| Outcome | Behavior |
|---------|----------|
| Fizzle | Retry same spell next tick |
| Resist | Retry same spell next tick |
| Interrupt | Retry same spell next tick |
| Target died (debuffs) | Immediately ready for next target (no reset delay) |
| Target died (other spells) | Reset rotation; restart if new mob engaged within 2 seconds |
| Immune | Log to database, skip this spell for this mob |

### Immune Database

**Storage:** `mq.configDir/SideKick/immune_database.lua`

**On-Disk Structure:**
```lua
{
    ["Crushbone"] = {
        ["Orc Centurion"] = { slow = true },
        ["Emperor Crush"] = { slow = true, mez = true },
    },
    ["Plane of Fire"] = {
        ["Fire Elemental"] = { fire = true },
    },
}
```

**Memory Loading:**
- **Loaded into memory on zone entry** - Read once when entering zone
- Updated in memory when new immune detected
- Persisted to disk periodically (or on zone exit)

**In-Memory Structure:**
```lua
_zoneImmunes = {
    ["Orc Centurion"] = { slow = true },
    ["Emperor Crush"] = { slow = true, mez = true },
}
```

**Usage:**
- On zone change: `_zoneImmunes = immuneDB[currentZone] or {}`
- Before casting: check `_zoneImmunes[mobName][spellCategory]`
- Fast in-memory lookup, no disk access during combat

**Categories Tracked:**
`slow`, `mez`, `root`, `snare`, `malo`, `tash`, `fire`, `cold`, `magic`, `poison`, `disease`, `chromatic`

### Rotation Reset

- When target dies, debuffs are immediately ready for next target (no delay)
- Other spells: mark rotation as "reset pending"
- If new mob engaged within 2 seconds, start rotation from top
- If > 2 seconds, treat as fresh combat start anyway

---

## Part 5: New Settings

### Caster Assist Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `CasterUseStick` | boolean | false | Pure casters stick to target like melee |
| `CasterEscapeRange` | number | 30 | Distance to move from rooted mob (fallback kite) |
| `CasterSafeZoneRadius` | number | 30 | Groupmate is "safe" if no mobs within this range |
| `PreferredResistType` | enum | Any | Magic/Fire/Cold/Poison/Disease/Chromatic/Any |

### Spell Rotation Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `SpellRotationEnabled` | boolean | false | Enable automated spell casting |
| `RotationResetWindow` | number | 2 | Seconds to wait for new mob before resetting rotation |
| `RetryOnFizzle` | boolean | true | Retry spell on fizzle |
| `RetryOnResist` | boolean | true | Retry spell on resist |
| `RetryOnInterrupt` | boolean | true | Retry spell on interrupt |
| `UseImmuneDatabase` | boolean | true | Skip spells for known immune mobs |

---

## Part 6: File Structure

### New Files

| File | Purpose |
|------|---------|
| `automation/caster_assist.lua` | Caster-specific assist logic (escape, positioning) |
| `data/immune_database.lua` | Persistent immune tracking (auto-generated) |
| `utils/spell_rotation.lua` | Spell selection and rotation state machine |

### Modified Files

| File | Changes |
|------|---------|
| `automation/assist.lua` | Route to caster_assist for pure caster classes |
| `utils/rotation_engine.lua` | Add spell rotation tick after AA/disc rotation |
| `utils/spell_engine.lua` | Add retry state, failure type tracking |
| `utils/spell_events.lua` | Detect immune messages, track failure types |
| `ui/settings.lua` | Add caster assist and spell rotation settings UI |
| `registry.lua` | Register new setting keys |
| `data/defaults.lua` | Add default values for new settings |

### Integration Point

```
SideKick.lua main loop
    └── Assist.tick()
            ├── Melee classes → CombatAssist.tick() (existing)
            └── Caster classes → CasterAssist.tick() (new)
                    └── Check escape condition
                    └── Handle positioning
    └── RotationEngine.tick()
            ├── AA/disc layers (existing)
            └── SpellRotation.tick() (new, runs after)
```

---

## Implementation Order

### Phase 1: Caster Assist Mode
1. Create `automation/caster_assist.lua` with class detection
2. Add `CasterUseStick` setting and UI
3. Implement rooted mob detection
4. Implement safe groupmate finding
5. Implement fallback kite logic
6. Wire into `assist.lua` routing

### Phase 2: Spell Rotation Integration
1. Create `utils/spell_rotation.lua` with state machine
2. Add spell category assignment
3. Add resist type filtering
4. Wire into `rotation_engine.lua`
5. Add settings UI

### Phase 3: Failure Handling & Immune Database
1. Extend `spell_events.lua` for immune detection
2. Create immune database persistence with zone-based memory loading
3. Add retry logic to spell engine
4. Add rotation reset logic (immediate for debuffs, 2s window for others)
5. Wire immune checks into spell selection
