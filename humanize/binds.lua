-- humanize/binds.lua
-- Registers slash commands for the humanization layer. Called once from
-- humanize/init.lua at module load.

local mq = require('mq')

local M = {}

local function bind(name, fn)
    if not mq or not mq.bind then return end
    if mq.unbind then
        pcall(mq.unbind, name)
    end
    pcall(mq.bind, name, fn)
end

local function teal(s) return string.format('\at%s\ax', s) end
local function red(s) return string.format('\ar%s\ax', s) end
local function green(s) return string.format('\ag%s\ax', s) end
local function yellow(s) return string.format('\ay%s\ax', s) end

function M.register(api)
    local function status()
        local prof = api.activeProfile() or 'off'
        local ovr = api.getOverride() or 'auto'
        printf('%s active=%s override=%s flag=%s',
            yellow('[Humanize]'),
            teal(prof),
            teal(tostring(ovr)),
            tostring(_G.SIDEKICK_NEXT_CONFIG and _G.SIDEKICK_NEXT_CONFIG.HUMANIZE_BEHAVIOR or false))
    end

    -- Master command: /sk_humanize <subcmd> [arg] [arg2]
    bind('/sk_humanize', function(sub, arg, arg2)
        sub = (sub or 'status'):lower()
        if sub == 'on' or sub == 'off' then
            local enabled = sub == 'on'
            -- Persist through Core settings so worker processes pick the
            -- master flag up via settings sync — the binds live only in the
            -- UI process, so a bare _G write would never reach them.
            local okP, Persistence = pcall(require, 'sidekick-next.humanize.persistence')
            if okP and Persistence and Persistence.persist then
                pcall(Persistence.persist, 'master', {}, enabled)
            else
                _G.SIDEKICK_NEXT_CONFIG = _G.SIDEKICK_NEXT_CONFIG or {}
                _G.SIDEKICK_NEXT_CONFIG.HUMANIZE_BEHAVIOR = enabled
            end
            printf('%s layer %s', yellow('[Humanize]'),
                enabled and green('ON') or red('OFF'))
        elseif sub == 'boss' then
            api.setOverride('boss')
            printf('%s override=%s', yellow('[Humanize]'), teal('boss'))
        elseif sub == 'fullbore' or sub == 'full' then
            api.setOverride('off')
            printf('%s override=%s', yellow('[Humanize]'), red('FULL-BORE'))
        elseif sub == 'clear' or sub == 'auto' then
            api.setOverride(nil)
            printf('%s override=%s', yellow('[Humanize]'), teal('auto'))
        elseif sub == 'debug' then
            local cur = arg
            if cur == 'on' then
                api.setDebug(true)
                printf('%s debug=%s', yellow('[Humanize]'), green('on'))
            elseif cur == 'off' then
                api.setDebug(false)
                printf('%s debug=%s', yellow('[Humanize]'), red('off'))
            elseif cur == 'dump' then
                local entries = api.dumpRecent() or {}
                printf('%s last %d decisions:', yellow('[Humanize]'), #entries)
                for _, e in ipairs(entries) do
                    printf('  t=%d kind=%s prof=%s delay=%s urg=%s action=%s',
                        e.at or 0, tostring(e.kind), tostring(e.profile),
                        tostring(e.delay), tostring(e.urgency), tostring(e.action))
                end
            else
                printf('%s usage: /sk_humanize debug on|off|dump', yellow('[Humanize]'))
            end
        elseif sub == 'subsystem' then
            -- Accept either: /sk_humanize subsystem combat off
            --             or: /sk_humanize subsystem "combat off"
            local key, val = arg, arg2
            if (not val) and type(arg) == 'string' then
                local k, v = arg:match('^(%S+)%s+(%S+)$')
                if k then key, val = k, v end
            end
            if not key or not val then
                printf('%s usage: /sk_humanize subsystem <combat|targeting|buffs|heals|fidget|engagement> on|off',
                    yellow('[Humanize]'))
                return
            end
            local enabled = val == 'on' or val == 'true'
            -- Persist through Core so worker processes pick the change up via
            -- settings sync (same reason as the master flag above).
            local okP, Persistence = pcall(require, 'sidekick-next.humanize.persistence')
            if okP and Persistence and Persistence.persist then
                pcall(Persistence.persist, 'subsystem', { name = key }, enabled)
            else
                api.setSubsystem(key, enabled)
            end
            printf('%s subsystem %s=%s', yellow('[Humanize]'), key, val)
        elseif sub == 'status' or sub == '' then
            status()
        else
            printf('%s usage: /sk_humanize on|off|boss|fullbore|clear|status|debug|subsystem',
                yellow('[Humanize]'))
        end
    end)

    -- Hotkey shortcuts. User binds an EQ key to these via /bind or hotbutton.
    bind('/skboss', function()
        if api.getOverride() == 'boss' then
            api.setOverride(nil)
            printf('%s %s', yellow('[Humanize]'), 'BOSS mode \aroff\ax')
        else
            api.setOverride('boss')
            printf('%s %s', yellow('[Humanize]'), teal('BOSS mode on'))
        end
    end)

    bind('/skfullbore', function()
        if api.getOverride() == 'off' then
            api.setOverride(nil)
            printf('%s %s', yellow('[Humanize]'), 'FULL-BORE \aroff\ax')
        else
            api.setOverride('off')
            printf('%s %s', yellow('[Humanize]'), red('FULL-BORE'))
        end
    end)
end

return M
