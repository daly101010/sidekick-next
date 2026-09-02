-- ma_healbridge.lua — headless bridge feeding sidekick-next healing intelligence
-- to a running muleassist.mac. Selection-only: the MACRO is the sole caster.
-- Launched/stopped by muleassist (SmartHealsOn); see the SmartHeals spec in
-- F:\macros\muleassist\docs\superpowers\specs\2026-09-02-smartheals-bridge-design.md
local mq = require('mq')
local Healing = require('sidekick-next.healing')
local HealerClasses = require('sidekick-next.utils.healer_classes')
local BridgeState = require('sidekick-next.utils.ma_bridge_state')

local LOOP_MS = 200
local MACRO_GONE_EXIT_MS = 10000

local function log(fmt, ...)
    print(string.format('\ag[MA-HealBridge]\ax ' .. fmt, ...))
end

local function macroRunning()
    return mq.TLO.Macro() == 'muleassist.mac'
end

local function macroVar(name)
    if not macroRunning() then return nil end
    local v = mq.TLO.Macro.Variable(name)
    return v and v() or nil
end

local function macroInt(name)
    return tonumber(macroVar(name)) or 0
end

local function macroBool(name)
    local v = macroVar(name)
    if type(v) == 'boolean' then return v end
    v = tostring(v or '')
    return v == 'TRUE' or (tonumber(v) or 0) > 0
end

local function scriptRunning(name)
    local s = mq.TLO.Lua and mq.TLO.Lua.Script(name)
    return s and s.Status and s.Status() == 'RUNNING'
end

-- ---------------------------------------------------------------- guards
if scriptRunning('sidekick-next') or scriptRunning('sidekick-next/sk_support')
    or scriptRunning('sidekick-next/sk_healing') or scriptRunning('sidekick-next/sk_start')
    or scriptRunning('sidekick-next/sk_coordinator') or scriptRunning('sidekick-next/sk_emergency') then
    log('\arRefusing to start: full SideKick is running on this character (two healing brains).')
    return
end

local myClass = mq.TLO.Me.Class and mq.TLO.Me.Class.ShortName and mq.TLO.Me.Class.ShortName() or ''
if not HealerClasses.isSupported(myClass) then
    log('\arClass %s is not supported by sidekick healing - exiting. Legacy heals remain active.', tostring(myClass))
    return
end

-- Wait briefly for muleassist (we are normally launched by it)
local waitUntil = mq.gettime() + 15000
while not macroRunning() and mq.gettime() < waitUntil do mq.delay(250) end
if not macroRunning() then
    log('\armuleassist.mac is not running - exiting.')
    return
end

-- ---------------------------------------------------------------- init
log('Initializing healing intelligence (phases 1-4, headless)...')
for phase = 1, 4 do
    Healing.initPhased(phase)
    mq.delay(50)
end
if not Healing.isInitialized() then
    log('\arHealing init failed - exiting. Legacy heals remain active.')
    return
end
-- v1: standalone. No cross-healer claims/broadcasts (spec decision).
Healing.Config.broadcastEnabled = false
Healing.Config.healPetsEnabled = macroInt('HealGroupPetsOn') > 0
log('Ready. broadcast=off healPets=%s', tostring(Healing.Config.healPetsEnabled))

-- ------------------------------------------- external targets (out-of-group)
-- TargetMonitor only scans the group. Feed the out-of-group MA and XTarHeal PC
-- slots through updateActorTargets ({id, zone, role, hp}); must run BEFORE
-- tickSensors each loop to win its 100ms throttle slot.
local function inMyGroup(id)
    local count = tonumber(mq.TLO.Group.Members()) or 0
    for i = 1, count do
        local m = mq.TLO.Group.Member(i)
        if m and m() and (tonumber(m.ID()) or 0) == id then return true end
    end
    return false
end

local function feedExternalTargets(maId)
    local feed = {}
    local myZone = mq.TLO.Zone.ShortName() or ''
    local myId = tonumber(mq.TLO.Me.ID()) or 0
    if maId > 0 and maId ~= myId and not inMyGroup(maId) then
        local spawn = mq.TLO.Spawn(maId)
        if spawn and spawn() and spawn.Type() == 'PC' then
            feed[#feed + 1] = { id = maId, zone = myZone, role = 'tank',
                hp = tonumber(spawn.PctHPs()) or 100 }
        end
    end
    local xt = tostring(macroVar('XTarHeal') or '0')
    if xt ~= '0' and xt ~= '' and xt ~= 'NULL' then
        for slotStr in xt:gmatch('[^|]+') do
            local xtarget = mq.TLO.Me.XTarget(tonumber(slotStr) or 0)
            local id = xtarget and xtarget() and tonumber(xtarget.ID()) or 0
            if id > 0 and id ~= myId and id ~= maId and not inMyGroup(id) then
                local spawn = mq.TLO.Spawn(id)
                if spawn and spawn() and spawn.Type() == 'PC' then
                    feed[#feed + 1] = { id = id, zone = myZone, role = 'dps',
                        hp = tonumber(spawn.PctHPs()) or 100 }
                end
            end
        end
    end
    if #feed > 0 and Healing.TargetMonitor and Healing.TargetMonitor.updateActorTargets then
        Healing.TargetMonitor.updateActorTargets(feed)
    end
end

-- Group scans rebuild each entry's role from class every tick, so re-apply the
-- muleassist MA as sidekick's 'tank' after every tickSensors.
local function applyTankRole(maId)
    if maId <= 0 or not Healing.TargetMonitor then return end
    local t = Healing.TargetMonitor.getTarget(maId)
    if t then t.role = 'tank' end
end

-- ------------------------------------------- HoT ledger on confirmed casts
-- The macro sets SmartHealResult then SmartHealAck after CastWhat returns.
-- Register successful HoT casts so hot_analyzer/proactive see them; direct
-- heals are already learned from the "You healed" chat events.
local lastSeenAck = 0
local publishedBySeq = {}
local function registerConfirmedCast()
    local ack = macroInt('SmartHealAck')
    if ack <= lastSeenAck then return end
    local action = publishedBySeq[ack]
    lastSeenAck = ack
    if action and action.isHoT and tostring(macroVar('SmartHealResult') or '') == 'CAST_SUCCESS' then
        local castInfo = Healing.prepareHealCast(action)
        if castInfo then Healing.registerHealCast(castInfo) end
    end
    for seq in pairs(publishedBySeq) do
        if seq <= ack then publishedBySeq[seq] = nil end
    end
end

-- ---------------------------------------------------------------- main loop
local state = BridgeState.newState()
local macroGoneSince = nil
log('Bridge loop running (%dms).', LOOP_MS)

while true do
    mq.doevents()
    if not macroRunning() then
        macroGoneSince = macroGoneSince or mq.gettime()
        if (mq.gettime() - macroGoneSince) > MACRO_GONE_EXIT_MS then
            log('muleassist stopped - exiting.')
            return
        end
    else
        macroGoneSince = nil
        local macroSeq = macroInt('SmartHealSeq')
        if macroSeq < state.seq then
            -- muleassist restarted: its outer vars reset to 0
            BridgeState.noteMacroSeq(state, macroSeq)
            lastSeenAck = macroInt('SmartHealAck')
            publishedBySeq = {}
        end
        local active = macroInt('SmartHealsOn') > 0
            and macroInt('HealsOn') > 0
            and not macroBool('BuffMode')
            and not macroBool('ZombieMode')
        local action = nil
        if active then
            local maId = macroInt('MainAssistID')
            feedExternalTargets(maId)
            Healing.tickSensors({ readOnly = true })
            applyTankRole(maId)
            registerConfirmedCast()
            action = Healing.buildHealAction({
                ignoreSpellEngine = true,
                skipIfCasting = false,
            })
        end
        local varsets = BridgeState.next(state, action, macroInt('SmartHealAck'))
        if varsets then
            publishedBySeq[state.seq] = action
            for _, pair in ipairs(varsets) do
                mq.cmdf('/varset %s %s', pair[1], pair[2])
            end
        end
        mq.cmdf('/varset SmartHealBeat %d', state.beat)
    end
    mq.delay(LOOP_MS)
end
