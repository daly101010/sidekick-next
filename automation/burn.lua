local mq = require('mq')

local M = {}

M.active = false
M.startedAt = 0
M.duration = 30

local _Core = nil

function M.init(opts)
    opts = opts or {}
    _Core = opts.Core
end

function M.setActive(val, opts)
    opts = opts or {}
    local on = val and true or false
    if on and not M.active then
        M.startedAt = os.clock()
    end
    M.active = on
    if opts.duration then
        M.duration = tonumber(opts.duration) or M.duration
    elseif _Core and _Core.Settings and _Core.Settings.BurnDuration then
        M.duration = tonumber(_Core.Settings.BurnDuration) or M.duration
    end
end

function M.tick()
    if not M.active then return end
    local dur = tonumber(M.duration) or 0
    if dur > 0 and (os.clock() - (M.startedAt or 0)) > dur then
        M.active = false
        if _Core and _Core.set then
            _Core.set('BurnActive', false)
        end
    end
end

return M
