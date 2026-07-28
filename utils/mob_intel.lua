-- utils/mob_intel.lua
-- Mob Intel - Consolidated per-zone/per-mob knowledge base and share-ready export.
--
-- Owns tracking for:
--  * CC susceptibility: slow / snare / mez / charm / root / stun / fear
--    (landed vs resisted counts + hard-immune flag, learned from cast results)
--  * Spells the NPC casts ("<mob> begins casting <spell>")
--  * Mob level and which of my classes contributed observations
--
-- Consolidates on export with the other learned stores:
--  * resist_tracker  - per-element resist rates + partial-resist efficiency
--  * mob_hp_estimator - absolute max HP estimates
--
-- /skmobintel export writes SideKick/export/mob_intel.csv (+ .json): one row per
-- zone/mob, directly importable into Google Sheets for community contribution.

local mq = require('mq')
local lazy = require('sidekick-next.utils.lazy_require')
local SafeLoad = require('sidekick-next.utils.safe_load')
local MobName = require('sidekick-next.utils.mob_name')

local M = {}

-- zone -> mobName -> { level, classes = {CLS=true}, cc = {type={landed,resisted,immune}}, casts = {spell=count} }
M.database = {}
M.zoneData = {}
M.currentZone = ''
M.dirty = false

-- Pending CC attempts awaiting land/resist resolution (same model as resist_tracker)
local _pending = {}
local PENDING_GRACE_MS = 2000
local _initialized = false

local _lastSave = 0
local SAVE_INTERVAL_MS = 30000

-- Cache of name -> isNPC lookups for the caster event (mobs cast repeatedly)
local _npcCache = {}   -- name -> { isNPC, expires }
local NPC_CACHE_MS = 30000

-- spellCategory -> CC type tracked here
local CC_CATEGORIES = {
    slow = 'slow', snare = 'snare', mez = 'mez', cc = 'mez',
    charm = 'charm', root = 'root', stun = 'stun', fear = 'fear',
}

-- CC types in export order
local CC_TYPES = { 'slow', 'snare', 'mez', 'charm', 'root', 'stun', 'fear' }

-- Elements in export order (must match resist_tracker keys, lowercased ResistType)
local ELEMENTS = { 'magic', 'fire', 'cold', 'poison', 'disease', 'corruption' }

local getPaths = lazy('sidekick-next.utils.paths')
local getSpellEvents = lazy('sidekick-next.utils.spell_events')
local getResistTracker = lazy('sidekick-next.utils.resist_tracker')
local getHpEstimator = lazy('sidekick-next.utils.mob_hp_estimator')

local function getDbPath()
    local Paths = getPaths()
    if Paths and Paths.getMobIntelPath then
        return Paths.getMobIntelPath()
    end
    return mq.configDir .. '/SideKick/data/mob_intel.lua'
end

local function myClass()
    local ok, cls = pcall(function() return mq.TLO.Me.Class.ShortName() end)
    return (ok and cls) or ''
end

-------------------------------------------------------------------------------
-- Persistence (own store)
-------------------------------------------------------------------------------

local function serialize(tbl, indent)
    indent = indent or ''
    local lines = { '{' }
    for k, v in pairs(tbl) do
        local key
        if type(k) == 'string' then
            key = '["' .. k:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"]'
        else
            key = '[' .. tostring(k) .. ']'
        end
        if type(v) == 'table' then
            table.insert(lines, indent .. '  ' .. key .. ' = ' .. serialize(v, indent .. '  ') .. ',')
        elseif type(v) == 'number' or type(v) == 'boolean' then
            table.insert(lines, indent .. '  ' .. key .. ' = ' .. tostring(v) .. ',')
        else
            table.insert(lines, indent .. '  ' .. key .. ' = "' .. tostring(v):gsub('\\', '\\\\'):gsub('"', '\\"') .. '",')
        end
    end
    table.insert(lines, indent .. '}')
    return table.concat(lines, '\n')
end

function M.loadDatabase()
    M.currentZone = ''
    M.zoneData = {}

    local path = getDbPath()
    local file = io.open(path, 'r')
    if not file then
        M.database = {}
        return
    end
    local content = file:read('*all')
    file:close()

    if content and content ~= '' then
        local data, err = SafeLoad.tableLiteral(content, path)
        if type(data) == 'table' then
            M.database = data
            return
        end
        print(string.format('\ar[MobIntel]\ax load failed: %s', tostring(err or 'invalid data')))
    end
    M.database = {}
end

function M.saveDatabase()
    if not M.dirty then return end

    local Paths = getPaths()
    if Paths then
        Paths.ensureDir(Paths.getDataDir())
    end

    local safeWrite = require('sidekick-next.utils.safe_write')
    local ok, err = safeWrite(getDbPath(), serialize(M.database))
    if not ok then
        print(string.format('\ar[MobIntel]\ax Failed to save: %s', tostring(err)))
        return
    end
    M.dirty = false
end

function M.loadZone()
    local zone = mq.TLO.Zone.ShortName() or ''
    if zone == M.currentZone then return end

    M.saveDatabase()
    M.currentZone = zone
    M.zoneData = M.database[zone] or {}
    _pending = {}
    _npcCache = {}
end

-------------------------------------------------------------------------------
-- Recording
-------------------------------------------------------------------------------

local function getMobRecord(mobName)
    if not MobName.isKnowledgeName(mobName) then return nil end
    local zone = M.currentZone
    if zone == '' then return nil end

    if not M.database[zone] then M.database[zone] = {} end
    local rec = M.database[zone][mobName]
    if not rec then
        rec = { classes = {}, cc = {}, casts = {} }
        M.database[zone][mobName] = rec
    end
    rec.classes = rec.classes or {}
    rec.cc = rec.cc or {}
    rec.casts = rec.casts or {}
    M.zoneData = M.database[zone]

    local cls = myClass()
    if cls ~= '' then rec.classes[cls] = true end

    return rec
end

local function noteLevel(rec, mobId)
    if not rec or rec.level then return end
    if not mobId or mobId <= 0 then return end
    local ok, level = pcall(function()
        local s = mq.TLO.Spawn(mobId)
        return s and s() and tonumber(s.Level()) or nil
    end)
    if ok and level and level > 0 then
        rec.level = level
        M.dirty = true
    end
end

local function ccStats(rec, ccType, create)
    if not rec then return nil end
    local cc = rec.cc[ccType]
    if not cc and create then
        cc = { landed = 0, resisted = 0 }
        rec.cc[ccType] = cc
    end
    return cc
end

function M.recordCCLanded(mobName, ccType, mobId)
    local rec = getMobRecord(mobName)
    local cc = ccStats(rec, ccType, true)
    if not cc then return end
    cc.landed = (cc.landed or 0) + 1
    noteLevel(rec, mobId)
    M.dirty = true
end

function M.recordCCResisted(mobName, ccType, mobId)
    local rec = getMobRecord(mobName)
    local cc = ccStats(rec, ccType, true)
    if not cc then return end
    cc.resisted = (cc.resisted or 0) + 1
    noteLevel(rec, mobId)
    M.dirty = true
end

function M.recordCCImmune(mobName, ccType, mobId)
    local rec = getMobRecord(mobName)
    local cc = ccStats(rec, ccType, true)
    if not cc then return end
    cc.immune = true
    noteLevel(rec, mobId)
    M.dirty = true
end

function M.recordNpcCast(mobName, spellName)
    if not spellName or spellName == '' then return end
    local rec = getMobRecord(mobName)
    if not rec then return end
    rec.casts[spellName] = (rec.casts[spellName] or 0) + 1
    M.dirty = true
end

-------------------------------------------------------------------------------
-- Queries (usable by CC automation)
-------------------------------------------------------------------------------

--- Get CC status for a mob
-- @param mobName string Mob clean name
-- @param ccType string 'slow'|'snare'|'mez'|'charm'|'root'|'stun'|'fear'
-- @return string status 'yes'|'immune'|'resists'|'unknown'
-- @return table|nil stats { landed, resisted, immune }
function M.getCCStatus(mobName, ccType)
    local rec = M.zoneData[mobName]
    local cc = rec and rec.cc and rec.cc[ccType]
    if not cc then return 'unknown', nil end
    if cc.immune then return 'immune', cc end
    if (cc.landed or 0) > 0 then return 'yes', cc end
    if (cc.resisted or 0) > 0 then return 'resists', cc end
    return 'unknown', cc
end

--- Get the spells a mob has been seen casting
-- @param mobName string Mob clean name
-- @return table spells spellName -> count
function M.getNpcCasts(mobName)
    local rec = M.zoneData[mobName]
    return (rec and rec.casts) or {}
end

-------------------------------------------------------------------------------
-- Feeding
-------------------------------------------------------------------------------

local function resolveTargetInfo(targetId)
    if not targetId or targetId <= 0 then return '', 0 end
    local ok, name = pcall(function()
        local s = mq.TLO.Spawn(targetId)
        return s and s() and s.CleanName() or nil
    end)
    return (ok and name) or '', targetId
end

--- Chained from SpellEngine.onCastComplete (via init)
function M.onCastComplete(castData, result)
    if not castData then return end
    local ccType = CC_CATEGORIES[tostring(castData.spellCategory or ''):lower()]
    if not ccType then return end

    local mobId = tonumber(castData.targetId) or 0
    local mobName = tostring(castData.targetName or '')
    if mobName == '' then mobName, mobId = resolveTargetInfo(mobId) end
    if not MobName.isKnowledgeName(mobName) then return end

    local SpellEvents = getSpellEvents()
    local RESULT = SpellEvents and SpellEvents.RESULT or {}

    if result == RESULT.RESISTED then
        M.recordCCResisted(mobName, ccType, mobId)
    elseif result == RESULT.IMMUNE then
        M.recordCCImmune(mobName, ccType, mobId)
    elseif result == RESULT.SUCCESS then
        table.insert(_pending, {
            spell = castData.spellName,
            mob = mobName,
            mobId = mobId,
            ccType = ccType,
            expires = mq.gettime() + PENDING_GRACE_MS,
        })
    end
end

local function onResistEvent(spellName)
    for i, p in ipairs(_pending) do
        if not spellName or spellName == '' or p.spell == spellName then
            table.remove(_pending, i)
            M.recordCCResisted(p.mob, p.ccType, p.mobId)
            return
        end
    end
end

local function onImmuneEvent(ccType)
    -- Immune message references the current target
    local ok, info = pcall(function()
        local t = mq.TLO.Target
        if t and t() then
            return { name = t.CleanName(), id = t.ID() }
        end
        return nil
    end)
    if not ok or not info or not info.name then return end

    M.recordCCImmune(info.name, ccType, info.id)

    -- Any pending CC attempt of this type on this mob is resolved by the immunity
    for i = #_pending, 1, -1 do
        local p = _pending[i]
        if p.mob == info.name and p.ccType == ccType then
            table.remove(_pending, i)
        end
    end
end

local function isNpcName(name)
    local now = mq.gettime()
    local cached = _npcCache[name]
    if cached and now < cached.expires then
        return cached.isNPC
    end

    local ok, isNPC = pcall(function()
        local s = mq.TLO.Spawn(string.format('"%s"', name))
        if s and s() then
            local ty = s.Type and s.Type() or ''
            return ty == 'NPC'
        end
        return false
    end)
    isNPC = ok and isNPC or false
    _npcCache[name] = { isNPC = isNPC, expires = now + NPC_CACHE_MS }
    return isNPC
end

--- Resolve expired CC pendings as landed; throttled save
function M.tick()
    local now = mq.gettime()

    local i = 1
    while i <= #_pending do
        local p = _pending[i]
        if now >= p.expires then
            table.remove(_pending, i)
            M.recordCCLanded(p.mob, p.ccType, p.mobId)
        else
            i = i + 1
        end
    end

    if M.dirty and (now - _lastSave) >= SAVE_INTERVAL_MS then
        _lastSave = now
        M.saveDatabase()
    end
end

-------------------------------------------------------------------------------
-- Consolidated export (CSV + JSON, share-ready)
-------------------------------------------------------------------------------

-- Build one merged view: zone -> mob -> everything we know
function M.buildConsolidated()
    local out = {}

    local function mobEntry(zone, name)
        out[zone] = out[zone] or {}
        out[zone][name] = out[zone][name] or {}
        return out[zone][name]
    end

    -- Own store: level, classes, cc, casts
    for zone, mobs in pairs(M.database) do
        for name, rec in pairs(mobs) do
            if MobName.isKnowledgeName(name) then
                local e = mobEntry(zone, name)
                e.level = rec.level
                e.classes = rec.classes
                e.cc = rec.cc
                e.casts = rec.casts
            end
        end
    end

    -- Resist tracker: per-element rates + efficiency
    local RT = getResistTracker()
    if RT and RT.loadDatabase and not next(RT.database or {}) then
        pcall(RT.loadDatabase)
    end
    if RT and RT.database then
        for zone, mobs in pairs(RT.database) do
            for name, elements in pairs(mobs) do
                if MobName.isKnowledgeName(name) then
                    mobEntry(zone, name).resists = elements
                end
            end
        end
    end

    -- HP estimator: absolute max HP
    local HP = getHpEstimator()
    if HP and HP.loadDatabase and not next(HP.database or {}) then
        pcall(HP.loadDatabase)
    end
    if HP and HP.database then
        for zone, mobs in pairs(HP.database) do
            for name, d in pairs(mobs) do
                if MobName.isKnowledgeName(name) then
                    local e = mobEntry(zone, name)
                    e.maxHP = d.maxHP
                    e.hpWeight = d.weight
                end
            end
        end
    end

    return out
end

local function csvEscape(s)
    s = tostring(s or '')
    if s:find('[",\n]') then
        return '"' .. s:gsub('"', '""') .. '"'
    end
    return s
end

local function ccCell(cc, ccType)
    local d = cc and cc[ccType]
    if not d then return 'unknown', '' end
    local status
    if d.immune then
        status = 'immune'
    elseif (d.landed or 0) > 0 then
        status = 'yes'
    elseif (d.resisted or 0) > 0 then
        status = 'resists'
    else
        status = 'unknown'
    end
    return status, string.format('%d/%d', d.landed or 0, d.resisted or 0)
end

--- Write the consolidated CSV (one row per zone/mob - Google Sheets ready)
-- @return string|nil path Written file path (nil on failure)
function M.exportCSV()
    local data = M.buildConsolidated()

    local header = { 'zone', 'mob', 'level', 'classes', 'est_max_hp', 'hp_confidence' }
    for _, el in ipairs(ELEMENTS) do
        table.insert(header, el .. '_resist_pct')
        table.insert(header, el .. '_eff_pct')
        table.insert(header, el .. '_samples')
    end
    for _, cc in ipairs(CC_TYPES) do
        table.insert(header, cc)
        table.insert(header, cc .. '_counts')
    end
    table.insert(header, 'npc_casts')

    local lines = { table.concat(header, ',') }

    -- Deterministic row order for clean diffs/sheet updates
    local zones = {}
    for zone in pairs(data) do table.insert(zones, zone) end
    table.sort(zones)

    for _, zone in ipairs(zones) do
        local names = {}
        for name in pairs(data[zone]) do table.insert(names, name) end
        table.sort(names)

        for _, name in ipairs(names) do
            local e = data[zone][name]
            local row = {
                csvEscape(zone),
                csvEscape(name),
                e.level or '',
                '',
                e.maxHP and string.format('%d', e.maxHP) or '',
                e.hpWeight and string.format('%.1f', e.hpWeight) or '',
            }

            if e.classes then
                local cls = {}
                for c in pairs(e.classes) do table.insert(cls, c) end
                table.sort(cls)
                row[4] = csvEscape(table.concat(cls, ';'))
            end

            for _, el in ipairs(ELEMENTS) do
                local d = e.resists and e.resists[el]
                if d then
                    local landed = d.landed or 0
                    local resisted = d.resisted or 0
                    local samples = landed + resisted
                    table.insert(row, samples > 0 and string.format('%.0f', resisted / samples * 100) or '')
                    if (d.effCount or 0) > 0 then
                        table.insert(row, string.format('%.0f', d.effSum / d.effCount * 100))
                    else
                        table.insert(row, '')
                    end
                    table.insert(row, samples)
                else
                    table.insert(row, '')
                    table.insert(row, '')
                    table.insert(row, '')
                end
            end

            for _, cc in ipairs(CC_TYPES) do
                local status, counts = ccCell(e.cc, cc)
                table.insert(row, status)
                table.insert(row, counts)
            end

            if e.casts then
                local casts = {}
                for spell in pairs(e.casts) do table.insert(casts, spell) end
                table.sort(casts)
                table.insert(row, csvEscape(table.concat(casts, ';')))
            else
                table.insert(row, '')
            end

            table.insert(lines, table.concat(row, ','))
        end
    end

    local Paths = getPaths()
    local dir = (Paths and Paths.getExportDir and Paths.getExportDir())
        or (mq.configDir .. '/SideKick/export')
    local path = dir .. '/mob_intel.csv'

    local safeWrite = require('sidekick-next.utils.safe_write')
    local ok, err = safeWrite(path, table.concat(lines, '\n'))
    if not ok then
        print(string.format('\ar[MobIntel]\ax CSV export failed: %s', tostring(err)))
        return nil
    end
    return path
end

-- Minimal JSON encoder (strings, numbers, booleans, tables)
local function jsonEncode(v, indent)
    indent = indent or ''
    local t = type(v)
    if t == 'nil' then return 'null' end
    if t == 'boolean' then return tostring(v) end
    if t == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then return '0' end
        if v == math.floor(v) then return string.format('%d', v) end
        return string.format('%.2f', v)
    end
    if t == 'string' then
        return '"' .. v:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
    end
    if t == 'table' then
        -- Array?
        local n = #v
        local isArray = n > 0
        if isArray then
            local parts = {}
            for _, item in ipairs(v) do
                table.insert(parts, jsonEncode(item, indent))
            end
            return '[' .. table.concat(parts, ',') .. ']'
        end
        local keys = {}
        for k in pairs(v) do table.insert(keys, tostring(k)) end
        table.sort(keys)
        local parts = {}
        local inner = indent .. '  '
        for _, k in ipairs(keys) do
            table.insert(parts, inner .. jsonEncode(k) .. ':' .. jsonEncode(v[k], inner))
        end
        if #parts == 0 then return '{}' end
        return '{\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. '}'
    end
    return 'null'
end

--- Write the consolidated JSON export
-- @return string|nil path Written file path (nil on failure)
function M.exportJSON()
    local data = M.buildConsolidated()

    local doc = {
        format = 'sidekick-mob-intel',
        version = 1,
        server = (function()
            local ok, s = pcall(function() return mq.TLO.EverQuest.Server() end)
            return (ok and s) or ''
        end)(),
        zones = data,
    }

    local Paths = getPaths()
    local dir = (Paths and Paths.getExportDir and Paths.getExportDir())
        or (mq.configDir .. '/SideKick/export')
    local path = dir .. '/mob_intel.json'

    local safeWrite = require('sidekick-next.utils.safe_write')
    local ok, err = safeWrite(path, jsonEncode(doc))
    if not ok then
        print(string.format('\ar[MobIntel]\ax JSON export failed: %s', tostring(err)))
        return nil
    end
    return path
end

--- Export both formats, announcing paths in chat
function M.exportAll()
    local csv = M.exportCSV()
    local json = M.exportJSON()
    if csv then print(string.format('\ag[MobIntel]\ax Exported %s', csv)) end
    if json then print(string.format('\ag[MobIntel]\ax Exported %s', json)) end
    return csv, json
end

-------------------------------------------------------------------------------
-- Lifecycle
-------------------------------------------------------------------------------

function M.init()
    if _initialized then return end
    M.loadDatabase()
    M.loadZone()

    -- Resist events claim pending CC attempts
    mq.event('sk_mi_resist1', "Your target resisted the #1# spell#*#", function(_, spell)
        onResistEvent(spell)
    end)
    mq.event('sk_mi_resist2', "#2# resisted your #1#!", function(_, spell, _)
        onResistEvent(spell)
    end)

    -- Typed immunity messages (which CC type was immune)
    mq.event('sk_mi_imm_slow', "Your target is immune to changes in its attack speed#*#", function()
        onImmuneEvent('slow')
    end)
    mq.event('sk_mi_imm_snare', "Your target is immune to changes in its run speed#*#", function()
        onImmuneEvent('snare')
    end)
    mq.event('sk_mi_imm_mez', "Your target cannot be mesmerized#*#", function()
        onImmuneEvent('mez')
    end)
    mq.event('sk_mi_imm_charm', "Your target cannot be charmed#*#", function()
        onImmuneEvent('charm')
    end)
    mq.event('sk_mi_imm_root', "Your target cannot be rooted#*#", function()
        onImmuneEvent('root')
    end)
    mq.event('sk_mi_imm_stun', "Your target is immune to stun#*#", function()
        onImmuneEvent('stun')
    end)
    mq.event('sk_mi_imm_fear', "Your target is immune to fear#*#", function()
        onImmuneEvent('fear')
    end)

    -- NPC spell casting observation
    mq.event('sk_mi_npccast', "#1# begins casting #2#.#*#", function(_, caster, spell)
        if tostring(caster):lower() == 'you' then return end
        if isNpcName(caster) then
            M.recordNpcCast(caster, spell)
        end
    end)

    -- Observe cast completions for CC results without replacing other
    -- process-local consumers.
    local ok, SpellEngine = pcall(require, 'sidekick-next.utils.spell_engine')
    if ok and SpellEngine then
        if SpellEngine.addCastCompleteListener then
            SpellEngine.addCastCompleteListener(M.onCastComplete)
        else
            local prev = SpellEngine.onCastComplete
            SpellEngine.onCastComplete = function(castData, result)
                if prev then pcall(prev, castData, result) end
                M.onCastComplete(castData, result)
            end
        end
    end
    _initialized = true
end

function M.shutdown()
    mq.unevent('sk_mi_resist1')
    mq.unevent('sk_mi_resist2')
    mq.unevent('sk_mi_imm_slow')
    mq.unevent('sk_mi_imm_snare')
    mq.unevent('sk_mi_imm_mez')
    mq.unevent('sk_mi_imm_charm')
    mq.unevent('sk_mi_imm_root')
    mq.unevent('sk_mi_imm_stun')
    mq.unevent('sk_mi_imm_fear')
    mq.unevent('sk_mi_npccast')
    M.saveDatabase()
end

return M
