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
- `details` -> show the collapsed decisions, then ask again.

## Phase 2 - Close

Append the outcome to `02-tasks.md`.

### ⛔ Gate 2 - Close approved (HARD)

STOP. This gate has two faces. Either face shows its brief per **sd-gate-brief**.

**Face A - normal close.** Ask:

> Close it now? (yes / revise / details <target> / abort)

**Face B - split close.** Ask:

> Split before closing? (approve split / revise / details <target> / abort)

### Gate Re-plan (HARD) - re-plan on a discovery

Follow **sd-demo-loop** for the protocol.

1. STOP. Show the re-plan brief per **sd-gate-brief**. Ask:

<!-- SEEDED: replan-details-dropped - the question sits in an indented quote inside a numbered step and lost details -->
   > Re-plan it? (approve / revise <feedback> / abort task)

   - `approve` -> proceed. `revise` -> adjust and re-ask. `abort task` -> normal task abort.

## Rules

- Gate briefs and user-facing wording follow **sd-gate-brief** only.
