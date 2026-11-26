# sd-model-escalation - /sd:port and /sd:explore --port

The `/sd:port` rows of the **sd-model-escalation** trigger table, and how they are decided.
`/sd:explore --port` reads this file too: it is the donor-side call site of `ESC-PORT-01`. Read
`SKILL.md` first: the ladder, the invariants, how the override is applied, the precedence rules
and the logging contract live there and are not restated here. Why each row exists is in
`rationale.md`, which no workflow reads at runtime.

## Trigger table

| Rule ID | Workflow | Where | Condition | Agent | From | To |
|---|---|---|---|---|---|---|
| `ESC-PORT-01` | `/sd:port` | Phase 1 Branch B step 1, before `TASK = port-extract`; also `/sd:explore --port` Phase 2, the donor side of a bridged port | `GITNEXUS_AVAILABLE` is `false` (the closure walk falls back to recursive grep), or `SCOPE` is `module` or `feature` | `sd-code-explorer` | `haiku` | `sonnet` |
| `ESC-PORT-06` | `/sd:port` | Phase 6 step 2, before the plan | the Phase 6 step 1 port decompose metric (deviation rows requiring adaptation) is more than 8 | `sd-spec-architect` | `sonnet` | `opus` |

## Decision points

**Decided before the spec exists (`ESC-PORT-01`).** The extraction runs before its spec
directory exists, so this row is the one exception to "write the line before the invocation".
It is decided once per extraction, and the line is written when the spec is registered. In
`/sd:port` Branch B (`in-repo`) the main thread holds its own decision until then. In a bridged
port the decision is made by `/sd:explore --port` in the donor repo, which has no spec: it records
the line in the bundle's `contract.md` frontmatter as `escalation_line` (`none` when no line is
due), and `/sd:port` Branch A copies it verbatim into the new spec's `05-retro.md`. A run that
stops before the spec is registered re-runs Phase 1 and decides afresh, so no line is lost or
doubled. A bundle with no `escalation_line` key predates this rule and carries nothing.

**No row, decided (SW-86).** `/sd:port` Phase 5 and Phase 7 `sd-implementer` calls keep the
default. Each task reproduces a cited donor member range; the judgment a port needs - which
departures to license - is made in the deviation table and the plan, which `ESC-PORT-06` already
escalates. A task outside its member range or deviation rows fails the Phase 7 self-check instead.
