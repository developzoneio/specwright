# ADR 0006: cross-file contracts are linted by a deterministic twin-implemented script

- Status: accepted (shipped in 1.6.0)
- Date: 2026-09-24 (recorded retroactively by SW-56; decisions made 2026-07, SW-25/26, SW-32..35)
- Source spec: Jira SW-25 (agent input declarations), SW-26 (Check 8 wave 1 and promotion),
  SW-32 (wave 2), SW-33 (wave 3a), SW-34 (wave 3b), SW-35 (wave 4)
- Relates to: `docs/contract-lint.md` (rule catalogue and per-rule scope decisions)
- Supersedes: none

## Context

Check 7 closed the *inventory* drift class: every count in the docs is derived from disk. It says
nothing about *relationships*: which agent a command invokes, whether that agent declares the mode
being asked for, whether a gate actually halts, whether a read-only agent is told to write. Every
one of those shipped as a real defect and was statically detectable the whole time (the table at
the top of `docs/contract-lint.md` lists them).

Most of the per-rule reasoning - why a write tool is `Write`/`Edit`/`MultiEdit` and never `Bash`,
why `CL500` counts normalized bytes, why budgets are a ratchet, why `CL202`/`CL401` stay WARN
forever, why `CL306` reuses the suppression comment, and why a gate count belongs in the manifest -
already lives in `docs/contract-lint.md` next to the rules it explains. This ADR records only the
cross-cutting decisions; it does not restate those.

## Decision

1. **A script, not a prompt.** Check 8 is deterministic file operations with no subagent and no
   model, emits TSV on stdout, and exits `2` when it cannot run - distinct from exit `1` (a BLOCK
   finding) so a broken linter can never read as a clean tree.

2. **Twin implementations, one registry.** `scripts/contract-lint.ps1` and `.sh` both exist so the
   check runs natively on every CI OS. Severity lives only in `contractLint.rules` in
   `specwright.manifest.json`, so a BLOCK/WARN divergence between the twins is structurally
   impossible. Each linter carries a registry parity guard that exits `2` when the rules it
   dispatches and the registry disagree.

3. **Parity is asserted, not hoped for.** `tests/contract-lint/run-selftest.ps1` drives both
   implementations in one process and compares them line for line on every fixture. Goldens pin a
   seed marker, never a line number, so an unrelated edit to a fixture does not churn goldens.
   `-SelfTest` proves the harness notices a linter that reports nothing.

4. **Input declarations are machine-readable.** `Inputs (required): ...` / `Inputs (optional): ...`
   lines under every agent mode heading (SW-25) are the contract the `CL1xx` band checks every
   invocation against. Adding them changed no agent behavior; they made an existing contract
   checkable.

5. **Rules ship WARN, then promote on evidence.** A rule that could false-positive ships WARN with
   an explicit promotion clause and promotes to BLOCK once the engine tree runs clean under both
   implementations for a release (SW-26 promoted `CL200`/`CL306`/`CL400` this way). Severity is
   registry-driven, so promotion changes no rule logic. A rule that is new rather than promoted may
   ship BLOCK from the start.

6. **Correct prose is suppressed, not rewritten.** Where a rule hit illustrative or multi-stack
   heuristic vocabulary (enumerated manifest-filename lists, "never hardcode X" examples), the
   finding is annotated with `<!-- contract-lint: allow <rule> - <reason> -->` instead of rewriting
   the line. Rewriting would have deleted correct stack-agnostic design, not fixed a bug. The
   suppression then becomes load-bearing once the rule is BLOCK.

7. **A budget raise is a reviewed decision.** When a file legitimately outgrows its
   `contractLint.budgets.<area>Bytes` ceiling, the raise lands in the same change as the growth,
   with the reason in the changelog. It is never a reflex to a red run.

## Consequences

**Positive.** Relationship drift between commands, agents and skills is caught per PR on all three
operating systems. Writing the rules found real defects on disk before they landed (a
`docs/architecture.md` gate list that disagreed with the gate count, `commands/setup.md` gates with
no literal `STOP`, drifted invocation contracts in `bug.md`, `rca.md`, `feature.md` and
`refactor.md`).

**Negative.** Every rule is written twice and every vocabulary list (`stackTokens`,
`gateProseEscapeTokens`, `knownMcpTools`) is hand-maintained. Adding a rule is a four-edit change:
registry, both linters, a fixture, and the doc table.
