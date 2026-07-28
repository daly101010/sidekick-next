-- Canonical offensive-target selection for the DPS and debuff workers.
--
-- Selection is read-only. It accepts a ModuleBase worker so Actor Team state
-- and peer target telemetry remain scoped to that worker's validated state.

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')

local M = {}

local _lastValidByWorker = {}

local function workerKey(worker)
    return tostring(worker and worker.name or 'offensive')
end

local function addCandidate(candidates, seen, id, source, coordinatedCombat)
    id = tonumber(id) or 0
    if id <= 0 then return end

    local existing = seen[id]
    if existing then
        if coordinatedCombat == true then existing.coordinatedCombat = true end
        return
    end

    local spawn = mq.TLO.Spawn(id)
    if not (spawn and spawn()) then return end
    local spawnType = tostring(lib.safeTLO(function() return spawn.Type() end, '') or ''):lower()
    if spawnType ~= 'npc' then return end
    if lib.safeTLO(function() return spawn.Dead() end, false) == true then return end

    -- A current or recently broken charm pet must never become an offensive
    -- target merely because it appears on XTarget or a peer is targeting it.
    local okActors, Actors = pcall(require, 'sidekick-next.utils.actors_coordinator')
    if okActors and Actors and Actors.isCharmPet and Actors.isCharmPet(id) then return end

    local candidate = {
        id = id,
        source = source or 'unknown',
        coordinatedCombat = coordinatedCombat == true,
    }
    seen[id] = candidate
    candidates[#candidates + 1] = candidate
end

local function addSpawnTargetCandidates(candidates, seen, spawn, source)
    if not (spawn and spawn()) then return end
    addCandidate(candidates, seen,
        lib.safeNum(function() return spawn.Target.ID() end, 0),
        source .. '_target')
    addCandidate(candidates, seen,
        lib.safeNum(function() return spawn.TargetOfTarget.ID() end, 0),
        source .. '_tot')
end

local function validateNpcTarget(worker, targetId, source, remember, coordinatedCombat)
    targetId = tonumber(targetId) or 0
    if targetId <= 0 then return nil end

    local target = mq.TLO.Spawn(targetId)
    if not (target and target()) then return nil end
    local targetType = tostring(lib.safeTLO(function() return target.Type() end, '') or '')
    local dead = lib.safeTLO(function() return target.Dead() end, false) == true
    if targetType:lower() ~= 'npc' or dead then return nil end

    local result = {
        id = targetId,
        name = tostring(lib.safeTLO(function() return target.CleanName() end, '') or ''),
        hp = lib.safeNum(function() return target.PctHPs() end, 100),
        source = source or 'unknown',
        coordinatedCombat = coordinatedCombat == true,
    }
    if remember ~= false then
        _lastValidByWorker[workerKey(worker)] = {
            id = result.id,
            name = result.name,
            hp = result.hp,
            source = result.source,
            coordinatedCombat = result.coordinatedCombat,
            seenAt = lib.getTimeMs(),
        }
    end
    return result
end

function M.isCombatActive(target)
    if not target or not target.id or target.id <= 0 then return false end
    if target.coordinatedCombat == true then return true end
    if lib.inCombat() then return true end

    local source = tostring(target.source or ''):lower()
    if source:find('xtarget', 1, true) then return true end

    local spawn = mq.TLO.Spawn(target.id)
    if not (spawn and spawn()) then return false end
    local hp = lib.safeNum(function() return spawn.PctHPs() end, 100)
    if hp > 0 and hp < 100 then return true end

    local targetType = tostring(lib.safeTLO(
        function() return spawn.Target.Type() end, '') or ''):lower()
    return targetType == 'pc' or targetType == 'pet' or targetType == 'mercenary'
end

local function addXTargetCandidates(candidates, seen)
    local xtCount = lib.safeNum(function() return mq.TLO.Me.XTarget() end, 0)
    for index = 1, xtCount do
        local xt = mq.TLO.Me.XTarget(index)
        if xt and xt() then
            local xtType = tostring(lib.safeTLO(function() return xt.TargetType() end, '') or ''):lower()
            if xtType:find('hater', 1, true) or xtType:find('auto', 1, true) then
                addCandidate(candidates, seen,
                    lib.safeNum(function() return xt.ID() end, 0),
                    'xtarget' .. tostring(index))
            end
        end
    end
end

local function getAuthoritativePrimary(worker, actorTtlSeconds)
    local Actors = worker and worker.peerActors or nil
    if not Actors then return false, nil end

    local tankState = Actors.getTankState and Actors.getTankState() or nil
    local tankUpdatedAt = type(tankState) == 'table' and tonumber(tankState.updatedAt) or nil
    if tankUpdatedAt and tankUpdatedAt > 0
        and (os.clock() - tankUpdatedAt) <= actorTtlSeconds then
        local primaryId = tankState.killAuthorized == true
            and (tonumber(tankState.primaryTargetId) or 0) or 0
        if primaryId <= 0 then return true, nil end
        return true, validateNpcTarget(
            worker, primaryId, 'actor_primary', true, true)
    end
    return false, nil
end

local function addActorTargetCandidates(worker, candidates, seen, maId, actorTtlSeconds)
    local Actors = worker and worker.peerActors or nil
    if not Actors then return end

    local assistNames = {}
    local function rememberName(name)
        name = tostring(name or '')
        if name ~= '' then assistNames[name:lower()] = true end
    end

    local settings = lib.getSettings() or {}
    rememberName(settings.AssistName)
    if maId and maId > 0 then
        local ma = mq.TLO.Spawn(maId)
        if ma and ma() then
            rememberName(lib.safeTLO(function() return ma.CleanName() end, ''))
        end
    end
    local groupMA = mq.TLO.Group.MainAssist
    if groupMA and groupMA() then
        rememberName(lib.safeTLO(function() return groupMA.CleanName() end, ''))
    end

    if next(assistNames) and Actors.getRemoteCharacters then
        for name, data in pairs(Actors.getRemoteCharacters() or {}) do
            if assistNames[tostring(name):lower()] then
                local updatedAt = tonumber(data.targetUpdatedAt) or 0
                if updatedAt > 0 and (os.clock() - updatedAt) <= actorTtlSeconds then
                    addCandidate(candidates, seen, data.targetId,
                        'actor_mainassist:' .. tostring(name), data.combat == true)
                end
            end
        end
    end

    -- Actor Team is the trust boundary for out-of-group targeting. Rank a
    -- named assist/tank first, then vote count, leader, and stable identity.
    local team = worker.state and worker.state.team or nil
    local votes = {}
    if type(team) == 'table' and team.enabled == true then
        local myZone = tostring(lib.getZone() or ''):lower()
        for _, member in ipairs(team.members or {}) do
            local ageMs = tonumber(member.ageMs) or 0
            local memberZone = tostring(member.zone or ''):lower()
            local targetType = tostring(member.targetType or ''):lower()
            local targetId = tonumber(member.targetId) or 0
            if member.self ~= true and ageMs <= (actorTtlSeconds * 1000)
                and memberZone == myZone and targetType == 'npc' and targetId > 0 then
                local name = tostring(member.character or '')
                local vote = votes[targetId] or {
                    id = targetId,
                    count = 0,
                    preferred = false,
                    leader = false,
                    inCombat = false,
                    sourceName = name,
                }
                vote.count = vote.count + 1
                vote.preferred = vote.preferred
                    or assistNames[name:lower()] == true
                    or tostring(member.role or ''):lower() == 'tank'
                vote.leader = vote.leader or member.key == team.leaderKey
                vote.inCombat = vote.inCombat or member.inCombat == true
                if name ~= '' and (vote.sourceName == ''
                    or name:lower() < vote.sourceName:lower()) then
                    vote.sourceName = name
                end
                votes[targetId] = vote
            end
        end
    end

    local ranked = {}
    for _, vote in pairs(votes) do ranked[#ranked + 1] = vote end
    table.sort(ranked, function(a, b)
        if a.preferred ~= b.preferred then return a.preferred end
        if a.count ~= b.count then return a.count > b.count end
        if a.leader ~= b.leader then return a.leader end
        if a.sourceName ~= b.sourceName then
            return a.sourceName:lower() < b.sourceName:lower()
        end
        return a.id < b.id
    end)
    for _, vote in ipairs(ranked) do
        addCandidate(candidates, seen, vote.id,
            string.format('actor_team:%s:votes%d', vote.sourceName, vote.count),
            vote.inCombat)
    end
end

function M.select(worker, opts)
    opts = opts or {}
    local actorTtlSeconds = tonumber(opts.actorTargetTtlSeconds) or 5
    local targetCacheMs = tonumber(opts.targetCacheMs) or 5000

    -- A fresh primary-target publication is the sole group kill intent. A
    -- fresh zero or an invalid/dead published spawn means "do not acquire";
    -- neither case may fall through to the tank's live peel target, MA target,
    -- Actor votes, XTarget, or a cached prior target.
    local authoritative, primary = getAuthoritativePrimary(
        worker, actorTtlSeconds)
    if authoritative then return primary end

    local maId = lib.getMainAssistId()
    local candidates, seen = {}, {}

    addActorTargetCandidates(worker, candidates, seen, maId, actorTtlSeconds)
    if maId > 0 then
        addSpawnTargetCandidates(candidates, seen, mq.TLO.Spawn(maId), 'mainassist')
    end
    addSpawnTargetCandidates(candidates, seen, mq.TLO.Group.MainAssist, 'group_ma')
    addSpawnTargetCandidates(candidates, seen, mq.TLO.Group.MainTank, 'group_mt')
    addSpawnTargetCandidates(candidates, seen, mq.TLO.Group.Leader, 'group_leader')

    local currentTarget = mq.TLO.Target
    if currentTarget and currentTarget() then
        addCandidate(candidates, seen,
            lib.safeNum(function() return currentTarget.ID() end, 0), 'current')
        addSpawnTargetCandidates(candidates, seen, currentTarget, 'current')
    end
    addXTargetCandidates(candidates, seen)

    for _, candidate in ipairs(candidates) do
        local target = validateNpcTarget(worker, candidate.id, candidate.source,
            true, candidate.coordinatedCombat)
        if target then return target end
    end

    local cached = _lastValidByWorker[workerKey(worker)]
    if cached and (lib.getTimeMs() - (cached.seenAt or 0)) <= targetCacheMs then
        return validateNpcTarget(worker, cached.id,
            'cache:' .. tostring(cached.source), false, cached.coordinatedCombat)
    end
    return nil
end

function M.clear(worker)
    _lastValidByWorker[workerKey(worker)] = nil
end

return M
