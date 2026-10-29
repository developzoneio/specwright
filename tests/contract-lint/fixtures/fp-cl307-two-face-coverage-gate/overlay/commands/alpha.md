---
description: Demo workflow used by the contract-lint fixtures.
argument-hint: <slug>
---

# /sd:alpha

Demo workflow. Writes `.specs/ALPHA-<slug>/00-spec.md`, then `01-plan.md`.

## Phase 0 - Bootstrap

If `templates/sd/demo.template.md` is missing, STOP and report it. Read **sd-gate-brief** before
the first gate.

## Phase 1 - Draft

Invoke `sd-keeper` with `TASK = draft`.

### ⛔ Gate 1 - Draft approved

STOP. Show the draft brief per **sd-gate-brief**, then ask:

> Approve the draft? (yes / refine <feedback> / details <target> / abort)

## Phase 2 - Measure

Measure coverage of the files the draft names and write it to `00-spec.md`.

### ⛔ Gate 2 - Coverage threshold met (HARD)

STOP. This gate is HARD. Write the brief per **sd-gate-brief** from the measurement, then show
it. The brief takes one of two faces, and its prose words every choice without a parenthetical.

**Face A - measured at or above the bar.** Ask:

> Coverage meets the bar. Continue? (yes / details <target> / abort)

**Face B - measured below the bar.** The work is blocked. Ask:

> Coverage is below the bar. (add tests / exception <reason> / details <target> / abort)

- `add tests` -> write characterization tests, measure again, then this gate again.
- `exception <reason>` -> log the lowered bar as a constitution exception, then proceed.
- `details <target>` -> print what the target names, then ask again.

### Gate Re-plan (HARD) - re-plan on a discovery

1. STOP. Show the re-plan brief per **sd-gate-brief**. Ask:

   > Re-plan it? (approve / revise <feedback> / details <target> / abort task)

   - `approve` -> proceed. `revise` -> adjust and re-ask. `abort task` -> normal task abort.

## Rules

- Gate briefs and user-facing wording follow **sd-gate-brief** only.
