# ADR 0034: bug Gate 2 says when a reproduction was traced, not run

- Status: accepted
- Date: 2026-11-16
- Source spec: Jira SW-127 (split out of SW-124; E12 / SW-87)
- Relates to: ADR 0024 (the `/sd:bug` gate brief); ADR 0016 and ADR 0029 (the BUG-G2 stop-gate
  row); ADR 0033 (off-option replies); `skills/sd-gate-brief/SKILL.md` (the shown lines)
- Supersedes: none. Extends ADR 0024 decision 1 for the Gate 2 shown lines.

## Context

In the SW-124 verification run of e2e `13-bug-gate-brief` (2026-11-02), the HARD Gate 2 brief said:

```text
Reproduction: confirmed locally by tracing the code path from the todo service into the domain title check; it has not been executed yet, the first run is the Phase 4 test.
```

The scripted `yes` (`yes - I can trigger it`) approved it. Nobody had triggered the bug before
the Phase 4 failing test ran. `commands/bug.md` says "Without reproduction the rest is theater",
but its step 3 says to reproduce "if applicable", so a reproduction read from the code is arguably
allowed.

Four facts shape the answer:

- **A run before any fix is already mandatory.** HARD rule 4 and Gate 4 require a failing test,
  its output saved to `04-artifacts/repro/failing-test-output.txt`, and the user's confirmation
  that it fails as expected, before Phase 5 writes the fix. The stop-gate's BUG-G4 row blocks an
  `in-progress` spec whose Gate 4 section has no approving reply. A traced-only bug that is not
  real fails at Gate 4, and nothing ships. What a traced Gate 2 risks is the Phase 3
  investigation, not the fix.
- **A run at Phase 2 is often impossible.** The spec is still `draft`, so spec-gate in `block`
  mode refuses a test written into the source tree, and Phase 4 is where the test belongs. A
  restricted permission mode may grant only `commands.test`, and the existing suite rarely
  covers the bug. A production-only bug has no local trigger at all. In e2e 13 the only granted
  command was `npm test`, and its suite has no 200-character case.
- **The brief had no honest value.** The skill offered `confirmed locally | intermittent, about
  <n>% | not reproduced`. A traced reproduction fits none of them, so the model wrote
  `confirmed locally` and qualified it in the clause.
- **The reply is the user's confirmation, not the session's.** ADR 0024 already says "the brief
  states what the session ran; the reply is the user's own confirmation". A user may have
  triggered the bug themselves; the e2e 13 report says "It happens every time, locally".

## Decision

1. **Gate 2 keeps its option set.** `yes` still means the user can trigger the bug; it does not
   require a run made by the session. The tokens, the stop-gate deny lists and `contractLint`
   are unchanged.
2. **The brief gains `traced, not run`.** `confirmed locally` needs a run this session made, with
   its output saved under `04-artifacts/repro-evidence/` and named on the `Evidence:` line.
   `intermittent` needs that run or the log evidence Phase 2 step 4 saves there, since an
   intermittent bug is often shown by logs rather than by a run. A reproduction read from the
   code is `traced, not run`. Its `Observed:` line
   says what the code would do, and its `Risk:` line says the first run is the Phase 4 failing
   test. The user then approves on a stated fact, not an unstated assumption.
3. **Phase 2 runs the trigger when it can.** `commands/bug.md` step 3 now runs it through a
   project command or a Reproduction step and saves the output. When nothing can run, it does
   not write a test into the source tree to get one: the first test is Phase 4's.
4. **No stop-gate change.** The hook cannot tell a traced reproduction from a run one without
   reading the brief's prose. The first run is already gated: the BUG-G4 row needs the approving
   Gate 4 reply, given on the saved failing-test output.

## Alternatives considered

- **`yes` requires a saved run; traced goes to a new `traced` option** (or to `partial`).
  Rejected. It changes the token set in both stop-gate twins, their fixtures, the CL305/CL306
  checks and ADR 0029's table, for a risk Gate 4 already bounds. It would refuse every
  production-only bug and every run under a posture that grants only the test command, which
  includes e2e 13. `partial` already means intermittent, and overloading it would blur the
  record.
- **Record no change.** Rejected. The behavior was defensible, but the brief's value list forced
  a misleading `confirmed locally`, and the user should not have to read the clause to learn
  nothing was run.

## Consequences

- A user who answers `yes` to a `traced, not run` brief is vouching for the trigger themselves.
  That is the same trust Gate 2 always placed in the reply, now stated where they read it.
- The value is not machine-checked. Asserting it in e2e 13 would read model wording in a gate
  line, which `tests/e2e/README.md` keeps to the `transcript-*` exceptions. The scenario's
  existing assertions still cover the Gate 2 section and the Gate 4 evidence.
- `templates/specs/bug.template.md` keeps its `Reproduction rate` field; the new value lives in
  the brief only.

## Revisit when

- A live run shows a traced-only Gate 2 sending Phase 3 down a non-bug often enough to cost more
  than the re-ask a separate option would add.
- The stop-gate gains a way to read the brief's structured lines, so a `traced, not run` value
  could be checked against the `Evidence:` line.
