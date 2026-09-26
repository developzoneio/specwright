# ADR 0002: complexity triage forces decomposition through a conditional face of Gate 2

- Status: proposed
- Date: 2026-07-22
- Source spec: Jira SW-13 (`FEAT-complexity-triage`); plan at
  `_bmad-output/SW-13-implementation-plan.md`
- Supersedes: none

## Context

External-user feedback: `sd-spec-architect` is accurate on medium tasks but degrades on complex
ones. The cause is structural, not model quality. Two things compound:

1. **Single-pass planning.** One `TASK = plan` invocation authors the full `01-plan.md` +
   `02-tasks.md`. Sequencing, dependency-graph, and Pattern-refs quality drop non-linearly as scope
   grows.
2. **A shallow impact map.** The `haiku` explorer's `03-decisions.md` is thin on multi-subsystem
   features, so the plan is built on a weak foundation before the architect even starts.

The measured evidence names the shape of "complex". In `asian-sportsbook-v2`, the only live repo
running specwright, feature specs cluster at **3-4 tasks** (`FEAT-ASF-245`, `FEAT-ASF-246`) and at
**10-12 tasks** (`FEAT-ASF-251` and `FEAT-ASF-251-LeagueContainer`) - with nothing in between. The
two large ones matter twice over: they share one Jira key (`ASF-251`), created the same day, so a
human **had already hand-decomposed** one ticket into a parent + child. The pain and the workaround
both exist on disk; SW-13 paves that cowpath.

The same corpus repeats SW-11's lesson. Task headings are written `### T01` in one spec and
`### ✅ T01` in another; a naive `^### T<NN>` counter reads the second as **zero tasks** and the
gate silently never fires. Any task-count heuristic must reuse the tolerant grammar from
`skills/sd-atomic-task-format/SKILL.md`.

## Decision

`/sd:feature` gains complexity triage, governed structurally (a gate), not by prose exhortation.

1. **A spec-level `complexity` frontmatter field** (`S` | `M` | `L`) with a one-line rationale,
   written by the architect at `create`. It reuses the `S|M|L` vocabulary of a task's
   `Estimated complexity` but is a **different field at a different altitude** (whole spec vs. one
   line item); the skill names the distinction so the two are never conflated.
2. **Estimate at create, measure at plan.** `complexity` is an honest estimate at create time (no
   plan exists yet), so it is a plain author-fill token, not a `<<PHASE-N: ...>>` deferred token.
   Phase 3 measures the *actual* plan against the decompose thresholds.
3. **Decompose thresholds**, any of which trips the gate: tasks **> 8**, spans **> 2** production
   layers (distinct `Layer` values, **excluding `Tests`/`Config`** - they cross-cut every change),
   impact surface **> 8** files, or an unresolved Open question at plan time. `> 8` is set from the
   corpus canyon between the 3-4 and 10-12 clusters; the Tests/Config exclusion is set from the same
   data, where the 3-4-task mediums touch `Application` + `Domain` + `Tests` and a naive layer count
   would have tripped the gate on exactly the specs that must pass friction-free.
4. **Gate Complexity is a conditional face of Gate 2, not a fourth gate.** Under threshold, Gate 2
   is the plan approval it has always been - zero added friction for the median 3-task spec. Over
   threshold, the same gate becomes a HARD decompose approval: the architect refuses one oversized
   plan and proposes 2+ child specs that partition the parent's SC/AC, with a dependency order.
5. **Sanctioned model escalation, aliases only.** A create-time `complexity: L` bumps the explorer
   to `sonnet` (Phase 2, deeper map) and the architect to `opus` (Phase 3, harder plan). This is the
   escape hatch for the legitimately-atomic large spec that does not partition cleanly. The bump is
   a per-invocation main-thread override, mirroring the existing `sd-implementer` sonnet override;
   no agent's `model:` frontmatter changes, and no full model ID is introduced.
6. **The parent becomes an immutable umbrella.** On split, the parent goes `archived` with a retro
   note naming its children; its spec/plan/tasks are never edited to match the split. Children are
   normal feature specs, linked with the existing `/sd:spec link spawns` / `depends-on` machinery -
   no bespoke decomposition mechanism is invented.

## Consequences

**Positive.** Complex work is forced into the medium regime the engine already plans well, instead
of producing one degraded oversized plan. The create-time estimate does double duty: it is both the
field SW-4 will validate and the trigger that deepens the impact map *upstream* of the gate,
addressing both root causes rather than only the planning one. Decomposition reuses link relations
that already exist, so the parent/child graph is queryable by every tool that already reads
`linked_specs`.

**Negative.** The `S|M|L` vocabulary now names two different things (spec vs. task); the skill
carries the disambiguation, and a careless reader can still conflate them. Gate 2 is now a branch,
not a straight line - more logic to reason about at the one gate authors hit every run. The child
IDs (`FEAT-<parent-arg>-<child-slug>`) grow a naming convention that must stay stable, borrowed from
the corpus (`FEAT-ASF-251-LeagueContainer`).

**Unresolved.** Like `SL060`, the gate is **model-executed prose** with no CI coverage - no script
in this repo drives a `/sd:feature` run, so nothing exercises the threshold arithmetic or the
tolerant task count automatically. The conformance evidence is a manual trace (a 3-task corpus spec
stays under; a 10-12-task one trips), recorded rather than automated. A check that cannot fail is a
failure mode this repo has shipped before (SW-20); this one is asserted by trace, not by runner.
**Update (SW-63):** decision 5's escalation policy now has a statement-consistency check -
contract-lint `CL601`-`CL605` and `scripts/validate-escalation-lines.*` (ADR 0014). The threshold
arithmetic, and whether a subagent was served the escalated model, remain uncovered by CI.

**Scope declined.** SW-13 does **not** add an `SL` lint rule. The `complexity` field is frontmatter,
so validation is `SL00x` territory, not the `SL06x` task-block band SW-11 reserved - there is no
collision to pre-empt and nothing to reserve here. The acceptance criteria assign linting of the
`complexity` field and split integrity to **SW-4** (`/sd:spec validate`), which owns it later. This
ADR records that hand-off; building it inside SW-13 would duplicate SW-4's job. Mid-execution
re-planning is also out of scope (a separate v2 epic) - triage here is pre-execution only.
