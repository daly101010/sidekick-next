# Healing Intelligence Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Port DeficitHealer's intelligent healing logic to SideKick, replacing HP-percentage thresholds with deficit-based heal selection, learned heal amounts, spell ducking, and multi-healer coordination.

**Architecture:** New `healing/` subdirectory as self-contained subsystem. Uses incoming heal tracking (not claims) for coordination. Integrates with existing SpellEngine and ActorsCoordinator. CLR-only initially with abstraction for future classes.

**Tech Stack:** Lua, MacroQuest TLOs, ImGui, Actors messaging

**Reference:** See `docs/plans/2026-01-18-healing-intelligence-design.md` for full design details.

---

## Phase 1: Foundation (Config, Persistence, Core Data Structures)

### Task 1: Create healing directory structure

**Files:**
- Create: `healing/init.lua`
- Create: `healing/config.lua`
- Create: `healing/persistence.lua`

**Step 1: Create the healing directory and init.lua stub**

```lua
-- healing/init.lua
local mq = require('mq')

local M = {}

local _initialized = false

function M.init()
    if _initialized then return end
    _initialized = true
    print('[Healing] Initialized')
end

function M.tick(settings)
    -- Stub: returns false (no priority healing active)
    return false
end

function M.tickActors()
    -- Stub: process actor messages
end

function M.shutdown()
    print('[Healing] Shutdown')
end

return M
```

**Step 2: Create config.lua with defaults**

```lua
-- healing/config.lua
local mq = require('mq')

local M = {
    _version = "1.0",

    -- Master enable toggle (single source of truth)
    enabled = true,

    -- Thresholds
    emergencyPct = 25,
    minHealPct = 10,
    groupHealMinCount = 3,
    nearDeadMobPct = 10,  -- Mobs below this HP% are excluded from fight phase avg

    -- Squishy handling
    squishyClasses = { WIZ = true, ENC = true, NEC = true, MAG = true },
    squishyCoveragePct = 70,
    nonSquishyMinHealPct = 15,

    -- Scoring weights
    scoringPresets = {
        emergency = { coverage = 4.0, manaEff = 0.1, overheal = -0.5 },
        normal = { coverage = 2.0, manaEff = 1.0, overheal = -1.5 },
        lowPressure = { coverage = 1.0, manaEff = 2.0, overheal = -2.0 },
    },

    -- Ducking
    duckEnabled = true,
    duckHpThreshold = 85,
    duckEmergencyThreshold = 70,
    duckHotThreshold = 92,
    duckBufferPct = 0.5,
    considerIncomingHot = true,

    -- HoT behavior
    hotEnabled = true,
    hotMinCoverageRatio = 0.3,
    hotUselessRatio = 0.1,
    hotMaxDeficitPct = 25,
    hotRefreshWindowPct = 0,
    hotTankOnly = true,

    -- Combat assessment
    survivalModeDpsPct = 5,
    survivalModeTankFullPct = 90,
    fightPhaseStartingPct = 70,
    fightPhaseEndingPct = 25,
    fightPhaseEndingTTK = 20,
    hotMinFightDurationPct = 50,

    -- DPS tracking (dual-source: HP delta + log parsing)
    damageWindowSec = 6,         -- Window for averaging damage (matches design)
    hpDpsWeight = 0.4,           -- Weight for HP delta DPS
    logDpsWeight = 0.6,          -- Weight for log-parsed DPS
    burstStddevMultiplier = 1.5, -- Burst = mean + (stddev * this) (matches design)

    -- Pet healing
    healPetsEnabled = false,     -- Whether to include pets in healing targets
    petHealMinPct = 40,          -- Minimum HP% to heal pets

    -- Learning
    learningWeight = 0.1,
    minSamplesForReliable = 10,

    -- Coordination
    incomingHealTimeoutSec = 10,
    broadcastEnabled = true,

    -- Logging (file logging enabled by default for troubleshooting)
    debugLogging = false,      -- Console debug output
    fileLogging = true,        -- Write detailed logs to file for review
    fileLogLevel = 'info',     -- 'debug', 'info', 'warn', 'error'
    logCategories = {          -- Granular control over what gets logged
        targetSelection = true,   -- Who needs healing and why
        spellSelection = true,    -- What spell was chosen and scoring details
        spellScoring = true,      -- Individual spell scores for comparison
        ducking = true,           -- Spell ducking decisions
        incomingHeals = true,     -- Incoming heal coordination
        combatState = true,       -- Fight phase, survival mode, DPS tracking
        hotDecisions = true,      -- Proactive HoT logic
        analytics = true,         -- Session statistics
    },

    -- Spells (user assigns)
    spells = {
        fast = {},
        small = {},
        medium = {},
        large = {},
        group = {},
        hot = {},
        hotLight = {},
        groupHot = {},
    },
}

local _charName = nil
local _serverName = nil

local function getCharInfo()
    if not _charName then
        _charName = mq.TLO.Me.CleanName() or 'Unknown'
    end
    if not _serverName then
        local server = mq.TLO.EverQuest.Server() or 'Unknown'
        _serverName = server:gsub(" ", "_")
    end
    return _charName, _serverName
end

local function getConfigPath()
    local char, server = getCharInfo()
    return string.format('%s/SideKick_Healing_%s_%s.lua', mq.configDir, server, char)
end

local function serializeValue(v, indent)
    indent = indent or ''
    local t = type(v)
    if t == 'string' then
        return string.format('%q', v)
    elseif t == 'number' or t == 'boolean' then
        return tostring(v)
    elseif t == 'table' then
        local parts = {}
        local isArray = #v > 0
        for k, val in pairs(v) do
            local key
            if type(k) == 'string' then
                if k:match('^[%a_][%w_]*$') then
                    key = k
                else
                    key = string.format('[%q]', k)
                end
            else
                key = string.format('[%s]', tostring(k))
            end
            table.insert(parts, string.format('%s    %s = %s,', indent, key, serializeValue(val, indent .. '    ')))
        end
        if #parts == 0 then
            return '{}'
        end
        return '{\n' .. table.concat(parts, '\n') .. '\n' .. indent .. '}'
    end
    return 'nil'
end

function M.load()
    local path = getConfigPath()
    local f = io.open(path, 'r')
    if not f then
        print('[Healing] No config found, using defaults')
        return
    end
    f:close()

    local ok, saved = pcall(dofile, path)
    if ok and type(saved) == 'table' then
        for k, v in pairs(saved) do
            if M[k] ~= nil and type(v) == type(M[k]) then
                if type(v) == 'table' then
                    -- Merge tables
                    for tk, tv in pairs(v) do
                        M[k][tk] = tv
                    end
                else
                    M[k] = v
                end
            end
        end
        print('[Healing] Config loaded from ' .. path)
    else
        print('[Healing] Failed to load config: ' .. tostring(saved))
    end
end

function M.save()
    local path = getConfigPath()
    local f = io.open(path, 'w')
    if not f then
        print('[Healing] Failed to save config to ' .. path)
        return false
    end

    f:write('return {\n')
    for k, v in pairs(M) do
        if type(v) ~= 'function' and not k:match('^_') then
            f:write(string.format('    %s = %s,\n', k, serializeValue(v, '    ')))
        end
    end
    f:write('}\n')
    f:close()
    print('[Healing] Config saved to ' .. path)
    return true
end

return M
```

**Step 3: Create persistence.lua for heal data**

```lua
-- healing/persistence.lua
local mq = require('mq')

local M = {}

local _charName = nil
local _serverName = nil

local function getCharInfo()
    if not _charName then
        _charName = mq.TLO.Me.CleanName() or 'Unknown'
    end
    if not _serverName then
        local server = mq.TLO.EverQuest.Server() or 'Unknown'
        _serverName = server:gsub(" ", "_")
    end
    return _charName, _serverName
end

local function getDataPath()
    local char, server = getCharInfo()
    return string.format('%s/SideKick_HealData_%s_%s.lua', mq.configDir, server, char)
end

local function serializeValue(v, indent)
    indent = indent or ''
    local t = type(v)
    if t == 'string' then
        return string.format('%q', v)
    elseif t == 'number' or t == 'boolean' then
        return tostring(v)
    elseif t == 'table' then
        local parts = {}
        for k, val in pairs(v) do
            local key
            if type(k) == 'string' then
                if k:match('^[%a_][%w_]*$') then
                    key = k
                else
                    key = string.format('[%q]', k)
                end
            else
                key = string.format('[%s]', tostring(k))
            end
            table.insert(parts, string.format('%s    %s = %s,', indent, key, serializeValue(val, indent .. '    ')))
        end
        if #parts == 0 then
            return '{}'
        end
        return '{\n' .. table.concat(parts, '\n') .. '\n' .. indent .. '}'
    end
    return 'nil'
end

function M.loadHealData()
    local path = getDataPath()
    local f = io.open(path, 'r')
    if not f then
        return {}
    end
    f:close()

    local ok, data = pcall(dofile, path)
    if ok and type(data) == 'table' then
        print('[Healing] Heal data loaded from ' .. path)
        return data
    end
    return {}
end

function M.saveHealData(data)
    if not data then return false end

    local path = getDataPath()
    local f = io.open(path, 'w')
    if not f then
        print('[Healing] Failed to save heal data to ' .. path)
        return false
    end

    f:write('return ')
    f:write(serializeValue(data))
    f:write('\n')
    f:close()
    print('[Healing] Heal data saved to ' .. path)
    return true
end

return M
```

**Step 4: Verify files load without error**

Run: `/lua run SideKick`
Then: `/lua stop SideKick`

Expected: No Lua errors in MQ console

**Step 5: Commit**

```bash
git add healing/
git commit -m "feat(healing): add foundation - init, config, persistence stubs"
```

---

### Task 2: Create heal_tracker.lua (learning system)

**Files:**
- Create: `healing/heal_tracker.lua`
- Modify: `healing/init.lua`

**Step 1: Create heal_tracker.lua**

```lua
-- healing/heal_tracker.lua
local mq = require('mq')
local Persistence = require('healing.persistence')

local M = {}

local Config = nil
local _healData = {}
local _dirty = false

function M.init(config)
    Config = config
    _healData = Persistence.loadHealData()
end

function M.shutdown()
    if _dirty then
        Persistence.saveHealData(_healData)
        _dirty = false
    end
end

function M.getData(spellName)
    return _healData[spellName]
end

function M.getExpected(spellName, mode)
    local data = _healData[spellName]
    if not data then
        -- Bootstrap from spell data
        local spell = mq.TLO.Spell(spellName)
        if spell and spell() then
            local base = tonumber(spell.Base(1)()) or 0
            if base > 0 then
                return base
            end
        end
        return 0
    end

    if mode == 'tick' and data.isHoT then
        return data.tickAvg or data.baseAvg or 0
    end

    return data.expected or data.baseAvg or 0
end

function M.isReliable(spellName)
    local data = _healData[spellName]
    if not data then return false end
    return data.reliable == true
end

function M.recordHeal(spellName, amount, isCrit, isHoT)
    amount = tonumber(amount) or 0
    if amount <= 0 then return end

    local data = _healData[spellName]
    if not data then
        data = {
            sampleCount = 0,
            baseAvg = 0,
            critCount = 0,
            critAvg = 0,
            critRate = 0,
            expected = 0,
            reliable = false,
            isHoT = isHoT or false,
            tickAvg = isHoT and 0 or nil,
            lastUpdated = os.time(),
        }
        _healData[spellName] = data
    end

    local weight = Config and Config.learningWeight or 0.1
    local minSamples = Config and Config.minSamplesForReliable or 10

    if isHoT then
        -- Track HoT tick separately
        data.tickAvg = data.tickAvg or 0
        data.tickAvg = data.tickAvg + (amount - data.tickAvg) * weight
        data.isHoT = true
    end

    if isCrit then
        data.critCount = data.critCount + 1
        if data.critAvg == 0 then
            data.critAvg = amount
        else
            data.critAvg = data.critAvg + (amount - data.critAvg) * weight
        end
    else
        if data.baseAvg == 0 then
            data.baseAvg = amount
        else
            data.baseAvg = data.baseAvg + (amount - data.baseAvg) * weight
        end
    end

    data.sampleCount = data.sampleCount + 1
    data.critRate = data.critCount / data.sampleCount

    -- Calculate expected value
    if data.critRate > 0 and data.critAvg > 0 then
        data.expected = (data.baseAvg * (1 - data.critRate)) + (data.critAvg * data.critRate)
    else
        data.expected = data.baseAvg
    end

    data.reliable = data.sampleCount >= minSamples
    data.lastUpdated = os.time()

    _dirty = true
end

-- Periodic save (call from main tick)
local _lastSaveCheck = 0
function M.tick()
    -- Use mq.gettime() for wall-clock accuracy
    local now = mq.gettime()
    if _dirty and (now - _lastSaveCheck) > 60 then
        _lastSaveCheck = now
        Persistence.saveHealData(_healData)
        _dirty = false
    end
end

return M
```

**Step 2: Update init.lua to use heal_tracker**

```lua
-- healing/init.lua
local mq = require('mq')

local Config = require('healing.config')
local HealTracker = require('healing.heal_tracker')

local M = {}

local _initialized = false

function M.init()
    if _initialized then return end
    _initialized = true

    Config.load()
    HealTracker.init(Config)

    print('[Healing] Initialized')
end

function M.tick(settings)
    HealTracker.tick()
    return false
end

function M.tickActors()
    -- Stub
end

function M.shutdown()
    HealTracker.shutdown()
    Config.save()
    print('[Healing] Shutdown')
end

-- Expose for testing
M.Config = Config
M.HealTracker = HealTracker

return M
```

**Step 3: Verify module loads**

Run: `/lua run SideKick`
Check: `[Healing] Initialized` appears in console
Then: `/lua stop SideKick`
Check: `[Healing] Shutdown` and `[Healing] Heal data saved` appear

**Step 4: Commit**

```bash
git add healing/heal_tracker.lua healing/init.lua
git commit -m "feat(healing): add heal_tracker learning system"
```

---

### Task 3: Create target_monitor.lua

**Files:**
- Create: `healing/target_monitor.lua`
- Modify: `healing/init.lua`

**Step 1: Create target_monitor.lua**

```lua
-- healing/target_monitor.lua
local mq = require('mq')

local M = {}

local Config = nil

-- Target data cache
local _targets = {}
local _lastFullScan = 0
local _lastDpsCalc = 0

-- Rolling damage window
local DAMAGE_WINDOW_SEC = 6
local DPS_CALC_INTERVAL = 0.5

function M.init(config)
    Config = config
    _targets = {}
end

function M.getTarget(spawnId)
    return _targets[spawnId]
end

function M.getAllTargets()
    return _targets
end

local function isSquishy(classShort)
    if not Config or not Config.squishyClasses then return false end
    return Config.squishyClasses[classShort] == true
end

local function getRole(spawn)
    if not spawn or not spawn() then return 'dps' end

    -- Check if it's a pet
    local spawnType = spawn.Type and spawn.Type() or ''
    if spawnType:lower() == 'pet' then
        return 'pet'
    end

    local classShort = spawn.Class and spawn.Class.ShortName and spawn.Class.ShortName() or ''
    classShort = classShort:upper()

    -- Tank classes
    if classShort == 'WAR' or classShort == 'PAL' or classShort == 'SHD' then
        return 'tank'
    end

    -- Healer classes
    if classShort == 'CLR' or classShort == 'DRU' or classShort == 'SHM' then
        return 'healer'
    end

    return 'dps'
end

local function updateTargetData(spawnId, spawn, roleOverride)
    if not spawn or not spawn() then
        _targets[spawnId] = nil
        return nil
    end

    -- Use mq.gettime() for wall-clock accuracy (os.clock() can drift)
    local now = mq.gettime()
    local existing = _targets[spawnId] or {}

    local currentHP = tonumber(spawn.CurrentHPs()) or 0
    local maxHP = tonumber(spawn.MaxHPs()) or 1
    local pctHP = tonumber(spawn.PctHPs()) or 100

    -- If we can't get actual HP values, estimate from percent
    if maxHP <= 1 and pctHP < 100 then
        maxHP = 100000  -- Default estimate
        currentHP = math.floor(maxHP * pctHP / 100)
    end

    local deficit = maxHP - currentHP
    local classShort = spawn.Class and spawn.Class.ShortName and spawn.Class.ShortName() or ''
    classShort = classShort:upper()

    -- Track damage for DPS calculation
    local recentDamage = existing.recentDamage or {}
    local prevHP = existing.currentHP or currentHP

    if currentHP < prevHP then
        local dmg = prevHP - currentHP
        table.insert(recentDamage, { time = now, amount = dmg })
    end

    -- Prune old damage entries
    local cutoff = now - DAMAGE_WINDOW_SEC
    local newDamage = {}
    for _, entry in ipairs(recentDamage) do
        if entry.time >= cutoff then
            table.insert(newDamage, entry)
        end
    end
    recentDamage = newDamage

    -- Calculate DPS from window
    local totalDamage = 0
    for _, entry in ipairs(recentDamage) do
        totalDamage = totalDamage + entry.amount
    end
    local windowDuration = math.max(1, #recentDamage > 0 and (now - recentDamage[1].time) or DAMAGE_WINDOW_SEC)
    local recentDps = totalDamage / windowDuration

    -- Burst detection
    local burstDetected = false
    if existing.recentDps and existing.recentDps > 0 then
        local spike = recentDps / existing.recentDps
        if spike > 2.0 then
            burstDetected = true
        end
    end

    local data = {
        id = spawnId,
        name = spawn.CleanName() or spawn.Name() or 'Unknown',
        class = classShort,
        role = roleOverride or getRole(spawn),
        isSquishy = isSquishy(classShort),

        currentHP = currentHP,
        maxHP = maxHP,
        pctHP = pctHP,
        deficit = deficit,

        recentDamage = recentDamage,
        recentDps = recentDps,
        burstDetected = burstDetected,

        -- Placeholders for incoming heal tracking
        incomingTotal = existing.incomingTotal or 0,
        effectiveDeficit = deficit - (existing.incomingTotal or 0),

        activeHoTs = existing.activeHoTs or {},
        incomingHoTRemaining = existing.incomingHoTRemaining or 0,

        lastUpdate = now,
    }

    _targets[spawnId] = data
    return data
end

function M.tick()
    -- Use mq.gettime() for wall-clock accuracy (os.clock() can drift)
    local now = mq.gettime()

    -- Full scan every 100ms
    if (now - _lastFullScan) < 0.1 then return end
    _lastFullScan = now

    local me = mq.TLO.Me
    if not me or not me() then return end

    -- Track self
    updateTargetData(me.ID(), me)

    -- Track group members
    local groupCount = tonumber(mq.TLO.Group.Members()) or 0
    for i = 1, groupCount do
        local member = mq.TLO.Group.Member(i)
        if member and member() and member.ID() then
            local spawn = member
            if member.Spawn then
                spawn = member.Spawn()
            end
            if spawn and spawn() then
                updateTargetData(spawn.ID(), spawn)
            end
        end
    end

    -- Track group pets if enabled (scope: group + pets only, not XTarget/raid)
    if Config and Config.healPetsEnabled then
        local petMinPct = Config.petHealMinPct or 40
        -- Check my pet
        local myPet = mq.TLO.Me.Pet
        if myPet and myPet() and myPet.ID() > 0 then
            local pctHP = tonumber(myPet.PctHPs()) or 100
            if pctHP < petMinPct then
                updateTargetData(myPet.ID(), myPet, 'pet')
            end
        end
        -- Check group member pets
        local groupSize = tonumber(mq.TLO.Group.Members()) or 0
        for i = 1, groupSize do
            local member = mq.TLO.Group.Member(i)
            if member and member() then
                local pet = member.Pet
                if pet and pet() and pet.ID() > 0 then
                    local pctHP = tonumber(pet.PctHPs()) or 100
                    if pctHP < petMinPct then
                        updateTargetData(pet.ID(), pet, 'pet')
                    end
                end
            end
        end
    end

    -- Prune stale targets (not seen in 5 seconds)
    local staleThreshold = now - 5
    for id, data in pairs(_targets) do
        if data.lastUpdate < staleThreshold then
            _targets[id] = nil
        end
    end
end

function M.getPriority(target)
    if not target then return 99 end

    local emergencyPct = Config and Config.emergencyPct or 25

    if target.pctHP < emergencyPct then return 1 end  -- Emergency
    if target.role == 'tank' then return 2 end
    if target.role == 'healer' then return 3 end
    if target.isSquishy then return 4 end
    if target.role == 'pet' then return 6 end  -- Pets always lower than players
    return 5  -- Non-squishy DPS
end

function M.getInjuredTargets(maxPctHP)
    maxPctHP = maxPctHP or 100
    local injured = {}
    for _, target in pairs(_targets) do
        if target.pctHP < maxPctHP and target.deficit > 0 then
            table.insert(injured, target)
        end
    end
    -- Sort by priority then by HP%
    table.sort(injured, function(a, b)
        local pa, pb = M.getPriority(a), M.getPriority(b)
        if pa ~= pb then return pa < pb end
        return a.pctHP < b.pctHP
    end)
    return injured
end

function M.updateIncoming(targetId, incomingTotal)
    local target = _targets[targetId]
    if target then
        target.incomingTotal = incomingTotal or 0
        target.effectiveDeficit = target.deficit - target.incomingTotal
    end
end

return M
```

**Step 2: Update init.lua to use target_monitor**

```lua
-- healing/init.lua
local mq = require('mq')

local Config = require('healing.config')
local HealTracker = require('healing.heal_tracker')
local TargetMonitor = require('healing.target_monitor')

local M = {}

local _initialized = false

function M.init()
    if _initialized then return end
    _initialized = true

    Config.load()
    HealTracker.init(Config)
    TargetMonitor.init(Config)

    print('[Healing] Initialized')
end

function M.tick(settings)
    TargetMonitor.tick()
    HealTracker.tick()
    return false
end

function M.tickActors()
    -- Stub
end

function M.shutdown()
    HealTracker.shutdown()
    Config.save()
    print('[Healing] Shutdown')
end

-- Expose for testing
M.Config = Config
M.HealTracker = HealTracker
M.TargetMonitor = TargetMonitor

return M
```

**Step 3: Verify target tracking works**

Run: `/lua run SideKick`
Wait 5 seconds in game with a group
Then: Check that no errors appear

**Step 4: Commit**

```bash
git add healing/target_monitor.lua healing/init.lua
git commit -m "feat(healing): add target_monitor with HP/DPS tracking"
```

---

### Task 3b: Add damage_parser.lua for chat log DPS tracking

**Files:**
- Create: `healing/damage_parser.lua`
- Modify: `healing/target_monitor.lua`

**Purpose:** The design specifies dual-source DPS tracking (HP delta + chat log parsing). This task adds chat log parsing for more accurate damage detection and statistical burst detection.

**Step 1: Create damage_parser.lua**

```lua
-- healing/damage_parser.lua
local mq = require('mq')

local M = {}

local Config = nil
local _handlers = {}
local _damageWindow = {}  -- [targetId] = { {time, amount, source}, ... }
local WINDOW_DURATION = 6  -- seconds (default, overridden by Config.damageWindowSec)

-- Statistics for burst detection
local _dpsHistory = {}  -- [targetId] = { dps1, dps2, ... }
local MAX_HISTORY = 20

function M.init(config)
    Config = config
    -- Use config window duration if available
    if Config and Config.damageWindowSec then
        WINDOW_DURATION = Config.damageWindowSec
    end
    M.registerEvents()
end

function M.registerEvents()
    -- Melee damage TO group members (mob hits player)
    mq.event('DmgMelee', '#1# hits #2# for #3# points of damage.', function(_, attacker, target, amount)
        M.recordDamage(target, tonumber(amount) or 0, attacker, 'melee')
    end)

    -- Critical melee (need to extract target from context)
    mq.event('DmgMeleeCrit', '#1# scores a critical hit! (#2#)', function(_, attacker, amount)
        -- Critical doesn't specify target, would need context tracking
    end)

    -- Spell damage TO group members
    mq.event('DmgSpell', '#1# hit #2# for #3# points of #4# damage by #5#.', function(_, caster, target, amount, dmgType, spell)
        M.recordDamage(target, tonumber(amount) or 0, caster, 'spell')
    end)

    -- DoT damage TO group members
    mq.event('DmgDot', '#1# has taken #2# damage from #3# by #4#.', function(_, target, amount, spell, caster)
        M.recordDamage(target, tonumber(amount) or 0, caster, 'dot')
    end)

    -- DS damage (on self when mob hits you)
    mq.event('DmgDs', '#1# is burned by YOUR #2# for #3# points of damage.', function(_, mob, spell, amount)
        -- DS damage is on mob, not relevant for healing
    end)
end

function M.recordDamage(targetName, amount, source, dmgType)
    if amount <= 0 then return end

    -- Find target ID by name
    local targetId = M.findTargetIdByName(targetName)
    if not targetId then return end

    local now = mq.gettime()

    _damageWindow[targetId] = _damageWindow[targetId] or {}
    table.insert(_damageWindow[targetId], {
        time = now,
        amount = amount,
        source = source,
        dmgType = dmgType,
    })
end

function M.findTargetIdByName(name)
    if not name or name == '' then return nil end

    -- Check self
    local me = mq.TLO.Me
    if me and me() and me.CleanName() == name then
        return me.ID()
    end

    -- Check group members
    local groupCount = tonumber(mq.TLO.Group.Members()) or 0
    for i = 1, groupCount do
        local member = mq.TLO.Group.Member(i)
        if member and member() then
            local spawn = member.Spawn and member.Spawn() or member
            if spawn and spawn() and spawn.CleanName() == name then
                return spawn.ID()
            end
        end
    end

    return nil
end

function M.getLogDps(targetId)
    local entries = _damageWindow[targetId]
    if not entries or #entries == 0 then return 0 end

    local now = mq.gettime()
    local cutoff = now - WINDOW_DURATION

    -- Sum damage in window
    local total = 0
    local count = 0
    local oldest = now

    for i = #entries, 1, -1 do
        local entry = entries[i]
        if entry.time >= cutoff then
            total = total + entry.amount
            count = count + 1
            if entry.time < oldest then
                oldest = entry.time
            end
        end
    end

    if count == 0 then return 0 end

    local duration = math.max(1, now - oldest)
    return total / duration
end

function M.checkBurst(targetId, currentDps)
    local history = _dpsHistory[targetId] or {}

    -- Need history for statistical analysis
    if #history < 5 then
        table.insert(history, currentDps)
        _dpsHistory[targetId] = history
        return false
    end

    -- Calculate mean and stddev
    local sum = 0
    for _, dps in ipairs(history) do
        sum = sum + dps
    end
    local mean = sum / #history

    local variance = 0
    for _, dps in ipairs(history) do
        variance = variance + (dps - mean) ^ 2
    end
    local stddev = math.sqrt(variance / #history)

    -- Burst threshold: mean + (stddev * multiplier) (multiplier from config)
    local multiplier = Config and Config.burstStddevMultiplier or 2.0
    local threshold = mean + (stddev * multiplier)

    -- Update history (rolling window)
    table.insert(history, currentDps)
    if #history > MAX_HISTORY then
        table.remove(history, 1)
    end
    _dpsHistory[targetId] = history

    return currentDps > threshold and stddev > 0
end

function M.tick()
    mq.doevents()

    -- Prune old entries
    local now = mq.gettime()
    local cutoff = now - WINDOW_DURATION

    for targetId, entries in pairs(_damageWindow) do
        local newEntries = {}
        for _, entry in ipairs(entries) do
            if entry.time >= cutoff then
                table.insert(newEntries, entry)
            end
        end
        if #newEntries > 0 then
            _damageWindow[targetId] = newEntries
        else
            _damageWindow[targetId] = nil
        end
    end
end

return M
```

**Step 2: Update target_monitor.lua to use damage_parser**

Add to target_monitor.lua near the top:
```lua
local DamageParser = nil
local function getDamageParser()
    if DamageParser == nil then
        local ok, dp = pcall(require, 'healing.damage_parser')
        if ok then
            DamageParser = dp
            dp.init(Config)  -- Pass Config for damageWindowSec, burstStddevMultiplier
        else
            DamageParser = false  -- Mark as unavailable
        end
    end
    return DamageParser or nil
end
```

Update the `updateTargetData` function to incorporate log DPS and burst detection:
```lua
-- After calculating recentDps from HP delta...
local logDps = 0
local dp = getDamageParser()
if dp then
    logDps = dp.getLogDps(spawnId)
end

-- Weighted combination (weights from config)
local hpDpsWeight = Config and Config.hpDpsWeight or 0.4
local logDpsWeight = Config and Config.logDpsWeight or 0.6
local combinedDps = (recentDps * hpDpsWeight) + (logDps * logDpsWeight)

-- Statistical burst detection
local burstDetected = false
if dp then
    burstDetected = dp.checkBurst(spawnId, combinedDps)
end

-- Update data structure
data.recentDps = combinedDps
data.hpDeltaDps = recentDps
data.logDps = logDps
data.burstDetected = burstDetected
```

**Step 3: Add DamageParser.tick() to init.lua**

In the tick function, add:
```lua
local dp = getDamageParser()
if dp then dp.tick() end
```

**Step 4: Commit**

```bash
git add healing/damage_parser.lua healing/target_monitor.lua healing/init.lua
git commit -m "feat(healing): add damage_parser for dual-source DPS tracking"
```

---

### Task 4: Create incoming_heals.lua (coordination)

**Files:**
- Create: `healing/incoming_heals.lua`
- Modify: `healing/init.lua`

**Step 1: Create incoming_heals.lua**

```lua
-- healing/incoming_heals.lua
local mq = require('mq')

local M = {}

local Config = nil
local TargetMonitor = nil

-- Lazy-load Analytics to avoid circular require
local Analytics = nil
local function getAnalytics()
    if Analytics == nil then
        local ok, a = pcall(require, 'healing.analytics')
        Analytics = ok and a or false
    end
    return Analytics or nil
end

-- Incoming heals from all healers: [targetId][healerId] = data
local _incoming = {}

-- My character ID
local _myId = nil

function M.init(config, targetMonitor)
    Config = config
    TargetMonitor = targetMonitor
    _incoming = {}
    _myId = mq.TLO.Me.ID()
end

function M.getMyId()
    if not _myId then
        _myId = mq.TLO.Me.ID()
    end
    return _myId
end

function M.add(healerId, targetId, data)
    if not targetId or targetId <= 0 then return end

    -- Use mq.gettime() for wall-clock accuracy (os.clock() can drift)
    local now = mq.gettime()
    _incoming[targetId] = _incoming[targetId] or {}
    _incoming[targetId][healerId] = {
        spellName = data.spellName,
        expectedAmount = tonumber(data.expectedAmount) or 0,
        castStartTime = tonumber(data.castStartTime) or now,
        castDuration = tonumber(data.castDuration) or 2.0,
        landsAt = tonumber(data.landsAt) or (now + 2.0),
        isHoT = data.isHoT or false,
        hotTickAmount = tonumber(data.hotTickAmount),
        hotExpiresAt = tonumber(data.hotExpiresAt),
    }

    M.updateTargetIncoming(targetId)
end

function M.remove(healerId, targetId)
    if not targetId or not _incoming[targetId] then return end

    _incoming[targetId][healerId] = nil

    -- Clean up empty target entries
    local hasAny = false
    for _ in pairs(_incoming[targetId]) do
        hasAny = true
        break
    end
    if not hasAny then
        _incoming[targetId] = nil
    end

    M.updateTargetIncoming(targetId)
end

function M.getForTarget(targetId)
    return _incoming[targetId] or {}
end

function M.sumForTarget(targetId)
    local total = 0
    local entries = _incoming[targetId]
    if not entries then return 0 end

    local now = mq.gettime()
    for healerId, data in pairs(entries) do
        -- Only count heals that haven't landed yet
        if data.landsAt > now then
            total = total + (data.expectedAmount or 0)
        end
    end

    return total
end

function M.updateTargetIncoming(targetId)
    if TargetMonitor then
        local total = M.sumForTarget(targetId)
        TargetMonitor.updateIncoming(targetId, total)
    end
end

function M.prune()
    local now = mq.gettime()
    local timeout = Config and Config.incomingHealTimeoutSec or 10

    for targetId, entries in pairs(_incoming) do
        for healerId, data in pairs(entries) do
            -- Remove if past expected land time + timeout
            if data.landsAt and (now - data.landsAt) > timeout then
                entries[healerId] = nil

                -- Track expired incoming heals in analytics
                local analytics = getAnalytics()
                if analytics and analytics.recordIncomingExpired then
                    analytics.recordIncomingExpired()
                end
            end
        end

        -- Clean up empty target entries
        local hasAny = false
        for _ in pairs(entries) do
            hasAny = true
            break
        end
        if not hasAny then
            _incoming[targetId] = nil
        end
    end
end

function M.tick()
    M.prune()
end

-- Called when we start casting a heal
function M.registerMyCast(targetId, spellName, expectedAmount, castDuration, isHoT, hotTickAmount, hotDuration)
    local now = mq.gettime()
    M.add(M.getMyId(), targetId, {
        spellName = spellName,
        expectedAmount = expectedAmount,
        castStartTime = now,
        castDuration = castDuration,
        landsAt = now + castDuration,
        isHoT = isHoT,
        hotTickAmount = hotTickAmount,
        hotExpiresAt = isHoT and (now + castDuration + (hotDuration or 0)) or nil,
    })
end

-- Called when our cast completes or is cancelled
function M.unregisterMyCast(targetId)
    M.remove(M.getMyId(), targetId)
end

return M
```

**Step 2: Update init.lua**

```lua
-- healing/init.lua
local mq = require('mq')

local Config = require('healing.config')
local HealTracker = require('healing.heal_tracker')
local TargetMonitor = require('healing.target_monitor')
local IncomingHeals = require('healing.incoming_heals')

local M = {}

local _initialized = false

function M.init()
    if _initialized then return end
    _initialized = true

    Config.load()
    HealTracker.init(Config)
    TargetMonitor.init(Config)
    IncomingHeals.init(Config, TargetMonitor)

    print('[Healing] Initialized')
end

function M.tick(settings)
    TargetMonitor.tick()
    IncomingHeals.tick()
    HealTracker.tick()
    return false
end

function M.tickActors()
    -- Stub - will process incoming heal messages from other healers
end

function M.shutdown()
    HealTracker.shutdown()
    Config.save()
    print('[Healing] Shutdown')
end

-- Expose for testing and external access
M.Config = Config
M.HealTracker = HealTracker
M.TargetMonitor = TargetMonitor
M.IncomingHeals = IncomingHeals

return M
```

**Step 3: Verify no errors**

Run: `/lua run SideKick`
Expected: `[Healing] Initialized` appears, no errors

**Step 4: Commit**

```bash
git add healing/incoming_heals.lua healing/init.lua
git commit -m "feat(healing): add incoming_heals coordination module"
```

---

## Phase 2: Combat Assessment & Heal Selection

### Task 5: Create combat_assessor.lua

**Files:**
- Create: `healing/combat_assessor.lua`
- Modify: `healing/init.lua`

**Step 1: Create combat_assessor.lua**

```lua
-- healing/combat_assessor.lua
local mq = require('mq')

local M = {}

local Config = nil
local TargetMonitor = nil

-- Lazy-load Logger
local Logger = nil
local function getLogger()
    if Logger == nil then
        local ok, l = pcall(require, 'healing.logger')
        Logger = ok and l or false
    end
    return Logger or nil
end

local _state = {
    fightPhase = 'none',
    inCombat = false,
    survivalMode = false,
    avgMobHP = 100,
    estimatedTTK = 999,
    activeMobCount = 0,
    totalIncomingDps = 0,
    tankDpsPct = 0,
}

local _lastUpdate = 0
local UPDATE_INTERVAL = 0.5
local _lastLoggedState = nil

function M.init(config, targetMonitor)
    Config = config
    TargetMonitor = targetMonitor
end

function M.getState()
    return _state
end

local function getXTargetData()
    local mobs = {}
    local me = mq.TLO.Me
    if not me or not me() then return mobs end

    local xtCount = tonumber(me.XTarget()) or 0
    for i = 1, xtCount do
        local xt = me.XTarget(i)
        if xt and xt() and xt.ID() and xt.ID() > 0 then
            local targetType = xt.TargetType and xt.TargetType() or ''
            -- Only count auto hater types
            if targetType:lower():find('auto hater') then
                local pctHP = tonumber(xt.PctHPs()) or 100
                local mezzed = xt.Mezzed and xt.Mezzed() or false
                table.insert(mobs, {
                    id = xt.ID(),
                    pctHP = pctHP,
                    mezzed = mezzed,
                })
            end
        end
    end
    return mobs
end

local function assessFightPhase(mobs)
    if #mobs == 0 then
        return 'none', 999
    end

    -- Calculate average HP of non-near-dead mobs
    local nearDeadPct = Config and Config.nearDeadMobPct or 10
    local totalHP = 0
    local count = 0

    for _, mob in ipairs(mobs) do
        if mob.pctHP > nearDeadPct then
            totalHP = totalHP + mob.pctHP
            count = count + 1
        end
    end

    local avgHP = count > 0 and (totalHP / count) or 0

    -- Estimate TTK (very rough)
    local estimatedTTK = avgHP * 0.5  -- Assume ~2% HP/sec average DPS

    local startingPct = Config and Config.fightPhaseStartingPct or 70
    local endingPct = Config and Config.fightPhaseEndingPct or 25
    local endingTTK = Config and Config.fightPhaseEndingTTK or 20

    if avgHP > startingPct then
        return 'starting', estimatedTTK
    elseif avgHP < endingPct or estimatedTTK < endingTTK then
        return 'ending', estimatedTTK
    else
        return 'mid', estimatedTTK
    end
end

local function checkSurvivalMode()
    if not TargetMonitor then return false end

    local targets = TargetMonitor.getAllTargets()
    local tank = nil

    -- Find the tank
    for _, target in pairs(targets) do
        if target.role == 'tank' then
            tank = target
            break
        end
    end

    if not tank then return false end

    local dpsPct = (tank.recentDps / math.max(1, tank.maxHP)) * 100
    local tankFullPct = Config and Config.survivalModeTankFullPct or 90
    local survivalDpsPct = Config and Config.survivalModeDpsPct or 5

    return dpsPct >= survivalDpsPct and tank.pctHP < tankFullPct
end

local function countActiveMobs(mobs)
    local count = 0
    for _, mob in ipairs(mobs) do
        if not mob.mezzed then
            count = count + 1
        end
    end
    return count
end

local function calcTotalIncomingDps()
    if not TargetMonitor then return 0 end

    local total = 0
    local targets = TargetMonitor.getAllTargets()
    for _, target in pairs(targets) do
        total = total + (target.recentDps or 0)
    end
    return total
end

function M.tick()
    -- Use mq.gettime() for wall-clock accuracy (os.clock() can drift)
    local now = mq.gettime()
    if (now - _lastUpdate) < UPDATE_INTERVAL then return end
    _lastUpdate = now

    local mobs = getXTargetData()

    _state.activeMobCount = countActiveMobs(mobs)
    _state.inCombat = _state.activeMobCount > 0
    _state.fightPhase, _state.estimatedTTK = assessFightPhase(mobs)
    _state.avgMobHP = 0

    if #mobs > 0 then
        local total = 0
        for _, mob in ipairs(mobs) do
            total = total + mob.pctHP
        end
        _state.avgMobHP = total / #mobs
    end

    _state.survivalMode = checkSurvivalMode()
    _state.totalIncomingDps = calcTotalIncomingDps()

    -- Calculate tank DPS %
    if TargetMonitor then
        local targets = TargetMonitor.getAllTargets()
        for _, target in pairs(targets) do
            if target.role == 'tank' and target.maxHP > 0 then
                _state.tankDpsPct = (target.recentDps / target.maxHP) * 100
                break
            end
        end
    end

    -- Log combat state changes (only when state changes to reduce log spam)
    local stateKey = string.format('%s_%s_%s_%d',
        _state.fightPhase, tostring(_state.inCombat), tostring(_state.survivalMode), _state.activeMobCount)
    if stateKey ~= _lastLoggedState then
        local log = getLogger()
        if log then
            log.logCombatState(_state)
        end
        _lastLoggedState = stateKey
    end
end

function M.getScoringWeights()
    if not Config or not Config.scoringPresets then
        return { coverage = 2.0, manaEff = 1.0, overheal = -1.5 }
    end

    if _state.survivalMode then
        return Config.scoringPresets.emergency
    end

    if _state.activeMobCount <= 1 then
        return Config.scoringPresets.lowPressure
    end

    return Config.scoringPresets.normal
end

return M
```

**Step 2: Update init.lua**

```lua
-- healing/init.lua
local mq = require('mq')

local Config = require('healing.config')
local HealTracker = require('healing.heal_tracker')
local TargetMonitor = require('healing.target_monitor')
local IncomingHeals = require('healing.incoming_heals')
local CombatAssessor = require('healing.combat_assessor')

local M = {}

local _initialized = false

function M.init()
    if _initialized then return end
    _initialized = true

    Config.load()
    HealTracker.init(Config)
    TargetMonitor.init(Config)
    IncomingHeals.init(Config, TargetMonitor)
    CombatAssessor.init(Config, TargetMonitor)

    print('[Healing] Initialized')
end

function M.tick(settings)
    TargetMonitor.tick()
    IncomingHeals.tick()
    CombatAssessor.tick()
    HealTracker.tick()
    return false
end

function M.tickActors()
    -- Stub
end

function M.shutdown()
    HealTracker.shutdown()
    Config.save()
    print('[Healing] Shutdown')
end

-- Expose modules
M.Config = Config
M.HealTracker = HealTracker
M.TargetMonitor = TargetMonitor
M.IncomingHeals = IncomingHeals
M.CombatAssessor = CombatAssessor

return M
```

**Step 3: Verify no errors**

Run: `/lua run SideKick`
Expected: No errors, `[Healing] Initialized` appears

**Step 4: Commit**

```bash
git add healing/combat_assessor.lua healing/init.lua
git commit -m "feat(healing): add combat_assessor for fight phase and survival mode"
```

---

### Task 6: Create heal_selector.lua (scoring system)

**Files:**
- Create: `healing/heal_selector.lua`
- Modify: `healing/init.lua`

**Step 1: Create heal_selector.lua**

```lua
-- healing/heal_selector.lua
local mq = require('mq')

local M = {}

local Config = nil
local HealTracker = nil
local TargetMonitor = nil
local IncomingHeals = nil
local CombatAssessor = nil

-- Lazy-load Logger to avoid circular require
local Logger = nil
local function getLogger()
    if Logger == nil then
        local ok, l = pcall(require, 'healing.logger')
        Logger = ok and l or false
    end
    return Logger or nil
end

-- Spell cache
local _spellCache = {}
local _lastSpellCacheUpdate = 0

function M.init(config, healTracker, targetMonitor, incomingHeals, combatAssessor)
    Config = config
    HealTracker = healTracker
    TargetMonitor = targetMonitor
    IncomingHeals = incomingHeals
    CombatAssessor = combatAssessor
end

local function getSpellInfo(spellName)
    if not spellName or spellName == '' then return nil end

    -- Use mq.gettime() for wall-clock accuracy
    local now = mq.gettime()
    local cached = _spellCache[spellName]
    if cached and (now - cached.cachedAt) < 60 then
        return cached
    end

    local spell = mq.TLO.Spell(spellName)
    if not spell or not spell() then return nil end

    local me = mq.TLO.Me
    local mySpell = me and me.Spell and me.Spell(spellName)

    local info = {
        name = spellName,
        id = spell.ID(),
        manaCost = tonumber(spell.Mana()) or 0,
        castTimeMs = mySpell and tonumber(mySpell.MyCastTime()) or tonumber(spell.CastTime()) or 0,
        recastMs = tonumber(spell.RecastTime()) or 0,
        isHoT = false,
        hotDuration = 0,
        hotTickInterval = 6,
        cachedAt = now,
    }

    -- Check if it's a HoT (has SPA 79 - HP regen)
    -- IMPORTANT: HasSPA(79) returns a function that must be called with ()
    if spell.HasSPA then
        local ok, v = pcall(function() return spell.HasSPA(79)() end)
        info.isHoT = ok and v == true
    end

    if info.isHoT and spell.Duration then
        local dur = spell.Duration
        if dur.TotalSeconds then
            info.hotDuration = tonumber(dur.TotalSeconds()) or 0
        end
    end

    _spellCache[spellName] = info
    return info
end

local function isSpellReady(spellName)
    local me = mq.TLO.Me
    if not me or not me() then return false end

    -- Check if memorized
    local gems = tonumber(me.NumGems()) or 13
    local found = false
    for i = 1, gems do
        local gem = me.Gem(i)
        if gem and gem() and gem.Name() == spellName then
            found = true
            -- Check gem timer
            local ready = me.GemTimer(i)
            if ready and ready() then
                local ms = tonumber(ready.TotalSeconds and ready.TotalSeconds() or ready()) or 0
                if ms > 0 then
                    return false  -- Still on cooldown
                end
            end
            break
        end
    end

    if not found then return false end

    -- Check mana
    local info = getSpellInfo(spellName)
    if info and info.manaCost > 0 then
        local myMana = tonumber(me.CurrentMana()) or 0
        if myMana < info.manaCost then
            return false
        end
    end

    return true
end

local function scoreHeal(spellName, target, weights)
    local info = getSpellInfo(spellName)
    if not info then return -999 end

    -- Get expected heal amount from learned data
    local expected = HealTracker and HealTracker.getExpected(spellName) or 0

    -- Fallback to spell base value (NOT mana cost - that makes no sense for heal scoring)
    if expected <= 0 then
        local spell = mq.TLO.Spell(spellName)
        if spell and spell() and spell.Base then
            expected = math.abs(tonumber(spell.Base(1)()) or 0)
        end
    end

    -- If we still have no data, we can't score this spell
    if expected <= 0 then return -999 end

    local effectiveDeficit = target.effectiveDeficit or target.deficit or 0
    if effectiveDeficit <= 0 then return -999 end

    -- Coverage: How much of deficit does this heal cover?
    local coverage = math.min(expected / effectiveDeficit, 1.5)

    -- Overheal: Penalty for healing beyond deficit
    local overheal = math.max(0, expected - effectiveDeficit) / expected

    -- Mana efficiency: HP per mana
    local manaEff = info.manaCost > 0 and (expected / info.manaCost) or 1
    -- Normalize mana efficiency to reasonable range
    manaEff = math.min(manaEff / 10, 2.0)

    local score = (coverage * weights.coverage)
               + (manaEff * weights.manaEff)
               + (overheal * weights.overheal)

    -- Bonus for reliable learned data
    if HealTracker and HealTracker.isReliable(spellName) then
        score = score + 0.1
    end

    return score, {
        expected = expected,
        coverage = coverage,
        overheal = overheal,
        manaEff = manaEff,
    }
end

function M.selectHeal(target, tier)
    if not Config or not Config.spells then return nil end

    local weights = CombatAssessor and CombatAssessor.getScoringWeights() or { coverage = 2.0, manaEff = 1.0, overheal = -1.5 }

    -- Determine which spell categories to consider based on tier
    local categories = {}
    if tier == 'emergency' then
        categories = { 'fast', 'small', 'medium', 'large' }
    elseif tier == 'big' then
        categories = { 'large', 'medium' }
    elseif tier == 'group' then
        categories = { 'group' }
    elseif tier == 'hot' then
        categories = { 'hot', 'hotLight' }
    elseif tier == 'groupHot' then
        categories = { 'groupHot' }
    else
        categories = { 'small', 'medium', 'large', 'fast' }
    end

    local bestSpell = nil
    local bestScore = -999
    local bestDetails = nil
    local allScores = {}  -- For logging

    for _, cat in ipairs(categories) do
        local spells = Config.spells[cat] or {}
        for _, spellName in ipairs(spells) do
            if isSpellReady(spellName) then
                local score, details = scoreHeal(spellName, target, weights)

                -- Log individual spell scoring (debug level)
                local log = getLogger()
                if log then
                    log.logSpellScoring(spellName, target, {
                        coverage = details and details.coverage or 0,
                        manaEff = details and details.manaEff or 0,
                        overheal = details and details.overheal or 0,
                        castPenalty = 0,
                        burstBonus = 0,
                        total = score,
                    })
                end

                -- Track for summary log
                local info = getSpellInfo(spellName)
                table.insert(allScores, {
                    name = spellName,
                    score = score,
                    expected = details and details.expected or 0,
                    mana = info and info.manaCost or 0,
                    castTime = info and info.castTime or 0,
                })

                if score > bestScore then
                    bestScore = score
                    bestSpell = spellName
                    bestDetails = details
                end
            end
        end
    end

    -- Sort by score for logging
    table.sort(allScores, function(a, b) return a.score > b.score end)

    -- Log spell selection summary
    local log = getLogger()
    if log then
        log.logSpellSelection(target, tier, allScores, bestSpell, bestScore)
    end

    return bestSpell, bestScore, bestDetails
end

function M.findHealTarget()
    if not TargetMonitor then return nil, nil end

    local emergencyPct = Config and Config.emergencyPct or 25
    local minHealPct = Config and Config.minHealPct or 10

    -- Get injured targets sorted by priority
    local injured = TargetMonitor.getInjuredTargets(100 - minHealPct)

    for _, target in ipairs(injured) do
        -- Skip if effective deficit is covered by incoming heals
        if target.effectiveDeficit <= 0 then
            goto continue
        end

        -- Determine tier
        local tier = 'main'
        if target.pctHP < emergencyPct then
            tier = 'emergency'
        elseif target.pctHP < 50 then
            tier = 'big'
        end

        -- Squishy handling
        if target.isSquishy then
            local squishyCoverage = Config and Config.squishyCoveragePct or 70
            -- Squishies get more aggressive healing
            if target.pctHP < (100 - squishyCoverage) then
                tier = 'big'
            end
        else
            -- Non-squishies need more deficit before healing
            local nonSquishyMin = Config and Config.nonSquishyMinHealPct or 15
            if (100 - target.pctHP) < nonSquishyMin then
                goto continue
            end
        end

        -- Log target selection
        local log = getLogger()
        if log then
            log.logTargetSelection(injured, target, string.format('tier=%s HP=%d%% EffDeficit=%d',
                tier, target.pctHP or 0, target.effectiveDeficit or 0))
        end

        return target, tier
        ::continue::
    end

    -- Log no target found
    local log = getLogger()
    if log and #injured > 0 then
        log.logTargetSelection(injured, nil, 'all candidates covered by incoming heals or below threshold')
    end

    return nil, nil
end

function M.checkGroupHeal()
    if not TargetMonitor or not Config then return false, nil end

    local groupPoint = Config.groupHealMinCount or 3
    local groupThreshold = 75  -- HP% to count as injured for group heal

    local injured = TargetMonitor.getInjuredTargets(groupThreshold)

    if #injured >= groupPoint then
        local spell = M.selectHeal({ effectiveDeficit = 50000, deficit = 50000 }, 'group')
        if spell then
            return true, spell
        end
    end

    return false, nil
end

return M
```

**Step 2: Update init.lua**

```lua
-- healing/init.lua
local mq = require('mq')

local Config = require('healing.config')
local HealTracker = require('healing.heal_tracker')
local TargetMonitor = require('healing.target_monitor')
local IncomingHeals = require('healing.incoming_heals')
local CombatAssessor = require('healing.combat_assessor')
local HealSelector = require('healing.heal_selector')

local M = {}

local _initialized = false

function M.init()
    if _initialized then return end
    _initialized = true

    Config.load()
    HealTracker.init(Config)
    TargetMonitor.init(Config)
    IncomingHeals.init(Config, TargetMonitor)
    CombatAssessor.init(Config, TargetMonitor)
    HealSelector.init(Config, HealTracker, TargetMonitor, IncomingHeals, CombatAssessor)

    print('[Healing] Initialized')
end

function M.tick(settings)
    TargetMonitor.tick()
    IncomingHeals.tick()
    CombatAssessor.tick()
    HealTracker.tick()
    return false
end

function M.tickActors()
    -- Stub
end

function M.shutdown()
    HealTracker.shutdown()
    Config.save()
    print('[Healing] Shutdown')
end

-- Expose modules
M.Config = Config
M.HealTracker = HealTracker
M.TargetMonitor = TargetMonitor
M.IncomingHeals = IncomingHeals
M.CombatAssessor = CombatAssessor
M.HealSelector = HealSelector

return M
```

**Step 3: Verify no errors**

Run: `/lua run SideKick`
Expected: `[Healing] Initialized` appears, no errors

**Step 4: Commit**

```bash
git add healing/heal_selector.lua healing/init.lua
git commit -m "feat(healing): add heal_selector with deficit-based scoring"
```

---

## Phase 3: Events, Ducking & Main Logic

### Task 7: Create spell events and ducking logic

**Files:**
- Create: `healing/spell_events.lua`
- Modify: `healing/init.lua`

**Step 1: Create spell_events.lua**

```lua
-- healing/spell_events.lua
local mq = require('mq')

local M = {}

local HealTracker = nil
local IncomingHeals = nil
local Analytics = nil

local _currentCast = nil
local _eventHandlers = {}

function M.init(healTracker, incomingHeals, analytics)
    HealTracker = healTracker
    IncomingHeals = incomingHeals
    Analytics = analytics

    M.registerEvents()
end

function M.registerEvents()
    -- Direct heals
    mq.event('HealLanded', 'You healed #1# for #2# (#3#) hit points by #4#.', function(_, target, amount, _, spell)
        M.onHealLanded(target, amount, spell, false, false)
    end)

    mq.event('HealLandedCrit', 'You healed #1# for #2# (#3#) hit points by #4#. (Critical)', function(_, target, amount, _, spell)
        M.onHealLanded(target, amount, spell, true, false)
    end)

    mq.event('HealLandedNoFull', 'You healed #1# for #2# hit points by #3#.', function(_, target, amount, spell)
        M.onHealLanded(target, amount, spell, false, false)
    end)

    mq.event('HealLandedNoFullCrit', 'You healed #1# for #2# hit points by #3#. (Critical)', function(_, target, amount, spell)
        M.onHealLanded(target, amount, spell, true, false)
    end)

    -- "You have healed" variants
    mq.event('HealLandedHave', 'You have healed #1# for #2# (#3#) hit points by #4#.', function(_, target, amount, _, spell)
        M.onHealLanded(target, amount, spell, false, false)
    end)

    mq.event('HealLandedHaveCrit', 'You have healed #1# for #2# (#3#) hit points by #4#. (Critical)', function(_, target, amount, _, spell)
        M.onHealLanded(target, amount, spell, true, false)
    end)

    mq.event('HealLandedHaveNoFull', 'You have healed #1# for #2# hit points by #3#.', function(_, target, amount, spell)
        M.onHealLanded(target, amount, spell, false, false)
    end)

    mq.event('HealLandedHaveNoFullCrit', 'You have healed #1# for #2# hit points by #3#. (Critical)', function(_, target, amount, spell)
        M.onHealLanded(target, amount, spell, true, false)
    end)

    -- HoT ticks
    mq.event('HotLanded', 'You healed #1# over time for #2# (#3#) hit points by #4#.', function(_, target, amount, _, spell)
        M.onHealLanded(target, amount, spell, false, true)
    end)

    mq.event('HotLandedCrit', 'You healed #1# over time for #2# (#3#) hit points by #4#. (Critical)', function(_, target, amount, _, spell)
        M.onHealLanded(target, amount, spell, true, true)
    end)

    mq.event('HotLandedNoFull', 'You healed #1# over time for #2# hit points by #3#.', function(_, target, amount, spell)
        M.onHealLanded(target, amount, spell, false, true)
    end)

    mq.event('HotLandedNoFullCrit', 'You healed #1# over time for #2# hit points by #3#. (Critical)', function(_, target, amount, spell)
        M.onHealLanded(target, amount, spell, true, true)
    end)

    -- Interrupts
    mq.event('SpellInterrupted', 'Your spell is interrupted.', function()
        M.onInterrupt('interrupted')
    end)

    mq.event('SpellFizzle', 'Your spell fizzles!', function()
        M.onInterrupt('fizzle')
    end)

    mq.event('SpellNotHold', 'Your target cannot be healed.', function()
        M.onInterrupt('invalid_target')
    end)
end

function M.onHealLanded(targetName, amount, spellName, isCrit, isHoT)
    amount = tonumber(amount) or 0
    if amount <= 0 then return end

    -- Record to heal tracker for learning
    if HealTracker then
        HealTracker.recordHeal(spellName, amount, isCrit, isHoT)
    end

    -- Clear our cast tracking if this was our spell
    if _currentCast and _currentCast.spellName == spellName then
        local targetId = _currentCast.targetId

        if IncomingHeals then
            IncomingHeals.unregisterMyCast(targetId)
        end

        -- Broadcast to other healers that heal landed (so they can clear their tracking)
        local initModule = require('healing.init')
        if initModule and initModule.broadcastLanded then
            initModule.broadcastLanded(targetId, spellName)
        end

        -- Record to analytics
        if Analytics and Analytics.recordHealComplete then
            local overhealed = 0  -- Would need target HP tracking to calculate
            Analytics.recordHealComplete(spellName, targetId, amount, overhealed, _currentCast.manaCost or 0)
        end

        _currentCast = nil
    end
end

function M.onInterrupt(reason)
    if not _currentCast then return end

    local targetId = _currentCast.targetId
    local spellName = _currentCast.spellName

    -- Clear incoming heal tracking
    if IncomingHeals then
        IncomingHeals.unregisterMyCast(targetId)
    end

    -- Broadcast to other healers that cast was cancelled
    local initModule = require('healing.init')
    if initModule and initModule.broadcastCancelled then
        initModule.broadcastCancelled(targetId, spellName, reason)
    end

    -- Record to analytics
    if Analytics and Analytics.recordInterrupt then
        Analytics.recordInterrupt(spellName, reason)
    end

    _currentCast = nil
end

function M.setCastInfo(info)
    _currentCast = info
end

function M.getCastInfo()
    return _currentCast
end

function M.isCasting()
    return _currentCast ~= nil
end

function M.tick()
    mq.doevents()
end

return M
```

**Step 2: Create ducking logic in init.lua (partial update)**

Add ducking check to init.lua - will fully integrate in next task.

**Step 3: Verify events register**

Run: `/lua run SideKick`
Expected: No errors on startup

**Step 4: Commit**

```bash
git add healing/spell_events.lua
git commit -m "feat(healing): add spell_events with heal/interrupt detection"
```

---

### Task 8: Create analytics.lua

**Files:**
- Create: `healing/analytics.lua`
- Modify: `healing/init.lua`

**Step 1: Create analytics.lua**

```lua
-- healing/analytics.lua
local mq = require('mq')

local M = {}

local _stats = {
    totalCasts = 0,
    completedCasts = 0,
    duckedCasts = 0,
    interruptedCasts = 0,

    totalHealed = 0,
    totalOverheal = 0,
    overHealPct = 0,

    totalManaSpent = 0,
    healPerMana = 0,

    duckSavingsEstimate = 0,

    incomingHealHonored = 0,
    incomingHealExpired = 0,

    bySpell = {},

    sessionStart = 0,
    lastUpdate = 0,
}

function M.init()
    _stats.sessionStart = os.time()
    _stats.lastUpdate = os.time()
end

function M.getStats()
    return _stats
end

function M.recordHealComplete(spellName, targetId, healed, overhealed, manaCost)
    healed = tonumber(healed) or 0
    overhealed = tonumber(overhealed) or 0
    manaCost = tonumber(manaCost) or 0

    _stats.totalCasts = _stats.totalCasts + 1
    _stats.completedCasts = _stats.completedCasts + 1
    _stats.totalHealed = _stats.totalHealed + healed
    _stats.totalOverheal = _stats.totalOverheal + overhealed
    _stats.totalManaSpent = _stats.totalManaSpent + manaCost

    -- Update rolling percentages
    if _stats.totalHealed > 0 then
        _stats.overHealPct = (_stats.totalOverheal / _stats.totalHealed) * 100
    end
    if _stats.totalManaSpent > 0 then
        _stats.healPerMana = _stats.totalHealed / _stats.totalManaSpent
    end

    -- Per-spell tracking
    _stats.bySpell[spellName] = _stats.bySpell[spellName] or {
        casts = 0,
        healed = 0,
        overhealed = 0,
        ducked = 0,
        manaSpent = 0,
    }
    local spell = _stats.bySpell[spellName]
    spell.casts = spell.casts + 1
    spell.healed = spell.healed + healed
    spell.overhealed = spell.overhealed + overhealed
    spell.manaSpent = spell.manaSpent + manaCost

    _stats.lastUpdate = os.time()
end

function M.recordDuck(spellName, manaCost)
    _stats.totalCasts = _stats.totalCasts + 1
    _stats.duckedCasts = _stats.duckedCasts + 1
    _stats.duckSavingsEstimate = _stats.duckSavingsEstimate + (tonumber(manaCost) or 0)

    _stats.bySpell[spellName] = _stats.bySpell[spellName] or {
        casts = 0,
        healed = 0,
        overhealed = 0,
        ducked = 0,
        manaSpent = 0,
    }
    _stats.bySpell[spellName].ducked = _stats.bySpell[spellName].ducked + 1

    _stats.lastUpdate = os.time()
end

function M.recordInterrupt(spellName, reason)
    _stats.totalCasts = _stats.totalCasts + 1
    _stats.interruptedCasts = _stats.interruptedCasts + 1
    _stats.lastUpdate = os.time()
end

function M.recordIncomingHonored()
    _stats.incomingHealHonored = _stats.incomingHealHonored + 1
end

function M.recordIncomingExpired()
    _stats.incomingHealExpired = _stats.incomingHealExpired + 1
end

function M.getSessionDuration()
    return os.time() - _stats.sessionStart
end

function M.getEfficiencyPct()
    if _stats.totalHealed <= 0 then return 100 end
    return 100 - _stats.overHealPct
end

function M.getSummary()
    local duration = M.getSessionDuration()
    local mins = math.floor(duration / 60)

    return string.format(
        'Session: %dm | Casts: %d | Ducked: %d (%.0f%%)\nEfficiency: %.1f%% | Overheal: %.1f%%\nHPM: %.1f | Mana Saved: ~%dk',
        mins,
        _stats.totalCasts,
        _stats.duckedCasts,
        _stats.totalCasts > 0 and (_stats.duckedCasts / _stats.totalCasts * 100) or 0,
        M.getEfficiencyPct(),
        _stats.overHealPct,
        _stats.healPerMana,
        math.floor(_stats.duckSavingsEstimate / 1000)
    )
end

return M
```

**Step 2: Update init.lua to use analytics**

```lua
-- healing/init.lua
local mq = require('mq')

local Config = require('healing.config')
local HealTracker = require('healing.heal_tracker')
local TargetMonitor = require('healing.target_monitor')
local IncomingHeals = require('healing.incoming_heals')
local CombatAssessor = require('healing.combat_assessor')
local HealSelector = require('healing.heal_selector')
local Analytics = require('healing.analytics')
local SpellEvents = require('healing.spell_events')

local M = {}

local _initialized = false

function M.init()
    if _initialized then return end
    _initialized = true

    Config.load()
    HealTracker.init(Config)
    TargetMonitor.init(Config)
    IncomingHeals.init(Config, TargetMonitor)
    CombatAssessor.init(Config, TargetMonitor)
    HealSelector.init(Config, HealTracker, TargetMonitor, IncomingHeals, CombatAssessor)
    Analytics.init()
    SpellEvents.init(HealTracker, IncomingHeals, Analytics)

    print('[Healing] Initialized')
end

function M.tick(settings)
    TargetMonitor.tick()
    IncomingHeals.tick()
    CombatAssessor.tick()
    SpellEvents.tick()
    HealTracker.tick()
    return false
end

function M.tickActors()
    -- Stub
end

function M.shutdown()
    HealTracker.shutdown()
    Config.save()
    print('[Healing] Analytics: ' .. Analytics.getSummary())
    print('[Healing] Shutdown')
end

-- Expose modules
M.Config = Config
M.HealTracker = HealTracker
M.TargetMonitor = TargetMonitor
M.IncomingHeals = IncomingHeals
M.CombatAssessor = CombatAssessor
M.HealSelector = HealSelector
M.Analytics = Analytics
M.SpellEvents = SpellEvents

return M
```

**Step 3: Verify analytics loads**

Run: `/lua run SideKick`
Wait, then: `/lua stop SideKick`
Expected: Analytics summary printed on shutdown

**Step 4: Commit**

```bash
git add healing/analytics.lua healing/init.lua
git commit -m "feat(healing): add analytics tracking module"
```

---

### Task 8b: Create logger.lua for detailed file logging

**Files:**
- Create: `healing/logger.lua`

**Purpose:** Comprehensive file logging for reviewing heal decisions, troubleshooting inefficiencies, and debugging coordination issues. Logs are written to `mq.configDir/HealingLogs/` with daily rotation.

**Step 1: Create logger.lua**

```lua
-- healing/logger.lua
local mq = require('mq')

local M = {}

local Config = nil
local _logFile = nil
local _logPath = nil
local _currentDate = nil
local _sessionId = nil

-- Log levels
local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }

function M.init(config)
    Config = config
    _sessionId = string.format('%s_%d', os.date('%H%M%S'), math.random(1000, 9999))
    M.ensureLogDir()
    M.rotate()
end

function M.ensureLogDir()
    local configDir = mq.configDir or 'config'
    local logDir = configDir .. '/HealingLogs'
    -- Create directory if needed (MQ creates parent dirs)
    os.execute('mkdir "' .. logDir .. '" 2>nul')
    _logPath = logDir
end

function M.rotate()
    local today = os.date('%Y-%m-%d')
    if _currentDate == today and _logFile then return end

    if _logFile then
        _logFile:close()
    end

    _currentDate = today
    local charName = mq.TLO.Me.CleanName() or 'Unknown'
    local server = (mq.TLO.EverQuest.Server() or 'Unknown'):gsub(' ', '_')
    local filename = string.format('%s/%s_%s_%s.log', _logPath, server, charName, today)

    _logFile = io.open(filename, 'a')
    if _logFile then
        M.info('session', '=== Session %s started ===', _sessionId)
    end
end

local function shouldLog(level, category)
    if not Config then return false end
    if not Config.fileLogging then return false end

    local configLevel = LEVELS[Config.fileLogLevel or 'info'] or 2
    local msgLevel = LEVELS[level] or 2
    if msgLevel < configLevel then return false end

    if category and Config.logCategories then
        if Config.logCategories[category] == false then return false end
    end

    return true
end

local function write(level, category, fmt, ...)
    if not shouldLog(level, category) then return end

    M.rotate()  -- Ensure we have current log file
    if not _logFile then return end

    local timestamp = os.date('%H:%M:%S')
    local msg = string.format(fmt, ...)
    local line = string.format('[%s][%s][%s] %s\n', timestamp, level:upper(), category or 'general', msg)

    _logFile:write(line)
    _logFile:flush()  -- Ensure immediate write for crash safety
end

function M.debug(category, fmt, ...) write('debug', category, fmt, ...) end
function M.info(category, fmt, ...) write('info', category, fmt, ...) end
function M.warn(category, fmt, ...) write('warn', category, fmt, ...) end
function M.error(category, fmt, ...) write('error', category, fmt, ...) end

-- Specialized logging functions for heal decisions

function M.logTargetSelection(targets, selected, reason)
    if not shouldLog('info', 'targetSelection') then return end

    local lines = { 'TARGET SELECTION:' }
    table.insert(lines, string.format('  Candidates: %d', #targets))
    for i, t in ipairs(targets) do
        if i <= 5 then  -- Top 5 only
            table.insert(lines, string.format('    %d. %s [%s] HP:%d%% Deficit:%d Incoming:%d EffDeficit:%d Priority:%d',
                i, t.name or '?', t.role or '?', t.pctHP or 0, t.deficit or 0,
                t.incomingHeals or 0, t.effectiveDeficit or 0, t.priority or 99))
        end
    end
    if selected then
        table.insert(lines, string.format('  SELECTED: %s - %s', selected.name or '?', reason or 'best candidate'))
    else
        table.insert(lines, string.format('  SELECTED: none - %s', reason or 'no valid target'))
    end

    write('info', 'targetSelection', table.concat(lines, '\n'))
end

function M.logSpellSelection(target, tier, spells, selected, score)
    if not shouldLog('info', 'spellSelection') then return end

    local lines = { string.format('SPELL SELECTION for %s [%s tier]:', target.name or '?', tier or '?') }
    table.insert(lines, string.format('  Target: HP:%d%% Deficit:%d EffDeficit:%d',
        target.pctHP or 0, target.deficit or 0, target.effectiveDeficit or 0))

    if spells and #spells > 0 then
        table.insert(lines, '  Candidates:')
        for i, s in ipairs(spells) do
            if i <= 8 then  -- Top 8 spells
                table.insert(lines, string.format('    %d. %s Score:%.2f Expected:%d Mana:%d Cast:%.1fs',
                    i, s.name or '?', s.score or 0, s.expected or 0, s.mana or 0, (s.castTime or 0) / 1000))
            end
        end
    end

    if selected then
        table.insert(lines, string.format('  SELECTED: %s (score: %.2f)', selected, score or 0))
    else
        table.insert(lines, '  SELECTED: none - no suitable spell')
    end

    write('info', 'spellSelection', table.concat(lines, '\n'))
end

function M.logSpellScoring(spellName, target, components)
    if not shouldLog('debug', 'spellScoring') then return end

    write('debug', 'spellScoring',
        'SCORE %s for %s: coverage=%.2f manaEff=%.2f overheal=%.2f castPenalty=%.2f burstBonus=%.2f TOTAL=%.2f',
        spellName, target.name or '?',
        components.coverage or 0, components.manaEff or 0, components.overheal or 0,
        components.castPenalty or 0, components.burstBonus or 0, components.total or 0)
end

function M.logDuckDecision(spellName, targetName, reason, details)
    if not shouldLog('info', 'ducking') then return end

    write('info', 'ducking', 'DUCK %s on %s: %s | %s',
        spellName or '?', targetName or '?', reason or '?', details or '')
end

function M.logIncomingHeals(targetId, targetName, heals, total)
    if not shouldLog('debug', 'incomingHeals') then return end

    local healerList = {}
    for healerId, data in pairs(heals or {}) do
        table.insert(healerList, string.format('%s:%d', data.healerName or healerId, data.expectedAmount or 0))
    end

    write('debug', 'incomingHeals', 'INCOMING for %s [%d]: %s = %d total',
        targetName or '?', targetId or 0, table.concat(healerList, ', '), total or 0)
end

function M.logCombatState(state)
    if not shouldLog('debug', 'combatState') then return end

    write('debug', 'combatState', 'COMBAT: phase=%s inCombat=%s survival=%s mobs=%d avgMobHP=%d%% TTK=%.1fs tankDPS=%d%%',
        state.fightPhase or '?', tostring(state.inCombat), tostring(state.survivalMode),
        state.activeMobCount or 0, state.avgMobHP or 0, state.estimatedTTK or 0, state.tankDpsPct or 0)
end

function M.logHotDecision(targetName, spellName, shouldApply, reason)
    if not shouldLog('info', 'hotDecisions') then return end

    write('info', 'hotDecisions', 'HOT %s on %s: %s - %s',
        spellName or '?', targetName or '?', shouldApply and 'APPLY' or 'SKIP', reason or '?')
end

function M.logHealCast(spellName, targetName, tier, expected, isHoT)
    write('info', 'spellSelection', 'CAST %s on %s [%s] expected:%d isHoT:%s',
        spellName or '?', targetName or '?', tier or '?', expected or 0, tostring(isHoT))
end

function M.logHealLanded(spellName, targetName, amount, isCrit)
    write('info', 'spellSelection', 'LANDED %s on %s for %d%s',
        spellName or '?', targetName or '?', amount or 0, isCrit and ' (CRIT)' or '')
end

function M.logCoordinationEvent(eventType, details)
    if not shouldLog('debug', 'incomingHeals') then return end
    write('debug', 'incomingHeals', 'COORD %s: %s', eventType or '?', details or '')
end

function M.logSessionSummary(analytics)
    if not shouldLog('info', 'analytics') then return end

    local lines = { '=== SESSION SUMMARY ===' }
    table.insert(lines, string.format('Duration: %s', analytics.duration or '?'))
    table.insert(lines, string.format('Total Casts: %d', analytics.totalCasts or 0))
    table.insert(lines, string.format('Total Healed: %d', analytics.totalHealed or 0))
    table.insert(lines, string.format('Overheal%%: %.1f%%', analytics.overHealPct or 0))
    table.insert(lines, string.format('Ducked: %d (saved ~%d mana)', analytics.duckedCasts or 0, analytics.duckSavings or 0))
    table.insert(lines, string.format('Incoming Honored: %d', analytics.incomingHonored or 0))
    table.insert(lines, string.format('Incoming Expired: %d', analytics.incomingExpired or 0))

    write('info', 'analytics', table.concat(lines, '\n'))
end

function M.shutdown()
    if _logFile then
        M.info('session', '=== Session %s ended ===', _sessionId or '?')
        _logFile:close()
        _logFile = nil
    end
end

return M
```

**Step 2: Commit**

```bash
git add healing/logger.lua
git commit -m "feat(healing): add detailed file logging module"
```

---

### Task 9: Implement main healing logic with ducking

**Files:**
- Modify: `healing/init.lua`

**Step 1: Add full healing tick logic**

Replace the tick function in `healing/init.lua` with the complete implementation:

```lua
-- healing/init.lua (full implementation)
local mq = require('mq')

local Config = require('healing.config')
local HealTracker = require('healing.heal_tracker')
local TargetMonitor = require('healing.target_monitor')
local IncomingHeals = require('healing.incoming_heals')
local CombatAssessor = require('healing.combat_assessor')
local HealSelector = require('healing.heal_selector')
local Analytics = require('healing.analytics')
local SpellEvents = require('healing.spell_events')
local Proactive = require('healing.proactive')
local Logger = require('healing.logger')

local M = {}

local _initialized = false
local _lastHealAttempt = 0
local _priorityActive = false
local ActorsCoordinator = nil

-- Lazy-load DamageParser (optional dual-source DPS tracking)
local DamageParser = nil
local function getDamageParser()
    if DamageParser == nil then
        local ok, dp = pcall(require, 'healing.damage_parser')
        if ok then
            DamageParser = dp
            dp.init(Config)
        else
            DamageParser = false  -- Mark as unavailable
        end
    end
    return DamageParser or nil
end

-- Check if we're a healing class
local function isHealerClass()
    local me = mq.TLO.Me
    if not me or not me() then return false end
    local classShort = me.Class and me.Class.ShortName and me.Class.ShortName() or ''
    classShort = classShort:upper()
    return classShort == 'CLR'  -- Only CLR for now
end

-- Check if we can heal right now
local function canHealNow()
    local me = mq.TLO.Me
    if not me or not me() then return false end

    -- Dead or hovering
    if me.Hovering and me.Hovering() then return false end

    -- Already casting
    if me.Casting and me.Casting() then return false end

    -- Moving
    if me.Moving and me.Moving() then return false end

    -- Check spell engine busy
    local ok, SpellEngine = pcall(require, 'utils.spell_engine')
    if ok and SpellEngine and SpellEngine.isBusy and SpellEngine.isBusy() then
        return false
    end

    return true
end

-- Check if we should duck the current cast
local function shouldDuck(castInfo)
    if not Config.duckEnabled then return false end
    if not castInfo then return false end

    local target = TargetMonitor.getTarget(castInfo.targetId)
    if not target then return false end

    local threshold
    if castInfo.tier == 'emergency' then
        threshold = Config.duckEmergencyThreshold or 70
    elseif castInfo.isHoT then
        threshold = Config.duckHotThreshold or 92
    else
        threshold = Config.duckHpThreshold or 85
    end

    threshold = threshold + (Config.duckBufferPct or 0.5)

    if target.pctHP >= threshold then
        return true, 'target_full'
    end

    if Config.considerIncomingHot and target.effectiveDeficit <= 0 then
        return true, 'incoming_covers'
    end

    return false
end

-- Execute a heal
local function executeHeal(spellName, targetId, tier, isHoT)
    local spell = mq.TLO.Spell(spellName)
    if not spell or not spell() then return false end

    local me = mq.TLO.Me
    local mySpell = me and me.Spell and me.Spell(spellName)
    local castTimeMs = mySpell and tonumber(mySpell.MyCastTime()) or tonumber(spell.CastTime()) or 2000
    local manaCost = tonumber(spell.Mana()) or 0
    local expected = HealTracker.getExpected(spellName)

    -- Set cast info for ducking (before cast attempt)
    SpellEvents.setCastInfo({
        spellName = spellName,
        targetId = targetId,
        tier = tier,
        isHoT = isHoT,
        manaCost = manaCost,
        startTime = mq.gettime(),  -- Use mq.gettime() for wall-clock accuracy
    })

    -- Use SpellEngine if available
    local ok, SpellEngine = pcall(require, 'utils.spell_engine')
    local success = false

    if ok and SpellEngine and SpellEngine.cast then
        success = SpellEngine.cast(spellName, targetId, { spellCategory = 'heal' })
    else
        -- Fallback to direct command
        mq.cmdf('/cast "%s"', spellName)
        success = true  -- Assume success for direct command
    end

    -- IMPORTANT: Only register incoming heal AFTER cast was accepted
    if success then
        IncomingHeals.registerMyCast(targetId, spellName, expected, castTimeMs / 1000, isHoT)
        M.broadcastIncoming(targetId, spellName, expected, mq.gettime() + castTimeMs / 1000, isHoT)
    else
        -- Cast failed, clear cast info
        SpellEvents.setCastInfo(nil)
    end

    return success
end

-- Main duck monitoring during cast
local function monitorDuck()
    local castInfo = SpellEvents.getCastInfo()
    if not castInfo then return end

    local me = mq.TLO.Me
    if not me or not me() or not me.Casting or not me.Casting() then
        -- Cast ended naturally
        SpellEvents.setCastInfo(nil)
        return
    end

    local duck, reason = shouldDuck(castInfo)
    if duck then
        -- Log duck decision with details
        local targetInfo = TargetMonitor.getTarget(castInfo.targetId)
        local details = string.format('targetHP=%d%% incoming=%d threshold=%d',
            targetInfo and targetInfo.pctHP or 0,
            targetInfo and targetInfo.incomingHeals or 0,
            Config.duckHpThreshold or 85)
        Logger.logDuckDecision(castInfo.spellName, castInfo.targetName or '?', reason, details)

        mq.cmd('/stopcast')

        -- IMPORTANT: Clear SpellEngine busy state to allow new casts
        local ok, SpellEngine = pcall(require, 'utils.spell_engine')
        if ok and SpellEngine and SpellEngine.abort then
            SpellEngine.abort()
        end

        IncomingHeals.unregisterMyCast(castInfo.targetId)
        Analytics.recordDuck(castInfo.spellName, castInfo.manaCost)
        SpellEvents.setCastInfo(nil)

        -- Broadcast cancellation to other healers
        M.broadcastCancelled(castInfo.targetId, castInfo.spellName, reason)

        print(string.format('[Healing] Ducked %s - %s', castInfo.spellName, reason))
    end
end

function M.init()
    if _initialized then return end
    _initialized = true

    Config.load()
    Logger.init(Config)  -- Initialize logging first for troubleshooting
    HealTracker.init(Config)
    TargetMonitor.init(Config)
    IncomingHeals.init(Config, TargetMonitor)
    CombatAssessor.init(Config, TargetMonitor)
    HealSelector.init(Config, HealTracker, TargetMonitor, IncomingHeals, CombatAssessor)
    Analytics.init()
    SpellEvents.init(HealTracker, IncomingHeals, Analytics)
    Proactive.init(Config, HealTracker, TargetMonitor, CombatAssessor)

    -- Load ActorsCoordinator for multi-healer coordination
    local ok, ac = pcall(require, 'utils.actors_coordinator')
    if ok then
        ActorsCoordinator = ac
    end

    Logger.info('session', 'Healing Intelligence initialized - fileLogging=%s', tostring(Config.fileLogging))
    print('[Healing] Initialized')
end

function M.tick(settings)
    -- Update all modules
    TargetMonitor.tick()
    IncomingHeals.tick()
    CombatAssessor.tick()
    SpellEvents.tick()
    HealTracker.tick()
    Proactive.tick()

    -- Update DamageParser for dual-source DPS tracking
    local dp = getDamageParser()
    if dp then dp.tick() end

    -- Check if healing is enabled (Config.enabled is the single source of truth)
    if Config.enabled == false then
        _priorityActive = false
        return false
    end

    -- Check if we're a healer class
    if not isHealerClass() then
        _priorityActive = false
        return false
    end

    -- Monitor for ducking during cast
    if SpellEvents.isCasting() then
        monitorDuck()
        _priorityActive = true
        return true
    end

    -- Throttle heal attempts (use mq.gettime() for wall-clock accuracy)
    local now = mq.gettime()
    if (now - _lastHealAttempt) < 0.1 then
        return _priorityActive
    end
    _lastHealAttempt = now

    -- Can we heal?
    if not canHealNow() then
        return _priorityActive
    end

    -- Check for group heal first
    local needGroup, groupSpell = HealSelector.checkGroupHeal()
    if needGroup and groupSpell then
        local myId = mq.TLO.Me.ID()
        if executeHeal(groupSpell, myId, 'group', false) then
            _priorityActive = true
            return true
        end
    end

    -- Find target that needs healing (deficit-based)
    local target, tier = HealSelector.findHealTarget()
    if not target then
        -- No urgent target found - check for proactive HoT opportunities (per design)
        -- Config.hotTankOnly controls whether HoTs are only applied to tanks or all targets
        if Config.hotEnabled and Proactive then
            local hotCandidates = {}
            local targets = TargetMonitor.getAllTargets()

            if Config.hotTankOnly then
                -- Only consider tanks for proactive HoTs
                for _, t in pairs(targets) do
                    if t.role == 'tank' then
                        table.insert(hotCandidates, t)
                    end
                end
            else
                -- Consider all targets for proactive HoTs, sorted by priority
                for _, t in pairs(targets) do
                    table.insert(hotCandidates, t)
                end
                table.sort(hotCandidates, function(a, b)
                    local pa = TargetMonitor.getPriority(a)
                    local pb = TargetMonitor.getPriority(b)
                    return pa < pb
                end)
            end

            for _, candidate in ipairs(hotCandidates) do
                local hotSpell = HealSelector.selectHeal(candidate, 'hot')
                if hotSpell then
                    local shouldApply, reason = Proactive.shouldApplyHoT(candidate, hotSpell)

                    -- Log HoT decision
                    Logger.logHotDecision(candidate.name, hotSpell, shouldApply, reason)

                    if shouldApply then
                        local spellData = mq.TLO.Spell(hotSpell)
                        local hotDuration = 0
                        if spellData and spellData() and spellData.Duration and spellData.Duration.TotalSeconds then
                            hotDuration = tonumber(spellData.Duration.TotalSeconds()) or 18
                        end

                        if executeHeal(hotSpell, candidate.id, 'hot', true) then
                            Proactive.recordHoT(candidate.id, hotSpell, hotDuration)
                            _priorityActive = true
                            return true
                        end
                    end
                end
            end
        end

        -- No healing needed
        _priorityActive = false
        return false
    end

    -- Check if someone else is already handling this target
    local incomingSum = IncomingHeals.sumForTarget(target.id)
    if incomingSum >= target.deficit then
        Analytics.recordIncomingHonored()
        -- Target is covered, try to find another
        -- (findHealTarget already filters by effectiveDeficit, but double-check)
        _priorityActive = false
        return false
    end

    -- Select best spell
    local spell, score = HealSelector.selectHeal(target, tier)
    if not spell then
        _priorityActive = tier == 'emergency'
        return _priorityActive
    end

    -- Execute the heal
    local spellInfo = mq.TLO.Spell(spell)
    local isHoT = false
    if spellInfo and spellInfo() and spellInfo.HasSPA then
        -- IMPORTANT: HasSPA(79) returns a function that must be called with ()
        local ok, v = pcall(function() return spellInfo.HasSPA(79)() end)
        isHoT = ok and v == true
    end

    if executeHeal(spell, target.id, tier, isHoT) then
        _priorityActive = true
        return true
    end

    return _priorityActive
end

function M.tickActors()
    -- TODO: Process incoming heal broadcasts from other healers
end

function M.isPriorityActive()
    return _priorityActive
end

function M.shutdown()
    -- Log session summary before shutdown
    Logger.logSessionSummary({
        duration = Analytics.getSessionDuration and Analytics.getSessionDuration() or '?',
        totalCasts = Analytics.getStats and Analytics.getStats().totalCasts or 0,
        totalHealed = Analytics.getStats and Analytics.getStats().totalHealed or 0,
        overHealPct = Analytics.getStats and Analytics.getStats().overHealPct or 0,
        duckedCasts = Analytics.getStats and Analytics.getStats().duckedCasts or 0,
        duckSavings = Analytics.getStats and Analytics.getStats().duckSavingsEstimate or 0,
        incomingHonored = Analytics.getStats and Analytics.getStats().incomingHealHonored or 0,
        incomingExpired = Analytics.getStats and Analytics.getStats().incomingHealExpired or 0,
    })

    HealTracker.shutdown()
    Config.save()
    Logger.shutdown()  -- Close log file
    print('[Healing] Analytics: ' .. Analytics.getSummary())
    print('[Healing] Shutdown')
end

-- Expose modules
M.Config = Config
M.HealTracker = HealTracker
M.TargetMonitor = TargetMonitor
M.IncomingHeals = IncomingHeals
M.CombatAssessor = CombatAssessor
M.HealSelector = HealSelector
M.Analytics = Analytics
M.SpellEvents = SpellEvents
M.Proactive = Proactive
M.Logger = Logger

return M
```

**Step 2: Verify full healing logic**

Run: `/lua run SideKick`
In game: Engage a mob with group, observe healing behavior (if spells configured)
Then: `/lua stop SideKick`
Expected: Analytics summary shows cast/duck counts

**Step 3: Commit**

```bash
git add healing/init.lua
git commit -m "feat(healing): implement full healing tick with ducking support"
```

---

## Phase 4: Actors Integration & UI

### Task 10: Integrate with ActorsCoordinator

**Files:**
- Modify: `healing/init.lua`
- Modify: `utils/actors_coordinator.lua` (add message handlers)

**IMPORTANT:** The existing ActorsCoordinator module in `utils/actors_coordinator.lua` needs to be updated to:
1. Register handlers for new message types: `heal:incoming`, `heal:landed`, `heal:cancelled`
2. Route these messages to the Healing module's `handleActorMessage` function
3. This is in addition to existing message types like `heal:claim` and `heal:hots`

**Step 1: Add actor message handling to init.lua**

Add to `healing/init.lua`:

```lua
-- Add after other local variables
local ActorsCoordinator = nil

-- In M.init(), after other init calls:
local ok, ac = pcall(require, 'utils.actors_coordinator')
if ok then
    ActorsCoordinator = ac
end

-- Replace tickActors function:
function M.tickActors()
    if not ActorsCoordinator then return end

    -- Broadcast our incoming heals periodically
    -- (handled by individual cast events)
end

-- Add broadcast functions:
function M.broadcastIncoming(targetId, spellName, expectedAmount, landsAt, isHoT)
    if not ActorsCoordinator or not ActorsCoordinator.broadcast then return end
    if not Config.broadcastEnabled then return end

    ActorsCoordinator.broadcast('heal:incoming', {
        targetId = targetId,
        spellName = spellName,
        expectedAmount = expectedAmount,
        landsAt = landsAt,
        isHoT = isHoT,
    })
end

function M.broadcastLanded(targetId, spellName)
    if not ActorsCoordinator or not ActorsCoordinator.broadcast then return end
    if not Config.broadcastEnabled then return end

    ActorsCoordinator.broadcast('heal:landed', {
        targetId = targetId,
        spellName = spellName,
    })
end

function M.broadcastCancelled(targetId, spellName, reason)
    if not ActorsCoordinator or not ActorsCoordinator.broadcast then return end
    if not Config.broadcastEnabled then return end

    ActorsCoordinator.broadcast('heal:cancelled', {
        targetId = targetId,
        spellName = spellName,
        reason = reason,
    })
end

-- Handler for incoming messages from other healers
function M.handleActorMessage(msgType, data, senderId)
    if msgType == 'heal:incoming' then
        IncomingHeals.add(senderId, data.targetId, data)
    elseif msgType == 'heal:landed' then
        IncomingHeals.remove(senderId, data.targetId)
    elseif msgType == 'heal:cancelled' then
        IncomingHeals.remove(senderId, data.targetId)
    end
end
```

**Step 2: Update executeHeal to broadcast**

**Note:** The broadcast call is now integrated directly in the `executeHeal` function in Task 9, so this step is already done. The broadcast uses `mq.gettime()` for timing consistency.

**Step 3: Commit**

```bash
git add healing/init.lua
git commit -m "feat(healing): add actors integration for multi-healer coordination"
```

---

### Task 11: Create proactive.lua (HoT timing)

**Files:**
- Create: `healing/proactive.lua`
- Modify: `healing/init.lua`

**Step 1: Create proactive.lua**

```lua
-- healing/proactive.lua
local mq = require('mq')

local M = {}

local Config = nil
local HealTracker = nil
local TargetMonitor = nil
local CombatAssessor = nil

-- Track active HoTs we've applied
local _activeHoTs = {}  -- [targetId][spellName] = expiresAt

function M.init(config, healTracker, targetMonitor, combatAssessor)
    Config = config
    HealTracker = healTracker
    TargetMonitor = targetMonitor
    CombatAssessor = combatAssessor
end

function M.recordHoT(targetId, spellName, duration)
    _activeHoTs[targetId] = _activeHoTs[targetId] or {}
    -- Use mq.gettime() for wall-clock accuracy (os.clock() can drift)
    _activeHoTs[targetId][spellName] = mq.gettime() + duration
end

function M.hasActiveHoT(targetId)
    local hots = _activeHoTs[targetId]
    if not hots then return false end

    local now = mq.gettime()
    for spellName, expires in pairs(hots) do
        if expires > now then
            return true, spellName, expires - now
        end
    end
    return false
end

function M.shouldRefreshHoT(targetId, hotSpellName)
    local hots = _activeHoTs[targetId]
    if not hots then return true end

    local expires = hots[hotSpellName]
    if not expires then return true end

    local remaining = expires - mq.gettime()
    if remaining <= 0 then return true end

    -- Check refresh window
    local refreshPct = Config and Config.hotRefreshWindowPct or 0
    if refreshPct <= 0 then return false end  -- Wait until expired

    -- Get spell duration
    local spell = mq.TLO.Spell(hotSpellName)
    if not spell or not spell() then return true end

    local duration = 0
    if spell.Duration and spell.Duration.TotalSeconds then
        duration = tonumber(spell.Duration.TotalSeconds()) or 0
    end

    if duration <= 0 then return true end

    local remainingPct = (remaining / duration) * 100
    return remainingPct <= refreshPct
end

function M.shouldApplyHoT(target, hotSpellName)
    if not Config or not Config.hotEnabled then
        return false, 'disabled'
    end

    local combatState = CombatAssessor and CombatAssessor.getState() or {}

    -- No HoTs during emergency
    if target.pctHP < (Config.emergencyPct or 25) then
        return false, 'emergency'
    end

    -- Check fight duration
    local spell = mq.TLO.Spell(hotSpellName)
    local hotDuration = 0
    if spell and spell() and spell.Duration and spell.Duration.TotalSeconds then
        hotDuration = tonumber(spell.Duration.TotalSeconds()) or 0
    end

    local minFightPct = Config.hotMinFightDurationPct or 50
    local fightRemaining = combatState.estimatedTTK or 999
    if fightRemaining < hotDuration * (minFightPct / 100) then
        return false, 'fight_ending'
    end

    -- Check if already has active HoT
    local hasHoT, existingSpell = M.hasActiveHoT(target.id)
    if hasHoT and not M.shouldRefreshHoT(target.id, existingSpell) then
        return false, 'hot_active'
    end

    -- Check HoT coverage ratio vs incoming DPS
    local tickAmount = HealTracker and HealTracker.getExpected(hotSpellName, 'tick') or 0
    local tickInterval = 6  -- Default tick interval

    if tickAmount <= 0 then
        -- Try to get from spell data
        if spell and spell() and spell.Base then
            tickAmount = math.abs(tonumber(spell.Base(1)()) or 0)
        end
    end

    if tickAmount <= 0 then
        return false, 'no_tick_data'
    end

    local hotHps = tickAmount / tickInterval
    local incomingDps = target.recentDps or 0

    if incomingDps <= 0 then
        -- No damage, only apply HoT if small deficit
        local deficitPct = (target.deficit / math.max(1, target.maxHP)) * 100
        local maxDeficitPct = Config.hotMaxDeficitPct or 25
        if deficitPct > 0 and deficitPct <= maxDeficitPct then
            return true, 'small_deficit'
        end
        return false, 'no_damage'
    end

    local coverageRatio = hotHps / incomingDps
    local minRatio = Config.hotMinCoverageRatio or 0.3
    local uselessRatio = Config.hotUselessRatio or 0.1

    if coverageRatio >= minRatio then
        return true, 'sustained_damage'
    elseif coverageRatio >= uselessRatio then
        return true, 'supplement'
    end

    return false, 'hot_insufficient'
end

function M.tick()
    -- Prune expired HoTs (use mq.gettime() for wall-clock accuracy)
    local now = mq.gettime()
    for targetId, hots in pairs(_activeHoTs) do
        for spellName, expires in pairs(hots) do
            if expires <= now then
                hots[spellName] = nil
            end
        end

        -- Clean up empty entries
        local hasAny = false
        for _ in pairs(hots) do
            hasAny = true
            break
        end
        if not hasAny then
            _activeHoTs[targetId] = nil
        end
    end
end

return M
```

**Step 2: Integrate proactive into init.lua**

Add to init.lua:
- `local Proactive = require('healing.proactive')`
- In `M.init()`: `Proactive.init(Config, HealTracker, TargetMonitor, CombatAssessor)`
- In `M.tick()`: `Proactive.tick()`
- Expose: `M.Proactive = Proactive`

**Step 3: Commit**

```bash
git add healing/proactive.lua healing/init.lua
git commit -m "feat(healing): add proactive HoT timing module"
```

---

### Task 12: Create UI settings tab

**Files:**
- Create: `healing/ui/settings.lua`
- Modify: `ui/settings.lua` (add healing tab)

**Step 1: Create healing/ui/settings.lua**

```lua
-- healing/ui/settings.lua
local mq = require('mq')
local imgui = require('ImGui')

local M = {}

local Config = nil

function M.init(config)
    Config = config
end

function M.draw()
    if not Config then return end

    -- Enable toggle (Config.enabled is the single source of truth)
    local enabled = Config.enabled ~= false
    local changed
    enabled, changed = imgui.Checkbox('Enable Healing Intelligence', enabled)
    if changed then
        Config.enabled = enabled
        -- Auto-save when toggling enabled state
        Config.save()
    end

    imgui.Separator()

    -- Thresholds
    if imgui.CollapsingHeader('Thresholds') then
        imgui.PushItemWidth(150)

        local emergency = Config.emergencyPct or 25
        emergency, changed = imgui.SliderInt('Emergency HP %', emergency, 10, 50)
        if changed then Config.emergencyPct = emergency end

        local minHeal = Config.minHealPct or 10
        minHeal, changed = imgui.SliderInt('Min Heal HP %', minHeal, 1, 30)
        if changed then Config.minHealPct = minHeal end

        local groupCount = Config.groupHealMinCount or 3
        groupCount, changed = imgui.SliderInt('Group Heal Min Count', groupCount, 2, 5)
        if changed then Config.groupHealMinCount = groupCount end

        imgui.PopItemWidth()
    end

    -- Spell Assignment
    if imgui.CollapsingHeader('Spell Assignment') then
        imgui.TextDisabled('Configure spells in config file for now')
        imgui.TextDisabled('Path: ' .. mq.configDir .. '/SideKick_Healing_*.lua')

        -- Show current assignments
        if Config.spells then
            for category, spells in pairs(Config.spells) do
                if type(spells) == 'table' and #spells > 0 then
                    imgui.Text(category .. ': ' .. table.concat(spells, ', '))
                end
            end
        end
    end

    -- Ducking
    if imgui.CollapsingHeader('Spell Ducking') then
        local duckEnabled = Config.duckEnabled ~= false
        duckEnabled, changed = imgui.Checkbox('Enable Ducking', duckEnabled)
        if changed then Config.duckEnabled = duckEnabled end

        if duckEnabled then
            imgui.PushItemWidth(150)

            local duckThresh = Config.duckHpThreshold or 85
            duckThresh, changed = imgui.SliderInt('Duck Threshold %', duckThresh, 70, 95)
            if changed then Config.duckHpThreshold = duckThresh end

            local considerHot = Config.considerIncomingHot ~= false
            considerHot, changed = imgui.Checkbox('Consider Incoming HoTs', considerHot)
            if changed then Config.considerIncomingHot = considerHot end

            imgui.PopItemWidth()
        end
    end

    -- HoT Behavior
    if imgui.CollapsingHeader('HoT Behavior') then
        local hotEnabled = Config.hotEnabled ~= false
        hotEnabled, changed = imgui.Checkbox('Enable Proactive HoTs', hotEnabled)
        if changed then Config.hotEnabled = hotEnabled end

        if hotEnabled then
            imgui.PushItemWidth(150)

            local minRatio = Config.hotMinCoverageRatio or 0.3
            minRatio, changed = imgui.SliderFloat('Min Coverage Ratio', minRatio, 0.1, 1.0, '%.2f')
            if changed then Config.hotMinCoverageRatio = minRatio end

            local tankOnly = Config.hotTankOnly ~= false
            tankOnly, changed = imgui.Checkbox('Big HoT Tank Only', tankOnly)
            if changed then Config.hotTankOnly = tankOnly end

            imgui.PopItemWidth()
        end
    end

    -- Advanced
    if imgui.CollapsingHeader('Advanced') then
        local broadcast = Config.broadcastEnabled ~= false
        broadcast, changed = imgui.Checkbox('Broadcast to Other Healers', broadcast)
        if changed then Config.broadcastEnabled = broadcast end

        local debug = Config.debugLogging == true
        debug, changed = imgui.Checkbox('Debug Logging', debug)
        if changed then Config.debugLogging = debug end
    end

    imgui.Separator()

    if imgui.Button('Save Config') then
        Config.save()
    end

    imgui.SameLine()

    if imgui.Button('Open Heal Monitor') then
        -- TODO: Toggle monitor window
    end
end

return M
```

**Step 2: Note for integration**

The settings tab will be integrated into SideKick's main settings UI in a later task. For now, it's a standalone module.

**Step 3: Commit**

```bash
git add healing/ui/settings.lua
git commit -m "feat(healing): add UI settings module"
```

---

### Task 13: Create monitor window

**Files:**
- Create: `healing/ui/monitor.lua`

**Step 1: Create monitor.lua**

```lua
-- healing/ui/monitor.lua
local mq = require('mq')
local imgui = require('ImGui')

local M = {}

local _open = false
local _draw = false

local TargetMonitor = nil
local IncomingHeals = nil
local CombatAssessor = nil
local Analytics = nil
local Config = nil

function M.init(config, targetMonitor, incomingHeals, combatAssessor, analytics)
    Config = config
    TargetMonitor = targetMonitor
    IncomingHeals = incomingHeals
    CombatAssessor = combatAssessor
    Analytics = analytics
end

function M.toggle()
    _open = not _open
end

function M.isOpen()
    return _open
end

function M.setOpen(open)
    _open = open
end

function M.draw()
    if not _open then return end

    imgui.SetNextWindowSize(400, 350, ImGuiCond.FirstUseEver)

    _open, _draw = imgui.Begin('Healing Monitor##HealMon', _open)
    if _draw then
        -- Status line
        local state = CombatAssessor and CombatAssessor.getState() or {}
        local statusColor = state.survivalMode and { 1, 0.3, 0.3, 1 } or { 0.3, 1, 0.3, 1 }
        imgui.TextColored(statusColor[1], statusColor[2], statusColor[3], statusColor[4],
            string.format('Status: %s | Phase: %s | Survival: %s',
                state.inCombat and 'Active' or 'Idle',
                state.fightPhase or 'none',
                state.survivalMode and 'ON' or 'OFF'))

        imgui.Separator()

        -- Targets table
        if imgui.BeginTable('##targets', 5, ImGuiTableFlags.Borders + ImGuiTableFlags.RowBg) then
            imgui.TableSetupColumn('Target', ImGuiTableColumnFlags.WidthFixed, 100)
            imgui.TableSetupColumn('HP%', ImGuiTableColumnFlags.WidthFixed, 50)
            imgui.TableSetupColumn('Deficit', ImGuiTableColumnFlags.WidthFixed, 60)
            imgui.TableSetupColumn('Incoming', ImGuiTableColumnFlags.WidthFixed, 60)
            imgui.TableSetupColumn('DPS', ImGuiTableColumnFlags.WidthFixed, 50)
            imgui.TableHeadersRow()

            if TargetMonitor then
                local injured = TargetMonitor.getInjuredTargets(100)
                for _, target in ipairs(injured) do
                    imgui.TableNextRow()

                    imgui.TableNextColumn()
                    local roleIcon = target.role == 'tank' and '[T]' or (target.role == 'healer' and '[H]' or '')
                    imgui.Text(roleIcon .. ' ' .. (target.name or 'Unknown'):sub(1, 12))

                    imgui.TableNextColumn()
                    local hpColor = target.pctHP < 25 and { 1, 0, 0, 1 } or (target.pctHP < 50 and { 1, 0.5, 0, 1 } or { 1, 1, 1, 1 })
                    imgui.TextColored(hpColor[1], hpColor[2], hpColor[3], hpColor[4], string.format('%d%%', target.pctHP))

                    imgui.TableNextColumn()
                    imgui.Text(string.format('%dk', math.floor(target.deficit / 1000)))

                    imgui.TableNextColumn()
                    local incoming = target.incomingTotal or 0
                    if incoming > 0 then
                        imgui.TextColored(0.3, 0.8, 0.3, 1, string.format('%dk', math.floor(incoming / 1000)))
                    else
                        imgui.Text('-')
                    end

                    imgui.TableNextColumn()
                    imgui.Text(string.format('%.0f', target.recentDps or 0))
                end
            end

            imgui.EndTable()
        end

        imgui.Separator()

        -- Analytics summary
        if Analytics then
            local stats = Analytics.getStats()
            imgui.Text(string.format('Session: %dm | Casts: %d | Ducked: %d (%.0f%%)',
                math.floor(Analytics.getSessionDuration() / 60),
                stats.totalCasts,
                stats.duckedCasts,
                stats.totalCasts > 0 and (stats.duckedCasts / stats.totalCasts * 100) or 0))

            imgui.Text(string.format('Efficiency: %.1f%% | Overheal: %.1f%% | HPM: %.1f',
                Analytics.getEfficiencyPct(),
                stats.overHealPct,
                stats.healPerMana))
        end
    end
    imgui.End()
end

return M
```

**Step 2: Integrate monitor into init.lua**

Add to init.lua:
- `local Monitor = require('healing.ui.monitor')`
- In `M.init()`: `Monitor.init(Config, TargetMonitor, IncomingHeals, CombatAssessor, Analytics)`
- Add function: `M.toggleMonitor = function() Monitor.toggle() end`
- Add to imgui registration (or expose for SideKick to call)

**Step 3: Commit**

```bash
git add healing/ui/monitor.lua healing/init.lua
git commit -m "feat(healing): add healing monitor window"
```

---

## Phase 5: Integration with SideKick Main

### Task 14: Integrate healing module into SideKick.lua

**Files:**
- Modify: `SideKick.lua`

**IMPORTANT: Class-Based Module Switching**
The new healing intelligence module is CLR-only for now. Other healing classes (SHM, DRU, RNG, BST) should continue using the legacy `automation.healing` module until they are supported.

**Step 1: Add class-based module loading**

In `SideKick.lua`, add logic to choose the appropriate healing module:
```lua
-- Near the top, after other requires
local LegacyHealing = require('automation.healing')
local NewHealing = nil

-- Function to get the appropriate healing module
local function getHealingModule()
    local me = mq.TLO.Me
    if not me or not me() then return LegacyHealing end
    local classShort = me.Class and me.Class.ShortName and me.Class.ShortName() or ''
    classShort = classShort:upper()

    -- CLR uses new healing intelligence module
    if classShort == 'CLR' then
        if not NewHealing then
            local ok, mod = pcall(require, 'healing')
            if ok then
                NewHealing = mod
                NewHealing.init()
            end
        end
        return NewHealing or LegacyHealing
    end

    -- All other classes use legacy module
    return LegacyHealing
end

local Healing = nil  -- Will be set dynamically
```

**Step 2: Update tick call**

In `tickAutomation()`, update to get the appropriate healing module:
```lua
local priorityHealingActive = false
if playStyle ~= 'manual' then
    Healing = getHealingModule()  -- Get appropriate module for current class
    if Healing and Healing.tick then
        priorityHealingActive = Healing.tick(Core.Settings) == true
    end
end
```

**Step 3: Add tickActors call**

In the actors section of the main loop:
```lua
if Core.Settings.ActorsEnabled ~= false then
    if Healing and Healing.tickActors then
        Healing.tickActors()
    end
    -- ... rest of actors tick
end
```

**Step 4: Add shutdown call**

Before the end of main(), handle both possible modules:
```lua
if NewHealing and NewHealing.shutdown then
    NewHealing.shutdown()
end
-- LegacyHealing doesn't have shutdown, but check anyway
if LegacyHealing and LegacyHealing.shutdown then
    LegacyHealing.shutdown()
end
```

**Step 5: Add command binding**

In the `/SideKick` command handler, add:
```lua
elseif a1 == 'healmonitor' then
    local mod = getHealingModule()
    if mod and mod.toggleMonitor then
        mod.toggleMonitor()
    end
```

**Step 6: Add imgui draw call**

In the imgui registration, add:
```lua
-- Only new healing module has drawMonitor
if NewHealing and NewHealing.drawMonitor then
    NewHealing.drawMonitor()
end
```

**Step 7: Verify integration**

Run: `/lua run SideKick`
Expected: `[Healing] Initialized` appears
Test: `/sidekick healmonitor` opens the monitor window
Then: `/lua stop SideKick`
Expected: `[Healing] Analytics:` and `[Healing] Shutdown` appear

**Step 9: Commit**

```bash
git add SideKick.lua
git commit -m "feat: integrate new healing intelligence module into SideKick"
```

---

### Task 15: Add healing settings to SideKick settings UI

**Files:**
- Modify: `ui/settings.lua`

**Step 1: Add Healing tab to settings**

In the settings UI tab bar, add a new tab:

```lua
if imgui.BeginTabItem('Healing') then
    local Healing = require('healing')
    if Healing and Healing.Config then
        local HealSettingsUI = require('healing.ui.settings')
        HealSettingsUI.init(Healing.Config)
        HealSettingsUI.draw()
    else
        imgui.Text('Healing module not loaded')
    end
    imgui.EndTabItem()
end
```

**Step 2: Verify UI appears**

Run: `/lua run SideKick`
Open settings (cog icon)
Expected: "Healing" tab appears with settings

**Step 3: Commit**

```bash
git add ui/settings.lua
git commit -m "feat: add Healing tab to SideKick settings UI"
```

---

### Task 16: Final testing and documentation

**Step 1: Create test checklist**

Manually verify:
- [ ] Healing module initializes without errors
- [ ] Target monitor tracks group HP correctly
- [ ] Combat assessor detects fight phases
- [ ] Heal selector picks appropriate spells based on deficit
- [ ] Spell events track heal landed/crit correctly
- [ ] Ducking cancels cast when target is healed
- [ ] Analytics tracks casts/ducks/efficiency
- [ ] Monitor window shows real-time data
- [ ] Settings UI allows configuration changes
- [ ] Config saves and loads correctly
- [ ] Heal data persists across sessions

**Step 2: Test with configured spells**

1. Open config file: `mq.configDir/SideKick_Healing_<server>_<char>.lua`
2. Add spells to categories:
```lua
spells = {
    fast = { "Sincere Remedy" },
    small = { "Merciful Light" },
    medium = { "Sincere Intervention" },
    large = { "Merciful Renewal" },
    group = { "Word of Greater Reformation" },
    hot = { "Earnest Elixir" },
    groupHot = { "Avowed Acquittal" },
},
```
3. Run SideKick and engage in combat
4. Verify heals are cast appropriately

**Step 3: Commit any fixes**

```bash
git add -A
git commit -m "fix: address issues found during integration testing"
```

**Step 4: Final commit**

```bash
git add -A
git commit -m "feat(healing): complete healing intelligence implementation"
```

---

## Summary

This implementation plan creates a comprehensive healing intelligence system with:

1. **Foundation** (Tasks 1-4): Config, persistence, heal tracker, target monitor, incoming heals
2. **Combat Assessment** (Tasks 5-6): Fight phase detection, survival mode, heal selector with scoring
3. **Events & Ducking** (Tasks 7-9): Spell events, analytics, main healing logic with ducking
4. **Actors & UI** (Tasks 10-13): Multi-healer coordination, proactive HoTs, settings UI, monitor window
5. **Integration** (Tasks 14-16): SideKick integration, settings tab, testing

Total estimated tasks: 16
Each task has explicit file paths, code, and verification steps.
