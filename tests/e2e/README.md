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
  `02-feature-happy`, `06`-`08`).

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
```

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
| 2 | `02-feature-happy` | `/sd:feature` happy path on a small spec reaches `done` with a full artifact set and a passing `06-verify.md`. |
| 3 | `03-spec-gate-negative` | spec-gate denies a direct code edit with no in-progress spec recorded. |
| 4 | `04-closeout-negative` | spec-gate's verify-gate denies flipping an index row to `done` with no passing `06-verify.md`. |
| 5 | `05-spec-lint-validate` | `/sd:spec validate --all` against `examples/spec-lint-fixture/broken` surfaces the seeded `SL0xx` findings - the one command this harness must assert on output text, since `/sd:spec validate` is report-only with no artifact file. |
| 6 | `06-escalation-implementer` | `/sd:feature` Phase 4 resumed on a seeded 2-task spec under `models.escalation.ceiling: "sonnet"`: the `Estimated complexity: L` task logs exactly one uncapped, applied `escalation: sd-implementer haiku -> sonnet (trigger: ESC-FEAT-04)` line in `05-retro.md`; the `S` / `trivial` task logs none. |
| 7 | `07-escalation-disabled` | Same seeded spec under `models.escalation.enabled: false`, with T01 at `Estimated complexity: L` and T02 at `Reversibility: hard`: both tasks run and `05-retro.md` carries no `escalation:` line - the suppression covers `ESC-FEAT-04` and `ESC-FEAT-04b` alike. |
| 8 | `08-resume-checkoff` | `/sd:feature` re-invoked on a seeded 2-task spec whose T01 is already checked off (`Status: done`, code landed, retro line written) and T02 is `open`: the resume executes T02 only - `05-retro.md` gains a `T02:` line and still has exactly one `T01:` line, `countTodos` is not re-added - and both tasks end at the canonical `Status: done` marker (SW-71). |

Each scenario directory may contain: `source.txt` (repo-relative base tree to copy),
`workspace/` (overlay applied on top - added/overwritten files only, mirrors the
`tests/contract-lint` `_base` + overlay fixture pattern), `prompt.txt` (the literal headless
prompt), `expect.json` (declarative assertions), and optional `budget.txt` / `permission-mode.txt`
/ `skip-permissions.txt` / `disallowed-tools.txt` overrides. An optional `requires.txt` lists
commands the scenario needs on `PATH` (one per line, `#` comments allowed). The preflight checks it
for the selected scenarios only, so `-Case 03-spec-gate-negative` does not demand Node.

## Cost and CI placement

Not per-PR: a `claude -p` suite costs real tokens and minutes of wall clock, and neither belongs
in a gate on every push. It runs nightly (or on manual `workflow_dispatch`) on a single OS via
`.github/workflows/e2e-nightly.yml`.

**The cost trade-off per run.** With API-key auth, one full run costs **more than ~$2.50** (see the
measured table below), plus about **$0.35** for `-SelfTest`. With subscription auth,
`total_cost_usd` is a notional figure, and the run draws on the plan's usage allowance instead of
dollars. The measured run below used subscription auth. That makes the suite practical to run
locally before a PR, one `-Case` at a time for the cheap scenarios (`03`, `04`: about $0.15 each).
It is no longer only a nightly report to read afterwards.

Measured cost of one full 5-scenario run on this machine (`SD_E2E_DEBUG=1`, per-scenario
`total_cost_usd` from the `claude -p --output-format json` result), 2026-08-01, `claude` 2.1.220,
auth via `~/.claude/.credentials.json` (claude.ai login - `ANTHROPIC_API_KEY` must be unset, see
"Isolation and auth"):

| Scenario | `total_cost_usd` | Result |
|---|---|---|
| `01-setup` | $0.7355 | pass |
| `02-feature-happy` | not recorded - process killed at the 600s timeout before `claude -p` returned a result | **fail (timeout)** - see gap #1 below |
| `03-spec-gate-negative` | $0.1350 | pass |
| `04-closeout-negative` | $0.1696 | pass |
| `05-spec-lint-validate` | $1.4645 | pass |

Sum of the four completed scenarios: **~$2.50**. `02-feature-happy` additionally consumed real,
uncaptured spend across its full 10-minute run before being killed - the true full-suite cost is
higher than the $2.50 figure above. `-SelfTest` (re-runs only `03`/`04` against a neutered guard)
cost an additional $0.1156 + $0.2361 = ~$0.35 and correctly flagged both scenarios as
guard-detected (the `events.jsonl` block-event assertion fails as expected when the hook is
stubbed out, even though the model independently declined to make the edit in one case - see
`Test-OneAssertion` / `-SelfTest` semantics in `run-e2e.ps1`).

**Acceptance bar "green 3 times consecutively" is not yet met.** Only one full-suite run has been
completed against these figures, and it was not clean (see gap #1). Two more consecutive clean
runs are still required before this harness can be considered to satisfy SW-27's reproducibility
criterion - tracked as follow-up, not attempted further here to avoid spending real budget
re-confirming a known, non-flaky failure.

### Escalation scenarios (SW-61)

First run of `06` and `07`, 2026-09-25, `claude` 2.1.282, Windows, subscription auth
(`~/.claude/.credentials.json`), one `-Case` at a time:

| Scenario | `total_cost_usd` | Assertions | Result |
|---|---|---|---|
| `06-escalation-implementer` | $0.7453 | 7/7 | pass |
| `07-escalation-disabled` | $0.6820 | 5/5 | pass |

In `06` the `ESC-FEAT-04` line was written before the T01 implementer call and no `unapplied`
suffix appeared, so the Agent tool accepted a `model` parameter on this CLI version. That is
the model's own account of the invocation, not a per-invocation model attribution read from a
transcript - it does not settle SW-59.

## Known product gaps this harness surfaced

**1. Rule 1 (`paths.protected`) appears to make `/sd:feature` unable to complete under a
permission posture that actually respects hooks - this looks like a real, pre-existing bug, not a
new regression.** `.specs/index.md` is listed in `paths.protected` by default
(`templates/project-config.template.json`), and `spec-gate.ps1`/`.sh` Rule 1 blocks EVERY edit to a
protected path unconditionally (no `mode` check, unlike Rule 3) - except the narrow Rule 0
carve-out for a FEAT- row's `in-progress -> done` transition with a passing `06-verify.md`. But
`/sd:feature`'s own Gate 1 (spec approval, `draft -> approved`) and Gate 2 (plan approval,
`approved -> in-progress`) work by editing that exact same `index.md` row with the `Edit` tool -
there is no separate "`/sd:spec status` mechanism" at the tool-call level, so the hook cannot tell
apart the workflow's own legitimate transition from a careless hand-edit. Scenario 2's real run
against the unmodified `examples/fixture-project` config confirms this happening live - the exact
sequence spec-gate recorded in `.specs/_metrics/events.jsonl`:

```
{"...","gate":"protected","decision":"block"}          <- draft -> approved edit
{"...","spec_id":"FEAT-todo-count","phase":"draft","event":"spec_transition","from":"-","decision":"block"}
{"...","gate":"protected","decision":"block"}          <- approved -> in-progress edit
{"...","spec_id":"FEAT-todo-count","phase":"approved","event":"spec_transition","from":"draft","decision":"block"}
{"...","gate":"protected","decision":"block"}          <- in-progress -> done edit (also hits Rule 1 first)
{"...","spec_id":"FEAT-todo-count","phase":"in-progress","event":"spec_transition","from":"approved","decision":"block"}
...
{"...","spec_id":"FEAT-todo-count","phase":"done","event":"gate","gate":"verify","decision":"allow"}   <- Rule 0 finally allows the LAST one
```

Every one of those edits nonetheless landed in the real file, and the scenario passed - only
because scenario 2 deliberately runs under `acceptEdits` (see "Permission mode" above), which this
harness independently proved overrides a hook's deny. Under the harness's own default `dontAsk`
(the mode that actually enforces hook decisions), the very first status transition of any
`/sd:feature` run would be denied and the workflow could never progress past Gate 1. This was never
caught before because `tests/hooks/run-conformance.ps1` only pipes crafted JSON into the hook
script in isolation - it has no way to know the real workflow's own operation collides with Rule 1
- and no prior mechanism drove a real session through `/sd:feature` under an enforcing permission
mode. Likely candidate fixes (not attempted here - out of scope for SW-27, and touching `spec-gate`
means a twin-implementation change plus new `tests/hooks` fixtures): widen Rule 0's scope beyond
"FEAT- done transitions only" to cover legitimate in-workflow status transitions generally, or
special-case `index.md` row edits that only change the `Status` column via a recognized transition
pattern. **Recommend filing this as its own ticket** rather than folding a `hooks/` fix into SW-27's
scope.

**Update, 2026-08-01 full-suite run:** this time `02-feature-happy` did not merely proceed despite
repeated Rule 1 denials - it stalled outright and hit the 600s timeout. `events.jsonl` shows the
same three blocked transitions, one allowed code-edit, then a `subagent_stop` with `"stale":1` at
06:24:03, and nothing further before the kill at 06:27:28. Whether this is the same underlying
collision now additionally tripping some retry/backoff path, or a second, separate stall condition,
is not diagnosed here - worth investigating alongside the Rule 1 fix rather than assuming the two
are identical. This also means the suite has not yet achieved a clean run, so the "reproducible
green 3x" acceptance bar (see "Cost and CI placement" above) remains open.

**2. `spec-gate`'s `PreToolUse` matcher only covers the `Edit`, `Write`, and `MultiEdit` tools.** A
model that is willing to bypass the intended workflow (unlike the well-aligned behavior seen while
building this harness - see "Scenario prompts" above) could in principle write the same file
change through `Bash` (`sed`, `cat <<EOF >`, ...), which the hook never sees. This is not a defect
in this harness or in `spec-gate` as scoped; it is a real, previously-unverified boundary of what
the hook covers, discovered by driving a real session instead of only unit-testing the hook script
in isolation. Worth a follow-up ticket if Bash-mediated code edits during an active spec workflow
turn out to matter in practice.
