# sd-spec-templates

Per-template authoring rules for specwright. Used by `sd-spec-architect` when `TASK = create`.
Each template has a dedicated section below. Read only the section matching the spec type being authored.

---

## Common rules (apply to all templates)

- Output goes to the **file**, not to the prose response. Response = one-paragraph summary + file path.
- Follow the template structure **exactly** — sections, order, headings. Reordering breaks downstream agents.
- Cross-phase fields carry a `<<PHASE-N: description>>` token. Leave the token **verbatim** — do
  not pre-fill it, do not delete it. Phase N of the owning workflow replaces it with measured
  evidence. `/sd:spec validate` fails a `draft` or `approved` spec whose phase-deferred tokens are
  already filled, so pre-filling is caught, not just discouraged.
- Author-fill fields use the plain `<<description>>` token and must be replaced before `approved`.
- `created` = current UTC date in `YYYY-MM-DD`.
- If anything is genuinely uncertain, surface as an **Open question** — never silently allow.

### Required frontmatter fields

| Type | Fields |
|---|---|
| All | `id`, `type`, `status: draft`, `created`, `linked_specs` |
| Feature | `jira` (or `none`), `complexity` (`S` \| `M` \| `L`) |
| Bug | `severity` (P0–P3), `jira` |
| Refactor | `smell` |
| Perf | `target_metric` |
| RCA | `severity`, `incident_started`, `incident_resolved` |
| Port | `jira` (or `none`), `scope` (`endpoint`\|`module`\|`feature`\|`pattern`), `source_repo`, `source_commit`, `source_license`, `snapshot` (`contract`\|`contract+source`) |

`linked_specs` is always `[]` at authoring time. Cross-references are written later by
`/sd:spec link`, which maintains the inverse entry on the other spec — never hand-write the list,
and never add a "Linked specs" body section. A one-sided link fails `/sd:spec validate`.

---

## feature.template.md

Fill:
- **Why** — one paragraph, quantify impact if possible.
- **What** — Given/When/Then scenarios: happy path, edge cases, failure modes.
- **Success criteria** — concrete and checkable (observable test outcome, not "works correctly").
- **Out of scope** — explicit list; prevents scope creep disputes.
- **Open questions** — real ambiguities only; don't pad.
- **`complexity` frontmatter** — the whole-spec size estimate, `S` | `M` | `L`, with a one-line
  rationale in the trailing comment. See "Complexity estimate" below.

**Leave empty**: `## Spawned specs` — header + separator only, no rows and no `<<...>>` token. It
mirrors `rca.template.md`'s four-column table and is filled at close-out by the owning workflow,
not at create time. A reserved ID is a placeholder, never an `.specs/index.md` row.

- Scenario headings use stable IDs: `### SC-<n>: <name>`. IDs are sequential from SC-1 and are
  never renumbered or reused after a scenario is deleted - downstream `Covers` fields and
  `/sd:verify` reports reference them.
- Success criteria use stable IDs: `- [ ] AC-<n>: <criterion>`. Same stability rule as SC IDs.
- Every SC and AC ID must be covered by at least one task's `Covers` field in `02-tasks.md`
  before `/sd:verify` can pass (see sd-atomic-task-format).

Constitution check: list applicable `§N.M` references. Flag any potential violation as an Open question.

### Complexity estimate (feature only)

The `complexity` frontmatter field is the architect's whole-spec size estimate. It exists to route
oversized work into the regime the engine handles well: at Gate 2, `/sd:feature` measures the real
plan against the thresholds below and, if the plan exceeds them, refuses a single oversized plan and
forces a decompose into medium child specs (see `commands/feature.md`, Gate Complexity).

**`complexity` is a spec-level field. It is NOT the same as a task's `Estimated complexity`
field in `02-tasks.md`.** The task field sizes one line item; this field sizes the whole feature.
They share the `S` | `M` | `L` vocabulary on purpose (one house currency) but answer different
questions. Never conflate them.

**Estimate at create, measure at plan.** At `create` the architect has only Why / What / SC / AC /
Open questions — no plan yet — so `complexity` is an honest *estimate*, written with a one-line
rationale. It is not a measured field, so it is a plain author-fill token, not a `<<PHASE-N: ...>>`
token, and it is filled at create time. Phase 3 is where the plan is *measured* against the
thresholds; the create-time estimate does not have to be re-derived, but it must be a genuine
judgement, not always `M`.

Rubric for the estimate:

| Value | Guideline (estimate) |
|---|---|
| `S` | One layer, a handful of tasks (≈1-4), single subsystem, no unresolved Open questions. |
| `M` | Up to 2 layers, ≈5-8 tasks, one boundary crossing. The regime the engine plans well. |
| `L` | Spans > 2 production layers/subsystems, likely > 8 tasks, or carries unresolved Open questions at plan time. Candidate for decomposition. |

**Decompose thresholds (measured at Gate 2).** A plan is over-threshold when **any** of these hold:

- estimated/authored tasks **> 8**
- spans **> 2** production layers/subsystems — count the distinct `Layer` values across tasks, but
  **exclude `Tests` and `Config`**: they cross-cut nearly every change, so counting them would make
  an ordinary 2-layer feature (e.g. `Application` + `Domain` + `Tests`) read as 3 and over-fire
- impact surface **> 8** files (from `03-decisions.md`)
- **any** unresolved Open question remains at plan time

The `> 8` task line is set from the only live corpus (`asian-sportsbook-v2`): real feature specs
cluster at 3-4 tasks (medium) and 10-12 tasks (the two specs a human had already hand-split into a
parent + child), with nothing in between — `> 8` sits in that canyon, so mediums pass untouched and
the genuinely large trip the gate. The Tests/Config exclusion is set from the same corpus: the
3-4-task mediums touch `Application` + `Domain` + `Tests`, so a naive layer count would have tripped
the gate on exactly the specs that must pass with zero friction.

**Count tasks with the tolerant grammar, never a naive regex.** When measuring the task count, use
the **Field label / heading grammar** the way `sd-atomic-task-format` describes — live specs write
task headings as `### T01`, `### ✅ T01`, and other drifted forms. A counter that matches only
`^### T<NN>` undercounts real specs and the gate silently never fires. Match tolerantly: a task
heading is an H3 (or deeper) whose text contains a `T<digits>` token.

**A create-time estimate of `L` also escalates models** — `/sd:feature` applies the
**sd-model-escalation** rules that read it. That is a main-thread action; the architect only writes
the estimate.

---

## bug.template.md

Fill:
- **Symptom** — observed behavior.
- **Expected** — correct behavior.
- **Reproduction** — deterministic steps (numbered list).
- **Affected** — components, scope, first introduced (version / PR if known).
- **Severity** — P0 (production down) / P1 (major feature broken) / P2 (partial degradation) / P3 (minor).

**Leave empty**: Root cause section, Fix approach section, `## Spawned specs` (header + separator
only, no `<<...>>` token) — the first two are filled in Phase 3 (debugger) and Phase 5 (main thread
+ implementer); `## Spawned specs` is filled at close-out by the owning workflow. Pre-filling
breaks the workflow gate discipline.

---

## refactor.template.md

Fill:
- **Smell / Driver** — named code smell or architectural reason.
- **Current state** — high level. Code-explorer fills detailed impact in `03-decisions.md`.
- **Target state** — the intended structure after refactor.
- **Invariants — MUST preserve** — concrete and checkable; each invariant gets a test witness.
- **Out of scope** — explicit.

Leave TBD:
- **Impact surface** — Phase 2 explorer fills.
- **Test coverage prerequisite measurements** — Phase 3 fills.
- **`## Spawned specs`** — header + separator only, no `<<...>>` token; filled at close-out by the
  owning workflow, not at create time.

Public API: preserved by default. Any public API change requires explicit mention in the spec.

---

## perf.template.md

Fill:
- **Target** — metric (e.g. `p95 latency`), goal SLA (e.g. `< 200ms`), environment, load profile, workload type.
- **Measurement methodology** — tool, script, warm-up rounds, duration, reps, DB state, cache state.
- **Constraints** — correctness non-negotiables, behavioral invariants, forbidden side effects.
- **Out of scope**.

Leave empty:
- "Current observed" in Target table — filled by Phase 2 baseline measurement.
- **Results log** — filled iteratively in Phase 4.
- **Hypothesis tree** — filled by debugger in Phase 3.
- **Trade-offs accepted** — filled at close-out.
- **`## Spawned specs`** — header + separator only, no `<<...>>` token; filled at close-out.

---

## rca.template.md

Produce skeleton only. The following are filled **interactively** by the main thread with user input in Phase 1 — do NOT pre-fill them:
- Timeline
- Symptoms
- Affected scope
- Recent changes

Leave TBD (filled by later phases):
- Hypothesis tree (Phase 2 debugger)
- Root cause (Phase 3 verification)
- Affected components, Mitigation, Follow-up actions, Spawned specs, Lessons learned

Spec ID format: `RCA-<slug>-<YYYYMMDD>` using UTC date.

---

## port.template.md

`source_repo` / `source_commit` are required **values**, not just present fields, when `scope` is
not `pattern` (write `none` for `pattern`). The three fidelity tables - Path mapping table, Member
manifest, Deviation table - and the mandatory fidelity acceptance criterion (`AC-1`, pre-filled,
never reworded or renumbered) are owned by **sd-port-fidelity**: read that skill for the column
schemas and completeness conditions rather than re-deriving them here.

Fill:
- **Why**, **Donor provenance**, **Behavioral contract** (fixed 7-row table), **Success criteria**
  `AC-2` onward, **Out of scope**, **Open questions**.
- **`## Behavioral invariants (non-obvious)`** is mandatory even when short and must never be
  deleted - it is the single highest-value section in the spec.
- **`## Spawned specs`** mirrors `rca.template.md`'s 4-column table: one row per donor defect
  reproduced deliberately, not per sanctioned deviation.

**No `<<PHASE-N: ...>>` tokens exist for this template** (same as `feature.template.md`) - the
fidelity tables and `Frozen:` line are progressively filled by `sd-spec-architect` `refine` calls
and main-thread edits across `/sd:port`'s phases, not gated by phase-deferred tokens. Do not invent
one.

Spec ID format: `PORT-<slug>-<YYYYMMDD>` using UTC date.

---

## Anti-patterns

- Filling cross-phase fields prematurely (bug root cause, perf results log, rca root cause).
- Reordering sections in the template output — downstream agents key off section headers.
- Hardcoding stack assumptions — always read `CLAUDE.md` first; never default to a stack from prior invocations.
- Producing the spec text in the prose response — write to the file; return only the summary + path.
- Glossing over a constitution violation — if §1.1 is at risk, that is an Open question.
- Inventing a line-range column in the port member manifest — line ranges live only in
  `04-artifacts/source/MANIFEST.md`, keyed by `(Snapshot path, Ordinal)`.
