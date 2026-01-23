-- F:\lua\SideKick\automation\cures.lua
-- Cure System - Automatic debuff removal for group members
-- Supports: Disease, Poison, Curse, Corruption

local mq = require('mq')

local M = {}

-- Lazy-load dependencies to avoid circular requires
local _SpellEngine = nil
local function getSpellEngine()
    if not _SpellEngine then
        local ok, se = pcall(require, 'sidekick-next.utils.spell_engine')
        if ok then _SpellEngine = se end
    end
    return _SpellEngine
end

local _RuntimeCache = nil
local function getRuntimeCache()
    if not _RuntimeCache then
        local ok, rc = pcall(require, 'sidekick-next.utils.runtime_cache')
        if ok then _RuntimeCache = rc end
    end
    return _RuntimeCache
end

local _Core = nil
local function getCore()
    if not _Core then
        local ok, c = pcall(require, 'sidekick-next.utils.core')
        if ok then _Core = c end
    end
    return _Core
end

local _ActorsCoordinator = nil
local function getActors()
    if not _ActorsCoordinator then
        local ok, ac = pcall(require, 'sidekick-next.utils.actors_coordinator')
        if ok then _ActorsCoordinator = ac end
    end
    return _ActorsCoordinator
end

-- Cure types we track and handle
M.CURE_TYPES = { 'Disease', 'Poison', 'Curse', 'Corruption' }

-- Map debuff types to spell line names (for spellset lookup)
M.CURE_LINE_MAP = {
    Disease = { 'CureDisease', 'CureDiseaseGroup', 'CureAll' },
    Poison = { 'CurePoison', 'CurePoisonGroup', 'CureAll' },
    Curse = { 'CureCurse', 'CureCurseGroup', 'CureAll' },
    Corruption = { 'CureCorruption', 'CureCorruptionGroup', 'CureAll' },
}

-- Classes that can cure
M.CURE_CLASSES = {
    CLR = { Disease = true, Poison = true, Curse = true, Corruption = true },
    DRU = { Disease = true, Poison = true, Curse = true, Corruption = true },
    SHM = { Disease = true, Poison = true, Curse = false, Corruption = false },
    PAL = { Disease = true, Poison = false, Curse = false, Corruption = false },
    RNG = { Disease = true, Poison = true, Curse = false, Corruption = false },
    BST = { Disease = false, Poison = true, Curse = false, Corruption = false },
}

-- State
local _state = {
    initialized = false,
    lastTick = 0,
    lastCureCastAt = 0,
    selfName = '',
    classShort = '',
    canCure = {},  -- { [cureType] = boolean }

    -- Debuff tracking per target
    trackedDebuffs = {},  -- { [targetId] = { [debuffType] = { detected = timestamp, spellId, spellName } } }

    -- Cure claims (prevent duplicate cures)
    localClaims = {},   -- { [targetId] = { [debuffType] = { claimedAt } } }
    remoteClaims = {},  -- { [targetId] = { [debuffType] = { claimedAt, claimer } } }

    -- Recent cures (for coordination)
    recentCures = {},  -- { [targetId] = { [debuffType] = { curedAt, curer } } }
}

local TICK_INTERVAL = 0.25       -- Check for cures every 250ms
local CLAIM_TIMEOUT = 8.0        -- Claims expire after 8 seconds
local RECENT_CURE_WINDOW = 10.0  -- Consider cure "recent" for 10 seconds
local MAX_BUFF_SLOTS = 42        -- Maximum buff slots to scan

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

function M.init()
    _state.initialized = false
    _state.trackedDebuffs = {}
    _state.localClaims = {}
    _state.remoteClaims = {}
    _state.recentCures = {}
    _state.lastTick = 0
    _state.lastCureCastAt = 0

    _state.selfName = (mq.TLO.Me and mq.TLO.Me.CleanName and mq.TLO.Me.CleanName()) or ''

    -- Determine class and cure capabilities
    local cls = ''
    if mq.TLO.Me and mq.TLO.Me.Class and mq.TLO.Me.Class.ShortName then
        cls = tostring(mq.TLO.Me.Class.ShortName() or ''):upper()
    end
    _state.classShort = cls

    -- Set up cure capabilities
    _state.canCure = {}
    local classCures = M.CURE_CLASSES[cls]
    if classCures then
        for cureType, canDo in pairs(classCures) do
            _state.canCure[cureType] = canDo
        end
    end

    _state.initialized = true
end

--------------------------------------------------------------------------------
-- Class Config Integration
--------------------------------------------------------------------------------

local function loadClassConfig(classShort)
    local ok, config = pcall(require, string.format('data.class_configs.%s', classShort))
    if ok then return config end
    return nil
end

local function spellMemorized(spellName)
    if not spellName or spellName == '' then return false end
    local me = mq.TLO.Me
    if not (me and me()) then return false end
    local gems = tonumber(me.NumGems()) or 13
    for i = 1, gems do
        local gem = me.Gem(i)
        if gem and gem() and (gem.Name() or '') == spellName then
            return true
        end
    end
    return false
end

local function resolveSpellLine(classConfig, lineName)
    if not classConfig or not classConfig.spellLines or not lineName then return nil end
    local line = classConfig.spellLines[lineName]
    if type(line) ~= 'table' then return nil end
    for _, name in ipairs(line) do
        if spellMemorized(name) then
            return name
        end
    end
    return nil
end

local function getBestCureSpell(debuffType, forGroup)
    local classConfig = loadClassConfig(_state.classShort)
    if not classConfig then return nil end

    local lineNames = M.CURE_LINE_MAP[debuffType]
    if not lineNames then return nil end

    -- Prefer group cures if forGroup is true
    if forGroup then
        for _, lineName in ipairs(lineNames) do
            if lineName:find('Group') or lineName == 'CureAll' then
                local spell = resolveSpellLine(classConfig, lineName)
                if spell then return spell end
            end
        end
    end

    -- Fallback to single-target cures
    for _, lineName in ipairs(lineNames) do
        local spell = resolveSpellLine(classConfig, lineName)
        if spell then return spell end
    end

    return nil
end

--------------------------------------------------------------------------------
-- Debuff Detection
--------------------------------------------------------------------------------

local function isDetrimentalBuff(spawn, buffSlot)
    if not (spawn and spawn()) then return false end
    local buff = spawn.Buff(buffSlot)
    if not (buff and buff()) then return false end

    -- Check Beneficial flag
    local beneficial = nil
    if buff.Beneficial then
        local ok, v = pcall(function() return buff.Beneficial() end)
        if ok then beneficial = v end
    end

    -- Detrimental if Beneficial is false
    if beneficial == false then return true end

    -- Some buffs may not have Beneficial flag, check SpellType
    local spellType = nil
    if buff.SpellType then
        local ok, v = pcall(function() return buff.SpellType() end)
        if ok then spellType = tostring(v or ''):lower() end
    end

    if spellType == 'detrimental' then return true end

    return false
end

local function getDebuffType(spawn, buffSlot)
    if not (spawn and spawn()) then return nil end
    local buff = spawn.Buff(buffSlot)
    if not (buff and buff()) then return nil end

    -- Check SpellType for cure category
    local spellType = nil
    if buff.SpellType then
        local ok, v = pcall(function() return buff.SpellType() end)
        if ok then spellType = tostring(v or '') end
    end

    -- Check CounterType or Category
    local counterType = nil
    if buff.CounterType then
        local ok, v = pcall(function() return buff.CounterType() end)
        if ok then counterType = tostring(v or '') end
    end

    -- Check for common debuff types
    local typeLower = tostring(spellType or ''):lower()
    local counterLower = tostring(counterType or ''):lower()

    -- Disease detection
    if typeLower:find('disease') or counterLower:find('disease') then
        return 'Disease'
    end

    -- Poison detection
    if typeLower:find('poison') or counterLower:find('poison') then
        return 'Poison'
    end

    -- Curse detection
    if typeLower:find('curse') or counterLower:find('curse') then
        return 'Curse'
    end

    -- Corruption detection
    if typeLower:find('corrupt') or counterLower:find('corrupt') then
        return 'Corruption'
    end

    -- Fallback: check spell categories/subcategories
    local spell = buff.Spell
    if spell and spell() then
        local category = nil
        if spell.Category then
            local ok, v = pcall(function() return spell.Category() end)
            if ok then category = tostring(v or ''):lower() end
        end
        local subcategory = nil
        if spell.Subcategory then
            local ok, v = pcall(function() return spell.Subcategory() end)
            if ok then subcategory = tostring(v or ''):lower() end
        end

        if category then
            if category:find('disease') then return 'Disease' end
            if category:find('poison') then return 'Poison' end
            if category:find('curse') then return 'Curse' end
            if category:find('corrupt') then return 'Corruption' end
        end
        if subcategory then
            if subcategory:find('disease') then return 'Disease' end
            if subcategory:find('poison') then return 'Poison' end
            if subcategory:find('curse') then return 'Curse' end
            if subcategory:find('corrupt') then return 'Corruption' end
        end
    end

    return nil
end

local function scanSpawnForDebuffs(spawn)
    if not (spawn and spawn()) then return {} end

    local debuffs = {}
    local id = spawn.ID and spawn.ID() or 0
    if id == 0 then return {} end

    -- Scan buff slots for detrimental effects
    for slot = 1, MAX_BUFF_SLOTS do
        if isDetrimentalBuff(spawn, slot) then
            local debuffType = getDebuffType(spawn, slot)
            if debuffType then
                local buff = spawn.Buff(slot)
                debuffs[debuffType] = debuffs[debuffType] or {}
                table.insert(debuffs[debuffType], {
                    slot = slot,
                    spellId = buff.ID and buff.ID() or 0,
                    spellName = buff.Name and buff.Name() or '',
                    duration = buff.Duration and buff.Duration.TotalSeconds and buff.Duration.TotalSeconds() or 0,
                })
            end
        end
    end

    return debuffs
end

local function scanGroupForDebuffs()
    local allDebuffs = {}  -- { [targetId] = { [debuffType] = { ... } } }
    local now = os.clock()

    -- Scan self
    local me = mq.TLO.Me
    local myId = me and me.ID and me.ID() or 0
    if myId > 0 then
        local myDebuffs = scanSpawnForDebuffs(me)
        if next(myDebuffs) then
            allDebuffs[myId] = myDebuffs
        end
    end

    -- Scan group members
    local members = tonumber(mq.TLO.Group.Members()) or 0
    for i = 1, members do
        local member = mq.TLO.Group.Member(i)
        if member and member() and not member.Offline() and not member.OtherZone() and not member.Dead() then
            local memberId = member.ID and member.ID() or 0
            if memberId > 0 then
                local spawn = mq.TLO.Spawn(memberId)
                local debuffs = scanSpawnForDebuffs(spawn)
                if next(debuffs) then
                    allDebuffs[memberId] = debuffs
                end
            end
        end
    end

    -- Scan group member pets
    for i = 1, members do
        local member = mq.TLO.Group.Member(i)
        if member and member() and not member.Offline() and not member.OtherZone() then
            local pet = member.Pet
            if pet and pet() and pet.ID and pet.ID() > 0 then
                local petId = pet.ID()
                local petSpawn = mq.TLO.Spawn(petId)
                local debuffs = scanSpawnForDebuffs(petSpawn)
                if next(debuffs) then
                    allDebuffs[petId] = debuffs
                end
            end
        end
    end

    return allDebuffs
end

--------------------------------------------------------------------------------
-- Claim System (prevent duplicate cures)
--------------------------------------------------------------------------------

local function claimCure(targetId, debuffType)
    if not targetId or targetId == 0 then return false end
    local id = tonumber(targetId)
    if not id then return false end

    debuffType = tostring(debuffType or '')
    if debuffType == '' then return false end

    -- Check if someone else claimed it
    if M.isCureClaimed(id, debuffType) then
        return false
    end

    -- Check if recently cured
    if M.wasRecentlyCured(id, debuffType) then
        return false
    end

    -- Claim it
    _state.localClaims[id] = _state.localClaims[id] or {}
    _state.localClaims[id][debuffType] = {
        claimedAt = os.clock(),
    }

    -- Broadcast claim
    local Actors = getActors()
    if Actors and Actors.broadcast then
        Actors.broadcast('cure:claim', {
            targetId = id,
            debuffType = debuffType,
            claimer = _state.selfName,
            claimedAt = os.clock(),
        })
    end

    return true
end

local function releaseClaim(targetId, debuffType)
    if not targetId then return end
    local id = tonumber(targetId)
    if not id then return end

    if debuffType then
        debuffType = tostring(debuffType)
        if _state.localClaims[id] then
            _state.localClaims[id][debuffType] = nil
            if not next(_state.localClaims[id]) then
                _state.localClaims[id] = nil
            end
        end
    else
        _state.localClaims[id] = nil
    end
end

function M.isCureClaimed(targetId, debuffType)
    if not targetId then return false end
    local id = tonumber(targetId)
    if not id then return false end

    debuffType = tostring(debuffType or '')
    if debuffType == '' then return false end

    local now = os.clock()
    local remoteClaims = _state.remoteClaims[id]
    if remoteClaims and remoteClaims[debuffType] then
        local claim = remoteClaims[debuffType]
        if (now - claim.claimedAt) < CLAIM_TIMEOUT then
            return true
        end
    end

    return false
end

function M.wasRecentlyCured(targetId, debuffType)
    if not targetId then return false end
    local id = tonumber(targetId)
    if not id then return false end

    debuffType = tostring(debuffType or '')
    if debuffType == '' then return false end

    local now = os.clock()
    local recent = _state.recentCures[id]
    if recent and recent[debuffType] then
        local cure = recent[debuffType]
        if (now - cure.curedAt) < RECENT_CURE_WINDOW then
            return true
        end
    end

    return false
end

function M.receiveClaim(payload)
    local targetId = tonumber(payload.targetId)
    if not targetId or targetId == 0 then return end

    local debuffType = tostring(payload.debuffType or '')
    if debuffType == '' then return end

    local claimer = payload.claimer or payload.from or 'unknown'
    if claimer == _state.selfName then return end

    _state.remoteClaims[targetId] = _state.remoteClaims[targetId] or {}
    _state.remoteClaims[targetId][debuffType] = {
        claimedAt = os.clock(),
        claimer = claimer,
    }
end

function M.receiveCureLanded(payload)
    local targetId = tonumber(payload.targetId)
    if not targetId or targetId == 0 then return end

    local debuffType = tostring(payload.debuffType or '')
    if debuffType == '' then return end

    local curer = payload.curer or payload.from or 'unknown'

    _state.recentCures[targetId] = _state.recentCures[targetId] or {}
    _state.recentCures[targetId][debuffType] = {
        curedAt = os.clock(),
        curer = curer,
    }

    -- Clear claims for this cure
    if _state.remoteClaims[targetId] then
        _state.remoteClaims[targetId][debuffType] = nil
        if not next(_state.remoteClaims[targetId]) then
            _state.remoteClaims[targetId] = nil
        end
    end
end

local function broadcastCureLanded(targetId, debuffType, spellName)
    local Actors = getActors()
    if not Actors or not Actors.broadcast then return end

    Actors.broadcast('cure:landed', {
        targetId = targetId,
        debuffType = debuffType,
        spellName = spellName or '',
        curer = _state.selfName,
    })
end

--------------------------------------------------------------------------------
-- Target Selection
--------------------------------------------------------------------------------

local function getTargetPriority(targetId, debuffType, settings)
    local me = mq.TLO.Me
    local myId = me and me.ID and me.ID() or 0

    -- Priority: Higher = more urgent
    local priority = 50

    -- Self gets priority if CurePrioritySelf is enabled
    if targetId == myId and settings.CurePrioritySelf == true then
        priority = priority + 100
    end

    -- Lower HP = higher priority
    local spawn = mq.TLO.Spawn(targetId)
    if spawn and spawn() then
        local hp = spawn.PctHPs and tonumber(spawn.PctHPs()) or 100
        priority = priority + (100 - hp)  -- Lower HP adds more priority

        -- Tanks get higher priority
        local class = spawn.Class and spawn.Class.ShortName and spawn.Class.ShortName() or ''
        class = tostring(class):upper()
        if class == 'WAR' or class == 'PAL' or class == 'SHD' then
            priority = priority + 50
        end

        -- Healers get moderate priority
        if class == 'CLR' or class == 'DRU' or class == 'SHM' then
            priority = priority + 25
        end
    end

    -- Disease/Poison tend to be more dangerous, prioritize them
    if debuffType == 'Disease' or debuffType == 'Poison' then
        priority = priority + 10
    end

    return priority
end

function M.getBestCureTarget(settings)
    settings = settings or {}
    local Core = getCore()
    if not Core or not Core.Settings then
        settings = settings
    else
        -- Merge with Core.Settings
        for k, v in pairs(Core.Settings) do
            if settings[k] == nil then
                settings[k] = v
            end
        end
    end

    -- Scan group for debuffs
    local allDebuffs = scanGroupForDebuffs()
    if not next(allDebuffs) then return nil end

    local candidates = {}

    for targetId, debuffs in pairs(allDebuffs) do
        for debuffType, debuffList in pairs(debuffs) do
            -- Can we cure this type?
            if _state.canCure[debuffType] then
                -- Is it claimed by someone else?
                if not M.isCureClaimed(targetId, debuffType) then
                    -- Was it recently cured?
                    if not M.wasRecentlyCured(targetId, debuffType) then
                        -- Do we have a spell to cure it?
                        local cureSpell = getBestCureSpell(debuffType, false)
                        if cureSpell then
                            local priority = getTargetPriority(targetId, debuffType, settings)
                            table.insert(candidates, {
                                targetId = targetId,
                                debuffType = debuffType,
                                debuffCount = #debuffList,
                                cureSpell = cureSpell,
                                priority = priority,
                            })
                        end
                    end
                end
            end
        end
    end

    -- Sort by priority (highest first)
    table.sort(candidates, function(a, b)
        return a.priority > b.priority
    end)

    return candidates[1]
end

--------------------------------------------------------------------------------
-- Cure Casting
--------------------------------------------------------------------------------

local function canCureNow(settings)
    local me = mq.TLO.Me
    if not (me and me()) then return false end

    -- Check if curing is enabled
    if settings.DoCures ~= true then return false end

    -- Check combat setting
    local Cache = getRuntimeCache()
    local inCombat = Cache and Cache.inCombat and Cache.inCombat() or false
    if inCombat and settings.CureInCombat ~= true then
        return false
    end

    -- Not if moving
    if Cache and Cache.me and Cache.me.moving == true then return false end

    -- Not if dead
    if me.Hovering and me.Hovering() then return false end

    -- Not if already casting (Casting() returns spell name string, empty if not)
    local casting = me.Casting() or ''
    if casting ~= '' then return false end

    -- Not if spell engine is busy
    local SpellEngine = getSpellEngine()
    if SpellEngine and SpellEngine.isBusy and SpellEngine.isBusy() then
        return false
    end

    return true
end

function M.castCure(targetId, debuffType, cureSpell)
    if not targetId or targetId == 0 then return false, 'no_target' end
    if not debuffType or debuffType == '' then return false, 'no_debuff_type' end
    if not cureSpell or cureSpell == '' then return false, 'no_cure_spell' end

    local SpellEngine = getSpellEngine()
    if not SpellEngine or not SpellEngine.cast then
        return false, 'no_spell_engine'
    end

    -- Claim the cure
    if not claimCure(targetId, debuffType) then
        return false, 'already_claimed'
    end

    -- Cast the cure
    local success, reason = SpellEngine.cast(cureSpell, targetId, {
        spellCategory = 'cure',
        maxRetries = 2,
    })

    if success then
        _state.lastCureCastAt = os.clock()

        -- Track local cure
        _state.recentCures[targetId] = _state.recentCures[targetId] or {}
        _state.recentCures[targetId][debuffType] = {
            curedAt = os.clock(),
            curer = _state.selfName,
        }

        -- Broadcast that we cured
        broadcastCureLanded(targetId, debuffType, cureSpell)

        -- Release claim
        releaseClaim(targetId, debuffType)
    else
        -- Release claim on failure
        releaseClaim(targetId, debuffType)
    end

    return success, reason
end

--------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------

local function cleanupExpired()
    local now = os.clock()

    -- Clean expired local claims
    for targetId, claims in pairs(_state.localClaims) do
        for debuffType, data in pairs(claims) do
            if (now - data.claimedAt) >= CLAIM_TIMEOUT then
                claims[debuffType] = nil
            end
        end
        if not next(claims) then
            _state.localClaims[targetId] = nil
        end
    end

    -- Clean expired remote claims
    for targetId, claims in pairs(_state.remoteClaims) do
        for debuffType, data in pairs(claims) do
            if (now - data.claimedAt) >= CLAIM_TIMEOUT then
                claims[debuffType] = nil
            end
        end
        if not next(claims) then
            _state.remoteClaims[targetId] = nil
        end
    end

    -- Clean expired recent cures
    for targetId, cures in pairs(_state.recentCures) do
        for debuffType, data in pairs(cures) do
            if (now - data.curedAt) >= RECENT_CURE_WINDOW then
                cures[debuffType] = nil
            end
        end
        if not next(cures) then
            _state.recentCures[targetId] = nil
        end
    end
end

--------------------------------------------------------------------------------
-- Main Tick
--------------------------------------------------------------------------------

function M.tick(settings)
    if not _state.initialized then
        M.init()
    end

    local now = os.clock()
    if (now - _state.lastTick) < TICK_INTERVAL then
        return false
    end
    _state.lastTick = now

    -- Cleanup expired data
    cleanupExpired()

    -- Get settings
    local Core = getCore()
    settings = settings or (Core and Core.Settings) or {}

    -- Check if we can cure right now
    if not canCureNow(settings) then
        return false
    end

    -- Don't spam cures too fast
    if (now - _state.lastCureCastAt) < 1.5 then
        return false
    end

    -- Find best cure target
    local target = M.getBestCureTarget(settings)
    if not target then
        return false
    end

    -- Cast the cure
    local success, reason = M.castCure(target.targetId, target.debuffType, target.cureSpell)

    return success
end

--------------------------------------------------------------------------------
-- Query Functions
--------------------------------------------------------------------------------

function M.isInitialized()
    return _state.initialized
end

function M.canCureType(debuffType)
    return _state.canCure[debuffType] == true
end

function M.getTrackedDebuffs()
    return scanGroupForDebuffs()
end

function M.getCureCapabilities()
    return _state.canCure
end

function M.getClassName()
    return _state.classShort
end

return M
