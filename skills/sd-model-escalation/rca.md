# sd-model-escalation - /sd:rca

The `/sd:rca` row of the **sd-model-escalation** trigger table, and how it is decided. Read
`SKILL.md` first: the ladder, the invariants, how the override is applied, the precedence rules
and the logging contract live there and are not restated here. Why the row exists is in
`rationale.md`, which no workflow reads at runtime.

## Trigger table

| Rule ID | Workflow | Where | Condition | Agent | From | To |
|---|---|---|---|---|---|---|
| `ESC-RCA-02` | `/sd:rca` | Phase 2 step 0, once per run, before the first `sd-debugger` call | spec `severity` (`00-spec.md` frontmatter) is `P0` | `sd-debugger` | `sonnet` | `opus` |

## Decision points

**Per run.** `ESC-RCA-02` is decided once per run, at the first Phase 2 `sd-debugger` call, and
covers every Phase 2 and Phase 3 `sd-debugger` call, including Gate 2 `add hypothesis` loops and
Gate 3 `dig deeper` - one line per run. A resumed session that finds the rule's line in
`05-retro.md` re-applies that decision without writing a second line.
