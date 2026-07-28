# Consolidated Worker Implementation

Status: implemented; live MacroQuest validation pending.

## Contract

- Keep one action-blind coordinator and exactly one local action lease.
- Make the default supervised fleet ten workers.
- Preserve mature component logic, settings, commands, and specialized
  telemetry.
- Do not redesign Pull.
- Retain an 18-worker legacy A/B profile.
- Retain Fidget source but do not supervise or execute it.

## Default fleet

1. Emergency
2. Support: Healing, Cures, Resurrection
3. Tank
4. Combat: CC, Feign, Debuff, Assist, Disciplines, DPS
5. Pull
6. Chase
7. Maintenance: Resources, Buffs
8. Items
9. Meditation
10. Scribing

## Internal ordering

- Support: Healing, Cures, Resurrection. A new heal or cure may finalize an
  active resurrection workflow.
- Combat: managed Feign is exclusive; otherwise CC, Debuff, Assist,
  Disciplines, DPS. Only managed Feign or CC may interrupt another Combat
  component.
- Maintenance: Resources, Buffs. Resources do not interrupt an active buff
  workflow.

Every interruption completes the same executor drain, finalization, lease
release, and later reacquisition path. Components never hold independent
coordinator leases.

## Foundation work

- Shared process-local configuration selects consolidated or legacy profile.
- Domain hosts tick one process-local runtime cache before components.
- Cache readiness differentiates uninitialized data from an empty scan.
- Generic action transitions go directly from worker to local UI and remain
  outside scheduler policy.
- Coordinator, workers, supervisor, and peer Actor gateway count drops by
  reason.
- Throttled logging emits through the unified logger.
- Executor lifecycle, worker profile, Lua parse, scheduler, and architecture
  invariant tests cover the implementation.

## Deferred

- Pull selection, election, pathing, and strategy redesign.
- Resource-dimension or concurrent lease scheduling.
- Moving Actor routing into another Lua process.
- Re-enabling Fidget.
