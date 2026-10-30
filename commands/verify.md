---
description: Verify criterion -> task -> test traceability for a spec and write the 06-verify.md close-out gate artifact
argument-hint: <spec-ID>
---

# /sd:verify - traceability verification gate

Pure verification command - no subagent, no code changes, no edits outside the spec's own
folder. Proves that every success criterion and scenario in `00-spec.md` is implemented by at
least one task in `02-tasks.md` and observable through at least one existing test, then runs
the project test suite and writes `<spec.dir>/<ID>/06-verify.md` recording the verdict.

The spec-gate hook blocks an `index.md` row transitioning to `done` unless this artifact
records `result: pass`. Re-run the command after fixing findings; it overwrites the artifact.

## State machine

| Condition | State | Behavior |
|---|---|---|
| Spec folder missing | not-found | STOP, saying the spec folder is missing |
| `02-tasks.md` missing | not-planned | STOP, saying the spec has no task list yet |
| Otherwise | verifiable | Run all applicable checks, write artifact |

Any status may be verified (verification before `in-progress` is allowed and useful), but the
artifact only matters to the hook at the `in-progress -> done` transition.

## Phase 0 - Bootstrap (always)

1. Read `.claude/project-config.json` -> `spec.dir`, `spec.indexFile`, `commands.test`.
   Missing config -> STOP: "No project config found - run /sd:setup first."
2. Resolve `<arg>` against `<spec.dir>/`: accept a full ID (`FEAT-1042`) or unique suffix.
   Ambiguous or missing -> STOP listing candidates.
3. Read from disk (commands cannot load skills via frontmatter):
   - `~/.claude/skills/sd/sd-severity-taxonomy/SKILL.md`
   - `~/.claude/skills/sd/sd-evidence-citation/SKILL.md`
   - `~/.claude/skills/sd/sd-atomic-task-format/SKILL.md` (the "Witness test" section)
   - `~/.claude/skills/sd/sd-gate-brief/SKILL.md` (the "User-facing text" section only). It owns
     the wording of every line the user reads, this command's reply text included.

## Checks

Stable rule IDs (record every finding in the artifact as `VF0xx`, severity per
sd-severity-taxonomy, citing `file:line` relative to project root). The IDs belong to the
artifact; the reply names each check in plain words (see "Output"). Generic rules apply to all
spec types; traceability rules apply when the corresponding section exists in `00-spec.md`.

| ID | Applies | Check | Severity |
|---|---|---|---|
| VF001 | all | Spec folder and `00-spec.md` exist | BLOCK |
| VF002 | all | `02-tasks.md` exists | BLOCK |
| VF003 | all | Spec frontmatter `id` matches the folder name | BLOCK |
| VF010 | spec has `SC-<n>:` scenario headings | Every SC ID is listed in >=1 task's `Covers` | BLOCK |
| VF011 | spec has `AC-<n>:` criteria | Every AC ID is listed in >=1 task's `Covers` | BLOCK |
| VF012 | tasks have `Covers` | Every ID referenced in a `Covers` exists in `00-spec.md` | BLOCK |
| VF013 | feature specs | `## Success criteria` checkboxes carry `AC-<n>:` prefixes | WARN |
| VF020 | all | Every task whose `Covers` != none has a witness test, as defined by the "Witness test" section of `sd-atomic-task-format` | BLOCK |
| VF021 | all | Every file path named by the witness test exists (use Glob; a witness naming a suite/pattern instead of a path is checked by VF022 only) | BLOCK |
| VF022 | all | `commands.test` from project-config runs and exits green | BLOCK |
| VF023 | `commands.test` empty/null | Cannot run tests - report and continue | WARN |
| VF030 | all | Every `## Success criteria` checkbox in `00-spec.md` is checked (`- [x]`) | BLOCK |

Parsing shapes (exact):

- Scenario IDs: headings matching `^### SC-([0-9]+):` in `00-spec.md`.
- Criterion IDs: lines matching `^- \[[ xX]\] AC-([0-9]+):` in `00-spec.md`.
- Covers: task lines matching `^- \*\*Covers\*\*: (.+)$` in `02-tasks.md`; split on commas;
  `none` means no IDs. A task block with no `Covers` line is treated as `Covers: none`
  (legacy compatibility).
- Witness test files: whether a task has a witness is defined once, by the "Witness test" section
  of `sd-atomic-task-format`. For `VF021`, take each path-like token that definition finds (in the
  legacy `Test` value, else in `Acceptance`) and check it with Glob.

VF022 execution: run `commands.test` via Bash from the project root. Capture the exit code.
Do not guess a test command when `commands.test` is empty - that is VF023 (stack-agnostic
<!-- contract-lint: allow CL400 - these are FORBIDDEN examples illustrating the stack-agnostic rule itself, not a hardcoded command this file runs -->
rule: never hardcode `dotnet test`, `npm test`, etc.).

## Artifact

ALWAYS write `<spec.dir>/<ID>/06-verify.md` (overwrite an existing one) - on pass AND on fail -
once the spec reaches the `verifiable` state. The `not-found` (VF001) and `not-planned` (VF002)
STOP states above are reached BEFORE that point and write no artifact at all: there is no spec
folder, or no `02-tasks.md` to check traceability against, so there is nothing yet to record.

```markdown
---
spec: <ID>
result: <pass | fail>
date: <YYYY-MM-DD>
failures: <count of BLOCK findings>
---

# Verification report - <ID>

## Traceability

| ID | Kind | Covered by | Test(s) | Status |
|---|---|---|---|---|
| SC-1 | scenario | T01, T03 | tests/... | PASS |
| AC-1 | criterion | T02 | tests/... | PASS |

## Test run

- Command: `<commands.test or "not configured (VF023)">`
- Exit code: <n or "-">

## Findings

<severity-tagged VF0xx findings with file:line citations, or "none">
```

`result: pass` if and only if there are zero BLOCK-severity findings. WARN findings (VF013,
VF023) do not fail the run but must appear under Findings.

## Output

Reply text is user-facing text: it follows the "User-facing text" section of **sd-gate-brief**,
whether `/sd:verify` runs on its own or inside a workflow close-out, and is not restated here.
The `VF0xx` IDs, the `SC-<n>` / `AC-<n>` IDs and the `file:line` citations stay in
`06-verify.md`, the machine record.

Print to the user: a traceability summary (each scenario and criterion by its plain title, the
tasks that cover it, the tests by name), the findings in plain words (what was checked and what
failed), the artifact path as the place the full record lives, and one of:

- `[OK] <ID> verified - result: pass recorded in <spec.dir>/<ID>/06-verify.md`
- `[FAIL] <ID> verification failed (<n> BLOCK findings) - result: fail recorded. Close-out is
  blocked until /sd:verify passes.`

## Hard constraints

- Never edit any file except `<spec.dir>/<ID>/06-verify.md`.
- Never invoke a subagent.
- Never mark a criterion covered without a concrete task ID + existing test citation.
- Findings without a `file:line` citation in the artifact are invalid (sd-evidence-citation).
