-- ============================================================
-- SideKick Settings - Animations Tab
-- ============================================================
-- Animation feature toggles and configuration.

local imgui = require('ImGui')
local C = require('sidekick-next.ui.constants')
local Settings = require('sidekick-next.ui.settings')
local Components = require('sidekick-next.ui.components')

local M = {}

function M.draw(settings, themeNames, onChange)
    local themeName = settings.SideKickTheme or 'Classic'

    -- Master toggle (clickable badge)
    local animEnabled = settings.AnimationsEnabled ~= false

    -- Toggle badge for animations (clickable to toggle)
    local animVal, animChanged = Components.StatusBadge.toggle('Animations', animEnabled, themeName, {
        enabledText = 'Enabled',
        disabledText = 'Disabled',
        tooltip = 'Click to toggle all animation effects',
    })
    if animChanged and onChange then onChange('AnimationsEnabled', animVal) end
    animEnabled = animVal

    if animEnabled then
        -- Button Effects Section
        Components.SettingGroup.draw('Button Effects', function()
            -- Hover scale
            local hoverScale = settings.HoverScaleEnabled ~= false
            local hoverVal, hoverChanged = Components.CheckboxRow.draw('Hover Scale', 'HoverScaleEnabled', hoverScale, nil, {
                tooltip = 'Buttons grow slightly when hovered',
            })
            if hoverChanged and onChange then onChange('HoverScaleEnabled', hoverVal) end

            -- Click bounce
            local clickBounce = settings.ClickBounceEnabled ~= false
            local bounceVal, bounceChanged = Components.CheckboxRow.draw('Click Bounce', 'ClickBounceEnabled', clickBounce, nil, {
                tooltip = 'Buttons bounce when cooldown completes',
            })
            if bounceChanged and onChange then onChange('ClickBounceEnabled', bounceVal) end

            -- Toggle pop
            local togglePop = settings.TogglePopEnabled ~= false
            local popVal, popChanged = Components.CheckboxRow.draw('Toggle Pop', 'TogglePopEnabled', togglePop, nil, {
                tooltip = 'Toggle buttons pop when activated',
            })
            if popChanged and onChange then onChange('TogglePopEnabled', popVal) end
        end, { id = 'button_effects', defaultOpen = true })

        -- Visual Effects Section
        Components.SettingGroup.draw('Visual Effects', function()
            -- Ready pulse
            local readyPulse = settings.ReadyPulseEnabled ~= false
            local pulseVal, pulseChanged = Components.CheckboxRow.draw('Ready Pulse', 'ReadyPulseEnabled', readyPulse, nil, {
                tooltip = 'Ready abilities glow with a subtle pulse',
            })
            if pulseChanged and onChange then onChange('ReadyPulseEnabled', pulseVal) end

            -- Cooldown color tween
            local cdColorTween = settings.CooldownColorTweenEnabled ~= false
            local cdVal, cdChanged = Components.CheckboxRow.draw('Cooldown Color Transition', 'CooldownColorTweenEnabled', cdColorTween, nil, {
                tooltip = 'Smooth color transitions as cooldown progresses',
            })
            if cdChanged and onChange then onChange('CooldownColorTweenEnabled', cdVal) end

            -- Toggle color tween
            local toggleColorTween = settings.ToggleColorTweenEnabled ~= false
            local tcVal, tcChanged = Components.CheckboxRow.draw('Toggle Color Transition', 'ToggleColorTweenEnabled', toggleColorTween, nil, {
                tooltip = 'Smooth color transitions when toggling buttons',
            })
            if tcChanged and onChange then onChange('ToggleColorTweenEnabled', tcVal) end

            -- Stagger animation
            local staggerAnim = settings.StaggerAnimationEnabled ~= false
            local staggerVal, staggerChanged = Components.CheckboxRow.draw('Stagger Animation', 'StaggerAnimationEnabled', staggerAnim, nil, {
                tooltip = 'Grid items fade in with staggered timing',
            })
            if staggerChanged and onChange then onChange('StaggerAnimationEnabled', staggerVal) end
        end, { id = 'visual_effects', defaultOpen = true })

        -- Warning Effects Section
        Components.SettingGroup.draw('Warning Effects', function()
            -- Low resource warning
            local lowResWarning = settings.LowResourceWarningEnabled ~= false
            local lowVal, lowChanged = Components.CheckboxRow.draw('Low Resource Warning', 'LowResourceWarningEnabled', lowResWarning, nil, {
                tooltip = 'Pulse effect when resources are low',
            })
            if lowChanged and onChange then onChange('LowResourceWarningEnabled', lowVal) end

            -- Damage flash
            local damageFlash = settings.DamageFlashEnabled ~= false
            local flashVal, flashChanged = Components.CheckboxRow.draw('Damage Flash', 'DamageFlashEnabled', damageFlash, nil, {
                tooltip = 'Flash effect when taking significant damage',
            })
            if flashChanged and onChange then onChange('DamageFlashEnabled', flashVal) end
        end, { id = 'warning_effects', defaultOpen = true })

        -- Animation Parameters Section (collapsed by default)
        Components.SettingGroup.draw('Animation Parameters', function()
            imgui.TextDisabled('Spring Stiffness: ' .. C.ANIMATION.SPRING_STIFFNESS)
            imgui.TextDisabled('Spring Damping: ' .. C.ANIMATION.SPRING_DAMPING)
            imgui.TextDisabled('Hover Scale: ' .. C.ANIMATION.HOVER_SCALE)
            imgui.TextDisabled('Press Scale: ' .. C.ANIMATION.PRESS_SCALE)
            imgui.TextDisabled('Ready Pulse Freq: ' .. C.ANIMATION.READY_PULSE_FREQ .. ' Hz')
        end, { id = 'anim_params', defaultOpen = false })
    else
        imgui.Spacing()
        imgui.TextDisabled('All animations are disabled')
    end
end

return M
