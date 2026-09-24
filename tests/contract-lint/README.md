# contract-lint fixtures

Fixture suite for `scripts/contract-lint.ps1` and `scripts/contract-lint.sh`.

```powershell
.\tests\contract-lint\run-selftest.ps1            # the suite
.\tests\contract-lint\run-selftest.ps1 -SelfTest  # plus: does the harness notice a dead linter?
.\tests\contract-lint\run-selftest.ps1 -Case cl30 # one family, for debugging
```

One pwsh runner drives **both** implementations in a single process, so parity is asserted rather
than inferred from two green runs in separate CI jobs. There is deliberately no `.sh` twin of the
runner: validate's Check 2 (`bash -n`) is depth-1 over `hooks/bash`, `install` and `scripts`, and
shipping a harness outside those directories would leave it unchecked.

## How a case works

`fixtures/_base/` is a complete, valid mini-engine with its own `specwright.manifest.json`. It is
the only tree that exists in full. Each case directory holds an `overlay/` copied over a fresh copy
of `_base`, plus an `expected.json`. That keeps every case to roughly one file instead of a near
duplicate tree that drifts out of sync with the others.

`expected.json` pins an **anchor**, never a line number:

```json
{ "rule": "CL300", "severity": "BLOCK", "file": "commands/alpha.md",
  "anchor": "seed", "seed": "gate-without-stop" }
```

| Anchor | Means |
|---|---|
| `seed` | the finding must land within three lines after the `<!-- SEEDED: <name> - <why> -->` marker |
| `file` | the finding is a whole-file verdict, so its line must be 1 |

A literal line number in a golden rots the moment a line above it shifts, and the case then passes
while checking nothing. The seed marker travels with the violation instead. A window rather than
"the next non-comment line" because the `CL9xx` cases report **on** a comment: the suppression is
the violation.

The message text is never pinned, but it **is** compared between the two implementations, so
wording can improve in one commit while a divergence still fails.

## Cases that must FIRE

| Case | Rule |
|---|---|
| `cl001-unresolved-agent-reference` | CL001 |
| `cl002-skills-entry-without-skill-md` | CL002 |
| `cl003-unresolved-skill-reference` | CL003 |
| `cl004-skill-referenced-by-nobody` | CL004 |
| `cl005-missing-templates-path` | CL005 |
| `cl006-unknown-command-reference` | CL006 |
| `cl007-agent-invoked-by-no-command` | CL007 |
| `cl008-unknown-spec-artifact` | CL008 |
| `cl009-phase0-restates-bootstrap-guard` | CL009, wrapped and single-line |
| `cl100-invocation-sets-undeclared-mode` | CL100 |
| `cl101-mode-invoked-by-nobody` | CL101 |
| `cl102-invocation-omits-required-input` | CL102 |
| `cl103-invocation-passes-undeclared-input` | CL103 |
| `cl104-duplicate-agent-name` | CL104 |
| `cl200-agent-instructed-to-write` | CL200 |
| `cl201-readonly-agent-declares-write-tool` | CL201 |
| `cl202-unknown-mcp-tool-name` | CL202 |
| `cl203-declared-tool-never-mentioned` | CL203 |
| `cl204-write-capable-agent-block` | CL204 |
| `cl205-readonly-block-passive-artifact-write` | CL205 |
| `cl300-gate-without-stop` | CL300 |
| `cl301-gate-without-options` | CL301 |
| `cl302-gate-count-disagrees` | CL302 |
| `cl303-gate-numbering-gap` | CL303 |
| `cl304-conditional-gate-mismatch` | CL304, both directions |
| `cl305-hard-gate-offers-override` | CL305 |
| `cl306-hard-gate-prose-escape-unsuppressed` | CL306 |
| `cl400-hardcoded-npm-test` | CL400 |
| `cl401-hardcoded-typescript` | CL401 |
| `cl402-hardcoded-absolute-path` | CL402 |
| `cl900-suppression-without-reason` | CL900 |
| `cl901-suppression-unknown-rule` | CL901 |
| `cl902-suppression-suppresses-nothing` | CL902 |

## Cases that must STAY SILENT

These are not decoration. They are the only thing stopping a future tightening of `CL301` or
`CL305` from quietly breaking the real engine, where all four shapes occur.

| Case | Shape it protects | Lives in the engine at |
|---|---|---|
| `clean` | the unmodified base tree | - |
| `fp-gate-activity-heading` | `## Gate activity` is a report section | `commands/status.md` |
| `fp-bold-pseudo-gate` | bold `Gate Complexity (HARD)` text is not a heading | `commands/feature.md` |
| `fp-substep-before-parent` | a conditional sub-gate authored before its parent | `commands/bug.md` |
| `fp-hard-gate-prose-escape` | a HARD gate whose PROSE mentions an override, annotated for both CL305 and CL306 | `commands/bug.md`, `commands/release.md` |
| `fp-negated-write-verb` | a negated ("Do not write") or third-person ("The caller will Create") use of a CL200 verb | `agents/code-explorer.md` |
| `fp-cl205-main-thread-named` | an artifact write in a read-only agent's block whose step names the main thread, wrapped across lines or in the step's opening parenthetical | `commands/port.md` Phase 3 |
| `fp-cl400-placeholder-and-fenced-example` | a stack command token inside a `<<placeholder>>` and inside a fenced example | `commands/perf.md`, `commands/verify.md` |
| `fp-cl401-placeholder-and-fenced-example` | a language name inside a `<<placeholder>>` and inside a fenced example | `commands/setup.md`, `agents/spec-architect.md` |
| `fp-cl402-slash-command-reference` | `/sd:<name>` references and `~/.claude/...` install-target paths, not filesystem paths | throughout `commands/`, `agents/` |
| `fp-cl009-phrase-outside-phase0` | bootstrap guard text inside the skill that owns it, in a fenced example, and outside Phase 0; a Phase 0 that reads the skill at runtime | `skills/sd-bootstrap-guard/SKILL.md`, the Phase 0 of every workflow command |

## The case that must still BITE

| Case | Why it exists |
|---|---|
| `fp-phase0-stop` | The engine's Phase 0 bootstrap paths are full of literal `STOP`s. This case has them **and** a gate with none, and asserts `CL300` still fires. It guards the opposite direction from the silent cases: a widened `CL300` window would let a real gate pass because some unrelated line elsewhere said `STOP`. |

## Adding a rule

Adding one to `specwright.manifest.json` means adding all four of these, and skipping any one of
them fails this harness or CI:

1. a `contractLint.rules` entry (the registry, which carries the severity);
2. a rule function in **both** `scripts/contract-lint.ps1` and `scripts/contract-lint.sh` -- each
   linter's registry parity guard exits 2 if the dispatched set and the registry disagree;
3. a case here with an `expected.json` that names the rule, plus a row in the table above;
4. a row in `docs/contract-lint.md`.

## House rules for fixture prose

Fixture `.md` files are walked by validate's Check 7, which flags any line that looks like a
published inventory claim but has no `docClaims` entry behind it. Write fixture prose with none of
that vocabulary: no `N hard gates`, no `N commands`, no `N agents`, no `N skills`. Say what the
case does instead of counting anything. The fallback -- adding `tests/` to `historicalExclusions` --
would silently drop this whole directory out of the scan, and is worth avoiding.

`run-selftest.ps1` is scanned by Check 1 and must stay pure ASCII. The fixture `.md` files are not,
and deliberately carry the real non-ASCII gate marker so the marker-stripping path is exercised.
