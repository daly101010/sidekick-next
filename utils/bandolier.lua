-- F:/lua/sidekick-next/utils/bandolier.lua
-- Conditional bandolier (weapon-set) swapping, muleassist-style.
--
-- Model: an ordered list of { name, condition } entries evaluated
-- first-match-wins each tick; the first set whose condition passes is worn.
-- An empty condition always matches, so the last entry usually acts as the
-- default/fallback set. A separate pull set is forced by the pull module
-- while it owns the character (sk_items skips normal evaluation then).
--
-- Set names must match bandolier sets created in-game (Inventory > Bandolier).

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local getConditionBuilder = lazy('sidekick-next.ui.condition_builder')
local getPaths = lazy('sidekick-next.utils.paths')
local getSafeLoad = lazy('sidekick-next.utils.safe_load')

local M = {}

M.Config = {
    sets = {},      -- array of { name = string, condition = table|nil }
    pullSet = '',   -- bandolier set forced while pulling ('' = disabled)
}

local _loadedAt = 0
local _lastActivateAt = 0
local ACTIVATE_COOLDOWN_MS = 1500
-- The UI process saves the config; worker processes (sk_items, sk_pull) must
-- notice edits without a restart, so cached config is re-read on a short TTL.
local RELOAD_TTL_MS = 5000

local function now()
    return mq.gettime()
end

--- Per-character config path, or nil while identity is unavailable (startup,
--- zoning). A nil path makes load/save no-ops: reading the wrong file would
--- present an empty config, and a save in that state would then WIPE the real
--- file the moment identity comes back.
local function configPath()
    local server, char
    pcall(function() server = mq.TLO.EverQuest.Server() end)
    pcall(function() char = mq.TLO.Me.CleanName() end)
    server = tostring(server or '')
    char = tostring(char or '')
    if server == '' or server == 'NULL' or char == '' or char == 'NULL' then
        return nil
    end
    local Paths = getPaths()
    return string.format('%s/bandolier_%s_%s.lua', Paths.getDataDir(), server, char)
end

function M.load()
    if _loadedAt > 0 and (now() - _loadedAt) < RELOAD_TTL_MS then return end
    local path = configPath()
    if not path then return end -- identity not ready; retry next call, no TTL latch
    _loadedAt = now()
    local fh = io.open(path, 'r')
    if not fh then return end -- first run: no config saved yet
    local content = fh:read('*a')
    fh:close()
    -- SafeLoad.tableLiteral takes SOURCE CONTENT, not a path.
    local SafeLoad = getSafeLoad()
    local data, err = SafeLoad.tableLiteral(content, 'bandolier')
    if type(data) == 'table' then
        if type(data.sets) == 'table' then M.Config.sets = data.sets end
        if type(data.pullSet) == 'string' then M.Config.pullSet = data.pullSet end
        if data.nextId ~= nil then M.Config.nextId = data.nextId end
    elseif err then
        print(string.format('\ay[Bandolier]\ax Config load failed: %s', tostring(err)))
    end
end

function M.save()
    local path = configPath()
    if not path then
        print('\ay[Bandolier]\ax Save skipped: character identity not available yet')
        return
    end
    local ok, err = pcall(mq.pickle, path, M.Config)
    if not ok then
        print(string.format('\ar[Bandolier]\ax Config save failed: %s', tostring(err)))
    else
        -- Saving makes the in-memory copy authoritative; push the TTL forward
        -- so this process doesn't immediately re-read its own write.
        _loadedAt = now()
    end
end

function M.getConfig()
    M.load()
    return M.Config
end

--- True when the named bandolier set is effectively worn. Prefers the
--- client's Active flag; falls back to comparing primary/secondary item ids
--- (muleassist's approach) for builds where Active is unreliable.
function M.isSetWorn(name)
    if not name or name == '' then return true end
    local band = mq.TLO.Me.Bandolier(name)
    if not (band and band()) then return true end -- unknown set: nothing to do
    local okA, active = pcall(function() return band.Active() end)
    if okA and active == true then return true end

    local function setItemId(i)
        local ok, id = pcall(function() return band.Item(i).ID() end)
        return ok and tonumber(id) or 0
    end
    local function wornId(slot)
        local ok, id = pcall(function() return mq.TLO.Me.Inventory(slot).ID() end)
        return ok and tonumber(id) or 0
    end
    local p, s = setItemId(1), setItemId(2)
    if p == 0 and s == 0 then return false end
    return (p == 0 or p == wornId('mainhand'))
        and (s == 0 or s == wornId('offhand'))
end

local _lastBlindSet = nil
local _lastBlindAt = 0
local BLIND_REISSUE_MS = 60000

--- Activate the named set if it is not already worn.
--- Returns true when an activation was issued.
function M.activateSet(name)
    if not name or name == '' then return false end
    if (now() - _lastActivateAt) < ACTIVATE_COOLDOWN_MS then return false end

    local band = mq.TLO.Me.Bandolier(name)
    local resolvable = band and band() and true or false

    if resolvable then
        if M.isSetWorn(name) then return false end
        _lastActivateAt = now()
        _lastBlindSet = nil
        pcall(function()
            require('sidekick-next.utils.action_counters').bump('weapon_swap')
        end)
        -- Direct method call on modern MQ Lua; /invoke fallback for builds
        -- where datatype methods are not callable from Lua.
        local invoked = pcall(function() band.Activate() end)
        if not invoked then
            mq.cmdf('/squelch /invoke ${Me.Bandolier[%s].Activate}', name)
        end
        return true
    end

    -- The Bandolier TLO does not populate on some emu builds. Fall back to
    -- the native client command — blind (no worn-check), so re-issue the same
    -- set at most once per BLIND_REISSUE_MS to avoid command spam.
    if _lastBlindSet == name and (now() - _lastBlindAt) < BLIND_REISSUE_MS then
        return false
    end
    _lastActivateAt = now()
    _lastBlindSet = name
    _lastBlindAt = now()
    mq.cmdf('/bandolier activate %s', name)
    return true
end

--- Forced set while pulling. Called from the pull module's own process;
--- self-throttled via the worn check and activation cooldown.
function M.activatePull()
    M.load()
    return M.activateSet(M.Config.pullSet)
end

local function conditionPasses(condition)
    if type(condition) ~= 'table'
        or type(condition.conditions) ~= 'table'
        or #condition.conditions == 0 then
        return true -- empty condition = always matches (fallback set)
    end
    local CB = getConditionBuilder()
    if not (CB and CB.evaluate) then return false end
    local ok, result = pcall(CB.evaluate, condition)
    return ok and result == true
end

--- Evaluate the conditional sets first-match-wins and wear the winner.
--- @param settings table Core settings (reads BandolierEnabled)
--- @param skip boolean|nil Skip evaluation entirely (e.g. pull owns the char)
function M.tick(settings, skip)
    if skip then return end
    if not settings or settings.BandolierEnabled ~= true then return end
    M.load()
    if #M.Config.sets == 0 then return end

    -- Never swap weapons mid-cast.
    local casting = false
    pcall(function()
        casting = mq.TLO.Me.Casting() ~= nil and (tonumber(mq.TLO.Me.Casting.ID()) or 0) > 0
    end)
    if casting then return end

    for _, set in ipairs(M.Config.sets) do
        if set and set.name and set.name ~= '' and conditionPasses(set.condition) then
            M.activateSet(set.name)
            return
        end
    end
end

--- Console dump of the full decision chain, for /sk_bando.
function M.debugDump(settings, skip)
    _loadedAt = 0 -- force a fresh read so the dump reflects disk truth
    M.load()
    local path = configPath()
    local exists, size = false, 0
    if path then
        local fh = io.open(path, 'r')
        if fh then
            exists = true
            size = fh:seek('end') or 0
            fh:close()
        end
    end
    print(string.format('\ag[Bandolier]\ax path=%s exists=%s size=%d',
        tostring(path or '<identity unavailable>'), tostring(exists), size))
    print(string.format('\ag[Bandolier]\ax enabled=%s skip=%s sets=%d pullSet=%s',
        tostring(settings and settings.BandolierEnabled == true),
        tostring(skip == true), #M.Config.sets, tostring(M.Config.pullSet or '')))
    for i, set in ipairs(M.Config.sets) do
        local name = tostring(set.name or '?')
        local band = mq.TLO.Me.Bandolier(name)
        local resolvable = band and band() and true or false
        print(string.format('\ag[Bandolier]\ax set%d name=%s condition=%s worn=%s tloResolves=%s',
            i, name, tostring(conditionPasses(set.condition)),
            tostring(resolvable and M.isSetWorn(name) or 'n/a'), tostring(resolvable)))
    end
end

return M
