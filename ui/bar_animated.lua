local mq = require('mq')
local imgui = require('ImGui')
local iam = require('ImAnim')
local C = require('sidekick-next.ui.constants')
local Colors = require('sidekick-next.ui.colors')
local AnimHelpers = require('sidekick-next.ui.animation_helpers')
local Core = require('sidekick-next.utils.core')
local Themes = require('sidekick-next.themes')
local Anchor = require('sidekick-next.ui.anchor')
local Draw = require('sidekick-next.ui.draw_helpers')
local Helpers = require('sidekick-next.lib.helpers')
local SpecialAbilities = require('sidekick-next.utils.special_abilities')
local ContextMenu = require('sidekick-next.ui.components.animated_context_menu')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

-- Lazy-loaded texture renderer
local getTextureRenderer = lazy.once('sidekick-next.ui.texture_renderer')

local _dragKey = nil
local _pressKey = nil
local _hoverStart = {}
local TOOLTIP_DELAY = 1.0 -- seconds before showing tooltip

-- Use centralized draw helpers
local IM_COL32 = Draw.IM_COL32
local dlAddRectFilled = Draw.addRectFilled
local dlAddRect = Draw.addRect

-- Cached ease descriptor for shadow/glow animations
local _ezOutCubic = iam.EasePreset(IamEaseType.OutCubic)

local function getGroupTargetBounds()
    if Anchor and Anchor.getTargetBounds then
        return Anchor.getTargetBounds('grouptarget')
    end
    local gt = _G.GroupTargetBounds
    if not gt or not gt.loaded then return nil end
    if gt.timestamp and (os.clock() - gt.timestamp) > 5.0 then return nil end
    return gt
end

local function collectEnabledAbilities(abilities, settings)
    local excludedById = SpecialAbilities.excludedAltIDs()
    local excludedByName = SpecialAbilities.excludedNames()
    local out = {}
    for _, def in ipairs(abilities or {}) do
        if type(def) == 'table' and def.settingKey and def.altName and (def.visible ~= false) then
            local altId = def.altID and tonumber(def.altID) or nil
            local altName = def.altName and tostring(def.altName):lower() or nil
            if (altId and excludedById[altId]) or (altName and excludedByName[altName]) then
                goto continue
            end
            if settings and settings[def.settingKey] == true then
                table.insert(out, def)
            end
        end
        ::continue::
    end
    return out
end

-- Use shared cooldownTotalFor from Helpers
local cooldownTotalFor = Helpers.cooldownTotalFor

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

local function initOrderIfMissing(allAbilities, cooldownProbe)
    local orderKey = 'BarOrder'
    local orderList = loadOrder(orderKey)
    if #orderList > 0 then return orderKey, orderList, false end

    local defs = {}
    for _, def in ipairs(allAbilities or {}) do
        if type(def) == 'table' and def.settingKey and def.altName and (def.visible ~= false) then
            table.insert(defs, def)
        end
    end

    table.sort(defs, function(a, b)
        local at = cooldownTotalFor(a, cooldownProbe)
        local bt = cooldownTotalFor(b, cooldownProbe)
        if at == nil and bt ~= nil then return false end
        if at ~= nil and bt == nil then return true end
        if at ~= nil and bt ~= nil and at ~= bt then return at < bt end
        return tostring(a.altName or '') < tostring(b.altName or '')
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
        if type(def) == 'table' and def.settingKey and def.altName and (def.visible ~= false) then
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
        return tostring(a.altName or '') < tostring(b.altName or '')
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

local function abilityDurationSeconds(def)
    if not def then return 0 end

    local kind = tostring(def.kind or 'aa')
    if kind == 'disc' then
        local nm = tostring(def.discName or def.altName or '')
        if nm == '' then return 0 end
        return spellDurationSeconds(mq.TLO.Spell(nm))
    end

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

        local okId, spellId = pcall(function()
            return aa.SpellID and aa.SpellID()
        end)
        spellId = tonumber(spellId) or 0
        if okId and spellId > 0 then
            return spellDurationSeconds(mq.TLO.Spell(spellId))
        end
    end

    local nm = tostring(def.altName or '')
    if nm ~= '' then
        return spellDurationSeconds(mq.TLO.Spell(nm))
    end
    return 0
end

local function buildModeMenu(def, settings, opts)
    if not def.modeKey then return nil end
    local currentMode = tonumber(settings[def.modeKey]) or 1
    local items = {}

    -- Header (disabled, just for context)
    table.insert(items, { label = tostring(def.altName or 'Ability'), disabled = true })
    table.insert(items, { separator = true })

    -- Mode options: 1=On Demand, 2=On Condition, 3=On Cooldown
    local modes = { { value = 1, label = 'On Demand' }, { value = 2, label = 'On Condition' }, { value = 3, label = 'On Cooldown' } }
    if opts.modeLabels then
        for _, m in ipairs(modes) do
            m.label = opts.modeLabels[m.value] or m.label
        end
    end

    for _, m in ipairs(modes) do
        local check = (currentMode == m.value) and '> ' or '   '
        table.insert(items, {
            label = check .. m.label,
            action = function()
                if opts.onMode then opts.onMode(def.modeKey, m.value) end
                if m.value == 2 and opts.onOpenSettings then opts.onOpenSettings() end
            end,
        })
    end

    return items
end

function M.draw(opts)
    opts = opts or {}
    local settings = opts.settings or {}
    local enabled = collectEnabledAbilities(opts.abilities, settings)
    if #enabled == 0 then return end

    -- Initialize animation helpers
    AnimHelpers.init(ImAnim)
    AnimHelpers.updateStaggerFrame()

    local orderKey, orderList = initOrderIfMissing(opts.abilities, opts.cooldownProbe)
    ensureOrderContains(orderKey, orderList, opts.abilities)
    orderEnabled(enabled, orderList)

    local cell = tonumber(settings.SideKickBarCell) or 48
    local rows = tonumber(settings.SideKickBarRows) or 2
    if rows < 1 then rows = 1 end
    local gap = tonumber(settings.SideKickBarGap) or 4
    local pad = tonumber(settings.SideKickBarPad) or 6
    local bgAlpha = tonumber(settings.SideKickBarBgAlpha) or 0.85
    local rounding = 6

    if settings.SideKickSyncThemeWithGT == true and _G.GroupTargetBounds then
        local gt = _G.GroupTargetBounds
        if tonumber(gt.windowRounding) then
            rounding = tonumber(gt.windowRounding)
        end
        if tonumber(gt.transparency) then
            bgAlpha = bgAlpha * tonumber(gt.transparency)
        end
    end

    local cols = math.max(1, math.ceil(#enabled / rows))
    local autoW = cols * cell + (cols - 1) * gap + pad * 2
    local winH = rows * cell + (rows - 1) * gap + pad * 2

    -- Width override (0 = auto)
    local widthOverride = tonumber(settings.SideKickBarWidth) or 0
    local winW = (widthOverride > 0) and widthOverride or autoW

    if imgui.SetNextWindowSizeConstraints then
        imgui.SetNextWindowSizeConstraints(winW, winH, winW, winH)
    end

    local anchorTarget = settings.SideKickBarAnchorTarget or 'grouptarget'
    local ax, ay = Anchor.getAnchorPos(anchorTarget, settings.SideKickBarAnchor, winW, winH, settings.SideKickBarAnchorGap)
    if ax and ay and imgui.SetNextWindowPos then
        imgui.SetNextWindowPos(ax, ay, (ImGuiCond and ImGuiCond.Always) or 0)
    elseif imgui.SetNextWindowPos then
        imgui.SetNextWindowPos(50, 200, (ImGuiCond and ImGuiCond.FirstUseEver) or 4)
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
    imgui.PushStyleVar(ImGuiStyleVar.WindowRounding, rounding)
    imgui.PushStyleVar(ImGuiStyleVar.WindowPadding, pad, pad)

    local open, shown = imgui.Begin('SideKick Abilities##SideKickBar', true, flags)
    if shown == nil then shown = open end
    if shown then local _drawOk, _drawErr = pcall(function()
        if Anchor and Anchor.updateWindowBounds then
            Anchor.updateWindowBounds('sidekick_bar', imgui)
        end
        local animSpellIcons = opts.animSpellIcons
        local dl = imgui.GetWindowDrawList()

        -- Draw textured background for ClassicEQ Textured theme
        -- Flip horizontally when anchored to the right so borders mirror the left-side bar
        -- ShowBorder: true = gold frame + background, false = background only (no gold border)
        local showBorder = settings.SideKickBarShowBorder ~= false
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
                    local anchor = tostring(settings.SideKickBarAnchor or 'none'):lower()
                    local tintCol = tr.parseTintSetting and tr.parseTintSetting(settings.SideKickBarTextureTint) or nil
                    if showBorder and tr.drawHotbuttonBg then
                        -- Draw with gold frame border
                        tr.drawHotbuttonBg(dl, winPosX, winPosY, winSizeX, winSizeY, {
                            rounding = rounding,
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
            local clipPushed = false
            local cellOk, cellErr = pcall(function()
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
                            pcall(imgui.SetDragDropPayload, 'SideKickBarSwap', _dragKey)
                        end
                        imgui.Text(string.format('Move: %s', tostring(def.altName or '')))
                        imgui.EndDragDropSource()
                    end
                end

                local swapped = false
                if imgui.BeginDragDropTarget and imgui.EndDragDropTarget then
                    local ok, isTarget = pcall(imgui.BeginDragDropTarget)
                    if ok and isTarget then
                        local droppedKey = nil
                        if imgui.AcceptDragDropPayload then
                            local ok2, payload = pcall(imgui.AcceptDragDropPayload, 'SideKickBarSwap')
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

                -- Right-click opens mode context menu
                local rightReleased = false
                pcall(function() rightReleased = imgui.IsMouseReleased(1) end)
                if hovered and rightReleased and not isDragging and def.modeKey then
                    local uniqueCtx = def.settingKey or def.altName or tostring(idx)
                    local menuDef = buildModeMenu(def, settings, opts)
                    if menuDef then
                        ContextMenu.open(menuDef, bx, by, 'sk_mode_' .. uniqueCtx)
                    end
                end

                -- Get unique ID for animations
                local uniqueId = def.settingKey or def.altName or tostring(idx)

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

                -- Rounded button rendering: shadow, background, glow
                local rounding = math.floor(cell * C.LAYOUT.BUTTON_ROUNDING_PCT)
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
                    shadowCol, rounding)

                -- Button background
                dlAddRectFilled(dl, minX, minY, minX + sw, minY + sh,
                    IM_COL32(30, 30, 30, 220), rounding)

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
                        glowCol, rounding + expand, 0, 2)
                end

                -- Clip to rounded rect for icon and overlays
                imgui.PushClipRect(minX, minY, minX + sw, minY + sh, true)
                clipPushed = true

                -- Draw textured icon holder background (completely isolated)
                local _textureRenderer = nil
                pcall(function()
                    if not Themes.isTexturedTheme then
                        -- Missing function
                        return
                    end
                    local isTextured = Themes.isTexturedTheme(themeName)
                    if not isTextured then
                        -- Not a textured theme
                        return
                    end
                    local tr = getTextureRenderer()
                    if not tr then
                        return
                    end
                    if tr.isAvailable and not tr.isAvailable() then
                        return
                    end
                    if not dl then
                        return
                    end

                    local holderState = hovered and 'hover' or (active and 'active' or 'normal')
                    local drawResult = tr.drawIconHolder(dl, minX, minY, sw, holderState)
                    if drawResult then
                        _textureRenderer = tr  -- Save for cooldown bar below
                    end
                end)

                -- Draw icon at scaled position
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
                else
                    imgui.SetCursorScreenPos(iconX + 4, iconY + 4)
                    imgui.Text('AA')
                    imgui.SetCursorPos(x, y)
                end

                -- Probe cooldown
                local rem, total = 0, 0
                if opts.cooldownProbe then
                    rem, total = opts.cooldownProbe({ label = def.altName, key = def.altName })
                end

                -- Draw enhanced cooldown overlay with smooth color tween (over icon area, not frame)
                local restoreX, restoreY = imgui.GetCursorPos()
                AnimHelpers.drawCooldownOverlay(dl, iconX, iconY, iconX + iconW, iconY + iconH, rem, total, uniqueId, opts.helpers, IM_COL32, dlAddRectFilled, dlAddRect)
                imgui.SetCursorPos(restoreX, restoreY)

                -- Draw textured cooldown bar at bottom of icon (optional)
                if _textureRenderer and dl and rem and rem > 0 and total and total > 0 then
                    pcall(function()
                        local cdBarH = 6
                        local cdPct = (total - rem) / total  -- Fill as cooldown completes
                        local cdY = iconY + iconH - cdBarH
                        _textureRenderer.drawSimpleGauge(dl, iconX, cdY, iconW, cdBarH, cdPct, 'cooldown')
                    end)
                end

                -- Name overlay (over icon area)
                drawNameWrapped(iconX, iconY, iconX + iconW, def.altName, opts.helpers)

                -- Pop rounded clip rect
                imgui.PopClipRect()
                clipPushed = false

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
                            -- Show current automation mode
                            if def.modeKey then
                                local mode = tonumber(settings[def.modeKey]) or 1
                                local modeLabel = opts.modeLabels and opts.modeLabels[mode] or 'On Demand'
                                imgui.TextColored(0.6, 0.8, 1.0, 1.0, 'Mode: ' .. modeLabel)
                            end
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
            end)
            if clipPushed then
                pcall(imgui.PopClipRect)
            end
            imgui.PopID()
            if not cellOk and mq and mq.cmd then
                mq.cmd('/echo \\ar[SideKick Bar] Cell error [' .. tostring(def.altName or def.settingKey or idx) .. ']: ' .. tostring(cellErr) .. '\\ax')
            end
        end
    end) if not _drawOk and mq and mq.cmd then mq.cmd('/echo \\ar[SideKick Bar] Render error: ' .. tostring(_drawErr) .. '\\ax') end end
    imgui.End()
    imgui.PopStyleVar(2)
    imgui.PopStyleColor(1)

    -- Draw context menu above all windows (uses foreground draw list)
    if ContextMenu.isOpen() then
        ContextMenu.draw()
    end

    if _dragKey and imgui.IsMouseDown and not imgui.IsMouseDown(0) then
        _dragKey = nil
    end
    if _pressKey and imgui.IsMouseDown and not imgui.IsMouseDown(0) then
        _pressKey = nil
    end
end

return M
