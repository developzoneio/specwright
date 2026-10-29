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

### ⛔ Gate 1 - Draft approved

STOP. Show the draft brief per **sd-gate-brief**, then ask:

> Approve the draft? (yes / revise / details / abort)

- `yes` -> proceed.
<!-- SEEDED: prose-paren-counts - a slash parenthetical in prose is an option set, and it lacks details -->
- `revise` -> redraft it from the notes only (logs / traces only), then ask again.

### ⛔ Gate 2 - Draft confirmed (HARD)

STOP. Show the confirm brief per **sd-gate-brief**. Ask:

> Is it confirmed? (yes - I checked it / no - not yet / details <target>)

## Phase 2 - Investigate

Append each finding to `02-tasks.md`.

<!-- SEEDED: sub-gate-undeclared-brief - 3a names the skill, but only 3 is declared -->
### ⛔ Gate 3a - Nothing found

STOP. Show the brief per **sd-gate-brief**. Ask:

<!-- SEEDED: sub-gate-undeclared-details - 3a offers details, but only 3 is declared -->
> Nothing found. How now? (retry / details <target> / abort)

### ⛔ Gate 3 - Finding confirmed

STOP. Show the finding brief per **sd-gate-brief**. Ask:

> Confirm the finding? (yes / dig deeper / details <target> / abort)
