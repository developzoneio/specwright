# Contract lint (Check 8)

`scripts/contract-lint.ps1` and `scripts/contract-lint.sh` lint the **relationships between** the
engine's prompt files: which agent a command invokes, which skill an agent loads, which template a
prompt reads, how many hard gates a workflow declares.

Check 7 (`docs consistency`) already guards *inventory* -- how many files exist. That closed the
inventory drift class permanently. This closes the **contract** drift class: relationships that
were previously asserted in prose and checked only by human review.

Each of these shipped, and each was statically detectable the whole time:

| Shipped defect | Caught by |
|---|---|
| An agent told to append to a file with no write tool in its allowlist | CL200 (wave 3) |
| An input token an invocation never actually passes | CL102 (wave 2) |
| An `mcp__*` tool name that does not exist | CL202 (wave 3) |
| README claiming one gate count where `docs/architecture.md` claimed another | CL302 |
| A command step asserting an artifact write in a read-only agent's block, with no writer named | CL205 (SW-51) |
| A workflow that let the model move a spec's status with `sed -i`, past `spec-gate` | CL206 (SW-79) |
| `/sd:adr` invoking a subagent with no escalation decision, found when CL601 first ran | CL601 (SW-63) |

It is a **script, not a prompt**: deterministic file operations, no subagent, no model, run per PR
in CI on all three operating systems like every other check.

## Running it

```bash
bash scripts/contract-lint.sh --root .              # the repo
bash scripts/contract-lint.sh --root <tree>         # any tree with a manifest
bash scripts/contract-lint.sh --root . --rule CL305 # filter the output
```

```powershell
.\scripts\contract-lint.ps1 -Root .
.\scripts\contract-lint.ps1 -Root . -Rule CL305 -Quiet
```

`--rule` filters what is **printed**, never what runs. Every rule always executes, so `CL902`
(a suppression that suppressed nothing) stays truthful under a filter.

Output is TSV on stdout and nothing else -- one finding per line, root-relative paths, forward
slashes, sorted by file then line then rule then message:

```
CL300	BLOCK	commands/alpha.md	59	gate block contains no literal STOP
```

Exit codes: `0` no BLOCK findings, `1` at least one BLOCK, **`2` could not run** (bad root, missing
manifest, `jq` absent, registry parity guard failed). Exit 2 is separate on purpose. A validator
that cannot tell "clean" from "crashed" is worthless, so validate's Check 8 treats it as a failure.

## Rules

Severity lives in `specwright.manifest.json` under `contractLint.rules[]`, never in a rule's own
code, so a BLOCK/WARN divergence between the two implementations is structurally impossible.

### CL0xx -- reference resolution

| Rule | Severity | Fires when |
|---|---|---|
| `CL001` | BLOCK | an `sd-` token resolves to neither an agent name nor a skill folder |
| `CL002` | BLOCK | an agent's `skills:` frontmatter entry has no `skills/<name>/SKILL.md` |
| `CL003` | BLOCK | the same unresolved shape as CL001, on a line that mentions a skill |
| `CL004` | WARN | a skill folder is referenced by nothing in scan scope and is not declared in `skillConsumers` |
| `CL005` | BLOCK | a `templates/` path does not exist once the install namespace segment is folded away |
| `CL006` | BLOCK | a `/sd:<name>` reference has no `commands/<name>.md` |
| `CL007` | WARN | an agent is mentioned by no command body |
| `CL008` | BLOCK | a numbered spec-artifact filename is absent from `contractLint.specArtifacts` |
| `CL009` | BLOCK | a command's `## Phase 0` section restates a phrase from `contractLint.bootstrapGuardPhrases` -- text `sd-bootstrap-guard` owns |

CL001 and CL003 split on whether the offending line mentions a skill; both BLOCK, so the split is
about the message a reader gets, not about severity.

`CL009` is the inverse of the rules above it: text that must be a reference, not a copy. The
workflow commands' Phase 0 bootstrap guard lives in `skills/sd-bootstrap-guard/SKILL.md`, which
each command reads at runtime (commands cannot load skills via frontmatter). The rule scans every
`commands/*.md`, not a consumer list, so a new workflow that copies the guard is caught too. Its
window opens at a `## Phase 0` heading and closes at the next H1/H2 heading; fenced lines and
suppression comments are skipped. Each line is also joined with the next one, so a phrase wrapped
across two lines still matches -- reported once, on the line where it starts. The vocabulary
deliberately omits "run `/sd:setup` first": `/sd:release`, `/sd:review`, `/sd:spec` and
`/sd:verify` say it for their own preconditions, and the guard's half of that sentence ("No
`.specs/` found") always travels with it. Blind spots, by design: a paraphrase, a phrase wrapped
over three or more lines, and a restatement outside Phase 0. `CL009` **shipped BLOCK from its
introduction on 2026-09-24** (SW-54), on the same `warnBudget` grounds as `CL205`.

### CL1xx -- invocation contract

An **invocation** is a `commands/*.md` line mentioning "Invoke"/"invoke" next to a backticked
`sd-<agent>` token. From there its **token span** runs forward through every backticked
`` `KEY = value` `` pair -- covering a bullet block, a same-line inline list, and a wrapped
multi-line inline list alike -- until the next heading, the next invocation, or the next top-level
numbered step, whichever comes first. A **mode declaration** is an `agents/*.md` heading carrying
the same kind of `` `KEY = value` `` pair (or, for the `` Task type: `value` `` heading grammar,
a key named by the agent's own "Read the `KEY` field" prose) immediately followed by
`Inputs (required):` then `Inputs (optional):` lines.

| Rule | Severity | Fires when |
|---|---|---|
| `CL100` | BLOCK | an invocation sets `TASK`/`WORKFLOW_TYPE`/`TASK_TYPE` to a mode the target agent does not declare |
| `CL101` | WARN | an agent declares a mode no command ever invokes |
| `CL102` | BLOCK | an invocation omits an input the declared mode marks required |
| `CL103` | WARN | an invocation passes an input token the declared mode declares nowhere |
| `CL104` | BLOCK | two agent files share a frontmatter `name:` |

CL100/CL102/CL103 skip an invocation whose target agent CL001 already flagged as unresolved --
one problem, one message. CL104 is independent of the other four: it fires while the disk-derived
agent inventory is built, the same way CL900/CL901 fire while the suppression index is built,
rather than in a later Phase B pass.

### CL2xx -- role and tool integrity

Tool allowlists enforce agent roles *structurally* -- the reviewer has no write tool, so it
cannot auto-fix. That guarantee is only as good as the prompt text agreeing with the frontmatter.

| Rule | Severity | Fires when |
|---|---|---|
| `CL200` | BLOCK | an agent with no write tool is instructed to write, append or create |
| `CL201` | BLOCK | an agent listed in `contractLint.readOnlyAgents` declares a write tool |
| `CL202` | WARN | an `mcp__*` name in scan scope is absent from `contractLint.knownMcpTools` |
| `CL203` | WARN | a non-write-capable agent's own frontmatter declares a tool its own body never mentions |
| `CL204` | BLOCK | a write-capable agent's own frontmatter declares a tool its own body never mentions |
| `CL205` | BLOCK | a command step inside a read-only agent's invocation block asserts a spec-artifact write and names no main-thread writer |
| `CL206` | BLOCK | a command listed in `contractLint.editToolOnly` never states its phrase: change the spec index / a spec status with the Edit tool only |

A **write tool** is exactly `Write`, `Edit` or `MultiEdit` -- never `Bash`, which technically can
write a file but is a different, harder problem, deliberately out of scope here.

`CL200` and `CL201` answer two different questions and read two different sources. `CL200` reads
**disk only**: any agent whose own `tools:` line lacks a write tool is a candidate, full stop, so a
brand-new read-only agent is protected on day one even if nobody remembers to list it anywhere.
`CL201` reads the **declared promise**: `contractLint.readOnlyAgents` names agents architecturally
committed to staying read-only, and `CL201` is the only rule that fires when one of them grows a
write tool in its own frontmatter -- the same declared-vs-disk shape `CL304` already uses for
conditional gates.

`CL200`'s imperative-verb scan is line-initial only (after an optional bullet or numbered-step
marker), which is what lets a negated instruction ("Do not attempt to write files"), a third-person
subject ("The calling command appends your output") and a mid-sentence use ("write `` `_No
findings._` ``, after a comma) all pass untouched, with no exclusion list -- the same shape
`Get-GateClassification`/`classify_heading` already uses for `## Gate activity`. It is the only
rule in this band that reads prose intent rather than pure structure, which is why it ships WARN
first: **CL200 promoted to BLOCK on 2026-07-31, once the engine tree ran clean under both
implementations.**

`CL203`/`CL204` search an agent's own **body** -- everything after its closing `---` -- for the
declared tool's exact name. A tool mentioned only inside the `tools:` line itself (its own
declaration) does not count as "used." They are two rule ids sharing one check because severity is
looked up from the manifest per rule id, never computed by a rule -- the same invariant that keeps a
BLOCK/WARN divergence between the bash and PowerShell twins structurally impossible (see
`docs/architecture.md` or either script's own header comment). `CL204` fires on a **write-capable**
agent: `Write`, `Edit` or `MultiEdit` present in that agent's *own* `tools:` line right now, read off
disk the same way `CL200` decides write-capability -- never `contractLint.readOnlyAgents`, which is
a declared promise about a fixed, named set of agents, not a live predicate over all of them. An unexplained,
unused write tool on the one class of agent that holds write power is the highest-value thing this
check can find, so it blocks; the same finding on a read-only agent's unused `Glob` stays WARN.

**`CL204` shipped BLOCK from its introduction on 2026-09-02** (SW-48) -- unlike `CL200`/`CL306`/`CL400`,
it did not need a WARN-first rollout window, because it is a new rule id rather than a promoted
existing one: nothing depended on its prior severity.

`CL205` is `CL200`'s command-side twin. `CL200` stops a read-only agent's own body from telling it
to write; `CL205` stops a *command* from asserting a write that the invoked read-only agent cannot
perform and that nobody else is told to perform either -- the SW-51 defect, where
`commands/rca.md` Phase 2 step 3 read "Hypothesis tree written to `00-spec.md`" two steps after
invoking `sd-debugger`, so Gate 2 could stop on an empty section. Three predicates, all
structural enough to decide by regex:

- **Window.** From an invocation anchor (the same index CL1xx uses) whose target agent has no
  write tool on disk, to the next heading or the next anchor. Unlike the CL1xx token span it does
  **not** end at a numbered step, because the defect lives in a later step of the same block.
- **Line.** Names a spec artifact (`NN-name.md` or `04-artifacts/`) *and* a word-bounded write
  form (write/append/save/record/persist/store and their inflections).
- **Actor.** Passes when `main thread` appears anywhere in the line's enclosing numbered step,
  joined across line wraps -- `commands/port.md` Phase 3 wraps "Main" / "thread appends" over two
  lines and names the actor in step 3's opening parenthetical. The phrase is the one every sibling
  step already uses ("Main thread appends the returned ... (debugger has no write tool)").

Its known blind spots are deliberate: a passive write inside a **write-capable** agent's block
(`rca.md` Phase 1's evidence step was one, fixed by hand in the same change) and a write that
names a spec section but no artifact file. Both stay prose-review territory; widening either
predicate buys false positives on legitimate close-out prose. `CL205` **shipped BLOCK from its
introduction on 2026-09-23** (SW-51) on the same grounds as `CL204`, and because
`contractLint.warnBudget` is `0`, a WARN would already have failed validate's Check 8.

`CL206` keeps the *prompt* half of the SW-79 fix from silently dropping out. In the e2e run that
found it, `/sd:feature` moved `draft -> approved -> in-progress` with `Bash` `sed -i` on
`.specs/index.md`: `spec-gate` never saw the writes, so Rules 0, 0b and 1 were sidestepped and two
`spec_transition` events were never recorded. Every command in `contractLint.editToolOnly.files`
must carry `contractLint.editToolOnly.phrase` ("with the Edit tool only - never a shell command")
on a non-fenced line, or wrapped across it and the next non-fenced line (joined as `CL009` joins).
The finding is a whole-file verdict on line 1, like `CL302`.

- **Declared, not inferred.** Whether a command writes the index is not decidable from prose, so
  the file list is written down. A command that starts writing the index or a status has to be
  added by hand; `verify` is left out on purpose (it writes only `06-verify.md`). A listed file
  that does not exist exits 2, like `gates`.
- **Blind spot.** It proves the sentence is there, not that the model obeys it. The hook half of
  SW-79 (`spec-gate`'s shell-write rule) is the backstop, and that is a text heuristic too.

`CL206` **shipped BLOCK from its introduction on 2026-09-25** (SW-79).

### CL3xx -- gate integrity

A **gate block** runs from its heading to the next heading of any level, or end of file. That
window is why the literal `STOP`s in Phase 0 bootstrap error paths never satisfy or
trip a gate rule -- they all sit under a `## Phase 0` heading.

| Rule | Severity | Fires when |
|---|---|---|
| `CL300` | BLOCK | a gate block contains no literal `STOP` |
| `CL301` | BLOCK | a gate block offers no option set |
| `CL302` | BLOCK | the hard gate count on disk disagrees with `contractLint.gates.<file>.hard` |
| `CL303` | WARN | hard gate labels are not exactly `1..N` without duplicates |
| `CL304` | BLOCK | a conditional gate is on disk but undeclared, or declared and absent |
| `CL305` | BLOCK | a HARD gate lists an override token as a selectable option |
| `CL306` | BLOCK | a HARD gate's prose describes an escape hatch with no `contract-lint: allow CL306` comment nearby |

An **option set** is a slash-separated parenthetical such as `(yes / revise / abort)`, or two or
more top-level `- ` bullets. `CL303` compares **sets, never file order**: `commands/bug.md` authors
`Gate 3a` before `Gate 3` and passes.

`CL305` is scoped to the gate's **option set**, never its prose. An override is a *listed choice*,
not a *described consequence* -- `commands/release.md` may say "the user may override the version
at this gate" without tripping it, while `(yes / skip / abort)` at a HARD gate fires.

`CL306` is the prose half CLAUDE.md rule 6 calls out by name ("describing one in prose is fine"):
it scans a HARD gate's remaining prose -- everything that is NOT the option-set parenthetical or a
backtick-led option bullet, since those are CL305's territory -- against
`contractLint.gateProseEscapeTokens`. It is deliberately a naive scanner, the same "reads prose
intent" tradeoff `CL200` already made: it fires on `commands/bug.md`'s logged insist-and-proceed
sentence and `commands/release.md`'s "may override the version" bullet until each is annotated with
its own `<!-- contract-lint: allow CL306 - <reason> -->` comment. There is no separate per-gate
declared-exception surface -- the existing suppression-comment convention already covers "this
gate's escape hatch is intentional," the same way it covers `CL305` on `commands/perf.md`, so a
second mechanism saying the same thing was not worth adding.

**`CL306` shipped WARN on 2026-07-30 and promoted to BLOCK on 2026-07-31, once the engine tree ran
clean under both implementations** -- the same rollout `CL200` used, for the same reason: it reads
prose intent, not pure structure.

Gate classification needs no exclusion list. `Gate` followed by a lowercase word is never a gate,
which is what makes `## Gate activity` in `commands/status.md` invisible to all six rules.

### CL4xx -- stack-agnostic prose

CLAUDE.md rule 4 says commands, agents and skills carry no hardcoded stack command or language
assumption -- everything comes from the target project's `project-config.json` at runtime. This
band is regression-prevention for that rule: it does not reach beyond `contractLint.scanScope`
(never `CLAUDE.md`, `CONTRIBUTING.md` or `docs/`, which is exactly why their known sandbox paths
and frontmatter examples need no special-case handling).

| Rule | Severity | Fires when |
|---|---|---|
| `CL400` | BLOCK | a stack command token (`contractLint.stackTokens.commands`) appears outside a `<<placeholder>>`, a fenced code block, or a `contract-lint: allow CL400` comment |
| `CL401` | WARN (permanent) | a language/framework name (`contractLint.stackTokens.languages`) appears in the same contexts |
| `CL402` | BLOCK | a hardcoded absolute filesystem path (a Windows drive letter, or a POSIX path with two or more segments) appears in scan scope |

A vocabulary hit is **word-bounded**: the character immediately before and after the token must not
itself be alphanumeric or `_`, so `npmrc` never trips on `npm` and `Going`/`algorithm` never trip on
the language token `Go`. `CL401` stays WARN permanently, unlike `CL400` -- a language name in prose
is often legitimate (an enumerated multi-stack heuristic, or the stack-agnostic rule's own
"never hardcode X" illustration), while a literal stack **command** is closer to an actual
instruction and is worth eventually blocking.

`CL402`'s absolute-path match requires a genuine word boundary immediately before the leading `/`
or drive letter (blank, backtick, quote, paren, or start of line) -- never another path or
placeholder character. Without that positive boundary, `~/.claude/hooks/sd/` and
`.specs/<ID>/04-artifacts/` would both mint a phantom absolute path starting at their own interior
`/`, and `/sd:<name>` would collide with the leading slash of every slash-command reference in the
engine (a `/prefix:name` command has no second `/`, so it never matches at all).

**`CL400` shipped WARN on 2026-07-30 and promoted to BLOCK on 2026-07-31, once the engine tree ran
clean under both implementations**, the same rollout `CL200`/`CL306` used. `CL401` and `CL402` do
not follow this schedule: `CL401` is permanent WARN by design, and `CL402` shipped BLOCK
immediately since a hardcoded absolute path is a structural fact, not prose intent.

### CL5xx -- retired (prompt size moved to a release-time report)

The band held one rule, `CL500`: a WARN when a file exceeded `contractLint.budgets.<area>Bytes`,
a ceiling set at each area's largest file. SW-57 retired it on 2026-09-24. The id stays
unused so an old reference cannot silently mean something else. The measured reasons are in
[ADR 0011](adr/0011-retire-cl500-byte-ratchet.md). In short: it had 8 budget raises in 6 commits
and 0 fires on any pushed commit. Every local fire was settled by raising the budget to the
file's exact new size in the same commit, and none led to a trim. Because only an area's largest
file set its ceiling, `commands/explore.md` grew 179% since the rule landed without ever being
checked.

The concern it guarded is real. A prompt file that grows past the point where the model
reliably reads all of it fails quietly: the instructions at the bottom stop being followed, with
no error. So that concern now lives in a report instead of a per-run check.

### Prompt size report

`scripts/prompt-size-report.{sh,ps1}` (twins, parity-tested by
`tests/prompt-size-report/run-parity.ps1`) compares every file in `contractLint.scanScope` with
the same path at a git ref. The default ref is the highest `v*` tag. The report prints one TSV
row per file (bytes before, bytes after, delta, percent), then a total for each area. A file
that grew more than `promptSizeReport.flagGrowthPercent` (15) is marked `FLAG`. The report is
advisory: it exits `0` whatever it finds, and `2` only when it cannot run.

```bash
bash scripts/prompt-size-report.sh                 # since the latest release tag
bash scripts/prompt-size-report.sh --since v1.5.0  # any ref
```

**The byte count is normalized, never a raw disk read.** This is the measure `CL500` used: CR
bytes are dropped and one trailing LF is not counted. `contractLint.scanScope` is `text=auto`
(see `.gitattributes`), so identical content checks out as LF on Linux and as CRLF on a native
Windows checkout. On this repo, `commands/spec.md` measured 25979 bytes as a git blob and 26521
bytes on Windows. A raw count would make the two twins disagree.

**Cadence.**

- **When:** at every minor release, in the same pass as the threshold calibration
  (`CONTRIBUTING.md`, "Threshold re-calibration" and "Prompt size report"). There is no
  per-PR run and nothing to bump.
- **What is normal:** most files show less than 5% change, and a few grow because a feature
  landed in them. A release that adds a whole workflow can move one area's total by 20-40%.
- **What needs action:** each `FLAG` row needs one line in that release's `CHANGELOG.md`
  section: either "trimmed" (with the follow-up ticket) or the reason the growth is worth
  its cost. The same applies to a file that has grown in three releases in a row, which you
  can see by re-running `--since` against the older tags.
- **Signs the mechanism has stopped working**, and a new ADR should revisit it:
  - the report is skipped for two releases in a row;
  - every `FLAG` across two releases is justified and none is ever trimmed, which is the
    same reflexive-bump pattern that retired `CL500`;
  - the threshold is raised to make a release come out clean.

### CL6xx -- escalation policy

`skills/sd-model-escalation/SKILL.md` owns the model escalation policy in prose: the ladder, the
trigger table, the precedence rules and the `05-retro.md` line format. `contractLint.escalationTriggers`
is the table's assertable copy, one row per rule ID (`id`, `command`, `phase`, `agent`, `from`,
`to`), and `contractLint.escalationPolicy` declares the ladder, the alias set and CL605's phrase
vocabulary. Added by SW-63; the decision record is [ADR 0014](adr/0014-escalation-policy-lint.md).

| Rule | Severity | Fires when |
|---|---|---|
| `CL601` | BLOCK | a command invokes an agent but no `escalationTriggers` row targets it and no `allow CL601` comment covers the first invocation; or it has rows but never references `sd-model-escalation`; or it never names one of its own rows (a row is live only when its command cites it) |
| `CL602` | BLOCK | the manifest rows and the skill's trigger table disagree: an id in one and not the other, a shared id whose command, agent, from or to differ, a `phase` whose leading digits differ from the id's, a duplicate id; or a scan-scope file outside the skill cites an `ESC-` id no row declares; or the skill exists and `escalationTriggers` is absent or empty |
| `CL603` | BLOCK | a row's `from` or `to` is not in `escalationPolicy.aliases` -- a full model ID entering through the escalation path |
| `CL604` | BLOCK | `escalationPolicy.ladder` differs from the skill's `## Ladder` line, or a row's tiers are not exactly one rung apart on it (`inherit` is an alias, not a rung) |
| `CL605` | BLOCK | a command line contains an `escalationPolicy.restatePhrases` entry: the ladder, the retro line format or a precedence rule restated instead of cited |

**The band switches on when the skill exists on disk,** not when the manifest keys do. Deleting
`escalationTriggers` or `escalationPolicy` therefore fails CL602-CL605 rather than silently turning
the checks off -- the defect SW-20 found in the selftest. The skill name is a constant in both
linters for the same reason. Manifest-side findings land on `specwright.manifest.json` line 1;
that file is outside `scanScope`, so no suppression can reach them.

**Invocation detection is CL1xx's**, not a second parser: a command line indexed as an `sd-`
reference whose text contains "nvoke", filtered to agent names. CL601 reports on the first such
line, so a one-line `allow CL601` comment directly above it is the exemption.

**CL605 does not skip fenced lines.** A fenced retro-line example in a command is exactly the
restatement the rule exists for. It uses CL009's two-line wrap window, so a ladder fragment split
across a line break still fires, once.

**Allow comments taken: 3**, each deciding that a workflow has no escalation row rather than
forgetting one:

| Command | Agent | Reason |
|---|---|---|
| `commands/adr.md` | `sd-docs-writer` | one drafting call per ADR, re-run only on a user edit, and no spec frontmatter to read a trigger from |
| `commands/explore.md` | `sd-code-explorer` | one read-only call per run, and no `00-spec.md` exists in either branch |
| `commands/review.md` | `sd-reviewer` | one read-only call per run, and modes A/B/D have no spec frontmatter |

A fourth `allow CL601` should arrive with its own reason in the PR that adds it, and this table
should grow a row.

**What green does NOT prove.** CL6xx checks that the policy is *stated* consistently. It cannot
check that a subagent *ran* on the escalated model: that is behavioral, and the e2e harness cannot
assert it today (ADR 0014 records why). `scripts/validate-escalation-lines.{sh,ps1}` closes the
gap one step further by checking the `escalation:` lines a real run wrote into `05-retro.md`
against the same manifest rows -- still a statement, the main thread's own, not a served-model
attribution.

### CL9xx -- suppression hygiene

| Rule | Severity | Fires when |
|---|---|---|
| `CL900` | BLOCK | a suppression carries no usable reason |
| `CL901` | BLOCK | a suppression names a rule id absent from the registry |
| `CL902` | WARN | a suppression suppressed nothing |

## Suppressions

```
<!-- contract-lint: allow CL305 - Case A is the already-at-goal branch, and the option there buys a logged constitution exception rather than a way past the requirement -->
```

It applies to a finding of that rule, in that file, on the same line or the next one. Indexed only
inside `contractLint.scanScope` and only outside fenced code blocks, so this page and
`CONTRIBUTING.md` can show the syntax without minting a phantom suppression that then trips CL902.

**A suppression can never suppress CL900, CL901 or CL902.** That exclusion is hardcoded in both
implementations rather than manifest-driven, because `<!-- contract-lint: allow CL900 -->` would
otherwise be a self-authorizing loophole.

The reason is not decoration. CL900 rejects anything under ten non-separator characters, so
"`- x`" fails and the writer has to say why.

## Manifest surface

Everything configurable lives under one top-level `contractLint` key, so later waves nest inside it
and never touch `areas`, `derived` or `docClaims`.

| Key | Purpose |
|---|---|
| `scanScope` | globs the linter reads. Deliberately `commands/`, `agents/`, `skills/` and nothing else |
| `installNamespaceSegment` | the `sd` in `templates/sd/...`, folded away before CL005 tests disk |
| `rules` | the registry: id, severity, wave, summary. The one source of severity |
| `gates` | per file: the declared hard count, the declared conditional labels, and the Check 7 quantity name |
| `specArtifacts` | the numbered artifact filenames CL008 accepts |
| `skillConsumers` | skills whose only consumers live outside scan scope, with the reason |
| `overrideOptionTokens` | the vocabulary CL305 treats as an escape hatch |
| `gateProseEscapeTokens` | the phrase vocabulary CL306 scans HARD gate prose for |
| `bootstrapGuardPhrases` | the phrase vocabulary CL009 scans a command's `## Phase 0` section for |
| `editToolOnly` | CL206's contract: `phrase` plus the `files` that must state it (optional; absent means CL206 checks nothing) |
| `stackTokens.commands` / `.languages` | the CL400 / CL401 stack vocabulary |
| `readOnlyAgents` | agent names CL201 checks for a write tool gained since being declared read-only |
| `knownMcpTools` | the `mcp__*` allowlist CL202 checks scan-scope tokens against |
| `escalationTriggers` | the assertable copy of `sd-model-escalation`'s trigger table, read by CL601-CL604 and by `scripts/validate-escalation-lines.*` |
| `escalationPolicy` | `ladder` (CL604), `aliases` (CL603) and `restatePhrases` (CL605) |
| `warnBudget` | max standing WARN count (excluding CL202) `scripts/validate.{sh,ps1}` Check 8 allows before failing - a ratchet, checked by validate, not by the linter itself |

`scanScope` is load-bearing. `CLAUDE.md` and `CONTRIBUTING.md` use `sd-test` as a sandbox path and
`docs/architecture.md` carries a `name: sd-debugger` frontmatter example, so widening the scope to
`docs/**` produces a wall of CL001 false positives on day one.

### Why the manifest stores a gate count

The manifest's own charter says it stores no counts, and `gates.<file>.hard` is a literal number.
The test that resolves it:

> Can a script count it from disk with no judgement calls?
> **Yes** -- it is inventory, it belongs in `areas`, and it must be derived.
> **No** -- it is a declared design contract, and it belongs in `contractLint`.

"How many command files exist" passes that test. "How many hard gates `/sd:feature` declares" does
not: nothing on disk is a second source for it, so a derived value would make CL302 compare disk
against itself and pass vacuously forever. The number's job is to make deleting a gate heading a
deliberate two-file edit that shows up in review.

Feeding those counts into Check 7 as quantities gives `README <- manifest` there and
`manifest <- disk` here, hence transitively `README == disk`, with no gate parser duplicated into
`scripts/validate.*`.

## Waves

Wave 1 is what ships here. Later waves are pure additions: one registry entry, one function per
implementation, one fixture, one row in the tables above.

| Wave | Band | Status |
|---|---|---|
| 1 | CL0xx reference resolution, CL3xx gate integrity, CL9xx suppression hygiene | shipped, BLOCK (CL009 added 2026-09-24, BLOCK from the start) |
| 2 | CL1xx invocation contract (agent input declarations) | shipped, BLOCK+WARN |
| 3a | CL2xx role and tool integrity (CL200-CL206) | shipped, BLOCK (CL200 promoted from WARN; CL202/CL203 stay WARN; CL204 added 2026-09-02, CL205 2026-09-23 and CL206 2026-09-25, all BLOCK from the start) |
| 3b | CL4xx stack-agnostic prose, CL306 | shipped 2026-07-30 WARN, now BLOCK (CL400/CL306 promoted 2026-07-31; CL401 stays WARN) |
| 4 | CL5xx file budgets | shipped 2026-07-30, retired 2026-09-24 (SW-57) - see the prompt size report |
| 5 | CL6xx escalation policy (CL601-CL605) | shipped 2026-09-26 (SW-63), BLOCK from the start |

Four scope decisions were made deliberately and are recorded here so they read as decisions
rather than oversights:

- **CL007 is still loose.** "Invoked by" means any mention of the agent name in a command body.
  CL100-CL104 added a real invocation-token parser but did not fold it back into CL007 -- CL007
  answers "is this agent mentioned at all", CL1xx answers "does a specific mode match", and
  merging them would make CL007 depend on the mode-selector convention (`TASK`/`WORKFLOW_TYPE`/
  `TASK_TYPE`) instead of a plain name match.
- **CL006 does not scan `hooks/`,** although `/sd:` references live there. That remains a future
  scope extension.
- **CL1xx recognizes exactly three mode-selector keys** (`TASK`, `WORKFLOW_TYPE`, `TASK_TYPE`) --
  the ones actually on disk. An invocation that sets none of them (`sd-docs-writer`'s flat
  `ADR_NUMBER`/`ADR_PATH`/... contract, which has no modes at all) is invisible to CL100-CL103 by
  design, not by omission.
- **`knownMcpTools` is hand-maintained, not derived**, and that is a deliberate acceptance of
  staleness risk: nothing on disk is a second source for which `mcp__*` tool names are real, since
  that comes from runtime MCP server configuration this repo cannot see. `CL202` stays WARN
  forever precisely because of this -- a stale allowlist must never be able to block CI. A `CL202`
  hit means "update this list or explain why not," never "suppress and move on."
- **`CL401` stays WARN permanently**, unlike its `CL400`/`CL402`/`CL306` siblings -- a language or
  framework name in prose is often legitimate (an enumerated multi-stack heuristic, or the
  stack-agnostic rule's own "never hardcode X" illustration), so the same false-positive band that
  makes `CL400`/`CL306` promotable makes `CL401` a permanent-WARN rule by design, the same
  precedent `CL202` already set for `knownMcpTools`.
- **`CL400`/`CL401`/`CL402` never widen `scanScope`**, on purpose. `CLAUDE.md`, `CONTRIBUTING.md`
  and `docs/architecture.md` all carry sandbox paths, stack names and a frontmatter example that
  this band would otherwise light up on day one -- exactly the risk `scanScope`'s own comment
  already documents for `CL0xx`. Staying inside `commands/`, `agents/`, `skills/` is what lets the
  positive-boundary path regex and the word-bounded vocabulary match stay this simple.
- **`CL306` reuses the existing suppression comment instead of a new declared-exception surface.**
  A `contractLint.gates.<file>.proseExceptions` key was considered (a per-gate list of allowed
  escape-hatch labels) and rejected: it would say the same thing `<!-- contract-lint: allow CL306 -
  <reason> -->` already says, just in a second place that could drift out of sync with the first.

## Testing it

`tests/contract-lint/` holds the fixture suite; see its README for the case map and for what to do
when adding a rule. The load-bearing assertions are the fixture sweep and the line-for-line
comparison of the two implementations on every case.
