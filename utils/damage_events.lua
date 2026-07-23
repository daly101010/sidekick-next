-- utils/damage_events.lua
-- Damage Events - Parses OUTGOING damage messages (group -> mob) and dispatches
-- to listeners. This is the observation layer for mob HP estimation, per-spell
-- damage learning, and partial-resist detection.
--
-- (healing/damage_parser.lua handles the INCOMING direction, mob -> group.)
--
-- Listener signature: fn(event) where event = {
--   target  = string  mob name as printed in the message,
--   amount  = number  damage dealt,
--   mine    = boolean true if I dealt it,
--   kind    = string  'melee' | 'nuke' | 'dot' | 'ds',
--   spell   = string|nil spell name (DoT ticks only),
-- }

local mq = require('mq')

local M = {}

local _listeners = {}
local _registered = false

--- Add a damage listener
-- @param fn function Listener callback
function M.addListener(fn)
    if type(fn) == 'function' then
        table.insert(_listeners, fn)
    end
end

local function dispatch(target, amount, mine, kind, spell, attacker)
    amount = tonumber(amount) or 0
    if amount <= 0 then return end
    if not target or target == '' then return end

    local event = { target = target, amount = amount, mine = mine, kind = kind, spell = spell,
        attacker = mine and 'me' or (attacker or '') }
    for _, fn in ipairs(_listeners) do
        pcall(fn, event)
    end
end

-- Melee verbs used in outgoing combat messages ("You slash X" / "Soandso slashes X")
local MELEE_VERBS = {
    'bash', 'bite', 'backstab', 'claw', 'crush', 'gore', 'hit', 'kick',
    'maul', 'pierce', 'punch', 'slam', 'slash', 'slice', 'smash', 'sting', 'strike',
}

-- Third-person forms are the verb + 's' except a couple of irregulars
local function pluralVerb(verb)
    if verb == 'crush' or verb == 'bash' or verb == 'smash' then
        return verb .. 'es'
    end
    return verb .. 's'
end

function M.registerEvents()
    if _registered then return end
    _registered = true

    -- ============================================
    -- MY NON-MELEE (nuke) DAMAGE
    -- ============================================
    mq.event('sk_de_my_nuke', "You hit #1# for #2# points of non-melee damage#*#", function(_, target, amount)
        dispatch(target, amount, true, 'nuke')
    end)

    -- ============================================
    -- OTHERS' NON-MELEE DAMAGE
    -- ============================================
    mq.event('sk_de_other_nuke', "#1# hit #2# for #3# points of non-melee damage#*#", function(_, attacker, target, amount)
        -- My own line also matches with attacker "You" - handled by sk_de_my_nuke
        if tostring(attacker):lower() ~= 'you' then
            dispatch(target, amount, false, 'nuke', nil, attacker)
        end
    end)

    -- ============================================
    -- DOT TICKS (mine and others')
    -- ============================================
    mq.event('sk_de_my_dot', "#1# has taken #2# damage from your #3#.#*#", function(_, target, amount, spell)
        dispatch(target, amount, true, 'dot', spell)
    end)

    mq.event('sk_de_other_dot', "#1# has taken #2# damage from #3# by #4#.#*#", function(_, target, amount, caster, spell)
        dispatch(target, amount, false, 'dot', spell, caster)
    end)

    -- ============================================
    -- MELEE (mine: "You slash X for N points of damage.")
    -- ============================================
    for _, verb in ipairs(MELEE_VERBS) do
        mq.event('sk_de_my_' .. verb, string.format("You %s #1# for #2# points of damage.#*#", verb), function(_, target, amount)
            dispatch(target, amount, true, 'melee')
        end)
    end

    -- ============================================
    -- MELEE (others/pets: "Soandso slashes X for N points of damage.")
    -- ============================================
    for _, verb in ipairs(MELEE_VERBS) do
        local plural = pluralVerb(verb)
        mq.event('sk_de_ot_' .. verb, string.format("#1# %s #2# for #3# points of damage.#*#", plural), function(_, attacker, target, amount)
            dispatch(target, amount, false, 'melee', nil, attacker)
        end)
    end

    -- ============================================
    -- DAMAGE SHIELD (mob takes DS damage when it hits us)
    -- ============================================
    mq.event('sk_de_ds1', "#1# is burned by YOUR #2# for #3# points of#*#", function(_, target, spell, amount)
        dispatch(target, amount, true, 'ds')
    end)
    mq.event('sk_de_ds2', "#1# is pierced by YOUR thorns for #2# points of#*#", function(_, target, amount)
        dispatch(target, amount, true, 'ds')
    end)
end

function M.unregisterEvents()
    if not _registered then return end
    _registered = false

    mq.unevent('sk_de_my_nuke')
    mq.unevent('sk_de_other_nuke')
    mq.unevent('sk_de_my_dot')
    mq.unevent('sk_de_other_dot')
    for _, verb in ipairs(MELEE_VERBS) do
        mq.unevent('sk_de_my_' .. verb)
        mq.unevent('sk_de_ot_' .. verb)
    end
    mq.unevent('sk_de_ds1')
    mq.unevent('sk_de_ds2')
end

function M.init()
    M.registerEvents()
end

function M.shutdown()
    M.unregisterEvents()
end

return M
