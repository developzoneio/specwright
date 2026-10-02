---
description: Second demo workflow used by the contract-lint fixtures.
argument-hint: <slug>
---

# /sd:beta

<!-- SEEDED: invoke-without-escalation - invokes an agent, has no escalation row and no allow comment -->
Runs after `/sd:alpha`. Invokes `sd-keeper` for the write step.

## Gate - confirm before writing

STOP for explicit approval:

> Reply to accept as-is, or send corrections. (go / <corrections>)
