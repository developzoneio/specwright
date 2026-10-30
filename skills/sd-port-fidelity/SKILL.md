# sd-port-fidelity

Cross-project port fidelity policy for specwright. A port reproduces a donor implementation inside
a host repo; the donor's form is the specification, and every departure from it is a citable
decision rather than a preference. Authored into port specs by `sd-spec-architect` and enforced
against the changeset by `sd-reviewer`.

Read the section matching your role. The core rule and the deviation allowlist apply to everyone.

---

## The core rule

**Mirror the donor structurally. Every departure is a row in the deviation table, or it is a
defect.**

Structural mirror means the host reproduces, as far as the target permits: the donor's file
layout, member set, member order, symbol names, local variable names, step order within each
member, attribute order, and log message text. Judgement is not the mechanism here. A departure
carrying a deviation row is legal; a departure carrying none is a defect; and nobody is asked to
decide which of the two a given hunk is.

---

## Deviation allowlist

Exactly four groups force a departure. Each requires its own citation - a row citing nothing is
invalid, and the hunk it claims to cover is unjustified.

| Group | Forced by | Citation required |
|---|---|---|
| 1 | Compiler, namespace, or assembly conflict | the conflicting identifier |
| 2 | Host constitution | the constitution section, `§N.M` |
| 3 | Host precedent | `file:line` in the host |
| 4 | Behavior parity fix on an agreed donor defect | the parity criterion it satisfies |

Anything outside these four reverts to the donor form. "Cleaner", "more idiomatic to me", and "the
host does it differently somewhere" are not groups.

---

## Anti-simplification rules

These bind the implementer through the task blocks the architect writes, not by the implementer
loading this file: `sd-spec-architect` puts each applicable rule into the port task's `Acceptance`
and cites the donor `file:line` in `Pattern refs` (see **sd-atomic-task-format**).

- **No unrequested simplification.** Shorter is not better. Collapsing branches, merging members,
  or replacing a loop with a library call is a departure and needs a row.
- **No gratuitous rename.** Donor identifier names carry over even where host style would differ.
  Group 1, group 3, or nothing.
- **No reordering.** Statement order, parameter order, and member order follow the donor, even
  where another order reads better.
- **No opportunistic fix.** A donor defect is reproduced as-is and recorded for a follow-up spec.
  Fixing it inline is group 4 only when the fix was agreed at the gate before implementation began.
- **Host constitution beats donor precedent.** "It is only a copy" exempts nothing. A donor form
  that violates the host constitution is a cited group 2 deviation, never a verbatim import.

---

## Gate tables (sd-spec-architect)

A port spec carries three tables. Each has a completeness condition the gate evaluates
mechanically - it counts and matches, it never assesses whether a reason is good. A table failing
its condition is incomplete and the gate refuses it.

The spec must also carry a **fidelity acceptance criterion**: the criterion these tables are
evidence for. It is what review findings anchor to, and without it a fidelity finding has no legal
anchor (see **sd-severity-taxonomy**). A port spec missing it fails the gate.

### Path mapping table

| Column | Contents |
|---|---|
| `Donor path` | repo-relative path in the donor |
| `Host path` | repo-relative destination in the host |
| `Kind` | `mirror` / `merge` / `omit` |
| `Reason` | required when `Kind` is not `mirror`; `-` when it is |

**Complete when**: one row per file in the declared donor scope and no others; every `Host path`
unique; no empty cell; every non-`mirror` row carries a non-empty `Reason`.

### Member manifest

| Column | Contents |
|---|---|
| `Donor path` | the donor file the member comes from |
| `Member` | donor symbol name, verbatim |
| `Ordinal` | 1-based position of the member within that donor file |
| `Host path` | destination, copied from the path mapping table |
| `Status` | `ported` / `deviated` / `omitted` |
| `Deviation ID` | `D<NN>` when `Status` is not `ported`; `-` when it is |

**Complete when**: one row per member of every non-`omit` donor file; the `Ordinal` values within
each `Donor path` form `1..N` with no gap and no duplicate; each `Host path` equals the mapping row
for its `Donor path`; every non-`ported` row names a `Deviation ID` present in the deviation table.

### Deviation table

| Column | Contents |
|---|---|
| `ID` | `D<NN>`, unique, ascending |
| `Donor form` | the donor name, order, or text departed from |
| `Host form` | what the host uses instead |
| `Group` | `1`, `2`, `3`, or `4` from the allowlist |
| `Citation` | the citation that group requires, verbatim |

**Complete when**: every `ID` unique; every `Group` is one of `1` to `4`; every `Citation` is
non-empty and in the shape its group requires; every `Deviation ID` named in the member manifest
appears here exactly once; no row here is unreferenced by the manifest.

---

## Snapshot artifacts (sd-spec-architect)

Under a port spec's `04-artifacts/source/`: the bridged contract always, and under
`snapshot: contract+source`, the donor files too. `MANIFEST.md` sits at that directory's root.

### Snapshot manifest format

- **Donor**: <repo url or path>
- **Commit**: <full sha>
- **Captured**: <YYYY-MM-DD>
- **Mode**: contract | contract+source
- **Hash algorithm**: sha256, lowercase hex, over the bytes as captured

| Snapshot path | Donor path | Commit | Bytes | SHA-256 | Member ranges |
|---|---|---|---|---|---|
| `orders/order-intake` | `src/orders/order-intake` | `<sha>` | 4821 | `3f9a...` | `1: CreateOrder 12-58; 2: ValidateTotals 60-93` |

One row per captured file. `Member ranges` is `<ordinal>: <member> <firstLine>-<lastLine>`,
semicolon-separated, ordinals contiguous from 1 - the same ordinals the Member manifest table uses.

### Two snapshot rules

1. **Cite the snapshot, not the donor.** Path mapping and Member manifest rows cite `Snapshot
   path`, never a donor-repo path - donor line numbers rot the moment the donor changes; the
   snapshot is frozen. Donor paths, the commit, and line ranges live only in `MANIFEST.md`,
   addressed by `(Snapshot path, Ordinal)` - the Member manifest table carries no line-range
   column of its own.
2. **Quarantine.** The snapshot directory is evidence, never a copy source handed to an
   implementer without a Member manifest row and an allowed-deviation list scoping it.

### Immutability

At freeze, every file under `04-artifacts/source/` plus `MANIFEST.md` is appended as an
**individual literal string** to `paths.protected` in `.claude/project-config.json`. Both
`spec-gate` hooks match `paths.protected` by exact string equality, not glob - the enumeration
*is* the mechanism, not a workaround for one. The append must be idempotent. `/sd:spec` cannot
perform this step itself (it never touches `.claude/`); `/sd:port` Phase 2 performs the freeze.
Outside that pipeline it stays a documented manual step. `spec-gate` guards `Edit`/`Write` only -
it does not stop a shell delete.

Per-file hashes are recorded now so a later drift check (re-hashing the donor at a newer commit)
remains possible; consuming them is out of scope for this story.

---

## Parity artifacts (main thread)

The diff `sd-reviewer` adjudicates is produced by the main thread, never by an agent. The reviewer
has no `Bash` and no write tool - that allowlist is what structurally stops the adjudicator from
fixing what it judges - so the diff must already be a file on disk when the reviewer is invoked.

Output root is `04-artifacts/parity/`, a sibling of the frozen `04-artifacts/source/`: same spec,
same artifacts folder, evidence produced at a later phase by a different actor. Nothing under
`parity/` is frozen or appended to `paths.protected` - it is regenerated on every parity run and
overwrites the previous one.

- One diff per non-`omit` path mapping row, snapshot side first, host side second, unified format,
  at least 3 lines of context. File name is the `Host path` with `/` replaced by `__`, suffix
  `.diff`.
- A mapping row whose `Host path` does not exist still gets its diff - an all-deletion one. That is
  what makes a `missing` member visible without the reviewer listing the host tree itself.
- Every changeset file with no mapping row gets an all-addition diff, named the same way. Path
  conformance is then a property of the diff set rather than a second traversal.
- Every pinning file (see "Pinning files" below) gets a diff from its pinned copy to its host
  form, named the same way. It is not a changeset file, so it never gets the all-addition diff.
- `INDEX.md` at the parity root, one row per diff file: `Diff file`, `Snapshot path`, `Host path`,
  `Mapping row` (the path mapping row number, `pinning` for a pinning file, whose `Snapshot path`
  cell holds its pinned copy, or `-` when there is none).

`INDEX.md` is the reviewer's `DIFF_REF`. A run that cannot produce a diff for a row says so in that
row's `Mapping row` cell instead of dropping the row - a silently absent row reads as a clean file.

---

## Hunk classification (sd-reviewer)

Classify every hunk of the port changeset into exactly one class. The vocabulary is closed - there
is no sixth class and no "probably fine".

| Class | Condition | Verdict |
|---|---|---|
| `justified` | maps to a deviation row whose citation satisfies its group | accept |
| `unjustified` | departs from the donor form with no deviation row covering it | BLOCK |
| `missing` | a manifest member has no host counterpart and no `omitted` status | BLOCK |
| `extra` | host content with no donor counterpart and no deviation row | BLOCK |
| `overreached` | a deviation row covers the hunk, but the hunk changes more than that row's `Host form` states | BLOCK |

`overreached` is where a rubber stamp hides: one legitimately cited rename carrying an unrelated
reordering in the same hunk. Judge the hunk against the row's `Host form` text, never against the
mere existence of a row.

A `justified` hunk is a PASS and is not written up as a finding - report the count in the summary
line. Listing them individually buries the BLOCKs they outnumber.

Anchor every fidelity BLOCK to the port spec's fidelity acceptance criterion - a spec acceptance
criterion is a legal anchor for a code target under **sd-severity-taxonomy**. Cite the deviation
row, or its absence, as the supporting `file:line` per **sd-evidence-citation**. A deviation row is
evidence; it is never the anchor by itself.

### Whole-artifact checks

Two checks no hunk class can express, because each is a property of the changeset as a whole. Both
run once per parity review, both are BLOCK, and both are reported even when they pass - the count
is the evidence the check ran.

| Check | Question | Reported as |
|---|---|---|
| Member completeness | does every manifest row with `Status` `ported` or `deviated` have a host counterpart? | `<n>/<total> members present`, plus one BLOCK naming the `Donor path`, `Member` and `Ordinal` of each absent row |
| Path conformance | does every changeset file appear as a `Host path` in the path mapping table? | one BLOCK per unmapped file, citing the file and the table it is missing from |

Both belong to the reviewer rather than to `/sd:verify`, which decides everything from the spec's
own artifacts and reads no host source - the reasoning is recorded in `docs/architecture.md`.

### Pinning files

The behavior-pinning tests are written under `paths.tests` before any host code exists, and are
listed on the `Pinning files:` line of the `## Behavior pinning` section of `03-decisions.md`,
with a pinned copy of each saved under `04-artifacts/pinning/as-pinned/`. They pin the donor's
behavior; they port nothing, so the path mapping table has no row for them and never needs one.

- **Not changeset files.** A pinning file is left out of the changeset that path conformance
  reads, even when a task later edited it (re-pointing a characterization test from donor to
  host is such an edit). Counting it there would block every port that pins, and neither
  resolution would fit: there is no snapshot form to revert to, and a deviation row for it would
  be derived from the diff.
- **Still adjudicated.** Its pinning diff (`Mapping row` `pinning` in `INDEX.md`) is read like any
  other. The pinned assertions must be the ones Gate 3 approved, so the diff may touch only what
  the recorded mechanism allows to change: the one construction-seam factory method for
  characterization tests, the target parameter for a contract suite. Any other hunk is one BLOCK
  naming the file and what it changed. It is not one of the five classes, and its revert target
  is the pinned copy, not the snapshot.

### The parity gate

A HARD gate. Any BLOCK from the classification, from either whole-artifact check, or from a
pinning diff refuses close-out. Two resolutions exist: revert the host toward the snapshot (a
pinning file toward its pinned copy), or add a deviation row whose group and citation hold up,
then regenerate the parity artifacts and re-run. There is no third, and
no override - a gate that can be waived measures nothing. Deriving the missing rows from the
unexplained hunks is not a resolution either; it makes the diff justify itself.

---

## Anti-patterns

- **Improving the donor while porting.** The port is not the moment. Reproduce it, record it, and
  raise the follow-up.
- **A deviation row citing nothing.** "Host style" is not a citation; group 3 needs `file:line`.
- **Renaming to local taste.** Taste is not one of the four groups.
- **Reordering for readability.** Donor order is the order, attribute order included.
- **Waving a table through because it looks right.** The completeness conditions are counted, not
  judged. An incomplete table is refused without a discussion of intent.
- **Treating a donor defect as an invitation.** Record it; fix it in its own spec.
