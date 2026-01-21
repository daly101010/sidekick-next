local imgui = require('ImGui')
local ImAnim = require('sidekick-next.lib.imanim')
local AnimHelpers = require('sidekick-next.ui.animation_helpers')
local Themes = require('sidekick-next.themes')
local Anchor = require('sidekick-next.ui.anchor')
local Draw = require('sidekick-next.ui.draw_helpers')

local Special = require('sidekick-next.utils.special_abilities')

local M = {}

-- Use centralized draw helpers
local IM_COL32 = Draw.IM_COL32
local dlAddRectFilled = Draw.addRectFilled
local dlAddRect = Draw.addRect

local function getGroupTargetBounds()
    if Anchor and Anchor.getTargetBounds then
        return Anchor.getTargetBounds('grouptarget')
    end
    local gt = _G.GroupTargetBounds
    if not gt or not gt.loaded then return nil end
    if gt.timestamp and (os.clock() - gt.timestamp) > 5.0 then return nil end
    return gt
end

-- Legacy getAnchorPos removed; use ui.anchor instead.

local function drawOutlinedText(x, y, text, r, g, b)
    local offsets = { { -1, -1 }, { 0, -1 }, { 1, -1 }, { -1, 0 }, { 1, 0 }, { -1, 1 }, { 0, 1 }, { 1, 1 } }
    for _, off in ipairs(offsets) do
        imgui.SetCursorScreenPos(x + off[1], y + off[2])
        imgui.TextColored(0, 0, 0, 1, text)
    end
    imgui.SetCursorScreenPos(x, y)
    imgui.TextColored(r or 1, g or 1, b or 1, 1, text)
end

local function drawNameWrapped(minX, minY, maxX, name, helpers)
    name = tostring(name or '')
    if name == '' then return end
    if not helpers or not helpers.wrapToWidth then
        drawOutlinedText(minX + 3, minY + 3, name, 1, 1, 1)
        return
    end

    local maxW = (maxX - minX) - 8
    local lines = helpers.wrapToWidth(name, maxW)
    local lineH = imgui.GetTextLineHeight()
    for i = 1, math.min(#lines, 2) do
        drawOutlinedText(minX + 3, minY + 3 + (i - 1) * lineH, lines[i], 1, 1, 1)
    end
end

function M.draw(opts)
    opts = opts or {}
    local settings = opts.settings or {}

    local trained = Special.getTrained()
    if #trained == 0 then return end

    -- Initialize animation helpers
    AnimHelpers.init(ImAnim)
    AnimHelpers.updateStaggerFrame()

    local cell = tonumber(settings.SideKickSpecialCell) or 65
    local rows = tonumber(settings.SideKickSpecialRows) or 1
    if rows < 1 then rows = 1 end
    local gap = tonumber(settings.SideKickSpecialGap) or 4
    local pad = tonumber(settings.SideKickSpecialPad) or 6
    local bgAlpha = tonumber(settings.SideKickSpecialBgAlpha) or 0.85

    if settings.SideKickSyncThemeWithGT == true and _G.GroupTargetBounds then
        local gt = _G.GroupTargetBounds
        if tonumber(gt.transparency) then bgAlpha = bgAlpha * tonumber(gt.transparency) end
    end

    local cols = math.max(1, math.ceil(#trained / rows))
    local winW = cols * cell + (cols - 1) * gap + pad * 2
    local winH = rows * cell + (rows - 1) * gap + pad * 2

    if imgui.SetNextWindowSizeConstraints then
        imgui.SetNextWindowSizeConstraints(winW, winH, winW, winH)
    end

    local anchorTarget = settings.SideKickSpecialAnchorTarget or 'grouptarget'
    local ax, ay = Anchor.getAnchorPos(anchorTarget, settings.SideKickSpecialAnchor, winW, winH, settings.SideKickSpecialAnchorGap)
    if ax and ay and imgui.SetNextWindowPos then
        imgui.SetNextWindowPos(ax, ay, (ImGuiCond and ImGuiCond.Always) or 0)
    elseif imgui.SetNextWindowPos then
        imgui.SetNextWindowPos(50, 330, (ImGuiCond and ImGuiCond.FirstUseEver) or 4)
    end

    local flags = 0
    if ImGuiWindowFlags and bit32 and bit32.bor then
        flags = bit32.bor(
            ImGuiWindowFlags.NoScrollbar or 0,
            ImGuiWindowFlags.NoTitleBar or 0,
            ImGuiWindowFlags.NoResize or 0,
            ImGuiWindowFlags.NoCollapse or 0
        )
    end

    local themeName = settings.SideKickTheme or 'Classic'
    local style = Themes.getWindowStyle(themeName)
    imgui.PushStyleColor(ImGuiCol.WindowBg, style.WindowBg[1], style.WindowBg[2], style.WindowBg[3], bgAlpha)
    imgui.PushStyleVar(ImGuiStyleVar.WindowRounding, 6)
    imgui.PushStyleVar(ImGuiStyleVar.WindowPadding, pad, pad)

    local shown = imgui.Begin('SideKick Specials##SideKickSpecial', true, flags)
    if shown then
        if Anchor and Anchor.updateWindowBounds then
            Anchor.updateWindowBounds('sidekick_special', imgui)
        end
        local animSpellIcons = opts.animSpellIcons
        local dl = imgui.GetWindowDrawList()

        local startX, startY = imgui.GetCursorPos()
        for idx, def in ipairs(trained) do
            local c = (idx - 1) % cols
            local r = math.floor((idx - 1) / cols)
            local x = startX + c * (cell + gap)
            local y = startY + r * (cell + gap)

            imgui.SetCursorPos(x, y)
            imgui.PushID(def.altName or tostring(def.altID))

            local sp = imgui.GetCursorScreenPos()
            local bx, by
            if type(sp) == 'table' then
                bx = sp.x or sp[1]
                by = sp.y or sp[2]
            else
                bx = sp
                by = select(2, imgui.GetCursorScreenPos())
            end

            imgui.InvisibleButton('btn', cell, cell)
            local clicked = imgui.IsItemClicked()
            local hovered = imgui.IsItemHovered()
            local active = imgui.IsItemActive()

            if clicked and opts.onActivate then
                opts.onActivate(def)
            end

            -- Get unique ID for animations
            local uniqueId = def.altName or tostring(def.altID) or tostring(idx)

            -- Spring-based button scaling
            local scale = AnimHelpers.getButtonScale(uniqueId, hovered, active)

            -- Calculate scaled geometry from center
            local minX, minY, sw, sh = AnimHelpers.scaleFromCenter(bx, by, cell, cell, scale)

            -- Get completion pulse offset
            local pulse = AnimHelpers.getCompletionPulse(uniqueId)
            minX = minX - pulse
            minY = minY - pulse
            sw = sw + pulse * 2
            sh = sh + pulse * 2

            -- Draw icon at scaled position
            if animSpellIcons and imgui.DrawTextureAnimation then
                animSpellIcons:SetTextureCell(tonumber(def.icon) or 0)
                imgui.SetCursorScreenPos(minX, minY)
                imgui.DrawTextureAnimation(animSpellIcons, sw, sh)
                imgui.SetCursorPos(x, y)
            end

            -- Probe cooldown
            local rem, total = 0, 0
            if opts.cooldownProbe then
                rem, total = opts.cooldownProbe({ label = def.altName, key = def.altName })
            end

            -- Draw enhanced cooldown overlay with OKLAB colors
            local restoreX, restoreY = imgui.GetCursorPos()
            AnimHelpers.drawCooldownOverlay(dl, minX, minY, minX + sw, minY + sh, rem, total, uniqueId, opts.helpers, IM_COL32, dlAddRectFilled, dlAddRect)
            imgui.SetCursorPos(restoreX, restoreY)

            -- Name overlay
            if opts.drawName ~= false then
                drawNameWrapped(minX, minY, minX + sw, def.altName, opts.helpers)
            end

            if hovered then
                imgui.BeginTooltip()
                imgui.Text(tostring(def.altName))
                imgui.EndTooltip()
            end

            imgui.PopID()
        end
    end
    imgui.End()
    imgui.PopStyleVar(2)
    imgui.PopStyleColor(1)
end

return M
