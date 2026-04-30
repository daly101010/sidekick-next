-- automation/pull.lua
-- Ported from rgmercs/modules/pull.lua. Normal + Chain modes only.
-- Hunt and Farm omitted by design.
--
-- Public API:
--   M.init(opts)               -- one-time setup (Core, Settings reference)
--   M.start()                  -- enable pulling
--   M.stop()                   -- disable pulling
--   M.tick()                   -- call from main loop (drives state machine)
--   M.deny(name) / allow(name) / clearIgnore()
--   M.pullCurrentTarget()      -- one-shot pull on the user's current target
--   M.getState() / M.getStateText()
--
-- Settings live in Core.Settings under the 'Pull_' prefix; persistence is
-- handled by Core.set the same way humanize does it.

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local Scan      = require('sidekick-next.automation.pull.scan')
local Abilities = require('sidekick-next.automation.pull.abilities')

local getCore     = lazy.once('sidekick-next.utils.core')
local getSkLib    = lazy.once('sidekick-next.sk_lib')
local getHumanize = lazy.once('sidekick-next.humanize')
local getChase    = lazy.once('sidekick-next.automation.chase')

local M = {}

-- States ----------------------------------------------------------------------

M.STATES = {
    IDLE          = 'IDLE',
    SCAN          = 'SCAN',
    NAV_TO_TARGET = 'NAV_TO_TARGET',
    PULLING       = 'PULLING',
    RETURN_CAMP   = 'RETURN_CAMP',
    WAITING_MOB   = 'WAITING_MOB',
    WAITING_GATE  = 'WAITING_GATE',
}

local STATE_TEXT = {
    IDLE          = 'Idle',
    SCAN          = 'Scanning',
    NAV_TO_TARGET = 'Naving to target',
    PULLING       = 'Pulling',
    RETURN_CAMP   = 'Returning to camp',
    WAITING_MOB   = 'Waiting on mob',
    WAITING_GATE  = 'Gate failed; waiting',
}

M.MODES = { 'Normal', 'Chain' }

-- Defaults --------------------------------------------------------------------

local DEFAULT = {
    enabled            = false,
    mode               = 'Normal',
    ability            = 'AutoAttack',
    pullItemName       = '',

    pullRadius         = 200,
    pullZRadius        = 100,
    pullDelaySec       = 5,
    chainCount         = 2,
    maxMoveTimeSec     = 30,
    maxPathRange       = 0,        -- 0 = use PathExists only
    autoCampRadius     = 25,
    pullBackwards      = false,

    -- safety gates
    pullHpPct          = 75,
    pullManaPct        = 30,
    pullEndPct         = 25,
    pullBuffCount      = 0,
    pullDebuffed       = false,    -- true = ignore root/snare/disease/etc
    pullMobsInWater    = false,
    pullRespectMedState= true,

    -- target filter
    useLevels          = false,
    minLevel           = 1,
    maxLevel           = 999,
    minCon             = 2,        -- GREEN
    maxCon             = 7,        -- RED
    maxLevelDiff       = 3,

    -- lists
    allowList          = {},
    denyList           = {},
    safeZones          = { 'poknowledge','neighborhood','guildhall','guildlobby','bazaar','nexus' },
}

-- State -----------------------------------------------------------------------

local State = {
    pullState        = M.STATES.IDLE,
    pullStateReason  = '',
    pullId           = 0,
    pullStartedAtMs  = 0,
    lastPullEndedMs  = 0,
    campX            = 0,
    campY            = 0,
    campZ            = 0,
    campSet          = false,
    ignoreUntilMs    = {},  -- [spawnId] = expireMs
    pausedManually   = false,
    initialized      = false,
}

-- Config bridge ---------------------------------------------------------------

local Config = {}

local function settings()
    local Core = getCore()
    return Core and Core.Settings or {}
end

local function settingPrefix(k) return 'Pull_' .. k end

local function loadFromSettings()
    -- Pull values from Core.Settings; fall back to DEFAULT.
    local s = settings()
    for k, def in pairs(DEFAULT) do
        local raw = s[settingPrefix(k)]
        if raw == nil then
            Config[k] = def
        elseif type(def) == 'boolean' then
            Config[k] = (raw == true or raw == 'true' or raw == '1' or raw == 1)
        elseif type(def) == 'number' then
            Config[k] = tonumber(raw) or def
        elseif type(def) == 'table' then
            -- Lists are stored as comma-joined strings via persistList.
            if type(raw) == 'string' and raw ~= '' then
                local out = {}
                for w in string.gmatch(raw, '[^,]+') do
                    w = w:match('^%s*(.-)%s*$')
                    if w and w ~= '' then table.insert(out, w) end
                end
                Config[k] = out
            else
                Config[k] = def
            end
        else
            Config[k] = raw
        end
    end
end

local function persist(k, v)
    Config[k] = v
    local Core = getCore()
    if Core and Core.set then
        if type(v) == 'table' then
            Core.set(settingPrefix(k), table.concat(v, ','))
        else
            Core.set(settingPrefix(k), v)
        end
    end
end

-- Helpers ---------------------------------------------------------------------

local function nowMs() return mq.gettime() or 0 end

local function setState(s, reason)
    State.pullState = s
    State.pullStateReason = reason or ''
end

local function abort(reason)
    setState(M.STATES.IDLE, reason or 'aborted')
    State.pullId = 0
end

local function meSafe()
    local me = mq.TLO.Me
    return me and me() ~= nil
end

local function isCasting()
    local lib = getSkLib()
    if lib and lib.isCasting then
        local ok, v = pcall(lib.isCasting); if ok then return v end
    end
    local s = mq.TLO.Me.Casting() or ''
    return s ~= '' and s ~= 'NULL'
end

local function xtHaterCount()
    local me = mq.TLO.Me
    if not (me and me()) then return 0 end
    local n = me.XTarget() or 0
    local c = 0
    for i = 1, n do
        local x = me.XTarget(i)
        if x and x() and x.ID and x.ID() and x.ID() > 0 then c = c + 1 end
    end
    return c
end

local function isInCombat()
    local lib = getSkLib()
    if lib and lib.inCombat then
        local ok, v = pcall(lib.inCombat); if ok then return v == true end
    end
    return xtHaterCount() > 0
end

local function isCurrentZoneSafe()
    local zoneShort = mq.TLO.Zone and mq.TLO.Zone.ShortName and mq.TLO.Zone.ShortName() or ''
    zoneShort = string.lower(zoneShort)
    for _, z in ipairs(Config.safeZones or {}) do
        if string.lower(tostring(z)) == zoneShort then return true end
    end
    return false
end

local function spawnDist(id)
    local sp = mq.TLO.Spawn(id)
    if not (sp and sp() and sp.ID() == id) then return 99999 end
    local me = mq.TLO.Me
    local mx, my, mz = me.X() or 0, me.Y() or 0, me.Z() or 0
    local sx, sy, sz = sp.X() or 0, sp.Y() or 0, sp.Z() or 0
    local dx, dy, dz = mx - sx, my - sy, mz - sz
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

-- Pre-flight checks (ShouldPull) ----------------------------------------------

local function shouldPull()
    if not Config.enabled or State.pausedManually then return false, 'disabled' end
    if not meSafe() then return false, 'no_me' end
    if isCurrentZoneSafe() then return false, 'safe_zone' end

    local me = mq.TLO.Me
    if isCasting() then return false, 'casting' end

    local hpp = me.PctHPs() or 100
    if hpp < (Config.pullHpPct or 0) then return false, 'low_hp' end

    local endp = me.PctEndurance() or 100
    if endp < (Config.pullEndPct or 0) then return false, 'low_end' end

    local maxMana = me.MaxMana() or 0
    if maxMana > 0 then
        local mp = me.PctMana() or 100
        if mp < (Config.pullManaPct or 0) then return false, 'low_mana' end
    end

    if me.Buff and me.Buff('Resurrection Sickness') and me.Buff('Resurrection Sickness').ID and me.Buff('Resurrection Sickness').ID() then
        return false, 'rez_sick'
    end

    if me.Rooted and me.Rooted.ID and (me.Rooted.ID() or 0) > 0 then return false, 'rooted' end

    if not Config.pullDebuffed then
        if me.Snared and me.Snared.ID and (me.Snared.ID() or 0) > 0 then return false, 'snared' end
        if me.Poisoned and me.Poisoned.ID and (me.Poisoned.ID() or 0) > 0 then return false, 'poisoned' end
        if me.Diseased and me.Diseased.ID and (me.Diseased.ID() or 0) > 0 then return false, 'diseased' end
        if me.Cursed and me.Cursed.ID and (me.Cursed.ID() or 0) > 0 then return false, 'cursed' end
    end

    if (Config.pullBuffCount or 0) > 0 then
        local cur = me.BuffCount() or 0
        if cur < Config.pullBuffCount then return false, 'low_buff_count' end
    end

    if Config.mode == 'Chain' then
        if xtHaterCount() >= (Config.chainCount or 2) then return false, 'chain_full' end
    else
        if xtHaterCount() > 0 then return false, 'in_combat' end
    end

    return true
end

-- Camp -----------------------------------------------------------------------

local function setCampHere()
    if not meSafe() then return end
    local me = mq.TLO.Me
    State.campX = me.X() or 0
    State.campY = me.Y() or 0
    State.campZ = me.Z() or 0
    State.campSet = true
end

local function navStop()
    mq.cmd('/squelch /nav stop')
end

local function navToTargetId(id, range, requireLOS)
    local los = requireLOS and 'on' or 'off'
    mq.cmdf('/nav id %d distance=%d lineofsight=%s log=off', id, range or 30, los)
end

local function navToCamp()
    if not State.campSet then return end
    local face = Config.pullBackwards and 'facing=backward' or ''
    mq.cmdf('/nav locyxz %.2f %.2f %.2f %s log=off',
        State.campY, State.campX, State.campZ, face)
end

local function navActive()
    if mq.TLO.Nav and mq.TLO.Nav.Active and mq.TLO.Nav.Active() then return true end
    if mq.TLO.Navigation and mq.TLO.Navigation.Active and mq.TLO.Navigation.Active() then return true end
    return false
end

local function distToCamp()
    if not State.campSet or not meSafe() then return 99999 end
    local me = mq.TLO.Me
    local dx, dy, dz = (me.X() or 0) - State.campX, (me.Y() or 0) - State.campY, (me.Z() or 0) - State.campZ
    return math.sqrt(dx*dx + dy*dy + dz*dz)
end

-- State handlers --------------------------------------------------------------

local function tick_IDLE()
    if not Config.enabled then return end
    if (nowMs() - State.lastPullEndedMs) < (Config.pullDelaySec or 5) * 1000 then return end

    -- Chain mode permits pulling while in combat (up to chainCount). Normal must be downtime.
    if Config.mode ~= 'Chain' and isInCombat() then return end

    local ok, why = shouldPull()
    if not ok then
        setState(M.STATES.WAITING_GATE, why)
        return
    end

    if not State.campSet then setCampHere() end
    setState(M.STATES.SCAN, '')
end

local function tick_SCAN()
    local res = Scan.scan({
        checkX = State.campX, checkY = State.campY, checkZ = State.campZ,
        pullRadius = Config.pullRadius,
        pullZRadius = Config.pullZRadius,
        useLevels = Config.useLevels,
        minLevel = Config.minLevel, maxLevel = Config.maxLevel,
        minCon = Config.minCon, maxCon = Config.maxCon,
        maxLevelDiff = Config.maxLevelDiff,
        allowList = Config.allowList, denyList = Config.denyList,
        ignoreSet = State.ignoreUntilMs,
        pullMobsInWater = Config.pullMobsInWater,
        maxPathRange = Config.maxPathRange,
        skipXTHaters = Config.mode == 'Chain',
    })

    if #res.sortedIds == 0 then
        setState(M.STATES.IDLE, 'no_target')
        return
    end

    State.pullId = res.sortedIds[1]
    State.pullStartedAtMs = nowMs()

    local def = Abilities.getById(Config.ability) or Abilities.getById('AutoAttack')
    local range = Abilities.rangeOf(def)
    if range <= 0 then range = 30 end

    -- Stand + nav
    if mq.TLO.Me.Sitting and mq.TLO.Me.Sitting() then mq.cmd('/stand') end
    mq.cmd('/attack off')
    navToTargetId(State.pullId, range, false)
    setState(M.STATES.NAV_TO_TARGET, '')
end

local function chainAbortConditions()
    local count = xtHaterCount()
    if Config.mode == 'Chain' then
        if count >= (Config.chainCount or 2) then return true, 'chain_cap' end
    else
        if count > 0 then return true, 'engaged' end
    end
    return false
end

local function tick_NAV_TO_TARGET()
    -- Timeouts and abort conditions
    if (nowMs() - State.pullStartedAtMs) > (Config.maxMoveTimeSec or 30) * 1000 then
        navStop()
        State.ignoreUntilMs[State.pullId] = nowMs() + 30 * 1000
        abort('nav_timeout')
        return
    end

    local stop, reason = chainAbortConditions()
    if stop then
        navStop()
        State.ignoreUntilMs[State.pullId] = nowMs() + 60 * 1000
        setState(M.STATES.RETURN_CAMP, reason)
        navToCamp()
        return
    end

    -- Validate target still exists
    local sp = mq.TLO.Spawn(State.pullId)
    if not (sp and sp() and sp.ID() == State.pullId) then
        navStop(); abort('target_gone'); return
    end

    -- Are we close enough?
    local def = Abilities.getById(Config.ability) or Abilities.getById('AutoAttack')
    local range = Abilities.rangeOf(def)
    if range <= 0 then range = 30 end
    local d = spawnDist(State.pullId)

    if d <= range then
        navStop()
        -- Acquire target
        if (mq.TLO.Target.ID() or 0) ~= State.pullId then
            mq.cmdf('/target id %d', State.pullId)
        end
        setState(M.STATES.PULLING, '')
        State.pullStartedAtMs = nowMs()
    end
end

local function tick_PULLING()
    -- Fire ability once we're in range and targeting.
    local tid = mq.TLO.Target.ID() or 0
    if tid ~= State.pullId then
        mq.cmdf('/target id %d', State.pullId)
        return
    end

    local def = Abilities.getById(Config.ability) or Abilities.getById('AutoAttack')
    if not def then abort('no_ability'); return end

    -- Optional humanize gate: small delay before issuing the pull command.
    local H = getHumanize()
    if H and H.gate then
        local d = H.gate('ability', { kind = 'pull', target = State.pullId })
        if d == H.SKIP then
            -- Skip this tick; will retry next iteration.
            return
        end
        if d and d > 0 then mq.delay(d) end
    end

    local ctx = { cfg = Config }
    local ok, fired = pcall(def.execute, State.pullId, ctx)
    if not ok or fired == false then
        abort('exec_failed'); return
    end

    -- Wait briefly for the mob to register on xtarget.
    setState(M.STATES.RETURN_CAMP, 'pulled')
    State.pullStartedAtMs = nowMs()

    -- Disengage from melee/auto attack while heading back.
    if def.id == 'AutoAttack' then mq.cmd('/attack off') end

    -- For pet pulls, bring pet back.
    if def.id == 'PetPull' then
        mq.delay(500)
        mq.cmd('/pet back off')
        mq.delay(100)
        mq.cmd('/pet follow')
    end

    navToCamp()
end

local function tick_RETURN_CAMP()
    if (nowMs() - State.pullStartedAtMs) > (Config.maxMoveTimeSec or 30) * 1000 then
        navStop()
        setState(M.STATES.WAITING_MOB, 'rtc_timeout')
        State.pullStartedAtMs = nowMs()
        return
    end
    if distToCamp() <= (Config.autoCampRadius or 25) then
        navStop()
        setState(M.STATES.WAITING_MOB, 'arrived')
        State.pullStartedAtMs = nowMs()
    end
end

local function tick_WAITING_MOB()
    -- Wait up to 120s for the pulled mob to reach camp / engage.
    if (nowMs() - State.pullStartedAtMs) > 120 * 1000 then
        State.lastPullEndedMs = nowMs()
        State.pullId = 0
        setState(M.STATES.IDLE, 'mob_lost')
        return
    end

    -- If a hater is in range or already in combat, pull is complete.
    if xtHaterCount() > 0 then
        State.lastPullEndedMs = nowMs()
        State.pullId = 0
        setState(M.STATES.IDLE, 'engaged')
        return
    end

    -- If specific target despawned, give up.
    local sp = mq.TLO.Spawn(State.pullId)
    if not (sp and sp() and sp.ID() == State.pullId) then
        State.lastPullEndedMs = nowMs()
        State.pullId = 0
        setState(M.STATES.IDLE, 'target_gone')
    end
end

local function tick_WAITING_GATE()
    -- Periodically retry the gate.
    if (nowMs() - (State.lastGateAt or 0)) > 1000 then
        State.lastGateAt = nowMs()
        local ok = shouldPull()
        if ok then setState(M.STATES.IDLE, '') end
    end
end

-- Public API ------------------------------------------------------------------

function M.init(opts)
    if State.initialized then return end
    State.initialized = true
    loadFromSettings()
end

function M.start()
    persist('enabled', true)
    State.pausedManually = false
    setCampHere()
    setState(M.STATES.IDLE, 'started')
    printf('\at[Pull]\ax start mode=%s ability=%s', Config.mode, Config.ability)
end

function M.stop()
    persist('enabled', false)
    State.pausedManually = true
    navStop()
    setState(M.STATES.IDLE, 'stopped')
    printf('\at[Pull]\ax stop')
end

function M.pullCurrentTarget()
    local tid = mq.TLO.Target.ID() or 0
    if tid <= 0 then printf('\ar[Pull]\ax no target'); return end
    if not State.campSet then setCampHere() end
    State.pullId = tid
    State.pullStartedAtMs = nowMs()
    local def = Abilities.getById(Config.ability) or Abilities.getById('AutoAttack')
    local range = Abilities.rangeOf(def)
    if range <= 0 then range = 30 end
    if mq.TLO.Me.Sitting and mq.TLO.Me.Sitting() then mq.cmd('/stand') end
    mq.cmd('/attack off')
    navToTargetId(tid, range, false)
    setState(M.STATES.NAV_TO_TARGET, 'manual')
end

function M.deny(name)
    if not name or name == '' then return end
    local list = Config.denyList or {}
    for _, n in ipairs(list) do if string.lower(n) == string.lower(name) then return end end
    table.insert(list, name)
    persist('denyList', list)
    printf('\at[Pull]\ax deny += %s', name)
end

function M.allow(name)
    if not name or name == '' then return end
    local list = Config.allowList or {}
    for _, n in ipairs(list) do if string.lower(n) == string.lower(name) then return end end
    table.insert(list, name)
    persist('allowList', list)
    printf('\at[Pull]\ax allow += %s', name)
end

function M.clearIgnore()
    State.ignoreUntilMs = {}
    printf('\at[Pull]\ax cleared ignore list')
end

function M.getState()
    return {
        state = State.pullState,
        reason = State.pullStateReason,
        pullId = State.pullId,
        config = Config,
        campSet = State.campSet,
    }
end

function M.getStateText()
    return STATE_TEXT[State.pullState] or State.pullState
end

function M.getConfig() return Config end
function M.persistKnob(key, value) persist(key, value) end

-- Tick driver -----------------------------------------------------------------

function M.tick()
    if not State.initialized then M.init() end
    if not Config.enabled and State.pullState == M.STATES.IDLE then return end

    local s = State.pullState
    if     s == M.STATES.IDLE          then tick_IDLE()
    elseif s == M.STATES.SCAN          then tick_SCAN()
    elseif s == M.STATES.NAV_TO_TARGET then tick_NAV_TO_TARGET()
    elseif s == M.STATES.PULLING       then tick_PULLING()
    elseif s == M.STATES.RETURN_CAMP   then tick_RETURN_CAMP()
    elseif s == M.STATES.WAITING_MOB   then tick_WAITING_MOB()
    elseif s == M.STATES.WAITING_GATE  then tick_WAITING_GATE()
    end
end

-- Slash binds -----------------------------------------------------------------

local function bindOnce(name, fn)
    if not (mq and mq.bind) then return end
    if mq.unbind then pcall(mq.unbind, name) end
    pcall(mq.bind, name, fn)
end

bindOnce('/sk_pull', function(sub, arg, arg2)
    sub = (sub or 'status'):lower()
    if sub == 'start' or sub == 'on' then M.start()
    elseif sub == 'stop' or sub == 'off' then M.stop()
    elseif sub == 'pulltarget' then M.pullCurrentTarget()
    elseif sub == 'deny' then M.deny(arg)
    elseif sub == 'allow' then M.allow(arg)
    elseif sub == 'clearignore' then M.clearIgnore()
    elseif sub == 'mode' then
        if arg == 'Normal' or arg == 'Chain' then persist('mode', arg) end
        printf('\at[Pull]\ax mode=%s', Config.mode)
    elseif sub == 'ability' then
        if arg and arg ~= '' then persist('ability', arg) end
        printf('\at[Pull]\ax ability=%s', Config.ability)
    elseif sub == 'camp' then
        setCampHere()
        printf('\at[Pull]\ax camp set: %.0f, %.0f, %.0f', State.campX, State.campY, State.campZ)
    elseif sub == 'status' then
        printf('\at[Pull]\ax state=%s reason=%s mode=%s ability=%s id=%d enabled=%s',
            State.pullState, State.pullStateReason, Config.mode, Config.ability,
            State.pullId, tostring(Config.enabled))
    else
        printf('\at[Pull]\ax usage: /sk_pull start|stop|pulltarget|deny <name>|allow <name>|' ..
            'clearignore|mode <Normal|Chain>|ability <id>|camp|status')
    end
end)

return M
