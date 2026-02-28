local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local Core = require('sidekick-next.utils.core')
local RuntimeCache = require('sidekick-next.utils.runtime_cache')
local HealTargeting = require('sidekick-next.utils.heal_targeting')
local ActorsCoordinator = require('sidekick-next.utils.actors_coordinator')

local M = {}

-- Logging
local getThrottledLog = lazy('sidekick-next.utils.throttled_log')

M.debugHealLineMapping = false

local _state = {
    priorityActive = false,
    lastDecisionAt = 0,
    lastHealCastAt = 0,
    localHots = {}, -- [targetId][spellName] = expiresAt
}

local function safeNum(fn, fallback)
    local ok, v = pcall(fn)
    if not ok then return fallback end
    return tonumber(v) or fallback
end

local function prune_map(map, now)
    for id, spells in pairs(map) do
        local any = false
        for spellName, exp in pairs(spells or {}) do
            if (tonumber(exp) or 0) <= now then
                spells[spellName] = nil
            else
                any = true
            end
        end
        if not any then
            map[id] = nil
        end
    end
end

local function normalize_class()
    local c = tostring((RuntimeCache.me and RuntimeCache.me.class) or ''):upper()
    if c == '' and mq.TLO.Me and mq.TLO.Me.Class and mq.TLO.Me.Class.ShortName then
        c = tostring(mq.TLO.Me.Class.ShortName() or ''):upper()
    end
    return c
end

local function spell_memorized(spellName)
    if not spellName or spellName == '' then return false end
    local me = mq.TLO.Me
    if not (me and me()) then return false end
    local gems = tonumber(me.NumGems()) or 13
    for i = 1, gems do
        local gem = me.Gem(i)
        if gem and gem() and (gem.Name() or '') == spellName then
            return true
        end
    end
    return false
end

local function resolve_spell_line(classConfig, lineName)
    if not classConfig or not classConfig.spellLines or not lineName then return nil end
    local line = classConfig.spellLines[lineName]
    if type(line) ~= 'table' then return nil end
    local me = mq.TLO.Me
    if not (me and me()) then return nil end
    for _, name in ipairs(line) do
        if spell_memorized(name) then
            return name
        end
    end
    return nil
end

local function load_class_config(classShort)
    local ok, config = pcall(require, string.format('data.class_configs.%s', classShort))
    if ok then return config end
    return nil
end

local function get_profile(classShort, classConfig)
    -- Profiles are line-name lists; resolve_spell_line chooses the best memorized spell.
    if classShort == 'CLR' then
        return {
            -- These must match the keys in data/class_configs/CLR.lua spellLines.
            main = { 'RemedyHeal', 'HealNuke', 'NukeHeal', 'HealingLight' },
            big = { 'Renewal', 'HealNuke', 'RemedyHeal', 'HealingLight' },
            group = { 'GroupFastHeal', 'GroupHealCure' },
            hotSingle = { 'SingleElixir' },
            hotGroup = { 'GroupElixir', 'GroupAcquittal' },
        }
    end
    if classShort == 'SHM' then
        return {
            main = { 'RecklessHeal1', 'RecourseHeal' },
            big = { 'InterventionHeal', 'RecklessHeal2', 'RecourseHeal' },
            group = { 'AESpiritualHeal' },
            hotGroup = { 'GroupRenewalHoT' },
        }
    end
    if classShort == 'DRU' then
        return {
            main = { 'QuickHealSurge', 'QuickHeal' },
            big = { 'LongHeal1', 'QuickHealSurge' },
            group = { 'QuickGroupHeal', 'LongGroupHeal' },
        }
    end
    if classShort == 'RNG' then
        return {
            main = { 'Fastheal', 'Heal' },
            big = { 'Heal' },
            hotSingle = { 'RegenSpells' },
        }
    end
    if classShort == 'BST' then
        return {
            main = { 'HealSpell' },
            pet = { 'PetHealSpell' },
        }
    end

    -- Default: no heal profile.
    return nil
end

local function is_hot_spell(spellName)
    if not spellName or spellName == '' then return false end
    local spell = mq.TLO.Spell(spellName)
    if not (spell and spell()) then return false end
    local isDetrimental = tostring(spell.SpellType and spell.SpellType() or ''):lower() == 'detrimental'
    if isDetrimental then return false end
    if spell.HasSPA and spell.HasSPA(79) then
        local ok, v = pcall(function() return spell.HasSPA(79)() end)
        return ok and v == true
    end
    return false
end

local function hot_duration_seconds(spellName)
    local spell = mq.TLO.Spell(spellName)
    if not (spell and spell()) then return 0 end
    if spell.Duration and spell.Duration.TotalSeconds then
        local ok, v = pcall(function() return spell.Duration.TotalSeconds() end)
        if ok then return tonumber(v) or 0 end
    end
    return 0
end

local function get_hot_remaining(targetId, now)
    local best = 0
    local own = _state.localHots[targetId]
    if own then
        for _, exp in pairs(own) do
            local rem = (tonumber(exp) or 0) - now
            if rem > best then best = rem end
        end
    end

    local remote = ActorsCoordinator and ActorsCoordinator.getHoTStates and ActorsCoordinator.getHoTStates() or nil
    local perTarget = remote and remote[targetId] or nil
    if perTarget then
        for _, info in pairs(perTarget) do
            local exp = tonumber(info.expiresAt) or 0
            local rem = exp - now
            if rem > best then best = rem end
        end
    end

    return best
end

local function has_active_claim(targetId, now)
    local claims = ActorsCoordinator and ActorsCoordinator.getHealClaims and ActorsCoordinator.getHealClaims() or nil
    local perTarget = claims and claims[targetId] or nil
    if not perTarget then return false end
    for _, c in pairs(perTarget) do
        if (tonumber(c.expiresAt) or 0) > now then
            return true
        end
    end
    return false
end

local function broadcast_claim(targetId, tier, spellName, castTimeSec)
    if not (ActorsCoordinator and ActorsCoordinator.broadcast) then return end
    local now = os.clock()
    local exp = now + (castTimeSec or 2.0) + 1.0
    ActorsCoordinator.broadcast('heal:claim', {
        targetId = targetId,
        tier = tier,
        spellName = spellName,
        expiresAt = exp,
    })
end

local function broadcast_hot(targetId, spellName, exp)
    if not (ActorsCoordinator and ActorsCoordinator.broadcast) then return end
    ActorsCoordinator.broadcast('heal:hots', {
        targetId = targetId,
        spellName = spellName,
        expiresAt = exp,
    })
end

local function is_line_enabled(settings, lineName)
    local key = 'HealLine_' .. tostring(lineName or '')
    if key == 'HealLine_' then return true end
    -- Default enabled unless explicitly disabled.
    return settings[key] ~= false
end

local function choose_spell_for_lines(classConfig, lines, settings)
    settings = settings or Core.Settings or {}
    local TL = getThrottledLog()

    for _, lineName in ipairs(lines or {}) do
        if not is_line_enabled(settings, lineName) then
            if M.debugHealLineMapping and TL then
                TL.log('heal_line_disabled_' .. tostring(lineName), 10, 'Healing: line disabled by setting HealLine_%s', tostring(lineName))
            end
            goto continue
        end
        local spellName = resolve_spell_line(classConfig, lineName)
        if spellName and spellName ~= '' then
            if M.debugHealLineMapping and TL then
                TL.log('heal_line_resolved_' .. tostring(lineName), 5, 'Healing: %s -> %s (memorized)', tostring(lineName), tostring(spellName))
            end
            return spellName
        end
        if M.debugHealLineMapping and TL then
            TL.log('heal_line_missing_' .. tostring(lineName), 10, 'Healing: no memorized spell found for line %s (check gems/loadout)', tostring(lineName))
        end
        ::continue::
    end
    return nil
end

local function can_heal_now(settings)
    local me = mq.TLO.Me
    if not (me and me()) then return false end
    if RuntimeCache.me and RuntimeCache.me.moving == true then return false end
    if me.Hovering and me.Hovering() then return false end
    if RuntimeCache.me and RuntimeCache.me.casting == true then return false end

    local inCombat = RuntimeCache.inCombat and RuntimeCache.inCombat() or false
    local invis = safeNum(function() return me.Invis() end, 0) ~= 0
    if invis and not inCombat and settings.HealBreakInvisOOC ~= true then
        return false
    end

    local ok, ActionExecutor = pcall(require, 'sidekick-next.utils.action_executor')
    if ok and ActionExecutor and ActionExecutor.isSpellBusy and ActionExecutor.isSpellBusy() then
        return false
    end
    return true
end

function M.isPriorityActive()
    return _state.priorityActive == true
end

function M.tick(settings)
    settings = settings or Core.Settings or {}
    if settings.DoHeals ~= true then
        _state.priorityActive = false
        return false
    end

    local classShort = normalize_class()
    local now = os.clock()
    prune_map(_state.localHots, now)
    if ActorsCoordinator and ActorsCoordinator.pruneHealState then
        ActorsCoordinator.pruneHealState()
    end

    if not can_heal_now(settings) then
        _state.priorityActive = false
        return false
    end

    if (now - (_state.lastDecisionAt or 0)) < 0.10 then
        return _state.priorityActive
    end
    _state.lastDecisionAt = now

    local classConfig = load_class_config(classShort)
    local profile = get_profile(classShort, classConfig)
    if not profile then
        _state.priorityActive = false
        return false
    end

    local mainPoint = tonumber(settings.MainHealPoint) or 80
    local bigPoint = tonumber(settings.BigHealPoint) or 50
    local groupPoint = tonumber(settings.GroupHealPoint) or 75
    local injCnt = tonumber(settings.GroupInjureCnt) or 2
    local petPoint = tonumber(settings.PetHealPoint) or 50
    local hotWindow = tonumber(settings.HealHoTMinSeconds) or 6

    local doPetHeals = settings.DoPetHeals == true or settings.HealPetsEnabled == true
    local doMA = settings.HealWatchMA == true
    local doXT = settings.HealXTargetEnabled == true

    local groupInjured = HealTargeting.groupInjuredCount(groupPoint)
    local needGroup = groupInjured >= injCnt

    local worst = HealTargeting.findWorstGroupTarget(mainPoint)
    local worstPet = (doPetHeals and HealTargeting.findWorstPetTarget(petPoint)) or nil
    local worstXT = (doXT and HealTargeting.findWorstXTarget(settings.HealXTargetSlots, mainPoint, doPetHeals)) or nil
    local ma = (doMA and HealTargeting.getMainAssistTarget()) or nil

    local candidates = {}
    for _, c in ipairs({ worst, worstPet, worstXT, ma }) do
        if c and (c.id or 0) > 0 then
            local hp = tonumber(c.hp) or 100
            if hp < 100 then
                table.insert(candidates, c)
            end
        end
    end
    table.sort(candidates, function(a, b) return (a.hp or 100) < (b.hp or 100) end)
    local target = candidates[1]

    local needAny = needGroup or (target ~= nil and (target.hp or 100) <= mainPoint)
    _state.priorityActive = needAny and (settings.PriorityHealing == true) or false
    if not needAny then
        return _state.priorityActive
    end

    local tier = nil
    local targetId = 0
    if needGroup and profile.group then
        tier = 'group'
        targetId = safeNum(function() return mq.TLO.Me.ID() end, 0)
    elseif target then
        targetId = tonumber(target.id) or 0
        if (target.hp or 100) <= bigPoint and profile.big then
            tier = 'big'
        else
            tier = 'main'
        end
        if target.kind == 'pet' and profile.pet then
            tier = 'pet'
        end
    end

    if not tier or targetId <= 0 then
        return _state.priorityActive
    end

    if settings.HealCoordinateActors ~= false and has_active_claim(targetId, now) then
        -- Someone else is already healing this target; do not pile on unless it is an emergency.
        if tier ~= 'big' then
            return _state.priorityActive
        end
    end

    local useHots = settings.HealUseHoTs ~= false and settings.HealTrackHoTsViaActors ~= false
    local spellName = nil
    local hotChosen = false

        if useHots and tier == 'main' then
            local rem = get_hot_remaining(targetId, now)
            if rem <= hotWindow then
            local hotSpell = choose_spell_for_lines(classConfig, profile.hotSingle, settings)
            if hotSpell and is_hot_spell(hotSpell) then
                spellName = hotSpell
                hotChosen = true
            end
            end
        end

        if useHots and tier == 'group' then
            local rem = get_hot_remaining(targetId, now)
            if rem <= hotWindow then
            local hotSpell = choose_spell_for_lines(classConfig, profile.hotGroup, settings)
            if hotSpell and is_hot_spell(hotSpell) then
                spellName = hotSpell
                hotChosen = true
            end
            end
        end

        if not spellName then
            if tier == 'pet' then
            spellName = choose_spell_for_lines(classConfig, profile.pet, settings) or choose_spell_for_lines(classConfig, profile.main, settings)
            elseif tier == 'big' then
            spellName = choose_spell_for_lines(classConfig, profile.big, settings) or choose_spell_for_lines(classConfig, profile.main, settings)
            elseif tier == 'group' then
            spellName = choose_spell_for_lines(classConfig, profile.group, settings)
            else
            spellName = choose_spell_for_lines(classConfig, profile.main, settings)
            end
        end

    if not spellName then
        return _state.priorityActive
    end

    local okSE, SpellEngine = pcall(require, 'sidekick-next.utils.spell_engine')
    if not okSE or not SpellEngine or not SpellEngine.cast then
        return _state.priorityActive
    end
    if SpellEngine.isBusy and SpellEngine.isBusy() then
        return _state.priorityActive
    end

    local castTimeMs = safeNum(function() return mq.TLO.Spell(spellName).MyCastTime() end, 2000)
    broadcast_claim(targetId, tier, spellName, (castTimeMs / 1000))

    local success = SpellEngine.cast(spellName, targetId, { spellCategory = 'heal' })
    if success then
        _state.lastHealCastAt = now
        if hotChosen and is_hot_spell(spellName) then
            local dur = hot_duration_seconds(spellName)
            local exp = now + (dur > 0 and dur or 18)
            _state.localHots[targetId] = _state.localHots[targetId] or {}
            _state.localHots[targetId][spellName] = exp
            if settings.HealTrackHoTsViaActors ~= false then
                broadcast_hot(targetId, spellName, exp)
            end
        end
    end

    return _state.priorityActive
end

return M
