-- Compatibility shim. Emergency and normal healing now share one authoritative
-- runtime so target state, incoming heals, events, and persistence cannot split.
local mq = require('mq')

printf('\ay[SideKick]\ax sk_healing_emergency is retired; sk_healing handles dynamic emergency priority.')
mq.cmd('/lua run sidekick-next/sk_healing')

return { deprecated = true }
