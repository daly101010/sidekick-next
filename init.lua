-- ============================================================
-- SideKick Next - Experimental Branch
-- ============================================================
-- This is the standalone sidekick-next copy for visual redesign
-- experimentation (Approach C from the refactoring plan).
--
-- Run with: /lua run sidekick-next

local BASE = 'sidekick-next.'
local Config = require(BASE .. 'config')
Config.apply({ IS_UI_PROCESS = true })
local Supervisor = require(BASE .. 'utils.supervisor')

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
