# tests/e2e - headless behavioral eval harness (SW-27)

Drives real `claude -p` (headless) sessions against a throwaway copy of a fixture project and
asserts on **produced artifacts** - files, frontmatter, status values - never on transcript
wording. This is the only mechanism in the repo that exercises a real model session against the
engine's commands and hooks; everything else (`scripts/validate.*`, `tests/hooks/`,
`tests/contract-lint/`) checks the *assets* (do commands/agents/skills reference each other
correctly) or pipes fixture JSON directly into a hook script in isolation. Neither proves the
engine *behaves* correctly end-to-end through a real session - see `examples/spec-lint-fixture/README.md`
for the gap this closes (`/sd:spec validate` is a prompt, not executable code, so no script can run
it - this harness runs it for real instead of reimplementing the rules).

## The rule: assert artifacts, never prose

A model's phrasing varies run to run; the files it must produce, and their frontmatter/status
values, do not. Every `expect.json` in `scenarios/*/` asserts on file existence, file content
patterns, or (only for the one report-only command, scenario 5) presence of specific structured
rule-ID tokens in the final output - never on sentence-level wording. Any assertion that flakes
twice gets deleted or rewritten, not retried.

## Prerequisites

The runner checks all of these before it builds any sandbox. A missing one exits `2` and names the
dependency; it never shows up as a failed scenario assertion.

- PowerShell 7+ (`pwsh`). This is a single cross-platform runner by design, the same as the other
  parity harnesses. See [CONTRIBUTING.md "Test suites and
  prerequisites"](../../CONTRIBUTING.md#test-suites-and-prerequisites) for why.
- `claude` CLI on `PATH`, **v2.1.196 or later**.
- **One** way to authenticate `claude`. **No API key is needed**: a Claude subscription works. See
  [Auth](#auth) below.
- Node.js (`node`, `npm`), only for scenarios that declare it in `requires.txt` (`01-setup`,
  `02-feature-happy`, `06`-`10`).
- A sandbox root with no `.claude` directory in it or in any directory above it. The defaults
  already meet this; see [the ancestor-walk rule](#the-ancestor-walk-rule-sw-73) below.

## Running it

```powershell
# Full suite
.\tests\e2e\run-e2e.ps1

# One scenario, for debugging
.\tests\e2e\run-e2e.ps1 -Case 03-spec-gate-negative

# Prove the harness would catch a removed guard (see "Self-test" below)
.\tests\e2e\run-e2e.ps1 -SelfTest

# Verbose: prints claude's exit code/result/cost and the workspace's events.jsonl per scenario
$env:SD_E2E_DEBUG = '1'; .\tests\e2e\run-e2e.ps1

# Keep the throwaway workspace and fake home after a run instead of deleting them (debugging only)
$env:SD_E2E_KEEP = '1'; .\tests\e2e\run-e2e.ps1 -Case 01-setup

# Keep the session transcript too: drops --no-session-persistence and implies SD_E2E_KEEP. The
# transcript lands under <fakeHome>\.claude\projects\ (the path is printed) (SW-79)
$env:SD_E2E_TRANSCRIPT = '1'; .\tests\e2e\run-e2e.ps1 -Case 02-feature-happy

# Also write the run as JSON: date, mode, claude version, auth mode, OS, git commit, and per
# scenario the result, assertion counts, exit code, total_cost_usd and duration (SW-77). It holds
# no prompt, transcript or credential, and is written for full, -Case and -SelfTest runs alike
.\tests\e2e\run-e2e.ps1 -ResultsFile C:\sd-e2e-results\run1-suite.json
```

### Reproducibility runs (SW-77)

SW-27's acceptance bar is "green 3 times consecutively". To measure it, use one machine and one
`claude` version, and run the full suite and then `-SelfTest` three times in a row, each with its
own `-ResultsFile`:

```powershell
$out = 'C:\sd-e2e-results'
foreach ($i in 1..3) {
    .\tests\e2e\run-e2e.ps1           -ResultsFile "$out\run$i-suite.json"
    .\tests\e2e\run-e2e.ps1 -SelfTest -ResultsFile "$out\run$i-selftest.json"
}
```

A red run restarts the count. An assertion that fails in one run and passes in another is flaky:
rewrite or delete it (see the rule above), never retry it.

Not wired into the per-PR `ci.yml` job - see "CI placement" below.

## Isolation and auth

Each scenario gets a fresh "fake home" directory with the engine installed into it via
`install.ps1 -BasePath <fakehome>/.claude` - the same sandbox recipe CLAUDE.md documents and the
CI install/uninstall round-trip job already uses - plus a fresh workspace directory holding the
project under test (a throwaway copy of `examples/fixture-project` or
`examples/spec-lint-fixture/broken`, per scenario). The `claude` subprocess runs with
`HOME`/`USERPROFILE` pointed at the fake home and cwd set to the workspace, so `~/.claude/...`
(used literally in command prompts, e.g. `commands/setup.md` Phase 0) and `${HOME}` (used in
`settings.json` hook command strings) both resolve into the sandbox, never the real user install.
`--setting-sources project` is passed as a second, independent guarantee that no real user-scope
settings can merge in. Both directories are deleted after every run.

### The ancestor-walk rule (SW-73)

Neither of those guarantees covers the directories *above* the workspace. When no git root stops
the walk, Claude Code loads every ancestor `.claude/` directory of the cwd as **project** scope,
and project scope outranks the fake home's user scope. The fixture workspaces have no `.git`, so
the walk runs all the way to the filesystem root. On Windows, `GetTempPath()` is
`C:\Users\<user>\AppData\Local\Temp`, which is under the user profile. The walk therefore reached
the real `C:\Users\<user>\.claude`, and its agents and skills shadowed the engine under test (a
stale real `sd-implementer` was served the wrong model). On Linux and macOS, `/tmp` is not under
`$HOME`, so the leak never appeared there. Settings do **not** leak this way: a hook in an ancestor
`.claude/settings.json` did not fire, with or without `--setting-sources project`, while the same
hook in the workspace's own `.claude/settings.json` did (Linux, `claude` 2.1.282, 2026-09-25).
Only agents and skills walk up. The harness handles this in two steps:

- **Sandbox root outside the profile.** Fake homes and workspaces are created under
  `<SystemDrive>\sd-e2e\` on Windows (for example `C:\sd-e2e\`) and under `GetTempPath()` on Unix.
  Set `SD_E2E_ROOT` to use a different root on any OS.
- **Preflight guard.** Before any sandbox is built, the harness checks the root and every ancestor
  of it. If any of them contains a `.claude` directory, the harness refuses to run, names the path,
  and exits `2`, like any other missing prerequisite.

```powershell
# Use a custom sandbox root (no .claude folder in it or above it)
$env:SD_E2E_ROOT = 'D:\sd-e2e'; .\tests\e2e\run-e2e.ps1
```

Verified on Windows, 2026-09-25, `claude` 2.1.282: scenario `06-escalation-implementer` passed
under `C:\sd-e2e`. A kept-transcript `tests/e2e/probe-model-override.ps1 -Case feat04` run, which
uses the same drive-root layout, served every `sd-implementer` call that had no `model` parameter
on `claude-haiku-4-5-20251001`, the fake home's `model: haiku`. The real `~/.claude` still had a
conflicting `sd-implementer` with `model: sonnet` during that run. `run-e2e.ps1` keeps no
transcript by default (`--no-session-persistence`), so the served-model evidence comes from the
probe. `SD_E2E_TRANSCRIPT=1` (SW-79) now keeps one for any scenario.

`git init` in each workspace would also stop the walk, but it was not chosen: it changes the
fixture, and `/sd:setup` and other workflows can behave differently inside a git repository.

Tool-level file access is a **separate** sandbox from the OS-level `HOME` override: Claude Code
restricts Read/Write/Bash/Glob to the session's working directory plus any `--add-dir` grants, so
the fake home is explicitly added via `--add-dir` on every invocation - without it, Claude Code
correctly refuses to read `~/.claude/templates/sd/` even though `HOME` points there.

### Auth

Auth is the one piece that can't be fully sandboxed. The runner accepts any of these, checks them
in this order, and prints the mode it picked:

| Mode | How to get it | Billing | Where it fits |
|---|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | `claude setup-token` (one-time, long-lived) | Claude subscription | Local on any OS; CI as a repo secret |
| `~/.claude/.credentials.json` | An ordinary `claude` login (`/login`) | Claude subscription | Local on Windows and Linux |
| `ANTHROPIC_API_KEY` | Anthropic Console | API, per token | CI (the original nightly setup) |

- **Credentials file.** `run-e2e.ps1` copies the real `~/.claude/.credentials.json` into each fake
  home at setup time and deletes it on cleanup. It is never written anywhere persistent and never
  committed. On macOS the login is kept in the Keychain rather than in this file, so use
  `claude setup-token` there instead.
- **API key precedence.** `claude -p` prefers `ANTHROPIC_API_KEY` over a subscription credential.
  If both are present, the runner warns that the run will bill the API. Unset the key to run on the
  subscription.
- **Empty values.** An auth variable that is set but empty counts as absent. That is what an unset
  GitHub secret looks like. The runner removes such variables from the child `claude`
  environment.
- **Open question.** An earlier local run recorded that `claude -p` failed with `"Not logged in"`
  when it had a valid `ANTHROPIC_API_KEY` but no `.credentials.json`. The nightly workflow runs in
  exactly that configuration. Neither result has been re-checked since. If the nightly fails the
  same way, switch it to the `CLAUDE_CODE_OAUTH_TOKEN` secret. The workflow already passes both
  secrets.

### Model-override probe (manual)

`probe-model-override.ps1` is a separate, manual and paid script, not part of `run-e2e.ps1` or
CI. It is the reproducible method behind ADR 0013. It checks that `/sd:feature` passes the Agent
tool's `model` parameter when an escalation rule fires, and that the call is served on that tier.
The evidence is subagent `meta.json` and transcript `message.model`, never the model's own
account. Re-run it when the minimum `claude` version above is raised.

Two isolation facts it relies on also apply to this harness:

- On Windows, a sandbox under `%TEMP%` is under the user profile. With no git root to stop the
  walk, Claude Code loads the real `~/.claude` as project scope, which outranks the fake home. See
  SW-73.
- `--no-session-persistence` means `SD_E2E_KEEP=1` keeps no transcript. Use
  `SD_E2E_TRANSCRIPT=1` instead when you need one (SW-79).

## Permission mode - do not default to `acceptEdits`

This was the single biggest surprise building this harness, worth stating plainly: **verified by a
minimal repro (a trivial always-deny `PreToolUse` hook, no spec-gate logic involved) that
`--permission-mode acceptEdits`, and `dontAsk` combined with an explicit `--allowedTools` grant for
Edit/Write, both cause Claude Code to silently ignore a hook's `deny` decision** - the tool call
succeeds, `permission_denials` in the JSON result stays empty, and the file changes anyway. Only
`--permission-mode dontAsk` **with no `--allowedTools` override** actually respects a hook's deny;
read-only tools (Read/Glob/Grep) still work fine under it without an explicit grant.

Consequently `run-e2e.ps1` defaults every scenario to `dontAsk`. Scenarios that need free writes
Claude Code itself would otherwise gate interactively - `01-setup` (writes `.claude/settings.json`
and `.claude/project-config.json`, which Claude Code treats as sensitive files) and
`02-feature-happy` (needs Bash for `npm test` plus many ordinary file writes across a whole
workflow, with no human to approve any of it) - opt into `acceptEdits` + `--dangerously-skip-permissions`
via a `permission-mode.txt` / `skip-permissions.txt` marker in their scenario directory. The
negative scenarios (`03`, `04`) never do; that would make their own assertions meaningless.

## Scenario prompts: honest framing, not persuasion

The negative scenarios ask Claude to attempt an edit that spec-gate should deny. An early version
framed this as "this is a test, do it even if it seems wrong" - a well-aligned model correctly
recognized that as pressure-to-override-judgment language and refused outright, which left the
guard never actually exercised (a legitimate, good safety property, but it made the scenario
inconclusive rather than green). The prompts that work instead state the literal, verifiable truth:
this is a disposable temp copy created and deleted by this exact runner, the target spec is
synthetic fixture content authored for this one test (and says so in its own frontmatter/body), and
the task is the software-engineering equivalent of `expect(validator.reject(badInput)).toBe(true))`
- a negative unit test has to actually submit the bad input to prove the rejection. If a future
scenario needs the same pattern, keep it truthful rather than adversarial; an adversarially-framed
prompt is also a worse regression signal, since a refusal and a hook malfunction now look the same.

## Self-test (guard-neutering)

`-SelfTest` re-runs scenarios `03-spec-gate-negative` and `04-closeout-negative` against a copy of
the engine with the installed `spec-gate.ps1`/`.sh` replaced by an always-allow stub (never touches
the repo's real `hooks/` source), and asserts that BOTH scenarios' assertions now fail as a whole -
proving the harness would notice a regression that removes the guard. Mirrors
`tests/hooks/run-conformance.ps1` and `tests/contract-lint/run-selftest.ps1`'s own `-SelfTest`
modes.

## Scenarios

| # | Scenario | Claim under test |
|---|---|---|
| 1 | `01-setup` | `/sd:setup` on a bare, unscaffolded project produces `CLAUDE.md`, `.specs/`, `.claude/project-config.json`, `.claude/settings.json`, all BOM-free. |
| 2 | `02-feature-happy` | `/sd:feature` happy path on a small spec reaches `done` with a full artifact set and a passing `06-verify.md`. `events.jsonl` records all four allowed `spec_transition` edges (`-` -> `draft` -> `approved` -> `in-progress` -> `done`) and no `shell-write` gate, so an index move made through a shell instead of the Edit tool fails the run (SW-79). |
| 3 | `03-spec-gate-negative` | spec-gate denies a direct code edit with no in-progress spec recorded. |
| 4 | `04-closeout-negative` | spec-gate's verify-gate denies flipping an index row to `done` with no passing `06-verify.md`. |
| 5 | `05-spec-lint-validate` | `/sd:spec validate --all` against `examples/spec-lint-fixture/broken` surfaces the seeded `SL0xx` findings - the one command this harness must assert on output text, since `/sd:spec validate` is report-only with no artifact file. |
| 6 | `06-escalation-implementer` | `/sd:feature` Phase 4 resumed on a seeded 2-task spec under `models.escalation.ceiling: "sonnet"`: the `Estimated complexity: L` task logs exactly one uncapped, applied `escalation: sd-implementer haiku -> sonnet (trigger: ESC-FEAT-04)` line in `05-retro.md`; the `S` / `trivial` task logs none. |
| 7 | `07-escalation-disabled` | Same seeded spec under `models.escalation.enabled: false`, with T01 at `Estimated complexity: L` and T02 at `Reversibility: hard`: both tasks run and `05-retro.md` carries no `escalation:` line - the suppression covers `ESC-FEAT-04` and `ESC-FEAT-04b` alike. |
| 8 | `08-resume-checkoff` | `/sd:feature` re-invoked on a seeded 2-task spec whose T01 is already checked off (`Status: done`, code landed, retro line written) and T02 is `open`: the resume executes T02 only - `05-retro.md` gains a `T02:` line and still has exactly one `T01:` line, `countTodos` is not re-added - and both tasks end at the canonical `Status: done` marker (SW-71). |
| 9 | `09-resume-approved` | `/sd:feature` re-invoked on a seeded `complexity: L` spec that is `approved` with no `02-tasks.md` and no impact map (the approving session ended before Phase 2): the state machine resumes at **Phase 2**, not Phase 3. `03-decisions.md` gains exactly one `## Impact analysis (sd-code-explorer)` section, `05-retro.md` carries the applied `escalation: sd-code-explorer haiku -> sonnet (trigger: ESC-FEAT-02)` line, Phase 3 writes `02-tasks.md`, and the run stops at Gate 2 with status still `approved` and no code changed (SW-74). Under the pre-SW-74 table the first two assertions fail. |
| 10 | `10-resume-impact-mapped` | Control for 09: the same spec with the impact analysis already in `03-decisions.md`. The resume goes straight to Phase 3 (`impact-mapped`): still exactly one impact section, no `ESC-FEAT-02` line, `02-tasks.md` written, stopped at Gate 2 (SW-74). |

Each scenario directory may contain: `source.txt` (repo-relative base tree to copy),
`workspace/` (overlay applied on top - added/overwritten files only, mirrors the
`tests/contract-lint` `_base` + overlay fixture pattern), `prompt.txt` (the literal headless
prompt), `expect.json` (declarative assertions), and optional `budget.txt` / `timeout.txt` / `permission-mode.txt`
/ `skip-permissions.txt` / `disallowed-tools.txt` overrides. An optional `requires.txt` lists
commands the scenario needs on `PATH` (one per line, `#` comments allowed). The preflight checks it
for the selected scenarios only, so `-Case 03-spec-gate-negative` does not demand Node.

## Cost and CI placement

Not per-PR: a `claude -p` suite costs real tokens and minutes of wall clock, and neither belongs
in a gate on every push. It runs nightly (or on manual `workflow_dispatch`) on a single OS via
`.github/workflows/e2e-nightly.yml`.

**The cost trade-off per run.** One full 10-scenario run costs about **$7.55-$7.79** in
`total_cost_usd` and takes about **26-28 minutes** of wall clock, plus about **$0.26** for
`-SelfTest` (see the measured table below). With subscription auth, `total_cost_usd` is a notional
figure, and the run draws on the plan's usage allowance instead of dollars. With API-key auth it is
billed. The runs below used subscription auth. That makes the suite practical to run locally
before a PR, one `-Case` at a time for the cheap scenarios (`03`, `04`: about $0.15 each). It is no
longer only a nightly report to read afterwards. A full run plus `-SelfTest` fits inside the
nightly job's `timeout-minutes: 45`.

### Reproducibility runs, 2026-09-26 (SW-77)

Three consecutive full-suite runs, each followed by `-SelfTest`, on one machine: commit `7086d29`,
`claude` 2.1.283, Windows 10.0.26200, pwsh 7.6.6, subscription auth
(`~/.claude/.credentials.json`). The runs finished at 04:31, 04:58 and 05:26 UTC. Figures come from
`-ResultsFile` (per-scenario `total_cost_usd` from the `claude -p --output-format json` result):

| Scenario | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| `01-setup` | $0.42 | $0.47 | $0.49 |
| `02-feature-happy` | $2.57 (699 s) | $2.36 (613 s) | $2.34 (672 s) |
| `03-spec-gate-negative` | $0.13 | $0.13 | $0.13 |
| `04-closeout-negative` | $0.13 | $0.13 | $0.14 |
| `05-spec-lint-validate` | $1.01 | $0.99 | $0.90 |
| `06-escalation-implementer` | $0.74 | $0.75 | $0.72 |
| `07-escalation-disabled` | $0.63 | $0.65 | $0.62 |
| `08-resume-checkoff` | $0.59 | $0.55 | $0.62 |
| `09-resume-approved` | $0.92 | $0.92 | $1.07 |
| `10-resume-impact-mapped` | $0.65 | $0.61 | $0.69 |
| **Suite total** | **$7.79** | **$7.55** | **$7.71** |
| `-SelfTest` (`03` + `04`, neutered guard) | $0.25 | $0.26 | $0.26 |

Every scenario passed every assertion in all three runs, and `-SelfTest` detected the neutered
guard for both `03` and `04` each time.

**Acceptance bar "green 3 times consecutively" is met.** No assertion failed in one run and passed
in another, so none was rewritten or deleted. `02-feature-happy` ran for 613-699 s every time,
above the 600 s cap that killed it in the 2026-08-01 run. SW-79's `timeout.txt` (1500 s) keeps it
clear of the timeout now. The earlier 5-scenario measurement (2026-08-01, `claude` 2.1.220), whose
`02` timed out, is superseded by this table.

### Escalation scenarios (SW-61)

History: the SW-77 table above supersedes these first-run figures for cost.

First run of `06` and `07`, 2026-09-25, `claude` 2.1.282, Windows, subscription auth
(`~/.claude/.credentials.json`), one `-Case` at a time:

| Scenario | `total_cost_usd` | Assertions | Result |
|---|---|---|---|
| `06-escalation-implementer` | $0.7453 | 7/7 | pass |
| `07-escalation-disabled` | $0.6820 | 5/5 | pass |

In `06` the `ESC-FEAT-04` line was written before the T01 implementer call and no `unapplied`
suffix appeared, so the Agent tool accepted a `model` parameter on this CLI version. That is
the model's own account of the invocation, not a per-invocation model attribution read from a
transcript - it does not settle SW-59. (Settled since by ADR 0013, from transcript evidence.)

### Resume-from-approved scenarios (SW-74)

History: the SW-77 table above supersedes these first-run results.

First run of `09` and `10`, 2026-09-25, `claude` 2.1.282, Windows, subscription auth
(`~/.claude/.credentials.json`), one `-Case` at a time. `SD_E2E_DEBUG` was unset, so cost was not
recorded:

| Scenario | Assertions | Result |
|---|---|---|
| `09-resume-approved` | 6/6 | pass |
| `10-resume-impact-mapped` | 6/6 | pass |

`09` passing is the live proof of the SW-74 fix. Under the pre-SW-74 state machine, an `approved`
spec skipped Phase 2, and its impact-section and `ESC-FEAT-02` assertions fail. That was checked
offline against a simulated old-behavior workspace before the run. On Windows, run these with
`TMP`/`TEMP` pointed outside the user profile until SW-73 lands. Otherwise the sandbox also loads
the real `~/.claude`, including its installed `feature.md`.

## Known product gaps this harness surfaced

**1. [FIXED - SW-75] Rule 1 (`paths.protected`) made `/sd:feature` unable to complete under a
permission posture that actually respects hooks.** `.specs/index.md` is in `paths.protected` by
default, and `spec-gate` Rule 1 blocked every edit to it except Rule 0's FEAT `-> done` carve-out.
But every workflow records its own gates (`draft -> approved`, `approved -> in-progress`, ...) by
editing that row with the `Edit` tool. Scenario 2's run against the unmodified
`examples/fixture-project` config recorded the denials live:

```text
{"...","gate":"protected","decision":"block"}          <- draft -> approved edit
{"...","spec_id":"FEAT-todo-count","phase":"draft","event":"spec_transition","from":"-","decision":"block"}
{"...","gate":"protected","decision":"block"}          <- approved -> in-progress edit
{"...","spec_id":"FEAT-todo-count","phase":"approved","event":"spec_transition","from":"draft","decision":"block"}
{"...","gate":"protected","decision":"block"}          <- in-progress -> done edit (also hits Rule 1 first)
{"...","spec_id":"FEAT-todo-count","phase":"in-progress","event":"spec_transition","from":"approved","decision":"block"}
...
{"...","spec_id":"FEAT-todo-count","phase":"done","event":"gate","gate":"verify","decision":"allow"}   <- Rule 0 finally allows the LAST one
```

The edits landed only because scenario 2 runs with `--dangerously-skip-permissions`, which
overrides a hook's deny. SW-75 added **Rule 0b** to both `spec-gate` implementations. It rebuilds
the post-edit `index.md` and allows the edit only when its net effect is new rows at
`draft`/`approved` and/or Status-only moves along a workflow edge. A FEAT `-> done` move still
needs Rule 0's verify artifact. Anything else (title change, deleted row, illegal jump) is still
blocked. `tests/hooks` covers both sides (`allow-index-*` / `block-index-*` fixtures).
**Live re-run, 2026-09-25** (Windows, CLI 2.1.282, subscription auth): `02-feature-happy`, `03`,
`04` and `-SelfTest` were all green. Scenario 02's `events.jsonl` recorded no
`"gate":"protected","decision":"block"` line; the previous run recorded three. That run also
showed the `spec_transition` metric missing partial Status-cell edits, so Rule 0b now records
transitions from its own diff (`metrics-transition-partial-edit` fixture). **Still open:** scenario
2 still runs with `skip-permissions` for its Bash steps (`npm test`), and that overrides hook
denies. SW-27's "no skip-permissions" bar therefore needs a Bash grant that does not override hook
denies. That work is tracked with SW-80, not here.

**Update, 2026-08-01 full-suite run:** this time `02-feature-happy` did not merely proceed despite
repeated Rule 1 denials - it stalled outright and hit the 600s timeout. `events.jsonl` shows the
same three blocked transitions, one allowed code-edit, then a `subagent_stop` with `"stale":1` at
06:24:03, and nothing further before the kill at 06:27:28.

**Resolved (SW-77).** `02` did not stall in any of the three consecutive 2026-09-26 runs after
SW-75 and SW-79. It passed every time, taking 613-699 s, which is longer than the old 600 s cap.
So the 2026-08-01 kill is at least partly explained by that cap alone. SW-79's `timeout.txt`
raised it to 1500 s. The `"stale":1` event was not reproduced, and whether it played a part then
is not established.

**2. `spec-gate`'s `PreToolUse` matcher only covered the `Edit`, `Write`, and `MultiEdit` tools -
addressed by SW-79.** A model could write the same file change through `Bash` (`sed`,
`cat <<EOF >`, ...), which the hook never saw. The 2026-09-25 run of `02-feature-happy` (CLI
2.1.282, kept transcript) showed that this was not hypothetical: `draft -> approved` and
`approved -> in-progress` went through `Bash` `sed -i` on `.specs/index.md` and `00-spec.md`, so
Rules 0, 0b and 1 were sidestepped and two `spec_transition` events were never recorded. The fix has
two layers. Every workflow that writes the index or a status now says to do it with the Edit tool
only, and contract-lint `CL206` keeps that sentence in place. `spec-gate` also matches `Bash` and
`PowerShell` and denies a command that visibly writes a protected path or the spec index, recording
a `gate:"shell-write"` event. The hook half reads the command text only, so it is a heuristic, not a
guarantee: `cd .specs && sed -i ... index.md` still gets through. Scenario 02 now asserts all four
transitions and no `shell-write` gate, so a regression of the prompt half fails the run.
`acceptEdits` still overrides a hook deny (see above), so under that mode the assertions, not the
deny, are what catch it.
