-- ============================================================
-- SideKick Draw Helpers
-- ============================================================
-- Centralized drawing utilities including IM_COL32 conversion,
-- vec2 helpers, and DrawList API wrappers with cached signature
-- detection.
--
-- Usage:
--   local Draw = require('sidekick-next.ui.draw_helpers')
--   local color = Draw.IM_COL32(255, 128, 0, 200)
--   Draw.addRectFilled(drawList, x1, y1, x2, y2, color, rounding)

local imgui = require('ImGui')

local M = {}

-- ============================================================
-- CACHED API DETECTION
-- ============================================================

-- Detect DrawList API signature once at startup, not per-call
local _apiDetected = false
local _useImVec2 = false
local _imVec2Func = nil

local function detectApiSignature()
    if _apiDetected then return end
    _apiDetected = true

    -- Check for ImVec2 constructor
    local ImVec2 = _G.ImVec2 or (imgui and imgui.ImVec2)
    if ImVec2 and type(ImVec2) == 'function' then
        _imVec2Func = ImVec2
    end

    -- Try to detect which signature works by probing with safe dummy values
    -- This happens once at module load, not per-frame
    local dl = imgui.GetBackgroundDrawList and imgui.GetBackgroundDrawList()
    if not dl then return end

    -- Test raw coordinates first (most common)
    local ok = pcall(function()
        dl:AddRect(0, 0, 1, 1, 0x00000000, 0, 0, 0)
    end)

    if not ok and _imVec2Func then
        -- Try ImVec2 signature
        ok = pcall(function()
            dl:AddRect(_imVec2Func(0, 0), _imVec2Func(1, 1), 0x00000000, 0, 0, 0)
        end)
        if ok then
            _useImVec2 = true
        end
    end
end

-- Run detection on module load
detectApiSignature()

-- ============================================================
-- IM_COL32 - Convert RGBA (0-255) to packed uint32
-- ============================================================

function M.IM_COL32(r, g, b, a)
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

-- ============================================================
-- IM_COL32_FLOAT - Convert RGBA (0-1 floats) to packed uint32
-- ============================================================

function M.IM_COL32_FLOAT(r, g, b, a)
    r = math.floor((tonumber(r) or 0) * 255)
    g = math.floor((tonumber(g) or 0) * 255)
    b = math.floor((tonumber(b) or 0) * 255)
    a = math.floor((tonumber(a) or 1) * 255)
    return M.IM_COL32(r, g, b, a)
end

-- ============================================================
-- vec2xy - Extract x,y from various vec2 representations
-- ============================================================

function M.vec2xy(a, b)
    if b ~= nil then
        return tonumber(a) or 0, tonumber(b) or 0
    end
    if type(a) == 'table' then
        return tonumber(a.x or a[1]) or 0, tonumber(a.y or a[2]) or 0
    end
    return tonumber(a) or 0, 0
end

-- ============================================================
-- DRAWLIST WRAPPERS
-- ============================================================

-- Internal helper to call DrawList methods with correct signature
local function callDl(dl, method, x1, y1, x2, y2, ...)
    if not dl or not dl[method] then return false end

    if _useImVec2 and _imVec2Func then
        local ok = pcall(dl[method], dl, _imVec2Func(x1, y1), _imVec2Func(x2, y2), ...)
        if ok then return true end
    end

    -- Try raw coordinates
    local ok = pcall(dl[method], dl, x1, y1, x2, y2, ...)
    if ok then return true end

    -- Fallback: try with fewer arguments
    local args = {...}
    while #args > 0 do
        table.remove(args)
        ok = pcall(dl[method], dl, x1, y1, x2, y2, unpack(args))
        if ok then return true end
    end

    return false
end

-- AddRectFilled wrapper
function M.addRectFilled(dl, x1, y1, x2, y2, col, rounding, flags)
    if not dl then return false end
    rounding = tonumber(rounding) or 0
    flags = tonumber(flags) or 0
    return callDl(dl, 'AddRectFilled', x1, y1, x2, y2, col, rounding, flags)
end

-- AddRect wrapper (outline)
function M.addRect(dl, x1, y1, x2, y2, col, rounding, flags, thickness)
    if not dl then return false end
    rounding = tonumber(rounding) or 0
    flags = tonumber(flags) or 0
    thickness = tonumber(thickness) or 1
    return callDl(dl, 'AddRect', x1, y1, x2, y2, col, rounding, flags, thickness)
end

-- AddLine wrapper
function M.addLine(dl, x1, y1, x2, y2, col, thickness)
    if not dl then return false end
    thickness = tonumber(thickness) or 1

    if _useImVec2 and _imVec2Func then
        local ok = pcall(function()
            dl:AddLine(_imVec2Func(x1, y1), _imVec2Func(x2, y2), col, thickness)
        end)
        if ok then return true end
    end

    local ok = pcall(function() dl:AddLine(x1, y1, x2, y2, col, thickness) end)
    if ok then return true end

    ok = pcall(function() dl:AddLine(x1, y1, x2, y2, col) end)
    return ok == true
end

-- AddCircle wrapper
function M.addCircle(dl, cx, cy, radius, col, segments, thickness)
    if not dl then return false end
    segments = tonumber(segments) or 0
    thickness = tonumber(thickness) or 1

    local ok = pcall(function() dl:AddCircle(cx, cy, radius, col, segments, thickness) end)
    if ok then return true end

    ok = pcall(function() dl:AddCircle(cx, cy, radius, col, segments) end)
    if ok then return true end

    ok = pcall(function() dl:AddCircle(cx, cy, radius, col) end)
    return ok == true
end

-- AddCircleFilled wrapper
function M.addCircleFilled(dl, cx, cy, radius, col, segments)
    if not dl then return false end
    segments = tonumber(segments) or 0

    local ok = pcall(function() dl:AddCircleFilled(cx, cy, radius, col, segments) end)
    if ok then return true end

    ok = pcall(function() dl:AddCircleFilled(cx, cy, radius, col) end)
    return ok == true
end

-- AddText wrapper
function M.addText(dl, x, y, col, text)
    if not dl then return false end
    text = tostring(text or '')

    if _useImVec2 and _imVec2Func then
        local ok = pcall(function() dl:AddText(_imVec2Func(x, y), col, text) end)
        if ok then return true end
    end

    local ok = pcall(function() dl:AddText(x, y, col, text) end)
    return ok == true
end

-- ============================================================
-- UTILITY FUNCTIONS
-- ============================================================

-- Draw dashed line (for anchor visualization)
function M.addDashedLine(dl, x1, y1, x2, y2, col, thickness, dashLen, gapLen)
    if not dl then return false end
    thickness = tonumber(thickness) or 1
    dashLen = tonumber(dashLen) or 5
    gapLen = tonumber(gapLen) or 3

    local dx = x2 - x1
    local dy = y2 - y1
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 1 then return true end

    local ux = dx / dist
    local uy = dy / dist

    local pos = 0
    local drawing = true
    while pos < dist do
        local segLen = drawing and dashLen or gapLen
        if pos + segLen > dist then segLen = dist - pos end

        if drawing then
            local sx = x1 + ux * pos
            local sy = y1 + uy * pos
            local ex = x1 + ux * (pos + segLen)
            local ey = y1 + uy * (pos + segLen)
            M.addLine(dl, sx, sy, ex, ey, col, thickness)
        end

        pos = pos + segLen
        drawing = not drawing
    end

    return true
end

-- Draw outlined text (text with shadow/outline)
function M.drawOutlinedText(x, y, text, r, g, b, outlineColor)
    outlineColor = outlineColor or M.IM_COL32(0, 0, 0, 255)
    local textColor = M.IM_COL32(
        math.floor((tonumber(r) or 1) * 255),
        math.floor((tonumber(g) or 1) * 255),
        math.floor((tonumber(b) or 1) * 255),
        255
    )

    local offsets = {
        { -1, -1 }, { 0, -1 }, { 1, -1 },
        { -1, 0 }, { 1, 0 },
        { -1, 1 }, { 0, 1 }, { 1, 1 }
    }

    for _, off in ipairs(offsets) do
        imgui.SetCursorScreenPos(x + off[1], y + off[2])
        imgui.TextColored(0, 0, 0, 1, text)
    end

    imgui.SetCursorScreenPos(x, y)
    imgui.TextColored(r or 1, g or 1, b or 1, 1, text)
end

-- ============================================================
-- RE-DETECTION (for runtime debugging)
-- ============================================================

function M.redetectApi()
    _apiDetected = false
    detectApiSignature()
end

function M.getApiInfo()
    return {
        detected = _apiDetected,
        useImVec2 = _useImVec2,
        hasImVec2 = _imVec2Func ~= nil,
    }
end

return M
