# ADR 0008: behavior is proven by headless runs against a committed non-.NET fixture

- Status: accepted (shipped in 1.6.0)
- Date: 2026-09-24 (recorded retroactively by SW-56; decisions made 2026-08, SW-27/SW-30)
- Source spec: Jira SW-27 (`tests/e2e/`), SW-30 (`examples/fixture-project/`)
- Relates to: ADR 0010 (the engine does not dogfood itself); `tests/e2e/README.md`
- Supersedes: none

## Context

Every other suite in `scripts/` and `tests/` proves that the engine's *assets* reference each other
correctly: counts match disk, hooks come in pairs, commands invoke agents that exist. None of them
proves the engine *behaves* correctly when a real Claude Code session runs a command. Separately,
"stack-agnostic" was an assertion with no demonstration: every spec ever run through the engine had
been in a .NET project.

## Decision

1. **A committed, runnable, non-.NET fixture.** `examples/fixture-project/` is a tiny plain Node.js
   project, pre-scaffolded with Layer 2 (`CLAUDE.md`, `.specs/constitution.md`,
   `.claude/project-config.json`), carrying one complete real `/sd:feature` run
   (`FEAT-todo-priority`, spec through verify). It proves stack-agnosticism by demonstration, and it
   is the corpus the README's "what it looks like" transcripts are copied from, so nothing there is
   invented.

2. **Assert on artifacts, not transcript wording.** `tests/e2e/` drives real headless `claude -p`
   sessions against a throwaway copy of a fixture and asserts on produced files, frontmatter and
   status values. Model wording varies run to run; the artifacts are the contract.

3. **Sandbox through the installer's own flag.** Each run gets a fresh "fake home" with the engine
   installed through `-BasePath`, so the e2e run also exercises the installer, and never touches the
   developer's real `~/.claude`.

4. **One pwsh runner.** `run-e2e.ps1` has no bash twin, the same posture as
   `tests/hooks/run-conformance.ps1` and `tests/contract-lint/run-selftest.ps1`.

5. **Nightly, not per PR.** Real sessions cost money and minutes, so the suite runs from
   `.github/workflows/e2e-nightly.yml` on a schedule and on manual dispatch, not in `ci.yml`.

6. **The harness proves it can fail.** `-SelfTest` re-runs the negative scenarios against a
   neutered `spec-gate` and asserts the harness notices.

## Findings recorded while building it

- `--permission-mode acceptEdits` silently overrides a `PreToolUse` hook's deny. Only `dontAsk`,
  with no `--allowedTools` override, respects one.
- `spec-gate`'s matcher covers `Edit` / `Write` / `MultiEdit` only, not file writes made through
  `Bash`. **Update (SW-79):** the matcher now also covers `Bash` / `PowerShell`; a command that
  visibly writes a protected path or the spec index is denied, as a heuristic.

## Consequences

**Positive.** There is a mechanism that fails when a command or gate stops behaving, not only when
a file reference breaks. Stack-agnosticism has a worked example a reader can run.

**Negative.** Behavioral regressions surface up to a day late, because the suite is nightly. The
fixture's single closed spec is a thin corpus (see ADR 0004), and the scenarios cover short
single-session runs only - never a spec that lives for weeks (see ADR 0010).
