-- ============================================================
-- SideKick Next - Experimental Branch
-- ============================================================
-- This is the standalone sidekick-next copy for visual redesign
-- experimentation (Approach C from the refactoring plan).
--
-- Run with: /lua run sidekick-next

local BASE = 'sidekick-next.'
local Supervisor = require(BASE .. 'utils.supervisor')

-- Feature flags for experimental features
_G.SIDEKICK_NEXT_CONFIG = {
    USE_NEW_COLORS = true,       -- Use ui/colors.lua for theme-aware colors
    USE_NEW_COMPONENTS = true,   -- Use ui/components/ for reusable widgets
    USE_NEW_SETTINGS = true,     -- Use ui/settings/ modular tab system
    VISUAL_REDESIGN = false,     -- Placeholder for C experiments
    DEBUG_SETTINGS = false,      -- Log ImGui setting interactions (dev)
    HUMANIZE_BEHAVIOR = true,   -- Behavioral humanization layer (humanize/). Off = byte-identical to baseline.
    IS_UI_PROCESS = true,       -- Only the UI entry sets this; worker processes
                                -- never do. Gates process-global registrations
                                -- like slash-command binds (MQ binds are global
                                -- per client, not per Lua script).
}

-- Helper for require with base path (optional, modules can use relative requires)
_G.SK_NEXT_REQUIRE = function(path)
    return require(BASE .. path)
end

-- Load main module
local main = require(BASE .. 'SideKick')

if type(main) == 'function' then
    local ok, err = xpcall(function()
        Supervisor.start()
        main()
    end, debug.traceback)
    pcall(Supervisor.stop)
    if not ok then error(err, 0) end
end
return main
