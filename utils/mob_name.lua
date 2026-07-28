-- Shared name validation for persisted NPC intelligence.
--
-- EverQuest can retain a killed NPC under the same spawn ID while changing
-- its clean name to "<mob>'s corpse". Intelligence recorded after that
-- transition must not create a second knowledge row for the corpse.

local M = {}

local function trimmed(value)
    return tostring(value or ''):match('^%s*(.-)%s*$')
end

--- Return the original NPC name when value is an EQ corpse clean name.
-- The optional numeric suffix matches corpse variants already handled by the
-- resurrection worker. Plain live NPC names such as "a corpse" are preserved.
function M.corpseBaseName(value)
    local name = trimmed(value)
    if name == '' then return nil end
    local suffixAt = name:lower():match("()'s corpse%d*$")
    if not suffixAt then return nil end
    local base = trimmed(name:sub(1, suffixAt - 1))
    return base ~= '' and base or nil
end

function M.isCorpseName(value)
    return M.corpseBaseName(value) ~= nil
end

function M.isKnowledgeName(value)
    local name = trimmed(value)
    return name ~= '' and not M.isCorpseName(name)
end

return M
