-- utils/damage_events.lua
-- Damage Events - Parses OUTGOING damage messages (group -> mob) and dispatches
-- to listeners. This is the observation layer for mob HP estimation, per-spell
-- damage learning, and partial-resist detection.
--
-- (healing/damage_parser.lua handles the INCOMING direction, mob -> group.)
--
-- Registration scope: MQ matches every incoming chat line against every
-- registered pattern, so in a boxed group it's wasteful for all characters to
-- watch everyone's damage. Third-person patterns (other members' hits - the
-- bulk of combat spam) are registered per the DamageObserver setting:
--   'auto' (default) - full set only when this character is the tank
--                      (CombatMode == 'tank'); everyone else runs lean
--   'always'         - full set regardless (old behavior)
--   'never'          - lean set only (own damage)
-- Own-damage patterns always register - they feed per-character systems
-- (spell damage learning, partial resists) that cannot be delegated.
-- The observer shares its mob HP estimates via actors (see mob_hp_estimator).
--
-- Listener signature: fn(event) where event = {
--   target   = string  mob name as printed in the message,
--   amount   = number  damage dealt,
--   mine     = boolean true if I dealt it,
--   attacker = string  'me' or the attacker's name ('' if unknown),
--   kind     = string  'melee' | 'nuke' | 'dot' | 'ds',
--   spell    = string|nil spell name (DoT ticks only),
-- }

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

local _listeners = {}
local _registeredNames = {}   -- event names currently registered (for teardown)
local _scope = nil            -- 'full' | 'lean' | nil (not registered)

local getCore = lazy('sidekick-next.utils.core')

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

local function reg(name, pattern, fn)
    mq.event(name, pattern, fn)
    table.insert(_registeredNames, name)
end

--- Resolve the registration scope from settings
-- @return string 'full' or 'lean'
function M.resolveScope()
    local Core = getCore()
    local settings = (Core and Core.Settings) or {}
    local mode = tostring(settings.DamageObserver or 'auto'):lower()
    if mode == 'always' then return 'full' end
    if mode == 'never' then return 'lean' end
    -- auto: the tank is the group's damage observer
    return (settings.CombatMode == 'tank') and 'full' or 'lean'
end

--- Get the current registration scope
function M.getScope()
    return _scope
end

--- Register damage events for the given scope
-- @param scope string|nil 'full' or 'lean' (defaults to resolveScope())
function M.registerEvents(scope)
    scope = scope or M.resolveScope()
    if _scope == scope then return end
    if _scope then M.unregisterEvents() end
    _scope = scope

    -- ============================================
    -- OWN DAMAGE (always registered - personal signals)
    -- ============================================
    reg('sk_de_my_nuke', "You hit #1# for #2# points of non-melee damage#*#", function(_, target, amount)
        dispatch(target, amount, true, 'nuke')
    end)

    reg('sk_de_my_dot', "#1# has taken #2# damage from your #3#.#*#", function(_, target, amount, spell)
        dispatch(target, amount, true, 'dot', spell)
    end)

    for _, verb in ipairs(MELEE_VERBS) do
        reg('sk_de_my_' .. verb, string.format("You %s #1# for #2# points of damage.#*#", verb), function(_, target, amount)
            dispatch(target, amount, true, 'melee')
        end)
    end

    reg('sk_de_ds1', "#1# is burned by YOUR #2# for #3# points of#*#", function(_, target, spell, amount)
        dispatch(target, amount, true, 'ds')
    end)
    reg('sk_de_ds2', "#1# is pierced by YOUR thorns for #2# points of#*#", function(_, target, amount)
        dispatch(target, amount, true, 'ds')
    end)

    if scope ~= 'full' then return end

    -- ============================================
    -- OTHERS' DAMAGE (observer only - the bulk of combat spam)
    -- ============================================
    reg('sk_de_other_nuke', "#1# hit #2# for #3# points of non-melee damage#*#", function(_, attacker, target, amount)
        -- My own line also matches with attacker "You" - handled by sk_de_my_nuke
        if tostring(attacker):lower() ~= 'you' then
            dispatch(target, amount, false, 'nuke', nil, attacker)
        end
    end)

    reg('sk_de_other_dot', "#1# has taken #2# damage from #3# by #4#.#*#", function(_, target, amount, caster, spell)
        dispatch(target, amount, false, 'dot', spell, caster)
    end)

    for _, verb in ipairs(MELEE_VERBS) do
        local plural = pluralVerb(verb)
        reg('sk_de_ot_' .. verb, string.format("#1# %s #2# for #3# points of damage.#*#", plural), function(_, attacker, target, amount)
            dispatch(target, amount, false, 'melee', nil, attacker)
        end)
    end
end

function M.unregisterEvents()
    for _, name in ipairs(_registeredNames) do
        pcall(mq.unevent, name)
    end
    _registeredNames = {}
    _scope = nil
end

--- Re-resolve scope and re-register if it changed (e.g. CombatMode toggled)
function M.ensureScope()
    local want = M.resolveScope()
    if want ~= _scope then
        M.registerEvents(want)
    end
end

function M.init()
    M.registerEvents()
end

function M.shutdown()
    M.unregisterEvents()
end

return M
