-- ============================================================
-- SideKick Settings - Ability Bar Tab
-- ============================================================
-- Main ability bar layout settings.

local imgui = require('ImGui')
local C = require('sidekick-next.ui.constants')
local Settings = require('sidekick-next.ui.settings')

local M = {}

function M.draw(settings, themeNames, onChange)
    local changed

    -- Enable bar
    local barEnabled = settings.SideKickBarEnabled ~= false
    barEnabled, changed = Settings.labeledCheckbox('Show ability bar', barEnabled)
    if changed and onChange then onChange('SideKickBarEnabled', barEnabled) end

    imgui.Separator()
    imgui.Text('Layout')

    -- Cell size
    local cell = tonumber(settings.SideKickBarCell) or 48
    cell, changed = Settings.labeledSliderInt('Cell Size', cell, C.LAYOUT.MIN_CELL_SIZE, C.LAYOUT.MAX_CELL_SIZE)
    if changed and onChange then onChange('SideKickBarCell', cell) end

    -- Rows
    local rows = tonumber(settings.SideKickBarRows) or 2
    rows, changed = Settings.labeledSliderInt('Rows', rows, 1, C.LAYOUT.MAX_ROWS)
    if changed and onChange then onChange('SideKickBarRows', rows) end

    -- Gap
    local gap = tonumber(settings.SideKickBarGap) or 4
    gap, changed = Settings.labeledSliderInt('Gap', gap, 0, 12)
    if changed and onChange then onChange('SideKickBarGap', gap) end

    -- Padding
    local pad = tonumber(settings.SideKickBarPad) or 6
    pad, changed = Settings.labeledSliderInt('Padding', pad, 0, 24)
    if changed and onChange then onChange('SideKickBarPad', pad) end

    -- Background alpha
    local alpha = tonumber(settings.SideKickBarBgAlpha) or 0.85
    alpha, changed = Settings.labeledSliderFloat('Background Alpha', alpha, 0.2, 1.0)
    if changed and onChange then onChange('SideKickBarBgAlpha', alpha) end

    imgui.Separator()
    imgui.Text('Anchoring')

    -- Anchor target
    local target = Settings.labeledComboKeyed('Anchor To', settings.SideKickBarAnchorTarget or 'grouptarget', C.ANCHOR_TARGETS)
    if target ~= tostring(settings.SideKickBarAnchorTarget or 'grouptarget') and onChange then
        onChange('SideKickBarAnchorTarget', target)
    end

    -- Anchor mode
    local anchor = tostring(settings.SideKickBarAnchor or 'none')
    anchor = Settings.labeledCombo('Anchor Mode', anchor, C.ANCHOR_MODES)
    if anchor ~= tostring(settings.SideKickBarAnchor or 'none') and onChange then
        onChange('SideKickBarAnchor', anchor)
    end

    -- Anchor gap
    local anchorGap = tonumber(settings.SideKickBarAnchorGap) or 2
    anchorGap, changed = Settings.labeledSliderInt('Anchor Gap', anchorGap, 0, C.LAYOUT.MAX_ANCHOR_GAP)
    if changed and onChange then onChange('SideKickBarAnchorGap', anchorGap) end
end

return M
