# Contributing to specwright

Thanks for considering a contribution. This document covers the PR process,
per-file-type guidelines, and how to test changes locally.

---

## Quick links

- [Project goals and non-goals](#project-goals-and-non-goals)
- [Repo layout](#repo-layout)
- [The manifest](#the-manifest)
- [Test suites and prerequisites](#test-suites-and-prerequisites)
- [Threshold re-calibration](#threshold-re-calibration)
- [PR process](#pr-process)
  - [Changelog vs ADR](#changelog-vs-adr)
- [Per-file-type guidelines](#per-file-type-guidelines)
  - [Commands (`commands/*.md`)](#commands-commandsmd)
  - [Agents (`agents/*.md`)](#agents-agentsmd)
  - [Hooks (`hooks/powershell/*.ps1` and `hooks/bash/*.sh`)](#hooks)
  - [Templates (`templates/**`)](#templates-templates)
- [Local install test](#local-install-test)
- [Hook test snippets](#hook-test-snippets)
- [Style conventions](#style-conventions)

---

## Project goals and non-goals

**Goals**
- Spec-driven workflows on top of Claude Code: every non-trivial change starts with a spec.
- Stack-agnostic: works for .NET, Node, Python, Go, Rust, etc. No language assumptions in agents.
- Cross-platform: PowerShell (Windows) and bash (Unix/macOS) parity.
- Cost-aware: heavy reasoning on `sonnet`, mechanical work on `haiku`.

**Non-goals**
- Not an IDE plugin or VSCode extension. Lives in `~/.claude/`.
- Not a replacement for `git` workflow tooling.
- Not a code formatter or linter wrapper.

---

## Repo layout

```
specwright/
  commands/         # 14 slash commands (markdown with frontmatter)
  agents/           # 6 subagent definitions (markdown with frontmatter)
  hooks/
    powershell/     # 4 PowerShell hooks
    bash/           # 4 bash hooks (parity with PowerShell)
  templates/        # 4 setup templates
    specs/          # 6 spec templates
  install/          # install.ps1 + install.sh + install/README.md
  docs/             # architecture, usage, walkthrough, troubleshooting
  examples/         # demo references
```

---

## The manifest

`specwright.manifest.json` is the canonical inventory contract. Check 7 of
`scripts/validate.{ps1,sh}` reads it and fails the build when a number published in the docs
disagrees with what is actually on disk. A discipline tool that misdescribes itself has no
standing to lecture anyone about specs.

The manifest **stores no counts**. It declares where assets live (`areas`, each with a `glob` or
an explicit `files` list) and where the docs make claims about them (`docClaims`); the numbers are
derived from disk at runtime. That is deliberate - a manifest holding hardcoded counts would be a
third place to update on every change and would reintroduce exactly the drift it exists to prevent.

What this means in practice:

- **Adding a command, agent, skill, or template**: add the file. Nothing else. The count follows.
- **Publishing a number in the docs**: add a `docClaims` entry - `file`, a `pattern` with exactly
  one capture group around the number, and the `equals` quantity it must match. A number with no
  entry fails the build as an *undeclared claim*, so this is not optional.
- **Rewording a sentence that carries a number**: update its `pattern` too. A pattern that matches
  nothing fails as a *vacuous claim* rather than passing quietly - otherwise a reword would turn
  the check into a no-op that still reports green.
- **Writing intentionally historical docs** (superseded counts as a past-state record): put the
  path in `historicalExclusions`. `docs/history/`, `docs/superpowers/` and `CHANGELOG.md` are
  already excluded. Never "fix" their numbers to match today's disk state.
- **Publishing the current released version**: add a `versionClaims` entry (`file` + a `pattern`
  with one capture group, no `equals`). It is checked against the newest dated
  `## [x.y.z] - <date>` heading in `CHANGELOG.md`, not against a manifest quantity - CHANGELOG is
  the single source of truth for "what version is released." Unlike `docClaims`, there is no
  undeclared-claim scan for version strings yet: a version claim in a doc that is not listed here
  is not caught.

Two constraints on `pattern`: it must be valid in **both** POSIX ERE (bash `[[ =~ ]]`) and .NET
(PowerShell), so use `[0-9]` rather than `\d` and avoid lookarounds; and it is matched
**case-sensitively** on both platforms. This applies to `versionClaims` patterns too.

`scripts/selftest-docs.{ps1,sh}` proves Check 7 still bites, by corrupting a throwaway copy of the
repo and asserting the validator catches it. CI runs it on all three OSes.

`tests/hooks/run-conformance.ps1` (pwsh-only by design, see
[Why the parity harnesses are pwsh-only](#why-the-parity-harnesses-are-pwsh-only)) pipes every
golden fixture under `tests/hooks/fixtures/` into the bash and PowerShell implementation of each
hook and fails if their normalized decisions diverge from each other or from the golden. Add a
fixture case whenever you add hook behavior; `-SelfTest` proves the harness still detects
divergence.

In a fixture's `input.json`, `{{ROOT}}` is the workspace (the project root) and `{{CWD}}` is the
session cwd. The session cwd is the root unless `setup.json` names a `"cwd"` subdirectory of the
fixture's own `workspace/` tree. The runner strips `CLAUDE_PROJECT_DIR` from every child process,
and `setup.json` `"env"` sets it per case (`{{ROOT}}` is substituted there too). A case with an
off-root `cwd` also fails if any hook creates `.specs/` or `.claude/` under that cwd (SW-78).

Check 7 needs `jq` on Unix and **fails loudly without it**. This is the opposite of the hook rule
below (hooks exit `0` silently when `jq` is missing so they never block a user on their own bugs) -
a validator that skipped itself for a missing tool would turn CI green while checking nothing.

### Contract lint (Check 8)

Where Check 7 guards *inventory*, Check 8 guards the **relationships between** the prompt files:
which agent a command invokes, which skill an agent loads, which template a prompt reads, how many
hard gates a workflow declares. It is a script, not a prompt - `scripts/contract-lint.{ps1,sh}`,
configured entirely from the manifest's `contractLint` subtree. Full rule catalogue and rationale:
[`docs/contract-lint.md`](docs/contract-lint.md).

Run it directly while iterating:

```bash
bash scripts/contract-lint.sh --root .
```
```powershell
.\scripts\contract-lint.ps1 -Root .
```

Exit `0` means no BLOCK findings, `1` means at least one, and **`2` means it could not run at all**
(missing manifest, missing `jq`, or the registry parity guard tripped). Check 8 treats `2` as a
failure for the same reason Check 7 refuses to skip itself.

**Suppressing a finding.** Rarely, a violation is correct on purpose. Put a comment on the offending
line or the line above it, naming the rule and giving a real reason:

```text
<!-- contract-lint: allow CL305 - the option here buys a logged constitution exception rather than a way past the requirement -->
```

Three things constrain that escape hatch, and all three are enforced:

- **The reason is mandatory.** Under ten non-separator characters fails as CL900. "`- x`" is not a
  reason.
- **The rule id must exist.** A typo fails as CL901 rather than silently suppressing nothing.
- **It must actually suppress something.** A suppression that outlives the finding it was written
  for fails as CL902 - the same anti-rot posture as Check 7's vacuous-claim rule.

A suppression can never suppress CL900, CL901 or CL902; that would be a self-authorizing loophole.

**Adding a rule** means four edits, and skipping any one of them fails CI: a `contractLint.rules`
registry entry, a rule function in *both* implementations, a fixture case under
`tests/contract-lint/` whose `expected.json` names the rule, and a row in `docs/contract-lint.md`.
Each edge of that square is guarded by a different mechanism - the linters' own registry parity
guard, and invariants C and D in `tests/contract-lint/run-selftest.ps1`.

`tests/contract-lint/run-selftest.ps1` is the fixture suite. Like the hook conformance harness, it
is pwsh-only by design ([why](#why-the-parity-harnesses-are-pwsh-only)). `-SelfTest` swaps in a linter that reports nothing and asserts the harness
notices.

### Root-level ad-hoc notes guard (Check 9)

Review findings become Jira issues, not files in the tree. If you find a defect while reviewing a
PR or doing an audit, file it (or fix it directly) instead of leaving a `REVIEW-TODO.md`-style
snapshot at the repo root - a hand-maintained defect list that no gate reads is exactly the kind of
honour-system drift this repo exists to eliminate. Check 9 of `scripts/validate.{ps1,sh}` enforces
this mechanically: it fails the build when a root-level file matches a declared ad-hoc-notes
pattern in `specwright.manifest.json`'s `adHocNotesGuard` (`TODO.md`, `FIXME.md`, `NOTES.md`, and
similarly-named findings snapshots). `ROADMAP.md` is a deliberately maintained project document and
is excluded on purpose - the distinction is "ad-hoc findings snapshot" vs "maintained project
document," not file extension. `scripts/selftest-root-guard.{ps1,sh}` proves Check 9 still bites,
the same posture as `scripts/selftest-docs.{ps1,sh}` for Check 7.

### Bash strict mode (Check 10)

Every `*.sh` in the repo opens with `set -euo pipefail` as its first statement (comments and the
shebang may come before it; a wider flag cluster such as `-Eeuo` is fine). Check 10 of
`scripts/validate.{ps1,sh}` enforces this. A script that must not run under strict mode goes in
`specwright.manifest.json`'s `bashStrictMode.exceptions` with a `reason`. Today that is only the
bash hooks, which must exit 0 on every failure path. An exception whose path no longer exists
fails the check, so the list cannot go stale.
Scripts that need a tool the runner may lack (e.g. `jq`) check for it up front and exit `2` with
the tool's name. They must not let a missing dependency show up as a failure of the thing under
test.

---

## Test suites and prerequisites

"Testing" in this repo means running the suites below. Every suite checks its own tools up front. A
missing prerequisite exits `2` and names the dependency; it never shows up as a failed assertion
against the code under test.

| Suite | Needs | What it covers | Run it | In CI |
|---|---|---|---|---|
| `scripts/validate.{sh,ps1}` | bash + `jq`; or pwsh + bash | Every engine invariant: ASCII, hook-pair parity, model aliases, install targets, changelog, docs claims (Check 7), contract lint (Check 8), root notes guard (Check 9), bash strict mode (Check 10) | `bash scripts/validate.sh` / `.\scripts\validate.ps1` | Every OS, per push |
| `scripts/smoke-hooks.{sh,ps1}` | bash + `jq`; or pwsh | Each hook, fed fixture JSON: exits `0` and emits the expected decision | `bash scripts/smoke-hooks.sh` / `.\scripts\smoke-hooks.ps1` | Every OS, per push |
| `scripts/selftest-docs.{sh,ps1}` | Same as `validate` | Check 7 still catches a corrupted doc claim | `bash scripts/selftest-docs.sh` | Every OS, per push |
| `scripts/selftest-root-guard.{sh,ps1}` | Same as `validate` | Check 9 still catches a root-level notes file | `bash scripts/selftest-root-guard.sh` | Every OS, per push |
| `scripts/contract-lint.{sh,ps1}` | bash + `jq`; or pwsh | Check 8 on its own, for fast iteration on prompts | `bash scripts/contract-lint.sh --root .` | Via `validate` |
| `tests/hooks/run-conformance.ps1` | **pwsh 7** + bash + `jq` | bash and PowerShell hooks reach identical decisions on every golden fixture | `pwsh tests/hooks/run-conformance.ps1 [-SelfTest]` | Every OS, per push |
| `tests/contract-lint/run-selftest.ps1` | **pwsh** + bash + `jq` | Both linters produce identical findings on every fixture | `pwsh tests/contract-lint/run-selftest.ps1 [-SelfTest]` | Every OS, per push |
| `tests/installer/run-prefix-parity.ps1` | **pwsh 7** + bash | All installer scripts agree on which `--prefix` values they accept | `pwsh tests/installer/run-prefix-parity.ps1 [-SelfTest]` | Every OS, per push |
| `tests/prompt-size-report/run-parity.ps1` | **pwsh 7** + bash + git | Both prompt size reports print identical output, matching a hand-computed table | `pwsh tests/prompt-size-report/run-parity.ps1` | Every OS, per push |
| `tests/e2e/run-e2e.ps1` | **pwsh 7** + `claude` CLI + claude auth (a subscription works; no API key needed) + Node for some scenarios | Real `claude -p` sessions: the commands and gates *behave* correctly, asserted on produced artifacts | `pwsh tests/e2e/run-e2e.ps1 [-Case <name>] [-SelfTest]` | Nightly, ubuntu only |

`ci.yml` also runs inline checks: the lesson tooling fixtures and the installer's
argument-validation and partial-install negative cases. It needs nothing beyond bash + `jq` or
pwsh. `tests/hooks/measure-latency.ps1` is a measurement tool, not a pass/fail suite.

### Why the parity harnesses are pwsh-only

The five `tests/**/*.ps1` runners above have no bash twin. **That is a deliberate decision, not a
gap.** Each one exists to prove that the bash and PowerShell implementations of something agree.
That can only be *asserted* when one process drives both implementations and compares their
outputs directly. Two separate platform-native runners, each green on its own side, only let you
*infer* parity, and a bash twin of the harness would itself be one more pair that could drift.

- **pwsh runs everywhere.** PowerShell 7 runs on Linux and macOS, and all three CI runner images
  have it. On a machine without it, `pwsh` fails with the shell's own "command not found" before
  any assertion runs.
- **Harnesses aren't shipped.** The "hooks ship in pairs" rule applies to what the installer
  copies into `~/.claude/`. The harnesses are never installed.
- **No pwsh? You can still check most of it.** A contributor without pwsh can run every
  `scripts/*.sh` suite. CI then covers the parity harnesses on every push.

### e2e auth and cost

The e2e suite is the only one that exercises real prompt behavior, so it matters that the
maintainer can run it. It authenticates with any of the following:

- `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token` (a subscription).
- An existing `claude` login in `~/.claude/.credentials.json` (a subscription).
- `ANTHROPIC_API_KEY` (API billing).

On an API key, one full run costs more than ~$2.50. On a subscription, it draws on plan usage
instead. The cheap negative scenarios (`-Case 03-spec-gate-negative`, `-Case 04-closeout-negative`)
are practical to run before a PR. Details, the measured per-scenario costs, and the macOS Keychain
caveat are in [`tests/e2e/README.md`](tests/e2e/README.md#auth).

### Minimum local check before a PR

```bash
bash scripts/validate.sh && bash scripts/smoke-hooks.sh          # any OS with bash + jq
```
```powershell
.\scripts\validate.ps1; .\scripts\smoke-hooks.ps1                # Windows
pwsh tests/hooks/run-conformance.ps1                             # if you touched hooks
pwsh tests/contract-lint/run-selftest.ps1                        # if you touched a lint rule
pwsh tests/e2e/run-e2e.ps1 -Case 03-spec-gate-negative           # if you touched a command or gate
```

---

## Threshold re-calibration

Every hardcoded threshold in this repo (Gate Complexity's tasks/layers/files limits,
`retroStaleMinutes`, `debounceMinutes`, `maxLessons`, `metrics.maxSizeKb`, the perf gate's noise
floor) started as an estimate, not a measurement - see `docs/adr/0004-threshold-calibration.md`.
Re-run the calibration pass **every 20 closed specs, or at each minor release, whichever comes
first**:

1. Run `/sd:status --calibration` against the accumulated `.specs/index.md` and
   `.specs/_metrics/events.jsonl`.
2. For each threshold, record the verdict - keep, change, or insufficient data - in a new ADR under
   `docs/adr/`. "Insufficient data" is a legitimate, expected outcome at a thin corpus size; do not
   change a threshold without a stated measurement behind it.
3. Where a threshold's rationale in `templates/project-config.template.json` is still a judgement
   call (no measured basis), leave its `_..._use` caveat in place rather than removing it.

### Prompt size report

Run it in the same pass, at each minor release, before the tag is cut:

```bash
bash scripts/prompt-size-report.sh          # compares against the previous release tag
```

Each `FLAG` row (a file that grew more than `promptSizeReport.flagGrowthPercent`) needs one line in
the release's `CHANGELOG.md` section: either "trimmed" or why the growth is worth its cost. There is
no budget number to raise; that ratchet (`CL500`) was retired, see
`docs/adr/0011-retire-cl500-byte-ratchet.md`. `docs/contract-lint.md` ("Prompt size report")
describes what a normal release looks like and the signs that this check has stopped working.

---

## PR process

1. **Open an issue first** for anything larger than a typo or a small docs fix. State:
   - What problem the change solves.
   - Which files are affected.
   - Whether it is a breaking change.

2. **Branch from `main`** with a descriptive name:
   - `feat/<slug>` for new commands / agents / hooks.
   - `fix/<slug>` for bug fixes.
   - `docs/<slug>` for docs-only changes.
   - `refactor/<slug>` for internal restructuring.

3. **Keep PRs focused.** One workflow, one agent, one hook per PR. A 1500-line "improve everything" PR will be asked to split.

4. **Run the validator** before opening the PR: `scripts/validate.ps1` (Windows) or
   `scripts/validate.sh` (Unix) runs every engine-invariant check at once (ASCII, hook-pair parity,
   model aliases, install-target counts, changelog gate, docs consistency, root-level notes guard).
   CI runs the same on Windows, Ubuntu and macOS. [Test suites and
   prerequisites](#test-suites-and-prerequisites) lists every other suite, what each needs, and the
   minimum local check. See also the [Local install test](#local-install-test) for a manual install
   smoke test, and [The manifest](#the-manifest) for what Check 7 enforces.

5. **Update the changelog.** Add a line under `## [Unreleased]` in `CHANGELOG.md`. Say what
   changed; put why in an ADR - see [Changelog vs ADR](#changelog-vs-adr).

6. **Open the PR** with:
   - A short description.
   - Screenshots or terminal output if behaviour changes.
   - A note on whether docs were updated.

### Changelog vs ADR

The two answer different questions, for different readers:

- **`CHANGELOG.md` says what changed** and whether it affects the reader: the new command, flag,
  file, rule or behavior, and what a user or contributor has to do about it. One entry, a few
  lines, then a link to the ADR if one exists.
- **An ADR in `docs/adr/` says why, and what was rejected**: the context that forced the decision,
  the alternatives considered, what was deliberately not built, known gaps, and consequences.
  One ADR per substantive decision, numbered `NNNN-<slug>.md`, following the existing ones.

**The test.** If a sentence would still be true had the change been built differently, it is
rationale and belongs in the ADR. If it describes what now exists, it belongs in the changelog.
"Deliberately not built", "known gap", "X instead of Y because" and "found while building it" are
always ADR material. If the rationale already lives in a doc (for example `docs/contract-lint.md`
for a lint rule), link to it rather than copying it into a second place.

**Worked example** (SW-42, from 1.6.0). The original changelog entry carried this:

```markdown
- **`## Spawned specs` in the feature, bug, refactor, and perf spec templates** (SW-42) - ...
  prompts for the section when the retro names deferred work - a prompt, not a gate: gate counts
  are unchanged, since hard-gating hygiene would tax every spec for a minority's benefit.
  - **The section ships with no `<<...>>` token.** It is filled at close-out, i.e. after
    `approved`, so an author-fill placeholder there would be an `SL010` BLOCK on every spec ...
```

Split along the test, the changelog keeps what exists:

```markdown
- **`## Spawned specs` in the feature, bug, refactor and perf spec templates** (SW-42), using the
  RCA template's reserved-ID table. Close-out prompts for it when the retro names deferred work;
  gate counts are unchanged. New `SL090` ... See [ADR 0009](docs/adr/0009-...md).
```

and `docs/adr/0009-spawned-specs-and-suggest-band.md` takes the "why": prompt rather than gate
because hard-gating taxes every spec, no `<<...>>` token because of `SL010`, a reserved ID is not an
index row because of `SL032`.

---

## Per-file-type guidelines

### Commands (`commands/*.md`)

A command is a markdown file with YAML frontmatter that Claude Code reads when the user types `/sd:<name>`.

**Required structure:**
```markdown
---
description: One-line summary shown in /help
argument-hint: <ID or slug>
---

# /sd:<name>

## Phase 0 - Bootstrap
1. Read ~/.claude/skills/sd/sd-bootstrap-guard/SKILL.md and apply it
2. Detect state (resumable?)

## Phase 1 - <name>
... (with hard gates marked as Gate N)

## Rules
- Hard constraints that cannot be bypassed.
```

**Conventions:**
- Phase 0 always bootstraps; do not skip. Step 1 applies `sd-bootstrap-guard` and never restates
  its messages - contract-lint `CL009` blocks a Phase 0 that does.
- Hard gates use the explicit marker `Gate N` and prose "STOP. Wait for explicit user approval."
- State machine documented at top of file (what happens on re-invocation).
- Subagent invocation uses the `sd-` prefix, never bare names.
- No stack-specific commands inside (no `dotnet test`, `npm test`, etc.). Reference the `commands.test` field from `project-config.json`.

### Agents (`agents/*.md`)

A subagent is a markdown file with YAML frontmatter consumed by the `Task` tool.

**Required frontmatter:**
```yaml
---
name: sd-<role>
color: <color>   # e.g. cyan, orange, purple, green, blue - used for display only
description: One-line summary used by routing.
model: sonnet   # MUST be an alias: sonnet | haiku | opus | inherit
tools: Read, Grep, Glob, ...   # MINIMAL allowlist
skills:
  - sd-<shared-rule-pack>   # any skill this agent's body references; see Skills below
---
```

**Critical:**
- `model:` MUST be an alias. Full IDs like `claude-sonnet-4-7` are not portable and may not even exist. The alias `sonnet` auto-resolves to the latest Sonnet.
- `tools:` should be the minimum set the agent needs. Read-only agents do not get `Write`. Implementer does not get `WebSearch`.
- `skills:` must list every skill the agent body references (`**skill-name**` in prose). A rule used by multiple agents lives in one `SKILL.md`, never copy-pasted into agent bodies.
- Agent must read `CLAUDE.md` and `constitution.md` at runtime. No hardcoded stack assumptions (no `cs`, `csproj`, `dotnet`, etc. literal references unless they come from project config).
- Every finding cites `file:line`. No prose without citations.

**Machine-readable input declarations.** Under every heading that selects a distinct agent
behavior by field value (`## Mode N: TASK = <mode>`, `## Task type: `<type>``, `### `TASK =
<type>``, `### `WORKFLOW_TYPE = <type>``), add two lines immediately before the existing prose:

```
Inputs (required): SPEC, IMPACT
Inputs (optional): MODE, REPLAN_SCOPE
```

- Tokens are `UPPER_SNAKE`, comma-separated, exactly the identifiers the calling command sets -
  never a paraphrase.
- Write `none` explicitly when a mode has no required (or no optional) inputs. Silence is not an
  assertion - an omitted line reads as "not yet documented," not as "empty."
- The existing prose `Inputs: ...` line (with parenthetical caveats, cross-references, etc.) stays
  below unchanged - the two new lines are additive, for tooling to grep, not a replacement for the
  explanatory prose.
- When adding or changing an agent invocation in `commands/*.md`, cross-check it against the
  target mode's declared inputs: a token the command passes that the mode doesn't declare, or a
  required token the mode declares that the command omits, is a real defect - fix the mismatch (add
  the missing token to the declaration or the invocation, whichever is actually correct) rather than
  leaving the two out of sync.
- This cross-check is machine-enforced: Check 8's `CL100`-`CL104` rules (`docs/contract-lint.md`)
  parse both sides and BLOCK on a mode mismatch or a missing required input. A legitimate mismatch
  the declaration can't express (an either/or required set, for example) gets a
  `<!-- contract-lint: allow CLxxx - <reason> -->` suppression, not a silent gap.

### Hooks

Hooks come in pairs. If you change `hooks/powershell/foo.ps1`, you also update `hooks/bash/foo.sh`. The repo CI runs `scripts/validate.{ps1,sh}`, which refuses PRs where the pair drifts (along with the other engine-invariant checks).

**PowerShell (`*.ps1`) - critical encoding rule:**

PowerShell 5.1 reads UTF-8 without BOM as Windows-1252. The em-dash `-` (U+2014) is byte sequence `E2 80 94`; PowerShell sees the final byte `0x94` as a curly closing quote, and your string terminates in the middle of nowhere. Result: cascading parse errors like `Missing closing '}'`.

**Pure ASCII only in `*.ps1` files.** Substitute as follows:

| Forbidden | Use instead |
|---|---|
| `-` (em-dash U+2014) | `-` (ASCII hyphen-minus) |
| `->` (right arrow) | `->` |
| `>` (triangular bullet) | `>` |
| `OK:` | `OK:` or `[OK]` |
| `WARN:` | `WARN:` or `[WARN]` |
| `X` | `X` or `[FAIL]` |
| `i` | `i` or `[INFO]` |

Verify before committing:
```bash
grep -nP "[^\x00-\x7F]" hooks/powershell/*.ps1 install/install.ps1
# Empty output = OK. Any output = REJECT, fix it.
```

**Bash (`*.sh`):**
- Shebang: `#!/usr/bin/env bash`
- Use `jq` for JSON; if `jq` is missing, exit `0` silently (do not block the user).
- Use `stat -c %Y` (Linux) AND `stat -f %m` (macOS) - detect and branch.
- Set `chmod +x` on commit (or rely on the installer to do it).
- Test with `bash -n hooks/bash/foo.sh` to catch syntax errors before runtime.

### Templates (`templates/**`)

Templates are filled by `/sd:setup` and by agents.

- Use `<<placeholder>>` syntax for fields the user fills manually.
- Keep templates short and scannable. A `CLAUDE.md` template that ends up being 600 lines defeats the purpose.
- Spec templates leave the cross-phase fields explicitly **empty** with a comment like `<!-- Filled by Phase 3 - do not pre-fill -->`. This is intentional: workflows enforce sequencing through empty fields.

---

## Local install test

Before opening any PR that touches install, hooks, commands, or agents:

**Windows (PowerShell):**
```powershell
# 1. From the repo root, dry-run first
.\install\install.ps1 -DryRun

# 2. Real install to a sandbox base path
.\install\install.ps1 -BasePath C:\temp\sd-test

# 3. Verify
Get-ChildItem C:\temp\sd-test\commands\sd\
Get-ChildItem C:\temp\sd-test\agents\sd\
Get-ChildItem C:\temp\sd-test\hooks\sd\
Get-ChildItem C:\temp\sd-test\templates\sd\

# 4. Cleanup
Remove-Item -Recurse -Force C:\temp\sd-test
```

**Unix/macOS (bash):**
```bash
# 1. Dry-run
./install/install.sh --dry-run

# 2. Real install to a sandbox base path
./install/install.sh --base-path /tmp/sd-test

# 3. Verify
ls /tmp/sd-test/commands/sd/
ls /tmp/sd-test/agents/sd/
ls /tmp/sd-test/hooks/sd/
ls /tmp/sd-test/templates/sd/

# Verify hook executable bits
test -x /tmp/sd-test/hooks/sd/prompt-router.sh && echo "OK"

# 4. Cleanup
rm -rf /tmp/sd-test
```

---

## Hook test snippets

Hooks read JSON from stdin. You can simulate Claude Code locally:

**prompt-router (UserPromptSubmit):**
```bash
echo '{"prompt":"fix bug INV-2501 in stock service","cwd":"/path/to/repo"}' \
  | bash hooks/bash/prompt-router.sh
```
```powershell
'{"prompt":"fix bug INV-2501 in stock service","cwd":"C:\\path\\to\\repo"}' `
  | powershell -File hooks\powershell\prompt-router.ps1
```

**spec-gate (PreToolUse):**
```bash
echo '{"tool_name":"Edit","tool_input":{"file_path":"src/foo.cs"},"cwd":"/path/to/repo"}' \
  | bash hooks/bash/spec-gate.sh
```

**subagent-retro (SubagentStop):**
```bash
echo '{"cwd":"/path/to/repo","session_id":"test-session-001"}' \
  | bash hooks/bash/subagent-retro.sh
```

Expected behaviour: every hook exits `0` and either prints a `<context-router>` / `<retro-reminder>` block to stdout, prints a warning to stderr, or stays silent.

---

## Style conventions

- **Markdown:** ATX headers (`#`, `##`), no trailing colons in headers, fenced code blocks with language hint, 100-char soft wrap.
- **PowerShell:** PascalCase function names, `$camelCase` variables, explicit `param()` block, pure ASCII.
- **Bash:** lowercase function names, `snake_case` variables, `set -euo pipefail` as the first statement (enforced by validate Check 10; declared exceptions in the manifest).
- **YAML frontmatter:** keys in lowercase-with-hyphens (`argument-hint`), values unquoted unless they contain special chars.
- **Commit messages:** imperative mood, 50-char subject, optional body wrapped at 72.

---

Thanks for contributing. If anything in this doc is unclear, open an issue and we'll improve it.
