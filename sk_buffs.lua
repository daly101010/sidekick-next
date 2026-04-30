-- F:/lua/sidekick-next/sk_buffs.lua
-- Buff module for SideKick multi-script system
-- Priority 6: OOC buff casting through coordinator claims
-- Maintains cross-character coordination via Actors

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')
local lazy = require('sidekick-next.utils.lazy_require')

-- Create module instance
local module = ModuleBase.create('buffs', lib.Priority.BUFF)

local debugLog = require('sidekick-next.utils.debug_log').module('sk_buffs', 'SK_BUFFS')

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

local BUFF_TICK_INTERVAL = 0.5             -- Casting tick interval (500ms)
local DEFAULT_REBUFF_WINDOW = 60           -- Default seconds before expiry to rebuff
local BUFF_CHECK_INTERVAL = 60.0           -- How often to recheck buff status on targets
local BUFF_DEFS_REFRESH_INTERVAL = 5.0     -- Refresh buff definitions if empty
local BUFF_DEFS_PERIODIC_REFRESH = 5.0     -- Periodic refresh to pick up spell set changes
local BUFF_GEM_HOLD_WINDOW = 8.0           -- Seconds to hold buff gem after mem
local CLAIM_TIMEOUT = 8.0                  -- Claims expire after 8 seconds
local PENDING_BUFF_WINDOW = 8.0            -- Seconds to treat a buff as present after cast
local GROUP_CAST_COOLDOWN = 6.0            -- Cooldown to avoid immediate re-cast of group spells

-------------------------------------------------------------------------------
-- Internal State
-------------------------------------------------------------------------------

local _coreLoaded = false
local _pendingAction = nil
local _pendingReason = nil
local _lastBuffScanReason = 'not_scanned'
local _lastBuffTick = 0
local _lastBuffDefsRefresh = 0
local _initialScanComplete = false
local _lastInitialScanAttempt = 0
local _selfName = ''
local _buffDebugEnabled = false
local _diagThrottle = {}

-- Buff definitions from spell set
local _buffDefinitions = {}

-- Gem hot-swap state
local _buffGemSwap = {
    active = false,
    reservedGem = 0,
    originalSpell = '',
    requestedSpell = '',
    lastRequestAt = 0,
    lastMemAt = 0,
}

-- Active buff cast state
local _activeBuff = {
    category = nil,
    spellName = nil,
    targetId = nil,
    startedAt = 0,
    timeout = 15.0,
    state = nil,  -- 'memorizing', 'casting', or nil
}

-- Group cast cooldowns
local _lastGroupCastAt = {}

-------------------------------------------------------------------------------
-- Lazy-load Dependencies
-------------------------------------------------------------------------------

local getCore = lazy('sidekick-next.utils.core')
local getCache = lazy('sidekick-next.utils.runtime_cache')
local getSpellEngine = lazy('sidekick-next.utils.spell_engine')
local getConditionBuilder = lazy('sidekick-next.ui.condition_builder')
local getBuffLogger = lazy('sidekick-next.automation.buff_logger')

local _SpellsetManager = nil
local function getSpellsetManager()
    if not _SpellsetManager then
        local ok, sm = pcall(require, 'sidekick-next.utils.spellset_manager')
        if ok then
            if not sm.initialized and sm.init then
                sm.init()
            end
            _SpellsetManager = sm
        end
    end
    return _SpellsetManager
end

local getBuff = lazy('sidekick-next.automation.buff')

-------------------------------------------------------------------------------
-- Helper Functions
-------------------------------------------------------------------------------

local function diagLog(key, intervalSec, fmt, ...)
    if not _buffDebugEnabled then return end

    local now = os.clock()
    key = tostring(key or 'diag')
    intervalSec = tonumber(intervalSec) or 0
    if intervalSec > 0 and (now - (_diagThrottle[key] or 0)) < intervalSec then return end
    _diagThrottle[key] = now

    local msg
    if select('#', ...) > 0 then
        local ok, formatted = pcall(string.format, fmt, ...)
        msg = ok and formatted or tostring(fmt)
    else
        msg = tostring(fmt)
    end

    debugLog('[diag] %s', msg)

    local BuffLogger = getBuffLogger()
    if BuffLogger then
        if BuffLogger.init then BuffLogger.init({ level = 'debug', enabled = true }) end
        if BuffLogger.info then BuffLogger.info('diagnostic', '%s', msg) end
    end
end

local function ensureCoreLoaded()
    if not _coreLoaded then
        local Core = getCore()
        if Core and Core.load then
            Core.load()
        end
        _coreLoaded = true
    end
end

local function syncSettings()
    ensureCoreLoaded()
    local Core = getCore()
    return Core and Core.Settings or {}
end

local function isWindowOpen(name)
    if not name or name == '' then return false end
    local w = mq.TLO.Window(name)
    return w and w.Open and w.Open() == true
end

local function getNumGems()
    local me = mq.TLO.Me
    if not (me and me()) then return 0 end
    return tonumber(me.NumGems()) or 0
end

local function getReservedBuffGem()
    local numGems = getNumGems()
    if numGems <= 0 then return 0 end
    return numGems
end

local function getGemSpellName(gemNum)
    local me = mq.TLO.Me
    if not (me and me()) then return '' end
    if gemNum <= 0 then return '' end
    local gem = me.Gem(gemNum)
    if gem and gem() then
        return gem.Name and gem.Name() or ''
    end
    return ''
end

local function getSpellId(spellName)
    if not spellName then return nil end
    local spell = mq.TLO.Spell(spellName)
    if spell and spell() and spell.ID then
        return tonumber(spell.ID()) or nil
    end
    return nil
end

local function buildNameQuery(spellName)
    if not spellName or spellName == '' then return nil end
    return string.format('name "%s"', spellName)
end

local function tloPresent(accessor)
    local ok, value = pcall(accessor)
    if not (ok and value) then return false end
    local okValue, present = pcall(function() return value() end)
    return okValue and present and true or false
end

local function actorHasBuffBySpell(actor, spellName, spellId)
    if not actor then return false end

    if spellId then
        if tloPresent(function() return actor.FindBuff and actor.FindBuff('id ' .. spellId) end) then return true end
        if tloPresent(function() return actor.FindSong and actor.FindSong('id ' .. spellId) end) then return true end
        if tloPresent(function() return actor.Buff and actor.Buff('id ' .. spellId) end) then return true end
        if tloPresent(function() return actor.Song and actor.Song('id ' .. spellId) end) then return true end
    end

    local query = buildNameQuery(spellName)
    if query then
        if tloPresent(function() return actor.FindBuff and actor.FindBuff(query) end) then return true end
        if tloPresent(function() return actor.FindSong and actor.FindSong(query) end) then return true end
    end

    if spellName and spellName ~= '' then
        if tloPresent(function() return actor.Buff and actor.Buff(spellName) end) then return true end
        if tloPresent(function() return actor.Song and actor.Song(spellName) end) then return true end
    end

    return false
end

local function buffProbe(actor, spellName, spellId)
    local probe = {
        findBuffId = false,
        findSongId = false,
        buffId = false,
        songId = false,
        findBuffName = false,
        findSongName = false,
        buffName = false,
        songName = false,
    }
    if not actor then return probe end

    if spellId then
        probe.findBuffId = tloPresent(function() return actor.FindBuff and actor.FindBuff('id ' .. spellId) end)
        probe.findSongId = tloPresent(function() return actor.FindSong and actor.FindSong('id ' .. spellId) end)
        probe.buffId = tloPresent(function() return actor.Buff and actor.Buff('id ' .. spellId) end)
        probe.songId = tloPresent(function() return actor.Song and actor.Song('id ' .. spellId) end)
    end

    local query = buildNameQuery(spellName)
    if query then
        probe.findBuffName = tloPresent(function() return actor.FindBuff and actor.FindBuff(query) end)
        probe.findSongName = tloPresent(function() return actor.FindSong and actor.FindSong(query) end)
    end

    if spellName and spellName ~= '' then
        probe.buffName = tloPresent(function() return actor.Buff and actor.Buff(spellName) end)
        probe.songName = tloPresent(function() return actor.Song and actor.Song(spellName) end)
    end

    return probe
end

local function probeSummary(probe)
    return string.format('findBuffId=%s findSongId=%s buffId=%s songId=%s findBuffName=%s findSongName=%s buffName=%s songName=%s',
        tostring(probe and probe.findBuffId),
        tostring(probe and probe.findSongId),
        tostring(probe and probe.buffId),
        tostring(probe and probe.songId),
        tostring(probe and probe.findBuffName),
        tostring(probe and probe.findSongName),
        tostring(probe and probe.buffName),
        tostring(probe and probe.songName))
end

local function actorHasTriggeredEffect(actor, spellName)
    if not actor or not spellName or spellName == '' then return false end
    local spell = mq.TLO.Spell(spellName)
    if not (spell and spell()) then return false end

    local okCount, rawCount = pcall(function()
        return spell.NumEffects and spell.NumEffects() or 0
    end)
    local numEffects = okCount and tonumber(rawCount or 0) or 0
    for i = 1, numEffects do
        local okTrigger, trigger = pcall(function()
            return spell.Trigger and spell.Trigger(i) or nil
        end)
        if not okTrigger then trigger = nil end
        local okPresent, triggerPresent = pcall(function()
            return trigger and trigger()
        end)
        if okPresent and triggerPresent then
            local okId, rawId = pcall(function()
                return trigger.ID and trigger.ID() or 0
            end)
            local triggerId = okId and tonumber(rawId or 0) or 0
            local okName, rawName = pcall(function()
                return trigger.Name and trigger.Name() or ''
            end)
            local triggerName = okName and tostring(rawName or '') or ''
            if triggerId > 0 and actorHasBuffBySpell(actor, triggerName, triggerId) then
                return true
            end
        end
    end

    return false
end

local function getCachedBuffState(targetId, category, rebuffWindow)
    local id = tonumber(targetId) or 0
    if id <= 0 or not category then return nil end

    local Cache = getCache()
    local state = Cache and Cache.buffState and Cache.buffState[id] and Cache.buffState[id][category]
    if not state then return nil end
    if state.pending then return state end
    if state.present and (tonumber(state.remaining) or 0) >= (rebuffWindow or DEFAULT_REBUFF_WINDOW) then
        return state
    end
    return nil
end

local function getSpellTargetType(spellName)
    if not spellName then return '' end
    local spell = mq.TLO.Spell(spellName)
    if spell and spell() and spell.TargetType then
        return tostring(spell.TargetType() or '')
    end
    return ''
end

local function isSelfOnlySpell(spellName)
    local targetType = getSpellTargetType(spellName)
    return targetType == 'Self' or targetType == 'Self Only' or targetType == 'PB AE'
end

local function isGroupSpell(spellName)
    local targetType = getSpellTargetType(spellName)
    return targetType:match('^Group') ~= nil
end

local function isSpellReady(spellName)
    if not spellName or spellName == '' then return false end
    local me = mq.TLO.Me
    if not (me and me()) then return false end

    local gem = me.Gem(spellName)
    if not gem or not gem() or gem() == 0 then return false end

    local ready = me.SpellReady(spellName)
    return ready and ready() == true
end

--- Ensure we are targeting the given spawn ID before casting
--- @param id number Spawn ID to target
--- @return boolean True if current target matches id
local function ensureTarget(id)
    if not id or id <= 0 then return false end
    local currentTargetId = lib.safeNum(function() return mq.TLO.Target.ID() end, 0)
    if currentTargetId == id then return true end
    mq.cmdf('/target id %d', id)
    mq.delay(50)
    currentTargetId = lib.safeNum(function() return mq.TLO.Target.ID() end, 0)
    return currentTargetId == id
end

local function selfHasBuff(spellName, spellId)
    if not spellName then return false end

    local me = mq.TLO.Me
    if not me or not me() then return false end

    if actorHasBuffBySpell(me, spellName, spellId) then return true end
    if actorHasTriggeredEffect(me, spellName) then return true end

    -- Check Aura slots
    for i = 1, 5 do
        local aura = me.Aura(i)
        if aura and aura() then
            local auraName = aura.Name and aura.Name() or ""
            if auraName ~= "" then
                -- Check exact match or partial match for auras
                if auraName:lower() == spellName:lower() then
                    return true
                end
                if auraName:lower():find(spellName:lower(), 1, true) then
                    return true
                end
                if spellName:lower():find(auraName:lower(), 1, true) then
                    return true
                end
            end
        end
    end

    return false
end

local function getGroupRoleNames()
    local roles = {}
    local function readRole(roleName, accessor)
        local ok, name = pcall(accessor)
        name = ok and tostring(name or ''):lower() or ''
        if name ~= '' and name ~= 'null' then
            roles[name] = roleName
        end
    end

    readRole('MainTank', function()
        local role = mq.TLO.Group.MainTank
        return role and role.CleanName and role.CleanName() or ''
    end)
    readRole('MainAssist', function()
        local role = mq.TLO.Group.MainAssist
        return role and role.CleanName and role.CleanName() or ''
    end)
    readRole('Puller', function()
        local role = mq.TLO.Group.Puller
        return role and role.CleanName and role.CleanName() or ''
    end)

    return roles
end

local function groupBuffCandidates(myId)
    local candidates = {}
    local roleNames = getGroupRoleNames()
    local me = mq.TLO.Me

    if me and me() and myId > 0 then
        local name = me.CleanName and me.CleanName() or _selfName
        table.insert(candidates, {
            id = myId,
            name = name,
            class = me.Class and me.Class.ShortName and me.Class.ShortName() or '',
            hp = me.PctHPs and me.PctHPs() or 100,
            mana = me.PctMana and me.PctMana() or 100,
            role = roleNames[tostring(name or ''):lower()],
            isSelf = true,
            tlo = me,
        })
    end

    local memberCount = tonumber(mq.TLO.Group.Members()) or 0
    for i = 1, memberCount do
        local member = mq.TLO.Group.Member(i)
        if member and member() then
            local id = tonumber(member.ID()) or 0
            if id > 0 and id ~= myId then
                local name = member.CleanName and member.CleanName() or ''
                table.insert(candidates, {
                    id = id,
                    name = name,
                    class = member.Class and member.Class.ShortName and member.Class.ShortName() or '',
                    hp = member.PctHPs and member.PctHPs() or 100,
                    mana = member.PctMana and member.PctMana() or 100,
                    distance = member.Distance and tonumber(member.Distance()) or 999,
                    role = roleNames[tostring(name or ''):lower()],
                    isSelf = false,
                    tlo = member,
                })
            end
        end
    end

    return candidates
end

local function targetMatchesBuffTarget(candidate, buffTarget)
    if not candidate then return false end
    local targetType = tostring(buffTarget and buffTarget.type or 'group'):lower()
    local targetValue = tostring(buffTarget and buffTarget.value or ''):lower()

    if targetType == '' or targetType == 'group' then
        return true
    elseif targetType == 'role' then
        return tostring(candidate.role or ''):lower() == targetValue
    elseif targetType == 'class' then
        return targetValue == '' or tostring(candidate.class or ''):lower() == targetValue
    elseif targetType == 'name' then
        return targetValue == '' or tostring(candidate.name or ''):lower() == targetValue
    end

    return true
end

local function conditionPassesForTarget(buffDef, candidate)
    local condition = buffDef and buffDef.condition
    if not condition or not condition.conditions or #condition.conditions == 0 then return true end

    local ConditionBuilder = getConditionBuilder()
    if not (ConditionBuilder and ConditionBuilder.evaluateWithContext) then return true end

    local cls = tostring(candidate.class or '')
    local ctx = {
        myHp = mq.TLO.Me.PctHPs() or 100,
        myMana = mq.TLO.Me.PctMana() or 100,
        myEndurance = mq.TLO.Me.PctEndurance() or 100,
        inCombat = lib.inCombat(),
        isInvis = mq.TLO.Me.Invis() == true,
        buffTarget = candidate.tlo,
        buffTargetClass = cls,
        buffTargetRole = candidate.role,
        buffTargetHp = candidate.hp or 100,
        buffTargetMana = candidate.mana or 100,
        buffTargetIsMe = candidate.isSelf == true,
        buffTargetIsTank = (cls == 'WAR' or cls == 'PAL' or cls == 'SHD'),
        buffTargetIsHealer = (cls == 'CLR' or cls == 'DRU' or cls == 'SHM'),
        buffTargetIsMelee = (cls == 'WAR' or cls == 'PAL' or cls == 'SHD' or cls == 'MNK' or cls == 'ROG' or cls == 'BER' or cls == 'RNG' or cls == 'BST'),
        buffTargetIsCaster = (cls == 'WIZ' or cls == 'MAG' or cls == 'ENC' or cls == 'NEC' or cls == 'CLR' or cls == 'DRU' or cls == 'SHM'),
    }

    local ok, result = pcall(ConditionBuilder.evaluateWithContext, condition, ctx)
    if not ok then
        debugLog('conditionPassesForTarget: condition failed for %s: %s', tostring(candidate.name), tostring(result))
        return false
    end
    return result == true
end

local function candidateHasBuff(candidate, spellName, spellId, category, rebuffWindow)
    if not candidate then return false end

    local cached = getCachedBuffState(candidate.id, category, rebuffWindow)
    local direct = false
    local triggered = false
    local aura = false

    if candidate.isSelf then
        local me = mq.TLO.Me
        if me and me() then
            direct = actorHasBuffBySpell(me, spellName, spellId)
            triggered = actorHasTriggeredEffect(me, spellName)
            aura = (not direct and not triggered) and selfHasBuff(spellName, spellId) or false
        end
    else
        direct = actorHasBuffBySpell(candidate.tlo, spellName, spellId)
        triggered = actorHasTriggeredEffect(candidate.tlo, spellName)
    end

    if _buffDebugEnabled then
        local probe = buffProbe(candidate.isSelf and mq.TLO.Me or candidate.tlo, spellName, spellId)
        local stateText = cached and string.format('present=%s pending=%s remaining=%s spellId=%s',
            tostring(cached.present), tostring(cached.pending), tostring(cached.remaining), tostring(cached.spellId)) or 'nil'
        diagLog('candidate_has_' .. tostring(category) .. '_' .. tostring(candidate.id), 0.5,
            'candidateHasBuff spell="%s" spellId=%s category=%s target=%s(%s) self=%s cached={%s} direct=%s triggered=%s aura=%s probe={%s}',
            tostring(spellName), tostring(spellId), tostring(category), tostring(candidate.name), tostring(candidate.id),
            tostring(candidate.isSelf), stateText, tostring(direct), tostring(triggered), tostring(aura), probeSummary(probe))
    end

    return cached ~= nil or direct or triggered or aura
end

local function pickBuffTarget(buffDef, spellName, category, rebuffWindow, isGroup, myId)
    local spellId = buffDef and buffDef.spellId or getSpellId(spellName)
    for _, candidate in ipairs(groupBuffCandidates(myId)) do
        if targetMatchesBuffTarget(candidate, buffDef and buffDef.buffTarget)
            and conditionPassesForTarget(buffDef, candidate) then
            local hasBuff = candidateHasBuff(candidate, spellName, spellId, category, rebuffWindow)
            debugLog('pickBuffTarget: %s candidate=%s id=%d hasBuff=%s isGroup=%s',
                spellName, tostring(candidate.name), tonumber(candidate.id) or 0, tostring(hasBuff), tostring(isGroup))
            if not hasBuff then
                return candidate
            end
        end
    end
    return nil
end

--- Check if a spell would stack (not blocked by existing buffs)
---@param spellName string The spell name to check
---@return boolean True if spell would stack/land
local function spellWouldStack(spellName)
    if not spellName then return false end

    local spell = mq.TLO.Spell(spellName)
    if not spell or not spell() then return false end

    -- Check if spell stacks on self
    -- Stacks() returns true if the spell would land (not blocked by existing buffs)
    local stacks = spell.Stacks
    if stacks then
        local result = stacks()
        if result == false then
            debugLog('spellWouldStack: %s would NOT stack', spellName)
            return false
        end
    end

    return true
end

--- Check if we have enough mana to cast a spell
---@param spellName string The spell name to check
---@return boolean True if we have enough mana
local function hasEnoughMana(spellName)
    if not spellName then return false end

    local me = mq.TLO.Me
    if not me or not me() then return false end

    local spell = mq.TLO.Spell(spellName)
    if not spell or not spell() then return false end

    local manaCost = spell.Mana and spell.Mana() or 0
    local currentMana = me.CurrentMana and me.CurrentMana() or 0

    if manaCost > currentMana then
        debugLog('hasEnoughMana: %s needs %d mana, have %d', spellName, manaCost, currentMana)
        return false
    end

    return true
end

-------------------------------------------------------------------------------
-- Buff Definitions Management
-------------------------------------------------------------------------------

local _persistenceLoaded = false

local function loadBuffDefinitions()
    local nextDefinitions = {}

    -- Get SpellSetData and Persistence to access oocBuffs
    local SpellSetData = nil
    local Persistence = nil
    pcall(function()
        SpellSetData = require('sidekick-next.utils.spellset_data')
    end)
    pcall(function()
        Persistence = require('sidekick-next.utils.spellset_persistence')
    end)

    if not SpellSetData or not Persistence then
        debugLog('loadBuffDefinitions: SpellSetData or Persistence not available')
        _lastBuffScanReason = 'no_spellset_modules'
        return
    end

    -- sk_buffs.lua runs as a separate script, so we need to load spell sets from disk
    -- This is only done once per session to avoid repeated disk reads
    if not _persistenceLoaded then
        debugLog('loadBuffDefinitions: Loading spell sets from disk (first time)')
        local ok, loadedOrErr = pcall(function()
            return Persistence.load()
        end)
        if not ok or loadedOrErr ~= true then
            debugLog('loadBuffDefinitions: Persistence.load() failed: %s', tostring(loadedOrErr))
            _lastBuffScanReason = 'spellset_load_failed'
            return
        else
            _persistenceLoaded = true
            debugLog('loadBuffDefinitions: Spell sets loaded, activeSetName=%s', tostring(Persistence.activeSetName))
        end
    end

    local spellSet = Persistence.getActiveSet()
    if not spellSet then
        debugLog('loadBuffDefinitions: No active spell set (activeSetName=%s)', tostring(Persistence.activeSetName))
        _lastBuffScanReason = 'no_active_spell_set'
        _persistenceLoaded = false
        return
    end

    local enabledBuffs = SpellSetData.getEnabledOocBuffs(spellSet)
    if not enabledBuffs or #enabledBuffs == 0 then
        debugLog('loadBuffDefinitions: No enabled OOC buffs in spell set')
        _buffDefinitions = {}
        _lastBuffScanReason = 'no_enabled_ooc_buffs'
        return
    end

    debugLog('loadBuffDefinitions: Found %d enabled OOC buffs', #enabledBuffs)

    for _, buffConfig in ipairs(enabledBuffs) do
        local spell = mq.TLO.Spell(buffConfig.spellId)
        local spellName = spell and spell.Name() or nil
        if spellName then
            local category = string.format('oocbuff_%d', buffConfig.spellId)
            nextDefinitions[category] = {
                spellId = buffConfig.spellId,
                spellName = spellName,
                category = category,
                condition = buffConfig.condition,
                buffTarget = buffConfig.buffTarget,
                priority = buffConfig.priority or 999,
                rebuffWindow = DEFAULT_REBUFF_WINDOW,
            }
            debugLog('loadBuffDefinitions: Added buff %s (id=%d, priority=%d)',
                spellName, buffConfig.spellId, buffConfig.priority or 999)
        else
            debugLog('loadBuffDefinitions: Spell id %s did not resolve to a spell name', tostring(buffConfig.spellId))
        end
    end

    _buffDefinitions = nextDefinitions
    if next(_buffDefinitions) then
        _lastBuffScanReason = string.format('loaded_%d_ooc_buffs', #enabledBuffs)
    else
        _lastBuffScanReason = 'no_resolved_ooc_buffs'
    end
end

local function refreshBuffDefinitionsIfNeeded()
    local now = os.clock()
    local hasDefinitions = next(_buffDefinitions) ~= nil

    local needsRefresh = false
    local isPeriodicRefresh = false

    if not hasDefinitions then
        if (now - _lastBuffDefsRefresh) >= BUFF_DEFS_REFRESH_INTERVAL then
            needsRefresh = true
        end
    else
        if (now - _lastBuffDefsRefresh) >= BUFF_DEFS_PERIODIC_REFRESH then
            needsRefresh = true
            isPeriodicRefresh = true
        end
    end

    if needsRefresh then
        _lastBuffDefsRefresh = now
        -- For periodic refresh, force reload from disk to pick up user changes
        if isPeriodicRefresh then
            _persistenceLoaded = false
            debugLog('refreshBuffDefinitionsIfNeeded: Periodic refresh, forcing disk reload')
        end
        loadBuffDefinitions()
    end
end

local function getSortedBuffDefinitions()
    local sorted = {}
    for category, def in pairs(_buffDefinitions) do
        table.insert(sorted, { category = category, def = def })
    end
    table.sort(sorted, function(a, b)
        return (a.def.priority or 999) < (b.def.priority or 999)
    end)
    return sorted
end

-------------------------------------------------------------------------------
-- Gem Hot-Swap Management
-------------------------------------------------------------------------------

local function ensureBuffSpellMemorized(spellName)
    if not spellName or spellName == '' then return false end
    local reservedGem = getReservedBuffGem()
    if reservedGem <= 0 then return false end

    local me = mq.TLO.Me
    if not (me and me()) then return false end
    local inBook = me.Book(spellName)
    if not (inBook and inBook()) then
        return false
    end

    if isWindowOpen('SpellBookWnd') or isWindowOpen('SpellBookWindow') then
        return false
    end

    if _buffGemSwap.reservedGem ~= reservedGem then
        _buffGemSwap.reservedGem = reservedGem
    end

    local current = getGemSpellName(reservedGem)

    -- Start of a buff rotation
    if not _buffGemSwap.active then
        _buffGemSwap.active = true
        _buffGemSwap.originalSpell = current
        _buffGemSwap.requestedSpell = ''
        _buffGemSwap.lastRequestAt = 0
        _buffGemSwap.lastMemAt = 0
    end

    -- Already memorized
    if current == spellName then
        _buffGemSwap.requestedSpell = ''
        _buffGemSwap.lastMemAt = os.clock()
        return true
    end

    local now = os.clock()
    local requestCooldown = 1.0
    if _buffGemSwap.requestedSpell == spellName and (now - (_buffGemSwap.lastRequestAt or 0)) < requestCooldown then
        return false
    end

    -- Retry if waiting too long
    if _buffGemSwap.requestedSpell == spellName and (now - (_buffGemSwap.lastRequestAt or 0)) >= 8.0 then
        _buffGemSwap.lastRequestAt = now
        mq.cmdf('/memspell %d "%s"', reservedGem, spellName)
        return false
    end

    _buffGemSwap.requestedSpell = spellName
    _buffGemSwap.lastRequestAt = now
    mq.cmdf('/memspell %d "%s"', reservedGem, spellName)
    return false
end

local function maybeRestoreBuffGem()
    if not _buffGemSwap.active then return end

    local reservedGem = getReservedBuffGem()
    if reservedGem <= 0 then
        _buffGemSwap.active = false
        _buffGemSwap.originalSpell = ''
        _buffGemSwap.requestedSpell = ''
        _buffGemSwap.lastRequestAt = 0
        _buffGemSwap.lastMemAt = 0
        _buffGemSwap.reservedGem = 0
        return
    end

    local now = os.clock()
    if (now - (_buffGemSwap.lastMemAt or 0)) < BUFF_GEM_HOLD_WINDOW then
        return
    end

    local current = getGemSpellName(reservedGem)
    local original = _buffGemSwap.originalSpell or ''

    if original ~= '' and current ~= original then
        local me = mq.TLO.Me
        if me and me() and me.Book and me.Book(original) and me.Book(original)() then
            if not isWindowOpen('SpellBookWnd') and not isWindowOpen('SpellBookWindow') then
                mq.cmdf('/memspell %d "%s"', reservedGem, original)
            end
        end
    end

    _buffGemSwap.active = false
    _buffGemSwap.originalSpell = ''
    _buffGemSwap.requestedSpell = ''
    _buffGemSwap.lastRequestAt = 0
    _buffGemSwap.lastMemAt = 0
end

-------------------------------------------------------------------------------
-- Active Buff State
-------------------------------------------------------------------------------

local function clearActiveBuff()
    _activeBuff.category = nil
    _activeBuff.spellName = nil
    _activeBuff.targetId = nil
    _activeBuff.startedAt = 0
    _activeBuff.state = nil
end

local function setActiveBuff(category, spellName, targetId, state)
    _activeBuff.category = category
    _activeBuff.spellName = spellName
    _activeBuff.targetId = targetId
    _activeBuff.startedAt = os.clock()
    _activeBuff.state = state or 'memorizing'
end

local function shouldContinueActiveBuff()
    if not _activeBuff.category then return false end
    local elapsed = os.clock() - _activeBuff.startedAt
    if elapsed > _activeBuff.timeout then
        clearActiveBuff()
        return false
    end
    return true
end

-------------------------------------------------------------------------------
-- Blocking Condition Checks
-------------------------------------------------------------------------------

local function canBuffNow()
    local me = mq.TLO.Me
    if not (me and me()) then return false, 'no_character' end

    -- Check combat state (buffing only allowed OOC)
    -- Use lib.inCombat() which checks XTarget haters directly,
    -- not RuntimeCache which may not be ticked in this script process
    local inCombat = lib.inCombat()
    if inCombat then return false, 'in_combat' end

    -- Check invis
    if me.Invis and me.Invis() then return false, 'invis' end

    local moving = me.Moving() == true

    -- Check movement plugins. Active stick/nav alone should not suppress
    -- OOC buffing forever; only block while the character is actually moving.
    local movementPluginActive = (mq.TLO.MoveTo and mq.TLO.MoveTo.Moving and mq.TLO.MoveTo.Moving())
        or (mq.TLO.Navigation and mq.TLO.Navigation.Active and mq.TLO.Navigation.Active())
        or (mq.TLO.AdvPath and mq.TLO.AdvPath.Following and mq.TLO.AdvPath.Following())
        or (mq.TLO.Stick and mq.TLO.Stick.Active and mq.TLO.Stick.Active())
    if movementPluginActive and moving then
        return false, 'movement_plugin'
    end

    -- Check if moving
    if moving then return false, 'moving' end

    -- Check if already casting
    local casting = me.Casting() or ''
    if casting ~= '' and casting ~= 'NULL' then return false, 'casting' end

    -- Check if hovering (dead)
    if me.Hovering and me.Hovering() then return false, 'dead' end

    -- Check if stunned/mezzed
    if me.Stunned and me.Stunned() then return false, 'stunned' end
    if me.Mezzed and me.Mezzed() then return false, 'mezzed' end

    -- Check SpellEngine availability
    local SpellEngine = getSpellEngine()
    if SpellEngine and SpellEngine.isBusy and SpellEngine.isBusy() then
        return false, 'spell_engine_busy'
    end

    return true, nil
end

-------------------------------------------------------------------------------
-- Buff Need Detection
-------------------------------------------------------------------------------

local function findBuffNeed()
    local Cache = getCache()
    if not Cache then
        debugLog('findBuffNeed: No Cache')
        return nil, 'no_cache'
    end

    local settings = syncSettings()

    -- Check if buffing is enabled
    local buffingEnabled = settings.BuffingEnabled
    if buffingEnabled == false or buffingEnabled == 0 then
        debugLog('findBuffNeed: Buffing disabled')
        return nil, 'buffing_disabled'
    end

    -- Check if we can buff now
    local canBuff, reason = canBuffNow()
    if not canBuff then
        debugLog('findBuffNeed: Cannot buff now: %s', tostring(reason))
        return nil, 'blocked_' .. tostring(reason or 'unknown')
    end

    refreshBuffDefinitionsIfNeeded()

    if not next(_buffDefinitions) then
        debugLog('findBuffNeed: No buff definitions')
        return nil, _lastBuffScanReason or 'no_buff_definitions'
    end

    -- NOTE: Initial scan check removed - we no longer depend on the old buff module
    -- The coordinator system uses Cache for buff state tracking instead

    debugLog('findBuffNeed: Checking %d buff definitions', #getSortedBuffDefinitions())

    local now = os.clock()
    local me = mq.TLO.Me
    local myId = me and me.ID and me.ID() or 0

    -- Pending peer requests jump ahead of normal scan order. Pick the highest
    -- priority request whose category we can actually cast.
    local okR, BuffReqs = pcall(require, 'sidekick-next.utils.buff_requests')
    if okR and BuffReqs and BuffReqs.peekHighestPriority then
        local req = BuffReqs.peekHighestPriority()
        if req and req.category and _buffDefinitions[req.category] then
            local buffDef = _buffDefinitions[req.category]
            local spellName = buffDef.spellName
            if spellName and spellName ~= '' then
                local isSelfOnly = isSelfOnlySpell(spellName)
                local isGroup = isGroupSpell(spellName)
                local castableTarget = req.targetId
                -- Self-only spells can only satisfy a request from us.
                if isSelfOnly and castableTarget ~= myId then
                    -- skip self-only request from someone else
                else
                    if spellWouldStack(spellName) and hasEnoughMana(spellName) then
                        debugLog('findBuffNeed: REQUEST priority — %s for %s (category=%s urgency=%s)',
                            spellName, tostring(req.from), req.category, req.urgency or 'normal')
                        return {
                            category = req.category,
                            spellName = spellName,
                            targetId = castableTarget,
                            targetName = req.from,
                            isSelfOnly = isSelfOnly,
                            isGroup = isGroup,
                            fromRequest = true,
                        }
                    end
                end
            end
        end
    end

    local sortedBuffs = getSortedBuffDefinitions()

    for _, entryDef in ipairs(sortedBuffs) do
        local category = entryDef.category
        local buffDef = entryDef.def
        local spellName = buffDef.spellName

        if spellName and spellName ~= '' then
            local rebuffWindow = buffDef.rebuffWindow or DEFAULT_REBUFF_WINDOW
            local isSelfOnly = isSelfOnlySpell(spellName)
            local isGroup = isGroupSpell(spellName)

            debugLog('findBuffNeed: Checking %s (isSelfOnly=%s, isGroup=%s)', spellName, tostring(isSelfOnly), tostring(isGroup))

            if isSelfOnly then
                -- Self-only buff: check directly if we have the buff
                if myId > 0 then
                    local spellId = buffDef.spellId or getSpellId(spellName)
                    local cached = getCachedBuffState(myId, category, rebuffWindow)
                    local hasSelf = selfHasBuff(spellName, spellId)
                    local hasBuff = cached ~= nil or hasSelf
                    if _buffDebugEnabled then
                        local probe = buffProbe(mq.TLO.Me, spellName, spellId)
                        local stateText = cached and string.format('present=%s pending=%s remaining=%s spellId=%s',
                            tostring(cached.present), tostring(cached.pending), tostring(cached.remaining), tostring(cached.spellId)) or 'nil'
                        diagLog('self_only_' .. tostring(category), 0.5,
                            'selfOnlyCheck spell="%s" spellId=%s category=%s cached={%s} selfHas=%s probe={%s}',
                            tostring(spellName), tostring(spellId), tostring(category), stateText, tostring(hasSelf), probeSummary(probe))
                    end
                    debugLog('findBuffNeed: Self-buff %s hasBuff=%s', spellName, tostring(hasBuff))

                    if not hasBuff then
                        -- Check if spell would stack (not blocked by existing buffs)
                        local wouldStack = spellWouldStack(spellName)
                        diagLog('self_only_stack_' .. tostring(category), 0.5,
                            'selfOnlyStack spell="%s" spellId=%s stacks=%s', tostring(spellName), tostring(spellId), tostring(wouldStack))
                        if not wouldStack then
                            debugLog('findBuffNeed: Self-buff %s would not stack, skipping', spellName)
                            goto continue_buff
                        end

                        -- Check if we have enough mana
                        if not hasEnoughMana(spellName) then
                            debugLog('findBuffNeed: Self-buff %s not enough mana, skipping', spellName)
                            goto continue_buff
                        end

                        debugLog('findBuffNeed: FOUND self-buff %s (category=%s)', spellName, category)
                        return {
                            category = category,
                            spellName = spellName,
                            targetId = myId,
                            isSelfOnly = true,
                            isGroup = false,
                        }
                    else
                        _lastBuffScanReason = 'already_has_self_buff:' .. spellName
                    end
                end
            else
                -- Check group cast cooldown first
                if isGroup then
                    local lastCast = _lastGroupCastAt[category] or 0
                    if (now - lastCast) < GROUP_CAST_COOLDOWN then
                        debugLog('findBuffNeed: Group buff %s on cooldown', spellName)
                        _lastBuffScanReason = 'group_cooldown:' .. spellName
                        goto continue_buff
                    end
                end

                -- Check if we have enough mana
                if not hasEnoughMana(spellName) then
                    debugLog('findBuffNeed: Group/single buff %s not enough mana, skipping', spellName)
                    _lastBuffScanReason = 'not_enough_mana:' .. spellName
                    goto continue_buff
                end

                local target = pickBuffTarget(buffDef, spellName, category, rebuffWindow, isGroup, myId)
                if not target then
                    debugLog('findBuffNeed: No eligible target needs %s', spellName)
                    _lastBuffScanReason = 'no_eligible_target:' .. spellName
                    goto continue_buff
                end

                -- Only use self Stacks() as a blocker when the selected target
                -- is self. A self stack failure should not suppress buffing
                -- another group member who is missing the buff.
                if target.isSelf and not spellWouldStack(spellName) then
                    debugLog('findBuffNeed: Group/single buff %s would not stack on self, skipping', spellName)
                    diagLog('target_stack_' .. tostring(category), 0.5,
                        'targetStack spell="%s" category=%s target=%s(%s) self=%s stacks=false -> skip',
                        tostring(spellName), tostring(category), tostring(target.name), tostring(target.id), tostring(target.isSelf))
                    _lastBuffScanReason = 'would_not_stack:' .. spellName
                    goto continue_buff
                end

                diagLog('found_need_' .. tostring(category), 0.5,
                    'FOUND need spell="%s" category=%s target=%s(%s) isGroup=%s isSelf=%s',
                    tostring(spellName), tostring(category), tostring(target.name), tostring(target.id),
                    tostring(isGroup), tostring(target.isSelf))
                debugLog('findBuffNeed: FOUND buff %s on %s (category=%s, isGroup=%s)',
                    spellName, tostring(target.name), category, tostring(isGroup))
                return {
                    category = category,
                    spellName = spellName,
                    targetId = isGroup and myId or target.id,
                    targetName = isGroup and _selfName or target.name,
                    isSelfOnly = false,
                    isGroup = isGroup,
                }
            end
        end
        ::continue_buff::
    end

    debugLog('findBuffNeed: No buffs needed')
    return nil, _lastBuffScanReason or 'no_buff_needed'
end

-------------------------------------------------------------------------------
-- Module Callbacks
-------------------------------------------------------------------------------

module.onTick = function(self)
    debugLog('onTick: ENTERED hasValidState=%s', tostring(self:hasValidState()))

    local settings = syncSettings()
    if not settings then
        debugLog('onTick: No settings, returning')
        _pendingAction = nil
        self:sendNeed(false, nil, 'no_settings')
        return
    end

    -- Check if buffing is enabled
    local buffingEnabled = settings.BuffingEnabled
    if buffingEnabled == false or buffingEnabled == 0 then
        _pendingAction = nil
        maybeRestoreBuffGem()
        self:sendNeed(false, nil, 'buffing_disabled')
        return
    end

    -- IMPORTANT: Check if we're actively casting a buff BEFORE anything else
    -- This ensures we keep sending need hints while casting, regardless of ownership state
    local isCasting = lib.isCasting()
    local hasActiveBuff = _activeBuff.category and _activeBuff.spellName
    local ownsCast = self:ownsCast()

    debugLog('onTick: isCasting=%s hasActiveBuff=%s ownsCast=%s activeBuff=%s',
        tostring(isCasting), tostring(hasActiveBuff), tostring(ownsCast),
        tostring(_activeBuff.spellName or 'nil'))

    if hasActiveBuff and isCasting then
        debugLog('onTick: Sending NEED=true (actively casting)')
        self:sendNeed(true, 5000, 'casting_buff')  -- Long TTL while casting
        return
    end

    -- Also check cast ownership (in case _activeBuff got cleared but we still own)
    if ownsCast then
        debugLog('onTick: Sending NEED=true (owns cast)')
        self:sendNeed(true, 5000, 'owns_cast')  -- Long TTL while casting
        return
    end

    -- Rate limit buff tick (only for finding new buffs, not for maintaining cast ownership)
    local now = os.clock()
    if (now - _lastBuffTick) < BUFF_TICK_INTERVAL then
        -- Still send need if we have pending action
        if _pendingAction then
            self:sendNeed(true, 1000, 'pending_buff')
        end
        return
    end
    _lastBuffTick = now

    -- Find if we have buff work to do
    local need, noNeedReason = findBuffNeed()

    _pendingAction = need
    _pendingReason = need and 'buff_needed' or nil

    local needsAction = need ~= nil
    debugLog('onTick: findBuffNeed=%s needsAction=%s',
        need and need.spellName or 'nil', tostring(needsAction))
    self:sendNeed(needsAction, needsAction and 1500 or nil, needsAction and 'buff_needed' or (noNeedReason or 'no_buff_needed'))

    -- Handle gem memorization while waiting
    if _buffGemSwap.active and _buffGemSwap.requestedSpell ~= '' then
        local reservedGem = getReservedBuffGem()
        local current = getGemSpellName(reservedGem)
        if current ~= _buffGemSwap.requestedSpell then
            if _activeBuff.category and _activeBuff.spellName then
                if not shouldContinueActiveBuff() then
                    _buffGemSwap.requestedSpell = ''
                    return
                end
            end
            ensureBuffSpellMemorized(_buffGemSwap.requestedSpell)
            return
        end
    end

    -- Handle active buff timeout
    if _activeBuff.category and _activeBuff.spellName then
        if not shouldContinueActiveBuff() then
            -- Timed out, will pick new buff next tick
            return
        end
    end

    -- Restore buff gem if no work
    if not needsAction then
        maybeRestoreBuffGem()
    end
end

module.shouldAct = function(self)
    local hasState = self:hasValidState()
    local isMyPrio = hasState and self:isMyPriority() or false
    local hasPending = _pendingAction ~= nil
    local result = hasState and isMyPrio and hasPending
    if hasPending then
        debugLog('shouldAct: hasState=%s isMyPriority=%s hasPending=%s -> %s',
            tostring(hasState), tostring(isMyPrio), tostring(hasPending), tostring(result))
    end
    if not hasState then return false end
    if not isMyPrio then return false end
    return hasPending
end

module.getAction = function(self)
    local action = _pendingAction
    if not action then return nil end

    local spellName = action.spellName
    local targetId = tonumber(action.targetId) or 0

    if not spellName or targetId <= 0 then
        return nil
    end

    local me = mq.TLO.Me
    local myId = me and me.ID and me.ID() or 0

    -- Determine claim type:
    -- - Self/group buffs: CAST-only (target is self or doesn't matter)
    -- - Single-target on others: Full ACTION claim (need target)
    local claimType = lib.ClaimType.CAST
    if not action.isSelfOnly and not action.isGroup and targetId ~= myId then
        claimType = lib.ClaimType.ACTION
    end

    return {
        kind = lib.ActionKind.CAST_SPELL,
        type = claimType,
        name = spellName,
        spellName = spellName,
        targetId = targetId,
        targetName = action.targetName,
        category = action.category,
        isSelfOnly = action.isSelfOnly,
        isGroup = action.isGroup,
        idempotencyKey = string.format('buff:%s:%d', action.category or 'buff', targetId),
        reason = _pendingReason or 'buff',
    }
end

module.executeAction = function(self)
    debugLog('executeAction: ENTERED')

    -- For buff claims, we need to handle differently based on claim type
    -- NOTE: explicit nil checks required — actors state can update between
    -- the ownsAction() guard in module_base and this access (file I/O in
    -- debugLog above can allow actors callbacks to deliver new state).
    if not self.state then
        debugLog('executeAction: no state')
        return false, 'no_action'
    end
    local castOwner = self.state.castOwner
    if not castOwner then
        debugLog('executeAction: no castOwner in state')
        return false, 'no_action'
    end
    local action = castOwner.action
    if not action then
        debugLog('executeAction: no action in castOwner')
        return false, 'no_action'
    end

    debugLog('executeAction: action=%s target=%d category=%s',
        tostring(action.spellName or action.name),
        tonumber(action.targetId) or 0,
        tostring(action.category))

    -- Check ownership based on what we requested
    local needsTargetOwnership = action.type == lib.ClaimType.ACTION
    if needsTargetOwnership then
        if not self:ownsAction() then
            debugLog('executeAction: no action ownership')
            return false, 'no_ownership'
        end
    else
        if not self:ownsCast() then
            debugLog('executeAction: no cast ownership')
            return false, 'no_cast_ownership'
        end
    end
    debugLog('executeAction: ownership OK')

    local settings = syncSettings()
    if not settings or settings.BuffingEnabled == false or settings.BuffingEnabled == 0 then
        return true, 'disabled'
    end

    local spellName = action.spellName or action.name
    local targetId = tonumber(action.targetId) or 0
    local category = action.category

    if not spellName or targetId <= 0 then
        return true, 'invalid_action'
    end

    local Buff = getBuff()

    -- Check if we're already working on this buff (subsequent tick calls)
    if _activeBuff.category == category and _activeBuff.spellName == spellName then
        local isCasting = lib.isCasting()
        debugLog('executeAction: Checking active buff, state=%s isCasting=%s', tostring(_activeBuff.state), tostring(isCasting))

        if _activeBuff.state == 'memorizing' then
            -- Still waiting for spell to memorize
            if not ensureBuffSpellMemorized(spellName) then
                debugLog('executeAction: Still memorizing')
                return false, 'memorizing'
            end
            -- Spell is memorized, check if ready
            if not isSpellReady(spellName) then
                debugLog('executeAction: Memorized but not ready yet')
                return false, 'spell_not_ready'
            end
            -- Ready to cast - ensure correct target first
            if not action.isGroup then
                if not ensureTarget(targetId) then
                    debugLog('executeAction: Failed to target %d for cast', targetId)
                    return false, 'target_failed'
                end
            end
            debugLog('executeAction: Spell ready, starting cast')
            _activeBuff.state = 'casting'
            mq.cmdf('/cast "%s"', spellName)
            return false, 'casting'

        elseif _activeBuff.state == 'casting' then
            -- Check if still casting
            if isCasting then
                debugLog('executeAction: Still casting')
                return false, 'casting'
            else
                -- Cast finished (or was interrupted)
                debugLog('executeAction: Cast finished, completing')
                lib.log('info', self.name, 'Buff cast completed: %s on %d', spellName, targetId)

                -- Track the buff with the caster-specific duration (accounts
                -- for our level + focus). Passing nil here used to fall through
                -- to trackLocalBuff's 1200s default, which suppressed rebuff
                -- for up to 20 min regardless of the real spell duration.
                if Buff and Buff.trackLocalBuff then
                    local spellId = getSpellId(spellName)
                    local duration = Buff.getMySpellDuration and Buff.getMySpellDuration(spellName) or nil
                    if action.isGroup then
                        local tracked = 0
                        local myId = lib.safeNum(function() return mq.TLO.Me.ID() end, 0)
                        for _, candidate in ipairs(groupBuffCandidates(myId)) do
                            local candidateId = tonumber(candidate.id) or 0
                            if candidateId > 0 then
                                Buff.trackLocalBuff(candidateId, category, spellId, spellName, duration)
                                tracked = tracked + 1
                            end
                        end
                        diagLog('track_local_' .. tostring(category), 0,
                            'trackLocalBuff group spell="%s" spellId=%s category=%s tracked=%d duration=%s castTargetId=%s',
                            tostring(spellName), tostring(spellId), tostring(category), tracked,
                            tostring(duration), tostring(targetId))
                    else
                        diagLog('track_local_' .. tostring(category), 0,
                            'trackLocalBuff spell="%s" spellId=%s category=%s targetId=%s duration=%s isGroup=%s',
                            tostring(spellName), tostring(spellId), tostring(category), tostring(targetId),
                            tostring(duration), tostring(action.isGroup))
                        Buff.trackLocalBuff(targetId, category, spellId, spellName, duration)
                    end
                end

                -- Track group cast cooldown
                if action.isGroup then
                    _lastGroupCastAt[category] = os.clock()
                end

                clearActiveBuff()
                return true, 'completed'
            end
        else
            -- Unknown state, restart
            debugLog('executeAction: Unknown state, clearing')
            clearActiveBuff()
        end
    end

    -- First time executing this action - set up and start cast
    debugLog('executeAction: First time - setting up cast for %s', spellName)

    -- Claim buff in cross-character system
    if Buff and Buff.claimBuff then
        if not Buff.claimBuff(targetId, category) then
            -- Already claimed by someone else
            debugLog('executeAction: Buff already claimed by another character')
            return true, 'buff_claimed'
        end
    end

    -- Set active buff state to 'memorizing' - the state machine above will handle the rest
    setActiveBuff(category, spellName, targetId, 'memorizing')
    debugLog('executeAction: Active buff set, starting memorization')

    -- Start memorizing the spell
    if not ensureBuffSpellMemorized(spellName) then
        debugLog('executeAction: Spell not memorized yet, returning false/memorizing')
        return false, 'memorizing'
    end

    -- If already memorized, check if ready to cast
    if isSpellReady(spellName) then
        -- Ensure correct target before casting
        if not action.isGroup then
            if not ensureTarget(targetId) then
                debugLog('executeAction: Failed to target %d for cast', targetId)
                return false, 'target_failed'
            end
        end
        debugLog('executeAction: Spell already ready, starting cast')
        _activeBuff.state = 'casting'
        mq.cmdf('/cast "%s"', spellName)
        return false, 'casting'
    end

    debugLog('executeAction: Spell memorized but not ready, returning false/spell_not_ready')
    return false, 'spell_not_ready'
end

-------------------------------------------------------------------------------
-- Custom requestClaim that handles both CAST-only and ACTION claims
-------------------------------------------------------------------------------

local originalRequestClaim = module.requestClaim

module.requestClaim = function(self, action)
    debugLog('requestClaim: ENTERED for action=%s', tostring(action and (action.spellName or action.name) or 'nil'))

    if not self:hasValidState() then
        lib.log('debug', self.name, 'Cannot claim: no valid state')
        debugLog('requestClaim: No valid state')
        return false
    end

    if self.claimPending then
        local elapsed = lib.getTimeMs() - self.claimRequestedAt
        if elapsed < 200 then
            debugLog('requestClaim: Claim still pending (elapsed=%dms)', elapsed)
            return false
        end
        self.claimPending = false
    end

    self.claimCounter = self.claimCounter + 1
    self.currentClaimId = lib.generateClaimId(self.name, self.claimCounter)
    debugLog('requestClaim: Generated claimId=%s', self.currentClaimId)

    -- Determine claim type from action
    local claimType = action.type or lib.ClaimType.CAST
    local wants = claimType == lib.ClaimType.ACTION and { 'target', 'cast' } or { 'cast' }

    -- Calculate TTL based on spell cast time (buff casts can take several seconds)
    local ttlMs = 10000  -- Default 10 seconds for buffs (includes mem time + cast time)
    local spellName = action.spellName or action.name
    if spellName then
        local spell = mq.TLO.Spell(spellName)
        if spell and spell() and spell.MyCastTime then
            local castTimeMs = tonumber(spell.MyCastTime()) or 3000
            -- TTL = mem time (up to 5s) + cast time + buffer (2s)
            ttlMs = 5000 + castTimeMs + 2000
        end
    end

    local claim = {
        msgType = 'claim',
        type = claimType,
        wants = wants,
        module = self.name,
        ownerName = lib.getMyName(),
        ownerServer = lib.getMyServer(),
        priority = self.priority,
        claimId = self.currentClaimId,
        epochSeen = self.state.epoch,
        ttlMs = ttlMs,
        reason = action.reason or 'buff',
        action = action,
    }

    self.claimPending = true
    self.claimRequestedAt = lib.getTimeMs()

    local ok, err = pcall(function()
        self.dropbox:send({ mailbox = lib.Mailbox.CLAIM, script = lib.Scripts.COORDINATOR }, claim)
    end)

    if ok then
        debugLog('requestClaim: Claim sent successfully: %s type=%s epoch=%d ttlMs=%d',
            self.currentClaimId, claimType, self.state.epoch, ttlMs)
    else
        debugLog('requestClaim: Claim send FAILED: %s', tostring(err))
    end

    lib.log('debug', self.name, 'Claim requested: %s (type=%s, epoch=%d)', self.currentClaimId, claimType, self.state.epoch)
    return true
end

-- Override ownsAction to handle CAST-only claims (buff module only needs cast, not target)
module.ownsAction = function(self)
    -- For CAST-only claims, we only need cast ownership (not target)
    local ownsCast = self:ownsCast()
    if not ownsCast then
        return false
    end

    -- Check if this is a CAST-only claim
    local owner = self.state.castOwner
    if owner and owner.action and owner.action.type == lib.ClaimType.CAST then
        debugLog('ownsAction: CAST-only claim, returning true')
        return true
    end

    -- For ACTION claims, also need target ownership
    local ownsTarget = self:ownsTarget()
    debugLog('ownsAction: ACTION claim, ownsTarget=%s', tostring(ownsTarget))
    return ownsTarget
end

-------------------------------------------------------------------------------
-- Command Binding
-------------------------------------------------------------------------------

mq.bind('/sk_buffs', function(cmd, arg)
    cmd = tostring(cmd or '')
    arg = tostring(arg or '')
    if arg == '' and cmd:find('%s') then
        local first, rest = cmd:match('^(%S+)%s+(.+)$')
        cmd = first or cmd
        arg = rest or ''
    end
    cmd = cmd:lower()
    arg = arg:lower()
    if cmd == 'stop' then
        module:stop()
        lib.log('info', module.name, 'Stop requested')
    elseif cmd == 'status' then
        local settings = syncSettings()
        local defCount = 0
        for _ in pairs(_buffDefinitions) do defCount = defCount + 1 end
        lib.log('info', module.name, 'running=%s, hasState=%s, isMyPriority=%s, ownsCast=%s, buffingEnabled=%s, defs=%d, reason=%s',
            tostring(module.running),
            tostring(module:hasValidState()),
            tostring(module:isMyPriority()),
            tostring(module:ownsCast()),
            tostring(settings.BuffingEnabled),
            defCount,
            tostring(_lastBuffScanReason))
    elseif cmd == 'reload' then
        _persistenceLoaded = false
        loadBuffDefinitions()
        lib.log('info', module.name, 'Buff definitions reloaded')
    elseif cmd == 'debug' then
        _buffDebugEnabled = (arg == 'on' or arg == '1' or arg == 'true')
        _diagThrottle = {}
        local BuffLogger = getBuffLogger()
        if BuffLogger and BuffLogger.init then
            BuffLogger.init({ level = 'debug', enabled = true })
        end
        lib.log('info', module.name, 'Buff diagnostics %s', _buffDebugEnabled and 'enabled' or 'disabled')
    end
end)

-------------------------------------------------------------------------------
-- Initialize and Run
-------------------------------------------------------------------------------

-- Get self name on load
local me = mq.TLO.Me
if me and me() then
    _selfName = me.CleanName and me.CleanName() or ''
end

-- Load initial buff definitions
loadBuffDefinitions()

module:run(50)

return module
