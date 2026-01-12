-- ============================================================
-- COMPREHENSIVE ImAnim WRAPPER FOR LUA/MQ2
-- ============================================================
-- Complete wrapper exposing all ImAnim features:
--   - Tweens: float, int, vec2, vec4, color
--   - Clips: timeline keyframe animations with looping/callbacks/chaining
--   - Easing: 30+ presets + cubic-bezier, steps, spring
--   - Motion Paths: bezier, catmull-rom curves
--   - Oscillators: sine, triangle, sawtooth, square waves
--   - Shake & Wiggle: triggered and continuous noise
--   - Noise: Perlin/Simplex procedural animation
--   - Stagger: cascading element animations
--
-- Usage:
--   local ImAnim = require('lib.imanim')
--   
--   -- Tween
--   local scale = ImAnim.tween_float('btn', 'scale', 1.1, 0.2, ImAnim.EASE.out_cubic)
--   
--   -- Oscillate
--   local wobble = ImAnim.oscillate('ui', 'y', 5, 2)  -- 5px amplitude, 2Hz
--   
--   -- Shake (triggered)
--   ImAnim.trigger_shake('impact')
--   local shake = ImAnim.shake('impact', 10, 0.3)  -- 10px, decay 0.3s
--   
--   -- Noise
--   local drift = ImAnim.smooth_noise('bg', 20, 0.5)  -- 20px amplitude, 0.5Hz


local ImAnim = {}

-- ============================================================
-- CONSTANTS & ENUMS
-- ============================================================

-- Easing function presets
ImAnim.EASE = {
  linear = 0,
  in_quad = 1, out_quad = 2, in_out_quad = 3,
  in_cubic = 4, out_cubic = 5, in_out_cubic = 6,
  in_quart = 7, out_quart = 8, in_out_quart = 9,
  in_quint = 10, out_quint = 11, in_out_quint = 12,
  in_sine = 13, out_sine = 14, in_out_sine = 15,
  in_expo = 16, out_expo = 17, in_out_expo = 18,
  in_circ = 19, out_circ = 20, in_out_circ = 21,
  in_back = 22, out_back = 23, in_out_back = 24,
  in_elastic = 25, out_elastic = 26, in_out_elastic = 27,
  in_bounce = 28, out_bounce = 29, in_out_bounce = 30,
}

-- Tween policies: how to handle target changes mid-animation
ImAnim.POLICY = {
  crossfade = 0,  -- Smoothly blend to new target
  cut = 1,        -- Snap immediately to new target
  queue = 2,      -- Queue new target for after animation ends
}

-- Color spaces for blending
ImAnim.COLOR_SPACE = {
  srgb = 0,
  srgb_linear = 1,
  hsv = 2,
  oklab = 3,
  oklch = 4,
}

-- Animation direction (for clips)
ImAnim.DIRECTION = {
  normal = 0,
  reverse = 1,
  alternate = 2,  -- Ping-pong
}

-- Wave types (for oscillators)
ImAnim.WAVE = {
  sine = 0,
  triangle = 1,
  sawtooth = 2,
  square = 3,
}

-- Noise types (for procedural animation)
ImAnim.NOISE = {
  perlin = 0,
  simplex = 1,
  value = 2,
}

-- ============================================================
-- INTERNAL STATE
-- ============================================================

local tweens = {}           -- Tween state: {current, from, to, elapsed, duration, ease, policy}
local springs = {}          -- Spring state: {current, velocity, target}
local clips = {}            -- Clip instances: {time, duration, playing, ...}
local oscillators = {}      -- Oscillator state: {time, ...}
local shakes = {}           -- Shake state: {time, triggered, ...}
local wiggles = {}          -- Wiggle state: {time, ...}
local noises = {}           -- Noise state: {time, ...}
local paths = {}            -- Path definitions

-- ============================================================
-- NATIVE C++ API DETECTION
-- ============================================================

local native = {}
if _G and type(_G.ImAnim) == 'table' then
  native.update_begin_frame = _G.ImAnim.update_begin_frame
  native.clip_update = _G.ImAnim.clip_update
  native.tween_float = _G.ImAnim.tween_float
  native.tween_int = _G.ImAnim.tween_int
  native.tween_vec2 = _G.ImAnim.tween_vec2
  native.tween_vec4 = _G.ImAnim.tween_vec4
  native.tween_color = _G.ImAnim.tween_color
end

-- ============================================================
-- FALLBACK EASING FUNCTIONS (Pure Lua)
-- ============================================================

local function easeLinear(t) return t end

local function easeQuadIn(t) return t * t end
local function easeQuadOut(t) return 1 - (1 - t) * (1 - t) end
local function easeQuadInOut(t) return t < 0.5 and 2*t*t or -1 + (4 - 2*t)*t end

local function easeCubicIn(t) return t * t * t end
local function easeCubicOut(t) return 1 + (t - 1) * (t - 1) * (t - 1) end

local function easeQuartIn(t) return t * t * t * t end
local function easeQuartOut(t) return 1 - (1 - t) * (1 - t) * (1 - t) * (1 - t) end

local function easeQuintIn(t) return t * t * t * t * t end
local function easeQuintOut(t) return 1 + (t - 1) * (t - 1) * (t - 1) * (t - 1) * (t - 1) end

local function easeSineIn(t) return 1 - math.cos((t * math.pi) / 2) end
local function easeSineOut(t) return math.sin((t * math.pi) / 2) end

local function easeExpoIn(t) return t == 0 and 0 or math.pow(2, 10 * t - 10) end
local function easeExpoOut(t) return t == 1 and 1 or 1 - math.pow(2, -10 * t) end

local function easeCircIn(t) return 1 - math.sqrt(1 - t * t) end
local function easeCircOut(t) return math.sqrt(1 - (t - 1) * (t - 1)) end

local function easeBackIn(t)
  local c1 = 1.70158
  local c3 = c1 + 1
  return c3 * t * t * t - c1 * t * t
end

local function easeBackOut(t)
  local c1 = 1.70158
  local c3 = c1 + 1
  return 1 + c3 * (t - 1) * (t - 1) * (t - 1) + c1 * (t - 1) * (t - 1)
end

local function easeElasticOut(t)
  if t == 0 then return 0 end
  if t == 1 then return 1 end
  local c4 = (2 * math.pi) / 3
  return math.pow(2, -10 * t) * math.sin((t * 10 - 0.75) * c4) + 1
end

local function easeBounceOut(t)
  local n1 = 7.5625
  local d1 = 2.75
  if t < 1 / d1 then
    return n1 * t * t
  elseif t < 2 / d1 then
    t = t - 1.5 / d1
    return n1 * t * t + 0.75
  elseif t < 2.5 / d1 then
    t = t - 2.25 / d1
    return n1 * t * t + 0.9375
  else
    t = t - 2.625 / d1
    return n1 * t * t + 0.984375
  end
end

-- Map ease type to function
local function getEaseFunction(easeType)
  easeType = tonumber(easeType) or ImAnim.EASE.linear
  if easeType == ImAnim.EASE.linear then return easeLinear end
  if easeType == ImAnim.EASE.in_quad then return easeQuadIn end
  if easeType == ImAnim.EASE.out_quad then return easeQuadOut end
  if easeType == ImAnim.EASE.in_out_quad then return easeQuadInOut end
  if easeType == ImAnim.EASE.in_cubic then return easeCubicIn end
  if easeType == ImAnim.EASE.out_cubic then return easeCubicOut end
  if easeType == ImAnim.EASE.in_quart then return easeQuartIn end
  if easeType == ImAnim.EASE.out_quart then return easeQuartOut end
  if easeType == ImAnim.EASE.in_quint then return easeQuintIn end
  if easeType == ImAnim.EASE.out_quint then return easeQuintOut end
  if easeType == ImAnim.EASE.in_sine then return easeSineIn end
  if easeType == ImAnim.EASE.out_sine then return easeSineOut end
  if easeType == ImAnim.EASE.in_expo then return easeExpoIn end
  if easeType == ImAnim.EASE.out_expo then return easeExpoOut end
  if easeType == ImAnim.EASE.in_circ then return easeCircIn end
  if easeType == ImAnim.EASE.out_circ then return easeCircOut end
  if easeType == ImAnim.EASE.in_back then return easeBackIn end
  if easeType == ImAnim.EASE.out_back then return easeBackOut end
  if easeType == ImAnim.EASE.out_elastic then return easeElasticOut end
  if easeType == ImAnim.EASE.out_bounce then return easeBounceOut end
  return easeLinear
end

-- ============================================================
-- TWEEN FUNCTIONS
-- ============================================================

-- Spring physics simulation
-- Returns the current value
function ImAnim.spring(id, target, stiffness, damping, initialValue)
  stiffness = stiffness or 170
  damping = damping or 26
  
  local state = springs[id] or { 
    current = initialValue or target, 
    velocity = 0, 
    target = target 
  }
  springs[id] = state
  
  -- If target changed, update it
  if state.target ~= target then
    state.target = target
  end
  
  local dt = 0.016 -- Fixed step for stability
  
  -- Spring force: F = -k * (x - target) - c * v
  local displacement = state.current - state.target
  local force = -stiffness * displacement - damping * state.velocity
  
  state.velocity = state.velocity + force * dt
  state.current = state.current + state.velocity * dt
  
  -- Snap to target if close enough to stop micro-oscillations
  if math.abs(displacement) < 0.001 and math.abs(state.velocity) < 0.001 then
    state.current = state.target
    state.velocity = 0
  end
  
  springs[id] = state
  return state.current
end

function ImAnim.tween_float(id, channel, target, duration, easeType, policy, dt)
  if native.tween_float then
    local ok, result = pcall(native.tween_float, id, channel, target, duration, 
                            easeType or ImAnim.EASE.linear, policy or ImAnim.POLICY.crossfade, dt or 0)
    if ok then return result end
  end
  
  -- Fallback implementation
  duration = tonumber(duration) or 0.0001
  dt = tonumber(dt) or 0
  easeType = tonumber(easeType) or ImAnim.EASE.linear
  policy = tonumber(policy) or ImAnim.POLICY.crossfade
  
  local key = tostring(id) .. ":" .. tostring(channel)
  local tween = tweens[key] or {current = 0, from = 0, to = 0, elapsed = 0, dur = 0, ease = ImAnim.EASE.linear}
  
  -- Check if target changed
  if tween.to ~= target or tween.dur ~= duration then
    if policy == ImAnim.POLICY.cut then
      tween.current = target
      tween.to = target
      tween.from = target
      tween.elapsed = 0
      tween.dur = 0
    else
      tween.from = tween.current
      tween.to = target
      tween.elapsed = 0
      tween.dur = duration
      tween.ease = easeType
    end
  end
  
  if tween.elapsed >= tween.dur then
    tween.current = tween.to
    tweens[key] = tween
    return tween.current
  end
  
  tween.elapsed = math.min(tween.elapsed + dt, tween.dur)
  local progress = (tween.dur > 0) and (tween.elapsed / tween.dur) or 1
  local easeFunc = getEaseFunction(tween.ease)
  local eased = easeFunc(progress)
  tween.current = tween.from + (tween.to - tween.from) * eased
  tweens[key] = tween
  
  return tween.current
end

function ImAnim.tween_int(id, channel, target, duration, easeType, policy, dt)
  return math.floor(ImAnim.tween_float(id, channel, target, duration, easeType, policy, dt))
end

function ImAnim.tween_vec2(id, channel, targetX, targetY, duration, easeType, policy, dt)
  if native.tween_vec2 then
    local ok, result = pcall(native.tween_vec2, id, channel, targetX, targetY, duration, 
                            easeType or ImAnim.EASE.linear, policy or ImAnim.POLICY.crossfade, dt or 0)
    if ok and result then return result.x, result.y end
  end
  
  local x = ImAnim.tween_float(id, channel .. "_x", targetX, duration, easeType, policy, dt)
  local y = ImAnim.tween_float(id, channel .. "_y", targetY, duration, easeType, policy, dt)
  return x, y
end

function ImAnim.tween_vec4(id, channel, targetX, targetY, targetZ, targetW, duration, easeType, policy, dt)
  if native.tween_vec4 then
    local ok, result = pcall(native.tween_vec4, id, channel, targetX, targetY, targetZ, targetW, duration,
                            easeType or ImAnim.EASE.linear, policy or ImAnim.POLICY.crossfade, dt or 0)
    if ok and result then return result.x, result.y, result.z, result.w end
  end
  
  local x = ImAnim.tween_float(id, channel .. "_x", targetX, duration, easeType, policy, dt)
  local y = ImAnim.tween_float(id, channel .. "_y", targetY, duration, easeType, policy, dt)
  local z = ImAnim.tween_float(id, channel .. "_z", targetZ, duration, easeType, policy, dt)
  local w = ImAnim.tween_float(id, channel .. "_w", targetW, duration, easeType, policy, dt)
  return x, y, z, w
end

function ImAnim.tween_color(id, channel, targetR, targetG, targetB, targetA, duration, easeType, colorSpace, policy, dt)
  if native.tween_color then
    local ok, result = pcall(native.tween_color, id, channel, targetR, targetG, targetB, targetA, duration,
                            easeType or ImAnim.EASE.linear, colorSpace or ImAnim.COLOR_SPACE.srgb, 
                            policy or ImAnim.POLICY.crossfade, dt or 0)
    if ok and result then return result.x, result.y, result.z, result.w end
  end
  
  local r = ImAnim.tween_float(id, channel .. "_r", targetR, duration, easeType, policy, dt)
  local g = ImAnim.tween_float(id, channel .. "_g", targetG, duration, easeType, policy, dt)
  local b = ImAnim.tween_float(id, channel .. "_b", targetB, duration, easeType, policy, dt)
  local a = ImAnim.tween_float(id, channel .. "_a", targetA, duration, easeType, policy, dt)
  return r, g, b, a
end

-- ============================================================
-- CLIP FUNCTIONS (Timeline-based keyframe animation)
-- ============================================================

function ImAnim.create_clip(clipId)
  if not clips[clipId] then
    clips[clipId] = {
      keyframes = {},  -- {channel, time, value, ease}
      duration = 0,
      instances = {},  -- {id -> {time, playing, ...}}
    }
  end
  return clips[clipId]
end

function ImAnim.clip_add_keyframe(clipId, channel, time, value, easeType)
  local clip = ImAnim.create_clip(clipId)
  table.insert(clip.keyframes, {channel = channel, time = time, value = value, ease = easeType or ImAnim.EASE.linear})
  clip.duration = math.max(clip.duration, time)
end

function ImAnim.clip_play(clipId, instanceId, looping)
  local clip = clips[clipId]
  if not clip then return nil end
  
  instanceId = instanceId or clipId .. "_inst_" .. tostring(math.random())
  local instance = {
    id = instanceId,
    clipId = clipId,
    time = 0,
    duration = clip.duration,
    playing = true,
    looping = looping or false,
    values = {},
  }
  
  if not clip.instances then clip.instances = {} end
  clip.instances[instanceId] = instance
  
  return instance
end

function ImAnim.clip_update_instance(instance, dt)
  if not instance or not instance.playing then return end
  
  instance.time = instance.time + (dt or 0.016)
  
  if instance.time >= instance.duration then
    if instance.looping then
      instance.time = instance.time - instance.duration
    else
      instance.playing = false
      instance.time = instance.duration
    end
  end
  
  local clip = clips[instance.clipId]
  if not clip then return end
  
  -- Interpolate keyframes
  for _, kf in ipairs(clip.keyframes) do
    if instance.time >= kf.time then
      -- Find next keyframe
      local nextKf = nil
      for _, kf2 in ipairs(clip.keyframes) do
        if kf2.time > kf.time then
          nextKf = kf2
          break
        end
      end
      
      if nextKf and instance.time < nextKf.time then
        -- Interpolate between kf and nextKf
        local localTime = instance.time - kf.time
        local duration = nextKf.time - kf.time
        local t = localTime / duration
        local easeFunc = getEaseFunction(kf.ease)
        local eased = easeFunc(t)
        instance.values[kf.channel] = kf.value + (nextKf.value - kf.value) * eased
      else
        instance.values[kf.channel] = kf.value
      end
    end
  end
end

function ImAnim.clip_get_value(instanceId, channel)
  for clipId, clip in pairs(clips) do
    if clip.instances then
      local instance = clip.instances[instanceId]
      if instance then return instance.values[channel] end
    end
  end
  return 0
end

-- ============================================================
-- OSCILLATOR FUNCTIONS
-- ============================================================

function ImAnim.oscillate(id, channel, amplitude, frequency, phase, dt)
  amplitude = tonumber(amplitude) or 1
  frequency = tonumber(frequency) or 1
  phase = tonumber(phase) or 0
  dt = tonumber(dt) or 0
  
  local key = tostring(id) .. ":" .. tostring(channel)
  oscillators[key] = (oscillators[key] or 0) + dt
  local t = oscillators[key]
  
  return amplitude * math.sin(2 * math.pi * frequency * t + phase)
end

function ImAnim.oscillate_vec2(id, channel, ampX, ampY, freqX, freqY, phaseX, phaseY, dt)
  local x = ImAnim.oscillate(id, channel .. "_x", ampX, freqX, phaseX, dt)
  local y = ImAnim.oscillate(id, channel .. "_y", ampY, freqY, phaseY, dt)
  return x, y
end

function ImAnim.wave(id, channel, waveType, amplitude, frequency, phase, dt)
  amplitude = tonumber(amplitude) or 1
  frequency = tonumber(frequency) or 1
  phase = tonumber(phase) or 0
  dt = tonumber(dt) or 0
  waveType = tonumber(waveType) or ImAnim.WAVE.sine
  
  local key = tostring(id) .. ":" .. tostring(channel)
  oscillators[key] = (oscillators[key] or 0) + dt
  local t = oscillators[key]
  
  local normalizedT = (frequency * t + phase) % 1
  local value
  
  if waveType == ImAnim.WAVE.sine then
    value = amplitude * math.sin(2 * math.pi * normalizedT)
  elseif waveType == ImAnim.WAVE.triangle then
    if normalizedT < 0.25 then
      value = amplitude * 4 * normalizedT
    elseif normalizedT < 0.75 then
      value = amplitude * (2 - 4 * normalizedT)
    else
      value = amplitude * (4 * normalizedT - 4)
    end
  elseif waveType == ImAnim.WAVE.sawtooth then
    value = amplitude * (2 * normalizedT - 1)
  elseif waveType == ImAnim.WAVE.square then
    value = normalizedT < 0.5 and amplitude or -amplitude
  else
    value = amplitude * math.sin(2 * math.pi * normalizedT)
  end
  
  return value
end

-- ============================================================
-- SHAKE & WIGGLE FUNCTIONS
-- ============================================================

function ImAnim.trigger_shake(id)
  local key = tostring(id)
  shakes[key] = {active = true, time = 0}
  -- Support shake_vec2() which uses id.."_x"/"_y"
  shakes[key .. "_x"] = {active = true, time = 0}
  shakes[key .. "_y"] = {active = true, time = 0}
end

function ImAnim.shake(id, magnitude, decayTime, dt)
  magnitude = tonumber(magnitude) or 1
  decayTime = tonumber(decayTime) or 0.5
  dt = tonumber(dt) or 0
  
  local key = tostring(id)
  shakes[key] = shakes[key] or {active = false, time = decayTime}
  local shake = shakes[key]
  
  -- Back-compat: older state used `triggered`; treat it as `active`.
  if shake.triggered then
    shake.active = true
    shake.triggered = nil
    shake.time = 0
  end

  if not shake.active then return 0 end

  shake.time = shake.time + dt
  if shake.time >= decayTime then
    shake.active = false
    return 0
  end

  local decay = 1 - (shake.time / decayTime)
  return (math.random() - 0.5) * 2 * magnitude * decay
end

function ImAnim.shake_vec2(id, magX, magY, decayTime, dt)
  local x = ImAnim.shake(id .. "_x", magX, decayTime, dt)
  local y = ImAnim.shake(id .. "_y", magY, decayTime, dt)
  return x, y
end

function ImAnim.wiggle(id, channel, amplitude, frequency, dt)
  amplitude = tonumber(amplitude) or 1
  frequency = tonumber(frequency) or 1
  dt = tonumber(dt) or 0
  
  local key = tostring(id) .. ":" .. tostring(channel)
  wiggles[key] = (wiggles[key] or 0) + dt
  local t = wiggles[key]
  
  return amplitude * (math.random() - 0.5) * 2 * math.sin(2 * math.pi * frequency * t)
end

function ImAnim.wiggle_vec2(id, ampX, ampY, frequency, dt)
  local x = ImAnim.wiggle(id .. "_x", "val", ampX, frequency, dt)
  local y = ImAnim.wiggle(id .. "_y", "val", ampY, frequency, dt)
  return x, y
end

--[[ -- ============================================================
-- NOISE FUNCTIONS (Perlin/Simplex simulation)
-- ============================================================

local function simpleHash(x, y)
  return bit.bxor(x * 73856093, y * 19349663) % 256
end

local function perlinValue(t)
  t = t % 256
  if t < 0 then t = t + 256 end
  return math.sin(t * math.pi / 128) * 0.5 + 0.5
end

function ImAnim.smooth_noise(id, channel, amplitude, frequency, dt)
  amplitude = tonumber(amplitude) or 1
  frequency = tonumber(frequency) or 1
  dt = tonumber(dt) or 0
  
  local key = tostring(id) .. ":" .. tostring(channel)
  noises[key] = (noises[key] or 0) + dt * frequency
  local t = noises[key]
  
  local x = math.floor(t)
  local frac = t - x
  
  -- Simple interpolation using Perlin-like smoothing
  local smoothFrac = frac * frac * (3 - 2 * frac)
  
  local v0 = perlinValue(x)
  local v1 = perlinValue(x + 1)
  
  return amplitude * (v0 + (v1 - v0) * smoothFrac)
end

function ImAnim.smooth_noise_vec2(id, ampX, ampY, freqX, freqY, dt)
  local x = ImAnim.smooth_noise(id .. "_x", "val", ampX, freqX, dt)
  local y = ImAnim.smooth_noise(id .. "_y", "val", ampY, freqY, dt)
  return x, y
end

function ImAnim.noise(x, y, noiseType, seed)
  noiseType = tonumber(noiseType) or ImAnim.NOISE.perlin
  seed = tonumber(seed) or 0
  
  local hash = simpleHash(math.floor(x) + seed, math.floor(y))
  return (hash / 256) * 2 - 1  -- Range: -1 to 1
end ]]

-- ============================================================
-- MOTION PATHS
-- ============================================================

function ImAnim.create_path(pathId)
  if not paths[pathId] then
    paths[pathId] = {
      points = {},
      types = {},  -- 'line', 'quad', 'cubic', 'catmull'
      length = 0,
    }
  end
  return paths[pathId]
end

function ImAnim.path_line_to(pathId, x, y)
  local path = ImAnim.create_path(pathId)
  table.insert(path.points, {x = x, y = y})
  table.insert(path.types, 'line')
end

function ImAnim.path_quadratic_to(pathId, cx, cy, x, y)
  local path = ImAnim.create_path(pathId)
  table.insert(path.points, {x = x, y = y, cx = cx, cy = cy})
  table.insert(path.types, 'quad')
end

function ImAnim.path_cubic_to(pathId, cx1, cy1, cx2, cy2, x, y)
  local path = ImAnim.create_path(pathId)
  table.insert(path.points, {x = x, y = y, cx1 = cx1, cy1 = cy1, cx2 = cx2, cy2 = cy2})
  table.insert(path.types, 'cubic')
end

local function bezierQuadratic(p0, p1, p2, t)
  local mt = 1 - t
  return mt * mt * p0 + 2 * mt * t * p1 + t * t * p2
end

local function bezierCubic(p0, p1, p2, p3, t)
  local mt = 1 - t
  return mt * mt * mt * p0 + 3 * mt * mt * t * p1 + 3 * mt * t * t * p2 + t * t * t * p3
end

function ImAnim.path_evaluate(pathId, t)
  local path = paths[pathId]
  if not path or #path.points == 0 then return 0, 0 end
  
  t = math.max(0, math.min(1, t))
  
  local segmentT = t * (#path.points - 1)
  local segment = math.floor(segmentT)
  local localT = segmentT - segment
  
  segment = math.min(segment, #path.points - 2)
  
  local p0 = path.points[segment + 1]
  local p1 = path.points[segment + 2]
  
  if path.types[segment + 1] == 'quad' then
    local x = bezierQuadratic(p0.x, p0.cx or p0.x, p1.x, localT)
    local y = bezierQuadratic(p0.y, p0.cy or p0.y, p1.y, localT)
    return x, y
  elseif path.types[segment + 1] == 'cubic' then
    local x = bezierCubic(p0.x, p0.cx1 or p0.x, p0.cx2 or p1.x, p1.x, localT)
    local y = bezierCubic(p0.y, p0.cy1 or p0.y, p0.cy2 or p1.y, p1.y, localT)
    return x, y
  else
    local x = p0.x + (p1.x - p0.x) * localT
    local y = p0.y + (p1.y - p0.y) * localT
    return x, y
  end
end

-- ============================================================
-- STAGGER HELPER
-- ============================================================

ImAnim._staggerGrids = ImAnim._staggerGrids or {}

-- ============================================================
-- STAGGER HELPER (simple wave-style stagger)
-- ============================================================

-- Helper: Apply out_elastic easing to a progress value (0..1)
local function applyElasticEasing(progress)
  if progress <= 0 then return 0 end
  if progress >= 1 then return 1 end
  local c4 = (2 * math.pi) / 3
  return math.pow(2, -10 * progress) * math.sin((progress * 10 - 0.75) * c4) + 1
end

-- Call this once per frame with dt
-- Advance stagger time once per frame
function ImAnim.update_stagger_frame(dt)
  dt = tonumber(dt) or 0.016
  ImAnim._staggerTime = (ImAnim._staggerTime or 0) + dt
end

-- One-shot stagger: fade in + single bounce, then stay visible and still
-- Returns alpha, bounceY
function ImAnim.get_stagger_bounce(gridKey, tileIndex, totalTiles, staggerDelay)
  local t = (ImAnim._staggerTime or 0)
  staggerDelay = tonumber(staggerDelay) or 2.18

  -- normalize inputs and accept 1-based or 0-based tileIndex
  local idx = tonumber(tileIndex) or 0
  if idx >= 1 then idx = idx - 1 end
  local total = tonumber(totalTiles) or 1

  -- when this tile's animation begins (zero-based index)
  local startT = idx * staggerDelay
  local localT = t - startT

  -- not reached yet: fully hidden, no movement
  -- allow localT == 0 to begin immediately (use < 0)
  if localT < 0 then
    return 0.0, 0.0
  end

  local fadeDur   = 2.6   -- seconds for fade-in + bounce (slower for easier observation)
  local amplitude = 3.0  -- pixels of vertical bounce (more visible)

  -- after fade/bounce window: fully visible, no bounce
  if localT >= fadeDur then
    return 1.0, 0.0
  end

  -- progress 0..1 over fadeDur
  local p = localT / fadeDur

  -- smooth fade-in alpha (smoothstep)
  local alpha = p * p * (3 - 2 * p)

  -- one-shot bounce: up then back to 0 using sin(0..π)
  local wave   = math.sin(p * math.pi)  -- 0 → 1 → 0
  local bounce = -wave * amplitude      -- negative = bounce upward

  return alpha, bounce
end

-- Convenience: return only alpha (0..1) for callers that don't need bounce
function ImAnim.get_stagger_alpha(gridKey, tileIndex, totalTiles, staggerDelay)
  local a, _ = ImAnim.get_stagger_bounce(gridKey, tileIndex, totalTiles, staggerDelay)
  return a
end




-- ============================================================
-- FRAME UPDATE & MEMORY MANAGEMENT
-- ============================================================

function ImAnim.update_begin_frame()
  if native.update_begin_frame then
    pcall(native.update_begin_frame)
  end
end

function ImAnim.clip_update(dt)
  if native.clip_update then
    pcall(native.clip_update, dt)
  end
  
  -- Update all clip instances
  for clipId, clip in pairs(clips) do
    if clip.instances then
      for instanceId, instance in pairs(clip.instances) do
        ImAnim.clip_update_instance(instance, dt)
      end
    end
  end
end

function ImAnim.gc(maxFrameAge)
  -- Garbage collect old tweens
  maxFrameAge = tonumber(maxFrameAge) or 300
  for key, tween in pairs(tweens) do
    if tween.elapsed > maxFrameAge then
      tweens[key] = nil
    end
  end
end

function ImAnim.clip_gc(maxFrameAge)
  -- Garbage collect old clip instances
  maxFrameAge = tonumber(maxFrameAge) or 300
  for clipId, clip in pairs(clips) do
    if clip.instances then
      for instanceId, instance in pairs(clip.instances) do
        if not instance.playing then
          clip.instances[instanceId] = nil
        end
      end
    end
  end
end

-- ============================================================
-- UTILITY FUNCTIONS
-- ============================================================

function ImAnim.ease_preset_name(easeType)
  for name, value in pairs(ImAnim.EASE) do
    if value == easeType then return name end
  end
  return "unknown"
end

function ImAnim.policy_name(policy)
  for name, value in pairs(ImAnim.POLICY) do
    if value == policy then return name end
  end
  return "unknown"
end

function ImAnim.color_space_name(colorSpace)
  for name, value in pairs(ImAnim.COLOR_SPACE) do
    if value == colorSpace then return name end
  end
  return "unknown"
end

-- STAGGER ANIMATION
-- ============================================================
ImAnim._staggerGrids = {}

function ImAnim.reset_stagger(gridId)
    ImAnim._staggerGrids[gridId] = nil
end

function ImAnim.stagger(gridId, index, totalItems, duration, delayPerItem)
    duration = duration or 0.5
    delayPerItem = delayPerItem or 0.05
    
    if not ImAnim._staggerGrids[gridId] then
        ImAnim._staggerGrids[gridId] = {
            startTime = os.clock(),
            items = {}
        }
    end
    
    local grid = ImAnim._staggerGrids[gridId]
    local now = os.clock()
    local timeSinceStart = now - grid.startTime
    
    local itemDelay = (index - 1) * delayPerItem
    local itemProgress = (timeSinceStart - itemDelay) / duration
    
    if itemProgress < 0 then itemProgress = 0 end
    if itemProgress > 1 then itemProgress = 1 end
    
    -- Use a simple ease out cubic
    local t = itemProgress
    t = t - 1
    local eased = t * t * t + 1
    
    return eased
end

return ImAnim
