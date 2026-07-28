local spells = {
    [100] = { name = 'Draught of Fire', mez = false },
    [200] = { name = 'Mesmerization', mez = true },
}

local function spellTlo(id)
    local data = spells[tonumber(id)]
    return setmetatable({
        Name = function() return data and data.name or '' end,
        HasSPA = function(spa)
            return function() return data ~= nil and spa == 31 and data.mez end
        end,
    }, {
        __call = function() return data ~= nil end,
    })
end

package.loaded.mq = {
    TLO = {
        Spell = spellTlo,
    },
}

local activeSet = {
    name = 'Default',
    gems = {
        [1] = { spellId = 100 },
    },
}

package.loaded['sidekick-next.utils.spellset_persistence'] = {
    loaded = true,
    activeSetName = 'Default',
    getActiveSet = function() return activeSet end,
}

local CC = require('sidekick-next.automation.cc')

local available = CC.hasLoadedMezSpell(true)
assert(available == false, 'damage-only spell set must not enable CC')

activeSet.gems[4] = { spellId = 200 }
local hasMez, spellName, slot, setName = CC.hasLoadedMezSpell(true)
assert(hasMez == true, 'SPA 31 spell must enable CC')
assert(spellName == 'Mesmerization')
assert(slot == 4)
assert(setName == 'Default')

print('cc_spellset_capability_test: 5 checks, 0 failures')
