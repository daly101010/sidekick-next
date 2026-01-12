# Caster Assist & Spell Rotation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add caster-specific combat assist with rooted-mob escape logic, and integrate spell rotation into the combat tick.

**Architecture:** Caster assist routes pure casters (ENC/WIZ/MAG/NEC/CLR/DRU/SHM) to stay-put casting with escape-on-rooted-mob logic. Spell rotation runs after AA/disc rotation, with retry-on-failure and persistent immune tracking per zone/mob.

**Tech Stack:** MacroQuest Lua, mq.TLO, mq.event(), mq.pickle() for persistence

---

## Phase 1: Caster Assist Mode

### Task 1: Add Caster Assist Settings to Registry

**Files:**
- Modify: `registry.lua:100-110` (after Debuff settings)

**Step 1: Add new settings to registry.defaults**

Add after line ~100 (after DebuffPrioritizeSelfHeal):

```lua
    -- Caster Assist Settings
    CasterUseStick = { type = 'bool', Default = false, Category = 'Combat', DisplayName = 'Caster Use Stick' },
    CasterEscapeRange = { type = 'number', Default = 30, Category = 'Combat', DisplayName = 'Caster Escape Range' },
    CasterSafeZoneRadius = { type = 'number', Default = 30, Category = 'Combat', DisplayName = 'Safe Zone Radius' },
    PreferredResistType = { type = 'text', Default = 'Any', Category = 'Combat', DisplayName = 'Preferred Resist Type' },

    -- Spell Rotation Settings
    SpellRotationEnabled = { type = 'bool', Default = false, Category = 'Combat', DisplayName = 'Spell Rotation Enabled' },
    RotationResetWindow = { type = 'number', Default = 2, Category = 'Combat', DisplayName = 'Rotation Reset Window (sec)' },
    RetryOnFizzle = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Retry on Fizzle' },
    RetryOnResist = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Retry on Resist' },
    RetryOnInterrupt = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Retry on Interrupt' },
    UseImmuneDatabase = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Use Immune Database' },
```

**Step 2: Verify settings load**

Run: `/lua run sidekick`
Expected: No errors, settings appear in Core.Settings

**Step 3: Commit**

```bash
git add registry.lua
git commit -m "feat: add caster assist and spell rotation settings"
```

---

### Task 2: Create Caster Assist Module Skeleton

**Files:**
- Create: `automation/caster_assist.lua`

**Step 1: Create the module file**

```lua
-- F:/lua/SideKick/automation/caster_assist.lua
-- Caster-specific assist logic: stay-put casting with rooted-mob escape

local mq = require('mq')

local M = {}

-- Class categorization
M.PURE_CASTERS = {
    ENC = true, WIZ = true, MAG = true,
    NEC = true, CLR = true, DRU = true, SHM = true,
}

M.HYBRID_MELEE = {
    PAL = true, SHD = true, RNG = true, BST = true, BRD = true,
}

M.PURE_MELEE = {
    WAR = true, MNK = true, ROG = true, BER = true,
}

-- State
M.enabled = false
M.escapeState = {
    phase = 'idle',  -- idle, finding_safe, navigating, kiting
    targetGroupmateId = nil,
    kiteDirection = nil,
    rootedMobId = nil,
    startTime = 0,
}

-- Lazy-load dependencies
local _Core = nil
local function getCore()
    if not _Core then
        local ok, c = pcall(require, 'utils.core')
        if ok then _Core = c end
    end
    return _Core
end

local _CombatAssist = nil
local function getCombatAssist()
    if not _CombatAssist then
        local ok, ca = pcall(require, 'utils.combatassist')
        if ok then _CombatAssist = ca end
    end
    return _CombatAssist
end

--- Check if current class is a pure caster
-- @return boolean
function M.isPureCaster()
    local class = mq.TLO.Me.Class.ShortName()
    return M.PURE_CASTERS[class] == true
end

--- Check if current class is a hybrid melee
-- @return boolean
function M.isHybridMelee()
    local class = mq.TLO.Me.Class.ShortName()
    return M.HYBRID_MELEE[class] == true
end

--- Check if current class is pure melee
-- @return boolean
function M.isPureMelee()
    local class = mq.TLO.Me.Class.ShortName()
    return M.PURE_MELEE[class] == true
end

--- Initialize caster assist
-- @param opts table Options
function M.init(opts)
    opts = opts or {}
    M.enabled = false
    M.escapeState.phase = 'idle'
end

--- Enable/disable caster assist
-- @param val boolean
function M.setEnabled(val)
    M.enabled = val and true or false
end

--- Main tick function
-- @param settings table Settings table
function M.tick(settings)
    if not M.enabled then return end
    if not M.isPureCaster() then return end

    -- Check if user wants stick mode (behave like melee)
    local useStick = settings and settings.CasterUseStick
    if useStick then
        -- Delegate to CombatAssist for melee-like behavior
        local ca = getCombatAssist()
        if ca and ca.tick then
            ca.tick()
        end
        return
    end

    -- Stay-put caster mode: check for escape conditions
    M.checkEscapeCondition(settings)

    -- Handle ongoing escape navigation
    if M.escapeState.phase ~= 'idle' then
        M.tickEscape(settings)
    end
end

--- Check if we need to escape from a rooted mob
-- @param settings table Settings
function M.checkEscapeCondition(settings)
    -- Placeholder: will implement in Task 3
end

--- Tick the escape state machine
-- @param settings table Settings
function M.tickEscape(settings)
    -- Placeholder: will implement in Task 4
end

return M
```

**Step 2: Verify module loads**

Run: `/lua run sidekick`
Then in-game: Verify no errors in console

**Step 3: Commit**

```bash
git add automation/caster_assist.lua
git commit -m "feat: create caster_assist module skeleton"
```

---

### Task 3: Implement Rooted Mob Detection

**Files:**
- Modify: `automation/caster_assist.lua`

**Step 1: Add helper functions for mob detection**

Add after the lazy-load section:

```lua
--- Check if a spawn is targeting me
-- @param spawn userdata Spawn to check
-- @return boolean
local function isTargetingMe(spawn)
    if not spawn or not spawn() then return false end
    local myId = mq.TLO.Me.ID()
    local targetId = spawn.TargetOfTarget and spawn.TargetOfTarget.ID and spawn.TargetOfTarget.ID()
    return targetId == myId
end

--- Check if a spawn is rooted
-- @param spawn userdata Spawn to check
-- @return boolean
local function isRooted(spawn)
    if not spawn or not spawn() then return false end
    local rooted = spawn.Rooted and spawn.Rooted()
    return rooted and rooted ~= ''
end

--- Check if I'm on a mob's hate list (via XTarget)
-- @param spawnId number Spawn ID to check
-- @return boolean
local function isOnHateList(spawnId)
    if not spawnId or spawnId <= 0 then return false end
    local xtCount = mq.TLO.Me.XTarget() or 0
    for i = 1, xtCount do
        local xt = mq.TLO.Me.XTarget(i)
        if xt and xt() and xt.ID() == spawnId then
            return true
        end
    end
    return false
end

--- Find a rooted mob that's hitting me
-- @return userdata|nil Rooted mob spawn, or nil
local function findRootedMobHittingMe()
    local xtCount = mq.TLO.Me.XTarget() or 0
    for i = 1, xtCount do
        local xt = mq.TLO.Me.XTarget(i)
        if xt and xt() and xt.ID() and xt.ID() > 0 then
            -- Check if this mob is targeting me and is rooted
            if isTargetingMe(xt) and isRooted(xt) then
                return xt
            end
        end
    end
    return nil
end
```

**Step 2: Implement checkEscapeCondition**

Replace the placeholder:

```lua
--- Check if we need to escape from a rooted mob
-- @param settings table Settings
function M.checkEscapeCondition(settings)
    -- Already escaping? Don't re-check
    if M.escapeState.phase ~= 'idle' then return end

    -- Check if currently casting a mez or heal (don't interrupt these)
    local casting = mq.TLO.Me.Casting
    if casting and casting() then
        local spellName = casting.Name and casting.Name() or ''
        local targetType = casting.TargetType and casting.TargetType() or ''
        local category = casting.Category and casting.Category() or ''

        -- Check for mez (category or spell name patterns)
        local isMez = category:lower():find('mesmerize') or
                      spellName:lower():find('mez') or
                      spellName:lower():find('mesmer')

        -- Check for heal (beneficial + HP-related)
        local isHeal = (targetType == 'Single' or targetType == 'Group') and
                       (category:lower():find('heal') or spellName:lower():find('heal'))

        if isMez or isHeal then
            -- Let the cast complete
            return
        end
    end

    -- Find a rooted mob hitting me
    local rootedMob = findRootedMobHittingMe()
    if not rootedMob then return end

    -- Start escape sequence
    M.escapeState = {
        phase = 'finding_safe',
        targetGroupmateId = nil,
        kiteDirection = nil,
        rootedMobId = rootedMob.ID(),
        startTime = os.clock(),
    }

    -- Interrupt current cast (if any, and not mez/heal - already checked above)
    if mq.TLO.Me.Casting() then
        mq.cmd('/stopcast')
    end
end
```

**Step 3: Verify detection works**

Manual test: Get a rooted mob to target you, verify escape state changes from 'idle' to 'finding_safe'

**Step 4: Commit**

```bash
git add automation/caster_assist.lua
git commit -m "feat: implement rooted mob detection for caster escape"
```

---

### Task 4: Implement Safe Groupmate Finding

**Files:**
- Modify: `automation/caster_assist.lua`

**Step 1: Add function to count nearby hostiles**

```lua
--- Count hostile mobs near a location
-- @param x number X coordinate
-- @param y number Y coordinate
-- @param radius number Search radius
-- @return number Count of hostile NPCs
local function countHostilesNear(x, y, radius)
    local count = 0
    local xtCount = mq.TLO.Me.XTarget() or 0
    for i = 1, xtCount do
        local xt = mq.TLO.Me.XTarget(i)
        if xt and xt() and xt.ID() and xt.ID() > 0 then
            local mobX = xt.X() or 0
            local mobY = xt.Y() or 0
            local dist = math.sqrt((x - mobX)^2 + (y - mobY)^2)
            if dist <= radius then
                count = count + 1
            end
        end
    end
    return count
end

--- Find the nearest safe groupmate (no hostiles nearby)
-- @param safeRadius number Radius to check for hostiles
-- @return number|nil Spawn ID of safe groupmate, or nil
local function findSafeGroupmate(safeRadius)
    local myId = mq.TLO.Me.ID()
    local myX = mq.TLO.Me.X() or 0
    local myY = mq.TLO.Me.Y() or 0

    local bestId = nil
    local bestDist = math.huge

    local groupCount = mq.TLO.Group.Members() or 0
    for i = 1, groupCount do
        local member = mq.TLO.Group.Member(i)
        if member and member() and member.ID() ~= myId then
            local memberId = member.ID()
            local memberX = member.X() or 0
            local memberY = member.Y() or 0

            -- Check if this groupmate has no hostiles near them
            local hostileCount = countHostilesNear(memberX, memberY, safeRadius)
            if hostileCount == 0 then
                -- Calculate distance to me
                local dist = math.sqrt((myX - memberX)^2 + (myY - memberY)^2)
                if dist < bestDist then
                    bestDist = dist
                    bestId = memberId
                end
            end
        end
    end

    return bestId
end
```

**Step 2: Add function to calculate kite position**

```lua
--- Calculate a position X units away from a mob
-- @param mobId number Mob spawn ID
-- @param distance number Distance to move away
-- @return number, number New X, Y coordinates
local function calculateKitePosition(mobId, distance)
    local mob = mq.TLO.Spawn(mobId)
    if not mob or not mob() then
        return mq.TLO.Me.X(), mq.TLO.Me.Y()
    end

    local myX = mq.TLO.Me.X() or 0
    local myY = mq.TLO.Me.Y() or 0
    local mobX = mob.X() or 0
    local mobY = mob.Y() or 0

    -- Calculate direction away from mob
    local dx = myX - mobX
    local dy = myY - mobY
    local len = math.sqrt(dx^2 + dy^2)

    if len < 1 then
        -- Too close, pick a random direction
        local angle = math.random() * 2 * math.pi
        dx = math.cos(angle)
        dy = math.sin(angle)
        len = 1
    end

    -- Normalize and extend
    local newX = myX + (dx / len) * distance
    local newY = myY + (dy / len) * distance

    return newX, newY
end
```

**Step 3: Commit**

```bash
git add automation/caster_assist.lua
git commit -m "feat: add safe groupmate finding and kite position calculation"
```

---

### Task 5: Implement Escape State Machine

**Files:**
- Modify: `automation/caster_assist.lua`

**Step 1: Implement tickEscape function**

Replace the placeholder:

```lua
--- Tick the escape state machine
-- @param settings table Settings
function M.tickEscape(settings)
    local state = M.escapeState
    local safeRadius = settings and settings.CasterSafeZoneRadius or 30
    local escapeRange = settings and settings.CasterEscapeRange or 30

    -- Timeout after 10 seconds
    if (os.clock() - state.startTime) > 10 then
        M.escapeState.phase = 'idle'
        mq.cmd('/squelch /nav stop')
        return
    end

    -- Check if rooted mob is dead or no longer a threat
    if state.rootedMobId then
        local mob = mq.TLO.Spawn(state.rootedMobId)
        if not mob or not mob() or (mob.Dead and mob.Dead()) then
            -- Threat gone, stop escaping
            M.escapeState.phase = 'idle'
            mq.cmd('/squelch /nav stop')
            return
        end

        -- Check if we're now out of range
        local dist = mob.Distance() or 0
        if dist > escapeRange then
            -- Safe now
            M.escapeState.phase = 'idle'
            mq.cmd('/squelch /nav stop')
            return
        end
    end

    -- State machine
    if state.phase == 'finding_safe' then
        -- Try to find a safe groupmate
        local safeId = findSafeGroupmate(safeRadius)
        if safeId then
            state.targetGroupmateId = safeId
            state.phase = 'navigating'
            mq.cmdf('/nav id %d', safeId)
        else
            -- No safe groupmate, kite away from mob
            local kiteX, kiteY = calculateKitePosition(state.rootedMobId, escapeRange)
            state.kiteDirection = { x = kiteX, y = kiteY }
            state.phase = 'kiting'
            mq.cmdf('/nav loc %f %f', kiteY, kiteX)  -- Note: nav uses y, x order
        end

    elseif state.phase == 'navigating' then
        -- Check if nav is complete
        local navActive = mq.TLO.Navigation and mq.TLO.Navigation.Active and mq.TLO.Navigation.Active()
        if not navActive then
            -- Arrived at safe groupmate
            M.escapeState.phase = 'idle'
        end

    elseif state.phase == 'kiting' then
        -- Check if nav is complete
        local navActive = mq.TLO.Navigation and mq.TLO.Navigation.Active and mq.TLO.Navigation.Active()
        if not navActive then
            -- Arrived at kite position
            M.escapeState.phase = 'idle'
        end
    end
end
```

**Step 2: Verify escape logic**

Manual test:
1. Get a rooted mob to target you
2. Verify caster runs to safe groupmate or kites away
3. Verify escape stops when mob dies or you're out of range

**Step 3: Commit**

```bash
git add automation/caster_assist.lua
git commit -m "feat: implement escape state machine for caster assist"
```

---

### Task 6: Wire Caster Assist into Assist Module

**Files:**
- Modify: `automation/assist.lua`

**Step 1: Add CasterAssist import**

Add at top after other requires:

```lua
local CasterAssist = require('automation.caster_assist')
```

**Step 2: Initialize CasterAssist in M.init**

Add in M.init function:

```lua
    CasterAssist.init(opts)
```

**Step 3: Route to CasterAssist in M.tick**

Modify M.tick to check class type before delegating:

```lua
function M.tick(settings)
    settings = settings or (_Core and _Core.Settings) or M.settings
    if not M.enabled then return end

    -- Route pure casters to CasterAssist
    if CasterAssist.isPureCaster() then
        CasterAssist.setEnabled(true)
        CasterAssist.tick(settings)
        return
    end

    -- Hybrid and pure melee use existing logic
    local combatMode = settings and settings.CombatMode or 'off'

    if combatMode == 'assist' then
        local usedTankAssist = M.runTankBroadcastAssist(settings)
        if usedTankAssist then
            return
        end
    end

    if _CombatAssist and _CombatAssist.tick then
        _CombatAssist.tick()
    end
end
```

**Step 4: Update M.setEnabled to also set CasterAssist**

```lua
function M.setEnabled(val)
    M.enabled = val and true or false
    CasterAssist.setEnabled(val)
    -- ... rest of existing code
```

**Step 5: Verify routing works**

Manual test:
1. Log in as ENC/WIZ/etc - should use CasterAssist
2. Log in as WAR/PAL/etc - should use CombatAssist

**Step 6: Commit**

```bash
git add automation/assist.lua
git commit -m "feat: route pure casters to CasterAssist module"
```

---

## Phase 2: Spell Rotation Integration

### Task 7: Create Spell Rotation Module

**Files:**
- Create: `utils/spell_rotation.lua`

**Step 1: Create the module**

```lua
-- F:/lua/SideKick/utils/spell_rotation.lua
-- Spell Rotation - Spell selection and execution for combat rotation

local mq = require('mq')

local M = {}

-- Rotation state
M.state = {
    currentSpell = nil,
    retryCount = 0,
    lastTargetId = 0,
    lastTargetDeathTime = 0,
    resetPending = false,
}

-- Spell categories for layer assignment
M.CATEGORY_TO_LAYER = {
    cc = 'support',
    mez = 'support',
    debuff = 'support',
    slow = 'support',
    malo = 'support',
    tash = 'support',
    cripple = 'support',
    selfheal = 'support',
    groupheal = 'support',
    nuke = 'combat',
    dot = 'combat',
    burn = 'burn',
    buff = 'utility',
}

-- Resist types
M.RESIST_TYPES = {
    'Any', 'Magic', 'Fire', 'Cold', 'Poison', 'Disease', 'Chromatic',
}

-- Debuff categories (no reset delay)
M.DEBUFF_CATEGORIES = {
    debuff = true, slow = true, malo = true, tash = true, cripple = true,
    snare = true, root = true,
}

-- Lazy-load dependencies
local _SpellEngine = nil
local function getSpellEngine()
    if not _SpellEngine then
        local ok, se = pcall(require, 'utils.spell_engine')
        if ok then _SpellEngine = se end
    end
    return _SpellEngine
end

local _SpellEvents = nil
local function getSpellEvents()
    if not _SpellEvents then
        local ok, se = pcall(require, 'utils.spell_events')
        if ok then _SpellEvents = se end
    end
    return _SpellEvents
end

local _ImmuneDB = nil
local function getImmuneDB()
    if not _ImmuneDB then
        local ok, db = pcall(require, 'utils.immune_database')
        if ok then _ImmuneDB = db end
    end
    return _ImmuneDB
end

--- Get the layer for a spell based on its category
-- @param category string Spell category
-- @return string Layer name
function M.getLayerForCategory(category)
    if not category then return 'combat' end
    return M.CATEGORY_TO_LAYER[category:lower()] or 'combat'
end

--- Check if a category is a debuff (no reset delay)
-- @param category string Spell category
-- @return boolean
function M.isDebuffCategory(category)
    if not category then return false end
    return M.DEBUFF_CATEGORIES[category:lower()] == true
end

--- Check if spell matches preferred resist type
-- @param spell userdata MQ Spell object
-- @param preferredType string Preferred resist type
-- @return boolean
function M.matchesResistType(spell, preferredType)
    if not spell or not spell() then return false end
    if not preferredType or preferredType == 'Any' then return true end

    local resistType = spell.ResistType and spell.ResistType() or ''
    return resistType:lower() == preferredType:lower()
end

--- Handle target death - reset rotation or continue
-- @param settings table Settings
function M.onTargetDeath(settings)
    M.state.lastTargetDeathTime = os.clock()
    M.state.resetPending = true
    M.state.retryCount = 0
end

--- Check if rotation should reset for new target
-- @param settings table Settings
-- @return boolean True if should reset
function M.shouldResetRotation(settings)
    if not M.state.resetPending then return false end

    local resetWindow = settings and settings.RotationResetWindow or 2
    local elapsed = os.clock() - M.state.lastTargetDeathTime

    if elapsed <= resetWindow then
        -- Within window, check if we have a new target
        local targetId = mq.TLO.Target.ID() or 0
        if targetId > 0 and targetId ~= M.state.lastTargetId then
            M.state.lastTargetId = targetId
            M.state.resetPending = false
            return true
        end
    else
        -- Window expired, reset anyway
        M.state.resetPending = false
        return true
    end

    return false
end

--- Main tick - called after AA/disc rotation
-- @param opts table Options: spells, settings, targetId
function M.tick(opts)
    opts = opts or {}
    local settings = opts.settings or {}
    local spells = opts.spells or {}

    -- Check if spell rotation is enabled
    if not settings.SpellRotationEnabled then return end

    -- Get spell engine
    local SpellEngine = getSpellEngine()
    if not SpellEngine then return end

    -- Don't try to cast if spell engine is busy
    if SpellEngine.isBusy() then return end

    -- Check for rotation reset
    if M.shouldResetRotation(settings) then
        M.state.currentSpell = nil
        M.state.retryCount = 0
    end

    -- Find next spell to cast (placeholder - will implement in Task 8)
end

--- Initialize spell rotation
function M.init()
    M.state = {
        currentSpell = nil,
        retryCount = 0,
        lastTargetId = 0,
        lastTargetDeathTime = 0,
        resetPending = false,
    }
end

return M
```

**Step 2: Verify module loads**

Run: `/lua run sidekick`
Expected: No errors

**Step 3: Commit**

```bash
git add utils/spell_rotation.lua
git commit -m "feat: create spell rotation module skeleton"
```

---

### Task 8: Implement Spell Selection Logic

**Files:**
- Modify: `utils/spell_rotation.lua`

**Step 1: Add spell selection function**

```lua
--- Select the next spell to cast from available spells
-- @param spells table Array of spell definitions
-- @param settings table Settings
-- @param targetId number Current target ID
-- @return table|nil Selected spell definition
function M.selectNextSpell(spells, settings, targetId)
    local preferredResist = settings.PreferredResistType or 'Any'
    local ImmuneDB = getImmuneDB()

    -- Get target info for immune check
    local targetName = ''
    if targetId and targetId > 0 then
        local target = mq.TLO.Spawn(targetId)
        if target and target() then
            targetName = target.CleanName and target.CleanName() or ''
        end
    end

    for _, spellDef in ipairs(spells) do
        if type(spellDef) ~= 'table' then goto continue end

        local spellName = spellDef.spellName or spellDef.name
        if not spellName or spellName == '' then goto continue end

        -- Check if enabled
        local enabled = spellDef.settingKey and settings[spellDef.settingKey]
        if enabled == false then goto continue end

        -- Get spell info
        local spell = mq.TLO.Spell(spellName)
        if not spell or not spell() then goto continue end

        -- Check resist type filter for damage spells
        local category = spellDef.category or ''
        if category == 'nuke' or category == 'dot' then
            if not M.matchesResistType(spell, preferredResist) then
                goto continue
            end
        end

        -- Check immune database
        if ImmuneDB and settings.UseImmuneDatabase and targetName ~= '' then
            local immuneCategory = M.getImmuneCategoryForSpell(spellDef, spell)
            if ImmuneDB.isImmune(targetName, immuneCategory) then
                goto continue
            end
        end

        -- Check if spell is ready (in gem and not on cooldown)
        local gemSlot = mq.TLO.Me.Gem(spellName)
        if not gemSlot or not gemSlot() then goto continue end

        local ready = mq.TLO.Me.SpellReady(spellName)
        if not ready or not ready() then goto continue end

        -- This spell is available
        return spellDef

        ::continue::
    end

    return nil
end

--- Get the immune category for a spell (for database lookup)
-- @param spellDef table Spell definition
-- @param spell userdata MQ Spell object
-- @return string Immune category
function M.getImmuneCategoryForSpell(spellDef, spell)
    local category = spellDef.category or ''
    if category ~= '' then
        return category:lower()
    end

    -- Infer from resist type for damage spells
    if spell and spell() then
        local resistType = spell.ResistType and spell.ResistType() or ''
        if resistType ~= '' then
            return resistType:lower()
        end
    end

    return 'unknown'
end
```

**Step 2: Update M.tick to use selection**

Add at end of M.tick:

```lua
    -- Select next spell
    local targetId = mq.TLO.Target.ID() or 0
    local spellDef = M.selectNextSpell(spells, settings, targetId)
    if not spellDef then return end

    -- Cast the spell
    local spellName = spellDef.spellName or spellDef.name
    local success = SpellEngine.cast(spellName, targetId, {
        spellCategory = spellDef.category,
    })

    if success then
        M.state.currentSpell = spellDef
    end
```

**Step 3: Commit**

```bash
git add utils/spell_rotation.lua
git commit -m "feat: implement spell selection with resist type filtering"
```

---

### Task 9: Implement Retry Logic

**Files:**
- Modify: `utils/spell_rotation.lua`

**Step 1: Add result handling function**

```lua
--- Handle spell cast result
-- @param result number Result code from SpellEvents
-- @param settings table Settings
function M.handleCastResult(result, settings)
    local SpellEvents = getSpellEvents()
    if not SpellEvents then return end

    local resultName = SpellEvents.getResultName(result)

    -- Success - clear current spell
    if result == SpellEvents.RESULT.SUCCESS then
        M.state.currentSpell = nil
        M.state.retryCount = 0
        return
    end

    -- Immune - log to database and move on
    if result == SpellEvents.RESULT.IMMUNE then
        M.handleImmune()
        M.state.currentSpell = nil
        M.state.retryCount = 0
        return
    end

    -- Check retry settings
    local shouldRetry = false
    if result == SpellEvents.RESULT.FIZZLE and settings.RetryOnFizzle then
        shouldRetry = true
    elseif result == SpellEvents.RESULT.RESISTED and settings.RetryOnResist then
        shouldRetry = true
    elseif result == SpellEvents.RESULT.INTERRUPTED and settings.RetryOnInterrupt then
        shouldRetry = true
    end

    if shouldRetry then
        M.state.retryCount = M.state.retryCount + 1
        -- Keep currentSpell for retry
        if M.state.retryCount > 3 then
            -- Too many retries, move on
            M.state.currentSpell = nil
            M.state.retryCount = 0
        end
    else
        -- Don't retry, move on
        M.state.currentSpell = nil
        M.state.retryCount = 0
    end
end

--- Handle immune result - log to database
function M.handleImmune()
    local ImmuneDB = getImmuneDB()
    if not ImmuneDB then return end

    local targetId = mq.TLO.Target.ID() or 0
    if targetId <= 0 then return end

    local target = mq.TLO.Spawn(targetId)
    if not target or not target() then return end

    local targetName = target.CleanName and target.CleanName() or ''
    if targetName == '' then return end

    local spellDef = M.state.currentSpell
    if not spellDef then return end

    local spell = mq.TLO.Spell(spellDef.spellName or spellDef.name)
    local immuneCategory = M.getImmuneCategoryForSpell(spellDef, spell)

    ImmuneDB.addImmune(targetName, immuneCategory)
end
```

**Step 2: Register result callback in init**

Update M.init:

```lua
function M.init()
    M.state = {
        currentSpell = nil,
        retryCount = 0,
        lastTargetId = 0,
        lastTargetDeathTime = 0,
        resetPending = false,
    }

    -- Register for spell result callbacks
    local SpellEvents = getSpellEvents()
    if SpellEvents then
        SpellEvents.setResultCallback(function(result, extra)
            local Core = require('utils.core')
            local settings = Core and Core.Settings or {}
            M.handleCastResult(result, settings)
        end)
    end
end
```

**Step 3: Commit**

```bash
git add utils/spell_rotation.lua
git commit -m "feat: implement spell retry logic with result handling"
```

---

## Phase 3: Immune Database

### Task 10: Create Immune Database Module

**Files:**
- Create: `utils/immune_database.lua`

**Step 1: Create the module**

```lua
-- F:/lua/SideKick/utils/immune_database.lua
-- Immune Database - Persistent tracking of mob immunities per zone

local mq = require('mq')

local M = {}

-- Full database (all zones)
M.database = {}

-- Current zone's immunes (loaded into memory)
M.zoneImmunes = {}

-- Current zone name
M.currentZone = ''

-- Dirty flag for persistence
M.dirty = false

-- Database file path
local function getDbPath()
    return mq.configDir .. '/SideKick/immune_database.lua'
end

--- Load the full database from disk
function M.loadDatabase()
    local path = getDbPath()
    local file = io.open(path, 'r')
    if not file then
        M.database = {}
        return
    end

    local content = file:read('*all')
    file:close()

    if content and content ~= '' then
        local fn = loadstring('return ' .. content)
        if fn then
            local ok, data = pcall(fn)
            if ok and type(data) == 'table' then
                M.database = data
                return
            end
        end
    end

    M.database = {}
end

--- Save the full database to disk
function M.saveDatabase()
    if not M.dirty then return end

    -- Ensure directory exists
    local dir = mq.configDir .. '/SideKick'
    os.execute('mkdir "' .. dir .. '" 2>nul')

    local path = getDbPath()
    local file = io.open(path, 'w')
    if not file then return end

    -- Simple serialization
    local function serialize(tbl, indent)
        indent = indent or ''
        local lines = {}
        table.insert(lines, '{')
        for k, v in pairs(tbl) do
            local key = type(k) == 'string' and ('["' .. k .. '"]') or ('[' .. k .. ']')
            if type(v) == 'table' then
                table.insert(lines, indent .. '  ' .. key .. ' = ' .. serialize(v, indent .. '  ') .. ',')
            elseif type(v) == 'boolean' then
                table.insert(lines, indent .. '  ' .. key .. ' = ' .. tostring(v) .. ',')
            else
                table.insert(lines, indent .. '  ' .. key .. ' = "' .. tostring(v) .. '",')
            end
        end
        table.insert(lines, indent .. '}')
        return table.concat(lines, '\n')
    end

    file:write(serialize(M.database))
    file:close()
    M.dirty = false
end

--- Load current zone's immunes into memory
function M.loadZone()
    local zone = mq.TLO.Zone.ShortName() or ''
    if zone == M.currentZone then return end

    M.currentZone = zone
    M.zoneImmunes = M.database[zone] or {}
end

--- Check if a mob is immune to a category
-- @param mobName string Mob name
-- @param category string Immune category (slow, mez, fire, etc.)
-- @return boolean True if immune
function M.isImmune(mobName, category)
    if not mobName or mobName == '' then return false end
    if not category or category == '' then return false end

    local mobData = M.zoneImmunes[mobName]
    if not mobData then return false end

    return mobData[category:lower()] == true
end

--- Add an immune entry
-- @param mobName string Mob name
-- @param category string Immune category
function M.addImmune(mobName, category)
    if not mobName or mobName == '' then return end
    if not category or category == '' then return end

    local zone = M.currentZone
    if zone == '' then return end

    -- Ensure zone table exists
    if not M.database[zone] then
        M.database[zone] = {}
    end

    -- Ensure mob table exists
    if not M.database[zone][mobName] then
        M.database[zone][mobName] = {}
    end

    -- Add immune entry
    M.database[zone][mobName][category:lower()] = true

    -- Update memory cache
    M.zoneImmunes = M.database[zone]

    -- Mark dirty for save
    M.dirty = true
end

--- Initialize - load database and current zone
function M.init()
    M.loadDatabase()
    M.loadZone()
end

--- Shutdown - save database
function M.shutdown()
    M.saveDatabase()
end

return M
```

**Step 2: Verify module loads**

Run: `/lua run sidekick`
Expected: No errors

**Step 3: Commit**

```bash
git add utils/immune_database.lua
git commit -m "feat: create immune database with zone-based memory loading"
```

---

### Task 11: Add Immune Detection Events

**Files:**
- Modify: `utils/spell_events.lua`

**Step 1: Add more immune detection patterns**

Add in registerEvents() after existing immune events:

```lua
    -- ============================================
    -- ADDITIONAL IMMUNE PATTERNS (specific debuffs)
    -- ============================================
    mq.event('sk_immune_slow', "Your target is immune to changes in its attack speed#*#", function()
        setResult(M.RESULT.IMMUNE, { immuneType = 'slow' })
    end)

    mq.event('sk_immune_snare', "Your target is immune to changes in its run speed#*#", function()
        setResult(M.RESULT.IMMUNE, { immuneType = 'snare' })
    end)

    mq.event('sk_immune_root', "Your target cannot be rooted#*#", function()
        setResult(M.RESULT.IMMUNE, { immuneType = 'root' })
    end)

    mq.event('sk_immune_charm', "Your target cannot be charmed#*#", function()
        setResult(M.RESULT.IMMUNE, { immuneType = 'charm' })
    end)

    mq.event('sk_immune_stun', "Your target is immune to stun#*#", function()
        setResult(M.RESULT.IMMUNE, { immuneType = 'stun' })
    end)

    mq.event('sk_immune_fear', "Your target is immune to fear#*#", function()
        setResult(M.RESULT.IMMUNE, { immuneType = 'fear' })
    end)
```

**Step 2: Add unregister for new events**

Add in unregisterEvents():

```lua
    -- Additional immune events
    mq.unevent('sk_immune_slow')
    mq.unevent('sk_immune_snare')
    mq.unevent('sk_immune_root')
    mq.unevent('sk_immune_charm')
    mq.unevent('sk_immune_stun')
    mq.unevent('sk_immune_fear')
```

**Step 3: Commit**

```bash
git add utils/spell_events.lua
git commit -m "feat: add specific immune detection events for debuffs"
```

---

### Task 12: Wire Spell Rotation into Rotation Engine

**Files:**
- Modify: `utils/rotation_engine.lua`

**Step 1: Add SpellRotation import**

Add lazy-load function:

```lua
local _SpellRotation = nil
local function getSpellRotation()
    if not _SpellRotation then
        local ok, sr = pcall(require, 'utils.spell_rotation')
        if ok then _SpellRotation = sr end
    end
    return _SpellRotation
end
```

**Step 2: Add spell rotation tick at end of M.tick**

Add at the end of M.tick function, after the layer loop:

```lua
    -- Run spell rotation after AA/disc rotation
    local SpellRotation = getSpellRotation()
    if SpellRotation then
        SpellRotation.tick({
            spells = opts.spells or {},
            settings = settings,
        })
    end
```

**Step 3: Commit**

```bash
git add utils/rotation_engine.lua
git commit -m "feat: wire spell rotation into rotation engine"
```

---

### Task 13: Wire Immune Database Lifecycle

**Files:**
- Modify: `SideKick.lua`

**Step 1: Add ImmuneDB import**

Add near top with other requires:

```lua
local ImmuneDB = require('utils.immune_database')
```

**Step 2: Initialize on load**

Add in initialization section:

```lua
ImmuneDB.init()
```

**Step 3: Add zone change detection**

Add in main loop, check zone change:

```lua
    -- Check for zone change (immune database)
    ImmuneDB.loadZone()
```

**Step 4: Save on shutdown**

Add in shutdown/cleanup section:

```lua
ImmuneDB.shutdown()
```

**Step 5: Commit**

```bash
git add SideKick.lua
git commit -m "feat: wire immune database lifecycle into main script"
```

---

### Task 14: Add Settings UI for Caster Options

**Files:**
- Modify: `ui/settings.lua`

**Step 1: Add caster assist section**

Find the Combat settings section and add:

```lua
    -- Caster Assist Settings
    if ImGui.CollapsingHeader('Caster Assist') then
        local changed

        changed, settings.CasterUseStick = ImGui.Checkbox('Use Stick (melee mode)', settings.CasterUseStick or false)
        if changed then Core.set('CasterUseStick', settings.CasterUseStick) end

        changed, settings.CasterEscapeRange = ImGui.SliderInt('Escape Range', settings.CasterEscapeRange or 30, 10, 100)
        if changed then Core.set('CasterEscapeRange', settings.CasterEscapeRange) end

        changed, settings.CasterSafeZoneRadius = ImGui.SliderInt('Safe Zone Radius', settings.CasterSafeZoneRadius or 30, 10, 100)
        if changed then Core.set('CasterSafeZoneRadius', settings.CasterSafeZoneRadius) end

        -- Resist type dropdown
        local resistTypes = { 'Any', 'Magic', 'Fire', 'Cold', 'Poison', 'Disease', 'Chromatic' }
        local currentResist = settings.PreferredResistType or 'Any'
        local currentIdx = 1
        for i, rt in ipairs(resistTypes) do
            if rt == currentResist then currentIdx = i break end
        end

        changed, currentIdx = ImGui.Combo('Preferred Resist', currentIdx, resistTypes)
        if changed then
            settings.PreferredResistType = resistTypes[currentIdx]
            Core.set('PreferredResistType', resistTypes[currentIdx])
        end
    end
```

**Step 2: Add spell rotation section**

```lua
    -- Spell Rotation Settings
    if ImGui.CollapsingHeader('Spell Rotation') then
        local changed

        changed, settings.SpellRotationEnabled = ImGui.Checkbox('Enable Spell Rotation', settings.SpellRotationEnabled or false)
        if changed then Core.set('SpellRotationEnabled', settings.SpellRotationEnabled) end

        changed, settings.RotationResetWindow = ImGui.SliderInt('Reset Window (sec)', settings.RotationResetWindow or 2, 0, 10)
        if changed then Core.set('RotationResetWindow', settings.RotationResetWindow) end

        ImGui.Separator()
        ImGui.Text('Retry Settings')

        changed, settings.RetryOnFizzle = ImGui.Checkbox('Retry on Fizzle', settings.RetryOnFizzle ~= false)
        if changed then Core.set('RetryOnFizzle', settings.RetryOnFizzle) end

        changed, settings.RetryOnResist = ImGui.Checkbox('Retry on Resist', settings.RetryOnResist ~= false)
        if changed then Core.set('RetryOnResist', settings.RetryOnResist) end

        changed, settings.RetryOnInterrupt = ImGui.Checkbox('Retry on Interrupt', settings.RetryOnInterrupt ~= false)
        if changed then Core.set('RetryOnInterrupt', settings.RetryOnInterrupt) end

        ImGui.Separator()
        changed, settings.UseImmuneDatabase = ImGui.Checkbox('Use Immune Database', settings.UseImmuneDatabase ~= false)
        if changed then Core.set('UseImmuneDatabase', settings.UseImmuneDatabase) end
    end
```

**Step 3: Commit**

```bash
git add ui/settings.lua
git commit -m "feat: add caster assist and spell rotation settings UI"
```

---

### Task 15: Final Integration Test

**Files:**
- None (manual testing)

**Step 1: Test caster assist**

1. Log in as ENC, WIZ, or MAG
2. Enable assist
3. Verify:
   - Caster stays in place (no stick) when `CasterUseStick` is false
   - Caster escapes when rooted mob targets you
   - Mez/heal casts complete before escape

**Step 2: Test spell rotation**

1. Enable `SpellRotationEnabled`
2. Set `PreferredResistType` to Magic
3. Engage mob
4. Verify:
   - Only magic nukes are cast (not fire/cold)
   - Retry on fizzle/resist
   - Debuffs cast immediately on new target

**Step 3: Test immune database**

1. Find a mob immune to slow
2. Cast slow, get immune message
3. Verify immune logged to database
4. Re-engage same mob type
5. Verify slow is skipped

**Step 4: Commit**

```bash
git add .
git commit -m "feat: complete caster assist and spell rotation integration"
```

---

## Summary

**Phase 1: Caster Assist Mode** (Tasks 1-6)
- Settings in registry
- Class detection (pure caster vs hybrid)
- Rooted mob escape logic
- Integration with assist module

**Phase 2: Spell Rotation** (Tasks 7-9)
- Spell selection with layer/category
- Resist type filtering
- Retry on fizzle/resist/interrupt
- Debuffs skip reset delay

**Phase 3: Immune Database** (Tasks 10-14)
- Zone-based immune tracking
- Memory loading on zone entry
- Specific immune event detection
- Settings UI

**Total: 15 Tasks**
