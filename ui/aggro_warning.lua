local mq = require('mq')
local imgui = require('ImGui')
local ImAnim = require('lib.imanim')
local Core = require('utils.core')

local M = {}

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

    -- Also check XTarget
    if me.XTarget then
        for i = 1, 13 do
            local xt = me.XTarget(i)
            if xt and xt.TargetType then
                local targetType = xt.TargetType()
                if targetType == 'Auto Hater' then
                    local xtId = xt.ID and xt.ID() or 0
                    local targetId = target.ID and target.ID() or -1
                    if xtId == targetId then
                        return true
                    end
                end
            end
        end
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

                -- Trigger shake animation
                if ImAnim and ImAnim.trigger_shake then
                    ImAnim.trigger_shake('aggro_warning')
                    ImAnim.trigger_shake('aggro_warning_y')
                end
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

    local now = os.clock()
    local elapsed = now - State.showStartTime
    local progress = elapsed / State.duration

    -- Get screen center
    local io = imgui.GetIO()
    local displaySize = io.DisplaySize
    local centerX = displaySize.x / 2
    local centerY = displaySize.y / 2

    -- Calculate scale (spring in, then settle)
    local scale = 1.0
    if ImAnim and ImAnim.spring then
        local targetScale = progress < 0.1 and 1.2 or 1.0
        scale = ImAnim.spring('aggro_scale', targetScale, 400, 20)
    end

    -- Calculate shake offset
    local shakeX, shakeY = 0, 0
    if ImAnim and ImAnim.shake then
        shakeX = ImAnim.shake('aggro_warning', 15, 0.5) or 0
        shakeY = ImAnim.shake('aggro_warning_y', 10, 0.5) or 0
    end

    -- Calculate pulse for glow
    local pulse = 1.0
    if ImAnim and ImAnim.oscillate then
        pulse = ImAnim.oscillate('aggro_pulse', 'sine', 0.7, 1.0, 4.0) or 1.0
    end

    -- Calculate fade out near end
    local alpha = 1.0
    if progress > 0.7 then
        alpha = 1.0 - ((progress - 0.7) / 0.3)
    end

    -- Draw the warning
    local text = 'AGGRO!'

    imgui.SetNextWindowPos(centerX + shakeX, centerY + shakeY, ImGuiCond.Always, 0.5, 0.5)
    imgui.SetNextWindowBgAlpha(0)
    imgui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, 0)

    local flags = ImGuiWindowFlags.NoTitleBar + ImGuiWindowFlags.NoResize +
                  ImGuiWindowFlags.NoMove + ImGuiWindowFlags.NoScrollbar +
                  ImGuiWindowFlags.NoInputs + ImGuiWindowFlags.AlwaysAutoResize

    if imgui.Begin('##AggroWarning', true, flags) then
        -- Red pulsing text
        local r, g, b = 1.0, 0.1 * pulse, 0.1 * pulse
        imgui.PushStyleColor(ImGuiCol.Text, r, g, b, alpha)
        imgui.SetWindowFontScale(scale * 3)
        imgui.Text(text)
        imgui.SetWindowFontScale(1.0)
        imgui.PopStyleColor()
    end
    imgui.End()
    imgui.PopStyleVar()
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
