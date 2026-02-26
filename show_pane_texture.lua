-- Standalone viewer: draws sk_pane_target.tga in its own window
local mq = require('mq')
local imgui = require('ImGui')

local UI_PATH = 'F:/lua/UI/'
local tex = nil
local open = true

local function render()
    if not open then return end

    -- Load texture once
    if not tex then
        local ok, t = pcall(function()
            return mq.CreateTexture(UI_PATH .. 'sk_pane_target_v2.tga')
        end)
        if ok and t then tex = t end
    end

    local flags = bit32.bor(
        ImGuiWindowFlags.AlwaysAutoResize,
        ImGuiWindowFlags.NoScrollbar
    )

    open = imgui.Begin('Pane Texture Preview', open, flags)
    if open then
        if tex then
            local texId = tex:GetTextureID()
            if texId then
                imgui.Image(texId, ImVec2(280, 600))
            else
                imgui.Text('Failed to get texture ID')
            end
        else
            imgui.Text('Loading texture...')
        end
    end
    imgui.End()
end

mq.imgui.init('PaneTexturePreview', render)

while open do
    mq.delay(100)
end
