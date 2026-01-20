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

-- Lazy-load DamageAttribution
local DamageAttribution = nil
local function getDamageAttribution()
    if DamageAttribution == nil then
        local ok, da = pcall(require, 'healing.damage_attribution')
        DamageAttribution = ok and da or false
    end
    return DamageAttribution or nil
end

-- Mob HP tracking for TTK calculation
local _mobSnapshots = {}  -- mobId -> { snapshots = [{hpPct, time}], name }

local _state = {
    fightPhase = 'none',
    inCombat = false,
    survivalMode = false,
    highPressure = false,
    avgMobHP = 100,
    estimatedTTK = 999,
    activeMobCount = 0,
    totalMobCount = 0,
    mezzedMobCount = 0,
    totalIncomingDps = 0,
    tankDpsPct = 0,
}

local _lastUpdate = 0
local UPDATE_INTERVAL = 0.5
local _lastLoggedState = nil

function M.init(config, targetMonitor)
    Config = config
    TargetMonitor = targetMonitor
    _mobSnapshots = {}
end

function M.getState()
    return _state
end

-- Record a mob's HP% snapshot for TTK calculation
local function recordMobHP(mobId, mobName, hpPct)
    if not mobId or mobId == 0 then return end

    if not _mobSnapshots[mobId] then
        _mobSnapshots[mobId] = {
            name = mobName,
            snapshots = {},
        }
    end

    local now = mq.gettime()
    local data = _mobSnapshots[mobId]

    -- Add snapshot
    table.insert(data.snapshots, {
        hpPct = hpPct,
        time = now,
    })

    -- Keep only last 30 seconds of snapshots
    local cutoff = now - 30
    while #data.snapshots > 1 and data.snapshots[1].time < cutoff do
        table.remove(data.snapshots, 1)
    end
end

-- Calculate time-to-kill for a mob based on HP% decline rate
-- Returns TTK in seconds, or nil if can't estimate
local function getMobTTK(mobId)
    local data = _mobSnapshots[mobId]
    if not data or #data.snapshots < 2 then
        return nil
    end

    local windowSec = (Config and Config.ttkWindowSec) or 5
    local now = mq.gettime()
    local cutoff = now - windowSec

    -- Collect samples within the window
    local samples = {}
    for _, snap in ipairs(data.snapshots) do
        if snap.time >= cutoff then
            table.insert(samples, snap)
        end
    end

    if #samples < 2 then
        return nil
    end

    -- Calculate HP% loss rate, filtering upward jumps (heals/regen)
    local totalHpLoss = 0
    local totalTime = 0

    for i = 2, #samples do
        local prev = samples[i - 1]
        local curr = samples[i]
        local hpDelta = prev.hpPct - curr.hpPct
        local timeDelta = curr.time - prev.time

        -- Only count HP decreases (ignore heals, regen)
        if hpDelta > 0 and timeDelta > 0 then
            -- Clamp outliers: ignore if HP dropped more than 20% in 1 second (likely target swap)
            local hpLossRate = hpDelta / timeDelta
            if hpLossRate <= 20 then
                totalHpLoss = totalHpLoss + hpDelta
                totalTime = totalTime + timeDelta
            end
        end
    end

    if totalTime <= 0 or totalHpLoss <= 0 then
        return nil
    end

    local hpLossPerSec = totalHpLoss / totalTime
    local currentHpPct = samples[#samples].hpPct

    -- TTK = remaining HP% / smoothed loss rate
    return currentHpPct / hpLossPerSec
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
            if targetType:lower():find('hater') then
                local id = xt.ID()
                local name = xt.CleanName and xt.CleanName() or 'Unknown'
                local pctHP = tonumber(xt.PctHPs()) or 100
                local mezzed = xt.Mezzed and xt.Mezzed() or false

                -- Record HP snapshot for TTK tracking
                recordMobHP(id, name, pctHP)

                table.insert(mobs, {
                    id = id,
                    name = name,
                    pctHP = pctHP,
                    mezzed = mezzed,
                })
            end
        end
    end

    -- Clean up dead/gone mobs from snapshots
    local activeMobIds = {}
    for _, mob in ipairs(mobs) do
        activeMobIds[mob.id] = true
    end
    for mobId in pairs(_mobSnapshots) do
        if not activeMobIds[mobId] then
            _mobSnapshots[mobId] = nil
        end
    end

    return mobs
end

-- Estimate fight duration using average TTK of non-near-dead mobs
local function estimateFightDuration(mobs)
    if #mobs == 0 then
        return 999, 'none'
    end

    local nearDeadPct = (Config and Config.nearDeadMobPct) or 10
    local startingPct = (Config and Config.fightPhaseStartingPct) or 70
    local endingPct = (Config and Config.fightPhaseEndingPct) or 25
    local endingTTK = (Config and Config.fightPhaseEndingTTK) or 20

    local totalHP = 0
    local totalTTK = 0
    local ttkCount = 0
    local hpCount = 0

    for _, mob in ipairs(mobs) do
        -- Include all mobs above near-dead threshold in TTK (mezzed mobs will be fought eventually)
        -- Mezzed status only affects pressure detection, not fight duration
        if mob.pctHP > nearDeadPct then
            totalHP = totalHP + mob.pctHP
            hpCount = hpCount + 1

            -- Try to get actual TTK from HP tracking (mezzed mobs won't have decline data yet)
            local ttk = getMobTTK(mob.id)
            if ttk and ttk > 0 then
                totalTTK = totalTTK + ttk
                ttkCount = ttkCount + 1
            elseif mob.mezzed then
                -- Mezzed mob with no TTK data - estimate from HP% (will be fought later)
                local estimatedTTK = mob.pctHP * 0.5  -- Rough estimate
                totalTTK = totalTTK + estimatedTTK
                ttkCount = ttkCount + 1
            end
        end
    end

    local avgHP = hpCount > 0 and (totalHP / hpCount) or 0
    local estimatedTTK

    if ttkCount > 0 then
        -- Use average TTK from HP decline tracking
        estimatedTTK = totalTTK / ttkCount
    else
        -- Fallback: rough estimate from HP% (assume ~2% HP/sec)
        estimatedTTK = avgHP * 0.5
    end

    -- Determine fight phase
    local phase
    if hpCount == 0 then
        phase = 'none'
        estimatedTTK = 999
    elseif avgHP > startingPct then
        phase = 'starting'
    elseif avgHP < endingPct or estimatedTTK < endingTTK then
        phase = 'ending'
    else
        phase = 'mid'
    end

    return estimatedTTK, phase, avgHP
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
    local tankFullPct = (Config and Config.survivalModeTankFullPct) or 90
    local survivalDpsPct = (Config and Config.survivalModeDpsPct) or 5

    return dpsPct >= survivalDpsPct and tank.pctHP < tankFullPct
end

-- Check if we're in high pressure situation
local function checkHighPressure(totalDps)
    local minDps = (Config and Config.highPressureMinDps) or 3000

    -- Primary check: Total incoming DPS to group
    if totalDps >= minDps then
        return true
    end

    local da = getDamageAttribution()
    if not da then
        return false
    end

    -- Check if tank is being swarmed (actively hit by multiple sources)
    if TargetMonitor then
        local targets = TargetMonitor.getAllTargets()
        for _, target in pairs(targets) do
            if target.role == 'tank' then
                local attrInfo = da.getTargetDamageInfo(target.id)
                if attrInfo.sourceCount >= 3 then
                    return true
                end
                break
            end
        end
    end

    -- Check for active AE damage hitting group
    if da.hasActiveAE() then
        return true
    end

    return false
end

local function countMobs(mobs)
    local active = 0
    local mezzed = 0
    for _, mob in ipairs(mobs) do
        if mob.mezzed then
            mezzed = mezzed + 1
        else
            active = active + 1
        end
    end
    return active, mezzed, #mobs
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
    local now = mq.gettime()
    if (now - _lastUpdate) < UPDATE_INTERVAL then return end
    _lastUpdate = now

    local mobs = getXTargetData()

    _state.activeMobCount, _state.mezzedMobCount, _state.totalMobCount = countMobs(mobs)
    _state.inCombat = _state.activeMobCount > 0
    _state.estimatedTTK, _state.fightPhase, _state.avgMobHP = estimateFightDuration(mobs)
    _state.totalIncomingDps = calcTotalIncomingDps()
    _state.survivalMode = checkSurvivalMode()
    _state.highPressure = checkHighPressure(_state.totalIncomingDps)

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

    -- Log combat state changes
    local stateKey = string.format('%s_%s_%s_%s_%d',
        _state.fightPhase, tostring(_state.inCombat), tostring(_state.survivalMode),
        tostring(_state.highPressure), _state.activeMobCount)
    if stateKey ~= _lastLoggedState then
        local log = getLogger()
        if log and log.logCombatState then
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

-- Check if high pressure (multiple mobs or high DPS)
function M.isHighPressure()
    return _state.highPressure, _state.activeMobCount, _state.totalIncomingDps
end

-- Check if HoT should be allowed based on fight state
-- Returns: allowed (bool), reason (string)
function M.shouldAllowHot(hotDurationSec)
    hotDurationSec = hotDurationSec or 36

    -- Block HoTs when not in combat
    if _state.activeMobCount == 0 or _state.fightPhase == 'none' then
        return false, 'no_combat'
    end

    -- Don't start new HoT if fight is ending (damage will cease soon)
    if _state.fightPhase == 'ending' then
        return false, 'fight_ending'
    end

    -- Check if fight will last long enough for HoT to be useful
    local minEfficiency = (Config and Config.hotMinFightDurationPct) or 50
    local minDuration = hotDurationSec * (minEfficiency / 100)

    if _state.estimatedTTK < minDuration then
        return false, string.format('ttk_too_short|ttk=%.0f<min=%.0f', _state.estimatedTTK, minDuration)
    end

    return true, 'ok'
end

-- Check if Promised heal should be allowed based on fight duration and tank state
function M.shouldAllowPromised(assessment, tankPct)
    if not assessment then return true, nil end

    local promisedDelay = (Config and Config.promisedDelaySeconds) or 18
    local buffer = (Config and Config.promisedDurationBuffer) or 5
    local minDuration = promisedDelay + buffer

    if assessment.fightPhase == 'ending' then
        return false, 'promised_blocked_ending'
    end

    if (assessment.estimatedTTK or 0) < minDuration then
        return false, string.format('promised_blocked_ttk|ttk=%.0f<min=%d', assessment.estimatedTTK or 0, minDuration)
    end

    local currentTankPct = tankPct or assessment.tankPct or 100
    local safetyFloor = M.getPromisedSafetyFloor()
    if currentTankPct < safetyFloor then
        return false, string.format('promised_blocked_floor|tankPct=%.0f<floor=%d', currentTankPct, safetyFloor)
    end

    return true, nil
end

function M.getPromisedSafetyFloor()
    local baseSafetyFloor = (Config and Config.promisedSafetyFloorPct) or 35
    local survivalSafetyFloor = (Config and Config.promisedSurvivalSafetyFloorPct) or 55
    if _state and _state.survivalMode then
        return survivalSafetyFloor
    end
    return baseSafetyFloor
end

-- Backward/DeficitHealer-style aliases
M.ShouldAllowPromised = M.shouldAllowPromised
M.GetPromisedSafetyFloor = M.getPromisedSafetyFloor

-- Get the spell duration in seconds from MQ
function M.getSpellDuration(spellName)
    if not spellName then return 0 end

    local spell = mq.TLO.Spell(spellName)
    if not spell or not spell() then return 0 end

    -- MyDuration returns tick count for the player's version of the spell
    local mySpell = mq.TLO.Me.Spell(spellName)
    local ticks = 0
    if mySpell and mySpell() and mySpell.MyDuration then
        ticks = tonumber(mySpell.MyDuration()) or 0
    end
    if ticks <= 0 and spell.Duration then
        ticks = tonumber(spell.Duration()) or 0
    end

    -- Duration in seconds = ticks * 6 (HoTs tick every 6 seconds)
    return ticks * 6
end

return M
