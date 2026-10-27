# SW-93 - lean task format, measured live

Spike under epic SW-87, run as part of SW-106. No engine change. ADR 0023 deferred this
measurement because a live run needed the developer's `~/.claude/.credentials.json`, which can log
out the real CLI. SW-106 removed that need (`run-e2e.ps1` now authenticates from
`CLAUDE_CODE_OAUTH_TOKEN` and copies the file only with `-CopyCredentials`), so the run below is the
acceptance measurement ADR 0023 left open.

**Verdict.** SW-93's criterion, "`01-plan.md` + `02-tasks.md` at least 50% smaller than SW-88's
401 lines for the M scenario", is **met**: 111 lines in the complete run (72% smaller) and 97 in a
second, partial run (76% smaller). The threshold is 200 lines. Both runs are far below it, so the
verdict does not depend on which run is taken. Both are single runs (n = 2, one complete).

## Method

- Scenario `90-spike-feature-m`: re-created from Appendix A of
  [SW-88](SW-88-feature-baseline.md) (`/sd:feature todo-due-date`, "expect 5-8 tasks"), with the
  gate replies sent as their own turns (SW-103 format) instead of one scripted "yes". It was a
  scratch scenario, listed in `.git/info/exclude` and never committed. Its `expect.json` held four
  `file-exists` checks (`00-spec`, `01-plan`, `02-tasks`, `06-verify`).
- Two runs, in order, with `SD_E2E_TRANSCRIPT=1`, from a PowerShell 7 window outside the editor so
  the host session's environment did not reach the child `claude`:
  - **Run 1**: three `yes` replies. It stopped at Gate 3 and wrote no `06-verify.md` (see caveat 1).
  - **Run 2**: the same scenario with a fourth, spare `yes`. It completed.
- Every figure comes from a scratch script that read the kept transcript, the kept workspace and
  the `-ResultsFile` JSON. Nothing was counted by eye. The script is not committed.
- Definitions:
  - **Phase time**: SW-88's definition. The gap between the first main-thread assistant text that
    narrates `Phase N - ...` and the one for `Phase N+1`. Phase 0 runs from session start. Phase 6
    runs to the last transcript event.
  - **3a, Gate 2, 3b**: Phase 3 split by the two `sd-spec-architect` calls (ADR 0022).
    3a is the Phase 3 marker to the first architect's return. Gate 2 is that return to the second
    architect's launch, so it includes the turn boundary the reply crosses. 3b is the second
    architect's launch to its return. A few seconds between 3b's return and the Phase 4 marker are
    not in any of the three.
  - **Lines**: physical lines of the file (`splitlines`), as SW-88 counted.
  - **Lean parse**: each `### T..` block was checked against `sd-atomic-task-format`. The five core
    fields (`Files`, `Acceptance`, `Covers`, `Depends on`, `Status`) must be present, and `Status`
    must be last. No legacy field (`Layer`, `Step type`, `Test`, `Conflicts with`) may appear, and
    no default may be written out (`Estimated complexity: M`, `Reversibility: trivial`).
    `Pattern refs` must be present exactly when a `Files` entry carries `(new)` or `(new symbol)`.

## Environment

| Item | Value |
|---|---|
| Date | 2026-10-27, UTC 15:16-15:39 (the M runs) |
| claude CLI | 2.1.306 |
| OS | Windows 10.0.26200, pwsh 7.6.9, node from PATH |
| git commit | `378324f`: `develop/v1` at `1c3ae45` (SW-93 merged) plus the two SW-106 commits, which touch only `tests/e2e/`, the README and the changelog. The engine is unchanged from `1c3ae45` |
| Auth | `CLAUDE_CODE_OAUTH_TOKEN` (subscription). `authMode` in both results files says so |
| Served models (run 2) | main thread `claude-sonnet-5-5`; `sd-spec-architect` and `sd-reviewer` `claude-sonnet-5-5`; `sd-code-explorer` and four of five `sd-implementer` calls `claude-haiku-5-5`; the T05 implementer `claude-sonnet-5-5` (T05 carries `Estimated complexity: L`, which is the ESC-FEAT-04 escalation) |

## Results

### M scenario

| Metric | SW-88 | SW-92 | SW-93 run 2 (complete) | SW-93 run 1 (stopped at Gate 3) |
|---|---|---|---|---|
| Phase 3 total | 146 s | 106 s | 121.1 s | 90.7 s |
| - 3a outline | - | 41 s | 48.8 s | 31.6 s |
| - Gate 2 | - | 20 s | 28.1 s | 27.2 s |
| - 3b expansion | - | 45 s | 37.3 s | 26.1 s |
| `01-plan.md` lines | 157 | 76 | **59** | 47 |
| `02-tasks.md` lines | 244 | 144 | **52** | 50 |
| **Plan + tasks** | **401** | **220** | **111** | **97** |
| Task count | 6 | 6 | 5 | 5 |
| `00-spec.md` / `03-decisions.md` lines | 206 / 82 | n/a | 209 / 78 | 187 / 105 |
| Spec artifacts 00-03 | 689 | n/a | 398 | 389 |
| Whole run | 634.3 s, $2.25 | 583 s, $1.76 | 628.4 s, $1.86 (5 turns) | 546.7 s, $1.42 (4 turns, incomplete) |
| Harness result | pass, 4/4 | n/a | pass, 4/4 | fail, 3/4 (no `06-verify.md`) |

SW-92's column is quoted from ADR 0022 "Measured"; it did not record the spec and decisions lines.

Phase times of run 2: Phase 0 28.4 s, Phase 1 112.3 s, Phase 2 49.8 s, Phase 3 121.1 s, Phase 4
195.6 s, Phase 5 85.4 s, Phase 6 33.2 s (sum 625.8 s, the transcript span). SW-88's M run had 20,
82, 60, 146, 203, 46 and 75 s.

### Lean format check (both runs)

All 10 task blocks (5 per run) parse as lean blocks: the five core fields are present, `Status` is
last, no legacy field appears, and no default is written out.

- Run 2: T01, T02 and T04 carry `Pattern refs`, and each has a `(new symbol)` marker in `Files`.
  T03 and T05 do not, and carry none. T05 also carries `Estimated complexity: L`, which is the one
  non-default value the format asks for.
- Run 1: T01, T03 and T05 carry `Pattern refs` with the same marker. T02 and T04 do not.

So "only the 5 core fields" holds for the always-present set. The extra fields that appear are the
conditional ones ADR 0023 allows, and each is present for the reason the format gives.

### S scenario (`02-feature-happy`, run for the SW-106 auth check)

| Metric | SW-88 S | SW-93 (this run) |
|---|---|---|
| `01-plan.md` + `02-tasks.md` | 57 + 31 = 88 | 37 + 27 = **64** |
| Whole run | 318.6 s, $1.36 | 360.8 s, $1.27 (5 turns) |
| Harness result | pass, 14/14 | pass, 25/25 |

This run kept no transcript, so there are no phase times. The S figures are a side observation,
not part of the criterion.

## Auth check (SW-106)

- All four live harness invocations (`02-feature-happy`, the two M runs and `-SelfTest`) ran with
  `CLAUDE_CODE_OAUTH_TOKEN` and without `-CopyCredentials`. Their `authMode` reads
  `subscription (CLAUDE_CODE_OAUTH_TOKEN)`.
- A watcher polled the sandbox root once every 0.7 s from before the first run. It saw 7 fake
  homes created after it started (3 during the first three runs, 4 during `-SelfTest`) and found
  `.credentials.json` in none. It recorded names and existence only.
- After the runs, the kept fake homes of `02` and of both M runs held no `.credentials.json` and no
  file with "credential" in its name.
- `-SelfTest` passed: the offline auth cases (9/9), then all four guard runs were detected
  (`always-allow` and `malformed-deny`, on scenarios 03 and 04). It cost $0.21.
- Total spend for SW-106's live checks: about $4.77 ($1.27 + $1.42 + $1.86 + $0.21).

## Caveats

1. **Both M runs hit the same permission stall, and it cost run 1 its Gate 3.** At T01 the main
   thread ran `npm test` through the PowerShell tool. The scenario grants only `Bash(npm test:*)`
   under `dontAsk`, so the call was refused, the session asked, and the next `yes` reply went to
   that instead of Gate 3. Run 1 had no reply left, so it stopped at Gate 3. Run 2 had the spare
   reply and finished. The stall cost about 16 s in run 2. The cause is the scenario's grant, not
   the lean format or the auth change; it belongs to the follow-up on `npm test` permissions
   (SW-105).
2. **n = 2, and only one run is complete.** Differences under about 20% are noise at this size.
   Phase 3 took 121 s in run 2 and 91 s in run 1 for the same scenario, a 25% spread. Do not read
   the whole-run time (628 s against SW-92's 583 s) as a regression or a gain. The size
   figures are the result.
3. **The SW-88 column was measured on a different machine.** SW-88 ran on Linux (a container) with
   `ANTHROPIC_API_KEY` and a main thread that was opus-class. SW-92 and SW-93 ran on Windows with the
   OAuth token and a `claude-sonnet-5-5` main thread. The SW-92 to SW-93 comparison shares an
   environment; the comparison with SW-88 does not. For size, that matters little (the files are
   what the architect wrote). For time, it matters, so none of the time columns above is a claim.
4. **Different run shape from SW-88.** SW-88 used one scripted "yes" within a single turn; the
   SW-92 and SW-93 runs send each gate reply as its own turn. The e2e README attributes SW-88's
   "no gate text printed" finding to that single-turn shape. Gate output was not measured here.
5. **The task count fell from 6 to 5 in both runs.** SW-88's M run had a verification-only task
   (T06, no `Files`); neither SW-93 run has one, and run 2 splits the work into code tasks and test
   tasks instead. Fewer tasks makes shorter files for a reason that has nothing to do with the
   format. A rough control: SW-88's 401 lines were about 67 per task, and run 2's 111 lines are
   about 22 per task, so the format still accounts for most of the cut. The two splits differ, so
   this is a sanity check, not a controlled comparison.
6. **Phase markers.** A phase counts only when the narration reads `Phase N - ...`, so a forward
   reference such as "before Phase 5" does not set a marker. The first version of the script matched
   any mention and gave an impossible Phase 4 time for run 1; it was tightened, and both runs were
   re-measured.
7. **Not measured here:** gate output length and decision counts (SW-88 metrics 3-5), which need the
   gate-surface proxy and a judgment per item.
