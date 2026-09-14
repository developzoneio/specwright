# Spec-lint fixture

Two `.specs/` trees for exercising `/sd:spec validate`, backing the SW-4 acceptance criterion:
*a seeded broken spec surfaces each violation at the right severity; a clean tree returns
all-PASS.*

| Tree | Expectation |
|---|---|
| [`clean/`](clean/) | Every spec PASSes. `_No findings._` under all four severity sections. |
| [`broken/`](broken/) | Every finding in the table below, at the stated severity, and nothing else. |

Rule IDs (`SL0xx`) are defined in the rule table in `commands/spec.md`, under `## validate`.

---

## How to run it

`/sd:spec validate` is a **prompt**, not executable code, so no script can run it and CI cannot
gate on it. Read that limitation before trusting a green build: see "What this does not do" below.

```
cd examples/spec-lint-fixture/clean     # then, in a Claude Code session rooted here:
/sd:spec validate --all                 # expect: every spec PASS, no findings

cd ../broken
/sd:spec validate --all                 # expect: exactly the findings in the table below
```

The fixture ships its own `.claude/project-config.json` so `validate` can resolve `spec.dir` and
`spec.lifecycle` without a full `/sd:setup`. Placeholder checks read the type's template from
`~/.claude/templates/sd/specs/`, so the engine must be installed for `SL010` / `SL011` / `SL012`
to be exercised; without it those checks raise `SL013` instead.

---

## Why `clean/` is the interesting half

`clean/PERF-CLEAN-002` is at `approved` with its `<<PHASE-2: ...>>` baseline token **unfilled**,
and it must PASS. Under the pre-SW-4 rule ("status >= `approved` -> no `<<placeholder>>` tokens
remaining") this correct spec FAILED, while `broken/PERF-BROKEN-002` — the same spec with a
baseline invented from memory — PASSED. The two perf specs are a matched pair: any change that
makes one behave like the other has reintroduced the bug SW-4 seam 1 fixed.

`clean/BUG-CLEAN-003` is `done` and its "Fix approach" section names a follow-up deferred to a
separate spec - but that follow-up carries a reserved ID (`REF-CLEAN-004`) in its
`## Spawned specs` table, so `SL090` stays silent. `broken/FEAT-BROKEN-015` is the same shape with
the table left empty, and `SL090` fires. The two are a second matched pair: any change that makes
`BUG-CLEAN-003` behave like `FEAT-BROKEN-015` has broken `SL090`.

`clean/PORT-CLEAN-004` and `broken/PORT-BROKEN-016` are a third matched pair, for the `SL061`-
`SL066` port task-block band (SW-49): identical donor scenario and fidelity tables, differing only
in `02-tasks.md`. Every task block in the clean half cites an in-range snapshot member and a
correct `Licensed deviations:` line; the broken half isolates one seeded defect per task (six
tasks, six rules) so each finding is independently traceable.

---

## Expected findings in `broken/`

Each `00-spec.md` carries `<!-- SEEDED: ... -->` comments naming its own violations, so a finding
can be traced to an intentional seed rather than an accident.

| Spec | Rule | Severity | Seeded violation |
|---|---|---|---|
| `BUG-BROKEN-001` | `SL003` | BLOCK | `id: BUG-BROKEN-999` in a folder named `BUG-BROKEN-001` |
| `BUG-BROKEN-001` | `SL030` | BLOCK | Index row says `approved`, frontmatter says `draft` |
| `PERF-BROKEN-002` | `SL011` | BLOCK | `PHASE-2` baseline filled from memory at `approved` |
| `REF-BROKEN-003` | `SL002` | BLOCK | Required field `smell` missing |
| `REF-BROKEN-003` | `SL020` | BLOCK | `in-progress` refactor with no `01-plan.md` / `02-tasks.md` |
| `REF-BROKEN-003` | `SL042` | BLOCK | Frontmatter `in-progress`; retro log ends at `approved` |
| `FEAT-BROKEN-004` | `SL050` | BLOCK | `related-to: FEAT-NOPE-999` resolves to nothing |
| `FEAT-BROKEN-004` | `SL051` | BLOCK | `depends-on: RCA-BROKEN-005` has no inverse |
| `FEAT-BROKEN-004` | `SL033` | BLOCK | Listed on two index rows |
| `RCA-BROKEN-005` | `SL031` | BLOCK | Folder exists, no index row (orphan) |
| `FEAT-BROKEN-007` | `SL006` | BLOCK | `linked_specs: none` is a scalar, not a list |
| `FEAT-BROKEN-007` | `SL010` | BLOCK | Author-fill `<<...>>` tokens survive at `approved` |
| `BUG-BROKEN-008` | `SL051` | BLOCK | Three links, none with an inverse |
| `BUG-BROKEN-008` | `SL052` | BLOCK | `duplicate-of: BUG-BROKEN-008` is a self-link |
| `BUG-BROKEN-008` | `SL053` | WARN | `blocked-by` stored - an alias `link` normalizes away |
| `BUG-BROKEN-008` | `SL054` | WARN | `related-to: FEAT-BROKEN-004` listed twice |
| `REF-BROKEN-009` | `SL040` | BLOCK | Retro logs `draft -> done`, not an edge in the machine |
| `REF-BROKEN-009` | `SL020` | BLOCK | `done` refactor with no `01-plan.md` / `02-tasks.md` |
| `REF-BROKEN-009` | `SL012` | WARN | `PHASE-2` / `PHASE-3` tokens unfilled at `done` |
| `BUG-BROKEN-010` | `SL004` | BLOCK | `type: feature` in a folder whose `BUG` prefix means `bug` |
| `FEAT-BROKEN-011` | `SL005` | BLOCK | `status: reviewing` is not in `spec.lifecycle` |
| `FEAT-BROKEN-011` | `SL043` | BLOCK | Status is not `draft` and there is no retro log |
| `PERF-BROKEN-012` | `SL021` | BLOCK | `done` with a `05-retro.md` that has only its header |
| `REF-BROKEN-013` | `SL041` | BLOCK | Retro jumps `approved` -> an entry opening at `in-progress` |
| `FEAT-BROKEN-014` | `SL044` | WARN | `archived -> in-progress` logged with an empty reason |
| `FEAT-BROKEN-015` | `SL090` | SUGGEST | `done` spec names deferred work; `## Spawned specs` table is empty |
| `PORT-BROKEN-016` | `SL061` (T01) | BLOCK | `Pattern refs` is prose, not the snapshot-member-range shape |
| `PORT-BROKEN-016` | `SL062` (T02) | BLOCK | `Pattern refs` shape is right, path is a host sibling, not `04-artifacts/source/` |
| `PORT-BROKEN-016` | `SL063` (T03) | BLOCK | `Pattern refs` names a path absent from `MANIFEST.md` |
| `PORT-BROKEN-016` | `SL064` (T04) | BLOCK | `Pattern refs` range (100-120) falls outside the manifest's recorded 10-70 |
| `PORT-BROKEN-016` | `SL065` (T05) | BLOCK | `Acceptance` carries no `Licensed deviations:` line |
| `PORT-BROKEN-016` | `SL066` (T06) | BLOCK | `Licensed deviations: D99` - `D99` is not in the Deviation table |
| _(tree-wide)_ | `SL032` | BLOCK | `BUG-GHOST-006` row in `index.md` has no folder |

`FEAT-BROKEN-011` is the one spec that seeds two rules on purpose. An illegal `status` cannot
have a legal retro log - no edge in the state machine ends at `reviewing` - so `SL005` always
drags `SL043` with it, and adding a retro to silence `SL043` would raise `SL040` instead.

### Rules these seeds hold apart

Four of the new seeds exist as much to keep neighbouring rules **from** firing as to make their
own rule fire. Each `00-spec.md` explains its own boundary; the summary:

| Seed | Must fire | Must stay silent, and why |
|---|---|---|
| `BUG-BROKEN-010` | `SL004` | `SL002` / `SL011` - it carries both types' required fields and the bug template's phase tokens, so neither type resolution yields a second finding |
| `PERF-BROKEN-012` | `SL021` | `SL043` (the retro file exists) and `SL042` (no last entry to disagree with) |
| `REF-BROKEN-013` | `SL041` | `SL040` (both edges are legal), `SL042` (last entry matches frontmatter), `SL043` (a retro exists) |
| `FEAT-BROKEN-014` | `SL044` at **WARN** | `SL040` / `SL041` / `SL042` - the chain is contiguous, legal, and ends where frontmatter says |
| `FEAT-BROKEN-015` | `SL090` at **SUGGEST** | `SL010` / `SL012` / `SL020` / `SL021` / `SL055` - plan, tasks, retro and a passing `06-verify.md` are all present, and the feature template has no phase-deferred token |

---

## What this does not do

**It is not automated.** `/sd:spec validate` is a prompt executed by a model, so `scripts/`
cannot run it the way `selftest-docs.{ps1,sh}` runs Check 7 of `scripts/validate.{ps1,sh}`.
Automating it in CI would mean reimplementing the linter as an executable script — a second copy
of the rules, which is precisely the drift that SW-1 and SW-3 exist to prevent. Until that
trade-off is decided, this fixture makes the acceptance criterion **reproducible**, not
**enforced**.

**Rule coverage is partial: 31 of the 43 rules are seeded.** `SL061`-`SL066` (port task-block) are
seeded directly in this fixture (`PORT-CLEAN-004` / `PORT-BROKEN-016` above). The `SL07x`
revision-log and `SL08x` port-fidelity bands are exercised by their own fixtures instead - see
`tests/revision-log/fixtures/` for `SL07x`; `SL08x` has no fixture anywhere yet, a pre-existing gap
this ticket does not close. Not seeded in this fixture, and why:

| Rule | Why not seeded |
|---|---|
| `SL001` | Unparseable frontmatter would break the fixture for every other reader/tool. |
| `SL013` | Needs an unreadable template, i.e. a broken engine install - not reproducible from a checked-in tree. |

Both remaining gaps are structural rather than unwritten work: each needs the fixture itself, or
the engine install underneath it, to be broken in a way a checked-in tree cannot express. Closing
them means a harness that corrupts a throwaway copy - the shape `scripts/selftest-docs.{ps1,sh}`
already uses for Check 7 - not another seeded spec.

A linter run over `broken/` that reports a rule from this second table has found a real bug in the
fixture, not in the spec tree.
