-- =========================================================================
-- abilities/cooldowns.lua - Cooldown probing for abilities, AAs, discs, items
-- =========================================================================

local mq = require('mq')
local Helpers = require('sidekick-next.lib.helpers')
local Core = require('sidekick-next.utils.core')

local M = {}

M._smooth = M._smooth or {}
M._observedTotal = M._observedTotal or {}
M._debug = false  -- Set to true via /lua run sidekick-next to enable CD debug logging
M._debugFilter = nil  -- Set to ability name to filter, e.g. "Fists of Wu"

local function dbg(...)
  if not M._debug then return end
  local msg = string.format(...)
  if mq and mq.cmd then
    mq.cmd('/echo \ag[CD DBG]\ax ' .. msg)
  end
end

local function nowMs()
  if mq and mq.gettime then return mq.gettime() end
  return os.clock() * 1000
end

-- Use centralized game state check from Core
local function can_query_items()
  return Core.CanQueryItems()
end

local function smooth(name, rem, total)
  name = tostring(name or '')
  rem = tonumber(rem) or 0
  total = tonumber(total) or 0

  if name == '' then
    return rem, total
  end

  -- Remember initial total for the duration of a cooldown.
  -- Needed when RecastTime=0 (shared timer) and total = rem each frame,
  -- which would otherwise make pct = rem/rem = 1.0 (stuck).
  if rem > 0 then
    local prev = M._observedTotal[name]
    if not prev then
      M._observedTotal[name] = total  -- Lock in total from first frame
    end
    local origTotal = total
    -- Use whichever is larger: current total or remembered total
    total = math.max(total, M._observedTotal[name])
    if M._debug and (not M._debugFilter or name == M._debugFilter) then
      dbg('[smooth] %s: rem=%.3f inTotal=%.3f observedTotal=%s outTotal=%.3f',
        name, rem, origTotal, tostring(prev), total)
    end
  else
    M._observedTotal[name] = nil
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
  local shouldLog = M._debug and (not M._debugFilter or name == M._debugFilter)

  -- Try AA first
  local aa = mq.TLO.Me.AltAbility(name)
  if aa and aa() then
    local myReuse = (aa.MyReuseTime and aa.MyReuseTime()) or 0
    local reuse = (aa.ReuseTime and aa.ReuseTime()) or 0
    local total = tonumber(myReuse) or 0
    if total <= 0 then total = tonumber(reuse) or 0 end

    local ready = mq.TLO.Me.AltAbilityReady(name)()
    local remRaw = (mq.TLO.Me.AltAbilityTimer and mq.TLO.Me.AltAbilityTimer(name)()) or 0
    local rem = (tonumber(remRaw) or 0) / 1000

    if shouldLog and (rem > 0 or not ready) then
      dbg('[AA] %s: MyReuse=%s Reuse=%s total=%.2f ready=%s remRaw=%s rem=%.3f',
        name, tostring(myReuse), tostring(reuse), total, tostring(ready), tostring(remRaw), rem)
    end

    if ready and total > 0 then
      return smooth(name, 0, total)
    end

    if rem > 0 and total > 0 then
      return smooth(name, rem, total)
    end
    -- NOTE: If total=0 here, DON'T use rem as fallback.
    -- AltAbilityTimer can report global AA lockout, not this ability's recast.
    -- Let disc/spell/item sections try instead.
    if total > 0 then
      return smooth(name, 0, total)
    end
  end

  -- Try Combat Ability / Disc
  if mq.TLO.Me.CombatAbilityTimer then
    for _, candidate in ipairs(Helpers.discNameCandidates(name)) do
      local discTimer = mq.TLO.Me.CombatAbilityTimer(candidate)
      if discTimer and discTimer() then
        local tickRem = discTimer.TotalSeconds and discTimer.TotalSeconds() or 0
        tickRem = tonumber(tickRem) or 0
        local spell = mq.TLO.Spell(candidate)
        local recastRaw = spell and spell.RecastTime and spell.RecastTime() or 0
        local total = (tonumber(recastRaw) or 0) / 1000

        -- Tick timers have 6-second granularity and may overshoot short recasts.
        -- Cap rem at total so short-CD abilities (e.g. 1.5s) don't show 6s.
        local rem = tickRem
        if total > 0 and rem > total then
          rem = total
        end

        if shouldLog and tickRem > 0 then
          dbg('[DISC] %s (candidate=%s): tickRem=%.3f recastRaw=%s total=%.3f rem=%.3f',
            name, candidate, tickRem, tostring(recastRaw), total, rem)
        end

        if rem > 0 then
          if total <= 0 then total = rem end  -- shared timer: RecastTime=0 but timer is real
          if shouldLog then
            dbg('[DISC] RETURNING: rem=%.3f total=%.3f', rem, total)
          end
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
        if shouldLog and rem > 0 then
          dbg('[GEM] %s: gem=%d rem=%.3f total=%.3f', name, gem, rem, total)
        end
        if rem > 0 and total > 0 then return smooth(name, rem, total) end
        if total > 0 then return smooth(name, 0, total) end
      end
      break
    end
  end

  -- Try Item
  if mq.TLO.FindItem and can_query_items() then
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

      if shouldLog and remain > 0 then
        dbg('[ITEM] %s: remain=%.3f total=%.3f', name, remain, total)
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

  if shouldLog then
    dbg('[MISS] %s: no section matched with active timer', name)
  end
  return 0, 0
end

-- Alias for backwards compatibility
M.abilityCooldownProbe = M.probe

return M
