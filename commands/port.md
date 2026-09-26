---
description: Fidelity-first port workflow. Bridge -> freeze -> survey -> tables -> pin -> plan -> execute batched -> parity -> close. 6 hard gates.
argument-hint: <slug> --from <contract-artifact-or-in-repo-path> --scope <endpoint|module|feature|pattern> [--snapshot contract|contract+source]
---

# /sd:port

Drives a fidelity-first port: reproduces a donor implementation inside this host repo, with every
departure from the donor form recorded as a citable deviation rather than a preference. Result
under `.specs/PORT-<slug>-<YYYYMMDD>/`. Reads `sd-port-fidelity` for the tables, artifacts, and
hunk vocabulary this file wires together - it does not restate them.

**Arguments**: `<slug> --from <contract-artifact-or-in-repo-path> --scope
<endpoint|module|feature|pattern> [--snapshot contract|contract+source]`. Spec ID =
`PORT-<slug>-<YYYYMMDD>`.

---

## HARD RULES (read before every phase)

1. **The donor is the specification.** Every departure is a row in the deviation table, or it is a
   defect (sd-port-fidelity core rule).
2. **The snapshot is evidence, never a copy source, and never edited.** It is quarantined the
   moment it is frozen.
3. **`--scope` is explicit.** Phase 0 asks when it is omitted. Nothing infers it - a wrong
   inference changes the parity mechanism.
4. **Port policy is Layer 2.** This file never states a policy - it reads the host's
   `.specs/constitution.md` and reports what it found, or the documented default.
5. **No opportunistic fix.** A donor defect is reproduced as-is and recorded under `## Spawned
   specs` - never fixed inline unless a group-4 deviation was agreed at Gate 2 before
   implementation began.

---

## State machine (resume behavior)

| Condition | State | Action |
|---|---|---|
| No `.specs/PORT-<slug>-<YYYYMMDD>/` dir | `not-found` | Start Phase 1 |
| `00-spec.md` exists, no `04-artifacts/source/MANIFEST.md` | `spec-drafted` | Resume Phase 2 |
| `MANIFEST.md` present, `Frozen: yes`, tables still carry `<<...>>` tokens | `frozen` | Resume Phase 3 |
| Tables filled, status `draft` | `tables-drafted` | Present Gate 2 |
| status `approved`, no `## Behavior pinning` in `03-decisions.md` | `approved` | Resume Phase 5 |
| Pinned, no `02-tasks.md` | `pinned` | Resume Phase 6 |
| `02-tasks.md` has unchecked tasks | `in-progress` | Resume Phase 7 at next unchecked task |
| All tasks checked, no `04-artifacts/parity/INDEX.md` | `tasks-complete` | Resume Phase 8 |
| Parity clean, status not `done` | `parity-clean` | Resume Phase 9 |
| status `done` | `done` | Print summary, exit |
| status `archived` | `archived` | Print archived notice, exit |

"Checked" and "unchecked" mean the task's check-off marker as defined in the "Check-off marker"
section of the **sd-atomic-task-format** skill - the one definition; do not invent a marker. Task
rows are evaluated only while status is `in-progress`: a `done` or `archived` spec resolves from its
frontmatter first and is never resumed from its task markers.

---

## Phase 0 - Bootstrap (always runs)

1. Read `~/.claude/skills/sd/sd-bootstrap-guard/SKILL.md` and apply it before anything else here -
   it owns the Layer-2 reads and all of their messages (commands cannot load skills via
   frontmatter, so it is read at runtime). If that file is unreadable, STOP: "specwright install
   incomplete - bootstrap guard skill not found under `~/.claude/skills/sd/`. Re-run the installer."
2. **Parse arguments**: `<slug>`; `--from <value>`; `--scope <endpoint|module|feature|pattern>`;
   `--snapshot <contract|contract+source>` (default `contract`).
   - `--scope` absent or not one of the four values -> ask the user to pick one. Never infer it.
   - `--from` absent -> STOP: "`--from` is required: a bridged contract artifact (cross-repo) or an
     in-repo path/symbol (intra-repo)."
   - `--snapshot` present and not one of the two values -> STOP naming the two legal forms.
3. **Select topology from `--from`** - the rest of the pipeline is identical either way:
   - Resolves to a directory or file containing a `contract.md` with frontmatter `type:
     port-extraction` -> topology = `bridged`.
   - Resolves to a path or symbol inside this working tree -> topology = `in-repo`.
   - Neither -> STOP naming both accepted forms.
4. Compute the UTC date and the spec ID `PORT-<slug>-<YYYYMMDD>`.
5. **Read the port policy.** Scan `.specs/constitution.md` for the first heading (any level) whose
   text contains "Port policy" (case-insensitive). Effective policy = that section's body.
6. **State the effective policy in output, always** - including the fallback:
   ```
   Effective port policy: <constitution heading> "<section body, or a one-line summary of it>"
   -- or, when no such section exists --
   Effective port policy: default - structural mirror (sd-port-fidelity core rule); no "Port
   policy" section found in .specs/constitution.md
   Scope: <scope>   Topology: <bridged|in-repo>   Snapshot mode: <contract|contract+source>
   ```
7. Read `~/.claude/skills/sd/sd-model-escalation/SKILL.md`. It owns the model escalation policy
   applied at Phase 6 step 2; this file names only rule IDs and trigger inputs. If that file is
   unreadable, STOP: "specwright install incomplete - model escalation skill not found under
   `~/.claude/skills/sd/`. Re-run the installer."
8. Detect state from the table above. Print the resume plan.

---

## Phase 1 - Consume the bridged contract, or extract in-repo

### Branch A - topology `bridged`

1. Read the bundle at `--from`. Validate all eight fixed sections of `sd-code-explorer`'s
   port-extract output (Entry surface, Output surface, Member closure, Complement set,
   Collaborators, Non-obvious invariants, Dead paths on this entry point, Precedent conventions). A
   section that is absent, or neither filled nor an explicit `None found (searched: ...)`, is
   incomplete - STOP naming it and telling the user to re-run `/sd:explore --port <entry> --scope
   <scope>` in the donor repo.
2. `Member closure` reported as `None found` is a failure of the extraction itself (the entry point
   could not be resolved), never a legitimately empty closure - STOP if you see it.
3. A `source_commit` reading `dirty (...)` is a WARN, not a STOP - record it as an Open question in
   the spec once created.
4. `--snapshot contract+source` with no `source/` subtree in the bundle -> STOP.

### Branch B - topology `in-repo`

1. Invoke `sd-code-explorer` with:
   - `TASK = port-extract`
   - `ENTRY_POINT = <the --from value>`
   - `SCOPE = <scope from Phase 0>`
   - `GITNEXUS_AVAILABLE = <true|false from project-config.mcp.gitnexus.enabled>`
2. Apply the same eight-section validation as Branch A to the returned output.

### Both branches - create the spec

3. If `ticket.system == "jira"` and `<slug>` matches `ticket.pattern`, fetch the ticket via
   `mcp__atlassian__getJiraIssue`. If MCP unavailable, ask the user for a paste or proceed without
   one.
4. Invoke `sd-spec-architect` with:
   - `TASK = create`
   - `TEMPLATE = port.template.md`
   - `SPEC_ID = PORT-<slug>-<YYYYMMDD>`
   - `SOURCE_REPO = <donor identity from the contract (Branch A), or this repo's identity (Branch B)>`
   - `SOURCE_COMMIT = <source_commit from the contract/extraction>`
   - `DONOR_SCOPE = <scope from Phase 0>`
   - `TICKET_CONTEXT = <fetched or pasted, when applicable>`
5. Architect fills Why / Donor provenance / Behavioral contract (7 fixed rows) / Behavioral
   invariants (from the extraction's Non-obvious invariants section), leaves the three fidelity
   tables' `<<...>>` rows for Phase 4, leaves `AC-1` verbatim. Register in `.specs/index.md` at
   status `draft`.

No gate here - Gate 1 covers the freeze that follows in Phase 2, not the raw extraction.

---

## Phase 2 - Freeze the snapshot

Main-thread file operations only - this command's `Write` tool is not escalated to any subagent.

1. Create `.specs/PORT-<slug>-<YYYYMMDD>/04-artifacts/source/`. Copy the bridged bundle verbatim:
   `contract.md` always; the `source/` tree too under `snapshot: contract+source`. For an `in-repo`
   topology, copy each distinct `Donor path` named in Member closure and Complement set once.
2. Per copied file: sha256 (lowercase hex) and byte count, over the bytes as captured.
3. Write `04-artifacts/source/MANIFEST.md` in the exact format `sd-port-fidelity`'s "Snapshot
   manifest format" defines - header fields plus the six-column table, `Member ranges` as
   `<ordinal>: <member> <firstLine>-<lastLine>`, semicolon-separated, contiguous from 1.
4. Append every file under `source/`, plus `MANIFEST.md` itself, as an **individual literal
   string** to `paths.protected` in `.claude/project-config.json`. Exact-string match, never a
   glob - the enumeration is the mechanism. Idempotent: skip entries already present.
5. Fill the spec's `Frozen:` line: `yes - <N> path(s) appended to paths.protected on <YYYY-MM-DD>`.
6. **Snapshot-visibility warning, never an edit.** If the host's build, lint, or coverage
   configuration has no exclusion covering `.specs/`, print a WARN naming each config file found
   and the exclusion it needs. This command warns; it never edits that configuration.

### ⛔ Gate 1 - Donor set frozen (HARD)

STOP. Display the snapshot root, the file count, the `MANIFEST.md` row count, how many entries
were appended to `paths.protected`, and the sha256 of `MANIFEST.md` itself. Ask:

> Donor set frozen for PORT-<slug>: <N> file(s), <M> member range(s). Proceed on this frozen set? (yes / re-capture <reason> / abort)

- `yes` -> proceed to Phase 3.
- `re-capture <reason>` -> delete `04-artifacts/source/`, remove exactly the `paths.protected`
  entries this phase appended, return to Phase 1.
- `abort` -> stop the workflow. Leave the spec at status `draft`; re-invoking resumes here.

This gate is HARD. Nothing downstream reads a donor file outside the frozen set, and no later
phase re-captures silently - re-capture is a decision made here, deliberately, or not at all.

---

## Phase 3 - Host survey

1. Invoke `sd-code-explorer` with:
   - `TASK = impact-map`
   - `SPEC = .specs/PORT-<slug>-<YYYYMMDD>/00-spec.md`
   - `OUTPUT_TARGET = .specs/PORT-<slug>-<YYYYMMDD>/03-decisions.md`
2. Its "Precedents & conventions" section is the host precedent sampling this phase needs. Main
   thread appends the returned analysis to `03-decisions.md` (create the file if missing; never
   overwrite existing content).
3. **Systematic host-constitution scan** (main thread, pattern-based - not a read-through). For
   each numbered constitution rule that states a mechanically checkable pattern (naming, layer
   direction, a forbidden construct, error handling, async style), derive a grep pattern from the
   rule text and run it over `04-artifacts/source/`. Append to `03-decisions.md`:

   ```markdown
   ## Host-constitution scan

   | Rule | Pattern used | Snapshot path:line | Donor form | Proposed host form |
   |---|---|---|---|---|
   ```

   Every applicable rule appears with its result, including `no hits` - the scan's coverage must be
   auditable. A rule with no mechanically checkable pattern is listed as `not mechanically checkable
   - manual review at Gate 2`. Each hit row pre-populates a group-2 deviation row for Phase 4,
   citing the `§N.M` the rule carries.

No gate here - the survey is informational. The user reviews it via the tables at Gate 2.

---

## Phase 4 - Author the three fidelity tables

1. Invoke `sd-spec-architect` with:
   - `TASK = refine`
   - `SPEC = .specs/PORT-<slug>-<YYYYMMDD>/00-spec.md`
   - `FEEDBACK = <fill the three fidelity tables - see below>`

   The feedback text: fill the Path mapping table, Member manifest, and Deviation table per
   `sd-port-fidelity`'s completeness conditions, sourced from `04-artifacts/source/MANIFEST.md` and
   the Host-constitution scan rows in `03-decisions.md`. Cite snapshot paths, never donor-repo
   paths. Every scan row becomes a group-2 deviation row or is explained under Open questions. Fill
   `AC-2` onward; leave `AC-1` verbatim.
2. **Main thread counts the three completeness conditions mechanically** - it counts and matches,
   it never judges a reason (sd-port-fidelity's own discipline). Compute `unmapped` = (manifest
   members with no Member-manifest row) + (Member-manifest rows whose `Host path` has no path-
   mapping row) + (non-`ported` rows naming a `Deviation ID` absent from the deviation table).
3. Run `/sd:spec validate PORT-<slug>-<YYYYMMDD>`. The `SL080`-`SL083` rules must report zero
   BLOCK.

### ⛔ Gate 2 - Fidelity tables complete, zero unmapped (HARD)

STOP. Display: path-mapping row count, `<M>/<T>` members mapped, deviation rows by group, the
unmapped count, and the `/sd:spec validate` verdict. Ask:

> PORT-<slug>: <P> path rows, <M>/<T> members mapped, <D> deviation rows, <U> unmapped. Approve the fidelity tables? (yes / refine <feedback> / abort)

- `yes` -> permitted only when `<U>` is 0, every author-fill `<<...>>` token is gone, and
  `/sd:spec validate` reports zero BLOCK. Set status=`approved` in `00-spec.md` and
  `.specs/index.md`; proceed to Phase 5.
- `refine <feedback>` -> loop through step 1.
- `abort` -> stop the workflow. Leave the spec at status `draft`.

This gate is HARD. An incomplete table is refused by count, without a discussion of intent.

---

## Phase 5 - Pin behavior before host code exists

**Mechanism by scope** - record the choice and its reason under a new `## Behavior pinning`
section in `03-decisions.md`:

- `endpoint` -> a **contract test suite** runnable against both donor and host. Assertions
  reference only the Entry surface and Output surface rows of the Behavioral contract table; the
  target address/transport is supplied by a single parameter.
- `module` -> **characterization tests** over an interface-typed construction seam. The subject is
  constructed through exactly one factory method typed to the interface, so re-pointing
  donor -> host changes that one method and nothing else; assertion bodies stay **byte-identical**,
  proven by diffing the two test files and showing the diff touches only the factory method.
- `feature` -> whichever of the above the surface allows. State the choice and why; prefer the
  contract suite when both are possible.
- `pattern` -> **skipped.** Record `Phase 5 skipped - scope is pattern; there is no donor instance
  to pin against.` The gate below still runs and records the skip; the empty-diff proof still runs.

1. Write the pinning tests under `paths.tests`.
2. Invoke `sd-implementer` with:
   - `TASK_DETAILS = <the pinning-test task block>`
   - `SPEC_REF = .specs/PORT-<slug>-<YYYYMMDD>/00-spec.md`
   - `IMPACT_REF = .specs/PORT-<slug>-<YYYYMMDD>/03-decisions.md`
   - `WORKFLOW_TYPE = port`
3. Run the pinned tests via `commands.test`.
4. **Prove the host production tree is unmodified.** Run `git diff --quiet --` over every path in
   `paths.src` and every `paths.layers[].path`, then `git status --porcelain --` over the same set
   to catch untracked additions. Both must return empty.

### ⛔ Gate 3 - Behavior pinned and green (HARD)

STOP. Display the mechanism chosen, the pinned test files, the `commands.test` result, and the
empty-diff proof - the exact checks run and their output. Ask:

> PORT-<slug> pinned via <mechanism>: tests green, host production tree unmodified. Proceed to planning? (yes / re-pin <feedback> / abort)

- `yes` -> permitted only when the pinned tests are green AND both tree checks returned empty.
- If either tree check returns output, this gate refuses and lists the dirty paths - a dirty
  production tree makes the Phase 8 parity diff unattributable. Commit or revert those changes
  under their own spec first, then re-run the check.
- `re-pin <feedback>` -> return to step 1.
- `abort` -> stop the workflow. Leave the spec at status `approved`.

This gate is HARD, including for `scope = pattern` - it presents the recorded skip reason and asks
the same question; the empty-diff proof is never skipped.

---

## Phase 6 - Plan atomic tasks

1. **Port-mode complexity triage**, computed by the main thread - `sd-spec-architect`'s
   self-assessment is feature-only, so do not expect `STATUS = needs-input` from it here.
   - **Metric: the number of deviation-table rows requiring adaptation** - every row in the
     Deviation table, counted once. Threshold: **> 8**, mirroring the feature-plan task threshold's
     shape.
   - **Rationale**, recorded verbatim in `01-plan.md` under `## Complexity triage (port mode)`: the
     existing decompose thresholds count impacted files and distinct `Layer` values. In a port the
     impacted-file count equals the donor's file count by construction, and the layer spread is
     inherited from the donor, so both trip on nearly every port regardless of how much judgment the
     work needs. The quantity that actually scales with judgment is the number of departures from
     the donor form - a 40-file mechanical mirror with two deviations is easier than a 3-file port
     with fifteen. Record metric name, value, threshold, and verdict.
   - Over threshold: present a split at Gate 4, partitioned along disjoint `Host path` rows (each
     child owns a set of path-mapping rows plus the deviation IDs those rows reference), or a
     no-split flag. Under threshold: normal plan, zero added friction.
2. **Model escalation check, then the plan.** Apply rule `ESC-PORT-06` of
   **sd-model-escalation** (read in Phase 0). Trigger input: the port decompose metric computed in
   step 1 (deviation rows requiring adaptation). Invoke `sd-spec-architect` (model: default, or as
   resolved above) with:
   - `TASK = plan`
   - `SPEC = .specs/PORT-<slug>-<YYYYMMDD>/00-spec.md`
   - `IMPACT = .specs/PORT-<slug>-<YYYYMMDD>/03-decisions.md`
3. **Port task-block requirements.** Every block carries the 11 required fields of
   **sd-atomic-task-format**; three are constrained in port mode:
   - **`Pattern refs` points at the snapshot member range**, never prose and never a host sibling.
     Format: `` `04-artifacts/source/<snapshot path>:<first>-<last>` - member <ordinal>
     `<Member>`; reproduce structurally. `` Resolve the range through `MANIFEST.md`'s `Member
     ranges` by `(Snapshot path, Ordinal)` - the Member manifest table carries no line-range column
     of its own.
   - **`Acceptance` carries the licensed-deviation list**, as nested bullets:
     ```
     - Licensed deviations: D03, D07   (or: none)
     - Anything not on that list is reproduced as-is from the cited member range.
     ```
   - **`Covers`** cites `AC-1` plus any `AC-<n>` the task proves.
   - A task block missing the snapshot-range `Pattern refs` or the licensed-deviation list is a
     **planning defect**. Do not execute it - return to step 2 naming the defective task IDs.
4. **Batching unit** (no new task field): a batch is the set of tasks whose `Files` name the same
   `Host path` from the path-mapping table, executed in `Ordinal` order; batches run in
   path-mapping row order.

### ⛔ Gate 4 - Plan approval

STOP. Display the task count, the port decompose metric (`<D>` deviation rows requiring
adaptation, threshold 8) with its verdict, and a per-task line showing the `Pattern refs` snapshot
range and the licensed deviation IDs. Ask:

> Approve plan for PORT-<slug>? (<N> tasks, <D> deviation rows requiring adaptation) (yes / refine <feedback> / abort)

- `yes` -> set status=`in-progress` in `00-spec.md` and `.specs/index.md`; proceed to Phase 7.
- `refine <feedback>` -> invoke `sd-spec-architect` with `TASK = refine`, `SPEC = .specs/PORT-<slug>-<YYYYMMDD>/00-spec.md`, `FEEDBACK = <user feedback>`. Loop.
- `abort` -> stop the workflow. Leave the spec at status `approved`.

This is the standard plan approval - the same shape as `/sd:feature` Gate 2 Face A. It is not one
of the four no-override gates.

---

## Phase 7 - Execute batched

Process batches from `02-tasks.md` in path-mapping row order. For each unchecked task in the
current batch:

1. **Pre-flight**: re-read `00-spec.md`, the task block, the cited snapshot member range under
   `04-artifacts/source/`, and the deviation rows the task licenses.
2. Invoke `sd-implementer` with:
   - `TASK_DETAILS = <full task block>`
   - `SPEC_REF = .specs/PORT-<slug>-<YYYYMMDD>/00-spec.md`
   - `IMPACT_REF = .specs/PORT-<slug>-<YYYYMMDD>/03-decisions.md`
   - `WORKFLOW_TYPE = port`
3. Run the task's test via `commands.test`.
4. **Self-check** (main thread, no per-task reviewer - same cost argument as `/sd:feature` Phase
   4): only files in `Files` were touched; the diff touches only what the cited member range
   accounts for, or a licensed deviation row; the test passes.
5. Check off the task in `02-tasks.md` (set its `Status` line to `done`, per the "Check-off
   marker" section of the **sd-atomic-task-format** skill). Log one line to `05-retro.md`:
   `T<NN>: <status> - <note>`.

### ⛔ Gate 5 - Batch tests green

STOP after every batch. Display the `commands.test` result and the Phase 5 pinned-suite result.

> Batch <n> of PORT-<slug>: tests <green|red>, pinned suite <green|red>. (continue / revert batch / abort)

- `continue` -> permitted only when both are green. Check off the batch, start the next one.
- `revert batch` -> revert the batch, re-plan the offending task, retry.
- `abort` -> stop the workflow. Leave the spec at status `in-progress`.

A red batch is reverted or fixed, never deferred - batched-with-tests-between exists to localize
the failure.

Move to the next batch. Repeat until every batch is checked off.

---

## Phase 8 - Justified-diff parity review

1. **Main thread generates `04-artifacts/parity/`** per `sd-port-fidelity`'s "Parity artifacts"
   section: one unified diff per non-`omit` path-mapping row (snapshot side first, host side
   second, at least 3 lines of context), file name = `Host path` with `/` replaced by `__`, suffix
   `.diff`; an all-deletion diff for a row whose host file is absent; an all-addition diff for
   every changeset file with no mapping row; `INDEX.md` at the parity root, columns `Diff file |
   Snapshot path | Host path | Mapping row`. Regenerated and overwritten every run - nothing under
   `parity/` is frozen or appended to `paths.protected`. A row whose diff could not be produced
   says so in its `Mapping row` cell rather than being dropped.
2. Run `commands.test` and `commands.lint`.
3. Invoke `sd-reviewer` with:
   - `TASK_TYPE = port-parity`
   - `SPEC_REF = .specs/PORT-<slug>-<YYYYMMDD>/00-spec.md`
   - `DIFF_REF = .specs/PORT-<slug>-<YYYYMMDD>/04-artifacts/parity/INDEX.md`
   - `CHANGED_FILES = <all host files changed across every batch>`
   - `SNAPSHOT_REF = .specs/PORT-<slug>-<YYYYMMDD>/04-artifacts/source/`

### ⛔ Gate 6 - Justified-diff parity (HARD)

STOP. Display the `justified` count as a single number, then each `unjustified` / `missing` /
`extra` / `overreached` finding, member completeness as `<n>/<total>`, the path-conformance BLOCK
count, and the test + lint summary.

**Case A - zero BLOCK.** Ask:

> PORT-<slug> parity clean: <J> justified hunks, members <n>/<n>, no unmapped file. Proceed to close-out? (yes / re-run parity / abort)

**Case B - one or more BLOCK.** The gate refuses close-out. Exactly two resolutions exist. Ask:

> PORT-<slug> parity: <B> BLOCK finding(s). Choose a resolution: (revert-to-snapshot <hunks> / add-deviation <rows> / re-run parity)

- `revert-to-snapshot <hunks>` -> route the named hunks to `sd-implementer` to restore the
  snapshot form, regenerate `04-artifacts/parity/`, re-invoke the reviewer.
- `add-deviation <rows>` -> route to `sd-spec-architect` (`TASK = refine`) to add rows whose group
  and citation hold up, regenerate, re-invoke.
- `re-run parity` -> regenerate and re-invoke with no spec or code change.

This gate is HARD and has no override. Deriving the missing rows from the unexplained hunks is not
a resolution - it makes the diff justify itself.

---

## Phase 9 - Close-out

1. Tick each `AC-<n>` checkbox only against evidence logged to `05-retro.md`. `AC-1`'s evidence is
   the clean parity report - cite `04-artifacts/parity/INDEX.md` and the reviewer verdict. Never
   tick a box just to make a verification check pass.
2. Run `/sd:verify PORT-<slug>-<YYYYMMDD>`. It must report `result: pass`.
3. Write to `05-retro.md` under `## PR description block`: the deviation table copied verbatim
   (each row is already PR-ready), the Donor + Commit lines from `MANIFEST.md`, the license
   obligation from Donor provenance, and `<n>/<total>` members ported.
4. **Spawned specs**: ensure one row in `00-spec.md`'s `## Spawned specs` per donor defect
   reproduced deliberately (a group-4 deviation is not one - it was already agreed and applied).
   Reserve the IDs and print the follow-up commands (e.g. `/sd:bug <slug>`) for the user to run
   separately; do not create the children from this workflow.
5. **Divergence record**, appended to `05-retro.md` under `## Divergence record`: every deviation
   ID with its group, citation, and the hunks it covered; every donor defect reproduced as-is with
   its reserved follow-up ID; the snapshot commit.
6. Set status=`done` in `00-spec.md` and `.specs/index.md`.
7. Print a 5-line summary: donor, scope, members ported, deviations applied, spawned follow-ups.

---

## Rules (hard constraints)

- Change `.specs/index.md` and any spec `status:` field with the Edit tool only - never a shell
  command (`sed -i`, `>`, `tee`, `Set-Content`). spec-gate checks an Edit-tool change (Rules 0,
  0b, 1) and records its `spec_transition`; a shell write skips both (SW-79).
- Phase 0 always runs, even on resume.
- Gates 1, 2, 3, and 6 are HARD - no override path. Gates 4 and 5 are ordinary approvals; the
  workflow still declares 6 total gates.
- `--scope` is never inferred. `--from`'s form (bridged artifact vs in-repo path) selects topology
  only - every phase after Phase 1 is identical regardless of which one was used.
- Port policy is Layer 2. This file never states one; it reads and reports the host's, or the
  documented default (structural mirror).
- The snapshot is immutable evidence once frozen. Re-freezing happens only through Gate 1's
  `re-capture` resolution.
- **Lifecycle**: this workflow drives `draft -> approved -> in-progress -> done` and takes no other
  edge. `abort` at any gate leaves the spec at its current state - it never jumps to `archived`,
  which `/sd:spec status` reaches only from `done`. This is a deliberate divergence from
  `/sd:feature` and `/sd:refactor`, which use a `draft -> archived` shortcut on abort; a port spec
  aborted mid-flight resumes exactly where it left off instead.
- No hardcoded stack command anywhere: tests, build, lint, and coverage come from `commands.test` /
  `commands.build` / `commands.lint` / `commands.coverage`; paths from `paths.src` / `paths.tests` /
  `paths.layers` / `paths.protected`.
- Model references are aliases only (`sonnet`, `haiku`, `opus`, `inherit`) - never a full model ID.
- **Model escalation follows `sd-model-escalation` only.** Rule `ESC-PORT-06` is applied at Phase 6
  step 2; the ladder, precedence, `models.escalation` config and the `05-retro.md` line format live
  in the skill and are not restated here.
- Snapshot visibility: this command warns about host tooling globbing `.specs/` and never edits the
  host's build, lint, or coverage configuration.
- Implementer touches only files declared in the task's `Files` list. Any scope creep -> stop,
  surface to main thread, log to retro.
- Out of scope: `--sync` / re-port drift detection, multi-donor ports.
- All files under `.specs/PORT-<slug>-<YYYYMMDD>/` are written in UTF-8 with no BOM.
