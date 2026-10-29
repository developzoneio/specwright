# tests/e2e - headless behavioral eval harness (SW-27)

Drives real `claude -p` (headless) sessions against a throwaway copy of a fixture project and
asserts on **produced artifacts** - files, frontmatter, status values - never on transcript
wording (two assertions read the transcript; see the rule below). This is the only mechanism in the repo that exercises a real model session against the
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

**One assertion reads the transcript, and it still asserts an artifact (SW-99).**
`transcript-contains-section` checks that the shown lines of each `gate-briefs.md` section appear
verbatim in the main thread's reply text. It meets the rule for three reasons:

- **The expected text is the artifact, not a sentence in `expect.json`.** The scenario names a
  file and a section heading pattern. The lines it looks for are whatever this run wrote to disk,
  so a different wording in the next run moves both sides at once and cannot flake the check.
- **The comparison is byte-for-byte, not a judgment of phrasing.** `sd-gate-brief` (ADR 0019)
  makes the file and the chat the same text, rendered once before the write. A paraphrase fails on
  purpose: it is the gate presented in words the record does not hold.
- **It answers a question no file can.** SW-88 and SW-89 found sessions that wrote every brief,
  printed none of it, and then said each gate was presented. Only the reply channel shows that.

The transcript is this assertion's input, so a scenario that uses it keeps its session whatever
`SD_E2E_TRANSCRIPT` says, and its fake home is still deleted afterwards. A missing transcript, a
missing brief, or a brief with no matching section fails the assertion; it never passes empty.
No other assertion may read the transcript, and no assertion may match model-written wording,
with one exception.

**The exception: `transcript-not-matches` (SW-113).** `sd-gate-brief` "User-facing text" forbids
internal IDs (`ESC-*`, lint and verify codes, `path:line`) in every line the user reads, not only
in the brief file, and no file holds the narration. The assertion fails when a regex matches any
main-thread assistant text block of any turn. It stays inside the rule because:

- **It is negative and names an ID class, not a phrasing.** Scenarios 02 and 13 to 17 reuse the
  patterns their `file-not-matches` on `gate-briefs.md` already use. A different wording in the
  next run cannot trip it; only a rule ID or a `path:line` in the reply can.
- **It shares one extraction with `transcript-contains-section`.** Main-thread text blocks only:
  tool calls, tool results, thinking blocks and subagent transcripts are not read, because they
  legitimately carry IDs (the `escalation:` lines in `05-retro.md`, reviewer `file:line` citations).
- **It never passes vacuously.** No transcript, or a transcript with zero main-thread text
  blocks, fails with that reason. A failure names the turn and a short excerpt around the match.

**First live run, 2026-10-22** (Linux, `claude` 2.1.308, API key, commit `90021f1`): `02` passed
21/22 and failed only this assertion, at 0 of 22 shown lines. Each gate was written and answered,
and none was printed. The kept transcript showed the session had read the "Printed means reply
text" rule. This is the SW-88 / SW-89 F1 defect, not a flake: it was the same in all four measured
runs. A probe the same day ran the same request with no standing reply, so the run stopped at
Gate 1 and the gate ended the turn: its brief was printed byte-for-byte, and the assertion passed.
The scripted single turn is what drops the print.

**SW-103 run, 2026-10-22** (same machine and CLI, commit `a4bcdf1` plus the SW-103 diff): with
each gate reply sent as its own turn (see "Gate replies as turns" below), `02` passed 22/22. All
three briefs were printed byte-for-byte, each inside one text block (Gate 1 7/7 lines, Gate 2
12/12, Gate 3 4/4), and user-visible text carried no internal ID and no `path:line`. Five turns,
448 s, $1.92. A full-suite run on commit `dc86f70` right after passed `02` 22/22 again (414 s,
$1.79) and every other scenario unchanged: 112/112 assertions, about $6.12 for the suite. `-SelfTest`
passed all 9 transcript cases and all 4 guard runs.
The SW-88 medium scenario (`90-spike-feature-m`, scratch, not committed) under replies-as-turns, at
commit `caad4e1`: 5/5, with all three briefs printed byte-for-byte (8/8, 16/16, 5/5 lines), no
internal ID in user-visible text, 7 tasks, 4 turns, 740 s, $2.81. In both multi-turn runs a phase
that starts right after a gate reply was sometimes not narrated (Phase 6 in both, Phase 4 in M).

## Prerequisites

The runner checks all of these before it builds any sandbox. A missing one exits `2` and names the
dependency; it never shows up as a failed scenario assertion.

- PowerShell 7+ (`pwsh`). This is a single cross-platform runner by design, the same as the other
  parity harnesses. See [CONTRIBUTING.md "Test suites and
  prerequisites"](../../CONTRIBUTING.md#test-suites-and-prerequisites) for why.
- `claude` CLI on `PATH`, **v2.1.196 or later**.
- **One** way to authenticate `claude`, as an environment variable: `CLAUDE_CODE_OAUTH_TOKEN` or
  `ANTHROPIC_API_KEY`. **No API key is needed**: a Claude subscription works. See [Auth](#auth)
  below.
- Node.js (`node`, `npm`), only for scenarios that declare it in `requires.txt` (`01-setup`,
  `02-feature-happy`, `06`-`10`, `12`-`14`, `16`, `17`), and `git` for `17`.
- Nothing extra for hooks on Linux or macOS. The fixture's committed `settings.json` calls
  `powershell`, which those systems lack, so the runner rewrites each workspace copy's hook
  commands to `pwsh` when not on Windows (SW-81). Without that, every hook exits 127, which Claude
  Code treats as non-blocking, and all of them silently no-op.
- A sandbox root with no `.claude` directory in it or in any directory above it. The defaults
  already meet this; see [the ancestor-walk rule](#the-ancestor-walk-rule-sw-73) below.

## Running it

Every example below needs an auth variable in the shell first. The runner exits `2` without one,
and it does not fall back to your `~/.claude/.credentials.json` (see [Auth](#auth)).

```powershell
# Once per shell (token from `claude setup-token`; never paste it into a command line you log)
$env:CLAUDE_CODE_OAUTH_TOKEN = '<from claude setup-token>'

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
# transcript lands under <fakeHome>\.claude\projects\ (the path is printed) (SW-79). A scenario
# with a transcript-contains-section assertion keeps its session without it, then deletes it (SW-99)
$env:SD_E2E_TRANSCRIPT = '1'; .\tests\e2e\run-e2e.ps1 -Case 02-feature-happy

# Also write the run as JSON: date, mode, claude version, auth mode, OS, git commit, and per
# scenario the result, assertion counts, exit code, total_cost_usd and duration (SW-77). It holds
# no prompt, transcript or credential, and is written for full, -Case and -SelfTest runs alike
.\tests\e2e\run-e2e.ps1 -ResultsFile C:\sd-e2e-results\run1-suite.json
```

### Reproducibility runs (SW-77)

SW-27's acceptance bar is "green 3 times consecutively". To measure it, use one machine and one
`claude` version, and run the full suite and then `-SelfTest` three times in a row, each with its
own `-ResultsFile`. Authenticate from a variable, so no run touches your real login (SW-106), and
check that each `authMode` in the results names that variable:

```powershell
$env:CLAUDE_CODE_OAUTH_TOKEN = '<from claude setup-token>'
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

The runner takes its auth from an environment variable and hands it to the child `claude`. It
prints the credential it handed over, and `authMode` in `-ResultsFile` records the same label
(SW-106):

| Mode | How to get it | Billing | `authMode` | Where it fits |
|---|---|---|---|---|
| `CLAUDE_CODE_OAUTH_TOKEN` | `claude setup-token` (one-time, long-lived) | Claude subscription | `subscription (CLAUDE_CODE_OAUTH_TOKEN)` | Local on any OS; CI as a repo secret |
| `ANTHROPIC_API_KEY` | Anthropic Console | API, per token | `API key (ANTHROPIC_API_KEY)` | CI (the original nightly setup) |
| Both set | - | API (the key wins) | `API key (ANTHROPIC_API_KEY; CLAUDE_CODE_OAUTH_TOKEN also passed, claude prefers the key)` | The nightly, when both secrets exist |
| `-CopyCredentials` | An ordinary `claude` login (`/login`) | Claude subscription | the above plus ` + copied ~/.claude/.credentials.json (content not inspected)` | Opt-in only; see below |

- **Credentials file: opt-in, off by default (SW-106).** `run-e2e.ps1` does **not** read or copy
  `~/.claude/.credentials.json` unless you pass `-CopyCredentials`, the same switch
  `probe-model-override.ps1` and `probe-hook-events.ps1` have. A copy forks a single-use OAuth
  refresh token: when the access token has expired, the sandbox run refreshes it and the real CLI
  is logged out. That happened during SW-68, and it is why SW-93 shipped without a live
  measurement. With the switch the file is copied in addition to any auth variable, into the
  throwaway fake home only, and removed again from a fake home that `SD_E2E_KEEP` or
  `SD_E2E_TRANSCRIPT` keeps. The label never claims the file unless it was copied, because the
  file's presence says nothing about what it holds: SW-88 recorded `subscription
  (~/.claude/.credentials.json)` for a file that held only MCP tokens. On macOS the login is kept
  in the Keychain rather than in this file, so use `claude setup-token` there.
- **No variable and no switch** exits `2` before any sandbox is built, with a message naming
  `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY` and `-CopyCredentials`.
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
  moved to the OAuth token. Since SW-106 that is the configuration an API-key-only run has by
  default, so if it fails that way, pass `-CopyCredentials` or use `CLAUDE_CODE_OAUTH_TOKEN`.

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

**`npm test` through either shell tool (SW-105).** On
Windows a session may run the test command through the PowerShell tool instead of Bash. A
`Bash(...)` grant does not cover it, so the call is refused and the session stops to ask. The
SW-93 M runs hit this twice, and in one the next gate reply went to that question. `02` therefore
also grants `Bash(npm run test:*)`, the `PowerShell` forms of `npm test` and `npm run test` (bare
and with arguments), and the two PowerShell pipe stages `Select-Object` and `Select-String`. No
rule grants a writer verb (`tee`, `Set-Content`, `Out-File`, `sed -i`, `node -e`, `sh -c`), and
the permissions docs say every part of a compound command must be allowed, so
`npm test; Set-Content .specs/index.md x` is refused by the mode. A redirect after `npm test` is
the part no grant stops: the CLI checks the target against Edit rules, and Edit is granted. That
case rests on spec-gate's `shell-write` rule, which reads the command text and so is a heuristic
(see gap 2 below). `tests/hooks/fixtures/spec-gate/` holds it for both tools
(`block-bash-npm-test-redirect-protected`, `block-powershell-npm-test-redirect-protected`) and
the two pipes that must stay allowed.

**First round: 0 of 5 runs were green (2026-10-28).** Five runs of `02` in a row,
each with `SD_E2E_TRANSCRIPT=1` (`claude` 2.1.312, Windows 10.0.26200, pwsh 7.6.9, subscription
auth via `CLAUDE_CODE_OAUTH_TOKEN`, commit `1e92e48`), cost $5.76 in all. Every run failed 3 to 5
assertions, and every transcript held `Permission to use Bash has been denied` (4 to 7 times); three
also held a PowerShell denial. The denied calls were not `npm test` variants that a prefix rule
covers:

| Shape of the refused call | Seen in | What it shows |
|---|---|---|
| `cd /d/sd-e2e/<ws> 2>/dev/null \|\| cd "C:/sd-e2e/<ws>"; npm test 2>&1 [\| tail -n 25]`, or `cd /d C:\... && npm test` | subagents, runs 1, 3, 4, 5 | the command starts with `cd` to a path the CLI does not count as a working directory, so `Bash(npm test:*)` never applies |
| `npm test >/dev/null 2>&1; echo exit=$?` | main thread, run 2 | refused although the docs say `/dev/null` is not checked and `echo` is read-only; not explained |
| `npm test 2>&1 \| Select-String -Pattern "..."`, `... \| Select-Object -Last 9; "exit=$LASTEXITCODE"` | main thread, runs 1 and 5 | refused **with** `PowerShell(npm test *)` and the `Select-*` rules granted, so either the rule form is not honoured or the compound is judged as a whole; not told apart |
| `node --test 2>&1 \| Select-String ...`, `node --input-type=module -e ...` | runs 3 and 2 | the model skips `npm test` for the command underneath it, which no `npm test` rule covers |
| `printf 'Reply: yes\n' >> gate-briefs.md`, `cat >> gate-briefs.md <<EOF` | main thread, runs 1, 3, 4, 5 | a shell write the model chose to record a gate reply; refusing it is correct. The stop-gate reason says to append the `Reply:` line without saying to use the Edit tool |
| `Glob` / `Grep` with a path or pattern outside the workspace (skill and template lookups) | subagents, runs 1-4 | read tools are refused outside the granted directories too; unrelated to `npm test` |

The refusals change the outcome. In runs 2 and 3 the tests could not be run, and in run 4 the
Gate 3 reply could not be recorded, so close-out never started: no `06-verify.md`. In run 5
`/sd:verify` could not run `npm test` and wrote `result: fail` with `VF022`. In all four the spec
stayed `in-progress`. Run 1 is a different failure: the tests ran, and `/sd:verify` returned `fail` on
two `VF020` findings, because the lean `Acceptance` of T02 and T03 named no path-like witness test
(ADR 0023 item 7 reads the witness test from `Acceptance`). That is a content defect of the
lean format, not a permission one, and it needs its own ticket.

**What the probe showed.** `probe-permission-posture.ps1 -Probe shell-shapes` runs 18 command
shapes, one tool call each, under three rule sets (haiku, 2026-10-28, three sessions for $0.03; the
outcome of each call is read from the kept transcript). The shipped grant works where it names the
command, and nothing a rule names covers a redirect:

| Shape | `Bash(npm test:*)` only | Shipped grant |
|---|---|---|
| `npm test`, `npm test 2>&1`, `... \| tail -n 5`, `cd <ws> && npm test` | allowed | allowed |
| `npm run test` (Bash) | DENIED | allowed |
| PowerShell `npm test`, `npm test 2>&1`, `... \| Select-Object -Last 5`, `npm run test` | DENIED | allowed |
| `npm test >/dev/null 2>&1; echo exit=$?`, `npm test > out.txt`, `cd <ws> 2>/dev/null \|\| cd "<ws>"; npm test` | DENIED | DENIED |
| `node --test` (either tool) | DENIED | DENIED |
| PowerShell `... \| Select-String -Pattern "^# (tests\|pass)\|^not ok"`, `...; "exit=$LASTEXITCODE"` | DENIED | DENIED |
| `printf 'x' >> notes.txt`, `npm test; Set-Content notes.txt x` (controls) | DENIED | DENIED |

So the `PowerShell(...)` rules are honoured in both the `*` and the `:*` form, which overturns the
first-round reading that they were ignored. What no prefix rule can cover is a redirect (even to
`/dev/null`), `node --test`, a quoted `Select-String` pattern with `|`, and a trailing string
statement. Those are decisions the model makes, so they were fixed where it makes them.

**Second round, 3 of 3 green (2026-10-28, commit `920bd92`).** Three changes: `sd-gate-brief` and
both stop-gate twins tell the model to record the `Reply:` line with the Edit tool; `02`'s prompt
states which shell forms are refused (plain `npm test` only, no `cd`, redirect, `;`, `||`,
`node --test`) and asks it to tell subagents the same; the grant above stays. Three consecutive
runs of `02` passed 25 of 25, in 319-361 s and $1.25, $1.32 and $1.25. No transcript, subagent ones
included, held `Permission to use Bash has been denied` or its PowerShell form. One run held three
`Glob` denials (subagent skill lookups outside the workspace), which the ticket's condition does
not name. The runs do not say which of the three changes mattered: the grant, the prompt and the
skill wording moved together. The prompt in particular states the posture to the model, so the
result is for that prompt; a session that skips it can still choose a refused shape. `06`-`08` carry
the same `Bash`-only grant and the same exposure and were not widened.

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

**As root, `01` needs `IS_SANDBOX=1`.** The CLI refuses `--dangerously-skip-permissions` under root
("cannot be used with root/sudo privileges for security reasons"), so in a container that runs as
root `01` reports "could not run". `IS_SANDBOX=1` in the runner's environment lets it run; it passed
11/11 that way (Linux container, `claude` 2.1.308, 2026-10-22). Set it only in a throwaway sandbox.

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

The same holds for gate replies. `02-feature-happy` says what is true: the runner types each gate
reply as the next message, so the session should stop at each gate and wait. Before SW-103 it was
told to take a standing "yes" and continue within one turn, which no person ever does, and which
the SW-99 measurements showed drops every gate brief from the chat.

## Self-test (guard-neutering)

`-SelfTest` re-runs scenarios `03-spec-gate-negative` and `04-closeout-negative` once for each of
two mutations of the installed spec-gate in the fake home (never the repo's real `hooks/` source),
and asserts that each of the four runs fails as a whole. Mirrors `tests/hooks/run-conformance.ps1`
and `tests/contract-lint/run-selftest.ps1`'s own `-SelfTest` modes.

| Mutation | What it does | What must fail |
|---|---|---|
| `always-allow` | Replaces the hook with a stub that decides nothing: the guard is gone. | Every assertion: the edit lands, nothing is denied, no block event. |
| `malformed-deny` (SW-82) | Keeps the real hook but rewrites its deny JSON to the pre-SW-80 shape, with no `hookSpecificOutput.hookEventName`. | The file and `permission-denied` assertions. The hook still decides to block and records the event, but the CLI drops the deny, so the granted edit lands. |

Before those paid runs, `-SelfTest` checks `transcript-contains-section` offline (SW-99). It
builds a brief with a Gate 1 and a Gate 2 section, writes one transcript per case into a scratch
fake home, and runs the real assertion function against each. No `claude` session is started, and
the check costs nothing:

| Case | Transcript | Must |
|---|---|---|
| `printed` | the Write call, a phase line, then each section's shown lines as a text block | pass |
| `write-only` | the Write call carrying the whole brief, then "Gate 1 and Gate 2 presented" | fail |
| `subagent-only` | the Write call; the shown lines only in a `subagents/` transcript | fail |
| `paraphrase` | both sections printed, one line reworded | fail |
| `no-transcript` | no session file at all | fail |
| `multi-turn` | one session file: Gate 1 printed, a user `yes` turn, then Gate 2 printed (SW-103) | pass |
| `forked-session` | Gate 1 printed in one session file and Gate 2 in a second, and the run names both | pass |
| `forked-last-only` | the same two files, but the run names only the second session | fail |
| `no-sections` | the brief has no `## Gate` section | fail |

`write-only` is the SW-88 / SW-89 F1 pattern. If any case behaves otherwise, `-SelfTest` exits 1.

`-SelfTest` checks `transcript-not-matches` the same way (SW-113), with the three ID patterns of
scenarios 13 and 14 (`ESC-*`, `SL/VF/CL` + 3 digits, `path:line`). A case marked "all 3" runs
against each pattern:

| Case | Transcript | Must |
|---|---|---|
| `esc-id-in-text`, `lint-id-in-text`, `path-line-in-text` | the ID in a main-thread text block | fail, naming turn 1 |
| `leak-in-turn-2` | a clean turn 1, then the ID in turn 2; tool results and subagent notices (`origin`) do not start a turn | fail, naming turn 2 |
| `leak-in-forked-session` | the ID in a second session file the run names | fail, naming turn 2 |
| `leak-in-unnamed-session` | the ID in a session file the run does not name | pass |
| `allowed-handles` (all 3) | spec ID, `T02` with its title, `H1`, `P1`, `Gate 2` and a bare file path | pass |
| `ids-in-tool-use`, `ids-in-tool-result`, `ids-in-thinking` (all 3) | every ID class only in that content | pass |
| `ids-in-sidechain-entry`, `ids-in-subagent-transcript` (all 3) | every ID class only in subagent text | pass |
| `no-transcript` (all 3) | no session file at all | fail |
| `zero-text-blocks` (all 3) | only tool calls and a tool result | fail |

First of all, before the preflight, `-SelfTest` checks the auth plan offline (SW-106). It needs no
`claude` CLI and no auth, and a failure exits 1 before any paid run. Each case sets the two auth
variables to a dummy marker (the real values are saved and restored, never printed), points the
plan at a fake credentials file in a scratch dir, and runs the real plan and copy functions:

| Case | Must |
|---|---|
| a variable is set, file present, no switch | copy nothing |
| both variables | copy nothing, and the label says the key wins |
| empty variables (an absent CI secret) | count as absent, so exit 2 |
| nothing set, file present, no switch | exit 2 naming `-CopyCredentials`, copy nothing |
| nothing set, switch, file present | copy the file |
| nothing set, switch, file absent | exit 2 saying the file was not found |
| a variable and the switch, file present | copy it, and the label names both |
| a variable and the switch, file absent | copy nothing, keep running |

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
| 2 | `02-feature-happy` | `/sd:feature` happy path on a small spec reaches `done` with a full artifact set and a passing `06-verify.md`. `events.jsonl` records all four allowed `spec_transition` edges (`-` -> `draft` -> `approved` -> `in-progress` -> `done`) and no `shell-write` gate, so an index move made through a shell instead of the Edit tool fails the run (SW-79). A final deliberate `Edit` to the protected `.specs/constitution.md` is in `permission_denials`, leaves the file unchanged, and records a `protected` block (SW-80). `gate-briefs.md` exists with Gate 1, 2 and 3 sections and holds no `ESC-*` or lint/verify rule ID (SW-89), and every section's shown lines appear verbatim in the main thread's reply text (SW-99), and no turn's reply text carries an `ESC-*` or lint/verify rule ID (SW-113). Each gate reply (`yes` x3) and the constitution probe are sent as their own turns from `replies.txt`, so each gate ends a turn (SW-103). |
| 3 | `03-spec-gate-negative` | spec-gate denies a direct code edit with no in-progress spec recorded. The edit is granted, so only the hook's deny keeps `src/domain/todo.js` unchanged and puts it in `permission_denials` (SW-82). |
| 4 | `04-closeout-negative` | spec-gate's verify-gate denies flipping an index row to `done` with no passing `06-verify.md`. The edit is granted, so only the hook's deny keeps the row `in-progress` and puts `.specs/index.md` in `permission_denials` (SW-82). |
| 5 | `05-spec-lint-validate` | `/sd:spec validate --all` against `examples/spec-lint-fixture/broken` surfaces the seeded `SL0xx` findings, including `SL060` seeded by the lean-task-format `FEAT-BROKEN-017` (SW-93) and `SL068` seeded by `FEAT-BROKEN-018`, a task block whose `Files` drifted from the approved outline (SW-105). `SL068` is also asserted absent on `FEAT-BROKEN-014` (no outline) and `FEAT-BROKEN-017` (an agreeing outline) - the one command this harness must assert on output text, since `/sd:spec validate` is report-only with no artifact file. |
| 6 | `06-escalation-implementer` | `/sd:feature` Phase 4 resumed on a seeded 2-task spec, authored in the lean task format (SW-93), under `models.escalation.ceiling: "sonnet"`: the task that writes `Estimated complexity: L` logs exactly one uncapped, applied `escalation: sd-implementer haiku -> sonnet (trigger: ESC-FEAT-04)` line in `05-retro.md`; the other task writes neither optional field, reads as `M` / `trivial`, and logs none. |
| 7 | `07-escalation-disabled` | Same seeded spec in the legacy 11-field format, under `models.escalation.enabled: false`, with T01 at `Estimated complexity: L` and T02 at `Reversibility: hard`: both tasks run and `05-retro.md` carries no `escalation:` line - the suppression covers `ESC-FEAT-04` and `ESC-FEAT-04b` alike. |
| 8 | `08-resume-checkoff` | `/sd:feature` re-invoked on a seeded 2-task spec in the lean task format (SW-93) whose T01 is already checked off (`Status: done`, code landed, retro line written) and T02 is `open`: the resume executes T02 only - `05-retro.md` gains a `T02:` line and still has exactly one `T01:` line, `countTodos` is not re-added - and both tasks end at the canonical `Status: done` marker (SW-71). |
| 9 | `09-resume-approved` | `/sd:feature` re-invoked on a seeded `complexity: L` spec that is `approved` with no `02-tasks.md` and no impact map (the approving session ended before Phase 2): the state machine resumes at **Phase 2**, not Phase 3. `03-decisions.md` gains exactly one `## Impact analysis (sd-code-explorer)` section, `05-retro.md` carries the applied `escalation: sd-code-explorer haiku -> sonnet (trigger: ESC-FEAT-02)` line, Phase 3a writes the `01-plan.md` outline (ADR 0022) and no `02-tasks.md`, and the run stops at Gate 2 with status still `approved` and no code changed (SW-74). Under the pre-SW-74 table the first two assertions fail. |
| 10 | `10-resume-impact-mapped` | Control for 09: the same spec with the impact analysis already in `03-decisions.md`. The resume goes straight to Phase 3a (`impact-mapped`): still exactly one impact section, no `ESC-FEAT-02` line, the `01-plan.md` outline written and no `02-tasks.md`, stopped at Gate 2 (SW-74). |
| 11 | `11-escalation-rca-capped` | `/sd:rca` resumed at Phase 2 on a seeded `severity: P0` incident under `models.escalation.ceiling: "sonnet"`: `ESC-RCA-02` is capped to no movement and `05-retro.md` still carries exactly one `escalation: sd-debugger sonnet -> sonnet (trigger: ESC-RCA-02) capped` line - no `-> opus`, no `unapplied`, no second line. The hypothesis tree is filled, the run stops at Gate 2 with status `draft`, and no code changes (SW-62). A capped decision that left no line would look exactly like the policy not running. |
| 13 | `13-bug-gate-brief` | `/sd:bug` on a seeded off-by-one (`validateTitle` rejects a 200-character title) runs Gates 1 to 5 with a `yes` each, sent as turns from `replies.txt`. `gate-briefs.md` has a section for each gate, a `Reply: yes`, no `ESC-*`, lint or verify rule ID and no `path:line`, and every section's shown lines appear verbatim in the main thread's reply text, which itself carries none of those IDs in any turn (SW-113). The failing-test output is saved under `04-artifacts/repro/`, the fix lands and the index row reaches `done` (SW-96). |
| 14 | `14-refactor-gate-brief` | `/sd:refactor` extracts the lookup-or-throw step of `TodoService.completeTodo` into a private method, one task in one batch with coverage already above the bar, so Gate 3 is not reached. Gates 1, 2, 4, 5 and 6 each get a `yes` from `replies.txt`. `gate-briefs.md` has a section for each of them, a `Reply: yes`, no `ESC-*`, lint or verify rule ID and no `path:line`, and every section's shown lines appear verbatim in the main thread's reply text, which itself carries none of those IDs in any turn (SW-113). The batch test output and the after-refactor coverage are saved under `04-artifacts/`, and the index row reaches `done`. The spec ID carries the run's date, so its paths use a wildcard (SW-109). |
| 15 | `15-rca-gate-brief` | `/sd:rca` from the raw evidence in the prompt and a seeded incident log (`InMemoryStore.save` leaves `#nextId` at 1 after a snapshot restore), run fresh under `models.escalation.ceiling: "sonnet"` so the `severity: P0` rule fires but is capped. Gates 1, 2 and 3 each get a `yes` from `replies.txt`. `gate-briefs.md` has a section for each of them, a `Reply: yes`, no `ESC-*`, lint or verify rule ID and no `path:line`, and every section's shown lines appear verbatim in the main thread's reply text, which itself carries none of those IDs in any turn. The spec has no unfilled tree or root cause field, the index row reaches `done`, and `store.js` is unchanged. The spec ID carries the run's date, so its paths use a wildcard (SW-111). The capped retro line stays with `11`. |
| 16 | `16-perf-gate-brief` | `/sd:perf` on a seeded quadratic de-duplication in `InMemoryStore.list` (`bench/list-bench.js` measures `listTodos` over 3000 todos, about 15 ms at p95 against a goal of 2 ms), one hotspot and one hypothesis. Gates 1 to 8 each get a reply from `replies.txt` (`yes`, `yes`, `choose H1`, `choose H1a`, `yes`, `keep`, `yes`, `yes`). `gate-briefs.md` has a section for each of them, a `Reply:` for each kind, no `ESC-*`, lint or verify rule ID and no `path:line`, and every section's shown lines appear verbatim in the main thread's reply text, which itself carries none of those IDs in any turn. The baseline, attempt and final measurements and the attempt and final test output are saved under `04-artifacts/`, the Results log has a `kept` row, `store.js` lost the de-duplication, and the index row reaches `done`. The spec ID carries the run's date, so its paths use a wildcard (SW-110). Not reached by this run, and covered by the contract lint only: Gate 2 with the baseline already at the goal, the red face of Gate 5, Gate 6 within noise, the `Already reverted` line of Gate 4, a second hotspot, and the narration of the two model escalation rules. |
| 17 | `17-port-gate-brief` | `/sd:port` with an in-repo donor (`src/legacy/title-format.js`, two functions and a `_WHITESPACE` constant) ported to `src/domain/title-format.js` at scope `module`, so the extraction escalates without GitNexus and that escalation is narrated in plain words. The run first makes the workspace a git repository, which the empty-diff proof needs. The host constitution forbids the `_` privacy prefix, which forces one deviation; everything else mirrors. Gates 1 to 6 each get a reply from `replies.txt` (`yes` four times, `continue` at the batch, `yes` at parity). `gate-briefs.md` has a section for each of them, a `Reply:` for each kind, no `ESC-*`, lint or verify rule ID, no `path:line`, no constitution section sign and no deviation ID without its `donor -> host` gloss, and every section's shown lines appear verbatim in the main thread's reply text, which itself carries none of those IDs in any turn. The snapshot manifest is frozen into `paths.protected`, the pinning output, empty-diff proof, batch output, parity index and parity report are saved under `04-artifacts/`, the donor is unchanged, the host file exists without the prefix, and the index row reaches `done`. The spec ID carries the run's date, so its paths use a wildcard (SW-112). Not reached by this run, and covered by the contract lint only: the incomplete face of Gate 2, a dirty production tree at Gate 3, the red face of Gate 5, Case B of Gate 6, a bridged donor and a plan over the split threshold. |

Each scenario directory may contain: `source.txt` (repo-relative base tree to copy),
`workspace/` (overlay applied on top - added/overwritten files only, mirrors the
`tests/contract-lint` `_base` + overlay fixture pattern), `prompt.txt` (the literal headless
prompt), `expect.json` (declarative assertions), and optional `budget.txt` / `timeout.txt` / `permission-mode.txt`
/ `skip-permissions.txt` / `disallowed-tools.txt` / `allowed-tools.txt` overrides, plus `replies.txt`
(gate replies sent as their own turns, see below). A
`skip-permissions.txt` must hold the evidenced reason the scenario cannot run under `dontAsk` with a
grant; the preflight refuses an empty one. `allowed-tools.txt`
holds one permission rule per line (`#` comments allowed), because a rule such as
`Bash(npm test:*)` contains a space. Besides the file assertions, `expect.json` accepts
`permission-denied` (`tool`, a regex, and `path`, a suffix): the run's `permission_denials` holds a
matching call. An optional `requires.txt` lists
commands the scenario needs on `PATH` (one per line, `#` comments allowed). The preflight checks it
for the selected scenarios only, so `-Case 03-spec-gate-negative` does not demand Node.

### Gate replies as turns (SW-103)

An optional `replies.txt` holds one reply per line (`#` comments allowed; a long reply stays on one
line). The runner sends `prompt.txt` first, then each reply as its own turn with
`claude -p --resume <session_id> "<reply>"`, in the same workspace, fake home and posture. A gate
then ends a turn and its reply arrives as the next message, the way it does with a person. That is
the path SW-99's Gate 1 probe showed prints the brief; one scripted turn that continues past every
gate prints none of it (ADR 0020).

- `budget.txt` and `timeout.txt` apply to each turn. `-ResultsFile` records the number of turns,
  the duration over all of them, and `totalCostUsd` from the **last** turn, plus each turn's raw
  figure in `turnCostsUsd`. On `--resume` the CLI reports the session's cumulative cost: in the
  first SW-103 run of `02` (`claude` 2.1.308) the five turns reported $0.45, $0.86, $1.47, $1.86 and
  $1.92, while the last turn's own tokens (one denied Edit) came to about $0.10. Summing them would
  have reported $6.57.
- Assertions run once, after the last turn. `permission_denials` is merged over every turn,
  `output-contains` reads the last turn's result, and `transcript-contains-section` reads every
  turn's session file.
- A turn that times out, prints no result, returns `is_error`, or leaves no `session_id` to resume
  makes the scenario "could not run" (SW-81), naming the turn.
- The reply list is fixed. If a turn ends somewhere other than the gate its reply was written for
  (for example a question the workflow asks first), the replies fall out of step and the
  assertions fail. That is the intended outcome: the run did not take the path the scenario
  describes. Read the kept transcript (`SD_E2E_TRANSCRIPT=1`) to see where it stopped.

### Assertion types

| Type | Fields | Passes when |
|---|---|---|
| `file-exists` / `file-not-exists` | `path` | the workspace file exists / does not |
| `file-matches` / `file-not-matches` | `path`, `pattern` (regex) | the file content matches / does not (a missing file counts as not matching) |
| `file-no-bom` | `path` | the file exists and does not start with a UTF-8 BOM |
| `output-contains` | `value` | the final `result` text holds `value` literally (scenario 5 only, see the rule) |
| `output-matches` / `output-not-matches` | `pattern` (regex) | the final `result` text does / does not match (scenario 5 only, SW-105). Used to scope one rule ID to one spec ID on a single line, which a literal `output-contains` cannot do; `-SelfTest` checks both offline |
| `exit-code` | `value` | `claude -p` exited with that code |
| `permission-denied` | `tool` (regex), `path` (suffix) | `permission_denials` holds a matching call (SW-80) |
| `transcript-contains-section` | `path`, `section` (heading regex, default `^## Gate `) | every matching section has shown lines, and they appear verbatim and in order in one main-thread text block. Shown lines are those after the heading, blank lines excluded, up to `### More decisions` or `Reply:`. Tool calls and subagent transcripts do not count (SW-99) |
| `transcript-not-matches` | `pattern` (regex, case-insensitive like `-match`) | no main-thread assistant text block of any turn matches. Tool calls, tool results, thinking blocks and subagent transcripts are not read. No transcript, or zero text blocks, fails; a match fails naming its turn and a short excerpt (SW-113) |

A `path` may contain `*` for a name the run picks, such as the date in a `REF-<slug>-<YYYYMMDD>`
spec ID. It must resolve to exactly one workspace file; none, or several, fails a `file-exists` or
`file-matches` rather than picking one (`-SelfTest` checks all three cases, SW-109).

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

### Outline-first plan scenarios (SW-92)

ADR 0022 splits `/sd:feature` Phase 3 into an outline (3a), Gate 2, and an expansion (3b). `09` and
`10` now assert that Gate 2 is presented with a `## Outline` in `01-plan.md` and **no**
`02-tasks.md`. `12-resume-outline-complexity` seeds an impact-mapped spec that crosses all three
production layers and carries an unresolved Open question. That makes Gate Complexity fire
deterministically, and the scenario asserts the `## Gate 2 - Complexity` section with no
`02-tasks.md` written: decompose is decided before any task block exists.

Run on 2026-10-25, `claude` 2.1.306, Windows, subscription auth (`CLAUDE_CODE_OAUTH_TOKEN`), one
`-Case` at a time:

| Scenario | Assertions | Result |
|---|---|---|
| `09-resume-approved` | 8/8 | pass |
| `10-resume-impact-mapped` | 8/8 | pass |
| `12-resume-outline-complexity` | 7/7 | pass |
| `08-resume-checkoff` (legacy single-step plan) | 8/8 | pass |
| `02-feature-happy` | 18/23, then 23/23 | first run stopped before Gate 3 (no transcript kept to diagnose); the re-run with `SD_E2E_TRANSCRIPT=1` passed |

### SW-92 follow-up runs (SW-105)

Run on 2026-10-28, `claude` 2.1.312, Windows 10.0.26200, pwsh 7.6.9, subscription auth
(`CLAUDE_CODE_OAUTH_TOKEN`, no `-CopyCredentials`), commit `1e92e48`. The first round of paid runs cost
$8.45 in all (`02` x5 $5.76, `05` and `-SelfTest` $0.64, `feat03b` $2.05). A second round the same day,
for items 4, 3 and 2, cost $5.19 (`05` $0.46, the split run $0.89, the probe $0.03, `02` x3 $3.81).
Item 2's result is in "Permission mode" above; the other three follow.

**`ESC-FEAT-03b` on the expansion (item 1): confirmed.** `probe-model-override.ps1 -Case feat03b`
now seeds an unresolved Open question, as scenario 12 does, so Gate 2 shows the Complexity face
whatever the architect's file partition. Gate 2 showed Face B in both runs (the precondition held).
Evidence is subagent `meta.json` and transcript `message.model` only:

| Run | Call | `model` param | Served |
|---|---|---|---|
| `feat03b-run` (reply `no-split`) | `sd-spec-architect` "Plan outline" (Phase 3a) | none | `claude-sonnet-5-5` |
| | `sd-spec-architect` "Expand outline into tasks" (Phase 3b) | `opus` | `claude-opus-5-5` |
| | `sd-code-explorer` | none | `claude-haiku-5-5` |
| `feat03b-control` (reply `approve split`) | `sd-spec-architect` x4 (outline and three child specs) | none | `claude-sonnet-5-5` |
| | `sd-code-explorer` | none | `claude-haiku-5-5` |

The run's retro carried `escalation: sd-spec-architect sonnet -> opus (trigger: ESC-FEAT-03b)`; the
control's carried none. That retro line is the model's own account and is context only. Cost $0.87
and $1.18, single runs.

**`SL068` live coverage (item 4): confirmed on the second run.** The first run of scenario `05`
passed 29 of 30 assertions ($0.43). The validate report raised `SL068` once, in block `B30`, on
`FEAT-BROKEN-018` (T02's `Files` adds `src/infrastructure/retry-after.ts`, citing `02-tasks.md:14`
and the outline row at `01-plan.md:18`), and none for `FEAT-BROKEN-014` (its one finding is `SL044`)
or `FEAT-BROKEN-017` (`SL060`). The failing assertion was the one that put `SL068` and the spec ID
on one line: the report prints each finding as a `### B30: ...` block with `File:line` and `Rule`
on their own lines. The two `output-not-matches` assertions passed, but vacuously, for the same
reason. They now match inside one finding block, and the offline self-check uses that layout. The
corrected `05` then passed 30 of 30 live ($0.46, commit `e6fbeb7`). `-SelfTest` passed in full
($0.21): auth 9 of 9, transcript 9 of 9, output assertions 4 of 4, and all four guard runs
detected.

**`approve split` with no task block (item 3): confirmed.** Run as a manual scenario kept out of the
suite: scenario 12's spec and prompt, with the reply `approve split` sent as a second turn (2 turns,
148 s, $0.89). Read from the kept workspace: the parent `FEAT-e2e-outline-split` is `archived`, with
`01-plan.md` (and its `## Outline`), `03-decisions.md`, `05-retro.md` and `gate-briefs.md` but no
`02-tasks.md`; three child specs exist at `draft` (`-domain-due-date`, `-store-due-before`,
`-service-overdue`), each with `spawned-by: FEAT-e2e-outline-split` under `linked_specs`, matched by
three `spawns:` entries on the parent; `index.md` has the four rows; `05-retro.md` has a
`## Decomposition` note naming the children. The run's own assertions reported 7 of 8, because the
scratch scenario looked for `spawns:` as a top-level key while `/sd:spec link` stores it as an
item of `linked_specs`. A single run.

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
