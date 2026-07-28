-- ============================================================
-- SideKick Settings Redesign - Palette
-- ============================================================
-- Eight named tokens. Dark parchment + burnished gold, with
-- vermilion and verdigris as secondaries so the panel doesn't
-- read as "another brown-and-gold EQ addon."
--
-- Values are stored as {r,g,b} in 0..1 space so ImGui can consume
-- them directly. Alpha is passed at the call site.

local M = {}

local function rgb(r, g, b) return { r / 255, g / 255, b / 255 } end

M.bg     = rgb(0x14, 0x10, 0x14)  -- near-black parchment
M.panel  = rgb(0x1E, 0x1A, 0x21)  -- panel plate
M.plate  = rgb(0x25, 0x20, 0x28)  -- rail row hover / content card
M.ink    = rgb(0xE7, 0xDD, 0xC7)  -- bone (body text)
M.dim    = rgb(0x8A, 0x80, 0x73)  -- faded ink (secondary)
M.rule   = rgb(0x3A, 0x2E, 0x1E)  -- patinated bronze (borders)
M.accent = rgb(0xD4, 0xA2, 0x4A)  -- burnished gold (nav / focus)
M.hot    = rgb(0xB8, 0x4A, 0x2E)  -- vermilion (combat / burn / warn)
M.cool   = rgb(0x5E, 0x8A, 0x9A)  -- verdigris (regen / passive)

--- Return r,g,b,a as four values for ImGui.PushStyleColor etc.
function M.rgba(color, alpha)
    if not color then return 1, 1, 1, alpha or 1 end
    return color[1], color[2], color[3], alpha or 1
end

--- Blend two palette colors by t in [0,1].
function M.mix(a, b, t)
    t = math.max(0, math.min(1, t or 0))
    return {
        a[1] * (1 - t) + b[1] * t,
        a[2] * (1 - t) + b[2] * t,
        a[3] * (1 - t) + b[3] * t,
    }
end

--- IM_COL32 helper (r,g,b,a in 0..1 -> uint32 for DrawList calls).
function M.col32(color, alpha)
    local r = math.floor((color[1] or 0) * 255 + 0.5)
    local g = math.floor((color[2] or 0) * 255 + 0.5)
    local b = math.floor((color[3] or 0) * 255 + 0.5)
    local a = math.floor((alpha or 1) * 255 + 0.5)
    return (a * 0x1000000) + (b * 0x10000) + (g * 0x100) + r
end

return M
