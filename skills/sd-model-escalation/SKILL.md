# sd-model-escalation

Model escalation policy for specwright workflows: when the main thread invokes a subagent one model
tier above its frontmatter default. This file is the single owner of the ladder, the invariants,
the trigger table, the precedence rules, the logging contract and the rule IDs. Commands read it
at runtime (they cannot load skills via frontmatter) and state only a rule ID and its trigger
inputs - never the policy itself. `sd-spec-architect` and `sd-implementer` load it via `skills:`
so they know what the main thread may do to their own invocation.

Origin: ADR 0002 ("Sanctioned model escalation, aliases only"), shipped for `/sd:feature` by SW-13
and extracted here by SW-60.

---

## Ladder

`haiku -> sonnet -> opus`. One tier per escalation, never a skipped rung.

`inherit` is not a rung. It is a separate mode in which the agent follows the session model; an
`inherit` agent is never escalated, and no trigger row may name one.

## Invariants

1. **Aliases only.** `haiku`, `sonnet`, `opus` - never a version-pinned model ID, anywhere, under
   any circumstance: not in a command, not in a retro line, not in project-config.
2. **Per-invocation main-thread override.** The main thread raises the model on one subagent
   invocation. An agent's `model:` frontmatter is never edited to escalate.
3. **No persistence.** An escalation covers exactly one invocation. The next invocation of the
   same agent - a `refine`, a later phase, a re-plan - starts at its frontmatter default again
   unless a row fires for it in its own right.

## How the override is applied

Pass the reached alias as the `model` parameter of the subagent-invocation tool (Task / Agent).
Claude Code documents that parameter as taking precedence over the agent's `model:` frontmatter.
A model named only in the prompt text is **not** an override - the tool resolves the model from
its parameter and the frontmatter, not from prose - so never "ask" the subagent to be a different
model.

If the invocation tool exposes no `model` parameter, the override cannot be applied. Invoke at the
default and log the decision with the `unapplied` suffix (see Logging contract). Never report an
escalation that did not take effect.

---

## Trigger table

One row per escalation point. `From` is the agent's frontmatter default; `To` is one rung up. A
row is live only when the command named in it references its rule ID - rows are added here, and
nowhere else, by the story that wires them.

| Rule ID | Workflow | Where | Condition | Agent | From | To |
|---|---|---|---|---|---|---|
| `ESC-FEAT-02` | `/sd:feature` | Phase 2 step 0, before the impact map | spec `complexity` (`00-spec.md` frontmatter) is `L` | `sd-code-explorer` | `haiku` | `sonnet` |
| `ESC-FEAT-03` | `/sd:feature` | Phase 3 step 0, before the plan | spec `complexity` is `L` | `sd-spec-architect` | `sonnet` | `opus` |
| `ESC-FEAT-03b` | `/sd:feature` | Gate 2 Face B, on `no-split` | `ESC-FEAT-03` did not fire for this plan (the `L` estimate under-called it); re-invoke Phase 3 once | `sd-spec-architect` | `sonnet` | `opus` |

Why each row exists:

- `ESC-FEAT-02` - a create-time `L` is exactly the multi-subsystem case where the shallow haiku
  impact map degrades.
- `ESC-FEAT-03` - single-pass planning is where large scope degrades non-linearly.
- `ESC-FEAT-03b` - the user accepted one oversized plan instead of a split; that plan must come
  from the escalated architect, so a plan written at the default is re-done once, escalated.

**Rule ID format.** `ESC-<WORKFLOW>-<PHASE>` with an optional lowercase suffix (`b`, `c`) for a
second row at the same phase. `<WORKFLOW>` is the spec prefix (`FEAT`, `BUG`, `REF`, `PERF`,
`RCA`, `PORT`). An ID is stable: once shipped it is never renumbered or reused, because retro
lines already written name it.

**Two different `complexity` fields.** A spec-level `complexity` (`00-spec.md` frontmatter) and a
task-level `Estimated complexity` (a `02-tasks.md` task block) are different fields. Every row
names the one it reads; a row that reads the task field gets its own rule ID.

---

## Precedence rules

Read `models.escalation` from the project-config the calling command already parsed in Phase 0.
Evaluate in order; the first rule that decides, decides.

1. **`models.escalation.enabled == false` suppresses everything.** No trigger fires, no override is
   applied, no retro line is written.
2. **`models.escalation.ceiling` caps the ladder.** A row whose `To` is above the ceiling reaches
   the ceiling instead - never below the row's `From`, because escalation never lowers a model.
   A capped escalation is not a skipped one: it is logged with the `capped` suffix. When the cap
   leaves the tier unchanged and the row's action is a re-invocation (`ESC-FEAT-03b`), the
   re-invocation is not run - it would reproduce the same plan - but the capped line is still
   written.
3. **Otherwise the trigger table applies.** A row fires when its condition holds at its `Where`
   point; a row whose condition does not hold writes nothing.
4. **Absent keys mean defaults.** No `models.escalation` block, or a block missing a key, reads as
   `enabled: true`, `ceiling: "opus"` - a project scaffolded before this policy behaves exactly as
   it did.

An invalid value - `enabled` that is not a boolean, or a `ceiling` outside `haiku` / `sonnet` /
`opus` (including `inherit` or a pinned ID) - is never guessed at. WARN once:
"`models.escalation` has an invalid value - escalation disabled for this run." and treat the run
as rule 1. The cheaper reading is the safe one; a typo never buys a more expensive model.

---

## Logging contract

Every decision that fires - applied, capped or unapplied - appends exactly one line to the spec's
`05-retro.md`, written by the main thread (subagents do not write it). Create the file if missing;
never overwrite existing content. Write the line when the decision is made, before the invocation.

```text
escalation: <agent> <from> -> <to> (trigger: <rule-id>)
escalation: <agent> <from> -> <reached> (trigger: <rule-id>) capped
escalation: <agent> <from> -> <to> (trigger: <rule-id>) unapplied
```

- `<agent>` is the namespaced agent name (`sd-spec-architect`), `<from>` / `<to>` / `<reached>` are
  aliases, `<rule-id>` is a Rule ID from the trigger table.
- `capped`: `<reached>` is the tier the ceiling allowed, which may equal `<from>`.
- `unapplied`: the tool had no `model` parameter; the invocation ran at `<from>`.
- No line is written for a row whose condition did not hold, or when `enabled` is `false`.

This line is the only runtime evidence the policy executed. A run that should have escalated and
left no line is indistinguishable from the policy not running.

Example - a `complexity: L` spec under `ceiling: "sonnet"`:

```text
escalation: sd-code-explorer haiku -> sonnet (trigger: ESC-FEAT-02)
escalation: sd-spec-architect sonnet -> sonnet (trigger: ESC-FEAT-03) capped
```

---

## Non-goals

- Selecting the main-session model. The policy escalates subagents only.
- Changing decomposition thresholds - `/sd:feature` Gate 2 and ADR 0004 own those.
- Invoking anything. The calling command invokes; this file decides the model for that invocation.

## Anti-patterns

- Restating the ladder, a precedence rule or the retro line format in a command. Reference the
  rule ID and state its trigger inputs; the policy stays here.
- Escalating two tiers at once, or escalating a second time on the same invocation.
- Editing an agent's `model:` frontmatter "just for this spec".
- Treating a capped or unapplied escalation as not worth logging.
