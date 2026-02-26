local mq = require('mq')
local imgui = require('ImGui')
local iam = require('ImAnim')
local C = require('sidekick-next.ui.constants')
local AnimHelpers = require('sidekick-next.ui.animation_helpers')
local Core = require('sidekick-next.utils.core')
local Themes = require('sidekick-next.themes')
local Anchor = require('sidekick-next.ui.anchor')
local Draw = require('sidekick-next.ui.draw_helpers')
local Helpers = require('sidekick-next.lib.helpers')

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

local _dragKey = nil
local _pressKey = nil
local _hoverStart = {}
local TOOLTIP_DELAY = 1.0 -- seconds before showing tooltip

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

local function collectEnabledDiscs(abilities, settings)
    local out = {}
    for _, def in ipairs(abilities or {}) do
        if type(def) == 'table' and tostring(def.kind or '') == 'disc' and def.settingKey and (def.visible ~= false) then
            if settings and settings[def.settingKey] == true then
                table.insert(out, def)
            end
        end
    end
    return out
end

local function splitCsv(s)
    local out = {}
    s = tostring(s or '')
    if s == '' then return out end
    for part in s:gmatch('([^,]+)') do
        part = tostring(part):gsub('^%s+', ''):gsub('%s+$', '')
        if part ~= '' then table.insert(out, part) end
    end
    return out
end

local function joinCsv(list)
    local parts = {}
    for _, v in ipairs(list or {}) do
        v = tostring(v or ''):gsub(',', ''):gsub('^%s+', ''):gsub('%s+$', '')
        if v ~= '' then table.insert(parts, v) end
    end
    return table.concat(parts, ',')
end

local function ensureLayoutSection()
    Core.Ini['SideKick-Layout'] = Core.Ini['SideKick-Layout'] or {}
    return Core.Ini['SideKick-Layout']
end

local function loadOrder(key)
    local sec = ensureLayoutSection()
    return splitCsv(sec[key])
end

local function saveOrder(key, orderList)
    local sec = ensureLayoutSection()
    sec[key] = joinCsv(orderList)
    Core.save()
end

local function indexByValue(list)
    local idx = {}
    for i, v in ipairs(list or {}) do
        idx[tostring(v)] = i
    end
    return idx
end

local function initOrderIfMissing(allAbilities)
    local orderKey = 'DiscBarOrder'
    local orderList = loadOrder(orderKey)
    if #orderList > 0 then return orderKey, orderList, false end

    local defs = {}
    for _, def in ipairs(allAbilities or {}) do
        if type(def) == 'table' and tostring(def.kind or '') == 'disc' and def.settingKey and (def.visible ~= false) then
            table.insert(defs, def)
        end
    end

    table.sort(defs, function(a, b)
        local at = tonumber(a.timer)
        local bt = tonumber(b.timer)
        if at == nil and bt ~= nil then return false end
        if at ~= nil and bt == nil then return true end
        if at ~= nil and bt ~= nil and at ~= bt then return at < bt end

        local al = tonumber(a.level) or 0
        local bl = tonumber(b.level) or 0
        if al ~= bl then return al > bl end

        return tostring(a.discName or a.altName or '') < tostring(b.discName or b.altName or '')
    end)

    for _, def in ipairs(defs) do
        table.insert(orderList, tostring(def.settingKey))
    end

    saveOrder(orderKey, orderList)
    return orderKey, orderList, true
end

local function ensureOrderContains(orderKey, orderList, allAbilities)
    local dirty = false
    local seen = indexByValue(orderList)
    for _, def in ipairs(allAbilities or {}) do
        if type(def) == 'table' and tostring(def.kind or '') == 'disc' and def.settingKey and (def.visible ~= false) then
            local k = tostring(def.settingKey)
            if not seen[k] then
                table.insert(orderList, k)
                seen[k] = #orderList
                dirty = true
            end
        end
    end
    if dirty then saveOrder(orderKey, orderList) end
    return dirty
end

local function orderEnabled(enabled, orderList)
    local pos = indexByValue(orderList)
    table.sort(enabled, function(a, b)
        local ak = tostring(a.settingKey or '')
        local bk = tostring(b.settingKey or '')
        local ap = pos[ak]
        local bp = pos[bk]
        if ap and bp then return ap < bp end
        if ap and not bp then return true end
        if not ap and bp then return false end
        return tostring(a.discName or a.altName or '') < tostring(b.discName or b.altName or '')
    end)
end

local function swapOrder(orderKey, orderList, aKey, bKey)
    aKey = tostring(aKey or '')
    bKey = tostring(bKey or '')
    if aKey == '' or bKey == '' or aKey == bKey then return false end

    local pos = indexByValue(orderList)
    local ai = pos[aKey]
    local bi = pos[bKey]
    if not ai then
        table.insert(orderList, aKey)
        ai = #orderList
    end
    if not bi then
        table.insert(orderList, bKey)
        bi = #orderList
    end
    orderList[ai], orderList[bi] = orderList[bi], orderList[ai]
    saveOrder(orderKey, orderList)
    return true
end

-- Use shared cooldownTotalFor from Helpers
local cooldownTotalFor = Helpers.cooldownTotalFor

local function drawDescription(desc)
    desc = tostring(desc or '')
    if desc == '' then return end
    desc = desc:gsub('\\n', '\n')
    desc = desc:gsub('\r', '')
    for line in desc:gmatch('([^\n]+)') do
        imgui.TextWrapped(line)
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

function M.draw(opts)
    opts = opts or {}
    local settings = opts.settings or {}
    local enabled = collectEnabledDiscs(opts.abilities, settings)
    if #enabled == 0 then return end

    -- Initialize animation helpers
    AnimHelpers.init(ImAnim)
    AnimHelpers.updateStaggerFrame()

    local orderKey, orderList = initOrderIfMissing(opts.abilities)
    ensureOrderContains(orderKey, orderList, opts.abilities)
    orderEnabled(enabled, orderList)

    local cell = tonumber(settings.SideKickDiscBarCell) or 48
    local rows = tonumber(settings.SideKickDiscBarRows) or 2
    if rows < 1 then rows = 1 end
    local gap = tonumber(settings.SideKickDiscBarGap) or 4
    local pad = tonumber(settings.SideKickDiscBarPad) or 6
    local bgAlpha = tonumber(settings.SideKickDiscBarBgAlpha) or 0.85

    if settings.SideKickSyncThemeWithGT == true and _G.GroupTargetBounds then
        local gt = _G.GroupTargetBounds
        if tonumber(gt.transparency) then bgAlpha = bgAlpha * tonumber(gt.transparency) end
    end

    local cols = math.max(1, math.ceil(#enabled / rows))
    local autoW = cols * cell + (cols - 1) * gap + pad * 2
    local winH = rows * cell + (rows - 1) * gap + pad * 2

    -- Width override (0 = auto)
    local widthOverride = tonumber(settings.SideKickDiscBarWidth) or 0
    local winW = (widthOverride > 0) and widthOverride or autoW

    if imgui.SetNextWindowSizeConstraints then
        imgui.SetNextWindowSizeConstraints(winW, winH, winW, winH)
    end

    local anchorTarget = settings.SideKickDiscBarAnchorTarget or 'grouptarget'
    local ax, ay = Anchor.getAnchorPos(anchorTarget, settings.SideKickDiscBarAnchor, winW, winH, settings.SideKickDiscBarAnchorGap)
    if ax and ay and imgui.SetNextWindowPos then
        imgui.SetNextWindowPos(ax, ay, (ImGuiCond and ImGuiCond.Always) or 0)
    elseif imgui.SetNextWindowPos then
        imgui.SetNextWindowPos(50, 260, (ImGuiCond and ImGuiCond.FirstUseEver) or 4)
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

    local shown = imgui.Begin('SideKick Discs##SideKickDiscBar', true, flags)
    if shown then local _drawOk, _drawErr = pcall(function()
        if Anchor and Anchor.updateWindowBounds then
            Anchor.updateWindowBounds('sidekick_disc', imgui)
        end
        local animSpellIcons = opts.animSpellIcons
        local dl = imgui.GetWindowDrawList()

        -- Draw textured background for ClassicEQ Textured theme
        -- Flip horizontally when anchored to the right so borders mirror the left-side bar
        -- ShowBorder: true = gold frame + background, false = background only (no gold border)
        local showBorder = settings.SideKickDiscBarShowBorder ~= false
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
                    local anchor = tostring(settings.SideKickDiscBarAnchor or 'none'):lower()
                    local tintCol = tr.parseTintSetting and tr.parseTintSetting(settings.SideKickDiscBarTextureTint) or nil
                    if showBorder and tr.drawHotbuttonBg then
                        -- Draw with gold frame border
                        tr.drawHotbuttonBg(dl, winPosX, winPosY, winSizeX, winSizeY, {
                            rounding = 6,
                            flipH = (anchor == 'right'),
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

        for idx, def in ipairs(enabled) do
            local c = (idx - 1) % cols
            local r = math.floor((idx - 1) / cols)
            local x = startX + c * (cell + gap)
            local y = startY + r * (cell + gap)

            imgui.SetCursorPos(x, y)
            imgui.PushID(def.settingKey)

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

            if justPressed then
                _pressKey = tostring(def.settingKey or '')
            end

            local isDragging = false
            if imgui.IsMouseDragging then
                local okDrag, dragging = pcall(imgui.IsMouseDragging, 0, 4)
                if okDrag and dragging and active then
                    isDragging = true
                end
            end

            if imgui.BeginDragDropSource and imgui.EndDragDropSource then
                local ok, started = pcall(imgui.BeginDragDropSource)
                if ok and started then
                    _dragKey = tostring(def.settingKey or '')
                    isDragging = true
                    _pressKey = nil
                    if imgui.SetDragDropPayload then
                        pcall(imgui.SetDragDropPayload, 'SideKickDiscBarSwap', _dragKey)
                    end
                    imgui.Text(string.format('Move: %s', tostring(def.discName or def.altName or '')))
                    imgui.EndDragDropSource()
                end
            end

            local swapped = false
            if imgui.BeginDragDropTarget and imgui.EndDragDropTarget then
                local ok, isTarget = pcall(imgui.BeginDragDropTarget)
                if ok and isTarget then
                    local droppedKey = nil
                    if imgui.AcceptDragDropPayload then
                        local ok2, payload = pcall(imgui.AcceptDragDropPayload, 'SideKickDiscBarSwap')
                        if ok2 and payload ~= nil then
                            if type(payload) == 'string' then
                                droppedKey = payload
                            elseif type(payload) == 'table' then
                                droppedKey = payload.Data or payload.data or payload.Payload or payload.payload
                            end
                        end
                    end
                    if not droppedKey and _dragKey and imgui.IsMouseReleased and imgui.IsMouseReleased(0) then
                        droppedKey = _dragKey
                    end
                    if droppedKey and droppedKey ~= '' then
                        swapped = swapOrder(orderKey, orderList, droppedKey, def.settingKey) or false
                        _dragKey = nil
                        _pressKey = nil
                    end
                    imgui.EndDragDropTarget()
                end
            end

            -- Activate only on mouse release (prevents activation on click-and-hold for drag).
            local released = false
            if imgui.IsMouseReleased then
                local okRel, v = pcall(imgui.IsMouseReleased, 0)
                released = okRel and v == true
            end
            if released and _pressKey == tostring(def.settingKey or '') then
                if hovered and not isDragging and not swapped and opts.onActivate then
                    opts.onActivate(def)
                end
                _pressKey = nil
            end

            -- Get unique ID for animations
            local uniqueId = def.settingKey or def.discName or def.altName or tostring(idx)

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

            -- Draw textured icon holder background
            local _textureRenderer = nil
            pcall(function()
                if not useTexturedBg then return end
                local tr = getTextureRenderer()
                if not tr or not tr.drawIconHolder then return end
                local holderState = hovered and 'hover' or (active and 'active' or 'normal')
                if tr.drawIconHolder(dl, minX, minY, sw, holderState) then
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
                local nm = def.discName or def.altName
                rem, total = opts.cooldownProbe({ label = nm, key = nm })
            end

            -- Draw enhanced cooldown overlay with smooth color tween (over icon area)
            local restoreX, restoreY = imgui.GetCursorPos()
            AnimHelpers.drawCooldownOverlay(dl, iconX, iconY, iconX + iconW, iconY + iconH, rem, total, uniqueId, opts.helpers, IM_COL32, dlAddRectFilled, dlAddRect)
            imgui.SetCursorPos(restoreX, restoreY)

            -- Name overlay (over icon area)
            drawNameWrapped(iconX, iconY, iconX + iconW, def.discName or def.altName, opts.helpers)

            -- Tooltip with hover delay
            if hovered then
                if not _hoverStart[uniqueId] then
                    _hoverStart[uniqueId] = os.clock()
                end
                if (os.clock() - _hoverStart[uniqueId]) >= TOOLTIP_DELAY then
                    local fmtCooldown = getFmtCooldown(opts.helpers)
                    local nm = tostring(def.discName or def.altName or '')
                    local duration = (nm ~= '') and spellDurationSeconds(mq.TLO.Spell(nm)) or 0
                    -- Defensive tooltip: Begin/End always paired, content in pcall
                    imgui.BeginTooltip()
                    pcall(function()
                        imgui.Text(nm)
                        if def.timer ~= nil then imgui.Text(string.format('Timer: T%s', tostring(def.timer))) end
                        if def.level ~= nil then imgui.Text(string.format('Level: %s', tostring(def.level))) end
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
                        if def.description and tostring(def.description) ~= '' then
                            imgui.Separator()
                            imgui.PushTextWrapPos(imgui.GetFontSize() * 20)
                            drawDescription(def.description)
                            imgui.PopTextWrapPos()
                        end
                    end)
                    imgui.EndTooltip()
                end
            else
                _hoverStart[uniqueId] = nil
            end

            imgui.PopID()
        end
    end) if not _drawOk and mq and mq.cmd then mq.cmd('/echo \\ar[SideKick DiscBar] Render error: ' .. tostring(_drawErr) .. '\\ax') end end
    imgui.End()
    imgui.PopStyleVar(2)
    imgui.PopStyleColor(1)

    if _dragKey and imgui.IsMouseDown and not imgui.IsMouseDown(0) then
        _dragKey = nil
    end
end

return M
