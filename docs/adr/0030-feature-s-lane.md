# ADR 0030: S lane for /sd:feature - one combined approval, bounded discovery, automatic fallback

- Status: accepted
- Date: 2026-10-26
- Source spec: Jira SW-94 (`FEAT-feature-s-lane`, E12 / SW-87)
- Relates to: ADR 0016 (the stop-gate invariant table that hosts the gate evidence rules); ADR 0021
  (stop-gate's `/sd:feature` rules, amended here); ADR 0022 (the outline-first plan, amended here
  for the S lane's status timing and resume rows); ADR 0023 (the lean task format the S lane
  expands to, unchanged); ADR 0002 (the decompose thresholds, which keep governing M and L);
  ADR 0029 (the label-generic brief reader the `## Gate 1+2` heading is parsed by)
- Supersedes: none. Amends ADR 0021's parse contract and FEAT-G1/FEAT-G2 rows by one heading form,
  and ADR 0022's rule that the outline is written after Gate 1.

## Context

A spec estimated `complexity: S` runs the full M/L pipeline: an `sd-code-explorer` impact map
(Phase 2), an architect outline that repeats precedent discovery, and two approval stops (Gate 1
spec, Gate 2 outline) before any code is written. For a one-layer, 2-4 task change the two stops
ask the user to approve the same small change twice, and the impact map is larger than the change.

Three facts shaped the design, each checked against the code:

- **Nothing measures S.** The `S` row of the `sd-spec-templates` rubric is an estimate guideline.
  The measured thresholds (tasks > 8, layers > 2, impact surface > 8, any open question) were
  written for M and L.
- **The "2 Glob/Grep rounds" allowance is not a discovery budget for the outline.** It is step 2 of
  the Pattern refs protocol: per `(new)` task, at expansion, to find a precedent to mirror. The
  architect has no discovery allowance during `create` or `STEP = outline`, and nothing finds the
  callers of a changed symbol without Phase 2.
- **The hooks pair the two gates.** `stop-gate` FEAT-G2 blocks an `in-progress` spec whose
  `gate-briefs.md` has no approved `## Gate 2` section, and `spec-gate` Rule 0b has no
  `draft>in-progress` edge.

## Decision

An S spec takes a shorter lane. M and L, and an S spec that is already `approved` or later, run
exactly as before. The gate count stays 3: the combined approval is a conditional face of Gate 1,
the same pattern Gate Complexity uses on Gate 2, so `contractLint.gates` and `gateBriefs` in the
manifest are unchanged.

1. **Lane entry.** After Phase 1, a spec whose `complexity` is `S` and whose `05-retro.md` has no
   `s-lane: fallback` line runs Phase 1S instead of Gate 1 and Phase 2.
2. **Phase 1S, bounded discovery and outline.** The architect (`TASK = plan`, `STEP = outline`,
   `LANE = s`, no `IMPACT`) runs at most 2 Glob/Grep rounds, covering precedents for `(new)` files
   and dependents of changed existing symbols. It writes `01-plan.md` with a `## Discovery`
   section (about 10 lines) before the `## Outline` table, then measures the outline against the S
   thresholds in `sd-spec-templates`.
3. **Face S of Gate 1.** Inside the one-reply budget, the main thread shows a combined brief:
   what changes, the top 3 decisions of spec and plan ranked together, risk, the outline's task
   table, and the question `(yes / refine <feedback> / details <target> / abort)`. `details` adds
   a `spec` target. The section is headed `## Gate 1+2 - Spec and outline approval (pass <n>)`.
4. **One reply, two Edits.** On `yes`, the main thread appends the `Reply:` line, Edits the spec
   and the index to `approved`, then Edits both to `in-progress`, then runs Phase 3b. There is no
   new status. `draft>in-progress` stays illegal in `spec-gate` Rule 0b, so the metrics log keeps
   `draft>approved` and `approved>in-progress`.
5. **Fallback, automatic.** When the outline breaches an S threshold, the architect writes it under
   `## Outline (S-lane draft)` and returns `STATUS = s-lane-breach` with the measures and a
   `gate: spec` brief. Before any approval is asked, the main thread appends one line to
   `05-retro.md` and presents the ordinary Gate 1; the flow then re-enters the full path
   (Phase 2, Phase 3a, Gate 2) unchanged. No user decision is involved.
6. **stop-gate accepts the combined section.** A `## Gate 1+2` heading opens a section that counts
   for Gate 1 **and** Gate 2. Both twins change; every other rule is untouched.

### S thresholds

Single-sourced in `sd-spec-templates` ("S-lane thresholds"). The outline falls back when **any**
holds:

| Limit | Value |
|---|---|
| tasks | > 4 |
| production layers, excluding `Tests` and `Config` | > 1 |
| surface: production files in the outline's `Files` plus dependents the discovery found | > 4 |
| open questions: any unresolved, including a path in no declared layer and a changed symbol whose callers the 2 rounds could not enumerate | any |

The values are proposals with no corpus behind them: half of M's task and surface limits. They
replace the impact-surface input, which read the Phase 2 map in `03-decisions.md`. `/sd:status
--calibration` reports the fallback count so the numbers can be tuned.

### Fallback line

```text
s-lane: fallback to full path - tasks 6 > 4; layers 2 > 1 (Application, Domain)
```

Clauses, joined by `; `: `tasks <n> > 4`, `layers <n> > 1 (<names>)`, `surface <n> > 4`,
`open questions <n>`. The line has no `escalation:` prefix, so the escalation lines' format and the
e2e assertions on it are not touched. The lane is one-way: the S rows require this line to be
absent, so a later `refine` at the ordinary Gate 1 never re-enters it.

### Resume

Three rows are added to the `/sd:feature` state machine and checked before the rows they refine.
All three require `complexity: S` and no fallback line.

| Condition | State | Action |
|---|---|---|
| `draft`, no `## Outline` in `01-plan.md` | `s-draft` | Phase 1S, then Face S |
| `draft`, `## Outline` present | `s-outline-drafted` | present Face S |
| `approved`, `## Outline`, no `02-tasks.md`, approving `Reply:` in the last `## Gate 1+2` section | `s-approved` | set `in-progress`, Phase 3b |

A crash after `in-progress` resolves on ADR 0022's `outline-approved`. A fallen-back spec is a
plain `draft` spec: its draft outline heading does not match `^## Outline[[:blank:]]*$`, so no hook
and no existing row sees an outline. A crash between the architect's return and the retro line
re-measures at `s-draft` and falls back again.

## Consumers

| Consumer | Change |
|---|---|
| `commands/feature.md` | Face S in Gate 1, Phase 1S, three rows, Phase 2 skipped, Phase 4 passes `IMPACT_REF` only when `03-decisions.md` exists |
| `sd-spec-architect` | `LANE = s` input, discovery budget and `## Discovery`, S measurement, `s-lane-breach` return, `gate: s-lane` brief block |
| `sd-gate-brief` | combined heading, shape, `details spec`, `gate: s-lane` block |
| `stop-gate` (both twins) | `## Gate 1+2` counts for gates 1 and 2, with Gate 1's non-approving tokens |
| `session-context` (both twins) | `draft` + outline hints `open gate: spec and plan approval` |
| `/sd:status --calibration` | counts `s-lane: fallback` lines; a spec with no `03-decisions.md` is tolerated |
| `sd-model-escalation` | a note: the S lane has no Phase 2 or 3a step 0; `ESC-FEAT-02` and `ESC-FEAT-03` read `L`, so neither can fire on an S spec, before or after a fallback; `ESC-FEAT-03b` keys on Gate Complexity and is unaffected |
| `/sd:spec` | none: `SL020` already exempts an `in-progress` outline with no tasks, `draft` requires no artifact, `SL068` needs `02-tasks.md` |
| manifest `gateBriefs`, CL307 | none: Face S sits inside the existing Gate 1 block, with no new gate heading |
| `spec-gate` | none |

## Alternatives considered

- **Two sections, `## Gate 1` and `## Gate 2`, each with a `Reply:` line.** Needs no hook change.
  Rejected: `gate-briefs.md` records what was shown at each pass, so one approval would be recorded
  twice, and the e2e `transcript-contains-section` check would need both bodies printed, which
  doubles the brief and defeats one combined approval.
- **A `draft>in-progress` edge in `spec-gate` Rule 0b.** One Edit instead of two. Rejected: it
  changes both `spec-gate` twins and weakens the invariant for every workflow.
- **A new status between `draft` and `in-progress`.** Rejected: `spec.lifecycle` is
  project-configured and the status is read by every hook, `/sd:spec` and `/sd:status`.
- **Reuse the Pattern refs allowance as the discovery budget.** Rejected: it finds precedents at
  expansion, not dependents at outline, and it is per task.
- **Fall back after the combined approval.** Rejected: the user would have approved an outline the
  workflow then discards. Measuring before presenting costs nothing to unwind.

## Consequences

- An S spec reaches Phase 4 after exactly one approval. Phase 2 and its explorer call are skipped.
- A mis-estimated S spec costs one architect invocation (the S outline), then runs the full path.
  The kept draft outline informs Phase 3a until it rewrites `01-plan.md`.
- **A contract changes on purpose.** ADR 0021's parse contract gains one heading form. Every
  existing `stop-gate` fixture keeps its golden; new fixtures cover the combined section.
- **Known limits:**
  - The surface count uses 2 discovery rounds; a symbol with more dependents than that is treated
    as an open question and falls back, not as a measured surface.
  - A fallen-back spec still reads `complexity: S`, so Phase 2 runs on the default explorer model.
  - `/sd:status` counts both transitions of an S spec, which are one approval.
  - The thresholds are untuned. Re-calibrate from the fallback count before changing them.
  - A legacy S spec still at `draft` takes the lane when next resumed. This is intended.
