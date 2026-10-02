---
id: RCA-TEST-300
type: rca
severity: P1
status: draft
created: 2026-09-27
linked_specs: []
---

# Payment outage

## Hypothesis tree

<!-- 4-8 hypotheses ranked. -->

**Status**: TBD - filled by Phase 2 enumeration.

<<PHASE-2: hypothesis tree with rankings and verification plans>>

### Verification results (Phase 3)

- <<PHASE-3: H1>>: <<PHASE-3: status>> - <<PHASE-3: evidence>>

## Root cause

The connection pool was capped at 15 while the new handler holds two connections.
