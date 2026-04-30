-- humanize/distributions.lua
-- Random samplers for humanization timings.
-- Lognormal is preferred for reaction-time-style distributions because real
-- human reaction times have a long right tail and can never be zero.

local M = {}

-- Box-Muller transform: returns one standard normal sample.
local function gaussian()
    local u1 = math.random()
    local u2 = math.random()
    if u1 <= 1e-12 then u1 = 1e-12 end
    return math.sqrt(-2.0 * math.log(u1)) * math.cos(2.0 * math.pi * u2)
end

-- Sample a lognormal-distributed value parameterized by median and sigma.
-- median_ms: 50th-percentile target (ms)
-- sigma:     shape parameter (~0.3 tight, ~0.6 loose tail)
-- min/max:   hard clamps (ms)
function M.lognormal(spec)
    local median_ms = spec.median_ms or 200
    local sigma = spec.sigma or 0.4
    local mu = math.log(median_ms)
    local z = gaussian()
    local v = math.exp(mu + sigma * z)
    if spec.min and v < spec.min then v = spec.min end
    if spec.max and v > spec.max then v = spec.max end
    return v
end

-- Truncated gaussian (ms). Useful when we want a symmetric distribution.
function M.gaussian(spec)
    local mean = spec.mean_ms or 200
    local stddev = spec.stddev_ms or 60
    local v = mean + stddev * gaussian()
    if spec.min and v < spec.min then v = spec.min end
    if spec.max and v > spec.max then v = spec.max end
    return v
end

-- Dispatch by spec.dist; returns a numeric ms value.
function M.sample(spec)
    if not spec then return 0 end
    local dist = spec.dist or 'lognormal'
    if dist == 'lognormal' then return M.lognormal(spec) end
    if dist == 'gaussian' then return M.gaussian(spec) end
    return spec.median_ms or spec.mean_ms or 0
end

-- Bernoulli trial; returns true with probability p.
function M.chance(p)
    if not p or p <= 0 then return false end
    if p >= 1 then return true end
    return math.random() < p
end

return M
