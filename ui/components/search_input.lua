-- ============================================================
-- SideKick Search Input Component
-- ============================================================
-- Styled search box with clear button, icons, and filter hints.
--
-- Usage:
--   local Search = require('sidekick-next.ui.components.search_input')
--   local text, changed = Search.draw('##search', searchText, 'Classic', {
--       placeholder = 'Search spells...',
--       width = 200,
--   })

local imgui = require('ImGui')
local Draw = require('sidekick-next.ui.draw_helpers')
local Colors = require('sidekick-next.ui.colors')

local M = {}

-- ============================================================
-- THEME COLORS
-- ============================================================

local function getSearchColors(themeName)
    local colors = {
        Classic = {
            bg = { 0.12, 0.14, 0.18 },
            bgFocused = { 0.15, 0.18, 0.24 },
            border = { 0.28, 0.32, 0.38 },
            borderFocused = { 0.35, 0.55, 0.80 },
            text = { 0.85, 0.88, 0.92 },
            placeholder = { 0.45, 0.48, 0.52 },
            icon = { 0.50, 0.55, 0.62 },
            iconFocused = { 0.65, 0.75, 0.90 },
            clearBtn = { 0.50, 0.52, 0.55 },
            clearBtnHover = { 0.75, 0.78, 0.82 },
        },
        Dark = {
            bg = { 0.08, 0.10, 0.14 },
            bgFocused = { 0.10, 0.13, 0.18 },
            border = { 0.22, 0.25, 0.30 },
            borderFocused = { 0.30, 0.50, 0.75 },
            text = { 0.80, 0.83, 0.88 },
            placeholder = { 0.40, 0.43, 0.48 },
            icon = { 0.45, 0.50, 0.58 },
            iconFocused = { 0.60, 0.70, 0.85 },
            clearBtn = { 0.45, 0.48, 0.52 },
            clearBtnHover = { 0.70, 0.73, 0.78 },
        },
        Neon = {
            bg = { 0.04, 0.06, 0.10 },
            bgFocused = { 0.06, 0.10, 0.14 },
            border = { 0.0, 0.35, 0.28 },
            borderFocused = { 0.0, 0.80, 0.60 },
            text = { 0.0, 0.90, 0.70 },
            placeholder = { 0.0, 0.40, 0.30 },
            icon = { 0.0, 0.50, 0.40 },
            iconFocused = { 0.0, 0.90, 0.70 },
            clearBtn = { 0.0, 0.50, 0.40 },
            clearBtnHover = { 0.0, 0.90, 0.70 },
        },
        Velious = {
            bg = { 0.08, 0.12, 0.18 },
            bgFocused = { 0.10, 0.15, 0.24 },
            border = { 0.25, 0.38, 0.55 },
            borderFocused = { 0.40, 0.60, 0.90 },
            text = { 0.75, 0.88, 1.0 },
            placeholder = { 0.40, 0.50, 0.62 },
            icon = { 0.45, 0.58, 0.75 },
            iconFocused = { 0.60, 0.80, 1.0 },
            clearBtn = { 0.45, 0.55, 0.68 },
            clearBtnHover = { 0.70, 0.85, 1.0 },
        },
        Kunark = {
            bg = { 0.12, 0.08, 0.05 },
            bgFocused = { 0.16, 0.11, 0.07 },
            border = { 0.45, 0.32, 0.20 },
            borderFocused = { 0.70, 0.48, 0.28 },
            text = { 0.95, 0.82, 0.65 },
            placeholder = { 0.55, 0.42, 0.30 },
            icon = { 0.60, 0.45, 0.32 },
            iconFocused = { 0.85, 0.65, 0.45 },
            clearBtn = { 0.60, 0.45, 0.32 },
            clearBtnHover = { 0.90, 0.72, 0.52 },
        },
    }
    return colors[themeName] or colors.Classic
end

-- ============================================================
-- SEARCH INPUT
-- ============================================================

function M.draw(inputId, text, themeName, opts)
    opts = opts or {}

    local width = opts.width or 200
    local placeholder = opts.placeholder or 'Search...'
    local showIcon = opts.showIcon ~= false
    local showClear = opts.showClear ~= false
    local iconChar = opts.icon or '🔍'
    local clearChar = opts.clearIcon or '×'
    local rounding = opts.rounding or 4
    local height = opts.height or 24

    text = text or ''
    local colors = getSearchColors(themeName or 'Classic')

    -- Track focus state
    local inputIdClean = inputId:gsub('^##', '')
    local focusId = 'search_focus_' .. inputIdClean

    -- Get cursor position
    local startX, startY = imgui.GetCursorScreenPos()
    if type(startX) == 'table' then
        startY = startX.y or startX[2]
        startX = startX.x or startX[1]
    end

    local dl = imgui.GetWindowDrawList()

    -- Calculate layout
    local iconWidth = showIcon and 20 or 0
    local clearWidth = showClear and 18 or 0
    local inputWidth = width - iconWidth - clearWidth - 8

    -- Draw background
    local isFocused = imgui.IsItemActive and imgui.IsItemActive()
    local bgColor = isFocused and colors.bgFocused or colors.bg
    local borderColor = isFocused and colors.borderFocused or colors.border

    if dl then
        local bgCol = Draw.IM_COL32(
            math.floor(bgColor[1] * 255),
            math.floor(bgColor[2] * 255),
            math.floor(bgColor[3] * 255),
            240
        )
        Draw.addRectFilled(dl, startX, startY, startX + width, startY + height, bgCol, rounding)

        local borderCol = Draw.IM_COL32(
            math.floor(borderColor[1] * 255),
            math.floor(borderColor[2] * 255),
            math.floor(borderColor[3] * 255),
            200
        )
        Draw.addRect(dl, startX, startY, startX + width, startY + height, borderCol, rounding, 0, 1)
    end

    -- Search icon
    if showIcon and dl then
        local iconColor = isFocused and colors.iconFocused or colors.icon
        local iconCol = Draw.IM_COL32(
            math.floor(iconColor[1] * 255),
            math.floor(iconColor[2] * 255),
            math.floor(iconColor[3] * 255),
            200
        )
        local iconX = startX + 6
        local iconY = startY + (height - imgui.GetTextLineHeight()) / 2
        Draw.addText(dl, iconX, iconY, iconCol, iconChar)
    end

    -- Input field
    imgui.SetCursorScreenPos(startX + iconWidth + 4, startY + 2)

    -- Push input styling
    local stylesPushed = 0
    local colorsPushed = 0

    if imgui.PushStyleVar then
        pcall(function()
            imgui.PushStyleVar(ImGuiStyleVar.FramePadding, 2, 2)
            stylesPushed = stylesPushed + 1
        end)
        pcall(function()
            imgui.PushStyleVar(ImGuiStyleVar.FrameRounding, 0)
            stylesPushed = stylesPushed + 1
        end)
        pcall(function()
            imgui.PushStyleVar(ImGuiStyleVar.FrameBorderSize, 0)
            stylesPushed = stylesPushed + 1
        end)
    end

    if imgui.PushStyleColor then
        pcall(function()
            imgui.PushStyleColor(ImGuiCol.FrameBg, 0, 0, 0, 0)
            colorsPushed = colorsPushed + 1
        end)
        pcall(function()
            imgui.PushStyleColor(ImGuiCol.Text, colors.text[1], colors.text[2], colors.text[3], 1)
            colorsPushed = colorsPushed + 1
        end)
    end

    -- Set item width for input
    imgui.PushItemWidth(inputWidth)

    -- Input or placeholder
    local newText = text
    local changed = false

    if text == '' and not isFocused then
        -- Show placeholder
        if dl then
            local phCol = Draw.IM_COL32(
                math.floor(colors.placeholder[1] * 255),
                math.floor(colors.placeholder[2] * 255),
                math.floor(colors.placeholder[3] * 255),
                180
            )
            local phX = startX + iconWidth + 6
            local phY = startY + (height - imgui.GetTextLineHeight()) / 2
            Draw.addText(dl, phX, phY, phCol, placeholder)
        end

        -- Still need an input for focus
        local result = imgui.InputText(inputId, '', 256)
        if type(result) == 'string' and result ~= '' then
            newText = result
            changed = true
        end
    else
        local result = imgui.InputText(inputId, text, 256)
        if type(result) == 'string' then
            if result ~= text then
                newText = result
                changed = true
            end
        end
    end

    imgui.PopItemWidth()

    -- Update focus state
    isFocused = imgui.IsItemActive()

    -- Pop styling
    if stylesPushed > 0 then
        pcall(imgui.PopStyleVar, stylesPushed)
    end
    if colorsPushed > 0 then
        pcall(imgui.PopStyleColor, colorsPushed)
    end

    -- Clear button
    local cleared = false
    if showClear and text ~= '' then
        local clearX = startX + width - clearWidth - 4
        local clearY = startY + (height - 16) / 2

        imgui.SetCursorScreenPos(clearX, clearY)

        -- Invisible button for clear
        if imgui.InvisibleButton(inputId .. '_clear', 16, 16) then
            newText = ''
            changed = true
            cleared = true
        end

        local clearHovered = imgui.IsItemHovered()
        local clearColor = clearHovered and colors.clearBtnHover or colors.clearBtn

        if dl then
            local clearCol = Draw.IM_COL32(
                math.floor(clearColor[1] * 255),
                math.floor(clearColor[2] * 255),
                math.floor(clearColor[3] * 255),
                220
            )
            local cx = clearX + 8
            local cy = clearY + 8

            -- Draw X
            Draw.addLine(dl, cx - 4, cy - 4, cx + 4, cy + 4, clearCol, 1.5)
            Draw.addLine(dl, cx + 4, cy - 4, cx - 4, cy + 4, clearCol, 1.5)
        end
    end

    -- Reset cursor position
    imgui.SetCursorScreenPos(startX, startY + height + 4)
    imgui.Dummy(width, 0)

    return newText, changed, cleared
end

-- ============================================================
-- SEARCH WITH DROPDOWN SUGGESTIONS
-- ============================================================

function M.withSuggestions(inputId, text, suggestions, themeName, opts)
    opts = opts or {}
    local maxSuggestions = opts.maxSuggestions or 5

    -- Draw search input
    local newText, changed, cleared = M.draw(inputId, text, themeName, opts)

    -- Show suggestions dropdown
    local selectedSuggestion = nil
    if newText ~= '' and suggestions and #suggestions > 0 then
        local matches = {}

        -- Filter suggestions
        local searchLower = newText:lower()
        for _, suggestion in ipairs(suggestions) do
            local suggestionStr = tostring(suggestion)
            if suggestionStr:lower():find(searchLower, 1, true) then
                table.insert(matches, suggestion)
                if #matches >= maxSuggestions then break end
            end
        end

        -- Draw dropdown
        if #matches > 0 then
            local colors = getSearchColors(themeName or 'Classic')

            if imgui.BeginTooltip then
                imgui.BeginTooltip()

                for i, match in ipairs(matches) do
                    local matchStr = tostring(match)

                    if imgui.Selectable(matchStr, false) then
                        selectedSuggestion = match
                        newText = matchStr
                        changed = true
                    end
                end

                imgui.EndTooltip()
            end
        end
    end

    return newText, changed, selectedSuggestion
end

-- ============================================================
-- FILTER INPUT (with filter type selector)
-- ============================================================

function M.filter(inputId, text, filterType, filterTypes, themeName, opts)
    opts = opts or {}
    filterTypes = filterTypes or { 'All', 'Name', 'Level', 'Class' }

    local colors = getSearchColors(themeName or 'Classic')

    -- Filter type dropdown
    local typeWidth = opts.typeWidth or 60

    if imgui.PushStyleColor then
        pcall(function()
            imgui.PushStyleColor(ImGuiCol.FrameBg, colors.bg[1], colors.bg[2], colors.bg[3], 1)
        end)
    end

    imgui.PushItemWidth(typeWidth)
    local typeIdx = 1
    for i, ft in ipairs(filterTypes) do
        if ft == filterType then typeIdx = i break end
    end

    local newType = filterType
    if imgui.BeginCombo(inputId .. '_type', filterType or filterTypes[1]) then
        for i, ft in ipairs(filterTypes) do
            if imgui.Selectable(ft, i == typeIdx) then
                newType = ft
            end
        end
        imgui.EndCombo()
    end
    imgui.PopItemWidth()

    if imgui.PopStyleColor then
        pcall(imgui.PopStyleColor, 1)
    end

    imgui.SameLine(0, 4)

    -- Search input
    opts.width = (opts.width or 200) - typeWidth - 8
    local newText, changed, cleared = M.draw(inputId .. '_input', text, themeName, opts)

    return newText, newType, changed
end

-- ============================================================
-- COMPACT SEARCH (minimal styling)
-- ============================================================

function M.compact(inputId, text, themeName, opts)
    opts = opts or {}
    opts.height = opts.height or 20
    opts.showIcon = opts.showIcon == nil and true or opts.showIcon
    opts.showClear = opts.showClear == nil and true or opts.showClear
    opts.rounding = opts.rounding or 3

    return M.draw(inputId, text, themeName, opts)
end

-- ============================================================
-- INLINE SEARCH (no border, transparent bg)
-- ============================================================

function M.inline(inputId, text, themeName, opts)
    opts = opts or {}
    opts.showIcon = true
    opts.showClear = text and text ~= ''
    opts.rounding = 0

    local colors = getSearchColors(themeName or 'Classic')

    -- Override colors for inline style
    local origColors = getSearchColors
    getSearchColors = function()
        local c = origColors(themeName)
        c.bg = { 0, 0, 0 }
        c.bgFocused = { 0, 0, 0 }
        c.border = { 0, 0, 0 }
        c.borderFocused = { 0, 0, 0 }
        return c
    end

    local result, changed, cleared = M.draw(inputId, text, themeName, opts)

    getSearchColors = origColors

    return result, changed, cleared
end

return M
