-- ============================================================
-- SideKick Texture Renderer
-- ============================================================
-- Core texture loading and rendering module for EQ-style textured UI.
-- Ports texture handling from eq_ui_rebuild.lua for use with themes.
--
-- Usage:
--   local TextureRenderer = require('sidekick-next.ui.texture_renderer')
--   TextureRenderer.drawClassicGauge(dl, x, y, w, h, 0.75, 'health')
--   TextureRenderer.drawClassicButton(dl, x, y, w, h, 'hover', 'std')

local mq = require('mq')
local imgui = require('ImGui')

local M = {}

-- ============================================================
-- CONFIGURATION
-- ============================================================

local UI_PATH = 'F:/lua/UI/'

-- ============================================================
-- LOCAL HELPERS (to avoid circular dependency with draw_helpers)
-- ============================================================

local function IM_COL32(r, g, b, a)
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

-- Find ImVec2 at module load time
local _imVec2Func = ImVec2 or (imgui and imgui.ImVec2) or nil

local function localAddRectFilled(dl, x1, y1, x2, y2, col, rounding)
    if not dl then return false end
    rounding = tonumber(rounding) or 0

    if _imVec2Func then
        local ok = pcall(function()
            dl:AddRectFilled(_imVec2Func(x1, y1), _imVec2Func(x2, y2), col, rounding)
        end)
        if ok then return true end
    end

    local ok = pcall(function()
        dl:AddRectFilled(x1, y1, x2, y2, col, rounding)
    end)
    return ok == true
end

local function localAddRect(dl, x1, y1, x2, y2, col, rounding, flags, thickness)
    if not dl then return false end
    rounding = tonumber(rounding) or 0
    thickness = tonumber(thickness) or 1

    if _imVec2Func then
        local ok = pcall(function()
            dl:AddRect(_imVec2Func(x1, y1), _imVec2Func(x2, y2), col, rounding, 0, thickness)
        end)
        if ok then return true end
    end

    local ok = pcall(function()
        dl:AddRect(x1, y1, x2, y2, col, rounding, 0, thickness)
    end)
    return ok == true
end

-- Lazy-load eq_ui_data to avoid issues
local _data = nil
local _dataLoadAttempted = false
local function getData()
    if _dataLoadAttempted then return _data end
    _dataLoadAttempted = true

    -- Try multiple require paths
    local paths = {
        'sidekick-next.eq_ui_data',
        'eq_ui_data',
    }

    for _, path in ipairs(paths) do
        local ok, d = pcall(require, path)
        if ok and d and type(d) == 'table' and d.anims then
            _data = d
            return _data
        end
    end

    return nil
end

-- ============================================================
-- TEXTURE CACHE
-- ============================================================

local Textures = {}

local function resolveTexturePath(name)
    if not name or name == '' then return nil end
    if name:match('^%a:[/\\]') or name:find('/') or name:find('\\') then
        return name
    end
    return UI_PATH .. name
end

function M.getTexture(name)
    if not name or name == '' then return nil end
    local key = resolveTexturePath(name)
    if not key then return nil end
    if Textures[key] then return Textures[key] end

    local ok, tex = pcall(function()
        return mq.CreateTexture(key)
    end)

    if ok and tex then
        Textures[key] = tex
        return tex
    end
    return nil
end

local function getTextureSize(tex)
    if not tex then return nil, nil end
    local w, h
    local ok1, w1 = pcall(function() return tex:GetWidth() end)
    if ok1 and type(w1) == 'number' then
        local ok2, h1 = pcall(function() return tex:GetHeight() end)
        if ok2 and type(h1) == 'number' then
            return w1, h1
        end
    end
    local ok3, size = pcall(function() return tex:GetTextureSize() end)
    if ok3 and size then
        if type(size) == 'table' then
            w = tonumber(size.x or size[1])
            h = tonumber(size.y or size[2])
        end
    end
    if w and h then return w, h end
    return nil, nil
end

-- Clear texture cache (useful for reloading)
function M.clearCache()
    Textures = {}
end

-- ============================================================
-- UV CALCULATION
-- ============================================================

function M.getAnimUV(animName)
    if not animName or animName == '' then return nil end

    local data = getData()
    if not data or not data.anims then return nil end

    local anim = data.anims[animName]
    if not anim then return nil end

    local texName = anim.tex
    local texSize = data.textures and data.textures[texName]
    if not texSize or texSize.w == 0 or texSize.h == 0 then return nil end

    return {
        tex = texName,
        u0 = anim.x / texSize.w,
        v0 = anim.y / texSize.h,
        u1 = (anim.x + anim.w) / texSize.w,
        v1 = (anim.y + anim.h) / texSize.h,
        srcW = anim.w,
        srcH = anim.h,
    }
end

-- ============================================================
-- TINT SETTING HELPERS
-- ============================================================

--- Parse a tint setting string "r,g,b" (floats 0-1) into an IM_COL32 value.
--- Returns nil on invalid input (caller should use 0xFFFFFFFF default).
--- @param str string "r,g,b" format with floats 0-1
--- @param alpha number|nil Optional alpha value 0-1 (defaults to 1.0)
local function parseTintSetting(str, alpha)
    alpha = tonumber(alpha) or 1.0
    alpha = math.max(0, math.min(1, alpha))
    if not str or str == '' then
        -- No tint, just apply alpha
        if alpha < 1.0 then
            return IM_COL32(255, 255, 255, math.floor(alpha * 255 + 0.5))
        end
        return nil
    end
    local r, g, b = str:match('^%s*([%d%.]+)%s*,%s*([%d%.]+)%s*,%s*([%d%.]+)%s*$')
    r, g, b = tonumber(r), tonumber(g), tonumber(b)
    if not (r and g and b) then
        -- Invalid tint, just apply alpha
        if alpha < 1.0 then
            return IM_COL32(255, 255, 255, math.floor(alpha * 255 + 0.5))
        end
        return nil
    end
    return IM_COL32(
        math.floor(math.max(0, math.min(1, r)) * 255 + 0.5),
        math.floor(math.max(0, math.min(1, g)) * 255 + 0.5),
        math.floor(math.max(0, math.min(1, b)) * 255 + 0.5),
        math.floor(alpha * 255 + 0.5)
    )
end

-- Expose for settings UI (returns {r,g,b} floats 0-1)
function M.parseTintToFloats(str)
    if not str or str == '' then return { 1.0, 1.0, 1.0 } end
    local r, g, b = str:match('^%s*([%d%.]+)%s*,%s*([%d%.]+)%s*,%s*([%d%.]+)%s*$')
    r, g, b = tonumber(r), tonumber(g), tonumber(b)
    if not (r and g and b) then return { 1.0, 1.0, 1.0 } end
    return { math.max(0, math.min(1, r)), math.max(0, math.min(1, g)), math.max(0, math.min(1, b)) }
end

function M.formatTintFromFloats(floats)
    if not floats or #floats < 3 then return '1.0,1.0,1.0' end
    return string.format('%.2f,%.2f,%.2f', floats[1] or 1, floats[2] or 1, floats[3] or 1)
end

-- Convert tint setting string to IM_COL32 (cached per frame is fine, but simple enough to call inline)
M.parseTintSetting = parseTintSetting

-- ============================================================
-- DRAWLIST IMAGE WRAPPER
-- ============================================================

-- (ImVec2 already captured above at line 40)

-- DrawList API detection (cached)
local _imageApiDetected = false
local _imageUseImVec2 = true

local function dl_add_image(dl, texId, x1, y1, x2, y2, u0, v0, u1, v1, tintCol)
    if not dl or not texId then return false end

    -- Try ImVec2 first (MQ standard)
    if _imVec2Func then
        -- With tint color
        if tintCol then
            local ok = pcall(function()
                dl:AddImage(texId, _imVec2Func(x1, y1), _imVec2Func(x2, y2),
                    _imVec2Func(u0, v0), _imVec2Func(u1, v1), tintCol)
            end)
            if ok then
                _imageApiDetected = true
                _imageUseImVec2 = true
                return true
            end
        end
        -- Without tint (or tinted call failed)
        local ok = pcall(function()
            dl:AddImage(texId, _imVec2Func(x1, y1), _imVec2Func(x2, y2), _imVec2Func(u0, v0), _imVec2Func(u1, v1))
        end)
        if ok then
            _imageApiDetected = true
            _imageUseImVec2 = true
            return true
        end
    end

    -- Fallback: raw coordinates
    if tintCol then
        local ok = pcall(function()
            dl:AddImage(texId, x1, y1, x2, y2, u0, v0, u1, v1, tintCol)
        end)
        if ok then
            _imageApiDetected = true
            _imageUseImVec2 = false
            return true
        end
    end
    local ok = pcall(function()
        dl:AddImage(texId, x1, y1, x2, y2, u0, v0, u1, v1)
    end)
    if ok then
        _imageApiDetected = true
        _imageUseImVec2 = false
        return true
    end

    return false
end

-- AddImageRounded wrapper (may not exist in all MQ builds)
local _hasAddImageRounded = nil  -- nil=untested

local function dl_add_image_rounded(dl, texId, x1, y1, x2, y2, u0, v0, u1, v1, col, rounding, flags)
    if not dl or not texId then return false end
    col = col or 0xFFFFFFFF
    rounding = rounding or 0
    flags = flags or 0

    if rounding <= 0 then
        return dl_add_image(dl, texId, x1, y1, x2, y2, u0, v0, u1, v1, col ~= 0xFFFFFFFF and col or nil)
    end

    if _hasAddImageRounded == false then
        return dl_add_image(dl, texId, x1, y1, x2, y2, u0, v0, u1, v1, col ~= 0xFFFFFFFF and col or nil)
    end

    -- Try AddImageRounded (ImGui 1.87+)
    if _imVec2Func then
        local ok = pcall(function()
            dl:AddImageRounded(texId,
                _imVec2Func(x1, y1), _imVec2Func(x2, y2),
                _imVec2Func(u0, v0), _imVec2Func(u1, v1),
                col, rounding, flags)
        end)
        if ok then
            _hasAddImageRounded = true
            return true
        end
    end

    local ok = pcall(function()
        dl:AddImageRounded(texId, x1, y1, x2, y2, u0, v0, u1, v1, col, rounding, flags)
    end)
    if ok then
        _hasAddImageRounded = true
        return true
    end

    -- Fallback: no rounding
    _hasAddImageRounded = false
    return dl_add_image(dl, texId, x1, y1, x2, y2, u0, v0, u1, v1, col ~= 0xFFFFFFFF and col or nil)
end

-- ============================================================
-- DRAW ANIMATION
-- ============================================================

function M.drawAnim(dl, animName, x, y, w, h)
    if not dl then return false end

    local uv = M.getAnimUV(animName)
    if not uv then return false end

    local tex = M.getTexture(uv.tex)
    if not tex then return false end

    local texId = tex:GetTextureID()
    if not texId then return false end

    return dl_add_image(dl, texId, x, y, x + w, y + h, uv.u0, uv.v0, uv.u1, uv.v1)
end

-- Draw animation with tinting (for fill colors)
function M.drawAnimTinted(dl, animName, x, y, w, h, tintCol)
    if not dl then return false end

    local uv = M.getAnimUV(animName)
    if not uv then return false end

    local tex = M.getTexture(uv.tex)
    if not tex then return false end

    local texId = tex:GetTextureID()
    if not texId then return false end

    -- AddImage with tint color uses 5 ImVec2 + color
    if _imVec2Func then
        local ok = pcall(function()
            dl:AddImage(texId, _imVec2Func(x, y), _imVec2Func(x + w, y + h),
                       _imVec2Func(uv.u0, uv.v0), _imVec2Func(uv.u1, uv.v1), tintCol)
        end)
        if ok then return true end
    end

    -- Fallback without tint
    return dl_add_image(dl, texId, x, y, x + w, y + h, uv.u0, uv.v0, uv.u1, uv.v1)
end

-- ============================================================
-- CLASSIC GAUGE RENDERING
-- ============================================================

-- Gauge fill color mappings (from EQ UI data: Player_HP, Player_Mana, Player_Fatigue)
local GAUGE_FILLS = {
    health    = 'A_Classic_GaugeFill',   -- HP (red/green gradient)
    mana      = 'A_Classic_GaugeFill5',  -- Mana (blue) - from Player_Mana
    endurance = 'A_Classic_GaugeFill2',  -- Endurance/Fatigue (yellow) - from Player_Fatigue
    cooldown  = 'A_Classic_GaugeFill4',  -- Cooldown (cyan)
    experience= 'A_Classic_GaugeFill3',  -- Experience (purple/other)
    aggro     = 'A_Classic_GaugeFill6',  -- Aggro (orange)
    tot       = 'A_Classic_GaugeFill3',  -- Target-of-Target
}

function M.drawClassicGauge(dl, x, y, w, h, fillPct, gaugeType)
    if not dl then return false end

    fillPct = math.max(0, math.min(1, fillPct or 0))
    gaugeType = gaugeType or 'health'

    -- Get UV data for sizing
    local bgUV = M.getAnimUV('A_Classic_GaugeBackground')
    local leftCapUV = M.getAnimUV('A_Classic_GaugeEndCapLeft')
    local rightCapUV = M.getAnimUV('A_Classic_GaugeEndCapRight')

    if not bgUV then
        -- Fallback to color-based rendering
        return false
    end

    -- Calculate scaled dimensions
    local srcH = bgUV.srcH or 12
    local scale = h / srcH
    local leftCapW = leftCapUV and (leftCapUV.srcW * scale) or 0
    local rightCapW = rightCapUV and (rightCapUV.srcW * scale) or 0
    local middleW = w - leftCapW - rightCapW

    -- Draw left end cap
    if leftCapUV and leftCapW > 0 then
        M.drawAnim(dl, 'A_Classic_GaugeEndCapLeft', x, y, leftCapW, h)
    end

    -- Draw background (middle)
    if middleW > 0 then
        M.drawAnim(dl, 'A_Classic_GaugeBackground', x + leftCapW, y, middleW, h)
    end

    -- Draw right end cap
    if rightCapUV and rightCapW > 0 then
        M.drawAnim(dl, 'A_Classic_GaugeEndCapRight', x + leftCapW + middleW, y, rightCapW, h)
    end

    -- Draw fill (if any)
    if fillPct > 0 then
        local fillAnim = GAUGE_FILLS[gaugeType] or 'A_Classic_GaugeFill'
        local fillW = middleW * fillPct

        -- Clip fill to middle region
        if fillW > 0 then
            local fillX = x + leftCapW
            local fillEndX = fillX + fillW

            -- Draw fill with clipping via partial UV
            local fillUV = M.getAnimUV(fillAnim)
            if fillUV then
                local tex = M.getTexture(fillUV.tex)
                if tex then
                    local texId = tex:GetTextureID()
                    if texId then
                        local fillU1 = fillUV.u0 + (fillUV.u1 - fillUV.u0) * fillPct
                        dl_add_image(dl, texId, fillX, y, fillEndX, y + h,
                                    fillUV.u0, fillUV.v0, fillU1, fillUV.v1)
                    end
                end
            end
        end
    end

    -- Draw gauge lines overlay
    M.drawAnim(dl, 'A_Classic_GaugeLines', x + leftCapW, y, middleW, h)

    return true
end

-- Simplified gauge (no end caps, just fill with background)
function M.drawSimpleGauge(dl, x, y, w, h, fillPct, gaugeType)
    if not dl then return false end

    fillPct = math.max(0, math.min(1, fillPct or 0))
    gaugeType = gaugeType or 'health'

    -- Draw background
    local bgDrawn = M.drawAnim(dl, 'A_Classic_GaugeBackground', x, y, w, h)
    if not bgDrawn then return false end

    -- Draw fill
    if fillPct > 0 then
        local fillAnim = GAUGE_FILLS[gaugeType] or 'A_Classic_GaugeFill'
        local fillW = w * fillPct

        local fillUV = M.getAnimUV(fillAnim)
        if fillUV then
            local tex = M.getTexture(fillUV.tex)
            if tex then
                local texId = tex:GetTextureID()
                if texId then
                    local fillU1 = fillUV.u0 + (fillUV.u1 - fillUV.u0) * fillPct
                    dl_add_image(dl, texId, x, y, x + fillW, y + h,
                                fillUV.u0, fillUV.v0, fillU1, fillUV.v1)
                end
            end
        end
    end

    return true
end

-- ============================================================
-- CLASSIC BUTTON RENDERING
-- ============================================================

-- Button animation mappings by state and size
local BUTTON_ANIMS = {
    normal   = { std = 'A_BtnNormal',      big = 'A_BigBtnNormal',      small = 'A_SmallBtnNormal' },
    hover    = { std = 'A_BtnFlyby',       big = 'A_BigBtnFlyby',       small = 'A_SmallBtnFlyby' },
    pressed  = { std = 'A_BtnPressed',     big = 'A_BigBtnPressed',     small = 'A_SmallBtnPressed' },
    disabled = { std = 'A_BtnDisabled',    big = 'A_BigBtnDisabled',    small = 'A_SmallBtnDisabled' },
}

function M.drawClassicButton(dl, x, y, w, h, state, size)
    if not dl then return false end

    state = state or 'normal'
    size = size or 'std'

    local stateAnims = BUTTON_ANIMS[state] or BUTTON_ANIMS.normal
    local animName = stateAnims[size] or stateAnims.std

    return M.drawAnim(dl, animName, x, y, w, h)
end

-- Determine best button size based on dimensions
function M.getBestButtonSize(w, h)
    -- Big buttons are 120x24, standard are 96x19, small are 48x19
    if w >= 100 then return 'big' end
    if w <= 60 then return 'small' end
    return 'std'
end

-- ============================================================
-- ICON HOLDER RENDERING (for ability bar cells)
-- ============================================================

-- Icon holder backgrounds
-- Note: eq_ui_data only has A_InvSlotFrame, use it for all states
local ICON_HOLDERS = {
    normal = 'A_InvSlotFrame',
    hover  = 'A_InvSlotFrame',
    active = 'A_InvSlotFrame',
}

function M.drawIconHolder(dl, x, y, size, state)
    if not dl then return false end

    state = state or 'normal'
    local animName = ICON_HOLDERS[state] or ICON_HOLDERS.normal

    -- Try to draw the icon holder texture
    local success = M.drawAnim(dl, animName, x, y, size, size)

    -- If no icon holder animation, draw a simple frame
    if not success then
        -- Fallback: draw a border using color
        local borderCol = IM_COL32(180, 160, 100, 200)  -- Gold border
        local bgCol = IM_COL32(30, 28, 25, 220)  -- Dark background
        localAddRectFilled(dl, x, y, x + size, y + size, bgCol, 2)
        localAddRect(dl, x, y, x + size, y + size, borderCol, 2, 0, 1)
        return true
    end

    return success
end

-- ============================================================
-- WINDOW BORDER RENDERING
-- ============================================================

-- Window border pieces
local BORDER_PIECES = {
    topLeft     = 'A_ClassicTopLeft',
    top         = 'A_ClassicTop',
    topRight    = 'A_ClassicTopRight',
    left        = 'A_ClassicLeft',
    right       = 'A_ClassicRight',
    bottomLeft  = 'A_ClassicBottomLeft',
    bottom      = 'A_ClassicBottom',
    bottomRight = 'A_ClassicBottomRight',
}

function M.drawWindowBorder(dl, x, y, w, h, scale)
    if not dl then return false end
    scale = scale or 1.0

    -- Get corner sizes
    local tlUV = M.getAnimUV(BORDER_PIECES.topLeft)
    local trUV = M.getAnimUV(BORDER_PIECES.topRight)
    local blUV = M.getAnimUV(BORDER_PIECES.bottomLeft)
    local brUV = M.getAnimUV(BORDER_PIECES.bottomRight)

    if not tlUV then return false end

    local cornerW = (tlUV.srcW or 7) * scale
    local cornerH = (tlUV.srcH or 7) * scale

    -- Draw corners
    M.drawAnim(dl, BORDER_PIECES.topLeft, x, y, cornerW, cornerH)
    M.drawAnim(dl, BORDER_PIECES.topRight, x + w - cornerW, y, cornerW, cornerH)
    M.drawAnim(dl, BORDER_PIECES.bottomLeft, x, y + h - cornerH, cornerW, cornerH)
    M.drawAnim(dl, BORDER_PIECES.bottomRight, x + w - cornerW, y + h - cornerH, cornerW, cornerH)

    -- Draw edges (stretched)
    local edgeW = w - cornerW * 2
    local edgeH = h - cornerH * 2

    if edgeW > 0 then
        M.drawAnim(dl, BORDER_PIECES.top, x + cornerW, y, edgeW, cornerH)
        M.drawAnim(dl, BORDER_PIECES.bottom, x + cornerW, y + h - cornerH, edgeW, cornerH)
    end

    if edgeH > 0 then
        M.drawAnim(dl, BORDER_PIECES.left, x, y + cornerH, cornerW, edgeH)
        M.drawAnim(dl, BORDER_PIECES.right, x + w - cornerW, y + cornerH, cornerW, edgeH)
    end

    return true
end

-- ============================================================
-- ACTION WINDOW BACKGROUND
-- ============================================================

-- Action window background texture names
local ACTION_WINDOW_BG = {
    main = 'A_Listbox_Background1',  -- Dark rock texture (256x256) - tiles cleanly
    shadowBottom = 'ACTW_bg_dropshadow_bottom_TX',
    shadowLeft = 'ACTW_bg_dropshadow_left_TX',
}

-- Draw any anim as a tiled/stretched background.
-- opts.tile: default true (tile); false = stretch
-- opts.rounding: when >0, draws a single rounded stretch (no tiling)
-- opts.tintCol: IM_COL32 or nil
-- opts.flipH/flipV: mirror texture UVs
function M.drawTiledAnimBg(dl, x, y, w, h, animName, opts)
    if not dl then return false end
    opts = opts or {}
    animName = animName or ACTION_WINDOW_BG.main

    local bgUV = M.getAnimUV(animName)
    local tex
    local srcW, srcH
    local u0, v0, u1, v1
    if bgUV then
        tex = M.getTexture(bgUV.tex)
        srcW = bgUV.srcW
        srcH = bgUV.srcH
        u0, v0, u1, v1 = bgUV.u0, bgUV.v0, bgUV.u1, bgUV.v1
    else
        -- Fallback: treat animName as a raw UI texture file
        tex = M.getTexture(animName)
        u0, v0, u1, v1 = 0, 0, 1, 1
    end
    if not tex then return false end

    local texId = tex:GetTextureID()
    if not texId then return false end

    local tileMode = opts.tile ~= false
    local rounding = tonumber(opts.rounding) or 0
    local tintCol = opts.tintCol
    local flipH = opts.flipH == true
    local flipV = opts.flipV == true

    local baseU0, baseU1 = u0, u1
    local baseV0, baseV1 = v0, v1
    if flipH then baseU0, baseU1 = baseU1, baseU0 end
    if flipV then baseV0, baseV1 = baseV1, baseV0 end

    if rounding > 0 and dl_add_image_rounded then
        local roundedCol = tintCol or 0xFFFFFFFF
        dl_add_image_rounded(dl, texId, x, y, x + w, y + h,
            baseU0, baseV0, baseU1, baseV1, roundedCol, rounding, 0)
        return true
    end

    if not tileMode then
        dl_add_image(dl, texId, x, y, x + w, y + h, baseU0, baseV0, baseU1, baseV1, tintCol)
        return true
    end

    if not srcW or not srcH then
        local tw, th = getTextureSize(tex)
        srcW = tw or 256
        srcH = th or 256
    end
    local tilesX = math.ceil(w / srcW)
    local tilesY = math.ceil(h / srcH)

    for ty = 0, tilesY - 1 do
        for tx = 0, tilesX - 1 do
            local tileX = x + tx * srcW
            local tileY = y + ty * srcH
            local tileW = math.min(srcW, x + w - tileX)
            local tileH = math.min(srcH, y + h - tileY)

            if tileW > 0 and tileH > 0 then
                local u1 = baseU0 + (baseU1 - baseU0) * (tileW / srcW)
                local v1 = baseV0 + (baseV1 - baseV0) * (tileH / srcH)
                dl_add_image(dl, texId, tileX, tileY, tileX + tileW, tileY + tileH,
                            baseU0, baseV0, u1, v1, tintCol)
            end
        end
    end

    return true
end

-- Draw action window background (tiled to fill area)
function M.drawActionWindowBg(dl, x, y, w, h, opts)
    if not dl then return false end
    opts = opts or {}

    local bgUV = M.getAnimUV(ACTION_WINDOW_BG.main)
    if not bgUV then return false end

    local tex = M.getTexture(bgUV.tex)
    if not tex then return false end

    local texId = tex:GetTextureID()
    if not texId then return false end

    -- Option to tile or stretch
    local tileMode = opts.tile ~= false  -- Default to tiling
    local tintCol = opts.tintCol  -- IM_COL32 or nil

    if tileMode then
        -- Tile the background to fill the area
        local srcW = bgUV.srcW or 256
        local srcH = bgUV.srcH or 256

        local tilesX = math.ceil(w / srcW)
        local tilesY = math.ceil(h / srcH)

        for ty = 0, tilesY - 1 do
            for tx = 0, tilesX - 1 do
                local tileX = x + tx * srcW
                local tileY = y + ty * srcH
                local tileW = math.min(srcW, x + w - tileX)
                local tileH = math.min(srcH, y + h - tileY)

                if tileW > 0 and tileH > 0 then
                    -- Calculate partial UV for edge tiles
                    local u1 = bgUV.u0 + (bgUV.u1 - bgUV.u0) * (tileW / srcW)
                    local v1 = bgUV.v0 + (bgUV.v1 - bgUV.v0) * (tileH / srcH)

                    dl_add_image(dl, texId, tileX, tileY, tileX + tileW, tileY + tileH,
                                bgUV.u0, bgUV.v0, u1, v1, tintCol)
                end
            end
        end
    else
        -- Stretch to fill
        dl_add_image(dl, texId, x, y, x + w, y + h, bgUV.u0, bgUV.v0, bgUV.u1, bgUV.v1, tintCol)
    end

    -- Optionally draw drop shadows
    if opts.shadows ~= false then
        -- Left shadow
        local leftShadowUV = M.getAnimUV(ACTION_WINDOW_BG.shadowLeft)
        if leftShadowUV then
            local shadowTex = M.getTexture(leftShadowUV.tex)
            if shadowTex then
                local shadowTexId = shadowTex:GetTextureID()
                if shadowTexId then
                    local shadowW = leftShadowUV.srcW or 5
                    dl_add_image(dl, shadowTexId, x - shadowW, y, x, y + h,
                                leftShadowUV.u0, leftShadowUV.v0, leftShadowUV.u1, leftShadowUV.v1)
                end
            end
        end

        -- Bottom shadow
        local bottomShadowUV = M.getAnimUV(ACTION_WINDOW_BG.shadowBottom)
        if bottomShadowUV then
            local shadowTex = M.getTexture(bottomShadowUV.tex)
            if shadowTex then
                local shadowTexId = shadowTex:GetTextureID()
                if shadowTexId then
                    local shadowH = bottomShadowUV.srcH or 5
                    dl_add_image(dl, shadowTexId, x, y + h, x + w, y + h + shadowH,
                                bottomShadowUV.u0, bottomShadowUV.v0, bottomShadowUV.u1, bottomShadowUV.v1)
                end
            end
        end
    end

    return true
end

-- Get action window background dimensions (for layout)
function M.getActionWindowBgSize()
    local bgUV = M.getAnimUV(ACTION_WINDOW_BG.main)
    if bgUV then
        return bgUV.srcW or 256, bgUV.srcH or 256
    end
    return 256, 256
end

-- Draw light rock background (tiled, with optional rounding)
function M.drawLightRockBg(dl, x, y, w, h, opts)
    if not dl then return false end
    opts = opts or {}

    local animName = 'A_LightRockFrameTopBottom'
    local bgUV = M.getAnimUV(animName)
    if not bgUV then return false end

    local tex = M.getTexture(bgUV.tex)
    if not tex then return false end

    local texId = tex:GetTextureID()
    if not texId then return false end

    local rounding = tonumber(opts.rounding) or 0
    local tintCol = opts.tintCol  -- IM_COL32 or nil
    local roundedCol = tintCol or 0xFFFFFFFF
    local srcW = bgUV.srcW or 256
    local srcH = bgUV.srcH or 30

    if rounding > 0 then
        -- Single stretched draw with rounding
        local ok = dl_add_image_rounded(dl, texId, x, y, x + w, y + h,
            bgUV.u0, bgUV.v0, bgUV.u1, bgUV.v1, roundedCol, rounding, 0)
        if ok then return true end
    end

    -- Tiled fallback (no rounding support when tiling)
    local tilesX = math.ceil(w / srcW)
    local tilesY = math.ceil(h / srcH)

    for ty = 0, tilesY - 1 do
        for tx = 0, tilesX - 1 do
            local tileX = x + tx * srcW
            local tileY = y + ty * srcH
            local tileW = math.min(srcW, x + w - tileX)
            local tileH = math.min(srcH, y + h - tileY)

            if tileW > 0 and tileH > 0 then
                local u1 = bgUV.u0 + (bgUV.u1 - bgUV.u0) * (tileW / srcW)
                local v1 = bgUV.v0 + (bgUV.v1 - bgUV.v0) * (tileH / srcH)
                dl_add_image(dl, texId, tileX, tileY, tileX + tileW, tileY + tileH,
                            bgUV.u0, bgUV.v0, u1, v1, tintCol)
            end
        end
    end

    return true
end

-- Draw hotbutton-style background (classic_bg_left.tga tiled, no bottom trim)
-- opts.flipH: horizontally mirror the texture (swap u0/u1) so borders face the opposite direction
function M.drawHotbuttonBg(dl, x, y, w, h, opts)
    if not dl then return false end
    opts = opts or {}

    local bgUV = M.getAnimUV('LEFTW_Overlap_bg_1_TX')
    if not bgUV then return false end

    local tex = M.getTexture(bgUV.tex)
    if not tex then return false end

    local texId = tex:GetTextureID()
    if not texId then return false end

    local rounding = tonumber(opts.rounding) or 0
    local tintCol = opts.tintCol  -- IM_COL32 or nil
    local roundedCol = tintCol or 0xFFFFFFFF
    local srcW = bgUV.srcW or 119
    local srcH = bgUV.srcH or 256
    local flipH = opts.flipH == true

    -- Base UV range (possibly flipped horizontally)
    local baseU0 = flipH and bgUV.u1 or bgUV.u0
    local baseU1 = flipH and bgUV.u0 or bgUV.u1

    -- With rounding, stretch a single copy
    if rounding > 0 then
        local ok = dl_add_image_rounded(dl, texId, x, y, x + w, y + h,
            baseU0, bgUV.v0, baseU1, bgUV.v1, roundedCol, rounding, 0)
        if ok then return true end
    end

    -- Tile to fill
    local tilesX = math.ceil(w / srcW)
    local tilesY = math.ceil(h / srcH)

    for ty = 0, tilesY - 1 do
        for tx = 0, tilesX - 1 do
            local tileX = x + tx * srcW
            local tileY = y + ty * srcH
            local tileW = math.min(srcW, x + w - tileX)
            local tileH = math.min(srcH, y + h - tileY)

            if tileW > 0 and tileH > 0 then
                local frac = tileW / srcW
                local u1 = baseU0 + (baseU1 - baseU0) * frac
                local v1 = bgUV.v0 + (bgUV.v1 - bgUV.v0) * (tileH / srcH)
                dl_add_image(dl, texId, tileX, tileY, tileX + tileW, tileY + tileH,
                            baseU0, bgUV.v0, u1, v1, tintCol)
            end
        end
    end

    return true
end

-- Per-pane background textures (vertical SELW_bg_Inv_Normal upscaled to pane size)
local _paneTex = {}       -- { target = tex, group = tex, xtarget = tex }
local _paneTexChecked = false

local PANE_FILES = {
    -- Margins (in pixels) trim the black border lines from texture edges
    -- marginL/R/T/B = left, right, top, bottom pixel margins
    target  = { file = 'sk_pane_target_v2.tga',  w = 280, h = 600, marginL = 1, marginR = 1, marginT = 3, marginB = 3 },
    group   = { file = 'sk_pane_group_v2.tga',   w = 500, h = 600, marginL = 6, marginR = 1, marginT = 3, marginB = 3 },
    -- Intentionally reuse the group pane texture for XTarget so both columns match.
    xtarget = { file = 'sk_pane_group_v2.tga',   w = 500, h = 600, marginL = 6, marginR = 1, marginT = 3, marginB = 3 },
}

local function loadPaneTextures()
    if _paneTexChecked then return end
    _paneTexChecked = true
    for name, info in pairs(PANE_FILES) do
        local ok, tex = pcall(function()
            return mq.CreateTexture(UI_PATH .. info.file)
        end)
        if ok and tex then _paneTex[name] = tex end
    end
end

--- Draw a per-pane background texture, stretching to fill the requested area.
--- When the requested size exceeds the texture, the full texture is stretched.
--- When smaller, only the matching portion of the texture is shown (UV clip).
--- @param pane string 'target'|'group'|'xtarget'
function M.drawPaneBg(dl, x, y, w, h, pane, opts)
    if not dl then return false end
    opts = opts or {}
    pane = pane or 'group'

    loadPaneTextures()

    local tex = _paneTex[pane]
    if not tex then return false end
    local texId = tex:GetTextureID()
    if not texId then return false end

    local info = PANE_FILES[pane]
    local texW, texH = info.w, info.h

    -- Get margins (in pixels) to trim black border lines
    -- Extra margins can be passed via opts to add on top of base margins
    local marginL = (info.marginL or 0) + (tonumber(opts.extraMarginL) or 0)
    local marginR = (info.marginR or 0) + (tonumber(opts.extraMarginR) or 0)
    local marginT = info.marginT or 0
    local marginB = info.marginB or 0

    -- Convert margins to UV space
    local uvMarginL = marginL / texW
    local uvMarginR = marginR / texW
    local uvMarginT = marginT / texH
    local uvMarginB = marginB / texH

    -- Effective texture size after margins
    local effectiveW = texW - marginL - marginR
    local effectiveH = texH - marginT - marginB

    -- Calculate UV coordinates
    -- vOffset: normalized (0-1) vertical offset into texture (0=top, 1=bottom)
    -- uOffset: normalized (0-1) horizontal offset into texture (0=left, 1=right)
    local uOffset = tonumber(opts.uOffset) or 0
    local vOffset = tonumber(opts.vOffset) or 0

    -- Apply margins: start from marginL/marginT, scale within effective area
    local u0 = uvMarginL + uOffset * (1.0 - uvMarginL - uvMarginR)
    local v0 = uvMarginT + vOffset * (1.0 - uvMarginT - uvMarginB)
    local u1 = math.min(u0 + w / effectiveW * (1.0 - uvMarginL - uvMarginR), 1.0 - uvMarginR)
    local v1 = math.min(v0 + h / effectiveH * (1.0 - uvMarginT - uvMarginB), 1.0 - uvMarginB)

    if opts.flipH then u0, u1 = u1, u0 end
    if opts.flipV then v0, v1 = v1, v0 end

    local rounding = tonumber(opts.rounding) or 0
    local tintCol = opts.tintCol
    if rounding > 0 then
        local roundedCol = tintCol or 0xFFFFFFFF
        local ok = dl_add_image_rounded(dl, texId, x, y, x + w, y + h,
            u0, v0, u1, v1, roundedCol, rounding, 0)
        if ok then return true end
    end

    dl_add_image(dl, texId, x, y, x + w, y + h, u0, v0, u1, v1, tintCol)
    return true
end

-- ============================================================
-- UTILITY FUNCTIONS
-- ============================================================

-- Check if textures are available
function M.isAvailable()
    local data = getData()
    if not data or not data.anims then return false end

    -- Try to load a common texture to verify
    local uv = M.getAnimUV('A_Classic_GaugeBackground')
    if not uv then return false end

    local tex = M.getTexture(uv.tex)
    return tex ~= nil
end

-- Get animation source dimensions
function M.getAnimSize(animName)
    local uv = M.getAnimUV(animName)
    if not uv then return nil, nil end
    return uv.srcW, uv.srcH
end

-- Debug function to diagnose texture loading issues
function M.diagnose()
    local results = {
        dataLoaded = false,
        dataHasAnims = false,
        dataHasTextures = false,
        testAnimFound = false,
        testTexturePath = nil,
        testTextureLoaded = false,
        error = nil,
    }

    local data = getData()
    results.dataLoaded = data ~= nil

    if data then
        results.dataHasAnims = data.anims ~= nil
        results.dataHasTextures = data.textures ~= nil
    end

    if results.dataHasAnims then
        local uv = M.getAnimUV('A_Classic_GaugeBackground')
        results.testAnimFound = uv ~= nil
        if uv then
            results.testTexturePath = UI_PATH .. uv.tex
            local tex = M.getTexture(uv.tex)
            results.testTextureLoaded = tex ~= nil
        end
    end

    -- Print results
    print('[TextureRenderer Diagnose]')
    print('  eq_ui_data loaded: ' .. tostring(results.dataLoaded))
    print('  data.anims exists: ' .. tostring(results.dataHasAnims))
    print('  data.textures exists: ' .. tostring(results.dataHasTextures))
    print('  Test anim found: ' .. tostring(results.testAnimFound))
    print('  Test texture path: ' .. tostring(results.testTexturePath or 'N/A'))
    print('  Test texture loaded: ' .. tostring(results.testTextureLoaded))

    return results
end

return M
