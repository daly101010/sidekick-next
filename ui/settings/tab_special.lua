-- ============================================================
-- SideKick Settings - Special Bar Tab
-- ============================================================
-- Special abilities bar layout settings.

local imgui = require('ImGui')
local C = require('sidekick-next.ui.constants')
local Settings = require('sidekick-next.ui.settings')

local M = {}

function M.draw(settings, themeNames, onChange)
    local changed

    -- Enable special bar
    local specEnabled = settings.SideKickSpecialEnabled ~= false
    specEnabled, changed = Settings.labeledCheckbox('Show special abilities', specEnabled)
    if changed and onChange then onChange('SideKickSpecialEnabled', specEnabled) end

    imgui.Separator()
    imgui.Text('Layout')

    -- Cell size
    local specCell = tonumber(settings.SideKickSpecialCell) or C.LAYOUT.SPECIAL_CELL_SIZE
    specCell, changed = Settings.labeledSliderInt('Cell Size', specCell, C.LAYOUT.MIN_CELL_SIZE, C.LAYOUT.MAX_CELL_SIZE)
    if changed and onChange then onChange('SideKickSpecialCell', specCell) end

    -- Rows
    local specRows = tonumber(settings.SideKickSpecialRows) or C.LAYOUT.SPECIAL_ROWS
    specRows, changed = Settings.labeledSliderInt('Rows', specRows, 1, C.LAYOUT.MAX_ROWS)
    if changed and onChange then onChange('SideKickSpecialRows', specRows) end

    -- Gap
    local specGap = tonumber(settings.SideKickSpecialGap) or 4
    specGap, changed = Settings.labeledSliderInt('Gap', specGap, 0, 12)
    if changed and onChange then onChange('SideKickSpecialGap', specGap) end

    -- Padding
    local specPad = tonumber(settings.SideKickSpecialPad) or 6
    specPad, changed = Settings.labeledSliderInt('Padding', specPad, 0, 24)
    if changed and onChange then onChange('SideKickSpecialPad', specPad) end

    -- Background alpha
    local specAlpha = tonumber(settings.SideKickSpecialBgAlpha) or 0.85
    specAlpha, changed = Settings.labeledSliderFloat('Background Alpha', specAlpha, 0.2, 1.0)
    if changed and onChange then onChange('SideKickSpecialBgAlpha', specAlpha) end

    imgui.Separator()
    imgui.Text('Anchoring')

    -- Anchor target
    local target = Settings.labeledComboKeyed('Anchor To', settings.SideKickSpecialAnchorTarget or 'grouptarget', C.ANCHOR_TARGETS)
    if target ~= tostring(settings.SideKickSpecialAnchorTarget or 'grouptarget') and onChange then
        onChange('SideKickSpecialAnchorTarget', target)
    end

    -- Anchor mode
    local specAnchor = tostring(settings.SideKickSpecialAnchor or 'none')
    specAnchor = Settings.labeledCombo('Anchor Mode', specAnchor, C.ANCHOR_MODES)
    if specAnchor ~= tostring(settings.SideKickSpecialAnchor or 'none') and onChange then
        onChange('SideKickSpecialAnchor', specAnchor)
    end

    -- Anchor gap
    local specAnchorGap = tonumber(settings.SideKickSpecialAnchorGap) or 2
    specAnchorGap, changed = Settings.labeledSliderInt('Anchor Gap', specAnchorGap, 0, C.LAYOUT.MAX_ANCHOR_GAP)
    if changed and onChange then onChange('SideKickSpecialAnchorGap', specAnchorGap) end
end

return M
