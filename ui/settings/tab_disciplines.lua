-- ============================================================
-- SideKick Settings - Disciplines Bar Tab
-- ============================================================
-- Disciplines bar layout settings (Berserker only).

local imgui = require('ImGui')
local C = require('sidekick-next.ui.constants')
local Settings = require('sidekick-next.ui.settings')

local M = {}

-- Texture tint parse/format helpers
local function parseTintColor(str)
    if not str or str == '' then return { 1.0, 1.0, 1.0 } end
    local r, g, b = str:match('^%s*([%d%.]+)%s*,%s*([%d%.]+)%s*,%s*([%d%.]+)%s*$')
    r, g, b = tonumber(r), tonumber(g), tonumber(b)
    if not (r and g and b) then return { 1.0, 1.0, 1.0 } end
    return { math.max(0, math.min(1, r)), math.max(0, math.min(1, g)), math.max(0, math.min(1, b)) }
end

local function formatTintColor(col)
    if not col or #col < 3 then return '1.0,1.0,1.0' end
    return string.format('%.2f,%.2f,%.2f', col[1] or 1, col[2] or 1, col[3] or 1)
end

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

    -- Width override (0 = auto)
    local widthOverride = tonumber(settings.SideKickDiscBarWidth) or 0
    widthOverride, changed = Settings.labeledSliderInt('Width Override', widthOverride, 0, 1200)
    if changed and onChange then onChange('SideKickDiscBarWidth', widthOverride) end
    imgui.SameLine()
    imgui.TextDisabled('(0 = auto)')

    -- Show gold frame border (background texture still shows when disabled)
    local showBorder = settings.SideKickDiscBarShowBorder ~= false
    showBorder, changed = Settings.labeledCheckbox('Show Gold Border', showBorder)
    if changed and onChange then onChange('SideKickDiscBarShowBorder', showBorder) end

    -- Texture tint
    local tintStr = settings.SideKickDiscBarTextureTint or '1.0,1.0,1.0'
    local tintColor = parseTintColor(tintStr)
    local newTint, tintChanged = imgui.ColorEdit3('Texture Tint##disc', tintColor)
    if tintChanged and onChange then onChange('SideKickDiscBarTextureTint', formatTintColor(newTint)) end
    imgui.SameLine()
    if imgui.SmallButton('Reset##disc_tint') then
        if onChange then onChange('SideKickDiscBarTextureTint', '1.0,1.0,1.0') end
    end

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
