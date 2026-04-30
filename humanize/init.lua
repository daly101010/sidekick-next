-- humanize/init.lua
-- Public API for the behavioral humanization layer.
--
-- Modules consult this service at known integration points:
--   local H = require('sidekick-next.humanize')
--   local d = H.gate('cast', { target=tid, spell=name, urgency='normal' })
--   if d == H.SKIP then return end
--   mq.delay(d)
--   mq.cmdf('/cast "%s"', name)
--
--   local picked = H.perturbChoice(ranked, { kind='heal' })
--
-- When _G.SIDEKICK_NEXT_CONFIG.HUMANIZE_BEHAVIOR is false, gate() returns 0 and
-- perturbChoice() returns the input untouched (zero behavioral change vs today).

local Profiles      = require('sidekick-next.humanize.profiles')
local Selector      = require('sidekick-next.humanize.selector')
local State         = require('sidekick-next.humanize.state')
local Distributions = require('sidekick-next.humanize.distributions')

local M = {}

-- Sentinel returned from gate() when the profile rolls a "looked away" skip.
M.SKIP = -1

State.init()

-- Lazy-apply persisted settings on first call. Core.Settings may not be
-- populated when humanize is first required, so we defer until any of
-- gate()/perturbChoice()/tick() is invoked.
local _settingsApplied = false
local function ensureSettingsApplied()
    if _settingsApplied then return end
    local okC, Core = pcall(require, 'sidekick-next.utils.core')
    if not (okC and Core and Core.Settings) then return end
    local okP, P = pcall(require, 'sidekick-next.humanize.persistence')
    if okP and P and P.applyFromSettings then
        pcall(P.applyFromSettings, Core.Settings)
        _settingsApplied = true
    end
end

function M.applySettings()
    _settingsApplied = false
    ensureSettingsApplied()
end

local function flagOn()
    local cfg = _G.SIDEKICK_NEXT_CONFIG
    return cfg and cfg.HUMANIZE_BEHAVIOR == true
end

-- Map an action kind to the subsystem it belongs to. Gate is no-op when the
-- subsystem is disabled.
local KIND_TO_SUBSYSTEM = {
    cast    = 'combat',
    ability = 'combat',
    target  = 'targeting',
    buff    = 'buffs',
    heal    = 'heals',
}

local function appliesTo(profile, kind)
    if not profile.applies_to or #profile.applies_to == 0 then return false end
    for _, k in ipairs(profile.applies_to) do
        if k == kind then return true end
    end
    return false
end

local function kindAllowedBySubsystem(kind, urgency)
    local sub = KIND_TO_SUBSYSTEM[kind]
    if not sub then return true end
    -- Heal urgency uses the 'heals' subsystem regardless of caller kind.
    if urgency == 'emergency' or urgency == 'heal' then sub = 'heals' end
    return Profiles.subsystemEnabled(sub)
end

local function recordIfDebug(entry)
    if State.debugEnabled() then
        State.recordDecision(entry)
    end
end

-- Single delay covering reaction + precast windows. Never stacked across two
-- gate() calls for one action.
function M.gate(kind, ctx)
    ctx = ctx or {}
    if not flagOn() then return 0 end
    if not kindAllowedBySubsystem(kind, ctx.urgency) then return 0 end

    -- Emergency carve-out: caller signals urgency; selector picks 'emergency'
    -- profile if we're not already there. Doesn't bypass the gate.
    if ctx.urgency == 'emergency' then
        State.setActive('emergency')
    end

    local profileName = Selector.resolve()
    local profile = Profiles.get(profileName) or Profiles.off

    State.markAction()

    if profileName == 'off' then return 0 end
    if not appliesTo(profile, kind) then return 0 end

    -- Decision-noise: skip this tick.
    local skipP = profile.noise and profile.noise.skip_global_p or 0
    if skipP > 0 and Distributions.chance(skipP) then
        recordIfDebug({ at = State.now(), kind = kind, profile = profileName, action = 'SKIP' })
        return M.SKIP
    end

    local reaction = Distributions.sample(profile.reaction) or 0
    local precast  = Distributions.sample(profile.precast)  or 0
    local extra    = 0
    if kind == 'target' then
        extra = Distributions.sample(profile.target_lock) or 0
        local hesitP = profile.noise and profile.noise.retarget_hesit or 0
        if hesitP > 0 and Distributions.chance(hesitP) then
            extra = extra + Distributions.sample({dist='lognormal', median_ms=200, sigma=0.4, min=80, max=600})
        end
    end

    local total = math.floor(reaction + precast + extra + 0.5)
    if total < 0 then total = 0 end

    recordIfDebug({
        at = State.now(),
        kind = kind,
        profile = profileName,
        delay = total,
        urgency = ctx.urgency or 'normal',
    })

    return total
end

-- Decision-noise pick from a ranked list. Returns input[1] when noise dice fail
-- or when noise is disabled. Caller passes the same list ordered best-first.
-- kind is informational; ctx.urgency='emergency' disables noise.
function M.perturbChoice(ranked, ctx)
    if type(ranked) ~= 'table' or #ranked == 0 then return ranked end
    if not flagOn() then return ranked[1] end
    ctx = ctx or {}
    if ctx.urgency == 'emergency' then return ranked[1] end
    if not Profiles.subsystemEnabled('heals') and ctx.kind == 'heal' then
        return ranked[1]
    end

    local profile = Profiles.get(Selector.resolve()) or Profiles.off
    local p = profile.noise and profile.noise.second_best_p or 0
    if p <= 0 or #ranked < 2 then return ranked[1] end
    if Distributions.chance(p) then
        recordIfDebug({ at = State.now(), kind = ctx.kind or 'choice', profile = Selector.resolve(), action = 'rank2' })
        return ranked[2]
    end
    return ranked[1]
end

-- Buff refresh jitter: returns the threshold to use *this evaluation* given the
-- configured threshold pct. Clamped to [thresh - jitter*100, thresh] so we never
-- let a buff drop below the user's intended floor.
function M.jitterRefreshPct(threshPct)
    if not flagOn() then return threshPct end
    if not Profiles.subsystemEnabled('buffs') then return threshPct end
    local profile = Profiles.get(Selector.resolve()) or Profiles.off
    local j = profile.buff_refresh_pct_jitter or 0
    if j <= 0 then return threshPct end
    local lo = threshPct - (j * 100.0)
    if lo < 0 then lo = 0 end
    return lo + math.random() * (threshPct - lo)
end

-- Tick called from any main loop that wants to drive selector cadence.
-- Optional: gate()/perturbChoice() also lazy-refresh, so wiring this is not required for P1.
function M.tick()
    ensureSettingsApplied()
    Selector.resolve()
end

-- Profile control --------------------------------------------------------------

function M.setOverride(o) State.setOverride(o) end
function M.getOverride() return State.getOverride() end
function M.activeProfile() return State.getActive() end

function M.setSubsystem(name, enabled) Profiles.setSubsystem(name, enabled) end
function M.subsystemEnabled(name) return Profiles.subsystemEnabled(name) end

function M.setDebug(on) State.setDebug(on) end
function M.dumpRecent() return State.dumpRecent() end

-- Per-target rolls (used by humanize.engagement in P5).
function M.getTargetRoll(id) return State.getTargetRoll(id) end
function M.setTargetRoll(id, r) State.setTargetRoll(id, r) end
function M.clearTargetRoll(id) State.clearTargetRoll(id) end

-- Register slash commands once per Lua state. mq.bind is per-script, so each
-- /lua run process that requires humanize gets its own binds; that's fine —
-- toggling overrides per process is the intended UX since profile state lives
-- in each script's local copy of state.lua.
local _bindsRegistered = false
if not _bindsRegistered then
    local ok, Binds = pcall(require, 'sidekick-next.humanize.binds')
    if ok and Binds and Binds.register then
        pcall(Binds.register, M)
    end
    _bindsRegistered = true
end

return M
