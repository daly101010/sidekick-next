-- ============================================================
-- SideKick Settings - UI Tab
-- ============================================================
-- Theme, sync, and docking settings.

local imgui = require('ImGui')
local C = require('sidekick-next.ui.constants')
local Settings = require('sidekick-next.ui.settings')

local M = {}

function M.draw(settings, themeNames, onChange)
    local changed

    -- Theme selection
    local theme = Settings.comboString('Theme', settings.SideKickTheme or 'Classic', themeNames)
    if theme ~= (settings.SideKickTheme or 'Classic') and onChange then
        onChange('SideKickTheme', theme)
    end

    -- Sync with GroupTarget
    local sync = settings.SideKickSyncThemeWithGT == true
    sync, changed = imgui.Checkbox('Sync theme with GroupTarget', sync)
    if changed and onChange then
        onChange('SideKickSyncThemeWithGT', sync)
    end
    if imgui.IsItemHovered() then
        Settings.safeTooltip('Automatically match GroupTarget theme')
    end

    imgui.Separator()
    imgui.Text('Main Window Docking')

    -- Main anchor target
    local mainTarget = Settings.comboKeyed('Anchor To', settings.SideKickMainAnchorTarget or 'grouptarget', C.ANCHOR_TARGETS)
    if mainTarget ~= tostring(settings.SideKickMainAnchorTarget or 'grouptarget') and onChange then
        onChange('SideKickMainAnchorTarget', mainTarget)
    end

    -- Main anchor mode
    local mainAnchor = tostring(settings.SideKickMainAnchor or 'none')
    mainAnchor = Settings.comboString('Anchor Mode', mainAnchor, C.ANCHOR_MODES)
    if mainAnchor ~= tostring(settings.SideKickMainAnchor or 'none') and onChange then
        onChange('SideKickMainAnchor', mainAnchor)
    end

    -- Match width
    local matchW = settings.SideKickMainMatchGTWidth == true
    matchW, changed = imgui.Checkbox('Match GroupTarget width', matchW)
    if changed and onChange then
        onChange('SideKickMainMatchGTWidth', matchW)
    end

    -- Main anchor gap
    local gap = tonumber(settings.SideKickMainAnchorGap) or 2
    gap, changed = imgui.SliderInt('Anchor Gap', gap, 0, C.LAYOUT.MAX_ANCHOR_GAP)
    if changed and onChange then
        onChange('SideKickMainAnchorGap', gap)
    end
end

return M
