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

> Approve the draft? (yes / revise <feedback> / details / abort)

- `revise` -> redraft it from the notes, from logs and traces only, then ask again.

### ⛔ Gate 2 - Draft reproduced (HARD)

STOP. This gate is HARD - no overrides. Show the brief per **sd-gate-brief**. Ask:

> Is it reproduced? (yes - I can trigger it / partial - intermittent / no - cannot reproduce / details <target>)

- `no` -> refuse to go on.
- `details <target>` -> print what the target names, then ask again.

<!-- contract-lint: allow CL306 - logged insist-and-proceed keeps an audit trail via the constitution exception -->
If the user insists on going on without it, log a constitution exception and proceed at their
explicit risk acknowledgement.

## Phase 2 - Investigate

Append each finding to `02-tasks.md`.

### ⛔ Gate 3a - Nothing found

STOP. Show the brief per **sd-gate-brief**. Ask:

> All <N> leads were ruled out. How do you want to proceed?
> (retry / observe / details <target> / abort)

### ⛔ Gate 3 - Finding confirmed

STOP. Show the finding brief per **sd-gate-brief**. Ask:

> Confirm the finding? (yes / dig deeper / details <target> / abort)
