-- healing/init.lua
-- Healing Intelligence module entry point for SideKick
-- Provides deficit-based heal selection, learned heal amounts, spell ducking, and multi-healer coordination

local mq = require('mq')

local M = {}

local _initialized = false

--- Initialize the Healing Intelligence subsystem
-- Loads configuration and learned heal data, sets up actor message handlers
function M.init()
    if _initialized then return end
    _initialized = true
    print('[Healing] Initialized')
end

--- Main tick function for healing decisions
-- Called each frame/tick by the main SideKick loop
-- @param settings table The current SideKick settings
-- @return boolean True if priority healing is active (should skip lower priority actions)
function M.tick(settings)
    -- Stub: returns false (no priority healing active)
    return false
end

--- Process incoming actor messages for heal coordination
-- Handles claim broadcasts, HoT tracking, and multi-healer synchronization
function M.tickActors()
    -- Stub: process actor messages
end

--- Shutdown the Healing Intelligence subsystem
-- Saves learned heal data and cleans up resources
function M.shutdown()
    print('[Healing] Shutdown')
end

return M
