---
description: Demo workflow used by the contract-lint fixtures.
argument-hint: <slug>
---

# /sd:alpha

Demo workflow. Writes `.specs/ALPHA-<slug>/00-spec.md`, then `01-plan.md`.

## Phase 0 - Bootstrap

1. Read `~/.claude/skills/sd/sd-demo-guard/SKILL.md` and apply it before anything else here. If
   that file is unreadable, STOP and report an incomplete install.
2. If `templates/sd/demo.template.md` is missing, STOP and report it. Neither STOP sits inside a
   gate block, and CL300 must not mistake them for one.

A fenced example of what the guard prints is documentation, not a restatement:

```text
No `.specs/` found - the guard prints this, not this command
```

## Phase 1 - Draft

Invoke `sd-keeper` with `TASK = draft`.

### ⛔ Gate 1 - Draft approved

STOP. Ask:

> Approve the draft? (yes / revise / abort)

## Phase 2 - Close

Append the outcome to `02-tasks.md`. Outside Phase 0, prose may mention that a config failed to
parse without restating the guard.

### ⛔ Gate 2 - Close approved (HARD)

STOP. Ask:

> Close it now? (yes / revise / abort)
