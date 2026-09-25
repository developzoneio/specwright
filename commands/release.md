---
description: Release-note generation from done specs. Groups by type into Keep-a-Changelog sections, then archives them.
argument-hint: [version] [--dry-run]
---

# /sd:release

Generates release notes from completed specs and cuts a release. **No code is changed. No subagent is invoked.** All operations are file-system reads on `.specs/` plus controlled writes to `CHANGELOG.md`, `.specs/index.md`, and each released spec's `00-spec.md` frontmatter and `05-retro.md`.

The release model is **lifecycle-driven**:

- `done` = merged and complete, **not yet shipped** in a release.
- `archived` = shipped in a release.

A release collects every spec currently in `done`, writes their notes grouped into Keep-a-Changelog sections, then transitions each one `done -> archived`. The next release naturally sees only newly-completed work. No dates, tags, or manifests to track.

**Usage**: `/sd:release [version] [--dry-run]`

- `[version]` (optional): explicit SemVer, e.g. `1.4.0`. If omitted, it is inferred (Phase 3) and confirmed at the gate.
- `--dry-run`: render the notes and the archive plan, then stop. Writes nothing.

---

## State machine (resume behavior)

This command is **not** multi-phase-resumable like the workflows - it is a single transaction guarded by one gate. Re-invocation simply re-reads the current `done` specs:

- Re-run after a completed release -> the just-archived specs are gone from `done`, so only newer `done` specs appear. Safe.
- Re-run after `--dry-run` or after declining the gate -> nothing was written; recomputes from scratch.
- Interrupted mid-write (rare) -> Phase 5 writes the CHANGELOG first and archives second, so a partial run leaves specs still in `done` and the release re-runs idempotently.

---

## Phase 0 - Bootstrap (always)

1. Read `.claude/project-config.json` for `spec.dir`, `spec.indexFile`, `spec.prefixes`, `spec.lifecycle`, `ticket.baseUrl`, and `project.repo`.
2. Verify `.specs/index.md` exists. If not, prompt: "No spec index found. Run `/sd:setup` first." and STOP.
3. Locate the target `CHANGELOG.md` at the repo root.
   - Present -> it will be updated in place.
   - Absent -> a fresh Keep-a-Changelog file will be created (see Phase 5).

---

## Phase 1 - Collect releasable specs

1. Parse `.specs/index.md` rows (`ID | Type | Status | Created | Title`).
2. Select rows where `Status == done` AND `Type` is one of `feature`, `bug`, `refactor`, `perf`, `port`.
   - **RCA specs are never released or archived by this command.** An RCA is a deliverable, not a shippable code change; its fixes ship as their spawned BUG / REF / PERF specs.
3. For each selected spec, read `.specs/<ID>/00-spec.md`:
   - Cross-check frontmatter `status == done`. If it disagrees with the index, WARN and skip that spec (index/spec drift - tell the user to run `/sd:spec validate <ID>`).
   - Extract the H1 title (the `# ...` line) and the ticket reference (`jira:` field, unless it is `none` / empty / a `<<placeholder>>`).
4. If `05-retro.md` exists, read the most recent `Status: * -> done` log line for the completion timestamp (used only to order entries oldest-first within each section).
5. If zero specs qualify: print "No specs in `done` status to release. `/sd:spec list -- done` shows what is releasable." and STOP.

---

## Phase 2 - Group into Keep-a-Changelog sections

Map each spec type to a section:

| Spec type | Prefix | CHANGELOG section |
|---|---|---|
| feature | FEAT | Added |
| bug | BUG | Fixed |
| refactor | REF | Changed |
| perf | PERF | Changed |
| port | PORT | Added |

A port lands new host capability from the consumer's viewpoint, the same category as a feature -
donor provenance belongs in the spec, not the changelog line.

Within a section, order entries oldest-completed first. Render one bullet per spec:

```
- <H1 title> (<ID>[, <ticket>])
```

- Ticket reference present and `ticket.baseUrl` set -> render it as a link `[<TICKET>](<baseUrl>/<TICKET>)`.
- Ticket present but no `baseUrl` -> render the bare ticket ID.
- No ticket -> just `(<ID>)`.

Example: `- Add low-stock webhook notifications (FEAT-INV-2501, [INV-2501](https://acme.atlassian.net/browse/INV-2501))`

Omit any section that has no entries.

---

## Phase 3 - Determine version

If `[version]` was supplied, validate it is SemVer (`MAJOR.MINOR.PATCH`) and use it.

Otherwise infer from the latest released version in `CHANGELOG.md` (the first `## [X.Y.Z]` heading; default base `0.0.0` if none):

- Any feature (FEAT) or port (PORT) in this release -> **MINOR** bump (`X.(Y+1).0`).
- Only bug / refactor / perf -> **PATCH** bump (`X.Y.(Z+1)`).
- **MAJOR is never auto-inferred** - breaking changes are not derivable from spec type. Pass an explicit `[version]` to cut a major.

Release date = today, `YYYY-MM-DD`.

---

## Phase 4 - Gate (preview + confirm) [HARD]

Display, for explicit approval:

1. The exact `## [<version>] - <date>` section that will be written, fully rendered (all sections + bullets).
2. The target file and the action: create a new `CHANGELOG.md`, or insert into the existing one.
3. The list of specs that will transition `done -> archived` (their IDs).
4. The version and the reasoning ("inferred: minor (1 feature)" or "explicit: <version>").

**STOP. Wait for explicit user approval.** Silence is not approval.

- If `--dry-run` was passed: stop here unconditionally. Report that nothing was written.
<!-- contract-lint: allow CL306 - version override is a described option, not a listed override token; CL305 already covers listed-choice overrides -->
- The user may override the version at this gate.
- On rejection: write nothing; specs stay in `done`.

---

## Phase 5 - Write (only after approval)

Order matters - CHANGELOG first, then archives, so an interruption leaves specs re-releasable.

### 5a. CHANGELOG.md

**If absent**, create it with the standard header, then the new section:

```
# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [<version>] - <date>
...sections...
```

**If present**, insert the new `## [<version>] - <date>` section:

- A `## [Unreleased]` section exists ->
  - Fold any hand-written entries under it into the matching sections of the new release (dedup against the generated bullets).
  - Reset `## [Unreleased]` to a header-only section above the new release.
  - Insert the new release section directly below the emptied `[Unreleased]`.
- No `[Unreleased]` section -> insert the new release section directly above the most recent `## [X.Y.Z]` heading.
- The file uses compare-link footers (lines like `[1.2.0]: <url>/compare/...`) AND `project.repo` is set -> add a `[<version>]:` link best-effort, matching the existing pattern. If the pattern is unclear, skip the footer rather than guess.

Preserve all existing content and formatting. Never rewrite prior release sections.

### 5b. Archive each released spec

For each spec from Phase 1, perform the validated `done -> archived` transition (identical to `/sd:spec status <ID> archived`):

1. Set `status: archived` in `.specs/<ID>/00-spec.md` frontmatter.
2. Update the spec's row in `.specs/index.md`.
3. Append to `.specs/<ID>/05-retro.md` (append-only - never edit prior lines):

```
- [<UTC ISO timestamp>] Status: done -> archived. Reason: released in v<version>.
```

If `05-retro.md` does not exist, create it with a header and the entry.

---

## Phase 6 - Report

Print:

- CHANGELOG path and whether it was created or updated.
- The version and date.
- Per-section entry counts (Added: N, Changed: M, Fixed: K).
- The archived spec IDs.
- Suggested next step (manual): `git tag v<version>` and push tags. **This command never runs git** - tagging and committing are the user's call.

---

## Rules (hard constraints)

- Change `.specs/index.md` and any spec `status:` field with the Edit tool only - never a shell
  command (`sed -i`, `>`, `tee`, `Set-Content`). spec-gate checks an Edit-tool change (Rules 0,
  0b, 1) and records its `spec_transition`; a shell write skips both (SW-79).
- This command NEVER invokes a subagent. Pure file ops, like `/sd:spec`.
- It writes ONLY: `CHANGELOG.md` (repo root), `.specs/index.md`, and per-released-spec `00-spec.md` frontmatter + `05-retro.md`. It never touches code, the constitution, or `.claude/`.
- Only `done` specs of type feature / bug / refactor / perf / port are released and archived. RCA specs are left untouched.
- Archiving reuses the validated `done -> archived` state-machine transition; every transition is logged append-only to `05-retro.md`.
- Exactly ONE hard gate (Phase 4) precedes any write. `--dry-run` stops before writing.
- MAJOR version bumps are never auto-inferred; pass `[version]` explicitly.
- No hardcoded stack or VCS commands. The command never runs `git`; tagging is a suggested manual follow-up.
- CHANGELOG edits are additive: existing sections are preserved verbatim; only the new release section (plus a best-effort footer link and `[Unreleased]` reset) is introduced.
