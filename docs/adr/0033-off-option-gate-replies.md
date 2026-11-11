# ADR 0033: a gate reply outside the offered options is refused, not mapped

- Status: accepted
- Date: 2026-11-02
- Source spec: Jira SW-124 (split out of SW-123; E12 / SW-87)
- Relates to: ADR 0019 (reply language); ADR 0021 (stop-gate deny list); ADR 0029 and ADR 0032
  (the per-workflow token lists); `skills/sd-gate-brief/SKILL.md` (the rule)
- Supersedes: none. Extends ADR 0021 decision "the hook lists the tokens that do not approve".

## Context

In the SW-122 live runs of e2e `17-port-gate-brief`, `/sd:port` Gate 5 asked
`(continue / details <target> / abort)` and the scripted reply was `yes`, meant for Gate 6. The
model took `yes` to mean `continue` and moved on. The guess was harmless there. At other gates an
approval the user never gave is the thing gates exist to prevent.

Nothing says what to do with a reply that is not an offered token. `skills/sd-gate-brief/SKILL.md`
says the reply closes the section and is recorded verbatim, but not whether it is valid. The only
re-ask rule covers a `details` target that names nothing.

The hook does not help. `read_brief` in `hooks/bash/stop-gate.sh` (twin: `Get-BriefState` in the
`.ps1`) counts a `Reply:` line as an approval unless its first token is on a per-gate list of
non-approving tokens (`deny_token`). `yes` at port Gate 5 is not on that list, so the hook accepts
the same off-option reply the model did. The approval is also sticky: one approving `Reply:` in
any section of a gate label is enough, and a later non-approving token does not take it back.

## Decision

1. **The rule lives once, in `sd-gate-brief`.** A reply is valid when it is one of the gate's
   offered tokens (trimmed, case-insensitive, trailing punctuation ignored, with the token's
   argument where it takes one), or, in a conversation that is not in English, the plain
   translation of one (ADR 0019). Anything else is not mapped onto an option. The main thread
   appends `Reply: unrecognized - <reply verbatim>` to the open section with the Edit tool, prints
   one line naming this gate's options, and asks the same question again. The section stays open,
   like a `details` reply. No per-command restatement.
2. **No synonym is ever accepted.** `y`, `ok`, `go` and `sure, go ahead` are off-option at every
   gate. Accepting synonyms only at soft gates would make the rule depend on a per-gate list the
   hook cannot see, and the cost of re-asking is one line. A token that belongs to another gate
   (`yes` at port Gate 5) is off-option for the same reason.
3. **The hook keeps its deny list; `unrecognized` joins it at every gate.** A section whose only
   reply is the marker is not approved, and a real reply recorded after it still counts, because
   approval is a sticky OR across the label. Both twins change in the same commit, and the list for
   the feature gates (which spell their words out) gains the token too.
4. **The hook does not learn each gate's approving set.** The rule above is the guarantee; the hook
   enforces only what it can see.

## Alternatives considered

- **The hook learns each gate's approving tokens** (an allow list). Rejected for the reason ADR
  0021 gave: replies may be in the conversation language, so every non-English approval would
  block. The option tokens are English, but a reply in the user's language is verbatim and cannot
  be matched against them.
- **Accept obvious synonyms at soft gates.** Rejected: it needs a second per-gate table, the model
  and the hook would have to agree on it, and the ticket's own incident (`yes` taken for
  `continue`) is exactly a synonym guess.
- **Record the off-option reply verbatim, like a `details` reply.** The ticket's first draft.
  Rejected: the hook would read the verbatim token, find it off the deny list, and count it as the
  approval the rule just refused. The marker makes the refusal visible to the hook.
- **A contract-lint rule.** Contract-lint checks relationships between files (a gate heading
  halts, an option set exists, a skill is wired). The off-option rule is runtime behavior of the
  model, not a relationship between two files, so a lint rule could only pin the skill's wording,
  which fails on every rephrase and proves nothing about behavior. The check that can prove it is
  an e2e scenario.

## Consequences

- **Known limit, stated plainly.** The marker works only when the model follows the rule. If it
  records a bare `Reply: yes` at a gate that did not offer `yes`, the hook still counts an
  approval. The hook cannot tell a legitimate `yes` from a misapplied one without the allow list
  rejected above.
- A stop-gate fixture pair is added: a section with only the marker is blocked, and the same
  section followed by a real reply is allowed. `allow-feat-free-form-reply` (a localized approval)
  is unchanged and must still pass.
- Every `tests/e2e/scenarios/*/replies.txt` must use only tokens its gate offers. Scenario `17`
  now does. Scenarios `16` (`choose H1`, `keep`) and `91` (`approve split`) are not checked here
  and are verified when this lands.
- No gate count changes, so `contractLint.gates` is unchanged.

## Revisit when

- A live run records a bare off-option reply and the hook lets it through. That would justify a
  per-gate allow list, with the localization cost weighed again.
- The hook gains a way to read the offered option set from the command it is evidencing.
