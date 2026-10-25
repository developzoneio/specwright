# ADR 0023: Lean task format - five core fields

- Status: accepted
- Date: 2026-10-25
- Source spec: Jira SW-93 (`FEAT-lean-task-format`, E12 / SW-87)
- Relates to: ADR 0001 (introduced `SL060`, the `Pattern refs` WARN this ADR narrows); ADR 0002
  (the decompose thresholds' layer count, which this ADR changes the source of, not the
  thresholds themselves); ADR 0013 and ADR 0014 (the `sd-model-escalation` trigger table, whose
  task-level rows gain an absent-reads-as-default rule); ADR 0017 (`handoff-integrity`'s task-block
  parser, unaffected - see Consumers below); ADR 0022 (the outline-first plan, which this ADR
  reconciles with rather than redesigns)
- Supersedes: none. Narrows `SL060`'s trigger and removes/defaults fields of the 11-field block
  ADR 0001 and ADR 0002 assumed; both ADRs' own decisions (WARN severity, the decompose thresholds)
  are unchanged.

## Context

`sd-atomic-task-format` required 11 fields on every task block: `Files`, `Layer`, `Step type`,
`Test`, `Acceptance`, `Covers`, `Depends on`, `Conflicts with`, `Estimated complexity`,
`Reversibility`, `Pattern refs`. Several of them have exactly one consumer, or none:

- `Step type` repeats information `01-plan.md`'s phase headings already carried, and no rule or
  hook reads its value.
- `Conflicts with` matters only for `/sd:refactor`'s parallel-batch planning; `/sd:feature`,
  `/sd:bug`, `/sd:perf` and `/sd:port` never read it.
- `Layer` existed mainly to count the decompose threshold's layer spread. ADR 0022 already moved
  that count to derive from the outline rows' `Files` at Gate 2, so the task block's own copy
  became a value nothing reads first - `sd-spec-architect` wrote it, `/sd:status --calibration`
  read it, and that was the whole consumer list.
- `Estimated complexity` and `Reversibility` exist to trigger `ESC-FEAT-04`/`04b` and
  `ESC-REF-05`/`05b` (`sd-model-escalation`). Every task wrote them, but only an `L` or a `hard`
  value ever does anything; `M`/`trivial` is inert.
- `Pattern refs` was required on every task (a 2026-07 tightening, ADR 0001's own follow-on),
  including tasks that only edit an existing file and cite nothing.
- `Test` duplicated the witness-test path that `Acceptance` routinely named anyway.

Measured against the only live corpus and this repo's own fixtures: of 11 fields, 5 have a
consumer on every task (`Files`, `Acceptance`, `Covers`, `Depends on`, the `Status` check-off);
the rest are read by one phase, one workflow mode, or nothing at this field's granularity.

ADR 0022 shipped first and changes the baseline this ADR is written against: the `## Outline`
table already carries a lean 4-column shape (`Task`, `Title`, `Files`, `Covers`) for the same
reason - only the fields Gate 2 decides on survive into the approved record. This ADR extends the
same reasoning to the expanded task block, reconciling with ADR 0022 rather than duplicating its
decision: the outline's shape and the resume state machine are unchanged (see Consequences).

## Decision

1. **Five core fields, always present.** `Files`, `Acceptance`, `Covers`, `Depends on`, `Status`.
   A block missing one of the first four is malformed.
2. **Three fields become optional-with-default, written only off their default.**
   - `Pattern refs`: required when a `Files` entry is marked `(new)` (the path does not exist yet)
     or `(new symbol)` (an existing file gains a symbol reachable from outside it) - restoring the
     rule ADR 0001's own follow-on relaxed. Absent reads as `none`.
   - `Estimated complexity`: write only when not `M`. Absent reads as `M`.
   - `Reversibility`: write only when not `trivial`. Absent reads as `trivial`.
   - `Test` folds into `Acceptance`: the witness test is the path named there. A legacy `Test`
     field is still read when present.
3. **Two fields are removed outright: `Layer`, `Step type`.** Neither is authored on a new task.
   A reader derives the layer of a path from `Files` (via `paths.layers`, else the constitution's
   declared layers) instead of reading a copied value.
4. **`Conflicts with` becomes refactor-only**, required there (unchanged shape), absent/ignored
   elsewhere. `Parallel batch` and the port/re-plan conditional fields (`Licensed deviations`,
   `Revised-by`) are unchanged.
5. **`SL060` narrows.** It fires only when a `Files` entry carries a `(new)`/`(new symbol)` marker
   and the block has no `Pattern refs` - not on every task, as the pre-ADR rule read. Severity
   stays WARN (ADR 0001's own test still holds: a missing field leaves the registry truthful and
   is fixed by re-planning).
6. **`SL068`'s `Files`/`Covers` comparison drops a trailing `(new)`/`(new symbol)` annotation**
   before comparing a block to its approved outline row (ADR 0022's immutability check). The
   outline row itself never carries the marker - it is authored only at expansion time.
7. **`VF020`/`VF021` read the witness test from `Acceptance`** (a path-like token) when no legacy
   `Test` field is present.
8. **`sd-model-escalation`'s task-level rows state the absent-reads-as-default rule explicitly**:
   `ESC-FEAT-04`/`ESC-REF-05` fire only on a written `L`; `ESC-FEAT-04b`/`ESC-REF-05b` only on a
   written `hard`. An absent field never fires a row - it was always true that `M`/`trivial` did
   not fire, but the field used to be written out explicitly; now it is also commonly absent, and
   the rule says so instead of leaving it implied.
9. **`01-plan.md` drops `Phased overview` and `Coverage map` as authored sections.** The critical
   path is one sentence in `Approach` (`Depends on` already orders the tasks); `/sd:verify`
   computes coverage from `Covers` rather than from a hand-written table nothing checks against
   it. The multi-row "Complexity self-assessment" becomes one `Complexity:` line. `Sequencing
   rationale` folds into `Approach` for the same reason `Phased overview` drops: with `Step type`
   gone, phase is not a field to narrate sequencing around.

The outline table's own shape (`Task`, `Title`, `Files`, `Covers`), the two-step plan/resume state
machine, and `SL068`'s existence are **ADR 0022's decisions and stay exactly as shipped** - item 6
above is the one place this ADR touches `SL068`, and it is a compatibility fix (a marker the
outline never carries must not read as a divergence), not a redesign of the check.

## Consumers of the removed/optional fields

| Consumer | Change |
|---|---|
| `sd-atomic-task-format` | the task block template, field rules, and anti-patterns rewritten; a "Legacy blocks" section states the 11-field form still reads correctly |
| `sd-spec-architect` | writes the lean block; derives the layer check at Phase 3a (outline) instead of copying `Layer` at Phase 3b (expand); `01-plan.md` structure updated |
| `sd-implementer`, `sd-reviewer` | read the witness test from `Acceptance` (or a legacy `Test`); drop the `Layer`-match self-check (constitution layer discipline, §1.1, is unchanged) |
| `sd-pattern-discipline` | restates the new-file/new-symbol condition for `Pattern refs`, matching `sd-spec-architect`'s own protocol (which this ADR's predecessor had left out of step with the skill) |
| `sd-model-escalation` | `ESC-FEAT-04`/`04b`, `ESC-REF-05`/`05b` conditions state the absent-reads-as-default rule |
| `sd-spec-templates` | the decompose-threshold layer count derives from `Files` when no legacy `Layer` field exists; the copy-into-expanded-block step is removed since there is nothing to copy into |
| `/sd:feature`, `/sd:refactor`, `/sd:port` | describe the lean block at their invocation sites; `/sd:port`'s port-mode complexity rationale no longer cites `Layer` |
| `/sd:spec validate` | `SL060` narrowed to the marker condition; `SL068` drops a marker before comparing `Files` sets |
| `/sd:verify` | `VF020`/`VF021` read the witness test from `Acceptance` as a fallback |
| `/sd:status --calibration` | derives layers from `Files` when a block has no legacy `Layer` field |
| `handoff-integrity` (both hook twins) | **none** - it reads only `Files`, `Depends on`, `Status`, and already strips a trailing `(...)` note from each `Files` entry, so a `(new)`/`(new symbol)` marker was silently compatible before this ADR shipped |
| `stop-gate`, `session-context` | **none** - both read only `Status` and `## Outline` existence, never a task field this ADR touches |
| `spec-gate` | **none** - never parses task blocks |

No hook required a code change. The one `handoff-integrity` behavior this ADR relies on - stripping
a trailing parenthetical from a `Files` entry - predates it (ADR 0017); a new conformance fixture
(`tests/hooks/fixtures/handoff-integrity/silent-lean-new-marker/`) records that reliance rather
than changing the hook.

## Measured

A scratch re-creation of the SW-88 baseline's M and S scenarios (`docs/spikes/SW-88-feature-baseline.md`
Appendix A), re-run through the lean format, plus the matched comparison kept at
`examples/lean-task-format/FEAT-todo-priority/` (the SW-88/SW-92 fixture-project feature, re-authored
by hand to the lean shape without re-running the workflow):

| Metric | SW-88 M (11-field) | SW-92 M (outline, 11-field) | SW-93 M (lean) |
|---|---|---|---|
| `01-plan.md` lines | 157 | 76 | *(see Step 3 run)* |
| `02-tasks.md` lines | 244 | 144 | *(see Step 3 run)* |

| Metric | SW-88 S (11-field) | SW-93 S (lean) |
|---|---|---|
| `01-plan.md` + `02-tasks.md` lines | 88 | *(see Step 3 run)* |

| Metric | Legacy (`fixture-project`) | Lean (`examples/lean-task-format/`) |
|---|---|---|
| `01-plan.md` lines | 171 | 57 |
| `02-tasks.md` lines | 234 | 66 |
| Total | 405 | 123 |

The hand-authored comparison is a 70% cut (123 of 405 lines) for that feature - well past the
ticket's 50% acceptance criterion measured against SW-88. It is illustrative, not the acceptance
measurement itself: a fresh `/sd:feature` run against the SW-88 scenarios is the actual Step 3
proof, recorded in the PR once run.

## Consequences

- A task block authored under this ADR is shorter and carries less dead weight: a `Pattern refs:
  none` line, a `Layer: Application`, a `Step type: behavior` that repeated the phase heading, a
  `Conflicts with: none` that no feature workflow ever reads.
- `sd-implementer` and `sd-reviewer` now treat two shapes as equally valid - the 5-core-field lean
  block and the 11-field legacy block - rather than one canonical shape with a lenient reader for
  drift. This is more surface than a single shape, but it is the same trade-off ADR 0001 already
  made for the field label grammar: a reader that accepts only the new form rejects every spec
  authored before this ADR.
- `/sd:refactor` keeps `Conflicts with` as a required field; `/sd:port` keeps `Pattern refs`
  always required (never `none`). Neither workflow's extra constraints change.
- Not covered: `SL08x` (port-fidelity integrity) has no fixture anywhere, a pre-existing gap this
  ticket does not close, per `examples/spec-lint-fixture/README.md`.
