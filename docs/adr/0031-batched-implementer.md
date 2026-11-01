# ADR 0031: batched implementer - one call per run of same-file tasks in /sd:feature Phase 4

- Status: accepted
- Date: 2026-11-01
- Source spec: Jira SW-95 (`FEAT-batched-implementer`, E12 / SW-87)
- Relates to: ADR 0017 (handoff-integrity's ready set, extended here); ADR 0023 (the lean task
  format whose `Files`, `Depends on` and `Reversibility` fields the rule reads); ADR 0003 (the
  re-plan loop, which a group stops for); `skills/sd-model-escalation/SKILL.md` (per-task
  decisions, `ESC-FEAT-04` / `04b`)
- Supersedes: none. Extends ADR 0017's definition of the ready set.

## Context

`/sd:feature` Phase 4 called `sd-implementer` once per task. Every call loads CLAUDE.md, the
cited constitution sections, the spec, the task block and the files it edits. Consecutive tasks
often edit the same file. In the fixture, `T01` and `T02` both edit `src/domain/todo.js`, so the
second call reloads almost everything the first one just read.

Three things must not change: each task is checked off on its own; each task gets its own
`T<NN>:` retro line; and the scope check still covers every edit.

## Decision

### The grouping rule (`commands/feature.md` Phase 4)

Tasks are taken in Phase 4 order: dependency order, ties broken by file order.

- **Seed**: the next unchecked task whose `Depends on` tasks are all checked. A seed marked
  `Reversibility: hard` runs alone.
- **Extend** with the next task in order while all three conditions hold:
  1. it is not `hard`;
  2. one of its `Files` entries equals an entry already in the group (normalized as the hook
     normalizes them, compared case-insensitively);
  3. every task in its `Depends on` is checked or already in the group.

  Stop at the first task that fails a condition. Groups are consecutive and never skip a task.
- A group of one is the old per-task run.

There is no size cap. The three conditions already limit a group to work on one file set, and the
ticket asks for none.

### What a group changes

- **One implementer call** with every task block of the group in `TASK_DETAILS`. The input name
  stays the same, so the invocation contract (CL100-CL103) is unchanged. The implementer's scope
  is the union of the group's `Files`. It verifies every block before its first edit, works the
  tasks in order, runs each witness test before starting the next task, and reports one line per
  task.
- **Escalation.** Each task is decided as before, and each task that fires writes its own line.
  The group runs at the highest tier any of its tasks resolved to. `ESC-FEAT-04b` never meets a
  multi-task group, because a `hard` task always runs alone.
- **Failure.** A failing witness test or a scope revert re-invokes the implementer for that group
  only.
- **Gate Re-plan.** A plan-invalidating discovery at task Tk stops the group there. The group's
  earlier tasks that passed are checked off and logged. Tk and every task after it stay unchecked
  until the revision is done.
- **Check-off and retro** stay per task, in order, after the group.

### handoff-integrity follows the rule (extends ADR 0017)

ADR 0017's ready set holds every unchecked task whose dependencies are all checked. Inside a group
`T01` + `T02`, where `T02` depends on `T01`, `T01` is not checked until the group ends. So `T02` is
not ready, and an edit to a file only `T02` declares would be flagged. That is a false positive.

Both hook twins now widen the ready set to a fixpoint. An unchecked task that is not `hard` joins
when two conditions hold:

- every dependency it has that is not yet checked is a non-`hard` task already in the set;
- one of its `Files` entries equals an entry of a non-`hard` task in the set.

This is the grouping rule, read without the "consecutive" condition, which the hook cannot see. A
successor with disjoint `Files`, a `hard` successor, and anything that depends on a `hard` task
all stay out, so they are still flagged. New fixtures:

| Fixture | Expected |
|---|---|
| `silent-grouped-run-second-task-file` | silent |
| `silent-grouped-run-chain` | silent |
| `flag-grouped-run-hard-successor` | flagged |
| `flag-grouped-run-no-overlap` | flagged |
| `flag-grouped-run-chain-stops-at-hard` | flagged |

The existing `flag-not-ready-task-file` keeps flagging. PowerShell and bash agree on every one.

## Alternatives considered

- **An explicit active-group marker.** The main thread would record the group's task IDs, for
  example in `.claude/.hookstate/`, and the hook would read it. That would be exact, but it fails
  open when the model skips the write, which is the reason ADR 0017 rejected an active-task marker.
  Deriving the group from `02-tasks.md` keeps the hook independent of the model.
- **Group every ready task, overlap or not.** That gives fewer calls, but a group then spans
  unrelated files. The implementer would load context it does not need, and a failure would
  re-run unrelated work. File overlap is the point of the saving.
- **Allow `hard` tasks in a group, escalated.** A `hard` task (a migration, a public API change)
  is the one whose diff must stay attributable and revertible on its own. Running it alone keeps
  that, and keeps `ESC-FEAT-04b` a one-task decision.
- **A new input name (`TASK_GROUP`).** Rejected: it would add an invocation mode to lint and
  document, for what is still a list of task blocks.

## Consequences

- Fewer implementer calls when consecutive tasks share a file. e2e scenario `23-feature-batched`
  asserts two `sd-implementer` calls for three tasks, with every task checked off individually
  (assertion `transcript-subagent-calls`, SW-95).
- **Drift.** The grouping rule now lives in two places: `commands/feature.md` and both
  handoff-integrity twins. A change to it must update all three and the fixtures. This is the
  same kind of restatement ADR 0017 already accepts for the task-block grammar.
- **Known gaps:**
  - The hook's widened set over-approximates further. A non-consecutive overlapping task with
    satisfied dependencies is accepted even when Phase 4 would not group it. This is the gap ADR
    0017 already records, now slightly wider.
  - `Files` overlap is exact-entry equality. A directory entry and a file under it do not count as
    overlapping, so such tasks run in separate groups.
  - No live scenario forces a red test or a Gate Re-plan inside a group. Those paths are prompt
    rules (`commands/feature.md`, `agents/implementer.md`, `sd-replan-loop`), and the hook side is
    covered by fixtures.
  - Other workflows (`/sd:refactor`, `/sd:port`, `/sd:bug`, `/sd:perf`) still pass one task per
    call.
