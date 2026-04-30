-- automation/pull/abilities.lua
-- Pull-ability definitions and execution. Mirrors rgmercs's seven options:
--   PetPull, Taunt, AutoAttack, Ranged, Kick, Face (face pull), Item.
--
-- Each definition exposes:
--   id, displayName, range (number or function returning number),
--   available(): bool — is this ability actually usable on this character right now
--   execute(targetId, ctx): fires the ability; returns true on issued, false on skip
-- The state machine waits for a successFn after execute() returns.

local mq = require('mq')

local M = {}

local function meValid()
    local me = mq.TLO.Me
    return me and me() ~= nil
end

local function mySkill(name)
    local me = mq.TLO.Me
    if not (me and me()) then return 0 end
    local s = me.Skill and me.Skill(name)
    return (s and s() or 0) > 0 and (s() or 0) or 0
end

local function rangedRange()
    local r = mq.TLO.Me.Inventory('ranged').Range() or 0
    local t = (mq.TLO.Me.Inventory('ranged').Type() or ''):lower()
    if t == 'archery' or t == 'bow' then
        r = r + (mq.TLO.Me.Inventory('ammo').Range() or 0)
    end
    return r
end

local function autoAttackRange()
    local t = mq.TLO.Target
    if not (t and t() and t.ID() and t.ID() > 0) then return 6 end
    local r = t.MaxRangeTo and t.MaxRangeTo() or 10
    return math.floor(r * 0.9)
end

-- Catalog ---------------------------------------------------------------------

M.Definitions = {
    {
        id = 'PetPull',
        displayName = 'Pet Pull',
        range = 175,
        available = function()
            local pet = mq.TLO.Me.Pet
            return pet and pet.ID and pet.ID() and pet.ID() > 0
        end,
        execute = function(targetId, ctx)
            mq.cmdf('/pet attack %d', targetId)
            -- Caller is responsible for /pet back off + /pet follow on RTC.
            return true
        end,
    },
    {
        id = 'Taunt',
        displayName = 'Taunt',
        range = 10,
        available = function() return mySkill('Taunt') > 0 end,
        execute = function(targetId, ctx)
            mq.cmd('/doability "Taunt"')
            return true
        end,
    },
    {
        id = 'AutoAttack',
        displayName = 'Auto Attack',
        range = function() return autoAttackRange() end,
        available = function() return true end,
        execute = function(targetId, ctx)
            mq.cmd('/attack on')
            return true
        end,
    },
    {
        id = 'Ranged',
        displayName = 'Ranged',
        range = function() return rangedRange() end,
        available = function()
            local t = (mq.TLO.Me.Inventory('ranged').Type() or ''):lower()
            return t == 'archery' or t == 'bow' or t == 'throwing'
                or t == 'throwingv1' or t == 'throwingv2'
        end,
        execute = function(targetId, ctx)
            mq.cmdf('/ranged %d', targetId)
            return true
        end,
    },
    {
        id = 'Kick',
        displayName = 'Kick',
        range = 10,
        available = function() return mySkill('Kick') > 0 end,
        execute = function(targetId, ctx)
            mq.cmd('/doability "Kick"')
            return true
        end,
    },
    {
        id = 'Face',
        displayName = 'Face Pull',
        range = 5,
        available = function() return true end,
        execute = function(targetId, ctx)
            -- Face-pull has no direct ability — caller closes to range and
            -- relies on aggro from proximity / facing. We just signal success.
            return true
        end,
    },
    {
        id = 'Item',
        displayName = 'Configured Item',
        range = 200,
        -- Caller-supplied: ctx.itemName must be set (defaults to nil; available()
        -- checks the live ctx via ctx.cfg.pullItemName).
        available = function(ctx)
            local name = ctx and ctx.cfg and ctx.cfg.pullItemName
            if not name or name == '' then return false end
            return (mq.TLO.FindItemCount(name)() or 0) > 0
        end,
        execute = function(targetId, ctx)
            local name = ctx and ctx.cfg and ctx.cfg.pullItemName
            if not name or name == '' then return false end
            mq.cmdf('/useitem "%s"', name)
            return true
        end,
    },
}

-- Lookup helpers --------------------------------------------------------------

function M.getById(id)
    for _, d in ipairs(M.Definitions) do
        if d.id == id then return d end
    end
    return nil
end

function M.rangeOf(def, ctx)
    if not def then return 0 end
    if type(def.range) == 'function' then
        local ok, v = pcall(def.range)
        if ok and type(v) == 'number' then return v end
        return 0
    end
    return def.range or 0
end

function M.availableNames(ctx)
    local out = {}
    for _, d in ipairs(M.Definitions) do
        local ok, isOk = pcall(d.available, ctx)
        if ok and isOk then table.insert(out, d.id) end
    end
    return out
end

return M
