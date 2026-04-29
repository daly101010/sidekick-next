local mq = require('mq')

local M = {}

M.settings = nil

local function normalizeName(value)
    value = tostring(value or '')
    value = value:gsub('_', ' ')
    value = value:gsub('^%s+', ''):gsub('%s+$', '')
    return value:lower()
end

local function customNameSet(settings)
    local raw = tostring((settings and settings.NamedDetectionCustomNames) or '')
    local set = {}
    for token in raw:gmatch('[^,]+') do
        local name = normalizeName(token)
        if name ~= '' then set[name] = true end
    end
    return set
end

local function pluginLoaded(name)
    return pcall(function()
        local plugin = mq.TLO.Plugin(name)
        if not plugin then return false end
        if plugin.IsLoaded then return plugin.IsLoaded() == true end
        return plugin() == true
    end)
end

local function spawnMasterHas(spawn)
    if not spawn or not spawn() or not spawn.ID then return false end
    local id = tonumber(spawn.ID()) or 0
    if id <= 0 then return false end
    local ok, result = pcall(function()
        if not mq.TLO.SpawnMaster or not mq.TLO.SpawnMaster.HasSpawn then return false end
        return mq.TLO.SpawnMaster.HasSpawn(id)() == true
    end)
    return ok and result == true
end

local function alertMasterHas(spawn)
    if not spawn or not spawn() then return false end
    local displayName = spawn.DisplayName and spawn.DisplayName() or spawn.CleanName()
    if not displayName or displayName == '' then return false end
    local ok, result = pcall(function()
        if not mq.TLO.AlertMaster or not mq.TLO.AlertMaster.IsNamed then return false end
        return mq.TLO.AlertMaster.IsNamed(displayName)() == true
    end)
    return ok and result == true
end

function M.init(settings)
    M.settings = settings
end

function M.isNamed(spawn, settings)
    settings = settings or M.settings or {}
    if not spawn or not spawn() then return false end

    local minLevel = tonumber(settings.NamedDetectionMinLevel) or 0
    if minLevel > 0 and spawn.Level and (tonumber(spawn.Level()) or 0) < minLevel then
        return false
    end

    if settings.NamedDetectionForceNamed == true then return true end

    if spawn.Named and spawn.Named() == true then return true end

    local body = spawn.Body and spawn.Body() or ''
    if body == 'Giant' then return true end

    local cleanName = normalizeName(spawn.CleanName and spawn.CleanName() or spawn.Name())
    local rawName = normalizeName(spawn.Name and spawn.Name() or cleanName)
    local custom = customNameSet(settings)
    if custom[cleanName] or custom[rawName] then return true end

    if settings.NamedDetectionUseSpawnMaster ~= false then
        local ok, loaded = pluginLoaded('MQ2SpawnMaster')
        if ok and loaded and spawnMasterHas(spawn) then return true end
    end

    if settings.NamedDetectionUseAlertMaster ~= false and alertMasterHas(spawn) then
        return true
    end

    return false
end

return M
