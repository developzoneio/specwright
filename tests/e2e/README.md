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
- Nothing extra for hooks on Linux or macOS. The fixture's committed `settings.json` calls
  `powershell`, which those systems lack, so the runner rewrites each workspace copy's hook
  commands to `pwsh` when not on Windows (SW-81). Without that, every hook exits 127, which Claude
  Code treats as non-blocking, and all of them silently no-op.
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
- **CI uses `CLAUDE_CODE_OAUTH_TOKEN`.** The nightly passed on ubuntu with only this secret set
  (2026-09-30, run 36663596039, `claude` 2.1.197). Add it as a **repository** secret (Settings ->
  Secrets and variables -> Actions -> Repository secrets). An *environment* secret is invisible to
  the job, because the workflow declares no `environment:`, so it arrives empty and the preflight
  exits 2 with "no claude auth found".
- **A present but wrong token** passes the preflight, which only checks that a value is set. Every
  scenario then "could not run" with `Failed to authenticate. API Error: 401 Invalid bearer token`.
  Regenerate it with `claude setup-token` and set it with `gh secret set CLAUDE_CODE_OAUTH_TOKEN`,
  which reads the value from a prompt and so avoids stray quotes or newlines.
- **Still unverified:** `ANTHROPIC_API_KEY` alone, with no `.credentials.json`. An earlier local
  run recorded `"Not logged in"` in that configuration, and it has not been re-checked since CI
  moved to the OAuth token.

### Model-override probe (manual)

`probe-model-override.ps1` is a separate, manual and paid script, not part of `run-e2e.ps1` or
CI. It is the reproducible method behind ADR 0013. It checks that `/sd:feature` passes the Agent
tool's `model` parameter when an escalation rule fires, and that the call is served on that tier.
The evidence is subagent `meta.json` and transcript `message.model`, never the model's own
account. Re-run it when the minimum `claude` version above is raised. It authenticates from
`CLAUDE_CODE_OAUTH_TOKEN` (`claude setup-token`) or `ANTHROPIC_API_KEY`. `-CopyCredentials`
copies `~/.claude/.credentials.json` into each fake home instead, which can rotate the refresh
token and log out your real CLI.

Two isolation facts it relies on also apply to this harness:

- On Windows, a sandbox under `%TEMP%` is under the user profile. With no git root to stop the
  walk, Claude Code loads the real `~/.claude` as project scope, which outranks the fake home. See
  SW-73.
- `--no-session-persistence` means `SD_E2E_KEEP=1` keeps no transcript. Use
  `SD_E2E_TRANSCRIPT=1` instead when you need one (SW-79).

### Hook event probe (manual)

`probe-hook-events.ps1` is also manual and paid, and is not part of `run-e2e.ps1` or CI. It is the
reproducible method behind ADR 0015. It answers four things for each hook event: whether it blocks
on exit 2, whether a prompt-type hook runs on it, what `source` SessionStart reports, and what a
spawn costs on PS 5.1 and pwsh. Every sandbox wires a recorder hook on eight events and runs under
`dontAsk` with no skip-permissions. Re-run it before building on a hook event it does not cover.
Like `probe-model-override.ps1`, it authenticates from `CLAUDE_CODE_OAUTH_TOKEN` or
`ANTHROPIC_API_KEY`. `-CopyCredentials` copies `~/.claude/.credentials.json` instead, which can
rotate the refresh token and log out your real CLI (it did during SW-68).

One fact it found applies to this harness too. An untrusted workspace has its project
`permissions.allow` **ignored** in `-p` mode (stderr: "this workspace has not been trusted"). To
make a grant take effect, set `projects["<ws>"].hasTrustDialogAccepted: true` in the fake home's
`.claude.json`. SW-80 re-checked this and then chose `--allowedTools` instead, which needs no
trust entry and leaves the fixture's `settings.json` alone (see "Permission mode" below).

A second fact, from SW-68: hook commands in a sandbox's `settings.json` run through bash on
Windows, so a Windows path must use forward slashes. `C:\x\hook.ps1` reaches PowerShell as
`C:xhook.ps1`, and the hook never runs.

## Permission mode - grant narrowly, never skip permissions

Every scenario runs under `--permission-mode dontAsk`. That mode refuses any tool call no rule
allows; read-only tools (Read/Glob/Grep) still work without a grant. A scenario that has to write
files or run its test command lists exactly those rules in `allowed-tools.txt`, one per line, and
the runner passes them as `--allowedTools`. `02-feature-happy`, `06`-`08` grant `Edit`, `Write`,
`MultiEdit` and `Bash(npm test:*)` (the fixture's `commands.test`). `03`, `04` and `09`-`11` run
no tests and grant only the three write tools. A `Bash` call outside the grant, such as
`echo x > file`, is refused.

**A well-formed hook deny wins over every posture.** Verified 2026-09-28, `claude` 2.1.283, with
`probe-permission-posture.ps1` (a minimal always-deny `PreToolUse` hook, no spec-gate logic, that
denies any call touching one file). The `dontAsk` rows ran on Linux, the `acceptEdits` and skip
rows on Windows 10.0.26200:

| Posture | Ordinary `Write` | `npm test` | Denied `Edit` |
|---|---|---|---|
| `dontAsk`, no grant | refused | refused | refused (by the mode, not the hook) |
| `dontAsk` + `--allowedTools "Bash(npm test:*)"` | refused | ran | not reached |
| `dontAsk` + `--allowedTools "Edit,Write,Bash(npm test:*)"` | written | ran | **refused**, in `permission_denials` |
| `dontAsk` + the same rules in project `permissions.allow`, trusted workspace | written | ran | **refused**, in `permission_denials` |
| same, workspace not trusted | refused (rules ignored) | refused | not reached |
| `acceptEdits` | written | refused | **refused**, in `permission_denials` |
| `acceptEdits` + `--allowedTools "Bash(npm test:*)"` | written | ran | **refused**, in `permission_denials` |
| `acceptEdits` + `--dangerously-skip-permissions` | written | ran | **refused**, in `permission_denials` |

The **refused** cells hold only when the hook's JSON is well-formed:
`hookSpecificOutput.hookEventName: "PreToolUse"` with `permissionDecision: "deny"`, or exit 2.
spec-gate emitted `hookSpecificOutput` without `hookEventName` before SW-80. The CLI drops such a
block, and the legacy `decision: "block"` alone does not beat an allow rule, so in every row
that allows the `Edit` (the two granted `dontAsk` rows and all three `acceptEdits` rows) the file
changed and `permission_denials` stayed empty. Both earlier claims in this section came from that
("`acceptEdits` ignores a hook's deny", "an explicit `--allowedTools` grant for Edit/Write ignores
a hook's deny"), and so did "`--dangerously-skip-permissions` overrides a hook's deny". All three
were a spec-gate output bug, not CLI behavior, and SW-80 fixed it in both hooks.
`tests/hooks/run-conformance.ps1` now fails any deny that lacks `hookEventName`.

**Why scenarios still grant narrowly.** The posture no longer decides whether a deny holds, but it
does decide what else goes through. `acceptEdits` and skip-permissions both let
`echo x > file` run through `Bash`. That is the route spec-gate's `shell-write` rule covers only
by a text heuristic (see gap #2 below). Under `dontAsk` with a narrow grant it is refused. That
also keeps SW-27's "no skip-permissions" bar, with one exception, `01-setup` (below). The runner
enforces the rule: a scenario that asserts a deny (`03`, `04`, or any `permission-denied`
assertion) exits `2` before any spend if it is configured with `skip-permissions.txt` or with
`permission-mode.txt` set to `acceptEdits` or `bypassPermissions`. A `skip-permissions.txt` that
states no reason also exits `2` (SW-83).

**`01-setup` keeps skip-permissions: no grant opens `.claude/` (SW-83).** `/sd:setup` writes
`.claude/project-config.json` and `.claude/settings.json`, and Claude Code treats both as
protected paths. `probe-permission-posture.ps1 -Probe claude-dir` asked for a `Write` of
`free.txt` (the control), a `Write` of each of those two files, then an `Edit` of `settings.json`,
in a bare workspace with no `.claude/`. Verified 2026-09-30, `claude` 2.1.285, Windows 10.0.26200,
haiku, about $0.26 for all six:

| Posture | `free.txt` | `.claude/project-config.json` | `.claude/settings.json` |
|---|---|---|---|
| `dontAsk`, no grant | refused | refused | refused |
| `dontAsk` + `--allowedTools "Edit,Write,MultiEdit"` | written | **refused**, in `permission_denials` | **refused**, in `permission_denials` |
| the same plus `Edit(.claude/**)`, `Write(.claude/**)`, `Edit(/.claude/**)`, `Write(/.claude/**)` | written | **refused**, in `permission_denials` | **refused**, in `permission_denials` |
| `acceptEdits` | written | refused | refused |
| `bypassPermissions` | written | written | written, then edited |
| `acceptEdits` + `--dangerously-skip-permissions` | written | written | written, then edited |

The whole of `.claude/` is protected, not only the settings files: `project-config.json` was
refused as well. This matches the documented rule that `dontAsk` denies protected-path writes and
that allow rules do not pre-approve them. The probe shows that an `--allowedTools` grant does not
either. `bypassPermissions` is no narrower than skip-permissions, so `01` stays on skip, and
`skip-permissions.txt` states why. The cost is the one the ticket named: under skip, a
`/sd:setup` regression that writes its files through `Bash` rather than the Write tool would still
pass `01`. `01` asserts no deny, so skip does not hide a hook failure.

**`03` and `04` grant the edit they expect to be denied (SW-82).** Before SW-82 they ran under
`dontAsk` with no grant, so the mode refused their `Edit` whether or not spec-gate was there. Their
file assertions passed with no hook at all, and a deny JSON missing `hookEventName` (the bug SW-80
fixed) kept them green too, since the hook still recorded its block. Now they grant `Edit`, `Write`
and `MultiEdit`, the posture in which the probe showed a well-formed deny held and a malformed one
did not. Only the hook's deny can stop the edit, so the unchanged file and the
`permission-denied` assertion prove it end to end. The `events.jsonl` assertion still shows which
rule decided. `run-conformance.ps1` still checks the JSON shape without a model in the loop.

**Live run, 2026-09-28** (Linux, `claude` 2.1.283, pwsh 7.4.6, one `-Case` at a time, the
fixture's `powershell` hook commands resolved to `pwsh`): `02` passed 14/14 ($2.00, 697 s), with
its constitution edit in `permission_denials`, the file unchanged, and a `protected` block
recorded. `03`, `04`, `07`-`11` passed. `06` failed one assertion on a correct retro: T02's note
mentioned `ESC-FEAT-04b` in prose. That assertion now reads `escalation:` lines only.

**Windows run, 2026-09-28** (the committed runner, unmodified; Windows 10.0.26200, `claude`
2.1.283, pwsh 7.6.6, subscription auth via `CLAUDE_CODE_OAUTH_TOKEN`, commit `30ae074`): `02`
passed 14/14 ($1.95, 706 s), including the `permission-denied` assertion. `03` (2/2) and `04`
(3/3) passed, and `-SelfTest` detected the neutered guard in both. In the self-test, only the
`events.jsonl` assertion failed; the file assertions still passed, because `dontAsk` refuses the
ungranted `Edit` on its own. SW-82 closed that gap by granting the edit (see above).

**Re-verifying.** `probe-permission-posture.ps1` is the repro as a script: manual, paid (about
$0.03 a run with haiku), not part of `run-e2e.ps1` or CI. It builds a throwaway workspace whose
`PreToolUse` hook denies one file, asks for a `Write`, an `Edit` of that file, `npm test` and
`echo x > file`, and reads the outcome from disk, `permission_denials` and the hook's own log,
never from the model's reply. `-HookFormat legacy,fixed,exit2` runs spec-gate's old JSON next to
known-good ones, so a hook-output bug cannot pass for CLI behavior again. Its `verdict` column says
`deny held (hook)` only under a posture that grants `Edit`. Auth is the same as the other probes.

```powershell
$env:CLAUDE_CODE_OAUTH_TOKEN = '<from claude setup-token>'
.\tests\e2e\probe-permission-posture.ps1                                  # 8 postures x legacy,fixed
.\tests\e2e\probe-permission-posture.ps1 -Posture acceptedits,skip -HookFormat fixed
.\tests\e2e\probe-permission-posture.ps1 -Probe claude-dir                # SW-83: writes under .claude/
```

`-Probe claude-dir` is the evidence for `01-setup`'s exception (above). Re-run it when the minimum
`claude` version is raised: if a `dontAsk` row ever writes both `.claude/` files, `01` can move to
`allowed-tools.txt` and drop `skip-permissions.txt` and `permission-mode.txt`.

Its first runs, 2026-09-28 on `claude` 2.1.283, are the table above: the five `dontAsk` postures x
`legacy` / `fixed` / `exit2` on Linux, and `acceptedits`, `acceptedits-bash`, `skip` and
`dontask-grant` x `legacy` / `fixed` on Windows. `fixed` and `exit2` held the deny in every run
that reached the hook; `legacy` was overridden in every run that allowed the `Edit`.

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

`-SelfTest` re-runs scenarios `03-spec-gate-negative` and `04-closeout-negative` once for each of
two mutations of the installed spec-gate in the fake home (never the repo's real `hooks/` source),
and asserts that each of the four runs fails as a whole. Mirrors `tests/hooks/run-conformance.ps1`
and `tests/contract-lint/run-selftest.ps1`'s own `-SelfTest` modes.

| Mutation | What it does | What must fail |
|---|---|---|
| `always-allow` | Replaces the hook with a stub that decides nothing: the guard is gone. | Every assertion: the edit lands, nothing is denied, no block event. |
| `malformed-deny` (SW-82) | Keeps the real hook but rewrites its deny JSON to the pre-SW-80 shape, with no `hookSpecificOutput.hookEventName`. | The file and `permission-denied` assertions. The hook still decides to block and records the event, but the CLI drops the deny, so the granted edit lands. |

`malformed-deny` is the regression SW-80 fixed, and the reason `03` and `04` grant the edit. Under
the old no-grant posture the mode refused the edit anyway, and both scenarios stayed green. The
mutation rewrites the hook's deny emitter by pattern. If that pattern stops matching (the emitter
was refactored), the run throws rather than quietly testing the real guard under a mutation's name.

**Windows run, 2026-09-30** (SW-82; Windows 10.0.26200, `claude` 2.1.285, pwsh 7.6.6,
subscription auth, working tree on commit `f5faa0e`, figures from `-ResultsFile`):

| Run | `03-spec-gate-negative` | `04-closeout-negative` |
|---|---|---|
| Real guard | 3/3 pass, $0.14, 15 s | 4/4 pass, $0.15, 16 s |
| `always-allow` | 0/3, detected, $0.15 | 0/4, detected, $0.15 |
| `malformed-deny` | 1/3, detected, $0.14 | 1/4, detected, $0.15 |

Under `malformed-deny` only the `events.jsonl` assertion passed: the hook recorded its block, the
CLI dropped the deny, and the edit landed. That is the SW-80 failure, now caught during a
self-test run. The whole `-SelfTest` cost $0.58.

**"Could not run" is not "detected" (SW-81).** A scenario whose `claude -p` timed out, printed no
parseable result, or returned `is_error: true` never touched its workspace, so every assertion
fails. Before SW-81 the self-test counted that as detecting the neutered guard. Nightly run #49 did
exactly that with no auth configured, printing `harness detected the neutered guard` for both
scenarios without having run either. Such a scenario is now reported as `[ERROR] ... could not run`
with its exit code, result and stderr, its assertions are skipped, and the self-test exits 1. The
normal suite reports it the same way, counts it apart from failed assertions in the summary line,
and exits 1.

## Scenarios

| # | Scenario | Claim under test |
|---|---|---|
| 1 | `01-setup` | `/sd:setup` on a bare, unscaffolded project produces `CLAUDE.md`, `.specs/`, `.claude/project-config.json`, `.claude/settings.json`, all BOM-free. |
| 2 | `02-feature-happy` | `/sd:feature` happy path on a small spec reaches `done` with a full artifact set and a passing `06-verify.md`. `events.jsonl` records all four allowed `spec_transition` edges (`-` -> `draft` -> `approved` -> `in-progress` -> `done`) and no `shell-write` gate, so an index move made through a shell instead of the Edit tool fails the run (SW-79). A final deliberate `Edit` to the protected `.specs/constitution.md` is in `permission_denials`, leaves the file unchanged, and records a `protected` block (SW-80). |
| 3 | `03-spec-gate-negative` | spec-gate denies a direct code edit with no in-progress spec recorded. The edit is granted, so only the hook's deny keeps `src/domain/todo.js` unchanged and puts it in `permission_denials` (SW-82). |
| 4 | `04-closeout-negative` | spec-gate's verify-gate denies flipping an index row to `done` with no passing `06-verify.md`. The edit is granted, so only the hook's deny keeps the row `in-progress` and puts `.specs/index.md` in `permission_denials` (SW-82). |
| 5 | `05-spec-lint-validate` | `/sd:spec validate --all` against `examples/spec-lint-fixture/broken` surfaces the seeded `SL0xx` findings - the one command this harness must assert on output text, since `/sd:spec validate` is report-only with no artifact file. |
| 6 | `06-escalation-implementer` | `/sd:feature` Phase 4 resumed on a seeded 2-task spec under `models.escalation.ceiling: "sonnet"`: the `Estimated complexity: L` task logs exactly one uncapped, applied `escalation: sd-implementer haiku -> sonnet (trigger: ESC-FEAT-04)` line in `05-retro.md`; the `S` / `trivial` task logs none. |
| 7 | `07-escalation-disabled` | Same seeded spec under `models.escalation.enabled: false`, with T01 at `Estimated complexity: L` and T02 at `Reversibility: hard`: both tasks run and `05-retro.md` carries no `escalation:` line - the suppression covers `ESC-FEAT-04` and `ESC-FEAT-04b` alike. |
| 8 | `08-resume-checkoff` | `/sd:feature` re-invoked on a seeded 2-task spec whose T01 is already checked off (`Status: done`, code landed, retro line written) and T02 is `open`: the resume executes T02 only - `05-retro.md` gains a `T02:` line and still has exactly one `T01:` line, `countTodos` is not re-added - and both tasks end at the canonical `Status: done` marker (SW-71). |
| 9 | `09-resume-approved` | `/sd:feature` re-invoked on a seeded `complexity: L` spec that is `approved` with no `02-tasks.md` and no impact map (the approving session ended before Phase 2): the state machine resumes at **Phase 2**, not Phase 3. `03-decisions.md` gains exactly one `## Impact analysis (sd-code-explorer)` section, `05-retro.md` carries the applied `escalation: sd-code-explorer haiku -> sonnet (trigger: ESC-FEAT-02)` line, Phase 3 writes `02-tasks.md`, and the run stops at Gate 2 with status still `approved` and no code changed (SW-74). Under the pre-SW-74 table the first two assertions fail. |
| 10 | `10-resume-impact-mapped` | Control for 09: the same spec with the impact analysis already in `03-decisions.md`. The resume goes straight to Phase 3 (`impact-mapped`): still exactly one impact section, no `ESC-FEAT-02` line, `02-tasks.md` written, stopped at Gate 2 (SW-74). |
| 11 | `11-escalation-rca-capped` | `/sd:rca` resumed at Phase 2 on a seeded `severity: P0` incident under `models.escalation.ceiling: "sonnet"`: `ESC-RCA-02` is capped to no movement and `05-retro.md` still carries exactly one `escalation: sd-debugger sonnet -> sonnet (trigger: ESC-RCA-02) capped` line - no `-> opus`, no `unapplied`, no second line. The hypothesis tree is filled, the run stops at Gate 2 with status `draft`, and no code changes (SW-62). A capped decision that left no line would look exactly like the policy not running. |

Each scenario directory may contain: `source.txt` (repo-relative base tree to copy),
`workspace/` (overlay applied on top - added/overwritten files only, mirrors the
`tests/contract-lint` `_base` + overlay fixture pattern), `prompt.txt` (the literal headless
prompt), `expect.json` (declarative assertions), and optional `budget.txt` / `timeout.txt` / `permission-mode.txt`
/ `skip-permissions.txt` / `disallowed-tools.txt` / `allowed-tools.txt` overrides. A
`skip-permissions.txt` must hold the evidenced reason the scenario cannot run under `dontAsk` with a
grant; the preflight refuses an empty one. `allowed-tools.txt`
holds one permission rule per line (`#` comments allowed), because a rule such as
`Bash(npm test:*)` contains a space. Besides the file assertions, `expect.json` accepts
`permission-denied` (`tool`, a regex, and `path`, a suffix): the run's `permission_denials` holds a
matching call. An optional `requires.txt` lists
commands the scenario needs on `PATH` (one per line, `#` comments allowed). The preflight checks it
for the selected scenarios only, so `-Case 03-spec-gate-negative` does not demand Node.

## Cost and CI placement

Not per-PR: a `claude -p` suite costs real tokens and minutes of wall clock, and neither belongs
in a gate on every push. It runs nightly (or on manual `workflow_dispatch`) on a single OS via
`.github/workflows/e2e-nightly.yml`.

**The cost trade-off per run.** One full 10-scenario run (measured before scenario 11 was added) costs about **$7.55-$7.79** in
`total_cost_usd` and takes about **26-28 minutes** of wall clock, plus about **$0.58** for
`-SelfTest`, which runs four sessions since SW-82 (two before; see the measured tables). With subscription auth, `total_cost_usd` is a notional
figure, and the run draws on the plan's usage allowance instead of dollars. With API-key auth it is
billed. The runs below used subscription auth. That makes the suite practical to run locally
before a PR, one `-Case` at a time for the cheap scenarios (`03`, `04`: about $0.15 each). It is no
longer only a nightly report to read afterwards. A full run plus `-SelfTest` fits inside the
nightly job's `timeout-minutes: 45`.

**Measured on CI, 2026-09-30** (run 36663596039, ubuntu-latest, `claude` 2.1.197, subscription
auth, commit `31ae29a`): all 11 scenarios passed (102/102 assertions) in about **35 minutes**, and
`-SelfTest` detected the neutered guard in both scenarios in under a minute. That leaves about 10
minutes of headroom under `timeout-minutes: 45`, so a new long scenario may need the limit raised.
The workflow keeps no `-ResultsFile`, so that run has no per-scenario cost figures.

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
| `-SelfTest` (`03` + `04`, always-allow only, before SW-82) | $0.25 | $0.26 | $0.26 |

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

### Capped-escalation scenario (SW-62)

Before the live run, the assertions were checked offline against a good retro and against broken
ones (no line, uncapped `-> opus`, two lines, `unapplied`, Phase 2 not run, severity edited).

First live run, 2026-09-26, Windows, subscription auth, `-Case 11-escalation-rca-capped`:

| Scenario | `total_cost_usd` | Assertions | Result |
|---|---|---|---|
| `11-escalation-rca-capped` | $0.5785 | 7/7 | pass |

The run wrote exactly one `escalation: sd-debugger sonnet -> sonnet (trigger: ESC-RCA-02) capped`
line to `05-retro.md` before the debugger call, filled the hypothesis tree, left `severity: P0`
and status `draft` untouched, and stopped at Gate 2. So `ceiling: "sonnet"` caps a
`sonnet -> opus` row to no movement and still leaves the decision visible.

The run also surfaced a fixture defect: the seeded timeline cited
`04-artifacts/demo-host-restart.log`, which `.gitignore`'s `*.log` had kept out of the commit, so
the debugger ranked three hypotheses as blocked on missing evidence. No assertion reads that file,
so the pass stands. The artifact is now `demo-host-restart.txt`. Avoid `.log` names in fixture
trees.

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
transitions from its own diff (`metrics-transition-partial-edit` fixture). **Closed by SW-80:** scenario
2 no longer runs with `skip-permissions`. It runs under `dontAsk` with an `allowed-tools.txt`
grant for its writes and `npm test`, which keeps hook denies in force (see "Permission mode"), and
it asserts one deliberate Rule 1 deny during the run.

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
Since SW-80, scenario 02 runs under a posture that keeps the deny, so a regression of the hook
half is refused during the run as well as caught by the assertions.
