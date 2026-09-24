---
description: Incident root-cause analysis. Output IS the spec - NO code change in this workflow. 3 hard gates.
argument-hint: <incident-slug>
---

# /sd:rca

Drives an incident analysis from raw signals to a documented root cause, recorded under `.specs/RCA-<slug>-<YYYYMMDD>/`. **No code is changed in this workflow.** Fixes spawn separate `BUG-*` / `REF-*` / `PERF-*` specs (reserved IDs are recorded under the RCA's "Spawned specs" section).

**Argument**: `$ARGUMENTS` -> spec ID = `RCA-<slug>-<YYYYMMDD>` (date stamp ensures uniqueness for slug reuse).

---

## State machine (resume behavior)

| Detected state | Action |
|---|---|
| Folder not found | Start at Phase 1 |
| `00-spec.md` exists, Timeline / Symptoms empty | Resume Phase 1 |
| Signals gathered, hypothesis tree empty | Resume Phase 2 |
| Hypothesis tree exists, no CONFIRMED entry | Resume Phase 3 |
| Root cause documented, no Mitigation entry | Resume Phase 4 |
| Mitigation documented, no Follow-up actions | Resume Phase 5 |
| status `done` | Refuse; suggest viewing with `/sd:spec show RCA-...` |

---

## Phase 0 - Bootstrap

1. Read `~/.claude/skills/sd/sd-bootstrap-guard/SKILL.md` and apply it before anything else here -
   it owns the Layer-2 reads and all of their messages (commands cannot load skills via
   frontmatter, so it is read at runtime). If that file is unreadable, STOP: "specwright install
   incomplete - bootstrap guard skill not found under `~/.claude/skills/sd/`. Re-run the installer."
2. Compute current UTC date for the spec ID stamp.
3. Detect state. Print resume plan.

---

## Phase 1 - Gather signals (interactive)

This phase is conversational. The user has the raw evidence; the workflow turns it into structured timeline + symptoms.

1. Invoke `sd-spec-architect` with:
   - `TASK = create`
   - `TEMPLATE = rca.template.md`
   - `SPEC_ID = RCA-<slug>-<YYYYMMDD>`
2. Architect produces skeleton with empty Timeline, Symptoms, Affected scope, Recent changes.
3. Main thread walks the user through:
   - **Timeline** - chronological events, UTC, sub-minute granularity if available.
   - **Symptoms observed** - specific error rates, status codes, queue depths, customer reports.
   - **Affected scope** - services / endpoints / users / revenue.
   - **Recent changes** - everything deployed or configured in the 72 hours before the incident.
4. Main thread saves the evidence (logs, screenshots, query results, dashboards) under `.specs/RCA-<slug>-<YYYYMMDD>/04-artifacts/` with descriptive filenames. Each artifact referenced from the timeline.

### ⛔ Gate 1 - Evidence gathered

STOP. Display the populated Timeline, Symptoms, Affected scope, Recent changes. Ask:

> Evidence is sufficient to enumerate hypotheses? (yes / gather more / abort)

- `yes` -> status=`draft` (RCA stays draft until root cause confirmed), append to index, proceed.
- `gather more` -> loop with user on missing pieces.

---

## Phase 2 - Hypothesis enumeration

1. Invoke `sd-debugger` with:
   - `TASK = enumerate`
   - `SPEC_REF = .specs/RCA-<slug>-<YYYYMMDD>/00-spec.md`
   - `EVIDENCE_DIR = .specs/RCA-<slug>-<YYYYMMDD>/04-artifacts/`
   - `MODE = incident`
2. Debugger enumerates hypotheses per the **sd-hypothesis-tree** skill (5 mental models,
   `(Likelihood x Impact) / Cost-to-verify` ranking).
3. Main thread appends the returned hypothesis tree to `00-spec.md` "Hypothesis tree" section (debugger has no write tool).

### ⛔ Gate 2 - Hypotheses enumerated

STOP. Display the ranked hypotheses. Ask:

> Hypothesis tree complete? (yes / add hypothesis / refine ranking / abort)

- `yes` -> proceed.
- `add hypothesis <text>` -> loop with debugger.
- `refine ranking` -> loop.

---

## Phase 3 - Verify loop

For each hypothesis in rank order:

1. Invoke `sd-debugger` with:
   - `TASK = verify`
   - `HYPOTHESIS = <H#>`
   - `EVIDENCE_DIR = .specs/RCA-<slug>-<YYYYMMDD>/04-artifacts/`
2. Debugger gathers evidence (logs, queries, code reads). Database access (via the project's MCP
   tool or CLI) is **SELECT / EXPLAIN only** - never UPDATE / DELETE / INSERT.
3. Result: `CONFIRMED` / `REJECTED` / `INCONCLUSIVE`. Main thread appends the result with evidence pointers to "Verification results (Phase 3)" (debugger has no write tool).
4. Main thread documents each REJECTED result with FULL reasoning. This is knowledge preservation.
5. Continue until one hypothesis is `CONFIRMED`.

### ⛔ Gate 3 - Root cause confirmed

STOP. Fill the Root cause section. Must be:
- A named, fixable cause (not a symptom).
- File:line citation where applicable.
- Reasoning under "Why this is root cause (not symptom)".

Ask:

> Confirm root cause: <one-line>. Proceed to mitigation documentation? (yes / dig deeper / abort)

- `yes` -> status=`approved`, proceed.
- `dig deeper` -> back to Phase 3, additional hypotheses if needed.

---

## Phase 4 - Isolate + document

1. Set status=`in-progress`, update index.
2. Fill in `00-spec.md`:
   - **Affected components** - file:line, service names, config keys.
   - **Why this is root cause** - the "why" chain (use 5-whys discipline; stop when answer is fixable).
3. Fill **Mitigation applied** - what stopped the bleeding. Reference timestamps from Timeline.
4. Note: mitigation IS NOT a fix. It is the immediate action that contained the impact. The actual fix lands in a spawned BUG-* spec.

No gate here - documentation-only phase.

---

## Phase 5 - Follow-up actions

1. Fill **Follow-up actions** with 4 buckets:
   - **Immediate (P0 hotfix)** - usually the actual code fix, spawned as BUG-*.
   - **Short-term (within sprint)** - test additions, observability, audits.
   - **Long-term (next quarter)** - process changes, coverage gates, training.
   - **Knowledge capture** - constitution amendments, glossary entries, runbook updates.
2. Reserve spec IDs for each spawned spec. List them in **Spawned specs** table with title + owner.
3. Note: this command does NOT create the spawned specs. The user runs `/sd:bug <ID>`, `/sd:refactor <slug>`, etc. separately. The RCA captures intent + reserved IDs.
4. Fill **Lessons learned** (3-5 takeaways, honest):
   - What we did well.
   - What we did poorly.
   - What we got lucky on.
5. Set status=`done` in frontmatter. Update `.specs/index.md`.
6. Append to `05-retro.md`: RCA duration, evidence completeness, any data the team could not access.
7. Print summary:
   - Root cause one-liner.
   - Spawned spec IDs.
   - Top 3 lessons.

---

## Rules (hard constraints)

- **No code is changed in /sd:rca.** Period. If the user asks "while we're here, can you fix it?" -> redirect to `/sd:bug <ID>` after this workflow completes.
- Reproduction is rarely possible for incidents (the incident is over). Verification relies on logs, traces, queries, and code reads from the relevant time window.
- All evidence lives under `04-artifacts/` with descriptive filenames. Never reference "the dashboard" - save a screenshot or query.
- Rejected hypotheses are documented in full. They are as valuable as the confirmed one for future incidents.
- Database access (via the project's MCP tool or CLI) is SELECT / EXPLAIN only. Any UPDATE attempt is a constitution violation.
- The Spawned specs section is a CONTRACT. Each reserved ID should be created within the agreed timeline; if not, log to retro.
- RCAs do not get a `revive` action. New incident -> new RCA.
