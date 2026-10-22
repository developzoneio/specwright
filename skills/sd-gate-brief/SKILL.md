# sd-gate-brief

Gate brief discipline for specwright workflows: what a gate shows the user, where that text is
kept, and how every user-facing line is worded. This file is the single owner of the brief
artifact, the per-gate shapes, the decision ranking rule, the agent return blocks and the
narration rule. `/sd:feature` reads it at runtime as Phase 0 step 4 (commands cannot load skills
via frontmatter) and names only where each rule applies. `sd-spec-architect` and `sd-reviewer`
load it via `skills:` so they know the block they return.

Origin: ADR 0018 ("Gate brief artifact"), Jira SW-89. Measured "before":
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
- **One section per gate pass.** Section headings, by gate:

```text
## Gate 1 - Spec approval (pass <n>)
## Gate 2 - Plan approval (pass <n>)
## Gate 2 - Complexity (pass <n>)
## Gate 3 - Integration and review (pass <n>)
## Gate Re-plan - R<n>
```

- **Collapsed decisions live under the section** in a `### More decisions (shown on details)`
  subsection, written in the same write as the brief. It is part of the record, not of the shown
  text, so a resumed session can answer `details` without re-deriving anything.
- **The reply closes the section.** When the user answers, append one line `Reply: <reply
  verbatim>` to the section. A `details` reply is recorded the same way, and the section stays
  open for the next reply.
- Subagents never write this file. `sd-spec-architect` and `sd-reviewer` return blocks (below);
  the main thread renders and writes.

## Brief shape

The shown body is **at most 10 lines**, counted from the line after the section heading up to and
including the question line, blank lines excluded. A task table (Gate 2 faces only) adds its
header, its separator and one row per task on top of the 10.

Lines, in order:

1. `What changes: <one plain sentence>` - the user-visible effect, not the mechanism.
2. `Decisions (top <k> of <N>):` then up to 3 numbered lines, each
   `<decision> - Recommended: <default>. <why, one clause>`. With no decision at all, a single
   line `Decisions: none - the spec only restates the request.` replaces the block.
3. When `N > 3`: `<N - 3> more defaults taken - reply details to list them.`
4. `Risk: <one line>` - the most likely way this goes wrong, or `Risk: none found.`
5. Gate 2 faces only: the task table, one row per task, in task order:

```text
| Task | What it does | Main file |
|---|---|---|
| T01 | <plain-language title> | <path> |
```

6. The gate's question line with its option set, copied from the command.

Per gate:

- **Spec approval** - decisions come from the spec: resolved open questions, defaults the
  architect chose, scope calls in Out of scope.
- **Plan approval** - decisions come from the plan: added public symbols the spec does not name,
  ordering by choice rather than need, tasks with no `Files`, a rejected alternative a reviewer
  could reasonably prefer. The Complexity face uses the same shape, and its `What changes` line
  states the measured reason the plan is over threshold.
- **Integration and review** - no task table. Lines: `Tests: <summary>. Lint: <summary>.`,
  `Review: <n> blocking, <n> warnings, <n> suggestions.`, then one line per blocking finding
  (`Blocking: <plain title> - <file> - <direction>`, or `Blocking: none`), then
  `Warnings: <n> - Recommended: log as follow-ups. Reply details to see them.` (omitted at 0),
  then `Suggestions: <n> logged to 05-retro.md.` (omitted at 0), then the question. Blocking
  findings are never collapsed and are not capped. Suggestions are logged to `05-retro.md` before
  the brief is written, without asking. Warning and suggestion detail goes in the collapsed
  subsection.
- **Re-plan** - `Discovery: <trigger>`, `Affects: <task IDs and titles>`, `Change: <the delta>`,
  then the question.

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

Every gate that carries a brief offers `details`. It prints the section's
`### More decisions (shown on details)` subsection and the paths of the full artifacts the gate
approves, records `Reply: details`, then asks the same question again. It is never an approval
and never advances the workflow.

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
and appears only for `plan` and `complexity`.

`sd-reviewer` ends a `holistic` review with one block. The main thread adds the test and lint
summary it measured itself.

```text
GATE_BRIEF
gate: review
block: <plain title> | <file> | <direction>
warn: <plain title> | <file>
suggest: <plain title> | <file>
END_GATE_BRIEF
```

Each field follows the user-facing text rule below: the block is rendered, not translated.

## User-facing text

Applies to every line the user reads: all chat text of the workflow and `gate-briefs.md`. It does
not apply to the machine records in other artifacts (for example the `escalation:` lines in
`05-retro.md`, whose format **sd-model-escalation** owns and which keep their rule IDs).

- **No internal IDs.** Never show a rule ID (`ESC-*`, or a lint or verify code of two letters and
  three digits), a constitution section sign reference, a criterion or decision
  reference (`SC-<n>`, `AC-<n>`, `D<n>`), or a `path:line` citation. Say what the thing is
  instead.
- **Allowed handles.** The spec ID, a task ID on the same line as its plain title, gate names,
  file paths, and the option tokens of the question line.
- **Narrate a model escalation in plain words**: what runs on a stronger model and why, for
  example "planning with a stronger model because the spec was sized large". The rule ID stays in
  the retro line only.
- **Phase narration** names the phase and what it does ("Phase 2 - mapping what the change
  touches"), not the step number of a rule.

## Anti-patterns

- Printing the brief without writing it, or writing a paraphrase of what was printed.
- Editing an earlier section to fix a typo instead of appending the next pass.
- Raising the cap to fit an eleventh line instead of collapsing a decision.
- Collapsing a blocking finding, or dropping a decision that does not fit.
- Translating a rule ID into the brief as "(rule X)" - the reader cannot act on it either way.
- Restating this file's shapes or ranking in a command or an agent body; name the skill.
