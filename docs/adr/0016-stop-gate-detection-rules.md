# ADR 0016: Stop close-out gate - skipped HARD gates are detected as on-disk invariants

- Status: accepted
- Date: 2026-09-27
- Source spec: Jira SW-69 (`FEAT-stop-gate`, E11 / SW-65)
- Relates to: ADR 0015 (hook event behaviour - chose a command hook for SW-69); ADR 0012 (hook
  latency budget); SW-51 (rca Gate 2 could run on an empty hypothesis tree); SW-44 (why gate
  markers are not parsed out of command markdown)
- Supersedes: none

## Context

Phase gates are prose instructions to the main thread. A model can drift past one, and nothing
catches it until someone runs `/sd:verify` or `/sd:spec validate` - which a model that skipped the
gate will also skip. ADR 0015 established that a `Stop` hook can refuse to end a turn, and chose a
**command** hook that reads gate state from `.specs/` over a prompt hook that can only judge the
transcript.

That leaves the question this ADR answers: what on disk says a HARD gate was skipped?

- **There is no phase field.** Spec frontmatter carries `status`, not a phase or a gate
  (`commands/spec.md`, "known blind spot"). `/sd:spec validate` asserts nothing about
  `<<PHASE-N: ...>>` tokens while a spec is `in-progress`.
- **Status alone cannot tell gates apart.** rca stays `draft` through Gate 2 and Phase 3; perf
  stays `approved` from Gate 1 to Gate 3; bug stays `approved` from Gate 2 to Gate 4.
- **Parsing gate headings out of the command files is brittle** (SW-44), and a hook cannot see
  which gate the model presented anyway.

## Decision

`stop-gate` evaluates a fixed table of **invariants**. Each rule pairs one HARD gate with:

- **advanced** - on-disk evidence that the workflow is past the gate (a status the gate sets, or
  an artifact a later phase writes), and
- **missing** - the gate's own evidence absent (an unfilled section, a missing artifact).

A rule fires only when both hold. A spec sitting *at* a gate - evidence not yet written, nothing
later written either - never fires, so a workflow in progress is never blocked for being in
progress.

| Rule | Gate | Advanced (any of) | Missing (any of) |
|---|---|---|---|
| BUG-G2 | `/sd:bug` Gate 2 - Reproduction confirmed | status `approved` or `in-progress`; `03-decisions.md` exists | `## Reproduction` still holds an author-fill `<<...>>` token - unless `05-retro.md` logs a constitution exception for reproduction (`bug.md`'s insist path) |
| PERF-G2 | `/sd:perf` Gate 2 - Baseline measured | status `in-progress`; `03-decisions.md` exists; `## Hypothesis tree` has no `<<PHASE-3:` token; a Results log row numbered 1 or higher | no `04-artifacts/baseline-*` file; no Results log row 0; `## Target` still holds `<<PHASE-2:` |
| RCA-G2 | `/sd:rca` Gate 2 - Hypotheses enumerated (SW-51) | status `approved` or `in-progress`; `## Root cause` has no `<<PHASE-3:` token | `## Hypothesis tree` still holds `<<PHASE-2:` |
| PORT-G1 | `/sd:port` Gate 1 - Donor set frozen | status `approved` or `in-progress`; `02-tasks.md` exists | no `04-artifacts/source/MANIFEST.md`; the `**Frozen**:` line does not say `yes` |
| PORT-G2 | `/sd:port` Gate 2 - Fidelity tables complete | status `approved` or `in-progress` | the spec body still holds an author-fill `<<...>>` token |
| PORT-G3 | `/sd:port` Gate 3 - Behavior pinned | `02-tasks.md` exists | `03-decisions.md` has no `## Behavior pinning` section |
| PORT-G6 | `/sd:port` Gate 6 - Justified-diff parity | `06-verify.md` exists | no `04-artifacts/parity/INDEX.md` |

Section text is read from a `## Heading` to the next `## ` heading with `<!-- ... -->` comments
removed, so template guidance that quotes `<<...>>` never counts. An author-fill token is any
`<<...>>` that is not a `<<PHASE-N: ...>>` token. Rules key off the frontmatter `type:`, not the
ID prefix, so custom prefixes work.

Scope and shape:

- **Which gates.** The gates whose heading is tagged HARD and that leave checkable evidence, plus
  rca Gate 2, the SW-51 instance the story names. Port Gates 4 and 5 are ordinary approvals.
  Gates that leave no verdict on disk (refactor Gate 5 "tests green", bug Gate 5) are out of
  reach of a file check.
- **Which spec.** Only the spec the session was driving: the newest spec ID in the last 256 KB of
  the transcript whose folder has a `00-spec.md` and whose status is not `done` or `archived` -
  precompact-state's selection, without its sole-in-progress fallback. A turn that never touched
  a spec is never blocked, and an old spec the session never opened cannot block it.
- **Output.** stdout `{"decision":"block","reason":"..."}` and exit 0. ADR 0015 shows this blocks
  Stop exactly like exit 2, and it keeps hard rule 1 (every hook exits 0) literally true. The
  reason names the spec, the gate, what is missing and the later-phase evidence, and tells the
  model to return to the gate and STOP for the user.
- **Loop guard.** When the payload carries `stop_hook_active: true` the hook allows the stop. The
  model gets one continuation to present the gate; it cannot be held in a loop it cannot escape.
- **Default off.** `hooks.stopGate.enabled` must be the literal JSON `true`; an absent key means
  off (the opposite of the other hooks, deliberately). It changes the workflow contract, so it
  ships behind the flag and is exercised by `examples/fixture-project/` and the nightly e2e
  before anyone considers default-on.

## Alternatives considered

- **Prompt-type Stop hook.** Rejected in ADR 0015: it judges the transcript only, cannot read
  `.specs/`, costs a model call per Stop, and cannot be asserted in the fixture suites. It stays a
  candidate second layer for "did the transcript actually present the gate?".
- **Add a `phase:` frontmatter field.** Would make detection exact, but every workflow would have
  to write it at every gate, and a model that skips a gate can skip that write too. The
  invariants use evidence the workflows already produce.
- **Check every in-flight spec in the index.** Stronger coverage, but an unrelated turn could be
  blocked by an old spec with a pre-hook history. Rejected for the "a clean turn is never
  blocked" criterion.

## Consequences

- A simulated skipped-gate turn is blocked with a readable reason; the fixtures in
  `tests/hooks/fixtures/stop-gate/` assert that, the clean cases, and the malformed-state cases,
  identically for PowerShell and bash.
- **Known limits:**
  - RCA-G2 fires only once Phase 3 has written the root cause or moved the status; a skipped
    Gate 2 mid-Phase-3 is caught at Gate 3, not before.
  - `done` specs are not checked, so a turn that skips a gate *and* closes the spec escapes.
    FEAT close-out without `06-verify.md` is already blocked by spec-gate.
  - The BUG-G2 exception is a text match on the retro, not a structured record.
- **Drift.** The table restates what the command files require at each gate. A change to a HARD
  gate's evidence in `commands/bug.md`, `perf.md`, `rca.md` or `port.md` must update both hook
  twins and their fixtures. A contract-lint edge tying the two together is a candidate follow-up.
- About 330 ms per Stop on Windows PowerShell 5.1 (ADR 0015 Q4) even when disabled, since the
  process starts before it reads the flag. Budgeted like the other hooks under ADR 0012.
