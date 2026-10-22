# ADR 0020: Gate brief - printed means reply text, and the e2e harness checks it

- Status: accepted
- Date: 2026-10-22
- Source spec: Jira SW-99 (`FEAT-gate-brief-printed`, E12 / SW-87)
- Relates to: ADR 0018 (the gate brief artifact); ADR 0019 (file and chat are the same text, which
  defines "verbatim"); ADR 0008 (the behavioral e2e harness and its "assert artifacts, never
  prose" rule); `skills/sd-gate-brief/SKILL.md` (the rules); `tests/e2e/README.md` (the
  assertion)
- Supersedes: none. Extends ADR 0018 decisions 1 and 6 and ADR 0019 decision 2; reverses none of
  them.
- Follow-up: SW-103 sends each e2e gate reply as its own turn. With it, `02-feature-happy` passes
  `transcript-contains-section` (see `tests/e2e/README.md`, "Gate replies as turns").

## Context

The SW-89 re-measure (headless, n=1 per size, PR #36) found three gaps after ADR 0018 shipped:

- **F1.** Both runs wrote all three briefs to `gate-briefs.md` and printed none of their lines to
  chat. The final message still said all three gates were presented. This is the SW-88 F1 pattern;
  the artifact now makes it visible, but nothing asserts it.
- **F2.** The small run's final summary cited two `path:line` references, although the
  "User-facing text" rule forbids them.
- **F3.** Neither run named "Phase 6", so the transcript could not separate Phase 5 from
  close-out.

The skill said "then prints the section body verbatim". It did not say which channel that is. A
session can treat its Write call as the presentation (an interactive tool view shows the content),
or it can treat every text block before the last as unread in a `-p` run. The rule's scope, "all
chat text of the workflow", also let the final message read as a report to the caller rather than
workflow text, and close-out step 1 had just put fresh `file:line` citations in context.

## Decision

1. **Printed means reply text.** The shown body is every line after the section heading up to and
   including the question line. Printing it means those lines appear in the main thread's own
   reply text, as one text block of their own, after the write and before the next tool call.
   A Write, Edit or Read of the file is not printing it, and neither is a sentence saying the
   brief was shown. This holds in headless and scripted runs, and in a turn that continues past
   the gate. No message may say a gate was presented when its body is not in reply text.
2. **The user-facing rule covers the whole turn.** It applies to all reply text from Phase 0 to
   the end of the turn, including the closing summary and any report the invoking prompt asks for.
   The summary names tests and files, not `path:line`; citations stay in `05-retro.md` and
   `06-verify.md`. `/sd:feature` Phase 6 step 7 names the skill; it does not restate the rule.
3. **Every phase is narrated on entry.** One line, `Phase <n> - <what it does>`, before the
   phase's first tool call, for Phase 0 through close-out and on a resume. The skill owns this;
   `/sd:feature` Phase 0 step 4 already hands it every user-facing line.
4. **A new e2e assertion, `transcript-contains-section`.** For each `gate-briefs.md` section that
   matches a heading pattern, its shown lines (blank lines excluded, up to `### More decisions` or
   `Reply:`) must appear verbatim and in order in one text block of the main thread's assistant
   messages. Tool calls and subagent transcripts do not count. `02-feature-happy` uses it for every
   `## Gate` section.
   - A scenario with a transcript assertion keeps its session (no `--no-session-persistence`)
     whatever `SD_E2E_TRANSCRIPT` says. The fake home is still deleted after the assertions.
   - A missing transcript, a missing brief, a brief with no matching section, or a section with no
     shown lines fails the assertion. It never passes empty.
   - `-SelfTest` checks it offline, before the paid guard runs: a printed brief must pass; a brief
     only written, only printed by a subagent, paraphrased, or with no transcript must fail.

### Why decision 4 keeps "assert artifacts, never prose"

The harness rule exists because a model's phrasing varies run to run. This assertion encodes no
phrasing. `expect.json` names a file and a heading pattern; the expected lines are whatever the
run itself wrote to disk, so a change of wording moves both sides together and cannot flake it.
The check is a byte comparison, which ADR 0019 decision 2 makes meaningful: the brief is rendered
into the conversation language once, before the write, and the chat repeats the file. A
paraphrase is meant to fail. Finally, F1 is a fact about the reply channel that no file records,
so an artifact-only harness cannot observe it at all. The carve-out is limited to this one type,
and the README says no other assertion may read the transcript.

## Alternatives considered

- **A scratch transcript metric only (no assertion).** Rejected. It measures F1 once, in a
  re-measure, and lets the next regression ship silently. The harness rule does not require it,
  because the compared text is the artifact.
- **Match the transcript against the full section, heading and blank lines included.** Rejected.
  The heading and the collapsed subsection are record, not shown text, and blank-line spacing is
  markdown rendering rather than content.
- **Accept the lines anywhere in the transcript, in any order.** Rejected. A short line such as
  `Risk: none found.` can occur in narration, and the skill asks for one text block; requiring
  order within one block keeps a coincidental match from passing.
- **Fail the assertion when `SD_E2E_TRANSCRIPT` is off.** Rejected. The nightly would need the
  flag, and the fake home with its copied credentials would then be kept. Keeping only the session
  for this scenario, then deleting it, needs no flag.
- **A `-SelfTest` mutation that weakens the skill and re-runs `02-feature-happy`.** Rejected. It
  costs about $2 a run and is not deterministic: the model may print the brief anyway. The offline
  cases exercise the same assertion code on the exact F1 shape.
- **Enforce printing in a hook.** Rejected for this story: no hook change is in scope, and a Stop
  hook sees the transcript only after the turn, too late to print anything.

## Consequences

- `02-feature-happy` gains one assertion (22). It now keeps its session during the run.
- `run-e2e.ps1 -SelfTest` runs six offline transcript cases before the paid `03`/`04` runs.
- The gate count stays 3, `contractLint.gates` is unchanged, and no hook changes.
- Printing is still an instruction to the model, now measured on every e2e run of `02`. If it keeps
  failing, the next step is a structural one, recorded as a follow-up, not built here.
- **First measurement (2026-10-22, `claude` 2.1.308, headless, n=1 per size): decision 1 did not
  take.** Both runs read the new rule and still printed 0 of their shown brief lines (S 0/22, M
  0/28), and both final messages again said every gate was shown. `02-feature-happy` fails this
  assertion, which is the intended signal: the assertion reports a real defect, and the self-test
  shows it is not a harness fault. Decisions 2 and 3 did take: 0 internal IDs and 0 `path:line` in
  user-visible text in both runs, and every phase line was found except Phase 5 in the small run.
  The cause is the scripted single turn. Every gate there is followed by more tool calls in the
  same turn, so no gate ever ends a turn, and the session drops the text between tool calls.
- **Probe, same day and engine (commit `e4a0779`):** the same `/sd:feature todo-count` request with
  no standing reply stopped at Gate 1, and the gate ended the turn. The final message carried the
  Gate 1 brief byte-for-byte (6 of 6 shown lines, `transcript-contains-section` passed), with 0
  internal IDs, for $0.50. Decision 1 holds on the path a person takes; the single-turn script is
  what defeats it. Follow-up SW-103 drives each gate reply as its own turn (`--resume`), so `02`
  reaches every gate the way a person does. Until it lands, `02` fails this one assertion.
- Other workflows adopt the brief in SW-96 and take these rules from the same skill.
