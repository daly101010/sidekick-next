--[[
    EQ Classic UI Piece Editor
    Place and position individual texture pieces manually.

    Commands:
      /eqclassic - Toggle overlay
      /eqsettings - Toggle settings window
      /eqaddpiece - Add a new piece
]]

local mq = require('mq')
local imgui = require('ImGui')

-------------------------------------------------------------------------------
-- Configuration
-------------------------------------------------------------------------------
local UI_PATH = "F:/lua/UI_hd_xml/"

-- HD texture sizes from XML
local TEX_SIZE = 461
local TEX_SIZE_SIDEBAR_W = 230
local TEX_SIZE_SIDEBAR_H = 461

local State = {
    open = true,
    draw = false,
    showSettings = true,
    showAddPiece = false,
    selectedPiece = nil,
    dragPiece = nil,
    dragOffsetX = 0,
    dragOffsetY = 0,
}

-------------------------------------------------------------------------------
-- Placed Pieces - each piece has: name, anim, x, y, w, h, scale, visible
-------------------------------------------------------------------------------
local PlacedPieces = {}
local PieceIdCounter = 1

-------------------------------------------------------------------------------
-- Texture Management
-------------------------------------------------------------------------------
local Textures = {}
local TextureSizes = {}

local function LoadTexture(name, filename, w, h)
    local ok, result = pcall(function()
        return mq.CreateTexture(UI_PATH .. filename)
    end)
    if ok and result then
        Textures[name] = result
        TextureSizes[name] = { w = w or TEX_SIZE, h = h or TEX_SIZE }
        return true
    end
    print(string.format("\ar[EQ UI]\ax Failed to load %s", filename))
    return false
end

local function LoadAllTextures()
    LoadTexture("pieces01", "classic_pieces01_hd.tga", TEX_SIZE, TEX_SIZE)
    LoadTexture("pieces02", "classic_pieces02_hd.tga", TEX_SIZE, TEX_SIZE)
    LoadTexture("pieces03", "classic_pieces03_hd.tga", TEX_SIZE, TEX_SIZE)
    LoadTexture("bg_left", "classic_bg_left_hd.tga", TEX_SIZE_SIDEBAR_W, TEX_SIZE_SIDEBAR_H)
    LoadTexture("bg_right", "classic_bg_right_hd.tga", TEX_SIZE_SIDEBAR_W, TEX_SIZE_SIDEBAR_H)
    LoadTexture("chat", "classic_chat01_hd.tga", TEX_SIZE, TEX_SIZE)
    LoadTexture("rock_dark", "wnd_bg_dark_rock_hd.tga", TEX_SIZE, TEX_SIZE)
    LoadTexture("window01", "window_pieces01_hd.tga", TEX_SIZE, TEX_SIZE)
    LoadTexture("window02", "window_pieces02_hd.tga", TEX_SIZE, TEX_SIZE)
end

-------------------------------------------------------------------------------
-- Available Animation Definitions (from XML)
-------------------------------------------------------------------------------
local AvailableAnims = {
    -- Left sidebar background (full texture, no UV slice)
    { name = "Left BG (full)", tex = "bg_left", x = 0, y = 0, w = 230, h = 461 },
    { name = "Right BG (full)", tex = "bg_right", x = 0, y = 0, w = 230, h = 461 },

    -- Menu buttons (classic_pieces01_hd.tga)
    { name = "HELP Btn Normal", tex = "pieces01", x = 0, y = 29, w = 126, h = 34 },
    { name = "HELP Btn Pressed", tex = "pieces01", x = 128, y = 29, w = 126, h = 34 },
    { name = "OPTIONS Btn Normal", tex = "pieces01", x = 0, y = 65, w = 126, h = 34 },
    { name = "OPTIONS Btn Pressed", tex = "pieces01", x = 128, y = 65, w = 126, h = 34 },
    { name = "FRIENDS Btn Normal", tex = "pieces01", x = 0, y = 101, w = 126, h = 34 },
    { name = "FRIENDS Btn Pressed", tex = "pieces01", x = 128, y = 101, w = 126, h = 34 },

    -- Top bar
    { name = "Left BG Top", tex = "pieces01", x = 0, y = 0, w = 214, h = 13 },

    -- Divider
    { name = "Left Divider", tex = "pieces01", x = 0, y = 137, w = 214, h = 20 },

    -- Arrows
    { name = "Prev Normal", tex = "pieces01", x = 0, y = 167, w = 38, h = 23 },
    { name = "Prev Pressed", tex = "pieces01", x = 0, y = 214, w = 38, h = 23 },
    { name = "Next Normal", tex = "pieces01", x = 0, y = 191, w = 38, h = 23 },
    { name = "Next Pressed", tex = "pieces01", x = 0, y = 238, w = 38, h = 23 },

    -- Inv background areas
    { name = "Inv BG Normal", tex = "pieces01", x = 274, y = 146, w = 128, h = 315 },
    { name = "Inv Normal", tex = "pieces01", x = 40, y = 167, w = 115, h = 279 },
    { name = "Inv FlyBy", tex = "pieces01", x = 157, y = 167, w = 115, h = 279 },

    -- Gauges (classic_pieces02_hd.tga)
    { name = "Gauge BG", tex = "pieces02", x = 18, y = 371, w = 117, h = 22 },
    { name = "Gauge Fill Red", tex = "pieces02", x = 18, y = 436, w = 117, h = 22 },
    { name = "Gauge Fill Blue", tex = "pieces02", x = 137, y = 371, w = 117, h = 22 },
    { name = "Gauge Fill Yellow", tex = "pieces02", x = 137, y = 436, w = 117, h = 22 },
    { name = "Gauge Fill Cyan", tex = "pieces02", x = 137, y = 392, w = 117, h = 22 },
    { name = "Gauge Lines", tex = "pieces02", x = 18, y = 392, w = 117, h = 22 },
    { name = "Gauge Cap L", tex = "pieces02", x = 0, y = 371, w = 18, h = 22 },
    { name = "Gauge Cap R", tex = "pieces02", x = 0, y = 392, w = 18, h = 22 },

    -- Inv slot frame
    { name = "Inv Slot Frame", tex = "pieces02", x = 0, y = 0, w = 86, h = 86 },

    -- Inv slot icons
    { name = "Inv Ear", tex = "pieces02", x = 0, y = 148, w = 72, h = 72 },
    { name = "Inv Wrist", tex = "pieces02", x = 74, y = 148, w = 72, h = 72 },
    { name = "Inv Ring", tex = "pieces02", x = 148, y = 148, w = 72, h = 72 },
    { name = "Inv Main 1", tex = "pieces02", x = 0, y = 221, w = 72, h = 72 },
    { name = "Inv Main 2", tex = "pieces02", x = 74, y = 221, w = 72, h = 72 },
    { name = "Inv Main 3", tex = "pieces02", x = 148, y = 221, w = 72, h = 72 },
    { name = "Inv Main 4", tex = "pieces02", x = 221, y = 221, w = 72, h = 72 },
    { name = "Inv Main 5", tex = "pieces02", x = 0, y = 295, w = 72, h = 72 },
    { name = "Inv Main 6", tex = "pieces02", x = 74, y = 295, w = 72, h = 72 },

    -- Done/Button
    { name = "Btn Done Normal", tex = "pieces02", x = 232, y = 0, w = 86, h = 34 },
    { name = "Btn Done Pressed", tex = "pieces02", x = 232, y = 36, w = 86, h = 34 },

    -- Classic borders
    { name = "Border TL", tex = "pieces02", x = 0, y = 92, w = 13, h = 13 },
    { name = "Border Top", tex = "pieces02", x = 14, y = 92, w = 173, h = 13 },
    { name = "Border TR", tex = "pieces02", x = 189, y = 92, w = 13, h = 13 },
    { name = "Border BL", tex = "pieces02", x = 0, y = 106, w = 13, h = 13 },
    { name = "Border Bottom", tex = "pieces02", x = 14, y = 106, w = 173, h = 13 },
    { name = "Border BR", tex = "pieces02", x = 189, y = 106, w = 13, h = 13 },

    -- Title bar
    { name = "Title Left", tex = "pieces02", x = 0, y = 121, w = 7, h = 25 },
    { name = "Title Middle", tex = "pieces02", x = 9, y = 121, w = 158, h = 25 },
    { name = "Title Right", tex = "pieces02", x = 169, y = 121, w = 7, h = 25 },
    { name = "Target Name Box", tex = "pieces02", x = 178, y = 121, w = 185, h = 25 },

    -- Selector buttons (window_pieces02_hd.tga)
    { name = "Hotbox Btn Normal", tex = "window02", x = 140, y = 216, w = 47, h = 47 },
    { name = "Hotbox Btn Pressed", tex = "window02", x = 140, y = 310, w = 47, h = 47 },
    { name = "Actions Btn Normal", tex = "window02", x = 0, y = 216, w = 47, h = 47 },
    { name = "Actions Btn Pressed", tex = "window02", x = 0, y = 310, w = 47, h = 47 },
    { name = "Spells Btn Normal", tex = "window02", x = 47, y = 216, w = 47, h = 47 },
    { name = "Spells Btn Pressed", tex = "window02", x = 47, y = 310, w = 47, h = 47 },
    { name = "Options Btn Normal", tex = "window02", x = 94, y = 216, w = 47, h = 47 },
    { name = "Options Btn Pressed", tex = "window02", x = 94, y = 310, w = 47, h = 47 },
    { name = "Pet Btn Normal", tex = "window02", x = 186, y = 216, w = 47, h = 47 },
    { name = "Pet Btn Pressed", tex = "window02", x = 186, y = 310, w = 47, h = 47 },
    { name = "Buff Btn Normal", tex = "window02", x = 232, y = 216, w = 47, h = 47 },
    { name = "Buff Btn Pressed", tex = "window02", x = 232, y = 310, w = 47, h = 47 },
    { name = "Song Btn Normal", tex = "window02", x = 280, y = 216, w = 47, h = 47 },
    { name = "Song Btn Pressed", tex = "window02", x = 280, y = 310, w = 47, h = 47 },
    { name = "Guild Btn Normal", tex = "window02", x = 328, y = 216, w = 47, h = 47 },
    { name = "Guild Btn Pressed", tex = "window02", x = 328, y = 310, w = 47, h = 47 },
    { name = "Map Btn Normal", tex = "window02", x = 376, y = 216, w = 47, h = 47 },
    { name = "Map Btn Pressed", tex = "window02", x = 376, y = 310, w = 47, h = 47 },
    { name = "Friends Btn Normal", tex = "window02", x = 0, y = 356, w = 47, h = 47 },
    { name = "Friends Btn Pressed", tex = "window02", x = 0, y = 402, w = 47, h = 47 },

    -- Scrollbar pieces
    { name = "VSB Up Normal", tex = "window01", x = 18, y = 162, w = 20, h = 32 },
    { name = "VSB Up Pressed", tex = "window01", x = 61, y = 162, w = 20, h = 32 },
    { name = "VSB Down Normal", tex = "window01", x = 18, y = 198, w = 20, h = 32 },
    { name = "VSB Down Pressed", tex = "window01", x = 61, y = 198, w = 20, h = 32 },
    { name = "VSB Thumb Normal", tex = "window01", x = 104, y = 162, w = 20, h = 32 },

    -- Close/Minimize buttons
    { name = "Close Btn Normal", tex = "window01", x = 180, y = 162, w = 22, h = 22 },
    { name = "Close Btn Pressed", tex = "window01", x = 223, y = 162, w = 22, h = 22 },
    { name = "Minimize Btn Normal", tex = "window01", x = 245, y = 164, w = 22, h = 22 },
    { name = "Minimize Btn Pressed", tex = "window01", x = 288, y = 164, w = 22, h = 22 },

    -- Cursors
    { name = "Cursor Default", tex = "window01", x = 414, y = 72, w = 40, h = 40 },
    { name = "Cursor Drag", tex = "window01", x = 180, y = 342, w = 40, h = 40 },

    -- Chat background
    { name = "Chat BG (full)", tex = "chat", x = 0, y = 0, w = 461, h = 461 },

    -- Rock background
    { name = "Rock Dark (full)", tex = "rock_dark", x = 0, y = 0, w = 461, h = 461 },
}

-------------------------------------------------------------------------------
-- Drawing Helpers
-------------------------------------------------------------------------------
local function GetUV(anim)
    local size = TextureSizes[anim.tex]
    if not size then return nil end
    return {
        u0 = anim.x / size.w,
        v0 = anim.y / size.h,
        u1 = (anim.x + anim.w) / size.w,
        v1 = (anim.y + anim.h) / size.h,
    }
end

local function DrawPiece(dl, piece)
    if not piece.visible then return end

    local anim = piece.anim
    local tex = Textures[anim.tex]
    if not tex then return end
    local texId = tex:GetTextureID()
    if not texId then return end

    local w = piece.w * piece.scale
    local h = piece.h * piece.scale
    local uv = GetUV(anim)
    if not uv then return end

    pcall(function()
        dl:AddImage(texId, ImVec2(piece.x, piece.y), ImVec2(piece.x + w, piece.y + h),
            ImVec2(uv.u0, uv.v0), ImVec2(uv.u1, uv.v1))
    end)

    -- Draw selection box if selected
    if State.selectedPiece == piece.id then
        pcall(function()
            dl:AddRect(ImVec2(piece.x - 2, piece.y - 2),
                ImVec2(piece.x + w + 2, piece.y + h + 2), 0xFF00FF00, 0, 0, 2)
        end)
    end
end

-------------------------------------------------------------------------------
-- Piece Management
-------------------------------------------------------------------------------
local function AddPiece(animDef, x, y)
    local piece = {
        id = PieceIdCounter,
        name = animDef.name .. " #" .. PieceIdCounter,
        anim = animDef,
        x = x or 100,
        y = y or 100,
        w = animDef.w,
        h = animDef.h,
        scale = 0.5,
        visible = true,
    }
    PieceIdCounter = PieceIdCounter + 1
    table.insert(PlacedPieces, piece)
    State.selectedPiece = piece.id
    return piece
end

local function RemovePiece(id)
    for i, p in ipairs(PlacedPieces) do
        if p.id == id then
            table.remove(PlacedPieces, i)
            if State.selectedPiece == id then
                State.selectedPiece = nil
            end
            return
        end
    end
end

local function GetPieceById(id)
    for _, p in ipairs(PlacedPieces) do
        if p.id == id then return p end
    end
    return nil
end

local function GetPieceAtPos(mx, my)
    -- Check in reverse order (top pieces first)
    for i = #PlacedPieces, 1, -1 do
        local p = PlacedPieces[i]
        if p.visible then
            local w = p.w * p.scale
            local h = p.h * p.scale
            if mx >= p.x and mx <= p.x + w and my >= p.y and my <= p.y + h then
                return p
            end
        end
    end
    return nil
end

local function MovePieceUp(id)
    for i, p in ipairs(PlacedPieces) do
        if p.id == id and i < #PlacedPieces then
            PlacedPieces[i], PlacedPieces[i + 1] = PlacedPieces[i + 1], PlacedPieces[i]
            return
        end
    end
end

local function MovePieceDown(id)
    for i, p in ipairs(PlacedPieces) do
        if p.id == id and i > 1 then
            PlacedPieces[i], PlacedPieces[i - 1] = PlacedPieces[i - 1], PlacedPieces[i]
            return
        end
    end
end

-------------------------------------------------------------------------------
-- Settings Window
-------------------------------------------------------------------------------
local function RenderAddPieceWindow()
    if not State.showAddPiece then return end

    ImGui.SetNextWindowSize(300, 500, ImGuiCond.FirstUseEver)
    State.showAddPiece = ImGui.Begin("Add Piece", State.showAddPiece)

    ImGui.Text("Click a piece to add it:")
    ImGui.Separator()

    if ImGui.BeginChild("##pieces", 0, 0, true) then
        for _, anim in ipairs(AvailableAnims) do
            if ImGui.Selectable(anim.name .. " (" .. anim.w .. "x" .. anim.h .. ")") then
                AddPiece(anim, 200, 200)
                State.showAddPiece = false
            end
        end
    end
    ImGui.EndChild()

    ImGui.End()
end

local function RenderSettings()
    if not State.showSettings then return end

    ImGui.SetNextWindowSize(350, 600, ImGuiCond.FirstUseEver)
    State.showSettings = ImGui.Begin("EQ Classic UI Editor", State.showSettings)

    -- Add piece button
    if ImGui.Button("+ Add Piece") then
        State.showAddPiece = true
    end
    ImGui.SameLine()
    if ImGui.Button("Clear All") then
        PlacedPieces = {}
        State.selectedPiece = nil
    end
    ImGui.SameLine()
    if ImGui.Button("Print Lua") then
        print("\ay-- Placed Pieces --\ax")
        for _, p in ipairs(PlacedPieces) do
            print(string.format('  { name="%s", x=%d, y=%d, w=%d, h=%d, scale=%.2f },',
                p.anim.name, p.x, p.y, p.w, p.h, p.scale))
        end
    end

    ImGui.Separator()
    ImGui.Text("Pieces (" .. #PlacedPieces .. "):")

    -- Piece list
    if ImGui.BeginChild("##pieceList", 0, 200, true) then
        for i, p in ipairs(PlacedPieces) do
            local flags = ImGuiSelectableFlags.None
            local selected = State.selectedPiece == p.id

            ImGui.PushID(p.id)

            -- Visibility toggle
            local vis = p.visible
            vis = ImGui.Checkbox("##vis", vis)
            p.visible = vis
            ImGui.SameLine()

            -- Selectable name
            if ImGui.Selectable(p.name, selected) then
                State.selectedPiece = p.id
            end

            ImGui.PopID()
        end
    end
    ImGui.EndChild()

    ImGui.Separator()

    -- Selected piece properties
    local selected = GetPieceById(State.selectedPiece)
    if selected then
        ImGui.Text("Selected: " .. selected.name)
        ImGui.Separator()

        -- Position
        ImGui.Text("Position:")
        selected.x = ImGui.SliderInt("X", selected.x, 0, 3840)
        selected.y = ImGui.SliderInt("Y", selected.y, 0, 1080)

        -- Size
        ImGui.Text("Size:")
        selected.w = ImGui.SliderInt("Width", selected.w, 1, 500)
        selected.h = ImGui.SliderInt("Height", selected.h, 1, 500)
        selected.scale = ImGui.SliderFloat("Scale", selected.scale, 0.1, 3.0, "%.2f")

        -- Reset size
        if ImGui.Button("Reset Size") then
            selected.w = selected.anim.w
            selected.h = selected.anim.h
        end
        ImGui.SameLine()
        if ImGui.Button("Reset Scale") then
            selected.scale = 0.5
        end

        ImGui.Separator()

        -- Layer controls
        if ImGui.Button("Move Up") then
            MovePieceUp(selected.id)
        end
        ImGui.SameLine()
        if ImGui.Button("Move Down") then
            MovePieceDown(selected.id)
        end
        ImGui.SameLine()
        if ImGui.Button("Delete") then
            RemovePiece(selected.id)
        end

        ImGui.Separator()

        -- Piece info
        ImGui.TextColored(0.6, 0.6, 0.6, 1, "Texture: " .. selected.anim.tex)
        ImGui.TextColored(0.6, 0.6, 0.6, 1, string.format("UV: %d,%d %dx%d",
            selected.anim.x, selected.anim.y, selected.anim.w, selected.anim.h))
        ImGui.TextColored(0.6, 0.6, 0.6, 1, string.format("Display: %.0fx%.0f",
            selected.w * selected.scale, selected.h * selected.scale))
    else
        ImGui.TextColored(0.5, 0.5, 0.5, 1, "No piece selected")
        ImGui.TextColored(0.5, 0.5, 0.5, 1, "Click a piece in the list or on screen")
    end

    ImGui.End()
end

-------------------------------------------------------------------------------
-- Main Render
-------------------------------------------------------------------------------
local function RenderUI()
    if not State.open then return end

    local viewport = ImGui.GetMainViewport()
    local vpPos = viewport.Pos
    local vpSize = viewport.Size

    ImGui.SetNextWindowPos(vpPos.x, vpPos.y)
    ImGui.SetNextWindowSize(vpSize.x, vpSize.y)

    local flags = bit32.bor(
        ImGuiWindowFlags.NoTitleBar,
        ImGuiWindowFlags.NoResize,
        ImGuiWindowFlags.NoMove,
        ImGuiWindowFlags.NoScrollbar,
        ImGuiWindowFlags.NoScrollWithMouse,
        ImGuiWindowFlags.NoCollapse,
        ImGuiWindowFlags.NoBackground,
        ImGuiWindowFlags.NoBringToFrontOnFocus,
        ImGuiWindowFlags.NoFocusOnAppearing,
        ImGuiWindowFlags.NoNavFocus,
        ImGuiWindowFlags.NoNav
    )

    ImGui.PushStyleVar(ImGuiStyleVar.WindowPadding, 0, 0)
    ImGui.PushStyleVar(ImGuiStyleVar.WindowBorderSize, 0)

    State.open, State.draw = ImGui.Begin("##EQClassicOverlay", State.open, flags)

    if State.draw then
        local dl = ImGui.GetWindowDrawList()

        -- Handle mouse interaction
        local mx, my = ImGui.GetMousePos()
        local isHovered = ImGui.IsWindowHovered()

        -- Click to select
        if isHovered and ImGui.IsMouseClicked(ImGuiMouseButton.Left) then
            local clickedPiece = GetPieceAtPos(mx, my)
            if clickedPiece then
                State.selectedPiece = clickedPiece.id
                State.dragPiece = clickedPiece.id
                State.dragOffsetX = mx - clickedPiece.x
                State.dragOffsetY = my - clickedPiece.y
            else
                State.selectedPiece = nil
            end
        end

        -- Drag to move
        if State.dragPiece and ImGui.IsMouseDown(ImGuiMouseButton.Left) then
            local draggedPiece = GetPieceById(State.dragPiece)
            if draggedPiece then
                draggedPiece.x = math.floor(mx - State.dragOffsetX)
                draggedPiece.y = math.floor(my - State.dragOffsetY)
            end
        else
            State.dragPiece = nil
        end

        -- Draw all pieces
        for _, piece in ipairs(PlacedPieces) do
            DrawPiece(dl, piece)
        end
    end

    ImGui.End()
    ImGui.PopStyleVar(2)

    RenderSettings()
    RenderAddPieceWindow()
end

-------------------------------------------------------------------------------
-- Init
-------------------------------------------------------------------------------
mq.imgui.init('EQClassicOverlay', RenderUI)

mq.bind('/eqclassic', function()
    State.open = not State.open
    print(string.format("\ay[EQ Classic UI]\ax Overlay %s", State.open and "shown" or "hidden"))
end)

mq.bind('/eqsettings', function()
    State.showSettings = not State.showSettings
end)

mq.bind('/eqaddpiece', function()
    State.showAddPiece = not State.showAddPiece
end)

print("\ay[EQ Classic UI]\ax Loading HD textures...")
LoadAllTextures()

local count = 0
for _ in pairs(Textures) do count = count + 1 end
print(string.format("\ay[EQ Classic UI]\ax Loaded %d textures.", count))
print("\ay[EQ Classic UI]\ax Commands: /eqclassic, /eqsettings, /eqaddpiece")
print("\ay[EQ Classic UI]\ax Click and drag pieces to position them!")

while State.open or mq.TLO.MacroQuest.GameState() == "INGAME" do
    mq.delay(100)
end
