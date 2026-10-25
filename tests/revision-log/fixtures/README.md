# Revision-log integrity fixtures (SW-14)

These fixtures state the contract for the `SL070`-`SL073` revision-log integrity checks in
`/sd:spec validate` (see `commands/spec.md` -> "Revision-log integrity", and the `sd-replan-loop`
skill). The checks are **cross-artifact**: the append-only `## Revisions` log lives in `01-plan.md`,
its `Revised-by: R<n>` markers live in `02-tasks.md`, and the two must agree in both directions.

Each case is a directory holding a `01-plan.md` + `02-tasks.md` pair - the minimum a cross-artifact
check needs. Like the `tests/task-format/` fixtures, these **have no runner**: they document the
contract for a human or a future harness, and are pinned to LF via `.gitattributes` so a byte- or
line-sensitive reader agrees on every platform. They are deliberately not silently skipped - the
absence of a runner is recorded here, not hidden.

| Case | Expected result | Rule |
|---|---|---|
| `valid-revision/` | PASS - one contiguous, well-formed `R1` entry; `T02` marked `Revised-by: R1`; symmetry holds both ways | none |
| `dangling-marker/` | BLOCK - `T02` carries `Revised-by: R1` but `01-plan.md` has no `## Revisions` entry at all | `SL070` |
| `one-sided/` | BLOCK - `R1` lists `Affected tasks: T02` but `T02` carries no `Revised-by: R1` marker | `SL071` |
| `broken-history/` | BLOCK - revisions jump `R1` -> `R3` (a gap); the log was not appended contiguously | `SL072` |
| `lean-revision/` | PASS - the same shape as `valid-revision/`, authored in the lean 5-core-field format (ADR 0023): `T02` writes no `Pattern refs` and still places `Revised-by: R1` directly before `Status` | none |

Notes for a reader running the check by hand:

- The checks fire **only** because a `## Revisions` section or a `Revised-by` marker is present. A
  spec with neither - the common never-re-planned case - produces no `SL07x` finding.
- `valid-revision/` is the byte-intact-original-plan proof: the plan prose above `## Revisions` is the
  original text, and the revision is appended below it, not woven in.
- These fixtures cannot demonstrate the boundary the ADR is honest about: an **unmarked** silent edit
  (no `Revised-by`, no `## Revisions` entry) is invisible to a static linter and is prevented by the
  HARD Gate Re-plan, not by `SL07x`. There is no fixture for it because there is nothing for the lint
  to find.
