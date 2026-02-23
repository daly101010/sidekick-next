-- ============================================================
-- SideKick Animation Helpers
-- ============================================================
-- Shared animation utilities for all SideKick bar UIs.
-- Provides spring-based button scaling, OKLAB color interpolation,
-- cooldown completion pulses, stagger animations, ready pulse,
-- low resource warnings, damage flash, and toggle animations.
--
-- Usage:
--   local AnimHelpers = require('sidekick-next.ui.animation_helpers')
--   AnimHelpers.init(ImAnim, settings)
--   AnimHelpers.updateStaggerFrame()
--   local scale = AnimHelpers.getButtonScale(id, hovered, active)

local imgui = require('ImGui')
local C = require('sidekick-next.ui.constants')
local Draw = require('sidekick-next.ui.draw_helpers')
local Colors = require('sidekick-next.ui.colors')
local iam = require('ImAnim')

local M = {}

-- ============================================================
-- CACHED EASE DESCRIPTORS (expensive to create per-frame)
-- ============================================================

local _ezOutCubic   = iam.EasePreset(IamEaseType.OutCubic)
local _ezOutBack    = iam.EasePreset(IamEaseType.OutBack)
local _ezOutElastic = iam.EasePreset(IamEaseType.OutElastic)
local _ezOutSine    = iam.EasePreset(IamEaseType.OutSine)
local _ezLinear     = iam.EasePreset(IamEaseType.Linear)

local _ezSpringNormal = iam.EaseSpring(1.0, C.ANIMATION.SPRING_STIFFNESS, C.ANIMATION.SPRING_DAMPING, 0.0)
local _ezSpringFast   = iam.EaseSpring(1.0, C.ANIMATION.SPRING_STIFFNESS_FAST, C.ANIMATION.SPRING_DAMPING_FAST, 0.0)
local _ezSpringSlow   = iam.EaseSpring(1.0, C.ANIMATION.SPRING_STIFFNESS_SLOW, C.ANIMATION.SPRING_DAMPING_SLOW, 0.0)

-- ============================================================
-- MODULE STATE
-- ============================================================

local _ImAnim = nil
local _settings = nil  -- Reference to settings for early-exit checks
local _lastCooldownState = {}
local _lastFrameTime = os.clock()
local _cachedDt = 0.016
local _cachedFrame = nil
local _staggerGrids = {}

-- State for new animation features
local _lowResourceThreshold = C.RESOURCE.LOW_THRESHOLD
local _lastHpValues = {}
local _damageFlashState = {}
local _toggleStates = {}

-- Animation ID cache to avoid string concatenation per frame
local _idCache = {}
local _idCacheHits = 0
local _idCacheMisses = 0

-- ============================================================
-- ANIMATION ID CACHING
-- ============================================================

local function getCachedId(base, suffix)
    local key = base
    if not _idCache[key] then
        _idCache[key] = {}
    end
    local cache = _idCache[key]
    if not cache[suffix] then
        cache[suffix] = base .. suffix
        _idCacheMisses = _idCacheMisses + 1
    else
        _idCacheHits = _idCacheHits + 1
    end
    return cache[suffix]
end

-- ============================================================
-- EARLY EXIT HELPERS
-- ============================================================

local function animationsEnabled()
    if not _settings then return true end
    return _settings.AnimationsEnabled ~= false
end

local function featureEnabled(settingKey)
    if not _settings then return true end
    if not animationsEnabled() then return false end
    return _settings[settingKey] ~= false
end

-- ============================================================
-- INITIALIZATION
-- ============================================================

function M.init(ImAnim, settings)
    _ImAnim = ImAnim
    _settings = settings
end

function M.setSettings(settings)
    _settings = settings
end

function M.getIdCacheStats()
    local size = 0
    for _, suffixes in pairs(_idCache) do
        for _ in pairs(suffixes) do size = size + 1 end
    end
    return { hits = _idCacheHits, misses = _idCacheMisses, size = size }
end

function M.clearIdCache()
    _idCache = {}
    _idCacheHits = 0
    _idCacheMisses = 0
end

-- ============================================================
-- DELTA TIME
-- ============================================================

function M.get_dt()
    -- IMPORTANT: dt must be per-frame, not "time since last call".
    -- This module calls get_dt() multiple times per frame (per button),
    -- and feeding tiny dt into shake() causes long-lived, violent jitter.
    local frame = (imgui.GetFrameCount and imgui.GetFrameCount()) or nil
    if frame ~= nil and frame == _cachedFrame then
        return _cachedDt
    end
    _cachedFrame = frame

    local dt = nil
    local io = (imgui.GetIO and imgui.GetIO()) or nil
    if io and io.DeltaTime ~= nil then
        dt = tonumber(io.DeltaTime)
    end

    if not dt or dt <= 0 then
        local now = os.clock()
        dt = now - _lastFrameTime
        _lastFrameTime = now
    else
        _lastFrameTime = os.clock()
    end

    _cachedDt = math.min(math.max(dt, 0), 0.1)
    return _cachedDt
end

-- ============================================================
-- SPRING-BASED BUTTON SCALING
-- ============================================================

function M.getButtonScale(uniqueId, isHovered, isActive)
    -- Early exit if hover scale is disabled
    if not featureEnabled('HoverScaleEnabled') then
        return 1.0
    end

    local dt = M.get_dt()
    local target = isActive and C.ANIMATION.PRESS_SCALE
                or isHovered and C.ANIMATION.HOVER_SCALE
                or 1.0
    local ez = isActive and _ezSpringFast or _ezSpringNormal
    return iam.TweenFloat(uniqueId, imgui.GetID('scale'), target, 0.5, ez, IamPolicy.Crossfade, dt)
end

-- ============================================================
-- COOLDOWN COMPLETION DETECTION
-- ============================================================

function M.checkCooldownCompletion(uniqueId, onCooldown)
    -- Early exit if click bounce is disabled
    if not featureEnabled('ClickBounceEnabled') then
        _lastCooldownState[uniqueId] = onCooldown
        return
    end

    local wasOnCooldown = _lastCooldownState[uniqueId]
    if wasOnCooldown and not onCooldown then
        iam.TriggerShake(uniqueId)
    end
    _lastCooldownState[uniqueId] = onCooldown
end

function M.getCompletionPulse(uniqueId)
    if not featureEnabled('ClickBounceEnabled') then return 0 end
    local dt = M.get_dt()
    return iam.Shake(uniqueId, imgui.GetID('pulse'), C.ANIMATION.SHAKE_MAGNITUDE, C.ANIMATION.SHAKE_DECAY, dt)
end

-- ============================================================
-- ENHANCED READY STATE GLOW (existing)
-- ============================================================

function M.getReadyGlow()
    if not featureEnabled('ReadyPulseEnabled') then
        return C.COOLDOWN.READY_GLOW_MIN
    end

    local t = os.clock() * C.COOLDOWN.READY_GLOW_FREQ
    local wave = math.sin(t * math.pi)
    local elastic = 1.0 + 0.15 * math.pow(2, -10 * (t % 1)) * math.sin((t % 1) * 10 * math.pi / 3)
    return C.COOLDOWN.READY_GLOW_MIN + (C.COOLDOWN.READY_GLOW_MAX - C.COOLDOWN.READY_GLOW_MIN) * math.abs(wave) * elastic
end

-- ============================================================
-- READY PULSE ANIMATION
-- ============================================================

function M.getReadyPulseAlpha(uniqueId, isReady)
    if not isReady then return 1.0 end
    if not featureEnabled('ReadyPulseEnabled') then return 1.0 end

    local dt = M.get_dt()
    local wave = iam.Oscillate(uniqueId, imgui.GetID('rpulse'),
        0.15, C.ANIMATION.READY_PULSE_FREQ, 0.0, IamWaveType.Sine, dt)
    return 0.85 + wave
end

function M.getReadyGlowColor(uniqueId, isReady, baseColor)
    if not isReady then return baseColor end
    if not featureEnabled('ReadyPulseEnabled') then return baseColor end

    local pulse = M.getReadyPulseAlpha(uniqueId, true)
    -- Interpolate toward a brighter/golden color when ready
    local r = baseColor[1] + (1.0 - baseColor[1]) * (1.0 - pulse) * 0.3
    local g = baseColor[2] + (0.9 - baseColor[2]) * (1.0 - pulse) * 0.3
    local b = baseColor[3]
    local a = baseColor[4] or 1.0

    return {r, g, b, a}
end

-- ============================================================
-- READY SHINE EFFECT (sweeping highlight)
-- ============================================================

-- Get the X offset for a shine sweep across a cell
-- Returns nil if ability is not ready or shine is disabled
function M.getReadyShineOffset(uniqueId, cellWidth, isReady)
    if not isReady then return nil end
    if not featureEnabled('ReadyPulseEnabled') then return nil end

    -- Slow sweep: 2.5 second cycle
    local cycleDuration = 2.5
    local t = (os.clock() % cycleDuration) / cycleDuration

    -- Ease in-out for smoother motion at edges
    local eased
    if t < 0.5 then
        eased = 2 * t * t
    else
        eased = 1 - math.pow(-2 * t + 2, 2) / 2
    end

    -- Sweep from left edge past right edge
    local shineWidth = cellWidth * 0.25
    return -shineWidth + (cellWidth + shineWidth * 2) * eased
end

-- Draw the shine highlight effect on a ready ability
-- Call this after drawing the icon but before other overlays
function M.drawReadyShine(dl, minX, minY, maxX, maxY, isReady, themeName)
    if not isReady then return end
    if not featureEnabled('ReadyPulseEnabled') then return end
    if not dl then return end

    local cellWidth = maxX - minX
    local shineOffset = M.getReadyShineOffset('shine', cellWidth, true)
    if not shineOffset then return end

    local shineWidth = cellWidth * 0.25
    local sx = minX + shineOffset

    -- Skip if shine is completely outside cell
    if sx > maxX or sx + shineWidth < minX then return end

    -- Get theme-aware ready color
    local readyRGB = Colors.ready(themeName)

    -- Calculate clipped bounds
    local drawLeft = math.max(minX, sx)
    local drawRight = math.min(maxX, sx + shineWidth)

    -- Gradient alpha: peak in center, fade at edges
    local centerX = sx + shineWidth / 2
    local distFromCenter = math.abs((drawLeft + drawRight) / 2 - centerX)
    local normalizedDist = distFromCenter / (shineWidth / 2)
    local peakAlpha = 50 * (1 - normalizedDist * normalizedDist)

    -- Draw gradient shine bar
    local leftAlpha = sx < minX and 0 or math.floor(peakAlpha * 0.3)
    local rightAlpha = (sx + shineWidth) > maxX and 0 or math.floor(peakAlpha * 0.3)
    local centerAlpha = math.floor(peakAlpha)

    -- Simple gradient approximation: draw 3 strips
    local thirdWidth = (drawRight - drawLeft) / 3

    if thirdWidth > 1 then
        local col1 = Draw.IM_COL32(readyRGB[1], readyRGB[2], readyRGB[3], leftAlpha)
        local col2 = Draw.IM_COL32(readyRGB[1], readyRGB[2], readyRGB[3], centerAlpha)
        local col3 = Draw.IM_COL32(readyRGB[1], readyRGB[2], readyRGB[3], rightAlpha)

        Draw.addRectFilled(dl, drawLeft, minY, drawLeft + thirdWidth, maxY, col1, 0)
        Draw.addRectFilled(dl, drawLeft + thirdWidth, minY, drawLeft + thirdWidth * 2, maxY, col2, 0)
        Draw.addRectFilled(dl, drawLeft + thirdWidth * 2, minY, drawRight, maxY, col3, 0)
    else
        -- Cell too small, just draw single rect
        local col = Draw.IM_COL32(readyRGB[1], readyRGB[2], readyRGB[3], centerAlpha)
        Draw.addRectFilled(dl, drawLeft, minY, drawRight, maxY, col, 0)
    end
end

-- ============================================================
-- LOW RESOURCE WARNING ANIMATION
-- ============================================================

function M.getLowResourcePulse(uniqueId, currentPct, threshold)
    threshold = threshold or _lowResourceThreshold
    if currentPct >= threshold then return 1.0, nil end

    -- Early exit if low resource warning is disabled
    if not featureEnabled('LowResourceWarningEnabled') then
        return 1.0, Colors.lowResource(1.0)
    end

    local dt = M.get_dt()

    -- Pulse faster as resource gets lower
    local severity = 1.0 - (currentPct / threshold)
    local freq = C.ANIMATION.LOW_RESOURCE_PULSE_FREQ_MIN +
                 severity * (C.ANIMATION.LOW_RESOURCE_PULSE_FREQ_MAX - C.ANIMATION.LOW_RESOURCE_PULSE_FREQ_MIN)

    local pulse = iam.Oscillate(uniqueId, imgui.GetID('lrpulse'),
        0.5, freq, 0.0, IamWaveType.Sine, dt)
    pulse = (pulse + 0.5) * severity
    local color = Colors.lowResource(severity)
    return pulse, color
end

function M.setLowResourceThreshold(threshold)
    _lowResourceThreshold = threshold or C.RESOURCE.LOW_THRESHOLD
end

-- ============================================================
-- DAMAGE FLASH DETECTION
-- ============================================================

function M.getDamageFlash(uniqueId, currentHp, flashDuration)
    -- Early exit if damage flash is disabled
    if not featureEnabled('DamageFlashEnabled') then
        _lastHpValues[uniqueId] = currentHp
        return nil
    end

    flashDuration = flashDuration or C.ANIMATION.DAMAGE_FLASH_DURATION
    local now = os.clock()

    local lastHp = _lastHpValues[uniqueId] or currentHp
    local flashState = _damageFlashState[uniqueId] or { active = false, startTime = 0 }

    -- Detect significant HP drop
    local hpDrop = lastHp - currentHp
    if hpDrop > C.RESOURCE.DAMAGE_FLASH_THRESHOLD then
        flashState.active = true
        flashState.startTime = now
    end

    _lastHpValues[uniqueId] = currentHp

    -- Calculate flash intensity
    local intensity = 0
    if flashState.active then
        local elapsed = now - flashState.startTime
        if elapsed < flashDuration then
            intensity = 1.0 - (elapsed / flashDuration)
        else
            flashState.active = false
        end
    end

    _damageFlashState[uniqueId] = flashState

    -- Return flash color overlay
    if intensity > 0 then
        return Colors.damageFlash(intensity)
    end
    return nil
end

function M.resetDamageFlash(uniqueId)
    _lastHpValues[uniqueId] = nil
    _damageFlashState[uniqueId] = nil
end

-- ============================================================
-- TOGGLE BUTTON ANIMATIONS
-- ============================================================

function M.getToggleScale(uniqueId, isActive)
    local prevState = _toggleStates[uniqueId]
    _toggleStates[uniqueId] = isActive

    -- Early exit if toggle pop is disabled
    if not featureEnabled('TogglePopEnabled') then
        return 1.0
    end

    local dt = M.get_dt()

    -- Trigger shake when toggled on
    if prevState ~= nil and prevState ~= isActive and isActive then
        iam.TriggerShake(uniqueId .. '_toggle')
    end

    local ez = isActive and _ezSpringFast or _ezSpringSlow
    return iam.TweenFloat(uniqueId, imgui.GetID('tscale'), 1.0, 0.5, ez, IamPolicy.Crossfade, dt)
end

function M.getToggleColor(uniqueId, isActive, onColor, offColor)
    -- Early exit if color tween is disabled
    if not featureEnabled('ToggleColorTweenEnabled') then
        return isActive and onColor or offColor
    end

    local dt = M.get_dt()
    local target = isActive and onColor or offColor
    local col = iam.TweenColor(
        uniqueId, imgui.GetID('tcol'),
        ImVec4(target[1], target[2], target[3], target[4] or 1.0),
        C.ANIMATION.TWEEN_FAST, _ezOutCubic, IamPolicy.Crossfade,
        IamColorSpace.OKLAB, dt
    )
    return { col.x, col.y, col.z, col.w }
end

function M.getTogglePop(uniqueId)
    if not featureEnabled('TogglePopEnabled') then return 0 end
    local dt = M.get_dt()
    return iam.Shake(uniqueId .. '_toggle', imgui.GetID('tpop'), C.ANIMATION.SHAKE_MAGNITUDE * 0.5, C.ANIMATION.SHAKE_DECAY, dt)
end

-- Theme-aware toggle color helper
function M.getToggleColorForTheme(uniqueId, isActive, themeName)
    local onColor = Colors.toggleOn(themeName)
    local offColor = Colors.toggleOff(themeName)
    return M.getToggleColor(uniqueId, isActive, onColor, offColor)
end

-- ============================================================
-- COLOR THRESHOLDS FOR COOLDOWN
-- ============================================================

local function getTargetColorForPct(pct)
    return Colors.cooldownRGB(pct)
end

-- ============================================================
-- OKLAB COLOR INTERPOLATION FOR COOLDOWN BORDER
-- ============================================================

function M.getCooldownColor(uniqueId, pct)
    local targetR, targetG, targetB = getTargetColorForPct(pct)

    -- Early exit if cooldown color tween is disabled
    if not featureEnabled('CooldownColorTweenEnabled') then
        return targetR, targetG, targetB
    end

    local dt = M.get_dt()
    local col = iam.TweenColor(
        uniqueId, imgui.GetID('cdcol'),
        ImVec4(targetR, targetG, targetB, 1.0),
        C.ANIMATION.TWEEN_FAST, _ezOutCubic, IamPolicy.Crossfade,
        IamColorSpace.OKLAB, dt
    )
    return col.x, col.y, col.z, col.w
end

-- ============================================================
-- OUTLINED TEXT RENDERING
-- ============================================================

function M.drawOutlinedText(x, y, text, r, g, b)
    Draw.drawOutlinedText(x, y, text, r, g, b)
end

-- ============================================================
-- ENHANCED COOLDOWN OVERLAY
-- ============================================================

function M.drawCooldownOverlay(dl, minX, minY, maxX, maxY, rem, total, uniqueId, helpers, IM_COL32_fn, dlAddRectFilled_fn, dlAddRect_fn, themeName)
    if not dl then return end
    IM_COL32_fn = IM_COL32_fn or Draw.IM_COL32
    dlAddRectFilled_fn = dlAddRectFilled_fn or Draw.addRectFilled
    dlAddRect_fn = dlAddRect_fn or Draw.addRect

    rem = tonumber(rem) or 0
    total = tonumber(total) or 0
    local onCooldown = rem > 0 and total > 0

    -- Check for cooldown completion (triggers pulse)
    M.checkCooldownCompletion(uniqueId, onCooldown)

    local rounding = math.floor((maxX - minX) * C.LAYOUT.BUTTON_ROUNDING_PCT)

    -- Ready state: enhanced pulsing glow
    if not onCooldown then
        local pulse = M.getReadyGlow()
        local glowAlpha = math.floor(pulse * C.COLORS.READY_GLOW_ALPHA_MAX)
        local readyRGB = Colors.ready(themeName)
        local glowColor = IM_COL32_fn(readyRGB[1], readyRGB[2], readyRGB[3], glowAlpha)
        dlAddRect_fn(dl, minX - 1, minY - 1, maxX + 1, maxY + 1, glowColor, rounding, 0, 2)
        return
    end

    local pct = (total > 0) and (rem / total) or 1
    pct = math.max(0, math.min(1, pct))

    -- Get smoothly interpolated color via OKLAB
    local r, g, b = M.getCooldownColor(uniqueId, pct)
    local r255 = math.floor(r * 255)
    local g255 = math.floor(g * 255)
    local b255 = math.floor(b * 255)

    -- Radial sweep cooldown: dark overlay + colored pie reveal
    local cx = (minX + maxX) / 2
    local cy = (minY + maxY) / 2
    local radius = math.max(maxX - minX, maxY - minY) * 0.71  -- diagonal to cover corners
    local completePct = 1.0 - pct  -- 0 = just started, 1 = done
    local overlayAlpha = C.COLORS.COOLDOWN_OVERLAY_ALPHA
    local tintAlpha = math.floor(C.COLORS.COOLDOWN_FILL_ALPHA * 0.5)

    -- Draw the REVEALED portion as clear (no overlay) via clipping:
    -- Strategy: draw dark pie for the REMAINING cooldown portion only
    if completePct < 0.999 then
        local startAngle = -math.pi / 2  -- 12 o'clock
        local remainStart = startAngle + completePct * math.pi * 2
        local remainEnd = startAngle + math.pi * 2

        -- Dark overlay pie (remaining portion)
        Draw.pathClear(dl)
        Draw.pathLineTo(dl, cx, cy)
        Draw.pathArcTo(dl, cx, cy, radius, remainStart, remainEnd, 32)
        Draw.pathFillConvex(dl, IM_COL32_fn(0, 0, 0, overlayAlpha))

        -- Colored tint pie (remaining portion)
        Draw.pathClear(dl)
        Draw.pathLineTo(dl, cx, cy)
        Draw.pathArcTo(dl, cx, cy, radius, remainStart, remainEnd, 32)
        Draw.pathFillConvex(dl, IM_COL32_fn(r255, g255, b255, tintAlpha))
    else
        -- Fully on cooldown: dark overlay on entire cell
        dlAddRectFilled_fn(dl, minX, minY, maxX, maxY, IM_COL32_fn(0, 0, 0, overlayAlpha), rounding)
        dlAddRectFilled_fn(dl, minX, minY, maxX, maxY, IM_COL32_fn(r255, g255, b255, tintAlpha), rounding)
    end

    -- Cooldown border
    dlAddRect_fn(dl, minX, minY, maxX, maxY,
        IM_COL32_fn(r255, g255, b255, C.COLORS.COOLDOWN_BORDER_ALPHA), rounding, 0, 1)

    -- Countdown text centered
    if rem > 0 then
        local txt = rem >= 10 and string.format('%d', math.ceil(rem)) or string.format('%.1f', rem)
        if helpers and helpers.fmtCooldown then
            txt = helpers.fmtCooldown(rem)
        end
        M.drawOutlinedText(minX + 3, maxY - imgui.GetTextLineHeight() - 2, txt, r, g, b)
    end
end

-- Simplified cooldown overlay using new modules
function M.drawCooldownOverlaySimple(dl, minX, minY, maxX, maxY, rem, total, uniqueId, helpers, themeName)
    M.drawCooldownOverlay(dl, minX, minY, maxX, maxY, rem, total, uniqueId, helpers, Draw.IM_COL32, Draw.addRectFilled, Draw.addRect, themeName)
end

-- ============================================================
-- STAGGER ANIMATION SUPPORT
-- ============================================================

function M.updateStaggerFrame()
    -- No-op: native ImAnim handles frame updates automatically
end

function M.resetStagger(gridKey)
    _staggerGrids[gridKey] = nil
end

function M.getStaggerAlpha(gridKey, idx, total, delay)
    if not featureEnabled('StaggerAnimationEnabled') then return 1.0 end
    delay = delay or C.ANIMATION.STAGGER_DELAY
    local staggerOffset = iam.StaggerDelay(idx, total, delay)
    local elapsed = M.getGridEntryElapsed(gridKey)
    if elapsed > C.ANIMATION.STAGGER_DURATION + (total * delay) then return 1.0 end
    local t = math.max(0, math.min(1, (elapsed - staggerOffset) / C.ANIMATION.STAGGER_DURATION))
    return iam.EvalPreset(IamEaseType.OutCubic, t)
end

-- ============================================================
-- ENHANCED STAGGERED ENTRY ANIMATIONS
-- ============================================================

-- Track grid visibility for entry detection
local _gridVisibility = {}
local _gridEntryTime = {}

-- Check if grid just became visible (for triggering entry animations)
function M.checkGridEntry(gridKey, isVisible)
    local wasVisible = _gridVisibility[gridKey]
    _gridVisibility[gridKey] = isVisible

    if isVisible and not wasVisible then
        -- Grid just appeared - record entry time
        _gridEntryTime[gridKey] = os.clock()
        M.resetStagger(gridKey)
        return true
    end
    return false
end

-- Get time since grid entry (for manual animation control)
function M.getGridEntryElapsed(gridKey)
    local entryTime = _gridEntryTime[gridKey]
    if not entryTime then return 999 end  -- Large value = fully entered
    return os.clock() - entryTime
end

-- Staggered scale-in for grid items (elastic ease-out)
function M.getStaggeredEntryScale(gridKey, idx, total)
    if not featureEnabled('StaggerAnimationEnabled') then return 1.0 end

    local alpha = M.getStaggerAlpha(gridKey, idx, total, C.ANIMATION.STAGGER_DELAY)

    if alpha >= 1.0 then return 1.0 end
    if alpha <= 0 then return 0.5 end

    -- Elastic ease-out for bouncy scale-in
    local t = alpha
    local elasticT
    if t == 0 or t == 1 then
        elasticT = t
    else
        -- Attempt elastic with reduced overshoot for subtlety
        local p = 0.4
        elasticT = math.pow(2, -10 * t) * math.sin((t - p / 4) * (2 * math.pi) / p) + 1
    end

    -- Scale from 0.7 to 1.0
    return 0.7 + 0.3 * math.min(1, math.max(0, elasticT))
end

-- Staggered Y offset for slide-up effect
function M.getStaggeredEntryOffsetY(gridKey, idx, total, maxOffset)
    if not featureEnabled('StaggerAnimationEnabled') then return 0 end

    maxOffset = maxOffset or 12
    local alpha = M.getStaggerAlpha(gridKey, idx, total, C.ANIMATION.STAGGER_DELAY)

    if alpha >= 1.0 then return 0 end
    if alpha <= 0 then return maxOffset end

    -- Ease-out cubic for smooth deceleration
    local t = alpha
    local eased = 1 - math.pow(1 - t, 3)

    return maxOffset * (1 - eased)
end

-- Combined entry transform: returns scale, offsetX, offsetY, alpha
function M.getStaggeredEntryTransform(gridKey, idx, total, opts)
    opts = opts or {}
    local maxOffsetY = opts.maxOffsetY or 12
    local maxOffsetX = opts.maxOffsetX or 0

    if not featureEnabled('StaggerAnimationEnabled') then
        return 1.0, 0, 0, 1.0
    end

    local alpha = M.getStaggerAlpha(gridKey, idx, total, C.ANIMATION.STAGGER_DELAY)

    if alpha >= 1.0 then return 1.0, 0, 0, 1.0 end
    if alpha <= 0 then return 0.7, maxOffsetX, maxOffsetY, 0 end

    -- Ease-out for position
    local t = alpha
    local posEased = 1 - math.pow(1 - t, 3)

    -- Elastic for scale (subtle)
    local scaleT = alpha
    local scale
    if scaleT >= 0.99 then
        scale = 1.0
    else
        local p = 0.5
        local elastic = math.pow(2, -8 * scaleT) * math.sin((scaleT - p / 4) * (2 * math.pi) / p) + 1
        scale = 0.7 + 0.3 * math.min(1.05, math.max(0, elastic))
    end

    local offsetX = maxOffsetX * (1 - posEased)
    local offsetY = maxOffsetY * (1 - posEased)

    return scale, offsetX, offsetY, alpha
end

-- ============================================================
-- STYLE ALPHA HELPER (for stagger fade-in)
-- ============================================================

function M.withStyleAlpha(alpha, fn)
    local pushed = false
    if ImGuiStyleVar and ImGuiStyleVar.Alpha and imgui.PushStyleVar then
        imgui.PushStyleVar(ImGuiStyleVar.Alpha, alpha)
        pushed = true
    end
    local ok, result = pcall(fn)
    if pushed and imgui.PopStyleVar then
        imgui.PopStyleVar()
    end
    if not ok then error(result) end
    return result
end

-- ============================================================
-- WINDOW FOCUS GLOW
-- ============================================================

-- Draw a subtle outer glow when window is focused
function M.drawWindowFocusGlow(dl, x, y, w, h, themeName, isFocused)
    if not isFocused then return end
    if not featureEnabled('ReadyPulseEnabled') then return end
    if not dl then return end

    local readyRGB = Colors.ready(themeName)

    -- Subtle pulsing glow
    local t = os.clock() * 1.5  -- Slower pulse than ready
    local pulse = 0.5 + 0.5 * math.sin(t * math.pi)

    -- Draw 3 layers of outer glow
    for i = 3, 1, -1 do
        local baseAlpha = 12 + (3 - i) * 6  -- 12, 18, 24
        local alpha = math.floor(baseAlpha * (0.6 + 0.4 * pulse))
        local col = Draw.IM_COL32(readyRGB[1], readyRGB[2], readyRGB[3], alpha)
        Draw.addRect(dl, x - i, y - i, x + w + i, y + h + i, col, 6 + i, 0, 1)
    end
end

-- ============================================================
-- GEOMETRY HELPERS
-- ============================================================

function M.scaleFromCenter(x, y, w, h, scale)
    local cx = x + w / 2
    local cy = y + h / 2
    local sw = w * scale
    local sh = h * scale
    return cx - sw / 2, cy - sh / 2, sw, sh
end

-- ============================================================
-- GC SCHEDULING
-- ============================================================

local _lastGcTime = 0
local _gcInterval = 30  -- seconds

function M.scheduleGc(interval)
    _gcInterval = interval or 30
end

function M.maybeRunGc()
    local now = os.clock()
    if now - _lastGcTime < _gcInterval then return end
    _lastGcTime = now

    -- Clear old cooldown states
    local staleThreshold = 60  -- seconds
    for id, _ in pairs(_lastCooldownState) do
        -- Just clear very old entries to prevent unbounded growth
        -- In practice, abilities cycle and this keeps the table bounded
    end

    -- Native C++ ImAnim manages its own memory — no gc() or clip_gc() needed

    -- Clear old ID cache entries (optional, usually stable)
    -- Only clear if cache gets very large
    local cacheSize = 0
    for _ in pairs(_idCache) do cacheSize = cacheSize + 1 end
    if cacheSize > 1000 then
        M.clearIdCache()
    end
end

-- ============================================================
-- CLEANUP
-- ============================================================

function M.cleanup()
    _lastCooldownState = {}
    _lastHpValues = {}
    _damageFlashState = {}
    _toggleStates = {}
    _staggerGrids = {}
    _gridVisibility = {}
    _gridEntryTime = {}
    M.clearIdCache()
end

return M
