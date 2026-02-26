-- Animated DrawList-rendered context menu with fade+slide animation.
-- Renders to FOREGROUND draw list so the menu is not clipped to window bounds.
-- Uses os.clock()-based tweens (ImAnim.TweenFloat returns 0 in some MQ builds).
-- Uses Draw helper wrappers for ImVec2-compatible drawlist calls.

local imgui = require('ImGui')
local Draw = require('sidekick-next.ui.draw_helpers')

local IM_COL32 = Draw.IM_COL32
local dlAddRectFilled = Draw.addRectFilled
local dlAddRect = Draw.addRect
local dlAddLine = Draw.addLine
local dlAddText = Draw.addText

local M = {}

-- Simple time-based tween state
local _tweens = {}

local function easeOutCubic(t)
    local inv = 1 - t
    return 1 - inv * inv * inv
end

local function simpleTween(key, target, duration, initValue)
    local now = os.clock()
    local tw = _tweens[key]
    if not tw then
        tw = {
            value = (initValue ~= nil) and initValue or target,
            target = target,
            startTime = now,
            startValue = (initValue ~= nil) and initValue or target,
            duration = duration,
        }
        _tweens[key] = tw
    end
    if tw.target ~= target then
        tw.startValue = tw.value
        tw.target = target
        tw.startTime = now
        tw.duration = duration
    end
    local elapsed = now - tw.startTime
    if elapsed >= tw.duration then
        tw.value = tw.target
    else
        local t = elapsed / tw.duration
        tw.value = tw.startValue + (tw.target - tw.startValue) * easeOutCubic(t)
    end
    return tw.value
end

local function resetTweens()
    _tweens = {}
end

-- Singleton state (only one menu open at a time)
local _state = {
    visible = false,
    menuDef = nil,
    posX = 0,
    posY = 0,
    uniqueId = '',
    openTime = 0,
    -- Sub-panel
    subVisible = false,
    subMenuDef = nil,
    subParentIdx = 0,
    subPosX = 0,
    subPosY = 0,
    subOpenTime = 0,
    -- Rendering config
    itemHeight = 24,
    paddingX = 10,
    paddingY = 6,
    minWidth = 130,
    rounding = 6,
    separatorHeight = 9,
}

function M.open(menuDef, mouseX, mouseY, uniqueId)
    resetTweens()
    _state.visible = true
    _state.menuDef = menuDef or {}
    _state.posX = mouseX or 0
    _state.posY = mouseY or 0
    _state.uniqueId = uniqueId or 'ctx'
    _state.openTime = os.clock()
    _state.subVisible = false
    _state.subMenuDef = nil
    _state.subParentIdx = 0
end

function M.close()
    _state.visible = false
    _state.subVisible = false
    _state.menuDef = nil
    _state.subMenuDef = nil
end

function M.isOpen()
    return _state.visible
end

local function isMouseInRect(x1, y1, x2, y2)
    local ok, result = pcall(imgui.IsMouseHoveringRect, x1, y1, x2, y2, false)
    if ok then return result end
    return false
end

local function calcMenuSize(menuDef)
    local maxW = _state.minWidth
    for _, item in ipairs(menuDef) do
        if not item.separator then
            local tw = 0
            pcall(function()
                local a, b = imgui.CalcTextSize(item.label or '')
                if type(a) == 'number' then tw = a
                elseif type(a) == 'table' or type(a) == 'userdata' then tw = a.x or a[1] or 0
                end
            end)
            local itemW = tw + _state.paddingX * 2
            if item.submenu then itemW = itemW + _state.paddingX + 8 end
            if itemW > maxW then maxW = itemW end
        end
    end
    local totalH = _state.paddingY * 2
    for _, item in ipairs(menuDef) do
        if item.separator then
            totalH = totalH + _state.separatorHeight
        else
            totalH = totalH + _state.itemHeight
        end
    end
    return maxW, totalH
end

local function clampToViewport(x, y, w, h)
    local vpW, vpH = 0, 0
    pcall(function()
        local vp = imgui.GetMainViewport()
        if vp then
            local sz = vp.Size or vp:GetSize()
            if type(sz) == 'table' or type(sz) == 'userdata' then
                vpW, vpH = sz.x or sz[1] or 1920, sz.y or sz[2] or 1080
            else
                vpW, vpH = 1920, 1080
            end
        end
    end)
    if vpW == 0 then vpW = 1920 end
    if vpH == 0 then vpH = 1080 end
    if x + w > vpW then x = vpW - w - 4 end
    if y + h > vpH then y = vpH - h - 4 end
    if x < 0 then x = 4 end
    if y < 0 then y = 4 end
    return x, y
end

function M.draw()
    if not _state.visible or not _state.menuDef then return end

    local dl = imgui.GetForegroundDrawList and imgui.GetForegroundDrawList()
    if not dl then return end

    local menuDef = _state.menuDef
    local menuW, menuH = calcMenuSize(menuDef)

    local animAlpha = simpleTween('menu_alpha', 1.0, 0.2, 0.0)
    local animSlide = simpleTween('menu_slide', 0.0, 0.2, 8.0)

    local alpha = math.max(0, math.min(1, animAlpha))
    if alpha < 0.01 then return end

    local mx, my = clampToViewport(_state.posX, _state.posY + animSlide, menuW, menuH)

    local mouseInMenu = isMouseInRect(mx, my, mx + menuW, my + menuH)

    local leftClicked = false
    pcall(function() leftClicked = imgui.IsMouseClicked(0) end)

    -- Background
    local bgA = math.floor(240 * alpha)
    dlAddRectFilled(dl, mx, my, mx + menuW, my + menuH, IM_COL32(45, 50, 60, bgA), _state.rounding)
    dlAddRect(dl, mx, my, mx + menuW, my + menuH, IM_COL32(70, 75, 85, math.floor(200 * alpha)), _state.rounding, 0, 1)

    -- Draw items
    local curY = my + _state.paddingY
    local clickedAction = nil
    local clickedSubmenu = nil
    local clickedSubIdx = 0
    local anyItemClicked = false

    for idx, item in ipairs(menuDef) do
        if item.separator then
            local sepY = curY + _state.separatorHeight * 0.5
            dlAddLine(dl, mx + 8, sepY, mx + menuW - 8, sepY, IM_COL32(80, 85, 95, math.floor(180 * alpha)), 1)
            curY = curY + _state.separatorHeight
        else
            local itemY = curY
            local itemH = _state.itemHeight

            local hovered = isMouseInRect(mx, itemY, mx + menuW, itemY + itemH)
            local clicked = hovered and leftClicked

            -- Hover highlight
            local hoverAlpha = simpleTween('hover_' .. idx,
                hovered and 1.0 or 0.0, 0.1, 0.0)
            if hoverAlpha > 0.01 then
                dlAddRectFilled(dl, mx + 3, itemY, mx + menuW - 3, itemY + itemH,
                    IM_COL32(70, 130, 180, math.floor(80 * hoverAlpha * alpha)), 4)
            end

            -- Text
            local textA = math.floor(255 * alpha)
            local tw, th = 0, 0
            pcall(function()
                local a, b = imgui.CalcTextSize(item.label or '')
                if type(a) == 'number' then tw, th = a, b
                elseif type(a) == 'table' or type(a) == 'userdata' then tw, th = a.x or a[1] or 0, a.y or a[2] or 0
                end
            end)
            if th < 1 then th = itemH * 0.6 end

            -- Dimmed text for disabled/header items
            local textColor = item.disabled
                and IM_COL32(140, 140, 150, textA)
                or IM_COL32(220, 220, 230, textA)
            dlAddText(dl, mx + _state.paddingX, itemY + (itemH - th) * 0.5, textColor, item.label or '')

            -- Submenu arrow
            if item.submenu then
                dlAddText(dl, mx + menuW - _state.paddingX - 8, itemY + (itemH - th) * 0.5,
                    IM_COL32(160, 160, 170, math.floor(200 * alpha)), '>')
            end

            -- Close sub-panel when hovering a different parent item
            if hovered and _state.subVisible and _state.subParentIdx ~= idx then
                _state.subVisible = false
                _state.subMenuDef = nil
            end

            -- Click handling (skip disabled items)
            if clicked and not item.disabled then
                anyItemClicked = true
                if item.submenu then
                    clickedSubmenu = item.submenu
                    clickedSubIdx = idx
                elseif item.action then
                    clickedAction = item.action
                end
            end

            curY = curY + itemH
        end
    end

    -- Open sub-panel if submenu clicked
    if clickedSubmenu then
        _state.subVisible = true
        _state.subMenuDef = clickedSubmenu
        _state.subParentIdx = clickedSubIdx
        _state.subOpenTime = os.clock()
        _tweens['sub_alpha'] = nil
        _tweens['sub_slideX'] = nil
        _state.subPosX = mx + menuW + 2
        local parentItemY = my + _state.paddingY
        for si = 1, clickedSubIdx - 1 do
            if menuDef[si] and menuDef[si].separator then
                parentItemY = parentItemY + _state.separatorHeight
            else
                parentItemY = parentItemY + _state.itemHeight
            end
        end
        _state.subPosY = parentItemY
    end

    -- Draw sub-panel
    if _state.subVisible and _state.subMenuDef then
        local subW, subH = calcMenuSize(_state.subMenuDef)
        local subX, subY = _state.subPosX, _state.subPosY
        local vpW = 1920
        pcall(function()
            local vp = imgui.GetMainViewport()
            if vp then
                local sz = vp.Size or vp:GetSize()
                if type(sz) == 'table' or type(sz) == 'userdata' then
                    vpW = sz.x or sz[1] or 1920
                end
            end
        end)
        if subX + subW > vpW then
            subX = mx - subW - 2
        end

        local subAlpha = simpleTween('sub_alpha', 1.0, 0.18, 0.0)
        local subSlideX = simpleTween('sub_slideX', 0.0, 0.18, -8.0)

        local sa = math.max(0, math.min(1, subAlpha)) * alpha
        subX = subX + subSlideX
        subX, subY = clampToViewport(subX, subY, subW, subH)

        if sa > 0.01 then
            mouseInMenu = mouseInMenu or isMouseInRect(subX, subY, subX + subW, subY + subH)

            dlAddRectFilled(dl, subX, subY, subX + subW, subY + subH,
                IM_COL32(45, 50, 60, math.floor(240 * sa)), _state.rounding)
            dlAddRect(dl, subX, subY, subX + subW, subY + subH,
                IM_COL32(70, 75, 85, math.floor(200 * sa)), _state.rounding, 0, 1)

            local subCurY = subY + _state.paddingY
            for subIdx, subItem in ipairs(_state.subMenuDef) do
                if subItem.separator then
                    local sepY = subCurY + _state.separatorHeight * 0.5
                    dlAddLine(dl, subX + 8, sepY, subX + subW - 8, sepY,
                        IM_COL32(80, 85, 95, math.floor(180 * sa)), 1)
                    subCurY = subCurY + _state.separatorHeight
                else
                    local sItemY = subCurY
                    local sItemH = _state.itemHeight

                    local sHovered = isMouseInRect(subX, sItemY, subX + subW, sItemY + sItemH)
                    local sClicked = sHovered and leftClicked

                    local sHoverA = simpleTween('subhover_' .. subIdx,
                        sHovered and 1.0 or 0.0, 0.1, 0.0)
                    if sHoverA > 0.01 then
                        dlAddRectFilled(dl, subX + 3, sItemY, subX + subW - 3, sItemY + sItemH,
                            IM_COL32(70, 130, 180, math.floor(80 * sHoverA * sa)), 4)
                    end

                    local sTw, sTh = 0, 0
                    pcall(function()
                        local a, b = imgui.CalcTextSize(subItem.label or '')
                        if type(a) == 'number' then sTw, sTh = a, b
                        elseif type(a) == 'table' or type(a) == 'userdata' then
                            sTw, sTh = a.x or a[1] or 0, a.y or a[2] or 0
                        end
                    end)
                    if sTh < 1 then sTh = sItemH * 0.6 end
                    dlAddText(dl, subX + _state.paddingX, sItemY + (sItemH - sTh) * 0.5,
                        IM_COL32(220, 220, 230, math.floor(255 * sa)), subItem.label or '')

                    if sClicked and subItem.action then
                        anyItemClicked = true
                        clickedAction = subItem.action
                    end

                    subCurY = subCurY + sItemH
                end
            end
        end
    end

    -- Execute action AFTER rendering
    if clickedAction then
        local fn = clickedAction
        M.close()
        pcall(fn)
        return
    end

    -- Grace period: ignore dismiss events for 200ms after opening
    local age = os.clock() - _state.openTime
    if age > 0.2 then
        if not anyItemClicked and leftClicked and not mouseInMenu then
            M.close()
        end
        local rightReleased = false
        pcall(function() rightReleased = imgui.IsMouseReleased(1) end)
        if rightReleased and _state.visible then
            M.close()
        end
        if ImGuiKey and ImGuiKey.Escape then
            local ok, pressed = pcall(imgui.IsKeyPressed, ImGuiKey.Escape)
            if ok and pressed then
                M.close()
            end
        end
    end
end

return M
