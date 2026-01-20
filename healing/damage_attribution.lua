-- healing/damage_attribution.lua
local mq = require('mq')

local M = {}

local Config = nil

-- Combat timeout tracking
local _lastDamageEvent = 0
local COMBAT_TIMEOUT = 5  -- seconds
local WINDOW_DURATION = 3  -- seconds for DPS calculation

-- Per-target damage attribution
local _targetDamage = {}  -- [targetId] = { sources = {}, sourceCount, totalDps, ... }

-- AE damage tracking (same mob hitting multiple targets)
local _aeDamage = {}  -- [mobId] = { targets = {}, isAE, totalDps }

-- Mob name-to-ID resolution cache
local _mobNameCache = {}  -- [mobName] = { id, lastSeen }

function M.init(config)
    Config = config
    COMBAT_TIMEOUT = Config and Config.combatTimeoutSec or 5
    WINDOW_DURATION = Config and Config.dpsWindowSec or 3
    _targetDamage = {}
    _aeDamage = {}
    _mobNameCache = {}
    _lastDamageEvent = 0
end

-- Refresh mob name cache from XTarget
local function refreshMobCache()
    local now = mq.gettime()
    local me = mq.TLO.Me
    if not me or not me() then return end

    local xtCount = tonumber(me.XTarget()) or 0
    for i = 1, xtCount do
        local xt = me.XTarget(i)
        if xt and xt() and xt.ID() and xt.ID() > 0 then
            local name = xt.CleanName() or xt.Name()
            local id = xt.ID()
            if name and id then
                _mobNameCache[name] = { id = id, lastSeen = now }
            end
        end
    end
end

-- Resolve attacker name to mob ID
local function resolveMobId(attackerName)
    if not attackerName then return nil end

    local cached = _mobNameCache[attackerName]
    if cached then return cached.id end

    -- Fallback: direct spawn lookup
    local spawn = mq.TLO.Spawn('npc "' .. attackerName .. '"')
    if spawn and spawn() and spawn.ID() > 0 then
        return spawn.ID()
    end

    return nil
end

-- Find target ID by name (group members only)
local function findTargetIdByName(name)
    if not name or name == '' then return nil end

    -- Handle "YOU" as self
    if name == 'YOU' or name == 'you' then
        local me = mq.TLO.Me
        if me and me() and me.ID() then
            return me.ID()
        end
        return nil
    end

    -- Check self
    local me = mq.TLO.Me
    if me and me() then
        local myName = me.CleanName()
        if myName and myName == name then
            return me.ID()
        end
    end

    -- Check group members
    local groupCount = tonumber(mq.TLO.Group.Members()) or 0
    for i = 1, groupCount do
        local member = mq.TLO.Group.Member(i)
        if member and member() then
            local memberName = member.CleanName() or member.Name()
            if memberName and memberName == name then
                local spawn = member.Spawn and member.Spawn() or member
                if spawn and spawn() and spawn.ID then
                    return spawn.ID()
                end
            end
        end
    end

    return nil
end

-- Check if combat has timed out (no damage for N seconds)
local function checkCombatTimeout()
    local now = mq.gettime()
    if _lastDamageEvent > 0 and (now - _lastDamageEvent) > COMBAT_TIMEOUT then
        -- Clear all attribution data
        _targetDamage = {}
        _aeDamage = {}
        _mobNameCache = {}
        _lastDamageEvent = 0
    end
end

-- Record a damage event
function M.recordDamage(targetName, amount, attackerName, dmgType)
    if not amount or amount <= 0 then return end

    local now = mq.gettime()
    _lastDamageEvent = now

    -- Ignore outgoing damage (we're the attacker)
    if attackerName == 'You' or attackerName == 'you' then
        return
    end

    -- Resolve target
    local targetId = findTargetIdByName(targetName)
    if not targetId then return end  -- Not a group member we track

    -- Resolve mob
    local mobId = resolveMobId(attackerName)
    local sourceKey = mobId or ('unknown_' .. (attackerName or '?'))

    -- Initialize target tracking
    if not _targetDamage[targetId] then
        _targetDamage[targetId] = {
            sources = {},
            sourceCount = 0,
            totalDps = 0,
            primarySourceId = nil,
            primarySourceDps = 0,
            isMultiSource = false,
        }
    end

    local targetData = _targetDamage[targetId]

    -- Initialize source tracking
    if not targetData.sources[sourceKey] then
        targetData.sources[sourceKey] = {
            mobId = mobId,
            mobName = attackerName,
            lastHit = now,
            dps = 0,
            entries = {},
        }
    end

    local sourceData = targetData.sources[sourceKey]
    sourceData.lastHit = now
    table.insert(sourceData.entries, {
        time = now,
        amount = amount,
        dmgType = dmgType,
    })

    -- Track for AE detection (only if we have a mobId)
    if mobId then
        if not _aeDamage[mobId] then
            _aeDamage[mobId] = {
                targets = {},
                activeTargetCount = 0,
                isAE = false,
                totalDps = 0,
            }
        end
        _aeDamage[mobId].targets[targetId] = now
    end
end

-- Calculate DPS for a specific target
local function calculateTargetDps(targetId)
    local targetData = _targetDamage[targetId]
    if not targetData then return end

    local now = mq.gettime()
    local cutoff = now - WINDOW_DURATION

    local activeSourceCount = 0
    local totalDps = 0
    local primaryId = nil
    local primaryDps = 0

    for sourceKey, sourceData in pairs(targetData.sources) do
        -- Prune old entries, sum recent damage
        local recentDamage = 0
        local recentEntries = {}

        for _, entry in ipairs(sourceData.entries) do
            if entry.time >= cutoff then
                table.insert(recentEntries, entry)
                recentDamage = recentDamage + entry.amount
            end
        end
        sourceData.entries = recentEntries

        -- Calculate this source's DPS
        local sourceDps = recentDamage / WINDOW_DURATION
        sourceData.dps = sourceDps

        if #recentEntries > 0 then
            activeSourceCount = activeSourceCount + 1
            totalDps = totalDps + sourceDps

            if sourceDps > primaryDps then
                primaryDps = sourceDps
                primaryId = sourceKey
            end
        end
    end

    -- Update aggregate fields
    targetData.sourceCount = activeSourceCount
    targetData.totalDps = totalDps
    targetData.primarySourceId = primaryId
    targetData.primarySourceDps = primaryDps
    targetData.isMultiSource = activeSourceCount >= 2
end

return M
