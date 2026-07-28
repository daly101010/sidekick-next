local distance = 20
local combatState = 'ACTIVE'
local nowMs = 10000
local navigationActive = false

local target = setmetatable({
    Type = function() return 'NPC' end,
    Dead = function() return false end,
    Distance = function() return distance end,
}, {
    __call = function() return 'a test target' end,
})

package.preload['mq'] = function()
    return {
        gettime = function() return nowMs end,
        TLO = {
            Me = {
                Class = { ShortName = function() return 'WIZ' end },
                CombatState = function() return combatState end,
                Casting = function() return '' end,
            },
            Spawn = function() return target end,
            Navigation = {
                Active = function() return navigationActive end,
            },
        },
    }
end

package.preload['sidekick-next.utils.lazy_require'] = function()
    return function() return nil end
end

package.preload['sidekick-next.utils.class_roles'] = function()
    return {
        PURE_CASTERS = { WIZ = true },
        HYBRID_MELEE = {},
        PURE_MELEE = {},
    }
end

package.preload['sidekick-next.utils.logger'] = function()
    local logger = {
        debug = function() end,
        info = function() end,
        warn = function() end,
    }
    return { new = function() return logger end }
end

package.preload['sidekick-next.sk_lib'] = function()
    return {}
end

local CasterAssist = dofile('automation/caster_assist.lua')
local settings = {
    CasterStandoffEnabled = true,
    CasterStandoffMin = 35,
    CasterStandoffMax = 60,
}

local needed, reason = CasterAssist.getStandoffNeed(settings, 123, false)
assert(needed == false and reason == 'not_in_combat')

needed, reason = CasterAssist.getStandoffNeed(settings, 123, true)
assert(needed == true and reason == 'initial_position')

CasterAssist.standoffState.positionedTargetId = 123
distance = 40
needed, reason = CasterAssist.getStandoffNeed(settings, 123, true)
assert(needed == false and reason == 'outside_minimum')

-- Retreat distance is a destination, not an outer trigger: never move inward.
distance = 100
needed, reason = CasterAssist.getStandoffNeed(settings, 123, true)
assert(needed == false and reason == 'outside_minimum')

distance = 20
needed, reason = CasterAssist.getStandoffNeed(settings, 123, true)
assert(needed == true and reason:find('inside_minimum:', 1, true) == 1)

-- Consolidated authority may supersede Chase/external Nav, but the legacy
-- uncoordinated path must not steal movement.
navigationActive = true
needed = CasterAssist.getStandoffNeed(settings, 123, true)
assert(needed == true)
combatState = 'COMBAT'
needed, reason = CasterAssist.getStandoffNeed(settings, 123, false)
assert(needed == false and reason == 'external_navigation_active')

print('caster_standoff_admission_test: ok')
