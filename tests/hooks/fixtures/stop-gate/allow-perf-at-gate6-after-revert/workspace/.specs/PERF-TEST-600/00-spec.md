---
id: PERF-TEST-600
type: perf
target_metric: latency-p95
status: in-progress
created: 2026-11-01
---

# Search latency

## Target

| Field | Value |
|---|---|
| **Metric** | p95 latency on GET /api/search |
| **Current observed** | p95 340ms (baseline-20261101-0900.json) |
| **Goal (SLA)** | p95 < 200ms |

## Hypothesis tree

H1: N+1 query in SearchHandler - high impact.

## Results log

| # | Date | Change | p50 | p95 | p99 | req/s | CPU | Memory | Decision |
|---|---|---|---|---|---|---|---|---|---|
| 0 | 2026-11-01 | baseline | 120 | 340 | 410 | 50 | 40% | 200MB | baseline |
| 1 | 2026-11-01 | H1a batch query | 118 | 335 | 400 | 51 | 40% | 200MB | reverted |
| 2 | 2026-11-01 | H1b index | 60 | 150 | 190 | 90 | 30% | 210MB | pending |

## Trade-offs accepted

- <<PHASE-6: trade-off 1>>
