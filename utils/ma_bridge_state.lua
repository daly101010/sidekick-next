-- Pure publish/ack bookkeeping for the muleassist heal bridge (ma_healbridge.lua).
-- No mq dependency so it stays testable under plain luajit.
local M = {}

function M.newState()
    return { seq = 0, beat = 0, lastKey = nil }
end

function M.actionKey(action)
    if not action then return nil end
    return string.format('%s|%d|%s',
        tostring(action.spellName or ''),
        tonumber(action.targetId) or 0,
        tostring(action.tier or 'single'))
end

--- Advance one bridge loop. Increments the heartbeat, and decides whether the
--- action needs (re-)publishing: publish when the action changed, or when the
--- macro has consumed the outstanding seq and the action is still wanted.
--- Returns an ordered varset batch ({name, value} pairs) or nil.
--- SmartHealSeq is always last so the macro never pairs a new seq with stale fields.
function M.next(state, action, ackSeq)
    state.beat = state.beat + 1
    if not action then
        state.lastKey = nil
        return nil
    end
    local key = M.actionKey(action)
    local consumed = (tonumber(ackSeq) or 0) >= state.seq
    if key == state.lastKey and not consumed then
        return nil
    end
    state.seq = state.seq + 1
    state.lastKey = key
    return {
        { 'SmartHealSpell', tostring(action.spellName or '') },
        { 'SmartHealTargetID', tostring(tonumber(action.targetId) or 0) },
        { 'SmartHealTier', tostring(action.tier or 'single') },
        { 'SmartHealSeq', tostring(state.seq) },
    }
end

--- Call each loop with the macro's live SmartHealSeq. A macro restart resets
--- its outer variables to 0; when the macro's seq falls behind ours, clear
--- lastKey so the next action republishes at a fresh seq.
function M.noteMacroSeq(state, macroSeq)
    if (tonumber(macroSeq) or 0) < state.seq then
        state.lastKey = nil
    end
end

return M
