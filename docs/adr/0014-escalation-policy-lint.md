# ADR 0014: escalation policy lint - CL6xx and an assertable copy of the trigger table

- Status: accepted
- Date: 2026-09-26
- Source spec: Jira SW-63 (epic SW-58, adaptive model escalation)
- Relates to: ADR 0002 (decision 5, sanctioned escalation; "Unresolved" names the missing CI
  coverage); ADR 0006 (contract lint); ADR 0013 (the override mechanism, and why a served-model
  claim needs a transcript); SW-60 (`skills/sd-model-escalation/SKILL.md`), SW-61 and SW-62
  (the rows it holds today)
- Supersedes: none

## Context

After SW-62 the escalation policy spans `/sd:feature`, `/sd:bug`, `/sd:rca`, `/sd:refactor`,
`/sd:perf` and `/sd:port`, with a trigger table of eleven rule IDs. All of it was prose. ADR 0002
already named the gap for one workflow: the gate is "model-executed prose with no CI coverage".
Accepting that again would have shipped a dozen unenforced claims.

The repo's own history says what happens to an unenforced claim. SW-20: a hardcoded count made
two selftest scenarios stop biting. SW-24: spelled-out inventory numbers slipped past a digits-only
pattern. SW-28: a version claim sat stale because nothing read it. Each stayed wrong until
something happened to look.

## Decision

1. **The manifest carries an assertable copy of the trigger table.**
   `contractLint.escalationTriggers` holds one row per rule ID (`id`, `command`, `phase`, `agent`,
   `from`, `to`). `contractLint.escalationPolicy` declares the ladder, the alias set and CL605's
   phrase vocabulary. The skill stays the single owner of the policy; the copy exists so that a
   check can fail when the two disagree. It nests under `contractLint`, not at the top level,
   because every lint setting lives there (`docs/contract-lint.md`, "Manifest surface").

2. **The copy is declared, not derived.** Deriving the rows from the skill's table would compare
   the table against itself and pass forever - the vacuous-claim failure Check 7 exists to catch.
   It passes the manifest's own test for a declared contract: nothing on disk is a second source
   for it.

3. **Five rules, one band (CL6xx).** CL5xx is retired and stays unused (ADR 0011).
   - `CL601` - a command that invokes an agent has an escalation row, or an `allow CL601` comment
     with a reason; a command with rows references the skill; every row's command names its ID.
     This is the rule that makes a forgotten workflow fail loudly.
   - `CL602` - manifest rows and skill table agree both ways, field by field, and no file outside
     the skill cites an `ESC-` ID that no row declares.
   - `CL603` - `from` and `to` are aliases. It overlaps validate's Check 4 on purpose: Check 4
     reads agent frontmatter, this reads the escalation path.
   - `CL604` - the manifest ladder equals the skill's `## Ladder` line, and every row is exactly
     one rung up it.
   - `CL605` - no command restates the ladder, a precedence rule or the retro line format.

4. **The band is switched on by the skill existing on disk,** never by the manifest keys.
   Deleting `escalationTriggers` fails CL602 instead of quietly turning the band off. The skill
   name is a constant in both linters for that reason.

5. **Invocation detection reuses the CL1xx anchor index** rather than adding a second parser, and
   CL601 reports on a command's first invocation so a one-line allow comment above it can carry
   the exemption. Findings about the manifest land on `specwright.manifest.json`, which sits
   outside `scanScope`, so no suppression can reach them.

6. **The retro line gets its own validator**, `scripts/validate-escalation-lines.{sh,ps1}`, not an
   extension of `validate-lessons.*`. That script guards the privacy and grammar of
   `lessons.md`; this one checks each `escalation:` line in a `05-retro.md` against the manifest
   rows: known rule ID, the rule's agent and `from`, alias-only tiers, and exactly the rule's
   one-rung `to` (or, for `capped`, a tier between `from` and the rule's `to`). One source of
   truth: it reads the same manifest rows the linter does. CI runs it on a clean and a bad
   fixture and asserts that every bad line is rejected, not only that the exit code is non-zero.

7. **Exemptions are counted.** At landing, three `allow CL601` comments were taken, each a
   decision that a workflow has no row: `/sd:adr` (`sd-docs-writer`), `/sd:explore`
   (`sd-code-explorer`) and `/sd:review` (`sd-reviewer`). The explore and review ones replace the
   `sd-model-escalation: no rule` markers SW-62 left for this rule; the ADR one is new, because
   `/sd:adr` invoked `sd-docs-writer` with no escalation decision at all - the first thing CL601
   found. `docs/contract-lint.md` keeps the table.

## Known limits

- **Green lint means the policy is stated consistently, not that it ran.** CL6xx cannot see
  whether a subagent was served the escalated model. A reader must not take a clean Check 8 as
  verified behaviour; a check that appears to prove more than it does is worse than no check.
- **The escalation-line validator checks a statement.** An `escalation:` line is what the main
  thread wrote before the invocation. ADR 0013 is explicit that a retro line is not evidence of
  the served model; only `message.model` in a transcript is.
- **No behavioural e2e scenario was added.** `tests/e2e/run-e2e.ps1` cannot assert a model per
  subagent invocation. It reads only workspace files and the final `--output-format json`
  result, whose `modelUsage` is a per-session aggregate, and it runs with
  `--no-session-persistence`, so no per-call transcript exists to read. ADR 0013 item 5 keeps
  that flag, because artifact assertions do not need transcripts. Served-model evidence stays
  with the manual, paid `tests/e2e/probe-model-override.ps1` (subagent `meta.json` plus
  `message.model`). Turning that into a scenario assertion would reverse ADR 0013 item 5 and the
  harness README's "never assert on transcripts" rule, and needs its own ADR.
- **CL605 matches a phrase list.** A restatement in wording the list does not carry passes. The
  list is hand-maintained, the same category as `bootstrapGuardPhrases`.
- **CL601 trusts "names the rule ID" as "applies the rule".** A command that cites `ESC-FEAT-04`
  in an unrelated sentence satisfies it. The trigger inputs and the placement of the check are
  still reviewed by a person.
- **No byte-budget coordination was needed.** SW-63's ticket asked not to bump the `CL500`
  budget a fifth time. `CL500` was retired by SW-57 before this landed (ADR 0011); growth in the
  command files touched here shows up in the next release's prompt size report instead.

## Consequences

**Positive.** Adding a trigger row is now a deliberate three-place edit - the skill table, the
manifest row, the command that cites it - and missing any one fails CI. A new workflow that
invokes a subagent cannot ship without either a row or a written reason. The retro line format
is checked mechanically wherever a consumer runs the validator.

**Negative.** The trigger table is written down twice, and editing it means editing both. That is
the price of a check that can fail; the same trade `contractLint.gates` made for gate counts.
