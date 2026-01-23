local mq = require('mq')
local Cache = require('sidekick-next.utils.runtime_cache')
local Actors = require('sidekick-next.utils.actors_coordinator')

local M = {}

-- Settings reference (set via init or passed to functions)
M.settings = nil

--- Check if a spawn is a PC's pet
-- @param spawnId number Spawn ID to check
-- @return boolean True if spawn is a pet owned by a PC
function M.isPCPet(spawnId)
    if not spawnId or spawnId == 0 then return false end

    local spawn = mq.TLO.Spawn(spawnId)
    if not spawn or not spawn() then return false end

    -- Check if spawn has a master
    local master = spawn.Master
    if not master or not master() then return false end

    -- Check if master is a PC
    local masterType = master.Type()
    return masterType == 'PC'
end

--- Initialize targeting module with settings reference
-- @param settings table Settings table
function M.init(settings)
    M.settings = settings
end

--- Check if spawn is a named mob
-- @param spawn userdata Spawn TLO
-- @return boolean
function M.isNamed(spawn)
    if not spawn or not spawn() then return false end
    return spawn.Named() == true or spawn.Body() == 'Giant'
end

--- Check if spawn is mezzed
-- @param spawn userdata Spawn TLO
-- @return boolean
function M.isMezzed(spawn)
    if not spawn or not spawn() then return false end
    local mezzed = spawn.Mezzed
    return mezzed and mezzed() and mezzed() ~= ''
end

--- Check if spawn is attacking a group member (not the tank)
-- @param spawn userdata Spawn TLO
-- @param myId number Tank's spawn ID
-- @return boolean
function M.isAttackingGroupMember(spawn, myId)
    if not spawn or not spawn() then return false end
    local tot = spawn.TargetOfTarget
    if not tot or not tot() then return false end
    local totId = tot.ID()
    if totId == myId then return false end
    -- Check if target is a group member
    for i = 1, mq.TLO.Group.Members() or 0 do
        local member = mq.TLO.Group.Member(i)
        if member and member.ID() == totId then
            return true
        end
    end
    return false
end

--- Check if a spawn ID belongs to our group
-- @param spawnId number Spawn ID to check
-- @return boolean True if spawn is in our group
local function isInGroup(spawnId)
    if not spawnId or spawnId == 0 then return false end

    -- Check self
    local myId = Cache.me.id or (mq.TLO.Me.ID and mq.TLO.Me.ID()) or 0
    if spawnId == myId then return true end

    -- Check group members from cache
    for _, member in pairs(Cache.group.members or {}) do
        if member.id == spawnId then return true end
        -- Also check member pets
        if member.pet and member.pet.id == spawnId then return true end
    end

    -- Check self pet
    if Cache.me.pet and Cache.me.pet.id == spawnId then return true end

    return false
end

--- Check if a spawn ID belongs to our raid
-- @param spawnId number Spawn ID to check
-- @return boolean True if spawn is in our raid
local function isInRaid(spawnId)
    if not spawnId or spawnId == 0 then return false end

    local raidCount = tonumber(mq.TLO.Raid.Members()) or 0
    if raidCount == 0 then return false end

    for i = 1, raidCount do
        local member = mq.TLO.Raid.Member(i)
        if member and member() then
            local spawn = member.Spawn
            if spawn and spawn() and spawn.ID then
                local memberId = tonumber(spawn.ID()) or 0
                if memberId == spawnId then return true end
                -- Check raid member pets
                local pet = spawn.Pet
                if pet and pet() and pet.ID then
                    local petId = tonumber(pet.ID()) or 0
                    if petId == spawnId then return true end
                end
            end
        end
    end

    return false
end

--- Check if a spawn ID belongs to a known actor peer (SideKick instance)
-- Only checks peers in the same zone for safety
-- @param spawnId number Spawn ID to check
-- @return boolean True if spawn is a known peer in same zone
local function isActorPeer(spawnId)
    if not spawnId or spawnId == 0 then return false end

    local remotes = Actors.getRemoteCharacters()
    if not remotes then return false end

    local myZone = Actors.getCurrentZone and Actors.getCurrentZone() or ''

    -- Build a set of known peer spawn IDs (only same zone)
    for charName, data in pairs(remotes) do
        -- Only consider peers in the same zone
        local peerZone = data.zone or ''
        if myZone ~= '' and peerZone ~= '' and myZone ~= peerZone then
            goto continue
        end

        -- Get spawn ID for this character name
        local spawn = mq.TLO.Spawn('pc =' .. charName)
        if spawn and spawn() and spawn.ID then
            local peerId = tonumber(spawn.ID()) or 0
            if peerId == spawnId then return true end
            -- Also check peer's pet
            local pet = spawn.Pet
            if pet and pet() and pet.ID then
                local petId = tonumber(pet.ID()) or 0
                if petId == spawnId then return true end
            end
        end
        ::continue::
    end

    return false
end

--- Check if a target is safe to attack (not KS-ing someone else's mob)
-- A target is safe if:
-- 1. It has no target (not engaged with anyone)
-- 2. Its target is one of: our group members, raid members, or actor peers
--
-- @param spawnId number Spawn ID to check
-- @param settings table Optional settings override (uses M.settings if nil)
-- @return boolean True if safe to attack
-- @return string|nil Reason if not safe
function M.isSafeTarget(spawnId, settings)
    settings = settings or M.settings or {}

    -- If safe targeting is disabled, everything is safe
    if settings.SafeTargetingEnabled == false then
        return true, nil
    end

    if not spawnId or spawnId == 0 then
        return false, 'invalid spawn id'
    end

    local spawn = mq.TLO.Spawn(spawnId)
    if not spawn or not spawn() then
        return false, 'spawn not found'
    end

    -- Get the target's target (who is this mob fighting?)
    local tot = spawn.TargetOfTarget
    if not tot or not tot() then
        -- Target has no target - it's safe (not engaged with anyone)
        return true, nil
    end

    local totId = tonumber(tot.ID()) or 0
    if totId == 0 then
        -- No valid target of target - safe
        return true, nil
    end

    -- Check if target's target is in our group (always checked)
    if isInGroup(totId) then
        return true, nil
    end

    -- Check if target's target is in our raid (if enabled)
    if settings.SafeTargetingCheckRaid ~= false then
        if isInRaid(totId) then
            return true, nil
        end
    end

    -- Check if target's target is one of our actor peers (if enabled)
    if settings.SafeTargetingCheckPeers ~= false then
        if isActorPeer(totId) then
            return true, nil
        end
    end

    -- Target's target is someone else - not safe (would be KS)
    local totName = tot.CleanName() or 'unknown'
    return false, string.format('target is fighting %s (not in group/raid/peers)', totName)
end

--- Score a target for priority (higher = more important)
-- @param spawn userdata Spawn TLO
-- @param myId number Tank's spawn ID
-- @param settings table Optional settings for safe targeting check
-- @return number Score (-1 if invalid target)
-- @return string|nil Reason if target was rejected
function M.scoreTarget(spawn, myId, settings)
    if not spawn or not spawn() then return -1, 'invalid spawn' end
    if spawn.Type() ~= 'NPC' then return -1, 'not NPC' end
    if spawn.Dead() then return -1, 'dead' end

    -- Check safe targeting (KS prevention)
    local spawnId = spawn.ID() or 0
    local isSafe, reason = M.isSafeTarget(spawnId, settings)
    if not isSafe then
        return -1, reason
    end

    local score = 0

    -- Named = highest priority
    if M.isNamed(spawn) then
        score = score + 1000
    end

    -- Attacking group member = high priority
    if M.isAttackingGroupMember(spawn, myId) then
        score = score + 500
    end

    -- Lower HP = higher priority (finish off wounded)
    local hp = spawn.PctHPs() or 100
    score = score + (100 - hp)

    return score, nil
end

--- Get all unmezzed hostile targets in range
-- @param range number Search radius (default 100)
-- @return table Array of spawn TLOs
function M.getUnmezzedTargets(range)
    range = range or 100
    local targets = {}
    local count = mq.TLO.SpawnCount('npc xtarhater radius ' .. range)() or 0
    for i = 1, count do
        local spawn = mq.TLO.NearestSpawn(i, 'npc xtarhater radius ' .. range)
        if spawn and spawn() and not M.isMezzed(spawn) then
            table.insert(targets, spawn)
        end
    end
    return targets
end

--- Get all mezzed hostile targets in range
-- @param range number Search radius (default 100)
-- @return table Array of spawn TLOs
function M.getMezzedTargets(range)
    range = range or 100
    local targets = {}
    local count = mq.TLO.SpawnCount('npc xtarhater radius ' .. range)() or 0
    for i = 1, count do
        local spawn = mq.TLO.NearestSpawn(i, 'npc xtarhater radius ' .. range)
        if spawn and spawn() and M.isMezzed(spawn) then
            table.insert(targets, spawn)
        end
    end
    return targets
end

-- Track recently skipped targets to avoid log spam
local _skippedTargetLog = {}  -- [spawnId] = lastLogTime
local SKIP_LOG_COOLDOWN = 5.0  -- Only log once per 5 seconds per target

--- Select the best target based on priority
-- Priority: Named > Attacking group > Lowest HP
-- Falls back to breaking mez on lowest HP if no unmezzed targets
-- Skips targets that fail safe targeting check (KS prevention)
-- @param myId number Tank's spawn ID
-- @param range number Search radius (default 100)
-- @param settings table Optional settings for safe targeting
-- @return userdata|nil Best target spawn or nil
function M.selectBestTarget(myId, range, settings)
    settings = settings or M.settings or {}
    local unmezzed = M.getUnmezzedTargets(range)
    local now = os.clock()

    if #unmezzed > 0 then
        -- Filter and score targets, logging skipped ones
        local scoredTargets = {}
        for _, spawn in ipairs(unmezzed) do
            local score, reason = M.scoreTarget(spawn, myId, settings)
            if score >= 0 then
                table.insert(scoredTargets, { spawn = spawn, score = score })
            elseif reason and reason:find('fighting') then
                -- Log skipped target due to safe targeting (with cooldown)
                local spawnId = spawn.ID() or 0
                local lastLog = _skippedTargetLog[spawnId] or 0
                if (now - lastLog) >= SKIP_LOG_COOLDOWN then
                    _skippedTargetLog[spawnId] = now
                    local name = spawn.CleanName() or 'Unknown'
                    -- Echo disabled
                end
            end
        end

        -- Sort by score descending
        if #scoredTargets > 0 then
            table.sort(scoredTargets, function(a, b)
                return a.score > b.score
            end)
            return scoredTargets[1].spawn
        end
    end

    -- No unmezzed targets - break mez on lowest HP (still check safe targeting)
    local mezzed = M.getMezzedTargets(range)
    if #mezzed > 0 then
        -- Filter by safe targeting
        local safeTargets = {}
        for _, spawn in ipairs(mezzed) do
            local spawnId = spawn.ID() or 0
            local isSafe, reason = M.isSafeTarget(spawnId, settings)
            if isSafe then
                table.insert(safeTargets, spawn)
            elseif reason and reason:find('fighting') then
                -- Log skipped target (with cooldown)
                local lastLog = _skippedTargetLog[spawnId] or 0
                if (now - lastLog) >= SKIP_LOG_COOLDOWN then
                    _skippedTargetLog[spawnId] = now
                    local name = spawn.CleanName() or 'Unknown'
                    -- Echo disabled
                end
            end
        end

        if #safeTargets > 0 then
            table.sort(safeTargets, function(a, b)
                return (a.PctHPs() or 100) < (b.PctHPs() or 100)
            end)
            return safeTargets[1]
        end
    end

    return nil
end

--- Clean up stale entries from skipped target log
function M.cleanupSkippedLog()
    local now = os.clock()
    for spawnId, lastLog in pairs(_skippedTargetLog) do
        if (now - lastLog) > 30 then  -- Remove entries older than 30 seconds
            _skippedTargetLog[spawnId] = nil
        end
    end
end

--- Target a spawn by ID (non-blocking)
-- @param spawn userdata Spawn TLO
-- @return boolean True if command issued (check target on next tick)
function M.targetSpawn(spawn)
    if not spawn or not spawn() then return false end
    local id = spawn.ID()
    if not id or id == 0 then return false end
    mq.cmdf('/target id %d', id)
    -- Non-blocking: caller should verify target on next tick if needed
    return true
end

return M
