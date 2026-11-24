# ADR 0036: Stop close-out gate - /sd:port Gate 5 is approved once per batch

- Status: accepted
- Date: 2026-11-24
- Source spec: Jira SW-133 (`FEAT-stop-gate-port-batch-count`, E12 / SW-87)
- Relates to: ADR 0032 (the PORT-G5 row, its any-pass rule 6 and its known limit); ADR 0035 (the
  same count for `/sd:refactor` Gate 5, and the section counter it added); ADR 0021 (the any-pass
  approval and the parse contract); ADR 0012 (hook latency budget)
- Supersedes: none. Extends ADR 0032's PORT-G5 row and lifts its known limit "Any-pass across
  repeats" for port Gate 5.

## Context

`/sd:port` stops at Gate 5 after every batch, and each stop writes a new `## Gate 5` section to
`gate-briefs.md`. ADR 0032 checks PORT-G5 with the any-pass rule: one approving reply in any Gate 5
section satisfies the gate. A session that answers `continue` for batch 1 and then runs batches 2
and later without stopping is not caught. ADR 0035 closed that gap for `/sd:refactor` and left port
as a follow-up, because port's batch flow differs in two ways:

- **Done tasks are not evidence.** `commands/port.md` Phase 7 step 5 checks each task off *before*
  the batch's Gate 5, so a done task does not show that its batch passed the gate. Refactor checks
  off only on `yes`.
- **No batch field.** Port tasks have no `Parallel batch` field. A batch is the set of tasks whose
  `Files` name one `Host path`, and batches run in path-mapping row order.

One signal carries over unchanged: Phase 7 step 6 saves
`04-artifacts/batches/batch-<n>-tests.txt` after batch `n` runs and *before* its Gate 5. A
`revert batch` retry re-runs the same batch, so it rewrites the same file and adds no new `<n>`.

ADR 0032 also gives PORT-G5 a single piece of later-phase evidence, `04-artifacts/parity/INDEX.md`,
which only Phase 8 writes. During Phase 7, a port run that never stops at Gate 5 at all is
therefore not caught either.

## Decision

PORT-G5 keeps its ADR 0032 checks. When the brief records Gate 4, it also compares two numbers:

| Term | Meaning |
|---|---|
| approved | `## Gate 5` sections holding at least one approving reply. A section counts once, however many replies it records (the counter ADR 0035 added) |
| tested | distinct numeric `<n>` among `04-artifacts/batches/batch-<n>-tests.txt` |
| finished | tested, once `04-artifacts/parity/INDEX.md` exists; otherwise tested minus one |

The rule fires when finished is greater than approved.

- **Some Gate 5 approves.** The finding's missing item is "an approving Reply: line in a ## Gate 5
  section of gate-briefs.md for every finished batch (<a> approved, <f> finished)", and its
  evidence adds "04-artifacts/batches/ holds test output for <t> batches".
- **No Gate 5 approves.** ADR 0032's item already names the gate. The test output is added as
  evidence only when nothing else is, so a run in Phase 7 that never stopped at Gate 5 is caught
  and the existing findings keep their text.

1. **Only after Gate 4 is recorded.** As in ADR 0035: the run that planned the batches wrote Gate
   4's section, so every batch since has a Gate 5 section to count. A brief that starts at Gate 5
   or later keeps the any-pass rule.
2. **The newest batch may be waiting.** Its test output is saved before its gate, so it does not
   count as finished until Phase 8 has written `parity/INDEX.md`. From then on no batch is waiting,
   so the last batch counts too.
3. **Re-passes.** `revert` (from `revert batch`), `details`, `abort` and `unrecognized` are
   non-approving for port Gate 5, so a red section does not count. The retried batch adds one
   approving section and no new `<n>`. A Gate 6 resolution (`revert-to-snapshot`,
   `add-deviation`) routes hunks back without saving batch test output, so it does not change the
   count.
4. **Done tasks are not read.** A batch whose tasks are all done and whose test output exists is
   only at its gate, so done tasks add nothing that the test output does not already show.
5. **Parse contract.** Only the file names of `04-artifacts/batches/` are read, never their
   content. `gate-briefs.md` is still read for headings and `Reply:` lines only.

## Alternatives considered

- **Done tasks as a signal**, as ADR 0035 uses for refactor. Rejected: port checks tasks off before
  Gate 5 (rule 4).
- **The ADR 0035 guard "only once some Gate 5 approves".** Rejected for port. In refactor it avoids
  repeating ADR 0029's finding, which a done task already triggers. In port, nothing triggers
  PORT-G5 during Phase 7, so the guard would leave a run that never stops at Gate 5 uncaught until
  Phase 8.
- **Always count the newest test file.** Rejected: a run waiting at batch `n`'s gate would be
  blocked. Counting it once `parity/INDEX.md` exists is safe, because Phase 8 starts only after the
  last batch's gate.
- **Batch identity from the brief body**, matching `Batch <n> of PORT-<slug>` lines to batches.
  Rejected for the reason ADR 0035 gives: it widens the parse contract to model-written body lines.

## Consequences

- **Fixtures.** Eight new cases in `tests/hooks/fixtures/stop-gate/`: three batches with one
  approval, a run waiting at batch 2, `revert batch` then `continue`, a `revert batch` that does not
  count, a brief that starts at Gate 5, a run that never stopped at Gate 5, the last batch skipped
  before Phase 8, and every batch approved. No existing fixture changed.
  `scripts/smoke-hooks.*` add three cases each.
- **Latency.** The port path lists `04-artifacts/batches/` once more, only when the brief records
  Gate 4. Measured in SW-133 (see CHANGELOG), within the ADR 0012 budgets, which are unchanged.
- **Known limits:**
  - A skipped Gate 5 whose next batch never saves test output leaves no trace.
  - The last batch's gate is checked by the count only once Phase 8 writes `parity/INDEX.md`.
  - An approval recorded for the wrong batch still counts: sections are counted, not matched to
    batches.
- **Drift.** The rule restates `commands/port.md` Phase 7 (test output saved before Gate 5,
  check-off before the gate) and Phase 8 (`parity/INDEX.md`). A change to either must update both
  hook twins and their fixtures.
