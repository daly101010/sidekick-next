-- healing/heal_selector.lua
-- healing/heal_selector.lua (DeficitHealer logic)
local mq = require('mq')

local M = {}

---@class HealSelectorConfig
---@field spells table
---@field scoringPresets table|nil
---@field burstDpsScale number|nil
---@field critOverhealThreshold number|nil
---@field critOverhealPenalty number|nil
---@field smallHealPenalty number|nil
---@field maxOverhealRatio number|nil
---@field hotSupplementMinDps number|nil
---@field hotMinDps number|nil
---@field emergencyPct number|nil
---@field considerIncomingHot boolean|nil
---@field hotIncomingCoveragePct number|nil
---@field hotOverrideDpsPct number|nil
---@field hotEnabled boolean|nil
---@field hotMaxDeficitPct number|nil
---@field hotLearnMaxDeficitPct number|nil
---@field hotPreferUnderDps number|nil
---@field sustainedDamageThreshold number|nil
---@field hotMinDeficitPct number|nil
---@field nonSquishyHotMinDeficitPct number|nil
---@field lowPressureHotMinDeficitPct number|nil
---@field hotLearnForce boolean|nil
---@field hotTankOnly boolean|nil
---@field hotMinDpsForNonTank number|nil
---@field bigHotWithPromisedMinDps number|nil
---@field minHealPct number|nil
---@field nonSquishyMinHealPct number|nil
---@field lowPressureMinDeficitPct number|nil
---@field quickHealsEmergencyOnly boolean|nil
---@field quickHealMaxPct number|nil
---@field squishyCoveragePct number|nil
---@field groupHealMinCount number|nil
---@field bigHotMinMobDps number|nil
---@field bigHotMinXTargetCount number|nil

---@type HealSelectorConfig
local Config = { spells = {} }
local HealTracker = nil
local TargetMonitor = nil
local IncomingHeals = nil
local CombatAssessor = nil

local Proactive = nil
local function getProactive()
    if Proactive == nil then
        local ok, p = pcall(require, 'healing.proactive')
        Proactive = ok and p or false
    end
    return Proactive or nil
end

local Logger = nil
local function getLogger()
    if Logger == nil then
        local ok, l = pcall(require, 'healing.logger')
        Logger = ok and l or false
    end
    return Logger or nil
end

local function getExpectedHeal(tracker, spellName)
    if tracker and tracker.GetExpectedHeal then
        return tracker.GetExpectedHeal(spellName)
    end
    if tracker and tracker.getExpected then
        return tracker.getExpected(spellName)
    end
    return nil
end

local _lastAction = nil
local TICK_MS = 6000

function M.init(config, healTracker, targetMonitor, incomingHeals, combatAssessor)
    Config = config
    HealTracker = healTracker
    TargetMonitor = targetMonitor
    IncomingHeals = incomingHeals
    CombatAssessor = combatAssessor
end

local function getSpellMeta(spellName)
    local spell = mq.TLO.Spell(spellName)
    if not spell or not spell() then
        return nil
    end

    -- Get mana cost
    local rawMana = spell.Mana()
    local manaCost = tonumber(rawMana) or 0

    -- Get cast time (in milliseconds)
    local rawCastTime = nil
    local rawDuration = nil
    pcall(function()
        ---@diagnostic disable-next-line: undefined-field
        if mq.TLO.Me and mq.TLO.Me.Spell then
            ---@diagnostic disable-next-line: undefined-field
            local mySpell = mq.TLO.Me.Spell(spellName)
            if mySpell and mySpell() then
                rawCastTime = mySpell.MyCastTime()
                rawDuration = mySpell.MyDuration()
            end
        end
    end)
    local castTime = tonumber(rawCastTime) or tonumber(spell.CastTime()) or 0

    -- Get recast time
    local recastTime = tonumber(spell.RecastTime()) or 0

    -- Get duration
    local duration = tonumber(rawDuration) or tonumber(spell.Duration()) or 0

    -- Get base heal amount
    local baseHeal = tonumber(spell.Base(1)()) or 0
    if baseHeal < 0 then
        baseHeal = -baseHeal
    end

    -- Debug logging
    local log = getLogger()
    if log and manaCost == 0 then
        log.debug('spellMeta', 'getSpellMeta(%s): rawMana=%s manaCost=%d castTime=%d baseHeal=%d',
            tostring(spellName), tostring(rawMana), manaCost, castTime, baseHeal)
    end

    return {
        mana = manaCost,
        castTimeMs = castTime,
        recastTimeMs = recastTime,
        durationTicks = duration,
        baseHeal = baseHeal,
    }
end

local function isSpellUsable(spellName, meta)
    local ready = mq.TLO.Me.SpellReady(spellName)
    if ready ~= nil and not ready() then
        return false
    end
    local currentMana = mq.TLO.Me.CurrentMana() or 0
    if meta.mana > 0 and currentMana < meta.mana then
        return false
    end
    return true
end

local function predictedDeficit(deficit, dps, timeSec, maxHP)
    if not dps or dps <= 0 or not timeSec or timeSec <= 0 then
        return deficit
    end
    local predicted = deficit + (dps * timeSec)
    if maxHP and predicted > maxHP then
        predicted = maxHP
    end
    return predicted
end

local function getSingleWeights(config, situation)
    local defaults = { coverage = 3.0, manaEff = 0.5, overheal = -1.5 }
    local presets = config and config.scoringPresets or nil
    local weights = (presets and presets.normal) or defaults
    if situation and (situation.hasEmergency or situation.survivalMode) and presets and presets.emergency then
        weights = presets.emergency
    elseif situation and situation.lowPressure and presets and presets.lowPressure then
        weights = presets.lowPressure
    end
    return {
        coverage = tonumber(weights.coverage) or defaults.coverage,
        manaEff = tonumber(weights.manaEff) or defaults.manaEff,
        overheal = tonumber(weights.overheal) or defaults.overheal,
    }
end

local function formatSingleWeights(weights)
    return string.format('weights=cov%.1f,mana%.1f,overheal%.1f,cast-0.2,recast-0.1',
        weights.coverage, weights.manaEff, weights.overheal)
end

local function scoreSingle(meta, expected, deficit, dps, maxHP, situation, targetInfo, category)
    local config = Config or { spells = {} }
    config.spells = config.spells or {}
    local tracker = HealTracker
    -- If mana is 0/unknown, use expected heal as proxy (assumes ~1 heal per mana as baseline)
    -- This prevents massive manaEff scores when mana data is missing
    local mana = meta.mana > 0 and meta.mana or expected
    local castSec = meta.castTimeMs / 1000
    local recastSec = meta.recastTimeMs / 1000
    local adjustedDps = dps
    local burst = false

    -- Scale up if multiple sources (being swarmed = sustained damage)
    if targetInfo and targetInfo.isMultiSource then
        local sourceScale = 1 + ((targetInfo.sourceCount or 1) - 1) * 0.1
        adjustedDps = adjustedDps * math.min(sourceScale, 1.5)
    end

    -- Burst detection
    if targetInfo and targetInfo.burstDetected then
        local scale = config and config.burstDpsScale or 1.5
        burst = true
        adjustedDps = adjustedDps * scale
    end
    local predicted = predictedDeficit(deficit, adjustedDps, castSec, maxHP)
    local safeDeficit = math.max(predicted, 1)
    local coverage = math.min(expected, safeDeficit) / safeDeficit
    local overheal = math.max(0, expected - safeDeficit) / safeDeficit
    local manaEff = expected / mana

    -- Underheal preference: reward heals that cover 80-100% without overhealing
    -- This is the "sweet spot" - enough healing without waste
    local underhealBonus = 0
    local minCoveragePct = (config.underhealMinCoveragePct or 80) / 100
    if config.preferUnderheal ~= false and overheal == 0 and coverage >= minCoveragePct then
        -- Perfect fit! Bonus for right-sized heals (scales with coverage, max +3.0 at 100%)
        underhealBonus = coverage * 3.0
    elseif overheal > 0 then
        -- Any overheal negates the underheal bonus opportunity
        underhealBonus = 0
    end

    local critRate = 0
    local critOverheal = 0
    local critPenalty = 0
    if tracker and tracker.GetHealingGiftCritRate then
        critRate = tracker.GetHealingGiftCritRate() or 0
    end
    if critRate > 0 then
        local baseHeal = expected / (1 + critRate)
        local critHeal = baseHeal * 2
        local critOverhealAmt = math.max(0, critHeal - safeDeficit)
        critOverheal = critOverhealAmt / safeDeficit
        local critOverhealThreshold = config and config.critOverhealThreshold or 0.5
        if critOverheal > critOverhealThreshold then
            local excessCritOverheal = critOverheal - critOverhealThreshold
            local critPenaltyWeight = config and config.critOverhealPenalty or -0.8
            critPenalty = excessCritOverheal * critRate * critPenaltyWeight
        end
    end

    local weights = getSingleWeights(config, situation)
    local categoryPenalty = 0
    if category == 'small' then
        categoryPenalty = config.smallHealPenalty or -0.5
    end

    local score = (coverage * weights.coverage)
        + (manaEff * weights.manaEff)
        + (overheal * weights.overheal)
        + underhealBonus
        + critPenalty
        + categoryPenalty
        - (castSec * 0.2)
        - (recastSec * 0.1)
    return score, {
        coverage = coverage,
        overheal = overheal,
        manaEff = manaEff,
        underhealBonus = underhealBonus,
        castSec = castSec,
        recastSec = recastSec,
        predicted = predicted,
        expected = expected,
        burst = burst,
        adjustedDps = adjustedDps,
        critRate = critRate,
        critOverheal = critOverheal,
        critPenalty = critPenalty,
        categoryPenalty = categoryPenalty,
    }, formatSingleWeights(weights)
end

local function scoreGroup(meta, expectedPerTarget, totalDeficit, hurtCount)
    local config = Config or { spells = {} }
    config.spells = config.spells or {}
    local tracker = HealTracker
    local mana = math.max(meta.mana, 1)
    local castSec = meta.castTimeMs / 1000
    local recastSec = meta.recastTimeMs / 1000
    local totalExpected = expectedPerTarget * hurtCount
    local safeDeficit = math.max(totalDeficit, 1)
    local coverage = math.min(totalExpected, safeDeficit) / safeDeficit
    local overheal = math.max(0, totalExpected - safeDeficit) / safeDeficit
    local manaEff = totalExpected / mana

    local critRate = 0
    local critOverheal = 0
    local critPenalty = 0
    if tracker and tracker.GetHealingGiftCritRate then
        critRate = tracker.GetHealingGiftCritRate() or 0
    end
    if critRate > 0 and hurtCount > 0 then
        local baseHealPerTarget = expectedPerTarget / (1 + critRate)
        local critHealPerTarget = baseHealPerTarget * 2
        local totalCritHeal = critHealPerTarget * hurtCount
        local critOverhealAmt = math.max(0, totalCritHeal - safeDeficit)
        critOverheal = critOverhealAmt / safeDeficit
        local critOverhealThreshold = config and config.critOverhealThreshold or 0.5
        if critOverheal > critOverhealThreshold then
            local excessCritOverheal = critOverheal - critOverhealThreshold
            local critPenaltyWeight = config and config.critOverhealPenalty or -0.8
            critPenalty = excessCritOverheal * critRate * (critPenaltyWeight * 0.5)
        end
    end

    local score = (coverage * 3) + (manaEff * 0.5) - (overheal * 1.5) - (castSec * 0.2) - (recastSec * 0.1) + critPenalty
    return score, {
        coverage = coverage,
        overheal = overheal,
        manaEff = manaEff,
        castSec = castSec,
        recastSec = recastSec,
        expected = totalExpected,
        predicted = safeDeficit,
        targets = hurtCount,
        critRate = critRate,
        critOverheal = critOverheal,
        critPenalty = critPenalty,
    }
end

local function scoreHot(meta, expectedTick, deficit, dps, maxHP)
    local config = Config or { spells = {} }
    config.spells = config.spells or {}
    local tracker = HealTracker
    local mana = math.max(meta.mana, 1)
    local castSec = meta.castTimeMs / 1000
    local recastSec = meta.recastTimeMs / 1000
    local durationSec = math.max(meta.durationTicks * (TICK_MS / 1000), 1)
    local totalExpected = expectedTick * math.max(meta.durationTicks, 1)
    local predicted = predictedDeficit(deficit, dps, durationSec, maxHP)
    local safeDeficit = math.max(predicted, 1)
    local coverage = math.min(totalExpected, safeDeficit) / safeDeficit
    local manaEff = totalExpected / mana
    local hps = totalExpected / durationSec

    local critRate = 0
    local critOverheal = 0
    local critPenalty = 0
    if tracker and tracker.GetHealingGiftCritRate then
        critRate = tracker.GetHealingGiftCritRate() or 0
    end
    if critRate > 0 then
        local baseTick = expectedTick / (1 + critRate)
        local critTick = baseTick * 2
        local totalCritHeal = critTick * math.max(meta.durationTicks, 1)
        local critOverhealAmt = math.max(0, totalCritHeal - safeDeficit)
        critOverheal = critOverhealAmt / safeDeficit
        local critOverhealThreshold = config and config.critOverhealThreshold or 0.5
        if critOverheal > critOverhealThreshold then
            local excessCritOverheal = critOverheal - critOverhealThreshold
            local critPenaltyWeight = (config and config.critOverhealPenalty or -0.8) * 0.5
            critPenalty = excessCritOverheal * critRate * critPenaltyWeight
        end
    end

    local score = (coverage * 2) + (manaEff * 0.5) + (hps * 0.001) + critPenalty - (castSec * 0.2) - (recastSec * 0.1)
    return score, {
        coverage = coverage,
        manaEff = manaEff,
        hps = hps,
        castSec = castSec,
        recastSec = recastSec,
        durationSec = durationSec,
        expected = totalExpected,
        predicted = safeDeficit,
        critRate = critRate,
        critOverheal = critOverheal,
        critPenalty = critPenalty,
    }
end

local function scorePromised(meta, expected, deficit, dps, maxHP)
    local config = Config or { spells = {} }
    config.spells = config.spells or {}
    local tracker = HealTracker
    local mana = math.max(meta.mana, 1)
    local castSec = meta.castTimeMs / 1000
    local recastSec = meta.recastTimeMs / 1000
    local delaySec = meta.durationTicks * (TICK_MS / 1000)
    local predicted = predictedDeficit(deficit, dps, delaySec, maxHP)
    local safeDeficit = math.max(predicted, 1)
    local coverage = math.min(expected, safeDeficit) / safeDeficit
    local manaEff = expected / mana

    local critRate = 0
    local critOverheal = 0
    local critPenalty = 0
    if tracker and tracker.GetHealingGiftCritRate then
        critRate = tracker.GetHealingGiftCritRate() or 0
    end
    if critRate > 0 then
        local baseHeal = expected / (1 + critRate)
        local critHeal = baseHeal * 2
        local critOverhealAmt = math.max(0, critHeal - safeDeficit)
        critOverheal = critOverhealAmt / safeDeficit
        local critOverhealThreshold = config and config.critOverhealThreshold or 0.5
        if critOverheal > critOverhealThreshold then
            local excessCritOverheal = critOverheal - critOverhealThreshold
            local critPenaltyWeight = config and config.critOverhealPenalty or -0.8
            critPenalty = excessCritOverheal * critRate * critPenaltyWeight
        end
    end

    local score = (coverage * 2) + (manaEff * 0.5) - (delaySec * 0.05) - (castSec * 0.2) - (recastSec * 0.1) + critPenalty
    return score, {
        coverage = coverage,
        manaEff = manaEff,
        delaySec = delaySec,
        castSec = castSec,
        recastSec = recastSec,
        expected = expected,
        predicted = safeDeficit,
        critRate = critRate,
        critOverheal = critOverheal,
        critPenalty = critPenalty,
    }
end

local function getExpectedWithFallback(tracker, spellName, fallback, isHot)
    local expected = getExpectedHeal(tracker, spellName)
    if expected ~= nil then
        return expected
    end
    local meta = getSpellMeta(spellName)
    if meta and meta.baseHeal and meta.baseHeal > 0 then
        local aaMult = 1.0
        if tracker and tracker.GetHealingBoonMultiplier and isHot then
            aaMult = tracker.GetHealingBoonMultiplier() or 1.0
        elseif tracker and tracker.GetHealingAdeptMultiplier then
            aaMult = tracker.GetHealingAdeptMultiplier() or 1.0
        end
        local critRate = tracker and tracker.GetHealingGiftCritRate and tracker.GetHealingGiftCritRate() or 0
        local estimated = meta.baseHeal * aaMult * (1 + critRate)
        return estimated
    end
    if tracker and tracker.IsLearning and tracker.IsLearning() and fallback and fallback > 0 then
        return fallback
    end
    return nil
end

local function attachExpected(allSpells, deficit, tracker)
    local list = {}
    for _, spell in ipairs(allSpells) do
        local expected = getExpectedWithFallback(tracker, spell.name, deficit, false)
        if expected then
            table.insert(list, { name = spell.name, cat = spell.cat, expected = expected })
        end
    end
    return list
end

local function preFilterSpells(allSpells, deficit, situation, tracker, config)
    local candidates = attachExpected(allSpells, deficit, tracker)
    if deficit <= 0 or #candidates == 0 then
        return candidates
    end

    local minCoverage = deficit * 0.5
    local maxOverheal = deficit * (config.maxOverhealRatio or 2.0)
    local filtered = {}
    for _, spell in ipairs(candidates) do
        local expected = spell.expected or 0
        if expected >= minCoverage then
            if expected <= maxOverheal or (situation and situation.hasEmergency) then
                table.insert(filtered, spell)
            end
        end
    end

    if #filtered == 0 then
        filtered = candidates
    end

    table.sort(filtered, function(a, b)
        return (a.expected or 0) < (b.expected or 0)
    end)

    return filtered
end

local function formatComponents(components)
    if not components then
        return ''
    end
    local parts = {}
    if components.coverage then table.insert(parts, string.format('cov=%.2f', components.coverage)) end
    if components.overheal then table.insert(parts, string.format('over=%.2f', components.overheal)) end
    if components.manaEff then table.insert(parts, string.format('mana=%.2f', components.manaEff)) end
    if components.underhealBonus and components.underhealBonus > 0 then table.insert(parts, string.format('under=+%.2f', components.underhealBonus)) end
    if components.castSec then table.insert(parts, string.format('cast=%.2f', components.castSec)) end
    if components.recastSec then table.insert(parts, string.format('recast=%.2f', components.recastSec)) end
    if components.delaySec then table.insert(parts, string.format('delay=%.2f', components.delaySec)) end
    if components.hps then table.insert(parts, string.format('hps=%.1f', components.hps)) end
    if components.critPenalty then table.insert(parts, string.format('crit=%.2f', components.critPenalty)) end
    if components.categoryPenalty then table.insert(parts, string.format('cat=%.2f', components.categoryPenalty)) end
    return table.concat(parts, ' ')
end

local function formatScoreDetails(trigger, category, components)
    local c = formatComponents(components)
    if c ~= '' then
        return string.format('trigger=%s category=%s %s', trigger or '', category or '', c)
    end
    return string.format('trigger=%s category=%s', trigger or '', category or '')
end

local function joinDetails(primary, extra)
    if extra == nil or extra == '' then
        return primary
    end
    if primary == nil or primary == '' then
        return extra
    end
    return primary .. ' | ' .. extra
end

local function getHighPressure()
    if CombatAssessor and CombatAssessor.isHighPressure then
        local hp, mobs, dps = CombatAssessor.isHighPressure()
        return hp == true, (mobs or 0), (dps or 0)
    end
    return false, 0, 0
end

local function getTotalIncomingDps()
    if CombatAssessor and CombatAssessor.getState then
        local s = CombatAssessor.getState()
        return s and s.totalIncomingDps or 0
    end
    return 0
end

local function calculateSupplementGap(targetInfo, config)
    local log = getLogger()
    local proactive = getProactive()
    local hotData = proactive and proactive.GetHotData and proactive.GetHotData(targetInfo.name) or nil
    if not hotData or not hotData.spell then
        if log then log.debug('supplement', '[%s] No active HoT, supplement allowed', targetInfo.name or '?') end
        return true, targetInfo.deficit, 'no_hot_active'
    end

    local remainingPct = proactive and proactive.GetHotRemainingPct and proactive.GetHotRemainingPct(targetInfo.name) or 0
    if remainingPct <= 0 then
        if log then log.debug('supplement', '[%s] HoT expired, supplement allowed', targetInfo.name or '?') end
        return true, targetInfo.deficit, 'hot_expired'
    end

    local remainingSec = (remainingPct / 100) * (hotData.duration or 0)

    local tracker = HealTracker
    local hpPerTick = 0
    if tracker and hotData.spell then
        hpPerTick = getExpectedHeal(tracker, hotData.spell) or 0
    end
    if hpPerTick <= 0 then
        if log then log.debug('supplement', '[%s] No HoT data for %s, supplement allowed', targetInfo.name or '?', hotData.spell or '?') end
        return true, targetInfo.deficit, 'no_hot_data'
    end

    local tickInterval = TICK_MS / 1000  -- 6 seconds per tick
    local ticksRemaining = math.floor(remainingSec / tickInterval)
    local remainingHotHealing = hpPerTick * ticksRemaining

    -- Calculate HoT HPS (healing per second)
    local hotHps = hpPerTick / tickInterval
    local dps = targetInfo.recentDps or 0

    -- Net HPS: positive = gaining HP, negative = losing HP
    local netHps = hotHps - dps

    if log then
        log.debug('supplement', '[%s] HoT=%s hpPerTick=%.0f ticksRemain=%d hotHps=%.0f dps=%.0f netHps=%.0f',
            targetInfo.name or '?', hotData.spell or '?', hpPerTick, ticksRemaining, hotHps, dps, netHps)
    end

    -- If HoT is keeping up with damage (positive net HPS), no supplement needed
    if netHps >= 0 then
        local details = string.format('hotHps=%.0f dps=%.0f netHps=+%.0f (HoT keeping up, no supplement)',
            hotHps, dps, netHps)
        if log then log.info('supplement', '[%s] HoT KEEPING UP: %s', targetInfo.name or '?', details) end
        return false, 0, details
    end

    -- HoT isn't keeping up - check if we have enough safety buffer
    -- Calculate current HP and danger threshold
    local currentHp = targetInfo.currentHP or ((targetInfo.maxHP or 1) * ((targetInfo.pctHP or 100) / 100))
    local dangerPct = config.emergencyPct or 25
    local dangerHp = (targetInfo.maxHP or 1) * (dangerPct / 100)
    local hpAboveDanger = currentHp - dangerHp

    -- Calculate time until we reach danger threshold at current net loss rate
    -- netHps is negative here, so we're losing HP
    local safetyBufferSec = config.hotSafetyBufferSec or 8  -- Default 8 seconds of safety buffer

    if log then
        log.debug('supplement', '[%s] currentHp=%.0f dangerHp=%.0f hpAboveDanger=%.0f safetyBuffer=%.0fs',
            targetInfo.name or '?', currentHp, dangerHp, hpAboveDanger, safetyBufferSec)
    end

    if hpAboveDanger > 0 then
        local timeUntilDanger = hpAboveDanger / math.abs(netHps)

        -- If we have enough time before danger, let HoT work
        if timeUntilDanger > safetyBufferSec then
            local details = string.format('hotHps=%.0f dps=%.0f netHps=%.0f hpBuffer=%.0f dangerIn=%.1fs safetyReq=%.0fs (safe, HoT working)',
                hotHps, dps, netHps, hpAboveDanger, timeUntilDanger, safetyBufferSec)
            if log then log.info('supplement', '[%s] HoT SAFE (%.1fs to danger > %.0fs buffer): %s', targetInfo.name or '?', timeUntilDanger, safetyBufferSec, details) end
            return false, 0, details
        end

        -- Danger is approaching - calculate the gap we need to cover
        -- Gap = how much HP we'll lose beyond what HoT can heal before HoT expires or we reach danger
        local hpLossRate = math.abs(netHps)
        local hpLossDuringHot = hpLossRate * remainingSec
        local gap = math.max(0, hpLossDuringHot - hpAboveDanger)

        -- Only supplement if gap is significant (at least 5% of max HP)
        local minGapPct = config.hotSupplementMinGapPct or 5
        local minGap = (targetInfo.maxHP or 1) * (minGapPct / 100)
        if gap < minGap then
            local details = string.format('hotHps=%.0f dps=%.0f netHps=%.0f dangerIn=%.1fs gap=%.0f minGap=%.0f (gap too small, skip supplement)',
                hotHps, dps, netHps, timeUntilDanger, gap, minGap)
            if log then log.info('supplement', '[%s] GAP TOO SMALL (%.0f < %.0f): %s', targetInfo.name or '?', gap, minGap, details) end
            return false, 0, details
        end

        local details = string.format('hotHps=%.0f dps=%.0f netHps=%.0f dangerIn=%.1fs gap=%.0f (supplement needed)',
            hotHps, dps, netHps, timeUntilDanger, gap)
        if log then log.warn('supplement', '[%s] SUPPLEMENT NEEDED (danger in %.1fs, gap=%.0f): %s', targetInfo.name or '?', timeUntilDanger, gap, details) end
        return true, gap, details
    end

    -- Already at or below danger threshold - need immediate supplement
    local details = string.format('hotHps=%.0f dps=%.0f netHps=%.0f hpBuffer=%.0f (at danger, supplement NOW)',
        hotHps, dps, netHps, hpAboveDanger)
    if log then log.warn('supplement', '[%s] AT DANGER THRESHOLD: %s', targetInfo.name or '?', details) end
    return true, targetInfo.deficit, details
end

function M.SelectHeal(targetInfo, situation)
    local config = Config or { spells = {} }
    config.spells = config.spells or {}
    local tracker = HealTracker
    local deficit = targetInfo.deficit
    local learning = tracker and tracker.IsLearning and tracker.IsLearning()
    local nonSquishy = not targetInfo.isSquishy
    local lowPressure = situation and situation.lowPressure

    if deficit <= 0 then return nil, 'no_deficit' end

    if targetInfo.pctHP < config.emergencyPct then
        local heal = M.FindFastestHeal(deficit)
        if heal then
            heal.details = joinDetails(heal.details, 'trigger=emergency')
        end
        if not heal then
            return nil, 'emergency_no_heal'
        end
        return heal
    end

    local deficitPct = (targetInfo.maxHP > 0) and (deficit / targetInfo.maxHP) * 100 or 0

    if Proactive and Proactive.IsSafeToWaitForPromised then
        local isSafe, projection = Proactive.IsSafeToWaitForPromised(targetInfo)
        if isSafe and projection then
            local reason = 'promised_covering|' .. (projection.details or '')
            return nil, reason
        end
        if projection and projection.minPctDuringWait and projection.safetyFloorPct then
            local safetyGapPct = projection.safetyFloorPct - projection.minPctDuringWait
            if safetyGapPct > 0 and safetyGapPct < deficitPct then
                local safetyGap = (safetyGapPct / 100) * (targetInfo.maxHP or 1)
                deficit = safetyGap
                deficitPct = safetyGapPct
                targetInfo._promisedSafetyGap = safetyGap
                targetInfo._promisedSafetyDetails = string.format(
                    'promised_pending safetyGap=%.0f gapPct=%.1f minPct=%.1f floor=%d%% %s',
                    safetyGap, safetyGapPct, projection.minPctDuringWait,
                    projection.safetyFloorPct, projection.details or ''
                )
            end
        end
    end

    if config.considerIncomingHot and targetInfo.incomingHotRemaining and targetInfo.incomingHotRemaining > 0 then
        local coveragePct = config.hotIncomingCoveragePct or 100
        local incoming = targetInfo.incomingHotRemaining or 0
        local maxHP = targetInfo.maxHP or 1
        local dps = targetInfo.recentDps or 0
        local dpsPctPerSec = (dps / maxHP) * 100
        local hotOverrideDpsPct = config.hotOverrideDpsPct or 5
        local lowDps = dpsPctPerSec <= hotOverrideDpsPct
        if lowDps and deficit > 0 and incoming >= (deficit * (coveragePct / 100)) then
            return nil, 'incoming_hot_cover'
        end
        deficit = math.max(0, deficit - incoming)
        if deficit <= 0 then
            return nil, 'incoming_hot_cover'
        end
        deficitPct = (targetInfo.maxHP > 0) and (deficit / targetInfo.maxHP) * 100 or 0
    end

    local hotEnabled = config.hotEnabled ~= false
    local hotMaxPct = config.hotMaxDeficitPct or 35  -- HoTs eligible up to 35% deficit (65% HP)
    local learnMaxPct = config.hotLearnMaxDeficitPct or hotMaxPct
    local hotPreferUnderDps = config.hotPreferUnderDps or config.sustainedDamageThreshold or 3000
    local hotMinDeficitPct = config.hotMinDeficitPct or 20  -- HoTs start at 20% deficit (80% HP)
    if nonSquishy and config.nonSquishyHotMinDeficitPct then
        hotMinDeficitPct = math.max(hotMinDeficitPct, config.nonSquishyHotMinDeficitPct)
    end
    if lowPressure and nonSquishy and config.lowPressureHotMinDeficitPct then
        hotMinDeficitPct = math.max(hotMinDeficitPct, config.lowPressureHotMinDeficitPct)
    end
    local allowLearnHot = learning and config.hotLearnForce and deficitPct <= learnMaxPct
    local refreshable = true
    if Proactive and Proactive.HasActiveHot and Proactive.HasActiveHot(targetInfo.name) then
        refreshable = Proactive.ShouldRefreshHot and Proactive.ShouldRefreshHot(targetInfo.name, config) or false
    end

    local isPriorityTarget = targetInfo.role == 'tank'
    local hotTankOnly = config.hotTankOnly ~= false
    local hotMinDpsForNonTank = config.hotMinDpsForNonTank or 500
    local hotMinDps = config.hotMinDps or 200
    local targetDps = targetInfo.recentDps or 0
    local hasSustainedDamage = targetDps >= hotMinDpsForNonTank
    local hasAnyDamage = targetDps >= hotMinDps  -- Require at least hotMinDps for any HoT
    local isHighPressure, mobs, totalDps = getHighPressure()
    local allowHighPressureHot = isPriorityTarget and isHighPressure

    -- Target must have minimum DPS for HoT consideration (prevents HoTs at full HP with no damage)
    local targetAllowedHot = (isPriorityTarget and hasAnyDamage) or hasSustainedDamage or allowLearnHot

    local hotEligible = hotEnabled
        and deficitPct >= hotMinDeficitPct
        and (deficitPct <= hotMaxPct or allowLearnHot)
        and ((targetDps <= hotPreferUnderDps and hasAnyDamage) or allowLearnHot or allowHighPressureHot)
        and refreshable
        and targetAllowedHot

    if hotEligible then
        local useLight = true
        if isPriorityTarget and isHighPressure then
            local totalIncoming = getTotalIncomingDps()
            local bigHotWithPromisedMinDps = config.bigHotWithPromisedMinDps or 6000
            local promisedAvailable = false
            if Proactive and Proactive.HasActivePromised and Proactive.HasActivePromised(targetInfo.name) then
                promisedAvailable = true
            end
            if not promisedAvailable and config.spells and config.spells.promised then
                for _, spellName in ipairs(config.spells.promised) do
                    local ready = mq.TLO.Me.SpellReady(spellName)
                    if ready and ready() then
                        promisedAvailable = true
                        break
                    end
                end
            end
            if promisedAvailable and totalIncoming < bigHotWithPromisedMinDps then
                useLight = true
            else
                useLight = false
            end
        end
        local allowFallback = isPriorityTarget or not hotTankOnly
        local bestHot = M.SelectBestHot(targetInfo, useLight, allowFallback)
        if bestHot then
            local trigger = allowLearnHot and 'trigger=hot_learn_force' or 'trigger=hot_preference'
            local refreshTag = (refreshable and Proactive and Proactive.HasActiveHot
                and Proactive.HasActiveHot(targetInfo.name)) and ' refresh=true' or ''
            local pressureTag = ''
            if not useLight then
                pressureTag = string.format(' bigHot=true highPressure=mobs:%s dps:%s', tostring(mobs or 0), tostring(totalDps or 0))
            else
                pressureTag = ' lightHot=true'
            end
            local detail = joinDetails(
                bestHot.details,
                string.format('%s dps=%.0f deficitPct=%.1f%s%s', trigger, targetInfo.recentDps or 0, deficitPct, refreshTag, pressureTag)
            )
            return { spell = bestHot.spell, expected = bestHot.expected, category = 'hot', details = detail }
        end
    end

    if Proactive and Proactive.HasActiveHot and Proactive.HasActiveHot(targetInfo.name) then
        local log = getLogger()
        local supplementMinPct = config.minHealPct or 10
        if nonSquishy and config.nonSquishyMinHealPct then
            supplementMinPct = math.max(supplementMinPct, config.nonSquishyMinHealPct)
        end
        if lowPressure and nonSquishy and config.lowPressureMinDeficitPct then
            supplementMinPct = math.max(supplementMinPct, config.lowPressureMinDeficitPct)
        end
        if deficitPct < supplementMinPct then
            if log then log.debug('supplement', '[%s] Deficit %.1f%% below supplement min %.1f%%, skipping', targetInfo.name or '?', deficitPct, supplementMinPct) end
            return nil, string.format('supplement_below_min_pct|deficitPct=%.1f minPct=%.1f', deficitPct, supplementMinPct)
        end

        if log then log.debug('supplement', '[%s] Checking supplement: deficit=%.0f deficitPct=%.1f%% pctHP=%.0f%% dps=%.0f',
            targetInfo.name or '?', deficit, deficitPct, targetInfo.pctHP or 0, targetInfo.recentDps or 0) end

        local needsSupplement, gap, supplementDetails = calculateSupplementGap(targetInfo, config)
        if not needsSupplement or gap <= 0 then
            if log then log.info('supplement', '[%s] HoT covering deficit, NO SUPPLEMENT: %s', targetInfo.name or '?', supplementDetails or '') end
            return nil, 'hot_covering|' .. (supplementDetails or '')
        end

        if log then log.info('supplement', '[%s] Supplement NEEDED, gap=%.0f: %s', targetInfo.name or '?', gap, supplementDetails or '') end

        local gapTargetInfo = {
            name = targetInfo.name,
            role = targetInfo.role,
            currentHP = targetInfo.currentHP,
            maxHP = targetInfo.maxHP,
            pctHP = targetInfo.pctHP,
            deficit = gap,
            recentDps = targetInfo.recentDps,
            isSquishy = targetInfo.isSquishy,
            incomingHotRemaining = 0,
        }

        local supplementHeal = M.FindEfficientHeal(gapTargetInfo, false, situation)
        if supplementHeal then
            if log then log.info('supplement', '[%s] Selected supplement heal: %s expected=%.0f for gap=%.0f',
                targetInfo.name or '?', supplementHeal.spell or '?', supplementHeal.expected or 0, gap) end
            supplementHeal.details = joinDetails(
                supplementHeal.details,
                string.format('trigger=supplement gap=%.0f %s', gap, supplementDetails or '')
            )
            return supplementHeal
        else
            if log then log.debug('supplement', '[%s] No supplement heal found for gap=%.0f', targetInfo.name or '?', gap) end
        end
    end

    local minHealPct = config.minHealPct or 10
    if lowPressure and nonSquishy and config.lowPressureMinDeficitPct and deficitPct < config.lowPressureMinDeficitPct then
        return nil, 'below_min_pct_low_pressure'
    end
    if nonSquishy and config.nonSquishyMinHealPct and deficitPct < config.nonSquishyMinHealPct then
        return nil, 'below_min_pct_nonsquishy'
    end
    if deficitPct < minHealPct then
        return nil, 'below_min_pct'
    end

    if targetInfo.isSquishy then
        local squishyHeal = M.FindHealForSquishy(deficit, not config.quickHealsEmergencyOnly)
        if squishyHeal then
            squishyHeal.details = joinDetails(
                squishyHeal.details,
                string.format('trigger=squishy deficitPct=%.1f', deficitPct)
            )
            return squishyHeal
        end
    end

    if not config.quickHealsEmergencyOnly and situation.multipleHurt and deficitPct <= config.quickHealMaxPct then
        local heal = M.FindFastestHeal(deficit)
        if heal then
            heal.details = joinDetails(
                heal.details,
                string.format('trigger=multi_hurt deficitPct=%.1f', deficitPct)
            )
        end
        return heal
    end

    -- Character-specific minimum deficit check
    -- This prevents overhealing when all available heals are too big for the deficit
    -- The threshold is relative to the target's max HP, not just the raw heal amount
    local minExpectedHeal = M.GetMinExpectedHeal()
    local minHealThresholdPct = config.minHealThresholdPct or 70  -- Deficit must be at least 70% of smallest heal's % of maxHP
    local log = getLogger()
    if minExpectedHeal and minExpectedHeal > 0 and targetInfo.maxHP and targetInfo.maxHP > 0 then
        -- What % of target's maxHP is our smallest heal?
        local minHealPctOfMaxHP = (minExpectedHeal / targetInfo.maxHP) * 100

        -- The target needs to be missing at least (minHealPct * threshold%) of their maxHP
        -- This makes the threshold character-specific - tanks with big HP pools have lower % thresholds
        local minDeficitPctNeeded = minHealPctOfMaxHP * (minHealThresholdPct / 100)

        if deficitPct < minDeficitPctNeeded then
            if log then
                log.debug('selection', '[%s] SKIP: DeficitPct %.1f%% < minNeeded %.1f%% (minHeal=%.0f is %.1f%% of maxHP %.0f)',
                    targetInfo.name or '?', deficitPct, minDeficitPctNeeded, minExpectedHeal, minHealPctOfMaxHP, targetInfo.maxHP)
            end
            return nil, string.format('deficit_pct_below_min_heal|deficitPct=%.1f minNeeded=%.1f minHeal=%.0f maxHP=%.0f',
                deficitPct, minDeficitPctNeeded, minExpectedHeal, targetInfo.maxHP)
        else
            if log then
                log.debug('selection', '[%s] PASS: DeficitPct %.1f%% >= minNeeded %.1f%% (minHeal=%.0f is %.1f%% of maxHP %.0f)',
                    targetInfo.name or '?', deficitPct, minDeficitPctNeeded, minExpectedHeal, minHealPctOfMaxHP, targetInfo.maxHP)
            end
        end
    end

    local heal = M.FindEfficientHeal(targetInfo, false, situation)
    if not heal then
        return nil, 'no_efficient_heal'
    end
    return heal
end

-- Cache for minimum expected heal (refreshed periodically)
local _minExpectedHealCache = nil
local _minExpectedHealCacheTime = 0
local MIN_HEAL_CACHE_TTL = 30  -- seconds

function M.GetMinExpectedHeal()
    local now = mq.gettime and mq.gettime() or os.time()
    if _minExpectedHealCache and (now - _minExpectedHealCacheTime) < MIN_HEAL_CACHE_TTL then
        return _minExpectedHealCache
    end

    local config = Config or { spells = {} }
    config.spells = config.spells or {}
    local tracker = HealTracker
    local minExpected = nil

    -- Check all direct heal categories (not HoTs)
    local categories = { 'fast', 'small', 'medium', 'large' }
    for _, cat in ipairs(categories) do
        for _, spellName in ipairs(config.spells[cat] or {}) do
            local expected = getExpectedHeal(tracker, spellName)
            if expected and expected > 0 then
                local meta = getSpellMeta(spellName)
                if meta and isSpellUsable(spellName, meta) then
                    if not minExpected or expected < minExpected then
                        minExpected = expected
                    end
                end
            end
        end
    end

    _minExpectedHealCache = minExpected
    _minExpectedHealCacheTime = now
    return minExpected
end

function M.FindFastestHeal(deficit)
    local config = Config or { spells = {} }
    config.spells = config.spells or {}
    local tracker = HealTracker
    local candidates = {}
    local categories = { 'fast', 'small', 'medium', 'large' }

    for _, cat in ipairs(categories) do
        for _, spellName in ipairs(config.spells[cat] or {}) do
            local expected = getExpectedHeal(tracker, spellName)
            if expected then
                local meta = getSpellMeta(spellName)
                if meta and isSpellUsable(spellName, meta) then
                    table.insert(candidates, {
                        spell = spellName,
                        expected = expected,
                        category = cat,
                        castTimeMs = meta.castTimeMs or 0,
                    })
                end
            end
        end
    end

    if #candidates == 0 then
        return nil
    end

    table.sort(candidates, function(a, b) return a.castTimeMs < b.castTimeMs end)
    local fastest = candidates[1]

    return {
        spell = fastest.spell,
        expected = fastest.expected,
        category = fastest.category,
        details = formatScoreDetails('fastest', 'single', nil),
    }
end

function M.FindHealForSquishy(deficit, allowFast)
    local config = Config or { spells = {} }
    config.spells = config.spells or {}
    local tracker = HealTracker
    local minCoverage = deficit * (config.squishyCoveragePct / 100)

    if allowFast then
        for _, spellName in ipairs(config.spells.fast or {}) do
            local expected = getExpectedHeal(tracker, spellName)
            if expected and expected >= minCoverage then
                local meta = getSpellMeta(spellName)
                if meta and isSpellUsable(spellName, meta) then
                    return {
                        spell = spellName,
                        expected = expected,
                        category = 'fast',
                        details = formatScoreDetails('squishy', 'single', nil),
                    }
                end
            end
        end
    end

    for _, spellName in ipairs(config.spells.small or {}) do
        local expected = getExpectedHeal(tracker, spellName)
        if expected and expected >= minCoverage then
            local meta = getSpellMeta(spellName)
            if meta and isSpellUsable(spellName, meta) then
                return {
                    spell = spellName,
                    expected = expected,
                    category = 'small',
                    details = formatScoreDetails('squishy', 'single', nil),
                }
            end
        end
    end

    return M.FindFastestHeal(deficit)
end

function M.FindEfficientHeal(targetInfo, allowFast, situation)
    local config = Config or { spells = {} }
    config.spells = config.spells or {}
    local tracker = HealTracker
    local deficit = targetInfo.deficit
    local dps = targetInfo.recentDps or 0
    local maxHP = targetInfo.maxHP or 1

    local allSpells = {}
    local categories = { 'small', 'medium', 'large' }
    if allowFast then
        table.insert(categories, 1, 'fast')
    end

    for _, cat in ipairs(categories) do
        for _, spellName in ipairs(config.spells[cat] or {}) do
            table.insert(allSpells, { name = spellName, cat = cat })
        end
    end

    -- If no spells found in small/medium/large, fall back to 'fast' category
    -- This handles cases where all direct heals are "quick heal" type
    if #allSpells == 0 and not allowFast then
        for _, spellName in ipairs(config.spells.fast or {}) do
            table.insert(allSpells, { name = spellName, cat = 'fast' })
        end
    end

    local filtered = preFilterSpells(allSpells, deficit, situation, tracker, config)
    local weights = getSingleWeights(config, situation)
    local best = nil
    local bestScore = -999
    local scores = {}

    for _, candidate in ipairs(filtered) do
        local spellName = candidate.name
        local meta = getSpellMeta(spellName)
        if meta and isSpellUsable(spellName, meta) then
            local score, components, weightText = scoreSingle(meta, candidate.expected, deficit, dps, maxHP, situation, targetInfo, candidate.cat)
            table.insert(scores, {
                spell = spellName,
                score = score,
                category = candidate.cat,
                expected = candidate.expected,
                mana = meta.mana,
                castTime = meta.castTimeMs,
                components = components,
                weights = weightText,
            })
            if score > bestScore then
                bestScore = score
                best = {
                    spell = spellName,
                    expected = candidate.expected,
                    category = candidate.cat,
                    details = formatScoreDetails('efficient', 'single', components),
                }
            end
        end
    end

    local log = getLogger()
    if log and log.logSpellSelection then
        local spells = {}
        for _, s in ipairs(scores) do
            table.insert(spells, {
                name = s.spell,
                score = s.score,
                expected = s.expected,
                mana = s.mana or 0,
                castTime = s.castTime or 0,
            })
        end
        table.sort(spells, function(a, b) return a.score > b.score end)
        log.logSpellSelection(targetInfo, 'single', spells, best and best.spell or nil, bestScore)
    end

    return best
end

function M.ShouldUseGroupHeal(targets)
    local config = Config or { spells = {} }
    config.spells = config.spells or {}
    local tracker = HealTracker
    if not config or not config.spells then return false, nil end

    local hasEmergency = false
    local hurtTargets = {}
    for _, t in ipairs(targets or {}) do
        if (t.pctHP or 100) < (config.emergencyPct or 25) then
            hasEmergency = true
        end
        if t.deficit and t.deficit > 0 then
            table.insert(hurtTargets, t)
        end
    end

    if hasEmergency then
        return false, nil
    end

    local best = nil
    local bestScore = -math.huge
    local allScores = {}

    for _, spellName in ipairs(config.spells.group or {}) do
        local expected = getExpectedHeal(tracker, spellName)
        if expected and expected > 0 then
            local meta = getSpellMeta(spellName)
            if meta and isSpellUsable(spellName, meta) then
                local castSec = meta.castTimeMs / 1000
                local predictedTotal = 0
                local eligibleCount = 0
                for _, t in ipairs(hurtTargets) do
                    local predicted = predictedDeficit(t.deficit, t.recentDps, castSec, t.maxHP)
                    if predicted >= expected then
                        eligibleCount = eligibleCount + 1
                        predictedTotal = predictedTotal + predicted
                    end
                end

                if eligibleCount >= (config.groupHealMinCount or 3) then
                    local totalHealing = expected * eligibleCount
                    local thresholdDeficit = predictedTotal > 0 and predictedTotal or totalHealing
                    if totalHealing >= thresholdDeficit * 0.7 then
                        local score, components = scoreGroup(meta, expected, thresholdDeficit, eligibleCount)
                        table.insert(allScores, { name = spellName, score = score, expected = expected, mana = meta.mana, castTime = meta.castTimeMs })
                        if score > bestScore then
                            bestScore = score
                            best = {
                                spell = spellName,
                                expected = expected,
                                targets = eligibleCount,
                                details = formatScoreDetails('group_score', 'group', components),
                            }
                        end
                    end
                end
            end
        end
    end

    local log = getLogger()
    if log and log.logSpellSelection then
        local spells = {}
        for _, s in ipairs(allScores) do
            table.insert(spells, { name = s.name, score = s.score, expected = s.expected, mana = s.mana or 0, castTime = s.castTime or 0 })
        end
        table.sort(spells, function(a, b) return a.score > b.score end)
        log.logSpellSelection({ name = 'group' }, 'group', spells, best and best.spell or nil, bestScore)
    end

    return best ~= nil, best
end

function M.SelectBestHot(targetInfo, useLight, allowFallback)
    local config = Config
    local tracker = HealTracker
    local list = {}

    local spells = config.spells or {}

    if useLight and spells.hotLight then
        for _, spellName in ipairs(spells.hotLight) do
            table.insert(list, spellName)
        end
    end
    if (not useLight or allowFallback) and spells.hot then
        for _, spellName in ipairs(spells.hot) do
            table.insert(list, spellName)
        end
    end

    local best = nil
    local bestScore = -999
    local allScores = {}

    for _, spellName in ipairs(list) do
        local meta = getSpellMeta(spellName)
        if meta and isSpellUsable(spellName, meta) then
            local ticks = math.max(meta.durationTicks, 1)
            local fallbackTick = math.max(1, math.floor(targetInfo.deficit / ticks))
            local expectedTick = getExpectedWithFallback(tracker, spellName, fallbackTick, true)
            if expectedTick then
                local score, components = scoreHot(meta, expectedTick, targetInfo.deficit, targetInfo.recentDps, targetInfo.maxHP)
                table.insert(allScores, { name = spellName, score = score, expected = expectedTick, mana = meta.mana, castTime = meta.castTimeMs })
                if score > bestScore then
                    bestScore = score
                    best = {
                        spell = spellName,
                        expected = expectedTick,
                        details = formatScoreDetails('hot', 'hot', components),
                    }
                end
            end
        end
    end

    local log = getLogger()
    if log and log.logSpellSelection then
        local spells = {}
        for _, s in ipairs(allScores) do
            table.insert(spells, { name = s.name, score = s.score, expected = s.expected, mana = s.mana or 0, castTime = s.castTime or 0 })
        end
        table.sort(spells, function(a, b) return a.score > b.score end)
        log.logSpellSelection(targetInfo, 'hot', spells, best and best.spell or nil, bestScore)
    end

    return best
end

function M.SelectBestGroupHot(targets, totalDeficit, hurtCount)
    local config = Config
    local tracker = HealTracker
    local best = nil
    local bestScore = -999
    local allScores = {}

    local spells = config.spells or {}
    for _, spellName in ipairs(spells.groupHot or {}) do
        local meta = getSpellMeta(spellName)
        if meta and isSpellUsable(spellName, meta) then
            local ticks = math.max(meta.durationTicks, 1)
            local fallbackTick = math.max(1, math.floor((totalDeficit or 0) / (ticks * math.max(hurtCount, 1))))
            local expectedTick = getExpectedWithFallback(tracker, spellName, fallbackTick, true)
            if expectedTick then
                local totalExpected = expectedTick * ticks * hurtCount
                local score, components = scoreHot(meta, expectedTick, totalDeficit or 0, 0, totalDeficit or 1)
                table.insert(allScores, { name = spellName, score = score, expected = totalExpected, mana = meta.mana, castTime = meta.castTimeMs })
                if score > bestScore then
                    bestScore = score
                    best = {
                        spell = spellName,
                        expected = expectedTick,
                        targets = hurtCount,
                        details = formatScoreDetails('groupHot', 'groupHot', components),
                    }
                end
            end
        end
    end

    local log = getLogger()
    if log and log.logSpellSelection then
        local spells = {}
        for _, s in ipairs(allScores) do
            table.insert(spells, { name = s.name, score = s.score, expected = s.expected, mana = s.mana or 0, castTime = s.castTime or 0 })
        end
        table.sort(spells, function(a, b) return a.score > b.score end)
        log.logSpellSelection({ name = 'group' }, 'groupHot', spells, best and best.spell or nil, bestScore)
    end

    return best
end

-- Compatibility wrappers
function M.selectHeal(target, tier)
    return nil, nil, nil
end

function M.findHealTarget()
    if not TargetMonitor then return nil, nil end
    local config = Config or {}
    local injured = TargetMonitor.getInjuredTargets(100 - (config.minHealPct or 10))
    if #injured == 0 then return nil, nil end
    local target = injured[1]
    local tier = (target.pctHP < (config.emergencyPct or 25)) and 'emergency' or 'normal'
    return target, tier
end

function M.checkGroupHeal()
    local ok, best = M.ShouldUseGroupHeal(TargetMonitor and TargetMonitor.getInjuredTargets and TargetMonitor.getInjuredTargets(100) or {})
    return ok, best and best.spell or nil
end

function M.recordLastAction(spellName, targetName, expected)
    _lastAction = { spell = spellName, target = targetName, expected = expected, time = os.time() }
end

function M.getLastAction()
    return _lastAction
end

return M
