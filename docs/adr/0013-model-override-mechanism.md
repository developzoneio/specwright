# ADR 0013: model override - the Agent tool honors a per-invocation `model` (Verdict A)

- Status: accepted (mechanism level); workflow-level confirmation open - see "Open item"
- Date: 2026-09-25
- Source spec: Jira SW-72 (follow-up to SW-59, whose deliverable was never committed)
- Relates to: ADR 0002 (complexity triage - asserts the architect override); SW-60
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
or when a release note changes subagent model resolution. Repeat the method above and compare
against the tables.

## Open item - workflow-level confirmation

Verdict A shows the mechanism works. It does not show that `/sd:feature` *uses* it: that a model
reading `ESC-FEAT-04` actually puts `model` in the Agent call rather than only writing the retro
line. That needs the real workflow, as SW-72's method describes:

- L run: e2e scenario 06 as shipped (T01 `Estimated complexity: L`). Expect T01's
  `sd-implementer` subagent `meta.json` to carry `"model":"sonnet"` and serve `claude-sonnet-*`,
  and T02 to carry no `model` and serve `claude-haiku-*`.
- Control run: the same workspace with T01 set to `S`. Expect both implementer subagents on haiku
  with no `model`.
- The same pair for a spec with `complexity: L` vs `M` through Gate 2, for `ESC-FEAT-02/03`.

This was not run for this ADR. The workflow needs `--dangerously-skip-permissions` (scenario 06
already uses it, to run `npm test` unattended), and that was not approved in the session that
wrote this ADR. Until it runs, the SW-61 retro line remains self-report for the workflow path. If
the run shows no `model` in the escalated call's `meta.json`, the verdict for the *workflow* is B
even though the mechanism is A. Fix the prompt text in `commands/feature.md` / the skill, not the
mechanism.

Harness note: `tests/e2e/run-e2e.ps1` passes `--no-session-persistence`, so `SD_E2E_KEEP=1` keeps
the fake home but writes **no transcript**. A workflow-level run for this item must invoke
`claude -p` without that flag. The harness itself should keep it, because per-scenario transcripts
are not needed for artifact assertions.

## Consequences

- ADR 0002's "per-invocation main-thread override" is no longer an assumption at the mechanism
  level.
- The `unapplied` fallback in `sd-model-escalation` stays. It covers hosts or future versions
  where the parameter is dropped, and costs nothing when the override works.
- The rejected Verdict B alternatives from SW-59 (`model: inherit` plus an advisory stop; an
  `sd-spec-architect-deep` duplicate agent) are not needed.
