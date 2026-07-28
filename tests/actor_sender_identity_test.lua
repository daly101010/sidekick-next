package.path = '../?.lua;../?/init.lua;' .. package.path

package.loaded.mq = {
    gettime = function() return 1000 end,
    TLO = {},
}

local lib = require('sidekick-next.sk_lib')

local script, actor = lib.actorSenderEndpoint({
    mailbox = 'lua:sidekick-next/sk_coordinator:coordinator',
})
assert(script == 'sidekick-next/sk_coordinator')
assert(actor == 'coordinator')

script, actor = lib.actorSenderEndpoint({
    mailbox = 'sidekick-next/sk_tank:tank',
})
assert(script == 'sidekick-next/sk_tank')
assert(actor == 'tank')

assert(lib.actorSenderMatches({
    mailbox = 'lua:sidekick-next/sk_coordinator:coordinator',
}, 'sidekick-next/sk_coordinator', 'coordinator'))

assert(lib.actorSenderMatches({
    mailbox = 'SIDEKICK-NEXT\\SK_COMBAT:SIDEKICK',
}, 'sidekick-next/sk_combat', 'sidekick'))

assert(lib.actorSenderMatches({
    script = 'sidekick-next/sk_tank',
    mailbox = 'lua:sidekick-next/sk_tank:sidekick',
}, 'sidekick-next/sk_tank', 'sidekick'))

assert(lib.actorSenderMatches({
    mailbox = 'lua:sidekick-next/sk_coordinator:sk:team',
}, 'sidekick-next/sk_coordinator', 'sk:team'))

assert(lib.actorSenderMatches({
    script = 'sidekick-next/sk_coordinator',
    mailbox = 'coordinator',
}, 'sidekick-next/sk_coordinator', 'coordinator'))

assert(not lib.actorSenderMatches({
    mailbox = 'lua:sidekick-next/sk_tank:tank',
}, 'sidekick-next/sk_coordinator', 'coordinator'))

assert(not lib.actorSenderMatches({
    mailbox = 'lua:sidekick-next/sk_coordinator:sidekick',
}, 'sidekick-next/sk_coordinator', 'coordinator'))

print('actor_sender_identity_test: 9 checks, 0 failures')
