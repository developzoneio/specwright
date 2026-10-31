---
description: Spec-driven feature workflow. Spec -> impact -> outline (complexity triage; S lane: one combined approval) -> expand -> execute -> batch review -> close. 3 hard gates.
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
| S lane (see below), status=`draft`, no `## Outline` in `01-plan.md` | `s-draft` | Start Phase 1S |
| S lane, status=`draft`, `01-plan.md` has `## Outline` | `s-outline-drafted` | Present Face S of Gate 1 |
| S lane, status=`approved`, `01-plan.md` has `## Outline`, no `02-tasks.md`, the last `## Gate 1+2` section of `gate-briefs.md` has an approving `Reply:` line | `s-approved` | Set status=`in-progress` (`00-spec.md`, `index.md`), start Phase 3b |
| `00-spec.md` exists, status=`draft` | `draft` | Present spec for Gate 1 |
| status=`approved`, no `02-tasks.md`, no `## Outline` in `01-plan.md`, no `## Impact analysis (sd-code-explorer)` in `03-decisions.md` | `approved` | Start Phase 2 |
| status=`approved`, no `02-tasks.md`, no `## Outline` in `01-plan.md`, impact analysis present | `impact-mapped` | Start Phase 3a |
| status=`approved`, `01-plan.md` has `## Outline`, no `02-tasks.md` | `outline-drafted` | Present outline for Gate 2 |
| status=`approved`, `02-tasks.md` exists | `plan-drafted` | Present plan for Gate 2 |
| status=`in-progress`, `01-plan.md` has `## Outline`, no `02-tasks.md` | `outline-approved` | Start Phase 3b |
| `02-tasks.md` exists, unchecked tasks remain | `in-progress` | Resume Phase 4 at next unchecked task |
| status=`in-progress`, all tasks checked, no approving `Reply:` in a `## Gate 3` section of `gate-briefs.md` | `tasks-complete` | Start Phase 5 |
| status=`in-progress`, all tasks checked, the last `Reply:` in a `## Gate 3` section of `gate-briefs.md` approves | `review-passed` | Start Phase 6 |
| status=`done` | `done` | Print summary, exit |
| status=`archived`, spawned children (has `spawns` links) | `umbrella` | Print the child IDs + `/sd:feature <child-arg>` for each, in dependency order; exit |
| status=`archived` | `archived` | Print archived notice, exit |

"Checked" and "unchecked" mean the task's check-off marker as defined in the "Check-off marker"
section of the **sd-atomic-task-format** skill - the one definition; do not invent a marker. Task
rows are evaluated only while status is `in-progress`: a `done` or `archived` spec resolves from its
frontmatter first and is never resumed from its task markers.

`## Outline` is the task outline heading Phase 3a writes (ADR 0022). A spec planned in one step,
before the outline existed, never has it: the two outline rows never match it, and every other row
reads exactly as it did. Such a spec at `plan-drafted` presents its plan for Gate 2 from
`02-tasks.md` as before.

**S lane** means: the `complexity` frontmatter of `00-spec.md` is `S` **and** `05-retro.md` has no
`s-lane: fallback` line (ADR 0030). The three S rows are checked first, before the rows they refine;
every other row keeps its condition. An M or L spec, and an S spec that is already `approved` or
later, can match none of them, so they resolve exactly as before. `## Outline` is the exact
heading: the `## Outline (S-lane draft)` section a fallen-back S spec keeps is not it, so a fallen-back
spec resolves on the ordinary rows (`draft`, then `approved` -> Phase 2).

---

## Phase 0 - Bootstrap (always runs)

1. Read `~/.claude/skills/sd/sd-bootstrap-guard/SKILL.md` and apply it before anything else here -
   it owns the Layer-2 reads and all of their messages (commands cannot load skills via
   frontmatter, so it is read at runtime). If that file is unreadable, STOP: "specwright install
   incomplete - bootstrap guard skill not found under `~/.claude/skills/sd/`. Re-run the installer."
2. Determine state from table above.
3. Read `~/.claude/skills/sd/sd-model-escalation/SKILL.md`. It owns the model escalation policy
   applied at Phase 2 step 0, Phase 3a step 0, Phase 3b step 0 and Phase 4 step 2; this file
   names only rule IDs and trigger inputs. If that file is unreadable, STOP: "specwright install
   incomplete - model escalation skill not found under `~/.claude/skills/sd/`. Re-run the
   installer."
4. Read `~/.claude/skills/sd/sd-gate-brief/SKILL.md`. It owns the gate brief artifact
   (`gate-briefs.md`), what each gate shows, the `details` option and the wording of every
   user-facing line; this file names only the gates it applies to. If that file is unreadable,
   STOP: "specwright install incomplete - gate brief skill not found under `~/.claude/skills/sd/`.
   Re-run the installer."

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
6. If the spec is on the S lane (see the state machine), continue with Phase 1S below instead of
   presenting the ordinary Gate 1. The `GATE_BRIEF` block `create` returned is then not used.

### ⛔ Gate 1 - Spec approval

STOP. This gate has two faces. Face S (below) is presented for an S spec whose outline stayed within
the S limits; every other spec sees the ordinary spec approval first. The main thread writes the
Gate 1 brief to `.specs/FEAT-<arg>/gate-briefs.md` from the architect's `GATE_BRIEF` block, per
**sd-gate-brief**, then shows it verbatim. Ask:

> Approve spec FEAT-<arg>? (yes / refine <feedback> / details / abort)

- `yes` -> set status=`approved`, proceed.
- `refine` -> invoke `sd-spec-architect` with `TASK = refine`, `SPEC = .specs/FEAT-<arg>/00-spec.md`, `FEEDBACK = <user feedback>`. Loop; the next pass is a new brief section.
- `details` -> show the collapsed decisions per **sd-gate-brief**, then ask again.
- `abort` -> set status=`archived`, exit.

**Face S - spec and outline approval (S lane).** Presented instead of the ordinary question above
when Phase 1S produced an outline within the S limits. The main thread writes the Face S brief to
`.specs/FEAT-<arg>/gate-briefs.md` from the architect's `GATE_BRIEF` block (`gate: s-lane`: spec and
outline in one brief, task rows from the outline), per **sd-gate-brief**, then shows it verbatim.
Ask:

> Approve spec and outline for FEAT-<arg>? (<N> tasks, complexity S) (yes / refine <feedback> / details <target> / abort)

- `yes` -> append the `Reply:` line to the section, then change the status with the Edit tool in two
  steps: `approved`, then `in-progress`, each in `00-spec.md` and `index.md`. Two steps, because
  `draft` -> `in-progress` is not a legal transition for spec-gate. Proceed to Phase 3b. One reply
  approves the spec, the outline and every default, shown and collapsed.
- `refine` -> invoke `sd-spec-architect` with `TASK = refine`, `SPEC = .specs/FEAT-<arg>/00-spec.md`, `FEEDBACK = <user feedback>`. Then run Phase 1S again, because the outline may no longer fit the spec; a breach falls back. The next pass is a new brief section.
- `details <target>` -> print what the target names (`spec`, a task ID, `plan` or `risks`), then ask again.
- `abort` -> set status=`archived`, exit.

---

## Phase 1S - S lane (complexity S only)

Applies when the spec is on the S lane (see the state machine). It replaces Phase 2 and Phase 3a for
this spec and ends at Face S of Gate 1 (ADR 0030). The S limits live in **sd-spec-templates**
("S-lane thresholds"); this file never restates them. No model escalation rule applies: the rules
of **sd-model-escalation** that read `complexity` fire on `L`, and this lane runs only for `S`.

<!-- contract-lint: allow CL102 - the S-lane outline passes LANE instead of IMPACT because no impact map exists on this lane, per the S-lane outline section of agents/spec-architect.md -->
1. Invoke `sd-spec-architect` with:
   - `TASK = plan`
   - `STEP = outline`
   - `LANE = s`
   - `SPEC = .specs/FEAT-<arg>/00-spec.md`
2. The architect runs its own bounded discovery, writes `01-plan.md` (a `## Discovery` section and
   the `## Outline` table) and measures the outline against the S limits. It returns one of:
   - a normal report with a `GATE_BRIEF` block `gate: s-lane` -> present **Face S** of Gate 1.
   - `STATUS = s-lane-breach` -> **fall back**, below.

**Fall back to the full path.** The decision is the workflow's and asks the user nothing. The
architect has already written its outline under `## Outline (S-lane draft)`, so no hook or state row
mistakes it for a plan waiting for approval. In order:

1. Append one line to `.specs/FEAT-<arg>/05-retro.md` (create the file if missing, never overwrite
   existing content), with the architect's clauses joined by `; `:
   `s-lane: fallback to full path - tasks 6 > 4; layers 2 > 1 (Application, Domain)`
2. Present the **ordinary** Gate 1 from the architect's `GATE_BRIEF` block (`gate: spec`). The status
   stays `draft`.
3. The spec then runs the full path: Phase 2, Phase 3a (the architect rewrites `01-plan.md`, using
   the kept draft outline as a starting point), Gate 2 on either face, Phase 3b. Nothing is kept
   from the S lane except the retro line and the draft until Phase 3a rewrites it.

The lane is one-way: the retro line keeps the spec off the S rows, so a `refine` at the ordinary
Gate 1 never re-enters it.

---

## Phase 2 - Impact analysis

Skipped on the S lane: an S spec within the S limits has no impact map, and its outline carries a
`## Discovery` section in its place. A fallen-back S spec runs this phase as any spec does.

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

## Phase 3 - Plan: outline, then expand

Phase 3 plans in two steps (ADR 0022). Phase 3a writes the plan and a task outline; Gate 2 approves
the outline - and decides any decompose - before a single full task block exists. Phase 3b then
expands the approved outline into `02-tasks.md`. Phase 3b adds no gate.

### 3a. Outline

Not run for an S spec on the S lane: Phase 1S wrote its outline and Face S of Gate 1 approved it.

0. **Model escalation check.** Apply rule `ESC-FEAT-03` of **sd-model-escalation** (read in
   Phase 0). Trigger input: the `complexity` frontmatter field of `.specs/FEAT-<arg>/00-spec.md`.
1. Invoke `sd-spec-architect` (model: default, or as resolved by step 0) with:
   - `TASK = plan`
   - `STEP = outline`
   - `SPEC = .specs/FEAT-<arg>/00-spec.md`
   - `IMPACT = .specs/FEAT-<arg>/03-decisions.md`
2. Spec-architect produces `.specs/FEAT-<arg>/01-plan.md`: approach, alternatives considered,
   rationale, risks, and the `## Outline` table - one row per task (ID, title, Files, Covers), per
   the "Outline row" section of the **sd-atomic-task-format** skill. It writes no `02-tasks.md`.
   - It also self-assesses the outline against the decompose thresholds and returns either a normal
     report (under threshold) or `STATUS = needs-input` carrying a **decompose proposal** or a
     **no-split** flag (over threshold). See its "Complexity self-assessment" section.
3. **Do not set status yet** - the Gate 2 branch below decides whether this spec executes its own
   plan or becomes an umbrella. Setting `in-progress` happens inside the resolved branch.

### ⛔ Gate 2 - Plan approval (with complexity triage)

STOP. This gate has two faces. Which one you present is decided by the architect's self-assessment
from Phase 3a step 2 - **not** by adding a separate always-on gate. A spec **under** the decompose
thresholds sees only the normal plan approval below, with **zero added friction**.

Either face starts the same way: the main thread writes the Gate 2 brief to
`.specs/FEAT-<arg>/gate-briefs.md` from the architect's `GATE_BRIEF` block (the plan face or the
complexity face, per **sd-gate-brief**; its task rows come from the outline), then shows it verbatim. `details <target>` on either face prints what the target names (no
target, a task ID, `plan` or `risks`) per **sd-gate-brief** and asks the same question again.

**Face A - normal plan approval** (plan is under threshold). Show the plan brief. Ask:

> Approve plan for FEAT-<arg>? (<N> tasks, complexity <S|M|L>) (yes / refine <feedback> / details <target> / abort)

- `yes` -> set status=`in-progress` in `00-spec.md` and `index.md`; proceed to Phase 3b (a legacy
  plan that already has `02-tasks.md` proceeds to Phase 4).
- `refine` -> invoke `sd-spec-architect` with `TASK = refine`, `SPEC = .specs/FEAT-<arg>/00-spec.md`, `FEEDBACK = <user feedback>`. Loop back through Phase 3a.
- `details <target>` -> print what the target names, then ask again.
- `abort` -> set status=`archived`, exit.

**Face B - Gate Complexity (HARD)** (plan is over threshold, measured on the outline: tasks > 8;
spans > 2 production layers/subsystems - distinct layers derived from the rows' `Files` excluding
`Tests`/`Config`, which cross-cut every change, per **sd-spec-templates**; impact surface > 8
files; or an unresolved Open question remains). The workflow **refuses to
execute one oversized plan.** Show the complexity brief, which carries the architect's proposal,
and STOP.

If the architect returned a **decompose proposal**, ask:

> FEAT-<arg> exceeds the complexity threshold (<reason: e.g. 14 tasks, spans 3 layers>).
> Split into <N> child specs? (approve split / no-split <reason> / refine <feedback> / details <target> / abort)

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
  `00-spec.md` and `01-plan.md` (with its outline; and `02-tasks.md`, for a legacy plan) are left
  intact as the historical record - **immutable, never edited to match the split**. No task block
  is written for a split parent. Print the child IDs and tell the user to run `/sd:feature
  <child-arg>` on each, respecting the dependency order. Exit this workflow.
- `no-split <reason>` -> the user judges the work legitimately atomic (large but cohesive, no clean
  partition). Treat as Face A `yes`: set status=`in-progress`, proceed to Phase 3b, whose step 0
  escalates the expansion. Log the no-split decision and its reason to `05-retro.md`.
- `refine` -> `sd-spec-architect` `TASK = refine`; loop back through Phase 3a and its self-assessment.
- `details <target>` -> print what the target names, then ask again.
- `abort` -> set status=`archived`, exit.

If the architect returned a **no-split** flag itself (over threshold but it found no clean split),
present that reasoning and ask the same question - the user still owns the call between forcing a
split and accepting the escalated single plan.

### 3b. Expand (no gate)

Runs once Gate 2 has approved the outline - or, on the S lane, Face S of Gate 1 has: status
`in-progress`, `## Outline` in `01-plan.md`, no `02-tasks.md`.

0. **Model escalation check.** Apply rule `ESC-FEAT-03b` of **sd-model-escalation**. Trigger
   input: whether Gate 2 was approved through `no-split` (the `Reply:` line of the last
   `## Gate 2 - Complexity` section in `gate-briefs.md`, or the no-split line in `05-retro.md`).
1. Invoke `sd-spec-architect` (model: default, or as resolved by step 0) with:
   - `TASK = plan`
   - `STEP = expand`
   - `SPEC = .specs/FEAT-<arg>/00-spec.md`
   - `IMPACT = .specs/FEAT-<arg>/03-decisions.md` (on the S lane no such file exists; the plan's
     `## Discovery` section stands in for it)
2. Spec-architect expands every outline row into a full task block in
   `.specs/FEAT-<arg>/02-tasks.md`, formatted per the **sd-atomic-task-format** skill (5 core
   fields plus `Pattern refs`/`Estimated complexity`/`Reversibility` where the skill's defaults say
   to write them; the architect applies this format, do not re-specify it here), keeping each
   row's ID, title, `Files` and `Covers`. It never edits the `## Outline` table.
3. **Material divergence?** If the architect finds a row that cannot be expanded as approved (per
   **sd-replan-loop**), it writes no `02-tasks.md` and returns `STATUS = needs-input` with the
   affected rows and a proposed delta. Enter **Gate Re-plan** below with `Phase: expand`. Never edit
   the approved outline, and never write a diverging block without that gate.
4. Proceed to Phase 4. No gate here: Gate 2 approved what each block carries.

---

## Phase 4 - Execute (no per-task reviewer)

Process tasks from `02-tasks.md` in dependency order.

For each unchecked task:

1. **Pre-flight**: re-read `00-spec.md`, the specific task block, and the constitution sections cited under the spec's "Constitution check".
2. **Model escalation check, then the implementer.** Before this task's first implementer call,
   apply rules `ESC-FEAT-04` and `ESC-FEAT-04b` of **sd-model-escalation** (read in Phase 0).
   Trigger inputs: the task block's `Estimated complexity` and `Reversibility` fields (absent
   reads as the default, per **sd-atomic-task-format**). The decision also covers this task's
   re-invocations in step 5; its retro line precedes the task's step 7 line.
   **Invoke `sd-implementer`** (model: default, or as resolved above) with:
   - `TASK_DETAILS = <full task block>`
   - `SPEC_REF = .specs/FEAT-<arg>/00-spec.md`
   - `IMPACT_REF = .specs/FEAT-<arg>/03-decisions.md` (omit it when that file does not exist, as on
     the S lane; the task's `Pattern refs` already carry what the implementer needs)
   - `WORKFLOW_TYPE = feature`
3. Implementer edits only files in `Files`. Writes a test if the witness test named in
   `Acceptance` (or a legacy `Test` field) does not yet exist.
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

Reachable from Phase 3b (a material divergence from the approved outline), Phase 4 (self-check
above), Phase 5b (a batch-review finding that the plan itself is wrong) **and** Phase 6 (an
uncovered criterion in `/sd:verify`, `Phase: verify`). Follow the **sd-replan-loop** skill; the protocol is defined there once and shared
with `/sd:refactor`. In brief:

1. STOP. The main thread writes the Re-plan brief (trigger, affected tasks, proposed delta) to
   `.specs/FEAT-<arg>/gate-briefs.md` per **sd-gate-brief**, then shows it verbatim. Ask:

   > Re-plan FEAT-<arg>? Discovery: <trigger>. Affects <task IDs>. (approve / revise <feedback> / details <target> / abort task)

   - `approve` -> proceed. `revise` -> adjust the delta and re-ask. `abort task` -> normal task abort.
   - `details <target>` -> print what the target names per **sd-gate-brief**, then ask again.
<!-- contract-lint: allow CL102 - scoped re-plan passes REPLAN_SCOPE/REVISION instead of SPEC/IMPACT, per the Scoped re-plan sub-path documented in agents/spec-architect.md -->
2. Invoke `sd-spec-architect` with `TASK = plan`, `REPLAN_SCOPE = <affected task IDs>`,
   `REVISION = R<n>` (next contiguous number). It appends the `## Revisions` entry to `01-plan.md`
   (append-only; the original plan prose is never edited), regenerates ONLY the affected task blocks
   in `02-tasks.md`, and marks each `Revised-by: R<n>`. From Phase 3b it also passes `STEP = expand`
   and writes the whole `02-tasks.md`, per **sd-replan-loop**. A scoped ID with no block yet is a
   new task, appended after the last block (the Phase 6 case).
3. Resume Phase 4 at the first regenerated task (from Phase 3b, at the first task). Tasks the
   revision did not touch stay checked.

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

STOP. The main thread logs every 🟡 SUGGEST to `05-retro.md` without asking, then writes the
Gate 3 brief to `.specs/FEAT-<arg>/gate-briefs.md` from the reviewer's `GATE_BRIEF` block plus the
Phase 5a test + lint summary, per **sd-gate-brief**, and shows it verbatim. Ask:

> All clean for FEAT-<arg>? (yes / address findings / details <target> / abort)

`details <target>` prints what the target names per **sd-gate-brief** (no target: the collapsed
warning and suggestion detail), then asks again.

Treat findings:
- Any 🔴 BLOCK that is a **code defect** (the task was right, the implementation is wrong) -> route
  back to implementer with the finding as feedback. Re-run batch review after fix.
- Any 🔴 BLOCK that reveals the **plan itself was wrong** (a spec/plan decision proved incorrect once
  written - e.g. a task asserts a behavior the codebase contradicts) -> enter **Gate Re-plan** (Phase
  4) with `Phase: review`, not a bare implementer fix. This is the review-time re-plan path: the
  wrong decision is recorded as a revision and the affected tasks are regenerated, rather than
  hand-patched with only a retro sentence.
- Any 🟠 WARN -> the brief recommends logging it as a follow-up. `yes` logs each one to
  `05-retro.md` as a follow-up; `address findings` routes it back to the implementer instead.
- 🟡 SUGGEST (already logged) and 🟢 PASS -> proceed.

---

## Phase 6 - Close-out

Close-out does its bookkeeping silently and asks at most one question (step 4).

1. **Collect AC evidence (no question).** For each `AC-<n>` line in `00-spec.md`, the covering
   tasks are the `02-tasks.md` blocks whose `Covers` lists it (parsing shapes as in `/sd:verify`).
   The evidence exists only when all of these hold: at least one covering task exists and every
   covering task is at the `done` check-off marker; each covering task has a witness test, as
   defined by the "Witness test" section of **sd-atomic-task-format**, and the file it names
   exists (Glob); and the Gate 3 brief's `Tests:` line records the Phase 5a suite as passing.
   - Evidence exists: check the box, and log `AC-<n>: <task IDs> - <witness test path(s)>; full
     suite green at Gate 3` under `## Close-out (Phase 6)` in `.specs/FEAT-<arg>/05-retro.md`.
   - Evidence is missing: leave the box unchecked, log `AC-<n>: unchecked - <what is missing>`,
     and report it in plain words.

   Never tick a box just to make verification pass - an unearned checkbox is a fabricated result,
   not a shortcut. This step collects evidence and never creates it: a task title, a plan line or
   a reviewer remark is not evidence.
2. Run `/sd:verify FEAT-<arg>`. It must report `result: pass`.
   - On FAIL: address the findings (uncovered criterion -> the plan is incomplete, so enter
     **Gate Re-plan** (Phase 4) with `Phase: verify`, scoped to the task that will cover it, then
     resume Phase 4 at that task; never edit the approved outline or append a block by hand;
     failing tests -> back to Phase 4; unchecked `AC-<n>` criterion with real evidence already
     in hand but not readable by step 1 (a measured value, a reviewer verdict) -> cite it in
     `05-retro.md` and check the box, with no question; unchecked criterion with no
     evidence yet -> route back to the phase that produces it, e.g. Phase 4 for an untested
     behavior). Re-run until it passes. Do NOT proceed on fail - the spec-gate hook will block
     step 5 without a passing `06-verify.md`.
3. Append to `.specs/FEAT-<arg>/05-retro.md`, asking nothing:
   - Tasks completed (count + IDs).
   - Surprises encountered.
   - Deferred follow-ups, one line each: every Gate 3 warning logged as a follow-up, plus any
     work in the surprises that has no home (a defect left in place on purpose, a rule or doc
     found stale, a "separate spec" hand-off, a hotspot not taken).
   - Constitution exceptions taken (should be none).
   - Cost rough estimate if available.
4. **Reserve spec IDs (at most one question).** Let N be the number of deferred follow-ups
   written in step 3 that have no reserved ID.
   - N = 0: ask nothing and leave `00-spec.md`'s `## Spawned specs` table at header + separator.
   - N >= 1: list each follow-up's plain title, one per line, then ask once:

     > <N> follow-ups were deferred - reserve spec IDs? (yes / no)

     `yes` adds one row per follow-up to the `## Spawned specs` table
     (`Reserved ID | Type | Title | Owner`, Owner `unassigned`) with no further question. `no`
     leaves the table at header + separator.
   - Whenever N >= 1, append `- Follow-up question: <N> deferred. Reply: <reply verbatim>` to
     `05-retro.md`.

   This is a prompt, not a gate: it has no STOP block and adds nothing to the gate count. Do NOT
   create the child specs here, and do NOT add a reserved ID to `.specs/index.md`; an index row
   exists only once the real spec directory does (see `/sd:spec`, "Index <-> folder symmetry").
5. Set frontmatter status=`done` in `00-spec.md`.
6. Update `.specs/index.md`: state -> `done`, completion date.
7. Print a 5-line summary to the user, worded per **sd-gate-brief**. It states the follow-up count
   or the reserved IDs, and any criterion left unchecked, inside those 5 lines.

---

## Rules (hard constraints)

- Change `.specs/index.md` and any spec `status:` field with the Edit tool only - never a shell
  command (`sed -i`, `>`, `tee`, `Set-Content`). spec-gate checks an Edit-tool change (Rules 0,
  0b, 1) and records its `spec_transition`; a shell write skips both (SW-79).
- Phase 0 always runs. No exceptions, even on resume.
- Gates 1-3 are HARD. The workflow refuses to proceed without explicit approval.
- **Gate Complexity is a face of Gate 2, not a fourth gate.** It fires ONLY when the plan is over
  threshold; a spec under threshold sees the normal plan approval with zero added friction. This is
  why the workflow still has 3 hard gates - do not describe it as 4.
- **Face S is a face of Gate 1, not a fourth gate.** On the S lane Gate 1 approves the spec and the
  outline in one reply, and it discharges Gate 2 as well: its `## Gate 1+2` brief section is the
  evidence of both. The count stays 3. An S spec that breaches the S limits falls back to the full
  path automatically, with no user decision, and the retro line `s-lane: fallback to full path` is
  its only trace; the full path is then unchanged.
- **Gate Re-plan is a conditional gate, not a fourth always-on gate.** Like Gate Complexity, it
  fires ONLY on a specific trigger - a material divergence from the outline in Phase 3b, a
  plan-invalidating discovery in Phase 4, a plan-is-wrong BLOCK in Phase 5 or an uncovered
  criterion in Phase 6. A run that never hits one never sees it. It is HARD when it does fire (explicit
  approval, no override), and it never re-plans a `done` spec. The protocol lives in the
  `sd-replan-loop` skill; `02-tasks.md` is re-planned only through it - never by a silent hand-edit.
  Any revision is recorded append-only in `01-plan.md`'s `## Revisions` log with the original plan
  prose left intact.
- **Model escalation follows `sd-model-escalation` only.** Rules `ESC-FEAT-02`, `ESC-FEAT-03`,
  `ESC-FEAT-03b`, `ESC-FEAT-04` and `ESC-FEAT-04b` are applied where named above; the ladder,
  precedence, `models.escalation` config and the `05-retro.md` line format live in the skill and
  are not restated here. Narrating a fired rule to the user follows **sd-gate-brief**.
- **Gate briefs and user-facing wording follow `sd-gate-brief` only.** Every gate above writes
  its brief to `.specs/FEAT-<arg>/gate-briefs.md` before showing it. The brief shape and language,
  the decision cap, the `details` targets and the rule for every line the user reads live in the
  skill and are not restated here.
- **An approved outline is immutable.** Once Gate 2 approves the `## Outline` table in `01-plan.md`,
  it is never edited. Phase 3b expands it as approved; a material divergence goes through Gate
  Re-plan and is recorded in `## Revisions`. Phase 3b adds no gate to the count.
- **A decomposed parent is an immutable umbrella.** Once split, the parent's spec/plan/tasks are a
  historical record and are never edited to match the children. Children are normal feature specs,
  linked via `/sd:spec link spawns` / `depends-on` - no bespoke decomposition mechanism.
- Implementer touches only files declared in the task's `Files` list. Any scope creep -> stop, surface to main thread, log to retro.
- Reviewer is invoked ONCE in Phase 5b for the entire changeset (not per-task). This is a deliberate cost optimization.
- BLOCK findings from the batch review must be addressed before close-out.
- No new constitution exception introduced silently. If one is needed, spawn an ADR spec.
- If `ticket.system == "jira"` and `<arg>` looks like a JIRA ID, the ticket is fetched in Phase 1. If MCP is unavailable, ask user for paste or proceed with slug.
- All files under `.specs/FEAT-<arg>/` are written in UTF-8 with no BOM.