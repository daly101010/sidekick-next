local mq = require('mq')
local Core = require('sidekick-next.utils.core')

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

-- Use centralized game state check from Core
local function can_query_items()
    return Core.CanQueryItems()
end

-- Build buff status: what buffs this character currently HAS
-- This allows other characters to know who needs buffs
local function buildSelfBuffStatus()
    local me = mq.TLO.Me
    if not me or not me() then return {} end

    local out = {}

    -- Check common buff categories by looking for spells in buff window
    -- These are the buff lines that are commonly coordinated between characters
    local buffCategories = {
        { name = 'haste', patterns = {'Haste', 'Speed', 'Celerity', 'Alacrity'} },
        { name = 'hp', patterns = {'Aegolism', 'Unity', 'Symbol', 'Blessing'} },
        { name = 'regen', patterns = {'Regen', 'Chloro', 'Pack Regen', 'Group Regen'} },
        { name = 'sta', patterns = {'Stamina', 'Fortitude', 'Endurance'} },
        { name = 'str', patterns = {'Strength', 'Furious Might', 'Ferocity'} },
        { name = 'agi', patterns = {'Agility', 'Deftness', 'Spirit of'} },
        { name = 'focus', patterns = {'Focus', 'Clarity', 'Koadic', 'Flowing', 'Mana'} },
        { name = 'ac', patterns = {'Skin', 'Guard', 'Ward', 'Armor'} },
        { name = 'ds', patterns = {'Damage Shield', 'Retribution', 'Thorns'} },
        { name = 'shielding', patterns = {'Shielding', 'Enchant', 'Rune'} },
        { name = 'aura', patterns = {'Aura'} },
    }

    -- Check buff and song windows for each category
    for _, cat in ipairs(buffCategories) do
        local hasBuff = false
        local remaining = 0

        -- Check buff slots (1-42 is typical max)
        for i = 1, 42 do
            local buff = me.Buff(i)
            if buff and buff() then
                local buffName = buff.Name and buff.Name() or ''
                if buffName ~= '' then
                    for _, pattern in ipairs(cat.patterns) do
                        if buffName:find(pattern) then
                            hasBuff = true
                            local duration = buff.Duration and tonumber(buff.Duration()) or 0
                            remaining = math.max(remaining, duration / 1000)  -- Duration is in ms
                            break
                        end
                    end
                end
            end
            if hasBuff then break end
        end

        -- Check song slots too
        if not hasBuff then
            for i = 1, 30 do
                local song = me.Song(i)
                if song and song() then
                    local songName = song.Name and song.Name() or ''
                    if songName ~= '' then
                        for _, pattern in ipairs(cat.patterns) do
                            if songName:find(pattern) then
                                hasBuff = true
                                local duration = song.Duration and tonumber(song.Duration()) or 0
                                remaining = math.max(remaining, duration / 1000)
                                break
                            end
                        end
                    end
                end
                if hasBuff then break end
            end
        end

        out[cat.name] = {
            present = hasBuff,
            remaining = remaining,
        }
    end

    return out
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
                if me and mq.TLO.FindItem and can_query_items() then
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
        buffs = buildSelfBuffStatus(),  -- What buffs this character currently has
        script = 'sidekick',
    }
end

return M
