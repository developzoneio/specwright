# sd-replan-loop

Sanctioned mid-execution re-plan protocol for specwright. Lets a workflow adapt when execution (or
the batch review) reveals that `02-tasks.md` is wrong, **without** violating spec immutability or
skipping a gate. Referenced at runtime by `/sd:feature` and `/sd:refactor` - the only two workflows
that produce a `01-plan.md` + `02-tasks.md` pair to re-plan.

Not used by `/sd:bug`, `/sd:perf`, or `/sd:rca`: bug and rca produce no atomic task list, and perf
already carries its own adaptive loop (Phase 4 reverts a failed hypothesis and re-selects at Gate 4).

---

## The problem this solves

The Planning pattern's strength is **adaptivity** - re-planning when execution surfaces new
information. specwright's immutability rule is right for audit, but it left the adaptive path
**undefined**: when an implementer discovers mid-Execute that a task's premise is false, or the batch
review finds the plan itself was wrong, there was no sanctioned move. The failure mode is a model
silently hack-editing `02-tasks.md` (violating sequencing, leaving no trail) or stalling.

The discovery point is **not only mid-task**. In the one measured corpus, the single real case of a
wrong plan surfaced at **batch review**: an implementer found a spec decision was wrong, hand-edited
the task, corrected the spec, and left one sentence in the retro - no gate, no append-only record.
The re-plan gate must be reachable from **both** the Execute phase and the review phase.

`/sd:feature` adds a third entry point (ADR 0022): its Phase 3b expands the task outline that Gate 2
approved into full task blocks, and expansion can show that an approved row cannot be carried out
as written. That is a plan-invalidating discovery too, and it goes through this gate before any
task block is written.

---

## What counts as a plan-invalidating discovery

A re-plan is warranted only when the **plan** is wrong, not when a single task needs a normal
implementation adjustment. Trigger the loop when:

- A task's stated premise is false - a `Pattern refs` precedent does not exist, an interface differs
  from what the task assumed, a `Depends on` edge is backwards, or the `Files` list cannot carry the
  change.
- A task is now known to be missing, redundant, or mis-sequenced given what execution revealed.
- The batch review (feature Phase 5, refactor Phase 6) finds the plan itself is wrong - the classic
  case: a spec/plan decision that only proves incorrect once the code is written.
- `/sd:feature` Phase 3b finds a **material divergence** from the approved outline (`## Outline` in
  `01-plan.md`, per `sd-atomic-task-format` "Outline row"): a row whose expanded block needs a
  different `Files` set or `Covers` set, a row that has to be split, merged or dropped, or a task the
  outline lacks. Rewording a title or filling the block's other fields is expansion, not divergence.

Do **not** trigger the loop for work that stays inside one task's contract (a rename, a helper reuse,
a test tweak). That is ordinary implementation, handled by the implementer's own scope. Re-planning
is for changing the **plan**, not for doing the task.

---

## Gate Re-plan (HARD)

When a plan-invalidating discovery lands, the workflow returns to this gate. It is HARD - it STOPS
and waits for explicit user approval; silence is not approval, and there is no override path.

1. **Surface the trigger.** Present to the user: what was discovered, which task(s) it invalidates,
   and the proposed delta. Ask:

   > Re-plan `<SPEC-ID>`? Discovery: `<trigger>`. Affects `<task IDs>`. (approve / revise `<feedback>` / abort task)

   - `approve` -> proceed to step 2.
   - `revise` -> adjust the proposed delta and re-ask. Loop.
   - `abort task` -> do not re-plan; return to the workflow's normal abort handling for that task.

2. **Append a revision entry to `01-plan.md`** (never rewrite prior content - see format below).
   Assign the next contiguous revision number `R<n>`.

3. **Regenerate only the affected tasks in `02-tasks.md`.** Invoke `sd-spec-architect` with
   `TASK = plan`, `REPLAN_SCOPE = <affected task IDs>`, and `REVISION = R<n>`. The architect
   rewrites only those task blocks, marks each with `Revised-by: R<n>` (per `sd-atomic-task-format`),
   and leaves every other task block byte-for-byte unchanged.

   From `/sd:feature` Phase 3b, `02-tasks.md` does not exist yet. The invocation also passes
   `STEP = expand`: the architect writes the whole file in one pass, expands every row outside
   `REPLAN_SCOPE` exactly as the outline approved it, and writes the affected tasks per the approved
   delta, each marked `Revised-by: R<n>`. The `## Outline` table itself is never edited.

4. **Resume.** Re-enter the Execute phase at the first affected (now regenerated) task. Already-passed
   tasks that the revision did not touch stay checked. From Phase 3b, the Execute phase starts at
   its first task, as it would after any expansion.

---

## The `## Revisions` log (`01-plan.md`)

Append-only. Lives at the **end** of `01-plan.md`, below the original plan prose. The original plan
text - approach, design decisions, risks, outline - is **never edited**; a re-plan only appends
here. Create the `## Revisions` header on the first revision.

```markdown
## Revisions

### R1 - <UTC ISO 8601 timestamp>

- Trigger: <the discovery that invalidated the plan - one or two lines>
- Phase: <execute | review | expand>
- Gate: re-plan
- Affected tasks: <T## list>
- Delta: <what changed in those tasks and why>
- revised-from: <one-line pointer to the original intent - what the tasks assumed before>
```

Rules:

- **Contiguous numbering.** Revisions are `R1`, `R2`, `R3` ... with no gaps and no reuse. `R<n>`
  never appears twice.
- **Append-only.** A prior `R<k>` entry is never edited or deleted. A later correction is a new
  entry that supersedes it in prose, never a rewrite.
- **Every entry names a gate event.** The `Gate: re-plan` and `Phase:` lines record that the entry
  came through this gate, not from a hand-edit. An entry with no gate/phase line is malformed.
- **Symmetry with tasks.** Every `Affected tasks` ID in `R<n>` must name a task block in
  `02-tasks.md` that carries `Revised-by: R<n>`, and every task carrying `Revised-by: R<n>` must be
  listed in entry `R<n>`. `/sd:spec validate` enforces this both ways (`SL070`-`SL073`).

---

## Immutability boundary

- **Never re-plan a `done` spec.** The loop runs only while the spec is `in-progress`. In-progress
  specs are mutable by definition; this protocol never touches a `done` (or `archived`) spec.
- **The original plan prose is intact.** Only the `## Revisions` section grows. That includes the
  approved `## Outline` table: a divergence from it is recorded here, never by editing a row.
- **Regenerated task blocks are replaced in place** in `02-tasks.md`; their history lives in the
  `## Revisions` log and the `revised-from` pointer, not in stale text left behind.

---

## What validate can and cannot see (honest scope)

`/sd:spec validate` is a **static linter** over `.specs/`. It has no snapshot of `02-tasks.md` as it
stood at Plan phase, so it **cannot** detect an arbitrary silent edit by diffing. What it enforces is
the **internal consistency of the revision record** (`SL070`-`SL073`): a task marked `Revised-by: R<n>`
with no backing entry, an entry naming tasks that do not carry the marker, non-contiguous or rewritten
history, a malformed entry. A compliant re-plan always marks its work, so the linter catches a
**broken record**; an unmarked hack-edit stays invisible to the linter and is prevented by the gate,
not the lint. State this boundary plainly - do not imply the linter diffs the file.
