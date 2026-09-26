# Changelog

All notable changes to **specwright** will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Fixed
- **`hooks/bash/spec-gate.sh`, `hooks/powershell/spec-gate.ps1`, workflow commands** (SW-79) -
  `spec-gate` was wired only for `Edit|Write|MultiEdit`, so a workflow that moved a spec's status
  with `Bash` `sed -i` on `.specs/index.md` sidestepped Rules 0, 0b and 1 and recorded no
  `spec_transition` event (seen in e2e scenario `02-feature-happy`). Two layers now close it:
  - **Prompt.** `commands/feature.md`, `bug`, `refactor`, `perf`, `rca`, `port`, `spec` and
    `release` each carry a hard rule to change the index and any spec `status:` field with the
    Edit tool only, never a shell command. New contract-lint rule `CL206` keeps it there.
  - **Hook.** The matcher is now `Edit|Write|MultiEdit|Bash|PowerShell` (in
    `templates/settings.template.json`, `examples/fixture-project`, and the installers' printed
    wiring). A shell command that visibly writes a protected path or the spec index (`sed -i`,
    `perl -i`, `>`/`>>`, `tee`, `Set-Content`, `Add-Content`, `Out-File`) is denied in every
    mode and recorded as a new `gate:"shell-write"` event. It is a text heuristic, not a
    guarantee (`cd .specs && sed -i ... index.md` still gets through). A command with no write
    marker exits before any disk read. The bash Rule 1 loop is factored into
    `is_protected_rel`, mirroring `Test-IsProtected`.
  - `/sd:setup` gains drift check A.4, which flags a `spec-gate` matcher without `Bash` /
    `PowerShell` in an existing `settings.json` (later checks renumber to 5-9).
    `commands/status.md` and `docs/architecture.md` list the new gate kind.
  - There are 9 new `tests/hooks` spec-gate fixtures (`block-bash-*`,
    `block-powershell-set-content-index`, `subdir-cwd-block-bash-absolute-index`,
    `allow-bash-*`), and `latency-selection.json` samples a cheap and a blocking Bash case.
- **`hooks/bash/*.sh`, `hooks/powershell/*.ps1`** (SW-78) - all three hooks now resolve the
  project root instead of trusting the hook payload's `cwd`, which Claude Code sets to the session's
  *current* directory (a Bash `cd` moves it). The root is `CLAUDE_PROJECT_DIR` when set; otherwise
  the nearest ancestor of `cwd` with `.claude/project-config.json`, then the nearest with `.specs/`;
  otherwise `cwd`. Before this, a session sitting in a subdirectory (e.g. `.specs/FEAT-x`) had every
  `spec-gate` rule fail open with no metric event, and the hooks created a stray nested
  `.specs/_metrics/` / `.claude/.hookstate/` there. A relative `file_path` is still anchored on the
  session `cwd`. `tests/hooks/run-conformance.ps1` gains per-fixture `cwd` / `env` in `setup.json`
  and a `{{ROOT}}` token. It also strips `CLAUDE_PROJECT_DIR` from child processes (as does
  `measure-latency.ps1`) and fails a case that creates state directories under an off-root `cwd`.
  There are 7 new `subdir-cwd-*` fixtures across the three hooks.
- **`hooks/bash/spec-gate.sh`, `hooks/powershell/spec-gate.ps1`** (SW-75) - new Rule 0b lets the
  workflows' own `.specs/index.md` status transitions through `paths.protected`. Previously Rule 1
  denied every `draft -> approved` / `approved -> in-progress` edit, so `/sd:feature` (and bug,
  refactor, perf, rca, port) could not pass Gate 1 under a permission mode that enforces hook
  denies. The hook rebuilds the post-edit index and allows only new rows at `draft`/`approved`
  plus Status-only moves along a workflow edge. A FEAT `-> done` move still needs a passing
  `06-verify.md` (Rule 0), and any other hand-edit stays blocked. There are 10 new `tests/hooks`
  fixtures. `block-index-done-bug-row-protected` is now `allow-index-done-bug-row-transition`, and
  `metrics-transition-event` now records `allow`. On an edit Rule 0b allows, the `spec_transition`
  events come from Rule 0b's own diff. A workflow edit that rewrites only the Status cell is
  therefore recorded; the old `new_string` row scan missed it (found in a live scenario 02 run).

### Added
- **Contract-lint rule `CL206` (BLOCK)** (SW-79) - a command listed in the new
  `contractLint.editToolOnly.files` must state `contractLint.editToolOnly.phrase` ("with the Edit
  tool only - never a shell command") outside a fence, wrapping across two lines allowed. The
  files are declared, not inferred; a listed file that does not exist exits 2. Fixtures
  `cl206-edit-tool-instruction-missing` and `fp-cl206-phrase-wrapped`.
- **`tests/e2e`** (SW-79) - `SD_E2E_TRANSCRIPT=1` makes `run-e2e.ps1` drop
  `--no-session-persistence` and keep the fake home, so a run's session transcript can be read.
  Scenario `02-feature-happy` now asserts all four allowed `spec_transition` events in
  `events.jsonl` and no `shell-write` gate. A new optional per-scenario `timeout.txt` sets the
  kill timeout; an explicit `-TimeoutSeconds` still wins. Scenario 02 carries `1500` because it
  runs about 11 minutes. Verified live on 2026-09-26 (CLI 2.1.283): 11/11 pass.
- **ADR 0013: model override mechanism** (SW-72) - `docs/adr/0013-model-override-mechanism.md`
  records Verdict A on Claude Code 2.1.282, from transcript evidence with a control for every
  pair. The Agent tool's `model` parameter overrides agent frontmatter (mechanism level), and
  `/sd:feature` passes it exactly when `ESC-FEAT-02`, `ESC-FEAT-03` or `ESC-FEAT-04` fires
  (workflow level). Each escalated call was served on its new tier; each control call stayed on
  the default. This replaces SW-61's self-reported retro line as SW-58's evidence. Along the way:
  a run's own summary claimed "ran at haiku" while `message.model` showed sonnet, and the e2e
  sandbox is not isolated on Windows (SW-73).
- **`tests/e2e/probe-model-override.ps1`** (SW-72) - manual, paid probe that re-runs ADR 0013's
  workflow check. It runs an L vs control pair per case (`feat04`, `feat03`) and reads
  `meta.json` / `message.model` from kept transcripts. `-EvaluateOnly` re-checks an earlier run at
  no cost. It refuses an `-OutDir` with a `.claude` folder above it. Not part of `run-e2e.ps1` or
  CI.
- **Task check-off marker for `02-tasks.md`** (SW-71) - `sd-atomic-task-format` gains a
  "Check-off marker" section and is its only owner. The canonical form is a last line in each block,
  `- **Status**: <open | done>`. It is execution state, not one of the 11 contract fields.
  `sd-spec-architect` writes `open` on every task, including re-planned ones. A field was chosen
  over the heading prefix (`### [x] T01`) because rewriting the heading on check-off breaks the task
  ID that `Depends on`, `Revised-by`, lint findings and `/sd:status` counters rely on.
  The reader is tolerant:
  - a `[x]` / `✅` heading prefix with no `Status` reads as checked;
  - an unknown value reads as unchecked;
  - a block with no marker reads as unchecked (legacy);
  - task markers are read only while the spec is `in-progress`, so a finished legacy spec is never
    resumed.

  `/sd:feature`, `/sd:port` and `/sd:refactor` resume rows and check-off steps now point at the
  skill. New `SL067` (WARN) in `/sd:spec validate` flags non-canonical markers. It uses the reserved
  task-block slot; `SL068`-`SL069` stay reserved. New conformance fixtures
  `tests/task-format/fixtures/checkoff-*.md`. e2e scenarios `06` and `07` now assert that both tasks
  end at `Status: done`. New scenario `08-resume-checkoff` seeds T01 as done and T02 as open, then
  asserts the resume runs T02 only.
- **Implementer escalation in `/sd:feature` Phase 4** (SW-61) - `sd-model-escalation` gains
  `ESC-FEAT-04` (task `Estimated complexity` is `L`) and `ESC-FEAT-04b` (task `Reversibility` is
  `hard`, alone, when `ESC-FEAT-04` did not fire), both `sd-implementer` `haiku -> sonnet`. Decided
  once per task in Phase 4 step 2 and held for that task's step 5 re-invocations; one retro line
  per task. An `unapplied` escalation never halts the loop for a model switch. `ceiling: "sonnet"`
  leaves both rows uncapped. This keeps the promise `agents/implementer.md` already made in its
  `description`, which now names the trigger fields. No step, gate or `model:` value changed.
  New e2e scenario `06-escalation-implementer` asserts one applied, uncapped line for the `L` task
  and none for the `S` task; `07-escalation-disabled` asserts `enabled: false` leaves no line for
  an `L` task or a `hard` task. First local run: both green (7/7 and 5/5 assertions). `docs/walkthrough.md`'s T05 cost row now reflects a real rule (and no
  longer counts T05 twice).
- **`skills/sd-model-escalation/SKILL.md`** (SW-60) - single owner of the model escalation
  policy: the `haiku -> sonnet -> opus` ladder (`inherit` is not a rung), the three invariants from
  ADR 0002, a trigger table with stable rule IDs, precedence rules, and a logging contract - every
  fired decision appends `escalation: <agent> <from> -> <to> (trigger: <rule-id>)` to the spec's
  `05-retro.md`, with a `capped` suffix when the ceiling limited it and `unapplied` when the
  invocation tool had no `model` parameter. The override is defined as the Task/Agent tool's
  `model` parameter, never prompt prose. Loaded by `sd-spec-architect` and `sd-implementer` via
  `skills:`; read at runtime by `/sd:feature` (new Phase 0 step 3). Skill inventory 10 -> 11.
- **`models.escalation` in `project-config.template.json`** (SW-60) - `enabled` (default `true`)
  and `ceiling` (default `"opus"`; `"sonnet"` caps cost). Additive: an absent block or key reads
  as the defaults, and `/sd:setup` Phase 1.5's field diff offers the block to older configs. An
  invalid value disables escalation for the run with a WARN rather than guessing.
- **`scripts/prompt-size-report.{sh,ps1}`** (SW-57) - a release-time report replacing `CL500`. For
  every file in `contractLint.scanScope` it prints the normalized size at the previous `v*` tag (or
  at `--since <ref>`), the size now, the delta and the percentage, plus a total per area. A file
  that grew more than the new `promptSizeReport.flagGrowthPercent` (15) is marked `FLAG`. Advisory:
  exit 0 whatever it finds, 2 only when it cannot run. It runs at each minor release (new
  CONTRIBUTING "Prompt size report" step); the cadence and failure signals are in
  `docs/contract-lint.md`. `tests/prompt-size-report/run-parity.ps1` asserts both twins match each
  other and a hand-computed table, and runs in CI on every OS.
- **validate Check 10: bash strict mode** (SW-52) - `scripts/validate.{ps1,sh}` fail when any
  `*.sh` in the repo does not open with `set -euo pipefail`. Exceptions are declared with a reason
  in the new `specwright.manifest.json` `bashStrictMode.exceptions` block (the 3 bash hooks, which
  must exit 0 on every failure path). A stale exception path also fails. This turns the
  CONTRIBUTING bash convention into a gate. The sweep across `scripts/` and `tests/` found
  `smoke-hooks.sh` to be the only violation.
- **`tests/installer/`** (SW-53) - `prefix-cases.json` shared case table (valid, empty, spaces,
  tab, newline, CR, `..`, `/`, `\`) plus `run-prefix-parity.ps1`, which asserts identical
  accept/reject outcomes across all four installer scripts in dry-run mode, and a `-SelfTest` that
  proves the pre-fix spaces-only guard is caught. Both run in CI on every OS.
- **`skills/sd-bootstrap-guard/SKILL.md`** (SW-54) - single owner of the Phase 0 bootstrap guard:
  the CLAUDE.md WARN, the constitution / project-config / index STOPs and the project-config parse
  STOP. Read at runtime by the workflow commands; if it is unreadable they STOP with an
  install-incomplete message.
- **Contract-lint rule `CL009` (BLOCK)** (SW-54) - a command whose `## Phase 0` section restates a
  phrase from the new `contractLint.bootstrapGuardPhrases` vocabulary fails, including a phrase
  wrapped across two lines. Before the dedupe it fired on all seven copies and on no other
  command. Fixtures `cl009-phase0-restates-bootstrap-guard` and `fp-cl009-phrase-outside-phase0`.
- **Hook latency budgets and measurements** (SW-50, commit 6/6) - `hookLatencyBudgets` now holds
  real p95 budgets (ms, pwsh / powershell): `spec-gate` 1300 / 1100, `prompt-router` 1300 / 1000,
  `subagent-retro` 1300 / 1100, each about 2x the worst CI p95 measured. Timeouts are unchanged.
  `docs/architecture.md` gains "Hook invocation latency" (method, measured p95 on
  windows/macos/ubuntu CI and a Linux container, how to reproduce). On windows-latest, Windows
  PowerShell 5.1 was about 20% faster than pwsh, the reverse of an earlier workstation
  measurement. The `_pwsh_recommended` note in `templates/settings.template.json` therefore now
  says to measure with `measure-latency.ps1` before switching, not that pwsh is faster. Decision
  and alternatives: [ADR 0012](docs/adr/0012-hook-latency-budget.md).
- **`measure-latency.ps1` verifies every timed run** (SW-50, commit 5/6) - each run's exit code,
  stderr and stdout are checked against the case's `expected.json` golden (block vs allow for
  `spec-gate`, routed workflows for `prompt-router`, surfaced lessons for `subagent-retro`), and a
  mismatch fails the script outright. Hooks exit 0 on every failure path, so a hook that died early
  under one PowerShell flavor would otherwise have been timed and reported as a speedup.
- **Hook latency floor in CI** (SW-50, commit 4/6) - `specwright.manifest.json` gains
  `hookLatencyBudgets` (per-hook, per-flavor p95 in ms), and a new `Hook latency budget` CI step
  runs `tests/hooks/measure-latency.ps1 -CheckBudget` on all three OSes (windows-latest measures
  Windows PowerShell 5.1 as well as pwsh). `-CheckBudget` is now strict: a missing budget block,
  an unbudgeted (hook, flavor), a requested flavor that isn't installed, or a hook with zero
  samples all fail instead of warning. Before measuring, it also refuses any p95 budget above half
  the hook's `timeout` in `templates/settings.template.json`, so raising a budget past that
  ceiling means raising the timeout in the same commit.
- **Contract-lint rule `CL205` (BLOCK)** (SW-51) - `CL200`'s command-side twin. Inside the block of
  an invocation whose target agent has no write tool on disk (anchor to next heading/anchor, NOT
  cut at numbered steps), a line naming a spec artifact (`NN-name.md` / `04-artifacts/`) and a
  write form fails unless its enclosing numbered step names the `main thread`, joined across line
  wraps. Would have caught the `rca.md` Phase 2 defect fixed above; the engine tree is clean under
  both implementations. New fixtures `cl205-readonly-block-passive-artifact-write` and
  `fp-cl205-main-thread-named` (the `port.md` Phase 3 wrapped-actor shape). Blind spots - passive
  writes in a write-capable agent's block, section-only writes - are recorded in
  `docs/contract-lint.md` as deliberate.
- **`tests/hooks/measure-latency.ps1`** (SW-50, commit 1/6) - p50/p95 per-invocation latency
  measurement for the three shipped hooks, spawning each as a fresh child process under every
  available PowerShell flavor (`pwsh` and, on Windows, `powershell` 5.1) against a curated fixture
  subset (`tests/hooks/fixtures/latency-selection.json`). `-CheckBudget` compares the result
  against `hookLatencyBudgets` (see the CI floor entry above). No bash twin, same rationale as `run-conformance.ps1`: it must drive
  multiple PowerShell flavors from one process to produce comparable numbers.
- **Check 9: root-level ad-hoc notes guard** (SW-47) - `scripts/validate.{sh,ps1}` now fails when
  a root-level file matches a declared ad-hoc-notes pattern (`specwright.manifest.json`'s new
  `adHocNotesGuard.patterns`: `REVIEW-TODO.md`, `TODO.md`, `FIXME.md`, `NOTES.md`,
  `*-FINDINGS.md`, matched case-insensitively - NTFS/APFS are case-insensitive filesystems, so a
  case-sensitive guard would let a differently-cased file through on most contributors' machines);
  `ROADMAP.md` is deliberately excluded as a maintained project document, not an ad-hoc findings
  snapshot. `scripts/selftest-root-guard.{sh,ps1}` proves the check bites, same posture as
  `selftest-docs.{sh,ps1}`. `CONTRIBUTING.md` now states explicitly that review findings become
  Jira issues, not files in the tree.
- **`CL204` (BLOCK): an unused declared tool on a write-capable agent** (SW-48) - `CL203` narrows to
  agents with no write tool of their own (stays WARN); `CL204` is its new BLOCK sibling for agents
  whose own `tools:` line carries `Write`/`Edit`/`MultiEdit`, checked off disk the same way `CL200`
  decides write-capability - never `contractLint.readOnlyAgents`, a declared promise about a fixed
  three agents, not a live predicate. A new rule id, not a conditional severity inside `CL203`:
  severity is looked up from the manifest per rule id and never computed by a rule, the invariant
  that keeps the bash/PowerShell twins from diverging on BLOCK vs WARN.
  - **All 12 standing warnings from v1.6.0 resolved, each decided individually, not blanket-suppressed.**
    `sd-spec-architect`'s unused `Edit`/`Write` (the two `CL203` findings on the one agent that holds
    write power - the original motivation for this ticket) now have explicit body mentions, since
    the agent genuinely writes and edits spec files. `sd-docs-writer`'s `Glob`/`Grep` and
    `sd-debugger`'s and `sd-implementer`'s `Glob` were genuinely unused and dropped (minimal tool
    allowlists, CLAUDE.md rule 5). `sd-code-explorer`'s five `TASK = callers/definition/trace/
    pattern/structure` headings are sub-routines reached only through `TASK = standalone`'s internal
    `DETECTED_INTENT` routing, never invoked directly by a command - each now carries a
    `contract-lint: allow CL101` suppression naming that reason. `sd-reviewer`'s `per-task` task
    type was dead: `/sd:feature` and `/sd:refactor` deliberately review the whole changeset via
    `holistic` instead of once per task (a documented cost decision), so nothing ever set
    `TASK_TYPE = per-task`. Its checklist wasn't dead, though - `holistic` builds on it - so it moved
    into a non-invocable "Baseline checklist" section rather than being deleted outright.
  - **AC-2's `(file, rule, token)`-keyed exception list was not built.** After the above, no `CL203`/
    `CL204` finding needed one: the only same-line collision case (`spec-architect.md`'s Edit and
    Write sharing one `tools:` line) is exactly the one AC-3 already forced a real fix for. The five
    `CL101` items that did need an exception are each on their own line, so the existing
    `<!-- contract-lint: allow -->` suppression convention already gives per-item granularity - and
    `docs/contract-lint.md` had already recorded once (for `CL306`) that a second declared-exception
    surface duplicating that convention was rejected. Building an unused mechanism was skipped.
  - **`contractLint.warnBudget` (0): a standing-warning ratchet in `scripts/validate.{sh,ps1}` Check
    8.** Counts every WARN finding except `CL500` and `CL202`, which stay WARN permanently by design
    (a byte-budget ratchet and a hand-maintained tool allowlist, respectively) and would otherwise
    fail the build through rules explicitly meant not to. Exceeding the budget fails validate;
    lowering the actual count requires lowering the budget in the same commit - the point is that a
    13th warning next release is exactly as visible as the first one was.
  - Fixture coverage: `tests/contract-lint/fixtures/cl204-write-capable-agent-block/` (new, must
    FIRE), the existing `cl203-declared-tool-never-mentioned` case re-verified as still WARN (its
    agent stays non-write-capable), and `CL204` added to every fixture manifest's `rules[]` registry
    (root, `_base`, and the nine case-local overlay manifests) to keep `run-selftest.ps1`'s registry
    parity guard - and its own internal one inside each linter - green.
- **`SL061`-`SL066`: the port task-block band for `/sd:spec validate`** (SW-49) - closes the known
  gap carried forward from SW-41: `/sd:port`'s anti-drift contract (every port task's `Pattern refs`
  cites a snapshot member range, `Acceptance` carries a licensed-deviation ID list) was enforced
  only by `commands/port.md` Phase 6 refusing to execute a defective block at *execution* time,
  invisible to `validate`. Six new rules, scoped to `type: port` specs only, checked per
  `Pattern refs` citation and per task, same granularity `SL082`/`SL083` already use for table rows:
  `SL061` malformed citation shape, `SL062` citation outside `04-artifacts/source/`, `SL063` citation
  names a path absent from `MANIFEST.md`, `SL064` citation range outside the manifest's recorded
  member range for that path (checked as a cascade - each rule requires the previous one to have
  resolved, so a citation reports exactly one of the four, never a stack of them), `SL065` no
  `Licensed deviations:` line in `Acceptance`, `SL066` a cited deviation ID absent from the spec's
  deviation table. Reserved band per `commands/spec.md`'s own note (`SL061`-`SL069`); `SL067`-`SL069`
  remain reserved.
  - **New convention: `Licensed deviations: D01, D02` (or `none`) inside `Acceptance`.** No prior
    syntax existed for embedding a deviation-ID list in a port task's free-text `Acceptance` field -
    documented as a new "Port mode" addendum in `sd-atomic-task-format`, alongside the existing
    "Refactor mode" / "Re-plan" addenda. Authoring it is `sd-spec-architect`'s job (`/sd:port`,
    unchanged here); this ticket only adds the reading/checking side.
  - **`examples/spec-lint-fixture/` gains a third matched clean/broken pair**: `PORT-CLEAN-004` (all
    six checks PASS) and `PORT-BROKEN-016` (one seeded defect per rule, isolated to its own task so
    each finding is independently traceable) - same donor scenario, differing only in `02-tasks.md`.
    Rule coverage in that fixture's README moves from 25/37 to 31/43.
  - **`contractLint.budgets.commandsBytes` raised 32677 -> 37194** - `commands/spec.md` picked up
    the new rule table rows and the "Port task-block checks" subsection; the ratchet moves with it,
    same mechanical consequence every prior SL-band addition (SW-38, SW-40) triggered. This is the
    only `specwright.manifest.json` edit in this ticket - no `SL0xx` rule itself was registered
    there (see below).
  - **Not otherwise touched, and why**: no `SL0xx` rule has ever been registered in
    `specwright.manifest.json` (that subtree is `contractLint`'s CL-rule registry, consumed only by
    `scripts/contract-lint.*`; an SL entry there would be inert, matching the precedent set by
    `SL070`-`SL090`, none of which registered there either). `docs/troubleshooting.md` - the SW-41 "known gap" note lives only
    in that entry's own CHANGELOG text, which is historical and untouched (`specwright.manifest.json`
    excludes `CHANGELOG.md` from doc-drift checks by design); there was no corresponding note in
    `troubleshooting.md` to remove. `commands/port.md` Phase 6 - stays as defense-in-depth for a spec
    approved before this rule existed.

### Changed
- **`/sd:feature` escalation prose extracted into `sd-model-escalation`** (SW-60) - Phase 2
  step 0, Phase 3 step 0, the Gate 2 `no-split` branch and the Key Rules line now name rules
  `ESC-FEAT-02`, `ESC-FEAT-03` and `ESC-FEAT-03b` plus their trigger inputs; the tiers, rationale
  and aliases-only rule moved into the skill unchanged. `sd-spec-architect`, `sd-spec-templates`,
  the feature spec template and `docs/usage.md` point to the skill instead of paraphrasing it. No
  agent `model:` frontmatter changed. Deviations from the ticket: the trigger table ships only the
  three live `/sd:feature` rows - SW-61 and SW-62 add their rows when they wire them, so no row
  exists without a command that applies it; and `PROJECT-SNAPSHOT.md` does not exist in this repo,
  so the inventory bump went to the files Check 7 guards.
- **1.6.0 changelog condensed; design rationale moved to ADRs** (SW-56). The `[1.6.0]` section
  goes from 476 to about 100 lines of what-changed entries, linking an ADR where one exists. New
  `docs/adr/0005`-`0009` hold the port pipeline, contract lint, version source, e2e + fixture and
  spawned-specs rationale. New [ADR 0010](docs/adr/0010-engine-does-not-dogfood.md) records why the
  engine does not run its own pipelines on itself and what validates them instead. `CONTRIBUTING.md`
  gains a "Changelog vs ADR" section with a worked example. The 1.6.0 release cut (`main` #27) is
  ported to this branch, so `ROADMAP.md` and `README.md` now report 1.6.0.
- **Test-harness prerequisites documented; e2e runs on a subscription** (SW-55) -
  - **Docs.** `CONTRIBUTING.md` gains a "Test suites and prerequisites" section. It has a per-suite
    table: what each suite needs, what it covers, how to run it, where CI runs it. It records why
    the parity harnesses under `tests/` are pwsh-only (one process drives both implementations, so
    parity is asserted rather than inferred) and gives a minimum local check before a PR.
    `README.md` gains a short "Local verification" section that points to it.
  - **e2e auth.** `tests/e2e/run-e2e.ps1` no longer implies it needs `ANTHROPIC_API_KEY`. It
    accepts `CLAUDE_CODE_OAUTH_TOKEN` (`claude setup-token`), an existing `claude` login in
    `~/.claude/.credentials.json`, or an API key, and prints which one it used. It warns when an
    API key would override a subscription credential, and removes empty auth variables from the
    child's environment.
  - **Fail-fast preflight.** Before building any sandbox, the e2e runner checks that the `claude`
    CLI is at least 2.1.196, that some auth is present, and that each selected scenario's commands
    are on `PATH`. A scenario lists those commands in a new optional `requires.txt`; `01-setup` and
    `02-feature-happy` declare `node` and `npm`. A missing prerequisite exits `2` and names it.
  - **Exit codes.** The hook conformance, contract-lint self-test and installer parity harnesses
    now also exit `2` (was `1`) for a missing bash or `jq`, following the documented convention.
  - **Nightly workflow.** `e2e-nightly.yml` also passes an optional `CLAUDE_CODE_OAUTH_TOKEN`
    secret.
  - **e2e README.** `tests/e2e/README.md` states the per-run cost trade-off: over ~$2.50 on an API
    key, plan usage on a subscription.
- **Phase 0 bootstrap guard deduplicated across the seven workflow commands** (SW-54) -
  `/sd:feature`, `/sd:bug`, `/sd:rca`, `/sd:refactor`, `/sd:perf`, `/sd:port` and `/sd:adr` now
  apply `sd-bootstrap-guard` as Phase 0 step 1 and keep only their own steps after it. Drift
  corrected: `port.md` lacked the "constitution is the binding Layer-2 contract" rationale;
  `feature.md` alone listed the project-config keys (moved into the skill); `/sd:adr` ran a
  lighter guard (no CLAUDE.md WARN, no STOP per missing file, no parse check, "abort" instead of
  STOP) and now applies the full guard, with its lack of state detection stated as step 2.
  `refactor`/`bug`/`perf`/`rca` print the same messages as before. Two deviations from the ticket:
  the skill is read at runtime rather than wired via `skills:` frontmatter (commands cannot load
  skills that way; `commands/spec.md` states the same), so `contractLint.skillConsumers` is
  unchanged - the body reference already satisfies `CL004`; and `contractLint.budgets.commandsBytes`
  stays 37194, because the ceiling is the single largest file (`commands/spec.md`, untouched), not
  the area's sum - every edited command shrank, but none of them sets the ceiling.
- **`templates/settings.template.json`** (SW-50, commit 3/6) - adds a prominent `_pwsh_recommended`
  block showing the exact, empirically-verified opt-in to run hooks under PowerShell 7+ (pwsh)
  instead of the default Windows PowerShell 5.1. Live-tested against a real Claude Code session:
  Claude Code's hook `"shell": "powershell"` field genuinely launches pwsh (Core), not Windows
  PowerShell 5.1 (Desktop), and `${HOME}` still expands correctly when `command` is rewritten to
  `& "${HOME}/.claude/hooks/sd/<hook>.ps1"` alongside it - simply renaming the executable inside
  `command` without switching to this form would launch pwsh which then launches ANOTHER nested
  copy of literal `powershell.exe`, doubling process-startup cost instead of avoiding it. The
  shipped default is unchanged (still Windows PowerShell 5.1, no new dependency), matching
  README's documented "PowerShell 5.1+" baseline. Also fixes `_note_powershell_on_unix`, which
  previously and incorrectly implied the PowerShell command lines "work as-is" on Unix pwsh
  installs (Unix invokes it as `pwsh`, not `powershell`, with no shim by default).
- **`install/install.ps1`** (SW-50, commit 3/6) - the printed post-install "Hook wiring" guidance
  now points to `_pwsh_recommended` in `templates/settings.template.json`, with a note to measure
  first: pwsh is not faster on every machine (see the SW-50 6/6 entry).
- **`hooks/powershell/spec-gate.ps1`** (SW-50, commit 2/6) - the `file_path`-empty and
  path-does-not-resolve early exits now run before `Get-ProjectConfig` (a disk read), not after,
  so the common case - a tool call with no gate-relevant path - no longer pays for a config-file
  read it doesn't need. `spec-gate.sh` needed no matching change: it already checked `file_path`
  before reading config. Measured effect on this machine: within noise (spec-gate p50 530ms ->
  532ms on pwsh, 1194ms -> 1217ms on Windows PowerShell 5.1) - the win is real but small against
  process-startup cost; see ADR 0012.

### Fixed
- **`tests/e2e/run-e2e.ps1` sandbox was not isolated on Windows** (SW-73). Fake homes and
  workspaces were created under `GetTempPath()`, which on Windows sits inside the user profile.
  With no git root to stop it, Claude Code loads every ancestor `.claude/` as project scope, which
  outranks the fake home's user scope. The developer's real `~/.claude` agents and skills therefore
  shadowed the engine under test, and a stale real `sd-implementer` was served the wrong model.
  Overriding `HOME`/`USERPROFILE` and passing `--setting-sources project` did not prevent this. The
  sandbox root now defaults to `<SystemDrive>\sd-e2e` on Windows and stays at `GetTempPath()` on
  Unix. `SD_E2E_ROOT` overrides both. A preflight guard exits `2` and names the path when the root
  or any of its ancestors contains a `.claude` directory. Linux and macOS behaviour is unchanged.
  Verified on Windows: scenario 06 passed under `C:\sd-e2e`, and a `feat04` probe re-run served
  every `sd-implementer` call with no `model` parameter on haiku. ADR 0013 finding 2 now records
  the fix.
- **`/sd:feature` resume from `approved` no longer skips Phase 2** (SW-74) - the state machine
  sent `approved` with no `02-tasks.md` straight to Phase 3. A spec interrupted after Gate 1 was
  planned with no impact map, and `ESC-FEAT-02` never fired (ADR 0013 finding 4). The row is now
  split on the explorer's output heading, `## Impact analysis (sd-code-explorer)` in
  `03-decisions.md`, the same idiom as `/sd:port`'s `## Behavior pinning`. Without that heading
  the workflow resumes at Phase 2; with it, `impact-mapped`, it resumes at Phase 3, and no second
  impact map is appended. There is also a new `plan-drafted` row. Phase 3 writes `02-tasks.md`
  but the status stays `approved` until Gate 2 decides, and that state matched no row before; it
  now resumes by presenting Gate 2.
- **e2e scenarios `09-resume-approved` and `10-resume-impact-mapped`** (SW-74) - a run/control
  pair for the fix above. 09 seeds an `approved` `complexity: L` spec with no impact map and
  asserts the resume runs Phase 2: one explorer impact section, the `ESC-FEAT-02` retro line, and
  a stop at Gate 2 with no code change. 10 seeds the impact map and asserts Phase 3 only, with no
  second map and no `ESC-FEAT-02` line. Both passed on a live run (6/6 each, `claude` 2.1.282,
  Windows). Offline, against simulated outcomes, the pre-SW-74 behavior fails 09 on exactly the
  impact-map and escalation checks.
- **CI: the two bash negative-case installer steps could never pass** - GitHub runs `shell: bash`
  as `bash -e`, and the steps' own `set -uo pipefail` left `-e` on, so the first expected
  non-zero exit captured by `out="$(...)"; rc=$?` aborted the step before `rc` was read.
  ubuntu-latest and macos-latest had been red on this since SW-46 (the partial-install step
  was hidden behind it as `skipped`). Both steps now `set +e` first; their explicit `exit 1`
  assertions still fail the step.
- **`agents/debugger.md` promised a "project-provided database MCP tool" it can never call**
  (SW-64). The agent's `tools:` allowlist is fixed in the engine, and no Layer-2 setting can add a
  project's database MCP tool to it, so that path never worked. The Verify, Hotspot A and "Database
  discipline" sections now name a read-only CLI client via `Bash` as the only supported database
  path, and say that the main thread can collect DB evidence with the project's MCP tool when no
  CLI client exists. The `mcp.database._use` note in `templates/project-config.template.json`, the
  README MCP table and the `docs/architecture.md` project-scope table now list that tool as main
  thread only. A per-project allowlist extension point was rejected: the agent is installed once
  in user scope, so patching it for one project would change it for every project.
- **`scripts/smoke-hooks.sh`** (SW-52) - now runs under `set -euo pipefail`. `run_hook` captures
  the hook's exit code explicitly, so an expected non-zero exit is reported rather than aborting
  the suite. A jq preflight runs before any fixture or assertion. With no `jq`, the suite exits `2`
  and names `jq` as a missing runner dependency. Before, every hook exited 0 silently, 7 assertions
  failed, and the hooks took the blame. The `[SKIP]` branch for cases (e)/(f) is gone, so both
  cases always run. `smoke-hooks.ps1` needs no twin change: the PowerShell hooks parse JSON
  natively and do not depend on `jq`. Closes REVIEW-TODO items 7 and 8.
- **`scripts/validate.sh`** (SW-52) - Check 8 now reports a missing `jq` with the same message as
  Checks 7 and 9, through one shared `jq_missing` helper. Before, it printed only
  "contract-lint could not run (exit 2)", because the linter's stderr reason was discarded.
- **`install/install.sh`, `install/uninstall.sh`** (SW-53) - the `--prefix` emptiness check now
  strips `[[:space:]]` instead of spaces only (`${PREFIX// /}`), matching `IsNullOrWhiteSpace` in
  the `.ps1` installers. A tab, newline or CR prefix was accepted on Unix (creating e.g.
  `commands/<TAB>/`) while Windows rejected it. `uninstall.sh`'s guard now carries the same
  "mirrors install.sh" comment as its twin.
- **`commands/rca.md` left three artifact writes with no named writer** (SW-51). Phase 2 step 3
  said "Hypothesis tree written to `00-spec.md`" - passive, inside a block invoking `sd-debugger`,
  which has no write tool - so the tree could go unpersisted and Gate 2 would stop on an empty
  section. It now reads "Main thread appends the returned hypothesis tree ... (debugger has no
  write tool)", matching `bug.md` and `perf.md`. The same sweep of every command file found two
  more actor-less steps in `rca.md` (Phase 1 evidence saving, Phase 3 REJECTED documentation);
  both now name the main thread. No other command had the defect.
- **Hooks hardcoded the spec-prefix alternation, making `PORT-` specs invisible to enforcement**
  (SW-44). `spec-gate`, `prompt-router`, and `subagent-retro` - both bash and PowerShell - matched
  in-progress specs against a literal `(FEAT|BUG|REF|PERF|RCA)` alternation instead of reading
  `spec.prefixes` from `.claude/project-config.json`, even though the template has shipped a
  `port: "PORT"` entry since `/sd:port` landed in SW-41. A `PORT-` spec was therefore invisible to
  `spec-gate`'s in-progress check, `prompt-router`'s context injection, and `subagent-retro`'s
  lesson scoping - the four HARD gates `/sd:port` documents had no hook backing. Both
  implementations now derive the alternation from `spec.prefixes` at runtime (each config-declared
  value validated against `^[A-Z][A-Z0-9]{1,9}$`; invalid entries are dropped individually rather
  than invalidating the whole set), falling back to a built-in six-prefix default
  (`FEAT|BUG|REF|PERF|RCA|PORT`) when the config is absent, unreadable, or has nothing valid
  declared - hooks still never fail noisily. Five new fixtures cover a `PORT-` spec detected by
  `spec-gate`, `port`-scoped lesson selection in `subagent-retro`, a custom seventh prefix, and
  both branches of the malformed-prefix fallback. Removes the now-stale `docs/troubleshooting.md`
  entry describing this gap.
- **`install.sh`/`install.ps1` did not validate `BASE_PATH`** (SW-45) - an empty or
  whitespace-only `--base-path`/`-BasePath` silently resolved path building against filesystem
  root (bash) or the caller's CWD (PowerShell, confirmed empirically), writable on a permissive
  environment (container, CI as root, WSL). A new guard in all four install/uninstall scripts
  rejects empty/whitespace `BASE_PATH` with a clear error and exit 2 (bash uses `[[:space:]]`,
  not the PREFIX guard's spaces-only idiom, so the check agrees with PowerShell's
  `IsNullOrWhiteSpace` on tabs/CR/LF). Separately, `--base-path`/`--prefix` given with no
  following value used to abort inside `shift 2` under `set -euo pipefail` with zero diagnostic
  output; both bash scripts now check argument count before consuming it and print usage + exit
  2. PowerShell's native parameter binder already rejects a missing `-BasePath` value before the
  script body runs (exit 1, its own message, zero files written) - documented as an accepted
  deviation from bash's exit 2 rather than replacing the idiomatic `param()` block. CI gains
  negative-case coverage on both platforms for both install/uninstall pairs: empty,
  whitespace-only, and missing-value, asserting exit code and zero files written. Relative
  `BASE_PATH` normalization and the `--base-path --force`-value-looks-like-a-flag case are
  deliberately out of scope, deferred to a follow-up ticket.
- **`install.sh`'s partial-install guard never fired** (SW-46) - `on_error()` was registered via
  `trap on_error ERR`, but the script ran under `set -euo pipefail` (no `-E`/errtrace), and bash
  does not propagate an ERR trap into shell functions without `-E`. Every copy happens inside
  `copy_one()`, so a failure there produced a bare non-zero exit with no partial-install warning
  and no cleanup instructions - exactly the half-populated `~/.claude/` the guard existed to
  prevent. `install.sh` now runs under `set -Eeuo pipefail`; the existing `$STAMP_TMP` `EXIT`
  trap (`install.sh:339`) is untouched and continues to fire independently. `install.ps1` had no
  equivalent guard at all - it gains one now: the copy phase (main loop plus the version-stamp
  write) is wrapped in `try`/`catch`, and an unexpected mid-copy failure prints the same
  three-line remedy as bash's `on_error()` (installed-file count, base path + prefix, and the
  exact `uninstall.ps1` command to run), gated on `-not $DryRun -and $installed -gt 0` to match.
  CI gains a negative case on both platforms: a plain file pre-created at `<base>/agents/sd`
  blocks that plan area's directory creation (`commands/`, plan position 1, has already installed
  successfully by then), asserting the guard message fires with the exact remedy on the sabotaged
  run. `uninstall.sh`/`uninstall.ps1` have no partial-state guard either - out of scope here.

### Removed
- **`REVIEW-TODO.md`** (SW-47) - its ten items are each fixed or tracked: items 1/2 by SW-45/SW-46,
  item 3 verified fixed in place (`hooks/bash/subagent-retro.sh:533` already parses the UTC
  timestamp with `date -u -j -f`), item 4 by SW-51, items 7/8 by SW-52, item 9 by SW-54, item 10 by
  SW-53, item 6 already closed by SW-3's manifest, and item 5's residual `agents/debugger.md` gap
  tracked under new child issue SW-64. Nothing is carried forward as a markdown file; Check 9 above
  guards against recurrence.
- **Contract-lint rule `CL500` and `contractLint.budgets`** (SW-57) - the per-area byte ratchet
  fired 8 times at authoring time and 0 times on 37 pushed commits. All 8 fires were settled by
  raising the budget to the file's exact new size, and none led to a trim. Because only an area's
  largest file set the ceiling, it never saw `commands/explore.md` grow 179%. Removed from both
  linters, the manifest registry, every fixture manifest and validate's Check 8 `warnBudget`
  exemption (now `CL202` only); fixtures `cl500-file-over-budget` and
  `fp-cl500-file-at-budget-ceiling` deleted. Superseded by the prompt size report above. See
  [ADR 0011](docs/adr/0011-retire-cl500-byte-ratchet.md).

## [1.6.0] - 2026-08-10

### Added
- **`/sd:port` - the fidelity-first port pipeline** (SW-41). One command runs a port end to end:
  bridge/extract -> freeze -> host survey -> fidelity tables -> pin behavior -> plan -> execute
  batched -> justified-diff parity -> close-out. Ten phases, six gates, four of them HARD with no
  override path. `--scope` (always explicit) selects the behavior-pinning mechanism; `--from`
  selects a bridged cross-repo contract or an in-repo path/symbol. Reads an optional `Port policy`
  heading from the host's `.specs/constitution.md`. Adds `WORKFLOW_TYPE = port` to
  `sd-implementer` and port phrases (`backport`, `port from`, `donor repo`, ...) to the
  prompt-router keyword map in both hook implementations and `project-config.template.json`.
  See [ADR 0005](docs/adr/0005-port-pipeline.md).
- **Port parity adjudication** (SW-40): a `port-parity` TASK_TYPE on `sd-reviewer`, the
  `04-artifacts/parity/` diff artifact, and the HARD justified-diff parity gate. Every hunk is
  classified as `justified` / `unjustified` / `missing` / `extra` / `overreached`, plus member
  completeness and path conformance checks. `port.template.md`'s fixed AC-1 now covers
  `overreached`. See [ADR 0005](docs/adr/0005-port-pipeline.md).
- **`examples/port-parity-fixture/`** (SW-40) - matched `clean/` and `broken/` port trees with a
  README table of expected findings, one seeded defect per BLOCK class.
- **`port-extract` TASK mode on `sd-code-explorer`, via `/sd:explore --port`** (SW-39). Donor-side
  extraction into eight fixed, `file:line`-cited sections; `--snapshot contract+source` copies the
  donor files and a `MANIFEST.md` into `.specs/_explorations/<slug>-<timestamp>/source/`.
- **`PORT` spec type** (SW-38): `PORT-<slug>-<YYYYMMDD>` in `spec.prefixes`,
  `templates/specs/port.template.md` (six mandatory sections, five provenance frontmatter fields),
  the `04-artifacts/source/` snapshot layout, and the `SL080`-`SL083` port-integrity band in
  `/sd:spec validate`. PORT specs are release-eligible, map to `Added`, and bump MINOR.
- **`sd-port-fidelity` skill** (SW-37) - port policy shared by `sd-spec-architect` and
  `sd-reviewer`: structural-mirror default, the four-group deviation allowlist with citations,
  anti-simplification rules, gate-table completeness conditions, and the hunk vocabulary.
- **`## Spawned specs` in the feature, bug, refactor and perf spec templates** (SW-42), using the
  RCA template's reserved-ID table. Close-out prompts for it when the retro names deferred work;
  gate counts are unchanged. New `SL090`, the first SUGGEST-severity `/sd:spec validate` rule, flags
  a `done` spec that names deferred work with an empty table. See
  [ADR 0009](docs/adr/0009-spawned-specs-and-suggest-band.md).
- **Threshold calibration machinery** (SW-31). `spec-gate` records a completed Gate Complexity
  split as a `gate:"complexity"` / `decision:"split"` metrics event, and `/sd:status --calibration`
  (new flag) reports task/layer/file distributions. `project-config.template.json` marks
  `retroStaleMinutes`, `debounceMinutes` and `maxLessons` as unmeasured, and CONTRIBUTING gains a
  re-calibration ritual. See [ADR 0004](docs/adr/0004-threshold-calibration.md).
- **Install-time version stamp** (SW-29). Installers write `specwright-version.txt` into every
  installed `<area>/sd/` root, taken from the newest dated CHANGELOG heading; uninstall removes it.
  Check 5 asserts it. See [ADR 0007](docs/adr/0007-version-stamp-and-version-claims.md).
- **`/sd:setup` reports engine/config drift** (SW-29). It compares the installed stamp with the
  project's `version` field and diffs against the full template. Fresh scaffolds stamp the real
  engine version, and the dead `$schema` URL is removed from `project-config.template.json`.
- **`tests/e2e/`: headless behavioral eval harness** (SW-27). `run-e2e.ps1` runs real `claude -p`
  sessions across five scenarios against a sandboxed fixture copy and asserts on produced
  artifacts. Runs nightly and on dispatch via `.github/workflows/e2e-nightly.yml`, not per PR.
  See [ADR 0008](docs/adr/0008-behavioral-e2e-and-fixture-project.md).
- **`examples/fixture-project/`** (SW-30) - a small runnable Node.js project with Layer 2
  pre-scaffolded and one complete committed `/sd:feature` run (`FEAT-todo-priority`). Closes
  SW-8's runnable-fixture criterion. See
  [ADR 0008](docs/adr/0008-behavioral-e2e-and-fixture-project.md).
- **Check 8: cross-file contract lint** (`scripts/contract-lint.{ps1,sh}`; SW-26, SW-32, SW-33,
  SW-34, SW-35). Lints the relationships between commands, agents and skills: `CL0xx` reference
  resolution, `CL1xx` invocation contract, `CL2xx` role and tool integrity, `CL3xx` gate integrity,
  `CL4xx` stack-agnostic prose, `CL5xx` file budgets, `CL9xx` suppression hygiene. Wired into both
  validators and into CI on all three operating systems. New `contractLint` manifest subtree (rule
  registry, declared gate counts, `readOnlyAgents`, `knownMcpTools`, vocabulary lists, per-area
  byte `budgets`), `tests/contract-lint/` fixture suite, and `docs/contract-lint.md`. Declared gate
  counts are now Check 7 claims. See [ADR 0006](docs/adr/0006-cross-file-contract-lint.md).
- **Machine-readable agent input declarations** (SW-25) - `Inputs (required): ...` /
  `Inputs (optional): ...` under every agent mode heading, checked by `CL1xx`. No behavior change.
- **`## Quickstart` in `README.md`** (SW-8) - install -> `/sd:setup` -> `/sd:feature <slug>`, with
  the bundled fixture as a fallback, plus a star / "using this at work" call-to-action.
- **`versionClaims` in `specwright.manifest.json`** (SW-28). Check 7 now fails when a published
  version string (`ROADMAP.md`'s "Current released version") disagrees with the newest dated
  CHANGELOG heading. `selftest-docs.{sh,ps1}` gain a scenario for it. See
  [ADR 0007](docs/adr/0007-version-stamp-and-version-claims.md).

### Changed
- **`README.md` restructured and cut from 390 to 282 lines.** It opens with real output transcribed
  from the fixture run (`## What it looks like`) and adds `## How this differs from prompt-level
  discipline`. Install lives in `## Quickstart`, and the advanced path moves to
  `## Install options and uninstall` (still split per platform, so a dry run stays readable).
  Duplicated agent, skill and architecture detail is replaced with links to
  `docs/architecture.md`. Adds a release badge and links to both example fixtures. The unsourced
  per-run cost estimate is replaced with a pointer to `/sd:status`. Two new `docClaims` cover the
  README's prose subagent and skill counts.
- **`CL200`, `CL306` and `CL400` promoted from WARN to BLOCK** (SW-26) after running clean for a
  release. Five existing `<!-- contract-lint: allow -->` suppressions are now load-bearing
  (`commands/bug.md`, `commands/release.md`, `commands/setup.md` x2, `commands/verify.md`).
- **`contractLint.budgets` raised with the port work.** `commandsBytes` 25978 -> 29664,
  `agentsBytes` 14454 -> 15232, `skillsBytes` 9134 -> 12412.

### Fixed
- **`ROADMAP.md` reported `1.3.0` as the current release** since before 1.4.0 (SW-28); it now reads
  the real version, and its `## Planned` section points at `[Unreleased]`.
- **`README.md`:** the BMAD acknowledgement linked to `https://github.com/` and now points at
  `bmad-code-org/BMAD-METHOD`. A stale "Latest as of Jan 2026" CLI compatibility row and an empty
  "Planned" roadmap bucket are updated. Two stray em dashes are replaced.
- **`docs/architecture.md`** listed four `/sd:feature` gates against a declared count of three,
  including a per-task review gate that no longer exists.
- **`commands/setup.md`**: the detected-facts gate had no literal `STOP`, and neither setup gate
  offered a machine-readable option set.
- **Drifted agent invocation contracts.** `/sd:bug`'s hypothesis-verify loop did not pass
  `EVIDENCE_DIR`. `/sd:rca` and `/sd:feature` passed tokens (`MODE`, `PLAN_REF`) the target mode
  never declared. `/sd:refactor`'s characterization-test loop did not pass `INVARIANTS`.
  `sd-code-explorer`'s `standalone` mode did not declare `GITNEXUS_AVAILABLE`. The unused
  `INCIDENT_DETAILS` input was removed from `sd-spec-architect`.
- **Contract-lint fixture base agent** declared a tool its body never mentioned, which would have
  tripped `CL203` on the fixture suite itself.

## [1.5.0] - 2026-07-23

### Fixed
- Three CI-only failures surfaced by PR #23, none reachable from a real install. (1)
  `scripts/validate.sh` Check 7 used `declare -A` and `mapfile` (both bash 4+), which crash on
  macOS's stock `/bin/bash` 3.2 (`declare: -A: invalid option`, then `mapfile: command not found`
  once the first was fixed) - rewritten as plain indexed arrays with linear-scan
  `q_get`/`q_set`/`fp_get`/`fp_append` lookup helpers and a `while read` loop in place of
  `mapfile`, no behavior change. (2) The
  "Lesson validator (PowerShell)" CI step asserts the leaky fixture correctly FAILS validation,
  but GitHub Actions appends an implicit `exit $LASTEXITCODE` to every pwsh step, so the
  intentional non-zero exit code from the leaky-fixture check failed the step even though the
  assertion itself passed - fixed with an explicit `exit 0` after the assertion. (3)
  `tests/hooks/run-conformance.ps1`'s `-SelfTest` stub bash script exits immediately without
  reading stdin, and writing the JSON payload to its now-closed pipe raised an unhandled
  `IOException: Broken pipe` on Linux runners - `Invoke-HookProcess` now wraps the
  `StandardInput.Write`/`Close` pair in a try/catch, since a child that never reads its input is
  not a harness failure.

### Added
- `/sd:status` - a read-only reader for the metrics log (SW-16). SW-10 has been accumulating
  `.specs/_metrics/events.jsonl` with no consumer; the data existed and was invisible. The new
  13th slash command summarises the **live** log plus `.specs/index.md`: specs in progress, gate
  activity broken out by kind (`verify` / `protected` / `code-edit`) and decision
  (`allow` / `warn` / `block`), lifecycle transitions, and a **friction** section ranking where the
  operator is actually stuck - which specs are blocked most, which code-edit warns are being
  ignored, which specs accumulate stale retros, and which in-progress specs are absent from the log
  entirely. Read-only: no spec is created, no gate is evaluated, nothing is written.
  Three decisions are worth recording because they diverge from a naive reading of the ticket.
  (1) **`jq` is an oracle, not a runtime dependency.** The acceptance criterion "counts reconcile
  against `jq`" reads like a dependency; it is not. The schema is flat, metadata-only and written in
  fixed key order, so exact substring counting is deterministic - and `jq` *aborts* on a
  partially-written line, which would lose the whole report to one interrupted append, exactly what
  the ticket forbids. `jq` verifies the numbers; it does not produce them.
  (2) **Counting is delegated to the shell, never to eyeballing.** A capped log is ~8000 lines;
  the command prescribes the exact count commands rather than asking for a summary, because a
  number that was estimated cannot reconcile with an independent count.
  (3) **The live file only** - `events.jsonl.1` is noted in one header line and never read, per the
  read contract set in SW-15.
  Every degrade path is a *labelled* state (`ST001`-`ST005`): no config, metrics disabled, log
  absent, log empty. A blank report would read as "no friction", so an empty table is treated as a
  defect rather than an edge case. Malformed lines are skipped **and counted**, and the skipped
  count is always shown - a silent skip and a clean file are not the same fact.
  Verification corpus at `tests/metrics/` (populated / malformed / empty fixtures, expected numbers,
  and the `jq` oracle procedure), pinned to LF in `.gitattributes`. It is documented as a **manual**
  corpus: `commands/status.md` is a prompt file and CI cannot execute it, so it is deliberately not
  wired into `scripts/validate.*`.

- Size cap and single-generation rotation for the metrics log (SW-15). A new `hooks.metrics.maxSizeKb`
  (default `1024` KB, ~1 MB) bounds `.specs/_metrics/events.jsonl`: before each append, if the live
  file already meets or exceeds `maxSizeKb * 1024` bytes, the hook rolls it to `events.jsonl.1`
  (single generation - any previous `.1` is overwritten) and starts fresh. Implemented in all four
  metrics writers (`spec-gate` and `subagent-retro`, PowerShell and bash) so the two platforms roll
  at the same raw-byte boundary (`(Get-Item).Length` / `wc -c`). Inherits every SW-10 invariant:
  rotation is best-effort and **never stops the append** (a silent stop would read as "metrics
  working" while dropping data - worse than unbounded growth, per the ticket), a failed roll (locked
  file on Windows, read-only dir) is a silent no-op, and it never alters a gate decision or the
  hook's exit code. An **absent** `maxSizeKb` is treated as `1024`, so a `project-config.json`
  written before this feature stays bounded with no edit; an explicit `0`/negative disables rotation,
  and any non-number is invalid and also disables it (SW-22 type-strictness). `events.jsonl.1` is a
  grace buffer, **not** part of any read contract - there is no consumer of the log today, and when
  one exists it reads only the live file. Added to `templates/project-config.template.json` and both
  hooks' embedded default configs; documented in `docs/architecture.md` and `docs/troubleshooting.md`.
  New conformance fixtures at `tests/hooks/fixtures/{spec-gate,subagent-retro}/metrics-rotates-at-cap`
  and `.../metrics-rotation-failure-noop` prove PS and bash rotate identically.
- Sanctioned mid-execution re-plan loop (SW-14). A new `sd-replan-loop` skill defines a **HARD Gate
  Re-plan** for the two workflows that produce a `01-plan.md` + `02-tasks.md` pair - `/sd:feature`
  and `/sd:refactor` - so a plan-invalidating discovery adapts the plan without violating
  immutability or skipping a gate. The gate is reachable from **both** the Execute phase and the
  batch/holistic **review** (the one real corpus failure surfaced at review, not mid-task). On
  approval it appends an `R<n>` entry to an append-only `## Revisions` log at the end of `01-plan.md`
  (original plan prose left intact), regenerates **only** the affected task blocks in `02-tasks.md`
  via `sd-spec-architect` (`TASK = plan` with `REPLAN_SCOPE`, no new architect mode), and marks each
  regenerated task `Revised-by: R<n>` (a conditional field in `sd-atomic-task-format`, like refactor's
  `Parallel batch`). Like Gate Complexity, it is a **conditional** gate that fires only on its trigger,
  so `/sd:feature` still advertises 3 hard gates and `/sd:refactor` still 6. It never re-plans a
  `done` spec. Scope was corrected from the ticket on evidence: `/sd:bug` and `/sd:rca` produce no
  task list to re-plan, and `/sd:perf` already carries its own revert-and-reselect loop, so all three
  are left untouched. See `docs/adr/0003-adaptive-replan-loop.md`.
- `SL070`-`SL073` in `/sd:spec validate`: a new **revision-log integrity** band cross-checking the
  `## Revisions` log in `01-plan.md` against the `Revised-by` markers in `02-tasks.md`. `SL070`
  (dangling marker), `SL071` (one-sided/unreferenced revision), and `SL072` (broken append-only
  history) are 🔴 BLOCK; `SL073` (malformed entry) is 🟠 WARN. The checks run only when a `## Revisions`
  section or a `Revised-by` marker exists, so a never-re-planned spec produces no finding. `SL074`-
  `SL079` reserved. Honest boundary recorded in the ADR: `validate` is a static linter with no
  Plan-phase snapshot, so it enforces the revision record's internal consistency but cannot detect an
  unmarked silent edit by diffing - that is prevented by the gate, not the lint.
- Conformance fixtures at `tests/revision-log/fixtures/` (SW-14): a valid revision record that passes
  and a dangling-marker record that must BLOCK, pinned to LF via `.gitattributes`. They state the
  contract; like the other fixture trees they have no runner (documented, not silently skipped).
- Complexity triage + forced decomposition in `/sd:feature` (SW-13). The architect writes a
  spec-level `complexity` frontmatter field (`S` | `M` | `L`, distinct from a task's
  `Estimated complexity`) with a one-line rationale at create time. Gate 2 then measures the actual
  plan against decompose thresholds - **> 8 tasks, > 2 production layers (Tests/Config excluded),
  > 8 impacted files, or an unresolved Open question** (the `> 8` line set from the corpus canyon
  between 3-4-task and 10-12-task specs; the Tests/Config exclusion keeps ordinary 2-layer mediums
  under threshold).
  Over threshold, Gate 2 becomes a HARD **Gate Complexity** that refuses one oversized plan and
  forces a split into medium child specs (`FEAT-<parent-arg>-<child-slug>`, linked via existing
  `/sd:spec link spawns` / `depends-on`; the parent becomes an immutable `archived` umbrella). Under
  threshold it stays the normal plan approval with **zero added friction** - still 3 hard gates, not
  4. A create-time `complexity: L` also escalates models a tier (explorer -> `sonnet`, architect ->
  `opus`, aliases only, per-invocation), deepening the impact map and plan for genuinely large work.
  Task counts use the tolerant `sd-atomic-task-format` heading grammar, not a naive `### T<NN>`
  regex. See `docs/adr/0002-complexity-triage-decomposition.md`. Linting of the field + split
  integrity is deferred to SW-4 (`/sd:spec validate`).
- Field label grammar in `sd-atomic-task-format` (SW-11). Task-block labels are now matched
  case-insensitively, with `**` optional and the colon permitted inside or outside the emphasis -
  all three forms found in live specs (`- **Files**:`, `- Files:`, `- **Files:**`) parse
  identically. A field's value runs to the next field label, not the next newline, so multi-line
  `Acceptance` and `Pattern refs` values are no longer truncated. The grammar is defined once and
  applies to every field and every reader; per-field matchers are forbidden.
- `SL060` (WARN) in `/sd:spec validate`: a task block in `02-tasks.md` with no `Pattern refs`
  field. `SL061`-`SL069` reserved for further task-block content rules. This is the first rule
  that reads *inside* a spec artifact rather than around it - see
  `docs/adr/0001-validate-parses-task-content.md`.
- `docs/adr/` for specwright's own engine-level decision records, numbered the same way `/sd:adr`
  numbers them (`^[0-9]{4}-<slug>.md`). Deliberately **not** `.specs/_adr/`: `.specs/` is Layer 2
  (target-project context), and this repo has none.
- Conformance fixtures at `tests/task-format/fixtures/` covering the three label forms plus a
  negative case, pinned to LF via `.gitattributes`. They state the contract; they have no runner
  (documented, not silently skipped).

- Lesson surfacing, part 3 and the close of the learning loop (SW-19, under epic SW-7):
  `subagent-retro.{ps1,sh}` now emit a `<retro-lessons>` block when a subagent finishes work on an
  in-progress spec, gated by `hooks.subagentRetro.injectLessons` (default `true`) and
  `maxLessons` (default `3`). **Placement is load-bearing:** the emit sits beside the existing
  metrics call site, *before* the staleness early-exit and *before* the debounce window - moved
  down to the reminder block it would have surfaced lessons only to users already behind on their
  retros, the population that needs them least. The one gate it keeps is the in-progress-spec
  check, and that gate *is* the relevance filter: the workflow type of the in-progress spec selects
  the scope (`FEAT-` pulls `feature`, `REF-` pulls `refactor`, and `all`-scoped lessons always
  apply), so there is no ranking, no scoring, and no tie-break that could diverge between
  implementations. This replaces the `prompt-router` placement and the
  `hooks.promptRouter.injectLessons` key named in the SW-7 epic; the epic records why.
  Repetition is bounded per **session** rather than by a clock - a new `shownLessons` key in the
  hook state file records what has already been surfaced, so `maxLessons` caps how many *new*
  lessons appear at one stop and a session converges to silence once it has said everything
  relevant. A time debounce was rejected because it would suppress a lesson the user has never
  seen purely because a different one was shown recently. Four cross-implementation conformance
  fixtures cover surfacing, scope filtering, already-shown state and the disabled flag, and the
  conformance decision object now captures emitted lessons in emission order (sorting them would
  hide exactly the selection-order divergence the fixtures exist to catch).
- Lesson aggregator, part 2 of the closed learning loop (SW-18, under epic SW-7):
  `scripts/aggregate-lessons.{ps1,sh}` collect tagged lesson lines from every
  `<spec-dir>/*/05-retro.md`, dedupe them, and render `<spec-dir>/_lessons/lessons.md`.
  `--check` / `-Check` writes nothing and exits non-zero on drift, which is how idempotence is
  asserted in CI. Two decisions differ from the SW-18 description and are recorded here: (1) the
  **retros** are append-only and `lessons.md` is a derived file regenerated on every run - the
  ticket called `lessons.md` itself append-only, but dedupe-with-a-count requires rewriting the
  line, so append-only and idempotent are mutually exclusive; (2) abstraction stays in the
  `sd-retro-lessons` skill, so the aggregator makes no judgement calls and its output is
  reproducible. Deduplication is on (tag, scope, case- and whitespace-normalised rule);
  a repeat adds a count and **never** raises severity, and the surviving wording is resolved
  independently of severity (byte-smallest) so a sloppier phrasing cannot win just by carrying a
  lower one. All ordering is byte-wise - `LC_ALL=C` in bash, `[string]::CompareOrdinal` plus an
  ordinal dictionary comparer in PowerShell, whose culture-aware defaults would otherwise
  diverge - and PowerShell writes UTF-8 without BOM and LF endings rather than going through
  `Set-Content`. A committed corpus fixture and expected output pin both implementations to the
  same bytes in CI; the corpus deliberately includes retros containing only `/sd:spec status`
  transition lines (which must contribute zero lessons) and an out-of-enum tag (which must be
  skipped). No hook is modified; surfacing (SW-19) follows.
- Structured retro lessons, part 1 of the closed learning loop (SW-17, under epic SW-7): new
  `sd-retro-lessons` skill defining a 10-tag enum, the one-line lesson record
  (`- [tag] severity/scope: Rule sentence.`), and the abstraction discipline that turns a
  retro note into a rule portable to another codebase. The tag enum is **derived from a mined
  corpus of real retros**, not authored up front - two of the three tags originally proposed
  in SW-7 were confirmed by that data and one (`pattern-violation`) was retired as overlapping
  `sibling-repo-assumption` and `precedent-conflict`. New standalone validators
  `scripts/validate-lessons.ps1` / `.sh` enforce grammar, the closed tag/severity/scope sets, a
  120-character ceiling, and the privacy contract (no paths, extensions, backticks, line
  citations, or Pascal/camel/snake_case identifiers), so `.specs/_lessons/lessons.md` is
  shareable outside the org as-is. They are **separate from `scripts/validate.*` on purpose**:
  that validator checks this repo's own invariants, and specwright has no `.specs/` tree - these
  take a file argument and default to `.specs/_lessons/lessons.md` in the current directory, so
  a consumer repo can run them directly. Paired fixtures under `tests/lessons/fixtures/` assert
  both directions in CI (clean must pass, leaky must fail) - a validator that rots into a no-op
  would otherwise report green forever. No hook is modified by this change; aggregation (SW-18)
  and surfacing (SW-19) follow.
- Local, privacy-safe spec metrics (SW-10): `spec-gate` and `subagent-retro` now append one JSON
  line per gate decision, `index.md` lifecycle transition, and subagent-stop check to
  `.specs/_metrics/events.jsonl` - metadata only (timestamp, spec ID, lifecycle phase, decision,
  file extension), never a file path or code content. Controlled by `hooks.metrics.enabled` in
  `.claude/project-config.json`, which **defaults to `true`** - an existing install starts writing
  `.specs/_metrics/events.jsonl` on the next hook run after upgrading, with no action required. Set
  `hooks.metrics.enabled` to `false` to opt out entirely. No log rotation in v1 (documented as a
  known limitation; ~120 bytes/line). Foundation for the closed retro-learning loop (SW-7).
- `/sd:verify <spec-ID>` traceability gate: SC-/AC-IDs in the feature template, a `Covers`
  task field, a `06-verify.md` pass artifact, and spec-gate hook enforcement (Rule 0 in
  `spec-gate.{ps1,sh}`, flag `hooks.specGate.verifyGate`) that blocks a feature (FEAT-)
  `index.md` row transitioning to `done` without a passing artifact. The gate is deliberately
  scoped to feature specs - bug/refactor/perf/rca workflows produce no `02-tasks.md`, so
  non-FEAT rows fall through to the unconditional protected-path block exactly as before,
  pending a follow-up spec that integrates verify into those workflows. `/sd:spec status`
  pre-checks the artifact before mutating any file on a FEAT `in-progress -> done` transition
  (prevents an `SL030` frontmatter/index strand), and `/sd:feature` Phase 6 requires an
  evidence citation before ticking an `AC-<n>` checkbox. 11 new conformance fixtures pin the
  gate, including the FEAT-only scoping (`block-index-done-bug-row-protected`) and the
  documented bundled-edit limitation (`allow-index-done-with-verify-bundled-edit`). (SW-6)
- Cross-implementation hook conformance suite (`tests/hooks/`): golden fixtures are piped into
  both the bash and PowerShell implementation of every hook and the normalized decisions must
  match; wired into CI on all matrix platforms with a self-test proving divergence detection (E4).
- Six more seeded lint rules in `examples/spec-lint-fixture/broken/` (SW-4, seam 4), taking
  coverage from 18 of 26 rules to 24: `SL004` (type/prefix mismatch), `SL005` + `SL043` (illegal
  status, which cannot have a legal retro log and so always drags `SL043` with it), `SL021`
  (`done` with a header-only retro), `SL041` (non-contiguous transition chain) and `SL044`
  (`archived -> in-progress` with an empty reason, the one WARN in the transition family). The
  two remaining rules, `SL001` and `SL013`, need the fixture or the engine install itself to be
  broken, so they need a corrupting harness rather than another seeded spec.
- Boundary documentation on the four seeds whose neighbouring rules overlap (SW-4, seam 4). The
  transition rules `SL040`-`SL044` are close enough that a linter can collapse several into one
  and still look correct, so each seed is built to make exactly one fire and names in-file which
  others must stay silent - e.g. `PERF-BROKEN-012` separates `SL021` (retro exists but is empty)
  from `SL043` (no retro at all), and `REF-BROKEN-013` isolates `SL041` behind two legal edges,
  a matching last entry and a present retro.
- Severity-tagged output for `/sd:spec validate` (SW-4, seam 3), with a stable rule table
  (`SL001`-`SL054`). BLOCK is reserved for a registry that lies about itself or evidence that was
  fabricated; WARN for a real but recoverable problem that leaves the registry truthful. The
  command reads `sd-severity-taxonomy` and `sd-evidence-citation` from disk at runtime, because
  only agents load skills via frontmatter and `validate` invokes no subagent.
- Anchor table in `sd-severity-taxonomy` (SW-4, seam 3): BLOCK/WARN still requires an anchor, but
  the legal anchor now depends on the target - a constitution `§N.M` or acceptance criterion for
  code, a lint rule ID for the `.specs/` tree. The code row stays strict.
- `examples/spec-lint-fixture/` (SW-4, seam 3): a clean `.specs/` tree that must report all-PASS
  and a seeded-broken one covering 18 of the 26 lint rules, each violation self-documented with a
  `SEEDED` comment. The two perf specs are a matched pair guarding the seam-1 regression: the
  correct one (unfilled baseline at `approved`) must PASS and the fabricated one must BLOCK.
  Run by hand - the linter is a prompt, so CI cannot execute it; see the fixture README.
- `linked_specs` frontmatter field on all five spec templates (SW-4, seam 2), replacing the
  "Linked specs" body section that only `feature.template.md` ever had - `/sd:spec link` accepted
  any spec ID but had nowhere to write on the other four types. Cross-references are now a
  structured YAML list maintained by `link` on both sides.
- Four structural checks in `/sd:spec validate` (SW-4, seam 2): index <-> folder symmetry (orphan
  folders, ghost rows, duplicate rows), transition replay against the state machine from the
  `05-retro.md` append-only log (catches a hand-edited status that bypassed `/sd:spec status`),
  link resolution (no dangling links), and link symmetry (no one-sided links).
- `<<PHASE-N: ...>>` token in the spec templates (SW-4, seam 1 of the `/sd:spec validate` linter):
  a distinguishable marker for cross-phase fields, replacing 20 phase-deferred fields that were
  previously indistinguishable from author-fill `<<placeholder>>`s. This makes the engine's
  cross-phase discipline machine-checkable in both directions - `validate` can now assert that an
  author-fill token is *gone* by `approved` and that a phase-deferred token is *still there*, so
  pre-filling a field from memory is caught rather than merely discouraged.
- `specwright.manifest.json` (SW-3): canonical inventory contract declaring where assets live
  (`areas`) and where the docs publish numbers about them (`docClaims`). Stores no counts - they
  are derived from disk at runtime, so adding a command/agent/skill/template means adding the file
  and nothing else.
- Check 7 (docs consistency) in `scripts/validate.{ps1,sh}`: fails the build when a published
  number disagrees with disk. Also fails on a *vacuous* claim (a pattern that matches nothing, i.e.
  a reworded doc that silently disabled its own check) and on an *undeclared* claim (a number no
  `docClaims` entry covers). Closes the gap that let SW-1's drift reach `main` with CI green.
- `scripts/selftest-docs.{ps1,sh}`: negative self-test proving Check 7 still bites, by corrupting a
  throwaway repo copy across four scenarios. Runs in CI on Ubuntu, macOS and Windows.

### Changed
- `Pattern refs` is required on **every** atomic task (SW-11), not only on tasks that create a new
  file or public symbol. A task with no precedent writes `Pattern refs: none` explicitly - `none`
  asserts the architect looked, an absent field asserts nothing. Legacy blocks with the field
  missing are still read as `none`, so existing `.specs/` folders keep working; the omission is a
  WARN, never a block. Task-block field count is now 11 across all docs (README,
  `docs/architecture.md`, `commands/feature.md`, `commands/refactor.md`,
  `agents/spec-architect.md`, `agents/implementer.md`), correcting a pre-existing drift where six
  of those sites still said 9 after SW-6 bumped the skill to 10.
- SW-11 explicitly did **not** add the `Context refs` field its ticket asked for. `Pattern refs`
  already covers the need with 22-of-22 adoption in the live corpus; renaming would touch 37 sites
  across 10 files for no measurable gain. Recorded in the ADR and on the ticket.

### Fixed
- Four `subagent-retro` conformance fixtures (`lessons-already-shown`, `lessons-disabled`,
  `lessons-scope-filter`, `lessons-surfaced`) were non-deterministic: each expects a **fresh** retro
  (`emitted: false`, `stale: []`, `subagent_stop` with `stale: 0`) but shipped no `setup.json`, so the
  harness copied `05-retro.md` with its on-disk mtime and the case failed on any checkout older than
  `retroStaleMinutes` (default 30 min) - the hook then read the retro as stale, flipped to
  `emitted: true`, and the drifted lesson selection no longer matched the golden (SW-23). Each now
  ships a `setup.json` that `touch`es its retro to `ageMinutes: 5`, mirroring how `remind-stale-retro`
  (120) and `metrics-emits-when-debounced` pin their fixtures; the four cases were introduced with the
  lesson-injection loop (SW-19) and the omission stayed latent because the suite is usually run while
  the retro is still fresh. Verified by backdating the retros two days on disk and confirming
  65 passed / 0 failed (bash output byte-identical to pwsh, so this was always a fixture defect, never
  a hook divergence). Test-only; no product-code or user-facing impact.
- Four PowerShell hook config reads used PowerShell truthiness where the bash twin asks a
  type-strict question, so the two implementations disagreed on the same `project-config.json`
  (SW-22). Two failure modes, both invisible to a scaffolded project (the template ships
  `enabled: true` and non-zero numbers) but reachable by the hand-trimmed config a user writes to
  change one setting. (1) **Absent `enabled` disabled the hook in PowerShell only.** A `subagentRetro`
  / `specGate` block that omitted `enabled` left the property `$null`, and `-not $null` is `$true`,
  so `subagent-retro.ps1` and `spec-gate.ps1` exited silently; `prompt-router.ps1` had the same class
  via `[bool]$null` (which is `$false`). All three bash twins use `== false`, so only a literal
  `false` disables. The reads are now type-strict (`-is [bool]` / return `$false` only for a real
  boolean `false`), mirroring the `verifyGate` and `metrics.enabled` reads already fixed this way.
  (2) **An explicit `0` was treated as absent.** `subagent-retro.ps1`'s `retroStaleMinutes` and
  `debounceMinutes` reads used `if ($config...)`, and PowerShell treats `0` as falsy, so an explicit
  `0` was ignored and the default kept, while the bash `// 30` / `// 10` accept `0`; both now use
  `$null -ne`, matching the `maxLessons` read SW-19 fixed for the same reason. Bash was already
  correct, so no `.sh` changed - the fix converges the pair. Five conformance fixtures added
  (`subagent-retro/{enabled-absent-still-on,stale-minutes-zero-honored,debounce-minutes-zero-honored}`,
  `spec-gate/enabled-absent-warns`, `prompt-router/enabled-absent-emits`); every one fails if its
  read is reverted - the previous fixture set could not, because all of them set `enabled` explicitly
  and used non-zero numbers.
- `docs/architecture.md` described the metrics `stale` field as a "count of stale/missing retros
  observed for that spec". It is a per-event flag, `0` or `1` - `subagent-retro` emits one event per
  in-progress spec per subagent stop and sets `1` when that spec's retro is stale or missing
  (`hooks/bash/subagent-retro.sh` `emit_subagent_stop_metric`). Retro pressure is measured by
  counting `1`s over time, never by reading a single value as a quantity. Found while building the
  first reader of the log (SW-16); the field had no consumer until now, so nothing had contradicted
  the prose.
- Check 7 could not see three whole classes of inventory claim, and each class had let a real,
  wrong number sit in a tracked doc through many green runs (SW-24). The `claimPhrases` vocabulary
  in `specwright.manifest.json` now closes all three:
  (1) **Spelled-out numbers.** Every pattern was anchored on `[0-9]+`, so `README.md`'s intro line
  saying "seven reusable skills" was invisible from the moment an eighth skill shipped in SW-17.
  (2) **Capitalisation.** Adding a lowercase word alternation is *not* enough - a spelled-out count
  in prose is usually sentence-initial, which is exactly where it is capitalised. `Three hooks ship
  in cross-platform pairs` in `docs/architecture.md` escaped a lowercase-only fix. POSIX ERE (bash
  `[[ =~ ]]`) has no inline case flag, so each word carries an explicit `[Tt]`-style class rather
  than a flag only one of the two engines supports.
  (3) **Bare nouns.** Only decorated forms were listed (`slash commands`, `workflow commands`), so
  `Five commands invoke no subagent` matched nothing at all - a line added by SW-16 itself, one
  commit before this one. Bare `commands` and `agents` are now in the vocabulary.
  Measured across the whole tracked tree: 4 real claims surfaced, 0 false positives.
  The four offending lines are resolved under a policy now recorded in the manifest
  (`$claimPolicyComment`): **if a number is derivable from an area, write it in digits and declare
  it; if it is not derivable, publish no number and let the names carry the meaning.** So
  `README.md`'s intro became digits with five new `docClaims` entries, `Three hooks ship ...`
  became `3 hooks ship ...` with a `docClaims` entry against `hooksPowerShell`, and the two counts
  that no area derives (`Five commands invoke no subagent ...`, `the two hooks that record`) had
  the number removed - both already listed every item by name.
  `selftest-docs.{sh,ps1}` grow from 4 scenarios to 6, one per new escape, and they are kept
  separate on purpose: a fix that only adds a lowercase alternation passes scenario 4 and fails 5,
  and a fix that only handles decorated nouns passes 5 and fails 6. Both were verified by
  sabotage - reverting the vocabulary to digit-only makes scenario 5 report `THE CHECK DID NOT
  BITE` while 6 stays green, and removing the bare-noun entries produces the mirror image.
  Check 7 now validates 52 published claims, up from 46.
- `subagent-retro.ps1` terminated its emitted block with `[Console]::Out.WriteLine`, which appends
  `[Environment]::NewLine` - CRLF on Windows - so its output differed from `subagent-retro.sh` by
  exactly one byte on the final line. Both the `<retro-reminder>` and the new `<retro-lessons>`
  block now `Write` an explicitly LF-terminated string. Pre-existing; surfaced by SW-19's
  byte-comparison requirement.
- `selftest-docs.{sh,ps1}` scenarios 2 and 3 had silently stopped testing anything (SW-20). Both
  planted their corruption by string-replacing the literal `**11 slash commands**`; the repo now
  ships 12, so the pattern matched nothing, the sandbox copy was never corrupted, the validator
  correctly passed, and the scenario reported `THE CHECK DID NOT BITE`. Scenario 2's setup guard
  could not catch this because it only checked that the *planted* text was present - and the
  planted value (12) had since become the **true** value already in `README.md`, so the guard
  found the real line and passed vacuously. Scenario 3 had no guard at all. Both counts are now
  derived from disk (plant `true + 1`, which can never collide), and both scenarios assert the
  *transition* rather than the destination, reporting a `fixture setup` failure when the pattern
  does not match. Check 7 itself was never broken - only the proof that it still bites, which had
  been absent since the 12th command landed on an unpushed branch CI never ran. A hardcoded count
  in the selftest was the last instance in the repo of the exact anti-pattern
  `specwright.manifest.json` exists to abolish.
- `subagent-retro`'s debounce state file, an on-disk contract shared between the two
  implementations, was not written in the same shape by both (SW-5): `subagent-retro.ps1` wrote
  the round-trip `o` format with 7 fractional digits while `subagent-retro.sh` wrote whole
  seconds, so only the bash reader ever had to cope with fractions. PowerShell now writes the same
  whole-second `yyyy-MM-ddTHH:mm:ssZ` stamp. The bash reader's two date fallbacks were also both
  wrong on BSD/macOS: neither passed `-u`, so a UTC stamp was read as local time and skewed the
  debounce window by the machine's offset, and the BSD branch handed `date -f` a string with a
  trailing `Z` it would warn about on stderr - breaking the hook's silence. Both branches now
  force UTC and the value is trimmed before parsing. The debounce branch had no fixture coverage
  at all until now; `setup.json` grew a `write` action that plants a file whose content carries a
  `{{UTCNOW-45M}}`-style token resolved at run time, so a state-file fixture cannot rot.
- `spec-gate` path matching disagreed on case (SW-5). `spec-gate.ps1` compared with
  `OrdinalIgnoreCase` throughout; `spec-gate.sh` used case-sensitive `==` and `case` globs, so a
  protected entry of `.specs/Constitution.md` blocked an edit to `.specs/CONSTITUTION.md` under
  PowerShell and allowed it under bash. bash now lowercases both sides for the protected list, the
  allow-listed directory prefixes and the cwd-prefix strip. Case-insensitive is the right
  semantics for a gate, not merely the parity-preserving one: Windows and macOS filesystems are
  case-insensitive by default, so a case-sensitive rule is bypassable there by retyping the path.
- The `spec-gate` basename allow-list let source files through under a documentation name (SW-5).
  Both implementations allow-listed anything called `README*`, so `README.py` bypassed the gate
  outright, and the two disagreed on multi-dot names - bash's `README.*` glob allowed
  `README.old.py` while the PowerShell regex's single optional extension did not match it at all.
  Only EXTENSION-LESS `README`/`CHANGELOG`/`CONTRIBUTING`/`LICENSE`/`NOTICE`/`AUTHORS` are now
  allow-listed by name; everything with an extension is decided by the extension rules, so
  `README.md` is still a doc and `README.old.py` is now correctly gated as Python.
- `spec-gate.sh` applied NO protected paths when `.claude/project-config.json` was absent or
  unparseable (SW-5), while `spec-gate.ps1` applied its built-in defaults - so on a project that
  had not run `/sd:setup` yet, the most common state there is, editing `.specs/constitution.md`
  was blocked under PowerShell and silently allowed under bash. The bash fallback is now the same
  full default document (`.specs/constitution.md`, `.specs/index.md`, `LICENSE` protected;
  `mode: warn`) instead of `{}`. `Get-ProjectConfig` in all three PowerShell hooks now reads the
  config with `-ErrorAction Stop`, since the script-wide `SilentlyContinue` preference could
  otherwise turn a malformed config into a non-terminating error that skips the `catch` and
  returns `$null` rather than the defaults. `prompt-router` and `subagent-retro` were checked for
  the same asymmetry and have none - every value they read has a matching `//` default - which is
  now stated in both scripts so a future read does not quietly reintroduce it.
- Conformance decision objects were too coarse to prove much (SW-5). `spec-gate` decisions kept
  only `decision`/`permissionDecision` and threw away the human-readable `reason`, which the two
  implementations hand-duplicate - the reason strings could have drifted completely and all 20
  cases would still have passed. The decision now carries `reason`, and reports
  `REASON-MISMATCH-BETWEEN-SCHEMA-HALVES` if the legacy and `hookSpecificOutput` copies of it ever
  disagree. `subagent-retro` decisions likewise dropped the measured age and the threshold it was
  compared against, so the two implementations could have disagreed on the arithmetic unnoticed;
  both are now asserted, and `subagent-retro.sh` rounds the age to the nearest minute instead of
  truncating it, matching `subagent-retro.ps1`'s `[Math]::Round`. Every decision object now also
  carries `stderr`, so the repo's "every failure path exits 0 SILENTLY" invariant is actually
  checked rather than assumed - a hook that regressed into printing a diagnostic on every
  invocation used to pass.
- Two bash hook bugs surfaced by the cross-implementation conformance suite (SW-5). `prompt-router`,
  `spec-gate` and `subagent-retro` all read `enabled` with jq's `//` operator, which treats an
  explicit JSON `false` as absent - a project that set `enabled: false` in `project-config.json`
  got a hook that ran anyway; the three scripts now use an `if`/`then`/`else` jq expression that
  compares directly against `false`. Separately, `spec-gate`'s protected-path loop never blocked a
  protected path on Windows because Windows `jq.exe` emits CRLF for `join("\n")` output, leaving a
  trailing `\r` on each path that broke the exact-match comparison; the loop now strips a trailing
  CR before comparing, mirroring the existing strip in `prompt-router.sh`'s keyword loop.
- Three spec stubs in `examples/spec-lint-fixture/broken/` (SW-4, seam 4) raised an unlisted
  `SL011` BLOCK: `BUG-BROKEN-001` and `BUG-BROKEN-008` carried none of the bug template's four
  phase-3 tokens and `RCA-BROKEN-005` carried four of the rca template's seven, because each had
  dropped the enclosing section wholesale. At `draft` a spec must carry at least its template's
  per-phase token count, so all three failed a rule the fixture's expected-findings table does
  not list - which would have read as a linter bug rather than a fixture one. Found by running
  the linter against the tree rather than by inspection, which is the first time the SW-4
  acceptance criterion was executed end-to-end rather than reasoned about.
- Placeholder tokens spelled out inside `<!-- SEEDED: ... -->` comments in the fixture (SW-4,
  seam 4). A token named in a comment is indistinguishable from a real one to any linter that
  scans line-wise rather than parsing, so the comments explaining the placeholder rules were
  themselves seeding phantom findings in a tree whose contract is "these findings and no others".
  The comments now describe tokens in prose.
- `/sd:spec link` inverse map (SW-4) was partial and ambiguous: it accepted 9 relations but
  defined inverses for only 5, so `blocks`, `blocked-by`, `spawned-by` and `superseded-by` had no
  defined other side. `depends-on` and `blocked-by` also asserted the same edge in two spellings.
  `blocked-by` is now an input alias normalized to `depends-on`, and the map is total and closed -
  every stored relation has exactly one inverse, which is what makes link symmetry checkable.
- `/sd:spec validate` required-field rules (SW-4) had drifted from
  `skills/sd-spec-templates/SKILL.md`, the skill that authors the specs: `validate` checked only
  `id`/`type`/`status`/`created` (+`severity` for bug, +`incident_started` for rca), so it passed
  malformed specs missing `target_metric` (perf), `smell` (refactor), `jira` (feature/bug) and
  `incident_resolved` (rca). The rules are now per-type and match the skill.
- `/sd:spec validate` placeholder rule (SW-4) contradicted the templates it validates: "status >=
  `approved` -> no `<<placeholder>>` remaining" failed a *correct* perf spec, whose baseline field
  must still be unfilled at `approved` by the cross-phase rule in `CLAUDE.md`. Author-fill and
  phase-deferred tokens are now separate forms with separate rules.
- Doc count/inventory drift (SW-1): `README.md` listed `/sd:setup` at no gates (`-` -> `2`, matching
  the two approval gates in `commands/setup.md`) and omitted `sd-docs-writer` from
  `sd-evidence-citation`'s "Used by" list (4 agents, not 3).
- Stale `MSSQL` references in the docs, left over from the stack-agnostic database rename
  (`mcp.mssql` -> `mcp.database`): `docs/architecture.md` listed a hardcoded MSSQL tool in
  `sd-debugger`'s tool surface and an `mssql` server in the project-scope MCP table; `README.md`
  named MSSQL in the MCP-friendly summary and the MCP table; `docs/troubleshooting.md` had an
  MSSQL-titled section. All now describe the project-provided database MCP, matching
  `agents/debugger.md` and `templates/project-config.template.json`. Addresses `REVIEW-TODO.md`
  item 5's doc half; the `agents/debugger.md` body-vs-allowlist defect it also names remains open.
- `spec-gate`'s protected-path matching could be bypassed via `..` path traversal under the bash
  hook: `spec-gate.ps1` normalizes `file_path` with `[System.IO.Path]::GetFullPath`, which resolves
  `..`/`.` segments before comparing against `paths.protected`, but `spec-gate.sh`'s `normalize_rel`
  only normalized separators and stripped the cwd prefix - it never collapsed `..`. A path like
  `<cwd>/src/../.specs/constitution.md` reached the protected constitution file while presenting a
  relative form (`src/../.specs/constitution.md`) that matched nothing in `paths.protected`, so
  bash exited 0 and silently allowed editing a protected file that PowerShell correctly blocked.
  `spec-gate.sh` now collapses `.`/`..` segments with pure string processing (no `realpath`,
  `readlink -f`, or `cd`, since the file may not exist yet under `Write` and the decision must not
  depend on filesystem state) before the protected-path and allow-list comparisons, clamping a
  rooted `..` at its own root the same way `GetFullPath` does, and falling back to the raw,
  un-collapsed path when resolution would escape the workspace entirely - matching
  `ConvertTo-RelativePath`'s own fallback branch. Covered by three new conformance fixtures:
  `..` traversing into a protected file, a bare `.` segment, and a benign `..` that resolves to a
  non-protected code file, proving the fix does not over-block.
- The bash-side `..` traversal fix above was one-sided: `spec-gate.ps1` had the mirror-image
  weakness, still live, letting the same class of edit through under PowerShell. Its
  `ConvertTo-RelativePath` called `[System.IO.Path]::GetFullPath($FilePath)` on a RELATIVE
  `file_path`, which resolves it against this hook PROCESS's own working directory rather than the
  `cwd` supplied in the hook payload; the result then failed the base-prefix check and fell through
  to the raw, un-collapsed path, matching nothing in `paths.protected`. A relative
  `src/../.specs/constitution.md` therefore reached the protected constitution file while
  PowerShell exited 0 silently and bash (already fixed) correctly blocked it. Separately,
  `GetFullPath` preserves a trailing path separator, so `<cwd>/.specs/constitution.md/` failed the
  protected-path equality test outright and, since `GetExtension` also returns `""` for a
  trailing-separator path, was not even caught by the code-file rule - a second silent bypass.
  `spec-gate.ps1` now collapses `.`/`..` segments with the same pure string processing as
  `spec-gate.sh`'s `collapse_dot_segments`/`normalize_rel` (a relative `file_path` is collapsed
  directly rather than joined onto the process cwd; a trailing separator collapses away as a
  no-op segment) so the two implementations resolve identically. `prompt-router` and
  `subagent-retro` were checked for the same pattern and do not have it - neither reads
  `tool_input.file_path` or compares a user-supplied path against `paths.protected`. Covered by
  three new conformance fixtures: a relative `..` traversal into the protected constitution file,
  a trailing separator on the protected constitution file, and a benign relative `..` resolving to
  a non-protected code file, proving the fix does not over-block.
- Extended `.gitattributes` with a repo-wide `* text=auto` default plus `*.sh` and `*.ps1` pinned to
  `eol=lf`, so shell scripts no longer check out as CRLF on Windows, where a `#!/usr/bin/env bash`
  line with a trailing CR fails with `bad interpreter` and heredocs / `[[ ... ]]` mis-parse (SW-21).
  Folds the previously narrow, fixtures-only policy into a repo-wide one; the byte-comparison fixture
  pins (`tests/**`) stay because `* text=auto` still yields a native CRLF checkout on Windows. The
  first checkout after this lands renormalizes line endings in existing Windows working trees - a
  one-time large diff, not a real change.

## [1.4.0] - 2026-07-05

### Added
- `ROADMAP.md` - published roadmap of near-term, planned, and exploratory work, linked from
  `README.md` (new `## Roadmap` section + Documentation entry). Migrated the forward-looking items
  out of the non-standard `### Planned` subsection that sat under the `1.2.0` changelog entry into
  this dedicated file.
- `/sd:setup` codebase scan (Phase 2.5) - samples the project tree to pre-fill detected facts
  (stack, `paths.{src,tests,docs}`, `commands.*` from the project manifest, and a new ordered
  inside-out `paths.layers` map) into `CLAUDE.md` and `project-config.json`, with a single batch
  confirmation gate. Facts only - constitution rules are never auto-filled. Adds `paths.layers` to
  `templates/project-config.template.json`.
- `/sd:adr` command (11th) + `sd-docs-writer` agent (6th) - drafts a numbered, MADR-style Architecture
  Decision Record under `.specs/_adr/` from a spec's `03-decisions.md` (or an ad-hoc decision), behind one
  hard approval gate. The agent (model `sonnet`, tools Read/Write/Glob/Grep, skill `sd-evidence-citation`)
  writes only the ADR file and never invents decisions; the command owns numbering and supersession links.
  Bumps command count 10 -> 11 and agent count 5 -> 6 across docs and the validators.
- `scripts/smoke-hooks.sh` + `scripts/smoke-hooks.ps1` - pipe fixture Claude Code hook JSON into
  `prompt-router`, `spec-gate`, and `subagent-retro` against a temp `.specs/` tree and assert exit
  codes AND key output substrings, not just "did not crash": keyword-match routing (bash and
  PowerShell must agree), spec-gate allow/warn/block across in-progress / header-only-marker /
  docs-edit / malformed-stdin cases, and subagent-retro naming the real spec ID then debouncing a
  second run. `.github/workflows/ci.yml` adds `macos-latest` to the OS matrix (exercising the
  BSD-specific `stat -f %m` / `date -j -f` fallback branches that only run there) and a smoke-test
  step on every OS.

### Changed
- Removed hardcoded MSSQL/C#/TS references from `agents/debugger.md`, `commands/perf.md`,
  `commands/rca.md`, and `commands/bug.md`, per CLAUDE.md's stack-agnostic rule. `sd-debugger`'s
  tool allowlist no longer bakes in `mcp__mssql__execute_sql`; its "Database discipline" section
  (renamed from "MSSQL discipline") now describes the same read-only SELECT/EXPLAIN discipline
  generically, deferring to whatever database MCP tool or CLI client the project provides.
  `templates/project-config.template.json`'s `mcp.mssql` entry is renamed to `mcp.database`.
  `perf.md`/`rca.md` generalize "MSSQL access (via MCP)" to "database access (via the project's
  MCP tool or CLI)"; `perf.md`'s final-review check drops the C#/TS-specific `dynamic`/`any`
  example in favor of "type-safety escapes for the project's language (as defined in
  `constitution.md`)"; `bug.md`'s failing-test step now references `paths.tests` from
  project-config instead of a hardcoded `tests/<mirrored path>/` with a C#-style example name.
- De-duplicated rules that were copy-pasted from skills into agent bodies and commands (CLAUDE.md:
  "a rule used by multiple agents lives in one `SKILL.md`, never copy-pasted"), replacing each
  copy with a reference to the owning skill: `agents/debugger.md`'s and `agents/reviewer.md`'s
  Anti-patterns sections no longer restate `sd-hypothesis-tree`/`sd-severity-taxonomy`/
  `sd-evidence-citation` (role-specific bullets are kept); `agents/code-explorer.md`'s
  Anti-patterns section no longer restates `sd-evidence-citation`. `commands/feature.md` and
  `commands/refactor.md` no longer inline the atomic task-block format - both now point at
  `sd-atomic-task-format`, which gains a documented "Refactor mode" `Parallel batch` field (the
  field `refactor.md`'s inline copy had already drifted to include while `feature.md`'s copy
  lacked it). `commands/bug.md` and `commands/rca.md` no longer restate the 5-mental-models /
  `(Likelihood x Impact) / Cost-to-verify` method inline - both now point at `sd-hypothesis-tree`.
- `scripts/validate.sh` and `scripts/validate.ps1` now derive their expected install-target
  counts (commands / agents / skills / hooks / templates) from the source tree instead of
  hardcoding them as literals in both files - a new command/agent/skill/template only needs to
  land in its source dir, never a constant bumped in two scripts (this already bit PR #12, which
  had to bump both). Each derived count is asserted `> 0` so an empty or misnamed source dir
  fails loudly instead of vacuously passing Check 5.

### Fixed
- `hooks/bash/prompt-router.sh` emitted `- /sd:0` instead of `- /sd:<workflow>` under bash 3.2
  (macOS system bash): `declare -A` is a bash-4 feature, so the associative arrays silently
  degraded to indexed arrays with all string subscripts arithmetic-evaluating to `0`. Caught by
  the macOS CI smoke test (`validate (macos-latest)` was red since the matrix gained macOS).
  Rewrote keyword matching with parallel indexed arrays; the hook is now bash-3.2 compatible.
- `hooks/powershell/subagent-retro.ps1`'s debounce silently stopped persisting/reading state on
  PowerShell 7+, found by writing `scripts/smoke-hooks.ps1`: (1) `Save-State`'s
  `Split-Path -LiteralPath $StatePath -Parent` throws "Parameter set cannot be resolved" on some
  PS7 builds (`-LiteralPath` there has no `-Parent` parameter set) - the surrounding `try/catch`
  swallowed it, so the state directory/file were never written; switched to `Split-Path -Path`
  (safe here - `-Parent` does no filesystem globbing, only `-Resolve` would). (2) Even once the
  state file wrote, `Test-DebounceElapsed` re-broke: PS7's `ConvertFrom-Json` auto-converts an
  ISO-8601 `...Z` string to a `[datetime]` (PS 5.1 leaves it as a string), and re-`Parse`-ing an
  already-converted `[datetime]` stringifies it with the local culture - dropping the UTC marker -
  so `[datetimeoffset]::Parse` silently re-interpreted it as local time, skewing `$age` by the
  machine's UTC offset exactly like the bug fixed earlier in this file, just triggered a different
  way. Both are PowerShell-only; `hooks/bash/subagent-retro.sh` was unaffected (no bash twin
  change needed).
- `install/install.sh` hardening: aligned to `set -euo pipefail` (was `set -e` only, so unset-
  variable typos and mid-pipeline failures - e.g. a `sha256sum`/`shasum` error - passed silently;
  those two pipelines now end `|| true` since a hash-tool failure is expected-recoverable, not a
  reason to abort); added the same `--prefix` safety guard `uninstall.sh` already had (empty,
  `/`, `\`, or `..` components rejected) to `install/install.ps1` too, so install and uninstall
  accept the same set of prefixes on both platforms - previously only uninstall validated it, so
  `--prefix ../evil` would have written outside the intended tree; quoted the unquoted
  `rel="${f#$src_root/}"` strip pattern (glob-interpreted `$src_root` broke on a repo path
  containing `[`, `*`, or `?`); and added an `ERR` trap that reports how many files already
  landed and the exact `uninstall.sh` command to run if a copy fails mid-install (no full
  transactional rollback - per-file `.bak.*` backups already protect overwritten files).
- Post-1.3.0 docs drift: `README.md`'s tagline said "Ten slash commands, five specialized
  subagents" (now eleven / six); the Commands table was missing `/sd:adr` and listed
  `/sd:feature` at 4 hard gates (the merged review+integration gate makes it 3); the Agents table
  was missing `sd-docs-writer` and listed a hardcoded `MSSQL` tool for `sd-debugger`; the `.specs/`
  tree diagram omitted `_explorations/`, `_reviews/`, `_adr/`; the Roadmap highlights repeated two
  items that already shipped. `ROADMAP.md`'s `## Planned` section still listed the `/sd:setup`
  codebase scan and `sd-docs-writer` agent, both shipped in 1.3.0+ (CHANGELOG is the source of
  truth for shipped work). `docs/usage.md`'s Utility commands section had no `/sd:adr` entry.
  `templates/project-config.template.json`'s `workflow.gates.feature` still listed the pre-merge
  4-gate sequence; collapsed to 3 and marked `_comment`-descriptive since no hook or command reads
  the block. `CONTRIBUTING.md`'s agent frontmatter example omitted the mandated `color:` and
  `skills:` fields. `examples/README.md` gated a promised-features list on "not in v1.0.0", three
  minor versions after v1.0.0; reworded to point at `ROADMAP.md`.
- Phase 0 of `/sd:feature`, `/sd:bug`, `/sd:refactor`, `/sd:perf`, and `/sd:rca` now guards
  against missing or malformed Layer-2 context instead of silently reading `CLAUDE.md`,
  `.specs/constitution.md`, `.claude/project-config.json`, and `.specs/index.md` and letting
  later phases fail on undefined config values. Missing `.specs/`, `.specs/constitution.md`, or
  `.specs/index.md` now STOPs with "No `.specs/` found - run `/sd:setup` first." (matching
  `spec.md`/`release.md`/`adr.md`); malformed `.claude/project-config.json` STOPs naming the file;
  a missing `CLAUDE.md` only WARNs and continues, since the constitution (not `CLAUDE.md`) is the
  binding Layer-2 contract - matching the stance the four utility commands already took.
- `sd-code-explorer`'s `impact-map` task no longer instructs the agent to APPEND to
  `OUTPUT_APPEND_TO` - its tool allowlist has no `Write`/`Edit`, so it physically could not
  perform that write, silently starving `03-decisions.md` (and everything downstream that reads
  it as `IMPACT`). The task now returns the structured analysis as final output; the informational
  `OUTPUT_TARGET` input names the file, and the calling command appends it. `commands/feature.md`
  and `commands/refactor.md` each gained an explicit main-thread append step after the impact-map
  invocation. `commands/perf.md`, `commands/bug.md`, and `commands/rca.md`'s equivalent
  "Append ... to `03-decisions.md`" steps after `sd-debugger` invocations (also write-tool-less)
  are now explicitly labeled as main-thread steps for the same reason.
- `/sd:bug`, `/sd:rca`, and `/sd:perf` now walk every state in `/sd:spec`'s
  `draft -> approved -> in-progress -> done -> archived` machine instead of jumping straight from
  `draft`/`approved` to `done` - a history `/sd:spec status` itself would have refused as an
  illegal transition. `bug.md` sets `approved` at Gate 2 (reproduction confirmed) and
  `in-progress` at the start of Phase 5 (fix implementation); its Gate 3a "abort" (hypothesis tree
  exhausted) now passes through `in-progress` on its way to `done` instead of jumping directly
  from `approved`. `rca.md` sets `approved` at Gate 3 (root cause confirmed) and `in-progress` at
  the start of Phase 4 (isolate + document) - RCAs produce no code, so "in-progress" now means
  report-writing is underway. `perf.md` sets `draft` at spec creation (previously jumped straight
  to `approved` at Gate 1) and `in-progress` at the start of Phase 4 (the per-hotspot loop),
  including the Gate 2 Case A shortcut (baseline already meets SLA) which now passes through
  `in-progress` before `done`. `docs/troubleshooting.md`'s "Illegal status transition" entry no
  longer tells users that `/sd:rca` intentionally skips straight to `done`.
- `/sd:setup` now migrates `.claude/*` drift instead of exiting blind on a `complete` project. A
  new Phase 1.5 (drift check & migrate) runs whenever `.claude/project-config.json` or
  `.claude/settings.json` exists (states `complete` and `partial`) and rule-based-compares them
  against the loaded templates - catching renamed engine paths (`hooks/ck` -> `hooks/sd`), the
  `$schema` URL, `/ck:*` // `ck:*` names in `_use` docs, newly-introduced fields
  (`ticket.snapshot`, `paths.layers`), pinned model IDs (`claude-sonnet-4-6` -> `sonnet`), and
  stale `settings.local.json` permission paths. Every change is previewed in one batch gate
  (silence is not approval) and each file is backed up `.bak.<timestamp>` before a targeted,
  value-preserving patch. Fixes scaffolded projects whose three hooks silently pointed at the
  non-existent `~/.claude/hooks/ck/` directory after the `ck` -> `specwright` rename.
- `/sd:setup` Phase 7 (and Phase 1.5) now verify every hook `command` path in
  `.claude/settings.json` resolves to a file on disk, warning loudly when a hook is not firing.
- `hooks/powershell/subagent-retro.ps1`, `prompt-router.ps1`, and `spec-gate.ps1` no longer assign
  parsed hook JSON to `$input` - PowerShell's reserved automatic pipeline variable. Assigning to it
  threw a non-terminating `ParameterBindingException` on every real (piped/redirected) stdin
  invocation, leaving it unbound and causing every PowerShell hook to exit silently before reading
  any input. Renamed to `$hookInput` in all three files.
- `hooks/bash/spec-gate.sh` in-progress detection now requires `in-progress` and a spec ID on the
  SAME line, matching `spec-gate.ps1` and `prompt-router.sh`'s existing same-line semantics. The
  previous two independent file-wide `grep`s let an `in-progress` legend/header line combine with a
  spec ID on an unrelated `done` row, so bash allowed a code edit that PowerShell would warn/block
  on the identical `.specs/index.md`.
- `commands/feature.md` subagent invocations now use the field names `sd-spec-architect` and
  `sd-code-explorer` actually read: `TICKET_CONTEXT` (was `TICKET_DATA`), `TASK`/`SPEC`/`IMPACT`
  (was `TASK_TYPE`/`SPEC_REF`/`IMPACT_REF`), a full `feature.template.md` filename (was the bare
  `feature`), and both `refine` invocations now carry the required `SPEC` path. `sd-reviewer`
  invocations, which legitimately use `TASK_TYPE`/`SPEC_REF` as their own contract, are unchanged.
  `commands/refactor.md`'s characterization-test loop now invokes `sd-implementer` with
  `TASK_DETAILS`/`SPEC_REF`/`WORKFLOW_TYPE` instead of the unrecognized `TASK_TYPE`, matching every
  other implementer invocation in the repo.
- `/sd:spec validate` no longer requires `01-plan.md`/`02-tasks.md` for in-progress bug and perf
  specs. Only `/sd:feature` and `/sd:refactor` produce those artifacts; `/sd:bug` and `/sd:perf`
  go straight from spec to investigation/baseline artifacts, so the old "except RCA" exemption
  reported FAIL on every correctly executed bug/perf spec. Also corrected the same overgeneralized
  claim in `docs/usage.md`'s resume heuristic.
- `hooks/powershell/subagent-retro.ps1`'s debounce check now parses `lastReminderUtc` as UTC via
  `[datetimeoffset]::Parse(...).UtcDateTime` instead of `[datetime]::Parse(...)`, which returned a
  local-`Kind` value silently converted from the UTC string, skewing `$age` by the machine's UTC
  offset (negative for ~UTC offset hours on UTC+N machines, wrongly suppressing reminders; always
  past-debounce on UTC-N machines, never suppressing). The bash twin was already correct
  (epoch seconds throughout).
- `hooks/powershell/prompt-router.ps1` now applies the built-in default keyword list PER WORKFLOW
  when the loaded `.claude/project-config.json` has no list (or an empty list) for that workflow,
  matching `prompt-router.sh`'s per-workflow fallback. Previously PS only fell back to defaults
  when the config file itself was absent/unparseable, then silently skipped any workflow whose
  list was `$null` once a config file existed - so a valid config that simply omitted
  `workflow.keywords` (or one workflow's entry) lost keyword routing hints on Windows while bash
  kept emitting them from defaults on Linux/macOS. The five built-in keyword lists are unchanged,
  just reused instead of duplicated.
- Agent frontmatter `tools:` allowlists and body instructions in `agents/code-explorer.md`,
  `agents/debugger.md`, `agents/reviewer.md`, `agents/implementer.md`, `agents/spec-architect.md`,
  `commands/explore.md`, and `skills/sd-evidence-citation/SKILL.md` referenced MCP tool names that
  no longer exist on the live servers (`mcp__gitnexus__search`/`get_file`/`find_references`/
  `get_call_graph`/`list_symbols`, `mcp__context7__get-library-docs`, `mcp__tavily__search`),
  so every "verify via MCP" instruction pointed at a dead tool. Remapped to the current GitNexus
  surface (`query`, `context`, `impact`, `list_repos`) and renamed `context7`/`tavily` tools to
  their current names (`query-docs`, `tavily_search`), keeping each agent's frontmatter allowlist
  and body usage in parity.
- `hooks/bash/prompt-router.sh`'s per-workflow keyword lookup silently dropped every keyword but
  the last in a workflow's list when `.claude/project-config.json` defined `workflow.keywords`:
  some `jq` builds (observed with a Windows `jq.exe`) emit CRLF line endings for `join("\n")`
  output even from an LF-only input, so `while IFS= read -r kw` left a trailing `\r` on every
  keyword but the final one, and `[[ "$prompt_lower" == *"$kw_lower"* ]]` never matched a
  CR-suffixed keyword. Found by piping real prompts through the hook against a live project's
  config (not the smoke-test fixture, which omitted `workflow.keywords` and only ever exercised
  the hardcoded default-list fallback). Fixed by stripping a trailing `\r` off each line read from
  the list; also added a `workflow.keywords` block to both `scripts/smoke-hooks.sh` and
  `scripts/smoke-hooks.ps1` fixtures so the `jq`/config-driven path is exercised going forward.
  `hooks/powershell/prompt-router.ps1` was unaffected (native `ConvertFrom-Json`, no `jq`).

---

## [1.3.0] - 2026-06-18

Release-tooling and CI hardening. Adds the `/sd:release` command (10th), a single-command repo invariant
validator with a Windows + Ubuntu CI matrix, an uninstaller, and a batch of command/agent refinements.

### Added
- `/sd:release` command (10th command) - generates release notes from completed specs: collects
  every spec in `done` status (feature / bug / refactor / perf; RCA excluded), groups them into
  Keep-a-Changelog sections (FEAT -> Added, BUG -> Fixed, REF/PERF -> Changed) under an inferred
  SemVer heading (any feature -> minor bump, else patch; major never auto-inferred), then
  transitions each `done -> archived`. One hard gate previews the notes and the archive plan
  before any write; `--dry-run` stops before writing. Pure file ops, no subagent (mirrors
  `/sd:spec`). Gives the `done` (merged, unshipped) vs `archived` (shipped) states a concrete
  meaning.
- `scripts/validate.ps1` + `scripts/validate.sh` - one command that runs every documented engine
  invariant: pure-ASCII scan of `*.ps1`, `bash -n` on `*.sh`, hook-pair parity, agent `model:`
  alias-only check, install-target file counts (real install to a temp base), and a non-empty
  `[Unreleased]` CHANGELOG gate. Exit 1 on any failure.
- `.github/workflows/ci.yml` - runs `validate` on push/PR across a Windows + Ubuntu matrix, plus an
  install -> uninstall round-trip per the `CLAUDE.md` sandbox recipe.
- `install/uninstall.ps1` + `install/uninstall.sh` - removes the five `<base>/<area>/sd/`
  directories with dry-run preview, confirmation prompt (`-Force`/`--force` to skip), and
  per-project cleanup reminders (`.claude/settings.json` hook wiring, `.claude/.hookstate/`).

### Changed
- `scripts/validate.{ps1,sh}` Check 6 now treats an empty `[Unreleased]` section as passing when the
  section immediately below it is a dated `[x.y.z] - <date>` release heading (the freshly cut version),
  so a clean post-release CHANGELOG no longer fails CI. A non-release-state empty `[Unreleased]` still
  fails, preserving the "every PR adds a changelog line" invariant.
- `/sd:perf` Gate 6 now structurally refuses a no-measurable-gain "keep" instead of merely warning about
  it in prose. The gate branches on the noise check: a measurable improvement still offers `keep` /
  `revert`, but a within-noise result defaults to `revert` and allows `keep` only as an explicit logged
  constitution exception (decision `kept (exception)` + a reason recorded to `05-retro.md`). With no
  reason supplied, the change is reverted.
- `docs/architecture.md` gains two reference sections: a "Command -> agent routing" tree showing the
  subagent fan-out per command (and the three file-ops commands that invoke none), and an "Artifact
  ownership" table mapping each `.specs/<ID>/` file to its producing phase/agent and downstream readers.
  Consolidates routing/ownership that previously lived only in scattered command files.
- `/sd:setup` Q1 and the `sd-spec-architect` ticket protocol now state explicitly that automatic
  ticket-context fetch is JIRA-only: GitHub Issues and Linear are still recorded as the project
  tracker (for prompt-hook ID recognition), but their ticket content is not auto-fetched - paste it
  into the prompt instead. The ticket snapshot protocol is documented as JIRA-specific. Closes the
  silent degradation where non-JIRA projects got no ticket fetch and no explanation.

### Fixed
- `/sd:spec status` now spells out the illegal-transition refusal instead of the vague "REFUSED with
  explanation": it prints the current state, the requested state, the valid next state(s) from the
  state machine, and the shortest legal path to the requested state when reachable (e.g. `draft -> done`
  is rejected with the hint `draft -> approved -> in-progress -> done`). No file is mutated on refusal.
- `/sd:bug` Phase 3 no longer assumes a confirmed root cause always arrives. The investigation loop
  previously said "Continue until one is CONFIRMED" with no exit, so a bug whose every hypothesis is
  rejected/inconclusive had no defined stopping point. Added Gate 3a (hypothesis tree exhausted): the
  loop now terminates on a CONFIRMED hypothesis OR an exhausted tree, and the exhausted case STOPs and
  asks the user to re-enumerate (with new evidence), add observability, or abort as "root cause not
  found" - never guessing a fix from an unconfirmed tree.
- `install/install.sh` marked executable (mode `100755`, matching `uninstall.sh`); it was `100644`,
  so the documented `./install/install.sh` invocation failed with "Permission denied" on a fresh
  Linux checkout. Surfaced by the new CI round-trip.
- `install/README.md`: total file count corrected (21 -> 32), `skills/sd/` added to the layout
  tree, install table, and manual uninstall commands (skills were missed since 1.1.0), and the
  `-Prefix`/`--prefix` option documented.

---

## [1.2.0] - 2026-06-12

Pattern conformance release. Introduces `sd-pattern-discipline` (the 6th skill), wires it into spec-architect/implementer/reviewer, adds the `Pattern refs` task field, and closes the gap where impact analysis never reached implementation.

### Added
- `sd-pattern-discipline` skill (6th skill) - pattern discovery and adherence rules: precedent
  sampling, `Pattern refs` authoring (spec-architect), following (implementer), and conformance
  review (reviewer). Fixes implementations that ignored the target codebase's structure.
- `Pattern refs` task field in `sd-atomic-task-format` - 1-3 `file:line` precedent citations the
  implementer reads before writing. Required for tasks creating a new file or public symbol;
  absent field is treated as `none` (backward compatible with existing `.specs/` folders).
- `sd-code-explorer` impact-map output gains a "Precedents & conventions" section: nearest
  similar implementations, observed naming/layout conventions, and reusable existing utilities.
- Ticket snapshot protocol in `sd-spec-architect`: fetched JIRA tickets are now persisted to
  `.specs/<ID>/04-artifacts/ticket/` together with related tickets (1 hop, capped) and linked
  Confluence pages (capped). Configurable via `ticket.snapshot` in project-config (enabled by
  default, absent means enabled); fetch failures never block spec creation.
- `CLAUDE.md` added to the specwright repo itself (was previously missing).

### Changed
- `/sd:feature`, `/sd:bug`, `/sd:refactor`, `/sd:perf` now pass `IMPACT_REF` (`03-decisions.md`)
  to `sd-implementer`, closing the gap where impact analysis never reached implementation.
- `sd-spec-architect`, `sd-implementer`, `sd-reviewer` wired to the `sd-pattern-discipline`
  skill; implementer's convention discipline expanded to cover new files, new-symbol naming, and
  reuse-before-write for helpers.
- `sd-spec-architect` Atlassian tool allowlist: added `getJiraIssueRemoteIssueLinks` and
  `getConfluencePage` (snapshot collection).

### Fixed
- `sd-spec-architect` tool allowlist referenced `mcp__atlassian__searchJiraIssues`, which is not
  a real Atlassian MCP tool name - corrected to `mcp__atlassian__searchJiraIssuesUsingJql`.
  Slug-based ticket search could never have resolved before.

> Forward-looking items that previously lived here moved to [`ROADMAP.md`](ROADMAP.md).

---

## [1.1.0] - 2026-06-03

Architecture refresh. Adds an Agent Skills layer and upgrades the `spec-gate` hook to the CLI's new permission-decision schema (forward-compatible, no break for older CLIs).

### Added

#### Skills (5, new `skills/sd/` layer)
A skill is a markdown rule pack referenced by agents from their YAML frontmatter (`skills: [...]`). Skills de-duplicate rules shared across multiple agents, keep agent prompts smaller, and make the rules auditable in one place.

- `sd-severity-taxonomy` - Severity rules (BLOCK / WARN / SUGGEST / PASS) and the mandatory review output format. Applied by `sd-reviewer`.
- `sd-hypothesis-tree` - Enumerate / verify protocol with the 5 mental models, `(L × I) / C` score formula, and the proximate-vs-root "why" ladder. Applied by `sd-debugger`.
- `sd-atomic-task-format` - The 9-field atomic task block plus canonical enums (`Step type`, `Complexity`, `Reversibility`). Applied by `sd-spec-architect` (authoring) and `sd-implementer` (consuming).
- `sd-evidence-citation` - `file:line` citation discipline, snippet length rules, evidence taxonomy, grouping. Applied by `sd-code-explorer`, `sd-debugger`, `sd-reviewer`.
- `sd-spec-templates` - Per-template authoring rules (feature / bug / refactor / perf / rca). Applied by `sd-spec-architect`.

#### Agent frontmatter
- All 5 agents now declare a `skills: [...]` list in frontmatter.
- All 5 agents now declare a `color:` field for terminal rendering.
- Agent body sizes reduced where content moved into a referenced skill.

#### Installers
- `install/install.ps1` and `install/install.sh` now install `skills/<prefix>/` alongside `commands/<prefix>/`, `agents/<prefix>/`, `hooks/<prefix>/`, `templates/<prefix>/`.

### Changed

#### Hooks - dual-format block output
Both `spec-gate.ps1` and `spec-gate.sh` now emit a single JSON object that carries **both** the new and legacy schemas. The CLI reads whichever it understands:

```json
{
  "decision": "block",
  "reason": "...",
  "hookSpecificOutput": {
    "permissionDecision": "deny",
    "reason": "..."
  }
}
```

This is forward-compatible with CLI builds that read `hookSpecificOutput.permissionDecision` and backward-compatible with builds that read the top-level `decision` field. No version probing needed.

#### Documentation
- `README.md` - Added Skills section and updated Layer 1 diagram to include `skills/sd/`.
- `docs/architecture.md` - Added "Agent skills" section explaining the rule-pack pattern; added the dual-format block-output schema to the `spec-gate` description.

---

## [1.0.0] - 2026-01-15

Initial public release.

### Added

#### Slash commands (9, all under `sd:` namespace)
- `/sd:feature` - Spec-driven feature workflow with 4 hard gates (spec, plan, review, integration).
- `/sd:bug` - Root-cause-first bug fix workflow with 5 hard gates (symptom, reproduction, root cause, failing test, regression).
- `/sd:rca` - Incident root-cause analysis (output IS the spec; no code change).
- `/sd:refactor` - Coverage-gated refactor workflow with 6 hard gates (spec, coverage threshold, post-test, plan, per-batch tests, holistic review).
- `/sd:perf` - Baseline-first performance workflow with 8 hard gates (target, baseline, hotspot, hypothesis, correctness, keep/revert, regression, final review).
- `/sd:spec` - Spec registry management (list / show / status / link / archive / revive / search / validate / stats / help).
- `/sd:explore` - Read-only code exploration via the `sd-code-explorer` agent.
- `/sd:review` - Standalone constitution-compliance review on a path, recent edits, or a spec.
- `/sd:setup` - Idempotent project scaffold (CLAUDE.md + .claude/ + .specs/ + project-config.json).

#### Subagents (5, cost-aware model assignment)
- `sd-spec-architect` (sonnet) - Creates and refines specs / plans / tasks.
- `sd-code-explorer` (haiku) - Read-only code navigation with citation discipline.
- `sd-debugger` (sonnet) - Hypothesis-tree investigation with sequential-thinking.
- `sd-implementer` (haiku) - Executes ONE atomic task with scope discipline.
- `sd-reviewer` (sonnet) - Severity-tagged compliance review (BLOCK / WARN / SUGGEST / PASS).

All agents use **portable model aliases** (`sonnet`, `haiku`) - they auto-update with the latest Anthropic models and are not pinned to specific versions.

#### Hooks (3, cross-platform)
- `prompt-router` (UserPromptSubmit) - Keyword routing and spec-context injection.
- `spec-gate` (PreToolUse on Edit / Write / MultiEdit) - Guard rail blocking code edits when no in-progress spec is registered.
- `subagent-retro` (SubagentStop) - Reminder to update stale retros after subagent runs.

Each hook ships in two flavours:
- `hooks/powershell/*.ps1` - PowerShell 5.1+ (pure ASCII, Windows-1252 safe).
- `hooks/bash/*.sh` - Bash 4+ with `jq` (graceful fallback if `jq` missing).

#### Templates (9)
**Setup templates (4):**
- `CLAUDE.template.md` - Thin orchestrator pointing at `.specs/`.
- `constitution.template.md` - YAML frontmatter + 8 governance sections.
- `project-config.template.json` - Machine-readable config (paths, commands, models, MCP, hook modes).
- `settings.template.json` - Claude Code hook wiring (PowerShell variant by default).

**Spec templates (5):**
- `feature.template.md`
- `bug.template.md` (root-cause and fix fields intentionally empty until Phase 3).
- `refactor.template.md`
- `perf.template.md` (baseline and results log intentionally empty until measured).
- `rca.template.md`

#### Installer
- Cross-platform: `install/install.ps1` (Windows) and `install/install.sh` (Unix/macOS).
- Content-hash (SHA256) comparison to skip identical files.
- Timestamped backups (`*.bak.<yyyyMMdd-HHmmss>`) before overwrites.
- `--dry-run`, `--force`, and `--base-path` options.
- Interactive y/N/all prompt on existing files.

#### Documentation
- `README.md` - GitHub landing page.
- `docs/architecture.md` - 3-layer architecture, lifecycle, cost model.
- `docs/usage.md` - Command-by-command reference.
- `docs/walkthrough.md` - End-to-end fictional project demo.
- `docs/troubleshooting.md` - Common issues and fixes.
- `install/README.md` - Install guide.
- `CONTRIBUTING.md` - PR process and dev guidelines.

### Design properties
- **Stack-agnostic** - Agents read `CLAUDE.md` and `constitution.md` at runtime; no hardcoded language, framework, or layer assumptions.
- **Hard gates** - Workflows refuse to proceed without explicit user approval at named checkpoints.
- **Spec as durable memory** - Every workflow produces searchable artifacts under `.specs/<ID>/`.
- **Cost-aware models** - Heavy reasoning (spec, debug, review) on sonnet; mechanical execution and read-only exploration on haiku.

### Known compatibility
- Claude Code CLI: tested with the released version current at January 2026.
- Operating systems: Windows 11 + PowerShell 5.1 / 7.x, macOS 13+, Ubuntu 22.04+.
- Optional MCP servers: Atlassian, Context7, sequential-thinking, GitNexus, MSSQL, Playwright, Tavily.

[Unreleased]: https://github.com/developzoneio/specwright/compare/v1.6.0...HEAD
[1.6.0]: https://github.com/developzoneio/specwright/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/developzoneio/specwright/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/developzoneio/specwright/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/developzoneio/specwright/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/developzoneio/specwright/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/developzoneio/specwright/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/developzoneio/specwright/releases/tag/v1.0.0
