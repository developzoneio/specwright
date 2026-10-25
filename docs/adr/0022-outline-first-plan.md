# ADR 0022: Outline-first plan for /sd:feature

- Status: accepted
- Date: 2026-10-25
- Source spec: Jira SW-92 (`FEAT-outline-first-plan`, E12 / SW-87)
- Relates to: ADR 0002 (complexity triage and the decompose thresholds, now measured on the
  outline); ADR 0003 (the Gate Re-plan protocol, which gains a Phase 3b entry point); ADR 0013 and
  ADR 0014 (model escalation rows `ESC-FEAT-03` / `ESC-FEAT-03b`, whose IDs are unchanged); ADR 0018
  and ADR 0019 (the Gate 2 brief and its `details` targets); ADR 0021 (stop-gate's `/sd:feature`
  rules, which gain one piece of Gate 2 evidence)
- Supersedes: none. Changes what `ESC-FEAT-03b` escalates: the expansion, not a re-run of the plan.

## Context

Before this ADR, `/sd:feature` Phase 3 wrote the whole plan in one invocation - `01-plan.md` and
every 11-field task block in `02-tasks.md` - and only then measured it against the decompose
thresholds. SW-88's medium run (`docs/spikes/SW-88-feature-baseline.md`, 6 tasks) spent 146 s in
Phase 3 and wrote 244 lines of `02-tasks.md`, while Gate 2 carried 3 real decisions. Two costs
follow:

- **Gate 2 approves the wrong artifact.** The user decides on the approach, the task partition and
  any decompose. The `Pattern refs`, `Acceptance` and `Reversibility` detail of each block arrives
  before those decisions, and none of it is needed to make them.
- **Gate Complexity throws work away.** When Face B approves a split, the parent's full task list
  is written, measured, and then left unused as an immutable record.

## Decision

Phase 3 becomes two steps. Gate count stays 3: Gate Complexity is still a face of Gate 2, and
Phase 3b adds no gate.

1. **3a Outline.** `sd-spec-architect` (`TASK = plan`, `STEP = outline`) writes `01-plan.md`:
   approach, alternatives, rationale, risks, and a `## Outline` table - one row per task with its
   ID, title, `Files` and `Covers` (format owned by `sd-atomic-task-format`, "Outline row"). It
   writes no `02-tasks.md`. Complexity triage runs on the outline: row count, production layers
   derived from the rows' `Files` (via `paths.layers`, else the constitution's layers, excluding
   `Tests`/`Config`), impact surface, open questions.
2. **Gate 2 approves the outline**, both faces. The brief's task rows come from the outline, and
   decompose is decided here, before any full task block exists. `details <task ID>` prints the
   task's outline row until `02-tasks.md` exists, so it never points at a missing file.
3. **3b Expand.** After approval, the architect (`STEP = expand`) expands every row into a full
   task block, keeping its ID, title, `Files` and `Covers`, and writes `02-tasks.md` in a single
   Write. The approved outline is immutable. A material divergence - a different `Files` or
   `Covers` set, a split, merged, dropped or missing task - goes through the existing Gate Re-plan
   with `Phase: expand`, never a silent edit.
4. **Status becomes `in-progress` at the Gate 2 approval**, as before, so Phase 3b runs on an
   `in-progress` spec. That keeps Gate Re-plan (which runs only on `in-progress` specs) reachable
   from 3b, and keeps "expanded after approval" distinguishable from "expanded before it" without
   reading `gate-briefs.md`.
5. **Two new resume states.** `outline-drafted` (`approved`, `## Outline`, no `02-tasks.md`)
   presents Gate 2. `outline-approved` (`in-progress`, `## Outline`, no `02-tasks.md`) runs 3b. A
   legacy spec never has `## Outline`, so every legacy layout resolves to the state it resolved to
   before.
6. **Escalation, IDs unchanged.** `ESC-FEAT-03` (spec sized `L`) escalates the 3a outline, where
   the planning decisions are made. `ESC-FEAT-03b` escalates the 3b expansion of an outline
   approved through `no-split`. It no longer re-runs the plan: that would rewrite the outline the
   user had just approved.

The outline lives in `01-plan.md`, not in a new file. `01-plan.md` is already the approved,
append-only plan record, and its `## Revisions` log is where a divergence from the outline is
recorded, so the two sit side by side. A separate file would add a spec artifact to the manifest,
validate and the docs, and a third file to keep immutable. Its one advantage - "the file exists"
as a signal - costs a single heading match instead.

## Consumers of "02-tasks.md exists"

| Consumer | Change |
|---|---|
| `commands/feature.md` state machine | the two rows above; legacy rows unchanged |
| `stop-gate` FEAT-G1 | none: every outline state is already `approved` or later |
| `stop-gate` FEAT-G2 | new advancement evidence: `01-plan.md` has `## Outline` and `02-tasks.md` exists. A plan expanded while Gate 2 is unanswered is now blocked. Legacy plans have no outline and are unaffected |
| `session-context` phase hint | `approved` + outline -> `open gate: plan approval`; `in-progress` + outline, no tasks -> `plan approved - expanding tasks` |
| `handoff-integrity` | none: it needs `02-tasks.md`, so it is silent during 3b, which has no ready set |
| `spec-gate` Rule 3 | none: an `in-progress` spec allows code edits during 3b, as during Phase 4; 3b writes only under `.specs/` |
| `/sd:status` | none: `--calibration` reads `02-tasks.md` as data, never as a phase signal |
| `/sd:spec` | `show` reports an unexpanded outline; `SL020` exempts `02-tasks.md` for an `in-progress` feature with an outline; new `SL068` (BLOCK) checks blocks against the approved outline |
| `/sd:verify` | none: it runs at close-out, after 3b |

`SL068` claims the last-but-one reserved slot of the task-block band. It makes one silent edit
visible that the `## Revisions` integrity rules cannot see (ADR 0003): a block that diverges from
the approved outline with no `Revised-by` marker. It runs only when `## Outline` exists, so it
never fails a legacy spec.

## Measured

The SW-88 medium scenario (`90-spike-feature-m`, Appendix A of the baseline note, scratch, not
committed), re-created and run with the multi-turn gate replies of SW-103 on 2026-10-25 (`claude`
2.1.306, subscription auth). Phase times use SW-88's definition: the gap between phase narration
markers in the kept transcript.

| Metric | SW-88 M (before) | SW-92 M (after) |
|---|---|---|
| Phase 3 total, Phase 3 marker to Phase 4 marker | 146 s | 106 s |
| - 3a outline (architect returns) | - | 41 s |
| - Gate 2 (brief written and printed, reply recorded) | - | 20 s |
| - 3b expansion | - | 45 s |
| `01-plan.md` lines | 157 | 76 |
| `02-tasks.md` lines | 244 | 144 |
| Task count | 6 | 6 |
| Whole run | 634 s, $2.25 | 583 s, $1.76 |

The expansion kept every outline row's ID, `Files` and `Covers`, so no Gate Re-plan fired.
Scenario `12-resume-outline-complexity` shows the Gate Complexity face presented with no
`02-tasks.md` on disk. These are single runs, not distributions.

## Consequences

- Gate 2 no longer waits for full task blocks, and a decomposed parent never has them written.
- Phase 3 costs two architect invocations instead of one. The expansion re-reads the spec and
  impact map, but it no longer decides anything, so a divergence there is rare and goes through
  Gate Re-plan.
- Between Gate 2 and the end of 3b, a spec is `in-progress` with no task list. Hooks treat that
  state explicitly (table above), and `/sd:spec validate` treats it as legal.
- `/sd:refactor` is unchanged. A `TASK = plan` invocation without `STEP` still plans in one step.
- Not covered: Phase 6's "uncovered criterion -> back to Phase 3" path still predates the
  outline. Adding a task after Gate 2 should go through Gate Re-plan; that is left as a
  follow-up.
