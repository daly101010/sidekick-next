-- F:/lua/SideKick/utils/ini_importer.lua
-- Import KissAssist and MuleAssist INI configurations into SideKick format

local mq = require('mq')

local AbilityResolver = require('sidekick-next.utils.ability_resolver')

local M = {}

-- MQ2 to Lua TLO conversion map
local ConversionMap = {
    -- Me properties
    ['${Me.PctHPs}'] = 'mq.TLO.Me.PctHPs()',
    ['${Me.PctMana}'] = 'mq.TLO.Me.PctMana()',
    ['${Me.PctEndurance}'] = 'mq.TLO.Me.PctEndurance()',
    ['${Me.CombatState.Equal[COMBAT]}'] = 'mq.TLO.Me.CombatState() == "COMBAT"',
    ['${Me.CombatState.Equal[Combat]}'] = 'mq.TLO.Me.CombatState() == "COMBAT"',
    ['${Me.Combat}'] = 'mq.TLO.Me.CombatState() == "COMBAT"',
    ['${Me.Invis}'] = 'mq.TLO.Me.Invis()',
    ['${Me.Hovering}'] = 'mq.TLO.Me.Hovering()',
    ['${Me.Feigning}'] = 'mq.TLO.Me.Feigning()',
    ['${Me.XTarget}'] = 'mq.TLO.Me.XTarget()',
    ['${Me.XTHaterCount}'] = 'mq.TLO.Me.XTHaterCount()',
    ['${Me.PctAggro}'] = 'mq.TLO.Me.PctAggro()',
    ['${Me.Level}'] = 'mq.TLO.Me.Level()',
    ['${Me.ActiveDisc.ID}'] = 'mq.TLO.Me.ActiveDisc.ID()',
    ['${Me.ActiveDisc.Name}'] = 'mq.TLO.Me.ActiveDisc.Name()',
    ['${Me.Standing}'] = 'mq.TLO.Me.Standing()',
    ['${Me.Sitting}'] = 'mq.TLO.Me.Sitting()',
    ['${Me.Moving}'] = 'mq.TLO.Me.Moving()',
    ['${Me.Casting}'] = 'mq.TLO.Me.Casting()',
    ['${Me.Casting.ID}'] = 'mq.TLO.Me.Casting.ID()',

    -- Pet properties
    ['${Me.Pet.ID}'] = 'mq.TLO.Me.Pet.ID()',
    ['${Me.Pet.PctHPs}'] = 'mq.TLO.Me.Pet.PctHPs()',
    ['${Pet.ID}'] = 'mq.TLO.Me.Pet.ID()',
    ['${Pet.PctHPs}'] = 'mq.TLO.Me.Pet.PctHPs()',

    -- Target properties
    ['${Target.ID}'] = 'mq.TLO.Target.ID()',
    ['${Target.PctHPs}'] = 'mq.TLO.Target.PctHPs()',
    ['${Target.Level}'] = 'mq.TLO.Target.Level()',
    ['${Target.Named}'] = 'mq.TLO.Target.Named()',
    ['${Target.Distance}'] = 'mq.TLO.Target.Distance()',
    ['${Target.Distance3D}'] = 'mq.TLO.Target.Distance3D()',
    ['${Target.LineOfSight}'] = 'mq.TLO.Target.LineOfSight()',
    ['${Target.Type}'] = 'mq.TLO.Target.Type()',

    -- Group properties
    ['${Group.Members}'] = 'mq.TLO.Group.Members()',

    -- Raid properties
    ['${Raid.Members}'] = 'mq.TLO.Raid.Members()',

    -- Operators (applied after all patterns)
    ['&&'] = ' and ',
    ['||'] = ' or ',
}

-- Patterns that need parameter extraction
local ParameterizedPatterns = {
    -- Me.Buff[name]
    { pattern = '%${Me%.Buff%[([^%]]+)%]%.ID}', replacement = 'mq.TLO.Me.Buff("%s").ID()' },
    { pattern = '%${Me%.Buff%[([^%]]+)%]%.Duration%.Ticks}', replacement = 'mq.TLO.Me.Buff("%s").Duration.Ticks()' },
    { pattern = '%${Me%.Buff%[([^%]]+)%]}', replacement = 'mq.TLO.Me.Buff("%s")()' },

    -- Me.Song[name]
    { pattern = '%${Me%.Song%[([^%]]+)%]%.ID}', replacement = 'mq.TLO.Me.Song("%s").ID()' },
    { pattern = '%${Me%.Song%[([^%]]+)%]}', replacement = 'mq.TLO.Me.Song("%s")()' },

    -- Target.Buff[name]
    { pattern = '%${Target%.Buff%[([^%]]+)%]%.ID}', replacement = 'mq.TLO.Target.Buff("%s").ID()' },
    { pattern = '%${Target%.Buff%[([^%]]+)%]}', replacement = 'mq.TLO.Target.Buff("%s")()' },

    -- Target.MyBuff[name]
    { pattern = '%${Target%.MyBuff%[([^%]]+)%]%.ID}', replacement = 'mq.TLO.Target.MyBuff("%s").ID()' },
    { pattern = '%${Target%.MyBuff%[([^%]]+)%]}', replacement = 'mq.TLO.Target.MyBuff("%s")()' },

    -- Target.Body.Name.Equal[type]
    { pattern = '%${Target%.Body%.Name%.Equal%[([^%]]+)%]}', replacement = 'mq.TLO.Target.Body.Name() == "%s"' },
    { pattern = '%${Target%.Body%.Name%.NotEqual%[([^%]]+)%]}', replacement = 'mq.TLO.Target.Body.Name() ~= "%s"' },

    -- Target.ConColor.Equal[color]
    { pattern = '%${Target%.ConColor%.Equal%[([^%]]+)%]}', replacement = 'mq.TLO.Target.ConColor() == "%s"' },

    -- Group.Injured[pct]
    { pattern = '%${Group%.Injured%[(%d+)%]}', replacement = 'mq.TLO.Group.Injured(%s)()' },

    -- SpawnCount[query]
    { pattern = '%${SpawnCount%[([^%]]+)%]}', replacement = 'mq.TLO.SpawnCount("%s")()' },

    -- Me.AltAbilityReady[name]
    { pattern = '%${Me%.AltAbilityReady%[([^%]]+)%]}', replacement = 'mq.TLO.Me.AltAbilityReady("%s")()' },

    -- Me.CombatAbilityReady[name]
    { pattern = '%${Me%.CombatAbilityReady%[([^%]]+)%]}', replacement = 'mq.TLO.Me.CombatAbilityReady("%s")()' },

    -- Me.AbilityReady[name]
    { pattern = '%${Me%.AbilityReady%[([^%]]+)%]}', replacement = 'mq.TLO.Me.AbilityReady("%s")()' },

    -- Me.GemTimer[gem]
    { pattern = '%${Me%.GemTimer%[(%d+)%]}', replacement = 'mq.TLO.Me.GemTimer(%s)()' },

    -- Spell[name].Stacks
    { pattern = '%${Spell%[([^%]]+)%]%.Stacks}', replacement = 'mq.TLO.Spell("%s").Stacks()' },
    { pattern = '%${Spell%[([^%]]+)%]%.StacksTarget}', replacement = 'mq.TLO.Spell("%s").StacksTarget()' },

    -- Me.XTAggroCount[pct]
    { pattern = '%${Me%.XTAggroCount%[(%d+)%]}', replacement = 'mq.TLO.Me.XTAggroCount(%s)()' },
}

--- Convert a MQ2 expression to Lua TLO code
---@param mq2Expr string The MQ2 expression (e.g., "${Me.PctHPs} < 50")
---@return string luaExpr The converted Lua expression
function M.convertCondition(mq2Expr)
    if not mq2Expr or mq2Expr == '' then return 'true' end
    if mq2Expr:upper() == 'TRUE' then return 'true' end
    if mq2Expr:upper() == 'FALSE' then return 'false' end

    local luaExpr = mq2Expr

    -- Handle NOT operator (!) before other conversions
    -- Must be careful not to replace !=
    luaExpr = luaExpr:gsub('([^!])!([^=])', '%1 not %2')
    luaExpr = luaExpr:gsub('^!([^=])', 'not %1')

    -- Handle != operator
    luaExpr = luaExpr:gsub('!=', '~=')

    -- Apply parameterized patterns first
    for _, p in ipairs(ParameterizedPatterns) do
        luaExpr = luaExpr:gsub(p.pattern, function(capture)
            return string.format(p.replacement, capture)
        end)
    end

    -- Apply direct conversions
    for mq2, lua in pairs(ConversionMap) do
        -- Escape special pattern characters in the MQ2 string
        local escaped = mq2:gsub('[%${}%.%[%]%(%)%+%-%*%?%^]', '%%%1')
        luaExpr = luaExpr:gsub(escaped, lua)
    end

    -- Clean up any remaining ${...} that we didn't convert
    -- Convert them to comments so they're visible but don't break
    luaExpr = luaExpr:gsub('%${([^}]+)}', '--[[UNCONVERTED: ${%1}]] nil')

    return luaExpr
end

--- Build a condition function from a Lua expression string
---@param luaExpr string The Lua expression
---@return function|nil condFn The condition function or nil if invalid
function M.buildConditionFunction(luaExpr)
    if not luaExpr or luaExpr == '' or luaExpr == 'true' then
        return function() return true end
    end
    if luaExpr == 'false' then
        return function() return false end
    end

    -- Wrap in a function that takes ctx but uses mq.TLO directly
    local fnStr = string.format([[
        local mq = require('mq')
        return function(ctx)
            return %s
        end
    ]], luaExpr)

    local fn, err = load(fnStr)
    if not fn then
        -- Print disabled
        return nil
    end

    local ok, result = pcall(fn)
    if not ok then
        -- Print disabled
        return nil
    end

    return result
end

--- Parse a KissAssist INI file
---@param iniPath string Path to the INI file
---@return table config Parsed configuration
function M.parseKissAssist(iniPath)
    local config = {
        spells = {},
        conditions = {},
        burns = {},
        settings = {},
        source = 'kissassist',
        path = iniPath,
    }

    local ini = mq.TLO.Ini
    if not ini then
        -- Print disabled
        return config
    end

    -- Helper to read INI key
    local function readKey(section, key)
        local ok, val = pcall(function()
            return ini(iniPath, section, key)()
        end)
        return ok and val or nil
    end

    -- Parse [KConditions] first (referenced by spells)
    local condSize = tonumber(readKey('KConditions', 'CondSize')) or 0
    for i = 1, condSize do
        local condExpr = readKey('KConditions', 'Cond' .. i)
        if condExpr and condExpr ~= '' then
            config.conditions[i] = M.convertCondition(condExpr)
        end
    end

    -- Parse DPS section
    local dpsSize = tonumber(readKey('DPS', 'DPSSize')) or 0
    for i = 1, dpsSize do
        local entry = readKey('DPS', 'DPS' .. i)
        if entry and entry ~= '' then
            local parsed = M.parseKissSpellEntry(entry, 'dps', config.conditions)
            if parsed then
                table.insert(config.spells, parsed)
            end
        end
    end

    -- Parse Heals section
    local healsSize = tonumber(readKey('Heals', 'HealsSize')) or 0
    for i = 1, healsSize do
        local entry = readKey('Heals', 'Heals' .. i)
        if entry and entry ~= '' then
            local parsed = M.parseKissSpellEntry(entry, 'heal', config.conditions)
            if parsed then
                table.insert(config.spells, parsed)
            end
        end
    end

    -- Parse Buffs section
    local buffsSize = tonumber(readKey('Buffs', 'BuffsSize')) or 0
    for i = 1, buffsSize do
        local entry = readKey('Buffs', 'Buffs' .. i)
        local cond = readKey('Buffs', 'BuffsCond' .. i)
        if entry and entry ~= '' then
            local parsed = M.parseKissBuffEntry(entry, cond)
            if parsed then
                table.insert(config.spells, parsed)
            end
        end
    end

    -- Parse Burn section
    local burnSize = tonumber(readKey('Burn', 'BurnSize')) or 0
    for i = 1, burnSize do
        local entry = readKey('Burn', 'Burn' .. i)
        if entry and entry ~= '' then
            table.insert(config.burns, {
                name = entry,
                category = 'burn',
            })
        end
    end

    return config
end

--- Parse a KissAssist spell entry
---@param entry string The entry string (SpellName|Priority|Modifier|CondN)
---@param category string The category (dps, heal, etc.)
---@param conditions table The conditions table
---@return table|nil parsed The parsed entry or nil
function M.parseKissSpellEntry(entry, category, conditions)
    -- Format: SpellName|Priority|Modifier|CondN
    local parts = {}
    for part in entry:gmatch('[^|]+') do
        table.insert(parts, part)
    end

    if #parts < 1 then return nil end

    local spellName = parts[1]
    local priority = tonumber(parts[2]) or 50
    local modifier = parts[3] or ''
    local condRef = parts[4] or ''

    -- Determine target from modifier
    local target = 'current'
    if modifier:upper() == 'MA' then
        target = 'assist'
    elseif modifier:upper() == 'ME' then
        target = 'self'
    elseif modifier:upper() == 'PET' then
        target = 'pet'
    end

    -- Get condition if referenced
    local condExpr = nil
    local condNum = condRef:match('Cond(%d+)')
    if condNum then
        condExpr = conditions[tonumber(condNum)]
    end

    return {
        spell = spellName,
        category = category,
        priority = priority,
        modifier = modifier,
        target = target,
        conditionExpr = condExpr,
        conditionFn = condExpr and M.buildConditionFunction(condExpr) or nil,
    }
end

--- Parse a KissAssist buff entry
---@param entry string The entry string
---@param condExpr string|nil The condition expression
---@return table|nil parsed The parsed entry or nil
function M.parseKissBuffEntry(entry, condExpr)
    -- Buff entries are usually just the spell name
    if not entry or entry == '' then return nil end

    local convertedCond = nil
    if condExpr and condExpr ~= '' then
        convertedCond = M.convertCondition(condExpr)
    end

    return {
        spell = entry,
        category = 'buff',
        priority = 50,
        target = 'group',
        conditionExpr = convertedCond,
        conditionFn = convertedCond and M.buildConditionFunction(convertedCond) or nil,
    }
end

--- Parse a MuleAssist INI file
---@param iniPath string Path to the INI file
---@return table config Parsed configuration
function M.parseMuleAssist(iniPath)
    local config = {
        spells = {},
        conditions = {},
        burns = {},
        settings = {},
        source = 'muleassist',
        path = iniPath,
    }

    local ini = mq.TLO.Ini
    if not ini then
        -- Print disabled
        return config
    end

    -- Helper to read INI key
    local function readKey(section, key)
        local ok, val = pcall(function()
            return ini(iniPath, section, key)()
        end)
        return ok and val or nil
    end

    -- Parse DPS section
    local dpsSize = tonumber(readKey('DPS', 'DPSSize')) or 0
    for i = 1, dpsSize do
        local entry = readKey('DPS', 'DPS' .. i)
        local cond = readKey('DPS', 'DPSCond' .. i)
        if entry and entry ~= '' then
            local parsed = M.parseMuleSpellEntry(entry, 'dps', cond)
            if parsed then
                table.insert(config.spells, parsed)
            end
        end
    end

    -- Parse Heals section
    local healsSize = tonumber(readKey('Heals', 'HealsSize')) or 0
    for i = 1, healsSize do
        local entry = readKey('Heals', 'Heals' .. i)
        local cond = readKey('Heals', 'HealsCond' .. i)
        if entry and entry ~= '' then
            local parsed = M.parseMuleSpellEntry(entry, 'heal', cond)
            if parsed then
                table.insert(config.spells, parsed)
            end
        end
    end

    -- Parse Buffs section
    local buffsSize = tonumber(readKey('Buffs', 'BuffsSize')) or 0
    for i = 1, buffsSize do
        local entry = readKey('Buffs', 'Buffs' .. i)
        local cond = readKey('Buffs', 'BuffsCond' .. i)
        if entry and entry ~= '' then
            local parsed = M.parseMuleSpellEntry(entry, 'buff', cond)
            if parsed then
                table.insert(config.spells, parsed)
            end
        end
    end

    return config
end

--- Parse a MuleAssist spell entry
---@param entry string The entry string
---@param category string The category
---@param condExpr string|nil The condition expression
---@return table|nil parsed The parsed entry or nil
function M.parseMuleSpellEntry(entry, category, condExpr)
    if not entry or entry == '' then return nil end

    -- MuleAssist entries can have various formats
    -- Simple: SpellName
    -- With target: SpellName|Target
    local parts = {}
    for part in entry:gmatch('[^|]+') do
        table.insert(parts, part)
    end

    local spellName = parts[1]
    local target = parts[2] or 'current'

    local convertedCond = nil
    if condExpr and condExpr ~= '' then
        convertedCond = M.convertCondition(condExpr)
    end

    return {
        spell = spellName,
        category = category,
        priority = 50,
        target = target:lower(),
        conditionExpr = convertedCond,
        conditionFn = convertedCond and M.buildConditionFunction(convertedCond) or nil,
    }
end

--- Apply imported config to SideKick, using spell line fallback
---@param importedConfig table The imported configuration
---@param classConfig table The SideKick class config with spell lines
---@return table result { applied = {}, skipped = {}, errors = {} }
function M.applyToSideKick(importedConfig, classConfig)
    local result = {
        applied = {},
        skipped = {},
        errors = {},
    }

    if not importedConfig or not importedConfig.spells then
        return result
    end

    local me = mq.TLO.Me
    if not (me and me()) then
        table.insert(result.errors, 'Character not available')
        return result
    end

    for _, entry in ipairs(importedConfig.spells) do
        local spellName = entry.spell

        -- Check if character has this spell
        local ok, inBook = pcall(function() return me.Book(spellName)() end)

        if ok and inBook then
            -- Character has this spell
            table.insert(result.applied, {
                original = spellName,
                resolved = spellName,
                category = entry.category,
                condition = entry.conditionExpr,
            })
        else
            -- Try to find a fallback from spell lines
            local lineName = AbilityResolver.findSpellLine(classConfig, spellName)
            if lineName then
                local fallback = AbilityResolver.getFallbackSpell(classConfig, spellName, lineName)
                if fallback then
                    table.insert(result.applied, {
                        original = spellName,
                        resolved = fallback,
                        category = entry.category,
                        condition = entry.conditionExpr,
                        fallback = true,
                    })
                else
                    table.insert(result.skipped, {
                        spell = spellName,
                        reason = 'No available spell in line: ' .. lineName,
                    })
                end
            else
                table.insert(result.skipped, {
                    spell = spellName,
                    reason = 'Spell not in spellbook and no matching spell line found',
                })
            end
        end
    end

    return result
end

--- Detect INI type from file path or content
---@param iniPath string Path to the INI file
---@return string type 'kissassist', 'muleassist', or 'unknown'
function M.detectIniType(iniPath)
    local pathLower = iniPath:lower()

    if pathLower:find('kissassist') then
        return 'kissassist'
    elseif pathLower:find('muleassist') then
        return 'muleassist'
    end

    -- Try to detect from content
    local ini = mq.TLO.Ini
    if ini then
        local ok, val = pcall(function()
            return ini(iniPath, 'KConditions', 'CondSize')()
        end)
        if ok and val then
            return 'kissassist'  -- KissAssist has KConditions section
        end
    end

    return 'unknown'
end

--- Parse any supported INI file
---@param iniPath string Path to the INI file
---@return table config Parsed configuration
function M.parseIni(iniPath)
    local iniType = M.detectIniType(iniPath)

    if iniType == 'kissassist' then
        return M.parseKissAssist(iniPath)
    elseif iniType == 'muleassist' then
        return M.parseMuleAssist(iniPath)
    else
        -- Print disabled
        return {
            spells = {},
            conditions = {},
            burns = {},
            settings = {},
            source = 'unknown',
            path = iniPath,
        }
    end
end

return M
