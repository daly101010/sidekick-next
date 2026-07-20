-- Compatibility shim for callers that still require the former UI-host
-- meditation automation. The authoritative implementation is sk_meditation;
-- keeping this module side-effect free prevents a second sit/stand owner.

local M = {}

function M.tick()
    return false, 'retired_use_sk_meditation'
end

function M.getState()
    return {
        retired = true,
        reason = 'coordinator_worker',
        script = 'sidekick-next/sk_meditation',
    }
end

return M
