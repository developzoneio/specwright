# Outline-agreement fixtures (SW-92)

These fixtures state the contract for the `SL068` outline-agreement check in `/sd:spec validate`
(see `commands/spec.md` -> "Outline checks", the "Outline row" section of
`skills/sd-atomic-task-format/SKILL.md`, and ADR 0022). `/sd:feature` Phase 3a writes a
`## Outline` table into `01-plan.md`, Gate 2 approves it, and Phase 3b expands it into
`02-tasks.md`. The approved outline is immutable, so every block must agree with its row unless a
Gate Re-plan revision says why it does not.

Each case is a directory holding a `01-plan.md` + `02-tasks.md` pair. Like the
`tests/revision-log/` fixtures, these **have no runner**: `SL068` is model-executed prose in
`commands/spec.md`, and no script in this repo parses task blocks. They document the contract for
a human or a future harness, and are pinned to LF via `.gitattributes`.

| Case | Expected result | Rule |
|---|---|---|
| `outline-agrees/` | PASS - both rows have a block, and each block's `Files` and `Covers` sets equal its row's | none |
| `drift-unmarked/` | BLOCK - `T02`'s block adds `src/FeedStream.cs` to its `Files`, carries no `Revised-by`, and `01-plan.md` has no `## Revisions` | `SL068` |
| `drift-revised/` | PASS - the same drift, recorded by Gate Re-plan: `R1` (`Phase: expand`) lists `T02`, and `T02` carries `Revised-by: R1` | none (`SL070`-`SL073` also pass) |
| `row-missing/` | BLOCK - outline row `T02` has no block in `02-tasks.md`, and no revision lists it | `SL068` |
| `marker-ignored/` | PASS - lean blocks (ADR 0023) mark every `Files` entry `(new)` or `(new symbol)`; none of the rows carry a marker, and the sets still agree once it is dropped | none |

Notes for a reader running the check by hand:

- `Files` and `Covers` compare as sets: order, case, whitespace and backticks do not matter. So
  `` `src/Feed.cs`, `tests/FeedTests.cs` `` in the row equals `src/Feed.cs, tests/FeedTests.cs` in
  the block. A trailing `(new)` / `(new symbol)` annotation on a block's `Files` entry is also
  dropped before the comparison (ADR 0023) - `marker-ignored/` is the fixture for that.
- The check runs **only** when `01-plan.md` has a `## Outline` table. A legacy plan, written in one
  step before ADR 0022, has none and is never checked against one - every `tests/revision-log/`
  case is such a plan.
- `drift-unmarked/` is the silent edit that `tests/revision-log/fixtures/README.md` calls invisible
  to a static linter. With an approved outline on disk it becomes visible, because the outline is
  the plan-time snapshot that the revision log alone does not keep.
