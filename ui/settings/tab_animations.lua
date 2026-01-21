-- ============================================================
-- SideKick Settings - Animations Tab
-- ============================================================
-- Animation feature toggles and configuration.

local imgui = require('ImGui')
local C = require('sidekick-next.ui.constants')
local Settings = require('sidekick-next.ui.settings')

local M = {}

function M.draw(settings, themeNames, onChange)
    local changed

    -- Master toggle
    local animEnabled = settings.AnimationsEnabled ~= false
    animEnabled, changed = imgui.Checkbox('Enable Animations', animEnabled)
    if changed and onChange then onChange('AnimationsEnabled', animEnabled) end
    if imgui.IsItemHovered() then
        Settings.safeTooltip('Master toggle for all animation effects')
    end

    if animEnabled then
        imgui.Separator()
        imgui.Text('Button Effects')

        -- Hover scale
        local hoverScale = settings.HoverScaleEnabled ~= false
        hoverScale, changed = imgui.Checkbox('Hover Scale', hoverScale)
        if changed and onChange then onChange('HoverScaleEnabled', hoverScale) end
        if imgui.IsItemHovered() then
            Settings.safeTooltip('Buttons grow slightly when hovered')
        end

        -- Click bounce
        local clickBounce = settings.ClickBounceEnabled ~= false
        clickBounce, changed = imgui.Checkbox('Click Bounce', clickBounce)
        if changed and onChange then onChange('ClickBounceEnabled', clickBounce) end
        if imgui.IsItemHovered() then
            Settings.safeTooltip('Buttons bounce when cooldown completes')
        end

        -- Toggle pop
        local togglePop = settings.TogglePopEnabled ~= false
        togglePop, changed = imgui.Checkbox('Toggle Pop', togglePop)
        if changed and onChange then onChange('TogglePopEnabled', togglePop) end
        if imgui.IsItemHovered() then
            Settings.safeTooltip('Toggle buttons pop when activated')
        end

        imgui.Separator()
        imgui.Text('Visual Effects')

        -- Ready pulse
        local readyPulse = settings.ReadyPulseEnabled ~= false
        readyPulse, changed = imgui.Checkbox('Ready Pulse', readyPulse)
        if changed and onChange then onChange('ReadyPulseEnabled', readyPulse) end
        if imgui.IsItemHovered() then
            Settings.safeTooltip('Ready abilities glow with a subtle pulse')
        end

        -- Cooldown color tween
        local cdColorTween = settings.CooldownColorTweenEnabled ~= false
        cdColorTween, changed = imgui.Checkbox('Cooldown Color Transition', cdColorTween)
        if changed and onChange then onChange('CooldownColorTweenEnabled', cdColorTween) end
        if imgui.IsItemHovered() then
            Settings.safeTooltip('Smooth color transitions as cooldown progresses')
        end

        -- Toggle color tween
        local toggleColorTween = settings.ToggleColorTweenEnabled ~= false
        toggleColorTween, changed = imgui.Checkbox('Toggle Color Transition', toggleColorTween)
        if changed and onChange then onChange('ToggleColorTweenEnabled', toggleColorTween) end
        if imgui.IsItemHovered() then
            Settings.safeTooltip('Smooth color transitions when toggling buttons')
        end

        -- Stagger animation
        local staggerAnim = settings.StaggerAnimationEnabled ~= false
        staggerAnim, changed = imgui.Checkbox('Stagger Animation', staggerAnim)
        if changed and onChange then onChange('StaggerAnimationEnabled', staggerAnim) end
        if imgui.IsItemHovered() then
            Settings.safeTooltip('Grid items fade in with staggered timing')
        end

        imgui.Separator()
        imgui.Text('Warning Effects')

        -- Low resource warning
        local lowResWarning = settings.LowResourceWarningEnabled ~= false
        lowResWarning, changed = imgui.Checkbox('Low Resource Warning', lowResWarning)
        if changed and onChange then onChange('LowResourceWarningEnabled', lowResWarning) end
        if imgui.IsItemHovered() then
            Settings.safeTooltip('Pulse effect when resources are low')
        end

        -- Damage flash
        local damageFlash = settings.DamageFlashEnabled ~= false
        damageFlash, changed = imgui.Checkbox('Damage Flash', damageFlash)
        if changed and onChange then onChange('DamageFlashEnabled', damageFlash) end
        if imgui.IsItemHovered() then
            Settings.safeTooltip('Flash effect when taking significant damage')
        end

        -- Configuration
        if imgui.CollapsingHeader('Animation Parameters') then
            imgui.Indent()

            -- Spring stiffness (informational, uses constants)
            imgui.TextDisabled('Spring Stiffness: ' .. C.ANIMATION.SPRING_STIFFNESS)
            imgui.TextDisabled('Spring Damping: ' .. C.ANIMATION.SPRING_DAMPING)
            imgui.TextDisabled('Hover Scale: ' .. C.ANIMATION.HOVER_SCALE)
            imgui.TextDisabled('Press Scale: ' .. C.ANIMATION.PRESS_SCALE)
            imgui.TextDisabled('Ready Pulse Freq: ' .. C.ANIMATION.READY_PULSE_FREQ .. ' Hz')

            imgui.Unindent()
        end
    else
        imgui.TextDisabled('All animations are disabled')
    end
end

return M
