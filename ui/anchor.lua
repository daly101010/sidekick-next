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
    if target == 'gt' then target = 'grouptarget' end
    if target == 'sidekickmain' then target = 'sidekick_main' end
    if target == 'sidekickbar' then target = 'sidekick_bar' end
    if target == 'sidekickspecial' then target = 'sidekick_special' end
    if target == 'sidekickdisc' or target == 'sidekickdiscbar' then target = 'sidekick_disc' end
    if target == 'sidekickitem' or target == 'sidekickitembar' then target = 'sidekick_items' end
    return target
end

local function getStableGroupTargetBounds()
    local gt = _G.GroupTargetBounds
    if not gt or not gt.loaded then return nil end
    if gt.timestamp and (os.clock() - gt.timestamp) > 5.0 then return nil end
    return gt
end

local function getStableSideKickBounds(key)
    local sk = _G.SideKickBounds
    if not sk or not sk.loaded then return nil end
    key = normalizeTargetKey(key)
    local b = sk[key]
    if not b then return nil end
    if b.timestamp and (os.clock() - b.timestamp) > 5.0 then return nil end
    return b
end

function M.getTargetBounds(targetKey)
    targetKey = normalizeTargetKey(targetKey)
    if targetKey == 'grouptarget' then
        return getStableGroupTargetBounds()
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

