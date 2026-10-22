---
description: Second demo workflow used by the contract-lint fixtures.
argument-hint: <slug>
---

# /sd:beta

Runs after `/sd:alpha`. Invokes `sd-keeper` for the write step. It shows no gate brief; only
`/sd:alpha` follows **sd-gate-brief**.

## Gate - confirm before writing

STOP for explicit approval:

> Reply to accept as-is, or send corrections. (go / <corrections>)
