local mq = require('mq')
local Targeting = require('utils.targeting')

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
