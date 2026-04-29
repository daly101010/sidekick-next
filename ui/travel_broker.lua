local mq = require('mq')
local imgui = require('ImGui')
local Core = require('sidekick-next.utils.core')
local Themes = require('sidekick-next.themes')
local TravelBroker = require('sidekick-next.automation.travel_broker')

local M = {}

local State = {
    open = false,
    selectedPorter = '',
    filter = '',
}

local function inputText(label, value, size)
    local a, b = imgui.InputText(label, value or '', size or 128)
    if type(a) == 'boolean' then return b or value or '', a end
    return a or value or '', b == true
end

local function sortedPorters(porters)
    local names = {}
    for name in pairs(porters or {}) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

local function matchesFilter(spell, filter)
    filter = tostring(filter or ''):lower()
    if filter == '' then return true end
    return tostring(spell.search or spell.name or ''):lower():find(filter, 1, true) ~= nil
end

local function groupedWith(name)
    if not name or name == '' then return false end
    if mq.TLO.Me and mq.TLO.Me.CleanName and name == mq.TLO.Me.CleanName() then return true end
    local ok, result = pcall(function()
        local member = mq.TLO.Group.Member(name)
        return member and member() ~= nil
    end)
    return ok and result == true
end

local function drawSpellButton(porterName, spell)
    local targetType = tostring(spell.type or '')
    local level = tonumber(spell.level) or 0
    local label = string.format('%s##%s_%s', tostring(spell.name or ''), porterName, tostring(spell.name or ''))
    local clicked = imgui.Button(label, 220, 0)
    if imgui.IsItemHovered() then
        imgui.BeginTooltip()
        imgui.Text(tostring(spell.name or ''))
        imgui.TextDisabled(string.format('Type: %s', targetType ~= '' and targetType or 'Unknown'))
        if level > 0 then imgui.TextDisabled(string.format('Level: %d', level)) end
        if spell.zoneText and spell.zoneText ~= '' then imgui.TextDisabled(tostring(spell.zoneText)) end
        if targetType == 'Single' then imgui.TextDisabled('Casts on your current target.') end
        imgui.EndTooltip()
    end
    if clicked then
        TravelBroker.requestCast(porterName, spell)
    end
end

function M.draw()
    if not State.open then return end

    local themeName = Core.Settings.SideKickTheme or 'Classic'
    local pushedTheme = Themes.pushWindowTheme(imgui, themeName, {
        windowAlpha = 0.94,
        childAlpha = 0.80,
        popupAlpha = 0.96,
        ImGuiCol = ImGuiCol,
    })

    local open = imgui.Begin('Travel Broker##SideKick', true)
    if not open then
        State.open = false
        imgui.End()
        if pushedTheme > 0 then imgui.PopStyleColor(pushedTheme) end
        return
    end

    if imgui.Button('Refresh') then
        TravelBroker.requestRefresh()
    end
    imgui.SameLine()
    State.filter = inputText('Filter##travel_filter', State.filter, 128)

    local porters = TravelBroker.getPorters()
    local names = sortedPorters(porters)
    if #names == 0 then
        imgui.TextDisabled('No transport casters found.')
        imgui.End()
        if pushedTheme > 0 then imgui.PopStyleColor(pushedTheme) end
        return
    end

    if State.selectedPorter == '' or not porters[State.selectedPorter] then
        State.selectedPorter = names[1]
    end

    if imgui.BeginCombo('Porter##travel_porter', State.selectedPorter) then
        for _, name in ipairs(names) do
            local selected = name == State.selectedPorter
            local label = name
            local data = porters[name] or {}
            if data.class and data.class ~= '' then label = string.format('%s (%s)', name, data.class) end
            if imgui.Selectable(label, selected) then State.selectedPorter = name end
            if selected and imgui.SetItemDefaultFocus then imgui.SetItemDefaultFocus() end
        end
        imgui.EndCombo()
    end

    local porter = porters[State.selectedPorter]
    if porter then
        imgui.TextDisabled(string.format('Grouped: %s', groupedWith(State.selectedPorter) and 'yes' or 'no'))
        if porter.zone and porter.zone ~= '' then
            imgui.SameLine()
            imgui.TextDisabled(string.format('Zone: %s', porter.zone))
        end

        if imgui.BeginTabBar('TravelTabs##SideKick') then
            for _, tabName in ipairs(porter.sortedTabNames or {}) do
                if imgui.BeginTabItem(tabName) then
                    local any = false
                    for _, spell in ipairs((porter.tabs and porter.tabs[tabName]) or {}) do
                        if matchesFilter(spell, State.filter) then
                            any = true
                            drawSpellButton(State.selectedPorter, spell)
                        end
                    end
                    if not any then imgui.TextDisabled('No matches.') end
                    imgui.EndTabItem()
                end
            end
            imgui.EndTabBar()
        end
    end

    imgui.End()
    if pushedTheme > 0 then imgui.PopStyleColor(pushedTheme) end
end

function M.toggle()
    State.open = not State.open
    if State.open then TravelBroker.requestRefresh() end
end

function M.setOpen(open)
    State.open = open == true
end

function M.isOpen()
    return State.open
end

return M
