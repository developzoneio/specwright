# ADR 0007: the newest dated CHANGELOG heading is the only version source

- Status: accepted (shipped in 1.6.0)
- Date: 2026-09-24 (recorded retroactively by SW-56; decisions made 2026-08, SW-28/SW-29)
- Source spec: Jira SW-28 (`versionClaims`), SW-29 (install-time version stamp, `/sd:setup` drift)
- Relates to: ADR 0006 (Check 8); `specwright.manifest.json` `$versionClaimsComment`
- Supersedes: none

## Context

Two failures had the same root cause: nothing in the repo knew which version the engine was.

- **Stale published versions.** `ROADMAP.md` said `Current released version: **1.3.0**` from
  before the 1.4.0 release until SW-28, through every green Check 7 run. Check 7's vocabulary
  (`docClaims` / `claimPhrases`) is built around integer counts derived from disk; a version string
  has no disk-derived quantity, so it had nothing to trip.
- **An installed engine could not say what it was.** `/sd:setup`'s drift check compared a
  project's `.claude/project-config.json` against a template, not against the engine actually
  installed, and fresh scaffolds stamped the template's literal `1.0.0`.

## Decision

1. **One source.** The version is the newest `## [x.y.z] - <date>` heading in `CHANGELOG.md`,
   computed once per run. There is no second version literal anywhere - not in the installer, not
   in the manifest.

2. **`versionClaims`, a separate shape from `docClaims`.** Entries are `{file, pattern}` with no
   `equals`, because the expected value is always the CHANGELOG version. The list is explicit only:
   there is no undeclared-claim scan for version strings, because a semver-shaped pattern would
   collide with legitimate non-claim versions (spec URLs, illustrative versions in command docs).

3. **The version check is independent of Check 6.** Check 6's `next_header` / `$nextHeader`
   variables resolve to whatever line sits directly below `[Unreleased]`, which is the first bullet
   rather than a heading in the normal, not-just-released state. Reusing them would have passed on
   bash and silently done nothing on PowerShell.

4. **The installer stamps what it parsed.** `install.ps1` / `install.sh` write
   `specwright-version.txt` into every installed `<area>/sd/` root, parsed from the same heading.
   LF, no BOM, US-ASCII, byte-identical whichever installer writes it, so a repeat install can
   report it `identical` and skip it. It lives inside `sd/`, so uninstall removes it with no new
   code.

5. **`version` is engine-tracked in project config.** `/sd:setup` compares the installed stamp with
   the project's `version` field and runs a full template diff instead of a hardcoded field list.
   `version` is the one field Apply may overwrite outside the project-specific preserve-list.

6. **Dead pointers are removed, not rewritten.** The template's `$schema` URL pointed at a schema
   that was never published, under the wrong org name. It was removed, and the drift check flags a
   leftover `$schema` key for removal.

## Consequences

**Positive.** A stale version claim now fails CI, naming both the wrong value and the true one. A
user can tell which engine is installed, and `/sd:setup` reports real engine/config drift.

**Negative.** Cutting a release is a multi-file edit by construction: the dated heading, every
`versionClaims` file, and the compare links all move together, or Check 7 fails. A branch that
misses a release cut (as `develop/v1` did with 1.6.0 until SW-56) keeps reporting the older
version until the cut is ported.
