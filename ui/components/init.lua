-- ============================================================
-- SideKick UI Components
-- ============================================================
-- Centralized exports for all reusable UI components.
--
-- Usage:
--   local Components = require('sidekick-next.ui.components')
--   Components.ThemedButton.toggle(...)
--   Components.SliderRow.int(...)
--
-- Or import individual components:
--   local ThemedButton = require('sidekick-next.ui.components.themed_button')

local M = {}

-- Lazy-load components to avoid circular dependencies
local _cache = {}

local function lazyLoad(name)
    return setmetatable({}, {
        __index = function(_, key)
            if not _cache[name] then
                _cache[name] = require('sidekick-next.ui.components.' .. name)
            end
            return _cache[name][key]
        end,
        __call = function(_, ...)
            if not _cache[name] then
                _cache[name] = require('sidekick-next.ui.components.' .. name)
            end
            if type(_cache[name]) == 'function' then
                return _cache[name](...)
            end
            return _cache[name]
        end
    })
end

-- Export components
M.ThemedButton = lazyLoad('themed_button')
M.SettingGroup = lazyLoad('setting_group')
M.SliderRow = lazyLoad('slider_row')
M.ComboRow = lazyLoad('combo_row')
M.CheckboxRow = lazyLoad('checkbox_row')
M.AnchorVisualizer = lazyLoad('anchor_visualizer')
M.Tooltip = lazyLoad('tooltip')
M.SettingCard = lazyLoad('setting_card')
M.ResourceBar = lazyLoad('resource_bar')

-- Direct access for common patterns
function M.toggle(...)
    return M.ThemedButton.toggle(...)
end

function M.iconToggle(...)
    return M.ThemedButton.iconToggle(...)
end

function M.checkbox(...)
    return M.CheckboxRow.draw(...)
end

function M.slider(...)
    return M.SliderRow.int(...)
end

function M.sliderFloat(...)
    return M.SliderRow.float(...)
end

function M.combo(...)
    return M.ComboRow.draw(...)
end

function M.comboValue(...)
    return M.ComboRow.byValue(...)
end

function M.group(...)
    return M.SettingGroup.draw(...)
end

function M.section(...)
    return M.SettingGroup.section(...)
end

function M.tooltip(...)
    return M.Tooltip.simple(...)
end

function M.abilityTooltip(...)
    return M.Tooltip.ability(...)
end

function M.card(...)
    return M.SettingCard.begin(...)
end

function M.cardFinish(...)
    return M.SettingCard.finish(...)
end

function M.collapsibleCard(...)
    return M.SettingCard.collapsible(...)
end

function M.healthBar(...)
    return M.ResourceBar.health(...)
end

function M.manaBar(...)
    return M.ResourceBar.mana(...)
end

function M.resourceBar(...)
    return M.ResourceBar.draw(...)
end

return M
