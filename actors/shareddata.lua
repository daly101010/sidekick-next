local mq = require('mq')

local M = {}

local function safeNum(fn, fallback)
    local ok, v = pcall(fn)
    if not ok then return fallback end
    return tonumber(v) or fallback
end

local function safeBool(fn, fallback)
    local ok, v = pcall(fn)
    if not ok then return fallback end
    if v == true then return true end
    if v == false or v == nil then return false end
    if type(v) == 'number' then return v ~= 0 end
    local s = tostring(v):lower()
    return (s == '1' or s == 'true' or s == 'yes' or s == 'on')
end

local function buildAbilityStatus(abilities, cooldownProbe)
    local out = {}
    local me = mq.TLO.Me
    for _, def in ipairs(abilities or {}) do
        if type(def) == 'table' and def.altName then
            local ready = false
            local kind = def.kind or 'aa'

            -- Check readiness based on ability type
            if kind == 'aa' then
                if me and me.AltAbilityReady then
                    if def.altID then
                        ready = me.AltAbilityReady(tonumber(def.altID))() == true
                    else
                        ready = me.AltAbilityReady(def.altName)() == true
                    end
                end
            elseif kind == 'disc' then
                if me and me.CombatAbilityReady then
                    ready = me.CombatAbilityReady(def.discName or def.altName)() == true
                end
            elseif kind == 'ability' then
                if me and me.AbilityReady then
                    ready = me.AbilityReady(def.altName)() == true
                end
            elseif kind == 'item' then
                if me and mq.TLO.FindItem then
                    local item = mq.TLO.FindItem(def.itemName or def.altName)
                    if item and item.TimerReady then
                        ready = item.TimerReady() == 0
                    end
                end
            end

            local cooldown = 0
            if cooldownProbe then
                local rem = cooldownProbe({ label = def.altName, key = def.altName })
                cooldown = tonumber(rem) or 0
            end

            -- Full payload for remote ability execution via /dex commands
            out[def.altName] = {
                ready = ready,
                cooldown = cooldown,
                cooldownTotal = def.cooldownTotal or 0,
                -- GroupTarget historically expects `.type`; keep `.kind` for SideKick internal use.
                type = kind,
                kind = kind,
                altID = def.altID,
                altName = def.altName,
                discName = def.discName,
                itemName = def.itemName,
                shortName = def.shortName or def.altName,
                icon = def.icon,
            }
        end
    end
    return out
end

function M.buildStatusPayload(opts)
    opts = opts or {}
    local me = mq.TLO.Me
    if not me or not me() then return nil end

    local hp = safeNum(function() return me.PctHPs() end, 0)
    local mana = safeNum(function() return me.PctMana() end, 0)
    local endur = safeNum(function() return me.PctEndurance() end, 0)
    local level = safeNum(function() return me.Level() end, 0)
    local class = ''
    if me.Class and me.Class.ShortName then
        class = tostring(me.Class.ShortName() or ''):upper()
    end

    local following = false
    if mq.TLO.AdvPath and mq.TLO.AdvPath.Following then
        following = safeBool(function() return mq.TLO.AdvPath.Following() end, false)
    end

    return {
        id = 'status:update',
        zone = mq.TLO.Zone and mq.TLO.Zone.ShortName and mq.TLO.Zone.ShortName() or '',
        hp = hp,
        mana = mana,
        endur = endur,
        level = level,
        class = class,
        sitting = me.Sitting and me.Sitting() == true or false,
        follow = following,
        chase = opts.chase == true,
        abilities = buildAbilityStatus(opts.abilities, opts.cooldownProbe),
        script = 'sidekick',
    }
end

return M
