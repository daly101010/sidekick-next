-- F:/lua/sidekick-next/sk_buffs.lua
-- Buff module for SideKick multi-script system
-- Priority 6: OOC buff casting through coordinator claims
-- Maintains cross-character coordination via Actors

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')

-- Create module instance
local module = ModuleBase.create('buffs', lib.Priority.BUFF)

-- Debug logging (set to true to enable)
local DEBUG_BUFFS = true
local DEBUG_LOG_FILE = mq.configDir .. '/sk_buffs_debug.log'

local function debugLog(fmt, ...)
    if not DEBUG_BUFFS then return end
    local msg = string.format(fmt, ...)
    local timestamp = os.date('%H:%M:%S')
    local f = io.open(DEBUG_LOG_FILE, 'a')
    if f then
        f:write(string.format('[%s] %s\n', timestamp, msg))
        f:close()
    end
end

-- Clear log file on startup
local function clearLogFile()
    local f = io.open(DEBUG_LOG_FILE, 'w')
    if f then
        f:write(string.format('=== SK_BUFFS DEBUG LOG STARTED %s ===\n', os.date('%Y-%m-%d %H:%M:%S')))
        f:close()
    end
end
clearLogFile()

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

local BUFF_TICK_INTERVAL = 0.5             -- Casting tick interval (500ms)
local DEFAULT_REBUFF_WINDOW = 60           -- Default seconds before expiry to rebuff
local BUFF_CHECK_INTERVAL = 60.0           -- How often to recheck buff status on targets
local BUFF_DEFS_REFRESH_INTERVAL = 5.0     -- Refresh buff definitions if empty
local BUFF_DEFS_PERIODIC_REFRESH = 30.0    -- Periodic refresh to pick up spell set changes
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
local _lastBuffTick = 0
local _lastBuffDefsRefresh = 0
local _initialScanComplete = false
local _lastInitialScanAttempt = 0
local _selfName = ''

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

local _Core = nil
local function getCore()
    if not _Core then
        local ok, c = pcall(require, 'sidekick-next.utils.core')
        if ok then _Core = c end
    end
    return _Core
end

local _Cache = nil
local function getCache()
    if not _Cache then
        local ok, c = pcall(require, 'sidekick-next.utils.runtime_cache')
        if ok then _Cache = c end
    end
    return _Cache
end

local _SpellEngine = nil
local function getSpellEngine()
    if not _SpellEngine then
        local ok, se = pcall(require, 'sidekick-next.utils.spell_engine')
        if ok then _SpellEngine = se end
    end
    return _SpellEngine
end

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

local _Buff = nil
local function getBuff()
    if not _Buff then
        local ok, b = pcall(require, 'sidekick-next.automation.buff')
        if ok then _Buff = b end
    end
    return _Buff
end

-------------------------------------------------------------------------------
-- Helper Functions
-------------------------------------------------------------------------------

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

local function selfHasBuff(spellName)
    if not spellName then return false end

    local me = mq.TLO.Me
    if not me or not me() then return false end

    -- Check Buff window
    local buff = me.Buff(spellName)
    if buff and buff() then
        return true
    end

    -- Check Song window (for bard songs)
    local song = me.Song(spellName)
    if song and song() then
        return true
    end

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
    _buffDefinitions = {}

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
        return
    end

    -- sk_buffs.lua runs as a separate script, so we need to load spell sets from disk
    -- This is only done once per session to avoid repeated disk reads
    if not _persistenceLoaded then
        debugLog('loadBuffDefinitions: Loading spell sets from disk (first time)')
        local ok, err = pcall(function()
            Persistence.load()
        end)
        if not ok then
            debugLog('loadBuffDefinitions: Persistence.load() failed: %s', tostring(err))
        else
            _persistenceLoaded = true
            debugLog('loadBuffDefinitions: Spell sets loaded, activeSetName=%s', tostring(Persistence.activeSetName))
        end
    end

    local spellSet = Persistence.getActiveSet()
    if not spellSet then
        debugLog('loadBuffDefinitions: No active spell set (activeSetName=%s)', tostring(Persistence.activeSetName))
        return
    end

    local enabledBuffs = SpellSetData.getEnabledOocBuffs(spellSet)
    if not enabledBuffs or #enabledBuffs == 0 then
        debugLog('loadBuffDefinitions: No enabled OOC buffs in spell set')
        return
    end

    debugLog('loadBuffDefinitions: Found %d enabled OOC buffs', #enabledBuffs)

    for _, buffConfig in ipairs(enabledBuffs) do
        local spell = mq.TLO.Spell(buffConfig.spellId)
        local spellName = spell and spell.Name() or nil
        if spellName then
            local category = string.format('oocbuff_%d', buffConfig.spellId)
            _buffDefinitions[category] = {
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
        end
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
    local Cache = getCache()
    local inCombat = Cache and Cache.inCombat and Cache.inCombat() or false
    if inCombat then return false, 'in_combat' end

    -- Check invis
    if me.Invis and me.Invis() then return false, 'invis' end

    -- Check movement plugins
    if (mq.TLO.MoveTo and mq.TLO.MoveTo.Moving and mq.TLO.MoveTo.Moving())
        or (mq.TLO.Navigation and mq.TLO.Navigation.Active and mq.TLO.Navigation.Active())
        or (mq.TLO.AdvPath and mq.TLO.AdvPath.Following and mq.TLO.AdvPath.Following())
        or (mq.TLO.Stick and mq.TLO.Stick.Active and mq.TLO.Stick.Active()) then
        return false, 'movement_plugin'
    end

    -- Check if moving
    if me.Moving() then return false, 'moving' end

    -- Check if already casting
    local casting = me.Casting() or ''
    if casting ~= '' then return false, 'casting' end

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
        return nil
    end

    local settings = syncSettings()

    -- Check if buffing is enabled
    local buffingEnabled = settings.BuffingEnabled
    if buffingEnabled == false or buffingEnabled == 0 then
        debugLog('findBuffNeed: Buffing disabled')
        return nil
    end

    -- Check if we can buff now
    local canBuff, reason = canBuffNow()
    if not canBuff then
        debugLog('findBuffNeed: Cannot buff now: %s', tostring(reason))
        return nil
    end

    refreshBuffDefinitionsIfNeeded()

    if not next(_buffDefinitions) then
        debugLog('findBuffNeed: No buff definitions')
        return nil
    end

    -- NOTE: Initial scan check removed - we no longer depend on the old buff module
    -- The coordinator system uses Cache for buff state tracking instead

    debugLog('findBuffNeed: Checking %d buff definitions', #getSortedBuffDefinitions())

    local now = os.clock()
    local me = mq.TLO.Me
    local myId = me and me.ID and me.ID() or 0

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
                    local hasBuff = selfHasBuff(spellName)
                    debugLog('findBuffNeed: Self-buff %s hasBuff=%s', spellName, tostring(hasBuff))

                    if not hasBuff then
                        -- Check if spell would stack (not blocked by existing buffs)
                        local wouldStack = spellWouldStack(spellName)
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
                    end
                end
            else
                -- Group or single-target buff: check group members directly
                -- Check group cast cooldown first
                if isGroup then
                    local lastCast = _lastGroupCastAt[category] or 0
                    if (now - lastCast) < GROUP_CAST_COOLDOWN then
                        debugLog('findBuffNeed: Group buff %s on cooldown', spellName)
                        goto continue_buff
                    end
                end

                -- Check self first for group buffs
                local hasSelfBuff = selfHasBuff(spellName)
                debugLog('findBuffNeed: Group/single buff %s selfHasBuff=%s', spellName, tostring(hasSelfBuff))

                if not hasSelfBuff then
                    -- Check if spell would stack (not blocked by existing buffs)
                    local wouldStack = spellWouldStack(spellName)
                    if not wouldStack then
                        debugLog('findBuffNeed: Group/single buff %s would not stack, skipping', spellName)
                        goto continue_buff
                    end

                    -- Check if we have enough mana
                    if not hasEnoughMana(spellName) then
                        debugLog('findBuffNeed: Group/single buff %s not enough mana, skipping', spellName)
                        goto continue_buff
                    end

                    debugLog('findBuffNeed: FOUND buff %s on SELF (category=%s, isGroup=%s)',
                        spellName, category, tostring(isGroup))
                    return {
                        category = category,
                        spellName = spellName,
                        targetId = myId,
                        targetName = _selfName,
                        isSelfOnly = false,
                        isGroup = isGroup,
                    }
                end

                -- TODO: Check group members for single-target buffs
                -- For now, just handle self-buffing
            end
        end
        ::continue_buff::
    end

    debugLog('findBuffNeed: No buffs needed')
    return nil
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
        self:sendNeed(false)
        return
    end

    -- Check if buffing is enabled
    local buffingEnabled = settings.BuffingEnabled
    if buffingEnabled == false or buffingEnabled == 0 then
        _pendingAction = nil
        maybeRestoreBuffGem()
        self:sendNeed(false)
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
        self:sendNeed(true, 5000)  -- Long TTL while casting
        return
    end

    -- Also check cast ownership (in case _activeBuff got cleared but we still own)
    if ownsCast then
        debugLog('onTick: Sending NEED=true (owns cast)')
        self:sendNeed(true, 5000)  -- Long TTL while casting
        return
    end

    -- Rate limit buff tick (only for finding new buffs, not for maintaining cast ownership)
    local now = os.clock()
    if (now - _lastBuffTick) < BUFF_TICK_INTERVAL then
        -- Still send need if we have pending action
        if _pendingAction then
            self:sendNeed(true, 1000)
        end
        return
    end
    _lastBuffTick = now

    -- Find if we have buff work to do
    local need = findBuffNeed()

    _pendingAction = need
    _pendingReason = need and 'buff_needed' or nil

    local needsAction = need ~= nil
    debugLog('onTick: findBuffNeed=%s needsAction=%s',
        need and need.spellName or 'nil', tostring(needsAction))
    self:sendNeed(needsAction, needsAction and 1500 or nil)

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
    local action = self.state and self.state.castOwner and self.state.castOwner.action
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
            -- Ready to cast - do it now
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

                -- Track the buff
                if Buff and Buff.trackLocalBuff then
                    local spellId = getSpellId(spellName)
                    Buff.trackLocalBuff(targetId, category, spellId, spellName, nil)
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

mq.bind('/sk_buffs', function(cmd)
    if cmd == 'stop' then
        module:stop()
        lib.log('info', module.name, 'Stop requested')
    elseif cmd == 'status' then
        local settings = syncSettings()
        lib.log('info', module.name, 'running=%s, hasState=%s, isMyPriority=%s, ownsCast=%s, buffingEnabled=%s',
            tostring(module.running),
            tostring(module:hasValidState()),
            tostring(module:isMyPriority()),
            tostring(module:ownsCast()),
            tostring(settings.BuffingEnabled))
    elseif cmd == 'reload' then
        loadBuffDefinitions()
        lib.log('info', module.name, 'Buff definitions reloaded')
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
