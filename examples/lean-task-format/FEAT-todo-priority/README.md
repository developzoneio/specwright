# Lean task format - FEAT-todo-priority

The same feature as `examples/fixture-project/.specs/FEAT-todo-priority/`, re-authored in the
lean 5-core-field task format (ADR 0023). The two trees share one spec
(`examples/fixture-project/.specs/FEAT-todo-priority/00-spec.md`) and one impact map; only
`01-plan.md` and `02-tasks.md` are rewritten here, side by side with the legacy originals.

This directory is a worked comparison for the format change, not a spec in its own right - it adds
no `.specs/index.md` row and nothing elsewhere reads it. The legacy originals are never edited;
`scripts/smoke-hooks.*` asserts they stay byte-identical.

## Line counts

| | `01-plan.md` | `02-tasks.md` | Total |
|---|---|---|---|
| Legacy (11-field, `fixture-project`) | 171 | 234 | 405 |
| Lean (5-core-field, this directory) | 57 | 66 | 123 |

123 of 405 lines is a 70% cut for this feature - well past the ticket's 50% acceptance criterion.
(This single re-authoring is illustrative; the Step 3 size measurement against the SW-88 and
SW-92 baselines is a fresh `/sd:feature` run, not this comparison.)

## What changed

- `Layer`, `Step type`, `Test` and `Conflicts with` are gone from every task block. The witness
  test is named inline in `Acceptance` instead of a separate `Test` field.
- `Estimated complexity` and `Reversibility` appear only on `T03` and `T05` (`M`, the only
  non-default values in this feature) - every other task omits them and reads as `M` / `trivial`.
- `Pattern refs` appears only on `T01`, the one task whose `Files` entry is marked `(new symbol)`
  (it adds `InvalidPriorityError` and `validatePriority`, both reachable from outside the file).
  The other five tasks edit existing files with no new public symbol, so the field is absent -
  not written as `none`.
- `01-plan.md` drops `Phased overview`, `Sequencing rationale` and `Coverage map` as their own
  sections; the critical path is one sentence in `Approach`, and `/sd:verify` computes coverage
  from `Covers` rather than from a hand-written table. The multi-row "Complexity self-assessment"
  becomes the single `Complexity:` line above the `## Outline` table (ADR 0022's outline shape is
  unchanged by this ticket).
- `Acceptance` is capped at 1-3 lines per task, naming the observable outcome and the witness test
  rather than the original's bullet-per-sub-criterion detail. The design rationale that detail
  carried (why a destructuring default, why no re-export) lives in `01-plan.md`'s Design decisions
  and Risks instead of being repeated on every task that touches it.
