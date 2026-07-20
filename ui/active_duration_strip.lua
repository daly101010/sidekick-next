-- =========================================================================
-- ui/active_duration_strip.lua
-- Active discipline countdown strip drawn at the top of the disc bar.
-- Click-driven: utils/abilities.lua registers a name+duration when a disc
-- is fired; we count down locally. One active at a time.
-- Mirrors the in-game Combat Abilities "No Effect" header strip.
-- =========================================================================

local mq = require('mq')
local imgui = require('ImGui')
local Draw = require('sidekick-next.ui.draw_helpers')

local STOP_BTN_W = 20
local STOP_BTN_GAP = 6
local STOP_BTN_RIGHT_MARGIN = 2

local M = {}

local _active = nil  -- { name, duration, startMs }

local function nowMs()
    if mq and mq.gettime then return mq.gettime() end
    return os.clock() * 1000
end

--- Register a newly-activated discipline. Replaces any existing active timer.
--- @param name string Discipline display name.
--- @param durationS number Duration in seconds (must be > 0 to register).
function M.register(name, durationS)
    name = tostring(name or '')
    durationS = tonumber(durationS) or 0
    if name == '' or durationS <= 0 then return end
    _active = { name = name, duration = durationS, startMs = nowMs() }
end

--- Get the currently active timer, auto-clearing if expired.
--- @return string|nil name
--- @return number remainingSeconds
--- @return number totalSeconds
function M.getActive()
    if not _active then return nil, 0, 0 end
    local elapsed = (nowMs() - _active.startMs) / 1000
    local remaining = _active.duration - elapsed
    if remaining <= 0 then
        _active = nil
        return nil, 0, 0
    end
    return _active.name, remaining, _active.duration
end

function M.clear() _active = nil end

-- Pixel height the strip will consume when drawn (label line + bar + spacing).
M.HEIGHT = 28

local LABEL_H = 14
local BAR_H = 8
local SEGMENTS = 20
local SEG_GAP = 1

local function getCursorScreenPos()
    local px, py = imgui.GetCursorScreenPos()
    if type(px) == 'table' then
        return px.x or px[1], px.y or px[2]
    end
    return px, py
end

local function calcTextWidth(s)
    local size = imgui.CalcTextSize(s)
    if type(size) == 'table' then return size.x or size[1] or 0 end
    return tonumber(size) or 0
end

--- Draw the strip at the current ImGui cursor.
--- Advances the cursor by M.HEIGHT via imgui.Dummy.
--- @param width number Strip pixel width.
--- @return number consumedHeight
function M.draw(width)
    width = tonumber(width) or 0
    if width <= 0 then return 0 end

    local name, rem, total = M.getActive()
    local label = name and string.format('%s  %ds', name, math.ceil(rem)) or 'No Effect'
    local pct = (name and total > 0) and math.max(0, math.min(1, rem / total)) or 0

    local px, py = getCursorScreenPos()
    local dl = imgui.GetWindowDrawList()

    -- Label (centered)
    local tw = calcTextWidth(label)
    local tx = px + (width - tw) * 0.5
    if tx < px then tx = px end
    imgui.SetCursorScreenPos(tx, py)
    if name then
        imgui.TextColored(1.0, 0.92, 0.55, 1.0, label)  -- soft gold while active
    else
        imgui.TextColored(0.65, 0.65, 0.65, 1.0, label) -- muted while idle
    end

    -- Bar geometry — reserve right side for the Stop button + a small right margin
    -- so the button doesn't get clipped by the window edge.
    local rightReserve = STOP_BTN_W + STOP_BTN_GAP + STOP_BTN_RIGHT_MARGIN
    local barWidth = width - rightReserve
    if barWidth < 1 then barWidth = width end
    local by = py + LABEL_H + 2
    local bx1, bx2 = px, px + barWidth
    local by2 = by + BAR_H

    -- Bar background
    Draw.addRectFilled(dl, bx1, by, bx2, by2, Draw.IM_COL32(0, 0, 0, 200), 2)
    Draw.addRect(dl, bx1, by, bx2, by2, Draw.IM_COL32(255, 255, 255, 60), 2)

    -- Segmented fill — green (>66%) → yellow (>33%) → red (<=33%) by remaining pct.
    if pct > 0 then
        local r, g, b
        if pct > 0.66 then
            local t = (pct - 0.66) / (1.0 - 0.66)
            t = math.max(0, math.min(1, t))
            r = math.floor(240 * (1 - t) + 80 * t)
            g = math.floor(200 * (1 - t) + 200 * t)
            b = math.floor(70 * (1 - t) + 80 * t)
        elseif pct > 0.33 then
            local t = (pct - 0.33) / (0.66 - 0.33)
            t = math.max(0, math.min(1, t))
            r = math.floor(220 * (1 - t) + 240 * t)
            g = math.floor(150 * (1 - t) + 200 * t)
            b = math.floor(60 * (1 - t) + 70 * t)
        else
            r, g, b = 220, 70, 60
        end
        local fillCol = Draw.IM_COL32(r, g, b, 230)

        local innerW = barWidth - 4
        if innerW > 0 then
            local segW = (innerW - (SEGMENTS - 1) * SEG_GAP) / SEGMENTS
            if segW > 0 then
                local filled = pct * SEGMENTS
                for i = 1, SEGMENTS do
                    local fill = math.max(0, math.min(1, filled - (i - 1)))
                    if fill > 0 then
                        local sx1 = bx1 + 2 + (i - 1) * (segW + SEG_GAP)
                        local sx2 = sx1 + segW * fill
                        local sy1 = by + 1
                        local sy2 = by2 - 1
                        Draw.addRectFilled(dl, sx1, sy1, sx2, sy2, fillCol, 1)
                    end
                end
            end
        end
    end

    -- Stop button — InvisibleButton hit area + DrawList visuals so it clips
    -- inside the window without ImGui's frame padding pushing past the edge.
    local btnH = BAR_H + 4
    local btnX = px + width - STOP_BTN_W - STOP_BTN_RIGHT_MARGIN
    local btnY = by - 2
    pcall(function()
        imgui.SetCursorScreenPos(btnX, btnY)
        local clicked = imgui.InvisibleButton('##SideKickStripStop', STOP_BTN_W, btnH)
        local hovered = imgui.IsItemHovered()
        local bgCol = hovered and Draw.IM_COL32(170, 60, 60, 240) or Draw.IM_COL32(90, 30, 30, 220)
        Draw.addRectFilled(dl, btnX, btnY, btnX + STOP_BTN_W, btnY + btnH, bgCol, 2)
        Draw.addRect(dl, btnX, btnY, btnX + STOP_BTN_W, btnY + btnH, Draw.IM_COL32(255, 255, 255, 140), 2)
        local stw = calcTextWidth('S')
        local sth = imgui.GetTextLineHeight() or 12
        imgui.SetCursorScreenPos(btnX + (STOP_BTN_W - stw) * 0.5, btnY + (btnH - sth) * 0.5)
        imgui.TextColored(1, 1, 1, 1, 'S')
        if clicked then
            mq.cmd('/stopdisc')
            M.clear()
        end
    end)

    -- Reset cursor and consume vertical space.
    imgui.SetCursorScreenPos(px, py)
    pcall(function() imgui.Dummy(width, M.HEIGHT) end)
    return M.HEIGHT
end

return M
