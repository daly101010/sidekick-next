package.path = '../?.lua;../?/init.lua;' .. package.path

local state = {
    navMesh = false,
    navPath = false,
    moveTo = false,
    stick = false,
}

local function boolMember(read)
    return setmetatable({}, {
        __call = function() return read() end,
    })
end

local navigation = {
    Active = boolMember(function() return false end),
    MeshLoaded = boolMember(function() return state.navMesh end),
}
navigation.PathExists = function()
    return boolMember(function() return state.navPath end)
end

local mq = {
    gettime = function() return 1000 end,
    cmd = function() end,
    cmdf = function() end,
    TLO = {
        Navigation = navigation,
        Nav = nil,
        MoveTo = nil,
        Stick = nil,
        AdvPath = nil,
        Me = {
            FeetWet = boolMember(function() return false end),
            Following = boolMember(function() return false end),
            CleanName = boolMember(function() return 'Tester' end),
            Instance = boolMember(function() return 0 end),
        },
        EverQuest = {
            Server = boolMember(function() return 'Test' end),
        },
        Zone = {
            ID = boolMember(function() return 1 end),
        },
    },
}

package.loaded.mq = mq
package.loaded['sidekick-next.utils.paths'] = {
    getDataDir = function() return '.' end,
}
package.loaded['sidekick-next.utils.safe_write'] = function() return true end

local Movement = require('sidekick-next.utils.chase_movement')
local fingerprint = { id = 123 }

local backend, reason = Movement.resolveBackend(fingerprint)
assert(backend == nil and reason == 'no_movement_backend')

mq.TLO.MoveTo = {
    Moving = boolMember(function() return false end),
}
backend, reason = Movement.resolveBackend(fingerprint, true)
assert(backend == 'moveto' and reason == nil)

mq.TLO.Stick = {
    Active = boolMember(function() return false end),
}
state.navMesh = true
state.navPath = true
backend, reason = Movement.resolveBackend(fingerprint, true)
assert(backend == 'nav' and reason == nil)

local snapshot = Movement.backendSnapshot(fingerprint)
assert(snapshot.selected == 'nav')
assert(snapshot.navMeshLoaded == true)
assert(snapshot.navPathExists == true)
assert(snapshot.moveToAvailable == true)
assert(snapshot.stickAvailable == true)

print('chase_backend_gate_test: ok')
