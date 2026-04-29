-- Compatibility shim — the heal preview was expanded into the full
-- orchestration dashboard (see ui/dashboard.lua). This module re-exports
-- the dashboard's API under the old names so existing slash-command
-- registrations and persisted settings keep working.

local Dashboard = require('sidekick-next.ui.dashboard')

local M = {}

function M.register()
    Dashboard.register_window()
end

function M.isVisible() return Dashboard.isVisible() end
function M.setVisible(v) Dashboard.setVisible(v) end
function M.toggle()      Dashboard.toggle() end
function M.draw()        Dashboard.draw() end

return M
