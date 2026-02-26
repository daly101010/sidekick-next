local mq = require('mq')
local imgui = require('ImGui')
local iam = require('ImAnim')
local C = require('sidekick-next.ui.constants')
local Colors = require('sidekick-next.ui.colors')
local AnimHelpers = require('sidekick-next.ui.animation_helpers')
local Themes = require('sidekick-next.themes')
local Anchor = require('sidekick-next.ui.anchor')
local Draw = require('sidekick-next.ui.draw_helpers')

local Special = require('sidekick-next.utils.special_abilities')

local M = {}

-- Lazy-loaded texture renderer
local _TextureRenderer = nil
local _TextureRendererLoaded = false
local function getTextureRenderer()
    if _TextureRendererLoaded then return _TextureRenderer end
    _TextureRendererLoaded = true
    local ok, renderer = pcall(require, 'sidekick-next.ui.texture_renderer')
    if ok and renderer then
        _TextureRenderer = renderer
    end
    return _TextureRenderer
end

-- Use centralized draw helpers
local IM_COL32 = Draw.IM_COL32
local dlAddRectFilled = Draw.addRectFilled
local dlAddRect = Draw.addRect

-- Cached ease descriptor for shadow/glow animations
local _ezOutCubic = iam.EasePreset(IamEaseType.OutCubic)

local _dragKey = nil
local _hoverStart = {}
local TOOLTIP_DELAY = 1.0 -- seconds before showing tooltip

local function getButtonKey(def, idx)
    if def and def.altID ~= nil then return tostring(def.altID) end
    if def and def.altName then return tostring(def.altName) end
    return tostring(idx)
end

local function getOffsetKeys(btnKey)
    return 'SideKickSpecialBtn_' .. btnKey .. '_OffsetX', 'SideKickSpecialBtn_' .. btnKey .. '_OffsetY'
end

local function getMouseDragDelta()
    if not imgui.GetMouseDragDelta then return 0, 0 end
    local ok, a, b = pcall(imgui.GetMouseDragDelta, 0, 4)
    if not ok then return 0, 0 end
    if type(a) == 'table' then
        local dx = a.x or a[1] or 0
        local dy = a.y or a[2] or 0
        return dx, dy
    end
    if type(a) == 'number' and type(b) == 'number' then
        return a, b
    end
    return 0, 0
end

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

local function getFmtCooldown(helpers)
    if helpers and helpers.fmtCooldown then return helpers.fmtCooldown end
    return function(rem)
        rem = tonumber(rem) or 0
        rem = math.max(0, math.floor(rem + 0.5))
        if rem >= 3600 then
            local h = math.floor(rem / 3600)
            local m = math.floor(math.fmod(rem, 3600) / 60)
            local s = math.floor(math.fmod(rem, 60))
            return string.format("%d:%02d:%02d", h, m, s)
        elseif rem >= 60 then
            local m = math.floor(rem / 60)
            local s = math.floor(math.fmod(rem, 60))
            return string.format("%d:%02d", m, s)
        else
            return string.format("%ds", rem)
        end
    end
end

local function spellDurationSeconds(spell)
    if not spell then return 0 end
    local ok, exists = pcall(function() return spell() end)
    if not ok or not exists then return 0 end
    local dur = 0
    local okDur, v = pcall(function()
        return spell.Duration and spell.Duration.TotalSeconds and spell.Duration.TotalSeconds()
    end)
    if okDur then dur = tonumber(v) or 0 end
    if dur > 0 then return dur end
    okDur, v = pcall(function()
        return spell.Duration and spell.Duration()
    end)
    if okDur then dur = tonumber(v) or 0 end
    if dur > 0 and dur < 5000 and math.floor(dur) == dur then
        dur = dur * 6
    end
    return dur
end

local function abilityDurationSeconds(def)
    if not def then return 0 end
    local idOrName = def.altID or def.altName
    local aa = idOrName and mq.TLO.Me.AltAbility(idOrName) or nil
    if aa and aa() then
        local okName, spellName = pcall(function()
            if aa.Spell and aa.Spell.Name then return aa.Spell.Name() end
            return nil
        end)
        if okName and type(spellName) == 'string' and spellName ~= '' then
            return spellDurationSeconds(mq.TLO.Spell(spellName))
        end
    end
    local nm = tostring(def.altName or '')
    if nm ~= '' then
        return spellDurationSeconds(mq.TLO.Spell(nm))
    end
    return 0
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
    local forceSingleRow = settings.SideKickSpecialForceSingleRow == true
    local forceSingleColumn = settings.SideKickSpecialForceSingleColumn == true
    local total = #trained
    if forceSingleRow then
        rows = 1
    elseif forceSingleColumn then
        rows = math.max(1, total)
    end
    local perButtonMove = settings.SideKickSpecialPerButtonMove == true
    local gap = tonumber(settings.SideKickSpecialGap) or 4
    local pad = tonumber(settings.SideKickSpecialPad) or 6
    local bgAlpha = tonumber(settings.SideKickSpecialBgAlpha) or 0.85

    if settings.SideKickSyncThemeWithGT == true and _G.GroupTargetBounds then
        local gt = _G.GroupTargetBounds
        if tonumber(gt.transparency) then bgAlpha = bgAlpha * tonumber(gt.transparency) end
    end

    local cols = math.max(1, math.ceil(total / rows))
    local autoW = cols * cell + (cols - 1) * gap + pad * 2
    local winH = rows * cell + (rows - 1) * gap + pad * 2

    -- Width override (0 = auto)
    local widthOverride = tonumber(settings.SideKickSpecialWidth) or 0
    local winW = (widthOverride > 0) and widthOverride or autoW

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

    -- Check if we're using textured theme
    local useTexturedBg = false
    pcall(function()
        useTexturedBg = Themes.isTexturedTheme and Themes.isTexturedTheme(themeName)
    end)

    -- For textured themes, make window background transparent so texture shows
    if useTexturedBg then
        imgui.PushStyleColor(ImGuiCol.WindowBg, 0, 0, 0, 0)
    else
        imgui.PushStyleColor(ImGuiCol.WindowBg, style.WindowBg[1], style.WindowBg[2], style.WindowBg[3], bgAlpha)
    end
    imgui.PushStyleVar(ImGuiStyleVar.WindowRounding, 6)
    imgui.PushStyleVar(ImGuiStyleVar.WindowPadding, pad, pad)

    local shown = imgui.Begin('SideKick Specials##SideKickSpecial', true, flags)
    if shown then local _drawOk, _drawErr = pcall(function()
        if Anchor and Anchor.updateWindowBounds then
            Anchor.updateWindowBounds('sidekick_special', imgui)
        end
        local animSpellIcons = opts.animSpellIcons
        local dl = imgui.GetWindowDrawList()

        -- Draw textured background for ClassicEQ Textured theme
        -- Flip horizontally by default so border faces outward (right) when bar is on right side
        -- Only don't flip when anchored to 'right' (which puts it on left side of target)
        -- ShowBorder: true = gold frame + background, false = background only (no gold border)
        local showBorder = settings.SideKickSpecialShowBorder ~= false
        if useTexturedBg and dl then
            pcall(function()
                local tr = getTextureRenderer()
                if tr then
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
                    local anchor = tostring(settings.SideKickSpecialAnchor or 'none'):lower()
                    local tintCol = tr.parseTintSetting and tr.parseTintSetting(settings.SideKickSpecialTextureTint) or nil
                    if showBorder and tr.drawHotbuttonBg then
                        -- Draw with gold frame border - flip by default, don't flip when anchored right
                        tr.drawHotbuttonBg(dl, winPosX, winPosY, winSizeX, winSizeY, {
                            rounding = 6,
                            flipH = (anchor ~= 'right'),
                            tintCol = tintCol,
                        })
                    elseif tr.drawActionWindowBg then
                        -- Draw background only (no gold border)
                        tr.drawActionWindowBg(dl, winPosX, winPosY, winSizeX, winSizeY, {
                            tile = true,
                            shadows = false,
                            tintCol = tintCol,
                        })
                    end
                end
            end)
        end

        local startX, startY = imgui.GetCursorPos()
        for idx, def in ipairs(trained) do
            local c = (idx - 1) % cols
            local r = math.floor((idx - 1) / cols)
            local btnKey = getButtonKey(def, idx)
            local offX, offY = 0, 0
            local offKeyX, offKeyY = nil, nil
            if perButtonMove then
                offKeyX, offKeyY = getOffsetKeys(btnKey)
                offX = tonumber(settings[offKeyX]) or 0
                offY = tonumber(settings[offKeyY]) or 0
            end
            local x = startX + c * (cell + gap) + offX
            local y = startY + r * (cell + gap) + offY

            imgui.SetCursorPos(x, y)
            imgui.PushID(btnKey)

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
            elseif imgui.IsMouseClicked then
                local ok, v = pcall(imgui.IsMouseClicked, 0)
                justPressed = ok and v == true and hovered
            end

            local isDragging = false
            local dragDx, dragDy = 0, 0
            if perButtonMove then
                if justPressed then
                    _dragKey = btnKey
                end
                if imgui.IsMouseDragging then
                    local okDrag, dragging = pcall(imgui.IsMouseDragging, 0, 4)
                    if okDrag and dragging and active and _dragKey == btnKey then
                        isDragging = true
                        dragDx, dragDy = getMouseDragDelta()
                    end
                end
                if imgui.IsMouseReleased then
                    local okRel, released = pcall(imgui.IsMouseReleased, 0)
                    if okRel and released and _dragKey == btnKey then
                        local relDx, relDy = dragDx, dragDy
                        if relDx == 0 and relDy == 0 then
                            relDx, relDy = getMouseDragDelta()
                        end
                        if (relDx ~= 0 or relDy ~= 0) and offKeyX and offKeyY then
                            local newX = math.floor((offX + relDx) + 0.5)
                            local newY = math.floor((offY + relDy) + 0.5)
                            if opts.onSettingChange then
                                opts.onSettingChange(offKeyX, newX)
                                opts.onSettingChange(offKeyY, newY)
                            else
                                settings[offKeyX] = newX
                                settings[offKeyY] = newY
                            end
                        end
                        if imgui.ResetMouseDragDelta then pcall(imgui.ResetMouseDragDelta, 0) end
                        _dragKey = nil
                    end
                end
            else
                if justPressed and opts.onActivate then
                    opts.onActivate(def)
                end
            end

            -- Get unique ID for animations
            local uniqueId = def.altName or tostring(def.altID) or tostring(idx)

            -- Spring-based button scaling
            local scale = AnimHelpers.getButtonScale(uniqueId, hovered, active)

            -- Calculate scaled geometry from center
            if isDragging then
                bx = bx + dragDx
                by = by + dragDy
            end
            local minX, minY, sw, sh = AnimHelpers.scaleFromCenter(bx, by, cell, cell, scale)

            -- Get completion pulse offset
            local pulse = AnimHelpers.getCompletionPulse(uniqueId)
            minX = minX - pulse
            minY = minY - pulse
            sw = sw + pulse * 2
            sh = sh + pulse * 2

            -- Rounded button rendering: shadow, background, glow
            local btnRounding = math.floor(cell * C.LAYOUT.BUTTON_ROUNDING_PCT)
            local dt = AnimHelpers.get_dt()

            -- Drop shadow (behind everything)
            local shadowAlpha = iam.TweenFloat(
                uniqueId, imgui.GetID('shadow'),
                hovered and C.LAYOUT.SHADOW_ALPHA_HOVER or C.LAYOUT.SHADOW_ALPHA_NORMAL,
                0.15, _ezOutCubic, IamPolicy.Crossfade, dt)
            local shadowCol = IM_COL32(0, 0, 0, math.floor(shadowAlpha))
            dlAddRectFilled(dl,
                minX + C.LAYOUT.SHADOW_OFFSET_X,
                minY + C.LAYOUT.SHADOW_OFFSET_Y,
                minX + sw + C.LAYOUT.SHADOW_OFFSET_X,
                minY + sh + C.LAYOUT.SHADOW_OFFSET_Y,
                shadowCol, btnRounding)

            -- Button background
            dlAddRectFilled(dl, minX, minY, minX + sw, minY + sh,
                IM_COL32(30, 30, 30, 220), btnRounding)

            -- Glow on hover
            local glowAlpha = iam.TweenFloat(
                uniqueId, imgui.GetID('glow'),
                hovered and C.LAYOUT.GLOW_ALPHA_MAX or 0,
                0.15, _ezOutCubic, IamPolicy.Crossfade, dt)
            if glowAlpha > 1 then
                local accentColor = Colors.ready(themeName)
                local glowCol = IM_COL32(accentColor[1], accentColor[2], accentColor[3], math.floor(glowAlpha))
                local expand = C.LAYOUT.GLOW_EXPAND
                dlAddRect(dl,
                    minX - expand, minY - expand,
                    minX + sw + expand, minY + sh + expand,
                    glowCol, btnRounding + expand, 0, 2)
            end

            -- Clip to rounded rect for icon and overlays
            imgui.PushClipRect(minX, minY, minX + sw, minY + sh, true)

            -- Draw textured icon holder background
            local _textureRenderer = nil
            local _texOk, _texErr = pcall(function()
                if not Themes.isTexturedTheme then return end
                local isTextured = Themes.isTexturedTheme(themeName)
                if not isTextured then return end
                local tr = getTextureRenderer()
                if not tr then return end
                if tr.isAvailable and not tr.isAvailable() then return end
                if not dl then return end
                local holderState = hovered and 'hover' or (active and 'active' or 'normal')
                local drawResult = tr.drawIconHolder(dl, minX, minY, sw, holderState)
                if drawResult then
                    _textureRenderer = tr
                end
            end)

            -- Inscribe icon within circular button to prevent corner overflow
            local circleInset = math.floor(sw * C.LAYOUT.ICON_CIRCLE_INSET_PCT)
            local iconInset = math.max(circleInset, _textureRenderer and 4 or 0)
            local iconX = minX + iconInset
            local iconY = minY + iconInset
            local iconW = sw - (iconInset * 2)
            local iconH = sh - (iconInset * 2)

            if animSpellIcons and imgui.DrawTextureAnimation then
                animSpellIcons:SetTextureCell(tonumber(def.icon) or 0)
                imgui.SetCursorScreenPos(iconX, iconY)
                imgui.DrawTextureAnimation(animSpellIcons, iconW, iconH)
                imgui.SetCursorPos(x, y)
            end

            -- Probe cooldown
            local rem, total = 0, 0
            if opts.cooldownProbe then
                rem, total = opts.cooldownProbe({ label = def.altName, key = def.altName })
            end

            -- Draw enhanced cooldown overlay with smooth color tween (over icon area)
            local restoreX, restoreY = imgui.GetCursorPos()
            AnimHelpers.drawCooldownOverlay(dl, iconX, iconY, iconX + iconW, iconY + iconH, rem, total, uniqueId, opts.helpers, IM_COL32, dlAddRectFilled, dlAddRect)
            imgui.SetCursorPos(restoreX, restoreY)

            -- Draw textured cooldown bar at bottom of icon
            if _textureRenderer and dl and rem and rem > 0 and total and total > 0 then
                pcall(function()
                    local cdBarH = 6
                    local cdPct = (total - rem) / total
                    local cdY = iconY + iconH - cdBarH
                    _textureRenderer.drawSimpleGauge(dl, iconX, cdY, iconW, cdBarH, cdPct, 'cooldown')
                end)
            end

            -- Name overlay (over icon area)
            if opts.drawName ~= false then
                drawNameWrapped(iconX, iconY, iconX + iconW, def.altName, opts.helpers)
            end

            -- Pop rounded clip rect
            imgui.PopClipRect()

            -- Tooltip with hover delay
            if hovered then
                if not _hoverStart[uniqueId] then
                    _hoverStart[uniqueId] = os.clock()
                end
                if (os.clock() - _hoverStart[uniqueId]) >= TOOLTIP_DELAY then
                    local fmtCooldown = getFmtCooldown(opts.helpers)
                    local duration = abilityDurationSeconds(def)
                    -- Defensive tooltip: Begin/End always paired, content in pcall
                    imgui.BeginTooltip()
                    pcall(function()
                        imgui.Text(tostring(def.altName))
                        if duration and duration > 0 then
                            imgui.Text(string.format('Duration: %s', fmtCooldown(duration)))
                        end
                        if total and total > 0 then
                            imgui.Text(string.format('Reuse: %s', fmtCooldown(total)))
                            if rem and rem > 0 then
                                imgui.Text(string.format('Cooldown: %s', fmtCooldown(rem)))
                            else
                                imgui.Text('Ready')
                            end
                        end
                    end)
                    imgui.EndTooltip()
                end
            else
                _hoverStart[uniqueId] = nil
            end

            imgui.PopID()
        end
    end) if not _drawOk and mq and mq.cmd then mq.cmd('/echo \\ar[SideKick SpecialBar] Render error: ' .. tostring(_drawErr) .. '\\ax') end end
    imgui.End()
    imgui.PopStyleVar(2)
    imgui.PopStyleColor(1)
end

return M
