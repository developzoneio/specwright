# ADR 0004: threshold calibration returns "insufficient data" - ships measurement, not new numbers

- Status: proposed
- Date: 2026-08-09
- Source spec: Jira SW-31 (`FEAT-threshold-recalibration`)
- Relates to: SW-13 (ADR 0002, Gate Complexity thresholds); SW-10 / SW-16 (metrics log and
  `/sd:status`); SW-30 (second example corpus)
- Supersedes: none

## Context

SW-31 asks for a repeatable calibration pass: turn accumulated `.specs/_metrics/events.jsonl` and
spec-artifact data into evidence for or against each threshold the engine enforces - Gate
Complexity (tasks > 8, layers > 2, files > 8, from ADR 0002), `retroStaleMinutes` (30),
`debounceMinutes` (10), `maxLessons` (3), `metrics.maxSizeKb` (1024), and the perf gate's 5% noise
floor - plus a standing ritual so calibration happens again.

Running that pass against this repo's actual state surfaced two things the ticket's own text
didn't anticipate:

1. **The corpus is thinner than "n=1 risk" implies.** specwright does not dogfood itself - there is
   no `.specs/` directory in this repo at all (a deliberate decision, recorded in ADR 0010).
   `examples/fixture-project`, the second corpus SW-31
   was waiting on (SW-30), has exactly **one** closed spec (`FEAT-todo-priority`) and no
   `events.jsonl` history. Real accumulated data is n=1, not a "canyon" or a "cluster" - there is
   nothing to fit a distribution to yet.
2. **Gate Complexity trips were never recorded.** The event schema
   (`docs/architecture.md`, "Event log") only ever emitted `gate: verify|protected|code-edit`.
   Gate Complexity (ADR 0002) is decided as model-executed prose inside `/sd:feature` Phase 3 Gate
   2 - ADR 0002 itself names this an accepted, unresolved limitation ("no script... exercises the
   threshold arithmetic... automatically"). Before this ADR, there was no path to ever answering
   "what is the trip rate" from measured data, regardless of corpus size.

Per ADR 0002's own "Scope declined" precedent, this ADR ships the machinery to close gap (2)
**partially** - split detection only, not full trip-rate - and accepts gap (1) as the honest
current state rather than manufacturing evidence from a single spec ("Re-fitting to the same five
specs would launder a guess as data" - SW-31's own note, which applies at n=1 even more directly
than the n=5 case it was written about).

## Decision

1. **New inferred metric: `gate:"complexity"` / `decision:"split"`.** `spec-gate`
   (`hooks/bash/spec-gate.sh`, `hooks/powershell/spec-gate.ps1`) now watches every `index.md` edit
   for the structural trace a completed Gate Complexity split leaves behind: a `FEAT-X` row newly
   transitioning to `archived` alongside any `FEAT-X-<slug>` row already registered (on disk or in
   the same pending edit), per `commands/feature.md`'s Face B "approve split" steps. This is
   observational only, computed from data the workflow already writes - no change to
   `commands/feature.md`'s Gate 2 (a HARD gate) or `agents/spec-architect.md` was made or is
   needed. It is emitted **only when the edit is actually allowed through**, never on a `block`
   exit - a denied edit never reaches disk, so a detected pattern inside it did not really happen.
   Under the default config, `.specs/index.md` is itself listed in `paths.protected`
   (`templates/project-config.template.json`), so most direct `index.md` edits are already blocked
   before this metric ever gets a chance to fire (`docs/architecture.md`'s existing note on the
   `decision` field: "Most direct index edits are blocked by `paths.protected`, so `block` is the
   common case"). That is a pre-existing, documented property of `spec-gate`, not something this
   ADR introduces or changes - but it does mean the split count will under-count real splits on
   any project that leaves `index.md` protected, which is the default. Fixing that tension (how
   `/sd:feature`'s own Gate 2 writes are meant to reach a protected `index.md` at all) is out of
   scope here; `commands/spec.md` already carries the same open tension for the `done` transition
   via its `verifyGate` carve-out.
2. **`/sd:status --calibration`.** A new optional view (`commands/status.md`, Phase 3b) reports
   task/layer/file distributions read from spec artifacts, plus the `gate:"complexity"`/`split`
   count from `events.jsonl`. The default `/sd:status` invocation's read contract is unchanged.
3. **The five non-Gate-Complexity thresholds are marked as judgement calls**, not measured values,
   directly in `templates/project-config.template.json` (`_retroStaleMinutes_use`,
   `_debounceMinutes_use`, `_maxLessons_use`, matching the existing `_maxSizeKb_use` caveat). Gate
   Complexity is left as-is; ADR 0002 already recorded its measured basis (the SW-13 corpus trace),
   which nothing in this ADR revisits or invalidates.
4. **Calibration verdict, this run: insufficient data, for every threshold.** n=1 closed spec
   across both corpora, zero real `gate:"complexity"` events (the metric only exists as of this
   ADR), zero real `events.jsonl` history outside test fixtures. No threshold changes size on this
   run - per SW-31's own acceptance criterion, this is the honest and expected outcome at this
   corpus size, not a failure of the calibration pass.
5. **CONTRIBUTING names the re-calibration trigger**: every 20 closed specs, or each minor release,
   whichever comes first (SW-31's own proposed cadence). The next run of `/sd:status --calibration`
   is the mechanism that answers whether that bar has been met.

## Consequences

**Positive.** Real calibration becomes possible going forward without re-opening this ticket - the
next `/sd:status --calibration` run after real specs accumulate reads live data instead of nothing.
The judgement-call caveats make future readers of `project-config.template.json` unable to mistake
an untuned default for a measured one.

**Negative.** `gate:"complexity"`/`split` cannot detect a bare trip (Face A vs. Face B "no-split"
look identical in `index.md`) - see "Scope declined" below. The split-detection heuristic itself is
best-effort: two unrelated specs that happen to share an id prefix (`FEAT-auth` / `FEAT-auth-v2`)
would misread as parent/child. Acceptable for an observational, non-gate-affecting metric, same
class of limitation the file already accepts elsewhere (Rule 0's bundled-edit limitation).
Recording only on an allowed edit (see Decision 1) means the metric under-counts on any project
that leaves `index.md` protected by default - it will report fewer splits than actually occurred,
never more; a project relying on this signal needs to make the archive-plus-child edit reachable.

**Scope declined.** Full trip-rate instrumentation (recording every Gate 2 resolution, not only
completed splits) is **not** built here. The only way to observe it directly is a marker the
architect or the `/sd:feature` command writes at Gate 2 resolution time - and making a HARD gate's
prose responsible for reliably feeding a metrics pipeline would break the invariant
`docs/architecture.md` states plainly: "`spec-gate` and `subagent-retro` are the hooks that
record." A future spec that wants full trip-rate should design the instrumentation around a
deterministic, hook-observable signal (or accept a model-authored marker as an explicit, separate
trade-off) rather than retrofitting it into this "cheap ticket."

## Follow-up

Re-run this calibration once `.specs/index.md` (or `examples/fixture-project/.specs/index.md`)
records at least 20 closed specs, or at the next minor release - whichever comes first, per
CONTRIBUTING. A future ADR should supersede this one with the first real verdict.
