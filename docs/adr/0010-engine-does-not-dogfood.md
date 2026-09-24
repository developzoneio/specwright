# ADR 0010: the engine does not run its own spec pipelines on itself

- Status: accepted
- Date: 2026-09-24
- Source spec: Jira SW-56
- Relates to: ADR 0004 (thin calibration corpus); ADR 0008 (e2e harness and fixture project)
- Supersedes: none

## Context

specwright's first stated goal (`CONTRIBUTING.md`, "Project goals and non-goals") is that every
non-trivial change starts with a spec, and `ROADMAP.md` says priorities shift "as the engine is
dogfooded on real projects". This repo does neither for its own work: there is no `.specs/`
directory, no `.specs/constitution.md` and no `.claude/project-config.json`. Engine work is
tracked in Jira, in `docs/superpowers/plans/`, and in this `docs/adr/` directory - not through
`/sd:feature`, `/sd:bug` or `/sd:refactor`.

Until this ADR that decision existed only as an absence (ADR 0004 mentions it in passing), so a new
reader could not tell whether it was deliberate or neglected. It is deliberate, for the reasons
below.

## Decision

The engine repo is exempt from running its own pipelines on itself. Changes are specified in a Jira
ticket with acceptance criteria, design decisions are recorded here as ADRs, and correctness is
enforced by the repo's own checks rather than by `spec-gate`.

**Why it is exempt.**

1. **Bootstrap.** The pipelines are the engine's own markdown. A change to `commands/feature.md`
   cannot be gated by the version of `/sd:feature` it is in the middle of changing, and a change
   that breaks a workflow would break the workflow tracking that change.

2. **This repo is Layer 1, not a target project.** The pipelines read Layer 2 at runtime - a
   constitution, `project-config.json` with `commands.test` / `commands.build`, an index of specs
   against source code. This repo has no application code, no build and no test command in that
   sense. Scaffolding a Layer 2 here would mean inventing a constitution and test command for a
   project that is mostly prompts, and those files would sit next to the engine sources the
   installer copies.

3. **`spec-gate` would gate almost nothing.** It allow-lists `docs/`, `tests/` and every `.md`,
   `.json` and `.yaml` file, and requires an in-progress spec only for code extensions. In this repo
   that is the hook and script `.sh` / `.ps1` files - a small minority of any engine change, and
   the part already guarded hardest by pair parity, ASCII checks and conformance fixtures.

**What validates the pipelines instead.**

- `examples/fixture-project/`: a real Node.js project with Layer 2 scaffolded and one complete
  committed `/sd:feature` run (`FEAT-todo-priority`).
- `tests/e2e/`, nightly: headless `claude -p` runs of `/sd:setup`, `/sd:feature`, `spec-gate` and
  `/sd:spec validate` against fixture copies, asserting on produced artifacts (ADR 0008).
- `examples/spec-lint-fixture/` and `examples/port-parity-fixture/`: seeded-defect corpora for
  `/sd:spec validate` and port parity adjudication.
- `scripts/validate.{sh,ps1}` Checks 1-10, including Check 8 contract lint (ADR 0006), per PR on
  all three CI operating systems; plus the hook conformance suite and the contract-lint self-test.

## Consequences

**Negative - stated plainly.** Pipeline UX is validated against short single-session fixture runs
and the nightly e2e, never against a live spec that lives for weeks: resume after days away, a
re-plan mid-execution (ADR 0003), index drift across many concurrent specs, retro lessons that
accumulate. Those paths are exercised only by adopters. It also keeps the calibration corpus thin:
ADR 0004's "insufficient data" verdict is partly a direct result of this decision, because the
engine's own work produces no `events.jsonl`.

**Positive.** Engine changes are not blocked by the engine's own in-flight changes, and this repo
stays a clean Layer 1 source tree with nothing the installer might confuse for engine content.

## Revisit when

Any of these would reopen the decision:

- The engine gains executable source that `spec-gate` could meaningfully gate - for example, the
  lint and validation scripts become the bulk of a typical change.
- There is a way to hold a Layer 2 scaffold (constitution, project config, `.specs/`) in this repo
  that the installer provably never copies and the validators never mistake for engine content.
- The pipelines stabilize enough that a released engine version can gate work on the next one
  (install the released engine, run it against a working tree of `develop`).
- No external adopter corpus of multi-week specs becomes available. Then dogfooding is the only
  remaining source of that evidence, and its value outweighs the bootstrap cost.
