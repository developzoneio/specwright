# sd-pattern-discipline

Pattern discovery and adherence rules for specwright. New code must read as if written by the
team that wrote the surrounding code. Applied by `sd-spec-architect` (authoring `Pattern refs`),
`sd-implementer` (following them), and `sd-reviewer` (verifying conformance).

Read the section matching your role. The core rule applies to everyone.

---

## The core rule

Before writing new code, find the precedent. The codebase - not your training data - defines what
"idiomatic" means here. Discovery is always by sampling (Glob / Grep / Read of 1-3 files), never
by stack assumption. If the precedent and your habits disagree, the precedent wins.

---

## Discovering precedents (sd-spec-architect)

For every task that creates a new file or introduces a new public symbol:

- **New file** -> `Glob` the target directory (and the nearest sibling directory if the target is
  new or sparse). Pick the 1-3 existing files closest in role to what the task creates. Those are
  the `Pattern refs`.
- **New symbol** (class / function / endpoint / handler / etc.) -> `Grep` for existing symbols of
  the same kind. Observe the naming morphology (prefix, suffix, casing, pluralization) and cite
  one representative example.
- **New utility / helper** -> search for an existing equivalent FIRST (`Grep` the domain noun and
  verb). If found, the ref says "reuse this - do not write a new one". If not found, state what
  was searched so the implementer does not repeat the search.
- **Budget**: max 3 sampled files per target directory. Verify every ref exists (`Glob` or `Read`)
  before citing it - a hallucinated precedent is worse than none.

## Authoring Pattern refs (sd-spec-architect)

- Field format lives in **sd-atomic-task-format**. Each ref is `file:line` plus a one-line
  instruction of WHAT to mirror ("mirror handler structure and registration", "name after this
  precedent", "reuse this helper - do not duplicate").
- Required for any task that creates a new file or introduces a new public symbol.
- `none` is acceptable only for tasks that exclusively edit existing files - there, the file
  itself is the precedent.

---

## Following patterns (sd-implementer)

- Read every file cited in `Pattern refs` BEFORE creating or editing anything. Cap: 3 files.
- **Creating a new file**: mirror the closest ref - file placement, header / import organization,
  member ordering, naming, and where its test file lives.
- **Naming a new symbol**: follow the morphology of the cited precedent, not your default style.
- **Before writing any helper not named in the task**: ONE `Grep` for an existing equivalent.
  Found -> use it. Not found -> write it, and note the search in your summary.
- **Stale refs**: line numbers may have drifted since planning. Treat a ref as file + nearby
  region. If the cited symbol moved, `Grep` its name once. If the file is gone, fall back to the
  nearest sibling file and note the substitution in your summary - do NOT stop for ref drift.
- **Conflict**: if a Pattern ref contradicts the constitution, the constitution wins. Follow the
  constitution and surface the mismatch in your summary.

---

## Verifying conformance (sd-reviewer)

- For each NEW file in the changeset: compare it against the task's `Pattern refs` (or the
  nearest sibling file if the task has none). State explicitly what you compared against (`file`).
- Deviation from an explicit Pattern ref -> WARN, anchored to the task block.
- Convention drift with no Pattern ref and no constitution anchor -> SUGGEST.
- A new utility duplicating an existing one -> WARN, citing both `file:line`.
- Never BLOCK solely because a task lacks a `Pattern refs` field. The field is required only when
  a task creates a new file or introduces a new public symbol (marked `(new)` / `(new symbol)` on
  the task's `Files` entry, per **sd-atomic-task-format**); a missing one on such a task is a
  spec-authoring defect, not a defect in the code under review - it belongs to `/sd:spec validate`
  as `SL060` (WARN), and older specs predate the requirement entirely. Reviewing the code against
  the nearest sibling file is the right response; failing the review is not.

---

## Anti-patterns

- **Inventing a "better" structure than the precedent.** Consistency beats local optimality. If
  the precedent is genuinely bad, surface it - do not silently diverge.
- **Scanning the repo broadly.** 1-3 reference files, sampled and cited. Pattern discovery is a
  bounded read, not an audit.
- **Citing precedents from memory.** Verify the file exists before citing it.
- **Writing a helper without one search for an existing equivalent.** Duplicated utilities are
  how codebases rot.
- **Treating Pattern refs as optional reading.** They are part of the task contract, same as
  `Acceptance`.
