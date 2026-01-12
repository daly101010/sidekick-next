-- F:/lua/SideKick/utils/ability_resolver.lua
-- Resolves spell/disc/AA lines to best available for the character

local mq = require('mq')

local M = {}

-- Cache for class configs
local classConfigCache = {}

--- Load a class config by class short name
---@param classShort string Class short name (CLR, WAR, etc.)
---@return table|nil config The class config or nil if not found
function M.loadClassConfig(classShort)
    if not classShort or classShort == '' then return nil end

    classShort = classShort:upper()
    if classConfigCache[classShort] then
        return classConfigCache[classShort]
    end

    local ok, config = pcall(require, string.format('data.class_configs.%s', classShort))
    if ok and config then
        classConfigCache[classShort] = config
        return config
    end

    return nil
end

--- Clear the class config cache (useful for hot reload)
function M.clearCache()
    classConfigCache = {}
end

--- Resolve spell line to best memorized spell
---@param classConfig table The class config with spellLines
---@param lineName string The spell line name
---@return table|nil resolved { name = spellName, gem = gemNumber } or nil
function M.resolveSpell(classConfig, lineName)
    if not classConfig or not classConfig.spellLines then return nil end
    if not lineName or lineName == '' then return nil end

    local line = classConfig.spellLines[lineName]
    if type(line) ~= 'table' then return nil end

    local me = mq.TLO.Me
    if not (me and me()) then return nil end

    local numGems = tonumber(me.NumGems()) or 13

    -- Check each spell in the line (ordered newest to oldest)
    for _, spellName in ipairs(line) do
        -- Check if memorized in any gem
        for gem = 1, numGems do
            local gemSpell = me.Gem(gem)
            if gemSpell and gemSpell() then
                local ok, name = pcall(function() return gemSpell.Name() end)
                if ok and name == spellName then
                    return {
                        name = spellName,
                        gem = gem,
                        ready = me.GemTimer(gem)() == 0,
                    }
                end
            end
        end
    end

    return nil
end

--- Resolve spell line to best available spell in spellbook (not necessarily memorized)
---@param classConfig table The class config with spellLines
---@param lineName string The spell line name
---@return table|nil resolved { name = spellName, inBook = true } or nil
function M.resolveSpellFromBook(classConfig, lineName)
    if not classConfig or not classConfig.spellLines then return nil end
    if not lineName or lineName == '' then return nil end

    local line = classConfig.spellLines[lineName]
    if type(line) ~= 'table' then return nil end

    local me = mq.TLO.Me
    if not (me and me()) then return nil end

    -- Check each spell in the line (ordered newest to oldest)
    for _, spellName in ipairs(line) do
        local ok, inBook = pcall(function() return me.Book(spellName)() end)
        if ok and inBook then
            return {
                name = spellName,
                inBook = true,
            }
        end
    end

    return nil
end

--- Resolve disc line to best available disc
---@param classConfig table The class config with discLines
---@param lineName string The disc line name
---@return table|nil resolved { name = discName, ready = boolean } or nil
function M.resolveDisc(classConfig, lineName)
    if not classConfig or not classConfig.discLines then return nil end
    if not lineName or lineName == '' then return nil end

    local line = classConfig.discLines[lineName]
    if type(line) ~= 'table' then return nil end

    local me = mq.TLO.Me
    if not (me and me()) then return nil end

    -- Check each disc in the line (ordered newest to oldest)
    for _, discName in ipairs(line) do
        -- Check if character has this combat ability
        local ok, hasDisc = pcall(function() return me.CombatAbility(discName)() end)
        if ok and hasDisc then
            local ready = false
            local readyOk, readyVal = pcall(function() return me.CombatAbilityReady(discName)() end)
            if readyOk then ready = readyVal == true end

            return {
                name = discName,
                ready = ready,
            }
        end
    end

    return nil
end

--- Resolve AA line to best available AA
---@param classConfig table The class config with aaLines
---@param lineName string The AA line name
---@return table|nil resolved { name = aaName, id = number, ready = boolean } or nil
function M.resolveAA(classConfig, lineName)
    if not classConfig or not classConfig.aaLines then return nil end
    if not lineName or lineName == '' then return nil end

    local line = classConfig.aaLines[lineName]
    if type(line) ~= 'table' then return nil end

    local me = mq.TLO.Me
    if not (me and me()) then return nil end

    -- Check each AA in the line (ordered newest to oldest)
    for _, aaName in ipairs(line) do
        local aa = me.AltAbility(aaName)
        if aa and aa() then
            local ok, hasSpell = pcall(function() return aa.Spell() end)
            if ok and hasSpell then
                local id = 0
                local idOk, idVal = pcall(function() return aa.ID() end)
                if idOk then id = tonumber(idVal) or 0 end

                local ready = false
                local readyOk, readyVal = pcall(function() return me.AltAbilityReady(aaName)() end)
                if readyOk then ready = readyVal == true end

                return {
                    name = aaName,
                    id = id,
                    ready = ready,
                }
            end
        end
    end

    return nil
end

--- Resolve ability line to best available ability
---@param classConfig table The class config with abilityLines
---@param lineName string The ability line name
---@return table|nil resolved { name = abilityName, ready = boolean } or nil
function M.resolveAbility(classConfig, lineName)
    if not classConfig or not classConfig.abilityLines then return nil end
    if not lineName or lineName == '' then return nil end

    local line = classConfig.abilityLines[lineName]
    if type(line) ~= 'table' then return nil end

    local me = mq.TLO.Me
    if not (me and me()) then return nil end

    -- Check each ability in the line
    for _, abilityName in ipairs(line) do
        local ok, hasAbility = pcall(function() return me.Ability(abilityName)() end)
        if ok and hasAbility then
            local ready = false
            local readyOk, readyVal = pcall(function() return me.AbilityReady(abilityName)() end)
            if readyOk then ready = readyVal == true end

            return {
                name = abilityName,
                ready = ready,
            }
        end
    end

    return nil
end

--- Find which spell line a specific spell belongs to
---@param classConfig table The class config with spellLines
---@param spellName string The specific spell name
---@return string|nil lineName, number|nil index The line name and position in line
function M.findSpellLine(classConfig, spellName)
    if not classConfig or not classConfig.spellLines then return nil, nil end
    if not spellName or spellName == '' then return nil, nil end

    for lineName, spells in pairs(classConfig.spellLines) do
        for idx, lineSpell in ipairs(spells) do
            if lineSpell == spellName then
                return lineName, idx
            end
        end
    end

    -- Try fuzzy match (same base name, different rank)
    local baseName = spellName:gsub(' Rk%. II+$', ''):gsub(' II+$', '')
    for lineName, spells in pairs(classConfig.spellLines) do
        for idx, lineSpell in ipairs(spells) do
            local lineBase = lineSpell:gsub(' Rk%. II+$', ''):gsub(' II+$', '')
            if lineBase == baseName then
                return lineName, idx
            end
        end
    end

    return nil, nil
end

--- Get a fallback spell when the requested one isn't available
---@param classConfig table The class config with spellLines
---@param spellName string The specific spell that's not available
---@param lineName string|nil The line name (optional, will be found if not provided)
---@return string|nil fallbackSpell The fallback spell name or nil
function M.getFallbackSpell(classConfig, spellName, lineName)
    if not classConfig or not classConfig.spellLines then return nil end

    -- Find the line if not provided
    local idx
    if not lineName then
        lineName, idx = M.findSpellLine(classConfig, spellName)
    else
        local line = classConfig.spellLines[lineName]
        if type(line) == 'table' then
            for i, s in ipairs(line) do
                if s == spellName then
                    idx = i
                    break
                end
            end
        end
    end

    if not lineName then return nil end

    local line = classConfig.spellLines[lineName]
    if type(line) ~= 'table' then return nil end

    local me = mq.TLO.Me
    if not (me and me()) then return nil end

    -- Start from the spell after the requested one
    local startIdx = (idx or 0) + 1

    for i = startIdx, #line do
        local testSpell = line[i]
        local ok, inBook = pcall(function() return me.Book(testSpell)() end)
        if ok and inBook then
            return testSpell
        end
    end

    return nil
end

--- Get all available spells from a line (for UI display)
---@param classConfig table The class config with spellLines
---@param lineName string The spell line name
---@return table available List of { name, inBook, memorized, gem }
function M.getAvailableSpellsFromLine(classConfig, lineName)
    local result = {}

    if not classConfig or not classConfig.spellLines then return result end
    if not lineName or lineName == '' then return result end

    local line = classConfig.spellLines[lineName]
    if type(line) ~= 'table' then return result end

    local me = mq.TLO.Me
    if not (me and me()) then return result end

    local numGems = tonumber(me.NumGems()) or 13

    for _, spellName in ipairs(line) do
        local entry = {
            name = spellName,
            inBook = false,
            memorized = false,
            gem = nil,
        }

        -- Check spellbook
        local ok, inBook = pcall(function() return me.Book(spellName)() end)
        entry.inBook = ok and inBook and true or false

        -- Check if memorized
        for gem = 1, numGems do
            local gemSpell = me.Gem(gem)
            if gemSpell and gemSpell() then
                local nameOk, name = pcall(function() return gemSpell.Name() end)
                if nameOk and name == spellName then
                    entry.memorized = true
                    entry.gem = gem
                    break
                end
            end
        end

        table.insert(result, entry)
    end

    return result
end

return M
