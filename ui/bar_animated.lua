local mq = require('mq')
local imgui = require('ImGui')
local ImAnim = require('sidekick-next.lib.imanim')
local AnimHelpers = require('sidekick-next.ui.animation_helpers')
local Core = require('sidekick-next.utils.core')
local Themes = require('sidekick-next.themes')
local Anchor = require('sidekick-next.ui.anchor')
local Draw = require('sidekick-next.ui.draw_helpers')
local Helpers = require('sidekick-next.lib.helpers')

local M = {}

local _dragKey = nil
local _pressKey = nil

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

local function collectEnabledAbilities(abilities, settings)
    local out = {}
    for _, def in ipairs(abilities or {}) do
        if type(def) == 'table' and def.settingKey and def.altName and (def.visible ~= false) then
            if settings and settings[def.settingKey] == true then
                table.insert(out, def)
            end
        end
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
    local winW = cols * cell + (cols - 1) * gap + pad * 2
    local winH = rows * cell + (rows - 1) * gap + pad * 2

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
    imgui.PushStyleColor(ImGuiCol.WindowBg, style.WindowBg[1], style.WindowBg[2], style.WindowBg[3], bgAlpha)
    imgui.PushStyleVar(ImGuiStyleVar.WindowRounding, rounding)
    imgui.PushStyleVar(ImGuiStyleVar.WindowPadding, pad, pad)

    local shown = imgui.Begin('SideKick Abilities##SideKickBar', true, flags)
    if shown then
        if Anchor and Anchor.updateWindowBounds then
            Anchor.updateWindowBounds('sidekick_bar', imgui)
        end
        local animSpellIcons = opts.animSpellIcons
        local dl = imgui.GetWindowDrawList()

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

            -- Draw icon at scaled position
            if animSpellIcons and imgui.DrawTextureAnimation then
                animSpellIcons:SetTextureCell(tonumber(def.icon) or 0)
                imgui.SetCursorScreenPos(minX, minY)
                imgui.DrawTextureAnimation(animSpellIcons, sw, sh)
                imgui.SetCursorPos(x, y)
            else
                imgui.SetCursorScreenPos(minX + 4, minY + 4)
                imgui.Text('AA')
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
            drawNameWrapped(minX, minY, minX + sw, def.altName, opts.helpers)

            if hovered then
                local fmtCooldown = getFmtCooldown(opts.helpers)
                local duration = abilityDurationSeconds(def)
                imgui.BeginTooltip()
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
                if def.description and tostring(def.description) ~= '' then
                    imgui.Separator()
                    drawDescription(def.description)
                end
                imgui.EndTooltip()
            end

            imgui.PopID()
        end
    end
    imgui.End()
    imgui.PopStyleVar(2)
    imgui.PopStyleColor(1)

    if _dragKey and imgui.IsMouseDown and not imgui.IsMouseDown(0) then
        _dragKey = nil
    end
    if _pressKey and imgui.IsMouseDown and not imgui.IsMouseDown(0) then
        _pressKey = nil
    end
end

return M
