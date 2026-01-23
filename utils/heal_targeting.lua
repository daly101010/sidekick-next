local mq = require('mq')

local RuntimeCache = require('sidekick-next.utils.runtime_cache')

local M = {}

local function safeNum(fn, fallback)
    local ok, v = pcall(fn)
    if not ok then return fallback end
    return tonumber(v) or fallback
end

local function splitSlots(s)
    s = tostring(s or '')
    if s == '' then return {} end
    local out = {}
    for token in s:gmatch('[^|]+') do
        local n = tonumber(token)
        if n and n >= 1 and n <= 20 then
            table.insert(out, n)
        end
    end
    return out
end

local function isHealableType(spawn)
    if not (spawn and spawn()) then return false end
    local t = tostring(spawn.Type and spawn.Type() or ''):lower()
    return t == 'pc' or t == 'mercenary' or t == 'pet'
end

local function isDead(spawn)
    if not (spawn and spawn()) then return true end
    if spawn.Dead then
        local ok, v = pcall(function() return spawn.Dead() end)
        if ok and v == true then return true end
    end
    return false
end

function M.groupInjuredCount(threshold)
    threshold = tonumber(threshold) or 75
    if RuntimeCache and RuntimeCache.injuredGroupCount then
        return RuntimeCache.injuredGroupCount(threshold) or 0
    end
    local cnt = 0
    local members = tonumber(mq.TLO.Group.Members()) or 0
    for i = 1, members do
        local m = mq.TLO.Group.Member(i)
        if m and m() and not m.Offline() and not m.OtherZone() and not m.Dead() then
            local hp = safeNum(function() return m.PctHPs() end, 100)
            if hp < threshold then cnt = cnt + 1 end
        end
    end
    return cnt
end

function M.findWorstGroupTarget(minHpPct)
    minHpPct = tonumber(minHpPct) or 100
    local worst = { id = 0, hp = minHpPct, kind = 'pc', ownerId = 0 }

    local myId = safeNum(function() return mq.TLO.Me.ID() end, 0)
    local bestSelf = safeNum(function() return mq.TLO.Me.PctHPs() end, 100)
    if bestSelf < worst.hp then
        worst.id = myId
        worst.hp = bestSelf
        worst.kind = 'pc'
        worst.ownerId = 0
    end

    local members = tonumber(mq.TLO.Group.Members()) or 0
    for i = 1, members do
        local m = mq.TLO.Group.Member(i)
        if m and m() and not m.Offline() and not m.OtherZone() and not m.Dead() then
            local hp = safeNum(function() return m.PctHPs() end, 100)
            if hp < worst.hp then
                worst.id = safeNum(function() return m.ID() end, 0)
                worst.hp = hp
                worst.kind = 'pc'
                worst.ownerId = 0
            end
        end
    end

    return worst.id > 0 and worst or nil
end

function M.findWorstPetTarget(minHpPct)
    minHpPct = tonumber(minHpPct) or 100
    local worst = { id = 0, hp = minHpPct, kind = 'pet', ownerId = 0 }

    local members = tonumber(mq.TLO.Group.Members()) or 0
    for i = 1, members do
        local m = mq.TLO.Group.Member(i)
        if m and m() and not m.Offline() and not m.OtherZone() then
            local pet = m.Pet
            local petId = safeNum(function() return pet and pet.ID and pet.ID() end, 0)
            if petId > 0 then
                local hp = safeNum(function() return pet.PctHPs() end, 100)
                if hp < worst.hp then
                    worst.id = petId
                    worst.hp = hp
                    worst.kind = 'pet'
                    worst.ownerId = safeNum(function() return m.ID() end, 0)
                end
            end
        end
    end

    return worst.id > 0 and worst or nil
end

function M.findWorstXTarget(slots, minHpPct, includePets)
    minHpPct = tonumber(minHpPct) or 100
    includePets = includePets == true
    local parsed = splitSlots(slots)
    if #parsed == 0 then return nil end

    local worst = { id = 0, hp = minHpPct, kind = 'pc', ownerId = 0, slot = 0 }
    for _, slot in ipairs(parsed) do
        local xt = mq.TLO.Me.XTarget(slot)
        if xt and xt() and isHealableType(xt) and not isDead(xt) then
            local typ = tostring(xt.Type and xt.Type() or ''):lower()
            if typ ~= 'pet' or includePets then
                local hp = safeNum(function() return xt.PctHPs() end, 100)
                if hp < worst.hp then
                    worst.id = safeNum(function() return xt.ID() end, 0)
                    worst.hp = hp
                    worst.kind = typ
                    worst.slot = slot
                    worst.ownerId = 0
                end
            end
        end
    end

    return worst.id > 0 and worst or nil
end

function M.getMainAssistTarget()
    local ma = mq.TLO.Group and mq.TLO.Group.MainAssist
    if ma and ma() then
        local id = safeNum(function() return ma.ID() end, 0)
        if id > 0 then
            local hp = safeNum(function() return ma.PctHPs() end, 100)
            return { id = id, hp = hp, kind = 'pc', ownerId = 0 }
        end
    end
    return nil
end

return M

