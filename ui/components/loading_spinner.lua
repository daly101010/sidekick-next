-- ============================================================
-- SideKick Loading Spinner Component
-- ============================================================
-- Animated loading indicators for async operations and
-- waiting states.
--
-- Usage:
--   local Spinner = require('sidekick-next.ui.components.loading_spinner')
--   Spinner.circular('Loading...', 'Classic')
--   Spinner.dots('Processing', 'Classic')
--   Spinner.bar(progress, total, 'Classic')
--   Spinner.pulse('Waiting', 'Classic')

local imgui = require('ImGui')
local Draw = require('sidekick-next.ui.draw_helpers')
local Colors = require('sidekick-next.ui.colors')

local M = {}

-- ============================================================
-- THEME COLORS
-- ============================================================

local function getSpinnerColor(themeName)
    local colors = {
        Classic = { 0.4, 0.7, 1.0 },
        Dark = { 0.5, 0.8, 1.0 },
        Neon = { 0.0, 1.0, 0.8 },
        Forest = { 0.4, 0.9, 0.5 },
        Velious = { 0.5, 0.8, 1.0 },
        Kunark = { 1.0, 0.6, 0.3 },
        Blood = { 0.9, 0.3, 0.3 },
        Royal = { 0.6, 0.4, 0.9 },
    }
    return colors[themeName] or colors.Classic
end

-- ============================================================
-- CIRCULAR SPINNER
-- ============================================================

function M.circular(label, themeName, opts)
    opts = opts or {}
    local radius = opts.radius or 10
    local thickness = opts.thickness or 2
    local speed = opts.speed or 2.0
    local segments = opts.segments or 8

    local color = opts.color or getSpinnerColor(themeName)

    -- Get cursor position
    local cx, cy = imgui.GetCursorScreenPos()
    if type(cx) == 'table' then
        cy = cx.y or cx[2]
        cx = cx.x or cx[1]
    end

    local dl = imgui.GetWindowDrawList()
    if not dl then
        imgui.Dummy(radius * 2 + (label and 60 or 0), radius * 2)
        return
    end

    -- Calculate center
    local centerX = cx + radius
    local centerY = cy + radius

    -- Animation time
    local t = os.clock() * speed

    -- Draw spinning arc segments
    local arcLength = 0.7  -- Portion of circle that's visible
    local startAngle = t * math.pi * 2

    for i = 0, segments - 1 do
        local segStart = startAngle + (i / segments) * arcLength * math.pi * 2
        local segEnd = startAngle + ((i + 0.6) / segments) * arcLength * math.pi * 2

        -- Fade segments toward tail
        local alpha = 1.0 - (i / segments) * 0.7

        local col = Draw.IM_COL32(
            math.floor(color[1] * 255),
            math.floor(color[2] * 255),
            math.floor(color[3] * 255),
            math.floor(alpha * 255)
        )

        -- Draw arc segment as lines
        local steps = 3
        for j = 0, steps - 1 do
            local a1 = segStart + (j / steps) * (segEnd - segStart)
            local a2 = segStart + ((j + 1) / steps) * (segEnd - segStart)

            local x1 = centerX + math.cos(a1) * radius
            local y1 = centerY + math.sin(a1) * radius
            local x2 = centerX + math.cos(a2) * radius
            local y2 = centerY + math.sin(a2) * radius

            Draw.addLine(dl, x1, y1, x2, y2, col, thickness)
        end
    end

    -- Reserve space for spinner
    local totalWidth = radius * 2
    if label and label ~= '' then
        totalWidth = totalWidth + 8 + imgui.CalcTextSize(label)
    end
    imgui.Dummy(totalWidth, radius * 2)

    -- Draw label
    if label and label ~= '' then
        local textCol = Colors.text(themeName)
        local labelX = cx + radius * 2 + 8
        local labelY = cy + radius - imgui.GetTextLineHeight() / 2
        Draw.addText(dl, labelX, labelY, Draw.IM_COL32(
            math.floor(textCol[1] * 255),
            math.floor(textCol[2] * 255),
            math.floor(textCol[3] * 255),
            255
        ), tostring(label))
    end
end

-- ============================================================
-- DOTS SPINNER
-- ============================================================

function M.dots(label, themeName, opts)
    opts = opts or {}
    local dotCount = opts.dotCount or 3
    local dotRadius = opts.dotRadius or 3
    local spacing = opts.spacing or 6
    local speed = opts.speed or 3.0

    local color = opts.color or getSpinnerColor(themeName)

    -- Get cursor position
    local cx, cy = imgui.GetCursorScreenPos()
    if type(cx) == 'table' then
        cy = cx.y or cx[2]
        cx = cx.x or cx[1]
    end

    local dl = imgui.GetWindowDrawList()
    if not dl then
        imgui.Dummy((dotRadius * 2 + spacing) * dotCount, dotRadius * 2)
        return
    end

    -- Animation time
    local t = os.clock() * speed

    -- Draw dots with bounce animation
    local totalWidth = 0
    for i = 0, dotCount - 1 do
        local phase = t - i * 0.3
        local bounce = math.max(0, math.sin(phase * math.pi))
        local scale = 1.0 + bounce * 0.5
        local alpha = 0.4 + bounce * 0.6

        local dotX = cx + i * (dotRadius * 2 + spacing) + dotRadius
        local dotY = cy + dotRadius - bounce * 4

        local col = Draw.IM_COL32(
            math.floor(color[1] * 255),
            math.floor(color[2] * 255),
            math.floor(color[3] * 255),
            math.floor(alpha * 255)
        )

        Draw.addCircleFilled(dl, dotX, dotY, dotRadius * scale, col, 12)
        totalWidth = dotX + dotRadius
    end

    -- Reserve space
    local height = dotRadius * 2 + 4
    imgui.Dummy(totalWidth - cx + (label and 60 or 0), height)

    -- Draw label
    if label and label ~= '' then
        local textCol = Colors.text(themeName)
        local labelX = totalWidth + 8
        local labelY = cy
        Draw.addText(dl, labelX, labelY, Draw.IM_COL32(
            math.floor(textCol[1] * 255),
            math.floor(textCol[2] * 255),
            math.floor(textCol[3] * 255),
            255
        ), tostring(label))
    end
end

-- ============================================================
-- PROGRESS BAR WITH ANIMATION
-- ============================================================

function M.bar(current, total, themeName, opts)
    opts = opts or {}
    local width = opts.width or 100
    local height = opts.height or 6
    local animated = opts.animated ~= false
    local showText = opts.showText == true
    local label = opts.label

    current = tonumber(current) or 0
    total = tonumber(total) or 1
    local pct = total > 0 and (current / total) or 0
    pct = math.max(0, math.min(1, pct))

    local color = opts.color or getSpinnerColor(themeName)

    -- Get cursor position
    local cx, cy = imgui.GetCursorScreenPos()
    if type(cx) == 'table' then
        cy = cx.y or cx[2]
        cx = cx.x or cx[1]
    end

    local dl = imgui.GetWindowDrawList()
    if not dl then
        imgui.Dummy(width, height)
        return
    end

    -- Background
    local bgCol = Draw.IM_COL32(40, 40, 40, 200)
    Draw.addRectFilled(dl, cx, cy, cx + width, cy + height, bgCol, 2)

    -- Fill
    local fillWidth = width * pct
    if fillWidth > 0 then
        local fillCol = Draw.IM_COL32(
            math.floor(color[1] * 255),
            math.floor(color[2] * 255),
            math.floor(color[3] * 255),
            230
        )
        Draw.addRectFilled(dl, cx, cy, cx + fillWidth, cy + height, fillCol, 2)

        -- Animated shine effect
        if animated and pct < 1 then
            local t = os.clock() * 2
            local shinePos = (t % 1) * (fillWidth + 40) - 20

            if shinePos > 0 and shinePos < fillWidth then
                local shineCol = Draw.IM_COL32(255, 255, 255, 60)
                local shineLeft = cx + math.max(0, shinePos - 10)
                local shineRight = cx + math.min(fillWidth, shinePos + 10)
                Draw.addRectFilled(dl, shineLeft, cy, shineRight, cy + height, shineCol, 2)
            end
        end
    end

    -- Border
    local borderCol = Draw.IM_COL32(80, 80, 80, 150)
    Draw.addRect(dl, cx, cy, cx + width, cy + height, borderCol, 2, 0, 1)

    imgui.Dummy(width, height)

    -- Text
    if showText or label then
        imgui.SameLine()
        local textCol = Colors.text(themeName)
        local text = label or string.format('%d%%', math.floor(pct * 100))
        imgui.TextColored(textCol[1], textCol[2], textCol[3], 1, text)
    end
end

-- ============================================================
-- PULSE INDICATOR
-- ============================================================

function M.pulse(label, themeName, opts)
    opts = opts or {}
    local radius = opts.radius or 6
    local speed = opts.speed or 2.0

    local color = opts.color or getSpinnerColor(themeName)

    -- Get cursor position
    local cx, cy = imgui.GetCursorScreenPos()
    if type(cx) == 'table' then
        cy = cx.y or cx[2]
        cx = cx.x or cx[1]
    end

    local dl = imgui.GetWindowDrawList()
    if not dl then
        imgui.Dummy(radius * 2 + (label and 60 or 0), radius * 2)
        return
    end

    -- Animation
    local t = os.clock() * speed
    local pulse = 0.5 + 0.5 * math.sin(t * math.pi)
    local scale = 1.0 + pulse * 0.3

    -- Center
    local centerX = cx + radius
    local centerY = cy + radius

    -- Outer ring (pulsing)
    local ringCol = Draw.IM_COL32(
        math.floor(color[1] * 255),
        math.floor(color[2] * 255),
        math.floor(color[3] * 255),
        math.floor((1 - pulse) * 150)
    )
    Draw.addCircle(dl, centerX, centerY, radius * scale, ringCol, 16, 2)

    -- Inner dot
    local dotCol = Draw.IM_COL32(
        math.floor(color[1] * 255),
        math.floor(color[2] * 255),
        math.floor(color[3] * 255),
        220
    )
    Draw.addCircleFilled(dl, centerX, centerY, radius * 0.5, dotCol, 12)

    -- Reserve space
    local totalWidth = radius * 2
    if label and label ~= '' then
        totalWidth = totalWidth + 8 + imgui.CalcTextSize(label)
    end
    imgui.Dummy(totalWidth, radius * 2)

    -- Label
    if label and label ~= '' then
        local textCol = Colors.text(themeName)
        local labelX = cx + radius * 2 + 8
        local labelY = cy + radius - imgui.GetTextLineHeight() / 2
        Draw.addText(dl, labelX, labelY, Draw.IM_COL32(
            math.floor(textCol[1] * 255),
            math.floor(textCol[2] * 255),
            math.floor(textCol[3] * 255),
            255
        ), tostring(label))
    end
end

-- ============================================================
-- INDETERMINATE BAR (back and forth)
-- ============================================================

function M.indeterminate(label, themeName, opts)
    opts = opts or {}
    local width = opts.width or 100
    local height = opts.height or 4
    local speed = opts.speed or 1.5

    local color = opts.color or getSpinnerColor(themeName)

    -- Get cursor position
    local cx, cy = imgui.GetCursorScreenPos()
    if type(cx) == 'table' then
        cy = cx.y or cx[2]
        cx = cx.x or cx[1]
    end

    local dl = imgui.GetWindowDrawList()
    if not dl then
        imgui.Dummy(width, height)
        return
    end

    -- Background
    local bgCol = Draw.IM_COL32(40, 40, 40, 200)
    Draw.addRectFilled(dl, cx, cy, cx + width, cy + height, bgCol, 2)

    -- Animated segment
    local t = os.clock() * speed
    local pos = 0.5 + 0.5 * math.sin(t * math.pi)
    local segWidth = width * 0.3

    local segLeft = cx + pos * (width - segWidth)
    local segRight = segLeft + segWidth

    local fillCol = Draw.IM_COL32(
        math.floor(color[1] * 255),
        math.floor(color[2] * 255),
        math.floor(color[3] * 255),
        230
    )
    Draw.addRectFilled(dl, segLeft, cy, segRight, cy + height, fillCol, 2)

    -- Border
    local borderCol = Draw.IM_COL32(80, 80, 80, 150)
    Draw.addRect(dl, cx, cy, cx + width, cy + height, borderCol, 2, 0, 1)

    imgui.Dummy(width, height)

    -- Label
    if label and label ~= '' then
        imgui.SameLine()
        local textCol = Colors.text(themeName)
        imgui.TextColored(textCol[1], textCol[2], textCol[3], 1, label)
    end
end

-- ============================================================
-- MINIMAL SPINNER (very small)
-- ============================================================

function M.mini(themeName, opts)
    opts = opts or {}
    opts.radius = opts.radius or 5
    opts.thickness = opts.thickness or 1.5
    M.circular(nil, themeName, opts)
end

-- ============================================================
-- INLINE SPINNER (draws next to content)
-- ============================================================

function M.inline(themeName, opts)
    imgui.SameLine()
    M.mini(themeName, opts)
end

return M
