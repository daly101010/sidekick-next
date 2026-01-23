-- ============================================================
-- SideKick UI Components Demo Launcher
-- ============================================================
-- Run with: /lua run sidekick-next/component_demo
--
-- This opens an interactive window showcasing all available
-- UI components with live theme switching.

local mq = require('mq')

print('\ay[Demo]\ax Starting component demo...')

local ok, err = pcall(function()
    local Demo = require('sidekick-next.ui.components.demo')
    print('\ay[Demo]\ax Module loaded, calling run()...')
    Demo.run()
end)

if not ok then
    print('\ar[Demo] ERROR:\ax ' .. tostring(err))
    -- Keep window open to see error
    mq.delay(10000)
end
