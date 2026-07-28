local function callable(fields)
    return setmetatable(fields or {}, {
        __call = function() return true end,
    })
end

local slots = {}

local function makeXTarget(values)
    return callable({
        ID = function() return values.id or 0 end,
        TargetType = function() return values.targetType or '' end,
        Aggressive = function() return values.aggressive == true end,
        Dead = function() return values.dead == true end,
        PctHPs = function() return values.hp == nil and 100 or values.hp end,
        Distance3D = function() return values.distance or 0 end,
    })
end

local me = callable({
    XTargetSlots = function() return 5 end,
    XTarget = function(index)
        return slots[index]
    end,
})

package.preload.mq = function()
    return { TLO = { Me = me } }
end

package.preload['sidekick-next.utils.lazy_require'] = function()
    return function() return nil end
end

local Cache = require('sidekick-next.utils.runtime_cache')

assert(Cache.hasAutoHaterActivity(true) == false,
    'empty XTarget slots must be inactive')

slots[1] = makeXTarget({
    id = 42,
    targetType = 'Auto Hater',
    distance = 75,
})
assert(Cache.hasAutoHaterActivity(true) == true,
    'Auto Hater slot 1 must activate scans')

slots[1] = makeXTarget({
    id = 42,
    targetType = 'Current Target',
    distance = 75,
})
assert(Cache.hasAutoHaterActivity(true) == false,
    'a non-aggressive slot 1 must not activate scans')

slots[1] = makeXTarget({
    id = 42,
    aggressive = true,
    distance = 250,
})
assert(Cache.hasAutoHaterActivity(true) == true,
    'slot 1 is a wake-up sentinel and must not apply engagement range')

slots[1] = makeXTarget({
    id = 7,
    targetType = 'Current Target',
    distance = 10,
})
slots[3] = makeXTarget({
    id = 42,
    aggressive = true,
    distance = 199,
})
assert(Cache.hasAutoHaterActivity(true) == false,
    'later slots must not bypass the configured slot-1 sentinel')

Cache.xtarget = {
    count = 1,
    haters = { { id = 42 } },
    aggroDeficitCount = 1,
}
Cache.setHeavyScanEnabled(false)
assert(Cache.xtarget.count == 0 and #Cache.xtarget.haters == 0,
    'closing the heavy gate must clear stale hostile rows')

print('combat_activity_gate_test: 6 checks, 0 failures')
