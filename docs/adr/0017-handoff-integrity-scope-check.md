# ADR 0017: handoff integrity - PostToolUse flags edits outside the ready tasks' declared Files

- Status: accepted
- Date: 2026-09-27
- Source spec: Jira SW-70 (`FEAT-handoff-integrity`, E11 / SW-65)
- Relates to: ADR 0015 (hook event behaviour - PostToolUse is observe-only, "GO, as a flag");
  ADR 0012 (hook latency budget); ADR 0016 (stop-gate - the spec selection and the opt-in shape
  reused here); `skills/sd-atomic-task-format/SKILL.md` (task block, check-off marker, field label
  grammar)
- Supersedes: none

## Context

`sd-implementer` may edit only the files in its task's `Files` field. Nothing checked that. In
`/sd:feature` Phase 4 the main thread is told to self-check "did the implementer stay within
`Files`?", which is a model reading a diff. The first mechanical check was `/sd:verify` at
close-out, several tasks later.

ADR 0015 settled what PostToolUse can do. It fires after a successful tool call. Exit 2 undoes
nothing, but its stderr reaches the model in the same turn. So the story can *report* drift where
it happens; it cannot *prevent* it. Prevention would belong in PreToolUse, where `spec-gate`
already runs.

The question this ADR answers is what "the active task" is. Nothing on disk says which task is
being executed:

- `02-tasks.md` records only `Status: open | done` per task. There is no "in progress" marker, and
  adding one would change the check-off contract that `/sd:feature`, `/sd:refactor`, `/sd:port`,
  `/sd:spec validate` and `/sd:status` all read.
- The implementer receives its task block inline (`TASK_DETAILS`) in the Agent prompt, not
  through a file.
- `/sd:refactor` runs up to three tasks of a batch in parallel, so "the" active task is not always
  one task.
- `/sd:bug` and `/sd:perf` have no `02-tasks.md`; their `TASK_DETAILS` is ad hoc.

## Decision

`handoff-integrity` is a PostToolUse command hook, a PowerShell/bash pair, wired with the matcher
`Edit|Write|MultiEdit` (ADR 0015: never `*`).

1. **Which spec.** The newest spec ID in the last 256 KB of the transcript whose folder has a
   `00-spec.md` with status `in-progress` and a `02-tasks.md`. This is stop-gate's selection with
   one more condition: tasks are only executed while a spec is `in-progress`. There is no fallback.
   A session driving no such spec is never flagged.
2. **Which task: the ready set.** Every unchecked task whose `Depends on` tasks are all checked.
   The declared files are the union of their `Files` values. "Checked" follows the skill's
   check-off rules exactly: `Status` decides when present, and a `[x]` or check-mark heading
   prefix counts only when `Status` is absent. A dependency on an ID the file does not define
   counts as met. No ready task means no active task, so the hook does nothing.
3. **Parsing.** It follows the skill's field label grammar: `-`/`*` bullet, optional `**`, colon
   inside or outside the emphasis, any case. A value runs until the next *known* label, so a
   multi-line `Files` value keeps its nested bullets. `<!-- ... -->` comments are removed first.
   Each `Files` entry drops backticks, quotes, a trailing `(...)` note and anything after the
   first blank. An entry matches the edited path exactly, as a directory when it ends in `/`, or
   as a wildcard when it contains `*` or `?`. Paths compare case-insensitively.
4. **Never flagged:** a file outside the project root (scratch files, temp files), and a file
   under the spec directory. The main thread writes check-offs, retro lines and decisions there.
5. **Output.** stdout `{"decision":"block","reason":"..."}` and exit 0, the shape stop-gate uses
   (ADR 0016). On PostToolUse this means "tell the model", not "block": the edit is already on
   disk, and the reason says so. The reason names the file, the spec and the ready task IDs. It
   tells the model to revert an out-of-scope edit, or to stop and surface a scope mismatch for a
   re-plan (`sd-replan-loop`). It must not widen the task silently.
6. **Opt-in.** Nothing happens unless `hooks.handoffIntegrity.enabled` is the literal JSON `true`,
   like `stopGate`. `examples/fixture-project/` enables it, so the nightly e2e runs it.

## Latency (the SW-50 gate)

The ticket required closing the story if the SW-50 budget could not be met. It was met.
`tests/hooks/measure-latency.ps1 -CheckBudget`, same workstation, 2026-09-27, 30 iterations per
case after 2 warm-ups:

| Hook | Flavor | p50 ms | p95 ms | Budget p95 ms |
|---|---|---|---|---|
| `handoff-integrity` | powershell (5.1) | 494 | 575 | 1200 |
| `handoff-integrity` | pwsh | 609 | 635 | 1300 |
| `spec-gate` (same run, for reference) | powershell (5.1) | 464 | 689 | 1100 |

The cases are the ones in `latency-selection.json`: disabled, in scope, and flagged. Every run
matched its golden. When enabled, a write-tool call on 5.1 pays `spec-gate` before the tool and
this hook after it: about 1 s at p50 in total. The hook's own work is small next to process
start-up (ADR 0015 Q4: about 330 ms of every spawn).

The budgets are 1200 ms p95 (5.1) and 1300 ms (pwsh): about 2x the measured p95, rounded up to 100 ms, as ADR 0012 sets them.
The ceiling is 2500 ms: half of the 5 s timeout, which `measure-latency.ps1` verified. A disabled hook
still costs a process start per write-tool call, because the flag is read inside the process. That is why
the matcher stays narrow and the wiring is documented as opt-in.

## Alternatives considered

- **An explicit active-task marker.** The main thread would write the task ID it is executing,
  either as a new `Status` value or a `.claude/.hookstate/` file, before invoking the
  implementer. That would be exact, but it edits the feature, refactor and port prompts and
  relies on a model making that write. A model that skips it also silences the check. Rejected
  for this story; it is the natural next step if the ready set proves too coarse.
- **All open tasks.** Simpler, with no dependency logic, but any file planned anywhere in the
  remaining plan would count as in scope. The ready set costs a few lines more and narrows that
  to the tasks that can actually be running.
- **Tell implementer edits from main-thread edits.** The recorded SW-66 payloads contain no
  subagent tool call, so it is not established that PostToolUse carries `agent_type` inside a
  subagent. The hook does not depend on it. A main-thread code edit during execution is out of
  plan too, so flagging it is correct.
- **Exit 2 with stderr.** ADR 0015 observed this channel on PostToolUse. The JSON form was
  chosen to keep "every hook exits 0" literally true, as ADR 0016 did, and it is observed too
  (see Evidence below).
- **Do the check in PreToolUse.** That would prevent the edit instead of reporting it, but
  spec-gate already pays one process start there. A second hook doubles that cost, and a
  model-authored `Files` list mistake would then block legitimate work. It is out of scope; the
  story reports drift.

## Evidence: the JSON channel on PostToolUse

`tests/e2e/probe-hook-events.ps1 -Case posttooluse-json` ran on 2026-09-27 against commit
`3c55d0b` (Claude Code 2.1.283, Windows 10.0.26200, haiku, `dontAsk`, USD 0.02). PostToolUse fired
once, on `Write`. The written `probe.txt` stayed on disk with its content, so nothing was undone.
The hook's token reached the transcript, so the reason reached the model. The token is built
inside the recorder script, not on the hook command line, so ADR 0015's "hook text leaks into the
transcript" caveat does not apply. The output channel this hook uses is therefore observed, not
assumed.

## Consequences

- An out-of-scope edit is reported in the turn it happens. The 40 fixtures in
  `tests/hooks/fixtures/handoff-integrity/` assert the flag, the silent in-scope cases and the
  no-op cases identically for PowerShell and bash.
- **Known gaps:**
  - The ready set over-approximates. With two tasks ready, an edit into the *other* ready task's
    file is not flagged.
  - Out of reach: `/sd:bug` and `/sd:perf` have no `02-tasks.md`, so their implementer edits
    are not checked.
  - `Files` entries containing spaces are cut at the first blank. A path with a space would be
    flagged even when it is declared.
- **Drift.** The parser restates the task-block grammar of `sd-atomic-task-format`. A change to
  the check-off marker or the label set there must update both hook twins and their fixtures.
