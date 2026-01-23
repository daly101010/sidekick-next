-- ============================================================
-- SideKick Setting Card Component
-- ============================================================
-- Card-based container for grouping related settings with
-- visual separation and optional icons.
--
-- Usage:
--   local Card = require('sidekick-next.ui.components.setting_card')
--
--   if Card.begin('Combat Settings', 'Classic', { icon = '⚔' }) then
--       -- Settings content here
--       imgui.Checkbox('Enable Assist', enabled)
--   end
--   Card.finish()

local imgui = require('ImGui')
local Themes = require('sidekick-next.themes')
local Colors = require('sidekick-next.ui.colors')
local Draw = require('sidekick-next.ui.draw_helpers')

local M = {}

-- Stack for nested cards
local _cardStack = {}
local _cardCount = 0

-- ============================================================
-- CARD CONTAINER
-- ============================================================

-- Begin a setting card
-- Returns true if content should be drawn (card is visible)
function M.begin(title, themeName, opts)
    opts = opts or {}
    local icon = opts.icon
    local collapsible = opts.collapsible == true
    local defaultOpen = opts.defaultOpen ~= false
    local height = opts.height or 0  -- 0 = auto
    local noPadding = opts.noPadding == true

    themeName = themeName or 'Classic'
    local style = Themes.getWindowStyle(themeName)

    -- Generate unique ID
    _cardCount = _cardCount + 1
    local cardId = '##card_' .. _cardCount .. '_' .. tostring(title or 'untitled')

    -- Push card info to stack
    table.insert(_cardStack, {
        id = cardId,
        title = title,
        themeName = themeName,
        stylesPushed = 0,
        colorsPushed = 0,
    })
    local cardInfo = _cardStack[#_cardStack]

    -- Calculate card background color (slightly darker than window)
    local bgCol = style.ChildBg or style.WindowBg or { 0.1, 0.1, 0.1 }
    local cardBg = {
        bgCol[1] * 0.85,
        bgCol[2] * 0.85,
        bgCol[3] * 0.85,
    }

    -- Push styling
    local stylesPushed = 0
    local colorsPushed = 0

    if imgui.PushStyleColor and ImGuiCol then
        -- Darker background for card
        pcall(function()
            imgui.PushStyleColor(ImGuiCol.ChildBg, cardBg[1], cardBg[2], cardBg[3], 0.95)
            colorsPushed = colorsPushed + 1
        end)

        -- Subtle border
        local borderCol = style.Border or { 0.3, 0.3, 0.3 }
        pcall(function()
            imgui.PushStyleColor(ImGuiCol.Border, borderCol[1], borderCol[2], borderCol[3], 0.5)
            colorsPushed = colorsPushed + 1
        end)
    end

    if imgui.PushStyleVar and ImGuiStyleVar then
        pcall(function()
            imgui.PushStyleVar(ImGuiStyleVar.ChildRounding, 6)
            stylesPushed = stylesPushed + 1
        end)
        pcall(function()
            imgui.PushStyleVar(ImGuiStyleVar.ChildBorderSize, 1)
            stylesPushed = stylesPushed + 1
        end)
        if not noPadding then
            pcall(function()
                imgui.PushStyleVar(ImGuiStyleVar.WindowPadding, 8, 6)
                stylesPushed = stylesPushed + 1
            end)
        end
    end

    cardInfo.stylesPushed = stylesPushed
    cardInfo.colorsPushed = colorsPushed

    -- Begin child window
    local flags = 0
    if ImGuiWindowFlags and bit32 then
        flags = bit32.bor(
            ImGuiWindowFlags.NoScrollbar or 0,
            ImGuiWindowFlags.NoScrollWithMouse or 0
        )
    end

    local visible = imgui.BeginChild(cardId, 0, height, true, flags)

    if visible then
        -- Draw card header
        if title and title ~= '' then
            local textCol = Colors.text(themeName)
            local headerCol = style.Border or { 0.4, 0.4, 0.4 }

            -- Icon + Title
            if icon then
                imgui.TextColored(headerCol[1], headerCol[2], headerCol[3], 1, tostring(icon))
                imgui.SameLine()
            end

            imgui.TextColored(
                headerCol[1] * 1.2,
                headerCol[2] * 1.2,
                headerCol[3] * 1.2,
                1,
                tostring(title)
            )

            imgui.Separator()
            imgui.Spacing()
        end
    end

    return visible
end

-- End the current card
function M.finish()
    if #_cardStack == 0 then return end

    local cardInfo = table.remove(_cardStack)

    imgui.EndChild()

    -- Pop styling in reverse order
    if imgui.PopStyleVar and cardInfo.stylesPushed > 0 then
        pcall(imgui.PopStyleVar, cardInfo.stylesPushed)
    end
    if imgui.PopStyleColor and cardInfo.colorsPushed > 0 then
        pcall(imgui.PopStyleColor, cardInfo.colorsPushed)
    end

    -- Add spacing after card
    imgui.Spacing()
end

-- ============================================================
-- CARD WITH COLLAPSING HEADER
-- ============================================================

-- Card that can be collapsed (uses CollapsingHeader internally)
function M.collapsible(title, themeName, opts)
    opts = opts or {}
    local icon = opts.icon
    local defaultOpen = opts.defaultOpen ~= false

    themeName = themeName or 'Classic'
    local style = Themes.getWindowStyle(themeName)

    -- Header styling
    local headerCol = style.Header or { 0.2, 0.2, 0.2 }
    local borderCol = style.Border or { 0.3, 0.3, 0.3 }

    local colorsPushed = 0
    if imgui.PushStyleColor and ImGuiCol then
        pcall(function()
            imgui.PushStyleColor(ImGuiCol.Header, headerCol[1], headerCol[2], headerCol[3], 0.8)
            colorsPushed = colorsPushed + 1
        end)
        pcall(function()
            imgui.PushStyleColor(ImGuiCol.HeaderHovered, headerCol[1] * 1.2, headerCol[2] * 1.2, headerCol[3] * 1.2, 0.9)
            colorsPushed = colorsPushed + 1
        end)
        pcall(function()
            imgui.PushStyleColor(ImGuiCol.HeaderActive, headerCol[1] * 1.3, headerCol[2] * 1.3, headerCol[3] * 1.3, 1.0)
            colorsPushed = colorsPushed + 1
        end)
    end

    -- Build header text
    local headerText = tostring(title or 'Settings')
    if icon then
        headerText = tostring(icon) .. '  ' .. headerText
    end

    -- Determine flags
    local flags = 0
    if ImGuiTreeNodeFlags and defaultOpen then
        flags = ImGuiTreeNodeFlags.DefaultOpen or 0
    end

    local isOpen = imgui.CollapsingHeader(headerText, flags)

    if imgui.PopStyleColor and colorsPushed > 0 then
        pcall(imgui.PopStyleColor, colorsPushed)
    end

    if isOpen then
        -- Indent content
        imgui.Indent(8)
        imgui.Spacing()
    end

    return isOpen, function()
        -- Return a finish function for cleaner syntax
        if isOpen then
            imgui.Spacing()
            imgui.Unindent(8)
        end
    end
end

-- ============================================================
-- INLINE CARD (no border, just visual grouping)
-- ============================================================

function M.inline(title, themeName)
    themeName = themeName or 'Classic'
    local style = Themes.getWindowStyle(themeName)
    local borderCol = style.Border or { 0.3, 0.3, 0.3 }

    if title and title ~= '' then
        imgui.TextColored(borderCol[1], borderCol[2], borderCol[3], 1, tostring(title))
        imgui.Separator()
    end

    imgui.Indent(4)
    imgui.Spacing()

    return function()
        imgui.Spacing()
        imgui.Unindent(4)
    end
end

-- ============================================================
-- CARD ROW (horizontal card container)
-- ============================================================

-- Begin a row of cards (uses columns)
function M.beginRow(count)
    count = count or 2
    if imgui.Columns then
        imgui.Columns(count, nil, false)
    end
end

-- Move to next card in row
function M.nextInRow()
    if imgui.NextColumn then
        imgui.NextColumn()
    end
end

-- End card row
function M.endRow()
    if imgui.Columns then
        imgui.Columns(1)
    end
end

-- ============================================================
-- RESET (for cleanup between frames if needed)
-- ============================================================

function M.reset()
    _cardStack = {}
    _cardCount = 0
end

return M
