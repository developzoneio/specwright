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

## Phase 1 - Draft

Invoke `sd-keeper` with `TASK = draft`.

### ⛔ Gate 1 - Draft approved

STOP. Ask:

> Approve the draft? (yes / revise / abort)

## Phase 2 - Close

Append the outcome to `02-tasks.md`.

## Rules (hard constraints)

- Change the registry row and the draft's `status:` field with the Edit tool only - never a shell
  command, so the gate hook can check the change.

### ⛔ Gate 2 - Close approved (HARD)

STOP. Ask:

> Close it now? (yes / revise / abort)
