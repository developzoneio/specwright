---
id: RCA-e2e-capped-20260926
type: rca
status: draft
severity: P0
incident_started: 2026-09-26 10:02 UTC
incident_resolved: 2026-09-26 10:20 UTC
created: 2026-09-26
linked_specs: []
---

# RCA: Restored todos overwritten after demo host restart

> **Synthetic fixture.** This spec was authored for `tests/e2e/scenarios/11-escalation-rca-capped`
> only. The incident, timeline and artifacts are fictional; the code it points at is the real
> fixture project. `severity: P0` is set on purpose.

> **This spec IS the deliverable.** No code is changed in `/sd:rca`. Fixes spawn separate BUG-* / REF-* / PERF-* specs (see "Spawned specs" below).

## Timeline (UTC)

| Time (UTC) | Event | Source |
|---|---|---|
| 09:58 | Demo host restarts and restores 3 todos (ids 1-3) from a snapshot via `InMemoryStore.save` | `04-artifacts/demo-host-restart.log` |
| 10:02 | First new todo after restart is assigned id 1; list still shows 3 items | `04-artifacts/demo-host-restart.log` |
| 10:05 | Second new todo is assigned id 2; list still shows 3 items | `04-artifacts/demo-host-restart.log` |
| 10:07 | Pager fires on the todo count regression | `04-artifacts/demo-host-restart.log` |
| 10:20 | Mitigation: demo host restarted with an empty store | on-call note |

**Detection latency**: 5 minutes
**Mitigation latency**: 13 minutes
**Total impact window**: 00:18

## Symptoms observed

- After a restore, every `addTodo` returns an id that already belongs to a restored todo.
- `listTodos()` stays at 3 items while todos are being added; restored todos silently disappear.
- No error is raised anywhere.

Artifacts: see `04-artifacts/` for logs, screenshots, query results.

## Affected scope

- **Services / endpoints**: demo host (`TodoService`, `InMemoryStore`)
- **User-facing impact**: restored todos lost on the demo deployment
- **Internal impact**: one pager alert
- **Data integrity impact**: restored todos overwritten in memory; the snapshot file is intact

## Recent changes

| When | What | By | Notes |
|---|---|---|---|
| 2026-09-25 17:00 | Demo host gained snapshot restore on startup | demo maintainer | restore calls `InMemoryStore.save` per todo |

## Hypothesis tree

<!-- TBD - filled by Phase 2 (sd-debugger enumerate mode). -->
<!-- 4-8 hypotheses ranked by (Likelihood × Impact) ÷ Cost-to-verify. -->

**Status**: TBD - filled by Phase 2 enumeration.

<<PHASE-2: hypothesis tree with rankings and verification plans>>

### Verification results (Phase 3)

<!-- Each hypothesis gets: CONFIRMED / REJECTED / INCONCLUSIVE with evidence pointers. -->
<!-- Document REJECTED with FULL reasoning - this is knowledge preservation. -->

- <<PHASE-3: H1>>: <<PHASE-3: CONFIRMED|REJECTED|INCONCLUSIVE>> - <<PHASE-3: evidence>>
- <<PHASE-3: H2>>: <<PHASE-3: status>> - <<PHASE-3: evidence>>

## Root cause

<!-- TBD - filled by Phase 3 once a hypothesis is CONFIRMED. -->

**Status**: TBD - filled when Gate 3 (Root cause confirmed) passes.

<<PHASE-3: root cause statement>>

## Affected components

- <<component 1>>

## Why this is root cause (not symptom)

<<reasoning>>

## Mitigation applied

- **Action**: demo host restarted with an empty store
- **Effective at**: 2026-09-26 10:20 UTC
- **Confidence**: high - no further overwrites reported
- **Reversibility**: restore can be re-enabled once the root cause is fixed

## Follow-up actions

### Immediate (P0 hotfix)

- [ ] <<action 1>>

## Spawned specs

| Reserved ID | Type | Title | Owner |
|---|---|---|---|
| <<BUG-XXX>> | bug | <<title>> | <<owner>> |

## Lessons learned

1. <<lesson 1>>
