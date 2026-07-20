-- F:/lua/sidekick-next/sk_resources.lua
-- Resource conversion module for SideKick multi-script system.
-- Casts spell-set gem entries marked as in-combat and/or out-of-combat utility.

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')
local ModuleBase = require('sidekick-next.sk_module_base')

local module = ModuleBase.create('resources', lib.Priority.IDLE)

local Config = {
    enabled = true,
    minSecondsBetweenCasts = 3,
}

local _settings = nil
local _settingsLoadedAt = 0
local _lastCastAtMs = 0
local _lastReason = 'init'
local _lastSpellSetLoadAt = 0
local _lastSpellSetPath = nil

local function commandEcho(fmt, ...)
    local msg
    if select('#', ...) > 0 then
        local ok, formatted = pcall(string.format, fmt, ...)
        msg = ok and formatted or tostring(fmt)
    else
        msg = tostring(fmt)
    end
    pcall(function() print(string.format('\ag[SK Resources]\ax %s', msg)) end)
end

local function toBool(v, default)
    if v == nil then return default end
    if type(v) == 'boolean' then return v end
    if type(v) == 'number' then return v ~= 0 end
    if type(v) == 'string' then
        local s = v:lower()
        return s == '1' or s == 'true' or s == 'yes' or s == 'on'
    end
    return default
end

local function loadSettingsFromIni()
    local settings = {}
    local okPaths, Paths = pcall(require, 'sidekick-next.utils.paths')
    if not okPaths or not Paths then return settings end

    local section = {}
    local okAtomic, AtomicIni = pcall(require, 'sidekick-next.utils.atomic_ini')
    if okAtomic and AtomicIni then
        local ini = AtomicIni.load(Paths.getModuleConfigPath('resources'))
        section = type(ini) == 'table' and (ini.Settings or {}) or {}
    end
    if next(section) == nil then
        local okLip, lip = pcall(require, 'LIP')
        if okLip and lip then
            local okIni, ini = pcall(lip.load, Paths.getMainConfigPath())
            if okIni and type(ini) == 'table' then section = ini.SideKick or ini['SideKick'] or {} end
        end
    end
    settings.enabled = toBool(section.ResourceConversionEnabled, Config.enabled)
    settings.minSecondsBetweenCasts = tonumber(section.ResourceMinSecondsBetweenCasts) or Config.minSecondsBetweenCasts
    return settings
end

local function getSettings()
    local now = lib.getTimeMs()
    if not _settings or (now - _settingsLoadedAt) >= 1000 then
        local loaded = loadSettingsFromIni()
        _settings = {
            enabled = loaded.enabled ~= nil and loaded.enabled or Config.enabled,
            minSecondsBetweenCasts = loaded.minSecondsBetweenCasts or Config.minSecondsBetweenCasts,
        }
        _settingsLoadedAt = now
    end
    return _settings
end

local function loadSpellSets(force)
    local ok, Persistence = pcall(require, 'sidekick-next.utils.spellset_persistence')
    if not ok or not Persistence then return nil, 'spellset_persistence_unavailable' end

    local now = os.clock()
    local shouldLoad = force == true or not Persistence.loaded or (now - (_lastSpellSetLoadAt or 0)) >= 5
    if shouldLoad and Persistence.load then
        local loadOk, loaded = pcall(Persistence.load)
        if not loadOk or loaded ~= true then
            return nil, 'spellset_load_failed:' .. tostring(loaded)
        end
        _lastSpellSetLoadAt = now
        if Persistence.getConfigPath then
            local pathOk, path = pcall(Persistence.getConfigPath)
            if pathOk then _lastSpellSetPath = path end
        end
    end
    return Persistence, nil
end

local function getActiveSpellSet()
    local Persistence, loadReason = loadSpellSets(false)
    if not Persistence then return nil, loadReason end
    if not Persistence.getActiveSet then return nil, 'spellset_api_missing' end
    local spellSet = Persistence.getActiveSet()
    if not spellSet then return nil, 'no_active_spellset:' .. tostring(Persistence.activeSetName) end
    return spellSet, nil
end

local function countUtilityGems(spellSet)
    local total = 0
    local combat = 0
    local ooc = 0
    for _, gemConfig in pairs((spellSet and spellSet.gems) or {}) do
        local utility = gemConfig and gemConfig.utility
        if utility and (utility.combat == true or utility.ooc == true) then
            total = total + 1
            if utility.combat == true then combat = combat + 1 end
            if utility.ooc == true then ooc = ooc + 1 end
        end
    end
    return total, combat, ooc
end

local function getSpellSetStatus()
    local Persistence, loadReason = loadSpellSets(false)
    if not Persistence then
        return {
            reason = loadReason,
            path = _lastSpellSetPath,
        }
    end

    local spellSet = Persistence.getActiveSet and Persistence.getActiveSet() or nil
    local utilityTotal, utilityCombat, utilityOoc = countUtilityGems(spellSet)
    return {
        activeSet = Persistence.activeSetName,
        loaded = Persistence.loaded,
        loadError = Persistence.loadError,
        pathError = Persistence.pathError,
        path = _lastSpellSetPath,
        gemCount = spellSet and spellSet.gems and (function()
            local n = 0
            for _ in pairs(spellSet.gems) do n = n + 1 end
            return n
        end)() or 0,
        utilityTotal = utilityTotal,
        utilityCombat = utilityCombat,
        utilityOoc = utilityOoc,
    }
end

local function getSpellName(spellId)
    if not spellId or tonumber(spellId) == nil then return nil end
    local spell = mq.TLO.Spell(tonumber(spellId))
    if spell and spell() and spell.Name then
        return spell.Name()
    end
    return nil
end

local function isSpellReady(spellName)
    local me = mq.TLO.Me
    if not (me and me()) then return false, 'no_character' end
    if not spellName or spellName == '' then return false, 'no_spell_name' end

    local gem = lib.safeNum(function() return me.Gem(spellName)() end, 0)
    if gem <= 0 then
        return false, 'spell_not_memorized:' .. spellName
    end

    local ready = lib.safeTLO(function() return me.SpellReady(spellName)() end, false) == true
    if not ready then
        return false, 'spell_not_ready:' .. spellName
    end

    return true, nil
end

local function conditionPasses(gemConfig, inCombat)
    if not gemConfig or not gemConfig.condition then return true, nil end

    local ok, ConditionBuilder = pcall(require, 'sidekick-next.ui.condition_builder')
    if not ok or not ConditionBuilder or not ConditionBuilder.evaluateWithContext then
        return false, 'condition_builder_unavailable'
    end

    local me = mq.TLO.Me
    local ctx = {
        myHp = lib.safeNum(function() return me.PctHPs() end, 100),
        myMana = lib.safeNum(function() return me.PctMana() end, 100),
        inCombat = inCombat,
    }

    local evalOk, result = pcall(ConditionBuilder.evaluateWithContext, gemConfig.condition, ctx)
    if not evalOk then
        return false, 'condition_error:' .. tostring(result)
    end
    if result ~= true then
        return false, 'condition_false'
    end

    return true, nil
end

local function findReadyResourceSpell()
    local me = mq.TLO.Me
    if not (me and me()) then return nil, 'no_character' end

    local spellSet, setReason = getActiveSpellSet()
    if not spellSet then return nil, setReason end

    local gems = spellSet.gems or {}
    local inCombat = lib.inCombat()
    local sawUtility = false
    local firstSkip = nil

    local totalGems = lib.safeNum(function() return me.NumGems() end, 13)
    for slot = 1, totalGems do
        local gemConfig = gems[slot]
        local utility = gemConfig and gemConfig.utility
        local enabledForState = utility and ((inCombat and utility.combat == true) or ((not inCombat) and utility.ooc == true))

        if enabledForState then
            sawUtility = true
            local spellName = getSpellName(gemConfig.spellId)
            if spellName then
                local conditionOk, conditionReason = conditionPasses(gemConfig, inCombat)
                if conditionOk then
                    local ready, readyReason = isSpellReady(spellName)
                    if ready then
                        return spellName, nil, slot
                    end
                    firstSkip = firstSkip or readyReason
                else
                    firstSkip = firstSkip or (conditionReason .. ':' .. spellName)
                end
            else
                firstSkip = firstSkip or 'invalid_spell_id:' .. tostring(gemConfig.spellId)
            end
        end
    end

    if not sawUtility then
        return nil, inCombat and 'no_combat_utility_spells' or 'no_ooc_utility_spells'
    end

    return nil, firstSkip or 'no_utility_spell_ready'
end

local function blockedByState(settings)
    local me = mq.TLO.Me
    if not (me and me()) then return 'no_character' end

    if settings.enabled == false then return 'disabled' end

    local inCombat = lib.inCombat()

    if lib.isCasting() then return 'casting' end
    if lib.safeTLO(function() return mq.TLO.Window('SpellBookWnd').Open() end, false) == true then return 'spellbook_open' end
    if lib.safeTLO(function() return me.Stunned() end, false) == true then return 'stunned' end
    if lib.safeTLO(function() return me.Feigning() end, false) == true then return 'feigning' end
    if lib.safeTLO(function() return me.Invis() end, false) == true then return 'invis' end

    local moving = lib.safeTLO(function() return me.Moving() end, false) == true
    if moving then return 'moving' end

    local nowMs = lib.getTimeMs()
    local minGapMs = math.max(0, tonumber(settings.minSecondsBetweenCasts) or 0) * 1000
    if minGapMs > 0 and (nowMs - (_lastCastAtMs or 0)) < minGapMs then
        return 'cast_cooldown'
    end

    local pctAggro = lib.safeNum(function() return me.PctAggro() end, 0)
    if inCombat and pctAggro >= 90 then
        return 'aggro_high'
    end

    return nil
end

local function getResourceNeed()
    local settings = getSettings()
    local block = blockedByState(settings)
    if block then return nil, block end

    local spellName, reason, slot = findReadyResourceSpell()
    if not spellName then return nil, reason end

    return {
        spellName = spellName,
        slot = slot,
        reason = 'spellset_utility',
    }, nil
end

module.onTick = function(self)
    local action, reason = getResourceNeed()
    _lastReason = action and 'ready:' .. tostring(action.spellName) or tostring(reason or 'none')
    self:sendNeed(action ~= nil, action and 1000 or nil, _lastReason)
end

module.shouldAct = function(self)
    if not self:hasValidState() then return false end
    local action = getResourceNeed()
    return action ~= nil
end

module.getAction = function(self)
    local action = getResourceNeed()
    if not action then return nil end

    local myId = lib.safeNum(function() return mq.TLO.Me.ID() end, 0)
    return {
        kind = lib.ActionKind.CAST_SPELL,
        type = lib.ClaimType.CAST,
        name = action.spellName,
        spellName = action.spellName,
        castTargetId = 0,
        castStartTimeoutMs = 4000,
        castOptions = {
            spellCategory = 'resource',
            sourceLayer = 'resources',
            maxRetries = 0,
        },
        targetId = myId,
        idempotencyKey = string.format('resource:%s:%d', action.spellName, math.floor(lib.getTimeMs() / 3000)),
        reason = action.reason,
    }
end

module.executeAction = function(self)
    if not self:ownsCast() then
        return false, 'no_cast_ownership'
    end

    local action = self.state and self.state.castOwner and self.state.castOwner.action
    if not action then return false, 'no_action' end

    local settings = getSettings()
    local block = blockedByState(settings)
    if block then return true, block end

    local spellName = action.spellName or action.name
    local readySpell, reason = findReadyResourceSpell()
    if readySpell ~= spellName then
        return true, reason or 'spell_changed'
    end

    local me = mq.TLO.Me
    if me and me() and me.Standing and not me.Standing() then
        if me.Stand then me.Stand() end
        mq.delay(100, function() return mq.TLO.Me.Standing() end)
    end

    lib.log('info', module.name, 'Casting resource spell: %s', spellName)
    mq.cmdf('/cast "%s"', spellName)
    mq.delay(150)

    if not lib.isCasting() then
        return true, 'cast_did_not_start'
    end

    local startMs = lib.getTimeMs()
    local maxWaitMs = 5000
    while lib.isCasting() do
        mq.delay(50)
        if not self:ownsCast() then return true, 'ownership_lost' end
        if (lib.getTimeMs() - startMs) > maxWaitMs then return true, 'cast_timeout' end
    end

    _lastCastAtMs = lib.getTimeMs()
    return true, 'completed'
end


module:enableUnifiedExecutor({
    preflight = function(action)
        local settings = getSettings()
        local block = blockedByState(settings)
        if block then return false, block end
        local readySpell, reason = findReadyResourceSpell()
        if readySpell ~= tostring(action.spellName or action.name or '') then
            return false, reason or 'spell_changed'
        end
        return true
    end,
    onComplete = function()
        _lastCastAtMs = lib.getTimeMs()
    end,
})

mq.bind('/sk_resources', function(cmd)
    cmd = tostring(cmd or ''):lower()
    if cmd == 'stop' then
        module:stop()
        lib.log('info', module.name, 'Stop requested')
        commandEcho('Stop requested')
    elseif cmd == 'reload' then
        _lastSpellSetLoadAt = 0
        local Persistence, reason = loadSpellSets(true)
        if Persistence then
            commandEcho('Reloaded spell sets: activeSet=%s path=%s', tostring(Persistence.activeSetName), tostring(_lastSpellSetPath))
        else
            commandEcho('Spell set reload failed: %s path=%s', tostring(reason), tostring(_lastSpellSetPath))
        end
    elseif cmd == 'status' or cmd == '' then
        local settings = getSettings()
        local spell, reason, slot = findReadyResourceSpell()
        local setStatus = getSpellSetStatus()
        local status = string.format(
            'running=%s hasState=%s priority=%s ownsCast=%s lastReason=%s enabled=%s activeSet=%s gems=%s utility=%s/%s/%s utilitySpell=%s slot=%s reason=%s path=%s loadError=%s pathError=%s',
            tostring(module.running),
            tostring(module:hasValidState()),
            tostring(module:isMyPriority()),
            tostring(module:ownsCast()),
            tostring(_lastReason),
            tostring(settings.enabled),
            tostring(setStatus.activeSet),
            tostring(setStatus.gemCount),
            tostring(setStatus.utilityTotal),
            tostring(setStatus.utilityCombat),
            tostring(setStatus.utilityOoc),
            tostring(spell),
            tostring(slot),
            tostring(reason),
            tostring(setStatus.path),
            tostring(setStatus.loadError),
            tostring(setStatus.pathError))
        lib.log('info', module.name, '%s', status)
        commandEcho('%s', status)
    else
        commandEcho('Usage: /sk_resources status|reload|stop')
    end
end)

module:run(50)

return module
