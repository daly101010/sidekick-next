-- F:/lua/sidekick-next/sk_start.lua
-- Backward-compatible launcher. The canonical sidekick-next entry point now
-- owns worker startup, supervision, and shutdown.

local mq = require('mq')

-- Wave 1: Heavy scripts that need time to initialize
mq.cmd('/lua run sidekick-next')
