---
description: Second demo workflow used by the contract-lint fixtures.
argument-hint: <slug>
---

# /sd:beta

<!-- contract-lint: allow CL601 - the write step is a single short call with no spec field to read a trigger from -->
Runs after `/sd:alpha`. Invokes `sd-keeper` for the write step.

## Gate - confirm before writing

STOP for explicit approval:

> Reply to accept as-is, or send corrections. (go / <corrections>)
