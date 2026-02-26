--[[
    EQ Classic UI Texture POC
    Tests loading TGA textures from F:/lua/ui and rendering them with ImGui
    to recreate the old-school EverQuest UI aesthetic.
]]

local mq = require('mq')
local imgui = require('ImGui')

-- State
local State = {
    open = true,
    draw = false,
    selectedTexture = nil,
    previewScale = 1.0,
    filterText = "",
    showOnlyLoaded = false,
    columns = 4,
}

-- Texture path
local UI_PATH = "F:/lua/ui/"

-- All texture files organized by category
local TextureFiles = {
    -- Window pieces & UI elements
    { category = "Window Pieces", files = {
        "window_pieces01.tga", "window_pieces02.tga", "window_pieces03.tga",
        "window_pieces04.tga", "window_pieces05.tga", "window_pieces06.tga",
        "window_pieces07.tga",
    }},
    { category = "Classic Pieces", files = {
        "classic_pieces01.tga", "classic_pieces02.tga", "classic_pieces03.tga",
        "classic_pieces04.tga", "classic_pieces05.tga",
    }},
    { category = "EQLS Window Pieces", files = {
        "EQLS_window_pieces_01.tga", "EQLS_window_pieces_02.tga",
        "EQLS_WndBorder_01.tga", "EQLS_WndBorder_02.tga", "EQLS_WndBorder_03.tga",
        "EQLS_WndBorder_04.tga", "EQLS_WndBorder_05.tga", "EQLS_WndBorder_06.tga",
    }},
    { category = "Backgrounds", files = {
        "wnd_bg_dark_rock.tga", "wnd_bg_light_rock.tga",
        "background_dark.tga", "background_light.tga",
        "classic_bg_left.tga", "classic_bg_right.tga",
        "shade.tga",
    }},
    { category = "EQLS Backgrounds", files = {
        "EQLS_background_01.tga", "EQLS_background_02.tga", "EQLS_background_03.tga",
        "EQLS_background_04.tga", "EQLS_background_05.tga", "EQLS_background_06.tga",
        "EQLS_BlackFill.tga",
    }},
    { category = "Class Art", files = {
        "bard01.tga", "beastlord01.tga",
        "Berserker01.tga", "Berserker02.tga",
        "cleric01.tga", "cleric02.tga",
        "druid01.tga", "druid02.tga",
        "enchanter01.tga",
        "magician01.tga", "magician02.tga", "magician03.tga",
        "monk01.tga", "monk02.tga",
        "necromancer01.tga", "necromancer02.tga",
        "paladin01.tga", "paladin02.tga",
        "ranger01.tga", "ranger02.tga",
        "rogue01.tga",
        "shadowknight01.tga", "shadowknight02.tga",
        "shaman01.tga",
        "warrior01.tga", "warrior02.tga", "warrior03.tga",
        "wizard01.tga", "wizard02.tga",
    }},
    { category = "Spell Icons", files = {
        "Spell_Icons.tga",
        "spells01.tga", "spells02.tga", "spells03.tga", "spells04.tga",
        "spells05.tga", "spells06.tga", "spells07.tga",
        "gemicons01.tga", "gemicons02.tga", "gemicons03.tga",
    }},
    { category = "Spellbook", files = {
        "spellbook01.tga", "spellbook02.tga", "spellbook03.tga", "spellbook04.tga",
    }},
    { category = "UI Elements", files = {
        "assist.tga", "AttackIndicator.tga", "TargetBox.tga", "TargetIndicator.tga",
        "scrollbar_gutter.tga", "scrollbar_Hgutter.tga", "EQLS_scrollbar_gutter.tga",
        "menuicons01.tga",
        "classic_chat01.tga", "classic_debug01.tga",
    }},
    { category = "Drag Items", files = {
        "dragitem1.tga", "dragitem2.tga", "dragitem3.tga", "dragitem4.tga",
        "dragitem5.tga", "dragitem6.tga", "dragitem7.tga", "dragitem8.tga",
        "dragitem9.tga", "dragitem10.tga", "dragitem11.tga", "dragitem12.tga",
        "dragitem13.tga", "dragitem14.tga", "dragitem15.tga", "dragitem16.tga",
        "dragitem17.tga", "dragitem18.tga", "dragitem19.tga", "dragitem20.tga",
        "dragitem21.tga", "dragitem22.tga", "dragitem23.tga", "dragitem24.tga",
        "dragitem25.tga", "dragitem26.tga", "dragitem27.tga", "dragitem28.tga",
        "dragitem29.tga", "dragitem30.tga", "dragitem31.tga", "dragitem32.tga",
        "dragitem33.tga", "dragitem34.tga",
    }},
    { category = "Carts", files = {
        "cart01.tga", "cart02.tga", "cart03.tga", "cart04.tga",
    }},
    { category = "Notes", files = {
        "note01.tga", "note02.tga", "note03.tga", "note04.tga",
    }},
    { category = "Marks", files = {
        "mark0.tga", "mark1.tga", "mark2.tga", "mark3.tga",
        "mark4.tga", "mark5.tga", "mark6.tga",
    }},
    { category = "Start City", files = {
        "startcity_top01.tga", "startcity_top02.tga", "startcity_top03.tga",
        "startcity_bottom04.tga", "startcity_bottom05.tga", "startcity_bottom06.tga",
    }},
    { category = "EQLS Splash", files = {
        "EQLS_ESRBSplash01.tga", "EQLS_ESRBSplash02.tga", "EQLS_ESRBSplash03.tga",
        "EQLS_ESRBSplash04.tga", "EQLS_ESRBSplash05.tga", "EQLS_ESRBSplash06.tga",
        "EQLS_SOESplash01.tga", "EQLS_SOESplash02.tga", "EQLS_SOESplash03.tga",
        "EQLS_SOESplash04.tga", "EQLS_SOESplash05.tga", "EQLS_SOESplash06.tga",
    }},
}

-- Texture cache: filename -> { texture, status, error }
local TextureCache = {}
local LoadStats = { total = 0, loaded = 0, failed = 0, pending = 0 }

-- Count total textures
local function CountTextures()
    local count = 0
    for _, cat in ipairs(TextureFiles) do
        count = count + #cat.files
    end
    return count
end

-- Load a single texture
local function LoadTexture(filename)
    if TextureCache[filename] then
        return TextureCache[filename]
    end

    local entry = { texture = nil, status = "pending", error = nil }
    TextureCache[filename] = entry

    local ok, result = pcall(function()
        return mq.CreateTexture(UI_PATH .. filename)
    end)

    if ok and result then
        entry.texture = result
        entry.status = "loaded"
        LoadStats.loaded = LoadStats.loaded + 1
    else
        entry.status = "failed"
        entry.error = tostring(result)
        LoadStats.failed = LoadStats.failed + 1
    end

    LoadStats.pending = LoadStats.pending - 1
    return entry
end

-- Load all textures
local function LoadAllTextures()
    LoadStats = { total = CountTextures(), loaded = 0, failed = 0, pending = CountTextures() }
    TextureCache = {}

    for _, cat in ipairs(TextureFiles) do
        for _, filename in ipairs(cat.files) do
            LoadTexture(filename)
        end
    end
end

-- Filter check
local function PassesFilter(filename)
    if State.filterText == "" then return true end
    return string.lower(filename):find(string.lower(State.filterText), 1, true) ~= nil
end

-- Render thumbnail grid for a category
local function RenderCategoryGrid(category, files)
    local thumbSize = 64
    local spacing = 8
    local availWidth = ImGui.GetContentRegionAvail()
    local cols = math.max(1, math.floor(availWidth / (thumbSize + spacing)))

    local visibleFiles = {}
    for _, filename in ipairs(files) do
        local entry = TextureCache[filename]
        if PassesFilter(filename) then
            if not State.showOnlyLoaded or (entry and entry.status == "loaded") then
                table.insert(visibleFiles, filename)
            end
        end
    end

    if #visibleFiles == 0 then return false end

    if ImGui.CollapsingHeader(category .. " (" .. #visibleFiles .. ")") then
        local col = 0
        for _, filename in ipairs(visibleFiles) do
            local entry = TextureCache[filename]

            if col > 0 then
                ImGui.SameLine()
            end

            ImGui.BeginGroup()

            -- Draw thumbnail or placeholder
            if entry and entry.status == "loaded" and entry.texture then
                local texId = entry.texture:GetTextureID()
                if texId then
                    -- Clickable image
                    if ImGui.ImageButton(filename, texId, ImVec2(thumbSize, thumbSize)) then
                        State.selectedTexture = filename
                    end
                else
                    ImGui.Button("No ID", ImVec2(thumbSize, thumbSize))
                end
            elseif entry and entry.status == "failed" then
                ImGui.PushStyleColor(ImGuiCol.Button, 0.5, 0.1, 0.1, 1)
                ImGui.Button("ERR", ImVec2(thumbSize, thumbSize))
                ImGui.PopStyleColor()
            else
                ImGui.PushStyleColor(ImGuiCol.Button, 0.2, 0.2, 0.2, 1)
                ImGui.Button("...", ImVec2(thumbSize, thumbSize))
                ImGui.PopStyleColor()
            end

            -- Tooltip with filename
            if ImGui.IsItemHovered() then
                ImGui.BeginTooltip()
                ImGui.Text(filename)
                if entry then
                    if entry.status == "loaded" and entry.texture then
                        ImGui.Text("Size: %s", tostring(entry.texture.size or "?"))
                    elseif entry.status == "failed" then
                        ImGui.TextColored(1, 0.3, 0.3, 1, "Error: %s", entry.error or "unknown")
                    end
                end
                ImGui.EndTooltip()
            end

            ImGui.EndGroup()

            col = col + 1
            if col >= cols then
                col = 0
            end
        end

        ImGui.Spacing()
        return true
    end

    return false
end

-- Render the selected texture preview
local function RenderPreview()
    if not State.selectedTexture then
        ImGui.Text("Click a texture to preview")
        return
    end

    local entry = TextureCache[State.selectedTexture]
    if not entry or entry.status ~= "loaded" or not entry.texture then
        ImGui.Text("Texture not available")
        return
    end

    local tex = entry.texture
    local texId = tex:GetTextureID()
    if not texId then
        ImGui.Text("No texture ID")
        return
    end

    -- Info
    ImGui.TextColored(1, 0.8, 0.2, 1, State.selectedTexture)
    if tex.size then
        ImGui.Text("Size: %s", tostring(tex.size))
    end

    -- Scale slider
    State.previewScale = ImGui.SliderFloat("Scale", State.previewScale, 0.25, 4.0, "%.2fx")

    ImGui.Separator()

    -- Get texture dimensions (assume 256x256 if unknown)
    local texW, texH = 256, 256
    if tex.size then
        -- tex.size might be an ImVec2 or table
        if type(tex.size) == "table" then
            texW = tex.size[1] or tex.size.x or 256
            texH = tex.size[2] or tex.size.y or 256
        end
    end

    local displayW = texW * State.previewScale
    local displayH = texH * State.previewScale

    -- Scrollable child for large previews
    if ImGui.BeginChild("PreviewChild", 0, 0, true, ImGuiWindowFlags.HorizontalScrollbar) then
        ImGui.Image(texId, ImVec2(displayW, displayH), ImVec2(0, 0), ImVec2(1, 1))
    end
    ImGui.EndChild()
end

-- Render the main UI
local function RenderUI()
    if not State.open then return end

    local flags = bit32.bor(
        ImGuiWindowFlags.MenuBar
    )

    ImGui.SetNextWindowSize(900, 700, ImGuiCond.FirstUseEver)

    State.open, State.draw = ImGui.Begin("EQ Classic UI Texture Browser", State.open, flags)

    if State.draw then
        -- Menu bar
        if ImGui.BeginMenuBar() then
            if ImGui.BeginMenu("Actions") then
                if ImGui.MenuItem("Reload All Textures") then
                    LoadAllTextures()
                end
                ImGui.Separator()
                if ImGui.MenuItem("Close") then
                    State.open = false
                end
                ImGui.EndMenu()
            end
            ImGui.EndMenuBar()
        end

        -- Stats bar
        ImGui.TextColored(0.5, 0.8, 1, 1, "Textures:")
        ImGui.SameLine()
        ImGui.TextColored(0.3, 1, 0.3, 1, "%d loaded", LoadStats.loaded)
        ImGui.SameLine()
        if LoadStats.failed > 0 then
            ImGui.TextColored(1, 0.3, 0.3, 1, "/ %d failed", LoadStats.failed)
            ImGui.SameLine()
        end
        ImGui.Text("/ %d total", LoadStats.total)

        ImGui.SameLine(ImGui.GetWindowWidth() - 250)
        ImGui.PushItemWidth(200)
        State.filterText = ImGui.InputTextWithHint("##filter", "Filter...", State.filterText)
        ImGui.PopItemWidth()

        ImGui.Separator()

        -- Two-column layout: browser | preview
        local availW, availH = ImGui.GetContentRegionAvail()
        local browserWidth = availW * 0.55

        -- Left: Texture browser
        if ImGui.BeginChild("Browser", browserWidth, availH - 4, true) then
            State.showOnlyLoaded = ImGui.Checkbox("Show only loaded", State.showOnlyLoaded)

            ImGui.Separator()

            for _, cat in ipairs(TextureFiles) do
                RenderCategoryGrid(cat.category, cat.files)
            end
        end
        ImGui.EndChild()

        ImGui.SameLine()

        -- Right: Preview
        if ImGui.BeginChild("Preview", 0, availH - 4, true) then
            ImGui.TextColored(1, 0.8, 0.2, 1, "Preview")
            ImGui.Separator()
            RenderPreview()
        end
        ImGui.EndChild()
    end

    ImGui.End()
end

-- Initialize
mq.imgui.init('EQTextureBrowser', RenderUI)

-- Load textures on startup
print("\ay[EQ Texture Browser]\ax Loading textures from F:/lua/ui ...")
LoadAllTextures()
print(string.format("\ay[EQ Texture Browser]\ax Loaded %d/%d textures (%d failed)",
    LoadStats.loaded, LoadStats.total, LoadStats.failed))

-- Main loop
while State.open do
    mq.delay(100)
end

print("\ay[EQ Texture Browser]\ax Closed.")
