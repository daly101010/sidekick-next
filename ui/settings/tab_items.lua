-- ============================================================
-- SideKick Settings - Items Tab
-- ============================================================
-- Item bar layout and slot configuration.

local imgui = require('ImGui')
local mq = require('mq')
local C = require('sidekick-next.ui.constants')
local Settings = require('sidekick-next.ui.settings')

local M = {}

-- Lazy-load Items module
local _Items = nil
local function getItems()
    if not _Items then
        local ok, mod = pcall(require, 'utils.items')
        if ok then _Items = mod end
    end
    return _Items
end

-- Undo state for clear operations
local _lastCleared = nil

function M.draw(settings, themeNames, onChange)
    local changed
    local Items = getItems()

    -- Enable item bar
    local itemBar = settings.SideKickItemBarEnabled ~= false
    itemBar, changed = imgui.Checkbox('Show item bar', itemBar)
    if changed and onChange then onChange('SideKickItemBarEnabled', itemBar) end

    -- Auto items
    local autoItems = settings.AutoItemsEnabled ~= false
    autoItems, changed = imgui.Checkbox('Auto-use items', autoItems)
    if changed and onChange then onChange('AutoItemsEnabled', autoItems) end

    imgui.Separator()
    imgui.Text('Layout')

    -- Cell size
    local itemCell = tonumber(settings.SideKickItemBarCell) or C.LAYOUT.ITEM_CELL_SIZE
    itemCell, changed = imgui.SliderInt('Cell Size', itemCell, C.LAYOUT.MIN_CELL_SIZE, C.LAYOUT.MAX_CELL_SIZE)
    if changed and onChange then onChange('SideKickItemBarCell', itemCell) end

    -- Rows
    local itemRows = tonumber(settings.SideKickItemBarRows) or C.LAYOUT.ITEM_ROWS
    itemRows, changed = imgui.SliderInt('Rows', itemRows, 1, C.LAYOUT.MAX_ROWS)
    if changed and onChange then onChange('SideKickItemBarRows', itemRows) end

    -- Gap
    local itemGap = tonumber(settings.SideKickItemBarGap) or 4
    itemGap, changed = imgui.SliderInt('Gap', itemGap, 0, 12)
    if changed and onChange then onChange('SideKickItemBarGap', itemGap) end

    -- Padding
    local itemPad = tonumber(settings.SideKickItemBarPad) or 6
    itemPad, changed = imgui.SliderInt('Padding', itemPad, 0, 24)
    if changed and onChange then onChange('SideKickItemBarPad', itemPad) end

    -- Background alpha
    local itemAlpha = tonumber(settings.SideKickItemBarBgAlpha) or 0.85
    itemAlpha, changed = imgui.SliderFloat('Background Alpha', itemAlpha, 0.2, 1.0)
    if changed and onChange then onChange('SideKickItemBarBgAlpha', itemAlpha) end

    imgui.Separator()
    imgui.Text('Anchoring')

    -- Anchor target
    local target = Settings.comboKeyed('Anchor To', settings.SideKickItemBarAnchorTarget or 'grouptarget', C.ANCHOR_TARGETS)
    if target ~= tostring(settings.SideKickItemBarAnchorTarget or 'grouptarget') and onChange then
        onChange('SideKickItemBarAnchorTarget', target)
    end

    -- Anchor mode
    local itemAnchor = tostring(settings.SideKickItemBarAnchor or 'none')
    itemAnchor = Settings.comboString('Anchor Mode', itemAnchor, C.ANCHOR_MODES)
    if itemAnchor ~= tostring(settings.SideKickItemBarAnchor or 'none') and onChange then
        onChange('SideKickItemBarAnchor', itemAnchor)
    end

    -- Anchor gap
    local itemAnchorGap = tonumber(settings.SideKickItemBarAnchorGap) or 2
    itemAnchorGap, changed = imgui.SliderInt('Anchor Gap', itemAnchorGap, 0, C.LAYOUT.MAX_ANCHOR_GAP)
    if changed and onChange then onChange('SideKickItemBarAnchorGap', itemAnchorGap) end

    -- Item slots management
    if Items then
        imgui.Separator()
        imgui.Text('Item Slots')

        local slots = Items.getSlots and Items.getSlots() or {}
        local slotCount = #slots

        imgui.Text('Configured: ' .. slotCount .. ' items')

        -- Clear and Undo buttons
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

        -- Slot list (simplified view)
        if slotCount > 0 and imgui.CollapsingHeader('Slot Details') then
            for i, slot in ipairs(slots) do
                local name = slot.name or slot.itemName or ('Slot ' .. i)
                imgui.BulletText(name)
            end
        end

        -- Add current target item
        if imgui.Button('Add Cursor Item') then
            local cursor = mq.TLO.Cursor
            if cursor and cursor.ID() then
                if Items.addSlot then
                    Items.addSlot({
                        itemName = cursor.Name(),
                        itemId = cursor.ID(),
                    })
                end
            end
        end
        if imgui.IsItemHovered() then
            Settings.safeTooltip('Pick up an item and click to add it to the bar')
        end
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
