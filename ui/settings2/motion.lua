-- ============================================================
-- SideKick Settings Redesign - Motion
-- ============================================================
-- Four (and only four) animation moments. Kept in one file so it's
-- obvious when someone tries to slip in a fifth.
--
--   1. chapterFade(id, targetAlpha)     -> content pane cross-fade on switch
--   2. chapterSlide(id, targetY)        -> content pane 6px slide-up on switch
--   3. pillBreathe(id)                  -> 0.7..1.0 alpha oscillation for live subsystems
--   4. togglePop(id)                    -> spring scale 1.0->1.15->1.0 imperatively triggered
--   5. revealStagger(gridId, idx, n)    -> per-row fade+offset when a conditional
--                                          section appears (grouped as one moment)
--
-- All IDs are strings. The imanim wrapper hashes them deterministically.

local imgui = require('ImGui')
local iam = require('sidekick-next.utils.imanim')

local M = {}

-- ------------------------------------------------------------
-- dt: cached per frame so multi-call sites share one value.
-- Mirrors ui/animation_helpers.lua get_dt(), simpler.
-- ------------------------------------------------------------

local _cachedFrame, _cachedDt, _lastClock = nil, 0.016, os.clock()

local function get_dt()
    local frame = (imgui.GetFrameCount and imgui.GetFrameCount()) or nil
    if frame ~= nil and frame == _cachedFrame then return _cachedDt end
    _cachedFrame = frame
    local dt
    local io = (imgui.GetIO and imgui.GetIO()) or nil
    if io and io.DeltaTime ~= nil then
        dt = tonumber(io.DeltaTime)
    end
    if not dt or dt <= 0 then
        local now = os.clock()
        dt = now - _lastClock
        _lastClock = now
    else
        _lastClock = os.clock()
    end
    _cachedDt = math.min(math.max(dt, 0), 0.1)
    return _cachedDt
end

-- ------------------------------------------------------------
-- Ease descriptors (cached; construction is not free)
-- ------------------------------------------------------------

local _ezOutCubic = iam.EasePreset(IamEaseType.OutCubic)

-- Spring for togglePop: fast + a little bouncy.
local _ezPop = (function()
    local ez = IamEaseDesc()
    ez.type = IamEaseType.Spring
    ez.p0 = 1.0     -- mass
    ez.p1 = 320     -- stiffness
    ez.p2 = 18      -- damping
    ez.p3 = 0.0
    return ez
end)()

-- Spring for stagger row: gentle.
local _ezRow = iam.EasePreset(IamEaseType.OutCubic)

-- ------------------------------------------------------------
-- 1 & 2. Chapter switch: fade + slide the content pane.
-- Time-based OutCubic - independent of imanim tween-rate semantics so it
-- behaves the same regardless of ImAnim build. 180ms window.
-- ------------------------------------------------------------

local _switchAt = -1e9  -- long ago, so first frame is already "settled"

function M.markChapterSwitched()
    _switchAt = os.clock()
end

--- Returns (alpha, offsetY). Starts at (0.0, 6.0) at t=0, eases to (1.0, 0.0)
-- over 180ms via OutCubic.
function M.chapterEnter()
    local elapsed = os.clock() - _switchAt
    if elapsed >= 0.18 then return 1.0, 0.0 end
    if elapsed <= 0 then return 0.0, 6.0 end
    local t = elapsed / 0.18
    local ease = 1 - (1 - t) ^ 3
    return ease, 6.0 * (1 - ease)
end

-- ------------------------------------------------------------
-- 3. Pill breathe: alpha oscillation for live subsystems.
-- ------------------------------------------------------------

--- Returns an alpha in [0.7, 1.0]. Feed into atoms.pill(text, variant, alpha).
-- Different pills get different IDs so they don't share phase.
function M.pillBreathe(idString)
    local dt = get_dt()
    -- Oscillate(id, amp, freq, wave, phase, dt) -> value in [-amp, +amp]
    local ok, wave = pcall(iam.Oscillate, 'sk2.pill.' .. tostring(idString),
        0.15, 0.9, IamWaveType.Sine, 0.0, dt)
    if not ok or type(wave) ~= 'number' then return 1.0 end
    return 0.85 + wave
end

-- ------------------------------------------------------------
-- 4. togglePop: spring scale, imperatively triggered.
-- ------------------------------------------------------------

-- Track the last-known state per toggle id, and the time it was last flipped.
local _lastToggleState = {}
local _popStart = {}

--- Detect toggle flips and stamp a pop start-time. Call once per frame per
-- toggle you care about (from the rail, since the rail is what pops).
function M.observeToggle(idString, isOn)
    local prev = _lastToggleState[idString]
    if prev ~= nil and prev ~= isOn then
        _popStart[idString] = os.clock()
    end
    _lastToggleState[idString] = isOn
end

--- Return current scale factor in [1.0, 1.15]. Auto-decays back to 1.0
-- after ~350ms.
function M.popScale(idString)
    local startedAt = _popStart[idString]
    if not startedAt then return 1.0 end
    local elapsed = os.clock() - startedAt
    if elapsed > 0.35 then
        _popStart[idString] = nil
        return 1.0
    end
    -- Piecewise: 0..80ms scale up to 1.15, 80..350ms spring back to 1.0.
    if elapsed < 0.08 then
        local t = elapsed / 0.08
        return 1.0 + 0.15 * t
    else
        local t = (elapsed - 0.08) / 0.27
        -- Overshoot spring: cos decay
        local amp = 0.15 * (1.0 - t)
        return 1.0 + amp * math.cos(t * math.pi * 1.6)
    end
end

-- ------------------------------------------------------------
-- 5. revealStagger: per-row fade + 4px slide when a conditional
-- section appears (e.g. Tank Settings after switching to Tank mode).
-- ------------------------------------------------------------

-- Grid appearance timestamps.
local _gridAppearedAt = {}

--- Call once per frame per section with (id, isVisible). Timestamps the
-- transition to visible so subsequent per-row calls can compute their delay.
function M.observeReveal(gridId, isVisible)
    if isVisible then
        if not _gridAppearedAt[gridId] then
            _gridAppearedAt[gridId] = os.clock()
        end
    else
        _gridAppearedAt[gridId] = nil
    end
end

--- Return (alpha, offsetY) for row `idx` (1-indexed) of gridId. Rows stagger
-- 40ms apart, each doing a 220ms OutCubic in.
function M.revealRow(gridId, idx)
    local startedAt = _gridAppearedAt[gridId]
    if not startedAt then return 1.0, 0.0 end
    local delay = (idx - 1) * 0.04
    local elapsed = os.clock() - startedAt - delay
    if elapsed <= 0 then return 0.0, 4.0 end
    if elapsed >= 0.22 then return 1.0, 0.0 end
    -- OutCubic
    local t = elapsed / 0.22
    local ease = 1 - (1 - t) ^ 3
    return ease, 4.0 * (1 - ease)
end

return M
