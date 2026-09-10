-- ma_healbridge.lua — headless bridge feeding sidekick-next healing intelligence
-- to a running muleassist.mac. Selection-only: the MACRO is the sole caster.
-- Launched/stopped by muleassist (SmartHealsOn); see the SmartHeals spec in
-- F:\macros\muleassist\docs\superpowers\specs\2026-09-02-smartheals-bridge-design.md
local mq = require('mq')
local Healing = require('sidekick-next.healing')
local HealerClasses = require('sidekick-next.utils.healer_classes')
local BridgeState = require('sidekick-next.utils.ma_bridge_state')
local HealLog = require('sidekick-next.healing.logger')
local actorsOk, actors = pcall(require, 'actors')
-- Forward-declared: registerConfirmedCast and vetoHot (below) call shSend
-- before its definition further down (which sits just above the main loop),
-- and a plain `local function shSend` there would leave those earlier call
-- sites resolving to an unrelated global. Assigned, not redeclared, later.
local shSend

local LOOP_MS = 200
local MACRO_GONE_EXIT_MS = 10000

local function log(fmt, ...)
    print(string.format('\ag[MA-HealBridge]\ax ' .. fmt, ...))
end

-- 'Running' means the macro has reached its SmartHeals declare block, not merely started:
-- a bridge that outlives a macro restart would otherwise /varset SmartHealBeat during LoadIni
-- (hundreds of lines before the declare) and spam 'variable not found'.
local function macroRunning()
    if mq.TLO.Macro() ~= 'muleassist.mac' then return false end
    local d = mq.TLO.Defined('SmartHealBeat')
    return d ~= nil and d() == true
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
-- 13k+ HOT_DECISION blocks per hour and nothing in the bridge acts on them
if Healing.Config.logCategories then Healing.Config.logCategories.hotCoverage = false end
-- Spell assignment happens before the file logger opens, so echo it here (diagnostic).
for _, cat in ipairs({ 'fast', 'small', 'medium', 'large', 'group', 'hot', 'hotLight', 'groupHot', 'promised', 'selfHeal' }) do
    local list = Healing.Config.spells and Healing.Config.spells[cat] or {}
    if #list > 0 then log('  %s: %s', cat, table.concat(list, ', ')) end
end
if not (Healing.Config.HasConfiguredSpells and Healing.Config.HasConfiguredSpells()) then
    log('rNo heal spells were assigned from the spell bar - the bridge will never recommend a heal.')
end

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
    HealLog.info('bridge', 'ACK seq=%d result=%s (%s on %s)', ack, tostring(macroVar('SmartHealResult')),
        action and tostring(action.spellName) or '?', action and tostring(action.targetName) or '?')
    shSend({ kind = 'ack', seq = ack, result = tostring(macroVar('SmartHealResult')) })
    if action and action.isHoT and tostring(macroVar('SmartHealResult') or '') == 'CAST_SUCCESS' then
        local castInfo = Healing.prepareHealCast(action)
        if castInfo then Healing.registerHealCast(castInfo) end
    end
    for seq in pairs(publishedBySeq) do
        if seq <= ack then publishedBySeq[seq] = nil end
    end
end

-- ------------------------------------------- unknown-MaxHP fallback + heal floor
-- Out-of-group PCs (XTarHeal slots) only resolve MaxHP through DanNet; when that
-- fails sidekick falls back to defaultRemoteMaxHP=100000, which turns an 86% target
-- into a 14000hp deficit and makes the biggest heal look right. Use the largest
-- MaxHP we actually know (self + DanNet-resolved targets) as the estimate instead.
local function applyMaxHPFallback()
    local best = tonumber(mq.TLO.Me.MaxHPs()) or 0
    local tm = Healing.TargetMonitor
    if tm and tm.getAllTargets then
        for _, t in pairs(tm.getAllTargets() or {}) do
            if t.maxHPKnown and (tonumber(t.maxHP) or 0) > best then best = tonumber(t.maxHP) end
        end
    end
    if best > 100 and Healing.Config.defaultRemoteMaxHP ~= best then
        Healing.Config.defaultRemoteMaxHP = best
    end
end

-- [Heals] SmartHealFloorPct: minimum deficit % before a non-emergency direct heal is
-- recommended (sidekick default is 10% squishy / 15% other / 20% low pressure).
local lastFloor = nil
local function applyHealFloor()
    local floor = macroInt('SmartHealFloorPct')
    if floor <= 0 or floor == lastFloor then return end
    lastFloor = floor
    Healing.Config.minHealPct = floor
    Healing.Config.nonSquishyMinHealPct = math.max(floor, 15)
    Healing.Config.lowPressureMinDeficitPct = math.max(floor, 20)
    log('Heal floor: %d%% deficit (nonSquishy %d%%, lowPressure %d%%)', floor,
        Healing.Config.nonSquishyMinHealPct, Healing.Config.lowPressureMinDeficitPct)
end

-- Spell assignment is decided once at init; sidekick proper only re-reads the gems on
-- a manual /sk rescan. Poll the bar so a heal memmed mid-session joins its category.
local lastGemScan = 0
local function rescanGems()
    local now = mq.gettime()
    if (now - lastGemScan) < 10000 then return end
    lastGemScan = now
    if not Healing.Config.mergeFromSpellBar then return end
    local added, additions = Healing.Config.mergeFromSpellBar()
    for _, add in ipairs(additions or {}) do
        log('Memorized heal added: %s -> %s', add.name, add.category)
    end
end

-- [Heals] SmartHealEmergencyPct: below this HP% a target is an emergency - fastest direct
-- heal, no HoTs, no group heals. sidekick's CLR default of 25% is far too low for this
-- server's melee (2026-09-10: tank at 42% under 1700 DPS got a 2s HoT and died).
local lastEmergency = nil
local function applyEmergencyPct()
    local pct = macroInt('SmartHealEmergencyPct')
    if pct <= 0 then pct = 45 end
    if pct == lastEmergency then return end
    lastEmergency = pct
    Healing.Config.emergencyPct = pct
    log('Emergency line: %d%% (fastest direct heal, HoTs/group heals suppressed below it)', pct)
end

-- HoT veto: sidekick documents that direct heals take over below 100-hotMaxDeficitPct
-- (65%), yet the log shows single-target HoT picks at 42% and 57% on a tank under
-- 800-1700 DPS. Enforce it here and re-run selection with HoTs disabled so the tick
-- still yields a direct heal instead of nothing.
local function vetoHot(action, opts)
    if not action or not action.isHoT or action.tier == 'groupHot' then return action end
    local tm = Healing.TargetMonitor
    local t = tm and tm.getTarget and tm.getTarget(tonumber(action.targetId) or 0) or nil
    local pct = t and tonumber(t.pctHP) or 100
    local floor = 100 - (tonumber(Healing.Config.hotMaxDeficitPct) or 35)
    if pct >= floor then return action end
    local saved = Healing.Config.hotEnabled
    Healing.Config.hotEnabled = false
    local direct = Healing.buildHealAction(opts)
    Healing.Config.hotEnabled = saved
    HealLog.info('bridge', 'HOT VETO: %s on %s at %d%% (< %d%%) -> %s', tostring(action.spellName),
        tostring(action.targetName), pct, floor, direct and tostring(direct.spellName) or 'none')
    shSend({
        kind = 'veto', spell = tostring(action.spellName), target = tostring(action.targetName),
        pct = pct, replacement = direct and tostring(direct.spellName) or nil,
    })
    return direct
end

-- ------------------------------------------- companion feed
-- Companion renders the SmartHeals Outcomes/Decisions cards from these. MQ
-- registers a Lua actor mailbox as '<script>:<name>' and an address-less send
-- only reaches the sender's own script, so every send fans out to each script
-- that might be hosting the companion parser -- the same fix companion's own
-- group.lua applies to 'companion_dps'. Sends to a mailbox nobody registered
-- are dropped silently.
local SH_MAILBOX = 'companion_smartheal'
local SH_SCRIPTS = { 'companion', 'maui', 'medley' }
local shActor    = nil
local shWarned   = false

shSend = function(payload)
    if not shActor then
        if not shWarned then
            shWarned = true
            log('\ayCompanion feed unavailable - SmartHeals cards will show no data.')
        end
        return
    end
    pcall(function()
        for _, script in ipairs(SH_SCRIPTS) do
            shActor:send({ mailbox = SH_MAILBOX, script = script }, payload)
        end
    end)
end

if actorsOk and actors then
    -- Registered as a no-op receiver purely so send() has a valid endpoint;
    -- companion registers its own callback on the same mailbox name.
    local okReg, a = pcall(actors.register, SH_MAILBOX, function() end)
    if okReg then shActor = a end
end

-- Config is resent only when a value actually changes, so this is a handful of
-- messages per session rather than one per loop.
local shLastConfig = nil
local function shConfig()
    local key = string.format('%s|%s|%s|%s',
        tostring(Healing.Config.emergencyPct), tostring(Healing.Config.minHealPct),
        tostring(mq.TLO.Spawn(macroInt('MainAssistID')).CleanName() or ''),
        tostring(macroInt('SmartHealDebug') > 0))
    if key == shLastConfig then return end
    shLastConfig = key
    shSend({
        kind         = 'config',
        emergencyPct = tonumber(Healing.Config.emergencyPct),
        floorPct     = tonumber(Healing.Config.minHealPct),
        maName       = mq.TLO.Spawn(macroInt('MainAssistID')).CleanName(),
        shadow       = macroInt('SmartHealDebug') > 0,
    })
end

-- The macro increments SmartHealNetFires every time CheckHealth's emergency
-- safety net casts the legacy MA heal. Nothing in that cast is distinguishable
-- from any other legacy heal in the chat log, so poll the counter and report
-- the delta.
local shLastNet = nil
local function shNet()
    local n = macroInt('SmartHealNetFires')
    if shLastNet == nil then shLastNet = n; return end
    if n > shLastNet then
        shSend({ kind = 'net', count = n - shLastNet })
    end
    -- A macro restart zeroes the counter; resync without reporting a negative.
    shLastNet = n
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
            applyMaxHPFallback()
            applyHealFloor()
            applyEmergencyPct()
            shConfig()
            shNet()
            rescanGems()
            registerConfirmedCast()
            local selOpts = { ignoreSpellEngine = true, skipIfCasting = false }
            action = vetoHot(Healing.buildHealAction(selOpts), selOpts)
        end
        local varsets = BridgeState.next(state, action, macroInt('SmartHealAck'))
        if varsets then
            publishedBySeq[state.seq] = action
            HealLog.info('bridge', 'PUBLISH seq=%d %s on %s [%s] %s', state.seq, tostring(action.spellName),
                tostring(action.targetName), tostring(action.tier or 'single'), tostring(action.details or action.reason or ''))
            local shT = Healing.TargetMonitor and Healing.TargetMonitor.getTarget
                and Healing.TargetMonitor.getTarget(tonumber(action.targetId) or 0) or nil
            shSend({
                kind      = 'decision',
                seq       = state.seq,
                spell     = tostring(action.spellName),
                target    = tostring(action.targetName),
                tier      = tostring(action.tier or 'single'),
                trigger   = action.reason and tostring(action.reason) or nil,
                targetPct = shT and tonumber(shT.pctHP) or nil,
                targetDps = shT and tonumber(shT.recentDps) or nil,
                isHoT     = action.isHoT == true,
            })
            for _, pair in ipairs(varsets) do
                mq.cmdf('/varset %s %s', pair[1], pair[2])
            end
        end
        mq.cmdf('/varset SmartHealBeat %d', state.beat)
    end
    mq.delay(LOOP_MS)
end
