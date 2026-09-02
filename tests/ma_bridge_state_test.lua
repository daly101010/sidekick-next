package.path = '../?.lua;../?/init.lua;' .. package.path

local State = require('sidekick-next.utils.ma_bridge_state')

local function act(spell, targetId, tier)
    return { spellName = spell, targetId = targetId, tier = tier }
end

local s = State.newState()
assert(s.seq == 0 and s.beat == 0 and s.lastKey == nil, 'fresh state')

-- nil action: beat ticks, nothing published
assert(State.next(s, nil, 0) == nil, 'nil action publishes nothing')
assert(s.beat == 1, 'beat increments on every call')

-- first action publishes, seq becomes 1, SmartHealSeq is LAST
local pub = State.next(s, act('Complete Heal', 42, 'single'), 0)
assert(pub, 'first action must publish')
assert(s.seq == 1, 'seq bumped to 1')
assert(pub[1][1] == 'SmartHealSpell' and pub[1][2] == 'Complete Heal', 'spell first')
assert(pub[2][1] == 'SmartHealTargetID' and pub[2][2] == '42', 'target id as string')
assert(pub[3][1] == 'SmartHealTier' and pub[3][2] == 'single', 'tier')
assert(pub[#pub][1] == 'SmartHealSeq' and pub[#pub][2] == '1', 'seq must be written last')

-- same action, not yet acked: heartbeat only
assert(State.next(s, act('Complete Heal', 42, 'single'), 0) == nil, 'unchanged+unacked = no publish')
assert(s.seq == 1, 'seq unchanged')

-- changed action while unacked: overwrite with new seq
pub = State.next(s, act('Word of Health', 42, 'single'), 0)
assert(pub and s.seq == 2, 'changed action overwrites, seq=2')

-- ack catches up, same action still wanted: re-publish so the macro heals again
pub = State.next(s, act('Word of Health', 42, 'single'), 2)
assert(pub and s.seq == 3, 'acked + still-wanted = republish, seq=3')

-- nil action clears lastKey so the same action later re-publishes
State.next(s, nil, 3)
pub = State.next(s, act('Word of Health', 42, 'single'), 3)
assert(pub and s.seq == 4, 'action after a nil gap republishes')

-- missing tier defaults to "single"
s = State.newState()
pub = State.next(s, { spellName = 'Renewal', targetId = 7 }, 0)
assert(pub[3][2] == 'single', 'nil tier defaults to single')

-- actionKey exposed and distinct per field
assert(State.actionKey(act('A', 1, 't')) ~= State.actionKey(act('A', 2, 't')), 'key includes target')
assert(State.actionKey(nil) == nil, 'nil action has nil key')

-- macro restart: macro's seq falls behind ours -> clear lastKey so we republish
s = State.newState()
pub = State.next(s, act('Renewal', 7, 'single'), 0)
assert(pub and s.seq == 1, 'restart setup publish')
State.noteMacroSeq(s, 1)
assert(s.lastKey ~= nil, 'equal macro seq must not clear lastKey')
assert(State.next(s, act('Renewal', 7, 'single'), 0) == nil, 'no spurious republish')
State.noteMacroSeq(s, 0)
assert(s.lastKey == nil, 'behind macro seq clears lastKey')
pub = State.next(s, act('Renewal', 7, 'single'), 0)
assert(pub and s.seq == 2, 'republish after macro restart')

print('ma_bridge_state_test OK')
