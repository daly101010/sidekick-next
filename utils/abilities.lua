local mq = require('mq')
local Helpers = require('lib.helpers')

local M = {}

-- Lazy-load modules to avoid circular requires
local _ConditionBuilder = nil
local function getConditionBuilder()
    if not _ConditionBuilder then
        local ok, cb = pcall(require, 'ui.condition_builder')
        if ok then _ConditionBuilder = cb end
    end
    return _ConditionBuilder
end

local _Core = nil
local function getCore()
    if not _Core then
        local ok, core = pcall(require, 'utils.core')
        if ok then _Core = core end
    end
    return _Core
end

-- Cache for bar order index (rebuilt when order changes)
local _orderCache = {
    BarOrder = { list = {}, index = {}, timestamp = 0 },
    DiscBarOrder = { list = {}, index = {}, timestamp = 0 },
}

local function splitCsv(str)
    local list = {}
    for part in string.gmatch(tostring(str or ''), '([^,]+)') do
        local trimmed = part:match('^%s*(.-)%s*$')
        if trimmed and trimmed ~= '' then
            table.insert(list, trimmed)
        end
    end
    return list
end

--- Get the bar order list and index for a given order key
-- @param orderKey string 'BarOrder' or 'DiscBarOrder'
-- @return table index mapping settingKey -> position (1-based)
local function getOrderIndex(orderKey)
    local Core = getCore()
    if not Core or not Core.Ini then return {} end

    local layoutSection = Core.Ini['SideKick-Layout'] or {}
    local rawOrder = layoutSection[orderKey] or ''

    -- Check if cache is still valid (simple string comparison)
    local cache = _orderCache[orderKey]
    if cache and cache.raw == rawOrder then
        return cache.index
    end

    -- Rebuild cache
    local list = splitCsv(rawOrder)
    local index = {}
    for i, key in ipairs(list) do
        index[key] = i
    end

    _orderCache[orderKey] = {
        raw = rawOrder,
        list = list,
        index = index,
    }

    return index
end

--- Get order position for an ability (lower = higher priority)
-- @param def table Ability definition
-- @param orderIndex table Index mapping settingKey -> position
-- @return number Position (defaults to 9999 if not in order)
local function getOrderPosition(def, orderIndex)
    if not def or not def.settingKey then return 9999 end
    return orderIndex[def.settingKey] or 9999
end

M.MODE = {
    ON_DEMAND = 1,    -- Never auto-fire, user must click (was MANUAL)
    ON_CD = 2,        -- Always fire when ready
    ON_BURN = 3,      -- Fire only during burn phase
    ON_NAMED = 4,     -- Fire only on named mobs
    ON_CONDITION = 5, -- Fire when condition gate passes
}
-- Backward compatibility alias
M.MODE.MANUAL = M.MODE.ON_DEMAND

M.MODE_LABELS = {
    [M.MODE.ON_DEMAND] = 'On Demand',
    [M.MODE.ON_CD] = 'On Cooldown',
    [M.MODE.ON_BURN] = 'On Burn',
    [M.MODE.ON_NAMED] = 'On Named',
    [M.MODE.ON_CONDITION] = 'On Condition',
}

--- Sort abilities by BarOrder position (user drag-drop order from UI)
-- Falls back to alphabetical if not in order list
-- @param abilities table Array of ability definitions
-- @param orderKey string Optional: 'BarOrder' (default) or 'DiscBarOrder'
-- @return table New sorted array
function M.sortByPriority(abilities, orderKey)
    orderKey = orderKey or 'BarOrder'
    local orderIndex = getOrderIndex(orderKey)

    local sorted = {}
    for i, def in ipairs(abilities) do
        sorted[i] = def
    end

    table.sort(sorted, function(a, b)
        local posA = getOrderPosition(a, orderIndex)
        local posB = getOrderPosition(b, orderIndex)
        if posA ~= posB then
            return posA < posB
        end
        -- Fallback: alphabetical by name
        local nameA = tostring(a.altName or a.discName or a.settingKey or '')
        local nameB = tostring(b.altName or b.discName or b.settingKey or '')
        return nameA < nameB
    end)

    return sorted
end

--- Sort abilities for disc bar (uses DiscBarOrder)
-- @param abilities table Array of ability definitions
-- @return table New sorted array
function M.sortByDiscOrder(abilities)
    return M.sortByPriority(abilities, 'DiscBarOrder')
end

--- Detect if an ability is AoE or single-target based on spell data
-- @param def table Ability definition
-- @return string 'aoe' or 'single'
function M.detectAggroType(def)
    -- Get spell info for this ability
    local spellName = def.altName or def.discName or ''
    local spell = mq.TLO.Spell(spellName)
    if not spell or not spell() then return 'single' end

    local targetType = spell.TargetType()
    if targetType == 'PB AE' or targetType == 'Targeted AE' or targetType == 'AE PC v1' then
        return 'aoe'
    end
    return 'single'
end

--- Get abilities marked for aggro use, separated by AoE vs single-target
-- @param abilities table Array of ability definitions
-- @param settings table Settings table with UseForAggro flags
-- @return table, table Two arrays: aoe abilities, single-target abilities
function M.getAggroAbilities(abilities, settings)
    local aoe, single = {}, {}
    for _, def in ipairs(abilities) do
        local aggroKey = def.settingKey and (def.settingKey .. 'UseForAggro')
        if aggroKey and settings[aggroKey] == true then
            local aggroType = M.detectAggroType(def)
            if aggroType == 'aoe' then
                table.insert(aoe, def)
            else
                table.insert(single, def)
            end
        end
    end
    return aoe, single
end

--- Check if character has learned/scribed this ability
-- @param def table Ability definition
-- @return boolean True if character has the ability
function M.hasAbility(def)
    local me = mq.TLO.Me
    if not me or not me() then return false end

    local kind = tostring(def.kind or 'aa')
    local name = def.altName or def.discName or ''

    if kind == 'aa' then
        local aa = me.AltAbility(name)
        return aa and aa() ~= nil
    elseif kind == 'disc' then
        local disc = me.CombatAbility(name)
        return disc and disc() ~= nil
    elseif kind == 'spell' then
        local spell = me.Book(name)
        return spell and spell() ~= nil
    end
    return false
end

--- Filter abilities to only those the character has learned/scribed
-- @param abilities table Array of ability definitions
-- @return table Filtered array containing only available abilities
function M.filterAvailable(abilities)
    local available = {}
    for _, def in ipairs(abilities) do
        if M.hasAbility(def) then
            table.insert(available, def)
        end
    end
    return available
end

local function isNamedTarget()
    local t = mq.TLO.Target
    return t and t() and t.Named and t.Named() == true
end

function M.activate(def)
    if not def then return end
    local kind = tostring(def.kind or 'aa')
    if kind == 'aa' then
        local id = tonumber(def.altID)
        if not id then return end
        mq.cmdf('/alt activate %d', id)
        return
    end
    if kind == 'disc' then
        local name = tostring(def.discName or def.altName or '')
        if name == '' then return end

        local me = mq.TLO.Me
        local chosen = name
        if me and me.CombatAbilityTimer then
            for _, candidate in ipairs(Helpers.discNameCandidates(name)) do
                local ok, timerVal = pcall(function()
                    local t = me.CombatAbilityTimer(candidate)
                    return t and t()
                end)
                if ok and timerVal ~= nil then
                    chosen = candidate
                    break
                end
            end
        end

        mq.cmd('/disc ' .. chosen)
        return
    end
    if kind == 'spell' then
        local spellName = tostring(def.spellName or def.altName or '')
        if spellName == '' then return end

        -- Use spell engine for proper state machine handling
        local ok, SpellEngine = pcall(require, 'utils.spell_engine')
        if ok and SpellEngine then
            SpellEngine.cast(spellName, def.targetId, def)
        else
            -- Fallback: direct cast (no state tracking)
            mq.cmdf('/cast "%s"', spellName)
        end
        return
    end
end

function M.tryAllAbilities(opts)
    opts = opts or {}
    local abilities = opts.abilities or {}
    local settings = opts.settings or {}
    local burn = opts.burn == true

    local me = mq.TLO.Me
    if not me or not me() then return end
    if not (me.Combat and me.Combat()) then return end

    local named = isNamedTarget()
    local sorted = M.sortByPriority(abilities)

    for _, def in ipairs(sorted) do
        if type(def) ~= 'table' then goto continue end

        local enabled = def.settingKey and settings[def.settingKey] == true
        if not enabled then goto continue end

        local mode = def.modeKey and tonumber(settings[def.modeKey]) or M.MODE.ON_DEMAND
        if mode == M.MODE.MANUAL or mode == M.MODE.ON_DEMAND then goto continue end
        if mode == M.MODE.ON_BURN and not burn then goto continue end
        if mode == M.MODE.ON_NAMED and not named then goto continue end
        if mode == M.MODE.ON_CONDITION then
            -- Evaluate condition from settings
            local condKey = def.conditionKey or (def.modeKey and def.modeKey:gsub('Mode$', 'Condition'))
            local condData = condKey and settings[condKey]
            local cb = getConditionBuilder()
            if cb and condData then
                -- Handle both deserialized table and serialized string
                local evalData = condData
                if type(condData) == 'string' and condData ~= '' then
                    evalData = cb.deserialize and cb.deserialize(condData) or nil
                end
                if not evalData or type(evalData) ~= 'table' then
                    goto continue  -- Invalid condition data
                end
                if not cb.evaluate(evalData) then goto continue end
            else
                goto continue  -- No condition set, skip
            end
        end

        local kind = tostring(def.kind or 'aa')
        if kind == 'aa' then
            local ready = false
            if def.altID and me.AltAbilityReady then
                ready = me.AltAbilityReady(tonumber(def.altID))() == true
            elseif def.altName and me.AltAbilityReady then
                ready = me.AltAbilityReady(def.altName)() == true
            end
            if ready then
                M.activate(def)
                mq.delay(50)
            end
        elseif kind == 'disc' then
            local discName = tostring(def.discName or def.altName or '')
            if discName ~= '' and me.CombatAbilityReady then
                local readyName = nil
                for _, candidate in ipairs(Helpers.discNameCandidates(discName)) do
                    local ok, ready = pcall(function()
                        return me.CombatAbilityReady(candidate)() == true
                    end)
                    if ok and ready then
                        readyName = candidate
                        break
                    end
                end
                if readyName then
                    def.discName = readyName
                    def.altName = readyName
                    M.activate(def)
                    mq.delay(50)
                end
            end
        end

        ::continue::
    end
end

return M
