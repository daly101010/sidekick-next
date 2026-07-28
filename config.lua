-- Process-local feature configuration shared by the UI, coordinator, and every
-- worker. MacroQuest Lua scripts do not share globals, so defaults must be
-- applied from a module that each process loads.

local M = {}

M.defaults = {
    USE_NEW_COLORS = true,
    USE_NEW_COMPONENTS = true,
    USE_NEW_SETTINGS = true,
    VISUAL_REDESIGN = false,
    SETTINGS_REDESIGN = true,
    DEBUG_SETTINGS = false,
    HUMANIZE_BEHAVIOR = true,
    -- The scheduler sees the ten domain workers by default. Set false before
    -- loading SideKick to run the legacy split-worker profile for A/B testing.
    CONSOLIDATED_WORKERS = true,
}

function M.apply(overrides)
    local current = _G.SIDEKICK_NEXT_CONFIG or {}
    for key, value in pairs(M.defaults) do
        if current[key] == nil then current[key] = value end
    end
    for key, value in pairs(overrides or {}) do current[key] = value end
    _G.SIDEKICK_NEXT_CONFIG = current
    return current
end

return M
