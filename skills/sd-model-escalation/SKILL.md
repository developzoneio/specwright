# sd-model-escalation

Model escalation policy for specwright workflows: when the main thread invokes a subagent one model
tier above its frontmatter default. This file is the single owner of the ladder, the invariants,
the trigger table, the precedence rules, the logging contract and the rule IDs. Commands read it
at runtime (they cannot load skills via frontmatter) and state only a rule ID and its trigger
inputs - never the policy itself. `sd-spec-architect`, `sd-implementer` and `sd-debugger` load it
via `skills:` so they know what the main thread may do to their own invocation.

Origin: ADR 0002 ("Sanctioned model escalation, aliases only"), shipped for `/sd:feature` by SW-13,
extracted here by SW-60 and extended to `/sd:bug`, `/sd:rca`, `/sd:refactor`, `/sd:perf` and
`/sd:port` by SW-62.

---

## Ladder

`haiku -> sonnet -> opus`. One tier per escalation, never a skipped rung.

`inherit` is not a rung. It is a separate mode in which the agent follows the session model; an
`inherit` agent is never escalated, and no trigger row may name one.

## Invariants

1. **Aliases only.** `haiku`, `sonnet`, `opus` - never a version-pinned model ID, anywhere, under
   any circumstance: not in a command, not in a retro line, not in project-config.
2. **Per-invocation main-thread override.** The main thread raises the model on one subagent
   invocation. An agent's `model:` frontmatter is never edited to escalate.
3. **No persistence.** An escalation covers exactly one invocation. The next invocation of the
   same agent - a `refine`, a later phase, a re-plan - starts at its frontmatter default again
   unless a row fires for it in its own right.

## How the override is applied

Pass the reached alias as the `model` parameter of the subagent-invocation tool (Task / Agent).
Claude Code documents that parameter as taking precedence over the agent's `model:` frontmatter.
A model named only in the prompt text is **not** an override - the tool resolves the model from
its parameter and the frontmatter, not from prose - so never "ask" the subagent to be a different
model.

If the invocation tool exposes no `model` parameter, the override cannot be applied. Invoke at the
default and log the decision with the `unapplied` suffix (see Logging contract). Never report an
escalation that did not take effect.

An `unapplied` escalation never stops the workflow to ask the user to switch the session model.
That matters most inside a loop: in `/sd:feature` Phase 4, halting task 5 of 9 for a model switch
costs more than running that one task at the default, and the `unapplied` line keeps the gap
visible in the retro.

---

## Trigger table

One row per escalation point. `From` is the agent's frontmatter default; `To` is one rung up. A
row is live only when the command named in it references its rule ID - rows are added here by the
story that wires them, mirrored row for row in the engine manifest's
`contractLint.escalationTriggers` (contract-lint CL601-CL604 fail on any drift).

| Rule ID | Workflow | Where | Condition | Agent | From | To |
|---|---|---|---|---|---|---|
| `ESC-FEAT-02` | `/sd:feature` | Phase 2 step 0, before the impact map | spec `complexity` (`00-spec.md` frontmatter) is `L` | `sd-code-explorer` | `haiku` | `sonnet` |
| `ESC-FEAT-03` | `/sd:feature` | Phase 3 step 0, before the plan | spec `complexity` is `L` | `sd-spec-architect` | `sonnet` | `opus` |
| `ESC-FEAT-03b` | `/sd:feature` | Gate 2 Face B, on `no-split` | `ESC-FEAT-03` did not fire for this plan (the `L` estimate under-called it); re-invoke Phase 3 once | `sd-spec-architect` | `sonnet` | `opus` |
| `ESC-FEAT-04` | `/sd:feature` | Phase 4 step 2, once per task, before the implementer | task `Estimated complexity` (`02-tasks.md` task block) is `L` | `sd-implementer` | `haiku` | `sonnet` |
| `ESC-FEAT-04b` | `/sd:feature` | Phase 4 step 2, once per task, before the implementer | task `Reversibility` is `hard`, and `ESC-FEAT-04` did not fire for this task | `sd-implementer` | `haiku` | `sonnet` |
| `ESC-BUG-03` | `/sd:bug` | Phase 3 step 0, once per enumeration round, before `TASK = enumerate` | spec `severity` (`00-spec.md` frontmatter) is `P0` or `P1` | `sd-debugger` | `sonnet` | `opus` |
| `ESC-BUG-03b` | `/sd:bug` | Phase 3 step 0, once per enumeration round, before `TASK = enumerate` | `03-decisions.md` already records two or more exhausted hypothesis trees (Gate 3a reached twice), and `ESC-BUG-03` did not fire | `sd-debugger` | `sonnet` | `opus` |
| `ESC-RCA-02` | `/sd:rca` | Phase 2 step 0, once per run, before the first `sd-debugger` call | spec `severity` (`00-spec.md` frontmatter) is `P0` | `sd-debugger` | `sonnet` | `opus` |
| `ESC-REF-04` | `/sd:refactor` | Phase 4 step 0, before the plan | the Phase 2 impact analysis in `03-decisions.md` names more than 8 distinct files, or those files fall under more than 2 `paths.layers` entries of project-config | `sd-spec-architect` | `sonnet` | `opus` |
| `ESC-PERF-04` | `/sd:perf` | Phase 4a step 4, before Gate 4 is re-presented for a hotspot | the Results log holds two or more `reverted` rows for this hotspot, and `ESC-PERF-04` has not fired for this hotspot; re-invoke 4a once | `sd-debugger` | `sonnet` | `opus` |
| `ESC-PORT-06` | `/sd:port` | Phase 6 step 2, before the plan | the Phase 6 step 1 port decompose metric (deviation rows requiring adaptation) is more than 8 | `sd-spec-architect` | `sonnet` | `opus` |

Why each row exists:

- `ESC-FEAT-02` - a create-time `L` is exactly the multi-subsystem case where the shallow haiku
  impact map degrades.
- `ESC-FEAT-03` - single-pass planning is where large scope degrades non-linearly.
- `ESC-FEAT-03b` - the user accepted one oversized plan instead of a split; that plan must come
  from the escalated architect, so a plan written at the default is re-done once, escalated.
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
- `ESC-RCA-02` - `P0` only. An RCA changes no code; its fixes spawn their own `BUG-*` specs, which
  carry `ESC-BUG-03` in their own right. Only a production-down incident justifies paying opus
  up front for the analysis itself.
- `ESC-REF-04` - the same two size limits `/sd:feature` Gate 2 Face B applies (impact surface > 8
  files; > 2 production layers, ADR 0004), read from the measured impact map instead of an
  estimate. A refactor that wide is where parallel-safe batching (disjoint file sets per batch)
  degrades first. When `paths.layers` is `[]`, only the file clause is evaluated.
- `ESC-PERF-04` - fires on observed failure: two optimizations the default debugger proposed were
  applied and reverted. Gate 4 would otherwise offer the rest of the same list from the same tier,
  so the rule re-runs the 4a deep dive once, escalated, with the reverted attempts in view. It is a
  re-invocation row: under a ceiling that leaves the tier unchanged the re-run is skipped
  (precedence rule 2) and Gate 4 continues with the hypotheses already listed.
- `ESC-PORT-06` - the port decompose metric `/sd:port` already computes and records. Planning
  judgment in a port scales with departures from the donor, not with its file count or layer
  spread, which are inherited from the donor by construction. The threshold is the same `> 8`.

**Measured beats self-declared.** `ESC-FEAT-02` / `03` read an estimate the model made about the
work before starting. `ESC-BUG-03b` and `ESC-PERF-04` fire on failure already observed, and
`ESC-REF-04` and `ESC-PORT-06` on a quantity the workflow has measured. A measured trigger
cannot be wrong about the past, and it escalates exactly when the default tier has shown it is not
enough. `ESC-BUG-03` / `ESC-RCA-02` read `severity`, a statement about impact, not about difficulty.
A measured trigger for `/sd:feature` (escalate when Gate 2's computed thresholds are exceeded) is
argued by the same reasoning, but it edits a shipped gate and is out of scope here.

**Per-round and per-run decisions.** `ESC-BUG-03` / `ESC-BUG-03b` are decided once per enumeration
round, at its `TASK = enumerate` call; the decision covers that round's `TASK = verify` calls - one
line per round. A Gate 3a `re-enumerate` or `observe` starts a new round, decided afresh.
`ESC-RCA-02` is decided once per run, at the first Phase 2 `sd-debugger` call, and covers every
Phase 2 and Phase 3 `sd-debugger` call, including Gate 2 `add hypothesis` loops and Gate 3
`dig deeper` - one line per run. A resumed session that finds the rule's line in `05-retro.md`
re-applies that decision without writing a second line. `ESC-PERF-04` fires at most once per
hotspot and covers only the 4a re-invocation it triggers.

**Per-task decision in Phase 4.** `ESC-FEAT-04` / `ESC-FEAT-04b` are decided once per task, when
the task is first invoked, and that decision covers the task's re-invocations in the same Phase 4
pass (a scope revert, a failing test, constitution feedback) - one line per task, not per retry.
The next task starts at the default again (invariant 3). A task regenerated by Gate Re-plan is a
new task block and is decided afresh.

**Ceiling interaction.** Both Phase 4 rows reach `sonnet`, so `ceiling: "sonnet"` leaves them
untouched - they fire, uncapped. Only `ceiling: "haiku"` caps them (logged `capped`, reached
`haiku`). `tests/e2e/scenarios/06-escalation-implementer` asserts the `sonnet` case. Every
non-feature row starts at `sonnet`, so `ceiling: "sonnet"` caps each of them to no movement: the
line still records the decision (`sonnet -> sonnet ... capped`), so a capped run stays
distinguishable from a run where the policy never executed.
`tests/e2e/scenarios/11-escalation-rca-capped` asserts that for `ESC-RCA-02`.

**Rule ID format.** `ESC-<WORKFLOW>-<PHASE>` with an optional lowercase suffix (`b`, `c`) for a
second row at the same phase. `<WORKFLOW>` is the spec prefix (`FEAT`, `BUG`, `REF`, `PERF`,
`RCA`, `PORT`). An ID is stable: once shipped it is never renumbered or reused, because retro
lines already written name it.

**Two different `complexity` fields.** A spec-level `complexity` (`00-spec.md` frontmatter) and a
task-level `Estimated complexity` (a `02-tasks.md` task block) are different fields. Every row
names the one it reads; a row that reads the task field gets its own rule ID.

---

## Precedence rules

Read `models.escalation` from the project-config the calling command already parsed in Phase 0.
Evaluate in order; the first rule that decides, decides.

1. **`models.escalation.enabled == false` suppresses everything.** No trigger fires, no override is
   applied, no retro line is written.
2. **`models.escalation.ceiling` caps the ladder.** A row whose `To` is above the ceiling reaches
   the ceiling instead - never below the row's `From`, because escalation never lowers a model.
   A capped escalation is not a skipped one: it is logged with the `capped` suffix. When the cap
   leaves the tier unchanged and the row's action is a re-invocation (`ESC-FEAT-03b`,
   `ESC-PERF-04`), the re-invocation is not run - it would reproduce the same output - but the
   capped line is still written.
3. **Otherwise the trigger table applies.** A row fires when its condition holds at its `Where`
   point; a row whose condition does not hold writes nothing.
4. **Absent keys mean defaults.** No `models.escalation` block, or a block missing a key, reads as
   `enabled: true`, `ceiling: "opus"` - a project scaffolded before this policy behaves exactly as
   it did.

An invalid value - `enabled` that is not a boolean, or a `ceiling` outside `haiku` / `sonnet` /
`opus` (including `inherit` or a pinned ID) - is never guessed at. WARN once:
"`models.escalation` has an invalid value - escalation disabled for this run." and treat the run
as rule 1. The cheaper reading is the safe one; a typo never buys a more expensive model.

---

## Logging contract

Every decision that fires - applied, capped or unapplied - appends exactly one line to the spec's
`05-retro.md`, written by the main thread (subagents do not write it). Create the file if missing;
never overwrite existing content. Write the line when the decision is made, before the invocation.

```text
escalation: <agent> <from> -> <to> (trigger: <rule-id>)
escalation: <agent> <from> -> <reached> (trigger: <rule-id>) capped
escalation: <agent> <from> -> <to> (trigger: <rule-id>) unapplied
```

- `<agent>` is the namespaced agent name (`sd-spec-architect`), `<from>` / `<to>` / `<reached>` are
  aliases, `<rule-id>` is a Rule ID from the trigger table.
- `capped`: `<reached>` is the tier the ceiling allowed, which may equal `<from>`.
- `unapplied`: the tool had no `model` parameter; the invocation ran at `<from>`.
- No line is written for a row whose condition did not hold, or when `enabled` is `false`.

This line is the only runtime evidence the policy executed. A run that should have escalated and
left no line is indistinguishable from the policy not running.

Example - a `complexity: L` spec under `ceiling: "sonnet"` whose task T03 is `Estimated
complexity: L`:

```text
escalation: sd-code-explorer haiku -> sonnet (trigger: ESC-FEAT-02)
escalation: sd-spec-architect sonnet -> sonnet (trigger: ESC-FEAT-03) capped
escalation: sd-implementer haiku -> sonnet (trigger: ESC-FEAT-04)
```

---

## Non-goals

- Selecting the main-session model. The policy escalates subagents only.
- Changing decomposition thresholds - `/sd:feature` Gate 2 and ADR 0004 own those.
- Invoking anything. The calling command invokes; this file decides the model for that invocation.

## Anti-patterns

- Restating the ladder, a precedence rule or the retro line format in a command. Reference the
  rule ID and state its trigger inputs; the policy stays here.
- Escalating two tiers at once, or escalating a second time on the same invocation.
- Editing an agent's `model:` frontmatter "just for this spec".
- Treating a capped or unapplied escalation as not worth logging.
