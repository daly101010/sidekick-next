local mq = require('mq')
local Targeting = require('sidekick-next.utils.targeting')

local M = {}

M.TAUNT_RANGE = 30
M.TAUNT_CHASE_RANGE = 60
M.AOE_THRESHOLD = 3

M.TAUNT_CLASSES = {
    PAL = true, SHD = true, WAR = true, RNG = true
}

--- Check if character's class can use Taunt ability
-- @return boolean
function M.canTaunt()
    local class = mq.TLO.Me.Class.ShortName()
    return M.TAUNT_CLASSES[class] == true
end

--- Check if Taunt ability is ready
-- @return boolean
function M.isTauntReady()
    return mq.TLO.Me.AbilityReady('Taunt')() == true
end

--- Find a mob that is attacking a group member (for reactive taunt)
-- @param myId number Tank's spawn ID
-- @return userdata|nil Loose mob spawn or nil
function M.findMobAttackingGroup(myId)
    local range = M.TAUNT_CHASE_RANGE
    local count = mq.TLO.SpawnCount('npc xtarhater radius ' .. range)() or 0

    for i = 1, count do
        local spawn = mq.TLO.NearestSpawn(i, 'npc xtarhater radius ' .. range)
        if spawn and spawn() and not Targeting.isMezzed(spawn) then
            if Targeting.isAttackingGroupMember(spawn, myId) then
                return spawn
            end
        end
    end
    return nil
end

-- Victim-class peel priority: healers first, then casters, then hybrids/melee.
-- A mob beating on the cleric matters more than one on the monk.
M.PEEL_PRIORITY = {
    CLR = 6, DRU = 5, SHM = 5,
    ENC = 4, WIZ = 4, MAG = 4, NEC = 4,
    RNG = 3, BST = 3, BRD = 3,
    PAL = 2, SHD = 2,
    WAR = 1, MNK = 1, ROG = 1, BER = 1,
}

--- Find the most important mob to peel off a group member.
-- Like findMobAttackingGroup, but ranks candidates by how fragile their victim
-- is (healer > caster > hybrid > melee) instead of taking the nearest.
-- @param myId number My spawn ID
-- @param minPriority number|nil Only peel for victims at/above this priority
--        (1 = anyone, 4 = casters and up, 5+ = healers only)
-- @return userdata|nil Best peel target spawn
-- @return number score Victim priority score (0 if none)
function M.findPriorityPeelTarget(myId, minPriority)
    local range = M.TAUNT_CHASE_RANGE
    local count = mq.TLO.SpawnCount('npc xtarhater radius ' .. range)() or 0
    if count == 0 then return nil, 0 end

    -- Member id -> class map (built once per call)
    local memberClass = {}
    for i = 1, mq.TLO.Group.Members() or 0 do
        local member = mq.TLO.Group.Member(i)
        if member and member() then
            local id = member.ID and member.ID() or 0
            if id > 0 then
                local cls = (member.Class and member.Class.ShortName and member.Class.ShortName()) or ''
                memberClass[id] = cls
            end
        end
    end

    minPriority = tonumber(minPriority) or 1

    local best, bestScore = nil, 0
    for i = 1, count do
        local spawn = mq.TLO.NearestSpawn(i, 'npc xtarhater radius ' .. range)
        if spawn and spawn() and not Targeting.isMezzed(spawn) then
            local tot = spawn.TargetOfTarget
            local totId = (tot and tot() and tot.ID()) or 0
            if totId > 0 and totId ~= myId and memberClass[totId] then
                local score = M.PEEL_PRIORITY[memberClass[totId]] or 1
                if score >= minPriority and score > bestScore then
                    best, bestScore = spawn, score
                end
            end
        end
    end
    return best, bestScore
end

--- Count unmezzed mobs in range
-- @param range number Search radius (default 100)
-- @return number Count of unmezzed hostiles
function M.countUnmezzedMobs(range)
    range = range or 100
    local targets = Targeting.getUnmezzedTargets(range)
    return #targets
end

--- Count mobs on XTarget with aggro deficit (PctAggro < 100)
-- @return number Count of mobs needing aggro
function M.countMobsWithAggroDeficit()
    local count = 0
    local xtCount = mq.TLO.Me.XTarget() or 0
    for i = 1, xtCount do
        local xt = mq.TLO.Me.XTarget(i)
        if xt and xt.ID() > 0 then
            local aggro = xt.PctAggro() or 100
            if aggro < 100 then
                count = count + 1
            end
        end
    end
    return count
end

--- Check if tank's aggro lead is low (needs hate gen)
-- @return boolean True if aggro lead is concerning
function M.aggroLeadLow()
    local aggro = mq.TLO.Me.PctAggro() or 100
    local secondary = mq.TLO.Me.SecondaryPctAggro() or 0
    return aggro < 100 or secondary > 80
end

--- Execute taunt ability
function M.doTaunt()
    mq.cmd('/doability taunt')
end

return M
