# SW-88 - /sd:feature friction baseline

Spike under epic SW-87. No engine change. Purpose: record baseline numbers for `/sd:feature`
friction, so each E12 story can show its effect against a measured "before".

## Method

- Two headless runs through the e2e harness (`tests/e2e/run-e2e.ps1`), one per size class:
  - **S** - the existing scenario `02-feature-happy` (`FEAT-todo-count`, "2-3 task spec").
  - **M** - a temporary scenario `90-spike-feature-m` (`FEAT-todo-due-date`, "expect 5-8 tasks").
    It was copied from `02-feature-happy`, with a new prompt (Appendix A), four `file-exists`
    assertions, `budget.txt` 20 and `timeout.txt` 3000. It was never committed.
- Both runs used `SD_E2E_TRANSCRIPT=1 SD_E2E_DEBUG=1 -ResultsFile <scratch>/run-<s|m>.json`, one
  after the other, with no re-runs.
- The harness was started under `env -i` with a whitelist (`PATH`, `HOME`, `LANG`, the proxy and CA
  variables) plus `ANTHROPIC_API_KEY`. Without that whitelist, the child `claude` inherits the
  hosting session's environment. That environment carries its own auth path and session settings
  (effort, subagent spawn depth) that would confound metrics 1 and 6.
- Every metric came from a scratch script that read the kept transcript, the kept workspace and
  the results JSON. Nothing was counted by eye, except the decision/FYI split (metric 4), which is
  a judgment and is listed item by item so it can be checked.
- Definitions:
  - **Phase wall time**: the gap between the first main-thread assistant text that names
    "Phase N" and the one that names "Phase N+1". The workflow narrates each phase entry, and all
    12 boundaries were found this way, with no fallback. Phase 0 runs from session start to the
    Phase 1 marker, and Phase 6 runs to the last transcript event. The phases sum to the
    transcript span.
  - **Gate output**: the assistant text that carries the gate question line ("Approve spec",
    "Approve plan", "All clean", the Gate Complexity split question, "Re-plan FEAT-").
  - **Gate surface (proxy)**: what each gate asks the user to approve, whether or not the session
    printed it.
    - Gate 1: `00-spec.md`.
    - Gate 2: `01-plan.md`, `02-tasks.md` and `03-decisions.md`. Phase 2 says the impact map is
      reviewed in Phase 3, which ends at Gate 2.
    - Gate 3: the `sd-reviewer` report returned to the main thread, minus the harness hand-back
      frame.
  - **ID regexes**:
    - `(SC|AC)-\d+`
    - `\bD\d+\b`
    - section sign `§\s*[\w.]+`
    - `ESC-[A-Z]+-\d+\w?`
    - `\b(SL|VF|CL)\d{3}\b`
    - `path:line`, as `[\w./-]+\.[A-Za-z]{1,5}:\d+(-\d+)?`

  The ID regexes count raw occurrences. "Unexplained" is assessed separately, in the findings.

## Environment

| Item | Value |
|---|---|
| Date | 2026-10-21 (runs 09:03-09:19 UTC) |
| claude CLI | 2.1.306 |
| OS | Ubuntu 24.04.5 LTS (Linux 6.18 container), pwsh 7.6.7, node 22.22.0 |
| git commit | `68515d8` (`develop/v1`) |
| Auth | `ANTHROPIC_API_KEY` (API billing). The results JSON says `subscription (~/.claude/.credentials.json)` because a file by that name exists, but it holds only MCP OAuth tokens. See caveats |
| Served models | main thread: the CLI default for the key (opus-class; the harness does not pin it). Subagents matched their frontmatter aliases: architect and reviewer `sonnet`, explorer and implementer `haiku` |

## Caveats

- **n = 1 per size class.** These are point measurements, not distributions. Treat a difference
  under about 20% as noise until it is repeated.
- **Headless auto-yes.** Every gate got a scripted "yes" within one turn, so no human think time is
  in the wall times. The numbers measure engine and model time only.
- **No gate output was printed (Finding 1).** Metrics 3-5 therefore use the gate-surface proxy.
- **Implementer had no Bash.** Under the scenario's `dontAsk` + `Bash(npm test:*)` grant, both
  runs' `sd-implementer` subagents were refused Bash, so the main thread ran `npm test` after every
  task. Phase 4 time includes that main-thread verification.
- **Misleading auth label.** The results JSON's `authMode` is a label from the harness preflight, not
  the credential that was used.
- **Credential copy.** The harness copies `~/.claude/.credentials.json` into each fake home, and
  `SD_E2E_TRANSCRIPT` keeps the fake home. The copy was deleted by hand right after each run. The
  API key itself was confirmed absent from both kept sandboxes.

## Results

| Metric | S - `02-feature-happy` | M - `90-spike-feature-m` |
|---|---|---|
| Harness result | pass, 14/14 assertions | pass, 4/4 assertions |
| Total duration (results JSON) | 318.6 s | 634.3 s |
| Cost (results JSON) | $1.36 | $2.25 |
| Phase 0 - bootstrap | 23 s | 20 s |
| Phase 1 - spec | 49 s | 82 s |
| Phase 2 - impact analysis | 35 s | 60 s |
| Phase 3 - plan + tasks | 47 s | 146 s |
| Phase 4 - execute | 60 s | 203 s |
| Phase 5 - integration + review | 31 s | 46 s |
| Phase 6 - close-out + verify | 71 s | 75 s |
| Time before first code edit (Phase 0-3) | 154 s (49%) | 308 s (49%) |
| `00-spec.md` lines | 92 | 206 |
| `01-plan.md` lines | 57 | 157 |
| `02-tasks.md` lines | 31 | 244 |
| `03-decisions.md` lines | 53 | 82 |
| Spec artifact total (00-03) | 233 | 689 |
| Task count | 2 | 6 |
| Gate output printed: Gate 1 / Gate 2 / Gate 3 | 0 / 0 / 0 lines | 0 / 0 / 0 lines |
| Gate Complexity / Gate Re-plan | did not fire / did not fire | did not fire / did not fire |
| Gate surface lines: Gate 1 / Gate 2 / Gate 3 | 92 / 141 / 33 | 206 / 483 / 53 |
| Decision vs FYI items: Gate 1 | 2 decision / ~22 FYI | 11 decision / ~32 FYI |
| Decision vs FYI items: Gate 2 | 2 decision / ~12 FYI + impact map | 3 decision / ~40 FYI + impact map |
| Decision vs FYI items: Gate 3 | 0 (+1 optional) / ~7 FYI | 0 (+1 optional) / ~15 FYI |
| IDs in Gate 1 surface | SC/AC 11, section 11 | SC/AC 33, section 12 |
| IDs in Gate 2 surface | SC/AC 20, section 1, path:line 28 | SC/AC 128, D-n 21, section 8, path:line 80 |
| IDs in Gate 3 surface | SC/AC 9, section 5, path:line 5 | SC/AC 26, D-n 4, section 7, path:line 22 |
| IDs in user-visible assistant text (whole run) | ESC 4, path:line 2 (32 lines total) | ESC 3, SC/AC 1 (25 lines total) |
| `sd-implementer` calls vs tasks | 2 / 2 | 5 / 6 (T06 has no `Files` and was checked by the main thread) |
| Other agent calls | architect 2, explorer 1, reviewer 1 | architect 2, explorer 1, reviewer 1 |
| `06-verify.md` result / findings | pass / 0 | pass / 0 |
| Plan-time-detectable findings (VF010-VF012, VF020) | 0 (all PASS) | 0 (all PASS) |
| Model escalation lines in `05-retro.md` | none fired (1 "no ESC rule fired" line) | none fired (1 line, same) |

`ESC-*` and `SL/VF/CL###` IDs never appeared in any gate surface. `ESC-*` appeared only in the
user-visible narration, and `SL/VF/CL###` did not appear anywhere.

## Per-gate decision / FYI lists (metric 4)

"Decision" means an item a reviewer could reasonably veto, so the scripted "yes" approved it on the
user's behalf. "FYI" means an item that restates the request, derives mechanically from a decision,
or reports a check result.

### Run S

**Gate 1 (`00-spec.md`, 92 lines)**

- Decision: the return shape is exactly `{ done, pending }`, with no `total` key.
- Decision: the tally lives in `TodoService` over `list()`, with no new store method. The architect
  resolved this as an open question.
- FYI:
  - Why paragraph.
  - SC-1..SC-3, which restate the request.
  - AC-1..AC-4.
  - 5 remaining out-of-scope bullets.
  - "Resolved - sync vs async".
  - 8 constitution-check bullets.

**Gate 2 (plan + tasks + decisions, 141 lines)**

- Decision: 2 tasks, test-after ordering (Alternative 4 rejects test-first).
- Decision: the SC-3 "no id consumed" proof compares the next id across two services (Risk 3).
- FYI:
  - Phased overview.
  - Approach.
  - Alternatives 1-3: two were already settled in the spec, one is marked as a local choice.
  - Sequencing.
  - Risks 1, 2, 4.
  - Complexity self-assessment.
  - 2 task blocks of 11 fields.
  - Impact analysis, 53 lines in 7 sections.

**Gate 3 (reviewer report, 33 lines)**

- Decision: none required. 1 optional SUGGEST (snapshot todos by value in the SC-3 test), which the
  workflow auto-logs.
- FYI:
  - Test summary.
  - Verdict counts.
  - 6 PASS groups (coverage, constitution, pattern refs, scope, public API, quality bars).

### Run M

**Gate 1 (`00-spec.md`, 206 lines)**

- Decisions: the architect made all 9 "Decided" open questions as headless defaults. The spec says
  "any of them can be overturned at Gate 1".
  - Date-only `YYYY-MM-DD`.
  - `now` is a `Date`.
  - Strictly before, at UTC-day granularity.
  - Undated and completed todos are excluded.
  - The key is omitted when absent.
  - Only `undefined` counts as absent.
  - Positional third argument on `addTodo`.
  - Stable tie order.
  - Two new error types.
- Decisions: 2 scope calls inside Out of scope.
  - No update path for `dueDate`.
  - The constitution example shapes are left stale.
- FYI:
  - Why.
  - SC-1..SC-8, which mostly re-express the decisions as examples.
  - AC-1..AC-9.
  - 7 other out-of-scope bullets.
  - 8 constitution-check bullets.

**Gate 2 (plan + tasks + decisions, 483 lines)**

- Decision: D2 adds an export the spec does not name (`validateNow`).
- Decision: T06 is a verification-only task with no `Files`.
- Decision: T04 is serialized after T03 by choice, not by need ("cheaper bisect").
- FYI:
  - 7 alternatives, each already settled by the spec or the constitution.
  - D1, D3, D4, which implement spec decisions.
  - Phased overview.
  - Sequencing.
  - 17-row coverage map.
  - R1-R8.
  - 4-row complexity table.
  - 6 task blocks of 11 fields.
  - Impact analysis, 82 lines in 7 sections.

**Gate 3 (reviewer report, 53 lines)**

- Decision: none required. 1 optional item, SUGGEST 3: log a constitution amendment as a
  follow-up. Phase 6 step 4 would prompt for a reserved ID, and the headless run skipped it.
- FYI:
  - SUGGEST 1 and 2 (style).
  - Verdict counts.
  - 9 PASS groups.
  - Public API summary (4 bullets).
  - Files-reviewed list.

## Findings

1. **No gate output was printed in either run, yet the session reported that it had been.** All 6
   gate passes produced 0 lines of gate text: no "Approve spec", "Approve plan" or "All clean" line
   appears anywhere in either transcript.
   - The only trace is a retro line such as `Gate 1 approved: "yes"`.
   - M's final message says "I showed the summary at Gates 1, 2 and 3".
   - The scenario prompt explicitly says to present each gate's summary before taking the
     standing "yes".
   - Consequence for E12: gate-output length cannot be measured by this harness as it stands.
     Either a story makes the gate presentation an artifact the harness can assert, or gate
     friction is tracked through the surface proxy used here.
2. **The Gate 2 surface grows faster than the work, while its decisions stay flat.**
   - The task count is 3x (2 to 6), but the Gate 2 surface is 3.4x (141 to 483 lines) and
     `02-tasks.md` is 7.9x (31 to 244 lines).
   - The decisions needing a human call stay at 2-3: one decision per 70 lines in S, one per 161 in
     M.
   - The M Gate 2 surface carries 128 SC/AC references, 80 `path:line` citations and 21 `D-n`
     references. Gate 3 then cites D1-D4 again, without saying what they are.
   - Gate 1 in M is where the decisions concentrate: 11, nine of them defaults the architect chose
     alone because the run was headless.
3. **Half the wall time is spent before the first code edit, and close-out is a fixed cost.**
   - Phases 0-3 take 49% of the run in both sizes.
   - Phase 3 (plan) grows 3.1x (47 to 146 s).
   - Phase 6 is almost constant (71 to 75 s), so it is 22% of the S run.
   - Plan-time-detectable verify rules (VF010-VF012, VF020) found nothing in either run, so this
     baseline offers no evidence that moving those checks to Gate 2 would save a loop.
   - Delegation is 1 implementer call per code task, but every test run fell back to the main
     thread because the implementer had no Bash.
   - The user-visible narration leaks rule IDs (`ESC-FEAT-02` ... `ESC-FEAT-04b`, 3-4 per run). A
     reason is given ("complexity S"), but the ID is never explained.

## Appendix A - M scenario `prompt.txt` (exact)

```text
/sd:feature todo-due-date

Feature request: Add an optional dueDate (ISO 8601 date string) to todos: validated in the Domain with its own
error type, accepted by createTodo and TodoService.addTodo, plus TodoService.listOverdue(now)
returning pending todos whose dueDate is before now, sorted by dueDate. Expect 5-8 tasks.

This is a headless, scripted test run with no human available to reply mid-workflow. Do not stop
and wait for a real person. At every hard gate (Gate 1 spec approval, Gate 2 plan approval, Gate 3
integration + review pass, and Gate Re-plan if it fires), treat the following as the standing reply
and continue immediately: "yes". Do not treat this as skipping the gate - actually present each
gate's summary as instructed, then proceed as if "yes" was just typed in response, all within this
single turn. If Gate Complexity fires, record that it fired and reply no-split.

Proceed all the way through Phase 6 close-out (including running /sd:verify) and report the final
spec ID and its status in your last message.
```

The M scenario's `expect.json` held only `file-exists` checks for `00-spec.md`, `01-plan.md`,
`02-tasks.md` and `06-verify.md` under `.specs/FEAT-todo-due-date/`.

## Jira comment for SW-87

```markdown
**SW-88 baseline done** - `docs/spikes/SW-88-feature-baseline.md` (claude 2.1.306, commit 68515d8, n=1 each, headless auto-yes)

| | S (2 tasks) | M (6 tasks) |
|---|---|---|
| Duration / cost | 319 s / $1.36 | 634 s / $2.25 |
| Before first code edit (Ph 0-3) | 49% | 49% |
| Phase 3 plan / Phase 6 close-out | 47 s / 71 s | 146 s / 75 s |
| Spec artifacts 00-03 (lines) | 233 | 689 |
| Gate surface G1 / G2 / G3 (lines) | 92 / 141 / 33 | 206 / 483 / 53 |
| Real decisions G1 / G2 / G3 | 2 / 2 / 0 | 11 / 3 / 0 |
| Gate text actually printed | 0 lines | 0 lines |
| sd-implementer calls / tasks | 2 / 2 | 5 / 6 |
| Plan-time VF findings / escalations | 0 / 0 | 0 / 0 |

Top findings:
1. Headless runs print **no gate summary at all**, yet the session claims it did. Gate-output length cannot be measured until the presentation is an assertable artifact.
2. Gate 2 grows 3.4x for 3x tasks (tasks file 7.9x) while its real decisions stay at 2-3 (1 per 161 lines in M). Gate 1 in M holds 11 decisions, 9 defaulted by the architect.
3. Half the wall time is pre-code, and close-out is a flat ~75 s. VF010-12/VF020 found nothing, so there is no evidence yet for moving them to Gate 2.

Caveat: implementer subagents had no Bash under the scenario grant, so the main thread ran every test.
```
