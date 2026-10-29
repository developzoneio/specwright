# ADR 0024: Gate brief - /sd:bug gates (rollout pilot)

- Status: accepted
- Date: 2026-10-28
- Source spec: Jira SW-96 (`FEAT-gate-brief-rollout`, E12 / SW-87), part 1 of 5
- Relates to: ADR 0018 (the gate brief artifact); ADR 0019 (`details` targets, language); ADR 0020
  (printed means reply text); ADR 0016 and ADR 0021 (stop-gate invariants);
  `skills/sd-gate-brief/SKILL.md` (the rules)
- Supersedes: none. Extends ADR 0018 decisions 4 and 5 and ADR 0019 decision 1 to `/sd:bug`.
- Extended by: ADR 0029 (stop-gate reads the `/sd:bug` briefs; SW-108)

## Context

After SW-89 only `/sd:feature` presents its gates as a brief. `/sd:bug` still shows raw artifacts
at six gates (1, 2 HARD, 3a conditional, 3, 4, 5) and can narrate `ESC-BUG-*` rule IDs. SW-96
rolls the brief out one workflow per PR; `/sd:bug` is the pilot because its gates differ most
from the feature shape: they confirm evidence (a reproduction, a root cause, a failing test)
rather than approve decisions.

Three facts constrain the design. `sd-debugger` holds no write tool and is shared with `/sd:rca`
and `/sd:perf`, while the main thread already appends every hypothesis tree and verdict to
`03-decisions.md`. Phase 4's failing-test output existed only in chat, so `details` could not
print it verbatim. And `CL307` treats every slash parenthetical in a declared gate block as an
option set, so the Gate 2 prose `(logs / traces only)` would have failed the lint.

## Decision

1. **Per-workflow parts live in the skill.** `sd-gate-brief` gains a `## Per-workflow parts`
   section with a `/sd:bug` part: section headings, the shown lines of each gate (they replace
   lines 1-5 of the generic shape; the 10-line cap, `Risk:`, the question line and the ranking
   still apply) and the `details` targets. `commands/bug.md` reads the skill in Phase 0 and only
   names it at each gate.
2. **Who composes each brief.** Gate 1 comes from a new architect block, `gate: symptom`
   (symptom, expected, severity, affected, decisions, risk), used for a bug spec's `create` and
   `refine`. Gate 5 reuses the `/sd:feature` Gate 3 shape and the reviewer's `gate: review`
   block, which `bug-fix-final` now returns too. The main thread composes Gates 2, 3a, 3 and 4
   from what it already wrote. The debugger is unchanged.
3. **Evidence without `path:line`.** A brief names the input, the observed result and the
   evidence file; the `details` targets (`repro`, `tree`, `H<n>`, `rootcause`, `output`, `fix`)
   print the on-disk text verbatim, with its IDs and line citations. Phase 4 saves the failing
   run's output to `04-artifacts/repro/failing-test-output.txt` so `details output` has a source.
4. **Hypothesis IDs are an allowed handle**, on the same line as their plain statement, like task
   IDs, so `details H2` is something the user can type. Bug severity (`P0`-`P3`) is allowed too.
5. **Every `/sd:bug` gate offers `details`**, HARD Gate 2 included: `details` never approves, so
   it is not an override and `CL305` is unaffected. Gate count stays 5 hard plus `3a`.
   `contractLint.gateBriefs` declares all six labels for both briefs and `details`.

## Alternatives considered

- **Debugger returns a `GATE_BRIEF` block.** Rejected: it adds a skill to an agent shared with
  `/sd:rca` and `/sd:perf` (not in this PR), and its verdicts are already on disk where the main
  thread writes them.
- **Reuse `gate: spec` at Gate 1.** Rejected: its `what-changes` line has no meaning for a bug
  report; the gate approves a description, not a change.
- **No `details` at the HARD Gate 2.** Rejected: the reproduction section is the evidence the
  user is asked to vouch for, and `details` is not an escape hatch.

## Consequences

- `CL307` covers `commands/bug.md`. Two fixtures pin the shapes bug introduced: `3` and `3a` are
  separate labels, and a slash parenthetical in prose counts as an option set
  (`cl307-sub-gate-label`); a HARD gate with descriptive option tokens plus `details`, and a
  question split over two lines, stay silent (`fp-cl307-hard-gate-details`).
- e2e scenario `13-bug-gate-brief` runs `/sd:bug` on a seeded off-by-one in the fixture project
  and asserts the six-gate record (five on the happy path), `Reply:` lines, the transcript
  printout and the absence of internal IDs.
- **No hook change.** stop-gate's `/sd:bug` rules (ADR 0016) do not read `gate-briefs.md`, and
  its feature parser (ADR 0021) runs only for `type: feature`. Follow-up: BUG rules evidenced by
  the brief; the feature heading pattern `^## Gate ([123])` would also match `## Gate 3a`, which a
  BUG rule must separate.
- Follow-ups, all done, which completes SW-96:
  - `/sd:refactor`, part 2 (SW-109, ADR 0025). Gate Re-plan offers `details` (ADR 0025).
  - `/sd:perf`, part 3 (SW-110, ADR 0027).
  - `/sd:rca`, part 4 (SW-111, ADR 0026).
  - `/sd:port`, part 5 (SW-112, ADR 0028).
