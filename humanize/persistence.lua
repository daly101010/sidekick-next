-- humanize/persistence.lua
-- Bridges UI knob changes to Core.set / Core.Settings so they survive script
-- restart. Two halves:
--   M.applyFromSettings(coreSettings) — call once at module load to push
--     persisted values back into the live Profiles/Fidget/Engagement/Chase
--     state.
--   M.persist(key, value) — UI calls this after a knob change; we both write
--     through to Core.set and update the live state. UI code uses this
--     instead of touching Core.set directly so the key naming stays here.

local M = {}

local PREFIX = 'Humanize_'

-- Settings key helpers --------------------------------------------------------
local function k_master()           return 'HUMANIZE_BEHAVIOR' end  -- mirrors _G flag
local function k_subsystem(name)    return PREFIX .. 'Sub_' .. name end
local function k_fidgetWeight(a)    return PREFIX .. 'FW_' .. a end
local function k_fidgetMinInt()     return PREFIX .. 'FidgetMinIntervalMs' end
local function k_fidgetPerSec()     return PREFIX .. 'FidgetPerSec' end
local function k_fidgetKeybind(n)   return PREFIX .. 'FK_' .. n end
local function k_windowKey(n)       return PREFIX .. 'WK_' .. n end
local function k_engageMin()        return PREFIX .. 'EngageMinPct' end
local function k_restickMs()        return PREFIX .. 'RestickAfterMs' end
local function k_chaseJitter()      return PREFIX .. 'ChaseJitterPct' end
local function k_profileDist(p, d, f) return string.format('%sP_%s_%s_%s', PREFIX, p, d, f) end
local function k_profileBuff(p)     return PREFIX .. 'P_' .. p .. '_buffjitter' end
local function k_profileNoise(p, k) return string.format('%sP_%s_n_%s', PREFIX, p, k) end

-- Lazy module accessors -------------------------------------------------------
local function getProfiles()
    local ok, P = pcall(require, 'sidekick-next.humanize.profiles'); return ok and P or nil
end
local function getFidget()
    local ok, F = pcall(require, 'sidekick-next.humanize.fidget'); return ok and F or nil
end
local function getEngagement()
    local ok, E = pcall(require, 'sidekick-next.humanize.engagement'); return ok and E or nil
end
local function getChase()
    local ok, C = pcall(require, 'sidekick-next.automation.chase'); return ok and C or nil
end
local function getCore()
    local ok, C = pcall(require, 'sidekick-next.utils.core'); return ok and C or nil
end

local function tobool(v)
    if v == true or v == 'true' or v == 1 or v == '1' then return true end
    if v == false or v == 'false' or v == 0 or v == '0' then return false end
    return nil
end

local function tonum(v)
    if type(v) == 'number' then return v end
    if type(v) == 'string' then return tonumber(v) end
    return nil
end

-- Apply persisted values to live state.
-- Called once at module load.
function M.applyFromSettings(settings)
    settings = settings or (getCore() and getCore().Settings) or {}
    local Profiles   = getProfiles()
    local Fidget     = getFidget()
    local Engagement = getEngagement()
    local Chase      = getChase()

    -- Master flag
    if settings[k_master()] ~= nil then
        local b = tobool(settings[k_master()])
        if b ~= nil then
            _G.SIDEKICK_NEXT_CONFIG = _G.SIDEKICK_NEXT_CONFIG or {}
            _G.SIDEKICK_NEXT_CONFIG.HUMANIZE_BEHAVIOR = b
        end
    end

    -- Subsystems
    if Profiles then
        for _, name in ipairs({'combat','targeting','buffs','heals','engagement','fidget'}) do
            local v = settings[k_subsystem(name)]
            if v ~= nil then
                local b = tobool(v); if b ~= nil then Profiles.setSubsystem(name, b) end
            end
        end
    end

    -- Fidget weights / interval / persec
    if Fidget then
        local actions = { 'turn','jump','strafe','window','pitch','face_spawn','med_cycle' }
        for _, a in ipairs(actions) do
            local v = tonum(settings[k_fidgetWeight(a)]); if v then Fidget.setWeight(a, v) end
        end
        local mi = tonum(settings[k_fidgetMinInt()]); if mi then Fidget.setMinIntervalMs(mi) end
        local fps = tonum(settings[k_fidgetPerSec()]); if fps then Fidget.setFidgetPerSec(fps) end

        -- Keybinds (string)
        for _, n in ipairs({'turn_left','turn_right','jump','strafe_left','strafe_right','look_up','look_down'}) do
            local v = settings[k_fidgetKeybind(n)]
            if type(v) == 'string' then Fidget.setKeybind(n, v) end
        end

        -- Window keys
        for _, n in ipairs({'inventory','character','map','group'}) do
            local v = settings[k_windowKey(n)]
            if type(v) == 'string' then Fidget.setWindowKey(n, v) end
        end
    end

    -- Engagement
    if Engagement then
        local v = tonum(settings[k_engageMin()]); if v then Engagement.setEngageMinPct(v) end
        local v2 = tonum(settings[k_restickMs()]); if v2 then Engagement.setRestickAfterMs(v2) end
    end

    -- Chase
    if Chase and Chase.setChaseJitterPct then
        local v = tonum(settings[k_chaseJitter()]); if v then Chase.setChaseJitterPct(v) end
    end

    -- Profile per-field values
    if Profiles then
        for _, pname in ipairs(Profiles.EDITABLE or {}) do
            for _, dname in ipairs({'reaction','precast','target_lock'}) do
                for _, field in ipairs({'median_ms','sigma','min','max'}) do
                    local v = tonum(settings[k_profileDist(pname, dname, field)])
                    if v then Profiles.setDistField(pname, dname, field, v) end
                end
            end
            local bj = tonum(settings[k_profileBuff(pname)])
            if bj then Profiles.setBuffJitter(pname, bj) end
            for _, nk in ipairs({'second_best_p','skip_global_p','retarget_hesit','double_press_p'}) do
                local v = tonum(settings[k_profileNoise(pname, nk)])
                if v then Profiles.setNoise(pname, nk, v) end
            end
        end
    end
end

-- Persist a knob value. UI code calls this; it both writes through to Core
-- and applies to live state. Exported so the UI doesn't have to know key
-- naming conventions.
function M.persist(kind, args, value)
    local Core = getCore()
    local Profiles = getProfiles()
    local Fidget = getFidget()
    local Engagement = getEngagement()
    local Chase = getChase()
    args = args or {}

    local function set(key, val)
        if Core and Core.set then Core.set(key, val) end
    end

    if kind == 'master' then
        _G.SIDEKICK_NEXT_CONFIG = _G.SIDEKICK_NEXT_CONFIG or {}
        _G.SIDEKICK_NEXT_CONFIG.HUMANIZE_BEHAVIOR = value and true or false
        set(k_master(), value and true or false)
    elseif kind == 'subsystem' then
        if Profiles then Profiles.setSubsystem(args.name, value) end
        set(k_subsystem(args.name), value and true or false)
    elseif kind == 'fidget_weight' then
        if Fidget then Fidget.setWeight(args.action, value) end
        set(k_fidgetWeight(args.action), value)
    elseif kind == 'fidget_minInterval' then
        if Fidget then Fidget.setMinIntervalMs(value) end
        set(k_fidgetMinInt(), value)
    elseif kind == 'fidget_perSec' then
        if Fidget then Fidget.setFidgetPerSec(value) end
        set(k_fidgetPerSec(), value)
    elseif kind == 'fidget_keybind' then
        if Fidget then Fidget.setKeybind(args.name, value) end
        set(k_fidgetKeybind(args.name), value or '')
    elseif kind == 'window_key' then
        if Fidget then Fidget.setWindowKey(args.name, value) end
        set(k_windowKey(args.name), value or '')
    elseif kind == 'engage_min' then
        if Engagement then Engagement.setEngageMinPct(value) end
        set(k_engageMin(), value)
    elseif kind == 'restick_ms' then
        if Engagement then Engagement.setRestickAfterMs(value) end
        set(k_restickMs(), value)
    elseif kind == 'chase_jitter' then
        if Chase and Chase.setChaseJitterPct then Chase.setChaseJitterPct(value) end
        set(k_chaseJitter(), value)
    elseif kind == 'profile_dist' then
        if Profiles then Profiles.setDistField(args.profile, args.dist, args.field, value) end
        set(k_profileDist(args.profile, args.dist, args.field), value)
    elseif kind == 'profile_buff' then
        if Profiles then Profiles.setBuffJitter(args.profile, value) end
        set(k_profileBuff(args.profile), value)
    elseif kind == 'profile_noise' then
        if Profiles then Profiles.setNoise(args.profile, args.key, value) end
        set(k_profileNoise(args.profile, args.key), value)
    end
end

return M
