-- ============================================================
-- SideKick Anchor Visualizer Component
-- ============================================================
-- Draws visual overlay showing anchor relationships between windows
-- when settings are open.
--
-- Usage:
--   local AnchorViz = require('sidekick-next.ui.components.anchor_visualizer')
--   AnchorViz.draw(settings, windowBounds)

local imgui = require('ImGui')
local C = require('sidekick-next.ui.constants')
local Draw = require('sidekick-next.ui.draw_helpers')
local Colors = require('sidekick-next.ui.colors')

local M = {}

-- ============================================================
-- ANCHOR VISUALIZATION
-- ============================================================

-- Get window bounds from global exports
local function getWindowBounds(targetKey)
    local bounds = nil

    if targetKey == 'grouptarget' then
        bounds = _G.GroupTargetBounds
    elseif targetKey == 'sidekick_main' then
        bounds = _G.SideKickMainBounds
    elseif targetKey == 'sidekick_bar' then
        bounds = _G.SideKickBarBounds
    elseif targetKey == 'sidekick_special' then
        bounds = _G.SideKickSpecialBounds
    elseif targetKey == 'sidekick_disc' then
        bounds = _G.SideKickDiscBounds
    elseif targetKey == 'sidekick_items' then
        bounds = _G.SideKickItemBounds
    end

    if bounds and bounds.loaded then
        return bounds
    end
    return nil
end

-- Calculate anchor connection points
local function getAnchorPoints(sourceBounds, targetBounds, anchorMode)
    if not sourceBounds or not targetBounds then return nil, nil end

    local sx, sy, sw, sh = sourceBounds.x, sourceBounds.y, sourceBounds.width, sourceBounds.height
    local tx, ty, tw, th = targetBounds.x, targetBounds.y, targetBounds.width, targetBounds.height

    -- Calculate center points
    local scx, scy = sx + sw / 2, sy + sh / 2
    local tcx, tcy = tx + tw / 2, ty + th / 2

    -- Calculate edge midpoints based on anchor mode
    local sourcePoint, targetPoint

    if anchorMode == 'left' then
        sourcePoint = { x = sx, y = scy }
        targetPoint = { x = tx + tw, y = tcy }
    elseif anchorMode == 'right' then
        sourcePoint = { x = sx + sw, y = scy }
        targetPoint = { x = tx, y = tcy }
    elseif anchorMode == 'above' then
        sourcePoint = { x = scx, y = sy }
        targetPoint = { x = tcx, y = ty + th }
    elseif anchorMode == 'below' then
        sourcePoint = { x = scx, y = sy + sh }
        targetPoint = { x = tcx, y = ty }
    elseif anchorMode == 'left_bottom' then
        sourcePoint = { x = sx, y = sy + sh }
        targetPoint = { x = tx + tw, y = ty + th }
    elseif anchorMode == 'right_bottom' then
        sourcePoint = { x = sx + sw, y = sy + sh }
        targetPoint = { x = tx, y = ty + th }
    else
        -- No anchor - use centers
        sourcePoint = { x = scx, y = scy }
        targetPoint = { x = tcx, y = tcy }
    end

    return sourcePoint, targetPoint
end

-- Draw a single anchor connection
local function drawAnchorLine(dl, sourceBounds, targetBounds, anchorMode, color, label)
    if anchorMode == 'none' then return end

    local sourcePoint, targetPoint = getAnchorPoints(sourceBounds, targetBounds, anchorMode)
    if not sourcePoint or not targetPoint then return end

    -- Draw dashed line
    Draw.addDashedLine(
        dl,
        sourcePoint.x, sourcePoint.y,
        targetPoint.x, targetPoint.y,
        color,
        2,  -- thickness
        8,  -- dash length
        4   -- gap length
    )

    -- Draw connection points
    Draw.addCircleFilled(dl, sourcePoint.x, sourcePoint.y, 4, color)
    Draw.addCircleFilled(dl, targetPoint.x, targetPoint.y, 4, color)

    -- Draw label at midpoint
    if label then
        local midX = (sourcePoint.x + targetPoint.x) / 2
        local midY = (sourcePoint.y + targetPoint.y) / 2
        Draw.addText(dl, midX - 20, midY - 10, color, label)
    end
end

-- ============================================================
-- MAIN DRAW FUNCTION
-- ============================================================

function M.draw(settings, themeName)
    if not settings then return end

    -- Get draw list
    local dl = imgui.GetForegroundDrawList and imgui.GetForegroundDrawList()
    if not dl then return end

    -- Define anchor relationships to visualize
    local anchors = {
        {
            source = 'sidekick_bar',
            targetKey = 'SideKickBarAnchorTarget',
            modeKey = 'SideKickBarAnchor',
            label = 'Bar',
            color = Draw.IM_COL32(100, 200, 255, 180),
        },
        {
            source = 'sidekick_special',
            targetKey = 'SideKickSpecialAnchorTarget',
            modeKey = 'SideKickSpecialAnchor',
            label = 'Special',
            color = Draw.IM_COL32(255, 180, 100, 180),
        },
        {
            source = 'sidekick_disc',
            targetKey = 'SideKickDiscBarAnchorTarget',
            modeKey = 'SideKickDiscBarAnchor',
            label = 'Disc',
            color = Draw.IM_COL32(100, 255, 150, 180),
        },
        {
            source = 'sidekick_items',
            targetKey = 'SideKickItemBarAnchorTarget',
            modeKey = 'SideKickItemBarAnchor',
            label = 'Items',
            color = Draw.IM_COL32(255, 100, 200, 180),
        },
    }

    -- Draw each anchor relationship
    for _, anchor in ipairs(anchors) do
        local targetKey = settings[anchor.targetKey] or 'grouptarget'
        local anchorMode = settings[anchor.modeKey] or 'none'

        if anchorMode ~= 'none' then
            local sourceBounds = getWindowBounds(anchor.source)
            local targetBounds = getWindowBounds(targetKey)

            if sourceBounds and targetBounds then
                drawAnchorLine(dl, sourceBounds, targetBounds, anchorMode, anchor.color, anchor.label)
            end
        end
    end
end

-- ============================================================
-- HIGHLIGHT SPECIFIC ANCHOR
-- ============================================================

function M.highlight(sourceKey, targetKey, anchorMode, settings)
    if anchorMode == 'none' then return end

    local dl = imgui.GetForegroundDrawList and imgui.GetForegroundDrawList()
    if not dl then return end

    local sourceBounds = getWindowBounds(sourceKey)
    local targetBounds = getWindowBounds(targetKey)

    if sourceBounds and targetBounds then
        -- Highlight color (bright yellow)
        local highlightColor = Draw.IM_COL32(255, 255, 100, 220)

        -- Draw highlighted line
        drawAnchorLine(dl, sourceBounds, targetBounds, anchorMode, highlightColor)

        -- Draw bounding boxes
        Draw.addRect(dl, sourceBounds.x - 2, sourceBounds.y - 2,
            sourceBounds.x + sourceBounds.width + 2, sourceBounds.y + sourceBounds.height + 2,
            highlightColor, 0, 0, 2)

        Draw.addRect(dl, targetBounds.x - 2, targetBounds.y - 2,
            targetBounds.x + targetBounds.width + 2, targetBounds.y + targetBounds.height + 2,
            highlightColor, 0, 0, 2)
    end
end

-- ============================================================
-- PREVIEW ANCHOR POSITION
-- ============================================================

function M.previewPosition(targetKey, anchorMode, gap, width, height)
    local targetBounds = getWindowBounds(targetKey)
    if not targetBounds then return nil end

    local x, y = targetBounds.x, targetBounds.y
    local tw, th = targetBounds.width, targetBounds.height

    if anchorMode == 'left' then
        x = targetBounds.x - width - gap
        y = targetBounds.y
    elseif anchorMode == 'right' then
        x = targetBounds.x + tw + gap
        y = targetBounds.y
    elseif anchorMode == 'above' then
        x = targetBounds.x
        y = targetBounds.y - height - gap
    elseif anchorMode == 'below' then
        x = targetBounds.x
        y = targetBounds.y + th + gap
    elseif anchorMode == 'left_bottom' then
        x = targetBounds.x - width - gap
        y = targetBounds.y + th - height
    elseif anchorMode == 'right_bottom' then
        x = targetBounds.x + tw + gap
        y = targetBounds.y + th - height
    end

    return { x = x, y = y, width = width, height = height }
end

return M
