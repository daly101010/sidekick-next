--[[
    EQ Classic UI Window Renderer
    Renders authentic EverQuest UI windows using texture pieces from the original UI XML.
    Parses the animation definitions and composites window frames via DrawList.
]]

local mq = require('mq')
local imgui = require('ImGui')

-------------------------------------------------------------------------------
-- Configuration
-------------------------------------------------------------------------------
local UI_PATH = "F:/lua/ui/"

-- State
local State = {
    open = true,
    draw = false,
}

-------------------------------------------------------------------------------
-- Texture Management
-------------------------------------------------------------------------------
local Textures = {}

local function LoadTexture(name, filename)
    local ok, result = pcall(function()
        return mq.CreateTexture(UI_PATH .. filename)
    end)
    if ok and result then
        Textures[name] = result
        return true
    else
        print(string.format("\ar[EQ Windows] Failed to load %s: %s\ax", filename, tostring(result)))
        return false
    end
end

local function LoadAllTextures()
    LoadTexture("classic_pieces02", "classic_pieces02.tga")
    LoadTexture("window_pieces01", "window_pieces01.tga")
    LoadTexture("window_pieces02", "window_pieces02.tga")
    LoadTexture("bg_dark_rock", "wnd_bg_dark_rock.tga")
    LoadTexture("bg_light_rock", "wnd_bg_light_rock.tga")
    LoadTexture("shade", "shade.tga")
end

-------------------------------------------------------------------------------
-- Animation Definitions (parsed from XML)
-- Format: { texture = "name", x, y, w, h }
-- Coordinates are in pixels, textures are 256x256
-------------------------------------------------------------------------------
local Animations = {
    -- Classic Window Border (from classic_pieces02.tga)
    ClassicTopLeft      = { texture = "classic_pieces02", x = 0,   y = 51, w = 7,  h = 7 },
    ClassicTop          = { texture = "classic_pieces02", x = 8,   y = 51, w = 96, h = 7 },
    ClassicTopRight     = { texture = "classic_pieces02", x = 105, y = 51, w = 7,  h = 7 },
    ClassicLeft         = { texture = "classic_pieces02", x = 240, y = 0,  w = 7,  h = 256 },
    ClassicRight        = { texture = "classic_pieces02", x = 248, y = 0,  w = 7,  h = 256 },
    ClassicBottomLeft   = { texture = "classic_pieces02", x = 0,   y = 59, w = 7,  h = 7 },
    ClassicBottom       = { texture = "classic_pieces02", x = 8,   y = 59, w = 96, h = 7 },
    ClassicBottomRight  = { texture = "classic_pieces02", x = 105, y = 59, w = 7,  h = 7 },

    -- Classic Titlebar (from classic_pieces02.tga)
    ClassicTitleLeft    = { texture = "classic_pieces02", x = 0,  y = 67, w = 4,  h = 14 },
    ClassicTitleMiddle  = { texture = "classic_pieces02", x = 5,  y = 67, w = 88, h = 14 },
    ClassicTitleRight   = { texture = "classic_pieces02", x = 94, y = 67, w = 4,  h = 14 },

    -- Close Button (from window_pieces01.tga)
    CloseBtnNormal      = { texture = "window_pieces01", x = 100, y = 90, w = 12, h = 12 },
    CloseBtnPressed     = { texture = "window_pieces01", x = 124, y = 90, w = 12, h = 12 },
    CloseBtnFlyby       = { texture = "window_pieces01", x = 112, y = 90, w = 12, h = 12 },

    -- Minimize Button (from window_pieces01.tga)
    MinimizeBtnNormal   = { texture = "window_pieces01", x = 136, y = 91, w = 12, h = 12 },
    MinimizeBtnPressed  = { texture = "window_pieces01", x = 160, y = 91, w = 12, h = 12 },
    MinimizeBtnFlyby    = { texture = "window_pieces01", x = 148, y = 91, w = 12, h = 12 },

    -- Tile Button (from window_pieces01.tga)
    TileBtnNormal       = { texture = "window_pieces01", x = 172, y = 91, w = 12, h = 12 },
    TileBtnPressed      = { texture = "window_pieces01", x = 196, y = 91, w = 12, h = 12 },
    TileBtnFlyby        = { texture = "window_pieces01", x = 184, y = 91, w = 12, h = 12 },

    -- Item Slot Frame (from classic_pieces02.tga)
    InvSlotFrame        = { texture = "classic_pieces02", x = 0, y = 0, w = 48, h = 48 },

    -- Scrollbar pieces (from window_pieces01.tga)
    VSBUpNormal         = { texture = "window_pieces01", x = 10, y = 90,  w = 11, h = 18 },
    VSBDownNormal       = { texture = "window_pieces01", x = 10, y = 112, w = 11, h = 18 },
    VSBThumbTop         = { texture = "window_pieces01", x = 70, y = 110, w = 11, h = 4 },
    VSBThumbMiddle      = { texture = "window_pieces01", x = 70, y = 130, w = 11, h = 2 },
    VSBThumbBottom      = { texture = "window_pieces01", x = 70, y = 120, w = 11, h = 4 },
}

-------------------------------------------------------------------------------
-- Drawing Helpers
-------------------------------------------------------------------------------

-- Convert pixel coordinates to UV (0-1) for a 256x256 texture
local function PixelToUV(anim)
    local texW, texH = 256, 256
    return {
        u0 = anim.x / texW,
        v0 = anim.y / texH,
        u1 = (anim.x + anim.w) / texW,
        v1 = (anim.y + anim.h) / texH,
    }
end

-- Draw a texture piece at screen position
local function DrawPiece(dl, anim, x, y, w, h)
    local tex = Textures[anim.texture]
    if not tex then return end

    local texId = tex:GetTextureID()
    if not texId then return end

    w = w or anim.w
    h = h or anim.h

    local uv = PixelToUV(anim)

    -- Try ImVec2 first, fall back to raw coords
    local ok = pcall(function()
        dl:AddImage(texId, ImVec2(x, y), ImVec2(x + w, y + h), ImVec2(uv.u0, uv.v0), ImVec2(uv.u1, uv.v1))
    end)
    if not ok then
        pcall(function()
            dl:AddImage(texId, x, y, x + w, y + h, uv.u0, uv.v0, uv.u1, uv.v1)
        end)
    end
end

-- Draw tiled texture piece (for borders and backgrounds)
local function DrawPieceTiled(dl, anim, x, y, w, h, tileDir)
    local tex = Textures[anim.texture]
    if not tex then return end

    local texId = tex:GetTextureID()
    if not texId then return end

    local uv = PixelToUV(anim)

    if tileDir == "horizontal" then
        -- Tile horizontally
        local tileW = anim.w
        local drawn = 0
        while drawn < w do
            local drawW = math.min(tileW, w - drawn)
            local u1 = uv.u0 + (uv.u1 - uv.u0) * (drawW / tileW)
            pcall(function()
                dl:AddImage(texId, ImVec2(x + drawn, y), ImVec2(x + drawn + drawW, y + h),
                    ImVec2(uv.u0, uv.v0), ImVec2(u1, uv.v1))
            end)
            drawn = drawn + tileW
        end
    elseif tileDir == "vertical" then
        -- Tile vertically
        local tileH = anim.h
        local drawn = 0
        while drawn < h do
            local drawH = math.min(tileH, h - drawn)
            local v1 = uv.v0 + (uv.v1 - uv.v0) * (drawH / tileH)
            pcall(function()
                dl:AddImage(texId, ImVec2(x, y + drawn), ImVec2(x + w, y + drawn + drawH),
                    ImVec2(uv.u0, uv.v0), ImVec2(uv.u1, v1))
            end)
            drawn = drawn + tileH
        end
    else
        -- Tile both directions (for backgrounds)
        local tileW = anim.w
        local tileH = anim.h
        local drawnY = 0
        while drawnY < h do
            local drawH = math.min(tileH, h - drawnY)
            local v1 = uv.v0 + (uv.v1 - uv.v0) * (drawH / tileH)
            local drawnX = 0
            while drawnX < w do
                local drawW = math.min(tileW, w - drawnX)
                local u1 = uv.u0 + (uv.u1 - uv.u0) * (drawW / tileW)
                pcall(function()
                    dl:AddImage(texId, ImVec2(x + drawnX, y + drawnY), ImVec2(x + drawnX + drawW, y + drawnY + drawH),
                        ImVec2(uv.u0, uv.v0), ImVec2(u1, v1))
                end)
                drawnX = drawnX + tileW
            end
            drawnY = drawnY + tileH
        end
    end
end

-- Draw a full background texture
local function DrawBackground(dl, texName, x, y, w, h)
    local tex = Textures[texName]
    if not tex then return end

    local texId = tex:GetTextureID()
    if not texId then return end

    -- Tile the 256x256 background
    local tileSize = 256
    local drawnY = 0
    while drawnY < h do
        local drawH = math.min(tileSize, h - drawnY)
        local v1 = drawH / tileSize
        local drawnX = 0
        while drawnX < w do
            local drawW = math.min(tileSize, w - drawnX)
            local u1 = drawW / tileSize
            pcall(function()
                dl:AddImage(texId, ImVec2(x + drawnX, y + drawnY), ImVec2(x + drawnX + drawW, y + drawnY + drawH),
                    ImVec2(0, 0), ImVec2(u1, v1))
            end)
            drawnX = drawnX + tileSize
        end
        drawnY = drawnY + tileSize
    end
end

-------------------------------------------------------------------------------
-- EQ Window Renderer
-------------------------------------------------------------------------------

-- Draw a complete EQ-style window frame
local function DrawEQWindow(dl, x, y, w, h, title, options)
    options = options or {}
    local showTitle = options.showTitle ~= false
    local showClose = options.showClose ~= false
    local bgType = options.background or "dark" -- "dark" or "light"

    local borderW = 7  -- Width of border pieces
    local titleH = showTitle and 14 or 0

    -- Content area (inside borders)
    local contentX = x + borderW
    local contentY = y + borderW + titleH
    local contentW = w - borderW * 2
    local contentH = h - borderW * 2 - titleH

    -- Draw background
    local bgTex = bgType == "dark" and "bg_dark_rock" or "bg_light_rock"
    DrawBackground(dl, bgTex, contentX, contentY, contentW, contentH)

    -- Draw titlebar background if showing title
    if showTitle then
        DrawBackground(dl, bgTex, contentX, y + borderW, contentW, titleH)
    end

    -- Draw border pieces
    -- Corners
    DrawPiece(dl, Animations.ClassicTopLeft, x, y)
    DrawPiece(dl, Animations.ClassicTopRight, x + w - borderW, y)
    DrawPiece(dl, Animations.ClassicBottomLeft, x, y + h - borderW)
    DrawPiece(dl, Animations.ClassicBottomRight, x + w - borderW, y + h - borderW)

    -- Edges (tiled)
    DrawPieceTiled(dl, Animations.ClassicTop, x + borderW, y, w - borderW * 2, borderW, "horizontal")
    DrawPieceTiled(dl, Animations.ClassicBottom, x + borderW, y + h - borderW, w - borderW * 2, borderW, "horizontal")
    DrawPieceTiled(dl, Animations.ClassicLeft, x, y + borderW, borderW, h - borderW * 2, "vertical")
    DrawPieceTiled(dl, Animations.ClassicRight, x + w - borderW, y + borderW, borderW, h - borderW * 2, "vertical")

    -- Draw titlebar
    if showTitle then
        local titleY = y + borderW
        local titleW = w - borderW * 2
        local tbLeft = Animations.ClassicTitleLeft
        local tbMid = Animations.ClassicTitleMiddle
        local tbRight = Animations.ClassicTitleRight

        DrawPiece(dl, tbLeft, contentX, titleY)
        DrawPieceTiled(dl, tbMid, contentX + tbLeft.w, titleY, titleW - tbLeft.w - tbRight.w, titleH, "horizontal")
        DrawPiece(dl, tbRight, contentX + titleW - tbRight.w, titleY)

        -- Draw title text
        if title then
            local textX = contentX + tbLeft.w + 4
            local textY = titleY + 2
            pcall(function()
                dl:AddText(ImVec2(textX, textY), 0xFFFFFFFF, title)
            end)
        end

        -- Draw close button
        if showClose then
            local btnX = contentX + titleW - 14
            local btnY = titleY + 1
            DrawPiece(dl, Animations.CloseBtnNormal, btnX, btnY)
        end
    end

    -- Return content area for caller to use
    return {
        x = contentX,
        y = contentY,
        w = contentW,
        h = contentH,
    }
end

-- Draw an item slot frame
local function DrawItemSlot(dl, x, y, size)
    size = size or 48
    DrawPiece(dl, Animations.InvSlotFrame, x, y, size, size)
end

-- Draw a vertical scrollbar
local function DrawScrollbar(dl, x, y, h, thumbPos, thumbSize)
    local btnH = 18  -- Height of up/down buttons
    local sbW = 11   -- Width of scrollbar
    local trackH = h - btnH * 2

    -- Up button
    DrawPiece(dl, Animations.VSBUpNormal, x, y)

    -- Down button
    DrawPiece(dl, Animations.VSBDownNormal, x, y + h - btnH)

    -- Track background (use shade texture tiled)
    local shadeTex = Textures["shade"]
    if shadeTex then
        local shadeId = shadeTex:GetTextureID()
        if shadeId then
            pcall(function()
                dl:AddImage(shadeId, ImVec2(x, y + btnH), ImVec2(x + sbW, y + h - btnH))
            end)
        end
    end

    -- Thumb
    local thumbTopH = 4
    local thumbBotH = 4
    local thumbY = y + btnH + (trackH - thumbSize) * thumbPos
    DrawPiece(dl, Animations.VSBThumbTop, x, thumbY)
    DrawPieceTiled(dl, Animations.VSBThumbMiddle, x, thumbY + thumbTopH, sbW, thumbSize - thumbTopH - thumbBotH, "vertical")
    DrawPiece(dl, Animations.VSBThumbBottom, x, thumbY + thumbSize - thumbBotH)
end

-------------------------------------------------------------------------------
-- Demo Windows
-------------------------------------------------------------------------------

local DemoWindows = {
    { name = "Player Window", x = 50, y = 50, w = 200, h = 150, bg = "dark", showClose = true },
    { name = "Target Window", x = 270, y = 50, w = 200, h = 150, bg = "dark", showClose = true },
    { name = "Chat Window", x = 50, y = 220, w = 300, h = 180, bg = "light", showClose = true },
    { name = "Inventory", x = 370, y = 220, w = 220, h = 200, bg = "dark", showClose = true },
}

local ShowSlotDemo = true
local ShowScrollbarDemo = true

-------------------------------------------------------------------------------
-- Main Render Function
-------------------------------------------------------------------------------

local function RenderUI()
    if not State.open then return end

    local flags = bit32.bor(
        ImGuiWindowFlags.NoScrollbar,
        ImGuiWindowFlags.NoScrollWithMouse
    )

    ImGui.SetNextWindowSize(700, 550, ImGuiCond.FirstUseEver)

    State.open, State.draw = ImGui.Begin("EQ Classic UI Window Demo", State.open, flags)

    if State.draw then
        -- Get draw list for custom rendering
        local dl = ImGui.GetWindowDrawList()
        local wx, wy = ImGui.GetWindowPos()
        local cx, cy = ImGui.GetCursorScreenPos()

        -- Controls
        ImGui.Text("EverQuest Classic Window Renderer")
        ImGui.Separator()

        _, ShowSlotDemo = ImGui.Checkbox("Show Item Slots", ShowSlotDemo)
        ImGui.SameLine()
        _, ShowScrollbarDemo = ImGui.Checkbox("Show Scrollbar", ShowScrollbarDemo)

        ImGui.Spacing()
        ImGui.Separator()
        ImGui.Spacing()

        -- Get area for demo windows
        local startX, startY = ImGui.GetCursorScreenPos()
        local availW, availH = ImGui.GetContentRegionAvail()

        -- Draw demo windows
        for _, win in ipairs(DemoWindows) do
            local content = DrawEQWindow(dl,
                startX + win.x,
                startY + win.y,
                win.w,
                win.h,
                win.name,
                { background = win.bg, showClose = win.showClose }
            )

            -- Draw content in each window
            if win.name == "Inventory" and ShowSlotDemo then
                -- Draw a grid of item slots
                local slotSize = 40
                local padding = 4
                local cols = 4
                local slotX = content.x + padding
                local slotY = content.y + padding

                for row = 0, 3 do
                    for col = 0, cols - 1 do
                        DrawItemSlot(dl,
                            slotX + col * (slotSize + padding),
                            slotY + row * (slotSize + padding),
                            slotSize
                        )
                    end
                end
            end

            if win.name == "Chat Window" and ShowScrollbarDemo then
                -- Draw a scrollbar on the right side
                local sbX = content.x + content.w - 20
                local sbY = content.y + 4
                local sbH = content.h - 8
                DrawScrollbar(dl, sbX, sbY, sbH, 0.3, 40)

                -- Draw some fake text lines
                for i = 1, 6 do
                    pcall(function()
                        dl:AddText(ImVec2(content.x + 4, content.y + 4 + (i - 1) * 14),
                            0xFFCCCCCC, string.format("[%02d:00] You say, 'Hello world!'", i))
                    end)
                end
            end
        end

        -- Reserve space for the demo area
        ImGui.Dummy(availW, 450)
    end

    ImGui.End()
end

-------------------------------------------------------------------------------
-- Initialization
-------------------------------------------------------------------------------

mq.imgui.init('EQWindowDemo', RenderUI)

print("\ay[EQ Windows]\ax Loading textures...")
LoadAllTextures()

local loadedCount = 0
for _ in pairs(Textures) do loadedCount = loadedCount + 1 end
print(string.format("\ay[EQ Windows]\ax Loaded %d textures. Demo ready.", loadedCount))

-- Main loop
while State.open do
    mq.delay(100)
end

print("\ay[EQ Windows]\ax Closed.")
