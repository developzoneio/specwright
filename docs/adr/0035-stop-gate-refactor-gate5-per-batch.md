# ADR 0035: Stop close-out gate - /sd:refactor Gate 5 is approved once per batch

- Status: accepted
- Date: 2026-11-17
- Source spec: Jira SW-115 (`FEAT-stop-gate-ref-batch-count`, E12 / SW-87)
- Relates to: ADR 0029 (the REF-G5 row and the alternative this ADR takes up); ADR 0021 (the
  any-pass approval and the parse contract); ADR 0025 (Gate Re-plan keeps `Parallel batch`);
  ADR 0012 (hook latency budget)
- Supersedes: none. Extends ADR 0029's REF-G5 row and removes its known limit "Refactor Gate 5 is
  approved once for every batch".

## Context

`/sd:refactor` stops at Gate 5 after every batch, and each stop writes a new `## Gate 5` section
to `gate-briefs.md`. ADR 0029 checks REF-G5 with the any-pass rule of ADR 0021: one approving
reply in any Gate 5 section satisfies the gate. A session that approves batch 1 and then runs
batches 2 and later without stopping is not caught. Racing ahead like that is the most likely
drift at this gate. ADR 0029 rejected a per-batch count for the time being because it needed the
`Parallel batch` field parsed, an answer for `solo` tasks and a guard for resumed specs.

Two things on disk show that a batch is past its Gate 5:

- **A done task.** Phase 5 sets a task's `Status` to `done` only on Gate 5 `yes`, so a done task
  is past its gate.
- **The next batch's test output.** `04-artifacts/batches/batch-<b>-tests.txt` is saved after
  batch `b` runs and *before* its Gate 5. The newest file can be a batch waiting at its gate, but
  every older one is a batch the run has gone past. A session that does not stop at Gate 5 also
  skips the check-off that `yes` triggers, so this is often the only trace of the skip.

## Decision

REF-G5 keeps its ADR 0029 checks. When the brief records Gate 4 and at least one Gate 5 section
holds an approving reply, it also compares two numbers:

| Term | Meaning |
|---|---|
| approved | `## Gate 5` sections holding at least one approving reply. A section counts once, however many replies it records |
| done units | distinct numeric `Parallel batch` values among tasks whose `Status` is `done`, plus one per done task whose batch is `solo` |
| tested units | distinct numeric `<b>` among `04-artifacts/batches/batch-<b>-tests.txt` |
| finished | the larger of done units and tested units minus one |

The rule fires when finished is greater than approved. The finding's missing item is "an approving
Reply: line in a ## Gate 5 section of gate-briefs.md for every finished batch (<a> approved, <f>
finished)". Its evidence lists whichever count exceeds approved: "done tasks in 02-tasks.md span
<n> batches", "04-artifacts/batches/ holds test output for <n> batches", or both.

1. **Only after Gate 4 is recorded.** The run that planned the batches wrote Gate 4's section, so
   every batch since has a Gate 5 section to count. A brief that starts at Gate 5 or later (a
   resumed spec, or one whose early batches predate gate briefs) keeps the any-pass rule: a
   missing record is not a skipped gate.
2. **Only once some Gate 5 approves.** With no approving Gate 5 reply, ADR 0029's item already
   reports the gate, and the count would only repeat it.
3. **`solo`.** `sd-atomic-task-format` defines `solo` as a task that cannot be batched with any
   other, so Phase 5 runs it as a batch of one with its own Gate 5. Each done `solo` task is one
   unit. A task with no readable `Parallel batch` counts for nothing.
4. **Re-passes.** `revert` and `fix` are non-approving tokens, so their sections do not count, and
   the batch's later `yes` section counts once. `details` followed by `yes` in one section is one
   approved pass.
5. **Gate Re-plan.** Regenerated tasks keep their `Parallel batch` (ADR 0025), and Phase 5 resumes
   at the batch holding the first regenerated task. Re-running a batch adds one approved section
   and no new unit, so a Re-plan never makes the count fire.
6. **Parse contract.** `02-tasks.md` is read for two field lines per task, `- **Parallel batch**:`
   and `- **Status**: done`. A task runs from one `## ` or `### ` heading to the next. Only the
   file names of `04-artifacts/batches/` are read, never their content. `gate-briefs.md` is still
   read for headings and `Reply:` lines only.

## Alternatives considered

- **Done tasks only** (the ticket's draft). Kept as one of the two signals. On its own it misses a
  session that races ahead without checking tasks off, which is the likely shape of the skip,
  because the check-off is part of the `yes` branch.
- **Batch identity from the brief body.** The Gate 5 shown lines start with `Batch <b> of <B>`, so
  approvals could be matched batch by batch. Rejected: it widens the brief parse contract to
  model-written body lines, which `sd-gate-brief` lets the model phrase. Counting sections is
  enough because a batch is approved exactly once on the happy path.
- **Count every batch test file.** Rejected: the newest file is written before its own Gate 5, so a
  session waiting at batch 2 would be blocked.
- **Apply the count to port Gate 5 too.** `/sd:port` Gate 5 also repeats per batch (ADR 0032, rule
  6). Not done here: port tasks have no `Parallel batch` field, so only the test-output signal
  would apply, and port's batch flow needs its own check. Done in ADR 0036 (SW-133).

## Consequences

- **Fixtures.** Ten new cases in `tests/hooks/fixtures/stop-gate/`: two batches done with one
  approval, each batch approved, a brief that starts at Gate 5, `revert` then `yes`, a `revert`
  that does not count, `solo` approved and unapproved, test output ahead of the check-off, a run
  waiting at batch 2, and two tasks in one batch. No existing fixture changed.
  `scripts/smoke-hooks.*` add three cases each.
- **Latency.** The refactor path reads `02-tasks.md` once more and lists `04-artifacts/batches/`,
  only when the brief records Gate 4 and approves Gate 5. Measured in SW-115 (see CHANGELOG),
  within the ADR 0012 budgets, which are unchanged.
- **Known limits:**
  - A batch whose test output is never saved and whose tasks are never checked off leaves no trace;
    the count cannot see it.
  - An approval recorded for the wrong batch still counts: sections are counted, not matched to
    batches.
  - A Re-plan that re-runs a finished batch adds an approval that a later skipped batch can use up.
- **Drift.** The rule restates `commands/refactor.md` Phase 5 (check-off on `yes`, test output
  saved before the gate) and the `Parallel batch` field of `sd-atomic-task-format`. A change to
  either must update both hook twins and their fixtures.
