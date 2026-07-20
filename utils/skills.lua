-- =========================================================================
-- utils/skills.lua
-- Skill discovery for the Skill bar.
-- Loops mq.TLO.Skill(i) for i in 0..147, returning entries where
-- MinLevel > 0 and Activated == true. Result is cached per session;
-- call refresh() to rebuild (e.g., after a level-up).
-- =========================================================================

local mq = require('mq')

local M = {}

local _cache = nil

local function _num(v) return tonumber(v) or 0 end

--- Discover all activated skills the character currently has.
--- @return table[] List of { index, name, minLevel } sorted by name.
function M.discover()
    if _cache then return _cache end
    local out = {}
    for i = 0, 147 do
        -- Some MQ TLOs prefer string indices; try both forms defensively.
        local skill = mq.TLO.Skill(i)
        if not (skill and skill()) then skill = mq.TLO.Skill(tostring(i)) end
        if skill and skill() then
            local minLevel = 0
            local activated = false
            local name = ''
            pcall(function() minLevel = _num(skill.MinLevel and skill.MinLevel()) end)
            pcall(function()
                local a = skill.Activated and skill.Activated()
                activated = (a == true) or (a == 1) or (tostring(a) == 'TRUE') or (tostring(a) == 'true')
            end)
            pcall(function() name = tostring(skill.Name and skill.Name() or '') end)
            if minLevel > 0 and activated and name ~= '' then
                table.insert(out, { index = i, name = name, minLevel = minLevel })
            end
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    _cache = out
    return out
end

--- Force a re-scan on next discover() call.
function M.refresh() _cache = nil end

--- For debugging from /lua console — dumps to chat what was discovered.
function M.dump()
    local list = M.discover()
    if mq and mq.cmd then
        mq.cmdf('/echo \\ag[Skills]\\ax found %d activated skills', #list)
        for _, sk in ipairs(list) do
            mq.cmdf('/echo \\ay  [%d] %s (lvl %d)', sk.index, sk.name, sk.minLevel)
        end
    end
end

return M
