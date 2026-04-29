local mq = require('mq')
local imgui = require('ImGui')
local iam = require('sidekick-next.utils.imanim')
local Core = require('sidekick-next.utils.core')

local M = {}

-- Cached spring ease descriptor (iam.EaseSpring may be nil in some builds)
local _ezSpringAggro = (function()
    local ez = IamEaseDesc()
    ez.type = IamEaseType.Spring
    ez.p0 = 1.0
    ez.p1 = 400
    ez.p2 = 20
    ez.p3 = 0.0
    return ez
end)()

local TANK_CLASSES = { WAR = true, PAL = true, SHD = true }

local State = {
    enabled = true,
    threshold = 98,
    duration = 3.0,
    cooldown = 5.0,

    showing = false,
    showStartTime = 0,
    lastWarningTime = 0,
}

local function loadSettings()
    local sec = Core.Ini['AggroWarning'] or {}
    if sec.enabled ~= nil then
        State.enabled = sec.enabled ~= false and sec.enabled ~= 'false'
    end
    State.threshold = tonumber(sec.threshold) or 98
    State.duration = tonumber(sec.duration) or 3.0
    State.cooldown = tonumber(sec.cooldown) or 5.0
end

local function saveSettings()
    Core.Ini['AggroWarning'] = {
        enabled = State.enabled,
        threshold = State.threshold,
        duration = State.duration,
        cooldown = State.cooldown,
    }
    if Core.save then Core.save() end
end

local function shouldShowWarning()
    if not State.enabled then return false end

    local me = mq.TLO.Me
    if not me or not me() then return false end

    -- Not in raid
    local raidMembers = 0
    if mq.TLO.Raid and mq.TLO.Raid.Members then
        raidMembers = mq.TLO.Raid.Members() or 0
    end
    if (tonumber(raidMembers) or 0) == 0 then return false end

    -- Is a tank class
    local myClass = ''
    if me.Class and me.Class.ShortName then
        myClass = me.Class.ShortName() or ''
    end
    if TANK_CLASSES[myClass:upper()] then return false end

    -- No target
    local target = mq.TLO.Target
    if not target or not target.ID or not target.ID() then return false end

    -- Target HP too high
    local targetHp = 100
    if target.PctHPs then
        targetHp = target.PctHPs() or 100
    end
    if (tonumber(targetHp) or 100) >= State.threshold then return false end

    -- Check if we have aggro
    local myId = 0
    if me.ID then myId = me.ID() or 0 end

    local aggroHolderId = nil
    if target.AggroHolder and target.AggroHolder.ID then
        aggroHolderId = target.AggroHolder.ID()
    end

    if aggroHolderId and aggroHolderId == myId then return true end

    -- Also check PctAggro - only warn if we have high aggro (>= 90%)
    -- This avoids false positives from Auto Hater which just means we're on the hate list
    local pctAggro = 0
    if me.PctAggro then
        pctAggro = me.PctAggro() or 0
    end
    if (tonumber(pctAggro) or 0) >= 90 then
        return true
    end

    return false
end

function M.update()
    if not State.enabled then
        State.showing = false
        return
    end

    local now = os.clock()

    -- Check if we should trigger warning
    if not State.showing then
        if shouldShowWarning() then
            -- Respect cooldown
            if (now - State.lastWarningTime) >= State.cooldown then
                State.showing = true
                State.showStartTime = now
                State.lastWarningTime = now

                -- Trigger shake animation (native ImAnim)
                iam.TriggerShake('aggro_warning')
                iam.TriggerShake('aggro_warning_y')
            end
        end
    else
        -- Check if we should hide
        local elapsed = now - State.showStartTime
        if elapsed >= State.duration then
            State.showing = false
        elseif not shouldShowWarning() then
            -- Aggro lost, hide early
            State.showing = false
        end
    end
end

function M.draw()
    if not State.showing then return end

    local stylePushed = false
    local begun = false
    local ok, err = pcall(function()
        local now = os.clock()
        local duration = tonumber(State.duration) or 3.0
        if duration <= 0 then duration = 3.0 end
        local elapsed = now - State.showStartTime
        local progress = elapsed / duration

        -- Get screen center
        local io = imgui.GetIO()
        local displaySize = io and io.DisplaySize or nil
        local centerX = 960
        local centerY = 540
        if type(displaySize) == 'table' then
            centerX = (tonumber(displaySize.x or displaySize[1]) or 1920) / 2
            centerY = (tonumber(displaySize.y or displaySize[2]) or 1080) / 2
        end

        -- Calculate scale (spring in, then settle) via native TweenFloat
        local dt = (io and tonumber(io.DeltaTime)) or 0.016
        local targetScale = progress < 0.1 and 1.2 or 1.0
        local scale = tonumber(iam.TweenFloat('aggro_scale', imgui.GetID('aScale'), targetScale, 0.5, _ezSpringAggro, IamPolicy.Crossfade, dt)) or 1.0

        -- Calculate shake offset via native Shake
        local shakeX = tonumber(iam.Shake('aggro_warning_x', 15, 30, 0.5, dt)) or 0
        local shakeY = tonumber(iam.Shake('aggro_warning_y', 10, 30, 0.5, dt)) or 0

        -- Calculate pulse for glow via native Oscillate
        local pulse = tonumber(iam.Oscillate('aggro_pulse', imgui.GetID('aPulse'), 0.15, 4.0, 0.0, IamWaveType.Sine, dt)) or 0
        pulse = 0.85 + pulse  -- 0.7 to 1.0 range

        -- Calculate fade out near end
        local alpha = 1.0
        if progress > 0.7 then
            alpha = 1.0 - ((progress - 0.7) / 0.3)
        end
        if alpha < 0 then alpha = 0 end
        if alpha > 1 then alpha = 1 end

        imgui.SetNextWindowPos(centerX + shakeX, centerY + shakeY, ImGuiCond.Always, 0.5, 0.5)
        imgui.SetNextWindowBgAlpha(0)
        imgui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, 0)
        stylePushed = true

        local flags = ImGuiWindowFlags.NoTitleBar + ImGuiWindowFlags.NoResize +
                      ImGuiWindowFlags.NoMove + ImGuiWindowFlags.NoScrollbar +
                      ImGuiWindowFlags.NoInputs + ImGuiWindowFlags.AlwaysAutoResize

        local open, draw = imgui.Begin('##AggroWarning', true, flags)
        begun = true
        if draw == nil then draw = open end
        if draw then
            -- Red pulsing text
            local r, g, b = 1.0, 0.1 * pulse, 0.1 * pulse
            imgui.PushStyleColor(ImGuiCol.Text, r, g, b, alpha)
            imgui.SetWindowFontScale(scale * 3)
            imgui.Text('AGGRO!')
            imgui.SetWindowFontScale(1.0)
            imgui.PopStyleColor()
        end
    end)

    if begun then
        pcall(imgui.End)
    end
    if stylePushed then
        pcall(imgui.PopStyleVar)
    end

    if not ok then
        State.showing = false
        if mq and mq.cmd then
            mq.cmd('/echo \\ar[SideKick AggroWarning] Draw error: ' .. tostring(err) .. '\\ax')
        end
    end
end

function M.drawSettings()
    local changed = false

    local enabled, e1 = imgui.Checkbox('Enable Aggro Warning', State.enabled)
    if e1 then State.enabled = enabled; changed = true end

    if State.enabled then
        imgui.Indent()

        local threshold, t1 = imgui.SliderInt('HP Threshold##aggro', State.threshold, 50, 100)
        if t1 then State.threshold = threshold; changed = true end
        if imgui.IsItemHovered() then
            imgui.SetTooltip('Only warn if target HP is below this %%')
        end

        local duration, d1 = imgui.SliderFloat('Display Duration##aggro', State.duration, 1.0, 10.0, '%.1f sec')
        if d1 then State.duration = duration; changed = true end

        local cooldown, c1 = imgui.SliderFloat('Cooldown##aggro', State.cooldown, 1.0, 30.0, '%.1f sec')
        if c1 then State.cooldown = cooldown; changed = true end

        imgui.Unindent()
    end

    if changed then saveSettings() end
end

function M.init()
    loadSettings()
end

function M.isEnabled()
    return State.enabled
end

function M.setEnabled(enabled)
    State.enabled = enabled
    saveSettings()
end

return M
