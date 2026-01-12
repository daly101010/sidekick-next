-- ============================================================
-- SideKick Animation Helpers
-- ============================================================
-- Shared animation utilities for all SideKick bar UIs.
-- Provides spring-based button scaling, OKLAB color interpolation,
-- cooldown completion pulses, stagger animations, ready pulse,
-- low resource warnings, damage flash, and toggle animations.
--
-- Usage:
--   local AnimHelpers = require('ui.animation_helpers')
--   AnimHelpers.init(ImAnim)
--   AnimHelpers.updateStaggerFrame()
--   local scale = AnimHelpers.getButtonScale(id, hovered, active)

local imgui = require('ImGui')

local M = {}

-- ============================================================
-- MODULE STATE
-- ============================================================

local _ImAnim = nil
local _lastCooldownState = {}
local _lastFrameTime = os.clock()
local _cachedDt = 0.016
local _cachedFrame = nil
local _staggerGrids = {}

-- State for new animation features
local _lowResourceThreshold = 0.20  -- 20%
local _lastHpValues = {}
local _damageFlashState = {}
local _toggleStates = {}

-- ============================================================
-- INITIALIZATION
-- ============================================================

function M.init(ImAnim)
    _ImAnim = ImAnim
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
    local targetScale = 1.0
    if isActive then
        targetScale = 0.95  -- Press down effect
    elseif isHovered then
        targetScale = 1.05  -- Hover enlarge effect
    end

    if _ImAnim and _ImAnim.spring then
        return _ImAnim.spring(uniqueId .. '_scale', targetScale, 400, 25)
    end
    return targetScale
end

-- ============================================================
-- COOLDOWN COMPLETION DETECTION
-- ============================================================

function M.checkCooldownCompletion(uniqueId, onCooldown)
    local wasOnCooldown = _lastCooldownState[uniqueId]
    if wasOnCooldown and not onCooldown then
        if _ImAnim and _ImAnim.trigger_shake then
            _ImAnim.trigger_shake(uniqueId .. '_pulse')
        end
    end
    _lastCooldownState[uniqueId] = onCooldown
end

function M.getCompletionPulse(uniqueId)
    if not _ImAnim or not _ImAnim.shake then return 0 end
    return _ImAnim.shake(uniqueId .. '_pulse', 3, 0.25, M.get_dt())
end

-- ============================================================
-- ENHANCED READY STATE GLOW (existing)
-- ============================================================

function M.getReadyGlow()
    local t = os.clock() * 2
    local wave = math.sin(t * math.pi)
    local elastic = 1.0 + 0.15 * math.pow(2, -10 * (t % 1)) * math.sin((t % 1) * 10 * math.pi / 3)
    return 0.4 + 0.4 * math.abs(wave) * elastic
end

-- ============================================================
-- READY PULSE ANIMATION (Task 5)
-- ============================================================

function M.getReadyPulseAlpha(uniqueId, isReady)
    if not isReady then return 1.0 end

    if _ImAnim and _ImAnim.oscillate then
        -- Gentle glow oscillation between 0.7 and 1.0 at 2Hz
        return _ImAnim.oscillate(uniqueId .. '_ready_pulse', 'sine', 0.7, 1.0, 2.0) or 1.0
    end
    -- Fallback without ImAnim
    local t = os.clock() * 2 * math.pi * 2.0
    return 0.7 + 0.15 * (1 + math.sin(t))
end

function M.getReadyGlowColor(uniqueId, isReady, baseColor)
    if not isReady then return baseColor end

    local pulse = M.getReadyPulseAlpha(uniqueId, true)
    -- Interpolate toward a brighter/golden color when ready
    local r = baseColor[1] + (1.0 - baseColor[1]) * (1.0 - pulse) * 0.3
    local g = baseColor[2] + (0.9 - baseColor[2]) * (1.0 - pulse) * 0.3
    local b = baseColor[3]
    local a = baseColor[4] or 1.0

    return {r, g, b, a}
end

-- ============================================================
-- LOW RESOURCE WARNING ANIMATION (Task 6)
-- ============================================================

function M.getLowResourcePulse(uniqueId, currentPct, threshold)
    threshold = threshold or _lowResourceThreshold
    if currentPct >= threshold then return 1.0, nil end

    -- Pulse faster as resource gets lower
    local urgency = 1.0 - (currentPct / threshold)
    local freq = 1.5 + urgency * 2.0  -- 1.5Hz to 3.5Hz

    if _ImAnim and _ImAnim.oscillate then
        local pulse = _ImAnim.oscillate(uniqueId .. '_low_res', 'sine', 0.5, 1.0, freq) or 1.0
        -- Return pulse value and warning color (red)
        return pulse, {1.0, 0.2, 0.2, pulse}
    end

    -- Fallback without ImAnim
    local t = os.clock() * 2 * math.pi * freq
    local pulse = 0.5 + 0.25 * (1 + math.sin(t))
    return pulse, {1.0, 0.2, 0.2, pulse}
end

function M.setLowResourceThreshold(threshold)
    _lowResourceThreshold = threshold or 0.20
end

-- ============================================================
-- DAMAGE FLASH DETECTION (Task 7)
-- ============================================================

function M.getDamageFlash(uniqueId, currentHp, flashDuration)
    flashDuration = flashDuration or 0.3
    local now = os.clock()

    local lastHp = _lastHpValues[uniqueId] or currentHp
    local flashState = _damageFlashState[uniqueId] or { active = false, startTime = 0 }

    -- Detect significant HP drop (>5%)
    local hpDrop = lastHp - currentHp
    if hpDrop > 5 then
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

    -- Return flash color overlay (red with fading alpha)
    if intensity > 0 then
        return {1.0, 0.0, 0.0, intensity * 0.5}
    end
    return nil
end

function M.resetDamageFlash(uniqueId)
    _lastHpValues[uniqueId] = nil
    _damageFlashState[uniqueId] = nil
end

-- ============================================================
-- TOGGLE BUTTON ANIMATIONS (Task 8)
-- ============================================================

function M.getToggleScale(uniqueId, isActive)
    local prevState = _toggleStates[uniqueId]
    local justActivated = isActive and not prevState
    _toggleStates[uniqueId] = isActive

    -- Trigger pop animation when toggled on
    if justActivated and _ImAnim and _ImAnim.trigger_shake then
        _ImAnim.trigger_shake(uniqueId .. '_toggle_pop')
    end

    -- Spring-based pop effect
    if _ImAnim and _ImAnim.spring then
        if justActivated then
            -- Temporarily target larger scale for pop
            return _ImAnim.spring(uniqueId .. '_toggle_scale', 1.15, 500, 20)
        end
        return _ImAnim.spring(uniqueId .. '_toggle_scale', 1.0, 300, 25)
    end
    return 1.0
end

function M.getToggleColor(uniqueId, isActive, onColor, offColor)
    if not _ImAnim or not _ImAnim.tween_vec4 then
        return isActive and onColor or offColor
    end

    local target = isActive and onColor or offColor
    local result = _ImAnim.tween_vec4(uniqueId .. '_toggle_color', target, 0.2, _ImAnim.EASE and _ImAnim.EASE.out_cubic or 5)
    return result or target
end

function M.getTogglePop(uniqueId)
    if not _ImAnim or not _ImAnim.shake then return 0 end
    return _ImAnim.shake(uniqueId .. '_toggle_pop', 2, 0.15, M.get_dt()) or 0
end

-- ============================================================
-- COLOR THRESHOLDS FOR COOLDOWN
-- ============================================================

local function getTargetColorForPct(pct)
    if pct > 0.66 then
        return 1.0, 0.4, 0.4  -- Red
    elseif pct > 0.33 then
        return 1.0, 0.7, 0.3  -- Orange
    elseif pct > 0.10 then
        return 1.0, 1.0, 0.4  -- Yellow
    else
        return 0.4, 1.0, 0.4  -- Green
    end
end

-- ============================================================
-- OKLAB COLOR INTERPOLATION FOR COOLDOWN BORDER
-- ============================================================

function M.getCooldownColor(uniqueId, pct)
    local targetR, targetG, targetB = getTargetColorForPct(pct)

    if _ImAnim and _ImAnim.tween_color then
        local dt = M.get_dt()
        local r, g, b = _ImAnim.tween_color(
            uniqueId .. '_cd', 'col',
            targetR, targetG, targetB, 1.0,
            0.15,  -- duration
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
    local offsets = { { -1, -1 }, { 0, -1 }, { 1, -1 }, { -1, 0 }, { 1, 0 }, { -1, 1 }, { 0, 1 }, { 1, 1 } }
    for _, off in ipairs(offsets) do
        imgui.SetCursorScreenPos(x + off[1], y + off[2])
        imgui.TextColored(0, 0, 0, 1, text)
    end
    imgui.SetCursorScreenPos(x, y)
    imgui.TextColored(r or 1, g or 1, b or 1, 1, text)
end

-- ============================================================
-- ENHANCED COOLDOWN OVERLAY
-- ============================================================

function M.drawCooldownOverlay(dl, minX, minY, maxX, maxY, rem, total, uniqueId, helpers, IM_COL32, dlAddRectFilled, dlAddRect)
    if not dl then return end

    rem = tonumber(rem) or 0
    total = tonumber(total) or 0
    local onCooldown = rem > 0 and total > 0

    -- Check for cooldown completion (triggers pulse)
    M.checkCooldownCompletion(uniqueId, onCooldown)

    -- Ready state: enhanced pulsing glow
    if not onCooldown then
        local pulse = M.getReadyGlow()
        local glowAlpha = math.floor(pulse * 80)
        local glowColor = IM_COL32(80, 200, 255, glowAlpha)
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
    dlAddRectFilled(dl, minX, minY, maxX, maxY, IM_COL32(0, 0, 0, 110), 0, 0)
    dlAddRectFilled(dl, minX, fillY, maxX, maxY, IM_COL32(r255, g255, b255, 140), 0, 0)
    dlAddRect(dl, minX, minY, maxX, maxY, IM_COL32(r255, g255, b255, 200), 0, 0, 2)

    -- Cooldown text with matching color
    if helpers and helpers.fmtCooldown then
        local txt = helpers.fmtCooldown(rem)
        M.drawOutlinedText(minX + 3, maxY - imgui.GetTextLineHeight() - 2, txt, r, g, b)
    end
end

-- ============================================================
-- STAGGER ANIMATION SUPPORT
-- ============================================================

function M.updateStaggerFrame()
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
    if not _ImAnim or not _ImAnim.stagger then return 1.0 end
    delay = delay or 0.05
    return _ImAnim.stagger(gridKey, idx, total, 0.5, delay)
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

return M
