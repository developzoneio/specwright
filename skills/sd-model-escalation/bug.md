# sd-model-escalation - /sd:bug

The `/sd:bug` rows of the **sd-model-escalation** trigger table, and how they are decided. Read
`SKILL.md` first: the ladder, the invariants, how the override is applied, the precedence rules
and the logging contract live there and are not restated here. Why each row exists is in
`rationale.md`, which no workflow reads at runtime.

## Trigger table

| Rule ID | Workflow | Where | Condition | Agent | From | To |
|---|---|---|---|---|---|---|
| `ESC-BUG-03` | `/sd:bug` | Phase 3 step 0, once per enumeration round, before `TASK = enumerate` | spec `severity` (`00-spec.md` frontmatter) is `P0` or `P1` | `sd-debugger` | `sonnet` | `opus` |
| `ESC-BUG-03b` | `/sd:bug` | Phase 3 step 0, once per enumeration round, before `TASK = enumerate` | `03-decisions.md` already records two or more exhausted hypothesis trees (Gate 3a reached twice), and `ESC-BUG-03` did not fire | `sd-debugger` | `sonnet` | `opus` |
| `ESC-BUG-05` | `/sd:bug` | Phase 5 step 3, once per run, before the implementer | spec `severity` (`00-spec.md` frontmatter) is `P0` or `P1` | `sd-implementer` | `haiku` | `sonnet` |

## Decision points

**Per round.** `ESC-BUG-03` / `ESC-BUG-03b` are decided once per enumeration round, at its
`TASK = enumerate` call; the decision covers that round's `TASK = verify` calls - one line per
round. A Gate 3a `re-enumerate` or `observe` starts a new round, decided afresh.

**Per run.** `ESC-BUG-05` is decided once per run, at the first Phase 5 implementer call, and
covers every later implementer call of that run, including a Gate 5 `address findings` loop - one
line per run. A resumed session that finds the rule's line in `05-retro.md` re-applies that
decision without writing a second line.
