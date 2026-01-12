local mq = require('mq')
local imgui = require('ImGui')
local ImAnim = require('lib.imanim')
local AnimHelpers = require('ui.animation_helpers')
local Items = require('utils.items')
local Themes = require('themes')
local Anchor = require('ui.anchor')

local M = {}

local function IM_COL32(r, g, b, a)
    local shift = bit32 and bit32.lshift
    r = math.max(0, math.min(255, math.floor(tonumber(r) or 0)))
    g = math.max(0, math.min(255, math.floor(tonumber(g) or 0)))
    b = math.max(0, math.min(255, math.floor(tonumber(b) or 0)))
    a = math.max(0, math.min(255, math.floor(tonumber(a) or 255)))
    if shift then
        return shift(a, 24) + shift(b, 16) + shift(g, 8) + r
    end
    return (((a * 256) + b) * 256 + g) * 256 + r
end

local function dlAddRectFilled(dl, x1, y1, x2, y2, col, rounding, flags)
    if not dl then return false end
    rounding = tonumber(rounding) or 0
    flags = tonumber(flags) or 0
    local ImVec2 = _G.ImVec2 or imgui.ImVec2
    local tries = {
        function() dl:AddRectFilled(x1, y1, x2, y2, col, rounding, flags) end,
        function() dl:AddRectFilled(x1, y1, x2, y2, col, rounding) end,
        function() dl:AddRectFilled(x1, y1, x2, y2, col) end,
    }
    if ImVec2 then
        table.insert(tries, function() dl:AddRectFilled(ImVec2(x1, y1), ImVec2(x2, y2), col, rounding, flags) end)
        table.insert(tries, function() dl:AddRectFilled(ImVec2(x1, y1), ImVec2(x2, y2), col, rounding) end)
        table.insert(tries, function() dl:AddRectFilled(ImVec2(x1, y1), ImVec2(x2, y2), col) end)
    end
    for _, fn in ipairs(tries) do
        if pcall(fn) then return true end
    end
    return false
end

local function dlAddRect(dl, x1, y1, x2, y2, col, rounding, flags, thickness)
    if not dl then return false end
    rounding = tonumber(rounding) or 0
    flags = tonumber(flags) or 0
    thickness = tonumber(thickness) or 1
    local ImVec2 = _G.ImVec2 or imgui.ImVec2
    local tries = {
        function() dl:AddRect(x1, y1, x2, y2, col, rounding, flags, thickness) end,
        function() dl:AddRect(x1, y1, x2, y2, col, rounding, flags) end,
        function() dl:AddRect(x1, y1, x2, y2, col, rounding) end,
        function() dl:AddRect(x1, y1, x2, y2, col) end,
    }
    if ImVec2 then
        table.insert(tries, function() dl:AddRect(ImVec2(x1, y1), ImVec2(x2, y2), col, rounding, flags, thickness) end)
        table.insert(tries, function() dl:AddRect(ImVec2(x1, y1), ImVec2(x2, y2), col, rounding, flags) end)
        table.insert(tries, function() dl:AddRect(ImVec2(x1, y1), ImVec2(x2, y2), col, rounding) end)
        table.insert(tries, function() dl:AddRect(ImVec2(x1, y1), ImVec2(x2, y2), col) end)
    end
    for _, fn in ipairs(tries) do
        if pcall(fn) then return true end
    end
    return false
end

-- Legacy getAnchorPos removed; use ui.anchor instead.

local function tooltipFor(entry, helpers, rem, total)
    local info = entry.info
    imgui.BeginTooltip()
    imgui.TextColored(0.0, 1.0, 0.0, 1.0, tostring(entry.itemName))
    if info then
        if info.spell and info.spell ~= '' then imgui.Text('Spell: ' .. tostring(info.spell)) end
        if info.durationFmt and info.durationFmt ~= '' then imgui.Text('Duration: ' .. tostring(info.durationFmt)) end
        if info.category and info.category ~= '' then imgui.Text('Category: ' .. tostring(info.category)) end
        if info.castTimeFmt and info.castTimeFmt ~= '' then imgui.Text('Cast Time: ' .. tostring(info.castTimeFmt)) end
        if info.recastFmt and info.recastFmt ~= '' then imgui.Text('Reuse: ' .. tostring(info.recastFmt)) end
    elseif total and total > 0 and helpers and helpers.fmtCooldown then
        imgui.Text('Reuse: ' .. helpers.fmtCooldown(total))
    end
    if total and total > 0 and helpers and helpers.fmtCooldown then
        if rem and rem > 0 then
            imgui.Text('Cooldown: ' .. helpers.fmtCooldown(rem))
        else
            imgui.Text('Ready')
        end
    end
    imgui.EndTooltip()
end

function M.draw(opts)
    opts = opts or {}
    local settings = opts.settings or {}
    local items = Items.collectConfigured()
    if #items == 0 then return end

    AnimHelpers.init(ImAnim)
    AnimHelpers.updateStaggerFrame()

    local cell = tonumber(settings.SideKickItemBarCell) or 40
    local rows = tonumber(settings.SideKickItemBarRows) or 1
    if rows < 1 then rows = 1 end
    local gap = tonumber(settings.SideKickItemBarGap) or 4
    local pad = tonumber(settings.SideKickItemBarPad) or 6
    local bgAlpha = tonumber(settings.SideKickItemBarBgAlpha) or 0.85
    local rounding = 6

    if settings.SideKickSyncThemeWithGT == true and _G.GroupTargetBounds then
        local gt = _G.GroupTargetBounds
        if tonumber(gt.windowRounding) then rounding = tonumber(gt.windowRounding) end
        if tonumber(gt.transparency) then bgAlpha = bgAlpha * tonumber(gt.transparency) end
    end

    local cols = math.max(1, math.ceil(#items / rows))
    local winW = cols * cell + (cols - 1) * gap + pad * 2
    local winH = rows * cell + (rows - 1) * gap + pad * 2

    if imgui.SetNextWindowSizeConstraints then
        imgui.SetNextWindowSizeConstraints(winW, winH, winW, winH)
    end

    local anchorTarget = settings.SideKickItemBarAnchorTarget or 'grouptarget'
    local ax, ay = Anchor.getAnchorPos(anchorTarget, settings.SideKickItemBarAnchor, winW, winH, settings.SideKickItemBarAnchorGap)
    if ax and ay and imgui.SetNextWindowPos then
        imgui.SetNextWindowPos(ax, ay, (ImGuiCond and ImGuiCond.Always) or 0)
    elseif imgui.SetNextWindowPos then
        imgui.SetNextWindowPos(50, 320, (ImGuiCond and ImGuiCond.FirstUseEver) or 4)
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
    imgui.PushStyleVar(ImGuiStyleVar.WindowRounding, rounding)
    imgui.PushStyleVar(ImGuiStyleVar.WindowPadding, pad, pad)

    local shown = imgui.Begin('SideKick Items##SideKickItemBar', true, flags)
    if shown then
        if Anchor and Anchor.updateWindowBounds then
            Anchor.updateWindowBounds('sidekick_items', imgui)
        end
        local animItems = opts.animItems
        local dl = imgui.GetWindowDrawList()
        local startX, startY = imgui.GetCursorPos()

        for idx, entry in ipairs(items) do
            local c = (idx - 1) % cols
            local r = math.floor((idx - 1) / cols)
            local x = startX + c * (cell + gap)
            local y = startY + r * (cell + gap)

            imgui.SetCursorPos(x, y)
            imgui.PushID(entry.slotKey)

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
            local hovered = imgui.IsItemHovered()
            local active = imgui.IsItemActive()

            local justPressed = false
            if imgui.IsItemActivated then
                local ok, v = pcall(imgui.IsItemActivated)
                justPressed = ok and v == true
            end

            local isDragging = false
            if imgui.IsMouseDragging then
                local okDrag, dragging = pcall(imgui.IsMouseDragging, 0, 4)
                if okDrag and dragging and active then
                    isDragging = true
                end
            end

            local released = false
            if imgui.IsMouseReleased then
                local okRel, v = pcall(imgui.IsMouseReleased, 0)
                released = okRel and v == true
            end

            if justPressed then
                -- placeholder for future drag/drop swapping
            end

            if released and hovered and not isDragging then
                Items.useItem(entry.itemName, { throttleKey = tostring(entry.slotKey or entry.itemName), minInterval = 0.25 })
            end

            local uniqueId = entry.slotKey or entry.itemName or tostring(idx)
            local scale = AnimHelpers.getButtonScale(uniqueId, hovered, active)
            local minX, minY, sw, sh = AnimHelpers.scaleFromCenter(bx, by, cell, cell, scale)

            local pulse = AnimHelpers.getCompletionPulse(uniqueId)
            minX = minX - pulse
            minY = minY - pulse
            sw = sw + pulse * 2
            sh = sh + pulse * 2

            -- Icon
            if animItems and imgui.DrawTextureAnimation then
                local iconIdx = entry.info and tonumber(entry.info.icon) or 0
                local cell0 = (iconIdx > 0) and (iconIdx - 500) or 0
                if cell0 < 0 then cell0 = 0 end
                animItems:SetTextureCell(cell0)
                imgui.SetCursorScreenPos(minX, minY)
                imgui.DrawTextureAnimation(animItems, sw, sh)
                imgui.SetCursorPos(x, y)
            end

            -- Cooldown
            local rem, total = 0, 0
            if opts.cooldownProbe then
                rem, total = opts.cooldownProbe({ label = entry.itemName, key = entry.itemName })
            end
            local restoreX, restoreY = imgui.GetCursorPos()
            AnimHelpers.drawCooldownOverlay(dl, minX, minY, minX + sw, minY + sh, rem, total, uniqueId, opts.helpers, IM_COL32, dlAddRectFilled, dlAddRect)
            imgui.SetCursorPos(restoreX, restoreY)

            if hovered then
                tooltipFor(entry, opts.helpers, rem, total)
            end

            imgui.PopID()
        end
    end

    imgui.End()
    imgui.PopStyleVar(2)
    imgui.PopStyleColor(1)
end

return M
