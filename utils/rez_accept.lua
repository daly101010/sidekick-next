-- Retired compatibility shim for resurrection acceptance.
--
-- The coordinated sk_resurrection worker detects and accepts resurrection
-- offers under the single action lease. Legacy callers may still require this
-- module, but it deliberately performs no gameplay mutation.

local M = {}

function M.init()
    return true
end

function M.tick()
    return false, 'worker_owned'
end

return M
