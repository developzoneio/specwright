---
description: Demo workflow used by the contract-lint fixtures.
argument-hint: <slug>
---

# /sd:alpha

Demo workflow. Writes `.specs/ALPHA-<slug>/00-spec.md`, then `01-plan.md`.

## Phase 0 - Bootstrap

Read the **sd-model-escalation** skill; it owns the escalation policy this file applies.
If `templates/sd/demo.template.md` is missing, STOP and report it. If the registry
is unreadable, STOP. Neither of these sits inside a gate block, and CL300 must not
mistake them for one.

## Phase 1 - Draft

0. **Model escalation check.** Apply rule `ESC-ALPHA-01` of **sd-model-escalation**.
1. Invoke `sd-keeper` with `TASK = draft`.

Log the decision with a retro line such as:

<!-- SEEDED: fenced-retro-line - a fenced retro line is still a restatement of the format -->
```text
escalation: sd-keeper haiku -> sonnet (trigger: ESC-ALPHA-01)
```

<!-- SEEDED: wrapped-ladder - the ladder wrapped across two prose lines -->
The keeper moves from haiku ->
sonnet when the draft is large.

### ⛔ Gate 1 - Draft approved

STOP. Ask:

> Approve the draft? (yes / revise / abort)

## Phase 2 - Close

Append the outcome to `02-tasks.md`.

### ⛔ Gate 2 - Close approved (HARD)

STOP. Ask:

> Close it now? (yes / revise / abort)
