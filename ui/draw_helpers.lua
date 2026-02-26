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
local _useImVec2 = true  -- Default to ImVec2 (MQ standard)

-- Find ImVec2 at module load time
-- MQ exposes ImVec2 as a global - capture it now while we're at module scope
local _imVec2Func = ImVec2 or (imgui and imgui.ImVec2) or nil

local function detectApiSignature(dl)
    if _apiDetected then return end

    -- If we didn't find ImVec2 at load time, try again
    if not _imVec2Func then
        _imVec2Func = ImVec2 or (imgui and imgui.ImVec2) or nil
    end

    -- Try to detect which signature works by probing with safe dummy values
    -- Only run when a valid draw list is provided
    if not dl then return end
    _apiDetected = true

    -- Try ImVec2 FIRST (MQ standard requires it)
    if _imVec2Func then
        local ok = pcall(function()
            dl:AddRectFilled(_imVec2Func(0, 0), _imVec2Func(1, 1), 0x00000000)
        end)
        if ok then
            _useImVec2 = true
            return
        end
    end

    -- Fallback: try raw coordinates
    local ok = pcall(function()
        dl:AddRectFilled(0, 0, 1, 1, 0x00000000)
    end)
    if ok then
        _useImVec2 = false
    end
end

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

-- AddRectFilled wrapper
-- Uses closure-style pcall for reliable MQ userdata binding compatibility
function M.addRectFilled(dl, x1, y1, x2, y2, col, rounding, flags)
    if not dl then return false end
    rounding = tonumber(rounding) or 0
    flags = tonumber(flags) or 0

    if not _apiDetected then
        detectApiSignature(dl)
    end

    -- Try ImVec2 first (MQ standard)
    if _useImVec2 and _imVec2Func then
        local ok = pcall(function()
            dl:AddRectFilled(_imVec2Func(x1, y1), _imVec2Func(x2, y2), col, rounding, flags)
        end)
        if ok then return true end

        -- Try without flags
        ok = pcall(function()
            dl:AddRectFilled(_imVec2Func(x1, y1), _imVec2Func(x2, y2), col, rounding)
        end)
        if ok then return true end

        -- Try without rounding
        ok = pcall(function()
            dl:AddRectFilled(_imVec2Func(x1, y1), _imVec2Func(x2, y2), col)
        end)
        if ok then return true end
    end

    -- Fallback: try raw coordinates
    local ok = pcall(function()
        dl:AddRectFilled(x1, y1, x2, y2, col, rounding, flags)
    end)
    if ok then return true end

    ok = pcall(function()
        dl:AddRectFilled(x1, y1, x2, y2, col, rounding)
    end)
    if ok then return true end

    ok = pcall(function()
        dl:AddRectFilled(x1, y1, x2, y2, col)
    end)
    return ok == true
end

-- AddRect wrapper (outline)
-- Uses closure-style pcall for reliable MQ userdata binding compatibility
function M.addRect(dl, x1, y1, x2, y2, col, rounding, flags, thickness)
    if not dl then return false end
    rounding = tonumber(rounding) or 0
    flags = tonumber(flags) or 0
    thickness = tonumber(thickness) or 1

    if not _apiDetected then
        detectApiSignature(dl)
    end

    -- Try ImVec2 first (MQ standard)
    if _useImVec2 and _imVec2Func then
        local ok = pcall(function()
            dl:AddRect(_imVec2Func(x1, y1), _imVec2Func(x2, y2), col, rounding, flags, thickness)
        end)
        if ok then return true end

        -- Try without thickness
        ok = pcall(function()
            dl:AddRect(_imVec2Func(x1, y1), _imVec2Func(x2, y2), col, rounding, flags)
        end)
        if ok then return true end

        -- Try without flags
        ok = pcall(function()
            dl:AddRect(_imVec2Func(x1, y1), _imVec2Func(x2, y2), col, rounding)
        end)
        if ok then return true end

        -- Try minimal
        ok = pcall(function()
            dl:AddRect(_imVec2Func(x1, y1), _imVec2Func(x2, y2), col)
        end)
        if ok then return true end
    end

    -- Fallback: try raw coordinates
    local ok = pcall(function()
        dl:AddRect(x1, y1, x2, y2, col, rounding, flags, thickness)
    end)
    if ok then return true end

    ok = pcall(function()
        dl:AddRect(x1, y1, x2, y2, col, rounding, flags)
    end)
    if ok then return true end

    ok = pcall(function()
        dl:AddRect(x1, y1, x2, y2, col, rounding)
    end)
    if ok then return true end

    ok = pcall(function()
        dl:AddRect(x1, y1, x2, y2, col)
    end)
    return ok == true
end

-- AddLine wrapper
function M.addLine(dl, x1, y1, x2, y2, col, thickness)
    if not dl then return false end
    thickness = tonumber(thickness) or 1

    if not _apiDetected then
        detectApiSignature(dl)
    end

    -- Try ImVec2 first (MQ standard)
    if _useImVec2 and _imVec2Func then
        local ok = pcall(function()
            dl:AddLine(_imVec2Func(x1, y1), _imVec2Func(x2, y2), col, thickness)
        end)
        if ok then return true end

        ok = pcall(function()
            dl:AddLine(_imVec2Func(x1, y1), _imVec2Func(x2, y2), col)
        end)
        if ok then return true end
    end

    -- Fallback to raw coords
    local ok = pcall(function() dl:AddLine(x1, y1, x2, y2, col, thickness) end)
    if ok then return true end

    ok = pcall(function() dl:AddLine(x1, y1, x2, y2, col) end)
    return ok == true
end

-- AddCircle wrapper
function M.addCircle(dl, cx, cy, radius, col, segments, thickness)
    if not dl then return false end
    segments = tonumber(segments) or 12
    thickness = tonumber(thickness) or 1

    if not _apiDetected then
        detectApiSignature(dl)
    end

    -- Try ImVec2 first (MQ standard)
    if _useImVec2 and _imVec2Func then
        local ok = pcall(function() dl:AddCircle(_imVec2Func(cx, cy), radius, col, segments, thickness) end)
        if ok then return true end

        ok = pcall(function() dl:AddCircle(_imVec2Func(cx, cy), radius, col, segments) end)
        if ok then return true end

        ok = pcall(function() dl:AddCircle(_imVec2Func(cx, cy), radius, col) end)
        if ok then return true end
    end

    -- Fallback to raw coords
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
    segments = tonumber(segments) or 12

    if not _apiDetected then
        detectApiSignature(dl)
    end

    -- Try ImVec2 first (MQ standard)
    if _useImVec2 and _imVec2Func then
        local ok = pcall(function() dl:AddCircleFilled(_imVec2Func(cx, cy), radius, col, segments) end)
        if ok then return true end

        ok = pcall(function() dl:AddCircleFilled(_imVec2Func(cx, cy), radius, col) end)
        if ok then return true end
    end

    -- Fallback to raw coords
    local ok = pcall(function() dl:AddCircleFilled(cx, cy, radius, col, segments) end)
    if ok then return true end

    ok = pcall(function() dl:AddCircleFilled(cx, cy, radius, col) end)
    return ok == true
end

-- AddText wrapper
function M.addText(dl, x, y, col, text)
    if not dl then return false end
    text = tostring(text or '')

    if not _apiDetected then
        detectApiSignature(dl)
    end

    -- Try ImVec2 first (MQ standard)
    if _useImVec2 and _imVec2Func then
        local ok = pcall(function() dl:AddText(_imVec2Func(x, y), col, text) end)
        if ok then return true end
    end

    -- Fallback to raw coords
    local ok = pcall(function() dl:AddText(x, y, col, text) end)
    return ok == true
end

-- AddImage wrapper (for texture rendering)
function M.addImage(dl, texId, x1, y1, x2, y2, u0, v0, u1, v1, tintCol)
    if not dl or not texId then return false end

    -- Default UV coordinates
    u0 = u0 or 0
    v0 = v0 or 0
    u1 = u1 or 1
    v1 = v1 or 1

    if not _apiDetected then
        detectApiSignature(dl)
    end

    -- Try ImVec2 first (MQ standard)
    if _useImVec2 and _imVec2Func then
        -- With tint color
        if tintCol then
            local ok = pcall(function()
                dl:AddImage(texId, _imVec2Func(x1, y1), _imVec2Func(x2, y2),
                           _imVec2Func(u0, v0), _imVec2Func(u1, v1), tintCol)
            end)
            if ok then return true end
        end

        -- Without tint
        local ok = pcall(function()
            dl:AddImage(texId, _imVec2Func(x1, y1), _imVec2Func(x2, y2),
                       _imVec2Func(u0, v0), _imVec2Func(u1, v1))
        end)
        if ok then return true end

        -- Minimal (no UV)
        ok = pcall(function()
            dl:AddImage(texId, _imVec2Func(x1, y1), _imVec2Func(x2, y2))
        end)
        if ok then return true end
    end

    -- Fallback: raw coordinates
    if tintCol then
        local ok = pcall(function()
            dl:AddImage(texId, x1, y1, x2, y2, u0, v0, u1, v1, tintCol)
        end)
        if ok then return true end
    end

    local ok = pcall(function()
        dl:AddImage(texId, x1, y1, x2, y2, u0, v0, u1, v1)
    end)
    if ok then return true end

    ok = pcall(function()
        dl:AddImage(texId, x1, y1, x2, y2)
    end)
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
-- GRADIENT FILLS
-- ============================================================

-- Vertical gradient fill (top color to bottom color)
-- Uses AddRectFilledMultiColor if available, falls back to solid
function M.addRectFilledGradientV(dl, x1, y1, x2, y2, colTop, colBottom, rounding)
    if not dl then return false end
    rounding = tonumber(rounding) or 0

    -- Try multi-color gradient first (no rounding support)
    if rounding == 0 and dl.AddRectFilledMultiColor then
        local ok = pcall(function()
            dl:AddRectFilledMultiColor(x1, y1, x2, y2, colTop, colTop, colBottom, colBottom)
        end)
        if ok then return true end
    end

    -- Fallback: solid fill with top color
    return M.addRectFilled(dl, x1, y1, x2, y2, colTop, rounding)
end

-- Horizontal gradient fill (left color to right color)
function M.addRectFilledGradientH(dl, x1, y1, x2, y2, colLeft, colRight, rounding)
    if not dl then return false end
    rounding = tonumber(rounding) or 0

    -- Try multi-color gradient first (no rounding support)
    if rounding == 0 and dl.AddRectFilledMultiColor then
        local ok = pcall(function()
            dl:AddRectFilledMultiColor(x1, y1, x2, y2, colLeft, colRight, colRight, colLeft)
        end)
        if ok then return true end
    end

    -- Fallback: solid fill with left color
    return M.addRectFilled(dl, x1, y1, x2, y2, colLeft, rounding)
end

-- Four-corner gradient (each corner can be different)
function M.addRectFilledGradient4(dl, x1, y1, x2, y2, colTL, colTR, colBR, colBL)
    if not dl then return false end

    if dl.AddRectFilledMultiColor then
        local ok = pcall(function()
            dl:AddRectFilledMultiColor(x1, y1, x2, y2, colTL, colTR, colBR, colBL)
        end)
        if ok then return true end
    end

    -- Fallback: solid fill with top-left color
    return M.addRectFilled(dl, x1, y1, x2, y2, colTL, 0)
end

-- ============================================================
-- DECORATIVE BORDERS
-- ============================================================

-- Draw corner accents (EQ-style bracket corners)
function M.addCornerAccents(dl, x1, y1, x2, y2, col, size, thickness)
    if not dl then return false end
    size = tonumber(size) or 8
    thickness = tonumber(thickness) or 2

    -- Top-left corner
    M.addLine(dl, x1, y1 + size, x1, y1, col, thickness)
    M.addLine(dl, x1, y1, x1 + size, y1, col, thickness)

    -- Top-right corner
    M.addLine(dl, x2 - size, y1, x2, y1, col, thickness)
    M.addLine(dl, x2, y1, x2, y1 + size, col, thickness)

    -- Bottom-left corner
    M.addLine(dl, x1, y2 - size, x1, y2, col, thickness)
    M.addLine(dl, x1, y2, x1 + size, y2, col, thickness)

    -- Bottom-right corner
    M.addLine(dl, x2 - size, y2, x2, y2, col, thickness)
    M.addLine(dl, x2, y2, x2, y2 - size, col, thickness)

    return true
end

-- Draw beveled border (classic 3D look: light top-left, dark bottom-right)
function M.addBeveledBorder(dl, x1, y1, x2, y2, lightCol, darkCol, thickness)
    if not dl then return false end
    thickness = tonumber(thickness) or 1

    -- Light edges (top, left) - raised look
    M.addLine(dl, x1, y1, x2, y1, lightCol, thickness)
    M.addLine(dl, x1, y1, x1, y2, lightCol, thickness)

    -- Dark edges (bottom, right) - shadow
    M.addLine(dl, x1, y2, x2, y2, darkCol, thickness)
    M.addLine(dl, x2, y1, x2, y2, darkCol, thickness)

    return true
end

-- Draw inner glow effect (layered lighter borders inside)
function M.addInnerGlow(dl, x1, y1, x2, y2, glowCol, glowWidth)
    if not dl then return false end
    glowWidth = tonumber(glowWidth) or 2

    -- Extract RGBA from packed color
    local r = bit32 and bit32.band(glowCol, 0xFF) or (glowCol % 256)
    local g = bit32 and bit32.band(bit32.rshift(glowCol, 8), 0xFF) or (math.floor(glowCol / 256) % 256)
    local b = bit32 and bit32.band(bit32.rshift(glowCol, 16), 0xFF) or (math.floor(glowCol / 65536) % 256)

    for i = glowWidth, 1, -1 do
        local alpha = math.floor(60 * (i / glowWidth))
        local col = M.IM_COL32(r, g, b, alpha)
        M.addRect(dl, x1 + i, y1 + i, x2 - i, y2 - i, col, 0, 0, 1)
    end

    return true
end

-- Draw outer glow effect (layered borders outside)
function M.addOuterGlow(dl, x1, y1, x2, y2, glowCol, glowWidth)
    if not dl then return false end
    glowWidth = tonumber(glowWidth) or 3

    -- Extract RGBA from packed color
    local r = bit32 and bit32.band(glowCol, 0xFF) or (glowCol % 256)
    local g = bit32 and bit32.band(bit32.rshift(glowCol, 8), 0xFF) or (math.floor(glowCol / 256) % 256)
    local b = bit32 and bit32.band(bit32.rshift(glowCol, 16), 0xFF) or (math.floor(glowCol / 65536) % 256)

    for i = glowWidth, 1, -1 do
        local alpha = math.floor(40 * (1 - (i - 1) / glowWidth))
        local col = M.IM_COL32(r, g, b, alpha)
        M.addRect(dl, x1 - i, y1 - i, x2 + i, y2 + i, col, 0, 0, 1)
    end

    return true
end

-- ============================================================
-- RE-DETECTION (for runtime debugging)
-- ============================================================

function M.redetectApi(dl)
    _apiDetected = false
    _useImVec2 = false
    detectApiSignature(dl)
end

function M.getApiInfo()
    return {
        detected = _apiDetected,
        useImVec2 = _useImVec2,
        hasImVec2 = _imVec2Func ~= nil,
    }
end

-- ============================================================
-- TEXTURE RENDERER ACCESS
-- ============================================================

local _textureRenderer = nil
local _textureRendererLoaded = false

function M.getTextureRenderer()
    if _textureRendererLoaded then return _textureRenderer end
    _textureRendererLoaded = true

    local ok, renderer = pcall(require, 'sidekick-next.ui.texture_renderer')
    if ok and renderer then
        _textureRenderer = renderer
    end
    return _textureRenderer
end

function M.useTexturesForTheme(themeName)
    local ok, Themes = pcall(require, 'sidekick-next.themes')
    if not ok or not Themes then return false end

    local isTextured = false
    pcall(function() isTextured = Themes.isTexturedTheme(themeName) end)
    if not isTextured then return false end

    local renderer = M.getTextureRenderer()
    if not renderer then return false end

    local available = false
    pcall(function()
        if renderer.isAvailable then
            available = renderer.isAvailable()
        end
    end)

    return available
end

-- ============================================================
-- PATH DRAWING WRAPPERS (for radial cooldown sweep, etc.)
-- ============================================================

-- PathArcTo wrapper
function M.pathArcTo(dl, cx, cy, radius, a_min, a_max, segments)
    if not dl then return false end
    segments = segments or 32

    if not _apiDetected then detectApiSignature(dl) end

    if _useImVec2 and _imVec2Func then
        local ok = pcall(function() dl:PathArcTo(_imVec2Func(cx, cy), radius, a_min, a_max, segments) end)
        if ok then return true end
    end
    local ok = pcall(function() dl:PathArcTo(cx, cy, radius, a_min, a_max, segments) end)
    return ok == true
end

-- PathLineTo wrapper
function M.pathLineTo(dl, x, y)
    if not dl then return false end

    if not _apiDetected then detectApiSignature(dl) end

    if _useImVec2 and _imVec2Func then
        local ok = pcall(function() dl:PathLineTo(_imVec2Func(x, y)) end)
        if ok then return true end
    end
    local ok = pcall(function() dl:PathLineTo(x, y) end)
    return ok == true
end

-- PathFillConvex wrapper
function M.pathFillConvex(dl, col)
    if not dl then return false end
    local ok = pcall(function() dl:PathFillConvex(col) end)
    return ok == true
end

-- PathClear wrapper
function M.pathClear(dl)
    if not dl then return false end
    local ok = pcall(function() dl:PathClear() end)
    return ok == true
end

-- AddTriangleFilled wrapper (safe: each triangle is always convex)
function M.addTriangleFilled(dl, x1, y1, x2, y2, x3, y3, color)
    if not dl then return false end
    if not _apiDetected then detectApiSignature(dl) end
    if _useImVec2 and _imVec2Func then
        local ok = pcall(function()
            dl:AddTriangleFilled(_imVec2Func(x1, y1), _imVec2Func(x2, y2), _imVec2Func(x3, y3), color)
        end)
        if ok then return true end
    end
    local ok = pcall(function()
        dl:AddTriangleFilled(x1, y1, x2, y2, x3, y3, color)
    end)
    return ok == true
end

-- Draw a filled pie/wedge using individual triangles (crash-safe).
-- Unlike PathFillConvex, this works for arcs > 180° because each
-- triangle (center → arc_i → arc_i+1) is always convex.
function M.drawPieFilled(dl, cx, cy, radius, startAngle, endAngle, color, segments)
    if not dl then return end
    segments = segments or 32
    local step = (endAngle - startAngle) / segments
    for i = 0, segments - 1 do
        local a0 = startAngle + i * step
        local a1 = startAngle + (i + 1) * step
        local x0 = cx + math.cos(a0) * radius
        local y0 = cy + math.sin(a0) * radius
        local x1 = cx + math.cos(a1) * radius
        local y1 = cy + math.sin(a1) * radius
        M.addTriangleFilled(dl, cx, cy, x0, y0, x1, y1, color)
    end
end

return M
