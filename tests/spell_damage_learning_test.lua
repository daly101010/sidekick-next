local now = 1000
local activeCast = nil

package.loaded.mq = {
    gettime = function() return now end,
    configDir = 'F:/Config',
    TLO = {
        Spawn = function()
            return setmetatable({}, { __call = function() return false end })
        end,
    },
}

package.loaded['sidekick-next.utils.spell_engine'] = {
    getCastInfo = function() return activeCast end,
}
package.loaded['sidekick-next.utils.spell_events'] = {
    RESULT = { SUCCESS = 1, RESISTED = 2 },
}

local Tracker = require('sidekick-next.utils.spell_damage_tracker')
Tracker._resetLearningForTest()

-- MQ events are drained before SpellEngine ticks: damage arrives first.
activeCast = {
    spellName = 'Sunstrike',
    targetName = 'a bottomless gnawer',
    category = 'damage',
}
assert(Tracker.observeDamage({
    mine = true,
    kind = 'nuke',
    target = 'a bottomless gnawer',
    amount = '1,234',
}) == true)
assert(Tracker.onCastComplete({
    spellName = 'Sunstrike',
    targetName = 'a bottomless gnawer',
    spellCategory = 'damage',
}, 1) == true)
assert(Tracker.data.Sunstrike.count == 1)
assert(Tracker.data.Sunstrike.maxSeen == 1234)

-- Damage can also arrive after terminal cast completion.
activeCast = nil
now = now + 100
assert(Tracker.onCastComplete({
    spellName = 'Draught of Fire',
    targetName = 'A Bottomless Gnawer',
    spellCategory = 'direct_damage',
}, 1) == true)
assert(Tracker.observeDamage({
    mine = true,
    kind = 'nuke',
    target = 'a bottomless gnawer',
    amount = 688,
}) == true)
assert(Tracker.data['Draught of Fire'].count == 1)
assert(Tracker.data['Draught of Fire'].maxSeen == 688)

-- Non-nuke damage must not pollute learned spell values.
assert(Tracker.observeDamage({
    mine = true,
    kind = 'melee',
    target = 'a bottomless gnawer',
    amount = 999,
}) == false)

local diagnostics = Tracker.getDiagnostics()
assert(diagnostics.ownNukeEvents == 2)
assert(diagnostics.matched == 2)
assert(diagnostics.unmatched == 0)
assert(diagnostics.pendingCasts == 0)

print('spell_damage_learning_test: 13 checks, 0 failures')
