---
description: Read-only summary of the metrics log and spec registry - what is in progress, where gates fire, where friction concentrates
argument-hint: (none) or --calibration
---

# /sd:status - metrics and registry summary

Read-only reporting command. **No spec is created, no code is changed, no gate is evaluated, and
nothing is written anywhere.** It summarises two files that already exist: the metrics log
`.specs/_metrics/events.jsonl` (written by the `spec-gate` and `subagent-retro` hooks) and the spec
registry `.specs/index.md`.

The event schema is documented in `docs/architecture.md` - see "Event log". This command reads the
**live** `events.jsonl` only. A rotated `events.jsonl.1` is a grace buffer, explicitly **not** part
of any read contract: a generation may be discarded on the next roll, so counting it would report a
window that cannot be reproduced.

Takes no argument, or the single optional flag `--calibration` (SW-31). Plain `/sd:status` never
reads anything beyond the two files above - `--calibration` is strictly additive: see Phase 3b.

## State machine

Evaluated in order. The first matching row wins. Every state produces a labelled result - an empty
report that renders like "no friction" is a defect, not an edge case.

| # | Condition | State | Behavior |
|---|---|---|---|
| ST001 | `.claude/project-config.json` missing | no-config | STOP: "No project config found - run `/sd:setup` first." |
| ST002 | `hooks.metrics.enabled` is `false` | disabled | Skip the metrics sections entirely, say so, still render Registry |
| ST003 | Metrics directory or log file absent | never-recorded | "No metrics recorded yet", still render Registry |
| ST004 | Log file present but zero bytes | empty | "Metrics log exists but is empty", still render Registry |
| ST005 | Log file present and non-empty | populated | Full report |

`.specs/index.md` missing is not a STOP - render the metrics sections and label Registry
"no spec index found".

## Phase 0 - Bootstrap

1. Read `.claude/project-config.json`. Missing -> ST001.
2. Resolve, with defaults when a key is absent:
   - `spec.dir` (default `.specs`)
   - `spec.indexFile` (default `<spec.dir>/index.md`)
   - `hooks.metrics.enabled` (default `true`; **absent means enabled**, matching the hooks)
   - `hooks.metrics.path` (default `<spec.dir>/_metrics/events.jsonl`)
3. `hooks.metrics.enabled === false` -> ST002.
4. Stat the log path. Absent -> ST003. Zero bytes -> ST004. Otherwise ST005.
5. If `<metrics.path>.1` exists, record that fact for the header line. **Do not read it.**

## Phase 1 - Count (ST005 only)

Counting is done by the shell, never by reading the file and tallying by eye. A populated log runs
to thousands of lines; an eyeballed number will not reconcile with an independent count, which is
the one property this report must have.

The schema is flat, metadata-only, one JSON object per line, in a **fixed key order** - so exact
substring counting is correct. `jq` is **not** required; when it is available it is a useful
independent oracle, not the mechanism.

Run these from the project root against `<metrics.path>` (Bash form; use `Select-String -Pattern
'...' -SimpleMatch | Measure-Object -Line` for the PowerShell equivalent):

| Number | Count |
|---|---|
| Total lines | `wc -l` |
| Well-formed lines | lines matching `^\{"ts":".*","event":"` and ending in `}` |
| Skipped lines | total minus well-formed |
| Events by kind | `grep -c '"event":"gate"'`, `'"event":"spec_transition"'`, `'"event":"subagent_stop"'` |
| Gate decisions by kind | `grep -c '"gate":"verify"'`, `'"gate":"protected"'`, `'"gate":"code-edit"'`, `'"gate":"shell-write"'` |
| Decision ratio | `grep -c '"decision":"allow"'`, `'"decision":"warn"'`, `'"decision":"block"'` |
| Extensions | `grep -o '"ext":"[^"]*"' | sort | uniq -c | sort -rn` |
| Per-spec | `grep -o '"spec_id":"[^"]*"' | sort | uniq -c | sort -rn` |
| Stale observations | `grep -c '"event":"subagent_stop","stale":1'` |
| Window | first and last `ts` values (`head -1` / `tail -1`) |

Field notes that change how a number must be read:

- `ext` is **optional even on a `code-edit` gate** - the hook omits the key when it cannot resolve an
  extension. Extension counts therefore do not sum to the `code-edit` total; never present them as
  if they do.
- `stale` is a per-event flag, `0` or `1` - not a count of retros. See Friction below.
- `shell-write` (SW-79) is a `block` recorded when a Bash / PowerShell command visibly wrote a
  protected path or the spec index - the model reached for a shell instead of the Edit tool. Its
  `spec_id` and `phase` are always `-`. List the row only when the count is non-zero.
- `spec_id` and `phase` are `-` when no spec is in scope. Treat `-` as its own bucket; do not drop it
  and do not rank it as a spec.

**Malformed lines.** A line is well-formed if and only if it starts with `{"ts":"`, contains
`"event":"`, and ends with `}`. A partially-written trailing line (the hook was interrupted
mid-append), a blank line, and any non-JSON content all fail that test. Such lines are **skipped and
counted** - never allowed to abort the report. Report the skipped count explicitly even when it is
zero: a silent skip and a clean file are not the same fact.

Decision counts are scoped to the events that carry a `decision` field (`gate` and
`spec_transition`); do not present them as a ratio over all events.

## Phase 2 - Registry

Parse `<spec.indexFile>` rows: `| ID | Type | Status | Created | Title |`. Collect specs whose
Status is `in-progress`, then `draft` / `approved` counts, then `done`. Tolerate a missing trailing
newline on the last row.

## Phase 3 - Friction

Counts say how much happened; friction says where it is stuck. Derive from the same numbers, and
present only lines that have data behind them - omit an empty friction section rather than printing
"none found" three times.

- **Blocked specs**: `spec_id` values ranked by `event: gate` + `decision: block` count. The top
  entries are where the operator is fighting the gate.
- **Repeated code-edit warns**: `spec_id` values with a high `gate: code-edit` + `decision: warn`
  count - the gate is set to warn and is being ignored repeatedly.
- **Retro pressure**: `spec_id` values ranked by **how many** `subagent_stop` events carry
  `"stale":1`. `stale` is a per-event flag (`0` or `1`), not a magnitude - the hook emits one event
  per in-progress spec per subagent stop and sets `1` when that spec's retro is stale or missing.
  Rank by occurrence count; never present a `stale` value as a quantity of retros.
- **Silent specs**: rows in the registry with status `in-progress` that appear **zero** times in the
  log. Either the work is not happening or metrics started after the spec did; say which is not
  determinable from the log.

## Phase 3b - Calibration (`--calibration` only)

Skipped entirely for a plain `/sd:status` invocation - the default read contract (`events.jsonl` +
`index.md`) is unchanged, and Phases 1-3 above already ran unmodified. When `--calibration` is
passed, additionally glob `<spec.dir>/*/02-tasks.md` and `<spec.dir>/*/03-decisions.md` for every
spec directory present, at any lifecycle status - a thin corpus needs every data point it has, not
only `done` ones.

For each spec directory found, from `02-tasks.md`:
- **Tasks**: count `### T<NN>` headings, tolerant of the `✅`-prefixed variant (`### ✅ T01`) per
  `docs/adr/0002-complexity-triage-decomposition.md`'s own warning that a naive `^### T<NN>`
  counter silently reads a checked-off task as zero.
- **Layers**: count distinct `Layer:` field values across the spec's task blocks, **excluding
  `Tests`/`Config`** per ADR 0002's own exclusion rule, so this count stays comparable to the
  threshold it is calibrating. Field values are read with the tolerant grammar in
  `skills/sd-atomic-task-format/SKILL.md` (bullet `-`/`*`, `**` optional, colon inside or outside
  the emphasis) - do not write a narrower matcher here.
- **Files**: count distinct paths across the spec's `Files:` fields, deduplicated within the spec.

From the already-loaded `events.jsonl` (fixed key order, same exact-substring counting as Phase 1):
- **Complexity-gate splits**: `grep -c '"gate":"complexity","decision":"split"'`. This is an
  inferred signal, not a direct observation - see `docs/architecture.md` "Event log" for what it
  can and cannot detect (it never sees a bare trip, only a completed split).

**Sample-size framing.** Let *n* be the number of spec directories found. When *n* is below the
CONTRIBUTING re-calibration trigger (20 closed specs), render every computed number - never hide a
count that was actually produced - but prefix the section with `insufficient data (n=<n>)` rather
than presenting the distribution as a basis for changing any threshold. This mirrors the ST002-ST004
degrade convention above: a thin corpus is a labelled state, not a silently-confident report.

## Phase 4 - Render

```
# Spec status

Window: <first ts> -> <last ts>  (<n> events, <k> skipped)
<one line only when a rotated generation exists:>
Note: an earlier generation was rotated to events.jsonl.1 and is NOT included - this
summary covers the live log only.

## In progress

| ID | Type | Created | Title |
...
(or: "No specs in progress." / "No spec index found at <path>.")

## Gate activity

| Gate | allow | warn | block | total |
|---|---|---|---|---|
| verify | ... |
| protected | ... |
| code-edit | ... |
| shell-write | ... |   (only when non-zero)

Extensions seen on code-edit gates: .cs (12), .ts (4)

## Lifecycle transitions

| Spec | From -> To | Count |
...

## Friction

- <spec>: blocked N times at the <gate> gate
- <spec>: N code-edit warns ignored
- <spec>: retro stale count reached N
- <spec>: in progress but absent from the log

<only when --calibration was passed:>

## Calibration (n=<n> specs<, insufficient data when n is below the CONTRIBUTING trigger>)

| Metric | Distribution |
|---|---|
| Tasks per spec | ... |
| Layers touched (excl. Tests/Config) | ... |
| Files touched | ... |

Complexity-gate splits observed: <count> (inferred from index.md, not a direct trip observation -
see docs/architecture.md "Event log")
```

Degrade states render the same skeleton with the metrics sections replaced by exactly one labelled
line:

- ST002 -> `Metrics recording is disabled (hooks.metrics.enabled = false). No gate data to report.`
- ST003 -> `No metrics recorded yet - <path> does not exist. Hooks write it on the first gate decision.`
- ST004 -> `Metrics log exists at <path> but is empty (0 bytes).`

Each names the reason and the path, so "quiet" is never confused with "clean".

## Hard constraints

- **Read-only.** Never write, create, or edit any file - including `.specs/_explorations/`. This
  command has no save option.
- Never invoke a subagent.
- Never start a spec lifecycle, never evaluate a gate, never modify `.specs/index.md`.
- Never read `events.jsonl.1`, and never merge it into the counts.
- Never abort the report because of a malformed line - skip it and count it.
- Never render an empty table as a result. A missing input is a labelled state (ST002-ST004), not a
  blank section.
- Stack-agnostic: this command reads only specwright's own artifacts. It never runs a build, a test
  command, or anything from `commands.*` in project-config.
- Do not guess at numbers. Every figure in the output comes from a counting command that was
  actually run; if a count could not be produced, say so in place of the number.
- `--calibration` may additionally read `02-tasks.md` / `03-decisions.md` under every spec
  directory (Phase 3b). It still never writes anything, still never reads `events.jsonl.1`, and a
  plain `/sd:status` invocation's read set is unaffected by the flag's existence.
