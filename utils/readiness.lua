-- utils/readiness.lua
-- Group Readiness Coordinator - answers "is the group ready to pull?" between
-- fights, using the actors status payloads that sidekick-next members already
-- broadcast (hp/mana/endur/class/zone).
--
-- Important: the puller is often NOT running sidekick-next (e.g. a bard on
-- Medley). Members without actor data are simply ignored - they can't block
-- readiness - and the READY/NOT READY signal is announced in group chat so a
-- human puller sees it without any integration.

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

M.state = {
    ready = false,
    members = {},      -- name -> { ready, hp, mana, endur, class, reason }
    lastChange = 0,
    lastAnnounce = 0,
}

local _lastTick = 0
local TICK_MS = 1000
local ANNOUNCE_COOLDOWN_MS = 8000

local getCore = lazy('sidekick-next.utils.core')
local getActors = lazy('sidekick-next.utils.actors_coordinator')
local Roles = require('sidekick-next.utils.class_roles')

local PURE_CASTERS = Roles.PURE_CASTERS
local HYBRIDS = Roles.HYBRID_MELEE

local function getSettings()
    local Core = getCore()
    return (Core and Core.Settings) or {}
end

--- Evaluate one member's readiness from vitals
-- @return boolean ready, string reason
local function evaluate(class, hp, mana, endur, settings)
    hp = tonumber(hp) or 0
    mana = tonumber(mana) or 100
    endur = tonumber(endur) or 100
    class = tostring(class or '')

    local hpMin = tonumber(settings.ReadyHpPct) or 90
    local manaMin = tonumber(settings.ReadyManaPct) or 80
    local endMin = tonumber(settings.ReadyEndPct) or 50

    if hp < hpMin then
        return false, string.format('hp %d%% < %d%%', hp, hpMin)
    end

    if PURE_CASTERS[class] then
        if mana < manaMin then
            return false, string.format('mana %d%% < %d%%', mana, manaMin)
        end
    elseif HYBRIDS[class] then
        local hybridMin = math.floor(manaMin / 2)
        if mana < hybridMin then
            return false, string.format('mana %d%% < %d%%', mana, hybridMin)
        end
    else
        if endur < endMin then
            return false, string.format('end %d%% < %d%%', endur, endMin)
        end
    end

    return true, 'ready'
end

--- Should I be the one announcing? (exactly one announcer per group: the
-- alphabetically-first sidekick member in zone, so three boxes don't spam)
local function iAmAnnouncer(memberNames, myName)
    local names = { myName }
    for name in pairs(memberNames) do
        if name ~= myName then table.insert(names, name) end
    end
    table.sort(names)
    return names[1] == myName
end

function M.tick()
    local settings = getSettings()
    if settings.ReadinessEnabled ~= true then return end
    if settings.ActorsEnabled == false then return end

    local now = mq.gettime()
    if (now - _lastTick) < TICK_MS then return end
    _lastTick = now

    local members = {}

    -- Me
    local myName, myClass, inCombat = 'Me', '', false
    local okMe = pcall(function()
        local me = mq.TLO.Me
        myName = me.CleanName() or 'Me'
        myClass = (me.Class and me.Class.ShortName and me.Class.ShortName()) or ''
        inCombat = tostring(me.CombatState() or '') == 'COMBAT'
        local ready, reason = evaluate(myClass,
            tonumber(me.PctHPs()), tonumber(me.PctMana()), tonumber(me.PctEndurance()), settings)
        members[myName] = {
            ready = ready, reason = reason, class = myClass,
            hp = tonumber(me.PctHPs()) or 0, mana = tonumber(me.PctMana()) or 0,
        }
    end)
    if not okMe then return end

    -- Peers (sidekick-next members broadcasting status in my zone).
    -- Group members WITHOUT actor data (e.g. a bard puller on Medley) simply
    -- don't appear here and never block readiness.
    local myZone = tostring(mq.TLO.Zone.ShortName() or '')
    local Actors = getActors()
    if Actors and Actors.getRemoteCharacters then
        local okPeers, peers = pcall(Actors.getRemoteCharacters)
        if okPeers and type(peers) == 'table' then
            for name, data in pairs(peers) do
                if tostring(data.zone or '') == myZone then
                    local ready, reason = evaluate(data.class, data.hp, data.mana, data.endur, settings)
                    members[name] = {
                        ready = ready, reason = reason, class = tostring(data.class or ''),
                        hp = tonumber(data.hp) or 0, mana = tonumber(data.mana) or 0,
                    }
                end
            end
        end
    end

    -- Aggregate
    local allReady = true
    local notReady = {}
    for name, m in pairs(members) do
        if not m.ready then
            allReady = false
            table.insert(notReady, string.format('%s (%s)', name, m.reason))
        end
    end

    local wasReady = M.state.ready
    M.state.members = members
    M.state.ready = allReady
    if allReady ~= wasReady then
        M.state.lastChange = now

        -- Announce transitions in group chat (for the human puller), out of
        -- combat only, one announcer per group, cooldown against flapping
        if settings.ReadinessAnnounce ~= false and not inCombat
            and iAmAnnouncer(members, myName)
            and (now - M.state.lastAnnounce) >= ANNOUNCE_COOLDOWN_MS then
            M.state.lastAnnounce = now
            if allReady then
                mq.cmd('/g << READY to pull >>')
            else
                table.sort(notReady)
                mq.cmdf('/g << NOT ready: %s >>', table.concat(notReady, ', '))
            end
        end
    end
end

--- Get the current readiness snapshot
function M.getGroupReadiness()
    return M.state.ready, M.state.members
end

function M.printStatus()
    local settings = getSettings()
    if settings.ReadinessEnabled ~= true then
        print('\ay[Ready]\ax Readiness coordinator disabled (ReadinessEnabled)')
        return
    end
    print(string.format('\ag[Ready]\ax Group %s', M.state.ready and 'READY' or 'NOT READY'))
    local names = {}
    for name in pairs(M.state.members) do table.insert(names, name) end
    table.sort(names)
    for _, name in ipairs(names) do
        local m = M.state.members[name]
        print(string.format('\ag[Ready]\ax   %-18s %-3s hp %3d%% mana %3d%% - %s',
            name, m.class, m.hp, m.mana, m.ready and 'ready' or m.reason))
    end
end

return M
