-- ============================================================
-- Texture Renderer Demo
-- ============================================================
-- Standalone demo to test EQ texture rendering
-- Run with: /lua run sidekick-next/texture_demo

local mq = require('mq')
local imgui = require('ImGui')

-- State
local State = {
    open = true,
    draw = false,

    -- Test values
    healthPct = 0.75,
    manaPct = 0.60,
    endPct = 0.90,
    cooldownPct = 0.5,

    -- Diagnostics
    diagnostics = {},
    lastDiagUpdate = 0,
}

-- Try to load modules
local TextureRenderer = nil
local Data = nil

local function updateDiagnostics()
    local diag = {}

    -- Check eq_ui_data
    table.insert(diag, '=== Data Loading ===')
    local dataOk, data = pcall(require, 'sidekick-next.eq_ui_data')
    if dataOk and data then
        Data = data
        table.insert(diag, 'eq_ui_data: LOADED')

        -- Count textures
        local texCount = 0
        if data.textures then
            for _ in pairs(data.textures) do texCount = texCount + 1 end
        end
        table.insert(diag, string.format('  textures: %d', texCount))

        -- Count anims
        local animCount = 0
        if data.anims then
            for _ in pairs(data.anims) do animCount = animCount + 1 end
        end
        table.insert(diag, string.format('  anims: %d', animCount))

        -- Check for specific anims we need
        local neededAnims = {
            'A_Classic_GaugeBackground',
            'A_Classic_GaugeFill',
            'A_Classic_GaugeFill2',
            'A_BtnNormal',
            'A_BtnPressed',
        }
        table.insert(diag, '  Key animations:')
        for _, animName in ipairs(neededAnims) do
            local found = data.anims and data.anims[animName]
            table.insert(diag, string.format('    %s: %s', animName, found and 'FOUND' or 'MISSING'))
        end
    else
        table.insert(diag, 'eq_ui_data: FAILED - ' .. tostring(data))
    end

    -- Check texture_renderer
    table.insert(diag, '')
    table.insert(diag, '=== Texture Renderer ===')
    local trOk, tr = pcall(require, 'sidekick-next.ui.texture_renderer')
    if trOk and tr then
        TextureRenderer = tr
        table.insert(diag, 'texture_renderer: LOADED')

        -- Check isAvailable
        if tr.isAvailable then
            local avail = tr.isAvailable()
            table.insert(diag, string.format('  isAvailable(): %s', tostring(avail)))
        else
            table.insert(diag, '  isAvailable: function missing')
        end

        -- Check key functions
        local funcs = {'drawClassicGauge', 'drawClassicButton', 'drawIconHolder', 'getAnimUV'}
        for _, fn in ipairs(funcs) do
            table.insert(diag, string.format('  %s: %s', fn, tr[fn] and 'present' or 'MISSING'))
        end

        -- Try to get a texture
        if tr.getAnimUV then
            local uvData = tr.getAnimUV('A_Classic_GaugeBackground')
            if uvData then
                table.insert(diag, string.format('  getAnimUV test: OK (tex=%s)', tostring(uvData.tex)))
            else
                table.insert(diag, '  getAnimUV test: FAILED (nil result)')
            end
        end
    else
        table.insert(diag, 'texture_renderer: FAILED - ' .. tostring(tr))
    end

    -- Check UI path info
    table.insert(diag, '')
    table.insert(diag, '=== Texture Path Info ===')
    table.insert(diag, 'Expected UI path: F:/lua/UI/')
    table.insert(diag, 'Required files:')
    table.insert(diag, '  - classic_pieces02.tga (gauges)')
    table.insert(diag, '  - window_pieces03.tga (buttons)')
    table.insert(diag, string.format('mq.CreateTexture: %s', mq.CreateTexture and 'available' or 'NOT AVAILABLE'))

    State.diagnostics = diag
end

local function renderDemo()
    if not State.open then return end

    imgui.SetNextWindowSize(600, 500, ImGuiCond.FirstUseEver)
    State.open, State.draw = imgui.Begin('Texture Renderer Demo', State.open)

    if State.draw then
        -- Update diagnostics periodically
        if os.clock() - State.lastDiagUpdate > 2.0 then
            State.lastDiagUpdate = os.clock()
            updateDiagnostics()
        end

        -- Diagnostics section
        if imgui.CollapsingHeader('Diagnostics', ImGuiTreeNodeFlags.DefaultOpen) then
            for _, line in ipairs(State.diagnostics) do
                if line:match('^===') then
                    imgui.TextColored(1, 1, 0, 1, line)
                elseif line:match('FAILED') or line:match('MISSING') or line:match('NOT FOUND') then
                    imgui.TextColored(1, 0.3, 0.3, 1, line)
                elseif line:match('LOADED') or line:match('FOUND') or line:match('OK') or line:match('present') then
                    imgui.TextColored(0.3, 1, 0.3, 1, line)
                else
                    imgui.Text(line)
                end
            end
        end

        imgui.Separator()

        -- Test controls
        if imgui.CollapsingHeader('Test Values', ImGuiTreeNodeFlags.DefaultOpen) then
            State.healthPct = imgui.SliderFloat('Health %', State.healthPct, 0, 1)
            State.manaPct = imgui.SliderFloat('Mana %', State.manaPct, 0, 1)
            State.endPct = imgui.SliderFloat('Endurance %', State.endPct, 0, 1)
            State.cooldownPct = imgui.SliderFloat('Cooldown %', State.cooldownPct, 0, 1)
        end

        imgui.Separator()

        -- Texture rendering tests
        if imgui.CollapsingHeader('Texture Rendering Tests', ImGuiTreeNodeFlags.DefaultOpen) then
            local dl = imgui.GetWindowDrawList()
            local startX, startY = imgui.GetCursorScreenPos()
            if type(startX) == 'table' then
                startY = startX.y or startX[2]
                startX = startX.x or startX[1]
            end

            imgui.Text('Health Bar (textured):')
            local y = startY + 20

            if TextureRenderer and TextureRenderer.drawClassicGauge then
                -- Try to draw a health gauge
                local success = false
                local err = nil
                local ok, result = pcall(function()
                    return TextureRenderer.drawClassicGauge(dl, startX, y, 200, 16, State.healthPct, 'health')
                end)
                if ok then
                    success = result
                else
                    err = result
                end

                if success then
                    imgui.SetCursorScreenPos(startX + 210, y)
                    imgui.TextColored(0, 1, 0, 1, 'OK')
                else
                    imgui.SetCursorScreenPos(startX + 210, y)
                    imgui.TextColored(1, 0, 0, 1, 'FAILED: ' .. tostring(err or 'returned false'))
                end
            else
                imgui.SetCursorScreenPos(startX + 210, y)
                imgui.TextColored(1, 0.5, 0, 1, 'TextureRenderer not loaded')
            end

            -- Mana bar
            y = y + 25
            imgui.SetCursorScreenPos(startX, y - 5)
            imgui.Text('Mana Bar (textured):')
            y = y + 15

            if TextureRenderer and TextureRenderer.drawClassicGauge then
                local ok, result = pcall(function()
                    return TextureRenderer.drawClassicGauge(dl, startX, y, 200, 16, State.manaPct, 'mana')
                end)
                if ok and result then
                    imgui.SetCursorScreenPos(startX + 210, y)
                    imgui.TextColored(0, 1, 0, 1, 'OK')
                else
                    imgui.SetCursorScreenPos(startX + 210, y)
                    imgui.TextColored(1, 0, 0, 1, 'FAILED')
                end
            end

            -- Icon holder tests
            y = y + 30
            imgui.SetCursorScreenPos(startX, y)
            imgui.Text('Icon Holders (48x48):')
            y = y + 20

            if TextureRenderer and TextureRenderer.drawIconHolder then
                local iconX = startX
                for _, state in ipairs({'normal', 'hover', 'active'}) do
                    local ok, result = pcall(function()
                        return TextureRenderer.drawIconHolder(dl, iconX, y, 48, state)
                    end)
                    iconX = iconX + 56
                end
                imgui.SetCursorScreenPos(startX + 180, y + 16)
                imgui.TextColored(0, 1, 0, 1, 'normal / hover / active')
            else
                imgui.SetCursorScreenPos(startX, y)
                imgui.TextColored(1, 0.5, 0, 1, 'drawIconHolder not available')
            end

            -- Button tests
            y = y + 60
            imgui.SetCursorScreenPos(startX, y)
            imgui.Text('Buttons (textured):')
            y = y + 20

            if TextureRenderer and TextureRenderer.drawClassicButton then
                local btnX = startX
                for _, state in ipairs({'normal', 'hover', 'pressed'}) do
                    local ok, result = pcall(function()
                        return TextureRenderer.drawClassicButton(dl, btnX, y, 96, 19, state, 'std')
                    end)
                    btnX = btnX + 104
                end
                imgui.SetCursorScreenPos(startX + 320, y)
                imgui.TextColored(0, 1, 0, 1, 'normal/hover/pressed')
            else
                imgui.SetCursorScreenPos(startX, y)
                imgui.TextColored(1, 0.5, 0, 1, 'drawClassicButton not available')
            end

            -- Fallback colored bars for comparison
            y = y + 35
            imgui.SetCursorScreenPos(startX, y)
            imgui.Text('Comparison (flat color bars):')
            y = y + 20

            -- Draw simple colored rectangles using draw_helpers pattern
            local function IM_COL32(r, g, b, a)
                r = math.floor(math.max(0, math.min(255, r)))
                g = math.floor(math.max(0, math.min(255, g)))
                b = math.floor(math.max(0, math.min(255, b)))
                a = math.floor(math.max(0, math.min(255, a)))
                if bit32 and bit32.lshift then
                    return bit32.lshift(a, 24) + bit32.lshift(b, 16) + bit32.lshift(g, 8) + r
                end
                return (((a * 256) + b) * 256 + g) * 256 + r
            end

            -- Health comparison using ImVec2
            local ImVec2 = ImVec2 or (imgui and imgui.ImVec2)
            if ImVec2 then
                pcall(function()
                    dl:AddRectFilled(ImVec2(startX, y), ImVec2(startX + 200, y + 16), IM_COL32(40, 40, 40, 255))
                    dl:AddRectFilled(ImVec2(startX, y), ImVec2(startX + 200 * State.healthPct, y + 16), IM_COL32(0, 200, 0, 255))
                    dl:AddRect(ImVec2(startX, y), ImVec2(startX + 200, y + 16), IM_COL32(100, 100, 100, 255))
                end)
            else
                pcall(function()
                    dl:AddRectFilled(startX, y, startX + 200, y + 16, IM_COL32(40, 40, 40, 255))
                    dl:AddRectFilled(startX, y, startX + 200 * State.healthPct, y + 16, IM_COL32(0, 200, 0, 255))
                    dl:AddRect(startX, y, startX + 200, y + 16, IM_COL32(100, 100, 100, 255))
                end)
            end
            imgui.SetCursorScreenPos(startX + 210, y)
            imgui.Text('Health (flat)')

            y = y + 20
            if ImVec2 then
                pcall(function()
                    dl:AddRectFilled(ImVec2(startX, y), ImVec2(startX + 200, y + 16), IM_COL32(40, 40, 40, 255))
                    dl:AddRectFilled(ImVec2(startX, y), ImVec2(startX + 200 * State.manaPct, y + 16), IM_COL32(0, 100, 200, 255))
                    dl:AddRect(ImVec2(startX, y), ImVec2(startX + 200, y + 16), IM_COL32(100, 100, 100, 255))
                end)
            else
                pcall(function()
                    dl:AddRectFilled(startX, y, startX + 200, y + 16, IM_COL32(40, 40, 40, 255))
                    dl:AddRectFilled(startX, y, startX + 200 * State.manaPct, y + 16, IM_COL32(0, 100, 200, 255))
                    dl:AddRect(startX, y, startX + 200, y + 16, IM_COL32(100, 100, 100, 255))
                end)
            end
            imgui.SetCursorScreenPos(startX + 210, y)
            imgui.Text('Mana (flat)')

            -- Reserve space for all content
            imgui.Dummy(400, 220)
        end

        imgui.Separator()

        -- Action Window Background demo
        if imgui.CollapsingHeader('Action Window Background', ImGuiTreeNodeFlags.DefaultOpen) then
            local dl = imgui.GetWindowDrawList()
            local bgStartX, bgStartY = imgui.GetCursorScreenPos()
            if type(bgStartX) == 'table' then
                bgStartY = bgStartX.y or bgStartX[2]
                bgStartX = bgStartX.x or bgStartX[1]
            end

            imgui.Text('ACTW_bg_TX (Action Window Background):')
            local bgY = bgStartY + 20

            if TextureRenderer and TextureRenderer.drawActionWindowBg then
                -- Draw a sample action window background (200x150 to show tiling)
                local ok, result = pcall(function()
                    return TextureRenderer.drawActionWindowBg(dl, bgStartX, bgY, 200, 150, { shadows = false })
                end)

                if ok and result then
                    -- Draw some icon holders on top to show how it looks
                    if TextureRenderer.drawIconHolder then
                        local iconY = bgY + 10
                        for row = 0, 2 do
                            for col = 0, 3 do
                                local iconX = bgStartX + 8 + col * 48
                                iconY = bgY + 10 + row * 48
                                pcall(function()
                                    TextureRenderer.drawIconHolder(dl, iconX, iconY, 44, 'normal')
                                end)
                            end
                        end
                    end

                    imgui.SetCursorScreenPos(bgStartX + 210, bgY + 60)
                    imgui.TextColored(0, 1, 0, 1, 'ACTW Background + Icon Grid')
                else
                    imgui.SetCursorScreenPos(bgStartX + 210, bgY)
                    imgui.TextColored(1, 0, 0, 1, 'FAILED: ' .. tostring(result or 'returned false'))
                end
            else
                imgui.SetCursorScreenPos(bgStartX, bgY)
                imgui.TextColored(1, 0.5, 0, 1, 'drawActionWindowBg not available')
            end

            -- Reserve space
            imgui.Dummy(400, 170)
        end

        imgui.Separator()

        -- Info about texture loading
        if imgui.CollapsingHeader('Texture Loading Info') then
            imgui.TextWrapped('The texture renderer uses mq.CreateTexture() to load TGA files from F:/lua/UI/')
            imgui.TextWrapped('If textures are not appearing, check:')
            imgui.BulletText('eq_ui_data.lua has the correct animation definitions')
            imgui.BulletText('Texture files exist at the expected paths')
            imgui.BulletText('The texture_renderer.lua is loading data correctly')

            imgui.Separator()
            imgui.Text('Available functions in mq:')
            imgui.BulletText(string.format('mq.CreateTexture: %s', mq.CreateTexture and 'available' or 'NOT AVAILABLE'))
        end
    end

    imgui.End()
end

-- Initialize
updateDiagnostics()

mq.imgui.init('TextureDemo', renderDemo)

print('\ag[TextureDemo] Started - check the demo window\ax')

while State.open do
    mq.delay(100)
end

print('\ay[TextureDemo] Closed\ax')
