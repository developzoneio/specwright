---
description: Standalone constitution-compliance review. Severity-tagged findings with file:line citations. Constitution required.
argument-hint: [path | "recent" | "spec <ID>" | (interactive)]
---

# /sd:review

Standalone review via `sd-reviewer`. Does NOT modify code. Produces severity-tagged findings with file:line citations.

**Argument formats**:
- `<path>` (file or directory) -> review the contents of that path.
- `recent` or `recent <N>h` -> review files modified in the last N hours (default 4).
- `spec <ID>` -> review the changed files associated with a spec.
- *(no args)* -> interactive prompt.

---

## Phase 0 - Bootstrap (always)

1. Read `CLAUDE.md`.
2. Read `.specs/constitution.md`. **If missing, ABORT** with: "Constitution is required for compliance review. Run `/sd:setup` first."
3. Read `.claude/project-config.json` for path conventions.
4. Read `.specs/index.md` if mode is `spec <ID>`.

The constitution check is a hard precondition. Without it, the reviewer has nothing to review against.

---

## Phase 1 - Resolve mode + collect target files

Parse `$ARGUMENTS`:

### Mode A: path

If first token is a path (file or directory exists):
- File -> review that one file.
- Directory -> review all code files under it (respecting `.gitignore`-style filtering, skipping `node_modules/`, `bin/`, `obj/`, `dist/`, etc.).

### Mode B: recent

If first token is `recent` or `recent <N>h` or `recent <N>m`:
- Default window: 4 hours.
- Parse window value if provided.
- Collect files in `paths.src` (and `paths.tests`) whose mtime is within window.
- Limit to 50 files; tell user to narrow if more.

### Mode C: spec <ID>

If first two tokens are `spec <ID>`:
- Verify `.specs/<ID>/` exists.
- Collect changed files from spec sources:
  1. `.specs/<ID>/02-tasks.md` -> each task's `Files:` field.
  2. `.specs/<ID>/03-decisions.md` -> any "Affected files" section.
  3. Fallback: list all files cited as `file:line` in the spec.
- Deduplicate. Verify each exists.

### Mode D: interactive

If no args:
- Prompt: "Review target: (1) recent 4h (2) spec <ID> (3) path <path> (4) custom"
- Resolve based on choice.

After resolution, print: "Reviewing <N> files in mode <A|B|C|D>."

---

## Phase 2 - Invoke `sd-reviewer`

Invoke with:
- `TASK_TYPE = standalone`
- `TARGET_FILES = <list>`
- `CONSTITUTION = .specs/constitution.md`
- `SPEC_REF = <.specs/<ID>/00-spec.md if Mode C, else none>`

Reviewer's output format is fixed (defined in `agents/reviewer.md`):
- Sections per severity: 🔴 BLOCK, 🟠 WARN, 🟡 SUGGEST, 🟢 PASS.
- Every finding cites `file:line`.
- Verdict counts at the top.
- Constitution rule references (e.g. `[§1.1]`) on every finding.

---

## Phase 3 - Present output

1. Display the reviewer's findings inline.
2. Print verdict summary at the bottom:

```
Verdict: <N> BLOCK, <N> WARN, <N> SUGGEST, <N> PASS across <F> files.
```

3. Offer:

> Save this review? (yes / no)

- `no` (default) -> end.
- `yes` -> save to `.specs/_reviews/review-<mode>-<YYYYMMDD-HHmm>.md`:

```
---
type: review
mode: <A|B|C|D>
target: "<resolved target>"
spec_ref: <ID or none>
files_reviewed: <count>
verdict: <N> BLOCK, <N> WARN, <N> SUGGEST, <N> PASS
created: <ISO timestamp>
---

# Review: <target summary>

<reviewer output>
```

Print the saved path.

---

## What happens if findings include 🔴 BLOCK?

This command does NOT auto-fix. It surfaces. If the user wants to act on BLOCKs:

- For findings related to an active spec -> route to that spec's workflow (e.g. `/sd:bug <ID>` continuation, or a new fix-up task).
- For findings independent of any spec -> suggest `/sd:bug <slug>` if the finding is a defect, or `/sd:refactor <slug>` if structural.
- For constitution-design issues (the rule itself needs amending) -> suggest an ADR via a `REF-*` spec.

---

## Rules (hard constraints)

<!-- sd-model-escalation: no rule -
     single read-only sd-reviewer call per run, and in modes A/B/D there is no spec frontmatter
     to read a trigger from. Decided in SW-62, not forgotten. -->
- Constitution is required. Without it, the command aborts in Phase 0.
- Read-only. Never modifies code. Reviewer's tool allowlist excludes write tools.
- Every finding cites file:line. Findings without citations are not displayed (reviewer is re-prompted).
- BLOCK / WARN / SUGGEST / PASS severities are not interchangeable. The reviewer's `agents/reviewer.md` defines criteria; this command does not relabel.
- Save destination is always `.specs/_reviews/`. Reviews are NOT tracked in `.specs/index.md` (scratchpad, like explorations).
- For Mode C (spec <ID>), if the spec is status `done` or `archived`, warn the user: "This spec is closed. Findings may relate to drift since closure."
