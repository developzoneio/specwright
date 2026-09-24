# Usage guide

Command-by-command reference for specwright. For the why and how it fits together, see [`architecture.md`](architecture.md). For a fully-worked example, see [`walkthrough.md`](walkthrough.md).

---

## First-time project setup

```
cd <your-project>
claude
> /init                # Standard Claude Code init (writes a basic CLAUDE.md)
> /sd:setup            # specwright scaffold
```

`/init` is optional but recommended. It creates a baseline `CLAUDE.md` that `/sd:setup` can parse for stack hints.

`/sd:setup` is interactive and asks **at most 3 questions**:

1. Ticket system (JIRA / GitHub / Linear / none).
2. Ticket pattern (regex like `^[A-Z]+-[0-9]+$`).
3. Shell (PowerShell / bash / both).

It generates:

```
<repo>/
├── CLAUDE.md                            (overwrites with backup if present)
├── .specs/
│   ├── constitution.md                  (with <<placeholder>> tokens to fill)
│   ├── index.md                         (empty registry)
│   ├── _explorations/                   (scratchpad for /sd:explore saves)
│   ├── _reviews/                        (scratchpad for /sd:review saves)
│   └── _adr/                            (architecture decision records)
└── .claude/
    ├── project-config.json
    └── settings.json
```

After running, **open `CLAUDE.md` and `.specs/constitution.md` in your editor** and fill the placeholders. `/sd:setup` does not infer your conventions; you declare them.

---

## Workflow commands

### `/sd:feature <ID-or-slug>`

Spec-driven feature workflow.

| Phase | Subagent / Actor | Gate |
|---|---|---|
| 0 - Bootstrap | main thread | - |
| 1 - Spec | `sd-spec-architect` | ⛔ Gate 1 (spec approval) |
| 2 - Impact | `sd-code-explorer` | - |
| 3 - Plan + tasks | `sd-spec-architect` | ⛔ Gate 2 (plan approval; complexity triage) |
| 4 - Execute | `sd-implementer` per task + main thread self-check | - |
| 5 - Integration + batch review | main thread + `sd-reviewer` (holistic, once) | ⛔ Gate 3 (integration + review) |
| 6 - Close-out | main thread | - |

**Spec ID**: `FEAT-<arg>`. State machine on re-invocation: detected state -> resume at next phase.

Phase 2 records the codebase's precedents and conventions (nearest similar implementations, naming patterns, existing utilities) alongside the impact map. Phase 3 tasks then carry `Pattern refs` - `file:line` citations of precedent code the implementer must read before writing, so new code mirrors the existing structure.

The architect writes a spec-level `complexity` estimate (`S` | `M` | `L`) at Phase 1. Gate 2 then measures the actual plan: under the decompose thresholds (> 8 tasks, > 2 production layers excluding Tests/Config, > 8 impacted files, or an unresolved Open question) it is the normal plan approval with **zero added friction**; over them it becomes a HARD **Gate Complexity** that refuses one oversized plan and forces a split into medium child specs (`FEAT-<arg>-<slug>`, linked to the parent umbrella). A create-time `L` estimate also escalates the impact and planning models, per the `sd-model-escalation` skill (tunable or disabled via `models.escalation` in project-config). Still 3 hard gates - complexity triage is a second face of Gate 2, not a fourth gate.

Example:
```
/sd:feature INV-2501
```
With JIRA enabled and ticket pattern matching `INV-2501`, the architect fetches the ticket and includes it in the spec context. It also snapshots the ticket content, its related tickets (1 hop), and linked Confluence pages to `.specs/FEAT-INV-2501/04-artifacts/ticket/` as durable evidence - caps configurable via `ticket.snapshot` in project-config.

### `/sd:bug <ID-or-slug>`

Root-cause-first bug fix. **Refuses to fix without reproduction confirmed AND root cause documented.**

| Phase | Subagent / Actor | Gate |
|---|---|---|
| 0 - Bootstrap | main thread | - |
| 1 - Capture symptoms | `sd-spec-architect` | ⛔ Gate 1 |
| 2 - Reproduce | main thread (interactive) | ⛔ Gate 2 (HARD - no override) |
| 3 - Investigate | `sd-debugger` (enumerate + verify) | ⛔ Gate 3 (root cause confirmed) |
| 4 - Write failing test FIRST | main thread | ⛔ Gate 4 (test fails as expected) |
| 5 - Minimal fix | `sd-implementer` | - |
| 6 - Regression + review | `sd-reviewer` (bug-fix-final) | ⛔ Gate 5 |
| 7 - Close-out | main thread | - |

**Spec ID**: `BUG-<arg>`.

Example:
```
/sd:bug 1247
```

### `/sd:rca <slug>`

Incident analysis. **No code is changed in this workflow.** Output IS the spec.

| Phase | Subagent / Actor | Gate |
|---|---|---|
| 0 - Bootstrap | main thread | - |
| 1 - Gather signals | main thread (interactive) | ⛔ Gate 1 (evidence gathered) |
| 2 - Hypothesis enumeration | `sd-debugger` (enumerate, incident mode) | ⛔ Gate 2 |
| 3 - Verify loop | `sd-debugger` (verify) | ⛔ Gate 3 (root cause confirmed) |
| 4 - Isolate + document | main thread | - |
| 5 - Follow-up actions | main thread | - |

**Spec ID**: `RCA-<slug>-<YYYYMMDD>`.

Fixes spawn separate `BUG-*`, `REF-*`, or `PERF-*` specs (reserved IDs listed under "Spawned specs" in the RCA).

Example:
```
/sd:rca payment-outage-jan8
```

### `/sd:refactor <slug> [smell-type]`

Coverage-gated refactor. **Refuses to touch code if coverage on affected files is below threshold (default 80%).**

| Phase | Subagent / Actor | Gate |
|---|---|---|
| 0 - Bootstrap | main thread | - |
| 1 - Spec | `sd-spec-architect` | ⛔ Gate 1 |
| 2 - Impact | `sd-code-explorer` | - |
| 3 - Coverage | main thread (runs `commands.coverage`) | ⛔ Gate 2 (threshold) + ⛔ Gate 3 (post-tests) |
| 4 - Plan parallel-safe tasks | `sd-spec-architect` | ⛔ Gate 4 |
| 5 - Execute batched (max 3 parallel) | `sd-implementer` per task | ⛔ Gate 5 (per-batch tests green) |
| 6 - Holistic review | `sd-reviewer` (holistic) | ⛔ Gate 6 |
| 7 - Close-out | main thread | - |

**Spec ID**: `REF-<slug>-<YYYYMMDD>`.

Example:
```
/sd:refactor extract-pricing-service extract-class
```

### `/sd:perf <endpoint-or-slug>`

Baseline-first optimization. **Refuses to optimize without a measured baseline.**

| Phase | Subagent / Actor | Gate |
|---|---|---|
| 0 - Bootstrap | main thread | - |
| 1 - Define target | `sd-spec-architect` | ⛔ Gate 1 |
| 2 - Baseline measurement | main thread | ⛔ Gate 2 (HARD) |
| 3 - Identify hotspot | `sd-debugger` (hotspot-analysis A) | ⛔ Gate 3 |
| 4 - Per-hotspot loop | `sd-debugger` (sub B) + `sd-implementer` + re-measure | ⛔ Gates 4-6 (hypothesis / correctness / keep-or-revert) |
| 5 - Regression check | main thread | ⛔ Gate 7 |
| 6 - Final review + close | `sd-reviewer` (perf-final) | ⛔ Gate 8 |

**Spec ID**: `PERF-<slug>-<YYYYMMDD>`.

Example:
```
/sd:perf search-endpoint-latency
```

### `/sd:port <slug> --from <source> --scope <scope>`

Fidelity-first port. **The donor is the specification - every departure is a row in the deviation
table, or it is a defect.** Reproduces a donor implementation inside this host repo, with a
justified-diff parity review as the close-out gate.

| Phase | Subagent / Actor | Gate |
|---|---|---|
| 0 - Bootstrap (args, port policy) | main thread | - |
| 1 - Consume bridged contract / in-repo extract | main thread + `sd-code-explorer` (port-extract, in-repo only) + `sd-spec-architect` (create) | - |
| 2 - Freeze snapshot | main thread | Gate 1 (HARD) |
| 3 - Host survey | `sd-code-explorer` (impact-map) + main thread constitution scan | - |
| 4 - Fidelity tables | `sd-spec-architect` (refine) | Gate 2 (HARD) |
| 5 - Pin behavior | main thread + `sd-implementer` | Gate 3 (HARD) |
| 6 - Plan atomic tasks | `sd-spec-architect` (plan) | Gate 4 |
| 7 - Execute batched | `sd-implementer` per task | Gate 5 |
| 8 - Parity review | main thread + `sd-reviewer` (port-parity) | Gate 6 (HARD) |
| 9 - Close-out | main thread | - |

**Spec ID**: `PORT-<slug>-<YYYYMMDD>`. `--scope` (`endpoint` / `module` / `feature` / `pattern`) is
explicit - Phase 0 asks when it is omitted and never infers it, because a wrong guess changes the
behavior-pinning mechanism used at Gate 3. `--from` selects topology: a bridged (cross-repo)
contract artifact produced by `/sd:explore --port` in the donor repo, or an in-repo path/symbol for
intra-repo duplication - the rest of the pipeline is identical either way.

Phase 5's pinning mechanism follows scope: `endpoint` gets a contract test suite runnable against
donor and host; `module` gets characterization tests through an interface-typed construction seam
so re-pointing changes exactly one factory method; `feature` uses whichever the surface allows;
`pattern` skips pinning (there is no donor instance) but still proves the host tree is unmodified.

Phase 6's complexity triage uses a port-specific metric - the count of deviation-table rows
requiring adaptation, not the impacted-file count the other workflows use, because a port's file
count equals the donor's by construction and would trip on nearly every port regardless of how much
judgment the work needs.

Phase 0 reads the port policy from a `Port policy` heading in `.specs/constitution.md` and always
states the effective policy in its output, including the fallback (structural mirror, per
`sd-port-fidelity`) when the host constitution declares nothing.

Example:
```
/sd:port order-intake --from .specs/_explorations/order-intake-20260809-1200/ --scope endpoint
/sd:port order-intake --from src/orders/order-intake --scope module
```

---

## Utility commands

### `/sd:spec <subcommand>`

Spec registry. **No code is changed. No subagent is invoked.**

| Subcommand | Args | Use |
|---|---|---|
| `list` | `[type] [status]` | Filtered list of specs |
| `show` | `<ID>` | Frontmatter + section summary + task completion |
| `status` | `<ID> <new-state>` | Validated lifecycle transition (logs to retro) |
| `link` | `<ID-A> <relation> <ID-B>` | Cross-reference (depends-on, related-to, spawned-by, ...) |
| `archive` | `<ID>` | Move from `done` to `archived` |
| `revive` | `<ID> [reason]` | Move from `archived` to `in-progress` |
| `search` | `<term>` | Full-text grep across spec bodies |
| `validate` | `[ID or --all]` | Verify frontmatter + structure + index consistency |
| `stats` | - | Counts + aging report |
| `help` | - | Print subcommand list |

Examples:
```
/sd:spec list bug in-progress
/sd:spec show FEAT-INV-2501
/sd:spec status BUG-1247 done
/sd:spec link FEAT-INV-2501 depends-on REF-extract-pricing-20260112
/sd:spec search "low-stock"
/sd:spec stats
```

### `/sd:explore <target-or-query>`

Read-only code navigation. Single `sd-code-explorer` invocation. No spec created.

The command parses your query for intent:
- "where is X" / "define X" -> definition mode.
- "who calls X" / "callers of X" -> callers mode.
- "trace X" -> call-graph trace.
- "what depends on X" / "impact of changing X" -> impact map.
- "show all X" / pattern -> grep pattern search.
- "structure of X" -> directory + symbols overview.

Output includes `file:line` citations for every finding. Offers to save to `.specs/_explorations/<slug>-<timestamp>.md`.

Examples:
```
/sd:explore where is PaymentHandler defined
/sd:explore who calls UserService.GetById
/sd:explore impact of changing StockReservation
/sd:explore show all places that use Redis
```

### `/sd:review [path | "recent" | "spec <ID>"]`

Standalone compliance review. Constitution required - aborts if missing.

Four modes:

- `<path>` - review a file or directory.
- `recent` or `recent <N>h` - files modified in the last N hours (default 4).
- `spec <ID>` - changed files associated with a spec.
- *(no args)* - interactive prompt to pick a mode.

Output: severity-tagged findings 🔴 BLOCK / 🟠 WARN / 🟡 SUGGEST / 🟢 PASS, each citing `file:line` and a constitution `§N.M`.

Examples:
```
/sd:review src/Application/Payment
/sd:review recent 4h
/sd:review spec BUG-1247
```

### `/sd:setup`

Already covered above. Re-runnable. Detects state (fresh / post-init / partial / complete) and only fills gaps. Backs up any file before overwriting.

### `/sd:release [version] [--dry-run]`

Cut a release from completed specs. **No code is changed. No subagent is invoked.** Pure file ops, like `/sd:spec`.

Collects every spec currently in `done` (types feature / bug / refactor / perf / port - RCA is never released), groups them into Keep-a-Changelog sections, writes a versioned section to the project `CHANGELOG.md`, then transitions each released spec `done -> archived`.

| Phase | Actor | Gate |
|---|---|---|
| 0 - Bootstrap | main thread | - |
| 1 - Collect `done` specs | main thread | - |
| 2 - Group into sections | main thread | - |
| 3 - Determine version | main thread | - |
| 4 - Preview + confirm | main thread | ⛔ Gate 1 (HARD - preview before any write) |
| 5 - Write CHANGELOG + archive | main thread | - |
| 6 - Report | main thread | - |

Type-to-section mapping: feature + port -> `Added`, bug -> `Fixed`, refactor + perf -> `Changed`.

Version is inferred when omitted (any feature -> minor bump, else patch; major is never auto-inferred - pass it explicitly). `--dry-run` renders the notes and the archive plan, then stops without writing.

The lifecycle distinction this relies on: `done` = merged but not yet shipped; `archived` = shipped in a release.

Examples:
```
/sd:release                  # infer version, preview, confirm, write
/sd:release 2.0.0            # explicit version (e.g. a major)
/sd:release --dry-run        # preview only, write nothing
```

---

### `/sd:adr <spec-ID | "decision title">`

Promotes a durable decision into a numbered, MADR-style ADR under `.specs/_adr/`. Drives the `sd-docs-writer` agent.

Argument: a spec ID (e.g. `FEAT-012`) whose `03-decisions.md` holds the decision, or a free-text decision title for an ad-hoc ADR with no spec.

| Phase | Actor | Gate |
|---|---|---|
| 0 - Bootstrap | main thread | - |
| 1 - Resolve decision source | main thread | - |
| 2 - Assign number and slug | main thread | - |
| 3 - Draft ADR | `sd-docs-writer` | - |
| Gate - approve before keeping | main thread | ⛔ Gate 1 (HARD - nothing is kept without approval) |
| 4 - Report | main thread | - |

Numbers are 4-digit, sequential (`0001-`, `0002-`, ...), derived by scanning `.specs/_adr/`. The
agent never invents decisions - an empty or absent `03-decisions.md` aborts the command. ADRs are
not specs: they have no `.specs/index.md` lifecycle entry.

Examples:
```
/sd:adr FEAT-012                        # ADR from an existing spec's decisions
/sd:adr "Adopt CQRS for the order service"  # ad-hoc ADR, no spec
```

---

### /sd:verify

Proves criterion -> task -> test traceability for one spec and writes
`.specs/<ID>/06-verify.md` with `result: pass|fail`. The spec-gate hook blocks a FEAT
(feature-spec) `index.md` row from transitioning to `done` without a passing artifact
(`hooks.specGate.verifyGate`, default on). Other spec types (bug, refactor, perf, rca, port) close
out through the unconditional protected-path rule, same as before this gate existed.

    /sd:verify FEAT-1042

Run it at close-out (Phase 6 of /sd:feature runs it for you) or any time earlier as a
progress check. A FAIL lists VF0xx findings with file:line citations.

---

## Porting from a donor repository

A `PORT` spec captures reproducing a donor repo's behavior in this host repo: which donor, at
which commit, which members must land, where each path maps to, and which departures are
sanctioned. `/sd:port` (documented above) drives the full pipeline - bridge, freeze, survey,
fidelity tables, behavior pinning, plan, batched execute, justified-diff parity, close-out.

**Cross-repo (bridged) topology** - when the donor lives in a different repository, capture its
side first: run `/sd:explore --port <entry point> --scope <scope> [--snapshot
contract+source]` **in the donor repo** (a separate session - never load a host project's
`CLAUDE.md` or constitution alongside it). It writes a fixed-section contract, plus - under
`contract+source` - a `source/` bundle with `MANIFEST.md`, to the donor's own
`.specs/_explorations/`. Pass that bundle's path as `--from` to `/sd:port` in the host repo - moving
the bundle between the two repos is a manual or scripted step, not automated by either command.

**Intra-repo topology** - when the donor and host are the same repository (duplicating a pattern
elsewhere in the codebase), pass the donor path or symbol directly as `--from`; `/sd:port` invokes
`sd-code-explorer`'s `port-extract` mode itself in Phase 1.

**Known limitations**:
- `spec-gate`, `prompt-router`, and `subagent-retro` do not recognize the `PORT-` prefix (it is
  hardcoded in the hook scripts) - a `PORT-` spec is invisible to in-progress-spec detection,
  context injection, and lesson scoping. Workaround: set `hooks.specGate.mode: "warn"` for the
  duration of the port, or track the work under an accompanying FEAT spec.
- `hooks.specGate.verifyGate` is FEAT-scoped, so a port's `done` close-out is not verify-gated by
  the hook - `/sd:port` Phase 9 still runs `/sd:verify` itself and requires `result: pass` before
  closing out.

---

## Common patterns

### Picking the right workflow

| You have | Use |
|---|---|
| "Add a new endpoint / behavior / capability" | `/sd:feature` |
| "Something is broken; need to investigate then fix" | `/sd:bug` |
| "Production incident; need a post-mortem with no code change" | `/sd:rca` |
| "This file / module is too tangled; need to restructure" | `/sd:refactor` |
| "X is too slow; need to optimize with measurements" | `/sd:perf` |
| "Reproduce a donor repo's behavior in this repo, faithfully" | `/sd:port` |
| "I just want to navigate the code" | `/sd:explore` |
| "Review this change for compliance" | `/sd:review` |
| "Manage / browse the spec registry" | `/sd:spec` |
| "Cut a release / generate release notes from completed work" | `/sd:release` |
| "Prove a spec is really done (criteria covered, tests pass)" | `/sd:verify` |

### Resuming a workflow

Workflow commands are **resumable**. Re-running `/sd:feature INV-2501` after closing your terminal mid-execution detects the current state of `.specs/FEAT-INV-2501/` and jumps to the next phase. The state machine is documented at the top of each command file.

The main heuristic: workflow checks for the presence and contents of `00-spec.md`, `05-retro.md`, and (feature/refactor/port only) `01-plan.md` and `02-tasks.md` (with task completion ratio) to determine where you are.

### Linking specs

When an RCA spawns fixes, link them so the registry knows:

```
/sd:rca payment-outage-jan8         # produces RCA-payment-outage-jan8-20260108
# ...RCA filled in, spawned specs listed...
/sd:bug 1310                        # produces BUG-1310
/sd:spec link BUG-1310 spawned-by RCA-payment-outage-jan8-20260108
```

Now `/sd:spec show BUG-1310` reveals the parent RCA.

### Recording deferred work

Every spec type now carries a `## Spawned specs` table - `Reserved ID | Type | Title | Owner` -
the same one the RCA has always had. Close-out in `/sd:feature`, `/sd:bug`, `/sd:refactor` and
`/sd:perf` prompts for it whenever the retro names something deferred. It is a prompt, not a gate:
an empty table is a legitimate answer.

A reserved ID is a **placeholder, not a registry entry**. It does not go in `.specs/index.md` and
it does not go in `linked_specs` until the child spec actually exists:

```
# FEAT-INV-2501 closes with | BUG-1310 | bug | Guard the empty-prefix match | alice |
/sd:bug 1310                                          # now the directory exists
/sd:spec link BUG-1310 spawned-by FEAT-INV-2501       # now the link exists
```

`/sd:spec validate` raises `SL090` (🟡 SUGGEST, never a failure) on a `done` spec that talks about
follow-up work and leaves the table empty.

### When a workflow can't make progress

If you hit a hard gate that the system refuses to override (e.g. bug reproduction unavailable, perf baseline cannot be measured), the workflow surfaces options:

1. **Gather more evidence** - logs, telemetry, observability changes.
2. **Accept the gate with explicit constitution exception** - logged to retro.
3. **Abort** - the spec stays at its current state for later resumption.

The system surfaces; the human decides. The gates exist precisely so the decision is conscious.

---

## Hook behavior examples

Hooks emit output inline during a session. Examples:

**prompt-router** on `"fix bug INV-2501 in stock service"`:

```
<context-router>
Routing hints from specwright (UserPromptSubmit hook):

Workflow keyword matches:
  - /sd:bug  (matched: bug, fix)

Ticket IDs detected: INV-2501
Matching spec folders under .specs/:
  - FEAT-INV-2501

Specs currently in-progress (from .specs/index.md):
  - FEAT-INV-2501
</context-router>
```

**spec-gate** when editing `src/Stock.cs` with no in-progress spec, `mode: warn`:

```
[WARN] spec-gate: editing code file 'src/Stock.cs' but no in-progress spec is recorded in .specs/index.md. Run /sd:feature, /sd:bug, /sd:refactor, or /sd:perf first to create a spec, or set hooks.specGate.mode='off' in .claude/project-config.json to disable.
```

**spec-gate** in `mode: block`:

```json
{"decision":"block","reason":"spec-gate: editing code file 'src/Stock.cs' but no in-progress spec..."}
```

**subagent-retro** after a subagent run, retro file is 90 minutes stale:

```
<retro-reminder>
Retro files appear stale or missing for the following in-progress specs:
  - FEAT-INV-2501: 05-retro.md last touched 90 min ago (threshold 30 min)

Consider appending: decisions made, surprises encountered, follow-ups identified.
</retro-reminder>
```

---

## Hook configuration

`.claude/project-config.json` contains the `hooks` section:

```json
{
  "hooks": {
    "userPromptRouter": {
      "enabled": true
    },
    "specGate": {
      "enabled": true,
      "mode": "warn"
    },
    "subagentRetro": {
      "enabled": true,
      "retroStaleMinutes": 30,
      "debounceMinutes": 10
    }
  }
}
```

**Common adjustments:**

- Tightening: change `specGate.mode` from `"warn"` to `"block"` once your team is used to the workflow.
- Loosening: set `enabled: false` on any hook during noisy debug sessions. Don't forget to flip back.
- Pace tuning: `retroStaleMinutes` and `debounceMinutes` control how often the retro reminder fires. Set both higher for long-form work; lower for tight iteration cycles.

`paths.protected` controls which files trigger an unconditional `decision=block`:

```json
{
  "paths": {
    "protected": [
      ".specs/constitution.md",
      ".specs/index.md",
      "LICENSE"
    ]
  }
}
```

Add anything you never want edited via Claude Code's tool. Migration scripts, sealed configs, generated files, etc.