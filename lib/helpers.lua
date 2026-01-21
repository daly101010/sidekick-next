-- =========================================================================
-- lib/helpers.lua - Pure utility functions for Medley
-- =========================================================================

local imgui = require('ImGui')

local M = {}

--- Sanitize a string for use as an ImGui ID
---@param s string|nil The string to sanitize
---@return string The sanitized string with non-word characters replaced by underscores
function M.sanitizeId(s)
  return tostring(s or ''):gsub('%W', '_')
end

--- Normalize a spell name by removing rank suffixes
---@param s string|nil The spell name to normalize
---@return string The normalized spell name in lowercase
function M.normSpellName(s)
  if type(s) ~= 'string' then s = tostring(s or '') end
  s = s:gsub('%s+[Rr][Kk]%.[^%s]+', '')      -- " Rk. II"
  s = s:gsub('%s+%([Rr]ank%s*%u+%s*%)', '')  -- " (Rank II)"
  s = s:lower()
  return s
end

--- Generate discipline name candidates (handles Rk. II/III variants).
---@param s string|nil Base discipline name (may or may not include rank suffix)
---@return table candidates Array of candidate names (best-effort)
function M.discNameCandidates(s)
  if type(s) ~= 'string' then s = tostring(s or '') end
  s = s:gsub('%s+$', '')
  if s == '' then return {} end

  local out, seen = {}, {}
  local function add(v)
    v = tostring(v or ''):gsub('%s+$', '')
    if v == '' or seen[v] then return end
    seen[v] = true
    table.insert(out, v)
  end

  add(s)

  local base = s
  base = base:gsub('%s+[Rr][Kk]%.[^%s]+', '')
  base = base:gsub('%s+%([Rr]ank%s*%u+%s*%)', '')
  base = base:gsub('%s+$', '')
  add(base)

  -- If the incoming string already includes a rank suffix, don't spam variants.
  local hasRank = s:match('%s+[Rr][Kk]%.%s*%u+') or s:match('%(%s*[Rr]ank%s*%u+%s*%)')
  if hasRank then return out end

  -- Prefer higher ranks first.
  add(base .. ' Rk. III')
  add(base .. ' Rk. II')
  add(base .. ' Rk. I')
  add(base .. ' (Rank III)')
  add(base .. ' (Rank II)')
  add(base .. ' (Rank I)')

  return out
end

--- Convert a value to boolean
---@param v any The value to convert
---@return boolean The boolean representation
function M.to_bool(v)
  local t = type(v)
  if t == "boolean" then return v
  elseif t == "number" then return v ~= 0
  elseif t == "string" then
    v = v:lower()
    return (v == "1" or v == "true" or v == "yes" or v == "on")
  end
  return false
end

--- Convert HSV color to RGB (pure Lua implementation)
---@param h number Hue (0-1)
---@param s number Saturation (0-1)
---@param v number Value (0-1)
---@return number r Red (0-1)
---@return number g Green (0-1)
---@return number b Blue (0-1)
function M.hsv_to_rgb(h, s, v)
  local r, g, b
  local i = math.floor(h * 6)
  local f = h * 6 - i
  local p = v * (1 - s)
  local q = v * (1 - f * s)
  local t = v * (1 - (1 - f) * s)
  i = i % 6
  if i == 0 then r, g, b = v, t, p
  elseif i == 1 then r, g, b = q, v, p
  elseif i == 2 then r, g, b = p, v, t
  elseif i == 3 then r, g, b = p, q, v
  elseif i == 4 then r, g, b = t, p, v
  elseif i == 5 then r, g, b = v, p, q
  end
  return r, g, b
end

--- Format a cooldown time as a human-readable string
--- >= 1h: H:MM:SS, >= 60s: M:SS, else: Xs
---@param rem number The remaining time in seconds
---@return string The formatted time string
function M.fmtCooldown(rem)
  rem = tonumber(rem) or 0
  rem = math.max(0, math.floor(rem + 0.5))
  if rem >= 3600 then
    local h = math.floor(rem / 3600)
    local m = math.floor(math.fmod(rem, 3600) / 60)
    local s = math.floor(math.fmod(rem, 60))
    return string.format("%d:%02d:%02d", h, m, s)
  elseif rem >= 60 then
    local m = math.floor(rem / 60)
    local s = math.floor(math.fmod(rem, 60))
    return string.format("%d:%02d", m, s)
  else
    return string.format("%ds", rem)
  end
end

--- Calculate the width of text in pixels (handles different ImGui return shapes)
---@param s string|nil The text to measure
---@return number The width in pixels
function M.textWidth(s)
  local a, b = imgui.CalcTextSize(s or "")
  if b ~= nil then return a or 0 end
  if type(a) == "table" and a.x then return a.x end
  return a or 0
end

--- Extract x coordinate from various vec2 representations
---@param v any ImVec2, table {x,y}, table {[1],[2]}, or number
---@return number The x coordinate
function M.vecX(v)
  if type(v) == 'number' then return tonumber(v) or 0 end
  if type(v) == 'table' then return tonumber(v.x or v[1]) or 0 end
  local ok, x = pcall(function() return v.x end)
  if ok and x ~= nil then return tonumber(x) or 0 end
  return 0
end

--- Extract x,y coordinates from various vec2 representations
---@param a any First argument (ImVec2, table, or x number)
---@param b number|nil Second argument (y number if a is x)
---@return number x The x coordinate
---@return number y The y coordinate
function M.vec2xy(a, b)
  if b ~= nil then
    return tonumber(a) or 0, tonumber(b) or 0
  end
  if type(a) == 'table' then
    return tonumber(a.x or a[1]) or 0, tonumber(a.y or a[2]) or 0
  end
  return tonumber(a) or 0, 0
end

--- Get cooldown total for an ability definition
---@param def table Ability definition with altName or discName
---@param cooldownProbe function Cooldown probe function
---@return number|nil The total cooldown time, or nil if unavailable
function M.cooldownTotalFor(def, cooldownProbe)
  if not cooldownProbe then return nil end
  local name = def and (def.discName or def.altName)
  if type(name) ~= 'string' or name == '' then return nil end
  local ok, _, total = pcall(function() return cooldownProbe({ label = name, key = name }) end)
  if not ok then return nil end
  total = tonumber(total) or 0
  if total <= 0 then return nil end
  return total
end

--- Wrap text to fit within a maximum width
---@param text string|nil The text to wrap
---@param maxWidth number The maximum width in pixels
---@return table An array of wrapped lines
function M.wrapToWidth(text, maxWidth)
  local out, line = {}, ""
  text = tostring(text or "")
  for word in text:gmatch("%S+") do
    local test = (line == "" and word) or (line .. " " .. word)
    if M.textWidth(test) > maxWidth and line ~= "" then
      table.insert(out, line); line = word
    else
      line = test
    end
  end
  if line ~= "" then table.insert(out, line) end
  return out
end

return M
