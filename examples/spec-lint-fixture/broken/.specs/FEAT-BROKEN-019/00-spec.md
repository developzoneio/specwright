---
id: FEAT-BROKEN-019
type: feature
status: in-progress
jira: none
created: 2026-07-28
complexity: S
linked_specs: []
---

# Log a webhook delivery failure with its status code (broken)

<!-- SEEDED: SL069 - T02 covers AC-2 but its `Acceptance` names no witness test and the block has no
     legacy `Test` field. T01 covers AC-1 and names tests/webhook-log.test.ts, so it must stay
     silent: the finding is per block, not per spec. -->
<!-- Held apart: no `## Outline` in 01-plan.md (SL068 silent), no `(new)` marker in any `Files`
     (SL060 silent), `Status: open` on both blocks (SL067 silent). 01-plan.md and 02-tasks.md are
     present because a feature at `in-progress` requires them (SL020), and no author-fill tokens
     remain because `in-progress` is past `approved` (SL010). -->

## Why

This is the SW-107 witness-test fixture's `broken/` half. Its matched pair is
`FEAT-CLEAN-005`, whose one covering task names its witness test.

## What

### SC-1: A failed delivery is logged with its status code

- **Given** a webhook endpoint that answers with a non-2xx status
- **When** the delivery attempt finishes
- **Then** the log line carries that status code

## Success criteria

- [ ] AC-1: The failure log line carries the endpoint's status code
- [ ] AC-2: The log line carries no request body

## Out of scope

- Retry scheduling - owned by the delivery queue

## Open questions

- None.

## Constitution check

- **Result**: compliant
