---
description: Spec registry management. Pure file ops on .specs/ - no subagent invocation, no code changes.
argument-hint: <subcommand> [args...]
---

# /sd:spec

Dispatcher for spec registry operations. **No code is changed. No subagent is invoked.** All operations are file-system reads on `.specs/` with controlled writes to `.specs/index.md` and the target spec's frontmatter / `05-retro.md`.

**Usage**: `/sd:spec <subcommand> [args...]`

If `<subcommand>` is omitted or not recognized, run the `help` subcommand.

---

## Subcommands

| Subcommand | Args | Purpose |
|---|---|---|
| `list` | `[type] [status]` | List specs filtered by type and/or status |
| `show` | `<ID>` | Display one spec's frontmatter + section summary |
| `status` | `<ID> <new-state>` | Transition lifecycle state (with validation) |
| `link` | `<ID-A> <relation> <ID-B>` | Record cross-reference |
| `archive` | `<ID>` | Move from `done` to `archived` |
| `revive` | `<ID> [reason]` | Move from `archived` back to `in-progress` |
| `search` | `<term>` | Full-text search across spec bodies |
| `validate` | `[ID or --all]` | Validate frontmatter + structure |
| `stats` | - | Counts by type / status; aging report |
| `help` | - | This list |

---

## Phase 0 - Bootstrap (always)

1. Read `.claude/project-config.json` for `spec.dir`, `spec.indexFile`, `spec.prefixes`, `spec.lifecycle`.
2. Verify `.specs/index.md` exists. If not, prompt: "No spec index found. Run `/sd:setup` first."
3. Dispatch to the requested subcommand.

---

## list

Args:
- `[type]` (optional): one of `feature`, `bug`, `refactor`, `perf`, `rca`, `port`. Filters by type prefix.
- `[status]` (optional): one of the lifecycle states. Filters by current state in index.

Behavior:
1. Parse `.specs/index.md` rows.
2. Apply filters.
3. Output a markdown table: ID | Type | Status | Created | Title.

Example:
```
/sd:spec list bug in-progress
/sd:spec list feature
/sd:spec list -- in-progress    (status only, double-dash signals positional skip)
```

---

## show

Args:
- `<ID>` (required): full spec ID, e.g. `FEAT-INV-2501`.

Behavior:
1. Resolve folder `.specs/<ID>/`.
2. Read `00-spec.md`. Display:
   - Frontmatter (id, type, status, created, jira/severity if present).
   - First H2 (title or "Why").
   - Status of each phase artifact: which of `00-spec.md`, `01-plan.md`, `02-tasks.md`, `03-decisions.md`, `04-artifacts/`, `05-retro.md`, `06-verify.md` (written by `/sd:verify`; gates the `done` transition) exist.
3. If `02-tasks.md` exists, show task completion count `N/M`.
4. Print folder URL: `file://<absolute path>`.

---

## status

Args:
- `<ID>` (required).
- `<new-state>` (required): one of `draft`, `approved`, `in-progress`, `done`, `archived`.

Behavior:
1. Read current status from `.specs/<ID>/00-spec.md` frontmatter.
2. Validate transition against the state machine:

```
draft -> approved
approved -> in-progress
in-progress -> done
done -> archived
archived -> in-progress (only via 'revive', with reason)
```

The `in-progress -> done` transition of a feature (FEAT) spec is hook-enforced: spec-gate
blocks the `index.md` edit unless `<spec.dir>/<ID>/06-verify.md` exists and records
`result: pass`. Run `/sd:verify <ID>` first. Disable only via `hooks.specGate.verifyGate: false`
in project-config. spec-gate lets any other `index.md` edit through
only if it adds a draft row or changes just a Status cell legally.

3. Illegal transitions are REFUSED. Do NOT mutate any file. Print a refusal that names the current
   state, the requested state, the valid next state(s) for the current state (from the machine above),
   and - when the requested state is reachable - the shortest legal path to it:

```
Refused: cannot move <ID> from '<current>' to '<requested>'.
Valid next state(s) from '<current>': <list, or 'none (terminal)'>.
To reach '<requested>', follow: <current> -> ... -> <requested>.   (omit this line if unreachable)
```

   Example - `status SPEC-123 done` while `SPEC-123` is `draft`:

```
Refused: cannot move SPEC-123 from 'draft' to 'done'.
Valid next state(s) from 'draft': approved.
To reach 'done', follow: draft -> approved -> in-progress -> done.
```
4. On valid transition:
   - If this is an `in-progress -> done` transition of a feature (FEAT) spec: BEFORE mutating
     any file, check `<spec.dir>/<ID>/06-verify.md` exists and records `result: pass`. If not,
     REFUSE the transition with no file mutated:

```
Refused: <ID> cannot move from 'in-progress' to 'done' - no passing /sd:verify artifact.
Run /sd:verify <ID> first; close-out is allowed only after <spec.dir>/<ID>/06-verify.md records
'result: pass'.
```

     This check exists because the frontmatter, index, and retro log are mutated one file at a
     time below; without it, a spec-gate block on the `index.md` edit alone would strand the
     frontmatter already updated to `done` while the index still says `in-progress` - an
     `SL030` disagreement. Checking first keeps the transition atomic: either nothing moves, or
     all three files do.
   - Update frontmatter `status:` field in `00-spec.md`.
   - Update the row in `.specs/index.md`.
   - Append a log entry to `.specs/<ID>/05-retro.md`:

```
- [<UTC ISO timestamp>] Status: <old> -> <new>. Reason: <reason from args or 'manual transition'>.
```

If `05-retro.md` does not yet exist, create it with a header and the entry.

---

## link

Args:
- `<ID-A>` (required).
- `<relation>` (required): one of `depends-on`, `related-to`, `spawned-by`, `spawns`, `blocks`, `blocked-by`, `duplicate-of`, `supersedes`, `superseded-by`.
- `<ID-B>` (required).

Behavior:
1. Verify both spec folders exist. A link to a non-existent ID is REFUSED - do not create a
   dangling entry.
2. Validate relation is in the allow-list, then normalize it (see below).
3. Refuse a self-link (`ID-A` == `ID-B`).
4. If the link already exists on either side, do nothing and say so - `link` is idempotent.
5. Update the `linked_specs` frontmatter list on both specs:
   - On ID-A: add `- <canonical-relation>: <ID-B>`.
   - On ID-B: add `- <inverse-relation>: <ID-A>`.
6. Append a log line to both retros.

### Relation vocabulary

`blocked-by` is an **input alias**, not a stored relation: "A is blocked-by B" and "A depends-on B"
assert the same edge, so storing both would let one spec carry two spellings of one fact and make
symmetry unverifiable. `link` normalizes `blocked-by` to `depends-on` and reports the rewrite.
The other eight inputs are already canonical and are stored as given.

| Input | Stored as | Inverse written on the other side |
|---|---|---|
| `depends-on` | `depends-on` | `blocks` |
| `blocked-by` | `depends-on` (alias) | `blocks` |
| `blocks` | `blocks` | `depends-on` |
| `spawns` | `spawns` | `spawned-by` |
| `spawned-by` | `spawned-by` | `spawns` |
| `supersedes` | `supersedes` | `superseded-by` |
| `superseded-by` | `superseded-by` | `supersedes` |
| `related-to` | `related-to` | `related-to` (symmetric) |
| `duplicate-of` | `duplicate-of` | `duplicate-of` (symmetric) |

The map is total and closed: every stored relation has exactly one inverse, and that inverse is
itself a stored relation. This is what makes the link-symmetry check in `validate` decidable.

### linked_specs format

A YAML list of single-key maps in `00-spec.md` frontmatter. Empty is `[]`.

```yaml
linked_specs:
  - depends-on: FEAT-INV-2501
  - related-to: BUG-1247
```

---

## archive

Args:
- `<ID>` (required).

Behavior:
1. Verify current status is `done`.
2. Run `status <ID> archived`.
3. Print confirmation.

If current status is not `done`, REFUSE: "Only `done` specs can be archived. Current status: <X>."

---

## revive

Args:
- `<ID>` (required).
- `[reason]` (optional, recommended): why the archived spec is being revived.

Behavior:
1. Verify current status is `archived`.
2. Run `status <ID> in-progress` with the provided reason.
3. Common use case: `done` work needs follow-up after being archived. If user is doing fundamentally new work, suggest creating a new spec instead.

---

## search

Args:
- `<term>` (required): plain text. No regex.

Behavior:
1. Recursive grep across `.specs/**/*.md` (excluding `_archived/` if conventionally placed there).
2. Output: `<spec ID>: <file>:<line>: <matching line trimmed>`.
3. Group by spec ID. Limit to 50 results; tell user to refine if hit.

---

## validate

Args:
- `<ID>` (optional, default `--all`).

Behavior:
1. Per-spec checks. For each target spec:
   - Frontmatter present and parseable.
   - Required fields present, per type (see "Required frontmatter fields" below).
   - `id` field matches the folder name.
   - `type` matches the prefix.
   - `status` is in `spec.lifecycle` from project-config.
   - Placeholder discipline (see "Placeholder tokens" below).
   - Expected files present per status:
     - status >= `in-progress` -> `01-plan.md` and `02-tasks.md` exist (feature, refactor, and
       port only; bug, perf, and rca do not produce plan/tasks artifacts).
     - status == `done` -> `05-retro.md` exists with at least one entry.
   - Index row matches frontmatter status.
   - Transition history is legal (see "Transition replay" below).
   - Links resolve and are symmetric (see "Link integrity" below).
   - Task-block content, when `02-tasks.md` exists (see "Task-block checks" below).
   - Port task-block content, when `02-tasks.md` exists and `type` is `port` (see "Port task-block
     checks" below).
   - Port-spec table integrity, when `type` is `port` (see "Port-spec checks" below).
   - Close-out hygiene, when `status` is `done` (see "Close-out hygiene checks" below).
2. Tree-wide checks (run once, only when the target is `--all`):
   - Index <-> folder symmetry (see below).
3. Report every finding using the severity taxonomy (see "Output" below). Do not stop at the
   first failure - a spec with three problems reports three findings.

### Rule table

Every finding cites one of these IDs. The ID is the finding's anchor - the taxonomy forbids a
BLOCK or WARN without one. IDs are stable: renumbering them breaks anyone who has pinned a rule.

| ID | Rule | Severity |
|---|---|---|
| `SL001` | Frontmatter missing or unparseable | 🔴 BLOCK |
| `SL002` | Required field missing for type | 🔴 BLOCK |
| `SL003` | `id` does not match folder name | 🔴 BLOCK |
| `SL004` | `type` does not match ID prefix | 🔴 BLOCK |
| `SL005` | `status` not in `spec.lifecycle` | 🔴 BLOCK |
| `SL006` | `linked_specs` missing, or present but not a list | 🔴 BLOCK |
| `SL010` | Author-fill `<<...>>` token remains at status >= `approved` | 🔴 BLOCK |
| `SL011` | Phase-deferred `<<PHASE-N: ...>>` token pre-filled at `draft` / `approved` | 🔴 BLOCK |
| `SL012` | Phase-deferred token still unfilled at `done` | 🟠 WARN |
| `SL013` | Type template unreadable - placeholder checks could not run | 🟠 WARN |
| `SL020` | Required artifact missing for status | 🔴 BLOCK |
| `SL021` | Status `done` but `05-retro.md` has no entry | 🔴 BLOCK |
| `SL030` | Index row status disagrees with frontmatter status | 🔴 BLOCK |
| `SL031` | Orphan folder - spec exists but has no index row | 🔴 BLOCK |
| `SL032` | Ghost row - index row whose folder does not exist | 🔴 BLOCK |
| `SL033` | Duplicate index rows for one ID | 🔴 BLOCK |
| `SL040` | Illegal transition edge in the retro log | 🔴 BLOCK |
| `SL041` | Transition chain not contiguous | 🔴 BLOCK |
| `SL042` | Last logged transition disagrees with frontmatter status | 🔴 BLOCK |
| `SL043` | Status is not `draft` but there is no retro log | 🔴 BLOCK |
| `SL044` | `archived -> in-progress` logged with an empty reason | 🟠 WARN |
| `SL050` | Link target does not resolve to an existing spec | 🔴 BLOCK |
| `SL051` | One-sided link - inverse entry missing on the target | 🔴 BLOCK |
| `SL052` | Self-link | 🔴 BLOCK |
| `SL053` | Stored relation is `blocked-by` - an input alias, so the field was hand-edited | 🟠 WARN |
| `SL054` | Duplicate entry in `linked_specs` | 🟠 WARN |
| `SL055` | Spec status `done` but `06-verify.md` is missing or records `result: fail` | 🟠 WARN |
| `SL060` | Task block in `02-tasks.md` has no `Pattern refs` field | 🟠 WARN |
| `SL061` | Port-spec task's `Pattern refs` citation does not match the snapshot-member-range shape `<path>:<first>-<last>` | 🔴 BLOCK |
| `SL062` | Citation matches the shape but its path does not start with `04-artifacts/source/` | 🔴 BLOCK |
| `SL063` | Citation names a path absent from `04-artifacts/source/MANIFEST.md` | 🔴 BLOCK |
| `SL064` | Citation's line range falls outside the member range(s) `MANIFEST.md` records for that path | 🔴 BLOCK |
| `SL065` | Port-spec task's `Acceptance` field carries no `Licensed deviations:` line | 🔴 BLOCK |
| `SL066` | A `Licensed deviations:` list cites a deviation ID absent from the spec's `## Deviation table` | 🔴 BLOCK |
| `SL067` | Task check-off marker is non-canonical: `Status` value is not `open`/`done`, or the heading carries a check-off prefix (`[x]`, `[ ]`, `✅`) | 🟠 WARN |
| `SL070` | Task carries `Revised-by: R<n>` but `01-plan.md` has no matching `## Revisions` entry `R<n>` | 🔴 BLOCK |
| `SL071` | A `## Revisions` entry `R<n>` names an `Affected task` that does not carry `Revised-by: R<n>` (or does not exist) | 🔴 BLOCK |
| `SL072` | Revision numbering is non-contiguous, duplicated, or a prior entry was rewritten (append-only violated) | 🔴 BLOCK |
| `SL073` | A `## Revisions` entry is malformed - missing `Trigger`, `Gate: re-plan`, `Phase`, or `revised-from` | 🟠 WARN |
| `SL080` | `source_repo` or `source_commit` missing, empty, `none`, or still a `<<placeholder>>` on a `port` spec whose `scope` is not `pattern` | 🔴 BLOCK |
| `SL081` | `## Member manifest` table has no data rows | 🔴 BLOCK |
| `SL082` | Deviation-table row with an empty `Citation`, or a `Group` that is empty or outside `1`-`4` | 🔴 BLOCK |
| `SL083` | Path-mapping row whose `Kind` is not `mirror` and whose `Reason` is empty or `-` | 🔴 BLOCK |
| `SL090` | Status `done`, the spec body names deferred work, and `## Spawned specs` has no data row (or no such section) | 🟡 SUGGEST |

`SL061`-`SL066` are the **port task-block** band - the anti-drift contract every port task must
carry (a snapshot-member-range `Pattern refs` citation and a licensed-deviation ID list in
`Acceptance`), checked at validate time instead of only at `/sd:port` Phase 6 execution.
`SL067` is the **check-off marker** rule and applies to every spec type. `SL068`-`SL069` remain
**reserved** for further task-block content rules. Claim from this band rather than extending
another one - `SL05x` is link integrity and has nothing to do with task content.

`SL070`-`SL079` are the **revision-log integrity** band (the `sd-replan-loop` `## Revisions` log in
`01-plan.md`, cross-checked against `Revised-by` markers in `02-tasks.md`). It is a distinct band on
purpose: it is neither task-block *content* (`SL06x`) nor `linked_specs` symmetry (`SL05x`), though it
borrows the two-sided-symmetry shape of the latter. `SL074`-`SL079` are reserved for further
revision-record rules.

`SL080`-`SL083` are the **port-spec integrity** band - the three fidelity tables (`sd-port-fidelity`)
a `port` spec must carry, checked from the outside without adjudicating their content. `SL084`-`SL089`
are reserved for further port rules (ordinal contiguity, `Host path` uniqueness, cross-table
referential integrity) if they ever move from the gate into this lint. All four are BLOCK: a `port`
spec that lints clean with an empty member manifest, an uncited deviation, or an unexplained
non-mirror row is a registry that **lies** about carrying a reviewable fidelity contract -
`sd-reviewer`'s hunk classification would then emit findings with no legal anchor, and the gate's
completeness conditions are counted, not judged, so the failure is objective. `SL080` is BLOCK for
the same reason `SL002` is: `source_repo`/`source_commit` are the only cross-project traceability
that exists (`linked_specs` cannot reference another repo), so a non-`pattern` port without them is
unauditable. `validate` does **not** check ordinal contiguity, `Host path` uniqueness, cross-table
referential integrity (`Deviation ID` <-> deviation row), or one-row-per-donor-file completeness -
those are `sd-port-fidelity`'s gate-time job, and duplicating them here would create a second source
of truth for the same predicate.

`SL090` is the **close-out hygiene** band - work the spec named but never gave an owner or an ID.
It is a new band on purpose: it is not task content (`SL06x`), not the revision log (`SL07x`), and
not port fidelity (`SL08x`). `SL091`-`SL099` are reserved for further close-out-hygiene rules.

Severity rationale: BLOCK is for a registry that **lies** (its own contents contradict each other,
so `list` / `stats` / downstream agents read something untrue) or evidence that was **fabricated**
(`SL011` - a measured field filled from memory). WARN is for a real problem that leaves the
registry still truthful and is recoverable by re-running a command. SUGGEST is for hygiene that
costs a future reader but leaves nothing untrue and breaks nothing - `SL090` is the only one
today, and it is deliberately never a failure: a spec that genuinely deferred nothing must not be
made to answer for an empty table.

`SL060` is WARN by that same test: a task with no `Pattern refs` leaves the registry truthful and
is fixed by re-planning the spec. It is deliberately **not** BLOCK - in the only corpus measured,
every task authored after the field shipped already carried it (22 of 22), while the two specs
without it predate the field entirely. Blocking would fail old specs for a rule they could not
have followed, and would gain nothing on new ones.

`SL067` is WARN by the same test. The tolerant reader in `sd-atomic-task-format` "Check-off marker"
still resolves every drifted marker to a definite checked/unchecked state, so resume behavior stays
decidable and the fix is a one-line edit. An **absent** `Status` is not a finding at all: every spec
authored before the marker existed would fail otherwise, and a finished legacy spec is kept out of
resume by its frontmatter status, not by its markers.

`SL061`-`SL066` are BLOCK: a port task block that lints clean while citing a fabricated or
out-of-range snapshot precedent, or an unlicensed deviation, is a registry that **lies** about the
fidelity contract `sd-port-fidelity` requires it to carry - the same test that makes `SL080`-`SL083`
BLOCK. Unlike `SL060`, there is no legacy corpus predating the field to protect: a port spec's
`Pattern refs` is never `none` (every port task cites a snapshot member), so there is no old-spec
class this would unfairly fail.

`SL070`-`SL072` are BLOCK: a task pointing at a revision that does not exist, a revision pointing at
a task that does not carry its marker, or a rewritten revision entry, are all a registry that **lies**
about its own audit trail - the append-only guarantee the `## Revisions` log exists to provide is
exactly what these catch. `SL073` is WARN: an entry missing a descriptive line (`Trigger`, `Gate`,
`Phase`, `revised-from`) is a poor record but leaves the task/log symmetry decidable and truthful,
and is recoverable by editing the entry - the same test that makes `SL044` a WARN.

### Task-block checks

Run only when `02-tasks.md` exists. Parse it per the **Field label grammar** in the
`sd-atomic-task-format` skill - label matching is case-insensitive, `**` around the label is
optional, and the colon may sit inside or outside the emphasis. All three forms occur in live
specs; a reader that accepts only the canonical `- **Label**:` form reports false `SL060`s against
correctly authored tasks, which is worse than not running the check at all.

A field's value runs to the next field label, not to the next newline - `Acceptance` and
`Pattern refs` are routinely multi-line with nested bullets.

Report one `SL060` per offending task block, citing the task heading (e.g. `02-tasks.md` `T01`).
A block that writes `Pattern refs: none` is **compliant** - the explicit `none` is the assertion
the rule is asking for. Only an absent field is a finding.

Report one `SL067` per offending task block, citing the task heading and the offending line. A
block is a finding when its `Status` value (read case-insensitively, per the grammar above) is
anything other than `open` or `done`, **or** its heading carries a check-off prefix (`[x]`, `[ ]`,
`✅`) before the `T<NN>` token - whether or not a `Status` line is also present. A block with no
`Status` line and a plain heading is **compliant** (legacy, reads as unchecked). The check-off
semantics themselves are defined in `sd-atomic-task-format` "Check-off marker"; do not restate them
here.

### Port task-block checks

Runs only when `02-tasks.md` exists **and** frontmatter `type` is `port` - a `FEAT`/`BUG`/`REF`/
`PERF`/`RCA` task is unaffected. Parse task blocks with the same tolerant **Field label grammar**
used for `SL060`. `Pattern refs` may carry 1-3 citations; check **each citation independently** and
report one finding per offending citation, not one per task block - the same granularity `SL082`/
`SL083` use for table rows. Cite the task heading (`02-tasks.md` `T<NN>`) plus the offending
`Pattern refs` or `Acceptance` line.

This is a cross-artifact check: `Pattern refs` lives in `02-tasks.md`, the ranges it must agree with
live in `04-artifacts/source/MANIFEST.md`, and the deviation IDs it must agree with live in the
spec's own `## Deviation table` (`00-spec.md`).

For each `Pattern refs` citation on a port task:

- **`SL061` - malformed citation.** The citation does not match the snapshot-member-range shape
  `<path>:<first>-<last>` (a path, a colon, two `[0-9]+` values joined by `-`). This includes the
  literal `none` - a port task's `Pattern refs` is never `none`, every port task cites a snapshot
  member.
- **`SL062` - wrong location.** The citation matches the shape, but `<path>` does not start with
  `04-artifacts/source/` (e.g. it names a host sibling file instead of the frozen snapshot).
- **`SL063` - unknown snapshot path.** `<path>`, with the `04-artifacts/source/` prefix stripped,
  does not appear as a `Snapshot path` value in any row of `04-artifacts/source/MANIFEST.md`.
- **`SL064` - range outside the manifest.** `<first>-<last>` falls outside the **union** of the
  member ranges `MANIFEST.md` records for that path - the lowest first-line to the highest last-
  line across every `<ordinal>: <member> <first>-<last>` entry for that `Snapshot path`, per
  `sd-port-fidelity`'s "Snapshot manifest format". A citation may legitimately span more than one
  member; this checks the citation stays within the recorded snapshot, not that it matches one
  member exactly.

  Each check requires the previous one to have resolved: `SL062`-`SL064` require the shape to have
  parsed first (a citation that already failed `SL061` reports only `SL061`), and `SL064` also
  requires the path to have resolved in `MANIFEST.md` first (a citation that already failed `SL063`
  reports only `SL063` - there is no recorded range to compare against for a path that isn't
  there). Report exactly one of `SL061`/`SL062`/`SL063`/`SL064` per citation, never more than one.

For `Acceptance` on a port task:

- **`SL065` - no licensed-deviation list.** The field carries no `Licensed deviations:` line (see
  the "Port mode" addendum in **sd-atomic-task-format**). `Licensed deviations: none` is compliant -
  the explicit `none` is the assertion this rule asks for, same convention as `Pattern refs: none`.
- **`SL066` - uncited deviation.** A `Licensed deviations:` list names a `D<NN>` ID that does not
  appear in the spec's `## Deviation table`.

### Revision-log integrity

Runs only when there is a revision record to check: `01-plan.md` has a `## Revisions` section, **or**
any task block in `02-tasks.md` carries a `Revised-by` field. A spec with neither - the overwhelming
common case, an original plan never re-planned - produces no `SL07x` finding. This is a cross-artifact
check: the `## Revisions` log lives in `01-plan.md`, its markers in `02-tasks.md`, and the two must
agree. Parse task blocks with the same tolerant **Field label grammar** used for `SL060`.

The `## Revisions` log is written only by the Gate Re-plan of `/sd:feature` and `/sd:refactor` via the
**sd-replan-loop** skill. Each entry is `### R<n> - <timestamp>` followed by `Trigger`, `Phase`,
`Gate: re-plan`, `Affected tasks`, `Delta`, and `revised-from` lines. Checks:

- **`SL070` - dangling marker.** A task carrying `Revised-by: R<n>` with no `### R<n>` entry in
  `01-plan.md`. Cite the task's `Revised-by` line; name the absent entry in the finding.
- **`SL071` - one-sided / unreferenced revision.** An `### R<n>` entry whose `Affected tasks` list
  names a task that either does not exist or does not carry `Revised-by: R<n>`. An entry with no
  parseable `Affected tasks` line is also `SL071` - the back-reference cannot be established, so the
  revision points at nothing. Cite the entry's `Affected tasks` line (or the `### R<n>` heading when
  the line is absent).
- **`SL072` - broken append-only history.** Revision numbers must run contiguously from `R1` with no
  gap, no duplicate, and no reuse. A gap (`R1`, `R3`), a duplicate `R<n>`, or a heading that reuses a
  number already logged means the log was rewritten rather than appended. Cite the first offending
  `### R<n>` heading.
- **`SL073` - malformed entry.** An `### R<n>` entry missing any of `Trigger`, `Gate: re-plan`,
  `Phase`, or `revised-from`. (A missing `Affected tasks` line is `SL071`, not `SL073` - it breaks
  symmetry, not just completeness.) Cite the `### R<n>` heading.

Report one finding per offending task or entry - a log with three problems reports three findings.
`validate` is a static linter: it verifies the revision record is internally consistent and
append-only shaped. It has no Plan-phase snapshot of `02-tasks.md`, so it **cannot** detect an
undocumented silent edit by diffing - an edit that adds no `Revised-by` marker and no `## Revisions`
entry is invisible here and is prevented by the HARD Gate Re-plan, not by this lint. Do not report,
or imply, a finding the checks above cannot actually decide.

### Port-spec checks

Runs only when frontmatter `type` is `port`. Locate each table by its exact `##` heading and parse
it as header row + separator row + data rows; a cell counts as empty when blank or `-`. Report one
finding per offending row or condition, never one finding per table. The three fidelity tables'
authoritative column schemas and completeness conditions live in
`~/.claude/skills/sd/sd-port-fidelity/SKILL.md` - read it at runtime rather than restating the
schemas here, the same pattern `### Output` already uses for `sd-severity-taxonomy` /
`sd-evidence-citation`.

- **`SL080`.** `scope` is not `pattern` and either `source_repo` or `source_commit` is missing,
  empty, the literal value `none`, or still an author-fill `<<...>>` token - `none` is a legitimate
  value only when `scope` is `pattern`. Cite the `scope:` frontmatter line - it is the line that
  creates the obligation.
- **`SL081`.** The `## Member manifest` table has a header and separator but no data row. Cite the
  `## Member manifest` heading line - an empty table has no row of its own to cite.
- **`SL082`.** A row in `## Deviation table` whose `Citation` cell is empty, or whose `Group` cell
  is empty or not one of `1`, `2`, `3`, `4`. Cite the offending row.
- **`SL083`.** A row in `## Path mapping table` whose `Kind` cell is not `mirror` (including a
  garbled or empty `Kind`) and whose `Reason` cell is empty or `-`. Cite the offending row.

### Close-out hygiene checks

Runs only when frontmatter `status` is `done`. One rule today, `SL090`, and it is 🟡 SUGGEST -
never a BLOCK, never a WARN, and never a reason for the run to report failure.

`SL090` fires when **both** hold:

1. The spec **named deferred work**. Search `00-spec.md` and `05-retro.md`, case-insensitively,
   for any of this closed list: `follow-up`, `follow up`, `deferred`, `defer to`, `separate spec`,
   `spawn a`, `spawned`, `own spec`, `future spec`, `left as-is`, `reproduced as-is`,
   `not fixed here`, `TODO`. The list is closed on purpose - "deferred-work language" judged
   freehand is not a decidable predicate, and an advisory that fires on a hunch is noise.
   Skip HTML comments, fenced code blocks, the `## Out of scope` section, and the
   `## Spawned specs` section itself. `## Out of scope` is excluded because it declares a
   boundary rather than deferring work, and it is where the templates put their own example
   prose - scanning it would fire on template text. `phase-deferred` does not count as a match
   for `deferred`: it names the `<<PHASE-N: ...>>` token mechanism, not deferred work.
2. The spec has **no reserved ID**: `## Spawned specs` is absent, or present with a header and
   separator but no data row.

Cite the first matching line as `file:line` - that line is the deferred work with nowhere to
land. Name the phrase that matched and the absent or empty table in the finding. Report **one**
`SL090` per spec, not one per phrase.

Do not fire on a spec that has at least one data row: this rule asks whether follow-up work was
recorded at all, and never adjudicates whether the rows are the *right* rows. A reserved ID in
that table is a placeholder, not a registry entry - see "Index <-> folder symmetry".

### Output

Read `~/.claude/skills/sd/sd-severity-taxonomy/SKILL.md` and
`~/.claude/skills/sd/sd-evidence-citation/SKILL.md` before emitting the report, and follow them.
This command has no `skills:` frontmatter - only agents load skills that way, and `validate`
invokes no subagent - so the rules are read at runtime instead. If either file is unreadable, say
so and fall back to plain PASS / FAIL lines rather than inventing a format.

Structure: the taxonomy's mandated output, plus a per-spec summary table above it.

```markdown
# Spec lint: <N> spec(s) under `.specs/`

**Verdict**: <N> 🔴 BLOCK, <N> 🟠 WARN, <N> 🟡 SUGGEST, <N> 🟢 PASS across <N> specs.

| Spec | Status | Result |
|---|---|---|
| `FEAT-INV-2501` | in-progress | PASS |
| `BUG-1247` | done | 2 findings (1 BLOCK, 1 WARN) |

## 🔴 BLOCK

### B1: `id` does not match folder name
- **File:line**: `.specs/BUG-1247/00-spec.md:2`
- **Rule**: `SL003`
- **Finding**: Frontmatter declares `id: BUG-1246` but the folder is `BUG-1247`. `show` and
  `link` resolve by folder, `list` renders the frontmatter - so the two disagree about what
  this spec is called.
- **Suggested direction**: Decide which ID is real, then fix the other side and the index row.
```

Citation rules for this command, applying `sd-evidence-citation`:

- Every finding cites `file:line`, relative to the project root.
- A finding about something **absent** (a missing artifact, a missing inverse link) has no line
  of its own. Cite the line that **creates the obligation** - e.g. for `SL020`, the `status:`
  line whose value requires the artifact - and name the absent path in the finding text. Never
  cite a bare directory: the skill rejects it, and the obligation line is the better evidence.
- Tree-wide findings (`SL031` / `SL032` / `SL033`) cite `.specs/index.md:<row>` where a row
  exists, and `.specs/<ID>/00-spec.md:1` for an orphan folder that has no row to point at.
- A clean tree prints the summary table with every spec `PASS`, and `_No findings._` under each
  of the four severity sections. Do not omit the empty sections.

### Index <-> folder symmetry

Only meaningful for `--all`; a single-ID run cannot see orphans. Compare the set of spec folders
under `spec.dir` against the set of rows in `spec.indexFile`:

- **Orphan folder**: a spec folder with no index row. The spec is invisible to `list` / `stats`.
- **Ghost row**: an index row whose folder does not exist. Points at nothing.
- **Duplicate row**: the same ID on more than one index row.

Directories whose name starts with `_` are engine-reserved (`_explorations/`, `_reviews/`,
`_adr/`, `_archived/`) and are NOT specs - skip them. Skip `index.md` and `constitution.md` too.

**Reserved IDs are not registry entries.** An ID in a spec's `## Spawned specs` table is a
placeholder for work that has not been started. It gets an `.specs/index.md` row only once its
spec directory actually exists - i.e. once someone runs the child workflow. Adding the row first
manufactures exactly the ghost row `SL032` exists to catch: an index entry pointing at a
directory that is in no commit. For the same reason a reserved ID never goes in `linked_specs`;
the link is written by `/sd:spec link` after the child is created.

### Transition replay

`05-retro.md` is the append-only status log written by `status` / `link`. Replay it against the
state machine in the `status` section above:

- Parse every `- [<ts>] Status: <old> -> <new>.` line, in file order.
- Each `<old> -> <new>` must be a legal edge. `archived -> in-progress` is legal only when the
  entry's reason is non-empty (that edge exists only via `revive`).
- The chain must be contiguous: each entry's `<old>` equals the previous entry's `<new>`.
- The last entry's `<new>` must equal the current frontmatter `status`. A mismatch means a
  status was hand-edited, bypassing `status` - which is exactly what the log exists to catch.
- A spec with no retro and status `draft` is fine (nothing has transitioned yet). Any other
  status with no retro is a failure.

Replay reads only committed history - it cannot see a transition that was never logged. A
hand-edit that updated frontmatter, index, *and* forged a matching log line is out of scope.

### Link integrity

For every entry in a spec's `linked_specs`:

- The relation is a **stored** relation from the `link` vocabulary. A stored `blocked-by` is a
  failure: it is an input alias that `link` normalizes away, so its presence means the field was
  hand-edited.
- The target ID resolves to an existing spec folder (no dangling links).
- The inverse entry exists on the target, pointing back (no one-sided links). Symmetric relations
  (`related-to`, `duplicate-of`) require the same relation back.
- No self-link, no duplicate entries.

### Required frontmatter fields

Presence is what is checked, not value - a field may legitimately hold a `<<placeholder>>` at
`draft`. The "Placeholder tokens" rules below govern when a value must be real.

Every type additionally requires `linked_specs` (a YAML list; `[]` when the spec stands alone).

| Type | Required fields (beyond `linked_specs`) |
|---|---|
| `feature` | `id`, `type`, `status`, `jira`, `created` |
| `bug` | `id`, `type`, `severity`, `status`, `jira`, `created` |
| `refactor` | `id`, `type`, `smell`, `status`, `created` |
| `perf` | `id`, `type`, `status`, `target_metric`, `created` |
| `rca` | `id`, `type`, `status`, `severity`, `incident_started`, `incident_resolved`, `created` |
| `port` | `id`, `type`, `status`, `scope`, `source_repo`, `source_commit`, `source_license`, `snapshot`, `jira`, `created` |

`jira` is required to be present but may hold `none`. `incident_resolved` may hold a placeholder
while an incident is still open - an RCA for an unresolved incident cannot pass `approved`.
`linked_specs` must be present and a list; `[]` is the valid empty form, a bare `none` is not.
`source_repo` / `source_commit` are required to be **present** for every port spec (that is
`SL002`); their **value** must additionally be real when `scope` is not `pattern` (that is
`SL080`) - a `pattern`-scope port writes `none`.

### Placeholder tokens

Two token forms with opposite rules. Both live in `00-spec.md`.

| Form | Meaning | Filled by |
|---|---|---|
| `<<description>>` | Author-fill. Written when the spec is drafted. | The spec author |
| `<<PHASE-N: description>>` | Phase-deferred. MUST NOT be pre-filled - the workflow's Phase N fills it from measured evidence. | Phase N of the owning workflow |

The reference set of phase-deferred tokens for a type is the `<<PHASE-N: ...>>` tokens in
`~/.claude/templates/sd/specs/<type>.template.md`. If that template is unreadable, raise `SL013`
and skip only the placeholder checks for that spec - never silently pass them.

Rules:
- status >= `approved` -> no author-fill `<<...>>` token remains. Phase-deferred tokens are
  exempt and are NOT a failure.
- status in {`draft`, `approved`} -> for each phase `N`, the spec MUST carry at least as many
  `<<PHASE-N: ...>>` tokens as the template does. A filled-in phase-deferred field at these
  states is a failure: it means the value was written from memory rather than measured. This is
  the check that makes the cross-phase discipline enforceable rather than advisory.

  Match on the `<<PHASE-N:` prefix and count per phase - do NOT require the description text to
  match the template verbatim. Filling a field deletes its token, which the count catches;
  trimming an example out of a token's description is not pre-filling and must not fail.
- status == `in-progress` -> no assertion either way. The lifecycle records status, not which
  phase is current, so a phase-deferred token may legitimately be filled or unfilled. This is a
  known blind spot, not an oversight: narrowing it would mean tracking phase in frontmatter.
- status == `done` -> no `<<PHASE-N: ...>>` token remains.

---

## stats

Args: none.

Behavior:
1. Parse `.specs/index.md`.
2. Output:
   - Counts by type (FEAT / BUG / REF / PERF / RCA / PORT).
   - Counts by status.
   - "Aging" report: specs in `in-progress` for more than 7 days (configurable), specs in `draft` for more than 14 days.
   - Top 5 oldest `in-progress` specs.

---

## help

Behavior: print the subcommand table above with one-line examples.

---

## Rules (hard constraints)

- Change `.specs/index.md` and any spec `status:` field with the Edit tool only - never a shell
  command (`sed -i`, `>`, `tee`, `Set-Content`). spec-gate checks an Edit-tool change (Rules 0,
  0b, 1) and records its `spec_transition`; a shell write skips both (SW-79).
- This command NEVER invokes a subagent.
- This command NEVER edits files outside `.specs/`. (Specifically: never touches code, never touches `.claude/`, never touches the constitution.)
- Lifecycle transitions follow the validated state machine. Illegal transitions are refused.
- Every state change is logged to `05-retro.md` with timestamp and reason. The log is append-only - never edit prior entries.
- The `revive` subcommand exists for `done` -> follow-up cases. New work uses a new spec.
- `search` is plain text; for regex needs, use `grep` directly.
