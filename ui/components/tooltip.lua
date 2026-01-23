-- ============================================================
-- SideKick Rich Tooltip Component
-- ============================================================
-- Enhanced tooltips with headers, stats, bars, and sections.
--
-- Usage:
--   local Tooltip = require('sidekick-next.ui.components.tooltip')
--   if imgui.IsItemHovered() then
--       Tooltip.begin('Classic')
--       Tooltip.header('Ability Name')
--       Tooltip.stat('Duration', '30s')
--       Tooltip.stat('Reuse', '5m', { 0.8, 0.8, 0.3 })
--       Tooltip.bar('Cooldown', 45, 300, { 0.4, 0.8, 0.4 })
--       Tooltip.separator()
--       Tooltip.text('This ability does something cool.')
--       Tooltip.finish()
--   end

local imgui = require('ImGui')
local Draw = require('sidekick-next.ui.draw_helpers')
local Colors = require('sidekick-next.ui.colors')

local M = {}

-- Internal state
local _currentTheme = 'Classic'
local _labelWidth = 80

-- ============================================================
-- TOOLTIP LIFECYCLE
-- ============================================================

-- Begin a rich tooltip
function M.begin(themeName, opts)
    opts = opts or {}
    _currentTheme = themeName or 'Classic'
    _labelWidth = opts.labelWidth or 80

    imgui.BeginTooltip()

    -- Apply subtle styling
    if imgui.PushStyleVar then
        pcall(imgui.PushStyleVar, ImGuiStyleVar.ItemSpacing, 4, 2)
    end
end

-- End the tooltip
function M.finish()
    if imgui.PopStyleVar then
        pcall(imgui.PopStyleVar, 1)
    end
    imgui.EndTooltip()
end

-- ============================================================
-- CONTENT ELEMENTS
-- ============================================================

-- Header text (emphasized)
function M.header(text)
    if not text or text == '' then return end
    local textCol = Colors.text(_currentTheme)
    -- Slightly brighter for header
    imgui.TextColored(
        math.min(1, textCol[1] * 1.15),
        math.min(1, textCol[2] * 1.15),
        math.min(1, textCol[3] * 1.1),
        1,
        tostring(text)
    )
end

-- Subheader (dimmed)
function M.subheader(text)
    if not text or text == '' then return end
    local textCol = Colors.textDim(_currentTheme)
    imgui.TextColored(textCol[1], textCol[2], textCol[3], textCol[4] or 1, tostring(text))
end

-- Plain text
function M.text(text)
    if not text or text == '' then return end
    imgui.TextWrapped(tostring(text))
end

-- Colored text
function M.textColored(text, color)
    if not text or text == '' then return end
    color = color or Colors.text(_currentTheme)
    imgui.TextColored(color[1], color[2], color[3], color[4] or 1, tostring(text))
end

-- Separator line
function M.separator()
    imgui.Separator()
end

-- Spacing
function M.spacing(amount)
    amount = amount or 1
    for _ = 1, amount do
        imgui.Spacing()
    end
end

-- ============================================================
-- STAT DISPLAY
-- ============================================================

-- Label: Value stat line
function M.stat(label, value, valueColor)
    label = tostring(label or '')
    value = tostring(value or '')

    local textCol = Colors.text(_currentTheme)
    local dimCol = Colors.textDim(_currentTheme)

    -- Label (dimmed)
    imgui.TextColored(dimCol[1], dimCol[2], dimCol[3], 1, label .. ':')
    imgui.SameLine(_labelWidth)

    -- Value (colored or normal)
    if valueColor then
        imgui.TextColored(valueColor[1], valueColor[2], valueColor[3], valueColor[4] or 1, value)
    else
        imgui.TextColored(textCol[1], textCol[2], textCol[3], 1, value)
    end
end

-- Stat with icon prefix
function M.statWithIcon(icon, label, value, valueColor)
    icon = tostring(icon or '')
    label = tostring(label or '')
    value = tostring(value or '')

    local textCol = Colors.text(_currentTheme)
    local dimCol = Colors.textDim(_currentTheme)

    -- Icon + Label
    imgui.TextColored(dimCol[1], dimCol[2], dimCol[3], 1, icon .. ' ' .. label .. ':')
    imgui.SameLine(_labelWidth + 16)

    -- Value
    if valueColor then
        imgui.TextColored(valueColor[1], valueColor[2], valueColor[3], valueColor[4] or 1, value)
    else
        imgui.TextColored(textCol[1], textCol[2], textCol[3], 1, value)
    end
end

-- Ready/Not Ready status
function M.readyStatus(isReady, readyText, notReadyText)
    readyText = readyText or 'Ready'
    notReadyText = notReadyText or 'On Cooldown'

    if isReady then
        M.stat('Status', readyText, { 0.4, 1.0, 0.4 })
    else
        M.stat('Status', notReadyText, { 1.0, 0.5, 0.3 })
    end
end

-- ============================================================
-- PROGRESS BAR
-- ============================================================

-- Draw a progress bar with label
function M.bar(label, current, max, color, opts)
    opts = opts or {}
    local width = opts.width or 120
    local height = opts.height or 12
    local showText = opts.showText ~= false

    current = tonumber(current) or 0
    max = tonumber(max) or 1
    local pct = max > 0 and (current / max) or 0
    pct = math.max(0, math.min(1, pct))

    -- Default color based on percentage if not provided
    if not color then
        if pct > 0.66 then
            color = { 0.4, 0.8, 0.4 }
        elseif pct > 0.33 then
            color = { 0.9, 0.7, 0.3 }
        else
            color = { 0.9, 0.4, 0.4 }
        end
    end

    local dimCol = Colors.textDim(_currentTheme)

    -- Label
    if label and label ~= '' then
        imgui.TextColored(dimCol[1], dimCol[2], dimCol[3], 1, tostring(label))
    end

    -- Get cursor position for drawing
    local cx, cy = imgui.GetCursorScreenPos()
    if type(cx) == 'table' then
        cy = cx.y or cx[2]
        cx = cx.x or cx[1]
    end

    local dl = imgui.GetWindowDrawList()
    if dl then
        -- Background
        local bgCol = Draw.IM_COL32(40, 40, 40, 200)
        Draw.addRectFilled(dl, cx, cy, cx + width, cy + height, bgCol, 2)

        -- Fill
        if pct > 0 then
            local fillCol = Draw.IM_COL32(
                math.floor(color[1] * 255),
                math.floor(color[2] * 255),
                math.floor(color[3] * 255),
                220
            )
            Draw.addRectFilled(dl, cx, cy, cx + width * pct, cy + height, fillCol, 2)
        end

        -- Border
        local borderCol = Draw.IM_COL32(80, 80, 80, 150)
        Draw.addRect(dl, cx, cy, cx + width, cy + height, borderCol, 2, 0, 1)
    end

    -- Reserve space
    imgui.Dummy(width, height + 2)

    -- Text overlay
    if showText then
        imgui.SameLine(width + 8)
        local textCol = Colors.text(_currentTheme)
        imgui.TextColored(textCol[1], textCol[2], textCol[3], 1, string.format('%d%%', math.floor(pct * 100)))
    end
end

-- Cooldown bar (time-based)
function M.cooldownBar(remaining, total, opts)
    opts = opts or {}
    remaining = tonumber(remaining) or 0
    total = tonumber(total) or 0

    local pct = total > 0 and (remaining / total) or 0
    local color
    if pct > 0.66 then
        color = { 0.9, 0.4, 0.4 }  -- Red
    elseif pct > 0.33 then
        color = { 0.9, 0.7, 0.3 }  -- Orange
    elseif pct > 0.10 then
        color = { 0.9, 0.9, 0.4 }  -- Yellow
    else
        color = { 0.4, 0.9, 0.4 }  -- Green
    end

    opts.showText = false
    M.bar('Cooldown', remaining, total, color, opts)

    -- Show time remaining
    imgui.SameLine()
    local textCol = Colors.text(_currentTheme)
    local timeText
    if remaining <= 0 then
        timeText = 'Ready'
    elseif remaining >= 60 then
        timeText = string.format('%d:%02d', math.floor(remaining / 60), math.floor(remaining % 60))
    else
        timeText = string.format('%ds', math.floor(remaining))
    end
    imgui.TextColored(textCol[1], textCol[2], textCol[3], 1, timeText)
end

-- ============================================================
-- SECTIONS
-- ============================================================

-- Begin a section with header
function M.section(title)
    M.separator()
    M.spacing()
    if title and title ~= '' then
        M.subheader(title)
    end
end

-- Bullet point
function M.bullet(text)
    if not text or text == '' then return end
    local dimCol = Colors.textDim(_currentTheme)
    imgui.TextColored(dimCol[1], dimCol[2], dimCol[3], 1, '•')
    imgui.SameLine()
    imgui.TextWrapped(tostring(text))
end

-- ============================================================
-- CONVENIENCE FUNCTIONS
-- ============================================================

-- Simple tooltip (header + optional description)
function M.simple(header, description, themeName)
    M.begin(themeName)
    M.header(header)
    if description and description ~= '' then
        M.separator()
        M.text(description)
    end
    M.finish()
end

-- Ability tooltip (common pattern)
function M.ability(name, opts, themeName)
    opts = opts or {}
    M.begin(themeName)

    M.header(name)

    if opts.duration then
        M.stat('Duration', opts.duration)
    end
    if opts.reuse then
        M.stat('Reuse', opts.reuse)
    end
    if opts.remaining and opts.total then
        M.cooldownBar(opts.remaining, opts.total)
    elseif opts.isReady ~= nil then
        M.readyStatus(opts.isReady)
    end

    if opts.description and opts.description ~= '' then
        M.section()
        M.text(opts.description)
    end

    M.finish()
end

return M
