# sd-gate-brief

Gate brief discipline for specwright workflows: what a gate shows the user, where that text is
kept, and how every user-facing line is worded. This file is the single owner of the brief
artifact, its language, the per-gate shapes, the decision ranking rule, the `details` targets,
the agent return blocks and the narration rule. `/sd:feature`, `/sd:bug`, `/sd:refactor`,
`/sd:rca`, `/sd:perf` and `/sd:port` read it at runtime in Phase 0 (commands cannot load skills
via frontmatter) and name only where each rule applies; **sd-replan-loop** names it at Gate
Re-plan. `sd-spec-architect` and `sd-reviewer` load it via `skills:` so they know the block they
return.

Origin: ADR 0018 ("Gate brief artifact"), Jira SW-89; extended by ADR 0019 (details targets,
brief language, plan-face decisions), Jira SW-102, and ADR 0020 (printed means reply text, the
closing summary, phase narration), Jira SW-99, and ADR 0022 (task rows and `details` from the
outline), Jira SW-92, and ADR 0024 (the `/sd:bug` gates), Jira SW-96, and ADR 0025 (the
`/sd:refactor` gates, `details` at Gate Re-plan), Jira SW-109, and ADR 0026 (the `/sd:rca` gates),
Jira SW-111, and ADR 0027 (the `/sd:perf` gates), Jira SW-110, and ADR 0028 (the `/sd:port`
gates), Jira SW-112, and ADR 0030 (the combined S-lane brief), Jira SW-94. Measured "before":
`docs/spikes/SW-88-feature-baseline.md`.

---

## Why a brief

A gate asks the user to approve an artifact set that grows faster than the decisions in it (SW-88:
one real decision per 161 lines of plan in a 6-task run). The brief puts the decisions first,
caps what is shown, and keeps the shown text on disk, because a session can report that it
presented a gate without printing a line of it.

## The artifact

- Path: `<spec.dir>/<ID>/gate-briefs.md`. Not numbered: it is a record of gate passes, not a
  phase artifact.
- **Append-only.** Create it on the first gate pass, with a first line `# Gate briefs - <ID>` and
  a second line `Append-only. Each section is the text shown at that gate pass.` Never edit or
  reorder an earlier section; a re-presented gate (after `refine`, `revise` or a resume) is a new
  section with the next pass number.
- **Written before it is shown.** The main thread writes the section with the Write or Edit tool,
  then prints the section body verbatim - the same characters, not a paraphrase. A gate whose
  brief is not on disk has not been presented.
- **Printed means reply text.** The shown body is every line after the section heading up to and
  including the question line; the heading and the `### More decisions (shown on details)`
  subsection are not printed. Printing it means those lines appear in the main thread's own reply
  text, as one text block of their own, after the write and before the next tool call (the one
  that appends the `Reply:` line). Copy them from the content you just wrote, not from memory.
  A Write, Edit or Read of the file is **not** printing it, even when a tool view displays the
  content, and neither is a sentence that says the brief was shown. The same holds in a headless
  or scripted run whose reply is already known, and in a turn that continues past the gate: the
  reply text is the only channel the user reads. A gate whose body is not in reply text has not
  been presented, and no later message may say it was.
- **One section per gate pass.** Section headings, by gate, for `/sd:feature` (other workflows:
  "Per-workflow parts"). `## Gate 1+2` is the S lane's combined approval (ADR 0030): one section,
  one `Reply:` line, and it is the evidence of **both** Gate 1 and Gate 2. The `1+2` is part of the
  heading's contract because `stop-gate` matches on it:

```text
## Gate 1 - Spec approval (pass <n>)
## Gate 1+2 - Spec and outline approval (pass <n>)
## Gate 2 - Plan approval (pass <n>)
## Gate 2 - Complexity (pass <n>)
## Gate 3 - Integration and review (pass <n>)
## Gate Re-plan - R<n> (pass <p>)
```

- **Gate Re-plan sections** are shared by every workflow that re-plans (**sd-replan-loop**). `R<n>`
  is the revision number this re-plan would take; `<p>` counts the passes for that `R<n>`. A
  `revise` re-presents the gate as a new section with the next pass; a `details` reply stays in the
  open section. After `abort task` no revision is written, so the next discovery presents the same
  `R<n>` with the next pass number.

- **Collapsed decisions live under the section** in a `### More decisions (shown on details)`
  subsection, written in the same write as the brief. It is part of the record, not of the shown
  text, so a resumed session can answer `details` without re-deriving anything.
- **The reply closes the section.** When the user answers, append one line `Reply: <reply
  verbatim>` to the section with the Edit tool, never a shell redirect or `printf`/`echo`: a shell
  write is the route a restricted permission mode refuses, and the stop-gate reads this line. A `details` reply is recorded the same way, and the section stays
  open for the next reply.
- Subagents never write this file. `sd-spec-architect` and `sd-reviewer` return blocks (below);
  the main thread renders and writes.

## Language

- The brief is written in the **conversation language**: the language the user types in this
  session. A fetched ticket or pasted text does not set it. When it is unclear, use English.
- Agents return their blocks in English, like every spec artifact. The main thread renders a block
  into the conversation language once, when it writes the section, and then shows the section
  verbatim. Translation never happens between the file and the chat, so the text on disk and the
  text shown stay byte-identical.
- These stay English in every language, because tools and replies match on them: the section
  headings, the `### More decisions (shown on details)` heading, the `Reply:` prefix, the option
  tokens of the question line, the spec ID, task IDs and file paths.
- Every other artifact under `<spec.dir>/<ID>/` stays English. `gate-briefs.md` is a record of
  what was shown; no subagent reads it as input.

## Brief shape

The shown body is **at most 10 lines**, counted from the line after the section heading up to and
including the question line, blank lines excluded. A task table (Gate 2 faces only) adds its
header, its separator and one row per task on top of the 10. This cap replaces the "about 15
lines" of the SW-89 ticket text: a total of 15 cannot hold one row per task for a plan at the
decompose threshold, and the ticket's parts (what changes, decisions, risk, tasks) are all here.

Lines, in order:

1. `What changes: <one plain sentence>` - the user-visible effect, not the mechanism.
2. `Decisions (top <k> of <N>):` then up to 3 numbered lines, each
   `<decision> - Recommended: <default>. <why, one clause>`. With no decision at all, a single
   line replaces the block: `Decisions: none - the spec only restates the request.` at spec
   approval, `Decisions: none - the plan adds no choice beyond the approved spec.` at a Gate 2
   face.
3. When `N > 3`: `<N - 3> more defaults taken - reply details to list them.`
4. `Risk: <one line>` - the most likely way this goes wrong, or `Risk: none found.`
5. Gate 2 faces and the S-lane combined approval only: the task table, one row per task, in task
   order. When `01-plan.md` has a
   `## Outline` (ADR 0022), the rows come from it: the outline row's ID and title, and as main
   file the first production path in its `Files`.

```text
| Task | What it does | Main file |
|---|---|---|
| T01 | <plain-language title> | <path> |
```

6. The gate's question line with its option set, copied from the command.

A workflow with its own shape in "Per-workflow parts" replaces lines 1-5 with the lines given
there. The cap, the `Risk:` line, the question line and the decision ranking still apply.

Per gate, for `/sd:feature`:

- **Spec approval** - decisions come from the spec: resolved open questions, defaults the
  architect chose, scope calls in Out of scope. Every decision in the block, shown or collapsed,
  is stated in `00-spec.md`: that file is the durable record of what this gate approves.
- **Plan approval** - decisions come from the plan: added public symbols the spec does not name,
  ordering by choice rather than need, tasks with no `Files`, a rejected alternative a reviewer
  could reasonably prefer. **A decision the approved `00-spec.md` already settles is not a plan
  decision**: the `yes` at spec approval took it, shown or collapsed. List only the decisions the
  plan adds; `N` counts those alone. The architect applies this when it builds the block; the
  main thread drops any such decision that still arrives before it writes the section. The
  Complexity face uses the same shape and the same rule,
  and its `What changes` line states the measured reason the plan is over threshold.
- **Spec and outline approval (S lane)** - the Gate 2 shape, one gate for both artifacts. Decisions
  come from the spec **and** the outline, ranked together: nothing is approved yet, so no decision
  is "already settled". `What changes` is the user-visible effect of the whole change. With no
  decision at all, the single line is `Decisions: none - the spec only restates the request.` The
  task table comes from the outline. Every decision in the block, shown or collapsed, is stated in
  `00-spec.md` or `01-plan.md`. A `yes` approves both artifacts and every default, shown and
  collapsed; the brief says so by saying "defaults taken".
- **Integration and review** - no task table. Lines: `Tests: <summary>. Lint: <summary>.`,
  `Review: <n> blocking, <n> warnings, <n> suggestions.`, then one line per blocking finding
  (`Blocking: <plain title> - <file> - <direction>`, or `Blocking: none`), then
  `Warnings: <n> - Recommended: log as follow-ups. Reply details to see them.` (omitted at 0),
  then `Suggestions: <n> logged to 05-retro.md.` (omitted at 0), then the question. Blocking
  findings are never collapsed and are not capped. Suggestions are logged to `05-retro.md` before
  the brief is written, without asking. Warning and suggestion detail goes in the collapsed
  subsection.
- **Re-plan** - `Discovery: <trigger>`, `Affects: <task IDs and titles>`, `Change: <the delta>`,
  `Risk:`, then the question. The same shape serves every workflow that re-plans.

## Decision ranking

A decision is an item a reviewer could reasonably veto. Everything else - restated request,
mechanical derivations, check results - is not shown at all; the artifacts hold it.

1. Rank by **impact** if the decision is wrong: `high` (public API, persisted data, behavior the
   user sees), `medium` (internal structure other code depends on), `low` (local to one unit).
2. Break ties by **reversibility**, in the task format's vocabulary (`hard` before `moderate`
   before `trivial`, per **sd-atomic-task-format**).
3. Break remaining ties by origin: a default the agent chose alone ranks above a choice the
   request already made.
4. Show the top 3, each with its recommended default. Collapse the rest into the one line from
   "Brief shape". Never drop a decision to fit the cap: every decision is either shown or listed
   under `### More decisions (shown on details)`.

A `yes` approves every recommended default, shown and collapsed. The brief says so by saying
"defaults taken".

## The details option

In `/sd:feature`, Gate 1, Gate 2 (both faces) and Gate 3 offer `details`, and Gate 2 and Gate 3
offer it with an optional target: `details <target>`. The S-lane combined approval, a face of
Gate 1, offers every target a Gate 2 face does, plus `spec`. Every `/sd:bug`, `/sd:refactor`,
`/sd:rca`, `/sd:perf` and `/sd:port` gate offers it, with the targets in "Per-workflow parts";
the rules of this section apply to them. Gate Re-plan offers `details <target>` in every workflow that reaches it (ADR 0025): its delta exists
only in the brief until `approve` writes the revision, so the user needs to see the tasks it
rewrites. A `details` reply is never an approval and never advances the
workflow. Each one prints, records `Reply: <reply verbatim>` in the open section, then asks the
same question again. The printout is not appended: it is either already in the section or a copy
of an artifact that is on disk.

| Reply | Prints | Offered at |
|---|---|---|
| `details` | the section's `### More decisions (shown on details)` subsection, the paths of the artifacts the gate approves, then one line naming the targets this gate offers | Gate 1, S-lane approval, Gate 2 faces, Gate 3, Gate Re-plan |
| `details <task ID>`, e.g. `details T02` | that task's full block from `02-tasks.md`, verbatim, from its heading to its `Status` line; before Phase 3b has written `02-tasks.md`, the `## Outline` table's header, separator and that task's row from `01-plan.md`, verbatim | S-lane approval, Gate 2 faces, Gate 3, Gate Re-plan |
| `details plan` | `01-plan.md`, verbatim, `## Revisions` included | S-lane approval, Gate 2 faces, Gate 3, Gate Re-plan |
| `details risks` | the risks section of `01-plan.md` and the `### Risk assessment` section of `03-decisions.md` (omitted when that file does not exist, as on the S lane), verbatim | S-lane approval, Gate 2 faces, Gate 3 |
| `details spec` | `00-spec.md`, verbatim | S-lane approval |

A target that names nothing at this gate (an unknown task ID, a target the gate does not offer)
prints one line naming the valid targets, then asks again. A task ID is valid at a Gate 2 face when
it names an outline row or, for a plan with no outline, a task block; at Gate Re-plan, when it
names a task block or an outline row (a new task the delta adds has neither yet: its target is the
`Change:` line). `details` never points at a
`02-tasks.md` that does not exist. Spec approval offers a bare `details`
only: no plan, task list or impact analysis exists yet. The S-lane approval has a plan and an
outline but no impact analysis, so `details risks` prints the plan's risks alone.

## Agent return blocks

`sd-spec-architect` ends its return for `TASK = create`, `refine` and `plan` (except a scoped
re-plan) with one block. Decisions come ranked, most important first; the main thread shows them
in that order.

```text
GATE_BRIEF
gate: spec | plan | complexity | s-lane
what-changes: <one plain sentence>
decision: <impact> <reversibility> | <decision> | <recommended default> | <why>
risk: <one line>
task: <task ID> | <plain-language title> | <main file>
END_GATE_BRIEF
```

`decision:` repeats once per decision (none when there are none); `task:` repeats once per task
and appears only for `plan`, `complexity` and `s-lane`, one per outline row when the plan has an
outline. `s-lane` is the combined S-lane approval: its decisions cover the spec and the outline.

For a bug spec (`TEMPLATE = bug.template.md`), `create` and `refine` end with a `gate: symptom`
block instead, ranked and recorded in `00-spec.md` exactly as `gate: spec`:

```text
GATE_BRIEF
gate: symptom
symptom: <one plain sentence>
expected: <one plain sentence>
severity: <P0 | P1 | P2 | P3> | <why, one clause>
affected: <components and users, one line>
decision: <impact> <reversibility> | <decision> | <recommended default> | <why>
risk: <one line>
END_GATE_BRIEF
```

`sd-reviewer` ends a `holistic`, a `bug-fix-final`, a `perf-final` or a `port-parity` review with
one block. The main thread adds
the test and lint summary it measured itself.

```text
GATE_BRIEF
gate: review
block: <plain title> | <file> | <direction>
warn: <plain title> | <file>
suggest: <plain title> | <file>
invariant: <plain statement> | <held | broken | unverified> | <file>
parity: <justified hunks> | <present>/<total> members | <files outside the path mapping>
END_GATE_BRIEF
```

`invariant:` repeats once per entry of `INVARIANTS`, in the spec's order, and appears only when the
review received `INVARIANTS` (a `/sd:refactor` holistic review). A `broken` invariant is also a
`block:` line. `parity:` appears once, in a `port-parity` review only, with the three counts of
its summary line. There, each non-`justified` hunk and each failed whole-artifact check is one
`block:` line, titled by its class and the member it touches, for example `unjustified change in
normalizeTitle`; a `justified` hunk is counted, never listed.

Each field is English and follows the user-facing text rule below, so the main thread can render
it into the conversation language (see "Language") without first removing IDs.

## Per-workflow parts

A workflow listed here uses the artifact, language, cap, ranking, `details` rules and text rule
above, with its own headings, shown lines and `details` targets from this section.

### /sd:bug

Section headings:

```text
## Gate 1 - Symptom captured (pass <n>)
## Gate 2 - Reproduction confirmed (pass <n>)
## Gate 3a - Hypothesis tree exhausted (pass <n>)
## Gate 3 - Root cause confirmed (pass <n>)
## Gate 4 - Failing test confirmed (pass <n>)
## Gate 5 - Regression and review (pass <n>)
```

Sources. Gate 1 comes from the architect's `gate: symptom` block and Gate 5 from the reviewer's
`gate: review` block plus the test and lint summary the main thread measured. The main thread
composes Gates 2, 3a, 3 and 4 itself from what it already wrote: the `## Reproduction` section,
the hypothesis tree and verdicts in `03-decisions.md`, the `## Root cause` section and the saved
failing-test output. `sd-debugger` returns no block: its verdicts are already on disk, and it
also serves `/sd:rca` and `/sd:perf`.

Shown lines, replacing lines 1-5 of "Brief shape":

- **Symptom captured** - `Bug: <symptom, one plain sentence>`, `Expected: <one plain sentence>`,
  `Severity: <P-level> (<why>). Affected: <components and users>`, then lines 2-4 of "Brief
  shape". The decisions are the calls the architect made alone (the severity, where the affected
  scope ends, the expected behavior when the report leaves it open), each stated in `00-spec.md`.
  With none: `Decisions: none - the spec only restates the report.`
- **Reproduction confirmed** - `Reproduction: <confirmed locally | intermittent, about <n>% | not
  reproduced> - <how it was tried, one clause>`, `Trigger: <the exact input or condition>`,
  `Observed: <what happened, against what was expected>`, `Evidence: <paths under 04-artifacts/>`
  or `Evidence: the steps in 00-spec.md only`, `Environment: <where it reproduces>`, `Risk:`. The
  brief states what the session ran; the reply is the user's own confirmation.
- **Hypothesis tree exhausted** - `No root cause yet: <N> hypotheses checked, <r> ruled out, <i>
  inconclusive.`, then up to 3 lines `Ruled out: H<n> <plain statement> - <why, one clause>`,
  highest score first, then `<n> more ruled out - reply details to list them.` when there are
  more, then `Still open: H<n> <plain statement> - missing: <evidence>` for the best-scored
  inconclusive one, or `Still open: none`, then `Recommended: <re-enumerate | observe | abort> -
  <why, one clause>`, then `Risk:`. The rest of the ruled-out list goes in the collapsed
  subsection.
- **Root cause confirmed** - `Root cause: <named, fixable cause, files named>`, `Why root, not
  symptom: <one clause>`, `Evidence: <the log, test or file that showed it> (confidence <low |
  medium | high>)`, `Ruled out: <r> other hypotheses - reply details tree to see them.` (omitted
  at 0), `Risk:` (for example an inconclusive hypothesis that may also contribute).
- **Failing test confirmed** - `Test: "<test name>" in <test file path>`, `Result: fails -
  <failure reason, one line>`, `Fails for the documented reason: yes` or `Fails for the documented
  reason: unclear - <why>`, `Links to root cause: <one clause>`, `Risk:`.
- **Regression and review** - the "Integration and review" lines, unchanged, with suggestions
  logged to `05-retro.md` before the brief is written. The `Tests:` line says whether the new test
  passes and whether anything else failed.

`details` targets:

| Reply | Prints | Offered at |
|---|---|---|
| `details` | the collapsed subsection when the section has one, the paths of the artifacts the gate approves, then one line naming the targets this gate offers | every gate |
| `details repro` | the `## Reproduction` section of `00-spec.md`, verbatim | Gate 2 |
| `details tree` | the hypothesis tree table and every `### H<n> verification` section of `03-decisions.md`, verbatim | Gates 3a, 3 |
| `details H<n>`, e.g. `details H2` | that hypothesis's tree row and its `### H<n> verification` sections, verbatim | Gates 3a, 3 |
| `details rootcause` | the `## Root cause` section of `00-spec.md`, verbatim | Gates 3, 4, 5 |
| `details output` | `04-artifacts/repro/failing-test-output.txt`, verbatim | Gate 4 |
| `details fix` | the `## Fix approach` section of `00-spec.md`, verbatim | Gate 5 |

Gate 1 offers a bare `details` only: nothing but the spec exists yet. `details` is never an
override, so the HARD Gate 2 offers it like any other gate.

### /sd:refactor

Section headings (Gate Re-plan uses the shared heading above):

```text
## Gate 1 - Spec approval (pass <n>)
## Gate 2 - Coverage threshold met (pass <n>)
## Gate 3 - Post-test coverage check (pass <n>)
## Gate 4 - Plan approval (pass <n>)
## Gate 5 - Tests green per batch (pass <n>)
## Gate 6 - Holistic review (pass <n>)
```

Each batch's Gate 5 is a new pass. Sources. Gate 1 comes from the architect's `gate: spec` block,
Gate 4 from its `gate: plan` block (a refactor plan has no complexity face), and Gate 6 from the
reviewer's `gate: review` block plus the test, lint and coverage results the main thread measured
in Phase 6. The main thread composes Gates 2, 3 and 5 itself from what it already wrote: the
`## Test coverage prerequisite` section of `00-spec.md`, the characterization tests the
implementer returned, and the saved batch test output.

Shown lines, replacing lines 1-5 of "Brief shape":

- **Spec approval** - lines 1-4 of "Brief shape", with the "Spec approval" decision rule of
  `/sd:feature` (public API changes, which invariants hold, where scope ends), then
  `Invariants: <n> to preserve - reply details invariants to list them.`, counted from the spec.
- **Coverage threshold met** - `Coverage: <measured>% on <k> affected files, bar <threshold>% -
  <met | <gap> points short>.`, then `Lowest: <file> <n>%` for up to 3 files, lowest first, then,
  below the bar only, `Uncovered: <what has no test, in plain words>`, then `Recommended: <continue
  | add characterization tests | exception> - <why, one clause>`, then `Risk:`. Files are named by
  path, never by `path:line`.
- **Post-test coverage check** - `Coverage: <before>% -> <now>%, bar <threshold>% - <met | <gap>
  points short>.`, `Added: <n> characterization tests in <test files>.`, `Pinned behavior: <the
  current behavior the new tests lock in, one clause>` (say so when it looks wrong: the tests pin
  it either way), `Still uncovered: <plain words>` or `Still uncovered: none`, `Risk:`.
- **Plan approval** - the `/sd:feature` "Plan approval" shape and decision rule, with
  `What changes: <N> tasks in <B> batches - <one plain sentence>`. The task table gains a first
  column and lists rows in batch order, each batch number from the task block's `Parallel batch`
  field:

```text
| Batch | Task | What it does | Main file |
|---|---|---|---|
| 1 | T01 | <plain-language title> | <path> |
```

- **Tests green per batch** - `Batch <b> of <B>`, the table above with this batch's rows only, then
  `Tests: <passed> of <total> pass.` or `Tests: <n> failed.` followed by up to 3 lines
  `Failing: "<test name>" - <reason, one line>`, then `Next: batch <b + 1> of <B>` or
  `Next: holistic review`, then `Risk:`. A red batch is never shown as green: the shown lines state
  the failure and the question offers only revert or fix.
- **Holistic review** - the `/sd:feature` "Integration and review" lines, unchanged, with
  `Tests: <summary>. Coverage: <before>% -> <after>%. Lint: <summary>.` as the first line and
  `Invariants: <k> of <n> held.` after the `Review:` line, plus `, <u> not verifiable - reply
  details to see them` when some are `unverified`. A broken invariant shows as a `Blocking:` line.
  The full invariant list, one line per `invariant:` entry, goes in the collapsed subsection.

`details` targets:

| Reply | Prints | Offered at |
|---|---|---|
| `details` | the collapsed subsection when the section has one, the paths of the artifacts the gate approves, then one line naming the targets this gate offers | every gate |
| `details invariants` | the `## Invariants - MUST preserve` section of `00-spec.md`, verbatim | Gates 1, 4, 6 |
| `details coverage` | the `## Test coverage prerequisite` section of `00-spec.md`, verbatim; at Gate 6 also `04-artifacts/coverage/after-refactor.txt` | Gates 2, 3, 6 |
| `details impact` | the impact analysis Phase 2 appended to `03-decisions.md`, verbatim | Gates 2, 3, 4 |
| `details <task ID>`, `details plan` | as in "The details option" | Gates 4, 5, 6 |
| `details risks` | as in "The details option" | Gate 4 |
| `details output` | `04-artifacts/batches/batch-<b>-tests.txt` of the batch this section reports, verbatim | Gate 5 |

Gate 1 offers `details invariants` besides the bare `details`: the spec is the only artifact yet.
The HARD Gates 2, 3 and 5 offer `details` like any other gate; it is never an override.

### /sd:rca

Section headings:

```text
## Gate 1 - Evidence gathered (pass <n>)
## Gate 2 - Hypotheses enumerated (pass <n>)
## Gate 3 - Root cause confirmed (pass <n>)
```

`gather more`, `add hypothesis`, `refine ranking` and `dig deeper` each re-present their gate as a
new pass. Sources. The main thread composes all three briefs itself and no agent returns a block:
Gate 1 from the Timeline, Symptoms, Affected scope and Recent changes sections it filled with the
user, Gate 2 from the tree it appended to `00-spec.md`, Gate 3 from the `## Root cause` section and
the confirmed verdict. The `GATE_BRIEF` block `sd-spec-architect` returns for the empty skeleton is
not used. `sd-debugger` is unchanged. An RCA keeps its tree and its verdicts in `00-spec.md`, not
in `03-decisions.md`, and it has no Gate 3a: an exhausted tree is `dig deeper`.

Shown lines, replacing lines 1-5 of "Brief shape". No line is a decision: the user supplied the
evidence and the tree is ranked, not chosen, so a gate here shows no `Decisions` block.

- **Evidence gathered** - `Incident: <what broke and for whom, one plain sentence>. Severity:
  <P-level> (<why>)`, `Window: <start> to <end> UTC (<duration>); detected after <latency>,
  mitigated after <latency>`, `Timeline: <n> events, from <first event> to <last event>`, `Impact:
  <services and users hit>; data integrity: <none | what is inconsistent>`, `Recent changes: <n>
  in the 72 hours before - <the most suspect, one clause>` or `Recent changes: none found`,
  `Evidence: <n> files saved under 04-artifacts/`, `Gaps: <what the user could not provide>` or
  `Gaps: none` (its own line), `Risk:`.
- **Hypotheses enumerated** - `Hypotheses: <N> ranked, best lead first.`, then the best-scored one
  as the "Still open" line of `/sd:bug` Gate 3a with `to check:` for `missing:`, then up to 2 lines
  `Next: H<n> <plain statement> - to check: <evidence>`, then `<n> more - reply details tree to
  list them.` when there are more, `Recommended: <yes | add hypothesis | refine ranking> - <why,
  one clause>`, `Risk:`.
- **Root cause confirmed** - the "Root cause confirmed" lines of `/sd:bug` (`Root cause:`, `Why
  root, not symptom:`, `Evidence:` with its confidence, `Ruled out:`), then `Explains: <the
  symptoms it accounts for>; unexplained: <none | what is left>` and `Timeline fit: <how it lines
  up with the first symptom, one clause>`, then `Risk:`.

`details` targets:

| Reply | Prints | Offered at |
|---|---|---|
| `details` | the collapsed subsection when the section has one, the paths of the artifacts the gate approves, then one line naming the targets this gate offers | every gate |
| `details timeline` | the `## Timeline (UTC)` and `## Recent changes` sections of `00-spec.md`, verbatim | Gates 1, 3 |
| `details impact` | the `## Symptoms observed` and `## Affected scope` sections of `00-spec.md`, verbatim | Gate 1 |
| `details tree` | as in `/sd:bug`, from `## Hypothesis tree` and `### Verification results (Phase 3)` of `00-spec.md` | Gates 2, 3 |
| `details H<n>`, e.g. `details H2` | that hypothesis's tree row and every entry under `### Verification results (Phase 3)` that names it, verbatim; before Phase 3, the tree row only | Gates 2, 3 |
| `details rootcause` | the `## Root cause` and `## Why this is root cause (not symptom)` sections of `00-spec.md`, verbatim | Gate 3 |

`details` is never an override, so the HARD gates offer it like any other gate.

### /sd:perf

Section headings, the titles of the gates in `commands/perf.md`:

```text
## Gate 1 - Target defined (pass <n>)
## Gate 2 - Baseline measured (pass <n>)
## Gate 3 - Hotspot identified (pass <n>)
## Gate 4 - Select hypothesis (pass <n>)
## Gate 5 - Correctness verified (pass <n>)
## Gate 6 - Keep or revert decision (pass <n>)
## Gate 7 - Regression pass (pass <n>)
## Gate 8 - Final review pass (pass <n>)
```

Gates 3 to 6 repeat, once per hotspot or per attempt, and each repeat is a new pass, like a
`refine` or a `revise`. Sources. Gate 1 comes from the architect's `gate: spec` block and Gate 8
from the reviewer's `gate: review` block (a `perf-final` review) plus the final row of the Results
log. The main thread composes Gates 2 to 7 itself from what it already
wrote: the saved measurement files, the saved test output, the hotspot ranking and the hypotheses
in `03-decisions.md`, and the Results log. `sd-debugger` returns no block: it also serves
`/sd:bug` and `/sd:rca`.

**Measured numbers come from the saved file.** Every number in a brief (a latency, a rate, a
test count) is read from the artifact named in the table below when the section is written, never
from memory of the run, and carries its unit and the number of runs it summarizes. An estimate the
debugger made (a hotspot share, an expected gain) is labelled as one.

**Hypothesis IDs.** A hotspot is `H<n>`, in the debugger's ranking order; a hypothesis for it is
`H<n>` plus a letter, `H1a`, `H1b`, in the order the debugger listed them. An attempt is numbered
`N`, the number of its Results-log row, assigned when it is applied: every attempt has a row,
reverted ones included.

Shown lines, replacing lines 1-5 of "Brief shape":

- **Target defined** - `What changes: <the target in plain words: metric, goal, workload; nothing
  is optimized yet>`, then lines 2-4 of "Brief shape" with the "Spec approval" decision rule of
  `/sd:feature` (the goal when the request left it open, the load profile, how many runs and what
  counts as noise), `Target: <metric> under <goal> <unit> on <workload>, load <profile>`, and
  `Method: <tool>, <n> runs, warm-up <duration>, <cache state>`.
- **Baseline measured** - `Baseline: p95 <x> <unit> (p50 <x>, p99 <x>), median of <n> runs`,
  `Target: p95 under <goal> <unit>`, `Gap: <x> <unit> (<pct>%) over the goal` or `Gap: none -
  already meets the goal`, `Spread: <min> to <max> <unit> across <n> runs - the noise floor of
  Gate 6`, `Conditions: <environment, load, cache state>`, `Evidence: <the baseline file under
  04-artifacts/>`, `Recommended: <continue | close, no work needed | refine methodology> - <why,
  one clause>`, `Risk:`. The gate has two faces, one per question: the baseline already meets the
  goal, or it does not.
- **Hotspot identified** - `Hotspots: <N> found, ranked by share of <metric>.`, then up to 3 lines
  `H<n> <where the time goes, plain> in <file path> - about <pct>% - basis: <profile | code
  read>`, then `<n> more - reply details hotspots to list them.` when there are more,
  `Recommended: choose H<n> - <why, one clause>`, `Risk:`. A file is named by path, never by
  `path:line`.
- **Select hypothesis** - `Hotspot: H<n> <plain statement>`, `Hypotheses: <k> untried.`, then one
  line per untried hypothesis, at most 4, `H<n><x> <the change, plain> - expected <delta> <unit> -
  cost <S | M | L> - undo: <trivial | moderate | hard>`, then, when this hotspot has reverted
  attempts, `Already reverted: H<n><x> (<delta> <unit>)` for each, `Recommended: choose H<n><x> -
  <why, one clause>`, `Risk:`.
- **Correctness verified** - `Attempt <N>: H<n><x> <the change, plain>`, then one of two faces.
  Green: `Tests: <passed> of <total> pass.`, `Changed: <file paths>`, `Next: re-measure under the
  baseline conditions`. Red: `Tests: <n> failed.` followed by up to 3 lines `Failing: "<test
  name>" - <reason, one line>`, `Reverted: yes - the change is out of the tree`, `Next: another
  hypothesis for H<n>`. Then `Risk:`. A red attempt is never shown as green, and the revert has
  already happened when the gate is shown.
- **Keep or revert decision** - `Attempt <N>: H<n><x> <the change, plain>`, `p95: <previous best>
  -> <new> <unit> (<delta> <unit>, <pct>%) over <n> runs`, `Noise: spread <x> <unit>; a real gain
  is above 5% and above that spread`, `Verdict: <real improvement | within noise>`, `Goal: p95
  under <goal> <unit> - <met | <gap> <unit> to go>`, `Others: <the other metrics against the
  previous best> - <no regression | what got worse>`, `Recommended: <keep | revert> - <why, one
  clause>`, `Risk:`. Within noise the recommendation is `revert`, and the question is the second
  face.
- **Regression pass** - `Tests: <passed> of <total> pass. Lint: <summary>.`, `Final: p95 <x>
  <unit> over <n> runs, baseline <x> <unit> - <pct>% faster`, `Goal: <met | <gap> <unit> to go>`,
  `Stable: <the final run against the best kept attempt, one clause>`, `Kept: <k> of <A> attempts,
  <r> reverted, <d> hotspots deferred.`, `Risk:`.
- **Final review pass** - the "Integration and review" lines of `/sd:feature`, with `Result: p95
  <baseline> -> <final> <unit> (<pct>%), goal <met | <gap> <unit> to go>.` as the first line in
  place of the `Tests:` line, which Gate 7 already showed. Suggestions are logged to `05-retro.md`
  before the brief is written.

`details` targets. Each prints the file named, verbatim:

| Reply | Prints | Offered at |
|---|---|---|
| `details` | the collapsed subsection when the section has one, the paths of the artifacts the gate approves, then one line naming the targets this gate offers | every gate |
| `details target` | the `## Target`, `## Measurement methodology` and `## Constraints` sections of `00-spec.md` | Gates 1, 2 |
| `details hotspots` | the hotspot ranking the debugger returned, as appended to `03-decisions.md` | Gates 3, 4 |
| `details H<n>`, `details H<n><x>`, e.g. `details H1`, `details H1b` | that hotspot's ranking row and its hypotheses, or that one hypothesis with its expected impact, cost, risk profile and verification approach, from `03-decisions.md` | Gates 3, 4, 5, 6 |
| `details results` | the `## Results log` table of `00-spec.md` | Gates 4, 6, 7, 8 |
| `details measurement` | the raw measurement the section reports: `baseline-<ts>.json` at Gate 2, `attempt-<N>-<ts>.json` at Gate 6, `final-<ts>.json` at Gate 7, from `04-artifacts/` | Gates 2, 6, 7 |
| `details output` | `attempt-<N>-tests.txt` at Gate 5, `final-tests.txt` at Gate 7, from `04-artifacts/` | Gates 5, 7 |

Gate 1 offers `target` besides the bare `details`: the spec is the only artifact yet. A target the
gate does not offer, or a hotspot or hypothesis ID that is not in the ranking, prints one line
naming the valid targets, then asks again. `details` is never an override, so the HARD gates offer
it like any other gate.

### /sd:port

Section headings, the titles of the gates in `commands/port.md`:

```text
## Gate 1 - Donor set frozen (pass <n>)
## Gate 2 - Fidelity tables complete (pass <n>)
## Gate 3 - Behavior pinned and green (pass <n>)
## Gate 4 - Plan approval (pass <n>)
## Gate 5 - Batch tests green (pass <n>)
## Gate 6 - Justified-diff parity (pass <n>)
```

`re-capture`, `refine`, `re-pin`, each batch and each parity run (`re-run parity`, and the
re-review after `revert-to-snapshot` or `add-deviation`) present their gate as a new pass.
Sources. Gate 4 comes from the architect's `gate: plan` block and Gate 6 from the reviewer's
`gate: review` block of a `port-parity` review plus the test and lint summary the main thread
measured. The main thread composes Gates 1, 2, 3 and 5 itself from what it already wrote:
`MANIFEST.md` and the warnings of Phases 0 to 2, the three fidelity tables it counts in Phase 4,
the `## Behavior pinning` section and the saved pinning output, and the saved batch output. The
`gate: spec` block the architect returns for `create` and `refine` is not used: the deviation
table is the record of what Gate 2 approves, and the main thread counts it rather than trusting a
summary of it.

**The tables are counted, never re-judged.** Every count in a brief is the count the command
makes mechanically, read from the artifact when the section is written. What a table row means,
its completeness condition and the hunk vocabulary stay in **sd-port-fidelity**; a brief states
counts and names rows, it does not restate those rules.

**A deviation in plain words.** A deviation row is shown as `D<NN> <donor form> -> <host form>`,
and what forced it as words, never as its citation: `compiler conflict on <identifier>`, `host
rule on <topic>`, `host precedent in <file path>`, `agreed fix of <donor defect>`. A `§N.M` or a
`path:line` citation stays in the table, where `details` prints it. The form holds on every line
that names a deviation, the closing summary included:
`Deviations applied: 1 - D01 _WHITESPACE -> WHITESPACE, host rule on naming private constants.`

Shown lines, replacing lines 1-5 of "Brief shape". Gates 1, 3 and 5 are checks and show no
`Decisions` block.

- **Donor set frozen** - `Donor: <donor> at <commit, first 12 characters> - scope <scope>, copied
  from <another repo | this repo>, snapshot <contract | contract and source>`, `Frozen: <N> files,
  <M> members; <k> paths now protected from edits.`, `Manifest: 04-artifacts/source/MANIFEST.md,
  sha256 <hex>`, `Policy: <the effective port policy, one clause>`, `Warnings: <each warning of
  Phases 0 to 2, plain: a dirty donor commit, a build or test configuration that sees .specs/>` or
  `Warnings: none`, `Risk:`.
- **Fidelity tables complete** - `Tables: <P> files mapped (<m> mirror, <g> merge, <o> omit);
  members <M>/<T> (<p> ported, <d> deviated, <x> omitted).`, `Deviations: <D> - <n> compiler
  conflict, <n> host rule, <n> host precedent, <n> agreed donor fix.` (a group at 0 is left out),
  then one of two faces.
  Complete, with nothing unmapped and no blocking problem from the spec check: the deviations are
  the decisions, shown as `Decisions (top <k> of <D>):` with up to 3 lines `D<NN> <donor form> ->
  <host form> - Recommended: keep. <what forced it>`, ranked agreed donor fix first (it changes
  behavior), then host rule, host precedent and compiler conflict, then `<D - 3> more deviations
  taken - reply details deviations to list them.` when there are more. With none: `Decisions:
  none - the host mirrors the donor.`
  Incomplete: `Blocking: <n> - approval refused until 0.` replaces the decisions, then up to 4
  lines `Blocking: <the member, file or row, plain> - <what is missing>`, then `<n> more blocking -
  reply details to list them.` when there are more; the rest go in the collapsed subsection.
  `yes` is refused on this face, so no decision is hidden by it. Then `Risk:` on both faces.
- **Behavior pinned and green** - `Pinned via: <contract suite | characterization tests | skipped -
  scope is pattern> - <why, one clause>`, `Tests: <n> pinned tests in <test files> - <passed> of
  <total> pass.` (omitted when skipped), `Covers: <the contract facets and invariants the tests
  assert, plain>`, `Production tree: unmodified - both checks empty.` or `Production tree: <n>
  changed paths - <up to 3 paths>; approval refused until clean.`, `Recommended: <yes | re-pin> -
  <why, one clause>`, `Risk:`.
- **Plan approval** - the `/sd:refactor` "Plan approval" lines and batch table, with `What
  changes: <N> tasks in <B> batches, one per host file - <D> deviations to adapt, threshold 8
  (<under | over: split along <k> host paths>).` The main thread writes that line from the metric
  it computed; the architect's other lines are kept. A deviation is not a plan decision: Gate 2
  approved it. A task's snapshot range and licensed deviations are not shown in the table:
  `details <task ID>` prints its block.
- **Batch tests green** - the `/sd:refactor` "Tests green per batch" lines, both faces, with
  `Pinned suite: <passed> of <total> pass.` or `Pinned suite: <n> failed.` after the `Tests:`
  line. A red pinned suite is a red batch.
- **Justified-diff parity** - the `/sd:feature` "Integration and review" lines, with `Parity: <J>
  hunks justified by a deviation, <B> blocking; members <n>/<total> present; <u> files outside the
  path mapping.` after the `Tests:` line, from the block's `parity:` field. Blocking lines are
  never collapsed; when one file has more than 3 blocking hunks of one class they share a line,
  `Blocking: <n> <class> changes in <file> - <direction>`, and each stays listed in the parity
  report. A justified hunk is never listed.

`details` targets. Each prints the file or section named, verbatim:

| Reply | Prints | Offered at |
|---|---|---|
| `details` | the collapsed subsection when the section has one, the paths of the artifacts the gate approves, then one line naming the targets this gate offers | every gate |
| `details manifest` | `04-artifacts/source/MANIFEST.md` | Gates 1, 2, 6 |
| `details contract` | the `## Behavioral contract` and `## Behavioral invariants (non-obvious)` sections of `00-spec.md` | Gates 1, 3 |
| `details tables` | the `## Path mapping table`, `## Member manifest` and `## Deviation table` sections of `00-spec.md` | Gates 2, 6 |
| `details deviations` | the `## Deviation table` section of `00-spec.md` | Gates 2, 4, 6 |
| `details D<NN>`, e.g. `details D02` | the Deviation table's header, separator and that row, then the Member manifest's header, separator and every row naming it, from `00-spec.md` | Gates 2, 4, 6 |
| `details scan` | the `## Host-constitution scan` section of `03-decisions.md` | Gate 2 |
| `details pinning` | the `## Behavior pinning` section of `03-decisions.md` | Gate 3 |
| `details output` | `04-artifacts/pinning/pinned-tests.txt` at Gate 3, `04-artifacts/batches/batch-<b>-tests.txt` of the batch the section reports at Gate 5 | Gates 3, 5 |
| `details proof` | `04-artifacts/pinning/tree-check.txt`, the empty-diff checks and their output | Gate 3 |
| `details <task ID>`, `details plan` | as in "The details option" | Gates 4, 5 |
| `details risks` | as in "The details option" | Gate 4 |
| `details parity` | `04-artifacts/parity/REPORT.md`, then `04-artifacts/parity/INDEX.md` | Gate 6 |
| `details <host path>`, e.g. `details src/domain/title-format.js` | the `.diff` file `INDEX.md` lists for that host path | Gate 6 |

A deviation ID that is not in the table, or a host path `INDEX.md` does not list, prints one line
naming the valid targets, then asks again. A deviation ID in that line carries its gloss, like
every other line that shows one: `D01 (_WHITESPACE -> WHITESPACE)`, never a bare `D01`.
`details` is never an override, so the HARD Gates 1, 2, 3 and 6 offer it like any other gate.

## User-facing text

Applies to every line the user reads: `gate-briefs.md` and all reply text of the session, from
Phase 0 to the end of the turn. That includes the closing summary and any report the request that
started the workflow asks for (a final status line, an answer to a harness step): a report the
invoking prompt asks for is still reply text the user reads. It does not apply to the machine
records in other artifacts (for example the `escalation:` lines in `05-retro.md`, whose format
**sd-model-escalation** owns and which keep their rule IDs).

- **No internal IDs.** Never show a rule ID (`ESC-*`, or a lint or verify code of two letters and
  three digits), a constitution section sign reference, a criterion or decision
  reference (`SC-<n>`, `AC-<n>`, `D<n>`), or a `path:line` citation. Say what the thing is
  instead.
- **Allowed handles.** The spec ID, a task ID on the same line as its plain title, a hypothesis ID
  (`H<n>`, or `H<n><x>` for a `/sd:perf` hypothesis of hotspot `H<n>`) on the same line as its
  plain statement, a `/sd:port` deviation ID (`D<NN>`) on the same line as its
  `<donor form> -> <host form>`, a bug severity (`P0`-`P3`), gate names, file
  paths, and the option tokens of the question line. The deviation ID is the one `D<n>` the
  user may see: it names a row the user can ask for (`details D02`) and cite in `add-deviation`.
- **Narrate a model escalation in plain words**: what runs on a stronger model and why, for
  example "planning with a stronger model because the spec was sized large". The rule ID stays in
  the retro line only.
- **Narrate every phase on entry.** On entering each phase, Phase 0 and close-out included and
  on a resume too, print one line of its own before the phase's first tool call:
  `Phase <n> - <what it does>`, for example "Phase 2 - mapping what the change touches". It names
  the phase and what it does, not the step number of a rule.
- **Cite evidence by name, not by line.** The closing summary and any progress line name a test
  by its name and code by its file. The `path:line` citations that close-out gathers belong in
  `05-retro.md` and `06-verify.md`; the summary may name those files instead.
- **A `details` excerpt is not brief text.** It is an artifact the user asked to see, printed
  verbatim, so it keeps the IDs and the English it has on disk.

## Anti-patterns

- Printing the brief without writing it, or writing a paraphrase of what was printed.
- Writing the brief and not printing it: treating the Write call, or a sentence such as "Gate 1
  presented", as the print. Saying a gate was shown when its body is not in reply text.
- Copying a `path:line` citation from the retro or the verify report into the closing summary.
- Glossing a deviation ID in prose (`D01 renames _WHITESPACE to WHITESPACE`) instead of its
  `donor -> host` form, or naming the constitution section that forced it.
- Editing an earlier section to fix a typo instead of appending the next pass.
- Raising the cap to fit an eleventh line instead of collapsing a decision.
- Collapsing a blocking finding, or dropping a decision that does not fit.
- Re-listing at a Gate 2 face a decision the approved spec already settles.
- Translating a section heading, the `Reply:` prefix or an option token; or translating between
  the file and the chat instead of once, before the write.
- Appending a `details` printout to the section, or summarizing an artifact instead of printing it.
- Translating a rule ID into the brief as "(rule X)" - the reader cannot act on it either way.
- Restating this file's shapes or ranking in a command or an agent body; name the skill.
