---
description: Demo workflow used by the contract-lint fixtures.
argument-hint: <slug>
---

# /sd:alpha

Demo workflow. Writes `.specs/ALPHA-<slug>/00-spec.md`, then `01-plan.md`.

## Phase 0 - Bootstrap

If `templates/sd/demo.template.md` is missing, STOP and report it. If the registry
is unreadable, STOP. Neither of these sits inside a gate block, and CL300 must not
mistake them for one. Read **sd-gate-brief** before the first gate.

## Phase 1 - Draft

Invoke `sd-keeper` with `TASK = draft`.

<!-- SEEDED: brief-only-fenced - Gate 1 is declared to carry a brief but names the skill only inside a fenced example -->
### ⛔ Gate 1 - Draft approved

STOP. Show the draft brief, then ask:

```text
Shown per sd-gate-brief.
```

> Approve the draft? (yes / revise / details / abort)

## Phase 2 - Close

Append the outcome to `02-tasks.md`.

<!-- SEEDED: brief-undeclared - Gate 2 names the skill but the manifest does not declare it -->
### ⛔ Gate 2 - Close approved (HARD)

STOP. Show the close brief per **sd-gate-brief**, then ask:

> Close it now? (yes / revise / abort)
