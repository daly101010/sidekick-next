-- ============================================================
-- SideKick Settings - UI Tab
-- ============================================================
-- Theme, sync, and docking settings.

local imgui = require('ImGui')
local C = require('sidekick-next.ui.constants')
local Settings = require('sidekick-next.ui.settings')
local Components = require('sidekick-next.ui.components')

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
    local themeName = settings.SideKickTheme or 'Classic'

    -- Theme selection
    Components.SettingGroup.section('Theme', themeName)

    local themeChanged, newTheme = Components.ComboRow.byValue('Theme', 'SideKickTheme', settings.SideKickTheme or 'Classic', themeNames, nil, {
        tooltip = 'Visual theme for SideKick windows',
        width = 150,
    })
    -- DEBUG: Log theme change detection
    if themeChanged then
        print(string.format('\ar[tab_ui] themeChanged=true newTheme=%s current=%s\ax', tostring(newTheme), tostring(settings.SideKickTheme)))
    end
    if themeChanged and onChange then
        onChange('SideKickTheme', newTheme)
    end

    -- Sync with GroupTarget
    local sync = settings.SideKickSyncThemeWithGT == true
    local syncVal, syncChanged = Components.CheckboxRow.draw('Sync theme with GroupTarget', 'SideKickSyncThemeWithGT', sync, nil, {
        tooltip = 'Automatically match GroupTarget theme',
    })
    if syncChanged and onChange then
        onChange('SideKickSyncThemeWithGT', syncVal)
    end

    -- Main Window Docking
    Components.SettingGroup.section('Main Window Docking', themeName)

    local optManual = settings.SideKickOptionsManual ~= false
    local optVal, optChanged = Components.CheckboxRow.draw('Options Window: Allow Move/Resize', 'SideKickOptionsManual', optManual, nil, {
        tooltip = 'Allow moving and resizing the SideKick Options window with the mouse',
    })
    if optChanged and onChange then
        onChange('SideKickOptionsManual', optVal)
    end

    local mainEnabled = settings.SideKickMainEnabled ~= false
    local mainEnabledVal, mainEnabledChanged = Components.CheckboxRow.draw('Show Main Bar', 'SideKickMainEnabled', mainEnabled, nil, {
        tooltip = 'Show or hide the SideKick main button bar window',
    })
    if mainEnabledChanged and onChange then
        onChange('SideKickMainEnabled', mainEnabledVal)
        mainEnabled = mainEnabledVal
    end

    -- Main anchor target
    local mainTarget = settings.SideKickMainAnchorTarget or 'grouptarget'
    local targetChanged, newTarget = Components.ComboRow.keyValue('Anchor To', 'SideKickMainAnchorTarget', mainTarget, C.ANCHOR_TARGETS, nil, {
        tooltip = 'Which window to anchor the main bar to',
        width = 150,
    })
    if targetChanged and onChange then
        onChange('SideKickMainAnchorTarget', newTarget)
    end

    -- Main anchor mode
    local mainAnchor = tostring(settings.SideKickMainAnchor or 'none')
    local anchorChanged, newAnchor = Components.ComboRow.byValue('Anchor Mode', 'SideKickMainAnchor', mainAnchor, C.ANCHOR_MODES, nil, {
        tooltip = 'How the main bar positions relative to anchor target',
        width = 150,
    })
    if anchorChanged and onChange then
        onChange('SideKickMainAnchor', newAnchor)
    end

    -- Main anchor gap
    local gap = tonumber(settings.SideKickMainAnchorGap) or 2
    local gapChanged, newGap = Components.SliderRow.anchorGap('Anchor Gap', 'SideKickMainAnchorGap', gap)
    if gapChanged and onChange then
        onChange('SideKickMainAnchorGap', newGap)
    end

    -- Window rounding
    local rounding = tonumber(settings.SideKickMainRounding) or 6
    local roundChanged, newRound = Components.SliderRow.int('Window Rounding', 'SideKickMainRounding', rounding, 0, 20, nil, {
        tooltip = 'Corner rounding for the main button bar window',
        format = '%d px',
    })
    if roundChanged and onChange then
        onChange('SideKickMainRounding', newRound)
    end

    -- Button scale
    local btnScale = tonumber(settings.SideKickMainButtonScale) or 1.0
    local scaleChanged, newScale = Components.SliderRow.float('Button Scale', 'SideKickMainButtonScale', btnScale, 0.5, 3.0, nil, {
        tooltip = 'Scale factor for main button bar buttons',
        format = '%.1fx',
    })
    if scaleChanged and onChange then
        onChange('SideKickMainButtonScale', newScale)
    end

    -- Font scale
    local fontScale = tonumber(settings.SideKickFontScale) or 1.0
    local fontScaleChanged, newFontScale = Components.SliderRow.float('Font Scale', 'SideKickFontScale', fontScale, 0.5, 3.0, nil, {
        tooltip = 'Scale factor for all UI text (for high-resolution monitors)',
        format = '%.1fx',
    })
    if fontScaleChanged and onChange then
        onChange('SideKickFontScale', newFontScale)
    end

    -- Width override (0 = auto)
    local widthOverride = tonumber(settings.SideKickMainWidth) or 0
    local widthChanged, newWidth = Components.SliderRow.int('Width Override', 'SideKickMainWidth', widthOverride, 0, 1200, nil, {
        tooltip = 'Override the main window width (0 = auto)',
        format = '%d px',
    })
    if widthChanged and onChange then
        onChange('SideKickMainWidth', newWidth)
    end
    imgui.SameLine()
    imgui.TextDisabled('(0 = auto)')

    -- Show textured border (gold frame)
    local showBorder = settings.SideKickMainShowBorder ~= false
    local borderVal, borderChanged = Components.CheckboxRow.draw('Show Gold Border', 'SideKickMainShowBorder', showBorder, nil, {
        tooltip = 'Show the gold frame border around the main window (background texture still shows when disabled)',
    })
    if borderChanged and onChange then
        onChange('SideKickMainShowBorder', borderVal)
    end

    -- Texture tint (only meaningful with textured theme)
    local tintStr = settings.SideKickMainTextureTint or '1.0,1.0,1.0'
    local tintColor = parseTintColor(tintStr)
    local newTint, tintChanged = imgui.ColorEdit3('Texture Tint##main', tintColor)
    if tintChanged and onChange then
        onChange('SideKickMainTextureTint', formatTintColor(newTint))
    end
    imgui.SameLine()
    if imgui.SmallButton('Reset##main_tint') then
        if onChange then onChange('SideKickMainTextureTint', '1.0,1.0,1.0') end
    end

    -- Main background texture selection (textured themes)
    local bgOptions = {
        { key = 'lightrock', label = 'Light Rock (default)' },
        { key = 'darkrock', label = 'Dark Rock (Listbox)' },
        { key = 'action', label = 'Action Window' },
        { key = 'classic', label = 'Classic Left Window' },
        { key = 'custom', label = 'Custom Anim...' },
        { key = 'none', label = 'None' },
    }
    local bgStyle = settings.SideKickMainBgStyle or 'lightrock'
    local bgChanged, newBg = Components.ComboRow.keyValue('Main Background', 'SideKickMainBgStyle', bgStyle, bgOptions, nil, {
        tooltip = 'Background texture used behind the main bar (textured themes only)',
        width = 180,
    })
    if bgChanged and onChange then
        onChange('SideKickMainBgStyle', newBg)
        bgStyle = newBg
    end
    if (bgStyle == 'custom') then
        local anim = settings.SideKickMainBgTexture or ''
        local newAnim, animChanged = imgui.InputText('Custom Anim or File##sk_main_bg_anim', anim, 64)
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Enter an EQ anim name (e.g. A_Listbox_Background1) or a UI file from F:/lua/UI (e.g. wnd_bg_dark_rock.tga)')
        end
        if animChanged and onChange then
            onChange('SideKickMainBgTexture', newAnim)
        end
        local tile = settings.SideKickMainBgTile ~= false
        local tileVal, tileChanged = Components.CheckboxRow.draw('Tile Custom Background', 'SideKickMainBgTile', tile, nil, {
            tooltip = 'Tile the custom anim instead of stretching it',
        })
        if tileChanged and onChange then
            onChange('SideKickMainBgTile', tileVal)
        end
    end

    -- Startup
    Components.SettingGroup.section('Startup', themeName)

    -- Launch Group script on startup (default true)
    local launchGroup = settings.SideKickLaunchGroup ~= false
    local launchVal, launchChanged = Components.CheckboxRow.draw('Launch Group window on startup', 'SideKickLaunchGroup', launchGroup, nil, {
        tooltip = 'Automatically run /lua run group when SideKick loads',
    })
    if launchChanged and onChange then
        onChange('SideKickLaunchGroup', launchVal)
    end
end

return M
