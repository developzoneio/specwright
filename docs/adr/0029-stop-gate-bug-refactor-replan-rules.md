# ADR 0029: Stop close-out gate - /sd:bug, /sd:refactor and Gate Re-plan rules from gate-briefs.md

- Status: accepted
- Date: 2026-10-29
- Source spec: Jira SW-108 (`FEAT-stop-gate-bug-ref-rules`, E12 / SW-87)
- Relates to: ADR 0016 (the invariant table); ADR 0021 (the `/sd:feature` rows, whose coverage,
  approval and parse rules this ADR reuses); ADR 0024 and ADR 0025 (the `/sd:bug` and
  `/sd:refactor` briefs, and the Re-plan section shape); ADR 0015 (Stop blocking and the
  `stop_hook_active` re-fire); ADR 0012 (hook latency budget)
- Supersedes: none. Extends ADR 0016's BUG-G2 row, and reverses ADR 0021's "Gate Re-plan has no
  rule", which ADR 0025 reaffirmed.

## Context

Since SW-96 parts 1 and 2, every `/sd:bug` and `/sd:refactor` gate writes a section to
`gate-briefs.md` and records the user's answer on its `Reply:` line. stop-gate read that file for
`type: feature` only. Its one bug rule (BUG-G2) checked for an unfilled `## Reproduction`, refactor
had no rule, and Gate Re-plan had none in any workflow. A session that moved past a bug or refactor
gate without the user's answer was never caught.

Three things make these gates harder than the feature ones:

- **Evidence written before the brief.** Bug Gate 3 fills `## Root cause` and Gate 4 saves
  `failing-test-output.txt` *before* their briefs. Neither can mean "past" its own gate, or a
  session waiting there correctly would be blocked.
- **Answers that loop.** Bug Gate 3a has no forward option (`re-enumerate` and `observe` return to
  Phase 3). Refactor Gate 2's `add tests` leads to Gate 3, which is the coverage decision that
  follows. A reply that sends work elsewhere is an answer, not a refusal.
- **Gates whose only later state is `done`.** Bug Gate 5 and refactor Gate 6 are followed by
  close-out, and spec selection skips `done` specs. The Gate 5/6 suggestions are logged to
  `05-retro.md` before the brief, so that file existing says nothing.

## Decision

`stop-gate` evaluates these rows. Spec selection, output, the loop guard and the opt-in flag are
ADR 0016's. Coverage, the any-pass approval and the parse contract are ADR 0021's, unchanged.

| Rule | Gate | Advanced (any of) | Non-approving tokens |
|---|---|---|---|
| BUG-G1 | Symptom captured | status `approved` or `in-progress`; `03-decisions.md` exists | base |
| BUG-G2 | Reproduction confirmed | as ADR 0016 | base, `partial` |
| BUG-G3a | Hypothesis tree exhausted (checked only when it has a section) | `## Root cause` has no `<<PHASE-3:` token; `04-artifacts/repro/failing-test-output.txt` exists | base |
| BUG-G3 | Root cause confirmed | `failing-test-output.txt` exists; status `in-progress` | base, `dig` |
| BUG-G4 | Failing test confirmed | status `in-progress` | base |
| BUG-G5 | Regression and review | `05-retro.md` has a `## Close-out` section | base, `address` |
| REF-G1 | Spec approval | status `approved` or `in-progress`; `03-decisions.md` exists; `01-plan.md` exists | base |
| REF-G2 | Coverage, Gates 2 and 3 together | `01-plan.md` exists; `02-tasks.md` exists; status `in-progress` | base, `add` |
| REF-G4 | Plan approval | status `in-progress`; a task is `done`; a `04-artifacts/batches/batch-*-tests.txt` exists | base |
| REF-G5 | Tests green per batch | a task is `done`; `04-artifacts/coverage/after-refactor.txt` exists | base, `revert`, `fix` |
| REF-G6 | Holistic review | `05-retro.md` has a `## Close-out` section | base, `address` |
| RP-R\<n> | Gate Re-plan, feature and refactor | `01-plan.md` `## Revisions` has `### R<n>` | base, `revise` |

"Base" is `details`, `refine`, `abort` and a bare `no`. Every other token approves, so `yes`,
`exception <reason>` (refactor coverage), `approve` (Re-plan), `re-enumerate` and `observe`
(Gate 3a) and a reply in the conversation language all count. The feature token lists of ADR 0021
are kept as they are.

1. **No file, no rule.** Without `gate-briefs.md`, none of these rows fire, and BUG-G2 falls back to
   ADR 0016's section check alone, byte for byte.
2. **BUG-G2 has two missing items** in one finding: the unfilled `## Reproduction` and the Gate 2
   reply. The constitution exception logged on the insist path excuses both, since insisting is not
   an option token. The follow-up answer after `partial` is recorded as another `Reply:` line in the
   same section (`commands/bug.md`), which the any-pass rule then reads.
3. **Refactor Gate 3 has no row of its own.** `add tests` at Gate 2 leads to Gate 3, so the
   coverage decision is an approving reply in any Gate 2 or Gate 3 section. The pool is covered
   when its last gate is at or after the brief's first section. `exception <reason>` is the
   approval itself, so the hook does not read the retro for refactor.
4. **Conditional gates.** Gate 3a and Gate Re-plan are checked only when the brief has a section
   for them: nothing on disk says they were due.
5. **Close-out evidence.** Phase 7 of both commands now opens its `05-retro.md` entry with a
   `## Close-out` heading. A turn that stops at close-out's spawned-specs prompt, before status
   `done`, is the stop these rows catch.
6. **Gate Re-plan.** The reader takes the revision number from `^## Gate Re-plan - R([0-9]+)`,
   with or without `(pass <p>)`. A revision numbered below the lowest one with a section predates
   gate briefs and is skipped; with no Re-plan section at all there is no rule. Each unanswered
   revision is one finding, `Gate Re-plan R<n>`, ordered with the gate it sits between.
7. **One reader, labels as data.** The reader takes the workflow's gate labels in order
   (`1 2 R 3` for feature, `1 2 3a 3 4 5` for bug, `1 2 3 4 5 R 6` for refactor). The position is
   the label's rank for coverage. The heading pattern is `^## Gate ([0-9]+[a-z]?)([^0-9a-z]|$)`,
   and a label not in the list is not a gate of that workflow, so `3` and `3a` never collide. A
   further workflow (SW-114) is one entry in the order table, its deny tokens and its rule rows.
8. **Reason.** The closing sentence ADR 0021 added for feature names the spec's own workflow
   (`A /sd:bug gate is evidenced by ...`) and appears whenever the brief was read. The feature text
   is unchanged.

## Alternatives considered

- **The ticket's evidence for bug Gates 3 and 4** (`## Root cause` filled; the failing-test output
  exists). Rejected: both are written before their own brief, so a session waiting at that gate
  would be blocked. They are evidence for the gate before it.
- **`re-enumerate` and `observe` as non-approving at Gate 3a** (the ticket). Rejected: they are the
  only ways forward from 3a, so a correct 3a -> Phase 3 -> Gate 3 run would be blocked.
- **Gate 3 as its own refactor rule.** Rejected: with `add` non-approving at Gate 2, a correct
  `add tests` -> Gate 3 `yes` run would block on Gate 2, and two rows for one decision would report
  one skip twice.
- **Count Gate 5 approvals per batch.** Would catch a session that approves batch 1 and races
  through the rest. Not done here: it needs the `Parallel batch` field parsed, an answer for `solo`
  tasks, and a guard for resumed specs whose early batches predate the brief. It also departs from
  the any-pass rule. A follow-up.
- **No rule for bug Gate 5 and refactor Gate 6.** Rejected for the close-out heading, a one-line
  command change that gives a reachable stop a fixed marker.

## Consequences

- **Fixtures.** 38 new cases in `tests/hooks/fixtures/stop-gate/` (17 bug, 13 refactor, 8 Re-plan,
  two of them feature). No existing fixture changed. Among them: `3` and `3a` replies do not count
  for each other, the exception excuses the brief, `partial` then an acceptance approves, a brief
  that starts at Gate 3 or 5, a revision older than the first Re-plan section, and specs with no
  brief. `scripts/smoke-hooks.*` add twelve cases and a re-fire.
- **The nightly e2e.** Scenarios `13-bug-gate-brief` and `14-refactor-gate-brief` run in
  `examples/fixture-project`, which enables `stopGate`. On a run that records every reply, each
  stop is silent.
- **Latency.** The bug and refactor paths read up to three more small files. Measured in SW-108
  (see CHANGELOG), within the ADR 0012 budgets, which are unchanged.
- **Known limits:**
  - All of ADR 0021's limits hold here: a gate before the brief's first section is not checked, an
    earlier approval still counts after work went back, and a refusal in the conversation language
    approves.
  - Refactor Gate 5 is approved once for every batch: a skip at batch 2 or later is not caught.
  - A run that skips a Re-plan entirely, writing a revision with no section, is caught only when an
    earlier Re-plan section exists.
  - Bug Gate 3a `abort` sets `in-progress` then `done`; a turn that stops between the two edits
    sees BUG-G4's evidence. Both edits are made in one step.
  - A feature brief heading `## Gate 3a` or `## Gate 1b` no longer counts as Gate 3 or Gate 1. No
    workflow writes one.
- **Drift.** The rows restate `commands/bug.md`, `commands/refactor.md`, `sd-replan-loop` and the
  `sd-gate-brief` headings. A change to a gate's options or artifacts there must update both hook
  twins and their fixtures.
