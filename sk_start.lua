-- F:/lua/sidekick-next/sk_start.lua
-- Convenience script to launch SideKick UI + all coordinator modules
--
-- Scripts are launched in two waves to prevent MQ frame stalling:
--   Wave 1: Main UI + coordinator (heavy init, given time to complete)
--   Wave 2: Lightweight coordinator modules (smaller, launch quickly)

local mq = require('mq')

-- Wave 1: Heavy scripts that need time to initialize
local wave1 = {
    'sidekick-next/init',          -- Main UI (heaviest: eager requires + Core.load + module inits)
}

-- Wave 2: Coordinator modules (lighter, but each still does sync init)
local wave2 = {
    'sidekick-next/sk_coordinator',
    'sidekick-next/sk_emergency',
    'sidekick-next/sk_healing_emergency',
    'sidekick-next/sk_healing',
    'sidekick-next/sk_dps',
    'sidekick-next/sk_buffs',
    'sidekick-next/sk_meditation',
    'sidekick-next/sk_resurrection',  -- self-gates on rez-class membership
    'sidekick-next/sk_disciplines',   -- self-gates on class having disciplines
}

local function startAll()
    -- Wave 1: Launch main UI and give it time to finish heavy init
    for _, mod in ipairs(wave1) do
        mq.cmdf('/lua run %s', mod)
        mq.delay(500)
    end

    -- Wave 2: Launch coordinator modules with shorter delays
    for _, mod in ipairs(wave2) do
        mq.cmdf('/lua run %s', mod)
        mq.delay(200)
    end
end

startAll()
