-- ============================================================
-- SideKick Settings - Special Bar Tab
-- ============================================================
-- Special abilities bar layout settings.

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

    -- Enable special bar
    local specEnabled = settings.SideKickSpecialEnabled ~= false
    specEnabled, changed = Settings.labeledCheckbox('Show special abilities', specEnabled)
    if changed and onChange then onChange('SideKickSpecialEnabled', specEnabled) end

    imgui.Separator()
    imgui.Text('Layout')

    local forceSingleRow = settings.SideKickSpecialForceSingleRow == true
    forceSingleRow, changed = Settings.labeledCheckbox('Force single row', forceSingleRow)
    if changed and onChange then onChange('SideKickSpecialForceSingleRow', forceSingleRow) end

    local forceSingleColumn = settings.SideKickSpecialForceSingleColumn == true
    forceSingleColumn, changed = Settings.labeledCheckbox('Force single column', forceSingleColumn)
    if changed and onChange then onChange('SideKickSpecialForceSingleColumn', forceSingleColumn) end

    local perButtonMove = settings.SideKickSpecialPerButtonMove == true
    perButtonMove, changed = Settings.labeledCheckbox('Enable per-button move', perButtonMove)
    if changed and onChange then onChange('SideKickSpecialPerButtonMove', perButtonMove) end
    if perButtonMove then
        imgui.SameLine()
        imgui.TextDisabled('(drag to reposition; disables activation while enabled)')
    end

    -- Cell size
    local specCell = tonumber(settings.SideKickSpecialCell) or C.LAYOUT.SPECIAL_CELL_SIZE
    specCell, changed = Settings.labeledSliderInt('Cell Size', specCell, C.LAYOUT.MIN_CELL_SIZE, C.LAYOUT.MAX_CELL_SIZE)
    if changed and onChange then onChange('SideKickSpecialCell', specCell) end

    -- Rows
    local specRows = tonumber(settings.SideKickSpecialRows) or C.LAYOUT.SPECIAL_ROWS
    specRows, changed = Settings.labeledSliderInt('Rows', specRows, 1, C.LAYOUT.MAX_ROWS)
    if changed and onChange then onChange('SideKickSpecialRows', specRows) end
    if forceSingleRow or forceSingleColumn then
        imgui.SameLine()
        imgui.TextDisabled('(forced to 1)')
    end

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

    -- Width override (0 = auto)
    local widthOverride = tonumber(settings.SideKickSpecialWidth) or 0
    widthOverride, changed = Settings.labeledSliderInt('Width Override', widthOverride, 0, 1200)
    if changed and onChange then onChange('SideKickSpecialWidth', widthOverride) end
    imgui.SameLine()
    imgui.TextDisabled('(0 = auto)')

    -- Show gold frame border (background texture still shows when disabled)
    local showBorder = settings.SideKickSpecialShowBorder ~= false
    showBorder, changed = Settings.labeledCheckbox('Show Gold Border', showBorder)
    if changed and onChange then onChange('SideKickSpecialShowBorder', showBorder) end

    -- Texture tint
    local tintStr = settings.SideKickSpecialTextureTint or '1.0,1.0,1.0'
    local tintColor = parseTintColor(tintStr)
    local newTint, tintChanged = imgui.ColorEdit3('Texture Tint##special', tintColor)
    if tintChanged and onChange then onChange('SideKickSpecialTextureTint', formatTintColor(newTint)) end
    imgui.SameLine()
    if imgui.SmallButton('Reset##special_tint') then
        if onChange then onChange('SideKickSpecialTextureTint', '1.0,1.0,1.0') end
    end

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
