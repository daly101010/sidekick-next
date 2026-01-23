-- F:/lua/sidekick-next/utils/spellbook_scanner.lua
-- Spellbook scanner that parses character's spellbook and categorizes spells
-- Uses EQ's native Category/Subcategory with fallback heuristics

local mq = require('mq')

---@class SpellbookScanner
local M = {}

-- Cached spell data
---@type { combat: table, ooc: table }
M.spells = { combat = {}, ooc = {} }

---@type number Last scan timestamp
M.lastScan = 0

---@type number Seconds between rescans
M.SCAN_COOLDOWN = 5

---@type table<number, SpellEntry> Quick lookup by spell ID
M.byId = {}

--------------------------------------------------------------------------------
-- SPA Constants for debuff detection
--------------------------------------------------------------------------------

---@type table<string, number> Spell ability constants
local SPA = {
    SNARE = 3,          -- Movement speed reduction
    TASH = 10,          -- Magic resist debuff (Tashani line)
    SLOW = 11,          -- Attack speed reduction
    MEZ = 31,           -- Mesmerize
    CRIPPLE = 96,       -- Stat debuff (Cripple line)
    ROOT = 99,          -- Root (movement prevention)
    RESIST_DEBUFF = 116, -- Resist debuffs (various types)
}

-- Export SPA constants for external use
M.SPA = SPA

--------------------------------------------------------------------------------
-- Type Definitions
--------------------------------------------------------------------------------

---@class SpellEntry
---@field name string Spell name
---@field id number Spell ID
---@field category string Category (e.g., "Heals", "Damage", "Buffs")
---@field subcategory string Subcategory (e.g., "Direct", "Group", "DoT")
---@field spellType string "Beneficial", "Beneficial(Group)", "Detrimental", or "Unknown"
---@field targetType string Target type (e.g., "Single", "Group v2", "Self")
---@field duration number Duration in ticks (0 = instant)
---@field beneficial boolean True if spell is beneficial
---@field level number Spell level for this class
---@field bookSlot number Position in spellbook (1-720)

--------------------------------------------------------------------------------
-- Category Inference
--------------------------------------------------------------------------------

---Check if a spell is a heal (has healing SPA or heal-related category)
---@param spell MQSpell The spell object from TLO
---@return boolean isHeal True if spell is a heal
local function isHealSpell(spell)
    if not spell or not spell() then return false end

    -- Check for healing SPA (SPA 0 = HP increase)
    local hasSPA = spell.HasSPA
    if hasSPA then
        local ok, hasHealSPA = pcall(function() return hasSPA(0)() end)
        if ok and hasHealSPA then return true end
    end

    -- Check spell name for heal keywords
    local name = spell.Name and spell.Name() or ""
    local nameLower = name:lower()
    if nameLower:find("heal") or nameLower:find("remedy") or nameLower:find("mend")
        or nameLower:find("cure") or nameLower:find("rejuvenation")
        or nameLower:find("celestial") or nameLower:find("renewal") then
        return true
    end

    return false
end

---Infer category from spell properties when native category is empty
---@param spell MQSpell The spell object from TLO
---@return string category The inferred category
---@return string subcategory The inferred subcategory
local function inferCategory(spell)
    local spellType = spell.SpellType and spell.SpellType() or ""
    local targetType = spell.TargetType and spell.TargetType() or ""
    local beneficial = spell.Beneficial and spell.Beneficial() or false
    local rawDuration = spell.Duration and spell.Duration() or 0
    local duration = tonumber(rawDuration) or 0

    -- Check for specific SPAs first (debuff detection)
    local hasSPA = spell.HasSPA
    if hasSPA then
        local ok, hasSlowSPA = pcall(function() return hasSPA(SPA.SLOW)() end)
        if ok and hasSlowSPA then return "Debuffs", "Slow" end

        ok, hasSlowSPA = pcall(function() return hasSPA(SPA.TASH)() end)
        if ok and hasSlowSPA then return "Debuffs", "Tash" end

        ok, hasSlowSPA = pcall(function() return hasSPA(SPA.MEZ)() end)
        if ok and hasSlowSPA then return "Debuffs", "Mez" end

        ok, hasSlowSPA = pcall(function() return hasSPA(SPA.ROOT)() end)
        if ok and hasSlowSPA then return "Debuffs", "Root" end

        ok, hasSlowSPA = pcall(function() return hasSPA(SPA.SNARE)() end)
        if ok and hasSlowSPA then return "Debuffs", "Snare" end

        ok, hasSlowSPA = pcall(function() return hasSPA(SPA.CRIPPLE)() end)
        if ok and hasSlowSPA then return "Debuffs", "Cripple" end

        ok, hasSlowSPA = pcall(function() return hasSPA(SPA.RESIST_DEBUFF)() end)
        if ok and hasSlowSPA then return "Debuffs", "Resist" end
    end

    if not beneficial then
        -- Detrimental spells
        if duration > 0 then
            return "Damage", "DoT"
        else
            return "Damage", "Direct"
        end
    else
        -- Beneficial spells - check target type
        local targetLower = targetType:lower()
        local isGroup = targetLower:find("group")
        local isHeal = isHealSpell(spell)

        if isHeal then
            -- Heal categorization
            if isGroup then
                if duration > 0 then
                    return "Heals", "Group HoT Heals"
                else
                    return "Heals", "Group Direct Heals"
                end
            else
                if duration > 0 then
                    return "Heals", "HoT Heals"
                else
                    return "Heals", "Direct Heals"
                end
            end
        elseif isGroup then
            return "Buffs", "Group"
        elseif targetLower == "self" then
            return "Buffs", "Self"
        else
            return "Buffs", "Single"
        end
    end
end

-- Export for testing/external use
M.inferCategory = inferCategory

---Normalize category and subcategory names to our standard format
---Specifically handles Heals subcategories
---@param category string The raw category
---@param subcategory string The raw subcategory
---@param spell MQSpell The spell object for additional context
---@return string category The normalized category
---@return string subcategory The normalized subcategory
local function normalizeCategory(category, subcategory, spell)
    -- Defensive nil checks
    if not category or category == "" then return category or "Unknown", subcategory or "General" end
    if not subcategory then subcategory = "General" end
    if not spell or not spell() then return category, subcategory end

    local catLower = category:lower()
    local subcatLower = subcategory:lower()

    -- Handle Heals category normalization
    if catLower:find("heal") then
        local targetType = spell.TargetType and spell.TargetType() or ""
        local targetLower = targetType:lower()
        local rawDuration = spell.Duration and spell.Duration() or 0
        local duration = tonumber(rawDuration) or 0
        local isGroup = targetLower:find("group")

        -- Determine proper heal subcategory
        if isGroup then
            if duration > 0 or subcatLower:find("hot") or subcatLower:find("over time") then
                return "Heals", "Group HoT Heals"
            else
                return "Heals", "Group Direct Heals"
            end
        else
            if duration > 0 or subcatLower:find("hot") or subcatLower:find("over time") then
                return "Heals", "HoT Heals"
            elseif subcatLower:find("heal") or subcatLower == "direct" or subcatLower == "general" then
                return "Heals", "Direct Heals"
            else
                -- Keep other heal subcategories as-is (e.g., "Cure", "Resurrection")
                return "Heals", subcategory
            end
        end
    end

    return category, subcategory
end

-- Export for testing/external use
M.normalizeCategory = normalizeCategory

--------------------------------------------------------------------------------
-- Internal Helpers
--------------------------------------------------------------------------------

---Add spell entry to categorized structure
---@param spells table The categorized spell table {category -> subcategory -> entries[]}
---@param entry SpellEntry The spell entry to add
local function addToCategory(spells, entry)
    local cat = entry.category
    local subcat = entry.subcategory

    if not spells[cat] then
        spells[cat] = {}
    end
    if not spells[cat][subcat] then
        spells[cat][subcat] = {}
    end

    table.insert(spells[cat][subcat], entry)
end

-- Export for testing/external use
M.addToCategory = addToCategory

--------------------------------------------------------------------------------
-- Main Scan Function
--------------------------------------------------------------------------------

---Scan character's spellbook and categorize all spells
---Respects SCAN_COOLDOWN to avoid excessive rescanning
---@return table spells { combat = {...}, ooc = {...} }
function M.scan()
    local now = os.time()
    if now - M.lastScan < M.SCAN_COOLDOWN then
        return M.spells
    end

    -- Reset spell data
    M.spells = { combat = {}, ooc = {} }
    M.byId = {}

    local me = mq.TLO.Me
    if not me or not me() then
        return M.spells
    end

    -- Iterate through all 720 possible spellbook slots
    for i = 1, 720 do
        local spell = me.Book(i)
        if spell and spell() and spell.Name and spell.Name() then
            local spellName = spell.Name()
            local spellId = spell.ID and spell.ID() or 0

            -- Skip if we already have this spell (can happen with ranks)
            if spellId > 0 and not M.byId[spellId] then
                -- Get native category/subcategory
                local category = ""
                local subcategory = ""

                if spell.Category then
                    local ok, cat = pcall(function() return spell.Category() end)
                    if ok and cat and cat ~= "" and cat ~= "Unknown" then
                        category = cat
                    end
                end

                if spell.Subcategory then
                    local ok, subcat = pcall(function() return spell.Subcategory() end)
                    if ok and subcat and subcat ~= "" and subcat ~= "Unknown" then
                        subcategory = subcat
                    end
                end

                -- Fallback if category is empty
                if category == "" then
                    category, subcategory = inferCategory(spell)
                end

                -- Default subcategory if still empty
                if subcategory == "" then
                    subcategory = "General"
                end

                -- Normalize categories (especially Heals subcategories)
                category, subcategory = normalizeCategory(category, subcategory, spell)

                -- Get spell properties safely
                local spellType = ""
                if spell.SpellType then
                    local ok, st = pcall(function() return spell.SpellType() end)
                    if ok and st then spellType = st end
                end

                local targetType = ""
                if spell.TargetType then
                    local ok, tt = pcall(function() return spell.TargetType() end)
                    if ok and tt then targetType = tt end
                end

                local duration = 0
                if spell.Duration then
                    local ok, dur = pcall(function() return spell.Duration() end)
                    if ok and dur then duration = tonumber(dur) or 0 end
                end

                local beneficial = false
                if spell.Beneficial then
                    local ok, ben = pcall(function() return spell.Beneficial() end)
                    if ok then beneficial = ben end
                end

                local level = 0
                if spell.Level then
                    local ok, lvl = pcall(function() return spell.Level() end)
                    if ok and lvl then level = tonumber(lvl) or 0 end
                end

                ---@type SpellEntry
                local entry = {
                    name = spellName,
                    id = spellId,
                    category = category,
                    subcategory = subcategory,
                    spellType = spellType,
                    targetType = targetType,
                    duration = duration,
                    beneficial = beneficial,
                    level = level,
                    bookSlot = i,
                }

                -- Add to ID lookup
                M.byId[spellId] = entry

                -- Combat tab gets everything
                addToCategory(M.spells.combat, entry)

                -- OOC tab gets beneficial spells AND auras
                -- Auras may not be flagged as beneficial but should be in OOC
                local isAura = category:lower():find("aura")
                    or subcategory:lower():find("aura")
                    or spellName:lower():find("aura")
                    or targetType:lower():find("aura")

                if beneficial or isAura then
                    addToCategory(M.spells.ooc, entry)
                end
            end
        end
    end

    M.lastScan = now
    return M.spells
end

--------------------------------------------------------------------------------
-- Utility Functions
--------------------------------------------------------------------------------

---Force rescan on next call (clears cooldown)
function M.invalidate()
    M.lastScan = 0
end

---Get sorted category list for a tab
---@param tab string 'combat' or 'ooc'
---@return string[] categories Sorted list of category names
function M.getCategories(tab)
    local spells = M.spells[tab] or {}
    local categories = {}

    for cat in pairs(spells) do
        table.insert(categories, cat)
    end

    table.sort(categories)
    return categories
end

---Get sorted subcategory list for a category
---@param tab string 'combat' or 'ooc'
---@param category string The category to get subcategories for
---@return string[] subcategories Sorted list of subcategory names
function M.getSubcategories(tab, category)
    local spells = M.spells[tab] or {}
    local catSpells = spells[category] or {}
    local subcategories = {}

    for subcat in pairs(catSpells) do
        table.insert(subcategories, subcat)
    end

    table.sort(subcategories)
    return subcategories
end

---Get spells in a subcategory
---@param tab string 'combat' or 'ooc'
---@param category string The category
---@param subcategory string The subcategory
---@return SpellEntry[] spells List of spell entries in the subcategory
function M.getSpells(tab, category, subcategory)
    local spells = M.spells[tab] or {}
    local catSpells = spells[category] or {}
    return catSpells[subcategory] or {}
end

---Get spell entry by ID from the cached data
---@param spellId number The spell ID to find
---@return SpellEntry|nil entry The spell entry or nil if not found
function M.getSpellById(spellId)
    -- Fast path: direct lookup
    if M.byId[spellId] then
        return M.byId[spellId]
    end

    -- Fallback: search through combat spells (shouldn't normally be needed)
    for _, catSpells in pairs(M.spells.combat) do
        for _, subcatSpells in pairs(catSpells) do
            for _, spell in ipairs(subcatSpells) do
                if spell.id == spellId then
                    return spell
                end
            end
        end
    end

    return nil
end

---Get all spells as a flat list (for search/filtering)
---@param tab string 'combat' or 'ooc'
---@return SpellEntry[] spells Flat list of all spell entries
function M.getAllSpells(tab)
    local result = {}
    local spells = M.spells[tab] or {}

    for _, catSpells in pairs(spells) do
        for _, subcatSpells in pairs(catSpells) do
            for _, spell in ipairs(subcatSpells) do
                table.insert(result, spell)
            end
        end
    end

    -- Sort by level descending (highest level first)
    table.sort(result, function(a, b)
        return (a.level or 0) > (b.level or 0)
    end)

    return result
end

---Get spell count for a tab
---@param tab string 'combat' or 'ooc'
---@return number count Total number of spells
function M.getSpellCount(tab)
    local count = 0
    local spells = M.spells[tab] or {}

    for _, catSpells in pairs(spells) do
        for _, subcatSpells in pairs(catSpells) do
            count = count + #subcatSpells
        end
    end

    return count
end

---Search spells by name (case-insensitive partial match)
---@param tab string 'combat' or 'ooc'
---@param searchText string Text to search for in spell names
---@return SpellEntry[] matches Matching spell entries
function M.searchSpells(tab, searchText)
    if not searchText or searchText == "" then
        return M.getAllSpells(tab)
    end

    local searchLower = searchText:lower()
    local results = {}

    for _, spell in ipairs(M.getAllSpells(tab)) do
        if spell.name:lower():find(searchLower, 1, true) then
            table.insert(results, spell)
        end
    end

    return results
end

---Check if the spellbook has been scanned
---@return boolean scanned True if scan() has been called successfully
function M.isScanned()
    return M.lastScan > 0
end

---Get time until next scan is allowed
---@return number seconds Seconds until scan cooldown expires (0 if can scan now)
function M.getCooldownRemaining()
    local elapsed = os.time() - M.lastScan
    local remaining = M.SCAN_COOLDOWN - elapsed
    return remaining > 0 and remaining or 0
end

--------------------------------------------------------------------------------
-- Spell Name Normalization (for Auto-Upgrade Detection)
--------------------------------------------------------------------------------

---@type string[] Rank suffixes to strip (order matters - longer matches first)
local RANK_SUFFIXES = {
    -- Rk. suffixes (most common modern format)
    " Rk%. III",
    " Rk%. II",
    " Rk%. I",
    -- Roman numerals (longest first to avoid partial matches)
    " XIV",
    " XIII",
    " XII",
    " XI",
    " IX",
    " VIII",
    " VII",
    " VI",
    " IV",
    " III",
    " II",
    " X",  -- X after XI, XII, XIII, XIV to avoid partial match
    " V",  -- V after VI, VII, VIII to avoid partial match
    " I",  -- I after II, III, IV, IX to avoid partial match
}

---@type string Pattern for Arabic numeral suffixes at end of string
local ARABIC_NUMERAL_PATTERN = " %d+$"

---Normalize a spell name by stripping rank suffixes
---Removes Rk. suffixes, Roman numerals, and Arabic numerals from end of name
---@param name string The spell name to normalize
---@return string baseName The normalized base name
function M.normalizeSpellName(name)
    if not name or name == "" then
        return ""
    end

    local result = name

    -- Try to match and remove rank suffixes
    for _, suffix in ipairs(RANK_SUFFIXES) do
        -- Check if name ends with this suffix (using Lua pattern)
        local pattern = suffix .. "$"
        local newResult = result:gsub(pattern, "")
        if newResult ~= result then
            result = newResult
            break  -- Only remove one suffix
        end
    end

    -- If no Roman numeral/Rk suffix found, check for Arabic numerals
    if result == name then
        result = result:gsub(ARABIC_NUMERAL_PATTERN, "")
    end

    -- Trim whitespace
    result = result:match("^%s*(.-)%s*$") or result

    return result
end

---Find an upgrade for a spell in the spellbook
---Searches for spells with the same base name but higher level
---@param currentSpellId number The spell ID to find an upgrade for
---@return SpellEntry|nil upgrade The highest level upgrade found, or nil if none
function M.findUpgrade(currentSpellId)
    if not currentSpellId or currentSpellId <= 0 then
        return nil
    end

    -- Get current spell info from TLO
    local currentSpell = mq.TLO.Spell(currentSpellId)
    if not currentSpell or not currentSpell() then
        return nil
    end

    local currentName = currentSpell.Name and currentSpell.Name() or ""
    local currentLevel = currentSpell.Level and currentSpell.Level() or 0

    if currentName == "" or currentLevel <= 0 then
        return nil
    end

    -- Normalize the current spell name to get the base
    local baseName = M.normalizeSpellName(currentName)

    -- Search through all combat spells for upgrades
    local bestUpgrade = nil
    local bestLevel = currentLevel

    for _, catSpells in pairs(M.spells.combat) do
        for _, subcatSpells in pairs(catSpells) do
            for _, spell in ipairs(subcatSpells) do
                -- Skip the current spell itself
                if spell.id ~= currentSpellId then
                    -- Check if this spell has the same base name
                    local spellBaseName = M.normalizeSpellName(spell.name)
                    if spellBaseName == baseName then
                        -- Check if it's a higher level upgrade
                        if spell.level > bestLevel then
                            bestLevel = spell.level
                            bestUpgrade = spell
                        end
                    end
                end
            end
        end
    end

    return bestUpgrade
end

---Find upgrades for all spells in a spell set
---@param spellSet table Spell set with gems table: { gems = { [slot] = spellId, ... } }
---@return table upgrades Table of { [slot] = { current = SpellEntry, upgrade = SpellEntry } }
function M.findAllUpgrades(spellSet)
    local upgrades = {}

    if not spellSet or not spellSet.gems then
        return upgrades
    end

    for slot, spellId in pairs(spellSet.gems) do
        if spellId and spellId > 0 then
            local upgrade = M.findUpgrade(spellId)
            if upgrade then
                -- Get current spell entry from our cache or create minimal one
                local current = M.byId[spellId]
                if not current then
                    -- Create minimal entry from TLO if not in our cache
                    local spell = mq.TLO.Spell(spellId)
                    if spell and spell() then
                        current = {
                            name = spell.Name and spell.Name() or "Unknown",
                            id = spellId,
                            level = spell.Level and spell.Level() or 0,
                        }
                    end
                end

                if current then
                    upgrades[slot] = {
                        current = current,
                        upgrade = upgrade,
                    }
                end
            end
        end
    end

    return upgrades
end

return M
