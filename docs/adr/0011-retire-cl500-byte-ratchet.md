# ADR 0011: retire the CL500 byte-budget ratchet for a release-time size report

- Status: accepted
- Date: 2026-09-24
- Source spec: Jira SW-57
- Relates to: ADR 0006 (cross-file contract lint); `docs/contract-lint.md` ("Prompt size report")
- Supersedes: ADR 0006 decision 7 ("A budget raise is a reviewed decision")

## Context

`CL500` (SW-35, wave 4) warned when a file in `contractLint.scanScope` exceeded
`contractLint.budgets.<area>Bytes`. Each budget was set at today's largest file in its area, and
raising one was meant to be "a real decision that belongs in a PR description". It stayed WARN
forever, and validate's Check 8 exempted it from `warnBudget` so that a legitimate raise could not
fail the build.

In the 1.6.0 cycle alone the changelog recorded a defence for every raise. SW-57 asked for a count
rather than an impression: did the ratchet ever change what landed?

## Evidence (AC-1)

**Fires on pushed commits.** The linter was replayed with `bash scripts/contract-lint.sh --root`
against every first-parent commit from `0a6c837` (SW-35, which introduced the rule) to `2f81b5f`
(SW-56), 37 commits in all. `CL500` fired **0 times**.

**Fires at authoring time.** Each budget-raising commit was replayed against the *previous*
commit's budgets. That shows what the author saw locally before raising the number:

| Commit | File that fired | Over by | Resolution |
|---|---|---|---|
| SW-37 `81b3fd3` | `agents/spec-architect.md` | 217 | `agentsBytes` 14454 -> 14671 |
| SW-38 `d165296` | `agents/spec-architect.md` | 561 | `agentsBytes` 14671 -> 15232 |
| SW-38 `d165296` | `commands/spec.md` | 3686 | `commandsBytes` 25978 -> 29664 |
| SW-38 `d165296` | `skills/sd-spec-templates/SKILL.md` | 1522 | `skillsBytes` 9134 -> 10656 |
| SW-40 `d0e81b3` | `skills/sd-port-fidelity/SKILL.md` | 1721 | `skillsBytes` 10656 -> 12377 |
| SW-41 `78a766d` | `skills/sd-port-fidelity/SKILL.md` | 35 | `skillsBytes` 12377 -> 12412 |
| SW-42 `fa6ea38` | `commands/spec.md` | 3013 | `commandsBytes` 29664 -> 32677 |
| SW-49 `894cb4c` | `commands/spec.md` | 4517 | `commandsBytes` 32677 -> 37194 |

That is **8 fires, 8 raises, and 0 trims**. Every raise landed in the same commit as the growth,
and every one set the ceiling to the file's exact new size, leaving zero headroom. By
construction, the next edit to that file would fire again. The budget never moved down.

**What it could not see.** Only the largest file in an area sets its ceiling, so growth anywhere
else goes unnoticed until that file becomes the largest. `scripts/prompt-size-report.sh --since
0a6c837` shows what went unseen over the same window:

- `commands/explore.md` grew +179.5% (4037 -> 11285 bytes) and `agents/code-explorer.md` grew
  +91.4%. Neither was ever checked, because each area's largest file (`commands/spec.md`,
  `agents/spec-architect.md`) held the ceiling.
- SW-54 shrank every command it edited (for example `commands/feature.md` by 337 bytes), but
  its AC-6, "`commandsBytes` goes down", could not be met. `commands/spec.md`, which it did not
  touch, sets the ceiling.

So the mechanism produced a discussion on every fire and a changed outcome on none. Meanwhile the
largest relative growth in the repo went unseen.

## Decision

Retire `CL500` and `contractLint.budgets`. Keep the concern: prompt bloat is a real cost, paid on
every invocation, and a file that outgrows what the model reliably reads fails quietly. Move it
into **`scripts/prompt-size-report.{sh,ps1}`**, an advisory report read once per minor release. The
report shows every in-scope file's normalized size at the previous release tag, its size now, the
delta and the percentage, then a total for each area. A file that grew more than
`promptSizeReport.flagGrowthPercent` (15) is marked `FLAG` and needs a trim-or-justify line in
that release's changelog. The cadence, what a normal release looks like, and the signs that this
has also stopped working are in `docs/contract-lint.md`.

**Why this option (AC-2).** The four options SW-57 listed were weighed against the evidence above:

- **Keep as is.** Rejected: 0 catches in 8 fires, and blind to every file except the largest.
- **Change the unit to per-file ceilings.** Rejected: it fixes the blind spot but multiplies the
  thing that failed. About 30 hand-maintained numbers would each need the same zero-headroom
  raise, so there would be more bumps, not fewer. A growth rate was the right unit. A per-run
  growth rate, though, needs a stable baseline, and "since the last release" is the only one
  every contributor shares.
- **Advisory with a release-time report.** Chosen. The unit is growth per release, measured on
  every file. There is no stored number to ratchet, and the threshold is a rate, so it does not
  drift upward with the files it measures. It costs nothing per PR.
- **Remove it outright.** Rejected: that drops the concern along with the mechanism, and the
  report above shows the concern is real.

**AC-3 does not apply.** AC-3 required that a budget change never hide inside a large diff. With
the ratchet gone there is no stored number to change. The only tunable, `flagGrowthPercent`,
lives in the manifest. Changing it is a single-line manifest diff, and the cadence in
`docs/contract-lint.md` names "raising the threshold to make a release come out clean" as a
failure signal.

## Consequences

**Positive.** Nothing to bump per PR, so no reflexive-bump churn and no changelog defences. Every
file's growth is visible, not only the largest one's. Shrinkage is visible too, so a refactor like
SW-54 can finally show its effect.

**Negative, stated plainly.** Prompt growth is no longer seen per PR. A file can grow a lot within
one release cycle, and nobody reads that until release time. The report only helps if someone
reads it: an unread report is weaker than a WARN that could not be ignored, even one that was
always raised. The cadence's first failure signal, "skipped for two releases", exists for that
case.

**Rule-id bookkeeping.** `CL500` is removed from both linters' dispatch lists, from the manifest
registry and from every fixture manifest. Its two fixtures are deleted. The id is left unused
rather than reassigned. Check 8's `warnBudget` exemption now covers only `CL202`.

**Deliberately not built.** Automatic multi-release trend detection: "grew three releases in a
row" is checked by re-running `--since` against older tags. Also not built: a CI step that runs
the report on this repo. CI clones shallow and has no tags, and the report is a release-time
reading, not a gate.
