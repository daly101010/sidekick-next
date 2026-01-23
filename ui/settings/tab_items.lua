-- ============================================================
-- SideKick Settings - Items Tab
-- ============================================================
-- Item bar layout and slot configuration.

local imgui = require('ImGui')
local mq = require('mq')
local C = require('sidekick-next.ui.constants')
local Settings = require('sidekick-next.ui.settings')
local Core = require('sidekick-next.utils.core')
local ConditionBuilder = require('sidekick-next.ui.condition_builder')

local M = {}

-- Lazy-load Items module
local _Items = nil
local function getItems()
    if not _Items then
        local ok, mod = pcall(require, 'sidekick-next.utils.items')
        if ok then _Items = mod end
    end
    return _Items
end

-- Undo state for clear operations
local _lastCleared = nil

-- Icon animation cache
local _animItems = nil
local function getAnimItems()
    if _animItems == nil then
        if mq.FindTextureAnimation then
            _animItems = mq.FindTextureAnimation('A_DragItem') or false
        else
            _animItems = false
        end
    end
    return _animItems or nil
end

local function iconCellFromIconId(iconId)
    local iconIdx = tonumber(iconId) or 0
    local cell0 = (iconIdx > 0) and (iconIdx - 500) or 0
    if cell0 < 0 then cell0 = 0 end
    return cell0
end

local function drawAnimIcon(iconId, size)
    local animItems = getAnimItems()
    if not (animItems and imgui.DrawTextureAnimation) then return false end
    local okCell = pcall(function() animItems:SetTextureCell(iconCellFromIconId(iconId)) end)
    if not okCell then return false end
    local okDraw = pcall(imgui.DrawTextureAnimation, animItems, size, size)
    return okDraw == true
end

local function isMouseReleasedLeft()
    if not imgui.IsMouseReleased then return false end
    local ok, v = pcall(imgui.IsMouseReleased, 0)
    if ok and v == true then return true end
    local mb = rawget(_G, 'ImGuiMouseButton')
    if mb and mb.Left ~= nil then
        ok, v = pcall(imgui.IsMouseReleased, mb.Left)
        if ok and v == true then return true end
    end
    return false
end

local MODES = {
    { key = 'on_demand', label = 'On Demand' },
    { key = 'combat', label = 'Combat (Auto)' },
    { key = 'ooc', label = 'Out of Combat (Auto)' },
    { key = 'on_condition', label = 'On Condition' },
}

local function modeLabel(k)
    for _, m in ipairs(MODES) do
        if m.key == k then return m.label end
    end
    return tostring(k)
end

-- Draw only the bar UI settings (for consolidated UI tab)
function M.drawBarUI(settings, themeNames, onChange)
    local changed

    -- Enable item bar
    local itemBar = settings.SideKickItemBarEnabled ~= false
    itemBar, changed = Settings.labeledCheckbox('Show item bar', itemBar)
    if changed and onChange then onChange('SideKickItemBarEnabled', itemBar) end

    -- Note: AutoItemsEnabled defaults to true (hidden setting)
    -- Auto-use behavior is controlled per-item via mode: combat, ooc, on_condition
    -- Items set to 'on_demand' mode are manual-only

    imgui.Separator()
    imgui.Text('Layout')

    -- Cell size
    local itemCell = tonumber(settings.SideKickItemBarCell) or C.LAYOUT.ITEM_CELL_SIZE
    itemCell, changed = Settings.labeledSliderInt('Cell Size##itembar', itemCell, C.LAYOUT.MIN_CELL_SIZE, C.LAYOUT.MAX_CELL_SIZE)
    if changed and onChange then onChange('SideKickItemBarCell', itemCell) end

    -- Rows
    local itemRows = tonumber(settings.SideKickItemBarRows) or C.LAYOUT.ITEM_ROWS
    itemRows, changed = Settings.labeledSliderInt('Rows##itembar', itemRows, 1, C.LAYOUT.MAX_ROWS)
    if changed and onChange then onChange('SideKickItemBarRows', itemRows) end

    -- Gap
    local itemGap = tonumber(settings.SideKickItemBarGap) or 4
    itemGap, changed = Settings.labeledSliderInt('Gap##itembar', itemGap, 0, 12)
    if changed and onChange then onChange('SideKickItemBarGap', itemGap) end

    -- Padding
    local itemPad = tonumber(settings.SideKickItemBarPad) or 6
    itemPad, changed = Settings.labeledSliderInt('Padding##itembar', itemPad, 0, 24)
    if changed and onChange then onChange('SideKickItemBarPad', itemPad) end

    -- Background alpha
    local itemAlpha = tonumber(settings.SideKickItemBarBgAlpha) or 0.85
    itemAlpha, changed = Settings.labeledSliderFloat('Background Alpha##itembar', itemAlpha, 0.2, 1.0)
    if changed and onChange then onChange('SideKickItemBarBgAlpha', itemAlpha) end

    imgui.Separator()
    imgui.Text('Anchoring')

    -- Anchor target
    local target = Settings.labeledComboKeyed('Anchor To##itembar', settings.SideKickItemBarAnchorTarget or 'grouptarget', C.ANCHOR_TARGETS)
    if target ~= tostring(settings.SideKickItemBarAnchorTarget or 'grouptarget') and onChange then
        onChange('SideKickItemBarAnchorTarget', target)
    end

    -- Anchor mode
    local itemAnchor = tostring(settings.SideKickItemBarAnchor or 'none')
    itemAnchor = Settings.labeledCombo('Anchor Mode##itembar', itemAnchor, C.ANCHOR_MODES)
    if itemAnchor ~= tostring(settings.SideKickItemBarAnchor or 'none') and onChange then
        onChange('SideKickItemBarAnchor', itemAnchor)
    end

    -- Anchor gap
    local itemAnchorGap = tonumber(settings.SideKickItemBarAnchorGap) or 2
    itemAnchorGap, changed = Settings.labeledSliderInt('Anchor Gap##itembar', itemAnchorGap, 0, C.LAYOUT.MAX_ANCHOR_GAP)
    if changed and onChange then onChange('SideKickItemBarAnchorGap', itemAnchorGap) end
end

-- Draw the full Items tab (slots configuration)
function M.draw(settings, themeNames, onChange)
    local changed
    local Items = getItems()

    -- Item slots management
    if Items then
        imgui.Text('Item Slots')
        imgui.TextWrapped('Drag an item onto a slot (or pick it up and click the slot icon) to assign it.')

        local slots = Items.getSlots and Items.getSlots() or {}
        local configured = Items.collectConfigured and Items.collectConfigured() or {}
        local configuredByIndex = {}
        for _, e in ipairs(configured) do
            if e and e.slot then
                configuredByIndex[tonumber(e.slot) or 0] = e
            end
        end

        local iconSize = 32

        -- Clear All and Undo buttons
        if imgui.Button('Clear All') then
            _lastCleared = Items.getSlots and Items.getSlots() or nil
            if Items.clearAll then
                Items.clearAll()
            end
        end

        if _lastCleared and #_lastCleared > 0 then
            imgui.SameLine()
            if imgui.Button('Undo') then
                if Items.setSlots then
                    Items.setSlots(_lastCleared)
                end
                _lastCleared = nil
            end
        end

        -- Add current cursor item
        imgui.SameLine()
        if imgui.Button('Add Cursor Item') then
            local cursor = mq.TLO.Cursor
            if cursor and cursor.ID() then
                if Items.addSlot then
                    Items.addSlot({
                        itemName = cursor.Name(),
                        itemId = cursor.ID(),
                    })
                    mq.cmd('/autoinv')
                end
            end
        end
        if imgui.IsItemHovered() then
            Settings.safeTooltip('Pick up an item and click to add it to the first empty slot')
        end

        -- Slot Details
        if imgui.CollapsingHeader('Slot Details', ImGuiTreeNodeFlags.DefaultOpen) then
            for _, slot in ipairs(slots) do
                imgui.PushID(slot.key or ('slot' .. slot.index))

                local entry = configuredByIndex[tonumber(slot.index) or 0]
                local slotIcon = entry and entry.info and tonumber(entry.info.icon) or 0

                -- Check cursor for drag-drop
                local cursorName = ''
                local cursorIcon = 0
                if mq.TLO.Cursor and mq.TLO.Cursor() then
                    cursorName = mq.TLO.Cursor.Name() or ''
                    cursorIcon = tonumber((mq.TLO.Cursor.Icon and mq.TLO.Cursor.Icon()) or 0) or 0
                end

                -- Icon button (drag-drop target)
                if imgui.Button('##slot_icon', iconSize, iconSize) then
                    if cursorName ~= '' then
                        Items.setSlot(slot.index, cursorName)
                        mq.cmd('/autoinv')
                    end
                end

                local hovered = imgui.IsItemHovered()
                if hovered and cursorName ~= '' and isMouseReleasedLeft() then
                    Items.setSlot(slot.index, cursorName)
                    mq.cmd('/autoinv')
                end

                -- Draw icon overlay
                do
                    local pos = imgui.GetItemRectMin and imgui.GetItemRectMin() or nil
                    local x, y
                    if type(pos) == 'table' then
                        x = pos.x or pos[1]
                        y = pos.y or pos[2]
                    elseif type(pos) == 'number' then
                        x = pos
                        y = select(2, imgui.GetItemRectMin())
                    end
                    if x and y then
                        imgui.SetCursorScreenPos(x, y)
                        local showIcon = (hovered and cursorIcon > 0) and cursorIcon or slotIcon
                        if showIcon and showIcon > 0 then
                            drawAnimIcon(showIcon, iconSize)
                        end
                        imgui.SetCursorScreenPos(x, y)
                    end
                end

                if hovered then
                    if cursorName ~= '' then
                        Settings.safeTooltip('Drop: ' .. tostring(cursorName))
                    else
                        Settings.safeTooltip('Click or drop an item here')
                    end
                end

                -- Clear button (X)
                imgui.SameLine()
                if imgui.SmallButton('X##clear') then
                    Items.clearSlot(slot.index)
                end
                if imgui.IsItemHovered() then
                    Settings.safeTooltip('Clear this slot')
                end

                -- Item name or empty
                imgui.SameLine()
                if slot.name and slot.name ~= '' then
                    imgui.Text(slot.name)
                else
                    imgui.TextDisabled('(empty)')
                end

                -- Mode selector
                imgui.SameLine()
                imgui.SetNextItemWidth(160)
                local curMode = tostring(slot.mode or 'on_demand')

                -- Build labels array and find current index
                local modeLabels = {}
                local currentIdx = 1
                for i, m in ipairs(MODES) do
                    modeLabels[i] = m.label
                    if m.key == curMode then currentIdx = i end
                end

                -- Use simple Combo (more reliable than BeginCombo/Selectable)
                local newIdx, modeChanged = imgui.Combo('##mode' .. slot.index, currentIdx, modeLabels)
                if modeChanged and newIdx ~= currentIdx then
                    Items.setSlotMode(slot.index, MODES[newIdx].key)
                    curMode = MODES[newIdx].key
                end
                if imgui.IsItemHovered() then
                    Settings.safeTooltip('Choose how this item activates.')
                end

                -- HP gate for combat mode
                if curMode == 'combat' then
                    imgui.SameLine()
                    imgui.SetNextItemWidth(140)
                    local hpGate = tonumber(slot.combatHpPct) or 0
                    local newHp = hpGate
                    newHp, changed = imgui.SliderInt('HP% <=##hpGate' .. slot.index, newHp, 0, 100)
                    if changed then
                        Items.setSlotCombatHpPct(slot.index, newHp)
                    end
                    if imgui.IsItemHovered() then
                        Settings.safeTooltip('Only auto-use in combat when HP% is at or below this value. 0 disables.')
                    end
                end

                -- Condition builder for on_condition mode (isolated in its own ID scope)
                if curMode == 'on_condition' then
                    imgui.PushID('cond_builder_' .. slot.index)
                    local condKey = string.format('ItemSlot%dCondition', slot.index)
                    local condData = Core.Settings[condKey]
                    if not condData and Core.Ini and Core.Ini['SideKick-Items'] then
                        local serialized = Core.Ini['SideKick-Items'][condKey]
                        if serialized and ConditionBuilder.deserialize then
                            condData = ConditionBuilder.deserialize(serialized)
                        end
                    end

                    imgui.Indent(20)
                    ConditionBuilder.drawInline(condKey, condData, function(newData)
                        Core.Settings[condKey] = newData
                        if Core.Ini and ConditionBuilder.serialize then
                            Core.Ini['SideKick-Items'] = Core.Ini['SideKick-Items'] or {}
                            Core.Ini['SideKick-Items'][condKey] = ConditionBuilder.serialize(newData)
                        end
                        if Core.save then Core.save() end
                    end)
                    imgui.Unindent(20)
                    imgui.PopID()
                end

                imgui.PopID()
            end
        end
    else
        imgui.TextDisabled('Items module not loaded')
    end
end

-- Undo support
function M.hasUndo()
    return _lastCleared and #_lastCleared > 0
end

function M.undoClear()
    local Items = getItems()
    if _lastCleared and Items and Items.setSlots then
        Items.setSlots(_lastCleared)
        _lastCleared = nil
        return true
    end
    return false
end

return M
