-- =========================================================================
-- ui/skill_bar_animated.lua
-- Skill bar — square cells with wrapped text labels and a cooldown
-- countdown overlay, mirroring the AA/Disc bar visual style.
-- Discovery via utils/skills.lua. The host sends activations to the
-- lease-bound manual action queue; cooldowns are read from live TLO state.
-- =========================================================================

local mq = require('mq')
local imgui = require('ImGui')
local Skills = require('sidekick-next.utils.skills')
local Themes = require('sidekick-next.themes')
local Anchor = require('sidekick-next.ui.anchor')
local Draw = require('sidekick-next.ui.draw_helpers')
local Helpers = require('sidekick-next.lib.helpers')
local lazy = require('sidekick-next.utils.lazy_require')

local getTextureRenderer = lazy.once('sidekick-next.ui.texture_renderer')

local M = {}

-- Cache the observed total per skill so the overlay's percentage stays
-- proportional even after the timer ticks down (AbilityTimer only reports
-- the remaining value, not the original total).
local _observedTotal = {}

local function lc(s) return tostring(s or ''):lower() end

local function readSeconds(timeTLO)
    if not timeTLO then return 0 end
    -- MQ "timetype" exposes .TotalSeconds for an exact float seconds count.
    local ok, v = pcall(function()
        return timeTLO.TotalSeconds and timeTLO.TotalSeconds()
    end)
    if ok then
        local n = tonumber(v)
        if n and n >= 0 then return n end
    end
    -- Fallback: bare invocation. Many MQ builds return seconds for AbilityTimer.
    ok, v = pcall(function() return timeTLO() end)
    if ok then
        local n = tonumber(v) or 0
        -- If the value looks like ms (large), convert.
        if n > 1000 and n < 86400000 then return n / 1000 end
        return n
    end
    return 0
end

local function readTotalRecastSeconds(name)
    local total = 0
    pcall(function()
        local sk = mq.TLO.Skill(name)
        if sk and sk() and sk.ReuseTime then
            local v = tonumber(sk.ReuseTime()) or 0
            if v > 0 and v < 1000 and math.floor(v) == v then
                total = v * 6  -- ticks → seconds
            else
                total = v
            end
        end
    end)
    return total
end

--- Probe the live TLO for a skill's reuse cooldown.
--- @param name string Skill display name.
--- @return number remainingSeconds
--- @return number totalSeconds
local function probeCooldown(name)
    if not name or name == '' then return 0, 0 end

    local rem = 0
    pcall(function()
        local t = mq.TLO.Me and mq.TLO.Me.AbilityTimer and mq.TLO.Me.AbilityTimer(name)
        rem = readSeconds(t)
    end)

    local key = lc(name)
    if rem <= 0 then
        _observedTotal[key] = nil
        return 0, 0
    end

    -- Lock in total at the first frame we see the timer running so the
    -- overlay percentage stays meaningful as it ticks down.
    local total = _observedTotal[key]
    if not total or total < rem then
        total = readTotalRecastSeconds(name)
        if total <= 0 or total < rem then total = rem end
        _observedTotal[key] = total
    end

    return rem, total
end

local function fmtRem(rem)
    rem = math.floor((tonumber(rem) or 0) + 0.5)
    if rem >= 60 then
        local m = math.floor(rem / 60)
        local s = math.floor(rem % 60)
        return string.format('%d:%02d', m, s)
    end
    return tostring(rem)
end

local function truthy(v)
    if v == true then return true end
    if v == false or v == nil then return false end
    if type(v) == 'number' then return v ~= 0 end
    if type(v) == 'string' then
        local s = v:lower()
        return s == '1' or s == 'true' or s == 'yes' or s == 'on'
    end
    return false
end

local function collectVisible(skills, settings)
    local out = {}
    for _, sk in ipairs(skills or {}) do
        local key = 'SideKickSkill_' .. tostring(sk.index)
        if settings and truthy(settings[key]) then
            table.insert(out, sk)
        end
    end
    return out
end

local function drawOutlinedText(x, y, text, r, g, b)
    local offsets = { { -1, -1 }, { 0, -1 }, { 1, -1 }, { -1, 0 }, { 1, 0 }, { -1, 1 }, { 0, 1 }, { 1, 1 } }
    for _, off in ipairs(offsets) do
        imgui.SetCursorScreenPos(x + off[1], y + off[2])
        imgui.TextColored(0, 0, 0, 1, text)
    end
    imgui.SetCursorScreenPos(x, y)
    imgui.TextColored(r or 1, g or 1, b or 1, 1, text)
end

local function calcTextW(s)
    local sz = imgui.CalcTextSize(s)
    if type(sz) == 'table' then return sz.x or sz[1] or 0 end
    return tonumber(sz) or 0
end

local function drawNameCentered(minX, minY, maxX, maxY, name, helpers)
    name = tostring(name or '')
    if name == '' then return end
    local lines
    if helpers and helpers.wrapToWidth then
        local maxW = (maxX - minX) - 6
        lines = helpers.wrapToWidth(name, maxW)
    else
        lines = { name }
    end
    if #lines > 3 then
        local trimmed = {}
        for i = 1, 3 do trimmed[i] = lines[i] end
        lines = trimmed
    end
    local lineH = imgui.GetTextLineHeight()
    local totalH = #lines * lineH
    local cellH = maxY - minY
    local cellW = maxX - minX
    local startY = minY + (cellH - totalH) * 0.5
    for i, line in ipairs(lines) do
        local lw = calcTextW(line)
        local lx = minX + (cellW - lw) * 0.5
        drawOutlinedText(lx, startY + (i - 1) * lineH, line, 1, 1, 1)
    end
end

function M.draw(opts)
    opts = opts or {}
    local settings = opts.settings or {}

    local all = Skills.discover()
    local enabled = collectVisible(all, settings)
    if #enabled == 0 then return end

    local cell = tonumber(settings.SideKickSkillBarCell) or 48
    local rows = tonumber(settings.SideKickSkillBarRows) or 2
    if rows < 1 then rows = 1 end
    local gap = tonumber(settings.SideKickSkillBarGap) or 4
    local pad = tonumber(settings.SideKickSkillBarPad) or 6
    local bgAlpha = tonumber(settings.SideKickSkillBarBgAlpha) or 0.85

    local cols = math.max(1, math.ceil(#enabled / rows))
    local autoW = cols * cell + (cols - 1) * gap + pad * 2
    local winH = rows * cell + (rows - 1) * gap + pad * 2

    local widthOverride = tonumber(settings.SideKickSkillBarWidth) or 0
    local winW = (widthOverride > 0) and widthOverride or autoW

    if imgui.SetNextWindowSizeConstraints then
        imgui.SetNextWindowSizeConstraints(winW, winH, winW, winH)
    end

    local anchorTarget = settings.SideKickSkillBarAnchorTarget or 'none'
    local anchorMode = settings.SideKickSkillBarAnchor or 'none'
    local ax, ay
    if Anchor and Anchor.getAnchorPos then
        ax, ay = Anchor.getAnchorPos(anchorTarget, anchorMode, winW, winH, settings.SideKickSkillBarAnchorGap)
    end
    if ax and ay and imgui.SetNextWindowPos then
        imgui.SetNextWindowPos(ax, ay, (ImGuiCond and ImGuiCond.Always) or 0)
    elseif imgui.SetNextWindowPos then
        imgui.SetNextWindowPos(80, 320, (ImGuiCond and ImGuiCond.FirstUseEver) or 4)
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
    local style = Themes.getWindowStyle and Themes.getWindowStyle(themeName) or { WindowBg = { 0.08, 0.08, 0.08 } }

    local useTexturedBg = false
    pcall(function()
        useTexturedBg = Themes.isTexturedTheme and Themes.isTexturedTheme(themeName) or false
    end)

    if useTexturedBg then
        imgui.PushStyleColor(ImGuiCol.WindowBg, 0, 0, 0, 0)
    else
        imgui.PushStyleColor(ImGuiCol.WindowBg, style.WindowBg[1], style.WindowBg[2], style.WindowBg[3], bgAlpha)
    end
    imgui.PushStyleVar(ImGuiStyleVar.WindowRounding, 6)
    imgui.PushStyleVar(ImGuiStyleVar.WindowPadding, pad, pad)

    local _, shown = imgui.Begin('SideKick Skills##SideKickSkillBar', true, flags)
    if shown == nil then shown = true end
    if shown then pcall(function()
        if Anchor and Anchor.updateWindowBounds then
            Anchor.updateWindowBounds('sidekick_skill', imgui)
        end
        local dl = imgui.GetWindowDrawList()

        -- Themed window background (gold border + tile fill, mirrors disc_bar).
        local showBorder = settings.SideKickSkillBarShowBorder ~= false
        if useTexturedBg and dl then
            pcall(function()
                local tr = getTextureRenderer()
                if not tr then return end
                local winPosX, winPosY = imgui.GetWindowPos()
                if type(winPosX) == 'table' then
                    winPosY = winPosX.y or winPosX[2]
                    winPosX = winPosX.x or winPosX[1]
                end
                local winSizeX, winSizeY = imgui.GetWindowSize()
                if type(winSizeX) == 'table' then
                    winSizeY = winSizeX.y or winSizeX[2]
                    winSizeX = winSizeX.x or winSizeX[1]
                end
                local anchor = tostring(settings.SideKickSkillBarAnchor or 'none'):lower()
                local tintCol = tr.parseTintSetting and tr.parseTintSetting(settings.SideKickSkillBarTextureTint) or nil
                if showBorder and tr.drawHotbuttonBg then
                    tr.drawHotbuttonBg(dl, winPosX, winPosY, winSizeX, winSizeY, {
                        rounding = 6,
                        flipH = (anchor == 'right'),
                        tintCol = tintCol,
                    })
                elseif tr.drawActionWindowBg then
                    tr.drawActionWindowBg(dl, winPosX, winPosY, winSizeX, winSizeY, {
                        tile = true,
                        shadows = false,
                        tintCol = tintCol,
                    })
                end
            end)
        end

        local startX, startY = imgui.GetCursorPos()

        for idx, sk in ipairs(enabled) do
            local c = (idx - 1) % cols
            local r = math.floor((idx - 1) / cols)
            local x = startX + c * (cell + gap)
            local y = startY + r * (cell + gap)

            imgui.SetCursorPos(x, y)
            imgui.PushID('skbtn_' .. tostring(sk.index))

            local sp = imgui.GetCursorScreenPos()
            local bx, by
            if type(sp) == 'table' then bx = sp.x or sp[1]; by = sp.y or sp[2] else bx = sp; by = select(2, imgui.GetCursorScreenPos()) end

            imgui.InvisibleButton('btn', cell, cell)
            local hovered = imgui.IsItemHovered()
            local pressed = imgui.IsItemActivated and (function()
                local ok, v = pcall(imgui.IsItemActivated)
                return ok and v == true
            end)() or false

            if pressed and opts.onActivate then
                opts.onActivate(sk)
            end

            local minX, minY = bx, by
            local maxX, maxY = bx + cell, by + cell
            local rounding = math.max(4, math.floor(cell * 0.12))

            -- Themed icon holder (textured) when a textured theme is active;
            -- otherwise a flat rounded rect with hover accent.
            local drewHolder = false
            if useTexturedBg then
                pcall(function()
                    local tr = getTextureRenderer()
                    if not tr or not tr.drawIconHolder then return end
                    local active = imgui.IsItemActive and imgui.IsItemActive() or false
                    local state = hovered and 'hover' or (active and 'active' or 'normal')
                    if tr.drawIconHolder(dl, minX, minY, cell, state) then
                        drewHolder = true
                    end
                end)
            end
            if not drewHolder then
                local bgCol = hovered and Draw.IM_COL32(60, 70, 90, 230) or Draw.IM_COL32(28, 30, 38, 220)
                local borderCol = Draw.IM_COL32(180, 180, 200, hovered and 200 or 110)
                Draw.addRectFilled(dl, minX, minY, maxX, maxY, bgCol, rounding)
                Draw.addRect(dl, minX, minY, maxX, maxY, borderCol, rounding)
            end

            -- Wrapped, centered name text
            drawNameCentered(minX, minY, maxX, maxY, sk.name, opts.helpers or Helpers)

            -- Cooldown overlay — red translucent wash across the whole cell,
            -- with the remaining time in the bottom-right corner.
            local rem, total = probeCooldown(sk.name)
            if rem > 0 then
                Draw.addRectFilled(dl, minX, minY, maxX, maxY,
                    Draw.IM_COL32(180, 30, 30, 130), rounding)
                local txt = fmtRem(rem)
                local tw = calcTextW(txt)
                local th = imgui.GetTextLineHeight()
                drawOutlinedText(maxX - tw - 3, maxY - th - 1, txt, 1, 1, 1)
            end

            -- Tooltip on hover
            if hovered and imgui.BeginTooltip then
                imgui.BeginTooltip()
                imgui.Text(sk.name)
                imgui.TextColored(0.7, 0.7, 0.7, 1, string.format('Min Level: %d', sk.minLevel or 0))
                if rem > 0 then
                    imgui.TextColored(1, 0.85, 0.4, 1, string.format('Reuse: %s', fmtRem(rem)))
                end
                imgui.EndTooltip()
            end

            imgui.PopID()
        end
    end) end
    imgui.End()
    imgui.PopStyleVar(2)
    imgui.PopStyleColor(1)
end

return M
