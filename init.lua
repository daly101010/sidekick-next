-- ============================================================
-- SideKick Next - Experimental Branch
-- ============================================================
-- This is the standalone sidekick-next copy for visual redesign
-- experimentation (Approach C from the refactoring plan).
--
-- Run with: /lua run sidekick-next

local BASE = 'sidekick-next.'

-- Feature flags for experimental features
_G.SIDEKICK_NEXT_CONFIG = {
    USE_NEW_COLORS = true,       -- Use ui/colors.lua for theme-aware colors
    USE_NEW_COMPONENTS = true,   -- Use ui/components/ for reusable widgets
    USE_NEW_SETTINGS = true,     -- Use ui/settings/ modular tab system
    VISUAL_REDESIGN = false,     -- Placeholder for C experiments
    DEBUG_SETTINGS = false,      -- Log ImGui setting interactions (dev)
    HUMANIZE_BEHAVIOR = true,   -- Behavioral humanization layer (humanize/). Off = byte-identical to baseline.
}

-- Helper for require with base path (optional, modules can use relative requires)
_G.SK_NEXT_REQUIRE = function(path)
    return require(BASE .. path)
end

-- Load main module
local main = require(BASE .. 'SideKick')

if type(main) == 'function' then
    main()
end
return main
