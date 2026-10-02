---
id: PERF-TEST-200
type: perf
target_metric: latency-p95
status: in-progress
created: 2026-09-27
linked_specs: []
---

# Search latency

## Target

| Field | Value |
|---|---|
| **Metric** | p95 latency on GET /api/search |
| **Current observed** | p95 1400ms at 50 RPS |
| **Goal (SLA)** | p95 < 200ms |

## Hypothesis tree

H1: N+1 query in SearchHandler - high impact.

## Results log

| # | Date | Change | p50 | p95 | p99 | req/s | CPU | Memory | Decision |
|---|---|---|---|---|---|---|---|---|---|
| 0 | 2026-09-27 | baseline (no change) | 600 | 1400 | 2100 | 50 | 70% | 900MB | baseline |
| 1 | 2026-09-27 | batch the lookup | 90 | 180 | 260 | 50 | 40% | 900MB | kept |
