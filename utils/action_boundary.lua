-- Final local admission check for automatic gameplay mutations.
--
-- This module deliberately does not schedule work.  It is a worker-side guard
-- that verifies the exact lease and the mutable game/settings facts immediately
-- before a command is issued.

local mq = require('mq')
local lib = require('sidekick-next.sk_lib')

local M = {}

local function setting(settings, name, fallback)
    local value = settings and settings[name]
    if value == nil then return fallback end
    return value
end

local function actionKind(action)
    return tostring(action and action.kind or ''):lower()
end

local function targetMatches(action)
    local targetId = tonumber(action and action.targetId) or 0
    if targetId <= 0 then return true end
    local spawn = mq.TLO.Spawn(targetId)
    if not (spawn and spawn()) then return false, 'target_missing' end

    local expectedName = tostring(action.targetName or action.expectedTargetName or '')
    if expectedName ~= '' then
        local actualName = tostring(spawn.CleanName() or ''):lower()
        if actualName ~= expectedName:lower() then return false, 'target_name_changed' end
    end

    local expectedType = tostring(action.targetType or action.expectedTargetType or '')
    if expectedType ~= '' then
        local actualType = tostring(spawn.Type() or ''):lower()
        if actualType ~= expectedType:lower() then return false, 'target_type_changed' end
    end
    return true
end

function M.validate(worker, action, opts)
    opts = opts or {}
    if not worker or not worker.ownsLease or not worker:ownsLease() then
        return false, 'lease_invalid'
    end
    if not lib.isInGame() then return false, 'not_ingame' end

    local state = worker.state or {}
    if state.automationPaused == true
        or tostring(state.lifecycle or 'running') ~= 'running' then
        return false, 'automation_paused'
    end

    if lib.isSelfDeadOrHovering and lib.isSelfDeadOrHovering()
        and not worker.canActDead then
        return false, 'self_dead'
    end
    local incapacitated, reason = lib.isIncapacitated()
    if incapacitated then
        return false, 'incapacitated:' .. tostring(reason or 'unknown')
    end

    local settings = lib.getSettings and lib.getSettings() or {}
    local spec = lib.getWorkerSpec and lib.getWorkerSpec(worker.name) or nil
    if spec and spec.enableSetting
        and settings[spec.enableSetting] == false then
        return false, 'worker_disabled:' .. tostring(spec.enableSetting)
    end
    local kind = actionKind(action)
    if kind == 'cast_spell' or kind == 'spell' then
        if setting(settings, 'UseSpells', true) == false then
            return false, 'spells_disabled'
        end
    elseif kind == 'spell_memorize' or kind == 'scribing' then
        if setting(settings, 'UseSpells', true) == false then
            return false, 'spells_disabled'
        end
        if action and action.mode ~= 'cleanup'
            and lib.inCombat and lib.inCombat() then
            return false, 'cannot_memorize_in_combat'
        end
    elseif kind == 'use_aa' or kind == 'aa' then
        if setting(settings, 'UseAAs', true) == false
            or setting(settings, 'AutoAbilitiesEnabled', true) == false then
            return false, 'aas_disabled'
        end
    elseif kind == 'use_disc' or kind == 'disc' or kind == 'discipline' then
        if setting(settings, 'UseDiscs', true) == false
            or setting(settings, 'AutoAbilitiesEnabled', true) == false then
            return false, 'discs_disabled'
        end
    elseif kind == 'use_item' or kind == 'item' then
        if setting(settings, 'AutoItemsEnabled', true) == false then
            return false, 'items_disabled'
        end
    elseif kind == 'movement' or kind == 'chase' or kind == 'navigate' then
        if tostring(setting(settings, 'AutomationLevel', 'auto')):lower() ~= 'auto' then
            return false, 'movement_not_allowed'
        end
    end

    local invis = lib.safeTLO(function()
        return mq.TLO.Me.Invis() or mq.TLO.Me.InvisToUndead()
    end, false) == true
    if invis and action and action.breaksInvis ~= false then
        local inCombat = lib.inCombat and lib.inCombat() or false
        local allow = action.allowBreakInvis == true
            or (inCombat and action.combatAction == true)
            or (action.healAction == true
                and setting(settings, 'HealBreakInvisOOC', false) == true)
        if not allow then return false, 'invisibility_preserved' end
    end

    if opts.skipTarget ~= true then
        local ok, targetReason = targetMatches(action)
        if not ok then return false, targetReason end
    end
    return true
end

function M.require(worker, action, opts)
    local ok, reason = M.validate(worker, action, opts)
    if not ok and lib.log then
        lib.log('debug', worker and worker.name or 'action',
            'Mutation blocked at final boundary: %s', tostring(reason))
    end
    return ok, reason
end

return M
