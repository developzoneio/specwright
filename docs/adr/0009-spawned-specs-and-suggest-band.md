# ADR 0009: spawned specs are a close-out prompt and an advisory rule, not a gate

- Status: accepted (shipped in 1.6.0)
- Date: 2026-09-24 (recorded retroactively by SW-56; decisions made 2026-08, SW-42)
- Source spec: Jira SW-42 (`## Spawned specs`)
- Relates to: ADR 0001 (`/sd:spec validate` parses artifact content)
- Supersedes: none

## Context

Follow-up work discovered in the middle of a spec had nowhere to land except prose, where it
evaporated. Only the RCA template had a place for it (a reserved-ID table), so two conventions
existed for one need. Four real-world follow-ups motivated the change; the fourth was lost by
exactly the mechanism described in decision 4 below.

## Decision

1. **One convention across spec types.** The RCA template's reserved-ID table
   (`Reserved ID | Type | Title | Owner`) becomes the `## Spawned specs` section in the feature,
   bug, refactor and perf spec templates.

2. **A prompt, not a gate.** Each affected workflow's close-out prompts for the section when the
   retro names deferred work. Gate counts are unchanged: hard-gating hygiene would tax every spec
   for the benefit of the minority that defer anything.

3. **No `<<...>>` token in the section.** It is filled at close-out, after `approved`, so an
   author-fill placeholder would be an `SL010` BLOCK on every spec that deferred nothing. Header
   plus separator row is the empty state, and it is also `SL090`'s trigger.

4. **A reserved ID is not a registry entry.** A spawned spec gets an `.specs/index.md` row only
   once its directory exists. Writing the row first manufactures the ghost row `SL032` exists to
   catch.

5. **`SL090` opens a SUGGEST band.** A `done` spec whose body names deferred work with an empty
   spawned-specs table is reported as SUGGEST - advisory, never a failure. Its trigger vocabulary is
   a closed phrase list rather than a judgement call, because an advisory that fires on a hunch is
   noise. `SL091`-`SL099` are reserved for close-out hygiene.

## Consequences

**Positive.** Deferred work has one named home in every spec type, and `/sd:spec validate` nudges
when a spec closes with deferred work unrecorded.

**Negative.** Nothing forces the section to be filled, and a closed phrase list misses deferred
work described in other words. Both are accepted: the rule is advisory by design.
