# sd-model-escalation

Demo escalation policy used by the contract-lint fixtures. It owns the ladder and the
trigger table; the demo workflow names only a rule ID.

## Ladder

`haiku -> sonnet -> opus`. One tier per escalation, never a skipped rung.

## Trigger table

| Rule ID | Workflow | Where | Condition | Agent | From | To |
|---|---|---|---|---|---|---|
| `ESC-ALPHA-01` | `/sd:alpha` | Phase 1 step 0, before the draft | the draft is large | `sd-keeper` | `haiku` | `claude-sonnet-4-5` |
