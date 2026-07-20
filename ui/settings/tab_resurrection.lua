-- Dedicated resurrection settings surface for the Options tab system.

local mq = require('mq')
local imgui = require('ImGui')
local RezData = require('sidekick-next.utils.rez_data')
local HealingTab = require('sidekick-next.ui.settings.tab_healing')

local M = {}

local function myClassShort()
    local ok, value = pcall(function() return mq.TLO.Me.Class.ShortName() end)
    if not ok then return '' end
    return tostring(value or ''):upper()
end

function M.isAvailable()
    return RezData.isRezClass(myClassShort())
end

function M.draw(settings, themeNames, onChange)
    if not M.isAvailable() then
        imgui.TextDisabled('Resurrection automation is not available for ' .. (myClassShort() ~= '' and myClassShort() or 'this class') .. '.')
        return
    end

    local themeName = settings.SideKickTheme or 'Classic'
    HealingTab.drawResurrection(settings, themeName, onChange)
end

return M
