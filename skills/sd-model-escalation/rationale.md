# sd-model-escalation - rationale

Why each trigger row exists, and the design notes behind the table. This file is the reasoning
record of **sd-model-escalation**. No workflow reads it at runtime: the rules a run applies are in
`SKILL.md` and the per-workflow files beside it. Read it before adding, changing or removing a row.

Origin: ADR 0002 ("Sanctioned model escalation, aliases only"), shipped for `/sd:feature` by SW-13,
extracted here by SW-60 and extended to `/sd:bug`, `/sd:rca`, `/sd:refactor`, `/sd:perf` and
`/sd:port` by SW-62. `ESC-REF-02` was added by SW-84, and `ESC-PORT-01` (the port
extraction, including its donor-side `/sd:explore --port` call site) by SW-85.
SW-86 extended the `sd-implementer` rows beyond `/sd:feature`. SW-97 split the skill into a core
and one file per workflow, so a command reads only its own rows.

---

## Why each row exists

- `ESC-FEAT-02` - a create-time `L` is exactly the multi-subsystem case where the shallow haiku
  impact map degrades.
- `ESC-FEAT-03` - planning is where large scope degrades non-linearly, and since ADR 0022 the
  planning decisions - approach, task partition, decompose - are made in the Phase 3a outline. The
  Phase 3b expansion of an outline Gate 2 approved stays at the default unless `ESC-FEAT-03b` fires.
- `ESC-FEAT-03b` - the user accepted one oversized plan instead of a split; its task blocks must
  come from the escalated architect. It escalates the expansion, not a second outline: re-running
  Phase 3a would rewrite the outline the user just approved, which is immutable.
- `ESC-FEAT-04` - an `L` task is by definition one that "requires a design decision at
  implementation time" (**sd-atomic-task-format**); that decision is what the haiku implementer
  is not sized for.
- `ESC-FEAT-04b` - `hard` alone trips it, whatever the task's size. `hard` means a data
  migration, a public API change or multi-service impact: the cost of a wrong diff is asymmetric
  and a small task does not shrink it - a one-line migration is still a migration. The value is
  rare by construction, and the escalation covers one invocation, so the added cost is bounded.
  The "did not fire" clause keeps a task that is both `L` and `hard` to one decision and one line.
- `ESC-BUG-03` - `P0` (production down) and `P1` (major feature broken) are the two severities
  (**sd-spec-templates**) where a wrong root cause ships a wrong fix into an outage. `P2` / `P3`
  keep the default: the cost of a second investigation round is lower than a standing opus bill.
- `ESC-BUG-03b` - fires on observed failure. One exhausted tree can mean the evidence was thin,
  which Gate 3a's `observe` exists to fix. A second exhaustion, after fresh evidence, shows the
  default tier has already failed twice on this bug. The threshold is two, not one, so a single
  evidence-starved round does not buy opus. The "did not fire" clause keeps a `P0` / `P1` round to
  one line.
- `ESC-BUG-05` - the same severity argument as `ESC-BUG-03`, applied to the diff instead of the
  diagnosis. A `P0` / `P1` root cause found at opus and then written as a fix by haiku spends the
  expensive tier on the half of the work the failing test already guards least. The Gate 4 test
  bounds the risk, so the rung is one (`sonnet`), not two. `P2` / `P3` keep the default.
- `ESC-RCA-02` - `P0` only. An RCA changes no code; its fixes spawn their own `BUG-*` specs, which
  carry `ESC-BUG-03` in their own right. Only a production-down incident justifies paying opus
  up front for the analysis itself.
- `ESC-REF-02` - `ESC-REF-04` is only as good as the impact map it measures. Without GitNexus
  the explorer walks callers by grep, which misses DI / reflection / dynamic-dispatch callers and
  under-counts the surface; a wide refactor then stays at or under 8 files, `ESC-REF-04` never
  fires, and the plan is made at the default tier. The condition is a project fact read before the
  call, not an estimate. Absent reads as disabled, matching the project-config template default.
  Not covered: GitNexus enabled but failing at runtime - the explorer falls back after the
  decision was made, and notes the caveat in its output.
- `ESC-REF-04` - the same two size limits `/sd:feature` Gate 2 Face B applies (impact surface > 8
  files; > 2 production layers, ADR 0004), read from the measured impact map instead of an
  estimate. A refactor that wide is where parallel-safe batching (disjoint file sets per batch)
  degrades first.
- `ESC-REF-05` / `ESC-REF-05b` - the `ESC-FEAT-04` / `ESC-FEAT-04b` argument, unchanged: both read
  fields of the shared task format (**sd-atomic-task-format**), so a refactor task block means what
  a feature task block means. An `L` refactor task holds a design decision, and a `hard` one
  (a public API move, a data shape change) is a wrong diff whose cost is asymmetric, and the
  implementer must keep every `INVARIANTS` entry across it. `ESC-REF-04` escalates the plan for a
  wide refactor; these rows escalate the task that is individually hard, wide refactor or not.
- `ESC-PERF-04` - fires on observed failure: two optimizations the default debugger proposed were
  applied and reverted. Gate 4 would otherwise offer the rest of the same list from the same tier,
  so the rule re-runs the 4a deep dive once, escalated, with the reverted attempts in view.
- `ESC-PERF-04b` - one optimization per call, but caching and concurrency changes are where a
  subtly wrong diff passes the correctness suite. It reads the `Reversibility` the debugger
  already records per hypothesis, in the task format's vocabulary (`trivial` / `moderate` /
  `hard`), and only `hard` - the `ESC-FEAT-04b` argument. Implementation cost is not a trigger:
  a perf attempt is measured and reverted at Gate 6 when it does not pay, so its size is already
  bounded by the loop.
- `ESC-PORT-01` - the extraction is the donor-side contract every later `/sd:port` phase consumes
  (snapshot, fidelity tables, the `ESC-PORT-06` metric, parity review), so a closure it misses
  propagates silently. It is the hardest task `sd-code-explorer` has: an uncapped member closure,
  a complement set, and a "Non-obvious invariants" section that is judgment, not lookup. Two
  inputs make it degrade at haiku: without GitNexus the walk is recursive grep, which the agent
  itself flags as imprecise for dynamic dispatch, DI and reflection; and a `module` or `feature`
  closure is wide even with GitNexus. An `endpoint` or `pattern` extraction with GitNexus keeps
  the default. Both inputs are declared before the call - configuration and the user's `--scope`
  - so the row fires on neither an estimate nor a failure.
- `ESC-PORT-06` - the port decompose metric `/sd:port` already computes and records. Planning
  judgment in a port scales with departures from the donor, not with its file count or layer
  spread, which are inherited from the donor by construction. The threshold is the same `> 8`.

## Measured beats self-declared

`ESC-FEAT-02` / `03` read an estimate the model made about the work before starting.
`ESC-BUG-03b` and `ESC-PERF-04` fire on failure already observed, and `ESC-REF-04` and
`ESC-PORT-06` on a quantity the workflow has measured. A measured trigger cannot be wrong about
the past, and it escalates exactly when the default tier has shown it is not enough - provided the
measurement is sound, which is what `ESC-REF-02` protects for `ESC-REF-04`. `ESC-BUG-03` /
`ESC-BUG-05` / `ESC-RCA-02` read `severity`, a statement about impact, not about difficulty.
`ESC-PORT-01` reads neither: it reads configuration and a user-chosen scope, which say how the walk
will run and how wide it is, not how hard the model thinks it is. The task-level rows
(`ESC-FEAT-04` / `04b`, `ESC-REF-05` / `05b`, `ESC-PERF-04b`) read a planner's estimate of one unit
of work - self-declared, but by a different agent than the one being escalated.
A measured trigger for `/sd:feature` (escalate when Gate 2's computed thresholds are exceeded) is
argued by the same reasoning, but it edits a shipped gate and is out of scope here.

## Ceiling interaction

Every `haiku`-default row - the `sd-implementer` rows (`ESC-FEAT-04` / `04b`, `ESC-BUG-05`,
`ESC-REF-05` / `05b`, `ESC-PERF-04b`) and the `sd-code-explorer` rows (`ESC-FEAT-02`,
`ESC-REF-02`, `ESC-PORT-01`) - reaches `sonnet`, so `ceiling: "sonnet"` leaves them untouched -
they fire, uncapped. Only `ceiling: "haiku"` caps them (logged `capped`, reached `haiku`).
`tests/e2e/scenarios/06-escalation-implementer` asserts the `sonnet` case. Every other row starts
at `sonnet`, so `ceiling: "sonnet"` caps each of them to no movement: the line still records the
decision (`sonnet -> sonnet ... capped`), so a capped run stays distinguishable from a run where
the policy never executed. `tests/e2e/scenarios/11-escalation-rca-capped` asserts that for
`ESC-RCA-02`.

## Task fields

**Two different `complexity` fields.** A spec-level `complexity` (`00-spec.md` frontmatter) and a
task-level `Estimated complexity` (a `02-tasks.md` task block) are different fields. Every row
names the one it reads; a row that reads the task field gets its own rule ID.

**Absent task fields read as their defaults.** `Estimated complexity` and `Reversibility` are
optional in a task block (**sd-atomic-task-format**): a block writes them only when they differ
from `M` / `trivial`. An absent field is read as that default, so it never fires a row; a task
trips `ESC-FEAT-04` / `ESC-REF-05` only by writing `L`, and `ESC-FEAT-04b` / `ESC-REF-05b` only by
writing `hard`. A legacy block that writes every field is read as written - nothing here changes
how a value that is present is read, only how an absent one is read. Each of those rows states
the default in its own `Condition` cell, so a run reading only its workflow file applies it.
