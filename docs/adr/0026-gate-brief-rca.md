# ADR 0026: Gate brief - /sd:rca gates

- Status: accepted
- Date: 2026-10-29
- Source spec: Jira SW-111 (`FEAT-gate-brief-rollout`, SW-96 part 4 of 5, E12 / SW-87)
- Relates to: ADR 0018 (the gate brief artifact); ADR 0019 (`details` targets, language); ADR 0020
  (printed means reply text); ADR 0024 (the `/sd:bug` pilot); ADR 0025 (the `/sd:refactor` gates);
  `skills/sd-gate-brief/SKILL.md` (the rules)
- Supersedes: none. Extends ADR 0024 decisions 1, 3 and 5 to `/sd:rca`.

## Context

After SW-96 part 2, `/sd:feature`, `/sd:bug` and `/sd:refactor` present their gates as briefs.
`/sd:rca` still displays raw sections at its three HARD gates (1 evidence, 2 hypotheses, 3 root
cause) and can narrate `ESC-RCA-02`.

Two facts set it apart from `/sd:bug`. An RCA keeps its hypothesis tree and its verdicts in
`00-spec.md`, where `/sd:bug` keeps them in `03-decisions.md`, and its verdicts are bullets under
`### Verification results (Phase 3)`, not `### H<n> verification` sections. And the evidence at
Gate 1 comes from the user, not from an agent: the architect only creates an empty skeleton.

## Decision

1. **A `/sd:rca` part in the skill.** `sd-gate-brief` "Per-workflow parts" gains section headings,
   shown lines and `details` targets for Gates 1-3. `commands/rca.md` reads the skill in Phase 0
   and only names it at each gate. The hypothesis lines (`Still open`, `Ruled out`, the root cause
   lines) and the `tree` / `H<n>` targets are the `/sd:bug` ones, by reference; only the sources
   change.
2. **The main thread composes all three briefs.** No agent returns a block for `/sd:rca`. The
   `GATE_BRIEF` block the architect returns for the empty skeleton is not used, and `sd-debugger`
   is unchanged: it also serves `/sd:bug` and `/sd:perf`.
3. **No decisions block.** The user supplies the evidence and the tree is ranked, not chosen, so
   the shown lines replace the `Decisions` lines of the generic shape. New lines exist only for the
   incident: `Incident`, `Window`, `Timeline`, `Impact`, `Recent changes`, `Evidence` / `Gaps` at
   Gate 1, and `Explains` / `Timeline fit` at Gate 3.
4. **Two new targets.** `details timeline` prints the Timeline and Recent changes sections and
   `details impact` prints Symptoms and Affected scope, both verbatim. `details rootcause` prints
   the Root cause section and the separate "Why this is root cause" section.
5. **Every `/sd:rca` gate offers `details`.** `details` never approves, so it is not an override
   and `CL305` is unaffected. Gate count stays 3 and there is no conditional gate.
   `contractLint.gateBriefs` declares labels `1`, `2`, `3` for both briefs and `details`.

## Alternatives considered

- **A `gate: incident` architect block at Gate 1.** Rejected: the skeleton is empty at `create`,
  so the architect knows nothing the user has not yet said.
- **Debugger returns a `GATE_BRIEF` block.** Rejected for the reason ADR 0024 gave: its verdicts
  are already on disk where the main thread writes them.
- **Move the RCA tree to `03-decisions.md`.** Rejected: it would change the RCA template and the
  stop-gate RCA rule, which read `00-spec.md`, to save one clause in the skill.
- **Extend e2e scenario 11.** Rejected: it resumes at Phase 2 with Gate 1 already passed and pins
  an escalation cap with seven retro assertions; the brief needs a fresh run from Gate 1.

## Consequences

- `CL307` covers `commands/rca.md`. The three gates have shapes the existing fixtures already pin,
  so no fixture is added.
- e2e scenario `15-rca-gate-brief` runs `/sd:rca` from the raw evidence in the prompt and a seeded
  incident log, under `ceiling: "sonnet"`, with a `yes` per gate. It asserts the three sections,
  the `Reply:` lines, the transcript printout and the absence of internal IDs in the file and in
  every assistant text block.
- **No hook change.** stop-gate's RCA-G2 rule reads `00-spec.md` only. Follow-up: RCA rules
  evidenced by the brief, with the BUG and REF rules (SW-108).
- Follow-ups: the remaining workflows (`/sd:perf`, `/sd:port`; SW-96 parts 3 and 5).
