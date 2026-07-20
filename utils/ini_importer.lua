-- MuleAssist character INI importer for SideKick Next.
--
-- The importer deliberately separates parsing, planning, and applying. A
-- preview never mutates SideKick. Apply creates backups, imports only settings
-- with clear SideKick equivalents, and stages spell lists in a separate spell
-- set rather than overwriting the user's active set.

local mq = require('mq')
local lip = require('LIP')
local HealerClasses = require('sidekick-next.utils.healer_classes')

local M = {}

local function trim(value)
    return tostring(value or ''):match('^%s*(.-)%s*$') or ''
end

local function isNull(value)
    local s = trim(value):lower()
    return s == '' or s == 'null' or s == 'nil'
end

local function splitPipe(value)
    local result = {}
    local s = tostring(value or '')
    local start = 1
    while true do
        local pos = s:find('|', start, true)
        if not pos then
            result[#result + 1] = trim(s:sub(start))
            break
        end
        result[#result + 1] = trim(s:sub(start, pos - 1))
        start = pos + 1
    end
    return result
end

local function toBool(value)
    local first = splitPipe(value)[1]:lower()
    -- Several MuleAssist toggles are modes rather than strict 0/1 values
    -- (for example DPSOn=2 and HealsOn=3). All non-zero modes are enabled.
    local numeric = tonumber(first)
    if numeric ~= nil then return numeric ~= 0 end
    if first == '1' or first == 'true' or first == 'yes' or first == 'on' then return true end
    if first == '0' or first == 'false' or first == 'no' or first == 'off' then return false end
    return nil
end

local function toNumber(value)
    return tonumber(splitPipe(value)[1])
end

local function fileExists(path)
    if not path or path == '' then return false end
    local file = io.open(path, 'r')
    if not file then return false end
    file:close()
    return true
end

local function findSection(data, wanted)
    wanted = tostring(wanted or ''):lower()
    for name, section in pairs(data or {}) do
        if tostring(name):lower() == wanted and type(section) == 'table' then
            return section
        end
    end
    return {}
end

local function readKey(data, sectionName, keyName)
    local section = findSection(data, sectionName)
    local wanted = tostring(keyName or ''):lower()
    for key, value in pairs(section) do
        if tostring(key):lower() == wanted then return value end
    end
    return nil
end

local function escapePattern(value)
    return tostring(value or ''):gsub('([^%w])', '%%%1')
end

local function identity()
    local server = ''
    local character = ''
    pcall(function() server = tostring(mq.TLO.EverQuest.Server() or '') end)
    pcall(function() character = tostring(mq.TLO.Me.CleanName() or '') end)
    server = server:gsub(' ', '_')
    if server:lower() == 'null' then server = '' end
    if character:lower() == 'null' then character = '' end
    return server, character
end

--- Find MuleAssist INIs for the current character. The exact non-level-suffixed
--- filename is preferred, followed by level-suffixed variants.
---@return string[] paths
function M.discoverMuleAssistFiles()
    local server, character = identity()
    if server == '' or character == '' then return {} end

    local exact = string.format('%s/MuleAssist_%s_%s.ini', mq.configDir, server, character)
    local paths = {}
    local seen = {}
    local function add(path)
        local key = tostring(path):lower()
        if not seen[key] and fileExists(path) then
            seen[key] = true
            paths[#paths + 1] = path
        end
    end
    add(exact)

    local ok, lfs = pcall(require, 'lfs')
    if ok and lfs and lfs.dir then
        local prefix = string.format('^MuleAssist_%s_%s_%%d+%%.ini$',
            escapePattern(server), escapePattern(character))
        pcall(function()
            for name in lfs.dir(mq.configDir) do
                if tostring(name):match(prefix) then
                    add(mq.configDir .. '/' .. name)
                end
            end
        end)
    end

    if #paths > 1 then
        local first = paths[1]
        local rest = {}
        for i = 2, #paths do rest[#rest + 1] = paths[i] end
        table.sort(rest)
        paths = { first }
        for _, path in ipairs(rest) do paths[#paths + 1] = path end
    end
    return paths
end

function M.getDefaultMuleAssistPath()
    return M.discoverMuleAssistFiles()[1]
end

local ENTRY_SECTIONS = {
    DPS = 'DPS',
    Heals = 'Heals',
    Buffs = 'Buffs',
    Burn = 'Burn',
    Aggro = 'Aggro',
    OhShit = 'OhShit',
    AE = 'AE',
    Cures = 'Cures',
    Charm = 'Charm',
    PetBuffs = 'PetBuffs',
}

local function parseEntry(sectionName, index, raw, condition)
    local parts = splitPipe(raw)
    local entry = {
        section = sectionName,
        index = index,
        raw = tostring(raw),
        name = parts[1],
        condition = isNull(condition) and nil or tostring(condition),
        parts = parts,
        modifiers = {},
    }
    if sectionName == 'Heals' then
        entry.threshold = tonumber(parts[2])
        for i = 3, #parts do entry.modifiers[#entry.modifiers + 1] = parts[i] end
    elseif sectionName == 'Buffs' or sectionName == 'PetBuffs' then
        for i = 2, #parts do entry.modifiers[#entry.modifiers + 1] = parts[i] end
    else
        entry.castAt = tonumber(parts[2])
        for i = 3, #parts do entry.modifiers[#entry.modifiers + 1] = parts[i] end
    end
    return entry
end

local function parseIndexedEntries(data, sectionName, prefix)
    local section = findSection(data, sectionName)
    local indexes = {}
    for key in pairs(section) do
        local index = tostring(key):match('^' .. escapePattern(prefix) .. '(%d+)$')
        if index then indexes[tonumber(index)] = true end
    end
    local sorted = {}
    for index in pairs(indexes) do sorted[#sorted + 1] = index end
    table.sort(sorted)

    local entries = {}
    for _, index in ipairs(sorted) do
        local raw = readKey(data, sectionName, prefix .. index)
        if not isNull(raw) then
            local condition = readKey(data, sectionName, prefix .. 'Cond' .. index)
            entries[#entries + 1] = parseEntry(sectionName, index, raw, condition)
        end
    end
    return entries
end

--- Parse a MuleAssist INI without mutating runtime settings.
---@param iniPath string
---@return table|nil config
---@return string|nil errorMessage
function M.parseMuleAssist(iniPath)
    if not fileExists(iniPath) then return nil, 'file_not_found' end
    local ok, data = pcall(lip.load, iniPath)
    if not ok or type(data) ~= 'table' then
        return nil, 'ini_parse_failed: ' .. tostring(data)
    end

    local config = {
        source = 'muleassist',
        path = iniPath,
        raw = data,
        entries = {},
        counts = {},
    }
    for sectionName, prefix in pairs(ENTRY_SECTIONS) do
        config.entries[sectionName] = parseIndexedEntries(data, sectionName == 'PetBuffs' and 'Pet' or sectionName, prefix)
        config.counts[sectionName] = #config.entries[sectionName]
    end
    return config
end

local function addSetting(plan, key, value, source, note)
    if value == nil then return end
    plan.settings[#plan.settings + 1] = {
        key = key,
        value = value,
        source = source,
        note = note,
    }
end

--- Build the non-destructive import plan. Ambiguous MuleAssist features are
--- reported but not guessed into unrelated SideKick settings.
function M.buildPlan(config)
    local plan = {
        sourcePath = config and config.path or nil,
        settings = {},
        ignored = {},
        warnings = {},
        entries = config and config.entries or {},
        counts = config and config.counts or {},
    }
    if not config or not config.raw then return plan end
    local data = config.raw

    local function mapBool(section, sourceKey, targetKey, note)
        addSetting(plan, targetKey, toBool(readKey(data, section, sourceKey)), section .. '.' .. sourceKey, note)
    end
    local function mapNumber(section, sourceKey, targetKey, note)
        addSetting(plan, targetKey, toNumber(readKey(data, section, sourceKey)), section .. '.' .. sourceKey, note)
    end

    mapBool('General', 'ActorsOn', 'ActorsEnabled')
    mapBool('General', 'ChaseAssist', 'ChaseEnabled')
    mapNumber('General', 'ChaseDistance', 'ChaseDistance')
    mapNumber('General', 'CastRetries', 'SpellMaxRetries')
    mapBool('General', 'RezAcceptOn', 'AutoAcceptRez')

    local medOn = toBool(readKey(data, 'General', 'MedOn'))
    if medOn ~= nil then addSetting(plan, 'MeditationMode', medOn and 'ooc' or 'off', 'General.MedOn') end
    local medStart = toNumber(readKey(data, 'General', 'MedStart'))
    if medStart then
        local className = splitPipe(readKey(data, 'General', 'CharInfo'))[1]:lower()
        local enduranceOnly = {
            warrior = true,
            monk = true,
            rogue = true,
            berserker = true,
        }
        if enduranceOnly[className] then
            addSetting(plan, 'MeditationEndStartPct', medStart, 'General.MedStart')
        else
            addSetting(plan, 'MeditationManaStartPct', medStart, 'General.MedStart')
        end
    end

    mapNumber('Melee', 'AssistAt', 'AssistAt')
    mapNumber('Melee', 'AssistRange', 'AssistRange')
    local stickHow = trim(readKey(data, 'Melee', 'StickHow'))
    if not isNull(stickHow) then
        if not stickHow:lower():match('^/stick') then stickHow = '/stick ' .. stickHow end
        addSetting(plan, 'StickCommand', stickHow, 'Melee.StickHow')
    end

    local role = trim(readKey(data, 'General', 'Role')):lower()
    local meleeOn = toBool(readKey(data, 'Melee', 'MeleeOn'))
    local dpsOn = toBool(readKey(data, 'DPS', 'DPSOn'))
    if dpsOn ~= nil then
        addSetting(plan, 'SpellRotationEnabled', dpsOn, 'DPS.DPSOn')
    end
    if role == 'tank' then
        addSetting(plan, 'CombatMode', 'tank', 'General.Role')
        local tankAll = toBool(readKey(data, 'Melee', 'TankAllMobs'))
        if tankAll ~= nil then addSetting(plan, 'TankTargetMode', tankAll and 'auto' or 'manual', 'Melee.TankAllMobs') end
    elseif role == 'assist' or role == 'puller' then
        addSetting(plan, 'CombatMode', (meleeOn or dpsOn) and 'assist' or 'off', 'General.Role')
    end

    mapBool('Heals', 'HealsOn', 'DoHeals')
    mapBool('Heals', 'HealGroupPetsOn', 'HealPetsEnabled')
    mapBool('Heals', 'HealGroupPetsOn', 'DoPetHeals')
    mapBool('Heals', 'AutoRezOn', 'AutoRezOOC')
    mapBool('Buffs', 'BuffsOn', 'BuffingEnabled')
    mapBool('Cures', 'CuresOn', 'DoCures')

    local className = splitPipe(readKey(data, 'General', 'CharInfo'))[1]
    local healsOn = toBool(readKey(data, 'Heals', 'HealsOn'))
    if healsOn and #(config.entries.Heals or {}) > 0 and not HealerClasses.isSupported(className) then
        plan.warnings[#plan.warnings + 1] = string.format(
            '%s heal entries will be staged, but coordinated Healing Intelligence supports only CLR, DRU, SHM, and PAL.',
            className ~= '' and className or 'Non-Cleric')
    end

    local xTar = trim(readKey(data, 'Heals', 'XTarHeal'))
    if not isNull(xTar) then
        local enabled = splitPipe(xTar)[1] ~= '0'
        addSetting(plan, 'HealXTargetEnabled', enabled, 'Heals.XTarHeal')
        addSetting(plan, 'HealXTargetSlots', enabled and xTar or '', 'Heals.XTarHeal')
    end

    local charmOn = toBool(readKey(data, 'Charm', 'CharmOn'))
    if charmOn == true then
        plan.warnings[#plan.warnings + 1] =
            'Charm.CharmOn was not enabled: SideKick currently stages charm spells but has no automatic charm owner.'
    end

    local thresholds = {}
    for _, entry in ipairs(config.entries.Heals or {}) do
        if entry.threshold then thresholds[#thresholds + 1] = entry.threshold end
    end
    table.sort(thresholds, function(a, b) return a > b end)
    if thresholds[1] then addSetting(plan, 'MainHealPoint', thresholds[1], 'Heals.Heals# thresholds') end
    if #thresholds > 1 then
        addSetting(plan, 'BigHealPoint', thresholds[#thresholds], 'Heals.Heals# thresholds')
    end

    plan.ignored = {
        'MuleAssist conditions are parsed but are not converted into SideKick condition-builder data.',
        'Pulling, camp, loot, mail, bandolier, mercenary, and invite behavior are not imported in this first pass.',
        'Burn/Aggro/OhShit action lists are parsed but are not auto-enabled without an exact SideKick ability mapping.',
        'DPS.DebuffAllOn is not mapped to task-only DebuffAllTask because their target scopes differ.',
        'Pet.PetBuffsOn and PetBuffs# are not mapped because the buffs worker does not currently target pets.',
    }
    return plan
end

local function resolveBookSpell(name)
    if isNull(name) or tostring(name):sub(1, 1) == '/' then return nil end
    local me = mq.TLO.Me
    if not (me and me()) then return nil end
    local ok, owned = pcall(function()
        local bookSpell = me.Book(name)
        return bookSpell and bookSpell() and true or false
    end)
    if not ok or not owned then return nil end
    local idOk, id = pcall(function()
        local spell = mq.TLO.Spell(name)
        return spell and spell() and tonumber(spell.ID()) or nil
    end)
    if idOk and id and id > 0 then return id end
    return nil
end

local function buffTarget(entry)
    for _, modifier in ipairs(entry.modifiers or {}) do
        local lower = tostring(modifier):lower()
        if lower == 'me' or lower == 'self' or lower == 'mana' or lower == 'mount' then
            return { type = 'self' }
        end
        if lower == 'pet' then return { type = 'pet' } end
        if lower:find('raid', 1, true) then return { type = 'raid' } end
    end
    return { type = 'group' }
end

local function copyFile(path)
    if not fileExists(path) then return nil end
    local source = io.open(path, 'rb')
    if not source then return nil end
    local content = source:read('*all')
    source:close()
    local backup = path .. '.pre-muleassist-import-' .. os.date('%Y%m%d_%H%M%S') .. '.bak'
    local target = io.open(backup, 'wb')
    if not target then return nil end
    target:write(content or '')
    target:close()
    return backup
end

local HEAL_CATEGORIES = {
    'fast', 'small', 'medium', 'large', 'group', 'hot',
    'hotLight', 'groupHot', 'promised', 'selfHeal',
}

local function addUnique(list, value)
    if type(list) ~= 'table' or not value or value == '' then return false end
    for _, existing in ipairs(list) do
        if tostring(existing):lower() == tostring(value):lower() then return false end
    end
    list[#list + 1] = value
    return true
end

local function spellSortValue(spellName, field)
    local spell = mq.TLO.Spell(spellName)
    if not (spell and spell()) then return 0 end
    local accessor = spell[field]
    if not accessor then return 0 end
    local ok, value = pcall(accessor)
    return ok and tonumber(value) or 0
end

local function stageHealingConfig(config, result)
    local HealingConfig = require('sidekick-next.healing.config')
    HealingConfig.load()

    local configPath = HealingConfig.GetConfigPath and HealingConfig.GetConfigPath() or nil
    local backup = configPath and copyFile(configPath) or nil
    if backup then result.backups[#result.backups + 1] = backup end

    HealingConfig.spells = HealingConfig.spells or {}
    for _, category in ipairs(HEAL_CATEGORIES) do
        HealingConfig.spells[category] = HealingConfig.spells[category] or {}
    end

    local directHeals = {}
    local hotHeals = {}
    local seen = {}
    local assigned = 0
    local configured = 0

    local function assign(category, spellName)
        configured = configured + 1
        if addUnique(HealingConfig.spells[category], spellName) then assigned = assigned + 1 end
    end

    for _, entry in ipairs(config.entries.Heals or {}) do
        local spellName = trim(entry.name)
        local id = resolveBookSpell(spellName)
        local key = spellName:lower()
        if id and not seen[key] then
            seen[key] = true
            if HealingConfig.IsValidSpellForCategory('promised', spellName) then
                assign('promised', spellName)
            elseif HealingConfig.IsValidSpellForCategory('groupHot', spellName) then
                assign('groupHot', spellName)
            elseif HealingConfig.IsValidSpellForCategory('group', spellName) then
                assign('group', spellName)
            elseif HealingConfig.IsValidSpellForCategory('fast', spellName) then
                assign('fast', spellName)
            elseif HealingConfig.IsValidSpellForCategory('selfHeal', spellName) then
                assign('selfHeal', spellName)
            elseif HealingConfig.IsValidSpellForCategory('hot', spellName) then
                hotHeals[#hotHeals + 1] = {
                    name = spellName,
                    value = spellSortValue(spellName, 'Mana'),
                }
            elseif HealingConfig.IsValidSpellForCategory('medium', spellName) then
                directHeals[#directHeals + 1] = {
                    name = spellName,
                    value = spellSortValue(spellName, 'Level'),
                }
            else
                result.warnings[#result.warnings + 1] = string.format(
                    'Heal entry is not a supported Healing Intelligence spell type: %s', spellName)
            end
        end
    end

    table.sort(directHeals, function(a, b) return a.value < b.value end)
    if #directHeals == 1 then
        assign('medium', directHeals[1].name)
    elseif #directHeals >= 2 then
        assign('small', directHeals[1].name)
        assign('large', directHeals[#directHeals].name)
        for i = 2, #directHeals - 1 do assign('medium', directHeals[i].name) end
    end

    table.sort(hotHeals, function(a, b) return a.value < b.value end)
    if #hotHeals == 1 then
        assign('hot', hotHeals[1].name)
    elseif #hotHeals >= 2 then
        assign('hotLight', hotHeals[1].name)
        assign('hot', hotHeals[#hotHeals].name)
        for i = 2, #hotHeals - 1 do assign('hot', hotHeals[i].name) end
    end

    local healsOn = toBool(readKey(config.raw, 'Heals', 'HealsOn'))
    if healsOn ~= nil then HealingConfig.enabled = healsOn end
    local thresholds = {}
    for _, entry in ipairs(config.entries.Heals or {}) do
        if entry.threshold then thresholds[#thresholds + 1] = entry.threshold end
    end
    table.sort(thresholds, function(a, b) return a > b end)
    local saved = HealingConfig.save()
    result.healingConfig = {
        saved = saved == true,
        assigned = assigned,
        configured = configured,
    }
end

local function stageSpellSet(config, options, result)
    local Persistence = require('sidekick-next.utils.spellset_persistence')
    local SpellSetData = require('sidekick-next.utils.spellset_data')
    Persistence.load()

    local persistencePath = Persistence.getConfigPath()
    local backup = copyFile(persistencePath)
    if backup then result.backups[#result.backups + 1] = backup end

    local setName = options.spellSetName or 'MuleAssist Import'
    local spellSet = Persistence.getSet(setName) or Persistence.createSet(setName)
    spellSet.gems = {}
    spellSet.oocBuffs = {}

    local unresolved = result.unresolved
    local seen = {}
    local gemCandidates = {}
    for _, sectionName in ipairs({ 'Heals', 'Charm', 'DPS' }) do
        for _, entry in ipairs(config.entries[sectionName] or {}) do
            local id = resolveBookSpell(entry.name)
            if id and not seen[id] then
                seen[id] = true
                gemCandidates[#gemCandidates + 1] = { id = id, entry = entry }
            elseif not id then
                unresolved[#unresolved + 1] = string.format('%s%d: %s', sectionName, entry.index, entry.name)
            end
        end
    end

    for _, entry in ipairs(config.entries.Buffs or {}) do
        local id = resolveBookSpell(entry.name)
        if id then
            -- An untranslated MacroQuest condition can materially change when a
            -- buff/utility spell is safe to use. Keep those entries visible in
            -- the staged set, but disabled until the condition is recreated.
            local condition = trim(entry.condition):upper()
            local enabled = condition == '' or condition == 'TRUE'
            SpellSetData.addOocBuff(spellSet, id, enabled, nil, buffTarget(entry))
            if not enabled then result.disabledBuffs = (result.disabledBuffs or 0) + 1 end
        else
            unresolved[#unresolved + 1] = string.format('Buffs%d: %s', entry.index, entry.name)
        end
    end

    local totalGems = SpellSetData.getTotalGemCount()
    local maxRotation = totalGems
    if #spellSet.oocBuffs > 0 and maxRotation > 0 then maxRotation = maxRotation - 1 end
    for slot, candidate in ipairs(gemCandidates) do
        if slot > maxRotation then
            unresolved[#unresolved + 1] = string.format('No gem slot: %s', candidate.entry.name)
        else
            local priority = SpellSetData.DEFAULT_PRIORITY.nuke
            if candidate.entry.section == 'Heals' then priority = SpellSetData.DEFAULT_PRIORITY.heal end
            if candidate.entry.section == 'Charm' then priority = SpellSetData.DEFAULT_PRIORITY.charm end
            SpellSetData.setGem(spellSet, slot, candidate.id, nil, priority, nil)
        end
    end

    if options.activateSpellSet then Persistence.setActiveSet(setName) end
    local saved = Persistence.save()
    result.spellSet = {
        name = setName,
        saved = saved == true,
        activated = options.activateSpellSet == true,
        path = persistencePath,
        gems = SpellSetData.countGems(spellSet),
        buffs = #(spellSet.oocBuffs or {}),
        disabledBuffs = result.disabledBuffs or 0,
    }
end

--- Preview or apply a MuleAssist import.
---@param iniPath string|nil Defaults to the current character's best match
---@param Core table|nil Required when preview=false
---@param options table|nil {preview, importSpellSet, importHealingConfig, activateSpellSet, spellSetName}
---@return table result
function M.run(iniPath, Core, options)
    options = options or {}
    if options.importSpellSet == nil then options.importSpellSet = true end
    if options.importHealingConfig == nil then options.importHealingConfig = true end
    iniPath = iniPath or M.getDefaultMuleAssistPath()
    local result = {
        ok = false,
        preview = options.preview == true,
        sourcePath = iniPath,
        settingsApplied = 0,
        backups = {},
        unresolved = {},
        warnings = {},
    }
    if not iniPath then
        result.error = 'No MuleAssist INI found for the current server/character.'
        return result
    end

    local config, parseError = M.parseMuleAssist(iniPath)
    if not config then
        result.error = parseError
        return result
    end
    result.config = config
    result.plan = M.buildPlan(config)
    result.ok = true
    if result.preview then return result end
    if not Core or not Core.set then
        result.ok = false
        result.error = 'SideKick Core was not supplied.'
        return result
    end

    local Paths = require('sidekick-next.utils.paths')
    local ConfigModules = require('sidekick-next.utils.config_modules')
    for _, moduleName in ipairs(ConfigModules.names) do
        local configBackup = copyFile(Paths.getModuleConfigPath(moduleName))
        if configBackup then result.backups[#result.backups + 1] = configBackup end
    end

    for _, setting in ipairs(result.plan.settings) do
        Core.set(setting.key, setting.value)
        result.settingsApplied = result.settingsApplied + 1
    end
    Core.forceSave()

    if options.importSpellSet then
        local ok, err = pcall(stageSpellSet, config, options, result)
        if not ok then result.warnings[#result.warnings + 1] = 'Spell-set import failed: ' .. tostring(err) end
    end
    if options.importHealingConfig and #(config.entries.Heals or {}) > 0 then
        local ok, err = pcall(stageHealingConfig, config, result)
        if not ok then result.warnings[#result.warnings + 1] = 'Healing-config import failed: ' .. tostring(err) end
    end
    return result
end

function M.summaryLines(result)
    if not result or not result.ok then
        return { 'MuleAssist import failed: ' .. tostring(result and result.error or 'unknown error') }
    end
    local plan = result.plan or {}
    local lines = {
        string.format('%s MuleAssist import: %s', result.preview and 'Previewed' or 'Applied', tostring(result.sourcePath)),
        string.format('Settings: %d%s', #(plan.settings or {}), result.preview and ' planned' or ' applied'),
        string.format('Entries: DPS=%d Heals=%d Buffs=%d Burn=%d Aggro=%d Charm=%d',
            tonumber(plan.counts and plan.counts.DPS) or 0,
            tonumber(plan.counts and plan.counts.Heals) or 0,
            tonumber(plan.counts and plan.counts.Buffs) or 0,
            tonumber(plan.counts and plan.counts.Burn) or 0,
            tonumber(plan.counts and plan.counts.Aggro) or 0,
            tonumber(plan.counts and plan.counts.Charm) or 0),
    }
    if result.spellSet then
        lines[#lines + 1] = string.format('Spell set "%s": %d gems, %d buffs%s',
            result.spellSet.name, result.spellSet.gems, result.spellSet.buffs,
            result.spellSet.activated and ' (active)' or ' (staged, not active)')
        lines[#lines + 1] = string.format('Spell set path: %s%s',
            tostring(result.spellSet.path),
            result.spellSet.saved and '' or ' (save failed)')
        if (result.spellSet.disabledBuffs or 0) > 0 then
            lines[#lines + 1] = string.format('Condition-dependent buffs staged disabled: %d',
                result.spellSet.disabledBuffs)
        end
    end
    if result.healingConfig then
        lines[#lines + 1] = string.format('Healing Intelligence: %d heal spells configured (%d newly added)%s',
            result.healingConfig.configured or 0,
            result.healingConfig.assigned or 0,
            result.healingConfig.saved and '' or ' (save failed)')
    end
    if #(result.unresolved or {}) > 0 then
        lines[#lines + 1] = string.format('Unresolved or unstaged entries: %d', #result.unresolved)
    end
    for _, warning in ipairs(result.warnings or {}) do lines[#lines + 1] = warning end
    return lines
end

return M
