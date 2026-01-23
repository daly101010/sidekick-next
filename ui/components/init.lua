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
M.StatusBadge = lazyLoad('status_badge')
M.LoadingSpinner = lazyLoad('loading_spinner')
M.KeybindBadge = lazyLoad('keybind_badge')
M.Toast = lazyLoad('toast')
M.IconButton = lazyLoad('icon_button')
M.DataTable = lazyLoad('data_table')
M.SearchInput = lazyLoad('search_input')
M.Demo = lazyLoad('demo')

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

function M.badge(...)
    return M.StatusBadge.draw(...)
end

function M.badgeReady(...)
    return M.StatusBadge.ready(...)
end

function M.badgeDebuff(...)
    return M.StatusBadge.debuff(...)
end

function M.statusDot(...)
    return M.StatusBadge.statusDot(...)
end

function M.spinner(...)
    return M.LoadingSpinner.circular(...)
end

function M.spinnerDots(...)
    return M.LoadingSpinner.dots(...)
end

function M.progressBar(...)
    return M.LoadingSpinner.bar(...)
end

function M.keybind(...)
    return M.KeybindBadge.draw(...)
end

function M.keybindCombo(...)
    return M.KeybindBadge.combo(...)
end

function M.actionHint(...)
    return M.KeybindBadge.actionHint(...)
end

function M.toast(...)
    return M.Toast.show(...)
end

function M.toastInfo(...)
    return M.Toast.info(...)
end

function M.toastSuccess(...)
    return M.Toast.success(...)
end

function M.toastWarning(...)
    return M.Toast.warning(...)
end

function M.toastError(...)
    return M.Toast.error(...)
end

function M.renderToasts(...)
    return M.Toast.render(...)
end

function M.iconButton(...)
    return M.IconButton.draw(...)
end

function M.iconButtonToggle(...)
    return M.IconButton.toggle(...)
end

function M.iconButtonGroup(...)
    return M.IconButton.group(...)
end

function M.dataTable(...)
    return M.DataTable.draw(...)
end

function M.simpleTable(...)
    return M.DataTable.simple(...)
end

function M.search(...)
    return M.SearchInput.draw(...)
end

function M.searchFilter(...)
    return M.SearchInput.filter(...)
end

function M.showDemo()
    return M.Demo.show()
end

function M.toggleDemo()
    return M.Demo.toggle()
end

return M
