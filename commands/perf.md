---
description: Baseline-first performance workflow. Target -> baseline -> hotspot -> per-hotspot loop (hypothesize / apply / measure / keep-or-revert) -> regression -> final review. 8 hard gates.
argument-hint: <endpoint or slug>
---

# /sd:perf

Drives an optimization from a measured baseline to a measured improvement, with one change at a time and a keep-or-revert decision per change. Result under `.specs/PERF-<slug>-<YYYYMMDD>/`.

**Argument**: `$ARGUMENTS` -> spec ID = `PERF-<slug>-<YYYYMMDD>`.

---

## HARD RULES (read before every phase)

1. **NEVER optimize without a measured baseline.** "It feels slow" is not a baseline. The number must be reproducible.
2. **One change at a time, each measured.** Multiple simultaneous changes invalidate attribution.
3. **Revert if no measurable improvement.** Keep only changes that move the metric beyond measurement noise.
4. **Correctness > speed.** A faster wrong answer is still wrong. All functional tests must continue to pass.
5. **Don't optimize what already meets SLA.** If the target already meets the goal, the workflow exits at Gate 2 with no work done.

---

## State machine (resume behavior)

| Detected state | Action |
|---|---|
| Folder not found | Start at Phase 1 |
| `00-spec.md` Target filled, "Current observed" empty | Resume Phase 2 |
| Baseline measured (Results log has row 0), no hypothesis tree | Resume Phase 3 |
| Hotspot identified, no per-hotspot rows attempted | Resume Phase 4 |
| At least one attempted row, no keep/revert decision | Resume Phase 4 (mid-loop) |
| Decisions complete, no Phase 5 regression run | Resume Phase 5 |
| Regression passed, no final review | Resume Phase 6 |
| status `done` | Refuse |

---

## Phase 0 - Bootstrap

1. Read `~/.claude/skills/sd/sd-bootstrap-guard/SKILL.md` and apply it before anything else here -
   it owns the Layer-2 reads and all of their messages (commands cannot load skills via
   frontmatter, so it is read at runtime). If that file is unreadable, STOP: "specwright install
   incomplete - bootstrap guard skill not found under `~/.claude/skills/sd/`. Re-run the installer."
2. Compute UTC date for spec ID.
3. Detect state. Print resume plan.

---

## Phase 1 - Define target

1. Invoke `sd-spec-architect` with:
   - `TASK = create`
   - `TEMPLATE = perf.template.md`
   - `SPEC_ID = PERF-<slug>-<YYYYMMDD>`
2. Architect fills Target (metric, goal SLA, environment, load profile, workload type), Measurement methodology, Constraints, Out of scope.
3. Architect leaves **Current observed EMPTY** and **Results log EMPTY**. These are filled by measurement, not by assumption.
4. Register in `.specs/index.md` with status=`draft`.

### ⛔ Gate 1 - Target defined

STOP. Display Target + Methodology. Ask:

> Target and methodology approved? Note: nothing is optimized until baseline is measured. (yes / refine / abort)

- `yes` -> status=`approved`, append to index, proceed.

---

## Phase 2 - Baseline measurement (HARD)

1. Set up the measurement per "Measurement methodology" (tool, test script, warm-up, duration, reps, DB state, cache state).
2. Run the measurement. Save raw output to `.specs/PERF-<slug>-<YYYYMMDD>/04-artifacts/baseline-<YYYYMMDD-HHmm>.json` (or .txt for human-readable summary).
3. Fill `00-spec.md` Target "Current observed" with measured numbers (p50, p95, p99, req/s, CPU, memory).
4. Add **row 0** to the Results log:

```
| 0 | <date> | baseline (no change) | <p50> | <p95> | <p99> | <req/s> | <CPU> | <mem> | baseline |
```

### ⛔ Gate 2 - Baseline measured (HARD)

STOP. Two cases:

**Case A: baseline already meets SLA goal.**
<!-- contract-lint: allow CL305 - Case A is the already-at-goal branch; 'proceed anyway' there buys a logged constitution exception, not a way past the baseline requirement, which stays unconditional -->
> Baseline p95=<X> already meets SLA goal p95<<goal>. No optimization needed. Close PERF-<slug> as 'done' with no changes? (yes / proceed anyway / abort)
- `yes` -> set status=`in-progress` (no hotspot work occurs, but the state machine has no
  approved -> done shortcut), then jump to Phase 6 close-out with summary "no work needed".
<!-- contract-lint: allow CL305 - same exception as the option line above; the bullet only explains what selecting it costs -->
- `proceed anyway` -> requires explicit constitution exception ("optimizing past SLA"). Log to retro.

**Case B: baseline below SLA goal.**
> Baseline p95=<X>, goal p95<<goal>. Proceed to hotspot analysis? (yes / refine methodology / abort)

This gate is HARD - the workflow CANNOT enter Phase 3 without a checked-in baseline artifact and a filled Results log row 0.

---

## Phase 3 - Identify hotspot

1. Invoke `sd-debugger` with:
   - `TASK = hotspot-analysis`
   - `SUB_MODE = A`
   - `SPEC_REF = .specs/PERF-<slug>-<YYYYMMDD>/00-spec.md`
   - `BASELINE_ARTIFACT = .specs/PERF-<slug>-<YYYYMMDD>/04-artifacts/baseline-<...>.json`
2. Debugger's job: identify the 80/20 hotspots from profile data, query plans, or code reads. Output: ranked list of hotspots with file:line citations and contribution percentage to total latency / CPU / memory.
3. Main thread appends the returned hotspot ranking to `03-decisions.md` (debugger has no write tool).

### ⛔ Gate 3 - Hotspot identified

STOP. Display hotspot ranking. Ask:

> Select hotspot to attack first: <H1>, <H2>, ... (choose / refine / abort)

- `choose <H#>` -> proceed with that hotspot.
- `refine` -> loop with debugger for more data.

---

## Phase 4 - Per-hotspot loop

Set status=`in-progress`, update index (once, on first entry to this phase).

For each selected hotspot, repeat this entire loop. Multiple hotspots = multiple loop iterations.

### 4a. Deep dive

1. Invoke `sd-debugger` with:
   - `TASK = hotspot-analysis`
   - `SUB_MODE = B`
   - `HOTSPOT = <H# details>`
2. Debugger produces 2-4 optimization hypotheses (not a single answer), each with:
   - Expected impact (e.g. "p95 -200ms based on current 350ms in this function").
   - Implementation cost (S / M / L).
   - Risk profile (correctness risk, scope of change, reversibility).
3. Main thread appends the returned hypotheses to `03-decisions.md` (debugger has no write tool).

### ⛔ Gate 4 - Select hypothesis

STOP. Display hypotheses. Ask:

> Select hypothesis to apply: <H#a>, <H#b>, ... (choose / abort hotspot / abort workflow)

- `choose` -> proceed to 4b.
- `abort hotspot` -> mark hotspot as deferred, return to Phase 3 with remaining hotspots.

### 4b. Apply

1. Invoke `sd-implementer` with:
   - `TASK_DETAILS = <hypothesis details + target files>`
   - `SPEC_REF = .specs/PERF-<slug>-<YYYYMMDD>/00-spec.md`
   - `IMPACT_REF = .specs/PERF-<slug>-<YYYYMMDD>/03-decisions.md` (hotspot analysis)
   - `WORKFLOW_TYPE = perf`
   - `CONSTRAINTS = <Constraints section: correctness must hold>`
2. Implementer applies the change. ONE hypothesis at a time - no bundling.

### 4c. Correctness tests

1. Run the full test suite via `commands.test`.

### ⛔ Gate 5 - Correctness verified

STOP. Display test results.

- All green -> proceed to 4d.
- Any red -> REVERT immediately. Log failed attempt to Results log with `reverted` decision. Loop back to Gate 4 to select a different hypothesis.

### 4d. Re-measure

1. Re-run the baseline measurement under IDENTICAL conditions to Phase 2.
2. Save artifact to `04-artifacts/attempt-<N>-<YYYYMMDD-HHmm>.json`.
3. Add row to Results log:

```
| <N> | <date> | <hypothesis short name> | <p50> | <p95> | <p99> | <req/s> | <CPU> | <mem> | pending |
```

### ⛔ Gate 6 - Keep or revert decision

STOP. Compare new measurement to previous best in Results log. Display:
- Previous p95 -> new p95 (delta).
- Whether the improvement exceeds measurement noise (rule of thumb: must be > 5% AND >= absolute noise
  floor of the methodology).

Branch on the noise check - the gate offers different choices depending on whether the gain is real:

**Case A - improvement is measurable** (> 5% AND >= noise floor). Ask:

> Keep change or revert? (keep / revert)

- `keep` -> update row decision to `kept`. Commit. Loop back to Gate 4 with the next hypothesis OR finalize this hotspot if SLA now met.
- `revert` -> update row decision to `reverted`. Revert the code. Loop back to Gate 4.

**Case B - within noise** (no measurable improvement). A plain "keep" here is a constitution violation:
either the improvement is real and measurable, or it does not exist. Default to revert. Ask:

> Within measurement noise - no real improvement. Default: revert.
> To keep anyway, state a constitution-exception reason; it will be logged. (revert / keep-with-reason)

- `revert` (default) -> update row decision to `reverted`. Revert the code. Loop back to Gate 4.
- `keep-with-reason` -> allowed ONLY with an explicit written reason. Update the row decision to
  `kept (exception)` with that reason, and log a constitution exception to `05-retro.md`
  (`Constitution exception: kept within-noise change at <hotspot>. Reason: <reason>.`). Commit, then
  loop back to Gate 4. With no reason supplied, this option is refused and the change is reverted.

Continue the loop until:
- SLA goal is met (jump to Phase 5), OR
- All hypotheses exhausted without meeting SLA (jump to Phase 5 with documented gap), OR
- User aborts the workflow.

---

## Phase 5 - Regression check

1. Run the full test suite via `commands.test` (one more time, as the final pre-close gate).
2. Run lint via `commands.lint`.
3. Re-run baseline measurement one final time to confirm the kept improvements are stable.
4. Add a final row to Results log labeled "final".

### ⛔ Gate 7 - Regression pass

STOP. Display final test results + final measurement. Ask:

> All clean and stable for final review? (yes / investigate / abort)

- `yes` -> proceed.
- `investigate` -> drop back to debugger if a regression appeared.

---

## Phase 6 - Final review + Close-out

1. Invoke `sd-reviewer` with:
   - `TASK_TYPE = perf-final`
   - `SPEC_REF = .specs/PERF-<slug>-<YYYYMMDD>/00-spec.md`
   - `CHANGED_FILES = <all files touched across kept attempts>`
   - `RESULTS_LOG = <Results log>`
2. Reviewer checks: correctness preserved (no test edits to make them pass), no behavior change beyond what spec accepted under "Trade-offs", no new constitution exceptions, no static state introduced, no type-safety escapes for the project's language (as defined in `constitution.md`) sneaked in.

### ⛔ Gate 8 - Final review pass

STOP. Display reviewer verdict. Ask:

> PERF-<slug> close-out? (yes / address findings / abort)

- `yes` -> proceed to close-out.
- Any 🔴 BLOCK -> loop to implementer or revert.

### Close-out

1. Fill "Trade-offs accepted" section in `00-spec.md` (what generality / simplicity / freshness / memory was given up for the speed).
2. Append to `05-retro.md`:
   - Baseline -> final measurement.
   - Kept changes (with file references).
   - Reverted attempts (with reasoning).
   - Hotspots deferred (if any).
   - Constitution exceptions (should be none).
3. **Spawned specs**: re-read the "Hotspots deferred" and "Reverted attempts" entries just written
   to 05-retro.md, plus the trade-offs accepted in `00-spec.md`, and look for follow-up work that
   has no home: a hotspot not taken, a reverted approach worth retrying under different
   constraints, a trade-off that should be revisited. For each one, ask the user to reserve an ID
   and add a row to `00-spec.md`'s `## Spawned specs` table (`Reserved ID | Type | Title | Owner`).
   This is a prompt, not a gate: nothing deferred, or the user declines - leave the table at
   header + separator and proceed. Do NOT create the child specs here, and do NOT add a reserved
   ID to `.specs/index.md`; an index row exists only once the real spec directory does (see
   `/sd:spec`, "Index <-> folder symmetry").
4. Set status=`done`. Update index.
5. Print 5-line summary: target, baseline, final, kept attempts, deferred hotspots.

---

## Rules (hard constraints)

- Change `.specs/index.md` and any spec `status:` field with the Edit tool only - never a shell
  command (`sed -i`, `>`, `tee`, `Set-Content`). spec-gate checks an Edit-tool change (Rules 0,
  0b, 1) and records its `spec_transition`; a shell write skips both (SW-79).
- Gate 2 (Baseline) is HARD. No optimization work without a checked-in baseline artifact.
- One change per attempt. Bundled changes invalidate measurement.
- Revert on no measurable improvement. The Results log is the source of truth.
- Reverted attempts are LOGGED, not deleted. They are knowledge.
- Correctness tests must remain unchanged. If the optimization requires changing a test, it changes behavior - that needs a FEAT-* or BUG-* spec, not PERF-*.
- Database access (via the project's MCP tool or CLI) for hotspot analysis is read-only: SELECT / EXPLAIN only.
- If SLA cannot be met after exhausting hypotheses, close the PERF spec with the documented gap and lessons. Do not "ship anyway".
