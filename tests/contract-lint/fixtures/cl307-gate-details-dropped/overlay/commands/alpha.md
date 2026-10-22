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

<!-- SEEDED: details-dropped - Gate 1 is declared to offer details but its option set lost it -->
> Approve the draft? (yes / revise / abort)

## Phase 2 - Close

Append the outcome to `02-tasks.md`.

### ⛔ Gate 2 - Close approved (HARD)

STOP. This gate has two faces. Either face shows its brief per **sd-gate-brief**.

**Face A - normal close.** Ask:

> Close it now? (yes / revise / details <target> / abort)

**Face B - split close.** Ask:

<!-- SEEDED: details-dropped-one-face - Face B lost details while Face A still offers it -->
> Split before closing? (approve split / revise / abort)

### Gate Re-plan (HARD) - re-plan on a discovery

1. STOP. Show the re-plan brief per **sd-gate-brief**. Ask:

<!-- SEEDED: details-undeclared - Re-plan offers details but the manifest does not declare it -->
   > Re-plan it? (approve / revise <feedback> / details / abort task)
