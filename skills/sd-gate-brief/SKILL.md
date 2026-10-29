# sd-gate-brief

Gate brief discipline for specwright workflows: what a gate shows the user, where that text is
kept, and how every user-facing line is worded. This file is the single owner of the brief
artifact, its language, the per-gate shapes, the decision ranking rule, the `details` targets,
the agent return blocks and the narration rule. `/sd:feature`, `/sd:bug`, `/sd:refactor` and
`/sd:rca` read it at runtime in Phase 0 (commands cannot load skills via frontmatter) and name only
where each rule applies; **sd-replan-loop** names it at Gate Re-plan. `sd-spec-architect` and `sd-reviewer`
load it via `skills:` so they know the block they return.

Origin: ADR 0018 ("Gate brief artifact"), Jira SW-89; extended by ADR 0019 (details targets,
brief language, plan-face decisions), Jira SW-102, and ADR 0020 (printed means reply text, the
closing summary, phase narration), Jira SW-99, and ADR 0022 (task rows and `details` from the
outline), Jira SW-92, and ADR 0024 (the `/sd:bug` gates), Jira SW-96, and ADR 0025 (the
`/sd:refactor` gates, `details` at Gate Re-plan), Jira SW-109, and ADR 0026 (the `/sd:rca` gates),
Jira SW-111. Measured "before":
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
  "Per-workflow parts"):

```text
## Gate 1 - Spec approval (pass <n>)
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
5. Gate 2 faces only: the task table, one row per task, in task order. When `01-plan.md` has a
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
offer it with an optional target: `details <target>`. Every `/sd:bug`, `/sd:refactor` and
`/sd:rca` gate offers it, with the targets in "Per-workflow parts"; the rules of this section apply to them. Gate
Re-plan offers `details <target>` in every workflow that reaches it (ADR 0025): its delta exists
only in the brief until `approve` writes the revision, so the user needs to see the tasks it
rewrites. A `details` reply is never an approval and never advances the
workflow. Each one prints, records `Reply: <reply verbatim>` in the open section, then asks the
same question again. The printout is not appended: it is either already in the section or a copy
of an artifact that is on disk.

| Reply | Prints | Offered at |
|---|---|---|
| `details` | the section's `### More decisions (shown on details)` subsection, the paths of the artifacts the gate approves, then one line naming the targets this gate offers | Gate 1, Gate 2 faces, Gate 3, Gate Re-plan |
| `details <task ID>`, e.g. `details T02` | that task's full block from `02-tasks.md`, verbatim, from its heading to its `Status` line; before Phase 3b has written `02-tasks.md`, the `## Outline` table's header, separator and that task's row from `01-plan.md`, verbatim | Gate 2 faces, Gate 3, Gate Re-plan |
| `details plan` | `01-plan.md`, verbatim, `## Revisions` included | Gate 2 faces, Gate 3, Gate Re-plan |
| `details risks` | the risks section of `01-plan.md` and the `### Risk assessment` section of `03-decisions.md`, verbatim | Gate 2 faces, Gate 3 |

A target that names nothing at this gate (an unknown task ID, a target the gate does not offer)
prints one line naming the valid targets, then asks again. A task ID is valid at a Gate 2 face when
it names an outline row or, for a plan with no outline, a task block; at Gate Re-plan, when it
names a task block or an outline row (a new task the delta adds has neither yet: its target is the
`Change:` line). `details` never points at a
`02-tasks.md` that does not exist. Spec approval offers a bare `details`
only: no plan, task list or impact analysis exists yet.

## Agent return blocks

`sd-spec-architect` ends its return for `TASK = create`, `refine` and `plan` (except a scoped
re-plan) with one block. Decisions come ranked, most important first; the main thread shows them
in that order.

```text
GATE_BRIEF
gate: spec | plan | complexity
what-changes: <one plain sentence>
decision: <impact> <reversibility> | <decision> | <recommended default> | <why>
risk: <one line>
task: <task ID> | <plain-language title> | <main file>
END_GATE_BRIEF
```

`decision:` repeats once per decision (none when there are none); `task:` repeats once per task
and appears only for `plan` and `complexity`, one per outline row when the plan has an outline.

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

`sd-reviewer` ends a `holistic` or a `bug-fix-final` review with one block. The main thread adds
the test and lint summary it measured itself.

```text
GATE_BRIEF
gate: review
block: <plain title> | <file> | <direction>
warn: <plain title> | <file>
suggest: <plain title> | <file>
invariant: <plain statement> | <held | broken | unverified> | <file>
END_GATE_BRIEF
```

`invariant:` repeats once per entry of `INVARIANTS`, in the spec's order, and appears only when the
review received `INVARIANTS` (a `/sd:refactor` holistic review). A `broken` invariant is also a
`block:` line.

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
  (`H<n>`) on the same line as its plain statement, a bug severity (`P0`-`P3`), gate names, file
  paths, and the option tokens of the question line.
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
- Editing an earlier section to fix a typo instead of appending the next pass.
- Raising the cap to fit an eleventh line instead of collapsing a decision.
- Collapsing a blocking finding, or dropping a decision that does not fit.
- Re-listing at a Gate 2 face a decision the approved spec already settles.
- Translating a section heading, the `Reply:` prefix or an option token; or translating between
  the file and the chat instead of once, before the write.
- Appending a `details` printout to the section, or summarizing an artifact instead of printing it.
- Translating a rule ID into the brief as "(rule X)" - the reader cannot act on it either way.
- Restating this file's shapes or ranking in a command or an agent body; name the skill.
