# ADR 0013: model override - the Agent tool honors a per-invocation `model` (Verdict A)

- Status: accepted (mechanism and workflow level)
- Date: 2026-09-25
- Source spec: Jira SW-72 (follow-up to SW-59, whose deliverable was never committed)
- Relates to: ADR 0002 (complexity triage - asserts the architect override); SW-73 (e2e sandbox
  isolation on Windows, found here); SW-60
  (`skills/sd-model-escalation/SKILL.md`, rules `ESC-FEAT-02/03/03b/04/04b`); SW-61 (implementer
  override, e2e scenarios 06 and 07)
- Supersedes: none

## Context

ADR 0002 and the `sd-model-escalation` skill assume the main thread can invoke a subagent with a
model other than the one in its frontmatter. Nothing in the repo had observed that. SW-59 was
opened to rule out a silent no-op and was closed without its ADR. The only later evidence, SW-61's
scenario 06 run, is the model's own retro line ("T01 ... Implementer model: sonnet"). That is
self-report: a model that believed it escalated while the tool ignored the parameter would write
the same line.

This ADR records what the model *actually served* for each subagent call, read from the session
transcript, with a control call for every override.

## Method

- Claude Code `2.1.282`, Linux, headless `claude -p`.
- Sandbox only: `install/install.sh --base-path <sandbox>/home/.claude`, `HOME` pointed at the
  sandbox, `--setting-sources project`, `--add-dir <sandbox>/home`, `--permission-mode dontAsk`.
  The real `~/.claude/` was not touched.
- Session persistence left **on**. The main thread was told to make a fixed list of Agent tool
  calls, each prompted "Reply with the word PONG and nothing else. Do not use any tools." Each
  override call is paired with a control call to the same agent with no `model` parameter.
- Evidence source: `<sandbox>/home/.claude/projects/<workspace>/<session>/subagents/`.
  - `agent-<id>.meta.json` holds the tool input as the CLI received it (`agentType`, `model`).
  - `agent-<id>.jsonl` holds the subagent's API turns. `message.model` on each `assistant` line
    is the model named in the API response, not in the prompt, so the subagent cannot misreport
    it.
- Second-best cross-check: `modelUsage` in the `--output-format json` result (per-model token
  counts, the headless equivalent of `/cost`).

Extraction, per subagent:

```bash
jq -c '{agentType, model}' agent-<id>.meta.json
jq -r 'select(.type=="assistant") | .message.model' agent-<id>.jsonl | sort -u
```

## Evidence

Probe 1, session `61929709-7416-44d2-a75f-2a1680624424`, under
`.claude/projects/<ws>/61929709-7416-44d2-a75f-2a1680624424/subagents/`:

| File | `meta.json` | `message.model` served |
|---|---|---|
| `agent-ac7c7683bb629c970` | `{"agentType":"sd-implementer","model":"opus"}` | `claude-opus-5-5` |
| `agent-ad084569b409a95db` | `{"agentType":"sd-implementer","model":null}` (control) | `claude-haiku-4-5-20251001` |

Probe 2, session `96c27cd9-b3ba-4cd2-bc9a-edcd1a7a598b`, same layout:

| File | `meta.json` | `message.model` served |
|---|---|---|
| `agent-a53dcc1331183afdb` | `{"agentType":"sd-spec-architect","model":"opus"}` | `claude-opus-5-5` |
| `agent-aca279b5c81569ce6` | `{"agentType":"sd-spec-architect","model":null}` (control) | `claude-sonnet-5` |
| `agent-a7e299aa05bac5a4f` | `{"agentType":"sd-code-explorer","model":"sonnet"}` | `claude-sonnet-5` |
| `agent-aca309907bdcf2d7d` | `{"agentType":"sd-code-explorer","model":null}` (control) | `claude-haiku-4-5-20251001` |

Every override call ran on the requested tier, and every control ran on its frontmatter tier
(`implementer`/`code-explorer` `haiku`, `spec-architect` `sonnet`). Probe 2's `modelUsage`
listed all three models (`claude-sonnet-5` 723, `claude-opus-5-5` 5, `claude-haiku-4-5-20251001`
66 output tokens), which is consistent with the transcripts. The signal is the delta between each
pair, not any single reading. These pairs cover all three edges the skill uses: explorer
haiku->sonnet (`ESC-FEAT-02`), architect sonnet->opus (`ESC-FEAT-03/03b`) and implementer
haiku->sonnet (`ESC-FEAT-04/04b`; opus was tested, a stricter case of the same edge).

The sandbox transcripts were in an ephemeral session container and are not committed. The
identifiers above are recorded so a re-run can be compared line by line.

## Decision

**Verdict A - override honored.** The Agent (Task) tool's `model` parameter overrides the agent
frontmatter `model` for that invocation, and the override is visible in the served model. No
special phrasing is needed (so not Verdict C): the parameter is structured tool input, not prompt
text. SW-60's definition of the mechanism stands, and epic SW-58 proceeds as scoped. No BUG
ticket is reserved.

Re-check this ADR when the pinned minimum Claude Code version in `tests/e2e/README.md` is raised,
or when a release note changes subagent model resolution. The mechanism probe is the method above.
The workflow probe is `tests/e2e/probe-model-override.ps1` (`-Case feat04|feat03|all`, about
USD 4 per run, 2 runs per case). It is manual and paid, and is not part of `run-e2e.ps1` or CI.

## Workflow-level evidence

Verdict A above is about the mechanism. Separately, `/sd:feature` has to *use* it: a model reading
`ESC-FEAT-0x` must put `model` in the Agent call, not only write the retro line. That was checked
with `tests/e2e/probe-model-override.ps1`, which pairs an L run with a control run through the real
workflow and applies the same `meta.json` / `message.model` extraction as above.

- Claude Code `2.1.282`, Windows, 2026-09-25. The runs used `--dangerously-skip-permissions`, like
  e2e scenario 06. Output dirs: `C:\sw72-20260925-130826` (`feat04`) and
  `C:\sw72-20260925-131314` (`feat03`), each with `sw72-report.md`. These are on the developer's
  machine and are not committed.
- `feat04`: scenario 06 as shipped (T01 `Estimated complexity: L`, T02 `S`) vs. the same
  workspace with T01 set to `S`.
- `feat03`: scenario 06's spec reseeded as `draft` with `complexity: L` vs. `M`. The escalation
  `ceiling` was raised to `opus`, because scenario 06 pins `sonnet`, which caps `ESC-FEAT-03`. The
  runs went through Phase 2 and 3 and stopped at Gate 2.

| Case | Run | `sd-*` subagent | `model` param | Served |
|---|---|---|---|---|
| `feat04` | L | `sd-implementer` (T01) | `sonnet` | `claude-sonnet-*` |
| `feat04` | L | `sd-implementer` (T02) | none or `haiku` | `claude-haiku-*` |
| `feat04` | control | every `sd-implementer` | none or `haiku` | `claude-haiku-*` |
| `feat03` | L | `sd-code-explorer` | `sonnet` | `claude-sonnet-*` |
| `feat03` | L | `sd-spec-architect` | `opus` | `claude-opus-*` |
| `feat03` | control | every `sd-code-explorer` | none or `haiku` | `claude-haiku-*` |
| `feat03` | control | every `sd-spec-architect` | none or `sonnet` | `claude-sonnet-*` |

All seven checks passed. `ESC-FEAT-02`, `ESC-FEAT-03` and `ESC-FEAT-04` are applied by the
workflow, and each call is served on the escalated tier. `ESC-FEAT-03b` and `ESC-FEAT-04b` were
not exercised. They use the same Agent-call step, so they rest on the same evidence, but no run
triggered them.

### Findings from getting there

1. **Self-report was wrong, and would have passed review.** The first Windows run (see finding 2)
   served both control implementers on `claude-sonnet-5`. The main thread's closing message in
   that transcript (line 79) said "Both tasks ran at **haiku**". This is the failure SW-59 and
   SW-72 were opened to catch. A retro line or summary is not evidence of the served model; only
   `message.model` is.
2. **The sandbox was not isolated on Windows (SW-73).** The first runs used `%TEMP%`, which is
   under the user profile. With no git root to stop it, Claude Code loads every ancestor `.claude/`
   as *project* scope, and project scope outranks the fake home. So the developer's real
   `~/.claude` was loaded: a stale `sd-implementer` with `model: sonnet`, and a personal skill.
   This was reproduced on Linux with an ancestor `.claude/agents/sd/implementer.md`. It was served
   sonnet with no `.git`, and haiku with `git init` in the workspace. The probe now defaults
   `-OutDir` to the drive root and refuses any `-OutDir` with a `.claude` above it.
   `tests/e2e/run-e2e.ps1` had the same gap. SW-73 fixed it the same way: its sandbox root is
   `<SystemDrive>\sd-e2e` on Windows, and the preflight exits `2` if a `.claude` sits above the
   root. Re-checked on Windows at commit `82d1394`, 2026-09-25: scenario 06 passed under
   `C:\sd-e2e`, and a `feat04` probe re-run (`C:\sw72-20260925-140307`) served every
   `sd-implementer` call that had no `model` parameter on `claude-haiku-4-5-20251001`. The
   developer's real `~/.claude/agents/sd/implementer.md` still had the stale `model: sonnet`
   during that run, so the conflicting agent was present and did not leak in.
3. **Line endings are not a factor.** LF and CRLF agent frontmatter both resolved `model: haiku`,
   on Linux and on Windows. `*.md` is not pinned to LF in `.gitattributes`, and that is fine.
4. **Resume skips `ESC-FEAT-02`.** `commands/feature.md`'s state machine sends `approved` with no
   `02-tasks.md` straight to Phase 3, so a spec resumed from `approved` never runs Phase 2 or its
   escalation check. The `feat03` case starts from `draft` to avoid this. Fixed in SW-74: the
   state machine now resumes `approved` at Phase 2 unless `03-decisions.md` already has the
   explorer's `## Impact analysis (sd-code-explorer)` heading.
5. **Harness transcripts.** `run-e2e.ps1` passes `--no-session-persistence`, so `SD_E2E_KEEP=1`
   keeps the fake home but writes no transcript. The probe omits that flag on purpose. The harness
   should keep it, because artifact assertions do not need transcripts.

## Consequences

- ADR 0002's "per-invocation main-thread override" is no longer an assumption, at either level.
- A served-model claim needs `message.model` from a transcript. A `--no-session-persistence`
  run cannot provide it, and a model's summary does not count.
- On Windows, any sandbox under the user profile reads the real `~/.claude` (SW-73). Both
  `run-e2e.ps1` and the probe now keep their sandboxes outside the profile and refuse a root with
  a `.claude` above it.
- The `unapplied` fallback in `sd-model-escalation` stays. It covers hosts or future versions
  where the parameter is dropped, and costs nothing when the override works.
- The rejected Verdict B alternatives from SW-59 (`model: inherit` plus an advisory stop; an
  `sd-spec-architect-deep` duplicate agent) are not needed.
