# Centralized Vitals Hub (`vitals:group` v1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The tank's sidekick-next publishes one consolidated `vitals:group` actors message (~5Hz, change-driven); the GroupTarget HUD (`F:\lua\group`) and the classic UI rebuild (`F:\lua\eq_ui_rebuild_classic`) consume it instead of polling `Group.Member(i)` TLOs per frame, with a TLO poll fallback whenever the feed is stale (>2s).

**Architecture:** A new `utils/vitals_hub.lua` in sidekick-next builds the payload from the tank's own `Group.Member` TLOs (covers non-sidekick members like a Medley bard), deduplicates changes, and hands it to `ActorsCoordinator.sendVitalsGroup`, which fans out to the two consumer scripts by script-addressed actors send. Each consumer stores the latest feed with a receive timestamp and reads member vitals from it when fresh; geometry-local values (Distance, Present, LineOfSight) always stay TLO-polled because they are relative to the viewer, not the tank. Healers are deliberately untouched — heal decisions keep direct polling (actor latency too high for emergencies).

**Tech Stack:** MacroQuest Lua (LuaJIT), MQ actors (post office), ImGui. No test framework exists and no Lua runtime is available on this machine — every code step is verified with a `luaparser` (Python) parse check plus an in-game checklist at the end (Task 8).

## Global Constraints

- Message contract: id `vitals:group`, version field `v = 1`. The contract is the interface — the publisher may later move to a standalone hub script without touching consumers.
- Publisher cadence: max 5Hz (0.2s min interval), change-driven, forced heartbeat resend every 2.0s.
- Consumer freshness window: a feed older than **2.0s** is stale → fall back to TLO polling.
- Healers keep direct `target_monitor` polling. Do not route any healing decision through this feed.
- sidekick-next actors addressing invariant: plain `{ mailbox = 'sidekick' }` never crosses script names. Consumer sends MUST be script-addressed (`{ mailbox = 'grouptarget', script = 'group' }`, `{ mailbox = 'medley_remote', script = 'eq_ui_rebuild_classic' }`).
- Actor handlers run with yielding disabled — no `mq.delay`, no `require` of not-yet-loaded modules inside message callbacks. Consumers only write plain tables in the handler.
- Do not register/service actors inside ImGui draw callbacks (eq_ui's `UpdateGaugeValues` runs in the draw context — it may only *read* the cache).
- Setting `VitalsHubEnabled` (bool, default `true`), registry-backed so `/skset VitalsHubEnabled` works with zero extra code.
- Never touch `F:\lua\sidekick` (production tree).
- Parse check command (run from `F:\lua\sidekick-next`, works for any absolute path):
  `python -c "from luaparser import ast; ast.parse(open(r'<FILE>',encoding='utf-8',errors='replace').read()); print('parse OK')"`
- Git: each repo gets its own commits. sidekick-next work goes on the current session branch `wip/feb-apr-development`. `F:\lua\group` and `F:\lua\eq_ui_rebuild_classic` are separate repos — see Tasks 4 and 6 for their branch handling. Never commit to `master`/`main`.

## `vitals:group` v1 contract (reference for all tasks)

```lua
{
    id = 'vitals:group',
    v = 1,
    seq = 42,                 -- monotonic per publisher process
    from = 'Tankchar',        -- publisher character name
    server = 'ezserver',
    zone = 'gukbottom',       -- publisher's short zone name
    members = {
        -- keyed by character CleanName/Name; INCLUDES the publisher itself
        ['Tankchar'] = {
            id = 12345,       -- spawn ID (0 if unknown)
            level = 60,
            class = 'WAR',    -- uppercase ShortName ('' if unknown)
            hp = 87,          -- PctHPs
            mana = 0,         -- PctMana
            endur = 55,       -- PctEndurance
            petHp = 0,        -- pet PctHPs, 0 = no pet
            dead = false,
            sitting = false,
            casting = '',     -- spell name; only ever populated for the publisher
                              -- (Spawn.Casting is only accurate on yourself). Reserved
                              -- for enrichment in a later version; consumers must
                              -- tolerate '' / nil.
            present = true,   -- Present() from the TANK's perspective. When false,
                              -- hp/mana/endur/petHp/dead/sitting are ABSENT (nil) —
                              -- consumers must fall back to their own polling.
        },
    },
}
```

Consumers key by member name and must treat every field as optional.

---

### Task 1: Publisher module `utils/vitals_hub.lua` (sidekick-next)

**Files:**
- Create: `F:\lua\sidekick-next\utils\vitals_hub.lua`

**Interfaces:**
- Consumes: `sidekick-next.utils.core` (`Core.Settings.VitalsHubEnabled`, `Core.Settings.CombatMode`), `sidekick-next.utils.actors_coordinator` (`Actors.sendVitalsGroup(payload)` — created in Task 2; the require is pcall-guarded so Task 1 parses/commits independently).
- Produces: `M.tick()` — call from the main loop; internally rate-limits, no-ops unless this character is the tank. `M.buildMembers()` and `M.membersChanged(a, b)` exposed for future smoke harnesses.

- [ ] **Step 1: Write the module**

```lua
--- Vitals hub publisher (tank-side).
--- One character (the tank) aggregates the whole group's vitals from its own
--- Group.Member TLOs — this covers members NOT running sidekick (Medley bard)
--- — and publishes a single consolidated `vitals:group` message for UI
--- consumers (GroupTarget HUD, eq_ui_rebuild_classic). Healers deliberately
--- do NOT consume this feed: actor relay latency is too high for emergency
--- heal decisions.
---
--- Contract v1: see docs/plans/2026-07-23-vitals-hub.md. The message is the
--- interface — this publisher can later move to a standalone hub script
--- without touching consumers.
local mq = require('mq')

local M = {}

local SEND_MIN_INTERVAL = 0.2   -- 5Hz cap
local HEARTBEAT_SEC = 2.0       -- force a resend even when nothing changed

local _lastSendAt = 0
local _lastMembers = nil
local _seq = 0

local function safeNum(fn, default)
    local ok, v = pcall(fn)
    if ok then v = tonumber(v) else v = nil end
    return v or default
end

local function safeBool(fn)
    local ok, v = pcall(fn)
    return ok and v == true
end

local function safeStr(fn)
    local ok, v = pcall(fn)
    if ok and v ~= nil then return tostring(v) end
    return ''
end

--- Build the members table (publisher included). Returns nil when not
--- meaningfully grouped (0 other members) — solo publishing is pure noise.
function M.buildMembers()
    local me = mq.TLO.Me
    if not me or not me() then return nil end
    local myName = safeStr(function() return me.CleanName() end)
    if myName == '' then return nil end

    local count = safeNum(function() return mq.TLO.Group.Members() end, 0)
    if count <= 0 then return nil end

    local members = {}
    members[myName] = {
        id = safeNum(function() return me.ID() end, 0),
        level = safeNum(function() return me.Level() end, 0),
        class = safeStr(function() return me.Class.ShortName() end):upper(),
        hp = safeNum(function() return me.PctHPs() end, 0),
        mana = safeNum(function() return me.PctMana() end, 0),
        endur = safeNum(function() return me.PctEndurance() end, 0),
        petHp = safeNum(function() return mq.TLO.Pet.PctHPs() end, 0),
        dead = safeBool(function() return me.Dead() end),
        sitting = safeBool(function() return me.Sitting() end),
        casting = safeStr(function() return me.Casting() end),
        present = true,
    }

    for i = 1, count do
        local mem = mq.TLO.Group.Member(i)
        if mem and mem() then
            local name = safeStr(function() return mem.Name() end)
            if name ~= '' then
                local present = safeBool(function() return mem.Present() end)
                local m = {
                    id = safeNum(function() return mem.ID() end, 0),
                    level = safeNum(function() return mem.Level() end, 0),
                    class = safeStr(function() return mem.Class.ShortName() end):upper(),
                    present = present,
                }
                if present then
                    m.hp = safeNum(function() return mem.PctHPs() end, 0)
                    m.mana = safeNum(function() return mem.PctMana() end, 0)
                    m.endur = safeNum(function() return mem.PctEndurance() end, 0)
                    m.petHp = safeNum(function() return mem.Pet.PctHPs() end, 0)
                    m.dead = safeBool(function() return mem.Dead() end)
                    m.sitting = safeBool(function() return mem.Sitting() end)
                end
                members[name] = m
            end
        end
    end
    return members
end

-- Fields that trigger a resend when they change. `casting` is deliberately
-- excluded: self-cast churn would defeat the change-dedup.
local WATCH = { 'hp', 'mana', 'endur', 'petHp', 'dead', 'sitting', 'level', 'id', 'present' }

function M.membersChanged(a, b)
    if not b then return true end
    for name, m in pairs(a) do
        local o = b[name]
        if not o then return true end
        for _, k in ipairs(WATCH) do
            if m[k] ~= o[k] then return true end
        end
    end
    for name in pairs(b) do
        if not a[name] then return true end
    end
    return false
end

--- Main-loop tick. Publishes only when this character is the designated
--- tank (CombatMode == 'tank') and VitalsHubEnabled is on.
function M.tick()
    local okCore, Core = pcall(require, 'sidekick-next.utils.core')
    if not okCore or not Core then return end
    local S = Core.Settings or {}
    if S.VitalsHubEnabled == false then return end
    if tostring(S.CombatMode or 'off'):lower() ~= 'tank' then return end

    local now = os.clock()
    if (now - _lastSendAt) < SEND_MIN_INTERVAL then return end

    local members = M.buildMembers()
    if not members then return end

    local heartbeatDue = (now - _lastSendAt) >= HEARTBEAT_SEC
    if not heartbeatDue and not M.membersChanged(members, _lastMembers) then
        return
    end

    local okAct, Actors = pcall(require, 'sidekick-next.utils.actors_coordinator')
    if not okAct or not Actors or not Actors.sendVitalsGroup then return end

    _lastSendAt = now
    _lastMembers = members
    _seq = _seq + 1

    Actors.sendVitalsGroup({
        id = 'vitals:group',
        v = 1,
        seq = _seq,
        zone = safeStr(function() return mq.TLO.Zone.ShortName() end),
        members = members,
    })
end

return M
```

- [ ] **Step 2: Parse check**

Run from `F:\lua\sidekick-next`:
```bash
python -c "from luaparser import ast; ast.parse(open(r'utils/vitals_hub.lua',encoding='utf-8',errors='replace').read()); print('parse OK')"
```
Expected: `parse OK`

- [ ] **Step 3: Commit**

```bash
git add utils/vitals_hub.lua
git commit -m "feat(vitals): tank-side vitals:group v1 publisher module"
```

---

### Task 2: Wire publisher — coordinator send, registry setting, main-loop tick (sidekick-next)

**Files:**
- Modify: `F:\lua\sidekick-next\utils\actors_coordinator.lua` (near `sendToGroupTarget`, ~line 204)
- Modify: `F:\lua\sidekick-next\registry.lua` (Combat category, near `ReadinessEnabled` ~line 278)
- Modify: `F:\lua\sidekick-next\SideKick.lua` (lazy requires ~line 152; main loop ActorsEnabled block ~line 2915)

**Interfaces:**
- Consumes: `sendToGroupTarget(payload)` local fn (actors_coordinator.lua:168), `_dropbox`, `_selfName`, `_selfServer` locals.
- Produces: `M.sendVitalsGroup(payload)` on ActorsCoordinator (used by Task 1's `M.tick`); registry key `VitalsHubEnabled`.

- [ ] **Step 1: Add `sendVitalsGroup` to actors_coordinator.lua**

Insert directly after the `function M.sendToGroupTarget(payload)` wrapper (line ~204-206):

```lua
-- eq_ui_rebuild_classic services its 'medley_remote' mailbox from its main
-- coroutine; script-addressed with no character = broadcast to that script
-- on every connected peer.
local _ADDR_EQUI = { mailbox = 'medley_remote', script = 'eq_ui_rebuild_classic' }

--- Publish consolidated group vitals (tank-side, see utils/vitals_hub.lua).
--- Fan-out is script-addressed because plain { mailbox = 'sidekick' } never
--- crosses script names: GroupTarget HUD + classic UI rebuild.
function M.sendVitalsGroup(payload)
    if not _dropbox or type(payload) ~= 'table' then return end
    payload.from = payload.from or _selfName
    payload.server = payload.server or _selfServer
    sendToGroupTarget(payload)
    pcall(function() _dropbox:send(_ADDR_EQUI, payload) end)
end
```

- [ ] **Step 2: Add the registry setting**

In `registry.lua`, after the `ReadyEndPct` line (~282), add:

```lua
    -- Vitals hub (tank publishes consolidated group vitals for UI scripts)
    VitalsHubEnabled = { type = 'bool', Default = true, Category = 'Combat', DisplayName = 'Publish Group Vitals (Tank Hub)' },
```

- [ ] **Step 3: Wire the tick in SideKick.lua**

Add the lazy require next to the other `lazy(...)` lines (after `local getReadiness = lazy('sidekick-next.utils.readiness')`, ~line 152):

```lua
local getVitalsHub = lazy('sidekick-next.utils.vitals_hub')
```

Inside the main loop's `if Core.Settings.ActorsEnabled ~= false then` block, immediately after `ActorsCoordinator.tick({ status = status })` (~line 2915):

```lua
            -- Tank-side consolidated group vitals for UI consumers (no-op
            -- unless CombatMode == 'tank'; rate-limited internally).
            do local VH = getVitalsHub() if VH then VH.tick() end end
```

- [ ] **Step 4: Parse check all three files**

```bash
python -c "
from luaparser import ast
for f in ['utils/actors_coordinator.lua','registry.lua','SideKick.lua']:
    ast.parse(open(f,encoding='utf-8',errors='replace').read()); print('parse OK', f)
"
```
Expected: three `parse OK` lines.

- [ ] **Step 5: Commit**

```bash
git add utils/actors_coordinator.lua registry.lua SideKick.lua
git commit -m "feat(vitals): publish vitals:group to GroupTarget + eq_ui consumers, /skset VitalsHubEnabled"
```

---

### Task 3: Document the contract (sidekick-next)

**Files:**
- Modify: `F:\lua\sidekick-next\docs\INTEGRATION_GUIDE.md`

**Interfaces:**
- Produces: contract documentation only.

- [ ] **Step 1: Add a `vitals:group` section**

Find the section of `docs/INTEGRATION_GUIDE.md` that documents actors messages (search for `pull:incoming` or `status:update`; if no message-contract section exists, add one titled `## Actors message contracts` at the end). Append:

```markdown
### `vitals:group` (v1) — tank → UI scripts

The designated tank (`CombatMode == 'tank'`, gate `VitalsHubEnabled`) publishes
one consolidated group-vitals message at ≤5Hz (change-driven, 2s heartbeat)
from `utils/vitals_hub.lua` via `ActorsCoordinator.sendVitalsGroup`. Fan-out is
script-addressed: `{ mailbox = 'grouptarget', script = 'group' }` and
`{ mailbox = 'medley_remote', script = 'eq_ui_rebuild_classic' }`.

Payload: `{ id='vitals:group', v=1, seq, from, server, zone, members }` where
`members[name] = { id, level, class, hp, mana, endur, petHp, dead, sitting,
casting, present }`. `present` is from the TANK's perspective; when false the
volatile fields are absent. `casting` is only populated for the publisher.
Consumers treat every field as optional, use the feed only while fresh (<2s),
and keep their own TLO polling as fallback. Distance / LineOfSight / viewer
zone logic must stay locally polled (relative to the viewer, not the tank).
Healing decisions never consume this feed (latency).
```

- [ ] **Step 2: Commit**

```bash
git add docs/INTEGRATION_GUIDE.md
git commit -m "docs(vitals): vitals:group v1 contract"
```

---

### Task 4: GroupTarget consumer — receive + expose feed (`F:\lua\group`)

**Files:**
- Modify: `F:\lua\group\gt_actors.lua` (message handler ~line 970; api accessors near `api:getPeers()` ~line 1908)

Repo note: `F:\lua\group` is its own git repo, currently clean on branch `claude/equi-99-button`. Create the topic branch first:
```bash
cd /f/lua/group && git checkout -b feat/vitals-hub
```

**Interfaces:**
- Consumes: `state` table, `now_s()` (gt_actors.lua:151), the `actors.register(state.mailbox, ...)` handler (gt_actors.lua:914).
- Produces: `api:getVitalsFeed()` → `members` table or nil when stale (>2s) — consumed by Task 5.

- [ ] **Step 1: Handle `vitals:group` in the message handler**

In the handler in `gt_actors.lua`, after the `if id == 'window:bounds:req' then ... end` block (~line 970) and BEFORE the `state.lastRxAt = now_s()` peer-store section, insert:

```lua
            -- Consolidated group vitals from the sidekick tank hub (v1).
            -- Stored whole; freshness is checked at read time (getVitalsFeed).
            if id == 'vitals:group' then
                if type(content.members) == 'table' then
                    state.vitalsFeed = {
                        members = content.members,
                        at = now_s(),
                        from = tostring(content.from or ''),
                        seq = tonumber(content.seq) or 0,
                    }
                end
                return
            end
```

- [ ] **Step 2: Add the accessor**

Directly after the end of `function api:getPeers()` (~line 1951), add:

```lua
    --- Latest tank-hub vitals feed (vitals:group v1), or nil when no feed
    --- has arrived within 2s — callers must fall back to TLO polling.
    function api:getVitalsFeed()
        local vf = state.vitalsFeed
        if not vf or (now_s() - (vf.at or 0)) > 2.0 then return nil end
        return vf.members
    end
```

- [ ] **Step 3: Parse check**

```bash
python -c "from luaparser import ast; ast.parse(open(r'F:/lua/group/gt_actors.lua',encoding='utf-8',errors='replace').read()); print('parse OK')"
```
Expected: `parse OK`

- [ ] **Step 4: Commit**

```bash
cd /f/lua/group && git add gt_actors.lua && git commit -m "feat(vitals): receive sidekick vitals:group feed + getVitalsFeed accessor"
```

---

### Task 5: GroupTarget consumer — feed-first roster build (`F:\lua\group`)

**Files:**
- Modify: `F:\lua\group\group_core.lua` (FrameCache block ~line 9224; roster loop ~line 11472)

**Interfaces:**
- Consumes: `api:getVitalsFeed()` from Task 4 (via the `actors` upvalue used at group_core.lua:9224), `_H.safeCall`, `normName`.
- Produces: `FrameCache.vitals` (members table or nil), feed-first `mData` build.

- [ ] **Step 1: Cache the feed once per frame**

In the FrameCache block, right after the `FrameCache.peers` assignment block (~line 9224-9232), add:

```lua
    -- Tank-hub consolidated vitals (vitals:group). nil when stale (>2s) —
    -- the roster build then falls back to per-member TLO reads.
    if actors and actors.getVitalsFeed then
        FrameCache.vitals = _H.safeCall(function() return actors:getVitalsFeed() end, nil)
    else
        FrameCache.vitals = nil
    end
```

- [ ] **Step 2: Feed-first member build**

In the roster loop (~line 11485), replace the `mData = { ... }` construction. Current code:

```lua
                            local FC = AnimState.FrameCache or {}
                            local peerData = (FC.peers or {})[name] or (FC.peersByName or {})[normName(name)]

                            local mData = {
                                Name = name,
                                ID = uiID,
                                Level = member.Level() or 0,
                                Class = member.Class.ShortName() or "UNK",
                                PctHPs = _H.safeCall(function() return member.PctHPs() end, 0) or 0,
                                PctMana = _H.safeCall(function() return member.PctMana() end, 0) or 0,
                                PctEndurance = _H.safeCall(function() return member.PctEndurance() end, 0) or 0,
                                Dead = _H.safeCall(function() return member.Dead() end, false) or false,
                                PetPctHPs = _H.safeCall(function()
                                    local pid = member.Pet.ID() or 0
                                    if pid and pid > 0 then return member.Pet.PctHPs() or 0 end
                                    return 0
                                end, 0) or 0,
                                Distance = member.Distance() or 0,
                                Present = _H.safeCall(function() return member.Present() end, true),
                                Zone = AnimState.viewerZoneShort,
                                LineOfSight = _H.safeCall(function() return member.LineOfSight() end, nil),
                                _index = i,
                                _isSelf = false,
                                _isPeer = false,
                            }
```

Replace with:

```lua
                            local FC = AnimState.FrameCache or {}
                            local peerData = (FC.peers or {})[name] or (FC.peersByName or {})[normName(name)]
                            -- Tank-hub vitals feed (fresh <2s) replaces the seven
                            -- per-member vitals TLO reads. Distance / Present /
                            -- LineOfSight stay TLO — they are viewer-relative.
                            local vData = (FC.vitals or {})[name]

                            local mData
                            if vData and vData.present ~= false and vData.hp ~= nil then
                                mData = {
                                    Name = name,
                                    ID = uiID,
                                    Level = tonumber(vData.level) or 0,
                                    Class = (vData.class and vData.class ~= '' and vData.class) or "UNK",
                                    PctHPs = tonumber(vData.hp) or 0,
                                    PctMana = tonumber(vData.mana) or 0,
                                    PctEndurance = tonumber(vData.endur) or 0,
                                    Dead = vData.dead == true,
                                    PetPctHPs = tonumber(vData.petHp) or 0,
                                    Distance = member.Distance() or 0,
                                    Present = _H.safeCall(function() return member.Present() end, true),
                                    Zone = AnimState.viewerZoneShort,
                                    LineOfSight = _H.safeCall(function() return member.LineOfSight() end, nil),
                                    _index = i,
                                    _isSelf = false,
                                    _isPeer = false,
                                }
                            else
                                mData = {
                                    Name = name,
                                    ID = uiID,
                                    Level = member.Level() or 0,
                                    Class = member.Class.ShortName() or "UNK",
                                    PctHPs = _H.safeCall(function() return member.PctHPs() end, 0) or 0,
                                    PctMana = _H.safeCall(function() return member.PctMana() end, 0) or 0,
                                    PctEndurance = _H.safeCall(function() return member.PctEndurance() end, 0) or 0,
                                    Dead = _H.safeCall(function() return member.Dead() end, false) or false,
                                    PetPctHPs = _H.safeCall(function()
                                        local pid = member.Pet.ID() or 0
                                        if pid and pid > 0 then return member.Pet.PctHPs() or 0 end
                                        return 0
                                    end, 0) or 0,
                                    Distance = member.Distance() or 0,
                                    Present = _H.safeCall(function() return member.Present() end, true),
                                    Zone = AnimState.viewerZoneShort,
                                    LineOfSight = _H.safeCall(function() return member.LineOfSight() end, nil),
                                    _index = i,
                                    _isSelf = false,
                                    _isPeer = false,
                                }
                            end
```

Leave the `if peerData then ... end` overlay that follows COMPLETELY unchanged — DanNet data stays authoritative for sidekick-running peers, and the overlay's out-of-zone handling still applies.

- [ ] **Step 3: Parse check**

```bash
python -c "from luaparser import ast; ast.parse(open(r'F:/lua/group/group_core.lua',encoding='utf-8',errors='replace').read()); print('parse OK')"
```
Expected: `parse OK`

- [ ] **Step 4: Commit**

```bash
cd /f/lua/group && git add group_core.lua && git commit -m "feat(vitals): roster build prefers tank-hub vitals feed, TLO fallback"
```

---

### Task 6: eq_ui consumer — receive + expose feed (`F:\lua\eq_ui_rebuild_classic`)

**Files:**
- Modify: `F:\lua\eq_ui_rebuild_classic\commandbar\medley_remote.lua` (handler ~line 388; module state near top)

Repo notes — do these first:
- `F:\lua\eq_ui_rebuild_classic` is its own git repo, currently on `feat/book-animation` with UNCOMMITTED changes including `commandbar/medley_remote.lua`. Do NOT discard or stash them.
```bash
cd /f/lua/eq_ui_rebuild_classic && git checkout -b feat/vitals-hub
git add -A && git commit -m "wip: carry pre-existing working-tree changes (book-animation session)"
```
This preserves the user's in-flight work as its own commit so the vitals changes are reviewable separately.

**Interfaces:**
- Consumes: the `actors.register('medley_remote', ...)` handler (medley_remote.lua:372).
- Produces: `M.getVitalsFeed()` → members table or nil when stale (>2s) — consumed by Task 7 via `package.loaded['eq_ui_rebuild_classic.commandbar.medley_remote']`.

- [ ] **Step 1: Add the handler branch**

Inside the `actors.register('medley_remote', function(message) ... end)` callback, directly after the `if content.id == 'status:rep' and content.script == 'sidekick' then ... return end` block (~line 388), insert:

```lua
            -- Consolidated group vitals from the sidekick tank hub (v1).
            -- Plain table write only — actor callbacks cannot yield.
            if content.id == 'vitals:group' then
                if type(content.members) == 'table' then
                    M.vitalsFeed = {
                        members = content.members,
                        at = os.clock(),
                        from = tostring(content.from or ''),
                        seq = tonumber(content.seq) or 0,
                    }
                end
                return
            end
```

- [ ] **Step 2: Add module state + accessor**

Near the other `M.` state declarations at the top of the module (search for `M.localAutomation` or `M.runtimePeers`), add:

```lua
M.vitalsFeed = nil  -- latest vitals:group payload { members, at, from, seq }
```

Next to the other public functions (e.g. after `M.collectRuntimeInfo` or at the end before `return M`), add:

```lua
--- Latest tank-hub vitals feed (vitals:group v1), or nil when no feed has
--- arrived within 2s — callers must fall back to TLO polling.
function M.getVitalsFeed()
    local vf = M.vitalsFeed
    if not vf or (os.clock() - (vf.at or 0)) > 2.0 then return nil end
    return vf.members
end
```

- [ ] **Step 3: Parse check**

```bash
python -c "from luaparser import ast; ast.parse(open(r'F:/lua/eq_ui_rebuild_classic/commandbar/medley_remote.lua',encoding='utf-8',errors='replace').read()); print('parse OK')"
```
Expected: `parse OK`

- [ ] **Step 4: Commit**

```bash
cd /f/lua/eq_ui_rebuild_classic && git add commandbar/medley_remote.lua && git commit -m "feat(vitals): receive sidekick vitals:group feed in medley_remote"
```

---

### Task 7: eq_ui consumer — feed-first gauge update (`F:\lua\eq_ui_rebuild_classic`)

**Files:**
- Modify: `F:\lua\eq_ui_rebuild_classic\live\gamedata.lua` (`UpdateGaugeValues` group loop, lines ~848-896)

**Interfaces:**
- Consumes: `M.getVitalsFeed()` from Task 6 via `package.loaded` (gamedata must NOT `require` it — the module is loaded by init.lua's main coroutine; `package.loaded` lookup avoids any load-order/yield hazard in the draw context).
- Produces: feed-first vitals in `State.gaugeValues.group_*`; TLO fallback intact.

- [ ] **Step 1: Add a feed lookup helper**

In `live\gamedata.lua`, above `function M.UpdateGaugeValues()` (~line 754), add:

```lua
-- Tank-hub consolidated vitals (vitals:group v1) received by medley_remote.
-- package.loaded lookup only: this runs in the ImGui draw context, which must
-- never trigger a module load. nil when the feed is stale (>2s) or absent.
local function vitalsFeed()
    local mr = package.loaded['eq_ui_rebuild_classic.commandbar.medley_remote']
    if mr and mr.getVitalsFeed then
        local ok, feed = pcall(mr.getVitalsFeed)
        if ok then return feed end
    end
    return nil
end
```

- [ ] **Step 2: Use the feed in the group loop**

Inside `UpdateGaugeValues`, right before the `for i = 1, 5 do` group loop (~line 848), add:

```lua
    local groupFeed = vitalsFeed()
```

Then replace the present-gated stats block. Current code:

```lua
            if present then
                local okHp, hp = pcall(function() return mem.PctHPs() end)
                if okHp then hpPct = tonumber(hp) or 0 end
                local okMana, mp = pcall(function() return mem.PctMana() end)
                if okMana then manaPct = tonumber(mp) or 0 end
                local okEnd, ep = pcall(function() return mem.PctEndurance() end)
                if okEnd then endPct = tonumber(ep) or 0 end
                local okPet, petHp = pcall(function() return mem.Pet.PctHPs() end)
                if okPet then petPct = tonumber(petHp) or 0 end
                local okDist, d = pcall(function() return mem.Distance() end)
                if okDist and d ~= nil then dist = tonumber(d) or -1 end
            end
```

Replace with:

```lua
            if present then
                -- Prefer the tank-hub feed (fresh <2s); fall back to TLO reads.
                -- Distance always stays TLO: it is relative to THIS viewer.
                local v = groupFeed and groupFeed[name]
                if v and v.hp ~= nil then
                    hpPct = tonumber(v.hp) or 0
                    manaPct = tonumber(v.mana) or 0
                    endPct = tonumber(v.endur) or 0
                    petPct = tonumber(v.petHp) or 0
                else
                    local okHp, hp = pcall(function() return mem.PctHPs() end)
                    if okHp then hpPct = tonumber(hp) or 0 end
                    local okMana, mp = pcall(function() return mem.PctMana() end)
                    if okMana then manaPct = tonumber(mp) or 0 end
                    local okEnd, ep = pcall(function() return mem.PctEndurance() end)
                    if okEnd then endPct = tonumber(ep) or 0 end
                    local okPet, petHp = pcall(function() return mem.Pet.PctHPs() end)
                    if okPet then petPct = tonumber(petHp) or 0 end
                end
                local okDist, d = pcall(function() return mem.Distance() end)
                if okDist and d ~= nil then dist = tonumber(d) or -1 end
            end
```

- [ ] **Step 3: Parse check**

```bash
python -c "from luaparser import ast; ast.parse(open(r'F:/lua/eq_ui_rebuild_classic/live/gamedata.lua',encoding='utf-8',errors='replace').read()); print('parse OK')"
```
Expected: `parse OK`

- [ ] **Step 4: Commit**

```bash
cd /f/lua/eq_ui_rebuild_classic && git add live/gamedata.lua && git commit -m "feat(vitals): group gauges prefer tank-hub vitals feed, TLO fallback"
```

---

### Task 8: In-game verification checklist (user-run; no code)

No Lua runtime exists on this machine and there is no test suite — final verification is in-game. Run with at least: 1 tank character (`CombatMode == 'tank'`), 1 other sidekick character, GroupTarget HUD and eq_ui_rebuild_classic running on a non-tank character.

- [ ] **Publisher up:** on the tank, `/skset VitalsHubEnabled` shows `true`. No error spam in the MQ console after `/lua run sidekick-next`.
- [ ] **GroupTarget receives:** on the non-tank, group HUD member bars still track HP/mana/endurance changes (have the tank take a hit / cast). Then `/lua stop sidekick-next` on the TANK only → within ~2s the HUD keeps updating (TLO fallback engaged, no freeze/flicker).
- [ ] **eq_ui receives:** same dance with the classic UI group window gauges (`GW_HPLabel`/`%` labels).
- [ ] **Non-sidekick member covered:** a group member NOT running sidekick (e.g. Medley bard) still shows correct vitals on consumers while the tank publishes (this is data the peers store never had).
- [ ] **Toggle off:** `/skset VitalsHubEnabled false` on the tank → consumers keep working via fallback.
- [ ] **Healer unaffected:** healing behavior identical with hub on/off (spot-check heal reaction time on a damaged tank).
- [ ] **Perf sanity:** no visible frame-time regression on consumers; actors traffic reasonable (2 sends per update, ≤5Hz, only from the tank).
- [ ] If all pass: push branches per the git playbook (end-of-session backup push; PRs at user's discretion).

---

## Self-review notes

- Spec coverage: publisher (Tasks 1-2), contract doc (Task 3), group consumer (4-5), 99ui consumer (6-7), healer exception (explicitly untouched, Global Constraints), poll fallback <2s (all consumers), 5Hz change-driven (Task 1). `casting` is contract-reserved, publisher-only in v1 — `Spawn.Casting` is self-only per mq-definitions, and no enrichment source exists yet (`status:update` doesn't carry casting).
- Deliberate deviation from the handoff sketch: members are sourced from the tank's `Group.Member` TLOs rather than `_remoteCharacters`, because the whole point is covering members that don't run sidekick; sidekick peers' extra data (buffs/abilities) already flows via `status:update` and is not duplicated here.
- The GroupTarget `peerData` overlay (group_core.lua:11518-11556) intentionally still wins over the feed for sidekick-running peers — DanNet is fresher (<1s) than the hub (≤5Hz + actor latency).
