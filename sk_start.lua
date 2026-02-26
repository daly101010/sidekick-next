-- F:/lua/sidekick-next/sk_start.lua
-- Convenience script to launch SideKick UI + all coordinator modules

local mq = require('mq')

local function log(msg)
    -- In-game echo disabled
end

local modules = {
    'sidekick-next/init',
    'sidekick-next/sk_coordinator',
    'sidekick-next/sk_emergency',
    'sidekick-next/sk_healing_emergency',
    'sidekick-next/sk_healing',
    'sidekick-next/sk_dps',
    'sidekick-next/sk_buffs',
    'sidekick-next/sk_meditation',
}

local function startAll()
    for _, mod in ipairs(modules) do
        mq.cmdf('/lua run %s', mod)
        mq.delay(100) -- Brief delay between launches
    end
end

startAll()
