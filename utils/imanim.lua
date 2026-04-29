-- Wraps require('ImAnim') to fix legacy-API issues in the sidekick-next Lua
-- layer. Use this instead of `require('ImAnim')` directly.
--
-- Problems addressed:
--   1. Native ImAnim expects ImGuiID (uint32). Scripts pass strings — we hash
--      via ImHashStr (deterministic, context-free) and cache results. We do
--      NOT use ImGui.GetID because it folds in the current ID stack, which
--      produces different IDs for the same string in different windows.
--   2. The legacy ImAnim API had a phantom `channel` arg on Oscillate / Wiggle /
--      SmoothNoiseFloat. We strip it when the caller's arg count exceeds native
--      arity.
--   3. The legacy Oscillate form also had `phase` BEFORE `wave_type` — opposite
--      of native order. The wrapper detects the 6-arg legacy form and swaps
--      them back to native order so existing callers still produce correct
--      Sawtooth/Triangle/Square waves (was silently producing Sine).
--
-- Native arities (args after id):
--   Oscillate        → 5 (amp, freq, wave_type, phase, dt)
--   Shake            → 4 (intensity, freq, decay, dt)
--   Wiggle           → 3 (amp, freq, dt)
--   SmoothNoiseFloat → 3 (amp, speed, dt)
--
-- Note: native Shake has the SAME arity as legacy `(axis, mag, decay, dt)`,
-- so the wrapper cannot disambiguate by count. Shake callers must use the
-- native shape `(id, intensity, freq, decay, dt)`.

local real  = require('ImAnim')

local _hashFunc = _G.ImHashStr
local _idCache = {}

local function toID(v)
    if type(v) == 'number' then return v end
    local s = tostring(v)
    local cached = _idCache[s]
    if cached then return cached end
    local h
    if _hashFunc then
        h = _hashFunc(s)
    else
        h = 2166136261
        for i = 1, #s do
            h = bit32.bxor(h, s:byte(i))
            h = bit32.band(h * 16777619, 0xFFFFFFFF)
        end
    end
    _idCache[s] = h
    return h
end

local function stripChannel(expected, ...)
    if select('#', ...) > expected then
        return select(2, ...)
    end
    return ...
end

local M = setmetatable({}, { __index = real })

-- Channel-aware (first two args are IDs):
M.TweenFloat = function(id, ch, ...) return real.TweenFloat(toID(id), toID(ch), ...) end
M.TweenInt   = function(id, ch, ...) return real.TweenInt(toID(id),   toID(ch), ...) end
M.TweenVec2  = function(id, ch, ...) return real.TweenVec2(toID(id),  toID(ch), ...) end
M.TweenVec4  = function(id, ch, ...) return real.TweenVec4(toID(id),  toID(ch), ...) end
M.TweenColor = function(id, ch, ...) return real.TweenColor(toID(id), toID(ch), ...) end

-- Single-ID:
M.TriggerShake = function(id) return real.TriggerShake(toID(id)) end

-- Oscillate: handle legacy 6-arg form (channel + phase-before-wave swap).
M.Oscillate = function(id, ...)
    local n = select('#', ...)
    if n == 6 then
        local _ch, amp, freq, phase, wave, dt = ...
        return real.Oscillate(toID(id), amp, freq, wave, phase, dt)
    end
    return real.Oscillate(toID(id), ...)
end

M.Wiggle            = function(id, ...) return real.Wiggle(toID(id),            stripChannel(3, ...)) end
M.SmoothNoiseFloat  = function(id, ...) return real.SmoothNoiseFloat(toID(id),  stripChannel(3, ...)) end
M.NoiseChannelFloat = function(id, ...) return real.NoiseChannelFloat(toID(id), ...) end

-- Path tween: id, channel, path_id are all ImGuiIDs
M.TweenPath  = function(id, ch, pid, ...) return real.TweenPath(toID(id), toID(ch), toID(pid), ...) end
M.TweenPathAngle = function(id, ch, pid, ...) return real.TweenPathAngle(toID(id), toID(ch), toID(pid), ...) end
M.PathBuildArcLut = function(pid, ...) return real.PathBuildArcLut(toID(pid), ...) end

-- Stagger: clip_id and instance_id are ImGuiIDs; native PlayStagger only takes
-- (clip_id, instance_id, index) — extra trailing args are ignored.
M.PlayStagger  = function(clipId, instId, index) return real.PlayStagger(toID(clipId), toID(instId), index) end
M.StaggerDelay = function(clipId, index) return real.StaggerDelay(toID(clipId), index) end
M.GetInstance  = function(id) return real.GetInstance(toID(id)) end
M.Play         = function(clipId, instId) return real.Play(toID(clipId), toID(instId)) end

-- Text stagger
M.TextStagger         = function(id, ...) return real.TextStagger(toID(id), ...) end
M.TextStaggerWidth    = function(...) return real.TextStaggerWidth(...) end
M.TextStaggerDuration = function(...) return real.TextStaggerDuration(...) end

-- Shake: native arity == legacy arity, cannot disambiguate. Callers must use
-- native shape (id, intensity, freq, decay, dt).
M.Shake = function(id, ...) return real.Shake(toID(id), ...) end

return M
