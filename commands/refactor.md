---
description: Coverage-gated refactor workflow. Spec -> impact -> coverage -> plan -> batched execute -> holistic review. 6 hard gates.
argument-hint: <slug> [smell-type]
---

# /sd:refactor

Drives a behavior-preserving restructure. Refuses to touch code until coverage on affected files meets threshold. Each step keeps all tests green. Result under `.specs/REF-<slug>-<YYYYMMDD>/`.

**Arguments**:
- `$1` (required): slug, e.g. `extract-pricing-service`.
- `$2` (optional): smell type. One of `extract-method`, `extract-class`, `rename`, `inline`, `move`, `replace-conditional`, `reduce-coupling`, `other`.

Spec ID = `REF-<slug>-<YYYYMMDD>`.

---

## HARD RULES (read before every phase)

1. **Never refactor without adequate test coverage.** Default threshold: 80% line coverage on affected files. Configurable via `quality.refactorCoverageThreshold` in `project-config.json`.
2. **Each step keeps all tests green.** A red test is a stop condition - revert or fix before continuing.
3. **No opportunistic feature work.** Refactor = restructure. New behavior goes in a separate FEAT-* spec.
4. **Public API preserved unless the spec states otherwise.** If consumers exist, they must continue to work.

---

## State machine (resume behavior)

| Detected state | Action |
|---|---|
| Folder not found | Start at Phase 1 |
| `00-spec.md` status `draft` | Resume Phase 1 |
| status `approved`, no `03-decisions.md` | Resume Phase 2 |
| Impact mapped, coverage not measured | Resume Phase 3 |
| Coverage above threshold, no `02-tasks.md` | Resume Phase 4 |
| Tasks present with unchecked items | Resume Phase 5 |
| All tasks checked, no holistic review | Resume Phase 6 |
| status `done` | Refuse |

"Checked" and "unchecked" mean the task's check-off marker as defined in the "Check-off marker"
section of the **sd-atomic-task-format** skill - the one definition; do not invent a marker. Task
rows are evaluated only while status is `in-progress`: a `done` or `archived` spec resolves from its
frontmatter first and is never resumed from its task markers.

---

## Phase 0 - Bootstrap

1. Read `~/.claude/skills/sd/sd-bootstrap-guard/SKILL.md` and apply it before anything else here -
   it owns the Layer-2 reads and all of their messages (commands cannot load skills via
   frontmatter, so it is read at runtime). If that file is unreadable, STOP: "specwright install
   incomplete - bootstrap guard skill not found under `~/.claude/skills/sd/`. Re-run the installer."
2. Compute UTC date for spec ID.
3. Read coverage threshold from project-config or default to 80%.
4. Detect state. Print resume plan.

---

## Phase 1 - Spec

1. Invoke `sd-spec-architect` with:
   - `TASK = create`
   - `TEMPLATE = refactor.template.md`
   - `SPEC_ID = REF-<slug>-<YYYYMMDD>`
   - `SMELL = <$2 or 'other'>`
2. Architect fills Smell/Driver, Current state (high level), Target state, **Invariants - MUST preserve** (concrete, checkable), Out of scope.
3. Architect leaves "Impact surface" TBD - Phase 2 fills it.

### ⛔ Gate 1 - Spec approval

STOP. Display spec summary, especially Invariants and Out-of-scope. Ask:

> Approve refactor spec REF-<slug>? (yes / refine / abort)

- `yes` -> status=`approved`, append to index, proceed.
- `refine <feedback>` -> loop with architect.

---

## Phase 2 - Impact

1. Invoke `sd-code-explorer` with:
   - `TASK = impact-map`
   - `SPEC = .specs/REF-<slug>-<YYYYMMDD>/00-spec.md`
   - `OUTPUT_TARGET = .specs/REF-<slug>-<YYYYMMDD>/03-decisions.md`
2. Explorer enumerates: direct callers, transitive callers (2-3 hop), test coverage scan of affected paths, DI / config grep, public API surface, risk assessment.
3. Every finding cites file:line.
4. Main thread appends the explorer's returned analysis to
   `.specs/REF-<slug>-<YYYYMMDD>/03-decisions.md` (create the file if missing; never overwrite
   existing content).

No gate here - read-only.

---

## Phase 3 - Coverage gate

1. Run coverage via `commands.coverage`. Filter to files listed in "Impact surface" and "Current state - Primary file".
2. Write the measured percentages to `00-spec.md` under "Test coverage prerequisite":
   - Current measured: `<N%>`
   - Gap: `<threshold - measured>`

### ⛔ Gate 2 - Coverage threshold met

STOP. Compare measured vs threshold.

- **If measured >= threshold** -> proceed to Phase 4.
- **If measured < threshold** -> REFUSE. Display:
  > Coverage on affected files is <measured>%, below threshold <threshold>%. Refactor is blocked.
  > Options: (1) add characterization tests now (recommended), (2) lower threshold for this spec with explicit constitution exception, (3) abort.

If user picks (1), enter the characterization sub-loop:
1. Identify uncovered branches via coverage report.
2. Invoke `sd-implementer` with `TASK_DETAILS = <characterization test task for the uncovered area>`, `SPEC_REF = .specs/REF-<slug>-<YYYYMMDD>/00-spec.md`, `WORKFLOW_TYPE = refactor`, `INVARIANTS = <invariants list from spec>` per uncovered area.
3. Each new test must FAIL FAST if current behavior changes - characterization tests pin the CURRENT behavior, correct or not.
4. Re-measure coverage.

### ⛔ Gate 3 - Post-test coverage check

STOP. After characterization tests are added, re-run coverage.

- Coverage now >= threshold -> proceed.
- Still below -> loop, or escalate to constitution exception with user approval.

If user picks (2) explicit exception, document the threshold reduction in `05-retro.md` with reasoning. Log as a constitution exception.

---

## Phase 4 - Plan parallel-safe tasks

1. Invoke `sd-spec-architect` with:
   - `TASK = plan`
   - `SPEC = .specs/REF-<slug>-<YYYYMMDD>/00-spec.md`
   - `IMPACT = .specs/REF-<slug>-<YYYYMMDD>/03-decisions.md`
   - `MODE = refactor`
2. Architect writes `01-plan.md` (sequencing) and `02-tasks.md`. Each task follows the
   **sd-atomic-task-format** skill (11 required fields, including `Pattern refs`, plus the skill's
   "Refactor mode" `Parallel batch` field - do not re-specify the format here). Tasks sharing a
   batch number must have disjoint file sets and no `Depends on` / `Conflicts with` relationship.

### ⛔ Gate 4 - Plan approval

STOP. Display batch groupings. Ask:

> Approve plan with <N> batches? (yes / refine / abort)

- `yes` -> status=`in-progress`, update index, proceed.

---

## Phase 5 - Execute batched

For each batch (up to 3 tasks in parallel):

1. **Pre-batch**: run full test suite. Must be green. If red, abort batch and surface failure - the baseline must be clean.
2. For each task in the batch:
   - Invoke `sd-implementer` with:
     - `TASK_DETAILS = <task block>`
     - `SPEC_REF = .specs/REF-<slug>-<YYYYMMDD>/00-spec.md`
     - `IMPACT_REF = .specs/REF-<slug>-<YYYYMMDD>/03-decisions.md`
     - `WORKFLOW_TYPE = refactor`
     - `INVARIANTS = <invariants list from spec>`
   - Implementer's constraint set is tightest in refactor mode: NO new public API, NO new feature, ONLY restructure.
3. **Post-batch**: run full test suite via `commands.test`.

### ⛔ Gate 5 - Tests green per batch

STOP after every batch. Display test results.

- All green -> check off the batch's tasks in `02-tasks.md` (set each `Status` line to `done`, per
  the "Check-off marker" section of the **sd-atomic-task-format** skill), proceed to next batch.
- Any red -> REFUSE to proceed. Revert the batch or fix the regression. The point of batched-with-tests-between is to localize failures.

### Gate Re-plan (HARD) - adaptive re-plan on a plan-invalidating discovery

Reachable from Phase 5 (a batch reveals a task's premise is false or an invariant cannot be preserved
as planned) **and** Phase 6 (a holistic-review finding that the plan itself is wrong). Follow the
**sd-replan-loop** skill - the same protocol `/sd:feature` uses, defined there once. In brief:

1. STOP. Surface the trigger, the affected task IDs, and the proposed delta. Ask:

   > Re-plan REF-<slug>? Discovery: <trigger>. Affects <task IDs>. (approve / revise <feedback> / abort task)

<!-- contract-lint: allow CL102 - scoped re-plan passes REPLAN_SCOPE/REVISION instead of SPEC/IMPACT, per the Scoped re-plan sub-path documented in agents/spec-architect.md -->
2. `approve` -> invoke `sd-spec-architect` with `TASK = plan`, `MODE = refactor`,
   `REPLAN_SCOPE = <affected task IDs>`, `REVISION = R<n>`. It appends the `## Revisions` entry to
   `01-plan.md` (append-only; original plan prose untouched), regenerates ONLY the affected task
   blocks in `02-tasks.md` - preserving each task's `Parallel batch` field - and marks each
   `Revised-by: R<n>`. `revise` -> adjust and re-ask. `abort task` -> normal task abort.
3. Resume Phase 5 at the batch containing the first regenerated task. Re-check batch disjointness if a
   regenerated task's `Files` set changed.

Runs only while the spec is `in-progress`; never re-plans a `done` spec.

---

## Phase 6 - Holistic review

After all batches complete:

1. Invoke `sd-reviewer` with:
   - `TASK_TYPE = holistic`
   - `SPEC_REF = .specs/REF-<slug>-<YYYYMMDD>/00-spec.md`
   - `INVARIANTS = <invariants list>`
   - `CHANGED_FILES = <all files touched across batches>`
2. Reviewer checks:
   - Invariants preserved (each one explicitly verified).
   - No new constitution exceptions introduced.
   - No public API drift (unless spec stated otherwise).
   - No opportunistic feature additions.
   - Test coverage did not decrease (run coverage again, compare to Phase 3 number).

### ⛔ Gate 6 - Holistic review pass

STOP. Display reviewer verdict counts + invariant verification table. Ask:

> Refactor REF-<slug> ready for close-out? (yes / address findings / abort)

- `yes` -> proceed.
- Any 🔴 BLOCK that is a **code defect** -> loop to implementer with the finding.
- Any 🔴 BLOCK that reveals the **plan itself was wrong** (e.g. a planned step cannot preserve an
  invariant) -> enter **Gate Re-plan** (Phase 5) with `Phase: review`, recording the wrong step as a
  revision and regenerating the affected tasks rather than hand-patching them.

---

## Phase 7 - Close-out

1. Append to `05-retro.md`:
   - Tasks completed (count + IDs).
   - Coverage before / after.
   - Invariants verified (table).
   - Surprises (e.g. discovered dead code, unexpected callers).
   - Constitution exceptions (should be none).
2. **Spawned specs**: re-read the "Surprises" entry just written to 05-retro.md - dead code found,
   unexpected callers, invariants that needed propping up, a perf concern this refactor exposed.
   For each one, ask the user to reserve an ID and add a row to `00-spec.md`'s `## Spawned specs`
   table (`Reserved ID | Type | Title | Owner`). This is a prompt, not a gate: nothing deferred, or
   the user declines - leave the table at header + separator and proceed. Do NOT create the child
   specs here, and do NOT add a reserved ID to `.specs/index.md`; an index row exists only once
   the real spec directory does (see `/sd:spec`, "Index <-> folder symmetry").
3. Set status=`done`. Update index.

---

## Rules (hard constraints)

- Gate 2 (Coverage) is HARD. No code edits until threshold met OR explicit exception logged.
- Gate 5 (Tests green per batch) is HARD. A red batch is reverted or fixed - never deferred.
- Implementer in refactor mode has the tightest scope discipline. Any "improvement" beyond restructuring is rejected.
- Public API preservation is verified by reviewer (Phase 6), not assumed.
- Max 3 parallel tasks per batch. More -> tests-between granularity is too coarse.
- Each batch's tests must finish before the next batch starts. No "tests run in background while next batch starts".
- **Gate Re-plan is a conditional gate, not a seventh always-on gate.** It fires only on a
  plan-invalidating discovery (Phase 5) or a plan-is-wrong BLOCK (Phase 6); a run that hits neither
  never sees it. `02-tasks.md` is re-planned only through it (the `sd-replan-loop` skill), never by a
  silent hand-edit, and never on a `done` spec. Revisions are append-only in `01-plan.md`.
