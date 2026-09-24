# specwright

> **Claude Code cannot touch your code until a spec is approved.**
> 14 slash commands, 6 specialized subagents, 3 guard-rail hooks, 10 templates, 10 reusable skills - all under the `sd:` namespace, stack-agnostic, cross-platform, and ready to drop into any project.

[![Release](https://img.shields.io/github/v/release/developzoneio/specwright)](https://github.com/developzoneio/specwright/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-compatible-blue)](https://docs.claude.com/en/docs/claude-code)
[![Cross-platform](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux-lightgrey)](#compatibility-matrix)
[![Buy me a coffee](https://img.shields.io/badge/Buy%20me%20a%20coffee-ff5e5b?logo=ko-fi&logoColor=white)](https://ko-fi.com/developzone)

## What it looks like

You ask for a feature. Nothing gets written yet - the workflow drafts a spec and **stops**:

```
> /sd:feature todo-priority

Phase 1  sd-spec-architect -> .specs/FEAT-todo-priority/00-spec.md

  Why               A todo carries no urgency signal, so every caller that needs
                    ordering keeps that data outside the library's own validation.
  Success criteria  AC-1 .. AC-9, each requiring a file:line or test citation
  Out of scope      6 items, incl. "no setPriority path in this iteration"
  Constitution      1.1 Layer rules OK / 2.3 Error handling OK
                    3 Quality bars: integration test MANDATORY
                    6 Forbidden: 1 exception, scoped and recorded

  Gate 1 - Spec approval   [STOP]

  Approve spec FEAT-todo-priority? (yes / refine <feedback> / abort)
_
```

That STOP is not a suggestion. Until you answer, the `spec-gate` hook denies every `Edit` / `Write`
call at the tool layer - the model cannot quietly start coding while you are still reading.

When the work is done, the review gate is just as blunt:

```
  Gate 3 - Integration + review pass   [STOP]

  Tests    18/18 pass (8 original + 6 Domain + 4 Application), original 8 unedited
  Review   0 BLOCK / 0 WARN / 5 SUGGEST / 7 PASS
           S1  .specs/constitution.md:143 - DTO bullet now inconsistent
               with the refreshed Aggregate-root bullet at :141

  All clean for FEAT-todo-priority? (yes / address findings / abort)
_
```

Every number above is real and committed. Read the whole run - spec, plan, tasks, decisions, retro,
verify - at [`examples/fixture-project/.specs/FEAT-todo-priority/`](examples/fixture-project/.specs/FEAT-todo-priority/).

## Why spec-driven?

Most AI coding assistants are great at producing diff-shaped output. They are less great at
remembering **why** a change was made, **what** invariants must hold, or **whether** the fix even
addressed the right cause. `specwright` adds a thin layer of discipline: every non-trivial change
starts with a written spec, workflows refuse to advance without explicit approval, and every
artifact lands in `.specs/<ID>/` as durable, searchable memory.

It runs on three layers: a generic engine installed once into `~/.claude/`, per-project context in
each repo's `CLAUDE.md` and `.specs/constitution.md`, and the Claude Code session where the two
meet. The engine never changes per project - which is what lets one `/sd:feature` workflow run on
.NET, Node, Python, Go, or Rust.

### How this differs from prompt-level discipline

Plenty of tools ask the model nicely to plan first. Four things here are structural instead:

- **Gates halt the workflow.** Silence is not approval - the phase does not advance without an explicit answer. HARD gates (bug reproduction, perf baseline) have no override path at all.
- **The block lives outside the prompt.** `spec-gate` is a `PreToolUse` hook: with no in-progress spec, `Edit` / `Write` is denied by the CLI, not discouraged by instructions. A prompt can be argued with; a tool-level deny cannot.
- **The reviewer physically cannot auto-fix.** Its tool allowlist contains no write tools, so findings must route back through a fresh implementer call.
- **Specs are inputs, not write-ups.** `00-spec.md` through `06-verify.md` are what each subagent is handed on invocation - so they cannot rot into documentation nobody reads.

Full architecture, including the cost model: [`docs/architecture.md`](docs/architecture.md).

## Quickstart

Your first spec in under 5 minutes. You need the
[Claude Code CLI](https://docs.claude.com/en/docs/claude-code) installed and authenticated, plus
PowerShell 5.1+ on Windows or bash 4+ on macOS/Linux.

**1. Install the engine.** Run the preview first, read what it plans to write, then install.

macOS / Linux:

```bash
git clone https://github.com/developzoneio/specwright.git
cd specwright
./install/install.sh --dry-run    # preview only - writes nothing
./install/install.sh              # install to ~/.claude
```

Windows:

```powershell
git clone https://github.com/developzoneio/specwright.git
cd specwright
.\install\install.ps1 -DryRun     # preview only - writes nothing
.\install\install.ps1             # install to $env:USERPROFILE\.claude
```

**2. Scaffold a project.**

```
cd <your-project>
claude
> /sd:setup
```

Generates `CLAUDE.md`, `.specs/` (constitution + index) and `.claude/project-config.json`. Idempotent.

**3. Run a real change.** `/sd:feature <slug>` walks spec -> impact -> plan -> execute -> review,
stopping at Gate 1 for your sign-off. No project handy? The bundled
[`examples/fixture-project/`](examples/fixture-project/) is already scaffolded, zero dependencies.

## Features

| Capability | What you get |
|---|---|
| **14 slash commands** | 6 spec-producing workflows + 8 utilities - see the Commands table below |
| **6 specialized subagents** | architect, explorer, debugger, implementer, reviewer, docs-writer |
| **3 cross-platform hooks** | `prompt-router`, `spec-gate`, `subagent-retro` (PowerShell + bash) |
| **10 templates** | 4 setup templates + 6 spec templates (feature / bug / refactor / perf / rca / port) |
| **10 reusable skills** | Shared rule packs loaded from agent frontmatter or read at runtime by commands, never copy-pasted |
| **Cross-platform installer** | Content-hash dedup, timestamped backups, dry-run mode |
| **MCP-friendly** | Atlassian, Context7, sequential-thinking, GitNexus, your database MCP, Playwright, Tavily |
| **Stack-agnostic** | .NET, Node, Python, Go, Rust - anything with a `CLAUDE.md` |
| **Cost-aware** | Sonnet for reasoning, Haiku for execution. `/sd:status` reports your own cost from the local metrics log |

## Commands

| Command | Type | Hard gates | Purpose |
|---|---|---|---|
| `/sd:feature <ID-or-slug>` | Workflow | 3 | Spec-driven feature: spec -> impact -> plan (complexity triage) -> execute -> batch review -> close |
| `/sd:bug <ID-or-slug>` | Workflow | 5 | Root-cause-first fix: capture -> reproduce -> investigate -> failing test -> minimal fix -> regression |
| `/sd:rca <slug>` | Workflow | 3 | Incident analysis. **Output is the spec - no code change.** |
| `/sd:refactor <slug>` | Workflow | 6 | Coverage-gated restructure: requires >=80% coverage before touching code |
| `/sd:perf <slug>` | Workflow | 8 | Baseline-first optimization: measure -> hypothesize -> apply -> remeasure -> keep or revert |
| `/sd:port <slug> --from <source> --scope <scope>` | Workflow | 6 | Fidelity-first port: bridge -> freeze -> tables -> pin -> execute -> justified-diff parity |
| `/sd:spec <subcommand>` | Utility | - | Spec registry: list, show, status, link, archive, revive, search, validate, stats |
| `/sd:explore <target-or-query>` | Utility | - | Read-only code navigation, single subagent call, optional save |
| `/sd:review [path / "recent" / "spec ID"]` | Utility | - | Standalone constitution-compliance review with severity tags |
| `/sd:setup` | Utility | 2 | Idempotent project scaffold (interactive) |
| `/sd:release [version]` | Utility | 1 | Release notes from `done` specs -> Keep-a-Changelog sections, then archive them |
| `/sd:adr <spec-ID \| "decision title">` | Utility | 1 | Author an ADR from a spec's decisions under `.specs/_adr/` |
| `/sd:verify <spec-ID>` | Utility | - | Verify criterion -> task -> test traceability; writes the close-out gate artifact |
| `/sd:status` | Utility | - | Read-only summary of the metrics log + spec registry: in progress, gate activity, friction |

Command-by-command reference with worked examples: [`docs/usage.md`](docs/usage.md).

## Agents and skills

Commands do not do the work themselves - they orchestrate 6 subagents, each with a focused role and a **minimal tool allowlist** that enforces that role structurally.

| Agent | Model | Role |
|---|---|---|
| `sd-spec-architect` | sonnet | Creates and refines specs, plans, and atomic tasks. Constitution-aware. |
| `sd-code-explorer` | haiku | Read-only navigation. Every finding cites `file:line`. |
| `sd-debugger` | sonnet | Hypothesis-tree investigation. Distinguishes proximate from root cause. |
| `sd-implementer` | haiku | Executes ONE atomic task. Scope-disciplined, no opportunism. |
| `sd-reviewer` | sonnet | Severity-tagged review: BLOCK / WARN / SUGGEST / PASS. **No write tools.** |
| `sd-docs-writer` | sonnet | Authors one MADR-style ADR from a spec's decisions. Writes only the ADR file. |

Models use **portable aliases** (`sonnet`, `haiku`) so they auto-update - never a pinned model ID.

Cross-cutting rules live in **10 skills**: markdown rule packs that agents load via a `skills:` list in their frontmatter, rather than copy-pasting the same rule into every agent body that needs it. Commands cannot load skills that way, so they read a `SKILL.md` at runtime instead - every workflow's Phase 0 applies `sd-bootstrap-guard`.

Full tool allowlists, the command -> agent routing map, and the skill catalogue:
[`docs/architecture.md`](docs/architecture.md).

## Spec-driven structure

A spec is not documentation you write afterwards. It is the **input contract** handed to every
subagent invocation. `/sd:setup` scaffolds this:

```
<your-repo>/
  CLAUDE.md                     # Thin orchestrator (points to .specs/)
  .claude/
    project-config.json         # Paths, models, MCP, hooks - machine-readable
    settings.json               # Claude Code hook wiring
  .specs/                       # Everything below is durable, greppable memory
    constitution.md             # Architectural rules + conventions + quality bars
    index.md                    # Registry of all specs with lifecycle states
    _explorations/  _reviews/  _adr/   # /sd:explore, /sd:review, /sd:adr output
    FEAT-INV-2501/              # One folder per spec
      00-spec.md                # Why / What / Success criteria / Constitution check
      01-plan.md                # Implementation plan
      02-tasks.md               # Atomic tasks with Files / Layer / Acceptance
      03-decisions.md           # Impact analysis from sd-code-explorer
      04-artifacts/             # Evidence: logs, queries, traces, ticket snapshots
      05-retro.md               # Post-execution retro
    BUG-1247/  REF-...  PERF-...  RCA-...  PORT-...    # same shape, one folder each
```

`PORT-` specs add one thing: `04-artifacts/source/`, a frozen donor snapshot whose `MANIFEST.md`
records each file's donor path, commit, hash and member line ranges, protected once frozen.

## MCP integrations

None are required - agents fall back gracefully. Configure per project in `.claude/project-config.json` under `mcp`.

| MCP server | Used by | Purpose |
|---|---|---|
| **Atlassian** | `sd-spec-architect`, commands | Fetch JIRA ticket context for `<ID>` arguments; snapshot ticket + related tickets + linked Confluence pages to `04-artifacts/ticket/` |
| **Context7** | `sd-spec-architect`, `sd-implementer`, `sd-debugger` | Pull current library docs (no stale training-data examples) |
| **sequential-thinking** | `sd-debugger`, `sd-reviewer` | Structured hypothesis enumeration and verification |
| **GitNexus** | `sd-code-explorer`, `sd-debugger`, `sd-reviewer` | Fast symbol search, callers, call graph |
| **Database** (project-provided, e.g. `mssql`, `postgres`) | `sd-debugger` (SELECT/EXPLAIN only) | Inspect schema and query plans during investigation |
| **Playwright** | optional | E2E reproduction for `/sd:bug` |
| **Tavily** | `sd-debugger` | Web search for error signatures / library issues |

## Compatibility matrix

| Component | Tested on | Notes |
|---|---|---|
| Claude Code CLI | Latest as of Aug 2026 | Hook contract: `UserPromptSubmit`, `PreToolUse`, `SubagentStop` |
| OS | Windows 11 (PS 5.1 + 7.x), macOS 13+, Ubuntu 22.04+ | PS 5.1 reads UTF-8 as CP1252, so hooks are pure ASCII; bash hooks branch `stat -f %m` vs `stat -c %Y` |
| jq | 1.6+ | Optional. Bash hooks exit 0 if missing. |
| Node stack | Node 20+ (plain JS) | Demonstrated end-to-end in [`examples/fixture-project/`](examples/fixture-project/) - a real `/sd:feature` run, committed, not just asserted. TS not yet exercised. |
| .NET / Python stacks | ASP.NET Core 8, Python 3.11+ | Same workflow - not yet demonstrated with a committed example |

## Install options and uninstall

The [Quickstart](#quickstart) covers the common path; for custom install roots, selective areas and
backup behavior see [`install/README.md`](install/README.md). Uninstalling removes the five `sd/`
engine directories and leaves every per-project artifact (`.specs/`, `.claude/`, `CLAUDE.md`) alone:

macOS / Linux:

```bash
./install/uninstall.sh --dry-run   # preview only - removes nothing
./install/uninstall.sh             # remove the five sd/ engine directories
```

Windows:

```powershell
.\install\uninstall.ps1 -DryRun    # preview only - removes nothing
.\install\uninstall.ps1            # remove the five sd/ engine directories
```

## Documentation

- [`docs/architecture.md`](docs/architecture.md) - 3-layer design, agent routing, skills, lifecycle, cost model
- [`docs/usage.md`](docs/usage.md) - Command-by-command reference with examples
- [`docs/walkthrough.md`](docs/walkthrough.md) - End-to-end demo on a fictional project (illustrative prose)
- [`docs/troubleshooting.md`](docs/troubleshooting.md) - Common issues and fixes
- [`docs/contract-lint.md`](docs/contract-lint.md) - How cross-file contracts are machine-checked
- [`install/README.md`](install/README.md) - Install guide and options
- [`CONTRIBUTING.md`](CONTRIBUTING.md), [`CHANGELOG.md`](CHANGELOG.md), [`ROADMAP.md`](ROADMAP.md)

**Runnable examples:** [`fixture-project/`](examples/fixture-project/) - committed worked spec;
[`port-parity-fixture/`](examples/port-parity-fixture/) - `/sd:port` fidelity gates;
[`spec-lint-fixture/`](examples/spec-lint-fixture/) - malformed specs `/sd:spec validate` must catch.

## Roadmap

Shipped work is in [`CHANGELOG.md`](CHANGELOG.md); the latest release is
[v1.5.0](https://github.com/developzoneio/specwright/releases). Next up, per [`ROADMAP.md`](ROADMAP.md):
GitHub Issue auto-fetch (`gh issue view`) to match the existing JIRA snapshot path, plus - exploratory -
local-only, opt-in usage analytics. Have a workflow you wish existed?
[Open an issue](https://github.com/developzoneio/specwright/issues/new) - the roadmap follows what people actually hit.

## Support

Enjoying `specwright`? A coffee goes a long way toward keeping it maintained -
[buy me one on Ko-fi](https://ko-fi.com/developzone). Thank you!

A star on the repo helps others find it. Using `specwright` at work? [Open an issue](https://github.com/developzoneio/specwright/issues/new) and let us know - we'd love to list you.

## License and acknowledgements

MIT. See [`LICENSE`](LICENSE).

Inspired by the spec-driven discipline of long-running software teams, and by the
[BMAD method](https://github.com/bmad-code-org/BMAD-METHOD) for structuring AI-assisted workflows.
Built on [Claude Code](https://docs.claude.com/en/docs/claude-code) by Anthropic.
