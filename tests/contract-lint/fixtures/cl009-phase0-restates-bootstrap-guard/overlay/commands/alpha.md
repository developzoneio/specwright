---
description: Demo workflow used by the contract-lint fixtures.
argument-hint: <slug>
---

# /sd:alpha

Demo workflow. Writes `.specs/ALPHA-<slug>/00-spec.md`, then `01-plan.md`.

## Phase 0 - Bootstrap

If `templates/sd/demo.template.md` is missing, STOP and report it. If the registry
is unreadable, STOP. Neither of these sits inside a gate block, and CL300 must not
mistake them for one.

<!-- SEEDED: wrapped-restatement - a bootstrap guard message copied into Phase 0, split across a wrap -->
If the spec folder is absent, STOP: "No `.specs/`
found - ask for the setup command."

<!-- SEEDED: single-line-restatement - a bootstrap guard parse message copied onto one line -->
If the project config failed to parse, STOP and report it.

## Phase 1 - Draft

Invoke `sd-keeper` with `TASK = draft`.

### ⛔ Gate 1 - Draft approved

STOP. Ask:

> Approve the draft? (yes / revise / abort)

## Phase 2 - Close

Append the outcome to `02-tasks.md`.

### ⛔ Gate 2 - Close approved (HARD)

STOP. Ask:

> Close it now? (yes / revise / abort)
