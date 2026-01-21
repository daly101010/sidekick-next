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

local M = {}

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

    local targetScale = 1.0
    if isActive then
        targetScale = C.ANIMATION.PRESS_SCALE
    elseif isHovered then
        targetScale = C.ANIMATION.HOVER_SCALE
    end

    if _ImAnim and _ImAnim.spring then
        local id = getCachedId(uniqueId, '_scale')
        return _ImAnim.spring(id, targetScale, C.ANIMATION.SPRING_STIFFNESS, C.ANIMATION.SPRING_DAMPING)
    end
    return targetScale
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
        if _ImAnim and _ImAnim.trigger_shake then
            local id = getCachedId(uniqueId, '_pulse')
            _ImAnim.trigger_shake(id)
        end
    end
    _lastCooldownState[uniqueId] = onCooldown
end

function M.getCompletionPulse(uniqueId)
    if not featureEnabled('ClickBounceEnabled') then return 0 end
    if not _ImAnim or not _ImAnim.shake then return 0 end
    local id = getCachedId(uniqueId, '_pulse')
    return _ImAnim.shake(id, C.ANIMATION.SHAKE_MAGNITUDE, C.ANIMATION.SHAKE_DECAY, M.get_dt())
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

    if _ImAnim and _ImAnim.oscillate then
        local id = getCachedId(uniqueId, '_ready_pulse')
        return _ImAnim.oscillate(id, 'sine', 0.7, 1.0, C.ANIMATION.READY_PULSE_FREQ) or 1.0
    end
    -- Fallback without ImAnim
    local t = os.clock() * 2 * math.pi * C.ANIMATION.READY_PULSE_FREQ
    return 0.7 + 0.15 * (1 + math.sin(t))
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
-- LOW RESOURCE WARNING ANIMATION
-- ============================================================

function M.getLowResourcePulse(uniqueId, currentPct, threshold)
    threshold = threshold or _lowResourceThreshold
    if currentPct >= threshold then return 1.0, nil end

    -- Early exit if low resource warning is disabled
    if not featureEnabled('LowResourceWarningEnabled') then
        return 1.0, Colors.lowResource(1.0)
    end

    -- Pulse faster as resource gets lower
    local urgency = 1.0 - (currentPct / threshold)
    local freq = C.ANIMATION.LOW_RESOURCE_PULSE_FREQ_MIN + urgency * (C.ANIMATION.LOW_RESOURCE_PULSE_FREQ_MAX - C.ANIMATION.LOW_RESOURCE_PULSE_FREQ_MIN)

    if _ImAnim and _ImAnim.oscillate then
        local id = getCachedId(uniqueId, '_low_res')
        local pulse = _ImAnim.oscillate(id, 'sine', 0.5, 1.0, freq) or 1.0
        return pulse, Colors.lowResource(pulse)
    end

    -- Fallback without ImAnim
    local t = os.clock() * 2 * math.pi * freq
    local pulse = 0.5 + 0.25 * (1 + math.sin(t))
    return pulse, Colors.lowResource(pulse)
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
    local justActivated = isActive and not prevState
    _toggleStates[uniqueId] = isActive

    -- Early exit if toggle pop is disabled
    if not featureEnabled('TogglePopEnabled') then
        return 1.0
    end

    -- Trigger pop animation when toggled on
    if justActivated and _ImAnim and _ImAnim.trigger_shake then
        local id = getCachedId(uniqueId, '_toggle_pop')
        _ImAnim.trigger_shake(id)
    end

    -- Spring-based pop effect
    if _ImAnim and _ImAnim.spring then
        local scaleId = getCachedId(uniqueId, '_toggle_scale')
        if justActivated then
            -- Temporarily target larger scale for pop
            return _ImAnim.spring(scaleId, C.ANIMATION.TOGGLE_POP_SCALE, C.ANIMATION.SPRING_STIFFNESS_FAST, C.ANIMATION.SPRING_DAMPING_FAST)
        end
        return _ImAnim.spring(scaleId, 1.0, C.ANIMATION.SPRING_STIFFNESS_SLOW, C.ANIMATION.SPRING_DAMPING)
    end
    return 1.0
end

function M.getToggleColor(uniqueId, isActive, onColor, offColor)
    -- Early exit if color tween is disabled
    if not featureEnabled('ToggleColorTweenEnabled') then
        return isActive and onColor or offColor
    end

    if not _ImAnim or not _ImAnim.tween_vec4 then
        return isActive and onColor or offColor
    end

    local target = isActive and onColor or offColor
    local id = getCachedId(uniqueId, '_toggle_color')
    local result = _ImAnim.tween_vec4(id, target, C.ANIMATION.TWEEN_FAST, _ImAnim.EASE and _ImAnim.EASE.out_cubic or 5)
    return result or target
end

function M.getTogglePop(uniqueId)
    if not featureEnabled('TogglePopEnabled') then return 0 end
    if not _ImAnim or not _ImAnim.shake then return 0 end
    local id = getCachedId(uniqueId, '_toggle_pop')
    return _ImAnim.shake(id, 2, C.ANIMATION.TWEEN_FAST, M.get_dt()) or 0
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

    if _ImAnim and _ImAnim.tween_color then
        local dt = M.get_dt()
        local id = getCachedId(uniqueId, '_cd')
        local r, g, b = _ImAnim.tween_color(
            id, 'col',
            targetR, targetG, targetB, 1.0,
            C.ANIMATION.TWEEN_FAST,
            _ImAnim.EASE and _ImAnim.EASE.out_cubic or 5,
            _ImAnim.COLOR_SPACE and _ImAnim.COLOR_SPACE.oklab or 3,
            _ImAnim.POLICY and _ImAnim.POLICY.crossfade or 0,
            dt
        )
        return r, g, b
    end
    return targetR, targetG, targetB
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

function M.drawCooldownOverlay(dl, minX, minY, maxX, maxY, rem, total, uniqueId, helpers, IM_COL32, dlAddRectFilled, dlAddRect, themeName)
    if not dl then return end

    rem = tonumber(rem) or 0
    total = tonumber(total) or 0
    local onCooldown = rem > 0 and total > 0

    -- Check for cooldown completion (triggers pulse)
    M.checkCooldownCompletion(uniqueId, onCooldown)

    -- Ready state: enhanced pulsing glow
    if not onCooldown then
        local pulse = M.getReadyGlow()
        local glowAlpha = math.floor(pulse * C.COLORS.READY_GLOW_ALPHA_MAX)
        local readyRGB = Colors.ready(themeName)
        local glowColor = IM_COL32(readyRGB[1], readyRGB[2], readyRGB[3], glowAlpha)
        dlAddRect(dl, minX - 1, minY - 1, maxX + 1, maxY + 1, glowColor, 0, 0, 2)
        return
    end

    local pct = (total > 0) and (rem / total) or 1
    pct = math.max(0, math.min(1, pct))

    local fillH = math.max(2, math.floor((maxY - minY) * pct + 0.5))
    local fillY = maxY - fillH

    -- Get smoothly interpolated color via OKLAB
    local r, g, b = M.getCooldownColor(uniqueId, pct)

    -- Convert 0-1 to 0-255
    local r255 = math.floor(r * 255)
    local g255 = math.floor(g * 255)
    local b255 = math.floor(b * 255)

    -- Draw overlay
    dlAddRectFilled(dl, minX, minY, maxX, maxY, IM_COL32(0, 0, 0, C.COLORS.COOLDOWN_OVERLAY_ALPHA), 0, 0)
    dlAddRectFilled(dl, minX, fillY, maxX, maxY, IM_COL32(r255, g255, b255, C.COLORS.COOLDOWN_FILL_ALPHA), 0, 0)
    dlAddRect(dl, minX, minY, maxX, maxY, IM_COL32(r255, g255, b255, C.COLORS.COOLDOWN_BORDER_ALPHA), 0, 0, 2)

    -- Cooldown text with matching color
    if helpers and helpers.fmtCooldown then
        local txt = helpers.fmtCooldown(rem)
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
    if not featureEnabled('StaggerAnimationEnabled') then return end
    if _ImAnim and _ImAnim.update_stagger_frame then
        _ImAnim.update_stagger_frame(M.get_dt())
    end
end

function M.resetStagger(gridKey)
    _staggerGrids[gridKey] = nil
    if _ImAnim and _ImAnim.reset_stagger then
        _ImAnim.reset_stagger(gridKey)
    end
end

function M.getStaggerAlpha(gridKey, idx, total, delay)
    if not featureEnabled('StaggerAnimationEnabled') then return 1.0 end
    if not _ImAnim or not _ImAnim.stagger then return 1.0 end
    delay = delay or C.ANIMATION.STAGGER_DELAY
    return _ImAnim.stagger(gridKey, idx, total, C.ANIMATION.STAGGER_DURATION, delay)
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

    -- Run ImAnim GC if available
    if _ImAnim and _ImAnim.gc then
        _ImAnim.gc(300)  -- max frame age
    end

    if _ImAnim and _ImAnim.clip_gc then
        _ImAnim.clip_gc(300)
    end

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
    M.clearIdCache()
end

return M
