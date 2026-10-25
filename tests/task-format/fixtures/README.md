# Task-block field-grammar fixtures

Conformance fixtures for the **Field label grammar** section of
`skills/sd-atomic-task-format/SKILL.md`.

**These fixtures have no automated runner.** `SL060` lives in `commands/spec.md` as
model-executed prose, and no script in this repo parses task blocks, so
`scripts/validate.{ps1,sh}` cannot exercise them. They are a *conformance contract*, not a CI
check - read them, and any reader of `02-tasks.md` must agree with the expectations below.
Wiring them to a real script is deliberately out of scope (see
`_bmad-output/SW-11-implementation-plan.md` section 5).

## Why these three label forms

Each is taken from a real spec in the only live corpus running specwright
(`asian-sportsbook-v2`, 29 tasks across 4 specs). All three occur in production; a reader built
against the canonical form alone would reject 22 of the 29 tasks - i.e. the two best-authored
specs.

| Fixture | Form | Seen in |
|---|---|---|
| `canonical-labels.md` | `- **Files**: v` | `FEAT-ASF-245` |
| `plain-labels.md` | `- Files: v` | `FEAT-ASF-251` |
| `colon-inside-emphasis.md` | `- **Files:** v` | `FEAT-ASF-251-LeagueContainer` |
| `missing-pattern-refs.md` | canonical, `(new)` `Files` marker, `Pattern refs` absent | negative case |
| `checkoff-canonical.md` | `Status` check-off marker in all three label forms | SW-71 |
| `checkoff-drift.md` | heading-prefix and unknown-value markers | SW-71 negative case (SW-61 e2e run) |
| `lean-canonical.md` | the lean 5-core-field block (ADR 0023): one `(new)` task with `Pattern refs`, one edit-only task without it | SW-93 |
| `lean-edit-no-refs.md` | an edit-only task, no `Files` marker, no `Pattern refs` field | SW-93 negative case |
| `lean-optional-fields.md` | `Estimated complexity`/`Reversibility` written only when non-default (`L`/`hard`), absent on the other task (`M`/`trivial`) | SW-93 |
| `lean-test-in-acceptance.md` | `Covers` != `none`, no `Test` field, witness test path named in `Acceptance` | SW-93, VF020 |
| `lean-no-test.md` | `Covers` != `none`, no `Test` field, no path-like token in `Acceptance` | SW-93 negative case, VF020 |

The first three are the 11-field legacy shape (ADR 0001); the `lean-*` fixtures are the 5-core-field
shape ADR 0023 introduced. Both shapes are first-class: a reader must parse both identically to
their own rules, since legacy `.specs/` folders keep working unchanged.

## Expectations

1. **The first three legacy fixtures parse identically.** Same 11 fields, same values. Label form
   is presentation, never meaning.
2. **`colon-inside-emphasis.md` proves value extent.** Its `Acceptance` and `Pattern refs` are
   multi-line with nested sub-bullets. A reader that stops at the first newline truncates both -
   it must return the full value, up to the next field label.
3. **`missing-pattern-refs.md` and `lean-canonical.md`'s T01 are the SL060 positive cases.** Each
   has a `Files` entry marked `(new)` and no `Pattern refs` field. `/sd:spec validate` must report
   exactly one `SL060` (WARN) against each - and must report **no** `SL060` against any other
   fixture, including `lean-edit-no-refs.md` and `lean-canonical.md`'s T02, neither of which
   carries a `(new)`/`(new symbol)` marker.

Expectation 3 is the one that matters: a check that never fires is the failure mode this repo
has already shipped once (see SW-20, where `selftest-docs` hardcoded a count and silently stopped
biting). If a change makes either positive case pass clean, or either negative case fire, the
check is broken - not the fixture.

## Check-off marker expectations (SW-71)

These apply the **Check-off marker** section of the same skill. The first four fixtures above
have no `Status` line and a plain heading, so every task in them reads as **unchecked (legacy)**
with **no** `SL067`.

| Fixture | Task | Reads as | `SL067` |
|---|---|---|---|
| `checkoff-canonical.md` | T01 `- **Status**: done` | checked | no |
| `checkoff-canonical.md` | T02 `- Status: OPEN` | unchecked | no |
| `checkoff-canonical.md` | T03 `- **Status:** Done` | checked | no |
| `checkoff-drift.md` | T01 `### [x] T01`, no `Status` | checked (drift fallback) | yes |
| `checkoff-drift.md` | T02 `### ✅ T02`, no `Status` | checked (drift fallback) | yes |
| `checkoff-drift.md` | T03 `- **Status**: complete` | unchecked (unknown value) | yes |
| `checkoff-drift.md` | T04 `### [x] T04` plus `- **Status**: open` | unchecked (`Status` wins) | yes |

`checkoff-canonical.md` must lint clean: label form and value case are presentation. The
`checkoff-drift.md` rows are the forms real model runs invented before the marker was defined. A
reader that reads T01/T02 there as unchecked re-runs finished work. A reader that lets the T04
heading override its `Status` line has two sources of truth.

## VF020/VF021 expectations (SW-93)

`commands/verify.md`'s witness-test parsing reads a task's legacy `Test` field when present, else
a path-like token in `Acceptance`. `lean-test-in-acceptance.md`'s T01 has `Covers: AC-1` and no
`Test` field, but its `Acceptance` names `tests/todo-service.test.js` - VF020 must pass and VF021
must find that path. `lean-no-test.md`'s T01 has `Covers: AC-1` and no path-like token anywhere -
VF020 must report exactly one BLOCK against it.
