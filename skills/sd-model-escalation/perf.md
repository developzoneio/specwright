# sd-model-escalation - /sd:perf

The `/sd:perf` rows of the **sd-model-escalation** trigger table, and how they are decided. Read
`SKILL.md` first: the ladder, the invariants, how the override is applied, the precedence rules
and the logging contract live there and are not restated here. Why each row exists is in
`rationale.md`, which no workflow reads at runtime.

## Trigger table

| Rule ID | Workflow | Where | Condition | Agent | From | To |
|---|---|---|---|---|---|---|
| `ESC-PERF-04` | `/sd:perf` | Phase 4a step 4, before Gate 4 is re-presented for a hotspot | the Results log holds two or more `reverted` rows for this hotspot, and `ESC-PERF-04` has not fired for this hotspot; re-invoke 4a once | `sd-debugger` | `sonnet` | `opus` |
| `ESC-PERF-04b` | `/sd:perf` | Phase 4b step 1, once per applied hypothesis, before the implementer | the hypothesis chosen at Gate 4 has `Reversibility: hard` in its risk profile (`03-decisions.md`) | `sd-implementer` | `haiku` | `sonnet` |

## Decision points

**Once per hotspot.** `ESC-PERF-04` fires at most once per hotspot and covers only the 4a
re-invocation it triggers. It is a re-invocation row: under a ceiling that leaves the tier
unchanged the re-run is skipped (precedence rule 2) and Gate 4 continues with the hypotheses
already listed.

**Once per hypothesis.** `ESC-PERF-04b` is decided once per hypothesis applied at 4b and covers
only that attempt; the next hypothesis chosen at Gate 4 is decided afresh.
