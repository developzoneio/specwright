# Engineering notes

Knowledge recovered from the third-party planning output in `docs/superpowers/` and the untracked
`.superpowers/sdd/` run logs (SW-5 hook conformance, SW-6 verify-gate hardening, the
`sd-docs-writer` and setup-scan designs) before those folders were removed. Everything that was
already recorded in `CHANGELOG.md`, an ADR, a command file or a code comment was left out; what
remains is the rationale, rules and open items that existed nowhere else.

Three kinds of content, kept apart because they age differently:

- [Design rationale](#design-rationale) - why a decision went the way it did. Stable.
- [Hook parity rules](#hook-parity-rules) - how to keep the bash and PowerShell twins honest.
  Apply on every hook change.
- [Open follow-ups](#open-follow-ups) - verified still unfixed on 2026-11-27. Move each one to a
  ticket and delete its row here when it ships.

## Design rationale

### `sd-docs-writer` writes one ADR and nothing else

Generating `docs/architecture.md` from accumulated specs was an explicit non-goal. It is a fuzzier
problem than drafting a single decision record, and it carries a high risk of overwriting
hand-written prose. The agent writes exactly one new ADR file per run and never edits an existing
document.

The agent runs on `sonnet` because ADR drafting is prose synthesis - the same tier as the
architect and reviewer, not the mechanical tier of the explorer and implementer.

### `/sd:setup` scans for facts, never for rules

Phase 2.5 samples the codebase to pre-fill facts (stack, layout, `paths.layers`), but it never
infers constitution rules from the code it reads. Auto-detection would codify accidental or
inconsistent patterns as enforced law; rules stay human-authored.

The scan is Claude-driven sampling, not a deterministic scanner script. That keeps it
stack-agnostic and avoids adding another `.ps1`/`.sh` pair that would have to stay in parity.

### `SL055` is WARN, not BLOCK

`SL055` flags a `done` spec with no passing `06-verify.md`. Specs closed before SW-6 introduced
`/sd:verify` have no such artifact, so a BLOCK would make validation fail retroactively on
history that was correct when it was written.

### A project config replaces the hook defaults wholesale

`spec-gate` ships built-in defaults (`paths.protected` = constitution, index, `LICENSE`; gate mode;
metrics path). They apply only when `.claude/project-config.json` is absent or unparseable. A
config that is present replaces them entirely - there is no key-by-key merge. A config that omits
`paths.protected` therefore protects nothing. `/sd:setup` writes the full list from the template,
so this only bites hand-written or trimmed configs.

## Hook parity rules

The conformance harness (`tests/hooks/run-conformance.ps1`) drives both implementations of each
hook against the same fixture and asserts that both match a hand-written golden. These rules come
from the real divergences SW-5 and SW-6 found; each one shipped as a bug at least once.

### Never adjust a golden to hide a divergence

When a fixture exposes a bash/pwsh difference, the fix is a paired hook change in its own commit.
Editing `expected.json` or the runner's normalizer until the suite goes green hides exactly the
drift the harness exists to catch.

### The harness proves agreement, not correctness

A golden is written by a person, and when both implementations share a wrong assumption the golden
usually encodes it too. Undotted `paths.protected` entries, `\\?\` paths and the hardcoded `FEAT-`
prefix (see [Open follow-ups](#open-follow-ups)) all pass the suite this way. For a security rule,
write the golden from the intended behaviour, not from what the hooks currently do, and add at
least one adversarial case per rule.

### Keep fixtures exercising the defaults

Prompt-router fixtures deliberately set no `workflow.keywords`, so they test the default keyword
lists hardcoded in both implementations - which is where silent drift hides. Do not "tidy" them by
adding explicit keywords.

Fixtures never embed wall-clock timestamps. Time-dependent cases (staleness, debounce) use
`setup.json` mtime backdating so they stay deterministic.

### Porting checklist

Check each item whenever logic moves between `hooks/bash/<name>.sh` and
`hooks/powershell/<name>.ps1`:

| Pitfall | bash side | PowerShell side |
|---|---|---|
| Explicit `false` | `jq '.x // true'` treats `false` as absent; compare `== false` | `"false" -eq $false` is true (right side coerces); require `-is [bool]` |
| First vs all matches | `grep -o` prints every match; use `awk 'match(...)'` for first | `-match` / `$Matches[0]` is first match only |
| Case | `[[ == ]]`, `grep`, `sort` are case-sensitive | `-eq`, `-match`, `Sort-Object` are case-insensitive by default |
| Culture | `LC_ALL=C` for `sort` and `grep -P` | `StartsWith(string)` is culture-sensitive; pass `[StringComparison]::Ordinal` |
| Whitespace class | `[[:space:]]` is ASCII in `C` locale | `\s` matches Unicode whitespace |
| Line endings | `jq.exe` on Windows emits CRLF; `tr -d '\r'` in line loops | `Get-Content` strips it |
| Missing config | fall back to the full default document, not `{}` | the `catch` only fires with `-ErrorAction Stop` |

### Normalize paths as strings, on both sides

Never resolve hook paths with `GetFullPath`, `realpath` or `cd`. `GetFullPath` resolves against the
hook process's working directory rather than the payload's `cwd`, and a `Write` target may not exist
yet. Collapse `.` and `..` segments as plain strings, and apply the same normalization to config
entries (`paths.protected`) as to the incoming path - otherwise the comparison is between two
differently-shaped strings.

### Running the ASCII check under Git Bash

`grep -P` in Git Bash fails with "supports only unibyte and UTF-8 locales" unless a UTF-8 locale is
set. Run the `CLAUDE.md` ASCII check as:

```bash
LC_ALL=C.UTF-8 grep -nP "[^\x00-\x7F]" hooks/powershell/*.ps1 install/*.ps1
```

## Open follow-ups

Each row was re-checked against the current hook code on 2026-11-27. Locations name the function
or rule rather than a line number so they survive edits.

### Worth a ticket first

| Item | Where | Effect |
|---|---|---|
| Rule 0 and Rule 0b match a literal `FEAT-` instead of the configured `spec.prefixes.feature` | `spec-gate.{ps1,sh}`, Rule 0 done-ID extraction and Rule 0b; the configured `$featurePrefix` is read but not used there | With a custom feature prefix, an `in-progress -> done` move is a legal Rule 0b edge, so the verify gate is silently off. Both impls agree, so the harness cannot see it |
| The harness compares canonical JSON with `-eq` | `run-conformance.ps1`, the `$match` line | A case-only drift in a reason string passes. Use `-ceq` |

### `spec-gate` path handling

| Item | Effect |
|---|---|
| `paths.protected` entries are not dot-collapsed (only `\` -> `/`, plus lowercasing in bash) | A config entry like `./.specs/constitution.md` never matches - a silently dead rule |
| `\\?\` extended-length and drive-relative `C:foo` paths fall back to the raw path in both impls | They escape the protected-path comparison |
| The base-prefix check has no segment boundary (`/ws` matches `/wsx/...`) | Fails closed; not exploitable, but wrong |
| A bare-string `paths.protected` | bash allows (jq iteration errors, yields nothing); pwsh blocks (`@()` wraps it) |
| Rule 0 takes the first `FEAT-` ID anywhere on a `done` line, not from the first table cell | A done line whose title names another FEAT ID with a passing artifact allows the whole edit and skips Rule 0b. Fix: anchor to `^\|\s*FEAT-` |
| `\s` (pwsh) vs `[[:space:]]` (bash) in the Rule 0 line match | Latent divergence on non-ASCII whitespace |
| A backslash `spec.dir` is not normalized in bash (`index_rel` is, `spec_dir` is not) | Latent; only on true POSIX bash with a Windows-style config |
| `StartsWith(string)` without a `StringComparison` in pwsh (`'/'` in `spec-gate.ps1`) | Latent culture sensitivity. The same call form is also used in `subagent-retro.ps1`, `handoff-integrity.ps1` and `stop-gate.ps1` (heading prefixes there) |

### Verify gate scope

| Item | Effect |
|---|---|
| `/sd:verify` is wired into `/sd:feature` and `/sd:port` only; bug, refactor, perf and rca close-outs never run it, and the hook rule stays FEAT-only | The "done needs evidence" guarantee covers two workflows. `/sd:refactor` is closest - it already has `02-tasks.md` |
| `06-verify.md` is self-attested: `.specs/` is allow-listed, so the artifact can be written directly | `docs/usage.md` says the hook "blocks" close-out without saying the evidence is unsigned. Either document the limit or sign the artifact |

### Test coverage

| Item | Effect |
|---|---|
| No prompt-router fixtures for the refactor or rca keyword lists | Drift in those two default lists is uncaught |
| `expected.json` key order must match the normalizer's property order | Brittle: a reordered golden fails although the content is identical |
| The harness reads stdout then stderr sequentially | Deadlock risk on large output; accepted, since hook output is tiny |

### Features never started

| Item | Origin |
|---|---|
| Offer "draft an ADR from this spec?" at the close-out of feature, bug, refactor and perf | `sd-docs-writer` design |
| Generate `docs/architecture.md` from accumulated specs (deliberately out of scope for `sd-docs-writer`; would need its own design) | `sd-docs-writer` design |
| Feed `paths.layers` into `spec-gate` (the impact-analysis use already shipped in `/sd:refactor`) | setup-scan design |
