-- F:/lua/SideKick/sk_start.lua
-- Convenience script to launch all SideKick modules

local mq = require('mq')

local function log(msg)
    -- In-game echo disabled
end

local modules = {
    'sidekick/sk_coordinator',
    'sidekick/sk_emergency',
    'sidekick/sk_healing',
    'sidekick/sk_dps',
}

local function startAll()
    log('Starting SideKick multi-script system...')

    for _, mod in ipairs(modules) do
        log(string.format('Starting %s...', mod))
        mq.cmdf('/lua run %s', mod)
        mq.delay(100) -- Brief delay between launches
    end

    log('All modules launched. Use /lua list to verify.')
end

local function stopAll()
    log('Stopping SideKick multi-script system...')

    for _, mod in ipairs(modules) do
        log(string.format('Stopping %s...', mod))
        mq.cmdf('/lua stop %s', mod)
    end

    log('All modules stopped.')
end

-- Command binding
mq.bind('/sidekick', function(cmd)
    if cmd == 'start' then
        startAll()
    elseif cmd == 'stop' then
        stopAll()
    elseif cmd == 'restart' then
        stopAll()
        mq.delay(500)
        startAll()
    elseif cmd == 'status' then
        log('Use /lua list to see running modules')
    else
        log('Usage: /sidekick start|stop|restart|status')
    end
end)

log('SideKick launcher loaded. Use /sidekick start|stop|restart')

-- Keep script alive so command binding persists
while mq.TLO.MacroQuest.GameState() == 'INGAME' do
    mq.delay(1000)
end
