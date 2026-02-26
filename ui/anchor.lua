local imgui = require('ImGui')
local Helpers = require('sidekick-next.lib.helpers')

local M = {}

-- Use shared vec2xy from Helpers
local vec2xy = Helpers.vec2xy

local function normalizeTargetKey(target)
    target = tostring(target or 'grouptarget'):lower()
    target = target:gsub('%s+', '')
    target = target:gsub('[^%w_]', '')
    if target == '' then target = 'grouptarget' end
    if target == 'gt' or target == 'group' or target == 'groupwindow' then target = 'grouptarget' end
    if target == 'commandbar' or target == 'command_bar' or target == 'gtcommandbar' or target == 'gt_commandbar' or target == 'grouptargetcommandbar' or target == 'grouptarget_commandbar' then
        target = 'gt_commandbar'
    end
    if target == 'targetwindow' then target = 'target' end
    if target == 'xtargetwindow' then target = 'xtarget' end
    if target == 'sidekickmain' then target = 'sidekick_main' end
    if target == 'sidekickbar' then target = 'sidekick_bar' end
    if target == 'sidekickspecial' then target = 'sidekick_special' end
    if target == 'sidekickdisc' or target == 'sidekickdiscbar' then target = 'sidekick_disc' end
    if target == 'sidekickitem' or target == 'sidekickitembar' then target = 'sidekick_items' end
    return target
end

local function getStableBounds(globalName)
    local b = _G[globalName]
    if not b then return nil end
    -- Accept bounds even if 'loaded' is missing/false as long as required fields exist.
    local hasCore = (b.x ~= nil and b.y ~= nil and b.width ~= nil and b.height ~= nil)
    if not b.loaded and not hasCore then return nil end
    -- Avoid hard-expiring bounds; windows may only broadcast on changes.
    -- If stale, keep last known bounds rather than breaking docking entirely.
    return b
end

local function getStableGroupTargetBounds()
    return getStableBounds('GroupTargetBounds')
end

local function getStableTargetWindowBounds()
    return getStableBounds('TargetWindowBounds')
end

local function getStableXTargetWindowBounds()
    return getStableBounds('XTargetWindowBounds')
end

local function getStableSideKickBounds(key)
    local sk = _G.SideKickBounds
    if not sk or not sk.loaded then return nil end
    key = normalizeTargetKey(key)
    local b = sk[key]
    if not b then return nil end
    -- Avoid hard-expiring bounds; windows may not update while hidden.
    return b
end

function M.getTargetBounds(targetKey)
    targetKey = normalizeTargetKey(targetKey)
    if targetKey == 'grouptarget' then
        return getStableGroupTargetBounds()
    end
    if targetKey == 'gt_commandbar' then
        local b = getStableGroupTargetBounds()
        if not b then return nil end
        local x = b.commandBarX or b.x
        local y = b.commandBarY
        local w = b.commandBarWidth or b.width
        local h = b.commandBarHeight
        if not (x and y and w and h) then return nil end
        return {
            x = x,
            y = y,
            width = w,
            height = h,
            right = (b.commandBarRight or (x + w)),
            bottom = (b.commandBarBottom or (y + h)),
            loaded = true,
            timestamp = b.timestamp or os.clock(),
        }
    end
    if targetKey == 'target' then
        return getStableTargetWindowBounds()
    end
    if targetKey == 'xtarget' then
        return getStableXTargetWindowBounds()
    end
    if targetKey == 'none' then
        return nil
    end
    return getStableSideKickBounds(targetKey)
end

function M.updateWindowBounds(key, imguiApi)
    imguiApi = imguiApi or imgui
    if not imguiApi or not imguiApi.GetWindowPos or not imguiApi.GetWindowSize then return end

    key = normalizeTargetKey(key)
    if key == 'none' or key == 'grouptarget' then return end

    local px, py = vec2xy(imguiApi.GetWindowPos())
    local pw, ph = vec2xy(imguiApi.GetWindowSize())

    _G.SideKickBounds = _G.SideKickBounds or { loaded = true }
    local sk = _G.SideKickBounds
    sk.loaded = true
    sk.timestamp = os.clock()
    sk[key] = {
        x = px,
        y = py,
        width = pw,
        height = ph,
        right = px + pw,
        bottom = py + ph,
        timestamp = os.clock(),
    }
end

function M.getAnchorPos(anchorTargetKey, anchorMode, winW, winH, gap)
    gap = tonumber(gap) or 2
    anchorMode = tostring(anchorMode or 'none'):lower()
    if anchorMode == 'none' then return nil end

    local b = M.getTargetBounds(anchorTargetKey)
    if not b then return nil end

    local x, y = nil, nil
    -- Always anchor relative to actual window top to avoid overlapping expanded settings
    local anchorY = b.y or 0

    if anchorMode == 'left' then
        x = (b.x or 0) - winW - gap
        y = anchorY
    elseif anchorMode == 'right' then
        x = (b.right or ((b.x or 0) + (b.width or 0))) + gap
        y = anchorY
    elseif anchorMode == 'above' then
        x = (b.x or 0)
        y = anchorY - winH - gap
    elseif anchorMode == 'below' then
        x = (b.x or 0)
        y = (b.bottom or ((b.y or 0) + (b.height or 0))) + gap
    elseif anchorMode == 'left_bottom' then
        x = (b.x or 0) - winW - gap
        y = (b.bottom or ((b.y or 0) + (b.height or 0))) - winH
    elseif anchorMode == 'right_bottom' then
        x = (b.right or ((b.x or 0) + (b.width or 0))) + gap
        y = (b.bottom or ((b.y or 0) + (b.height or 0))) - winH
    end
    return x, y
end

function M.normalizeTargetKey(key)
    return normalizeTargetKey(key)
end

return M
