# ADR 0018: Gate brief - what a gate shows is an append-only spec artifact

- Status: accepted
- Date: 2026-10-22
- Source spec: Jira SW-89 (`FEAT-gate-brief`, E12 / SW-87)
- Relates to: `docs/spikes/SW-88-feature-baseline.md` (the measured "before"); ADR 0016 (stop-gate
  invariants - a possible consumer, not built here); ADR 0002 (model escalation - its retro line
  keeps rule IDs); `skills/sd-gate-brief/SKILL.md` (the rules this ADR introduces)
- Supersedes: none
- Extended by: ADR 0019 (`details` targets, brief language, plan-face decisions; SW-102); ADR 0020
  (printed means reply text, closing summary, phase narration, e2e transcript assertion; SW-99)

## Context

The SW-88 baseline ran `/sd:feature` headless at two sizes and found three things this ADR acts
on:

- **F1.** Neither run printed a single line of gate text, yet both sessions reported that they
  had presented each gate. Nothing on disk could tell the two apart, so gate friction could not be
  measured.
- **F2.** Gate 1 of the 6-task run carried 11 real decisions, 9 of them defaults the architect
  chose alone. A hard cap of three items would have hidden eight of them behind a `yes`.
- **F3.** Rule IDs (`ESC-FEAT-*`) reached the user-visible narration with no explanation. The
  gate surfaces themselves cited criterion and decision IDs and `path:line` by the hundred.

## Decision

1. **New spec artifact `.specs/<ID>/gate-briefs.md`, append-only.** One section per gate pass,
   holding the exact text shown, written by the main thread before it is shown, closed by a
   `Reply:` line. Collapsed decisions are written in the same section, under
   `### More decisions (shown on details)`, so a resumed session can answer `details`.
2. **A fixed brief shape.** At most 10 lines up to the question, plus one task-table row per task
   at Gate 2. Gate 3 lists every blocking finding, counts warnings with the recommended default
   "log as follow-ups", and logs suggestions to `05-retro.md` without asking.
3. **Rank, show 3, collapse the rest.** Decisions are ranked by impact, then reversibility, then
   origin. The top 3 are shown with a recommended default, and the rest collapse into one line.
   No decision is dropped: each one is either shown or recorded as collapsed.
4. **Agents return blocks, the main thread writes.** `sd-spec-architect` returns `GATE_BRIEF` for
   `create`, `refine` and `plan`, and `sd-reviewer` returns a `gate: review` block. The reviewer
   keeps its read-only allowlist.
5. **A `details` option** on Gates 1, 2 (both faces) and 3. It shows the collapsed part and asks
   again. It never approves. The gate count stays 3, and Gate Re-plan records a section but keeps
   its option set, because its protocol is shared with `/sd:refactor`.
6. **No internal IDs in user-facing text**, across the workflow, not only at gates. Machine
   records in other artifacts (the `escalation:` retro lines) keep theirs.

All six live in one skill, `sd-gate-brief`. `/sd:feature` reads it at Phase 0 and names it at each
gate. `sd-spec-architect` and `sd-reviewer` load it via `skills:`.

## Alternatives considered

- **Brief inside `05-retro.md`.** Rejected. The retro is parsed line by line by
  `aggregate-lessons.*`, `validate-escalation-lines.*`, stop-gate's BUG-G2 exception check and
  `/sd:spec`'s status replay. `subagent-retro` also reads its mtime as a staleness signal, and a
  brief written at every gate would reset that signal.
- **A numbered artifact (`07-gate-briefs.md`).** Rejected. Numbers mark phase artifacts that later
  phases consume, and a brief is a record of presentation. Leaving it unnumbered also keeps it out
  of `contractLint.specArtifacts`.
- **Chat output only, as before.** Rejected by F1: an e2e harness that asserts artifacts cannot
  see it.
- **Hard cap of 3 decisions.** Rejected by F2.

## Consequences

- The e2e scenario `02-feature-happy` asserts the artifact exists, has Gate 1, 2 and 3 sections,
  and matches no rule-ID pattern.
- `/sd:spec status` lists the file. `/sd:spec validate` and `/sd:verify` do not read it.
- `spec-gate` treats it as non-code (`.specs/` is allow-listed), and `handoff-integrity` skips the
  spec directory.
- Follow-up, not built: stop-gate could treat a gate section with a `Reply: yes` line as the
  on-disk evidence `/sd:feature` gates lack today (ADR 0016 has no FEAT rule). The other workflows
  adopt the brief in SW-96.
