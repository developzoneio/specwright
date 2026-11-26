# ADR 0037: /sd:port counts criterion coverage before Gate 4 and re-plans at close-out

- Status: accepted
- Date: 2026-11-26
- Source spec: Jira SW-134 (`FIX-port-plan-uncovered-criterion`, E12 / SW-87)
- Relates to: ADR 0003 (the adaptive re-plan loop); ADR 0029 (Gate Re-plan in the stop-gate);
  ADR 0016 (the PORT-G6 row); ADR 0036 (the PORT-G5 batch count); Jira SW-90 (feature plan
  preflight, deferred); Jira SW-105 (`/sd:feature` Phase 6 re-plan on an uncovered criterion)
- Supersedes: none. Changes ADR 0016's PORT-G6 later-phase evidence from "`06-verify.md` exists"
  to "`06-verify.md` records `result: pass`".

## Context

e2e `17-port-gate-brief` run 1 (2026-11-26) passed all 6 gates, then failed close-out: `/sd:verify`
found a criterion that no task listed in `Covers`. The criterion was about the port as a whole
(the donor file left byte-identical and imported by nothing), so the architect had no member task
to attach it to. Two defects let that happen:

1. **Nothing counted coverage before Gate 4.** `sd-spec-architect` is told to cross-check that
   every criterion is covered, but nothing checks that it did. The first check was `VF011`, after
   every line of code was written. The Gate 4 brief had no way to show the gap.
2. **Close-out had no route on fail.** `/sd:feature` Phase 6 enters Gate Re-plan with `Phase:
   verify` on an uncovered criterion. `/sd:port` Phase 9 said only "It must report `result:
   pass`", so the run stopped at a dead end.

Two places could hold the check: (a) the main thread counts it in Phase 6, as Phase 4 step 2
already counts `unmapped`, or (b) a new `SL0xx` rule in `/sd:spec validate`, run before Gate 4.

## Decision

**(a) The main thread counts coverage.** Phase 6 step 5 computes `uncovered` = the `AC-<n>` of
`00-spec.md` listed in no task's `Covers`. When it is above 0, the architect gets one `refine`
call with those criteria, then the count is taken again. Gate 4 shows the count, and the brief
names each uncovered criterion in plain words, never by its `AC-` ID. `yes` is refused while the
count is above 0, the same kind of refusal by count as Gate 2's `unmapped`. Gate 4 stays an
ordinary gate. Refusing `yes` does not make it HARD, because `refine` and `abort` stay open.

Option (b) was rejected for this ticket. It is the four-edit lint path (registry, both linters, a
fixture, the doc table). A validate rule reaches every spec type, which is what SW-90 proposes for
`/sd:feature`, and SW-90 is deferred. A count in the command fixes the port gap without deciding
SW-90.

**Whole-port criteria go on the last task of the last batch.** Every port task needs a snapshot
member range (`SL061`-`SL064`), so a criterion with no member cannot get a task of its own. Phase 6
step 3 puts it in the `Covers` of the last task of the last batch. That batch's full-suite run and
the Phase 8 parity review are what prove it. Its `Acceptance` names the evidence path, either a
pinned test or the parity index, so the witness rule (`SL069`, `VF020`, `VF021`) holds.

**Close-out re-plans through sd-replan-loop.** Phase 9 step 2 routes an uncovered criterion to
Gate Re-plan with `Phase: verify`. Like `/sd:feature` and `/sd:refactor`, it is a conditional gate:
the always-on count stays at 6, and the manifest's `contractLint.gates` lists `Re-plan` as
conditional for `commands/port.md`. A port re-plan widens an existing member task's `Covers` and
never adds a block with no member range. Once the revision is approved:

1. **`04-artifacts/parity/` is removed.** It describes a changeset that is about to change.
   Nothing under it is frozen, and Phase 8 overwrites it on every run anyway. If the folder stayed,
   the state machine would read "all tasks checked, parity present" after the re-run batch and skip
   Phase 8. The stop-gate's PORT-G5 count would also treat the re-run batch as finished while it
   waits at its gate (ADR 0036, rule 2).
2. **The batch holding the regenerated task, Gate 5, Phase 8 and Gate 6 run again**, each as a new
   brief pass, then Phase 9.

**Stop-gate.** Both twins call the Gate Re-plan check (ADR 0029) for `port` specs, as they already
do for `feature` and `refactor`. Port's brief label order gains `R` after `6`, because the gate is
reached only from close-out. Without that entry the parser ignores a `## Gate Re-plan` section,
and the check never fires. PORT-G6's later-phase evidence becomes `06-verify.md records
result: pass`, the same wording FEAT-G3 uses. A failing `06-verify.md` is what starts a re-plan,
so during the re-run it exists while `parity/INDEX.md` does not. It is not evidence that Gate 6 was
skipped.

## Consequences

- A plan that leaves a criterion uncovered can no longer pass Gate 4 with `yes`, and the user sees
  the gap at Gate 4, not at close-out.
- A close-out failure on coverage now has a route, and that route keeps the append-only
  `## Revisions` record.
- PORT-G6 no longer fires on a failing `06-verify.md` alone. A session that writes a failing verify
  report without ever running Phase 8 is not caught. The verify report blocks nothing in that
  state: spec-gate still refuses `done` without a passing `06-verify.md`.
- Three stop-gate fixtures change their evidence text. Two new fixtures cover the port Re-plan:
  an unanswered Re-plan section blocks, and an approved re-plan waiting at the re-run batch's
  Gate 5, with `parity/` removed and a failing verify report, is allowed.
- `/sd:feature` keeps its outline cross-check by the architect alone. Whether it gets a counted
  check too is still SW-90.
