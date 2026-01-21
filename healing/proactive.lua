-- healing/proactive.lua
local mq = require('mq')

local M = {}

---@class HealingConfig
---@field groupHealMinCount number|nil
---@field hotEnabled boolean|nil
---@field emergencyPct number|nil
---@field duckHotThreshold number|nil
---@field hotMinFightDurationPct number|nil
---@field hotMinCoverageRatio number|nil
---@field hotUselessRatio number|nil
---@field hotRefreshWindowPct number|nil
---@field promisedSafetyFloorPct number|nil
---@field promisedSurvivalSafetyFloorPct number|nil

---@type HealingConfig
local Config = nil
local HealTracker = nil
local TargetMonitor = nil
local CombatAssessor = nil

-- Lazy-load ActorsCoordinator for peer HoT tracking
local ActorsCoordinator = nil
local function getActorsCoordinator()
    if ActorsCoordinator == nil then
        local ok, ac = pcall(require, 'utils.actors_coordinator')
        ActorsCoordinator = ok and ac or false
    end
    return ActorsCoordinator or nil
end

-- Track active HoTs we've applied
local _activeHoTs = {}  -- [targetName] = { spell, castTime, duration, expireTime }
local _activePromised = {}  -- [targetName] = { spell, castTime, delay, landingTime, expireTime, expectedHeal }

local function resolveTargetName(targetIdOrName)
    if not targetIdOrName then return nil end
    if type(targetIdOrName) == 'string' then
        return targetIdOrName
    end
    local id = tonumber(targetIdOrName) or 0
    if id <= 0 then return nil end
    local spawn = mq.TLO.Spawn(id)
    if spawn and spawn() then
        return spawn.CleanName() or spawn.Name()
    end
    return nil
end

function M.init(config, healTracker, targetMonitor, combatAssessor)
    Config = config
    HealTracker = healTracker
    TargetMonitor = targetMonitor
    CombatAssessor = combatAssessor
end

function M.recordHoT(targetIdOrName, spellName, duration)
    local targetName = resolveTargetName(targetIdOrName)
    if not targetName then return end
    local now = mq.gettime()
    _activeHoTs[targetName] = {
        spell = spellName,
        castTime = now,
        duration = duration or 18,
        expireTime = now + (duration or 18),
    }
end

function M.GetHotData(targetName)
    return _activeHoTs[targetName]
end

-- Check if target actually has the HoT buff on them (via MQ)
-- NOTE: Player-cast HoTs appear in the Song window, not Buff window
local function targetHasHoTBuff(targetId, hotSpellName)
    if not targetId or not hotSpellName then return false end

    -- Get target spawn
    local spawn = mq.TLO.Spawn(targetId)
    if not spawn or not spawn() then return false end

    local targetName = spawn.CleanName() or spawn.Name()
    if not targetName then return false end

    -- Check if it's us
    local myName = mq.TLO.Me.CleanName() or mq.TLO.Me.Name()
    if targetName == myName then
        -- HoTs go in the Song window for the player
        local song = mq.TLO.Me.Song(hotSpellName)
        if song and song() and song.ID() then
            ---@diagnostic disable-next-line: undefined-field
            return true, song.Duration and song.Duration.TotalSeconds and tonumber(song.Duration.TotalSeconds()) or 0
        end
        -- Also check buff window as fallback (some HoTs might be there)
        local buff = mq.TLO.Me.Buff(hotSpellName)
        if buff and buff() and buff.ID() then
            ---@diagnostic disable-next-line: undefined-field
            return true, buff.Duration and buff.Duration.TotalSeconds and tonumber(buff.Duration.TotalSeconds()) or 0
        end
        return false
    end

    -- For group members, use Group.Member buff checking
    -- Group member buffs include both buff and song windows
    local groupCount = tonumber(mq.TLO.Group.Members()) or 0
    for i = 1, groupCount do
        local member = mq.TLO.Group.Member(i)
        if member and member() then
            local memberName = member.CleanName() or member.Name()
            if memberName and memberName == targetName then
                -- Check member's buffs (includes songs for group members)
                local buff = member.Buff(hotSpellName)
                if buff and buff() and buff.ID() then
                    ---@diagnostic disable-next-line: undefined-field
                    return true, buff.Duration and buff.Duration.TotalSeconds and tonumber(buff.Duration.TotalSeconds()) or 0
                end
                return false
            end
        end
    end

    return false
end

function M.hasActiveHoT(targetIdOrName)
    local targetName = resolveTargetName(targetIdOrName)
    if not targetName then return false end

    local now = mq.gettime()
    local data = _activeHoTs[targetName]
    if data and data.expireTime and data.expireTime > now then
        local hasBuff = true
        local remaining = data.expireTime - now
        return hasBuff, data.spell, remaining
    end

    -- Check peer-reported HoTs via actors (if available)
    local ac = getActorsCoordinator()
    if ac and ac.getHoTStates then
        local spawn = mq.TLO.Spawn('pc ' .. targetName)
        local tid = spawn and spawn() and spawn.ID and tonumber(spawn.ID()) or 0
        local perTarget = tid > 0 and ac.getHoTStates()[tid] or nil
        if perTarget then
            local best = 0
            local bestSpell = nil
            for _, info in pairs(perTarget) do
                local exp = tonumber(info.expiresAt) or 0
                local rem = exp - now
                if rem > best then
                    best = rem
                    bestSpell = info.spellName or bestSpell
                end
            end
            if best > 0 then
                return true, bestSpell or 'unknown', best
            end
        end
    end

    return false
end

function M.HasActiveHot(targetIdOrName)
    return M.hasActiveHoT(targetIdOrName)
end

function M.shouldRefreshHoT(targetIdOrName, hotSpellName)
    -- First check if target actually has the buff
    local targetName = resolveTargetName(targetIdOrName)
    if not targetName then return false end
    local spawn = mq.TLO.Spawn('pc ' .. targetName)
    local targetId = spawn and spawn() and spawn.ID and tonumber(spawn.ID()) or 0
    local hasBuff, buffRemaining = targetHasHoTBuff(targetId, hotSpellName)
    if not hasBuff then
        -- Fallback: use cached/peer-reported remaining time if buff lookup failed
        local now = mq.gettime()
        local bestRemaining = 0

        local data = _activeHoTs[targetName]
        if data and data.expireTime and data.expireTime > now then
            bestRemaining = math.max(bestRemaining, data.expireTime - now)
        end

        local ac = getActorsCoordinator()
        if ac and ac.getHoTStates and targetId > 0 then
            local perTarget = ac.getHoTStates()[targetId]
            if perTarget then
                for _, info in pairs(perTarget) do
                    local exp = tonumber(info.expiresAt) or 0
                    local rem = exp - now
                    if rem > bestRemaining then bestRemaining = rem end
                end
            end
        end

        if bestRemaining > 0 then
            local refreshPct = Config and Config.hotRefreshWindowPct or 0
            if refreshPct <= 0 then
                return false
            end
            local spell = mq.TLO.Spell(hotSpellName)
            local duration = 0
            if spell and spell() and spell.Duration and spell.Duration.TotalSeconds then
                duration = tonumber(spell.Duration.TotalSeconds()) or 0
            end
            if duration > 0 then
                local remainingPct = (bestRemaining / duration) * 100
                return remainingPct <= refreshPct
            end
            return false
        end

        -- No known HoT remaining, safe to cast
        return true
    end

    -- Buff is on target - check if we should refresh based on remaining duration
    local remaining = buffRemaining or 0
    if remaining <= 0 then return true end

    -- Check refresh window from config
    local refreshPct = Config and Config.hotRefreshWindowPct or 0
    if refreshPct <= 0 then return false end  -- Wait until expired

    -- Get spell duration to calculate percentage remaining
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

function M.ShouldRefreshHot(targetIdOrName, hotSpellName)
    return M.shouldRefreshHoT(targetIdOrName, hotSpellName)
end

function M.getHotRemainingPct(targetIdOrName)
    local targetName = resolveTargetName(targetIdOrName)
    if not targetName then return 0 end
    local data = _activeHoTs[targetName]
    if not data or not data.duration or data.duration <= 0 then
        return 0
    end
    local now = mq.gettime()
    local elapsed = now - (data.castTime or now)
    local remaining = math.max(0, data.duration - elapsed)
    return (remaining / data.duration) * 100
end

function M.GetHotRemainingPct(targetIdOrName)
    return M.getHotRemainingPct(targetIdOrName)
end

function M.recordPromised(targetIdOrName, spellName, duration, expectedHeal, delaySeconds)
    local targetName = resolveTargetName(targetIdOrName)
    if not targetName then return end
    local now = os.time()
    local delay = delaySeconds or 18
    _activePromised[targetName] = {
        spell = spellName,
        castTime = now,
        delay = delay,
        landingTime = now + delay,
        expireTime = now + (duration or 18),
        expectedHeal = expectedHeal or 0,
    }
end

function M.hasActivePromised(targetIdOrName)
    local targetName = resolveTargetName(targetIdOrName)
    if not targetName then return false end
    local data = _activePromised[targetName]
    return data and data.expireTime and data.expireTime > os.time() or false
end

function M.getPromisedLandingInfo(targetIdOrName)
    local targetName = resolveTargetName(targetIdOrName)
    if not targetName then return nil end
    local data = _activePromised[targetName]
    if not data then return nil end

    local now = os.time()
    if now >= (data.landingTime or 0) then
        return nil
    end

    local timeRemaining = (data.landingTime or 0) - now
    return {
        timeRemaining = timeRemaining,
        expectedHeal = data.expectedHeal or 0,
        spell = data.spell,
        landingTime = data.landingTime,
    }
end

function M.GetPromisedLandingInfo(targetIdOrName)
    return M.getPromisedLandingInfo(targetIdOrName)
end

function M.getHotHealingInWindow(targetIdOrName, windowSec)
    local targetName = resolveTargetName(targetIdOrName)
    if not targetName then return 0 end
    local data = _activeHoTs[targetName]
    if not data then return 0 end

    local tracker = HealTracker
    if not tracker then return 0 end

    local hpPerTick = tracker.getExpected(data.spell, 'tick') or 0
    if hpPerTick <= 0 then return 0 end

    local now = os.time()
    local elapsed = now - (data.castTime or now)
    local remaining = math.max(0, (data.duration or 0) - elapsed)
    local tickInterval = 6
    local windowRemaining = math.min(windowSec or 0, remaining)
    local ticksInWindow = math.floor(windowRemaining / tickInterval)
    return ticksInWindow * hpPerTick
end

function M.GetHotHealingInWindow(targetIdOrName, windowSec)
    return M.getHotHealingInWindow(targetIdOrName, windowSec)
end

function M.getIncomingHotRemaining(targetIdOrName)
    local targetName = resolveTargetName(targetIdOrName)
    if not targetName then return 0 end

    local total = 0
    local now = mq.gettime()

    -- Prefer spell_events pending HoT ledger when available
    local okSe, se = pcall(require, 'healing.spell_events')
    if okSe and se and se.getIncomingHotRemaining then
        local pendingTotal = 0
        local pendingDetails = nil
        pendingTotal, pendingDetails = se.getIncomingHotRemaining(targetName)
        if pendingTotal and pendingTotal > 0 then
            total = total + pendingTotal
        end
    end

    local function addRemaining(spellName, expiresAt, castTime, duration)
        if not spellName then return end
        local remaining = 0
        if expiresAt and expiresAt > now then
            remaining = expiresAt - now
        elseif castTime and duration then
            local elapsed = now - castTime
            remaining = math.max(0, duration - elapsed)
        end
        if remaining <= 0 then return end

        local tick = HealTracker and HealTracker.getExpected(spellName, 'tick') or 0
        if tick <= 0 then
            local spell = mq.TLO.Spell(spellName)
            if spell and spell() then
                ---@diagnostic disable-next-line: undefined-field
                local calcVal = tonumber(spell.Calc and spell.Calc(1) and spell.Calc(1)()) or 0
                if calcVal > 0 then
                    tick = math.abs(calcVal)
                end
            end
        end
        if tick <= 0 then return end

        local ticksRemaining = math.floor(remaining / 6)
        if ticksRemaining <= 0 then return end
        total = total + (tick * ticksRemaining)
    end

    local data = _activeHoTs[targetName]
    if data then
        addRemaining(data.spell, data.expireTime, data.castTime, data.duration)
    end

    local ac = getActorsCoordinator()
    if ac and ac.getHoTStates then
        local spawn = mq.TLO.Spawn('pc ' .. targetName)
        local tid = spawn and spawn() and spawn.ID and tonumber(spawn.ID()) or 0
        local perTarget = tid > 0 and ac.getHoTStates()[tid] or nil
        if perTarget then
            for _, info in pairs(perTarget) do
                addRemaining(info.spellName, info.expiresAt)
            end
        end
    end

    return total
end

function M.GetIncomingHotRemaining(targetIdOrName)
    return M.getIncomingHotRemaining(targetIdOrName)
end

-- Calculate projected HP considering HoT + Promised + incoming DPS
function M.CalculateProjectedHP(targetInfo, promisedInfo)
    if not promisedInfo or not promisedInfo.timeRemaining then
        return nil
    end

    local windowSec = promisedInfo.timeRemaining
    local currentHP = targetInfo.currentHP or 0
    local maxHP = targetInfo.maxHP or 1
    local dps = targetInfo.recentDps or 0

    local expectedDamage = dps * windowSec
    local hotHealing = M.GetHotHealingInWindow(targetInfo.name, windowSec)
    local promisedHealing = promisedInfo.expectedHeal or 0

    local projectedHP = currentHP - expectedDamage + hotHealing + promisedHealing
    projectedHP = math.min(projectedHP, maxHP)
    projectedHP = math.max(projectedHP, 0)

    local projectedPct = (projectedHP / maxHP) * 100

    local details = string.format(
        'projHP=%.0f projPct=%.1f curHP=%.0f dmg=%.0f hotHeal=%.0f promHeal=%.0f window=%ds',
        projectedHP, projectedPct, currentHP, expectedDamage, hotHealing, promisedHealing, windowSec
    )

    return {
        projectedHP = projectedHP,
        projectedPct = projectedPct,
        expectedDamage = expectedDamage,
        hotHealing = hotHealing,
        promisedHealing = promisedHealing,
        windowSec = windowSec,
        details = details,
    }
end

-- Check if it's safe to wait for Promised
function M.IsSafeToWaitForPromised(targetInfo)
    if not targetInfo then return false, nil end

    local promisedInfo = M.GetPromisedLandingInfo(targetInfo.name)
    if not promisedInfo then
        return false, nil
    end

    local projection = M.CalculateProjectedHP(targetInfo, promisedInfo)
    if not projection then
        return false, nil
    end

    local safetyFloorPct = (CombatAssessor and CombatAssessor.GetPromisedSafetyFloor and CombatAssessor.GetPromisedSafetyFloor())
        or (Config and Config.promisedSafetyFloorPct or 35)

    local minHPDuringWait = (targetInfo.currentHP or 0) - projection.expectedDamage + projection.hotHealing
    local minPctDuringWait = ((targetInfo.maxHP or 1) > 0) and (minHPDuringWait / targetInfo.maxHP * 100) or 0

    local isSafe = minPctDuringWait >= safetyFloorPct

    projection.minHPDuringWait = minHPDuringWait
    projection.minPctDuringWait = minPctDuringWait
    projection.safetyFloorPct = safetyFloorPct
    projection.isSafe = isSafe
    projection.details = projection.details .. string.format(
        ' minPct=%.1f safetyFloor=%d%% safe=%s timeToLand=%ds',
        minPctDuringWait, safetyFloorPct, tostring(isSafe), promisedInfo.timeRemaining or 0
    )

    return isSafe, projection
end

-- Group HoT selection (DeficitHealer behavior)
function M.ShouldApplyGroupHot(targets, situation)
    if Config and Config.hotEnabled == false then
        return false, nil, nil, nil
    end

    if situation and situation.hasEmergency then
        return false, nil, nil, nil
    end

    local hurtCount = 0
    local totalDeficit = 0
    for _, t in ipairs(targets or {}) do
        if t.deficit and t.deficit > 0 then
            hurtCount = hurtCount + 1
            totalDeficit = totalDeficit + t.deficit
        end
    end

    local cfg = Config or {}
    if hurtCount < (cfg.groupHealMinCount or 2) then
        return false, nil, nil, nil
    end

    local selector = nil
    local ok, hs = pcall(require, 'healing.heal_selector')
    if ok then selector = hs end

    if selector and selector.SelectBestGroupHot then
        local best = selector.SelectBestGroupHot(targets, totalDeficit, hurtCount)
        if best then
            return true, best, totalDeficit, best.targets or hurtCount
        end
    end

    return false, nil, nil, nil
end

function M.calculateProjectedHP(targetInfo, promisedInfo)
    if not promisedInfo or not promisedInfo.timeRemaining then
        return nil
    end

    local windowSec = promisedInfo.timeRemaining
    local currentHP = targetInfo.currentHP or 0
    local maxHP = targetInfo.maxHP or 1
    local dps = targetInfo.recentDps or 0

    local expectedDamage = dps * windowSec
    local hotHealing = M.getHotHealingInWindow(targetInfo.name, windowSec)
    local promisedHealing = promisedInfo.expectedHeal or 0

    local projectedHP = currentHP - expectedDamage + hotHealing + promisedHealing
    projectedHP = math.min(projectedHP, maxHP)
    projectedHP = math.max(projectedHP, 0)

    local projectedPct = (projectedHP / maxHP) * 100
    local details = string.format(
        'projHP=%.0f projPct=%.1f curHP=%.0f dmg=%.0f hotHeal=%.0f promHeal=%.0f window=%ds',
        projectedHP, projectedPct, currentHP, expectedDamage, hotHealing, promisedHealing, windowSec
    )

    return {
        projectedHP = projectedHP,
        projectedPct = projectedPct,
        expectedDamage = expectedDamage,
        hotHealing = hotHealing,
        promisedHealing = promisedHealing,
        windowSec = windowSec,
        details = details,
    }
end

function M.isSafeToWaitForPromised(targetInfo)
    if not Config then return false, nil end

    local promisedInfo = M.getPromisedLandingInfo(targetInfo.name)
    if not promisedInfo then return false, nil end

    local projection = M.calculateProjectedHP(targetInfo, promisedInfo)
    if not projection then return false, nil end

    local safetyFloorPct = (Config and Config.promisedSafetyFloorPct) or 35
    local combatState = CombatAssessor and CombatAssessor.getState and CombatAssessor.getState() or {}
    if combatState and combatState.survivalMode then
        safetyFloorPct = (Config and Config.promisedSurvivalSafetyFloorPct) or safetyFloorPct
    end
    local minHPDuringWait = (targetInfo.currentHP or 0) - projection.expectedDamage + projection.hotHealing
    local minPctDuringWait = ((targetInfo.maxHP or 1) > 0) and (minHPDuringWait / targetInfo.maxHP * 100) or 0

    local isSafe = minPctDuringWait >= safetyFloorPct

    projection.minHPDuringWait = minHPDuringWait
    projection.minPctDuringWait = minPctDuringWait
    projection.safetyFloorPct = safetyFloorPct
    projection.isSafe = isSafe
    projection.details = projection.details .. string.format(
        ' minPct=%.1f safetyFloor=%d%% safe=%s timeToLand=%ds',
        minPctDuringWait, safetyFloorPct, tostring(isSafe), promisedInfo.timeRemaining or 0
    )

    return isSafe, projection
end

function M.shouldApplyHoT(target, hotSpellName)
    if not Config or not Config.hotEnabled then
        return false, 'disabled'
    end

    -- No HoTs during emergency (cheap check first)
    if target.pctHP < (Config.emergencyPct or 25) then
        return false, 'emergency'
    end

    -- Don't cast HoT if target is above duck threshold (would just be ducked anyway)
    -- Use the HoT-specific duck threshold (defaults to 92%)
    local duckThreshold = Config.duckHotThreshold
    if duckThreshold == nil then duckThreshold = 92 end
    if target.pctHP >= duckThreshold then
        return false, string.format('above_duck_threshold|hp=%d>=thresh=%d', target.pctHP, duckThreshold)
    end

    -- Use HotAnalyzer for TTK and DPS ratio gates (expensive, run after cheap guards)
    local ok, HotAnalyzer = pcall(require, 'healing.hot_analyzer')
    if ok and HotAnalyzer and HotAnalyzer.shouldApplyHoT then
        local shouldApply, analysis, reason = HotAnalyzer.shouldApplyHoT(target, hotSpellName, nil)
        if not shouldApply then
            return false, reason
        end
        -- Analysis passed new gates, continue with existing checks
    end

    local combatState = CombatAssessor and CombatAssessor.getState() or {}

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
        -- No damage = no HoT. HoTs are for countering sustained damage, not topping off.
        return false, 'no_damage'
    end

    local coverageRatio = hotHps / incomingDps

    -- Multiple sources = more sustained damage pattern, HoT more valuable
    local sourceCount = target.sourceCount or 1
    if sourceCount >= 2 then
        coverageRatio = coverageRatio * 1.2  -- Effective 20% boost to coverage
    end

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
    for name, data in pairs(_activeHoTs) do
        if data.expireTime and data.expireTime <= now then
            _activeHoTs[name] = nil
        end
    end

    -- Clean promised heals
    local nowSec = os.time()
    for name, data in pairs(_activePromised) do
        if data.expireTime and data.expireTime <= nowSec then
            _activePromised[name] = nil
        end
    end
end

return M
