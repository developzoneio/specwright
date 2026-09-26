---
description: Root-cause-first bug fix workflow. Capture -> reproduce -> investigate -> failing test -> minimal fix -> regression. 5 hard gates.
argument-hint: <JIRA-ID or slug>
---

# /sd:bug

Drives a bug from a one-line report to a documented root cause, a failing test that reproduces it, a minimal fix, and a regression-tested closure. Result is searchable under `.specs/BUG-<arg>/`.

**Argument**: `$ARGUMENTS` -> spec ID = `BUG-<arg>`.

---

## HARD RULES (read before every phase)

1. **NEVER write the fix before the root cause is documented.** Symptom-chasing produces "fixes" that ship the bug deeper.
2. **NEVER skip reproduction.** A bug that cannot be reproduced cannot be confirmed fixed.
3. **The fix is MINIMAL.** No opportunistic refactor. If you spot adjacent rot, spawn a separate REF-* spec.
4. **Test FIRST, then fix.** The failing test goes in before the fix is implemented (Phase 4 before Phase 5).

These rules override any user pressure to "just patch it".

---

## State machine (resume behavior)

| Detected state | Action |
|---|---|
| Folder not found | Start at Phase 1 |
| `00-spec.md` has empty "Symptom" | Resume Phase 1 |
| Symptom captured, "Reproduction" empty or unconfirmed | Resume Phase 2 |
| Reproduction confirmed, "Root cause" still TBD | Resume Phase 3 |
| Root cause confirmed, no failing test in `04-artifacts/repro/` | Resume Phase 4 |
| Failing test exists, "Fix approach" still TBD | Resume Phase 5 |
| Fix applied, regression suite not run | Resume Phase 6 |
| status `done` | Refuse to re-run |

---

## Phase 0 - Bootstrap

1. Read `~/.claude/skills/sd/sd-bootstrap-guard/SKILL.md` and apply it before anything else here -
   it owns the Layer-2 reads and all of their messages (commands cannot load skills via
   frontmatter, so it is read at runtime). If that file is unreadable, STOP: "specwright install
   incomplete - bootstrap guard skill not found under `~/.claude/skills/sd/`. Re-run the installer."
2. Read `~/.claude/skills/sd/sd-model-escalation/SKILL.md`. It owns the model escalation policy
   applied at Phase 3 step 1; this file names only rule IDs and trigger inputs. If that file is
   unreadable, STOP: "specwright install incomplete - model escalation skill not found under
   `~/.claude/skills/sd/`. Re-run the installer."
3. If `ticket.system == "jira"` and `<arg>` matches `ticket.pattern`, fetch ticket via Atlassian MCP.
4. Detect state. Print one-line resume plan.

---

## Phase 1 - Capture symptoms

1. Invoke `sd-spec-architect` with:
   - `TASK = create`
   - `TEMPLATE = bug.template.md`
   - `SPEC_ID = BUG-<arg>`
   - `TICKET_CONTEXT = <ticket payload or user-provided description>`
2. Architect fills Symptom, Expected, Affected. Leaves Reproduction / Root cause / Fix approach EMPTY (intentional - workflow enforces sequencing).
3. If a ticket was fetched, architect also snapshots it (ticket content + related tickets + linked Confluence pages, per its Ticket snapshot protocol) to `.specs/BUG-<arg>/04-artifacts/ticket/`.
4. Architect determines severity (P0-P3) from impact.

### ⛔ Gate 1 - Symptom captured

STOP. Show the user the captured symptom, expected behavior, severity, and affected scope. Ask:

> Is this an accurate description of the bug? (yes / refine / abort)

- `yes` -> status=`draft`, append to index, proceed.
- `refine` -> loop with architect.

---

## Phase 2 - Reproduce

This is the most-skipped phase and the most important. Without reproduction the rest is theater.

1. Work interactively with the user. Ask:
   - What inputs trigger it? (exact values)
   - Which environment? (local, staging, prod-only)
   - Is it 100% reproducible or intermittent?
2. Document deterministic steps in `00-spec.md` Reproduction section.
3. Attempt to reproduce in the local dev environment if applicable.
4. If non-deterministic, capture the conditions that make it more likely AND save log evidence to `.specs/BUG-<arg>/04-artifacts/repro-evidence/`.
5. If reproduction requires production data, document the data shape in artifacts (NOT the data itself if sensitive).

### ⛔ Gate 2 - Reproduction confirmed (HARD)

STOP. This gate is HARD - no overrides. Ask:

> Is reproduction confirmed? (yes - I can trigger it / partial - intermittent / no - cannot reproduce)

- `yes` -> status=`approved`, proceed.
- `partial` -> ask user if they accept investigating with partial repro (logs / traces only). Log the decision and risks to retro.
- `no` -> **REFUSE to proceed**. Tell the user: investigation without reproduction risks fixing the wrong thing. Options: gather more telemetry, add observability, or close as "cannot reproduce".

<!-- contract-lint: allow CL306 - logged insist-and-proceed keeps an audit trail via the constitution exception; it is described in prose, never offered as a selectable option -->
If the user insists on proceeding without repro, log a constitution exception to retro and proceed at their explicit risk acknowledgement.

---

## Phase 3 - Investigate

0. **Model escalation check.** At the start of every enumeration round (first entry, and each
   return from Gate 3a), apply rules `ESC-BUG-03` and `ESC-BUG-03b` of **sd-model-escalation**
   (read in Phase 0). Trigger inputs: the `severity` frontmatter field of
   `.specs/BUG-<arg>/00-spec.md`, and the number of exhausted hypothesis trees already recorded in
   `.specs/BUG-<arg>/03-decisions.md` by Gate 3a. The decision covers this round's step 1 and step 4
   `sd-debugger` calls.
1. Invoke `sd-debugger` (model: default, or as resolved by step 0) with:
   - `TASK = enumerate`
   - `SPEC_REF = .specs/BUG-<arg>/00-spec.md`
   - `REPRODUCTION = <reproduction section>`
   - `EVIDENCE_DIR = .specs/BUG-<arg>/04-artifacts/`
2. Debugger enumerates hypotheses per the **sd-hypothesis-tree** skill (5 mental models, `(Likelihood x Impact) / Cost-to-verify` ranking).
3. Main thread appends the returned hypothesis tree to `.specs/BUG-<arg>/03-decisions.md` (debugger has no write tool).
4. Loop:
   - Invoke `sd-debugger` (model as resolved by step 0) with `TASK = verify`, `HYPOTHESIS = <H#>`,
     `EVIDENCE_DIR = .specs/BUG-<arg>/04-artifacts/`.
   - Result: CONFIRMED / REJECTED / INCONCLUSIVE.
   - Main thread appends the result with evidence pointers (file:line, log lines, query results) to `03-decisions.md`.
   - Document REJECTED hypotheses with FULL reasoning - this is knowledge preservation for future similar bugs.
   - Terminate the loop when EITHER one hypothesis is CONFIRMED (proceed to Gate 3) OR every enumerated
     hypothesis is exhausted - all REJECTED, or only INCONCLUSIVE ones remain with no new evidence to act
     on (go to Gate 3a). Never guess a fix from an unconfirmed tree.

### ⛔ Gate 3a - Hypothesis tree exhausted (no confirmed root cause)

Reached ONLY when the loop ends with no CONFIRMED hypothesis. STOP. Do NOT proceed to a fix - a fix on an
unconfirmed root cause risks treating a symptom.

Main thread appends the exhausted tree (every hypothesis with its REJECTED / INCONCLUSIVE verdict
and reasoning) to `.specs/BUG-<arg>/03-decisions.md` - this is the knowledge record for the next
investigation.

Ask:

> All <N> hypotheses were rejected or inconclusive; no root cause confirmed. How do you want to proceed?
> (re-enumerate / observe / abort)

- `re-enumerate` -> return to Phase 3 step 0 with the new evidence/telemetry that justifies fresh
  hypotheses. Do not re-run identical hypotheses.
- `observe` -> add observability (logging, tracing, metrics), reproduce again to gather evidence, then
  re-enumerate. Log the gap to `05-retro.md`.
- `abort` -> set status=`in-progress` then `done` (the state machine has no approved -> done
  shortcut) and close the spec as "root cause not found"; record the exhausted tree as the
  outcome in `05-retro.md`.

### ⛔ Gate 3 - Root cause confirmed

STOP. Fill the Root cause section of `00-spec.md`:

```
Root cause: <named, fixable cause> (cite file:line)
Why this is root cause, not a symptom: <chain of reasoning>
```

Ask:

> Confirm root cause: <one-line summary>. Proceed to test+fix? (yes / dig deeper / abort)

- `yes` -> proceed.
- `dig deeper` -> loop more verification.

---

## Phase 4 - Write failing test FIRST

Main thread does this, NOT a subagent. The test must:

1. Live under `paths.tests` (from `.claude/project-config.json`), mirroring the source path per
   project convention.
2. Reproduce the symptom (must FAIL when run).
3. Be named for the bug, not the fix (example, adapt to project/language naming convention:
   "does not double-decrement when a transient failure is retried").
4. Be added to `00-spec.md` Regression test checklist.

Run the test once. Confirm it fails for the documented reason.

### ⛔ Gate 4 - Failing test confirmed

STOP. Display the test name and the failure output. Ask:

> Test fails AS EXPECTED (i.e. reproduces the bug)? (yes / no - adjust test)

- `yes` -> proceed.
- `no` -> revise the test until it correctly captures the bug.

---

## Phase 5 - Implement minimal fix

1. Set status=`in-progress`, update index.
2. Fill `00-spec.md` Fix approach (MINIMAL). Confirm scope-discipline checklist:
   - [ ] Touches only files implicated by root cause.
   - [ ] No "while I'm here" cleanups.
   - [ ] No reformatting unrelated code.
3. Invoke `sd-implementer` with:
   - `TASK_DETAILS = <fix approach + target files>`
   - `SPEC_REF = .specs/BUG-<arg>/00-spec.md`
   - `IMPACT_REF = .specs/BUG-<arg>/03-decisions.md` (investigation evidence)
   - `WORKFLOW_TYPE = bug`
   - `ROOT_CAUSE = <root cause statement>`
4. Implementer applies fix. Re-runs the failing test (now passing).

---

## Phase 6 - Regression + review

1. Run the full test suite via `commands.test`.
2. Run lint via `commands.lint`.
3. Invoke `sd-reviewer` with:
   - `TASK_TYPE = bug-fix-final`
   - `CHANGED_FILES = <files edited in Phase 5>`
   - `SPEC_REF = .specs/BUG-<arg>/00-spec.md`
   - `ROOT_CAUSE = <root cause>`
4. Reviewer checks: fix addresses ROOT CAUSE (not symptom), minimal, no scope creep, no HACK patterns, constitution compliant.

### ⛔ Gate 5 - Regression pass + review pass

STOP. Display:
- Test summary (must show the new test passing AND no regressions).
- Reviewer verdict counts.

Ask:

> All clean for BUG-<arg> close-out? (yes / address findings / abort)

- `yes` -> proceed.
- Any 🔴 BLOCK -> route to implementer, loop.

---

## Phase 7 - Close-out

1. Append to `05-retro.md`:
   - Root cause one-liner.
   - Lessons learned (focus on prevention).
   - Rejected hypotheses (knowledge preservation).
   - Constitution exceptions (should be none).
2. **Spawned specs**: re-read the lessons learned and rejected hypotheses just written to
   05-retro.md, plus anything the Scope discipline check pushed out of the fix - a systemic issue,
   a "while I'm here" cleanup deferred to a REF-* spec, a stale constitution section. For each one,
   ask the user to reserve an ID and add a row to `00-spec.md`'s `## Spawned specs` table
   (`Reserved ID | Type | Title | Owner`). This is a prompt, not a gate: nothing deferred, or the
   user declines - leave the table at header + separator and proceed. Do NOT create the child
   specs here, and do NOT add a reserved ID to `.specs/index.md`; an index row exists only once
   the real spec directory does (see `/sd:spec`, "Index <-> folder symmetry").
3. Set status=`done`, update index.

---

## Rules (hard constraints)

- Change `.specs/index.md` and any spec `status:` field with the Edit tool only - never a shell
  command (`sed -i`, `>`, `tee`, `Set-Content`). spec-gate checks an Edit-tool change (Rules 0,
  0b, 1) and records its `spec_transition`; a shell write skips both (SW-79).
- Reproduction (Gate 2) is HARD. No fix without repro.
- Root cause (Gate 3) is HARD. No fix without a named, fixable cause.
- Failing test FIRST (Gate 4). Never invert this order.
- Fix is MINIMAL. Opportunistic refactor goes into a separate REF-* spec.
- Rejected hypotheses are documented with reasoning, not deleted.
- **Model escalation follows `sd-model-escalation` only.** Rules `ESC-BUG-03` and `ESC-BUG-03b` are
  applied at Phase 3 step 0; the ladder, precedence, `models.escalation` config and the
  `05-retro.md` line format live in the skill and are not restated here.
- If the bug recurs after close-out, the original BUG-<arg> stays `done`; open a new BUG-* with cross-reference.
