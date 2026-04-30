-- humanize/engagement.lua
-- Per-engagement decision noise:
--   - pickStickVariant(role, settings): randomized stick command (non-tank only)
--   - pickEngageThreshold(role): mob HP% at which DPS will fire (jittered)
--
-- Results are stored on the target id; cleared on target change/death by callers.

local Profiles      = require('sidekick-next.humanize.profiles')
local Selector      = require('sidekick-next.humanize.selector')
local State         = require('sidekick-next.humanize.state')
local Distributions = require('sidekick-next.humanize.distributions')

local M = {}

local function flagOn()
    local cfg = _G.SIDEKICK_NEXT_CONFIG
    return cfg and cfg.HUMANIZE_BEHAVIOR == true
end

local function activeProfile()
    return Profiles.get(Selector.resolve()) or Profiles.off
end

-- Stick variants for non-tank melee. Each entry is a (verb, baseDistance) tuple.
-- distance gets perturbed by ±2..4 around the configured base when the variant is picked.
local NON_TANK_STICK_VARIANTS = {
    { verb = 'snaproll behind',  base = 10, moveback = true,  uw = true  },
    { verb = 'behind',           base = 10, moveback = true,  uw = false },
    { verb = 'behindonce',       base = 10, moveback = false, uw = false },
    { verb = '!front',           base = 10, moveback = true,  uw = false },
    { verb = 'loose',            base = 12, moveback = false, uw = false },
}

local function jitterDistance(base)
    -- ±2..4 around base, integer.
    local delta = math.random(-4, 4)
    local d = base + delta
    if d < 6 then d = 6 end
    return d
end

local function buildStickCmd(variant)
    local d = jitterDistance(variant.base)
    local parts = { '/stick', variant.verb, tostring(d) }
    if variant.moveback then table.insert(parts, 'moveback') end
    if variant.uw then table.insert(parts, 'uw') end
    return table.concat(parts, ' ')
end

local function isTank(role, settings)
    if role == 'tank' then return true end
    if settings and (settings.combatMode == 'tank' or settings.CombatMode == 'tank') then return true end
    return false
end

-- Pick a stick command for this engagement.
-- role: 'tank' | 'dps' | 'melee' | 'caster' | nil   (nil = inferred from settings)
-- settings: SideKick settings table (used for tank check + StickCommand fallback)
-- targetId: spawn id; the chosen variant is cached for the engagement.
-- Returns: stick command string ready for mq.cmd().
function M.pickStickVariant(role, settings, targetId)
    local fallback = (settings and settings.StickCommand) or '/stick snaproll behind 10 moveback uw'

    if not flagOn() then return fallback end
    if not Profiles.subsystemEnabled('engagement') then return fallback end

    -- Tank: always deterministic (hate management).
    if isTank(role, settings) then return fallback end

    -- Off-profile: deterministic.
    local profileName = Selector.resolve()
    if profileName == 'off' then return fallback end

    -- Reuse cached variant for this engagement if we already rolled.
    if targetId and targetId > 0 then
        local cached = State.getTargetRoll(targetId)
        if cached and cached.stickCmd then return cached.stickCmd end
    end

    local variant = NON_TANK_STICK_VARIANTS[math.random(1, #NON_TANK_STICK_VARIANTS)]
    local cmd = buildStickCmd(variant)

    if targetId and targetId > 0 then
        local roll = State.getTargetRoll(targetId) or {}
        roll.stickCmd = cmd
        roll.stickAt = State.now()
        State.setTargetRoll(targetId, roll)
    end

    return cmd
end

-- If the current target has been engaged for >= reStickAfterMs, force a re-roll
-- of the stick variant. Returns nil if no re-stick is due, otherwise returns
-- the new stick command (and updates the cache).
local RESTICK_AFTER_MS = 60000  -- ~1× per minute on long fights
function M.maybeReStick(role, settings, targetId)
    if not flagOn() then return nil end
    if not Profiles.subsystemEnabled('engagement') then return nil end
    if isTank(role, settings) then return nil end
    if not targetId or targetId == 0 then return nil end
    local roll = State.getTargetRoll(targetId)
    if not roll or not roll.stickAt then return nil end
    if (State.now() - roll.stickAt) < RESTICK_AFTER_MS then return nil end
    -- Roll a new variant; ~50% chance per check after the threshold.
    if not Distributions.chance(0.5) then return nil end

    -- Force a fresh pick by clearing prior cmd.
    roll.stickCmd = nil
    State.setTargetRoll(targetId, roll)
    return M.pickStickVariant(role, settings, targetId)
end

-- Pick the mob HP% at which non-tank DPS will start firing on this target.
-- Tanks: 100 (immediate engage).
-- Non-tank: lognormal in 88-100, median ~96. emergency/named profiles clamp to 95-100.
-- Per-engagement: stable for the life of the target.
function M.pickEngageThreshold(role, settings, targetId)
    if not flagOn() then return 100 end
    if not Profiles.subsystemEnabled('engagement') then return 100 end
    if isTank(role, settings) then return 100 end

    if targetId and targetId > 0 then
        local cached = State.getTargetRoll(targetId)
        if cached and cached.engageThreshold then return cached.engageThreshold end
    end

    -- Lognormal with median ~96 produces tight cluster near 100 with occasional dips.
    -- Express as 100 - sample(median=4, sigma=0.6, max=12) so most rolls land 96-100.
    local dip = Distributions.lognormal({ median_ms = 4, sigma = 0.6, min = 0, max = 12 })
    local thresh = 100 - dip

    local profileName = Selector.resolve()
    if profileName == 'emergency' or profileName == 'named' then
        if thresh < 95 then thresh = 95 end
    end
    if thresh < 88 then thresh = 88 end
    if thresh > 100 then thresh = 100 end

    if targetId and targetId > 0 then
        local roll = State.getTargetRoll(targetId) or {}
        roll.engageThreshold = thresh
        State.setTargetRoll(targetId, roll)
    end

    return thresh
end

-- Clear cached rolls for a target (call on death/target change).
function M.clearTarget(targetId)
    State.clearTargetRoll(targetId)
end

return M
