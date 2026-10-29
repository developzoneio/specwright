# ADR 0025: Gate brief - /sd:refactor gates, and `details` at Gate Re-plan

- Status: accepted
- Date: 2026-10-29
- Source spec: Jira SW-109 (`FEAT-gate-brief-rollout`, SW-96 part 2 of 5, E12 / SW-87)
- Relates to: ADR 0018 (the gate brief artifact); ADR 0019 (`details` targets, language); ADR 0020
  (printed means reply text); ADR 0021 (stop-gate feature rules); ADR 0024 (the `/sd:bug` pilot);
  ADR 0003 (the Gate Re-plan protocol); `skills/sd-gate-brief/SKILL.md` (the rules)
- Supersedes: none. Amends ADR 0018 decision 5 (its Gate Re-plan clause) and settles the Gate
  Re-plan section shape ADR 0021 left open.

## Context

After SW-96 part 1, `/sd:feature` and `/sd:bug` present their gates as briefs. `/sd:refactor`
still showed raw artifacts at six HARD gates and the conditional Gate Re-plan, and its Re-plan
block did not name `sd-gate-brief` at all. Three of its gates (2, 3 and 5) had no slash option set:
Gate 2 numbered its choices in prose and Gate 5 offered bullets only.

ADR 0018 kept Gate Re-plan's option set without `details`, because the protocol is shared with
`/sd:refactor`, and ADR 0024 left the question open. A Re-plan delta exists only in the brief's
`Change:` line until `approve` makes the architect write the `R<n>` revision, so at the gate the
user cannot see the tasks the delta rewrites without leaving the gate.

## Decision

1. **A `/sd:refactor` part in the skill.** `sd-gate-brief` "Per-workflow parts" gains section
   headings, shown lines and `details` targets for Gates 1-6. `commands/refactor.md` reads the skill
   in Phase 0 and only names it at each gate.
2. **Who composes each brief.** Gate 1 reuses the architect's `gate: spec` block, plus an
   invariant count the main thread reads from the spec. Gate 4 reuses `gate: plan`, with a `Batch`
   column taken from each task's `Parallel batch` field. Gate 6 reuses the reviewer's
   `gate: review` block, which gains an optional `invariant:` line for a review that received
   `INVARIANTS`. The main thread composes Gates 2, 3 and 5 from what it already wrote. The
   architect and the explorer are unchanged.
3. **Measured coverage, never `path:line`.** Gates 2 and 3 show measured coverage against the bar
   and name the lowest files by path. Phase 5 saves each batch's test output to
   `04-artifacts/batches/batch-<b>-tests.txt`. Phase 6 gains a step 0, in which the main thread
   runs tests, lint and coverage and saves the coverage output to
   `04-artifacts/coverage/after-refactor.txt`. The reviewer holds no Bash, so it never measured the
   coverage its checklist compares.
4. **Two faces for Gates 2, 3 and 5**, as in `/sd:feature` Gate 2.
   - Each face has a slash option set that includes `details`.
   - Coverage keeps its existing choices as tokens: `add tests`, `exception <reason>` and `abort`.
     None of them is in `overrideOptionTokens`. The exception is the logged constitution exception
     the HARD rules already allow.
   - A red batch offers only `revert` or `fix`.
   - Gate 2 now asks before planning even when coverage is met; its heading always said STOP.
5. **Gate Re-plan offers `details <target>` in every workflow.**
   - The targets are the bare `details`, a task ID (the current block, or the outline row before
     Phase 3b), and `plan`.
   - The cost is one token on a shared question line. `details` never approves, so it is not an
     override and `CL305` is unaffected.
   - The protocol's own block in `skills/sd-replan-loop/SKILL.md` carries the token and names
     `sd-gate-brief`. It is therefore declared in `contractLint.gateBriefs` beside
     `commands/feature.md` and `commands/refactor.md`.
6. **Re-plan section shape.**
   - Heading: `## Gate Re-plan - R<n> (pass <p>)`.
   - `revise` is a new pass. `details` stays in the open section. After `abort task` no revision is
     written, so the next discovery reuses `R<n>` with the next pass number.
   - The shown lines gain `Risk:`.

## Alternatives considered

- **Keep Re-plan without `details`** (ADR 0018's choice). Rejected: the gate is HARD and rewrites
  approved tasks, and the user's only view of the delta is one line.
- **Different option lines for feature and refactor Re-plan.** Rejected: the protocol is defined
  once in `sd-replan-loop`, and a per-command divergence is the drift the skill exists to prevent.
- **Architect returns the batch number on its `task:` line.** Rejected: the field is already on
  disk at Gate 4, and changing the block would touch every `plan` return for one workflow.
- **Reviewer runs coverage.** Rejected: it is read-only by allowlist, which is the point of its
  role.

## Consequences

- `CL307` covers `commands/refactor.md` (all seven labels for both briefs and `details`),
  `commands/feature.md` (now with Re-plan in `details`) and `skills/sd-replan-loop/SKILL.md`.
  - `cl307-replan-details-dropped` pins an indented Re-plan question that lost `details`, and a
    shared protocol block that offers it while undeclared.
  - `fp-cl307-two-face-coverage-gate` pins a silent HARD two-face gate with descriptive tokens.
  - `fp-cl307-replan-brief-without-details` keeps testing the generic property: a brief declared
    without `details` stays silent.
- **No hook change.** stop-gate's `^## Gate Re-plan` still matches the new heading, and it reads no
  `Reply:` line in a Re-plan section, so a `details` reply there is never taken for an approval.
  ADR 0021's "Gate Re-plan has no rule" still holds: a Re-plan is conditional, and nothing on disk
  says one was due before its revision exists.
- e2e scenario `14-refactor-gate-brief` runs `/sd:refactor` on the fixture project, a one-batch
  extraction with coverage already met. It asserts the five briefs of the happy path, the `Reply:`
  lines, the transcript printout, the two saved outputs and the absence of internal IDs.
- Follow-ups:
  - stop-gate REF rules evidenced by the brief, as SW-108 is for BUG, and a Re-plan rule pairing a
    `## Revisions` `R<n>` with an approving reply in its section.
  - An e2e assertion over assistant reply text for narration.
  - SW-96 parts 3-5.
