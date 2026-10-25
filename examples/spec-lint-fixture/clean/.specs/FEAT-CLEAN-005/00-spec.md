---
id: FEAT-CLEAN-005
type: feature
status: in-progress
jira: none
created: 2026-07-25
complexity: S
linked_specs: []
---

# Add a rate-limit header to webhook responses

## Why

This is the SW-93 lean-task-format fixture's `clean/` half: a feature spec planned and expanded
entirely in the lean 5-core-field format (ADR 0023), so `/sd:spec validate` must return
`_No findings._` for `SL060` and `SL068`. `FEAT-BROKEN-017` is its matched pair in `broken/`.

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
