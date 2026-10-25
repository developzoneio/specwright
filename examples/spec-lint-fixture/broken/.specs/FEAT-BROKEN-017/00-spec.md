---
id: FEAT-BROKEN-017
type: feature
status: in-progress
jira: none
created: 2026-07-26
complexity: S
linked_specs: []
---

# Add a rate-limit header to webhook responses (broken)

<!-- SEEDED: SL060 - T01's `Files` entry is marked `(new)` and the block carries no
     `Pattern refs` field. This is the SW-93 lean-task-format fixture's `broken/` half; its
     matched pair is `clean/FEAT-CLEAN-005`, the same spec with `Pattern refs` present. -->
<!-- 01-plan.md and 02-tasks.md are present because a feature at `in-progress` requires them
     (SL020), and no author-fill tokens remain because `in-progress` is past `approved` (SL010). -->

## Why

This is the SW-93 lean-task-format fixture's `broken/` half.

## What

### SC-1: Rate-limit header on every webhook response

- **Given** a webhook delivery attempt
- **When** the response is sent
- **Then** it carries an `X-RateLimit-Remaining` header

## Success criteria

- [ ] AC-1: Every webhook response carries `X-RateLimit-Remaining`

## Out of scope

- Configurable limits - fixed window only in this iteration

## Open questions

- None.

## Constitution check

- **Result**: compliant
