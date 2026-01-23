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
    animEnabled, changed = Settings.labeledCheckbox('Enable Animations', animEnabled, 'Master toggle for all animation effects')
    if changed and onChange then onChange('AnimationsEnabled', animEnabled) end

    if animEnabled then
        imgui.Separator()
        imgui.Text('Button Effects')

        -- Hover scale
        local hoverScale = settings.HoverScaleEnabled ~= false
        hoverScale, changed = Settings.labeledCheckbox('Hover Scale', hoverScale, 'Buttons grow slightly when hovered')
        if changed and onChange then onChange('HoverScaleEnabled', hoverScale) end

        -- Click bounce
        local clickBounce = settings.ClickBounceEnabled ~= false
        clickBounce, changed = Settings.labeledCheckbox('Click Bounce', clickBounce, 'Buttons bounce when cooldown completes')
        if changed and onChange then onChange('ClickBounceEnabled', clickBounce) end

        -- Toggle pop
        local togglePop = settings.TogglePopEnabled ~= false
        togglePop, changed = Settings.labeledCheckbox('Toggle Pop', togglePop, 'Toggle buttons pop when activated')
        if changed and onChange then onChange('TogglePopEnabled', togglePop) end

        imgui.Separator()
        imgui.Text('Visual Effects')

        -- Ready pulse
        local readyPulse = settings.ReadyPulseEnabled ~= false
        readyPulse, changed = Settings.labeledCheckbox('Ready Pulse', readyPulse, 'Ready abilities glow with a subtle pulse')
        if changed and onChange then onChange('ReadyPulseEnabled', readyPulse) end

        -- Cooldown color tween
        local cdColorTween = settings.CooldownColorTweenEnabled ~= false
        cdColorTween, changed = Settings.labeledCheckbox('Cooldown Color Transition', cdColorTween, 'Smooth color transitions as cooldown progresses')
        if changed and onChange then onChange('CooldownColorTweenEnabled', cdColorTween) end

        -- Toggle color tween
        local toggleColorTween = settings.ToggleColorTweenEnabled ~= false
        toggleColorTween, changed = Settings.labeledCheckbox('Toggle Color Transition', toggleColorTween, 'Smooth color transitions when toggling buttons')
        if changed and onChange then onChange('ToggleColorTweenEnabled', toggleColorTween) end

        -- Stagger animation
        local staggerAnim = settings.StaggerAnimationEnabled ~= false
        staggerAnim, changed = Settings.labeledCheckbox('Stagger Animation', staggerAnim, 'Grid items fade in with staggered timing')
        if changed and onChange then onChange('StaggerAnimationEnabled', staggerAnim) end

        imgui.Separator()
        imgui.Text('Warning Effects')

        -- Low resource warning
        local lowResWarning = settings.LowResourceWarningEnabled ~= false
        lowResWarning, changed = Settings.labeledCheckbox('Low Resource Warning', lowResWarning, 'Pulse effect when resources are low')
        if changed and onChange then onChange('LowResourceWarningEnabled', lowResWarning) end

        -- Damage flash
        local damageFlash = settings.DamageFlashEnabled ~= false
        damageFlash, changed = Settings.labeledCheckbox('Damage Flash', damageFlash, 'Flash effect when taking significant damage')
        if changed and onChange then onChange('DamageFlashEnabled', damageFlash) end

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
