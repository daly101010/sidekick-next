-- ============================================================
-- SideKick Settings - Disciplines Bar Tab
-- ============================================================
-- Disciplines bar layout settings (Berserker only).

local imgui = require('ImGui')
local C = require('sidekick-next.ui.constants')
local Settings = require('sidekick-next.ui.settings')

local M = {}

function M.draw(settings, themeNames, onChange)
    local changed

    -- Enable disc bar (defaults to true for Berserkers)
    local discBar = settings.SideKickDiscBarEnabled ~= false
    discBar, changed = Settings.labeledCheckbox('Show disciplines bar', discBar)
    if changed and onChange then onChange('SideKickDiscBarEnabled', discBar) end

    imgui.Separator()
    imgui.Text('Layout')

    -- Cell size
    local discCell = tonumber(settings.SideKickDiscBarCell) or 48
    discCell, changed = Settings.labeledSliderInt('Cell Size', discCell, C.LAYOUT.MIN_CELL_SIZE, C.LAYOUT.MAX_CELL_SIZE)
    if changed and onChange then onChange('SideKickDiscBarCell', discCell) end

    -- Rows
    local discRows = tonumber(settings.SideKickDiscBarRows) or 2
    discRows, changed = Settings.labeledSliderInt('Rows', discRows, 1, C.LAYOUT.MAX_ROWS)
    if changed and onChange then onChange('SideKickDiscBarRows', discRows) end

    -- Gap
    local discGap = tonumber(settings.SideKickDiscBarGap) or 4
    discGap, changed = Settings.labeledSliderInt('Gap', discGap, 0, 12)
    if changed and onChange then onChange('SideKickDiscBarGap', discGap) end

    -- Padding
    local discPad = tonumber(settings.SideKickDiscBarPad) or 6
    discPad, changed = Settings.labeledSliderInt('Padding', discPad, 0, 24)
    if changed and onChange then onChange('SideKickDiscBarPad', discPad) end

    -- Background alpha
    local discAlpha = tonumber(settings.SideKickDiscBarBgAlpha) or 0.85
    discAlpha, changed = Settings.labeledSliderFloat('Background Alpha', discAlpha, 0.2, 1.0)
    if changed and onChange then onChange('SideKickDiscBarBgAlpha', discAlpha) end

    imgui.Separator()
    imgui.Text('Anchoring')

    -- Anchor target
    local target = Settings.labeledComboKeyed('Anchor To', settings.SideKickDiscBarAnchorTarget or 'grouptarget', C.ANCHOR_TARGETS)
    if target ~= tostring(settings.SideKickDiscBarAnchorTarget or 'grouptarget') and onChange then
        onChange('SideKickDiscBarAnchorTarget', target)
    end

    -- Anchor mode
    local discAnchor = tostring(settings.SideKickDiscBarAnchor or 'none')
    discAnchor = Settings.labeledCombo('Anchor Mode', discAnchor, C.ANCHOR_MODES)
    if discAnchor ~= tostring(settings.SideKickDiscBarAnchor or 'none') and onChange then
        onChange('SideKickDiscBarAnchor', discAnchor)
    end

    -- Anchor gap
    local discAnchorGap = tonumber(settings.SideKickDiscBarAnchorGap) or 2
    discAnchorGap, changed = Settings.labeledSliderInt('Anchor Gap', discAnchorGap, 0, C.LAYOUT.MAX_ANCHOR_GAP)
    if changed and onChange then onChange('SideKickDiscBarAnchorGap', discAnchorGap) end
end

return M
