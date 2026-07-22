-- F:/lua/sidekick-next/utils/action_counters.lua
-- Session action counters for self-verification: "is the automation actually
-- doing things?" Counters are bumped in whichever process performs the act;
-- each worker's snapshot rides its existing module heartbeat into the
-- coordinator's moduleDiag (UI-only payload), so the Activity tab costs zero
-- additional actor sends.

local M = {}

M.counts = {}

--- Increment a named counter.
function M.bump(key, n)
    if not key or key == '' then return end
    M.counts[key] = (M.counts[key] or 0) + (tonumber(n) or 1)
end

--- Counters table for heartbeat embedding, or nil when nothing happened yet
--- (keeps idle heartbeats byte-identical to before).
function M.snapshot()
    if next(M.counts) == nil then return nil end
    return M.counts
end

return M
