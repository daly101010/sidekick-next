-- F:/lua/sidekick-next/utils/discipline_engine.lua
-- Discipline / burn ability rotation engine.
--
-- Walks a class config's `defaultConditions` predicates in deterministic
-- key order. For each predicate that returns true, resolves the matching
-- ability line (discLines / aaLines / spellLines) to the best-available
-- name via class_config_loader, checks readiness (AA cooldown, combat
-- ability cooldown, spell mem+cooldown), and returns the first hit.
--
-- The engine is class-agnostic — it consumes whatever the class config
-- exposes. Classes without any disciplines or condition predicates yield
-- nil (the consumer module then bows out for the tick).
--
-- Predicates take a ctx table whose schema mirrors what the existing
-- class_configs/<CLASS>.lua condition functions assume:
--   ctx.me.pctHPs / pctMana / pctEndurance / activeDisc / pctAggro
--   ctx.me.buff(<name>)   -> truthy if buff active on self
--   ctx.combat            -> bool
--   ctx.burnNow           -> bool (the user's BurnNow setting)
--   ctx.target.id / pctHPs / named / secondaryPctAggro

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')

local getNamed        = lazy('sidekick-next.utils.named_detector')
local getCore         = lazy('sidekick-next.utils.core')
local getTargeting    = lazy('sidekick-next.utils.targeting')

local M = {}

-------------------------------------------------------------------------------
-- Safe TLO helpers
-------------------------------------------------------------------------------

local function safeTLO(fn, fallback)
    local ok, v = pcall(fn)
    if not ok then return fallback end
    if v == nil then return fallback end
    return v
end

local function safeNum(fn, fallback)
    local ok, v = pcall(fn)
    if not ok then return fallback end
    return tonumber(v) or fallback
end

-------------------------------------------------------------------------------
-- Context construction
-------------------------------------------------------------------------------

-- Count XTarget haters (the "in combat" indicator most class predicates
-- want, e.g. ctx.me.xTargetCount >= 3 for AE-disc gates).
local function countXTargetHaters(me)
    local n = safeNum(function() return me.XTarget() end, 0)
    local count = 0
    for i = 1, n do
        local x = me.XTarget(i)
        if x and x() and safeNum(function() return x.ID() end, 0) > 0 then
            local tt = (safeTLO(function() return x.TargetType() end, '') or ''):lower()
            if tt:find('hater') then count = count + 1 end
        end
    end
    return count
end

local function lowestGroupHP(me)
    local lowest = safeNum(function() return me.PctHPs() end, 100)
    local count = safeNum(function() return mq.TLO.Group.Members() end, 0)
    for i = 1, count do
        local m = mq.TLO.Group.Member(i)
        if m and m() then
            local hp = safeNum(function() return m.PctHPs() end, 100)
            if hp < lowest then lowest = hp end
        end
    end
    return lowest
end

local function groupTankHP(me)
    -- "Tank" here means the main-tank if defined, else the main-assist's
    -- tank slot, else self if we're a tank class. Best-effort.
    local mt = mq.TLO.Group.MainTank
    if mt and mt() then return safeNum(function() return mt.PctHPs() end, 100) end
    return safeNum(function() return me.PctHPs() end, 100)
end

local function groupInjuredCount(me, pct)
    local threshold = tonumber(pct) or 100
    local count = 0
    if safeNum(function() return me.PctHPs() end, 100) < threshold then
        count = count + 1
    end
    local groupCount = safeNum(function() return mq.TLO.Group.Members() end, 0)
    for i = 1, groupCount do
        local m = mq.TLO.Group.Member(i)
        if m and m() then
            local hp = safeNum(function() return m.PctHPs() end, 100)
            if hp < threshold then count = count + 1 end
        end
    end
    return count
end

--- Build the predicate context. Returns nil if Me TLO isn't valid.
--- Schema mirrors what existing class_configs/<CLASS>.lua predicates use:
---   ctx.me.{pctHPs, pctMana, pctEnd, pctAggro, xTargetCount, activeDisc}
---   ctx.me.buff(name)
---   ctx.combat, ctx.burn
---   ctx.target.{id, pctHPs, named, secondaryPctAggro, body}, target.myBuff(name)
---   ctx.spawn.count(query)        — wraps mq.TLO.SpawnCount
---   ctx.group.{lowestHP, tankHP}, group.injured(pct)
---   ctx.pet.{id, pctHPs}, pet.buff(name)
function M.buildContext()
    local me = mq.TLO.Me
    if not (me and me()) then return nil end

    local Core = getCore()
    local settings = (Core and Core.Settings) or {}

    local target = mq.TLO.Target
    local hasTarget = false
    if target and target() then
        local typ = (safeTLO(function() return target.Type() end, '') or ''):lower()
        hasTarget = typ == 'npc'
    end

    local burnNow = settings.BurnNow == true

    local ND = getNamed()
    local isNamed = false
    if hasTarget and ND and ND.isNamed then
        isNamed = ND.isNamed(target, settings) == true
    end

    -- Combat detection mirrors sk_lib.inCombat()
    local inCombat = safeTLO(function() return me.Combat() end, false) == true
    local xtHaters = countXTargetHaters(me)
    if not inCombat and xtHaters > 0 then inCombat = true end

    local activeDisc = false
    local adName = safeTLO(function() return me.ActiveDisc.Name() end, '')
    if adName and adName ~= '' and adName ~= 'NONE' and adName ~= 'None' then
        activeDisc = true
    end

    local pet = mq.TLO.Me.Pet
    local petInfo = {
        id     = safeNum(function() return pet.ID() end, 0),
        pctHPs = safeNum(function() return pet.PctHPs() end, 0),
        buff = function(name)
            if not name or name == '' then return false end
            local b = pet.Buff(name)
            return b and b() and true or false
        end,
    }

    local targetInfo = {}
    if hasTarget then
        targetInfo = {
            id                = safeNum(function() return target.ID() end, 0),
            pctHPs            = safeNum(function() return target.PctHPs() end, 100),
            named             = isNamed,
            secondaryPctAggro = safeNum(function() return target.SecondaryPctAggro() end, 0),
            body              = safeTLO(function() return target.Body() end, '') or '',
            -- Any beneficial buff on the NPC (includes player-cast buffs via
            -- cached-buff scan). Dispel predicates: ctx.target.hasBeneficial
            hasBeneficial     = getTargeting().targetHasBeneficial(),
            -- Positional: am I in the target's rear arc (backstab position)?
            behind            = getTargeting().isBehindSpawn(target),
            myBuff = function(buffName)
                if not buffName or buffName == '' then return false end
                -- Exact-name hit first (cheap).
                local b = target.MyBuff and target.MyBuff(buffName) or nil
                if b and b() then return true end
                -- Substring fallback: class configs pass rank-agnostic
                -- fragments ('Deeds', 'Tashan', 'Cripple') to cover whole
                -- spell lines, but MyBuff only matches exact names — the
                -- miss made doSlow/doTash recast endlessly on a debuffed
                -- target. Any caster's matching debuff counts (a slow is a
                -- slow regardless of who landed it).
                local needle = buffName:lower()
                local count = safeNum(function() return target.BuffCount() end, 0)
                for i = 1, count do
                    local name = ''
                    pcall(function() name = tostring(target.Buff(i).Name() or '') end)
                    if name ~= '' and name:lower():find(needle, 1, true) then
                        return true
                    end
                end
                return false
            end,
        }
    else
        -- Provide stubs so predicates that read target fields don't crash
        -- when no target is selected.
        targetInfo = {
            id = 0, pctHPs = 100, named = false, secondaryPctAggro = 0, body = '',
            hasBeneficial = false,
            behind = false,
            myBuff = function() return false end,
        }
    end

    return {
        me = {
            pctHPs       = safeNum(function() return me.PctHPs() end, 100),
            pctMana      = safeNum(function() return me.PctMana() end, 100),
            pctEnd       = safeNum(function() return me.PctEndurance() end, 100),
            pctAggro     = safeNum(function() return me.PctAggro() end, 0),
            xTargetCount = xtHaters,
            activeDisc   = activeDisc,
            buff = function(buffName)
                if not buffName or buffName == '' then return false end
                local b = me.Buff(buffName)
                return b and b() and true or false
            end,
            song = function(songName)
                if not songName or songName == '' then return false end
                local song = me.Song(songName)
                return song and song() and true or false
            end,
        },
        combat = inCombat,
        burn   = burnNow,
        mode   = settings.CombatMode or 'off',
        target = targetInfo,
        spawn = {
            count = function(query)
                if not query or query == '' then return 0 end
                return safeNum(function() return mq.TLO.SpawnCount(query)() end, 0)
            end,
            npcRadius = function(radius, zradius)
                local query = string.format('npc radius %d', tonumber(radius) or 50)
                if zradius then
                    query = query .. string.format(' zradius %d', tonumber(zradius) or 50)
                end
                return safeNum(function() return mq.TLO.SpawnCount(query)() end, 0)
            end,
        },
        group = {
            lowestHP = lowestGroupHP(me),
            tankHP   = groupTankHP(me),
            injured  = function(pct) return groupInjuredCount(me, pct) end,
        },
        pet = petInfo,
    }
end

-------------------------------------------------------------------------------
-- Ability classification & readiness
-------------------------------------------------------------------------------

local function isAAReady(name)
    return safeTLO(function() return mq.TLO.Me.AltAbilityReady(name)() end, false) == true
end

local function isDiscReady(name)
    -- Combat abilities (disciplines) have a per-timer cooldown; CombatAbilityReady
    -- takes the timer ID. Easier path: check Me.CombatAbilityReady(spellName)
    -- which is supported by recent MQ builds. Fall back to "always ready" if the
    -- TLO is unavailable (the cast itself will refuse if on cooldown, harmless).
    local ok, ready = pcall(function() return mq.TLO.Me.CombatAbilityReady(name)() end)
    if ok then return ready == true end
    return true
end

local function isSpellReady(name)
    return safeTLO(function() return mq.TLO.Me.SpellReady(name)() end, false) == true
end

-- Melee/class skills activated with /doability (Backstab, Kick, Bash, ...)
local function isSkillReady(name)
    return safeTLO(function() return mq.TLO.Me.AbilityReady(name)() end, false) == true
end

local function isReady(kind, name)
    if kind == 'aa'   then return isAAReady(name) end
    if kind == 'disc' then return isDiscReady(name) end
    if kind == 'spell' then return isSpellReady(name) end
    if kind == 'skill' then return isSkillReady(name) end
    return false
end

local function abilityLineForKind(config, setName, kind)
    if not (config and setName and kind) then return nil end
    if kind == 'disc' and config.discLines and config.discLines[setName] then
        return config.discLines[setName]
    elseif kind == 'aa' and config.aaLines and config.aaLines[setName] then
        return config.aaLines[setName]
    elseif kind == 'spell' and config.spellLines and config.spellLines[setName] then
        return config.spellLines[setName]
    elseif kind == 'skill' and config.skillLines and config.skillLines[setName] then
        return config.skillLines[setName]
    end

    -- Legacy configs often keep AAs in AbilitySets with an "AA" suffix
    -- while the predicate name strips to the unsuffixed line name.
    if config.AbilitySets then
        if config.AbilitySets[setName] then
            return config.AbilitySets[setName]
        end
        if kind == 'aa' and config.AbilitySets[setName .. 'AA'] then
            return config.AbilitySets[setName .. 'AA']
        end
    end
    return nil
end

local function hasAbilityForKind(kind, name)
    if kind == 'aa' then
        local aa = mq.TLO.Me.AltAbility(name)
        return aa and aa() and true or false
    elseif kind == 'disc' then
        local disc = mq.TLO.Me.CombatAbility(name)
        return disc and disc() and true or false
    elseif kind == 'spell' then
        local book = mq.TLO.Me.Book(name)
        if book and book() then return true end
        local spell = mq.TLO.Me.Spell(name)
        return spell and spell() and true or false
    elseif kind == 'skill' then
        -- Trained skill check: Me.Skill returns the skill value (0 = untrained)
        return safeNum(function() return mq.TLO.Me.Skill(name)() end, 0) > 0
    end
    return false
end

local function resolveAbilityForKind(config, setName, kind)
    local line = abilityLineForKind(config, setName, kind)
    if type(line) ~= 'table' then return nil end
    for _, name in ipairs(line) do
        if hasAbilityForKind(kind, name) then
            return name
        end
    end
    return nil
end

local function kindCandidates(config, setName, allowKinds)
    local candidates = {}
    local function add(kind)
        if allowKinds[kind] and abilityLineForKind(config, setName, kind) then
            table.insert(candidates, kind)
        end
    end

    -- Disc first keeps duplicate disc/AA names such as BER Bloodfury from
    -- being misclassified as an AA before the discipline line is checked.
    add('disc')
    add('aa')
    add('spell')
    add('skill')
    return candidates
end

-------------------------------------------------------------------------------
-- Picker
-------------------------------------------------------------------------------

--- Walk classConfig.defaultConditions (or .Conditions) and return the first
--- predicate that returns true AND whose resolved ability is ready.
--- @param opts table|nil { allowKinds = { aa=true, disc=true, spell=true },
---                          excludeConditions = { doFoo=true } }
---            — defaults to all kinds. Pass { aa=true, disc=true } to
---            exclude spell-based predicates so the dispatcher doesn't
---            steal heal/nuke ownership from dedicated rotation modules.
--- Returns: { name, kind, setName, condKey } or nil.
-- A detrimental cast fired at the current target lands on WHOEVER is
-- targeted — a healer self-targeting between heals gets slowed/dotted by
-- their own rotation. Class-config conditions (ctx.combat + myBuff checks)
-- don't validate the target's type, so enforce it in both selection
-- (pickReadyAbility) and dispatch (fireAbility).
local function detrimentalTargetOk(spellName)
    if not spellName or spellName == '' then return true end
    local detrimental = false
    pcall(function()
        local sp = mq.TLO.Spell(spellName)
        detrimental = sp and sp() and sp.Beneficial() == false
    end)
    if not detrimental then return true end
    local ok, valid = pcall(function()
        local t = mq.TLO.Target
        return t and t() and t.Type() == 'NPC' and not t.Dead()
    end)
    return ok and valid == true
end

-- Resolve the effective spell behind an ability for the detrimental check.
local function abilityTargetOk(kind, resolved)
    if kind == 'spell' then
        return detrimentalTargetOk(resolved)
    elseif kind == 'aa' then
        local aaSpell = nil
        pcall(function() aaSpell = mq.TLO.Me.AltAbility(resolved).Spell.Name() end)
        return detrimentalTargetOk(aaSpell)
    end
    return true  -- discs/skills act on the engaged target; melee has one
end

function M.pickReadyAbility(classConfig, ctx, opts)
    if not classConfig then return nil end
    local conditions = classConfig.defaultConditions
        or classConfig.Conditions
        or {}

    if not next(conditions) then return nil end
    if not ctx then return nil end

    local allowKinds = (opts and opts.allowKinds) or { aa = true, disc = true, spell = true }
    local excludeConditions = (opts and opts.excludeConditions) or {}
    local includeCategories = opts and opts.includeCategories or nil

    -- Honor an explicit ordering on the class config when supplied. This
    -- lets a config author choose firing priority (e.g. defensive discs
    -- before aggro discs) without alphabetical key gymnastics. When
    -- absent, falls back to alphabetical sort — deterministic but
    -- arbitrary; the config author should add `M.conditionOrder` if they
    -- care about firing precedence.
    local keys
    if classConfig.conditionOrder and type(classConfig.conditionOrder) == 'table' then
        keys = {}
        local seen = {}
        for _, k in ipairs(classConfig.conditionOrder) do
            if conditions[k] and not seen[k] then
                table.insert(keys, k)
                seen[k] = true
            end
        end
        -- Append any predicates not in conditionOrder so we don't silently
        -- drop newly-added conditions.
        local extras = {}
        for k in pairs(conditions) do
            if not seen[k] then table.insert(extras, k) end
        end
        table.sort(extras)
        for _, k in ipairs(extras) do table.insert(keys, k) end
    else
        keys = {}
        for k in pairs(conditions) do table.insert(keys, k) end
        table.sort(keys)
    end

    for _, condKey in ipairs(keys) do
        local category = classConfig.categoryOverrides and classConfig.categoryOverrides[condKey] or nil
        local categoryAllowed = not includeCategories
            or includeCategories[tostring(category or 'combat'):lower()] == true
        if not excludeConditions[condKey] and categoryAllowed then
            local pred = conditions[condKey]
            if type(pred) == 'function' then
                local okEval, allow = pcall(pred, ctx)
                if okEval and allow then
                    -- Strip the leading "do" prefix to get the ability-set name
                    -- ("doFortitude" -> "Fortitude", "doStandDisc" -> "StandDisc").
                    local setName = condKey:gsub('^do', '')
                    for _, kind in ipairs(kindCandidates(classConfig, setName, allowKinds)) do
                        -- Conditions with a targetSelector (e.g. 'mez_target')
                        -- retarget before casting — the current target is
                        -- irrelevant to them, so skip the detrimental gate.
                        local hasSelector = classConfig.targetSelector
                            and classConfig.targetSelector[condKey] ~= nil
                        local resolved = resolveAbilityForKind(classConfig, setName, kind)
                        if resolved and isReady(kind, resolved)
                            and (hasSelector or abilityTargetOk(kind, resolved)) then
                            return {
                                name    = resolved,
                                kind    = kind,
                                setName = setName,
                                condKey = condKey,
                            }
                        end
                    end
                end
            end
        end
    end

    return nil
end

-------------------------------------------------------------------------------
-- Execution helper (small wrapper modules can call this directly).
-------------------------------------------------------------------------------

--- Fire the action by kind. Returns true if a command was issued.
function M.fireAbility(action)
    if not (action and action.name and action.kind) then return false end
    -- Last-line detrimental target check (selection also filters via
    -- abilityTargetOk, but the target can change between claim and dispatch).
    if not abilityTargetOk(action.kind, action.name) then return false end
    if action.kind == 'aa' then
        local id = safeNum(function() return mq.TLO.Me.AltAbility(action.name).ID() end, 0)
        if id <= 0 then return false end
        mq.cmdf('/alt activate %d', id)
        return true
    elseif action.kind == 'disc' then
        mq.cmd('/disc ' .. action.name)
        return true
    elseif action.kind == 'spell' then
        mq.cmdf('/cast "%s"', action.name)
        return true
    elseif action.kind == 'skill' then
        mq.cmdf('/doability "%s"', action.name)
        return true
    end
    return false
end

return M
