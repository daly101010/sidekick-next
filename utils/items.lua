local mq = require('mq')
local Core = require('sidekick-next.utils.core')
local Helpers = require('sidekick-next.lib.helpers')
local ConditionBuilder = require('sidekick-next.ui.condition_builder')

local M = {}

M.SLOT_COUNT = 12

M.ClickyCache = M.ClickyCache or {}
M._runtime = M._runtime or { lastAutoAt = {}, lastManualAt = {} }

M.MODES = {
    on_demand = { key = 'on_demand', label = 'On Demand' },
    combat = { key = 'combat', label = 'Combat (Auto)' },
    ooc = { key = 'ooc', label = 'Out of Combat (Auto)' },
    on_condition = { key = 'on_condition', label = 'On Condition' },
}

local function ensureSection()
    Core.Ini['SideKick-Items'] = Core.Ini['SideKick-Items'] or {}
    return Core.Ini['SideKick-Items']
end

local function slotKey(i)
    return string.format('Item%d', tonumber(i) or 0)
end

local function slotModeKey(i)
    return string.format('Item%d_Mode', tonumber(i) or 0)
end

local function slotCombatHpKey(i)
    return string.format('Item%d_CombatHpPct', tonumber(i) or 0)
end

local function trim(s)
    s = tostring(s or '')
    s = s:gsub('^%s+', ''):gsub('%s+$', '')
    return s
end

local function fmtSeconds(sec)
    sec = tonumber(sec) or 0
    if sec <= 0 then return '' end
    if Helpers and Helpers.fmtCooldown then return Helpers.fmtCooldown(sec) end
    return string.format('%ds', math.floor(sec + 0.5))
end

local function safeCall(fn)
    local ok, v = pcall(fn)
    if ok then return v end
    return nil
end

local function can_query_items()
    if Core and Core.CanQueryItems then
        return Core.CanQueryItems()
    end
    local mqTLO = mq.TLO
    if not mqTLO or not mqTLO.MacroQuest or not mqTLO.MacroQuest.GameState then
        return false
    end
    local gs = mqTLO.MacroQuest.GameState()
    if gs ~= 'INGAME' then
        return false
    end
    if mqTLO.Me and mqTLO.Me.Zoning and mqTLO.Me.Zoning() then
        return false
    end
    return true
end

local function buildClickyInfo(itemName)
    itemName = trim(itemName)
    if itemName == '' then return nil end
    if not can_query_items() then return nil end
    if not (mq and mq.TLO and mq.TLO.FindItem) then return nil end

    local item = mq.TLO.FindItem(itemName)
    if not (item and item()) then return nil end

    local icon = tonumber(safeCall(function() return item.Icon and item.Icon() end)) or 0
    local clickySpell = safeCall(function()
        return item.Clicky and item.Clicky.Spell and item.Clicky.Spell.RankName and item.Clicky.Spell.RankName()
    end)
    local beneficial = safeCall(function()
        return item.Clicky and item.Clicky.Spell and item.Clicky.Spell.Beneficial and item.Clicky.Spell.Beneficial()
    end)
    local category = safeCall(function()
        return item.Clicky and item.Clicky.Spell and item.Clicky.Spell.Category and item.Clicky.Spell.Category()
    end)
    local castTimeMs = tonumber(safeCall(function()
        return item.Clicky and item.Clicky.CastTime and item.Clicky.CastTime()
    end)) or 0
    local recastMs = tonumber(safeCall(function()
        return item.Clicky and item.Clicky.Spell and item.Clicky.Spell.RecastTime and item.Clicky.Spell.RecastTime()
    end)) or 0
    local duration = safeCall(function()
        if item.Clicky and item.Clicky.Spell and item.Clicky.Spell.Duration and item.Clicky.Spell.Duration.TotalSeconds then
            return item.Clicky.Spell.Duration.TotalSeconds()
        end
        return item.Clicky and item.Clicky.Spell and item.Clicky.Spell.Duration and item.Clicky.Spell.Duration()
    end)
    duration = tonumber(duration) or 0

    local timerId = tonumber(safeCall(function()
        return item.Clicky and item.Clicky.TimerID and item.Clicky.TimerID()
    end)) or 0

    return {
        name = itemName,
        icon = icon,
        spell = trim(clickySpell),
        beneficial = beneficial == true,
        durationSec = duration,
        durationFmt = fmtSeconds(duration),
        category = trim(category),
        castTimeMs = castTimeMs,
        castTimeFmt = (castTimeMs > 0) and string.format('%.1fs', castTimeMs / 1000) or '',
        recastMs = recastMs,
        recastSec = recastMs / 1000,
        recastFmt = fmtSeconds(recastMs / 1000),
        timerId = timerId,
    }
end

local function itemReady(itemName)
    itemName = trim(itemName)
    if itemName == '' then return false end
    if not can_query_items() then return false end
    local item = safeCall(function() return mq.TLO.FindItem(itemName) end)
    if not (item and item()) then return false end
    local ready = safeCall(function() return item.TimerReady and item.TimerReady() end)
    if ready ~= nil then
        return tonumber(ready) == 0
    end
    return true
end

local function meHasBuff(me, spellName)
    spellName = trim(spellName)
    if spellName == '' then return false end
    if not me then return false end
    local b = safeCall(function() return me.Buff and me.Buff(spellName) end)
    if b and safeCall(function() return b() end) then return true end
    local s = safeCall(function() return me.Song and me.Song(spellName) end)
    if s and safeCall(function() return s() end) then return true end
    return false
end

local function targetHasSpell(target, spellName)
    spellName = trim(spellName)
    if spellName == '' then return false end
    if not target then return false end

    local d = safeCall(function() return target.Debuff and target.Debuff(spellName) end)
    if d and safeCall(function() return d() end) then return true end
    local b = safeCall(function() return target.Buff and target.Buff(spellName) end)
    if b and safeCall(function() return b() end) then return true end
    local md = safeCall(function() return target.MyDebuff and target.MyDebuff(spellName) end)
    if md and safeCall(function() return md() end) then return true end
    local mb = safeCall(function() return target.MyBuff and target.MyBuff(spellName) end)
    if mb and safeCall(function() return mb() end) then return true end
    return false
end

local function effectAlreadyActive(entry)
    local info = entry and entry.info or nil
    if not info then return false end
    local spellName = trim(info.spell)
    if spellName == '' then return false end

    if info.beneficial == true then
        return meHasBuff(mq.TLO.Me, spellName)
    end

    -- Only gate detrimental effects if the clicky has a duration.
    if (tonumber(info.durationSec) or 0) <= 0 then
        return false
    end

    local t = mq.TLO.Target
    if not (t and t()) then
        return false
    end
    local tType = tostring(safeCall(function() return t.Type and t.Type() end) or '')
    if tType ~= 'NPC' then
        return false
    end
    return targetHasSpell(t, spellName)
end

local function modeKeyFromValue(v)
    v = tostring(v or ''):lower()
    if v == '' then return 'on_demand' end
    if v == 'on_demand' or v == 'ondemand' then return 'on_demand' end
    if v == 'combat' then return 'combat' end
    if v == 'ooc' or v == 'outofcombat' then return 'ooc' end
    if v == 'on_condition' or v == 'oncondition' then return 'on_condition' end
    return 'on_demand'
end

local function getSlotMode(sec, i)
    local key = slotModeKey(i)
    return modeKeyFromValue(sec[key])
end

local function getSlotCombatHpPct(sec, i)
    local key = slotCombatHpKey(i)
    local v = tonumber(sec[key]) or 0
    if v < 0 then v = 0 end
    if v > 100 then v = 100 end
    return math.floor(v + 0.5)
end

function M.getSlots()
    local sec = ensureSection()
    local out = {}
    for i = 1, M.SLOT_COUNT do
        local key = slotKey(i)
        table.insert(out, {
            index = i,
            key = key,
            name = trim(sec[key]),
            mode = getSlotMode(sec, i),
            combatHpPct = getSlotCombatHpPct(sec, i),
        })
    end
    return out
end

function M.setSlot(i, itemName)
    local sec = ensureSection()
    local key = slotKey(i)
    local name = trim(itemName)
    sec[key] = name
    if name == '' then
        M.ClickyCache[key] = nil
    else
        M.ClickyCache[key] = buildClickyInfo(name)
    end
    Core.save()
end

function M.clearSlot(i)
    M.setSlot(i, '')
end

function M.clearAll()
    for i = 1, M.SLOT_COUNT do
        M.clearSlot(i)
    end
end

function M.setSlots(slots)
    if not slots then return end
    for i = 1, M.SLOT_COUNT do
        local slot = slots[i]
        if slot then
            local name = slot.name or slot.itemName or ''
            M.setSlot(i, name)
            if slot.mode then
                M.setSlotMode(i, slot.mode)
            end
            if slot.combatHpPct then
                M.setSlotCombatHpPct(i, slot.combatHpPct)
            end
        else
            M.clearSlot(i)
        end
    end
end

function M.addSlot(config)
    if not config then return false end
    local name = config.itemName or config.name or ''
    if name == '' then return false end

    -- Find first empty slot
    local slots = M.getSlots()
    for i = 1, M.SLOT_COUNT do
        local slot = slots[i]
        if not slot.name or slot.name == '' then
            M.setSlot(i, name)
            if config.mode then
                M.setSlotMode(i, config.mode)
            end
            return true
        end
    end
    return false -- No empty slots
end

function M.setSlotMode(i, modeKey)
    local sec = ensureSection()
    modeKey = modeKeyFromValue(modeKey)
    sec[slotModeKey(i)] = modeKey
    Core.save()
end

function M.setSlotCombatHpPct(i, hpPct)
    local sec = ensureSection()
    hpPct = tonumber(hpPct) or 0
    if hpPct < 0 then hpPct = 0 end
    if hpPct > 100 then hpPct = 100 end
    sec[slotCombatHpKey(i)] = tostring(math.floor(hpPct + 0.5))
    Core.save()
end

function M.refreshCache()
    local sec = ensureSection()
    for i = 1, M.SLOT_COUNT do
        local key = slotKey(i)
        local name = trim(sec[key])
        if name ~= '' then
            M.ClickyCache[key] = buildClickyInfo(name)
        else
            M.ClickyCache[key] = nil
        end
    end
end

function M.collectConfigured()
    local sec = ensureSection()
    local out = {}
    for i = 1, M.SLOT_COUNT do
        local key = slotKey(i)
        local name = trim(sec[key])
        if name ~= '' then
            local info = M.ClickyCache[key]
            if not info or info.name ~= name then
                info = buildClickyInfo(name)
                M.ClickyCache[key] = info
            end
            table.insert(out, {
                slot = i,
                slotKey = key,
                itemName = name,
                info = info,
                mode = getSlotMode(sec, i),
                combatHpPct = getSlotCombatHpPct(sec, i),
            })
        end
    end
    return out
end

local function getConditionData(slotIndex)
    local condKey = string.format('ItemSlot%dCondition', slotIndex)
    local condData = Core.Settings[condKey]
    if not condData and Core.Ini and Core.Ini['SideKick-Items'] then
        local serialized = Core.Ini['SideKick-Items'][condKey]
        if serialized and ConditionBuilder.deserialize then
            condData = ConditionBuilder.deserialize(serialized)
            if condData then
                Core.Settings[condKey] = condData
            end
        end
    end
    return condData
end

local function shouldAutoUse(entry, inCombat, hpPct)
    if not entry or not entry.itemName then return false end
    local mode = tostring(entry.mode or 'on_demand')
    if mode == 'combat' then
        if not inCombat then return false end
        local gate = tonumber(entry.combatHpPct) or 0
        if gate > 0 and hpPct ~= nil then
            return hpPct <= gate
        end
        return true
    end
    if mode == 'ooc' then
        return inCombat ~= true
    end
    if mode == 'on_condition' then
        local condData = getConditionData(entry.slot)
        if not condData then return false end
        if ConditionBuilder.evaluate then
            return ConditionBuilder.evaluate(condData, entry.itemName)
        end
        return false
    end
    return false
end

function M.useItem(itemName, opts)
    itemName = trim(itemName)
    if itemName == '' then return end
    if not can_query_items() then return end
    opts = opts or {}
    local throttleKey = tostring(opts.throttleKey or itemName)
    local now = os.clock()
    local lastAt = M._runtime.lastManualAt[throttleKey] or 0
    local minInterval = tonumber(opts.minInterval) or 0.25
    if (now - lastAt) < minInterval then return end
    M._runtime.lastManualAt[throttleKey] = now

    if mq and mq.cmdf then
        mq.cmdf('/useitem "%s"', itemName)
    elseif mq and mq.cmd then
        mq.cmd('/useitem "' .. itemName .. '"')
    end
end

function M.tick()
    if not mq or not mq.TLO or not mq.TLO.Me then return end
    local me = mq.TLO.Me
    if not (me and me()) then return end

    local now = os.clock()
    local inCombat = false
    local hpPct = nil
    do
        local v = safeCall(function() return me.Combat and me.Combat() end)
        inCombat = v == true
        local hp = safeCall(function() return me.PctHPs and me.PctHPs() end)
        if hp ~= nil then hpPct = tonumber(hp) end
    end

    -- Don't try to auto-click while casting.
    local casting = safeCall(function() return me.Casting and me.Casting() end)
    if casting == true then return end

    for _, entry in ipairs(M.collectConfigured()) do
        if shouldAutoUse(entry, inCombat, hpPct) then
            if not itemReady(entry.itemName) then goto continue end
            if effectAlreadyActive(entry) then goto continue end

            local key = tostring(entry.slotKey or entry.itemName)
            local lastAt = M._runtime.lastAutoAt[key] or 0
            if (now - lastAt) >= 1.0 then
                M._runtime.lastAutoAt[key] = now
                M.useItem(entry.itemName, { throttleKey = key, minInterval = 0.25 })
            end
        end
        ::continue::
    end
end

return M
