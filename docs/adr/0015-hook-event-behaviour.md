# ADR 0015: hook event behaviour - what blocks, where prompt hooks run, SessionStart `source`

- Status: accepted (findings); proposed (the SW-69 enforcement mechanism, under Decision)
- Date: 2026-09-26
- Source spec: Jira SW-66 (spike for E11 / SW-65)
- Relates to: SW-67 (SessionStart context), SW-68 (PreCompact state), SW-69 (Stop close-out
  gate), SW-70 (PostToolUse handoff integrity); ADR 0012 (hook latency budget); ADR 0013 (the
  probe pattern this one follows); SW-80 (e2e permission posture - see Findings)
- Supersedes: none

## Context

E11 plans four stories on hook events specwright has never used: SessionStart, PreCompact, Stop
and PostToolUse. Each assumed behaviour from the documentation. Nothing in the repo had observed
it. The three shipped hooks exit 0 on every path (CLAUDE.md hard rule 1), so exit-2 semantics had
never run here at all.

The spike had to answer four questions definitively, against the installed CLI:

1. Which events block on exit 2 - Stop, SubagentStop, PreCompact - and is PostToolUse
   observe-only?
2. Is the prompt-type hook form (`"type": "prompt"`) available, and on which events?
3. Does SessionStart re-fire on `--continue`, `--resume` and `--fork-session`, and with what
   `source`?
4. What does a hook on each event cost on Windows PowerShell 5.1?

## Method

- Claude Code `2.1.283`, Windows 11 (10.0.26200), headless `claude -p --model haiku`.
- `tests/e2e/probe-hook-events.ps1`. It builds one throwaway sandbox per case under
  `C:\sw66-<ts>`: a fake home with `HOME`/`USERPROFILE` pointed at it, `--setting-sources project`,
  and no `.claude` in any parent directory (the SW-73 guard).
- Every sandbox workspace wires a recorder hook, `record.ps1`, run by `powershell -NoProfile
  -ExecutionPolicy Bypass -File` (PS 5.1, the shipped template's convention). It is wired on
  SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop, SubagentStop, PreCompact and
  SessionEnd. It appends the raw stdin payload to `events.jsonl`. For the event under test it
  blocks exactly once, with a token the model is asked to repeat.
- The runs use `--permission-mode dontAsk` with no `--allowedTools` and no
  `--dangerously-skip-permissions`. Both of those can override a hook's decision, which is the
  behaviour under test (see `tests/e2e/README.md`, "Permission mode").
- Evidence is never the model's account:
  - Blocking: the fire count and `stop_hook_active` on the re-fire, from the payloads.
  - PreCompact: a `compact_boundary` in the transcript, checked against a log-only control.
  - PostToolUse: whether the written file survived.
  - Prompt hooks: the `--debug-file` log.
- Total cost of the final evidence set: USD 0.52 across 22 invocations.
- The raw evidence stayed on the author's machine under `C:\sw66-dev\` (not committed; the probe
  regenerates it). `-EvaluateOnly` re-derives the report from it at no cost.

## Evidence

### Q1 - blocking

| Event | Hook output | Observed | Evidence |
|---|---|---|---|
| Stop | exit 2 + stderr | **Blocks.** The turn continues; Stop re-fires with `stop_hook_active: true`; the stderr text reaches the model | Stop x2; token in the final result |
| Stop | stdout `{"decision":"block","reason":...}`, exit 0 | **Blocks**, same as exit 2 | Stop x2; token in the final result |
| SubagentStop | exit 2 + stderr | **Blocks.** The subagent continues; the re-fire carries `stop_hook_active: true` | SubagentStop x2; token in `subagents/agent-*.jsonl` |
| PreCompact | exit 2 + stderr | **Blocks compaction.** The `-p` result text is `Compaction blocked by PreCompact hook: [<command>]: <stderr>`, with `is_error: false` | No `compact_boundary`; no `SessionStart source=compact`. The control compacts (boundary present) |
| PostToolUse | exit 2 + stderr | **Observe-only.** The write is not undone; the stderr text does reach the model | `probe.txt` exists with `hello`; token in the transcript |

### Q2 - prompt-type hooks

Each entry was `{"type": "prompt", "prompt": "...$ARGUMENTS...", "timeout": 30}` and answered
`{"ok": false, "reason": ...}`. Each case put the prompt hook on one event. No settings file was rejected at
load: whether a prompt hook runs is decided only when its event fires.

| Event | Observed | Effect of `ok: false` | Duration (debug log) |
|---|---|---|---|
| Stop | **Runs** | Blocks, like exit 2. The CLI wraps the prompt as "has the following stopping condition been satisfied? Answer based on transcript evidence only" | ~0.94 s |
| SubagentStop | **Runs** | Blocks; same wrapper | ~1.05 s |
| UserPromptSubmit | **Runs** | The prompt is dropped (`prompt.submit: dropped (Operation stopped by hook ...)`) | ~4.4 s (first model call of the session) |
| PreToolUse | **Runs** | The tool call is blocked (`probe.txt` never written) | ~0.91 s |
| PostToolUse | **Runs** | The write stays (observe-only, as in Q1) | ~0.89 s |
| SessionStart | **Rejected at run time**: `prompt-type hooks are not supported for SessionStart events (no conversation context is available)`. It is a non-blocking error; the session goes on | none | - |
| PreCompact | **Silently skipped.** The command hook on the same event ran and compaction went ahead. No prompt-hook trace, no error | none | - |

### Q3 - SessionStart `source`

One sandbox, four chained invocations:

| Entry point | Fired | `source` | `session_id` |
|---|---|---|---|
| fresh `claude -p` | yes | `startup` | A |
| `--continue` | yes | `resume` (there is no `continue` value) | A |
| `--resume A` | yes | `resume` | A |
| `--resume A --fork-session` | yes | `fork` | **B** (new) |
| after `/compact` (PreCompact control) | yes | `compact` | A |

### Q4 - latency (PS 5.1 vs pwsh, same workstation)

This was measured by replaying one captured payload per event through the log-mode recorder: 20
runs after 2 warm-ups (the method mirrors `tests/hooks/measure-latency.ps1`). It measures process
cost only, not the CLI's own dispatch.

| Event | 5.1 p50 / p95 ms | pwsh p50 / p95 ms | In-hook work, live p50 ms |
|---|---|---|---|
| SessionStart | 337 / 382 | 418 / 454 | 8.8 |
| UserPromptSubmit | 334 / 341 | 422 / 445 | 8.5 |
| PreToolUse | 329 / 342 | 418 / 463 | 8.2 |
| PostToolUse | 329 / 341 | 422 / 457 | 9.2 |
| Stop | 333 / 355 | 419 / 442 | 8.6 |
| SubagentStop | 335 / 358 | 425 / 461 | 8.7 |
| PreCompact | 336 / 367 | 427 / 444 | 8.3 |
| SessionEnd | 334 / 351 | 425 / 450 | 8.2 |

The event makes no difference: roughly 97% of the cost is the shell starting up. Under ADR 0012's
rule (p95 at most timeout/2), every event fits a 5 s timeout on both shells. 5.1 is faster than pwsh,
the same order as ADR 0012's CI numbers, not the one reversed workstation reading in
`docs/architecture.md`.

## Decision

Go/no-go per child story:

| Story | Verdict | Constraints this ADR puts on it |
|---|---|---|
| SW-67 SessionStart context | **GO** | Command-type only (prompt hooks are rejected). Handle `source` values `startup`, `resume` (which covers `--continue`), `fork` and `compact`. Do not expect a `continue` value. |
| SW-68 PreCompact state | **GO** | Command-type only (prompt hooks are silently skipped: the most dangerous failure mode). Exit 2 **blocks compaction**, so the hook must never exit 2 on its own errors (hard rule 1 already requires this). The re-injection point after a compaction is `SessionStart` with `source: compact`, which SW-67's hook can serve. Only the `manual` trigger was exercised; `auto` fires the same event with `trigger: auto` per the payload schema, but that was not observed. |
| SW-69 Stop close-out gate | **GO** | Both exit 2 and JSON `decision: block` block. The hook **must** read `stop_hook_active` and allow the stop when it is true, or a gate the model cannot satisfy loops until the budget runs out. |
| SW-70 PostToolUse handoff integrity | **GO, as a flag** | PostToolUse cannot undo anything; exit 2 only reaches the model as feedback. That matches the story's "flags" wording. Anything that must *prevent* an out-of-scope edit belongs in PreToolUse (spec-gate's territory). Narrow the matcher to `Edit|Write|MultiEdit`: at about 330 ms per spawn, a `*` matcher taxes every Read and Grep. |

**SW-69 mechanism (proposed).** Prompt hooks do run on Stop, and the ticket asks for that choice
to be recorded before the story starts. The proposal is to **keep a command hook as the
enforcement mechanism**, for four reasons:

1. **The gate state is in `.specs/`, not the transcript.** The CLI tells a Stop prompt hook to
   judge "based on transcript evidence only", and it cannot read files. A command hook can read
   `00-spec.md` directly.
2. **It is deterministic and testable.** It can be tested by piping JSON fixtures in, like the
   other hooks (CLAUDE.md "Commands"). A model verdict can't be asserted in the fixture suites.
3. **Cost.** A prompt hook adds about 1 s and a model call to every Stop.
4. **It ships the same way.** A command hook fits the PowerShell/bash pair rule and the latency
   budget machinery (ADR 0012).

A prompt hook stays a candidate as an optional second layer, for "did the transcript actually
present the gate?", if SW-69 finds the file check alone too weak. That is left to the story.

## Findings from getting there

- **An untrusted workspace ignores project `permissions.allow` in `-p` mode.** stderr says
  `Ignoring N permissions.allow entries from .claude/settings.json: this workspace has not been
  trusted`, so the first PostToolUse run never wrote anything. The fix is
  `projects["<ws>"].hasTrustDialogAccepted: true` in the fake home's `.claude.json`, which the
  probe now writes. This bears directly on SW-80, whose candidate posture is project
  `permissions.allow`.
- **The Agent tool ran under `dontAsk` without any grant in effect** (the SubagentStop cases ran
  before the trust fix, so their `allow` entry was ignored). Spawning a subagent is not gated the
  way Write is.
- **Hook text leaks into the transcript.** A failed prompt hook becomes a
  `hook_non_blocking_error` attachment that includes the prompt. `/compact` output lists each
  hook's full command line. The first evaluator treated "token found in the transcript" as proof
  that a prompt hook ran, and got SessionStart and PreCompact wrong. The probe now reads only the
  debug log for Q2. Two lessons for E11: nothing secret belongs in a hook command line, and
  transcript text is not proof that a hook ran.
- **SessionEnd fires on every `-p` exit.** It was recorded but not needed by any E11 story.

## Consequences

- SW-67 through SW-70 are unblocked, with the constraints in the Decision table.
- The hook-event lists in `README.md` ("Hook contract"), `docs/troubleshooting.md`,
  `commands/setup.md`, `CONTRIBUTING.md` and `docs/architecture.md` still name three events. Each
  child story updates them when it ships a hook. This spike changes no shipped hook or template.
- Re-run `tests/e2e/probe-hook-events.ps1` when the minimum `claude` version is raised, or before
  building on an event it does not cover.
