# ADR 0027: Gate brief - /sd:perf gates

- Status: accepted
- Date: 2026-10-29
- Source spec: Jira SW-110 (`FEAT-gate-brief-rollout`, SW-96 part 3 of 5, E12 / SW-87)
- Relates to: ADR 0018 (the gate brief artifact); ADR 0019 (`details` targets, language); ADR 0020
  (printed means reply text); ADR 0024 (the `/sd:bug` pilot); ADR 0025 (the `/sd:refactor` gates);
  ADR 0026 (the `/sd:rca` gates); `skills/sd-gate-brief/SKILL.md` (the rules)
- Supersedes: none. Extends ADR 0024 decisions 1, 2, 3 and 5 and ADR 0025 decision 4 to `/sd:perf`.

## Context

After SW-96 part 4, `/sd:feature`, `/sd:bug`, `/sd:refactor` and `/sd:rca` present their gates as
briefs. `/sd:perf` still displays raw artifacts at its eight HARD gates and can narrate
`ESC-PERF-04` and `ESC-PERF-04b`.

Three facts set it apart. What a gate shows is mostly measured numbers, and a model that writes them
from memory of the run is the failure the artifact exists to prevent. Gates 3 to 6 repeat per
hotspot and per attempt, so one run yields many passes. And the command had no file for the test
output of an attempt or for the final run, so `details` had nothing to print at Gates 5 and 7.

## Decision

1. **A `/sd:perf` part in the skill.** `sd-gate-brief` "Per-workflow parts" gains section headings,
   shown lines and `details` targets for Gates 1-8. The shapes are reused by reference: Gate 1 is
   the spec-approval shape, Gate 5 the two-face pattern of `/sd:refactor`, Gate 8 the review shape.
   New lines exist only for baseline against target (`Baseline`, `Target`, `Gap`, `Spread`, `p95`,
   `Noise`, `Final`), the hotspot list, and keep-or-revert per hypothesis with its measured delta.
   `Method:` at Gate 1 is the one line that is not in those groups: the gate approves the
   methodology.
   `commands/perf.md` reads the skill in Phase 0 and only names it at each gate.
2. **Who composes each brief.** Gate 1 reuses the architect's `gate: spec` block, with `Target:`
   and `Method:` read from the spec. Gate 8 reuses the reviewer's `gate: review` block, which
   `perf-final` now returns as `bug-fix-final` does. The main thread composes Gates 2-7 from what it
   already wrote. `sd-debugger` is unchanged: it also serves `/sd:bug` and `/sd:rca`.
3. **Measured numbers come from the saved file.** A brief reads each figure, with its unit and run
   count, from the artifact when the section is written. A debugger estimate (a hotspot share, an
   expected gain) is labelled as one. `Spread` is the noise floor Gate 6 compares against, so the
   baseline and attempt files hold each run's figures as well as the summary.
4. **Three new saves.** Phase 4c writes `04-artifacts/attempt-<N>-tests.txt`; Phase 5 writes
   `final-tests.txt` and `final-<ts>.json`. `N` is the number of the attempt's Results-log row,
   assigned when the attempt is applied, so a red attempt has a name before its row is complete.
5. **Hypothesis IDs.** A hotspot is `H<n>`, a hypothesis for it `H<n>` plus a letter (`H1a`),
   numbered by the main thread in the debugger's order. The command already used `<H#a>`; the skill
   now states it and counts both forms as allowed handles beside their plain statement.
6. **Two faces where the next step differs.**
   - Gate 2 keeps its two cases; its Case A prose and the `CL305` allow comments are unchanged, and
     only `details <target>` joins the question lines.
   - Gate 5 gets Face A (green) and Face B (red). The revert is still immediate and unconditional;
     what changes is that the gate then waits for `continue` instead of falling through to Gate 4.
   - Gate 6 keeps its Case A and Case B. `keep-with-reason` is the logged constitution exception,
     as `exception <reason>` is at `/sd:refactor` Gate 2; it is not an `overrideOptionTokens` entry.
7. **Seven `details` targets.** The bare `details`, `target`, `hotspots`, `H<n>` / `H<n><x>`,
   `results`, `measurement` and `output`. `measurement` prints the raw file of the section's gate
   (baseline, attempt, final) so one target serves three gates. `details` never approves, so it is
   not an override, and `CL305` is unaffected.
8. **Every `/sd:perf` gate offers `details`.** Gate count stays 8, there is no conditional gate.
   `contractLint.gateBriefs` declares labels `1` to `8` for both briefs and `details`.

## Alternatives considered

- **Debugger returns a `GATE_BRIEF` block** for Gates 3 and 4. Rejected for the reason ADR 0024
  gave: its hotspots and hypotheses are already on disk where the main thread writes them.
- **A `gate: target` architect block at Gate 1.** Rejected: the target and methodology are
  spec-approval material, and `gate: spec` already carries the decisions the architect took alone.
- **Keep the automatic revert-and-loop at a red Gate 5.** Rejected: a gate that does not stop is not
  presented, and the user would never see that an attempt broke tests.
- **One `details` target per measurement file** (`baseline`, `attempt`, `final`). Rejected: each is
  offered at one gate, so one target resolved by the gate is shorter for the user to remember.

## Consequences

- `CL307` covers `commands/perf.md`. The shapes it meets are pinned by existing fixtures: the
  two-face HARD gate, the question split over two lines and the HARD gate with descriptive tokens
  plus `details`, so no fixture is added.
- e2e scenario `16-perf-gate-brief` runs `/sd:perf` on a seeded quadratic de-duplication in the
  fixture store, with one hotspot and one hypothesis, and reaches all 8 gates on the happy path. It
  asserts the 8 sections, the `Reply:` lines, the transcript printout, the saved measurements and
  test output, and the absence of internal IDs in the file and in every assistant text block.
  - **Not reached by the run**, covered by the lint only: Gate 2 with the baseline already at the
    goal, the red face of Gate 5, Gate 6 within noise, the `Already reverted` line of Gate 4, a
    second hotspot, and the narration of the two escalation rules.
- **No hook change.** stop-gate's `PERF-G2` rule reads `00-spec.md` and `04-artifacts/baseline-*`,
  which are unchanged. Follow-up: PERF rules evidenced by the brief, with the BUG, REF and RCA rules
  (SW-108).
- Follow-ups: `/sd:port` (SW-96 part 5); an e2e variant that forces a red attempt or a
  within-noise gain.
