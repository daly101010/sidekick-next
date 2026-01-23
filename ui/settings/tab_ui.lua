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
    local theme = Settings.labeledCombo('Theme', settings.SideKickTheme or 'Classic', themeNames)
    if theme ~= (settings.SideKickTheme or 'Classic') and onChange then
        onChange('SideKickTheme', theme)
    end

    -- Sync with GroupTarget
    local sync = settings.SideKickSyncThemeWithGT == true
    sync, changed = Settings.labeledCheckbox('Sync theme with GroupTarget', sync, 'Automatically match GroupTarget theme')
    if changed and onChange then
        onChange('SideKickSyncThemeWithGT', sync)
    end

    imgui.Separator()
    imgui.Text('Main Window Docking')

    -- Main anchor target
    local mainTarget = Settings.labeledComboKeyed('Anchor To', settings.SideKickMainAnchorTarget or 'grouptarget', C.ANCHOR_TARGETS)
    if mainTarget ~= tostring(settings.SideKickMainAnchorTarget or 'grouptarget') and onChange then
        onChange('SideKickMainAnchorTarget', mainTarget)
    end

    -- Main anchor mode
    local mainAnchor = tostring(settings.SideKickMainAnchor or 'none')
    mainAnchor = Settings.labeledCombo('Anchor Mode', mainAnchor, C.ANCHOR_MODES)
    if mainAnchor ~= tostring(settings.SideKickMainAnchor or 'none') and onChange then
        onChange('SideKickMainAnchor', mainAnchor)
    end

    -- Match width
    local matchW = settings.SideKickMainMatchGTWidth == true
    matchW, changed = Settings.labeledCheckbox('Match GroupTarget width', matchW)
    if changed and onChange then
        onChange('SideKickMainMatchGTWidth', matchW)
    end

    -- Main anchor gap
    local gap = tonumber(settings.SideKickMainAnchorGap) or 2
    gap, changed = Settings.labeledSliderInt('Anchor Gap', gap, 0, C.LAYOUT.MAX_ANCHOR_GAP)
    if changed and onChange then
        onChange('SideKickMainAnchorGap', gap)
    end

    imgui.Separator()
    imgui.Text('Startup')

    -- Launch Group script on startup (default true)
    local launchGroup = settings.SideKickLaunchGroup ~= false
    launchGroup, changed = Settings.labeledCheckbox('Launch Group window on startup', launchGroup, 'Automatically run /lua run group when SideKick loads')
    if changed and onChange then
        onChange('SideKickLaunchGroup', launchGroup)
    end
end

return M
