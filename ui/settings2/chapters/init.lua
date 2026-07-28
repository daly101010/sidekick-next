-- ============================================================
-- SideKick Settings Redesign - Chapter Registry
-- ============================================================
-- Each chapter is a table of { title, sections = { {label, mount} ... } }
-- where `mount` is a callable `function(settings, themeNames, onChange)`
-- OR a table with { module = 'require.path', drawFn = 'draw', isAvailable? }.
--
-- Existing tab modules stay read-only - we call their draw() from here.

local imgui = require('ImGui')
local mq = require('mq')

local M = {}

-- Lazy-require cache.
local _mods = {}
local function loadMod(path)
    if _mods[path] ~= nil then return _mods[path] or nil end
    local ok, mod = pcall(require, path)
    _mods[path] = (ok and mod) or false
    return _mods[path] or nil
end

local function myClass()
    local ok, cls = pcall(function() return mq.TLO.Me.Class.ShortName() end)
    return ok and tostring(cls or '') or ''
end

-- Build a mount function that lazy-loads a tab module and calls a chosen fn.
local function mountTab(modPath, drawFn, opts)
    opts = opts or {}
    drawFn = drawFn or 'draw'
    return function(settings, themeNames, onChange)
        -- Class restriction
        if opts.classes and next(opts.classes) then
            local mc = myClass()
            if not opts.classes[mc] then
                imgui.TextDisabled('Not available for ' .. (mc ~= '' and mc or 'this class') .. '.')
                return
            end
        end
        local mod = loadMod(modPath)
        if not mod then
            imgui.TextColored(1, 0.4, 0.4, 1, 'Failed to load ' .. modPath)
            return
        end
        -- Honor tab-provided isAvailable
        if mod.isAvailable then
            local ok, avail = pcall(mod.isAvailable)
            if ok and avail == false then
                imgui.TextDisabled('This section is not available for your current setup.')
                return
            end
        end
        local fn = mod[drawFn]
        if not fn then
            imgui.TextColored(1, 0.4, 0.4, 1, 'Missing ' .. drawFn .. '() on ' .. modPath)
            return
        end
        local ok, err = pcall(fn, settings, themeNames, onChange)
        if not ok then
            imgui.TextColored(1, 0.3, 0.3, 1, 'Error: ' .. tostring(err))
        end
    end
end

-- ------------------------------------------------------------
-- Chapter definitions
-- ------------------------------------------------------------

M.CHAPTERS = {
    combat = {
        title = 'Combat',
        subtitle = 'How your character picks fights, holds aggro, and finishes them.',
        sections = {
            { label = 'Combat & Chase',   mount = mountTab('sidekick-next.ui.settings.tab_automation') },
        },
    },

    support = {
        title = 'Support',
        subtitle = 'Heals, buffs, cures, and resurrection.',
        sections = {
            { label = 'Healing',       mount = mountTab('sidekick-next.ui.settings.tab_healing') },
            { label = 'Buffs',         mount = mountTab('sidekick-next.ui.settings.tab_buffs') },
            { label = 'Resurrection',  mount = mountTab('sidekick-next.ui.settings.tab_resurrection') },
        },
    },

    presence = {
        title = 'Presence',
        subtitle = 'The humanization layer - how much your character behaves like a person, not a bot.',
        sections = {
            { label = 'Humanize', mount = mountTab('sidekick-next.ui.settings.tab_humanize') },
        },
    },

    interface = {
        title = 'Interface',
        subtitle = 'Themes, bars, docking, and animation.',
        sections = {
            { label = 'Theme & Docking',   mount = mountTab('sidekick-next.ui.settings.tab_ui') },
            { label = 'Ability Bar',       mount = mountTab('sidekick-next.ui.settings.tab_bar') },
            { label = 'Special Bar',       mount = mountTab('sidekick-next.ui.settings.tab_special') },
            { label = 'Disciplines Bar',   mount = mountTab('sidekick-next.ui.settings.tab_disciplines'),
              classGate = 'BER' },
            { label = 'Item Bar',          mount = mountTab('sidekick-next.ui.settings.tab_items') },
            { label = 'Animations',        mount = mountTab('sidekick-next.ui.settings.tab_animations') },
        },
    },

    extras = {
        title = 'Extras',
        subtitle = 'Pulling, remote abilities, integrations, and logging.',
        sections = {
            { label = 'Pull',        mount = mountTab('sidekick-next.ui.settings.tab_pull') },
            { label = 'Remote',      mount = mountTab('sidekick-next.ui.settings.tab_remote') },
            { label = 'Integration', mount = mountTab('sidekick-next.ui.settings.tab_integration') },
            { label = 'Logging',     mount = mountTab('sidekick-next.ui.settings.tab_logging') },
        },
    },

    diagnostics = {
        title = 'Diagnostics',
        subtitle = 'Live counters and internal state. Not saved.',
        sections = {
            { label = 'Performance', mount = mountTab('sidekick-next.ui.perf_monitor',       'drawContent') },
            { label = 'Coordinator', mount = mountTab('sidekick-next.ui.coordinator_debug',  'drawContent') },
            { label = 'Activity',    mount = mountTab('sidekick-next.ui.activity_debug',     'drawContent') },
        },
    },
}

--- Return the chapter table, or nil.
function M.get(id)
    return M.CHAPTERS[id]
end

--- Return a class check for a section entry, applying the classGate if any.
function M.sectionAvailable(section)
    if section.classGate then
        return myClass() == section.classGate
    end
    return true
end

return M
