---
id: FEAT-BROKEN-018
type: feature
status: in-progress
jira: none
created: 2026-07-27
complexity: S
linked_specs: []
---

# Add a retry-after header to webhook responses (broken)

<!-- SEEDED: SL068 - T02's `Files` set differs from its row in the approved `## Outline`
     (`src/infrastructure/retry-after.ts` is added), the block carries no `Revised-by`, and
     `01-plan.md` has no `## Revisions`. This is the SW-105 live-coverage seed for the outline
     agreement rule. Its matched negatives are `FEAT-BROKEN-014` (no outline, so never checked) and
     `FEAT-BROKEN-017` (an outline its block agrees with). -->
<!-- 01-plan.md and 02-tasks.md are present because a feature at `in-progress` requires them
     (SL020), no author-fill tokens remain because `in-progress` is past `approved` (SL010), and
     T01 carries no `(new)` marker so SL060 stays silent. -->

## Why

This is the SW-105 outline-agreement fixture's `broken/` half.

## What

### SC-1: Retry-after header on a rate-limited webhook response

- **Given** a webhook delivery attempt that exceeded its limit
- **When** the response is sent
- **Then** it carries a `Retry-After` header

## Success criteria

- [ ] AC-1: A rate-limited webhook response carries `Retry-After`

## Out of scope

- Configurable back-off - fixed value only in this iteration

## Open questions

- None.

## Constitution check

- **Result**: compliant
