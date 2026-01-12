# SideKick Combat Automation System Design

## Overview

A comprehensive combat automation system supporting three play modes:
- **Manual**: UI enhancements only, user clicks abilities
- **Hybrid**: Some automation, user retains control over key abilities
- **Fully Automated**: Complete combat automation with user-defined conditions

The system adopts rgmercs' layered rotation architecture while preserving SideKick's UI-driven condition system, giving users conditional control that surpasses code-based automation.

---

## Design Goals

1. **User conditional control**: Every ability can be gated by user-authored conditions via ConditionBuilder
2. **Mode per ability**: Each ability has its own mode (MANUAL, ON_CD, ON_BURN, ON_NAMED, ON_CONDITION)
3. **Role-based behavior**: Tank, DPS, Healer, Support behave differently
4. **Multi-character coordination**: Actor-based messaging for group-wide state sync
5. **Non-blocking execution**: No UI freezes from long operations
6. **Incremental migration**: Old system runs alongside new until stable

---

## Core Architecture

### Action Abstraction

Every executable thing (AA, disc, spell, item) is an Action:

```lua
Action = {
    -- Identity
    id = "lay_on_hands",
    name = "Lay on Hands",
    kind = "aa",              -- aa, disc, spell, item
    altID = 6001,             -- For AAs
    discName = nil,           -- For discs
    spellName = nil,          -- For spells
    itemName = nil,           -- For items

    -- Categorization
    category = "survival",    -- survival, cc, aggro, debuff, offensive, buff
    layer = "emergency",      -- Which rotation layer
    burnTier = "long",        -- short, medium, long (for burns)
    priority = 10,            -- Within-layer priority (lower = higher)

    -- Execution control
    settingKey = "doLayOnHands",
    modeKey = "doLayOnHandsMode",
    conditionKey = "doLayOnHandsCondition",
    mode = "ON_CONDITION",    -- MANUAL, ON_CD, ON_BURN, ON_NAMED, ON_CONDITION
    condition = { ... },      -- ConditionBuilder data

    -- Metadata
    isAoE = false,            -- For mez-break checks
    castTime = 0,             -- For spell timing
    recastTime = 4320,        -- Cooldown in seconds
    timerGroup = nil,         -- For disc mutual exclusion

    -- Runtime state
    ready = false,
    cooldownRemaining = 0,
}
```

### Rotation Layers

Combat runs through layers in priority order. Each layer processes one action per tick:

```lua
ROTATION_ORDER = {
    "emergency",    -- Actor-interrupt driven (incoming broadcasts)
    "survival",     -- Heals + defensives (self + group)
    "cc",           -- Crowd control (first-class module)
    "aggro",        -- Tank hate tools (only if role == tank)
    "debuff",       -- Slows, snares, malo, etc.
    "offensive",    -- DPS abilities (only if role ~= tank)
    "buff",         -- Out-of-combat only
    "burn",         -- ON_BURN abilities when burn active
}
```

### Two-Level Execution Model

1. **Outer loop**: Layer priority (Emergency → Survival → CC → etc.)
2. **Inner check**: Each action's mode gate (MANUAL skips, ON_BURN checks burn state, ON_CONDITION evaluates)

```lua
function runLayer(layerName, state)
    local actions = ActionRegistry.getByLayer(layerName)
    actions = sortByPriority(actions)

    for _, action in ipairs(actions) do
        -- Skip if mode doesn't allow
        if not checkModeGate(action, state) then
            goto continue
        end

        -- Evaluate user condition
        if action.mode == MODE.ON_CONDITION then
            if not ConditionBuilder.evaluate(action.condition) then
                goto continue
            end
        end

        -- Check readiness
        if not isReady(action) then
            goto continue
        end

        -- Execute through casting engine
        local success, reason = Casting.execute(action)
        if success then
            return true  -- One action per layer per tick
        end

        ::continue::
    end
    return false
end
```

---

## Category Definitions

### Survival (Heals + Defensives)
- Self heals, group heals, HoTs
- Defensive cooldowns (Armor of the Inquisitor, etc.)
- Emergency abilities (Lay on Hands, Divine Intervention)
- Runs first priority to keep people alive

### Crowd Control
- Mez (single and AE)
- Root, stun
- Charm (if applicable)
- First-class module with target lists, immune tracking, AE-vs-ST logic

### Aggro (Tank Only)
- Taunt and taunt-like abilities
- AoE hate generation
- Single-target hate generation
- Only runs when `role == "tank"`

### Debuff
- Slows (Sha's Revenge, etc.)
- Snares
- Malo/Tash (resistance debuffs)
- Disease/poison debuffs

### Offensive (Non-Tank)
- DPS AAs and discs
- Nukes (when spell casting added)
- DoTs
- Only runs when `role ~= "tank"`

### Buff (Out of Combat)
- Self buffs
- Group buffs
- Only runs when `not Me.Combat()`

---

## Burn Mode Enhancements

### Burn Tiers

Users categorize each burn ability:

| Tier | Usage | Examples |
|------|-------|----------|
| Short | Use freely on any fight | 2-5 minute cooldowns |
| Medium | Use on tougher fights | 10-15 minute cooldowns |
| Long | Save for named/boss | 30+ minute cooldowns |

### Burn End Conditions

User selects how burn ends:

1. **Timed**: Burn lasts X seconds (current behavior, default 30s)
2. **Target Dead**: Burn ends when the burn target dies
3. **Area Clear**: Burn ends when no aggressive NPCs remain in range

### Burn Integration

Burns unlock `ON_BURN` abilities but respect layer priority:

```lua
function checkModeGate(action, state)
    if action.mode == MODE.MANUAL then
        return false  -- Never auto-fire
    end
    if action.mode == MODE.ON_CD then
        return true   -- Always try if ready
    end
    if action.mode == MODE.ON_BURN then
        if not state.burnActive then return false end
        -- Check burn tier vs target
        if action.burnTier == "long" and not state.burnTarget.Named then
            return false  -- Don't waste long burns on trash
        end
        return true
    end
    if action.mode == MODE.ON_NAMED then
        return state.targetIsNamed
    end
    if action.mode == MODE.ON_CONDITION then
        return true  -- Condition evaluated separately
    end
    return false
end
```

### Discipline Mutual Exclusion

Only one disc can run at a time. The system tracks:

```lua
CastingState = {
    discActive = "Mighty Strike",
    discExpiry = os.clock() + 120,  -- When current disc ends
}

-- Gate blocks new disc if one is running
function gates.discSlotFree(action)
    if action.kind ~= 'disc' then return true end
    return os.clock() > CastingState.discExpiry
end
```

---

## Role-Based Melee

### Tank
Full combatassist logic:
- Stick with positioning (front for aggro)
- Navigation to mobs
- Aggro cycling
- Taunt runs (non-blocking state machine)
- Group centroid positioning

### DPS Melee
Simple stick:
- Stick behind target
- Basic positioning
- Follow tank's primary target

### Caster/Ranged
No melee:
- Maintain distance from target
- Cast from range
- No stick commands

```lua
function Melee.tick(role, state)
    if role == "tank" then
        Tank.tick(state)
    elseif role == "dps_melee" then
        SimpleMelee.tick(state)
    else
        -- Caster: no melee, maintain range
        Range.tick(state)
    end
end
```

---

## Casting Engine

Centralized execution with proper gating. Integrates with MQ2Cast plugin.

### Execution Gates

```lua
M.gates = {
    notDead       = function() return not mq.TLO.Me.Dead() end,
    notMoving     = function() return not mq.TLO.Me.Moving() end,
    notCasting    = function() return not mq.TLO.Me.Casting() end,
    notStunned    = function() return not mq.TLO.Me.Stunned() end,
    notSilenced   = function() return not mq.TLO.Me.Silenced() end,
    notFeigning   = function() return not mq.TLO.Me.Feigning() end,
    gcdReady      = function() return os.clock() > M.state.globalCooldown end,
    hasReagent    = function(action) return M.checkReagent(action) end,
    mezSafe       = function(action) return M.checkMezSafe(action) end,
    discSlotFree  = function(action)
        if action.kind ~= 'disc' then return true end
        return os.clock() > M.state.discExpiry
    end,
}
```

### Gate Profiles Per Action Type

```lua
M.gateProfiles = {
    spell = { "notDead", "notCasting", "notStunned", "notSilenced", "gcdReady", "hasReagent", "mezSafe" },
    aa    = { "notDead", "notCasting", "notStunned", "gcdReady" },
    disc  = { "notDead", "notCasting", "discSlotFree" },
    item  = { "notDead", "notCasting", "gcdReady" },
}
```

### MQ2Cast Integration

```lua
function M.castSpell(action, targetId)
    local cmd = string.format('/casting "%s" -maxtries|3', action.name)
    if targetId then
        cmd = cmd .. string.format(' -targetid|%d', targetId)
    end
    mq.cmd(cmd)

    M.state.casting = true
    M.state.castStartTime = os.clock()
    M.state.currentAction = action
    return true
end

function M.tick()
    if M.state.casting then
        local status = mq.TLO.Cast.Status()
        if status == 'C' then
            -- Still casting, check for interrupt conditions
            if M.shouldInterrupt(M.state.currentAction) then
                mq.cmd('/stopcast')
            end
        elseif status == 'I' then
            -- Idle, cast finished or failed
            M.state.casting = false
            M.state.currentAction = nil
        end
    end
end
```

### Mez-Break Prevention

```lua
function M.checkMezSafe(action)
    if not action.isAoE then return true end

    -- Check local mez list + actor broadcasts
    local mezzedMobs = CC.getMezzedMobs()
    local targetCount = Targeting.countNearbyHostiles(action.range or 30)

    -- If AoE and mezzed mobs in range, block
    if #mezzedMobs > 0 and targetCount > 1 then
        return false
    end
    return true
end
```

---

## Actor Coordination Protocol

### Message Categories

```lua
ACTOR_MESSAGES = {
    -- Combat intent (group-wide state)
    ["burn:state"]      = { burnTier, duration, endCondition, targetId },
    ["pause:state"]     = { mode = "soft|hard", reason },
    ["assist:target"]   = { targetId, targetName, mode = "sticky|follow" },

    -- Emergency interrupts (priority escalation)
    ["emergency:heal"]  = { charName, hpPct, priority },
    ["emergency:aggro"] = { charName, mobId, mobName },

    -- CC safety (do-not-break list)
    ["cc:mezzed"]       = { mobId, expiry, mezzer },
    ["cc:broken"]       = { mobId },
    ["cc:immune"]       = { mobId, spellType },

    -- Role claims (prevent duplication)
    ["role:claim"]      = { role, charName, priority },
    ["role:release"]    = { role, charName },

    -- Throttling
    ["dps:throttle"]    = { active, reason, duration },
    ["aggro:report"]    = { charName, pctAggro, secondaryPct, targetId },

    -- Remote execution (replaces /dex)
    ["cmd:use"]         = { kind, actionId, targetId },
    ["cmd:ack"]         = { success, reason },

    -- Telemetry
    ["debug:action"]    = { charName, action, result, reason },
}
```

### Safety Model

- Whitelist valid message IDs
- Validate sender (same server, in group/raid)
- TTL/staleness check (reject messages > 2s old)
- Remote `cmd:use` still respects local user toggles/conditions

### Emergency Interrupt Flow

```lua
-- Healer receives emergency:heal
if id == 'emergency:heal' then
    if fromMe then return end
    -- Don't interrupt if healing main tank
    if Rotation.currentLayer == 'survival' and
       Rotation.currentTarget == state.mainTankId then
        return
    end
    -- Interrupt current action and prioritize emergency heal
    Rotation.interruptForEmergency('heal', content)
    return
end
```

### CC Safety Flow

```lua
-- Mezzer broadcasts mezzed mob
function CC.onMezLanded(mobId, duration)
    Actors.broadcast({
        id = 'cc:mezzed',
        mobId = mobId,
        expiry = os.clock() + duration,
        mezzer = Me.CleanName(),
    })
end

-- DPS/Tank receives and tracks
if id == 'cc:mezzed' then
    CC.addMezzedMob(content.mobId, content.expiry, content.mezzer)
    return
end

-- Casting engine checks before AoE
function Casting.checkMezSafe(action)
    if not action.isAoE then return true end
    return #CC.getMezzedMobs() == 0
end
```

### Role Arbitration

```lua
-- Prevent multiple characters doing same job
RoleClaims = {
    primary_healer = { char = "Healbot", priority = 10, lastSeen = ... },
    primary_slower = { char = "Shammy", priority = 10, lastSeen = ... },
    primary_mezzer = { char = "Chanter", priority = 10, lastSeen = ... },
}

function Actors.claimRole(role, priority)
    local existing = RoleClaims[role]
    if existing and existing.priority >= priority then
        return false  -- Higher priority already claimed
    end
    Actors.broadcast({ id = 'role:claim', role = role, charName = Me.CleanName(), priority = priority })
    return true
end
```

---

## ConditionBuilder Expansion

### New Properties

```lua
-- beneficial:Me
{ key = "PctAggro",          label = "Aggro",              type = "numeric", min = 0, max = 100 },
{ key = "SecondaryPctAggro", label = "Secondary Aggro",    type = "numeric", min = 0, max = 100 },
{ key = "ActiveDisc",        label = "has Disc running",   type = "boolean" },
{ key = "CombatState",       label = "Combat State",       type = "enum", values = {"COMBAT", "DEBUFF", "COOLDOWN"} },
{ key = "AmTank",            label = "is Main Tank",       type = "boolean" },
{ key = "AmMA",              label = "is Main Assist",     type = "boolean" },

-- detrimental:Target
{ key = "PctAggro",    label = "My Aggro on Target",  type = "numeric", min = 0, max = 100 },
{ key = "TargetOfTarget", label = "is targeting Me",  type = "boolean" },
{ key = "Tashed",      label = "is not Tashed",       type = "negated" },
{ key = "Maloed",      label = "is not Maloed",       type = "negated" },

-- spawn:Spawn
{ key = "XTargetCount",   label = "XTarget mobs",     type = "numeric", min = 0, max = 13 },
{ key = "HaterCount",     label = "Haters in range",  type = "numeric", thresholdLabel = "range", min = 0, max = 50, thresholdMin = 10, thresholdMax = 200 },
{ key = "MezzedCount",    label = "Mezzed mobs",      type = "numeric", min = 0, max = 20 },

-- group:Group (new subject)
{ key = "TankHP",         label = "Tank HP",          type = "numeric", isPercent = true },
{ key = "LowestHP",       label = "Lowest member HP", type = "numeric", isPercent = true },
{ key = "ClericMana",     label = "Cleric Mana",      type = "numeric", isPercent = true },
```

### Persistence Fix

Fix `core.lua` to properly serialize condition data:

```lua
-- Before (coerces to string)
if key:match('Condition$') then
    value = tostring(value)
end

-- After (preserve table structure)
if key:match('Condition$') then
    value = ConditionBuilder.serialize(value)
end

-- On load
if key:match('Condition$') then
    value = ConditionBuilder.deserialize(value)
end
```

---

## Non-Blocking Tank Refactor

Convert blocking waits to state machine:

```lua
-- tank.lua
M.tauntState = {
    phase = "idle",  -- idle, targeting, nav_to_mob, taunt, return
    looseMob = nil,
    savedTargetId = nil,
    timeout = 0,
}

function M.startTauntRun(looseMob)
    M.tauntState = {
        phase = "targeting",
        looseMob = looseMob,
        savedTargetId = mq.TLO.Target.ID(),
        timeout = os.clock() + 5,  -- 5 second max
    }
    Actors.broadcastTauntRun()
end

function M.tickTauntRun()
    local s = M.tauntState
    if s.phase == "idle" then return end

    -- Timeout check
    if os.clock() > s.timeout then
        M.abortTauntRun()
        return
    end

    if s.phase == "targeting" then
        Targeting.targetSpawn(s.looseMob)
        if mq.TLO.Target.ID() == s.looseMob.ID() then
            local dist = s.looseMob.Distance() or 999
            if dist > Aggro.TAUNT_RANGE then
                mq.cmdf('/nav id %d', s.looseMob.ID())
                s.phase = "nav_to_mob"
            else
                s.phase = "taunt"
            end
        end
        return
    end

    if s.phase == "nav_to_mob" then
        local dist = s.looseMob.Distance() or 999
        if dist <= Aggro.TAUNT_RANGE then
            mq.cmd('/nav stop')
            s.phase = "taunt"
        end
        return
    end

    if s.phase == "taunt" then
        if Aggro.isTauntReady() then
            Aggro.doTaunt()
            s.phase = "return"
        end
        return
    end

    if s.phase == "return" then
        if s.savedTargetId and s.savedTargetId > 0 then
            mq.cmdf('/target id %d', s.savedTargetId)
        end
        Actors.broadcastTauntDone()
        s.phase = "idle"
        return
    end
end

function M.abortTauntRun()
    mq.cmd('/nav stop')
    Actors.broadcastTauntDone()
    M.tauntState.phase = "idle"
end
```

---

## File Structure

```
sidekick/
├── SideKick.lua                 # Main entry (minimal changes)
│
├── automation/
│   ├── assist.lua               # Keep (thin wrapper)
│   ├── burn.lua                 # Extend (add tiers, end conditions)
│   ├── chase.lua                # Keep as-is
│   ├── tank.lua                 # Refactor (state machine, no blocking)
│   └── cc.lua                   # NEW: First-class CC module
│
├── combat/                      # NEW: Core combat system
│   ├── rotation.lua             # Rotation layer engine
│   ├── action_registry.lua      # Action abstraction + registry
│   ├── casting.lua              # Centralized casting engine
│   ├── melee.lua                # Role-based melee (tank/dps/caster)
│   └── state.lua                # Combat state machine
│
├── actors/
│   ├── shareddata.lua           # Keep
│   ├── protocol.lua             # NEW: Message definitions + validation
│   └── handlers.lua             # NEW: Message handlers
│
├── utils/
│   ├── actors_coordinator.lua   # Extend (import protocol + handlers)
│   ├── abilities.lua            # Deprecate → migrate to action_registry
│   ├── aggro.lua                # Keep
│   ├── targeting.lua            # Extend (add xtarget helpers)
│   ├── positioning.lua          # Keep
│   └── core.lua                 # Fix condition persistence
│
├── ui/
│   ├── condition_builder.lua    # Extend (new primitives)
│   ├── grids.lua                # Extend (layer/burnTier columns)
│   ├── settings.lua             # Extend (combat mode selector)
│   └── rotation_debug.lua       # NEW: Debug panel for rotation state
│
├── data/
│   ├── classes/                 # Extend (add category, layer, burnTier)
│   ├── disciplines/             # Extend (add timer groups)
│   └── rotation_defaults.lua    # NEW: Default layer configs per class
```

---

## Implementation Order

### Sprint 1: Core Engine (No UI changes)
1. `combat/action_registry.lua` - Action abstraction
2. `combat/casting.lua` - Centralized execution gates
3. `combat/rotation.lua` - Layer-based rotation engine
4. `combat/state.lua` - Combat state machine

### Sprint 2: Data Migration
5. Update `data/classes/*.lua` - Add category, layer, burnTier fields
6. Update `data/disciplines/*.lua` - Add timer groups for mutual exclusion
7. `data/rotation_defaults.lua` - Default layer order per role

### Sprint 3: Tank Refactor
8. `combat/melee.lua` - Role-based melee behavior
9. `automation/tank.lua` - Convert to state machine (no blocking)
10. `automation/cc.lua` - First-class CC module

### Sprint 4: Actor Protocol
11. `actors/protocol.lua` - Message definitions + validation
12. `actors/handlers.lua` - Message handlers
13. Extend `utils/actors_coordinator.lua` - Wire up new handlers

### Sprint 5: Burn Enhancements
14. Extend `automation/burn.lua` - Tiers, end conditions
15. Add burnTier gating to rotation engine

### Sprint 6: ConditionBuilder Expansion
16. Extend `ui/condition_builder.lua` - New primitives
17. Fix `utils/core.lua` - Condition persistence

### Sprint 7: UI Integration
18. Extend `ui/grids.lua` - Layer/burnTier columns
19. Extend `ui/settings.lua` - Combat mode selector (manual/hybrid/auto)
20. `ui/rotation_debug.lua` - Debug panel

### Sprint 8: Polish & Testing
21. Parallel system toggle (old vs new)
22. Per-class testing and tuning
23. Remove deprecated code paths

---

## Critical Path Dependencies

```
action_registry.lua
        │
        ├──► casting.lua ──► rotation.lua
        │                         │
        │                         ▼
        └──► melee.lua ──► tank.lua (refactored)
                               │
                               ▼
                          cc.lua
                               │
                               ▼
                     actors/protocol.lua
                               │
                               ▼
                     actors/handlers.lua
```

---

## Testing Strategy

### Unit Tests
- Action mode gate logic
- Condition evaluation
- Casting gate checks
- State machine transitions

### Integration Tests
- Full rotation cycle with mock actions
- Actor message send/receive
- CC safety with mezzed mobs

### Manual Testing Checklist
- [ ] Manual mode: abilities only fire on click
- [ ] Hybrid mode: selected abilities auto-fire, others manual
- [ ] Auto mode: full rotation runs
- [ ] Burn mode: tiers respected, end conditions work
- [ ] Tank: taunt runs complete without freezing UI
- [ ] CC: mez list prevents AoE break
- [ ] Multi-box: actor messages coordinate group
- [ ] Conditions: all new primitives evaluate correctly

---

## Appendix: rgmercs Reference Points

Key files studied for this design:

| Feature | rgmercs Location | SideKick Adaptation |
|---------|------------------|---------------------|
| Rotation layering | `war_class_config.lua:316` | `combat/rotation.lua` |
| Rotation entries | `war_class_config.lua:385` | `data/classes/*.lua` |
| Rotation engine | `rotation.lua:264` | `combat/rotation.lua` |
| AbilitySet resolution | `rotation.lua:361` | `combat/action_registry.lua` |
| Casting gates | `casting.lua:775` | `combat/casting.lua` |
| Settings metadata | `war_class_config.lua:900` | `ui/settings.lua` |
| CC module | `mez.lua:400` | `automation/cc.lua` |
| Actor comms | `comms.lua:15` | `actors/protocol.lua` |

---

## Appendix: Mode Definitions

```lua
MODE = {
    MANUAL       = 1,  -- Never auto-fire, click only
    ON_CD        = 2,  -- Fire whenever ready
    ON_BURN      = 3,  -- Fire only when burn active
    ON_DEMAND    = 4,  -- Legacy: manual with UI feedback
    ON_NAMED     = 5,  -- Fire only on named mobs
    ON_CONDITION = 6,  -- Fire when condition evaluates true
}
```

---

## Appendix: Burn Tier Definitions

```lua
BURN_TIER = {
    SHORT  = "short",   -- 2-5 minute cooldowns, use freely
    MEDIUM = "medium",  -- 10-15 minute cooldowns, tougher fights
    LONG   = "long",    -- 30+ minute cooldowns, named/boss only
}

BURN_END_CONDITION = {
    TIMED      = "timed",       -- X seconds duration
    TARGET_DEAD = "target_dead", -- When burn target dies
    AREA_CLEAR = "area_clear",  -- When no aggressive NPCs remain
}
```
