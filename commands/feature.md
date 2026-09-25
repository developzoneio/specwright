---
description: Spec-driven feature workflow. Spec -> impact -> plan (complexity triage) -> execute -> batch review -> close. 3 hard gates.
argument-hint: <JIRA-ID or slug>
---

# /sd:feature

Drives a feature from a one-line ask to closed-out, reviewed, tested code with searchable spec artifacts under `.specs/FEAT-<arg>/`.

**Argument**: `$ARGUMENTS` -> spec ID = `FEAT-<arg>` (e.g. `FEAT-INV-2501`, `FEAT-low-stock-webhook`).

---

## State machine (resume behavior)

On re-invocation with the same `<arg>`, detect the current state of `.specs/FEAT-<arg>/` and jump to the next phase. Never restart a phase that already passed its gate.

| Condition | State | Action |
|---|---|---|
| No `.specs/FEAT-<arg>/` dir | `not-found` | Start Phase 1 |
| `00-spec.md` exists, status=`draft` | `draft` | Present spec for Gate 1 |
| status=`approved`, no `02-tasks.md` | `approved` | Start Phase 3 |
| `02-tasks.md` exists, unchecked tasks remain | `in-progress` | Resume Phase 4 at next unchecked task |
| All tasks checked, no integration pass | `tasks-complete` | Start Phase 5 |
| status=`done` | `done` | Print summary, exit |
| status=`archived`, spawned children (has `spawns` links) | `umbrella` | Print the child IDs + `/sd:feature <child-arg>` for each, in dependency order; exit |
| status=`archived` | `archived` | Print archived notice, exit |

"Checked" and "unchecked" mean the task's check-off marker as defined in the "Check-off marker"
section of the **sd-atomic-task-format** skill - the one definition; do not invent a marker. Task
rows are evaluated only while status is `in-progress`: a `done` or `archived` spec resolves from its
frontmatter first and is never resumed from its task markers.

---

## Phase 0 - Bootstrap (always runs)

1. Read `~/.claude/skills/sd/sd-bootstrap-guard/SKILL.md` and apply it before anything else here -
   it owns the Layer-2 reads and all of their messages (commands cannot load skills via
   frontmatter, so it is read at runtime). If that file is unreadable, STOP: "specwright install
   incomplete - bootstrap guard skill not found under `~/.claude/skills/sd/`. Re-run the installer."
2. Determine state from table above.
3. Read `~/.claude/skills/sd/sd-model-escalation/SKILL.md`. It owns the model escalation policy
   applied at Phase 2 step 0, Phase 3 step 0, Gate 2 `no-split` and Phase 4 step 2; this file
   names only rule IDs and trigger inputs. If that file is unreadable, STOP: "specwright install
   incomplete - model escalation skill not found under `~/.claude/skills/sd/`. Re-run the
   installer."

---

## Phase 1 - Spec

1. If `ticket.system == "jira"` and `<arg>` matches `ticket.pattern`, fetch ticket via `mcp__atlassian__getJiraIssue`. If MCP unavailable, ask user for a paste or proceed with slug.
2. Invoke `sd-spec-architect` with:
   - `TASK = create`
   - `TEMPLATE = feature.template.md`
   - `TICKET_CONTEXT = <fetched or pasted>`
   - `SPEC_ID = FEAT-<arg>`
3. Spec-architect produces `.specs/FEAT-<arg>/00-spec.md` with: Why (business value), What (Given/When/Then), Success criteria, Out of scope, Open questions, Constitution check. Cross-references are not authored here - they go in the `linked_specs` frontmatter field via `/sd:spec link`.
4. If a ticket was fetched, spec-architect also snapshots it (ticket content + related tickets + linked Confluence pages, per its Ticket snapshot protocol) to `.specs/FEAT-<arg>/04-artifacts/ticket/`.
5. Register in `.specs/index.md` with status=`draft`.

### ⛔ Gate 1 - Spec approval

STOP. Present the spec to the user. Ask:

> Approve spec FEAT-<arg>? (yes / refine <feedback> / abort)

- `yes` -> set status=`approved`, proceed.
- `refine` -> invoke `sd-spec-architect` with `TASK = refine`, `SPEC = .specs/FEAT-<arg>/00-spec.md`, `FEEDBACK = <user feedback>`. Loop.
- `abort` -> set status=`archived`, exit.

---

## Phase 2 - Impact analysis

0. **Model escalation check.** Apply rule `ESC-FEAT-02` of **sd-model-escalation** (read in
   Phase 0). Trigger input: the `complexity` frontmatter field of `.specs/FEAT-<arg>/00-spec.md`.
1. Invoke `sd-code-explorer` (model: default, or as resolved by step 0) with:
   - `TASK = impact-map`
   - `SPEC = .specs/FEAT-<arg>/00-spec.md`
   - `OUTPUT_TARGET = .specs/FEAT-<arg>/03-decisions.md`
2. Explorer produces: direct callers (1-hop), transitive (2-3 hop), test coverage scan, DI/config grep, public API surface, risk assessment.
3. All findings cite `file:line`.
4. Main thread appends the explorer's returned analysis to `.specs/FEAT-<arg>/03-decisions.md`
   (create the file if missing; never overwrite existing content).

No gate here - impact analysis is informational. User reviews it in Phase 3.

---

## Phase 3 - Plan + tasks

0. **Model escalation check.** Apply rule `ESC-FEAT-03` of **sd-model-escalation** (read in
   Phase 0). Trigger input: the `complexity` frontmatter field of `.specs/FEAT-<arg>/00-spec.md`.
1. Invoke `sd-spec-architect` (model: default, or as resolved by step 0) with:
   - `TASK = plan`
   - `SPEC = .specs/FEAT-<arg>/00-spec.md`
   - `IMPACT = .specs/FEAT-<arg>/03-decisions.md`
2. Spec-architect produces:
   - `.specs/FEAT-<arg>/01-plan.md` (approach, alternatives considered, rationale).
   - `.specs/FEAT-<arg>/02-tasks.md` with atomic tasks, each formatted per the
     **sd-atomic-task-format** skill (11 required fields, including `Pattern refs`; the architect applies
     this format, do not re-specify it here).
   - It also self-assesses the plan against the decompose thresholds and returns either a normal
     report (under threshold) or `STATUS = needs-input` carrying a **decompose proposal** or a
     **no-split** flag (over threshold). See its "Complexity self-assessment" section.
3. **Do not set status yet** - the Gate 2 branch below decides whether this spec executes its own
   plan or becomes an umbrella. Setting `in-progress` happens inside the resolved branch.

### ⛔ Gate 2 - Plan approval (with complexity triage)

STOP. This gate has two faces. Which one you present is decided by the architect's self-assessment
from Phase 3 step 2 - **not** by adding a separate always-on gate. A spec **under** the decompose
thresholds sees only the normal plan approval below, with **zero added friction**.

**Face A - normal plan approval** (plan is under threshold). Present the plan and task list. Ask:

> Approve plan for FEAT-<arg>? (<N> tasks, complexity <S|M|L>) (yes / refine <feedback> / abort)

- `yes` -> set status=`in-progress` in `00-spec.md` and `index.md`; proceed to Phase 4.
- `refine` -> invoke `sd-spec-architect` with `TASK = refine`, `SPEC = .specs/FEAT-<arg>/00-spec.md`, `FEEDBACK = <user feedback>`. Loop.
- `abort` -> set status=`archived`, exit.

**Face B - Gate Complexity (HARD)** (plan is over threshold: tasks > 8; spans > 2 production
layers/subsystems - distinct `Layer` values excluding `Tests`/`Config`, which cross-cut every
change; impact surface > 8 files; or an unresolved Open question remains). The workflow **refuses to
execute one oversized plan.** Present the architect's proposal and STOP.

If the architect returned a **decompose proposal**, ask:

> FEAT-<arg> exceeds the complexity threshold (<reason: e.g. 14 tasks, spans 3 layers>).
> Split into <N> child specs? (approve split / no-split <reason> / refine <feedback> / abort)

- `approve split` -> for each proposed child, in dependency order:
  1. Invoke `sd-spec-architect` with `TASK = create`, `TEMPLATE = feature.template.md`,
     `SPEC_ID = FEAT-<parent-arg>-<child-slug>`, and a `TICKET_CONTEXT` carved from the parent (the
     child's SC/AC slice + relevant Why/What). The child is a normal feature spec at status=`draft`
     - its own `/sd:feature` run will plan and execute it later. Children inherit medium scope by
     construction.
  2. Register the child in `.specs/index.md` at status=`draft`.
  3. Link it: `/sd:spec link FEAT-<parent-arg> spawns FEAT-<parent-arg>-<child-slug>` (the command
     writes the inverse `spawned-by` on the child). Then wire declared dependencies between
     children with `/sd:spec link FEAT-...-<a> depends-on FEAT-...-<b>`.
  Then make the **parent an umbrella record**: set parent status=`archived` in `00-spec.md` and
  `index.md` (it spawned its children; it does not execute its own oversized plan), and append to
  `05-retro.md` a one-line note naming the children it spawned and why it decomposed. The parent's
  `00-spec.md`, `01-plan.md`, `02-tasks.md` are left intact as the historical record - **immutable,
  never edited to match the split**. Print the child IDs and tell the user to run `/sd:feature
  <child-arg>` on each, respecting the dependency order. Exit this workflow.
- `no-split <reason>` -> the user judges the work legitimately atomic (large but cohesive, no clean
  partition). Apply rule `ESC-FEAT-03b` of **sd-model-escalation** - trigger input: whether
  `ESC-FEAT-03` fired for this plan in Phase 3 step 0. Then treat as Face A `yes`: set
  status=`in-progress`, proceed to Phase 4. Log the no-split decision and its reason to
  `05-retro.md`.
- `refine` -> `sd-spec-architect` `TASK = refine`; loop back through the self-assessment.
- `abort` -> set status=`archived`, exit.

If the architect returned a **no-split** flag itself (over threshold but it found no clean split),
present that reasoning and ask the same question - the user still owns the call between forcing a
split and accepting the escalated single plan.

---

## Phase 4 - Execute (no per-task reviewer)

Process tasks from `02-tasks.md` in dependency order.

For each unchecked task:

1. **Pre-flight**: re-read `00-spec.md`, the specific task block, and the constitution sections cited under the spec's "Constitution check".
2. **Model escalation check, then the implementer.** Before this task's first implementer call,
   apply rules `ESC-FEAT-04` and `ESC-FEAT-04b` of **sd-model-escalation** (read in Phase 0).
   Trigger inputs: the task block's `Estimated complexity` and `Reversibility` fields. The decision
   also covers this task's re-invocations in step 5; its retro line precedes the task's step 7 line.
   **Invoke `sd-implementer`** (model: default, or as resolved above) with:
   - `TASK_DETAILS = <full task block>`
   - `SPEC_REF = .specs/FEAT-<arg>/00-spec.md`
   - `IMPACT_REF = .specs/FEAT-<arg>/03-decisions.md`
   - `WORKFLOW_TYPE = feature`
3. Implementer edits only files in `Files`. Writes a test if `Test` references a non-existent test file.
4. **Run the task's test** in isolation via `commands.test` from project-config (scoped to the new test if possible).
5. **Self-check** (main thread, NO reviewer subagent):
   - Did implementer stay within `Files` list? If not -> revert, re-invoke.
   - Does the test pass? If not -> re-invoke implementer with failure output.
   - Any obvious constitution violation visible from the diff? If yes -> re-invoke with feedback.
   - **Plan-invalidating discovery?** If the implementer reports (or the diff reveals) that the task's
     premise is false - a `Pattern refs` precedent does not exist, an interface differs from what the
     task assumed, a `Depends on` edge is backwards, or a task is now known missing/redundant - do
     NOT hack-edit `02-tasks.md`. Enter **Gate Re-plan** below. This is distinct from an ordinary
     in-task adjustment, which the implementer handles within its own scope (see `sd-replan-loop` for
     the boundary).
6. **Check off** the task in `02-tasks.md`: set its `Status` line to `done`, per the "Check-off
   marker" section of the **sd-atomic-task-format** skill. Change nothing else in the block.
7. Log a one-line summary to `.specs/FEAT-<arg>/05-retro.md`: `T<NN>: <status> - <note>`.

> **Why no per-task reviewer?** Each reviewer invocation spawns a sonnet-class subagent that reloads the full context (CLAUDE.md + constitution + spec + changed files). For N tasks, that is N expensive calls. The main thread self-check catches scope violations and test failures. Constitution compliance and cross-task issues are caught more efficiently by the batch review in Phase 5.

Move to next task. Repeat until all tasks checked.

### Gate Re-plan (HARD) - adaptive re-plan on a plan-invalidating discovery

Reachable from Phase 4 (self-check above) **and** Phase 5b (a batch-review finding that the plan
itself is wrong). Follow the **sd-replan-loop** skill; the protocol is defined there once and shared
with `/sd:refactor`. In brief:

1. STOP. Surface the trigger, the affected task IDs, and the proposed delta. Ask:

   > Re-plan FEAT-<arg>? Discovery: <trigger>. Affects <task IDs>. (approve / revise <feedback> / abort task)

   - `approve` -> proceed. `revise` -> adjust the delta and re-ask. `abort task` -> normal task abort.
<!-- contract-lint: allow CL102 - scoped re-plan passes REPLAN_SCOPE/REVISION instead of SPEC/IMPACT, per the Scoped re-plan sub-path documented in agents/spec-architect.md -->
2. Invoke `sd-spec-architect` with `TASK = plan`, `REPLAN_SCOPE = <affected task IDs>`,
   `REVISION = R<n>` (next contiguous number). It appends the `## Revisions` entry to `01-plan.md`
   (append-only; the original plan prose is never edited), regenerates ONLY the affected task blocks
   in `02-tasks.md`, and marks each `Revised-by: R<n>`.
3. Resume Phase 4 at the first regenerated task. Tasks the revision did not touch stay checked.

This gate runs only while the spec is `in-progress` - it never re-plans a `done` spec. It adds no new
top-level gate to the workflow's count: it fires only on a plan-invalidating discovery, exactly as
Gate Complexity fires only over threshold.

---

## Phase 5 - Integration + batch review

### 5a. Integration tests

1. Run the full test suite via `commands.test` from project-config.
2. Run lint via `commands.lint`.
3. If either fails, diagnose inline. If the fix is trivial (import, typo), apply directly. If non-trivial, route back through Phase 4 as a new task (append to `02-tasks.md`, spec the diagnosis under `03-decisions.md`).

### 5b. Batch review (single reviewer invocation for ALL changes)

Invoke `sd-reviewer` with:
   - `TASK_TYPE = holistic`
   - `CHANGED_FILES = <all files changed across all tasks in Phase 4>`
   - `SPEC_REF = .specs/FEAT-<arg>/00-spec.md`
   - `PLAN_REF = .specs/FEAT-<arg>/01-plan.md`

Reviewer checks ALL changes in one pass:
- Constitution compliance across the full changeset.
- Cross-task consistency (naming, patterns, DI wiring) and conformance to each task's `Pattern refs`.
- Scope creep detection (files not in any task's `Files` list).
- Test coverage adequacy.
- Public API surface changes.

### ⛔ Gate 3 - Integration + review pass

STOP. Display:
- Test + lint summary.
- Reviewer verdict counts (BLOCK / WARN / SUGGEST / PASS).

Ask:

> All clean for FEAT-<arg>? (yes / address findings / abort)

Treat findings:
- Any 🔴 BLOCK that is a **code defect** (the task was right, the implementation is wrong) -> route
  back to implementer with the finding as feedback. Re-run batch review after fix.
- Any 🔴 BLOCK that reveals the **plan itself was wrong** (a spec/plan decision proved incorrect once
  written - e.g. a task asserts a behavior the codebase contradicts) -> enter **Gate Re-plan** (Phase
  4) with `Phase: review`, not a bare implementer fix. This is the review-time re-plan path: the
  wrong decision is recorded as a revision and the affected tasks are regenerated, rather than
  hand-patched with only a retro sentence.
- Any 🟠 WARN -> ask user: address now or log to `05-retro.md` as follow-up?
- 🟡 SUGGEST and 🟢 PASS -> log to retro, proceed.

---

## Phase 6 - Close-out

1. Review each `AC-<n>` checkbox in `00-spec.md` against evidence (a passing test, a measured
   value, a reviewer verdict) and check it only with a `file:line` or test citation logged to
   `.specs/FEAT-<arg>/05-retro.md`. Never tick a box just to make VF030 pass - an unearned
   checkbox is a fabricated result, not a shortcut.
2. Run `/sd:verify FEAT-<arg>`. It must report `result: pass`.
   - On FAIL: address the findings (uncovered criterion -> back to Phase 3 to add tasks;
     failing tests -> back to Phase 4; unchecked `AC-<n>` criterion with real evidence already
     in hand -> gather the citation and check the box per step 1; unchecked criterion with no
     evidence yet -> route back to the phase that produces it, e.g. Phase 4 for an untested
     behavior). Re-run until it passes. Do NOT proceed on fail - the spec-gate hook will block
     step 5 without a passing `06-verify.md`.
3. Append to `.specs/FEAT-<arg>/05-retro.md`:
   - Tasks completed (count + IDs).
   - Surprises encountered.
   - Deferred follow-ups (with reserved spec IDs, if any).
   - Constitution exceptions taken (should be none).
   - Cost rough estimate if available.
4. **Spawned specs**: re-read the "Deferred follow-ups" and "Surprises encountered" entries just
   written to 05-retro.md and look for follow-up work that has no home: a defect left in place on
   purpose, a rule or doc found stale, a "separate spec" hand-off, a hotspot not taken. For each
   one, ask the user to reserve an ID and add a row to `00-spec.md`'s `## Spawned specs` table
   (`Reserved ID | Type | Title | Owner`). This is a prompt, not a gate: nothing deferred, or the
   user declines - leave the table at header + separator and proceed. Do NOT create the child
   specs here, and do NOT add a reserved ID to `.specs/index.md`; an index row exists only once
   the real spec directory does (see `/sd:spec`, "Index <-> folder symmetry").
5. Set frontmatter status=`done` in `00-spec.md`.
6. Update `.specs/index.md`: state -> `done`, completion date.
7. Print a 5-line summary to the user.

---

## Rules (hard constraints)

- Phase 0 always runs. No exceptions, even on resume.
- Gates 1-3 are HARD. The workflow refuses to proceed without explicit approval.
- **Gate Complexity is a face of Gate 2, not a fourth gate.** It fires ONLY when the plan is over
  threshold; a spec under threshold sees the normal plan approval with zero added friction. This is
  why the workflow still has 3 hard gates - do not describe it as 4.
- **Gate Re-plan is a conditional gate, not a fourth always-on gate.** Like Gate Complexity, it
  fires ONLY on a specific trigger - a plan-invalidating discovery in Phase 4 or a plan-is-wrong
  BLOCK in Phase 5. A run that never hits one never sees it. It is HARD when it does fire (explicit
  approval, no override), and it never re-plans a `done` spec. The protocol lives in the
  `sd-replan-loop` skill; `02-tasks.md` is re-planned only through it - never by a silent hand-edit.
  Any revision is recorded append-only in `01-plan.md`'s `## Revisions` log with the original plan
  prose left intact.
- **Model escalation follows `sd-model-escalation` only.** Rules `ESC-FEAT-02`, `ESC-FEAT-03`,
  `ESC-FEAT-03b`, `ESC-FEAT-04` and `ESC-FEAT-04b` are applied where named above; the ladder,
  precedence, `models.escalation` config and the `05-retro.md` line format live in the skill and
  are not restated here.
- **A decomposed parent is an immutable umbrella.** Once split, the parent's spec/plan/tasks are a
  historical record and are never edited to match the children. Children are normal feature specs,
  linked via `/sd:spec link spawns` / `depends-on` - no bespoke decomposition mechanism.
- Implementer touches only files declared in the task's `Files` list. Any scope creep -> stop, surface to main thread, log to retro.
- Reviewer is invoked ONCE in Phase 5b for the entire changeset (not per-task). This is a deliberate cost optimization.
- BLOCK findings from the batch review must be addressed before close-out.
- No new constitution exception introduced silently. If one is needed, spawn an ADR spec.
- If `ticket.system == "jira"` and `<arg>` looks like a JIRA ID, the ticket is fetched in Phase 1. If MCP is unavailable, ask user for paste or proceed with slug.
- All files under `.specs/FEAT-<arg>/` are written in UTF-8 with no BOM.