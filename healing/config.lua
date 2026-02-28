-- healing/config.lua
local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

-- Lazy-load Logger to avoid circular requires
local getLogger = lazy.once('sidekick-next.healing.logger')

local M = {
    _version = "1.0",

    -- Master enable toggle (single source of truth)
    enabled = true,

    -- Thresholds
    emergencyPct = 25,
    minHealPct = 10,
    groupHealMinCount = 3,
    nearDeadMobPct = 10,  -- Mobs below this HP% are excluded from fight phase avg
    -- Character-specific minimum heal threshold:
    -- Compares deficit% vs (minHeal% of maxHP) * threshold
    -- E.g., if smallest heal is 10% of target's maxHP, need at least 7% deficit (at 70% threshold)
    -- This prevents overhealing when all available heals are too big for small deficits
    minHealThresholdPct = 70,

    -- Squishy handling
    squishyClasses = { WIZ = true, ENC = true, NEC = true, MAG = true },
    squishyCoveragePct = 70,
    nonSquishyMinHealPct = 15,
    nonSquishyHotMinDeficitPct = 20,  -- Non-squishy HoT threshold matches base (20% deficit = 80% HP)
    lowPressureMinDeficitPct = 20,    -- During low pressure, wait for 20% deficit before direct heals
    lowPressureHotMinDeficitPct = 25, -- During low pressure, wait for 25% deficit before HoTs (more conservative)
    lowPressureMobCount = 1,

    -- Scoring weights
    -- Overheal penalty increased to properly penalize heals that are too big for the deficit
    -- ManaEff reduced in normal mode - right-sizing heals matters more than raw efficiency
    scoringPresets = {
        emergency = { coverage = 4.0, manaEff = 0.1, overheal = -0.5 },  -- Save the target, efficiency doesn't matter
        raidFight = { coverage = 3.0, manaEff = 0.3, overheal = -1.5 },  -- Named/raid mobs: favor throughput, tolerate overheal
        normal = { coverage = 2.0, manaEff = 0.5, overheal = -3.0 },     -- Balance coverage with minimal waste
        lowPressure = { coverage = 1.0, manaEff = 1.5, overheal = -4.0 }, -- Maximize efficiency, heavily penalize overheal
    },
    maxOverhealRatio = 2.0,
    overhealTolerancePct = 20,
    preferUnderheal = true,
    underhealMinCoveragePct = 80,
    critOverhealThreshold = 0.15,
    critOverhealPenalty = -2.0,
    smallHealPenalty = -1.0,

    -- Ducking
    duckEnabled = true,
    duckHpThreshold = 85,
    duckEmergencyThreshold = 70,
    duckHotThreshold = 92,
    duckBufferPct = 0.5,
    considerIncomingHot = true,
    hotIncomingCoveragePct = 100,

    -- HoT behavior
    -- HoTs start around 80% HP when sustained damage is detected
    hotEnabled = true,
    hotMinDps = 200,             -- Minimum DPS to target for HoT to be considered
    hotSupplementMinDps = 200,   -- Minimum DPS for HoT supplementation
    hotMinDeficitPct = 20,       -- Minimum deficit% for HoT (20% = 80% HP) - first response to sustained damage
    hotMaxDeficitPct = 35,       -- Max deficit% for HoT eligibility (direct heals take over below 65% HP)
    hotPreferUnderDps = 3000,
    hotMinDpsForNonTank = 500,
    hotOverrideDpsPct = 5,
    hotTypicalDuration = 36,
    hotLearnForce = false,
    hotLearnMaxDeficitPct = 10,
    hotLearnIntervalSec = 30,
    quickHealMaxPct = 15,
    quickHealsEmergencyOnly = true,
    hotMinCoverageRatio = 0.3,
    hotUselessRatio = 0.1,
    hotRefreshWindowPct = 0,
    hotTankOnly = true,
    hotCoverageMultiplier = 1.2,  -- HoT HPS must exceed DPS * this multiplier to be sufficient
    hotSafetyBufferSec = 8,       -- Seconds of buffer before danger threshold to allow HoT to work
    hotSupplementMinGapPct = 5,   -- Minimum gap % of maxHP before supplementing a HoT
    bigHotMinMobDps = 3000,
    bigHotMinXTargetCount = 4,
    bigHotXTargetRange = 100,
    bigHotWithPromisedMinDps = 6000,

    -- Promised heal behavior
    promisedEnabled = true,
    promisedMinDps = 500,
    promisedMinActiveMobs = 1,
    promisedDelaySeconds = 18,
    promisedSafetyFloorPct = 35,
    promisedSurvivalSafetyFloorPct = 55,
    promisedRolling = true,
    promisedDurationBuffer = 5,

    -- Combat assessment
    survivalModeDpsPct = 5,
    survivalModeTankFullPct = 90,
    fightPhaseStartingPct = 70,
    fightPhaseEndingPct = 25,
    fightPhaseEndingTTK = 20,
    hotMinFightDurationPct = 50,
    survivalModeMaxHotDuration = 12,
    -- High pressure detection
    highPressureMinMobs = 3,         -- Min active mobs for high pressure
    highPressureMinDps = 3000,       -- OR min total DPS for high pressure
    highPressureMobMultiplier = 3.0, -- Mob difficulty multiplier that triggers high pressure (impossible+ tier)

    -- Mob difficulty adjustments (from mob_assessor tiers)
    raidMobSurvivalDpsPctReduction = 2,   -- Lower survival threshold by this % for raid mobs
    raidMobPromisedFloorIncrease = 10,    -- Raise promised safety floor by this % for raid fights

    -- Adaptive throttle for raid fights (reduces aggressiveness if overhealing)
    throttleMinHeals = 5,           -- Min heals in fight before throttle can activate
    throttleOverhealPct = 40,       -- Overheal % threshold to start throttling
    throttleMaxLevel = 0.5,         -- Max throttle level (0-1, affects weight adjustments)
    -- TTK tracking
    ttkWindowSec = 5,                -- Window for tracking mob HP decline

    -- DPS tracking (dual-source: HP delta + log parsing)
    damageWindowSec = 6,         -- Window for averaging damage (matches design)
    hpDpsWeight = 0.4,           -- Weight for HP delta DPS
    logDpsWeight = 0.6,          -- Weight for log-parsed DPS
    burstStddevMultiplier = 1.5, -- Burst = mean + (stddev * this) (matches design)
    burstDpsScale = 1.5,
    useLogDps = true,
    dpsValidationLogMs = 5000,

    -- Damage Attribution settings
    combatTimeoutSec = 5,        -- Clear attribution cache after N seconds of no damage
    dpsWindowSec = 3,            -- Rolling window for DPS calculation
    dpsVarianceThreshold = 25,   -- Max variance% between log DPS and HP delta DPS to be "reliable"

    -- Pet healing
    healPetsEnabled = false,     -- Whether to include pets in healing targets
    petHealMinPct = 40,          -- Minimum HP% to heal pets

    -- Self-healing (PAL off-tank use case)
    selfHealEnabled = false,     -- Whether to include selfHeal spells
    selfHealPct = 60,            -- HP% threshold for self-heal consideration

    -- Learning
    learningWeight = 0.1,
    minSamplesForReliable = 10,

    -- Coordination
    incomingHealTimeoutSec = 3,  -- Reduced from 10 - heals should land within cast time
    broadcastEnabled = true,

    -- Logging (file logging enabled by default for troubleshooting)
    debugLogging = false,      -- Console debug output
    fileLogging = true,        -- Write detailed logs to file for review
    fileLogLevel = 'info',     -- 'debug', 'info', 'warn', 'error'
    logCategories = {          -- Granular control over what gets logged
        targetSelection = true,   -- Who needs healing and why
        spellSelection = true,    -- What spell was chosen and scoring details
        spellScoring = true,      -- Individual spell scores for comparison
        ducking = true,           -- Spell ducking decisions
        incomingHeals = true,     -- Incoming heal coordination
        combatState = true,       -- Fight phase, survival mode, DPS tracking
        hotDecisions = true,      -- Proactive HoT logic
        supplement = true,        -- HoT supplement decisions (HoT vs DPS comparison)
        events = true,            -- Heal events (landed, HoT ticks, learning data)
        analytics = true,         -- Session statistics
        attribution = false,      -- Damage attribution (verbose, disabled by default)
        hotCoverage = true,       -- HoT vs direct heal decision logging
    },

    -- HoT Trust & Efficiency Settings
    hotCoverageLogLevel = 2,          -- 0=off, 1=summary, 2=detailed, 3=verbose

    -- Projection windows (seconds) for HoT trust calculation
    projectionWindowLow = 8,
    projectionWindowNormal = 6,
    projectionWindowHigh = 3,

    -- Heal thresholds by role and pressure (projected HP % to trigger direct heal)
    healThresholds = {
        tank    = { low = 50, normal = 60, high = 70 },
        healer  = { low = 60, normal = 70, high = 80 },
        dps     = { low = 55, normal = 65, high = 75 },
        squishy = { low = 65, normal = 75, high = 85 },
    },

    -- HoT application gates
    hotMinUsableTicks = 2,            -- Require at least 2 ticks to apply HoT
    hotSingleMobMinDpsRatio = 0.8,    -- Single-mob: DPS must be >= 80% of HoT HPS
    hotMultiMobMinDpsRatio = 0.3,     -- Multi-mob: DPS must be >= 30% of HoT HPS
    hotMaxOverhealRatio = 1.5,        -- Skip HoT if expected healing > damage × this

    -- Safety constraints (CRITICAL - see design constraints above)
    hotMinDpsForTrust = 100,          -- Min DPS required to trust HoT (prevents over-trust with bad data)
    hotTrustHardFloorPct = 35,        -- Below this HP%, BYPASS HoT trust entirely (safety backstop)

    -- Spells (user assigns)
    spells = {
        fast = {},
        small = {},
        medium = {},
        large = {},
        group = {},
        hot = {},
        hotLight = {},
        groupHot = {},
        promised = {},
        selfHeal = {},  -- Self-only heals (PAL SelfHeal line)
    },
}

-- Spell validation helpers
local function getSpell(spellName)
    local spell = mq.TLO.Spell(spellName)
    if spell and spell() then
        return spell
    end
    return nil
end

local function normalizeText(value)
    if not value then
        return ''
    end
    if type(value) ~= 'string' then
        value = tostring(value)
    end
    return value:lower():gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
end

local function isSingleTarget(targetType)
    local t = normalizeText(targetType)
    return t == 'single' or t:match('^single') ~= nil
end

local function isGroupV1(targetType)
    local t = normalizeText(targetType)
    return t:match('^group v1') ~= nil
end

local function isSelfTarget(targetType)
    local t = normalizeText(targetType)
    return t == 'self'
end

local function getCastTimeMs(spell)
    ---@diagnostic disable-next-line: undefined-field
    local mySpell = mq.TLO.Me.Spell(spell.Name())
    if mySpell and mySpell() then
        local myCastTime = tonumber(mySpell.MyCastTime())
        if myCastTime then
            return myCastTime
        end
    end
    local castTime = tonumber(spell.CastTime())
    if castTime then
        return castTime
    end
    return nil
end

function M.IsValidSpellForCategory(category, spellName)
    local spell = getSpell(spellName)
    if not spell then
        return false
    end

    local subcategory = normalizeText(spell.Subcategory())
    local targetType = normalizeText(spell.TargetType())

    if category == 'selfHeal' then
        return (subcategory == 'heals' or subcategory == 'quick heal') and isSelfTarget(targetType)
    elseif category == 'hot' or category == 'hotLight' then
        return subcategory == 'duration heals' and isSingleTarget(targetType)
    elseif category == 'groupHot' then
        return subcategory == 'duration heals' and isGroupV1(targetType)
    elseif category == 'group' then
        return subcategory == 'heals' and isGroupV1(targetType)
    elseif category == 'promised' then
        return subcategory == 'delayed' and isSingleTarget(targetType)
    elseif category == 'fast' or category == 'small' or category == 'medium' or category == 'large' then
        if category == 'fast' then
            return subcategory == 'quick heal' and isSingleTarget(targetType)
        end
        if not isSingleTarget(targetType) then
            return false
        end
        if category == 'small' or category == 'medium' then
            return subcategory == 'heals' or subcategory == 'quick heal'
        end
        if subcategory ~= 'heals' then
            return false
        end
        local castTimeMs = getCastTimeMs(spell)
        if not castTimeMs then
            return false
        end
        return castTimeMs > 2000
    end

    return true
end

function M.FilterSpells()
    if not M.spells then
        return
    end
    for category, spells in pairs(M.spells) do
        for i = #spells, 1, -1 do
            if not M.IsValidSpellForCategory(category, spells[i]) then
                table.remove(spells, i)
            end
        end
    end
end

function M.IsConfiguredSpell(spellName)
    if not M.spells or not spellName then
        return false
    end
    for _, spells in pairs(M.spells) do
        for _, name in ipairs(spells) do
            if name == spellName then
                return true
            end
        end
    end
    return false
end

-- Auto-assignment tracking
M.lastSpellBarScan = 0
M.spellBarScanInterval = 2.0  -- Rescan every 2 seconds

-- Get spell level for sorting
local function getSpellLevel(spell)
    if not spell then return 0 end
    local level = spell.Level and spell.Level()
    return tonumber(level) or 0
end

-- Categorize a healing spell (returns category or nil, plus level for sorting)
local function categorizeHealSpell(spellName)
    local spell = getSpell(spellName)
    if not spell then return nil end

    local subcategory = normalizeText(spell.Subcategory())
    local targetType = normalizeText(spell.TargetType())

    -- Check if it's a heal-related spell
    local isHealSpell = subcategory == 'heals' or subcategory == 'quick heal' or
                        subcategory == 'duration heals' or subcategory == 'delayed'
    if not isHealSpell then return nil end

    local singleTarget = isSingleTarget(targetType)
    local groupTarget = isGroupV1(targetType)

    -- Promised (delayed heals)
    if subcategory == 'delayed' and singleTarget then
        return 'promised'
    end

    -- Group HoT
    if subcategory == 'duration heals' and groupTarget then
        return 'groupHot'
    end

    -- Single target HoT - return marker for dynamic assignment
    if subcategory == 'duration heals' and singleTarget then
        -- Return marker with mana cost for sorting
        local manaCost = tonumber(spell.Mana()) or 0
        return 'hot_single', manaCost
    end

    -- Group direct heal
    if subcategory == 'heals' and groupTarget then
        return 'group'
    end

    -- Quick heal (fast/emergency)
    if subcategory == 'quick heal' and singleTarget then
        return 'fast'
    end

    -- Self-target heals (PAL SelfHeal line)
    local selfTarget = isSelfTarget(targetType)
    if (subcategory == 'heals' or subcategory == 'quick heal') and selfTarget then
        return 'selfHeal', getSpellLevel(spell)
    end

    -- Single target direct heals - return special marker for dynamic sizing by level
    if subcategory == 'heals' and singleTarget then
        return 'direct_single', getSpellLevel(spell)
    end

    return nil
end

-- Scan spell bar and auto-assign healing spells to categories
function M.autoAssignFromSpellBar()
    local now = os.clock()
    if (now - M.lastSpellBarScan) < M.spellBarScanInterval then
        return false  -- Not time to scan yet
    end
    M.lastSpellBarScan = now

    local me = mq.TLO.Me
    if not me or not me() then return false end

    -- Clear existing assignments
    M.spells = {
        fast = {},
        small = {},
        medium = {},
        large = {},
        group = {},
        hot = {},
        hotLight = {},
        groupHot = {},
        promised = {},
        selfHeal = {},
    }

    -- Track which spells we've assigned to avoid duplicates
    local assigned = {}

    -- Collect direct single-target heals for dynamic sizing by level
    local directHeals = {}  -- { spellName, level }
    -- Collect single-target HoTs for dynamic assignment by mana cost
    local hotHeals = {}  -- { spellName, manaCost }

    -- Scan all gem slots
    local numGems = tonumber(me.NumGems()) or 13
    local scanLog = getLogger()
    if scanLog then scanLog.debug('autoAssign', 'Scanning %d gem slots...', numGems) end

    for gem = 1, numGems do
        local gemSpell = me.Gem(gem)
        if gemSpell and gemSpell() then
            local spellName = gemSpell.Name()
            if spellName and spellName ~= '' and not assigned[spellName] then
                local category, value = categorizeHealSpell(spellName)
                if scanLog then
                    scanLog.debug('autoAssign', 'Gem %d: %s -> category=%s value=%s',
                        gem, spellName, tostring(category), tostring(value))
                end
                if category == 'direct_single' then
                    -- Collect for dynamic sizing
                    table.insert(directHeals, { name = spellName, level = value or 0 })
                    assigned[spellName] = true  -- Mark as processed
                elseif category == 'hot_single' then
                    -- Collect HoTs for dynamic assignment
                    table.insert(hotHeals, { name = spellName, manaCost = value or 0 })
                    assigned[spellName] = true  -- Mark as processed
                elseif category and M.spells[category] then
                    table.insert(M.spells[category], spellName)
                    assigned[spellName] = category
                end
            end
        end
    end

    -- Dynamic sizing for direct single-target heals
    local log = getLogger()
    if log then
        log.debug('autoAssign', 'Direct Heal AutoAssign: Found %d direct heals', #directHeals)
        for i, h in ipairs(directHeals) do
            log.debug('autoAssign', 'Direct Heal AutoAssign:   %d. %s (level: %d)', i, h.name, h.level)
        end
    end

    if #directHeals > 0 then
        -- Sort by spell level (ascending: lowest level = smallest heal)
        table.sort(directHeals, function(a, b) return a.level < b.level end)

        if log then
            log.debug('autoAssign', 'Direct Heal AutoAssign: After sort:')
            for i, h in ipairs(directHeals) do
                log.debug('autoAssign', 'Direct Heal AutoAssign:   %d. %s (level: %d)', i, h.name, h.level)
            end
        end

        if #directHeals == 1 then
            -- One heal: assign to medium (versatile workhorse)
            table.insert(M.spells.medium, directHeals[1].name)
            if log then log.debug('autoAssign', 'Direct Heal AutoAssign: Single heal -> medium: %s', directHeals[1].name) end
        elseif #directHeals == 2 then
            -- Two heals: smallest → small, largest → large
            table.insert(M.spells.small, directHeals[1].name)
            table.insert(M.spells.large, directHeals[2].name)
            if log then
                log.debug('autoAssign', 'Direct Heal AutoAssign: Smallest -> small: %s', directHeals[1].name)
                log.debug('autoAssign', 'Direct Heal AutoAssign: Largest -> large: %s', directHeals[2].name)
            end
        else
            -- Three+ heals: smallest → small, largest → large, middle → medium
            table.insert(M.spells.small, directHeals[1].name)
            table.insert(M.spells.large, directHeals[#directHeals].name)
            if log then
                log.debug('autoAssign', 'Direct Heal AutoAssign: Smallest -> small: %s', directHeals[1].name)
                log.debug('autoAssign', 'Direct Heal AutoAssign: Largest -> large: %s', directHeals[#directHeals].name)
            end
            -- All middle heals go to medium
            for i = 2, #directHeals - 1 do
                table.insert(M.spells.medium, directHeals[i].name)
                if log then log.debug('autoAssign', 'Direct Heal AutoAssign: Middle -> medium: %s', directHeals[i].name) end
            end
        end
    end

    -- Dynamic assignment for single-target HoTs
    -- Lower mana cost = hotLight (efficient, for low DPS)
    -- Higher mana cost = hot (stronger, for high DPS)
    if #hotHeals > 0 then
        -- Debug: Show detected HoTs before sorting
        local log = getLogger()
        if log then
            for i, h in ipairs(hotHeals) do
                log.debug('autoAssign', 'HoT AutoAssign: Detected: %s (mana: %d)', h.name, h.manaCost)
            end
        end

        -- Sort by mana cost (ascending: lowest mana = light HoT)
        table.sort(hotHeals, function(a, b) return a.manaCost < b.manaCost end)

        -- Debug: Show after sorting
        if log then
            log.debug('autoAssign', 'HoT AutoAssign: After sort: %d HoTs found', #hotHeals)
            for i, h in ipairs(hotHeals) do
                log.debug('autoAssign', 'HoT AutoAssign:   %d. %s (mana: %d)', i, h.name, h.manaCost)
            end
        end

        if #hotHeals == 1 then
            -- Only one HoT: put in hot category (can be used for both situations)
            table.insert(M.spells.hot, hotHeals[1].name)
            if log then
                log.debug('autoAssign', 'HoT AutoAssign: Single HoT -> hot: %s', hotHeals[1].name)
            end
        else
            -- Multiple HoTs: cheapest -> hotLight, most expensive -> hot
            table.insert(M.spells.hotLight, hotHeals[1].name)
            table.insert(M.spells.hot, hotHeals[#hotHeals].name)
            if log then
                log.debug('autoAssign', 'HoT AutoAssign: Cheapest -> hotLight: %s', hotHeals[1].name)
                log.debug('autoAssign', 'HoT AutoAssign: Most expensive -> hot: %s', hotHeals[#hotHeals].name)
            end
            -- Any middle HoTs also go to hot (higher tier)
            for i = 2, #hotHeals - 1 do
                table.insert(M.spells.hot, hotHeals[i].name)
                if log then
                    log.debug('autoAssign', 'HoT AutoAssign: Middle -> hot: %s', hotHeals[i].name)
                end
            end
        end
    end

    return true  -- Scan completed
end

-- Get a summary of auto-assigned spells (for UI display)
function M.getAssignmentSummary()
    local summary = {}
    local categoryLabels = {
        fast = 'Quick (Emergency)',
        small = 'Small',
        medium = 'Medium',
        large = 'Big',
        group = 'Group Heal',
        hot = 'HoT (High DPS)',
        hotLight = 'HoT (Low DPS)',
        groupHot = 'Group HoT',
        promised = 'Promised',
        selfHeal = 'Self Heal',
    }
    local categoryOrder = { 'fast', 'small', 'medium', 'large', 'group', 'hot', 'hotLight', 'groupHot', 'promised', 'selfHeal' }

    for _, category in ipairs(categoryOrder) do
        local spells = M.spells[category]
        if spells and #spells > 0 then
            table.insert(summary, {
                category = category,
                label = categoryLabels[category] or category,
                spells = spells,
            })
        end
    end

    return summary
end

local _charName = nil
local _serverName = nil

local function getCharInfo()
    if not _charName then
        _charName = mq.TLO.Me.CleanName() or 'Unknown'
    end
    if not _serverName then
        local server = mq.TLO.EverQuest.Server() or 'Unknown'
        _serverName = server:gsub(" ", "_")
    end
    return _charName, _serverName
end

local function getConfigPath()
    local char, server = getCharInfo()
    return string.format('%s/SideKick_Healing_%s_%s.lua', mq.configDir, server, char)
end

local function serializeValue(v, indent)
    indent = indent or ''
    local t = type(v)
    if t == 'string' then
        return string.format('%q', v)
    elseif t == 'number' or t == 'boolean' then
        return tostring(v)
    elseif t == 'table' then
        local parts = {}
        for k, val in pairs(v) do
            local key
            if type(k) == 'string' then
                if k:match('^[%a_][%w_]*$') then
                    key = k
                else
                    key = string.format('[%q]', k)
                end
            else
                key = string.format('[%s]', tostring(k))
            end
            table.insert(parts, string.format('%s    %s = %s,', indent, key, serializeValue(val, indent .. '    ')))
        end
        if #parts == 0 then
            return '{}'
        end
        return '{\n' .. table.concat(parts, '\n') .. '\n' .. indent .. '}'
    end
    return 'nil'
end

function M.save()
    local log = getLogger()
    local path = getConfigPath()
    local snapshot = {}
    for k, v in pairs(M) do
        if type(v) ~= 'function' then
            snapshot[k] = v
        end
    end
    local content = 'return ' .. serializeValue(snapshot) .. '\n'
    local safeWrite = require('sidekick-next.utils.safe_write')
    local ok, err = safeWrite(path, content)
    if not ok then
        if log then log.error('config', 'Failed to save config: %s', tostring(err)) end
        return false
    end
    if log then log.info('config', 'Config saved to %s', path) end
    return true
end

-- Class-specific default overrides (applied before user config)
local CLASS_DEFAULTS = {
    PAL = {
        emergencyPct = 30,       -- Slightly higher than CLR's 25 (off-healer needs headroom)
        groupHealMinCount = 2,   -- Aurora is PAL's strongest heal, use it more
        hotEnabled = false,      -- PAL has no HoTs
        selfHealEnabled = true,  -- PAL needs self-heal while tanking
        selfHealPct = 60,        -- Matches PAL config doSelfHeal condition
        healPetsEnabled = false, -- Limited heal bandwidth
    },
}

function M.applyClassDefaults()
    local me = mq.TLO.Me
    if not me or not me() then
        local log = getLogger()
        if log then log.warn('config', 'applyClassDefaults: character not available yet, skipping') end
        return
    end
    local classShort = (me.Class and me.Class.ShortName and me.Class.ShortName() or ''):upper()
    local defaults = CLASS_DEFAULTS[classShort]
    if not defaults then return end
    local log = getLogger()
    for k, v in pairs(defaults) do
        if M[k] ~= nil then
            M[k] = v
        end
    end
    if log then log.info('config', 'Applied class defaults for %s', classShort) end
end

function M.load()
    local log = getLogger()

    -- Apply class defaults first, then user config overrides them
    M.applyClassDefaults()

    local path = getConfigPath()
    local file = io.open(path, 'r')
    if not file then
        if log then log.info('config', 'No config file found, using class defaults') end
        return
    end
    local content = file:read('*a')
    file:close()
    local fn, err = load(content, path, 't', {})
    if not fn then
        if log then log.error('config', 'Config load error: %s', err) end
        return
    end
    local ok, data = pcall(fn)
    if not ok or type(data) ~= 'table' then
        if log then log.error('config', 'Config parse error') end
        return
    end
    -- Merge loaded data into M (preserving structure)
    for k, v in pairs(data) do
        if k ~= '_version' and M[k] ~= nil then
            M[k] = v
        end
    end

    -- Migration: Force new scoring weights if using old defaults
    -- Old defaults had manaEff=1.0, overheal=-1.5 which favored overhealing
    local needsMigration = false
    if M.scoringPresets and M.scoringPresets.normal then
        local normal = M.scoringPresets.normal
        -- Detect old weights: manaEff >= 1.0 and overheal > -2.0
        if (normal.manaEff or 0) >= 1.0 and (normal.overheal or 0) > -2.0 then
            needsMigration = true
        end
    end

    if needsMigration then
        if log then log.warn('config', 'Migrating scoring weights to prefer underhealing over overhealing') end
        M.scoringPresets = {
            emergency = { coverage = 4.0, manaEff = 0.1, overheal = -0.5 },
            normal = { coverage = 2.0, manaEff = 0.5, overheal = -3.0 },
            lowPressure = { coverage = 1.0, manaEff = 1.5, overheal = -4.0 },
        }
        -- Also update HoT thresholds if they're old values
        if M.hotMinDeficitPct and M.hotMinDeficitPct < 15 then
            M.hotMinDeficitPct = 20
        end
        if M.hotMaxDeficitPct and M.hotMaxDeficitPct < 30 then
            M.hotMaxDeficitPct = 35
        end
        -- Save migrated config
        M.save()
    end

    if log then log.info('config', 'Config loaded from %s', path) end
end

return M
