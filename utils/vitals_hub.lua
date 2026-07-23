--- Vitals hub publisher (tank-side).
--- One character (the tank) aggregates the whole group's vitals from its own
--- Group.Member TLOs — this covers members NOT running sidekick (Medley bard)
--- — and publishes a single consolidated `vitals:group` message for UI
--- consumers (GroupTarget HUD, eq_ui_rebuild_classic). Healers deliberately
--- do NOT consume this feed: actor relay latency is too high for emergency
--- heal decisions.
---
--- Contract v1: see docs/plans/2026-07-23-vitals-hub.md. The message is the
--- interface — this publisher can later move to a standalone hub script
--- without touching consumers.
local mq = require('mq')

local M = {}

local SEND_MIN_INTERVAL = 0.2   -- 5Hz cap
local HEARTBEAT_SEC = 2.0       -- force a resend even when nothing changed

local _lastSendAt = 0
local _lastMembers = nil
local _seq = 0

local function safeNum(fn, default)
    local ok, v = pcall(fn)
    if ok then v = tonumber(v) else v = nil end
    return v or default
end

local function safeBool(fn)
    local ok, v = pcall(fn)
    return ok and v == true
end

local function safeStr(fn)
    local ok, v = pcall(fn)
    if ok and v ~= nil then return tostring(v) end
    return ''
end

--- Build the members table (publisher included). Returns nil when not
--- meaningfully grouped (0 other members) — solo publishing is pure noise.
function M.buildMembers()
    local me = mq.TLO.Me
    if not me or not me() then return nil end
    local myName = safeStr(function() return me.CleanName() end)
    if myName == '' then return nil end

    local count = safeNum(function() return mq.TLO.Group.Members() end, 0)
    if count <= 0 then return nil end

    local members = {}
    members[myName] = {
        id = safeNum(function() return me.ID() end, 0),
        level = safeNum(function() return me.Level() end, 0),
        class = safeStr(function() return me.Class.ShortName() end):upper(),
        hp = safeNum(function() return me.PctHPs() end, 0),
        mana = safeNum(function() return me.PctMana() end, 0),
        endur = safeNum(function() return me.PctEndurance() end, 0),
        petHp = safeNum(function() return mq.TLO.Pet.PctHPs() end, 0),
        dead = safeBool(function() return me.Dead() end),
        sitting = safeBool(function() return me.Sitting() end),
        casting = safeStr(function() return me.Casting() end),
        present = true,
    }

    for i = 1, count do
        local mem = mq.TLO.Group.Member(i)
        if mem and mem() then
            local name = safeStr(function() return mem.Name() end)
            if name ~= '' then
                local present = safeBool(function() return mem.Present() end)
                local m = {
                    id = safeNum(function() return mem.ID() end, 0),
                    level = safeNum(function() return mem.Level() end, 0),
                    class = safeStr(function() return mem.Class.ShortName() end):upper(),
                    present = present,
                }
                if present then
                    m.hp = safeNum(function() return mem.PctHPs() end, 0)
                    m.mana = safeNum(function() return mem.PctMana() end, 0)
                    m.endur = safeNum(function() return mem.PctEndurance() end, 0)
                    m.petHp = safeNum(function() return mem.Pet.PctHPs() end, 0)
                    m.dead = safeBool(function() return mem.Dead() end)
                    m.sitting = safeBool(function() return mem.Sitting() end)
                end
                members[name] = m
            end
        end
    end
    return members
end

-- Fields that trigger a resend when they change. `casting` is deliberately
-- excluded: self-cast churn would defeat the change-dedup.
local WATCH = { 'hp', 'mana', 'endur', 'petHp', 'dead', 'sitting', 'level', 'id', 'present' }

function M.membersChanged(a, b)
    if not b then return true end
    for name, m in pairs(a) do
        local o = b[name]
        if not o then return true end
        for _, k in ipairs(WATCH) do
            if m[k] ~= o[k] then return true end
        end
    end
    for name in pairs(b) do
        if not a[name] then return true end
    end
    return false
end

--- Main-loop tick. Publishes only when this character is the designated
--- tank (CombatMode == 'tank') and VitalsHubEnabled is on.
function M.tick()
    local okCore, Core = pcall(require, 'sidekick-next.utils.core')
    if not okCore or not Core then return end
    local S = Core.Settings or {}
    if S.VitalsHubEnabled == false then return end
    if tostring(S.CombatMode or 'off'):lower() ~= 'tank' then return end

    local now = os.clock()
    if (now - _lastSendAt) < SEND_MIN_INTERVAL then return end

    local members = M.buildMembers()
    if not members then return end

    local heartbeatDue = (now - _lastSendAt) >= HEARTBEAT_SEC
    if not heartbeatDue and not M.membersChanged(members, _lastMembers) then
        return
    end

    local okAct, Actors = pcall(require, 'sidekick-next.utils.actors_coordinator')
    if not okAct or not Actors or not Actors.sendVitalsGroup then return end

    _lastSendAt = now
    _lastMembers = members
    _seq = _seq + 1

    Actors.sendVitalsGroup({
        id = 'vitals:group',
        v = 1,
        seq = _seq,
        zone = safeStr(function() return mq.TLO.Zone.ShortName() end),
        members = members,
    })
end

return M
