-- humanize/profiles.lua
-- Profile catalog. Each profile is a plain table; tunable without code edits.
--
-- Schema
--   reaction       distribution spec for "I noticed something happened"
--   precast        extra delay between target acquired / decision made and command issuance
--   target_lock    delay between deciding to switch target and /target id
--   buff_refresh_pct_jitter  refresh fires within [thresh - jitter*100, thresh] (clamped, never lets buff drop)
--   noise.second_best_p   probability of swapping to rank-2 option from a tier
--   noise.skip_global_p   probability of returning SKIP this tick ("looked away")
--   noise.retarget_hesit  probability of an extra small delay before re-targeting
--   noise.double_press_p  probability of a benign re-issue (currently informational; guarded sites may use later)
--   applies_to     action kinds the profile gates ('cast', 'ability', 'target', 'buff')
--
-- Profile selection rules live in selector.lua.

local M = {}

-- 'off' is no-op: zero delays, zero noise, applies_to empty.
-- selector returns 'off' when the feature flag is off, kill switch is on,
-- or full-bore override is active. gate() short-circuits on 'off'.
M.off = {
    reaction       = nil,
    precast        = nil,
    target_lock    = nil,
    buff_refresh_pct_jitter = 0,
    noise = { second_best_p = 0, skip_global_p = 0, retarget_hesit = 0, double_press_p = 0 },
    applies_to = {},
}

M.idle = {
    reaction       = {dist='lognormal', median_ms=600, sigma=0.55, min=200, max=2500},
    precast        = {dist='lognormal', median_ms=200, sigma=0.45, min=80,  max=900 },
    target_lock    = {dist='lognormal', median_ms=400, sigma=0.55, min=100, max=1500},
    buff_refresh_pct_jitter = 0.20,
    noise = { second_best_p = 0.10, skip_global_p = 0.06, retarget_hesit = 0.30, double_press_p = 0.01 },
    applies_to = {'cast','ability','target','buff'},
}

M.farming = {
    reaction       = {dist='lognormal', median_ms=280, sigma=0.45, min=100, max=1300},
    precast        = {dist='lognormal', median_ms=130, sigma=0.40, min=50,  max=700 },
    target_lock    = {dist='lognormal', median_ms=200, sigma=0.50, min=40,  max=900 },
    buff_refresh_pct_jitter = 0.12,
    noise = { second_best_p = 0.05, skip_global_p = 0.02, retarget_hesit = 0.15, double_press_p = 0.005 },
    applies_to = {'cast','ability','target','buff'},
}

M.combat = {
    reaction       = {dist='lognormal', median_ms=220, sigma=0.40, min=90,  max=1100},
    precast        = {dist='lognormal', median_ms=110, sigma=0.35, min=40,  max=600 },
    target_lock    = {dist='lognormal', median_ms=170, sigma=0.45, min=35,  max=800 },
    buff_refresh_pct_jitter = 0.10,
    noise = { second_best_p = 0.03, skip_global_p = 0.01, retarget_hesit = 0.10, double_press_p = 0.002 },
    applies_to = {'cast','ability','target','buff'},
}

M.emergency = {
    reaction       = {dist='lognormal', median_ms=140, sigma=0.30, min=60,  max=600 },
    precast        = {dist='lognormal', median_ms=80,  sigma=0.30, min=30,  max=400 },
    target_lock    = {dist='lognormal', median_ms=110, sigma=0.35, min=25,  max=500 },
    buff_refresh_pct_jitter = 0.05,
    noise = { second_best_p = 0, skip_global_p = 0, retarget_hesit = 0, double_press_p = 0 },
    applies_to = {'cast','ability','target','buff'},
}

M.named = {
    reaction       = {dist='lognormal', median_ms=180, sigma=0.35, min=75,  max=900 },
    precast        = {dist='lognormal', median_ms=100, sigma=0.35, min=40,  max=500 },
    target_lock    = {dist='lognormal', median_ms=140, sigma=0.40, min=30,  max=700 },
    buff_refresh_pct_jitter = 0.08,
    noise = { second_best_p = 0, skip_global_p = 0, retarget_hesit = 0.05, double_press_p = 0 },
    applies_to = {'cast','ability','target','buff'},
}

-- Subsystem toggles consulted at integration sites. Defaults all on.
-- UI layer flips these when user disables a subsystem.
M.subsystems = {
    combat     = true,   -- spell_engine + action_executor + dps cast gate
    targeting  = true,   -- target gate
    buffs      = true,   -- buff refresh jitter
    heals      = true,   -- heal_selector perturbChoice + heal cast gate
    fidget     = true,   -- idle camera/sit-stand emitter
    engagement = true,   -- stick variant + engage threshold
}

function M.get(name)
    return M[name]
end

function M.subsystemEnabled(name)
    local v = M.subsystems[name]
    if v == nil then return true end
    return v == true
end

function M.setSubsystem(name, enabled)
    if M.subsystems[name] ~= nil then
        M.subsystems[name] = enabled and true or false
    end
end

-- Editable profile names (excludes 'off' which is hard-coded no-op).
M.EDITABLE = { 'idle', 'farming', 'combat', 'emergency', 'named' }

local function clampNum(v, lo, hi)
    v = tonumber(v); if not v then return nil end
    if lo and v < lo then v = lo end
    if hi and v > hi then v = hi end
    return v
end

-- Set a single distribution field on a profile.
-- profileName: 'idle' | 'farming' | 'combat' | 'emergency' | 'named'
-- distName: 'reaction' | 'precast' | 'target_lock'
-- field: 'median_ms' | 'sigma' | 'min' | 'max'
function M.setDistField(profileName, distName, field, value)
    local p = M[profileName]
    if not p or profileName == 'off' then return end
    if not p[distName] then return end
    if field == 'median_ms' then
        value = clampNum(value, 10, 5000)
    elseif field == 'sigma' then
        value = clampNum(value, 0.05, 1.5)
    elseif field == 'min' then
        value = clampNum(value, 0, 5000)
    elseif field == 'max' then
        value = clampNum(value, 10, 10000)
    else
        return
    end
    if value == nil then return end
    p[distName][field] = value
end

function M.setBuffJitter(profileName, value)
    local p = M[profileName]
    if not p or profileName == 'off' then return end
    value = clampNum(value, 0, 0.5)
    if value == nil then return end
    p.buff_refresh_pct_jitter = value
end

function M.setNoise(profileName, key, value)
    local p = M[profileName]
    if not p or profileName == 'off' then return end
    p.noise = p.noise or {}
    if key ~= 'second_best_p' and key ~= 'skip_global_p'
       and key ~= 'retarget_hesit' and key ~= 'double_press_p' then return end
    value = clampNum(value, 0, 1)
    if value == nil then return end
    p.noise[key] = value
end

return M
