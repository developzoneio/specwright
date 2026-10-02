---
id: PERF-TEST-200
type: perf
target_metric: latency-p95
status: approved
created: 2026-09-27
linked_specs: []
---

# Search latency

## Target

| Field | Value |
|---|---|
| **Metric** | p95 latency on GET /api/search |
| **Current observed** | <<PHASE-2: measured baseline - do NOT pre-fill from memory>> |
| **Goal (SLA)** | p95 < 200ms |

## Hypothesis tree

<!-- TBD - filled by Phase 3. -->

H1: N+1 query in SearchHandler - high impact.

## Results log

| # | Date | Change | p50 | p95 | p99 | req/s | CPU | Memory | Decision |
|---|---|---|---|---|---|---|---|---|---|
| - | - | - | - | - | - | - | - | - | - |
