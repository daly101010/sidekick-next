-- ============================================================
-- SideKick Settings - Disciplines Bar Tab
-- ============================================================
-- Disciplines bar layout settings (for BER and other disc classes).

local imgui = require('ImGui')
local C = require('sidekick-next.ui.constants')
local Settings = require('sidekick-next.ui.settings')

local M = {}

function M.draw(settings, themeNames, onChange)
    local changed

    -- Enable disc bar
    local discBar = settings.SideKickDiscBarEnabled ~= false
    discBar, changed = imgui.Checkbox('Show disciplines bar (BER)', discBar)
    if changed and onChange then onChange('SideKickDiscBarEnabled', discBar) end

    imgui.Separator()
    imgui.Text('Layout')

    -- Cell size
    local discCell = tonumber(settings.SideKickDiscBarCell) or 48
    discCell, changed = imgui.SliderInt('Cell Size', discCell, C.LAYOUT.MIN_CELL_SIZE, C.LAYOUT.MAX_CELL_SIZE)
    if changed and onChange then onChange('SideKickDiscBarCell', discCell) end

    -- Rows
    local discRows = tonumber(settings.SideKickDiscBarRows) or 2
    discRows, changed = imgui.SliderInt('Rows', discRows, 1, C.LAYOUT.MAX_ROWS)
    if changed and onChange then onChange('SideKickDiscBarRows', discRows) end

    -- Gap
    local discGap = tonumber(settings.SideKickDiscBarGap) or 4
    discGap, changed = imgui.SliderInt('Gap', discGap, 0, 12)
    if changed and onChange then onChange('SideKickDiscBarGap', discGap) end

    -- Padding
    local discPad = tonumber(settings.SideKickDiscBarPad) or 6
    discPad, changed = imgui.SliderInt('Padding', discPad, 0, 24)
    if changed and onChange then onChange('SideKickDiscBarPad', discPad) end

    -- Background alpha
    local discAlpha = tonumber(settings.SideKickDiscBarBgAlpha) or 0.85
    discAlpha, changed = imgui.SliderFloat('Background Alpha', discAlpha, 0.2, 1.0)
    if changed and onChange then onChange('SideKickDiscBarBgAlpha', discAlpha) end

    imgui.Separator()
    imgui.Text('Anchoring')

    -- Anchor target
    local target = Settings.comboKeyed('Anchor To', settings.SideKickDiscBarAnchorTarget or 'grouptarget', C.ANCHOR_TARGETS)
    if target ~= tostring(settings.SideKickDiscBarAnchorTarget or 'grouptarget') and onChange then
        onChange('SideKickDiscBarAnchorTarget', target)
    end

    -- Anchor mode
    local discAnchor = tostring(settings.SideKickDiscBarAnchor or 'none')
    discAnchor = Settings.comboString('Anchor Mode', discAnchor, C.ANCHOR_MODES)
    if discAnchor ~= tostring(settings.SideKickDiscBarAnchor or 'none') and onChange then
        onChange('SideKickDiscBarAnchor', discAnchor)
    end

    -- Anchor gap
    local discAnchorGap = tonumber(settings.SideKickDiscBarAnchorGap) or 2
    discAnchorGap, changed = imgui.SliderInt('Anchor Gap', discAnchorGap, 0, C.LAYOUT.MAX_ANCHOR_GAP)
    if changed and onChange then onChange('SideKickDiscBarAnchorGap', discAnchorGap) end
end

return M
