# ADR 0038: /sd:feature counts criterion coverage before Gate 2

- Status: accepted
- Date: 2026-11-26
- Source spec: Jira SW-90 (`FEAT-plan-preflight`, E12 / SW-87)
- Relates to: ADR 0022 (outline, then expand); ADR 0030 (the S lane); ADR 0033 (off-option
  replies); ADR 0037 (port coverage count); Jira SW-134
- Supersedes: in part ADR 0037. The architect call in `/sd:port` Phase 6 step 5 changes from
  `TASK = refine` to `TASK = plan` with `UNCOVERED`.

## Context

SW-90 was deferred on 2026-10-25 because the SW-88 baseline found no coverage gap that could have
been detected at plan time. SW-134 then found one in e2e 17. A port plan left a criterion uncovered,
and `/sd:verify` caught it only at close-out. ADR 0037 added a main-thread count before port Gate
4. It left `/sd:feature` alone, which still relied on the architect checking its own coverage. The
first counted check there was `VF010`/`VF011` in Phase 6, after all the code was written.

Implementing the same count in `/sd:feature` brought up two more defects:

1. **`refine` cannot fix a plan.** Mode 3 (`TASK = refine`) of `sd-spec-architect` may edit
   `00-spec.md` only. ADR 0037's port step 5 used it to fix `02-tasks.md`, so the fix relied on the
   model going beyond its contract. Mode 2 (`plan`) had no input for feedback.
2. **A refused `yes` read as approval.** Port Gate 4, port Gate 2 and now feature Gate 2 refuse
   `yes` while a count is above 0, but nothing said how to record the refused reply. The stop-gate
   counts any `Reply:` token outside its deny list as approval (ADR 0033), so `Reply: yes` on disk
   would have counted as a passed gate.

## Decision

**The main thread counts coverage before every Gate 2 face and before Face S.** A `Coverage count`
step in Phase 3 computes `uncovered`: the `SC-<n>` and `AC-<n>` of `00-spec.md` that no `## Outline`
row lists in `Covers`. It uses the parsing shapes of `/sd:verify`. A legacy plan with no outline is
counted on its task blocks. The step runs whenever a Gate 2 face or Face S is presented, so a
resumed `outline-drafted` spec is counted too, and the state machine gains no row. When the count is
above 0, the architect is invoked once more, then the count is taken again. The gate questions show
`<C> criteria with no task`. `yes` on Face A and Face S, and `no-split` on Face B, are refused while
`<C>` is above 0. `approve split` stays open, because the decompose proposal assigns every
criterion to a child. Gate 2 stays an ordinary gate, and the gate count does not change.

One re-invocation, not the ticket's two rounds, to match ADR 0037. The gate's `refine` keeps the
loop open to the user.

**The re-invocation is Mode 2 with a new optional input, `UNCOVERED`.** It is passed with the same
`SPEC`, `IMPACT`, `STEP` and `LANE` as the first call. With `STEP = outline` the architect edits the
`## Outline` table, either widening a row's `Covers` or adding a row, and runs the complexity
self-assessment again, so an S-lane breach still falls back. With no `STEP` (port) it revises only
the task blocks that must change. It never edits `00-spec.md`. `UNCOVERED` is never passed after
approval: from then on, the outline is immutable and a gap goes through Gate Re-plan. Port Phase 6
step 5 moves to the same call.

Two alternatives were rejected:

- **Keep `refine` and widen Mode 3.** Mode 3 would then edit specs and plans, and its one rule
  ("edit `00-spec.md` to apply only what `FEEDBACK` requests") would stop being true.
- **A new `SL0xx` rule in `/sd:spec validate`.** This is the path ADR 0037 also rejected. The
  count is two set operations the command already describes, and a lint rule costs four edits.

**A refused reply is recorded as `refused`.** sd-gate-brief records a valid reply that a gate
refuses by count as `Reply: refused - <reply verbatim> (<the count>)`, and the section stays open.
Both stop-gate twins add `refused` to every deny list, so the marker is never read as approval.
This is the counterpart of ADR 0033's `unrecognized`: one marks a reply that is not an option, the
other an option the gate did not accept.

## Consequences

- An outline that leaves a scenario or criterion uncovered can no longer pass Gate 2 or Face S with
  `yes`, and the user sees the gap before any code is written. `VF010`/`VF011` in Phase 6 stay as
  a second line of defence, and the Phase 6 Re-plan route is unchanged.
- Every feature Gate 2 and Face S question line gains a count, and the brief gains one line. The
  brief cap still holds.
- The port coverage call now runs within the architect's contract. Port's Gate 4 question and
  rules are unchanged.
- A session that writes `Reply: yes` despite the refusal is not caught by the stop-gate. The rule
  is in the skill, as the `unrecognized` rule is.
- New stop-gate fixtures: `block-feat-g2-refused-only`, `allow-feat-refused-then-yes` and
  `block-port-g4-refused-only`.
