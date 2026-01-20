-- healing/target_monitor.lua
local mq = require('mq')

local M = {}

local Config = nil

-- Lazy-load DamageParser
local DamageParser = nil
local function getDamageParser()
    if DamageParser == nil then
        local ok, dp = pcall(require, 'healing.damage_parser')
        DamageParser = ok and dp or false
    end
    return DamageParser or nil
end

-- Lazy-load DamageAttribution
local DamageAttribution = nil
local function getDamageAttribution()
    if DamageAttribution == nil then
        local ok, da = pcall(require, 'healing.damage_attribution')
        DamageAttribution = ok and da or false
    end
    return DamageAttribution or nil
end

-- Target data cache
local _targets = {}
local _lastFullScan = 0

-- Rolling damage window (seconds) - updated from Config in init()
local DAMAGE_WINDOW_SEC = 6

-- DanNet max HP cache
local _remoteMaxHP = {}      -- { [charName] = maxHP }
local _remoteMaxHPAt = {}    -- { [charName] = lastQueryTime }
local _danNetObservers = {}  -- { [charName..propName] = true }
local _danNetAvailable = nil -- Cached DanNet availability

-- Check if DanNet plugin is available
local function isDanNetAvailable()
    if _danNetAvailable ~= nil then
        return _danNetAvailable
    end
    local dnPlugin = mq.TLO.Plugin('mq2dannet')
    _danNetAvailable = dnPlugin and dnPlugin.IsLoaded and dnPlugin.IsLoaded() == true
    return _danNetAvailable
end

-- Ensure DanNet observer is set up for a property
local function ensureDanNetObserver(charName, propName)
    if not charName or charName == '' then return end
    local key = charName .. '|' .. propName
    if _danNetObservers[key] then return end

    -- Set up observer via DanNet command
    mq.cmdf('/dobserve %s -q %s', charName, propName)
    _danNetObservers[key] = true
end

-- Get max HP from DanNet observer (cached)
local function getRemoteMaxHP(targetName)
    if not targetName or targetName == '' then
        return nil
    end

    local now = mq.gettime()
    local successTtl = 120000  -- Cache successful lookups for 2 minutes
    local failureTtl = 5000    -- Retry failed lookups every 5 seconds

    -- Check if we have a cached successful value
    local cachedValue = _remoteMaxHP[targetName]
    local lastAt = _remoteMaxHPAt[targetName] or 0
    local ttl = cachedValue and successTtl or failureTtl

    if (now - lastAt) < ttl then
        return cachedValue
    end

    -- Mark that we're attempting a lookup
    _remoteMaxHPAt[targetName] = now

    -- Check DanNet availability
    if not isDanNetAvailable() then
        return cachedValue
    end

    -- Query DanNet for Me.MaxHPs on the target character
    local propName = 'Me.MaxHPs'
    ensureDanNetObserver(targetName, propName)

    local rawVal = mq.TLO.DanNet(targetName).Observe(propName)()
    if rawVal == 'NULL' or rawVal == '' then
        return cachedValue
    end
    local num = tonumber(rawVal)
    if num and num > 0 then
        _remoteMaxHP[targetName] = num
        return num
    end

    -- Failed lookup - will retry in 5 seconds
    return cachedValue
end

function M.init(config)
    Config = config
    _targets = {}
    _remoteMaxHP = {}
    _remoteMaxHPAt = {}
    _danNetObservers = {}
    _danNetAvailable = nil  -- Re-check on init
    -- Update damage window from config
    if Config and Config.damageWindowSec then
        DAMAGE_WINDOW_SEC = Config.damageWindowSec
    end
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

    -- For non-targeted group members, CurrentHPs/MaxHPs return placeholder values (100/100)
    -- PctHPs is always accurate regardless of targeting
    local currentHP = tonumber(spawn.CurrentHPs()) or 0
    local maxHP = tonumber(spawn.MaxHPs()) or 1
    local pctHP = tonumber(spawn.PctHPs()) or 100

    -- Get target name for DanNet lookup
    local targetName = spawn.CleanName() or spawn.Name() or ''

    -- Try to get real MaxHP from DanNet observer (for other characters)
    local remoteMax = getRemoteMaxHP(targetName)

    -- For self, we can get MaxHP directly
    local fallbackMax = nil
    if targetName == mq.TLO.Me.Name() then
        fallbackMax = tonumber(mq.TLO.Me.MaxHPs()) or nil
    end

    -- Use DanNet value, then fallback, then spawn value
    local resolvedMax = remoteMax or fallbackMax
    if resolvedMax and resolvedMax > 0 then
        maxHP = resolvedMax
        -- If spawn returned placeholder values (100/100), calculate real currentHP from pctHP
        -- This is the key calculation: currentHP = (pctHP / 100) * maxHP
        if currentHP <= 100 then
            currentHP = math.floor((pctHP / 100) * maxHP)
        end
    elseif maxHP <= 1 and pctHP < 100 then
        -- Last resort fallback if no DanNet and spawn returned placeholder
        maxHP = 100000  -- Default estimate
        currentHP = math.floor(maxHP * pctHP / 100)
    end

    local deficit = maxHP - currentHP
    local classShort = spawn.Class and spawn.Class.ShortName and spawn.Class.ShortName() or ''
    classShort = classShort:upper()

    -- Track damage for DPS calculation using percentage changes
    -- This avoids issues when maxHP changes (e.g., DanNet kicking in)
    local recentDamage = existing.recentDamage or {}
    local prevPctHP = existing.pctHP or pctHP

    -- Only record damage if HP% dropped (not when maxHP changed causing currentHP to jump)
    if pctHP < prevPctHP then
        -- Calculate actual damage based on current maxHP
        local pctDrop = prevPctHP - pctHP
        local dmg = math.floor((pctDrop / 100) * maxHP)
        if dmg > 0 then
            table.insert(recentDamage, { time = now, amount = dmg })
        end
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

    -- Calculate DPS from HP delta window
    local totalDamage = 0
    for _, entry in ipairs(recentDamage) do
        totalDamage = totalDamage + entry.amount
    end
    local windowDuration = math.max(1, #recentDamage > 0 and (now - recentDamage[1].time) or DAMAGE_WINDOW_SEC)
    local hpDeltaDps = totalDamage / windowDuration

    -- Get log-based DPS
    local logDps = 0
    local dp = getDamageParser()
    if dp and dp.getLogDps then
        logDps = dp.getLogDps(spawnId)
    end

    -- Get attribution data if available
    local da = getDamageAttribution()
    local attrInfo = da and da.getTargetDamageInfo(spawnId) or nil
    local validation = da and da.validateDps(spawnId, hpDeltaDps) or nil

    -- Use attributed DPS when reliable, fall back to weighted combo when drifting
    local combinedDps
    if validation and validation.isReliable then
        combinedDps = attrInfo.totalDps
    else
        -- Fall back to weighted combo
        local hpDpsWeight = (Config and Config.hpDpsWeight ~= nil) and Config.hpDpsWeight or 0.6
        local attrDps = attrInfo and attrInfo.totalDps or logDps
        combinedDps = (hpDeltaDps * hpDpsWeight) + (attrDps * (1 - hpDpsWeight))
    end

    -- Statistical burst detection
    local burstDetected = false
    if dp and dp.checkBurst then
        burstDetected = dp.checkBurst(spawnId, combinedDps)
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
        recentDps = combinedDps,
        hpDeltaDps = hpDeltaDps,
        logDps = logDps,
        burstDetected = burstDetected,

        -- Attribution data
        sourceCount = attrInfo and attrInfo.sourceCount or 0,
        isMultiSource = attrInfo and attrInfo.isMultiSource or false,
        isInAE = attrInfo and attrInfo.isInAE or false,
        dpsValidation = validation,

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
        if member and member() and member.ID then
            local spawnId = member.ID()
            if spawnId and spawnId > 0 then
                local spawn = mq.TLO.Spawn(spawnId)
                if spawn and spawn() then
                    updateTargetData(spawnId, spawn)
                else
                    updateTargetData(spawnId, member)
                end
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

    local emergencyPct = (Config and Config.emergencyPct ~= nil) and Config.emergencyPct or 25

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
