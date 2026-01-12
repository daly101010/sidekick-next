local mq = require('mq')

local M = {}

-- Ported from Medley: these are "special" utility AAs that should live in their own window
-- and should not appear in the per-class discovered AA list/settings UI.
M.DEFS = {
    { altID = 483, altName = 'Expedient Recovery', icon = 109, kind = 'aa' },
    { altID = 484, altName = 'Chaotic Jester', icon = 167, kind = 'aa' },
    { altID = 481, altName = 'Lesson of the Devoted', icon = 12, kind = 'aa' },
    { altID = 486, altName = 'Staunch Recovery', icon = 119, kind = 'aa' },
    { altID = 485, altName = 'Steadfast Servant', icon = 167, kind = 'aa' },
    { altID = 511, altName = 'Throne of Heroes', icon = 129, kind = 'aa' },
    { altID = 331, altName = 'Origin', icon = 129, kind = 'aa' },
}

local function hasMeAA(idOrName)
    if not mq.TLO.Me or not mq.TLO.Me.AltAbility then return false end
    local aa = mq.TLO.Me.AltAbility(idOrName)
    return aa and aa() ~= nil
end

function M.excludedAltIDs()
    local s = {}
    for _, def in ipairs(M.DEFS) do
        if def.altID then s[tonumber(def.altID)] = true end
    end
    return s
end

function M.excludedNames()
    local s = {}
    for _, def in ipairs(M.DEFS) do
        if def.altName then s[tostring(def.altName):lower()] = true end
    end
    return s
end

function M.getTrained()
    local out = {}
    for _, def in ipairs(M.DEFS) do
        local trained = false
        if def.altID then
            trained = hasMeAA(tonumber(def.altID))
        elseif def.altName then
            trained = hasMeAA(def.altName)
        end

        if trained then
            table.insert(out, def)
        end
    end
    return out
end

return M

