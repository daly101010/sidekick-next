local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')
local Helpers = require('sidekick-next.lib.helpers')

local M = {}

-- Lazy-load modules to avoid circular requires
local getConditionBuilder = lazy('sidekick-next.ui.condition_builder')
local getCore = lazy('sidekick-next.utils.core')

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

-- Simplified mode: abilities either auto-fire (via category + conditions) or are on-demand only
-- The old ON_CD/ON_BURN/ON_NAMED modes are now handled by:
--   - Category assignment (burn abilities go in burn layer)
--   - defaultConditions in class configs (e.g., ctx.target.named for named-only abilities)
M.MODE = {
    ON_DEMAND = 1,     -- Never auto-fire, user must click
    ON_CONDITION = 2,  -- Auto-fire based on layer + condition gate
    ON_COOLDOWN = 3,   -- Mash ability: fire whenever ready (checked after rotation)
}
-- Backward compatibility aliases
M.MODE.MANUAL = M.MODE.ON_DEMAND
M.MODE.AUTO = M.MODE.ON_CONDITION  -- Legacy alias
M.MODE.ON_CD = M.MODE.ON_COOLDOWN  -- Legacy alias
M.MODE.ON_BURN = M.MODE.ON_CONDITION
M.MODE.ON_NAMED = M.MODE.ON_CONDITION

M.MODE_LABELS = {
    [M.MODE.ON_DEMAND] = 'On Demand',
    [M.MODE.ON_CONDITION] = 'On Condition',
    [M.MODE.ON_COOLDOWN] = 'On Cooldown',
}

-- Context for ON_COOLDOWN mode (when to spam the ability)
M.CONTEXT = {
    COMBAT = 1,        -- Only during combat (has XTarget haters)
    OUT_OF_COMBAT = 2, -- Only when not in combat
    ANYTIME = 3,       -- Always check/fire when ready
}

M.CONTEXT_LABELS = {
    [M.CONTEXT.COMBAT] = 'Combat',
    [M.CONTEXT.OUT_OF_COMBAT] = 'Out of Combat',
    [M.CONTEXT.ANYTIME] = 'Anytime',
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
        -- me.Book(name) requires exact match and silently misses ranked
        -- spells ("Avowed Light Rk. II"). Try exact first, then fall back
        -- to me.Spell which does SpellGroup substring matching.
        local exact = me.Book(name)
        if exact and exact() ~= nil then return true end
        local spell = me.Spell(name)
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
        local ok, SpellEngine = pcall(require, 'sidekick-next.utils.spell_engine')
        if ok and SpellEngine then
            SpellEngine.cast(spellName, def.targetId, def)
        else
            -- Fallback: direct cast (no state tracking)
            mq.cmdf('/cast "%s"', spellName)
        end
        return
    end
end

--- Try all abilities in sorted priority order
-- Note: This is a simplified version for backwards compatibility.
-- The rotation_engine.lua now handles the full category + condition logic.
-- @param opts table Options: abilities, settings, burn
function M.tryAllAbilities(opts)
    opts = opts or {}
    local abilities = opts.abilities or {}
    local settings = opts.settings or {}

    local me = mq.TLO.Me
    if not me or not me() then return end
    if not (me.Combat and me.Combat()) then return end

    local sorted = M.sortByPriority(abilities)

    for _, def in ipairs(sorted) do
        if type(def) ~= 'table' then goto continue end

        -- Check individual enabled toggle
        local enabled = def.settingKey and settings[def.settingKey] == true
        if not enabled then goto continue end

        -- Check mode:
        --   ON_DEMAND = skip auto-fire (user must click)
        --   ON_CONDITION = evaluate condition gate then fire
        --   ON_COOLDOWN = handled by mash queue, skip here
        local mode = def.modeKey and tonumber(settings[def.modeKey]) or M.MODE.ON_DEMAND
        if mode == M.MODE.ON_DEMAND then goto continue end
        if mode == M.MODE.ON_COOLDOWN then goto continue end  -- Handled by mash queue

        -- For ON_CONDITION mode, evaluate condition gate if present
        local condKey = def.conditionKey or (def.modeKey and def.modeKey:gsub('Mode$', 'Condition'))
        local condData = condKey and settings[condKey]
        local cb = getConditionBuilder()
        if cb and condData then
            local evalData = condData
            if type(condData) == 'string' and condData ~= '' then
                evalData = cb.deserialize and cb.deserialize(condData) or nil
            end
            if evalData and type(evalData) == 'table' then
                if not cb.evaluate(evalData) then goto continue end
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
