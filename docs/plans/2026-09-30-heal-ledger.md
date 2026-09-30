# Raid heal gap ledger (`ma_healagent` + `ma_healbrain`)

Phase 1 of the heal coordinator design
(`F:\macros\muleassist\docs\superpowers\specs\2026-09-30-heal-coordinator-design.md`). Passive: it
reports where the raid's healing logic failed to heal, cure or AE-heal, and changes nothing.

## Files

| File | Role |
|---|---|
| `utils/heal_ledger.lua` | Pure Lua world model and gap detectors. No `mq`. Replayable. |
| `utils/heal_ledger_store.lua` | JSON-lines writer and the text report. |
| `ma_healagent.lua` | Runs on every box beside muleassist. Ships a snapshot every 250 ms to the brain. |
| `ma_healbrain.lua` | Runs on the MA's box. Ingests, ticks the detectors, writes the file, draws the window. |
| `tests/heal_ledger_test.lua` | One scenario per gap kind plus the no-false-positive cases. |

## Running it

`[Heals] HealBrainOn=1` in the character INI makes muleassist launch the agent on every box and the brain
on the box whose MainAssist is itself. At runtime `/changevarint Heals HealBrainOn 1|0` does the same.
By hand: `/lua run sidekick-next/ma_healagent` everywhere, `/lua run sidekick-next/ma_healbrain` on the MA.

`/healbrain show|hide|report|reset|echo on|off|pause on|off|set <threshold> <ms>|stop`
`/healagent [show|hide]` prints the agent's send count and whether it hears a brain, or shows/hides its window.

## Windows

- **Raid Heal Ledger** (brain, MA's box). Live gaps: every row, filter by kind or text, click one for who
  could have acted. Healers: one line per healing or curing box with its `/healreport` counters (heals by
  bucket, group heals and the ones withheld for range, cures with holds and not-ready, interrupts, nukes
  cut, failed casts, lowest HP seen), the ledger rows it caused and the rows where it could have acted,
  its casting and idle-with-a-ready-heal share of the last fight, a totals line, each box's one-line
  HealStats, and buttons that reset or broadcast every box's counters. Fights and boxes: per-fight gap
  counts and healer utilisation, which boxes report and which are stale.
- **Heal Stats - <name>** (agent, every healing or curing box). That box's live `/healreport` counters,
  whether it hears the brain, and reset/print buttons. `/healagent hide` closes it.

Rows go to `config/HealingLogs/heal-ledger-YYYY-MM-DD.jsonl` (one JSON object per line: gap rows,
fight_start, fight_end with the fight summary) and to the "Raid Heal Ledger" window (Live gaps tab:
filter by kind or text, click a row for the candidates; Fights and boxes tab: per-fight gap counts,
healer casting and idle-with-a-ready-heal percentages, which boxes are reporting and which are stale).

## Gap kinds and default thresholds

| Kind | Opens when | Threshold |
|---|---|---|
| unhealed | a member is under a healer's line with an idle healer in range holding a ready, affordable heal that fits, and no heal in flight on it | 1.5 s |
| late | a heal starts on a member this long after it crossed the line | 2 s |
| duplicate | a second direct heal is in flight on a target while the first lands within this window | 1.5 s |
| uncured | a box has counters with an idle curer in range holding a matching ready cure | 4 s |
| missed_group | 3+ of a healer's group under a ready group line inside its AE range, no group heal cast by that group's healers | 3 s |
| interrupted_nothing | the macro interrupted a heal as "past the line" and the target was still under it this much later | 1 s |
| death | a member dies while a healer in range held a ready heal and was not casting on it | at once |
| withheld | the macro recorded a `/whynot` skip, a group heal withheld for range, or a cure not ready, for a member under the line | at once |

Thresholds are `Ledger.DEFAULTS`; `/healbrain set unhealedMs 2000` changes one for the session.

## What it cannot know

A raid member not running muleassist has HP and position but no counters and no cast in flight: it
appears as a heal target only and never as an uncured row. A box whose snapshot is older than 1 s is
stale and ignored by the detectors until it reports again.

## Verify in game

1. `/healbrain` on the MA prints the status line; `/healagent` on a healer says "brain <MA> seen 0.xs ago".
2. Fights and boxes tab lists every box as fresh.
3. Let a groupmate sit at 60% with the healer parked: an unhealed row opens after 1.5 s naming the
   healer, its ready spell and distance, and closes when the heal lands.
4. `/healbrain report` after a fight prints the fight summary and the file path.
