-- =========================================================================
-- abilities/cooldowns.lua - Cooldown probing for abilities, AAs, discs, items
-- =========================================================================

local mq = require('mq')
local Helpers = require('lib.helpers')

local M = {}

M._smooth = M._smooth or {}

local function nowMs()
  if mq and mq.gettime then return mq.gettime() end
  return os.clock() * 1000
end

local function smooth(name, rem, total)
  name = tostring(name or '')
  rem = tonumber(rem) or 0
  total = tonumber(total) or 0

  if name == '' then
    return rem, total
  end

  if rem <= 0 then
    M._smooth[name] = nil
    return 0, total
  end

  local t = nowMs()
  local s = M._smooth[name]
  if not s or s.raw ~= rem or s.total ~= total or rem > (s.raw or 0) then
    M._smooth[name] = { raw = rem, total = total, at = t }
    return rem, total
  end

  local elapsed = (t - (s.at or t)) / 1000
  local out = (s.raw or rem) - elapsed
  if out < 0 then out = 0 end
  if out > rem then out = rem end
  return out, total
end

--- Probe an ability/AA/disc/item for its cooldown status
--- @param row table A row with `label` and/or `key` fields identifying the ability
--- @return number remainingSeconds The remaining cooldown in seconds
--- @return number totalSeconds The total cooldown duration in seconds
function M.probe(row)
  local label = row and row.label
  local key = row and row.key
  if not label and not key then return 0, 0 end
  local name = label or key

  -- Try AA first
  local aa = mq.TLO.Me.AltAbility(name)
  if aa and aa() then
    local total = (aa.MyReuseTime and aa.MyReuseTime()) or (aa.ReuseTime and aa.ReuseTime()) or 0
    total = tonumber(total) or 0

    local ready = mq.TLO.Me.AltAbilityReady(name)()
    if ready and total > 0 then
      return smooth(name, 0, total)
    end

    local remRaw = (mq.TLO.Me.AltAbilityTimer and mq.TLO.Me.AltAbilityTimer(name)()) or 0
    local rem = (tonumber(remRaw) or 0) / 1000
    if rem > 0 and total > 0 then
      return smooth(name, rem, total)
    end
    if total > 0 then
      return smooth(name, 0, total)
    end
  end

  -- Try Combat Ability / Disc
  if mq.TLO.Me.CombatAbilityTimer then
    for _, candidate in ipairs(Helpers.discNameCandidates(name)) do
      local discTimer = mq.TLO.Me.CombatAbilityTimer(candidate)
      if discTimer and discTimer() then
        local rem = discTimer.TotalSeconds and discTimer.TotalSeconds() or 0
        rem = tonumber(rem) or 0
        local spell = mq.TLO.Spell(candidate)
        local total = spell and spell.RecastTime and (spell.RecastTime() or 0) / 1000 or 0
        total = tonumber(total) or 0

        if rem > 0 and total > 0 then
          return smooth(candidate, rem, total)
        end
        if total > 0 then
          return smooth(candidate, 0, total)
        end
      end
    end
  end

  -- Try Spell Gem (if it's a spell name that's memmed)
  for gem = 1, 13 do
    local gemSpell = mq.TLO.Me.Gem(gem)
    if gemSpell and gemSpell() and gemSpell.Name() == name then
      local gemTimer = mq.TLO.Me.GemTimer(gem)
      if gemTimer and gemTimer() then
        local rem = (tonumber(gemTimer()) or 0) / 1000
        local total = gemTimer.TotalSeconds and gemTimer.TotalSeconds() or 0
        total = tonumber(total) or 0
        if rem > 0 and total > 0 then return smooth(name, rem, total) end
        if total > 0 then return smooth(name, 0, total) end
      end
      break
    end
  end

  -- Try Item
  if mq.TLO.FindItem then
    local item = mq.TLO.FindItem(name)
    if item and item() then
      local remain = 0
      local total = 0

      -- Item.Timer returns a timestamp, use .TotalSeconds to get seconds remaining
      if item.Timer and item.Timer.TotalSeconds then
        remain = tonumber(item.Timer.TotalSeconds()) or 0
      end

      -- Fallback: TimerReady returns ticks (6 seconds each) in some versions
      if remain <= 0 and item.TimerReady then
        local raw = tonumber(item.TimerReady()) or 0
        if raw > 0 then
          -- TimerReady is in ticks (6 sec each) for items
          remain = raw * 6
        end
      end

      -- Get total recast from Clicky.RecastTime (in milliseconds)
      if item.Clicky and item.Clicky.RecastTime then
        local recastMs = tonumber(item.Clicky.RecastTime()) or 0
        total = recastMs / 1000
      end

      if remain > 0 then
        if total <= 0 then total = remain end
        return smooth(name, remain, total)
      end

      if total and total > 0 then
        return smooth(name, 0, total)
      end
    end
  end

  return 0, 0
end

-- Alias for backwards compatibility
M.abilityCooldownProbe = M.probe

return M
