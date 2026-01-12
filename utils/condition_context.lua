-- F:/lua/SideKick/utils/condition_context.lua
-- Provides a clean API for condition evaluation in rotation/buff/heal logic

local mq = require('mq')

local RuntimeCache = require('utils.runtime_cache')
local Core = require('utils.core')

local M = {}

--- Build a context object for condition evaluation
--- Caches expensive TLO calls for the duration of the tick
---@return table ctx Context object with me, target, group, spawn, combat, burn, mode
function M.build()
    local me = mq.TLO.Me
    local target = mq.TLO.Target
    local group = mq.TLO.Group

    -- Helper for safe TLO access
    local function safe(fn, default)
        local ok, v = pcall(fn)
        if not ok then return default end
        return v ~= nil and v or default
    end

    -- Helper for safe number access
    local function safeNum(fn, default)
        local ok, v = pcall(fn)
        if not ok then return default end
        return tonumber(v) or default
    end

    -- Pet info (cached)
    local petId = safeNum(function() return me.Pet.ID() end, 0)
    local petHPs = petId > 0 and safeNum(function() return me.Pet.PctHPs() end, 100) or nil

    return {
        me = {
            pctHPs = safeNum(function() return me.PctHPs() end, 100),
            pctMana = safeNum(function() return me.PctMana() end, 100),
            pctEnd = safeNum(function() return me.PctEndurance() end, 100),
            combat = safe(function() return me.CombatState() end, '') == 'COMBAT',
            invis = safe(function() return me.Invis() end, false),
            hovering = safe(function() return me.Hovering() end, false),
            feigning = safe(function() return me.Feigning() end, false),
            moving = RuntimeCache.me and RuntimeCache.me.moving or false,
            casting = RuntimeCache.me and RuntimeCache.me.casting or false,
            activeDisc = safe(function() return me.ActiveDisc.Name() end, nil),
            activeDiscId = safeNum(function() return me.ActiveDisc.ID() end, 0),
            level = safeNum(function() return me.Level() end, 1),
            class = safe(function() return me.Class.ShortName() end, ''),
            xTargetCount = safeNum(function() return me.XTarget() end, 0),
            xTHaterCount = safeNum(function() return me.XTHaterCount() end, 0),
            pctAggro = safeNum(function() return me.PctAggro() end, 0),
            petId = petId,

            -- Function to check buff by name
            buff = function(name)
                if not name or name == '' then return false end
                local b = me.Buff(name)
                return b and b() ~= nil and safeNum(function() return b.ID() end, 0) > 0
            end,

            -- Function to check song by name
            song = function(name)
                if not name or name == '' then return false end
                local s = me.Song(name)
                return s and s() ~= nil and safeNum(function() return s.ID() end, 0) > 0
            end,

            -- Check if AA is ready
            aaReady = function(name)
                if not name or name == '' then return false end
                return safe(function() return me.AltAbilityReady(name)() end, false)
            end,

            -- Check if disc is ready
            discReady = function(name)
                if not name or name == '' then return false end
                return safe(function() return me.CombatAbilityReady(name)() end, false)
            end,

            -- Check if ability is ready
            abilityReady = function(name)
                if not name or name == '' then return false end
                return safe(function() return me.AbilityReady(name)() end, false)
            end,
        },

        target = {
            id = safeNum(function() return target.ID() end, 0),
            pctHPs = safeNum(function() return target.PctHPs() end, 100),
            level = safeNum(function() return target.Level() end, 0),
            named = safe(function() return target.Named() end, false),
            body = safe(function() return target.Body.Name() end, ''),
            distance = safeNum(function() return target.Distance() end, 999),
            distance3D = safeNum(function() return target.Distance3D() end, 999),
            lineOfSight = safe(function() return target.LineOfSight() end, false),
            type = safe(function() return target.Type() end, ''),

            -- Check if target has a buff
            buff = function(name)
                if not name or name == '' then return false end
                local b = target.Buff(name)
                return b and b() ~= nil and safeNum(function() return b.ID() end, 0) > 0
            end,

            -- Check if target has MY buff (I cast it)
            myBuff = function(name)
                if not name or name == '' then return false end
                local b = target.MyBuff(name)
                return b and b() ~= nil and safeNum(function() return b.ID() end, 0) > 0
            end,

            -- Check target's con color
            conColor = safe(function() return target.ConColor() end, ''),
        },

        pet = {
            id = petId,
            pctHPs = petHPs,
            -- Check if pet has a buff
            buff = function(name)
                if petId <= 0 then return false end
                if not name or name == '' then return false end
                local pet = me.Pet
                if not (pet and pet()) then return false end
                local b = pet.Buff(name)
                return b and b() ~= nil and safeNum(function() return b.ID() end, 0) > 0
            end,
        },

        group = {
            size = safeNum(function() return group.Members() end, 0),
            -- Count injured group members below threshold
            injured = function(pct)
                pct = tonumber(pct) or 75
                return safeNum(function() return group.Injured(pct)() end, 0)
            end,
            -- Get lowest HP in group from RuntimeCache
            lowestHP = (RuntimeCache.group and RuntimeCache.group.lowestHPPercent) or 100,
            -- Get tank HP from RuntimeCache
            tankHP = (RuntimeCache.group and RuntimeCache.group.tankHP) or 100,
        },

        raid = {
            members = safeNum(function() return mq.TLO.Raid.Members() end, 0),
        },

        spawn = {
            -- Count spawns matching query
            count = function(query)
                if not query or query == '' then return 0 end
                return safeNum(function() return mq.TLO.SpawnCount(query)() end, 0)
            end,
            -- Count NPCs in radius
            npcRadius = function(radius, zradius)
                radius = tonumber(radius) or 50
                local query = string.format('npc radius %d', radius)
                if zradius then
                    query = string.format('%s zradius %d', query, tonumber(zradius) or 50)
                end
                return safeNum(function() return mq.TLO.SpawnCount(query)() end, 0)
            end,
        },

        -- Combat state from RuntimeCache
        combat = RuntimeCache.inCombat and RuntimeCache.inCombat() or false,

        -- Burn phase active
        burn = RuntimeCache.burnActive or false,

        -- Current combat mode from settings
        mode = Core.Settings and Core.Settings.CombatMode or 'DPS',

        -- Zone info
        zone = {
            id = safeNum(function() return mq.TLO.Zone.ID() end, 0),
            name = safe(function() return mq.TLO.Zone.Name() end, ''),
            shortName = safe(function() return mq.TLO.Zone.ShortName() end, ''),
        },
    }
end

--- Check if a spell will stack on target
---@param spellName string The spell name to check
---@return boolean stacks True if spell will stack
function M.spellStacks(spellName)
    if not spellName or spellName == '' then return false end
    local spell = mq.TLO.Spell(spellName)
    if not (spell and spell()) then return false end
    local ok, stacks = pcall(function() return spell.Stacks() end)
    return ok and stacks == true
end

--- Check if a spell will stack on target (target-specific)
---@param spellName string The spell name to check
---@return boolean stacks True if spell will stack on target
function M.spellStacksTarget(spellName)
    if not spellName or spellName == '' then return false end
    local spell = mq.TLO.Spell(spellName)
    if not (spell and spell()) then return false end
    local ok, stacks = pcall(function() return spell.StacksTarget() end)
    return ok and stacks == true
end

return M
