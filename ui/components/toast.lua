-- ============================================================
-- SideKick Toast Notification Component
-- ============================================================
-- Temporary notification messages that appear and auto-dismiss.
-- Supports stacking, animations, and different severity levels.
--
-- Usage:
--   local Toast = require('sidekick-next.ui.components.toast')
--   Toast.info('Settings saved', 'Classic')
--   Toast.success('Spell memorized', 'Classic')
--   Toast.warning('Low mana!', 'Classic')
--   Toast.error('Target out of range', 'Classic')
--
--   -- In your render loop:
--   Toast.render('Classic')

local imgui = require('ImGui')
local iam = require('sidekick-next.utils.imanim')
local Draw = require('sidekick-next.ui.draw_helpers')
local Colors = require('sidekick-next.ui.colors')

local M = {}

-- Cached ease descriptors
local _ezOutCubic = iam.EasePreset(IamEaseType.OutCubic)
local _ezOutBack = iam.EasePreset(IamEaseType.OutBack)

-- ============================================================
-- CONFIGURATION
-- ============================================================

local CONFIG = {
    maxToasts = 5,
    defaultDuration = 3.0,
    fadeInTime = 0.2,
    fadeOutTime = 0.4,
    slideDistance = 30,
    toastHeight = 36,
    toastWidth = 250,
    spacing = 6,
    padding = 10,
    rounding = 6,
    position = 'top-right',  -- top-right, top-left, bottom-right, bottom-left, top-center, bottom-center
    margin = 20,
}

-- ============================================================
-- TOAST STYLES
-- ============================================================

local TOAST_STYLES = {
    info = {
        bg = { 0.15, 0.25, 0.35 },
        border = { 0.3, 0.5, 0.7 },
        icon = 'i',
        iconColor = { 0.4, 0.7, 1.0 },
    },
    success = {
        bg = { 0.12, 0.28, 0.18 },
        border = { 0.25, 0.6, 0.35 },
        icon = '+',
        iconColor = { 0.4, 0.9, 0.5 },
    },
    warning = {
        bg = { 0.30, 0.25, 0.12 },
        border = { 0.7, 0.55, 0.25 },
        icon = '!',
        iconColor = { 1.0, 0.8, 0.3 },
    },
    error = {
        bg = { 0.30, 0.12, 0.12 },
        border = { 0.7, 0.25, 0.25 },
        icon = 'X',
        iconColor = { 1.0, 0.4, 0.4 },
    },
    spell = {
        bg = { 0.20, 0.15, 0.30 },
        border = { 0.5, 0.35, 0.7 },
        icon = '*',
        iconColor = { 0.7, 0.5, 1.0 },
    },
    combat = {
        bg = { 0.28, 0.15, 0.12 },
        border = { 0.65, 0.35, 0.25 },
        icon = '>',
        iconColor = { 1.0, 0.6, 0.4 },
    },
}

-- ============================================================
-- TOAST QUEUE
-- ============================================================

local _toasts = {}
local _toastId = 0

-- ============================================================
-- HELPER FUNCTIONS
-- ============================================================

local function getStyle(styleType)
    return TOAST_STYLES[styleType] or TOAST_STYLES.info
end

local function getPosition()
    local vp = imgui.GetMainViewport and imgui.GetMainViewport()
    local vpX, vpY, vpW, vpH

    if vp then
        local pos = vp.Pos or { x = 0, y = 0 }
        local size = vp.Size or { x = 800, y = 600 }
        vpX = pos.x or pos[1] or 0
        vpY = pos.y or pos[2] or 0
        vpW = size.x or size[1] or 800
        vpH = size.y or size[2] or 600
    else
        vpX, vpY = 0, 0
        vpW, vpH = 800, 600
    end

    local pos = CONFIG.position
    local margin = CONFIG.margin
    local w = CONFIG.toastWidth

    local x, y, anchorBottom

    if pos == 'top-right' then
        x = vpX + vpW - w - margin
        y = vpY + margin
        anchorBottom = false
    elseif pos == 'top-left' then
        x = vpX + margin
        y = vpY + margin
        anchorBottom = false
    elseif pos == 'bottom-right' then
        x = vpX + vpW - w - margin
        y = vpY + vpH - margin
        anchorBottom = true
    elseif pos == 'bottom-left' then
        x = vpX + margin
        y = vpY + vpH - margin
        anchorBottom = true
    elseif pos == 'top-center' then
        x = vpX + (vpW - w) / 2
        y = vpY + margin
        anchorBottom = false
    elseif pos == 'bottom-center' then
        x = vpX + (vpW - w) / 2
        y = vpY + vpH - margin
        anchorBottom = true
    else
        x = vpX + vpW - w - margin
        y = vpY + margin
        anchorBottom = false
    end

    return x, y, anchorBottom
end

-- Alpha and slide are now computed via native ImAnim tweens in render()
-- (removed manual calculateAlpha/calculateSlideOffset)

-- ============================================================
-- TOAST CREATION
-- ============================================================

local function addToast(message, styleType, opts)
    opts = opts or {}

    _toastId = _toastId + 1

    local duration = opts.duration or CONFIG.defaultDuration
    local now = os.clock()

    local toast = {
        id = _toastId,
        message = tostring(message or ''),
        styleType = styleType or 'info',
        startTime = now,
        endTime = now + duration,
        opts = opts,
    }

    -- Insert at beginning (newest first)
    table.insert(_toasts, 1, toast)

    -- Limit queue size
    while #_toasts > CONFIG.maxToasts do
        table.remove(_toasts)
    end

    return toast.id
end

-- ============================================================
-- PUBLIC API - TOAST CREATION
-- ============================================================

function M.show(message, styleType, opts)
    return addToast(message, styleType, opts)
end

function M.info(message, opts)
    return addToast(message, 'info', opts)
end

function M.success(message, opts)
    return addToast(message, 'success', opts)
end

function M.warning(message, opts)
    return addToast(message, 'warning', opts)
end

function M.error(message, opts)
    return addToast(message, 'error', opts)
end

function M.spell(message, opts)
    return addToast(message, 'spell', opts)
end

function M.combat(message, opts)
    return addToast(message, 'combat', opts)
end

-- ============================================================
-- TOAST DISMISSAL
-- ============================================================

function M.dismiss(toastId)
    for i, toast in ipairs(_toasts) do
        if toast.id == toastId then
            -- Start fade out immediately
            local now = os.clock()
            toast.endTime = now + CONFIG.fadeOutTime
            return true
        end
    end
    return false
end

function M.dismissAll()
    local now = os.clock()
    for _, toast in ipairs(_toasts) do
        toast.endTime = now + CONFIG.fadeOutTime
    end
end

function M.clear()
    _toasts = {}
end

-- ============================================================
-- RENDERING
-- ============================================================

function M.render(themeName)
    local now = os.clock()

    -- Remove expired toasts
    for i = #_toasts, 1, -1 do
        if now > _toasts[i].endTime then
            table.remove(_toasts, i)
        end
    end

    if #_toasts == 0 then return end

    -- Get position anchor
    local baseX, baseY, anchorBottom = getPosition()

    -- Get foreground draw list
    local dl = imgui.GetForegroundDrawList and imgui.GetForegroundDrawList()
    if not dl then return end

    -- Draw each toast with native ImAnim tweens
    local yOffset = 0
    local dt = imgui.GetIO().DeltaTime

    for i, toast in ipairs(_toasts) do
        local style = getStyle(toast.styleType)
        local tid = 'toast_' .. toast.id
        local remaining = toast.endTime - now

        -- Native tweened alpha (fade in/out)
        local isFadingOut = remaining < CONFIG.fadeOutTime
        local targetAlpha = isFadingOut and 0.0 or 1.0
        local fadeDur = isFadingOut and CONFIG.fadeOutTime or CONFIG.fadeInTime
        local alpha = iam.TweenFloat(tid, imgui.GetID('alpha'), targetAlpha, fadeDur,
            _ezOutCubic, IamPolicy.Crossfade, dt, 0.0)

        -- Native tweened slide X (OutBack for slight overshoot on entry)
        local slideTarget = 0
        local slideX = iam.TweenFloat(tid, imgui.GetID('slideX'), slideTarget, 0.3,
            _ezOutBack, IamPolicy.Crossfade, dt, CONFIG.slideDistance)

        -- Native tweened Y position (smooth stack reflow)
        local targetY
        if anchorBottom then
            targetY = baseY - CONFIG.toastHeight - yOffset
        else
            targetY = baseY + yOffset
        end
        local y = iam.TweenFloat(tid, imgui.GetID('posY'), targetY, 0.25,
            _ezOutCubic, IamPolicy.Crossfade, dt)

        local x = baseX + slideX
        local w = CONFIG.toastWidth
        local h = CONFIG.toastHeight

        -- Background
        local bgCol = Draw.IM_COL32(
            math.floor(style.bg[1] * 255),
            math.floor(style.bg[2] * 255),
            math.floor(style.bg[3] * 255),
            math.floor(alpha * 230)
        )
        Draw.addRectFilled(dl, x, y, x + w, y + h, bgCol, CONFIG.rounding)

        -- Border
        local borderCol = Draw.IM_COL32(
            math.floor(style.border[1] * 255),
            math.floor(style.border[2] * 255),
            math.floor(style.border[3] * 255),
            math.floor(alpha * 180)
        )
        Draw.addRect(dl, x, y, x + w, y + h, borderCol, CONFIG.rounding, 0, 1)

        -- Icon background
        local iconBgCol = Draw.IM_COL32(
            math.floor(style.iconColor[1] * 40),
            math.floor(style.iconColor[2] * 40),
            math.floor(style.iconColor[3] * 40),
            math.floor(alpha * 200)
        )
        Draw.addRectFilled(dl, x, y, x + h, y + h, iconBgCol, CONFIG.rounding)

        -- Icon
        local iconCol = Draw.IM_COL32(
            math.floor(style.iconColor[1] * 255),
            math.floor(style.iconColor[2] * 255),
            math.floor(style.iconColor[3] * 255),
            math.floor(alpha * 255)
        )
        local iconX = x + (h - imgui.CalcTextSize(style.icon)) / 2
        local iconY = y + (h - imgui.GetTextLineHeight()) / 2
        Draw.addText(dl, iconX, iconY, iconCol, style.icon)

        -- Message text with stagger effect
        local textCol = Colors.text(themeName)
        local textX = x + h + CONFIG.padding
        local textY = y + (h - imgui.GetTextLineHeight()) / 2
        local textElapsed = now - toast.startTime

        -- Use TextStagger for per-character fade-in during first 0.8s
        local staggerDone = textElapsed > 0.8
        if not staggerDone then
            local staggerOpts = IamTextStaggerOpts()
            staggerOpts.pos = ImVec2(textX, textY)
            staggerOpts.effect = IamTextStaggerEffect.Fade
            staggerOpts.char_delay = 0.02
            staggerOpts.char_duration = 0.15
            staggerOpts.ease = _ezOutCubic
            staggerOpts.color = Draw.IM_COL32(
                math.floor(textCol[1] * 255),
                math.floor(textCol[2] * 255),
                math.floor(textCol[3] * 255),
                math.floor(alpha * 255)
            )
            local progress = math.min(1.0, textElapsed / 0.6)
            pcall(function()
                iam.TextStagger(imgui.GetID(tid .. '_text'), toast.message, progress, staggerOpts)
            end)
        else
            -- After stagger complete, draw normally
            local msgCol = Draw.IM_COL32(
                math.floor(textCol[1] * 255),
                math.floor(textCol[2] * 255),
                math.floor(textCol[3] * 255),
                math.floor(alpha * 255)
            )
            Draw.addText(dl, textX, textY, msgCol, toast.message)
        end

        -- Progress bar (time remaining)
        local progress = (toast.endTime - now) / (toast.endTime - toast.startTime)
        progress = math.max(0, math.min(1, progress))
        local barY = y + h - 3
        local barW = (w - 4) * progress

        local barCol = Draw.IM_COL32(
            math.floor(style.border[1] * 255),
            math.floor(style.border[2] * 255),
            math.floor(style.border[3] * 255),
            math.floor(alpha * 100)
        )
        Draw.addRectFilled(dl, x + 2, barY, x + 2 + barW, barY + 2, barCol, 1)

        -- Update offset for next toast
        yOffset = yOffset + CONFIG.toastHeight + CONFIG.spacing
    end
end

-- ============================================================
-- CONFIGURATION
-- ============================================================

function M.configure(opts)
    if opts.maxToasts then CONFIG.maxToasts = opts.maxToasts end
    if opts.defaultDuration then CONFIG.defaultDuration = opts.defaultDuration end
    if opts.position then CONFIG.position = opts.position end
    if opts.margin then CONFIG.margin = opts.margin end
    if opts.toastWidth then CONFIG.toastWidth = opts.toastWidth end
    if opts.toastHeight then CONFIG.toastHeight = opts.toastHeight end
end

function M.setPosition(position)
    CONFIG.position = position
end

-- ============================================================
-- STATE QUERIES
-- ============================================================

function M.count()
    return #_toasts
end

function M.isEmpty()
    return #_toasts == 0
end

return M
