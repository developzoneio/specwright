# ADR 0021: Stop close-out gate - /sd:feature gates are evidenced by gate-briefs.md

- Status: accepted
- Date: 2026-10-22
- Source spec: Jira SW-100 (`FEAT-stop-gate-feature-rules`, E12 / SW-87)
- Relates to: ADR 0016 (the stop-gate invariant table this ADR extends); ADR 0018 (the
  `gate-briefs.md` artifact, which named this as a follow-up); ADR 0019 (briefs are written in the
  conversation language); ADR 0015 (Stop blocking and the `stop_hook_active` re-fire); ADR 0012
  (hook latency budget)
- Supersedes: none. Extends ADR 0016's table with three rows and reverses its "feature specs are
  never checked" consequence, which the fixture `allow-feature-type` asserted.
- Extended by: ADR 0025 (settles the Gate Re-plan section shape; Re-plan still has no rule; SW-109);
  ADR 0029 (bug, refactor and Gate Re-plan rows on the same reader; SW-108)
- Amended by: ADR 0030 (the S lane's combined approval). A `## Gate 1+2` heading opens one section
  that counts for Gate 1 and Gate 2 at once, ranked as Gate 1, with Gate 1's non-approving tokens.
  The parse contract below otherwise stands.

## Context

ADR 0016 gave `stop-gate` no `/sd:feature` rule. Feature gates leave no verdict in the phase
artifacts: Gate 1 sets a status the next phases also set, Gate 2's face is decided by an agent's
return, and Gate 3 approves a review that lives only in chat. A session that drifts past a feature
gate was therefore never caught, although `/sd:feature` is the most-used workflow and SW-88 found
both of its baseline runs reporting gates they had not shown.

SW-89 added `.specs/<ID>/gate-briefs.md` (ADR 0018): one section per gate pass, headed
`## Gate <n> - <name> (pass <k>)`, written before it is shown and closed by a `Reply: <reply
verbatim>` line. That is a file a hook can read. Three things it cannot say directly:

- **Whether the file should exist at all.** Specs created before SW-89 have none, and a spec
  resumed in a later session (e2e `06`-`10` seed exactly these) may hold sections only from the
  gate it resumed at.
- **What the reply means.** The line is the user's reply verbatim, in the conversation language
  (ADR 0019). Only the option tokens are guaranteed English.
- **Order against later work.** A section carries no timestamp, and `/sd:feature` can send work
  back to an earlier phase (a failed `/sd:verify` returns to Phase 3 or 4), which re-presents a
  gate that was already approved.

## Decision

`stop-gate` evaluates three more invariants when the driven spec's frontmatter `type:` is
`feature`. Spec selection, output, the loop guard and the opt-in flag are ADR 0016's, unchanged.

| Rule | Gate | Advanced (any of) | Missing (any of) |
|---|---|---|---|
| FEAT-G1 | `/sd:feature` Gate 1 - Spec approval | status `approved` or `in-progress`; `02-tasks.md` exists; `03-decisions.md` exists | the brief covers Gate 1, and no `## Gate 1` section exists or none has an approving `Reply:` line |
| FEAT-G2 | `/sd:feature` Gate 2 - Plan approval, either face | status `in-progress`; a task in `02-tasks.md` has `- **Status**: done` | the same, for `## Gate 2` |
| FEAT-G3 | `/sd:feature` Gate 3 - Integration and review | `06-verify.md` records `result: pass` | the same, for `## Gate 3` |

**No file, no rule.** Without `gate-briefs.md`, none of the three can fire. A missing record is not
evidence of a skipped gate.

**Coverage.** The brief covers a gate when that gate comes at or after the first gate heading in
the file, in workflow order: Gate 1, Gate 2, Gate Re-plan, Gate 3. A spec resumed at Gate 2 has a
brief that starts there, so its Gate 1 is not checked; a brief that starts at Gate 1 must also
hold Gate 2 once the plan is executing.

**Approval.** A gate is evidenced when **any** `Reply:` line in **any** of its sections carries an
approving token. A token approves unless it is one of the option tokens that keep the gate open or
leave it, or a bare `no`:

| Gate | Non-approving tokens |
|---|---|
| 1 | `details`, `refine`, `abort`, `no` |
| 2 (either face) | `details`, `refine`, `abort`, `approve` (as in `approve split`), `no` |
| 3 | `details`, `address` (as in `address findings`), `abort`, `no` |

So `yes`, `no-split <reason>` on the Complexity face, and a reply in the conversation language
all approve. `approve split` archives the parent, which spec selection already skips; it is listed
only so a parent left `in-progress` after a split is not taken as approved.

**Parse contract.** It is as tolerant as ADR 0016's section reader, and reads only two kinds of
line:

- The file is read like every other spec file here: CRs and a leading BOM removed, and every
  `<!-- ... -->` comment dropped, so a `Reply:` inside a comment never counts.
- **Headings.** A line starting `## `, trailing whitespace trimmed. `^## Gate ([123])([^0-9]|$)`
  opens a section for that gate; `^## Gate Re-plan` counts only for coverage. The rest of the
  heading (name, face, pass number) is ignored, and file order stands for time, so a misnumbered
  pass changes nothing. Any other `## ` heading closes the section; a `### ` heading does not.
- **Replies.** A line inside a gate section matching `^[ \t]*Reply:`. Its token is the text after
  `Reply:`, trimmed, with leading `` ` * _ " ' `` removed, cut at the first whitespace, with
  trailing `` . , ; : ! ? ` * _ " ' `` removed, compared case-insensitively. An empty token makes
  the line no reply. Everything else in the file - the brief body, tables, the collapsed
  decisions - is ignored.

**Reason.** Each fired rule adds one finding in ADR 0016's form, naming the gate, what is missing
(`a ## Gate 2 section in gate-briefs.md`; `a Reply: line in a ## Gate 2 section of
gate-briefs.md`; `an approving Reply: line in a ## Gate 2 section of gate-briefs.md (last reply:
refine)`) and the later-phase evidence. A feature reason then adds one sentence before ADR 0016's
closing instruction: the gate's evidence is its section and the reply on its `Reply:` line, and if
the user already answered that gate in this conversation, the model appends that answer verbatim
as the `Reply:` line, with the Edit tool (SW-105: five live runs recorded it through `printf` and
`echo`, which a restricted permission mode refuses), instead of asking again. The sentence has no
apostrophe, so PowerShell 5.1's
`ConvertTo-Json` leaves both twins' stdout byte-identical.

**Gate Re-plan has no rule.** Its heading `## Gate Re-plan - R<n>` carries no pass number, the
skill does not say whether `revise` re-asks in the same section or a new one, its protocol is shared
with `/sd:refactor` (whose briefs arrive in SW-96), and no e2e scenario reaches it. It still marks
where a brief starts.

## Alternatives considered

- **The latest pass counts.** The ticket's draft. Rejected: when close-out sends work back, the
  re-presented Gate 2 or Gate 3 is the latest pass and has no reply yet, so a session correctly
  waiting at it would be blocked. With `refine`, both readings agree, since the earlier passes are
  `refine` and the approval is in the latest. The cost of "any pass" is a known limit below.
- **Only `yes` approves.** Rejected: the reply is verbatim and may be in the conversation language
  (ADR 0019), so every non-English approval would block. The option tokens are guaranteed English,
  so the hook lists the tokens that do not approve instead. This needs no change to the skill or
  the command.
- **A missing section, or a missing file, is always missing evidence.** Rejected: it blocks every
  pre-SW-89 spec and every resumed one, including e2e `09` and `10` at their Gate 2 stop.
- **"Status `done`" as Gate 3 evidence** (the draft). Unreachable: ADR 0016's selection skips
  `done` specs. **"`06-verify.md` exists"** was rejected too: `/sd:verify` can be run on its own
  mid-work and writes the file on a fail as well, so a waiting session would be blocked. A passing
  verify happens only at close-out.
- **Amend ADR 0016 in place.** Rejected: the feature rows bring a new kind of evidence (a record
  of presentation, not a phase artifact), a coverage rule and a parse contract, and they reverse a
  0016-era fixture contract on purpose. The repository extends accepted ADRs with new ones (0019
  and 0020 extend 0018); 0016 points here.

## Consequences

- **A fixture contract changes on purpose.** `tests/hooks/fixtures/stop-gate/allow-feature-type`
  asserted that a feature spec is never blocked. It is renamed `allow-feat-no-briefs`, content
  unchanged, and now asserts the narrower contract: a feature spec with no `gate-briefs.md` is
  never blocked. Seven block and nine more allow fixtures cover the rules, the coverage rule, the
  any-pass reading, the token list (`Yes.` in bold, `no-split`, a Vietnamese reply) and a `Reply:`
  inside a comment, identically for both twins. `scripts/smoke-hooks.*` add each rule firing, and
  staying silent with the reply, at the gate and with no brief, plus the shipped
  `examples/fixture-project` spec `FEAT-todo-priority` (done, no brief) staying silent and
  unedited.
- **The nightly e2e runs these rules.** `examples/fixture-project` enables `stopGate`. On a run
  that records every reply, each stop of `02-feature-happy` is silent: at Gate 1 the spec is
  `draft`, at Gate 2 it is `approved` with no task done, at Gate 3 no verify has run, and after
  close-out it is `done`. Scenarios `06`-`10` seed specs with no brief, or produce one that starts
  at the gate they resume at.
- **Latency.** The feature path reads up to three more small files. Measured with the new case in
  `latency-selection.json` (2026-10-22, 15 iterations per case, one Windows workstation): p95
  541 ms under pwsh and 543 ms under PowerShell 5.1, against budgets of 1300 and 1000 ms. The
  budgets are unchanged.
- **Known limits:**
  - A fresh run that skips Gate 1 entirely, writing its first section at Gate 2, looks like a
    resumed spec and is not caught. The same holds for any gate before the brief's first section.
  - A gate that was approved once, re-presented after work went back, and then skipped is not
    caught: an earlier approval still counts.
  - A refusal worded in the conversation language counts as an approval. The hook catches a gate
    that was never answered, not one whose answer the model misread.
  - A turn that skips Gate 3 and also closes the spec escapes, as ADR 0016 already records for
    every `done` spec.
- **Drift.** The rows restate `/sd:feature`'s gates and `sd-gate-brief`'s heading and `Reply:`
  format. A change to either must update both hook twins and their fixtures. SW-96 (the other
  workflows adopt the brief) is where the same rules extend to `/sd:bug`, `/sd:refactor` and the
  rest, and where Gate Re-plan's section shape can be settled.
