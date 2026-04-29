local mq = require('mq')
local Actors = require('sidekick-next.utils.actors_coordinator')
local lazy = require('sidekick-next.utils.lazy_require')

local M = {}

local getActionExecutor = lazy('sidekick-next.utils.action_executor')

local SPELLBOOK_SLOTS = 1120
local RESCAN_SECONDS = 30
local PEER_TTL = 120

local State = {
    initialized = false,
    lastScanAt = 0,
    lastBroadcastAt = 0,
    selfInfo = nil,
    porters = {},
    pendingCast = nil,
}

local function selfName()
    return mq.TLO.Me and mq.TLO.Me.CleanName and mq.TLO.Me.CleanName() or ''
end

local function selfZone()
    return mq.TLO.Zone and mq.TLO.Zone.ShortName and mq.TLO.Zone.ShortName() or ''
end

local function selfClass()
    return mq.TLO.Me and mq.TLO.Me.Class and mq.TLO.Me.Class.ShortName and mq.TLO.Me.Class.ShortName() or ''
end

local function safeSpellField(spell, field)
    local ok, value = pcall(function()
        local member = spell[field]
        return member and member() or nil
    end)
    return ok and value or nil
end

local function scanTransportSpells()
    local me = mq.TLO.Me
    if not me or not me() then return nil end

    local info = {
        name = selfName(),
        class = selfClass(),
        zone = selfZone(),
        updatedAt = os.time(),
        tabs = {},
        sortedTabNames = {},
    }

    for slot = 1, SPELLBOOK_SLOTS do
        local spell = me.Book(slot)
        if spell and spell() and safeSpellField(spell, 'Category') == 'Transport' then
            local subcategory = tostring(safeSpellField(spell, 'Subcategory') or 'Transport')
            local name = tostring(safeSpellField(spell, 'RankName') or safeSpellField(spell, 'Name') or '')
            if name ~= '' then
                local targetType = tostring(safeSpellField(spell, 'TargetType') or '')
                local zoneText = tostring(safeSpellField(spell, 'Extra') or '')
                local level = tonumber(safeSpellField(spell, 'Level')) or 0
                info.tabs[subcategory] = info.tabs[subcategory] or {}
                table.insert(info.tabs[subcategory], {
                    name = name,
                    type = targetType,
                    level = level,
                    zoneText = zoneText,
                    search = string.format('%s %s %s %s', name, targetType, subcategory, zoneText):lower(),
                })
            end
        end
    end

    for tabName, spells in pairs(info.tabs) do
        table.sort(spells, function(a, b) return tostring(a.name) < tostring(b.name) end)
        table.insert(info.sortedTabNames, tabName)
    end
    table.sort(info.sortedTabNames)

    if #info.sortedTabNames == 0 then return nil end
    return info
end

local function broadcastSelfInfo(force)
    if not State.selfInfo then return end
    local now = os.clock()
    if not force and (now - (State.lastBroadcastAt or 0)) < 10 then return end
    State.lastBroadcastAt = now
    Actors.broadcast('travel:info', { porter = State.selfInfo, zone = State.selfInfo.zone })
end

local function receiveInfo(content, sender, fromMe)
    if fromMe then return false end
    local porter = content and content.porter
    if type(porter) ~= 'table' then return false end
    local name = tostring(porter.name or content.from or sender.character or '')
    if name == '' then return false end
    porter.name = name
    porter.lastSeen = os.clock()
    State.porters[name] = porter
    return true
end

local function receiveRequest(content, sender, fromMe)
    if fromMe then return false end
    broadcastSelfInfo(true)
    return true
end

local function receiveCast(content, sender, fromMe)
    if fromMe then return false end
    local targetPorter = tostring(content and content.to or ''):lower()
    if targetPorter == '' or targetPorter ~= selfName():lower() then return false end
    State.pendingCast = {
        spellName = tostring(content.spellName or ''),
        targetId = tonumber(content.targetId) or 0,
        requestedBy = tostring(content.from or sender.character or ''),
        requestedAt = os.clock(),
    }
    return true
end

local function registerCallbacks()
    if State.initialized then return end
    State.initialized = true
    Actors.registerMessageCallback('travel:info', receiveInfo)
    Actors.registerMessageCallback('travel:req', receiveRequest)
    Actors.registerMessageCallback('travel:cast', receiveCast)
end

local function prunePorters()
    local now = os.clock()
    for name, data in pairs(State.porters) do
        if (now - (data.lastSeen or 0)) > PEER_TTL then
            State.porters[name] = nil
        end
    end
end

local function processPendingCast()
    local pending = State.pendingCast
    if not pending then return end
    State.pendingCast = nil
    if pending.spellName == '' then return end

    local ActionExecutor = getActionExecutor()
    if not ActionExecutor or not ActionExecutor.executeSpell then return end
    ActionExecutor.executeSpell(pending.spellName, pending.targetId, {
        sourceLayer = 'travel',
        spellCategory = 'travel',
        maxRetries = 1,
    })
end

function M.init()
    registerCallbacks()
end

function M.tick(settings)
    settings = settings or {}
    if settings.TravelBrokerEnabled == false then return end
    registerCallbacks()

    local now = os.clock()
    if (now - (State.lastScanAt or 0)) >= RESCAN_SECONDS then
        State.lastScanAt = now
        State.selfInfo = scanTransportSpells()
        broadcastSelfInfo(true)
    end

    prunePorters()
    processPendingCast()
end

function M.requestRefresh()
    Actors.broadcast('travel:req', { zone = selfZone() })
    broadcastSelfInfo(true)
end

function M.requestCast(porterName, spellData, opts)
    opts = opts or {}
    porterName = tostring(porterName or '')
    if porterName == '' or type(spellData) ~= 'table' then return false end
    local spellName = tostring(spellData.name or spellData.Name or '')
    if spellName == '' then return false end

    local targetId = tonumber(opts.targetId) or 0
    if targetId <= 0 and tostring(spellData.type or '') == 'Single' then
        local target = mq.TLO.Target
        targetId = target and target() and target.ID and tonumber(target.ID()) or 0
    end

    if porterName:lower() == selfName():lower() then
        State.pendingCast = { spellName = spellName, targetId = targetId, requestedBy = selfName(), requestedAt = os.clock() }
        return true
    end

    Actors.broadcast('travel:cast', {
        to = porterName,
        spellName = spellName,
        targetId = targetId,
        zone = selfZone(),
    })
    return true
end

function M.getPorters()
    local result = {}
    if State.selfInfo then
        result[State.selfInfo.name] = State.selfInfo
    end
    for name, data in pairs(State.porters) do
        result[name] = data
    end
    return result
end

function M.getState()
    return State
end

return M
