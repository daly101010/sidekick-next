-- automation/pull/scan.lua
-- Spawn-search pipeline. Filters live mobs through level/con/list/distance/
-- path checks and sorts by nav path length. Returns the closest pullable
-- target ID, or 0 if none.

local mq = require('mq')

local M = {}

-- Helpers ---------------------------------------------------------------------

local function listContains(list, name)
    if type(list) ~= 'table' or not name then return false end
    name = string.lower(tostring(name))
    for _, v in ipairs(list) do
        if string.lower(tostring(v)) == name then return true end
    end
    -- Also accept map-style { ['name'] = true }
    for k, v in pairs(list) do
        if v and type(k) == 'string' and string.lower(k) == name then return true end
    end
    return false
end

local function distSq(x1, y1, x2, y2)
    local dx, dy = x1 - x2, y1 - y2
    return dx * dx + dy * dy
end

local function isTargetable(spawn)
    if not spawn() then return false end
    -- spawn.Targetable() exists in MQ; default to true if missing.
    if spawn.Targetable and spawn.Targetable() == false then return false end
    return true
end

local function isCharmedPet(spawn)
    if not spawn.Master then return false end
    local master = spawn.Master
    if not master or not master() then return false end
    return master.Type and master.Type() == 'PC'
end

-- Con color mapping. EQ con returns colors like 'GREEN', 'LIGHT BLUE',
-- 'BLUE', 'WHITE', 'YELLOW', 'RED'. Map to a level for range comparisons.
local CON_RANK = {
    GREY = 1, GREEN = 2, ['LIGHT BLUE'] = 3, BLUE = 4,
    WHITE = 5, YELLOW = 6, RED = 7,
}

local function conRank(spawn)
    local c = spawn.ConColor and spawn.ConColor() or ''
    return CON_RANK[string.upper(c)] or 0
end

-- Public ----------------------------------------------------------------------

-- Returns { sortedIds = {id1, id2, ...}, meta = { [id] = {distance=...} } }
function M.scan(cfg)
    cfg = cfg or {}
    local me = mq.TLO.Me
    if not (me and me()) then return { sortedIds = {}, meta = {} } end

    local checkX = cfg.checkX or me.X() or 0
    local checkY = cfg.checkY or me.Y() or 0
    local checkZ = cfg.checkZ or me.Z() or 0
    local pullRadius = cfg.pullRadius or 200
    local pullZRadius = cfg.pullZRadius or 100
    local maxLevelDiff = cfg.maxLevelDiff or 3
    local minLevel = cfg.minLevel or 1
    local maxLevel = cfg.maxLevel or 999
    local useLevels = cfg.useLevels == true
    local minCon = cfg.minCon or CON_RANK.GREEN
    local maxCon = cfg.maxCon or CON_RANK.RED
    local allowList = cfg.allowList or {}
    local denyList = cfg.denyList or {}
    local ignoreSet = cfg.ignoreSet or {}     -- map: { [spawnId] = expireMs }
    local pullMobsInWater = cfg.pullMobsInWater == true
    local maxPathRange = cfg.maxPathRange or 0  -- 0 = use PathExists only
    local skipXTHaters = cfg.skipXTHaters == true  -- chain mode

    local radiusSq = pullRadius * pullRadius
    local meLevel = me.Level() or 1

    -- Build a quick xtarget hater set when chain mode.
    local xtSet = {}
    if skipXTHaters then
        local n = me.XTarget() or 0
        for i = 1, n do
            local x = me.XTarget(i)
            if x and x() and x.ID and x.ID() and x.ID() > 0 then
                xtSet[x.ID()] = true
            end
        end
    end

    -- Iterate NPCs only via the spawn-search filter.
    local count = mq.TLO.SpawnCount('npc')() or 0

    local results = {}
    local nowMs = mq.gettime() or 0

    for i = 1, count do
        local spawn = mq.TLO.NearestSpawn(i, 'npc')
        if spawn and spawn() then
            local id = spawn.ID() or 0
            if id > 0 and isTargetable(spawn) then
                local sType = spawn.Type and spawn.Type() or ''
                if sType == 'NPC' or sType == 'NPCPET' then
                    local pass = true

                    -- Charmed pets: skip
                    if isCharmedPet(spawn) then pass = false end

                    -- Chain mode: skip already on xtarget
                    if pass and skipXTHaters and xtSet[id] then pass = false end

                    -- Allow/deny lists
                    if pass then
                        local cleanName = spawn.CleanName and spawn.CleanName() or ''
                        if #allowList > 0 then
                            if not listContains(allowList, cleanName) then pass = false end
                        elseif #denyList > 0 then
                            if listContains(denyList, cleanName) then pass = false end
                        end
                    end

                    -- Ignore set (failed/blacklisted at runtime)
                    if pass then
                        local exp = ignoreSet[id]
                        if exp and exp > nowMs then pass = false end
                    end

                    -- Water
                    if pass and not pullMobsInWater then
                        local wet = spawn.FeetWet and spawn.FeetWet() or false
                        if wet then pass = false end
                    end

                    -- Level / con
                    if pass then
                        local lvl = spawn.Level and spawn.Level() or 1
                        if useLevels then
                            if lvl < minLevel or lvl > maxLevel then pass = false end
                        else
                            local cr = conRank(spawn)
                            if cr < minCon or cr > maxCon then pass = false end
                            if maxLevelDiff > 0 and (lvl - meLevel) > maxLevelDiff then pass = false end
                        end
                    end

                    -- Distance
                    if pass then
                        local sx = spawn.X() or 0
                        local sy = spawn.Y() or 0
                        local sz = spawn.Z() or 0
                        if math.abs(sz - checkZ) > pullZRadius then pass = false end
                        if pass and distSq(sx, sy, checkX, checkY) > radiusSq then pass = false end
                    end

                    -- Path
                    if pass then
                        local navDist = 0
                        local pathOk = false
                        if mq.TLO.Navigation and mq.TLO.Navigation.PathLength then
                            navDist = mq.TLO.Navigation.PathLength('id ' .. id)() or 0
                            pathOk = navDist > 0
                            if maxPathRange > 0 and navDist > maxPathRange then pathOk = false end
                        else
                            local pe = mq.TLO.Navigation and mq.TLO.Navigation.PathExists
                            pathOk = pe and pe('id ' .. id)() == true
                        end
                        if not pathOk then pass = false end
                        if pass then
                            table.insert(results, { id = id, distance = navDist })
                        end
                    end
                end
            end
        end
    end

    table.sort(results, function(a, b) return a.distance < b.distance end)

    local sortedIds = {}
    local meta = {}
    for _, r in ipairs(results) do
        table.insert(sortedIds, r.id)
        meta[r.id] = { distance = r.distance }
    end
    return { sortedIds = sortedIds, meta = meta }
end

return M
