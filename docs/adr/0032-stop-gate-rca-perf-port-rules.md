# ADR 0032: Stop close-out gate - /sd:rca, /sd:perf and /sd:port rules from gate-briefs.md

- Status: accepted
- Date: 2026-11-01
- Source spec: Jira SW-114 (`FEAT-stop-gate-rca-perf-port-rules`)
- Relates to: ADR 0016 (the invariant table, whose RCA-G2, PERF-G2 and PORT-G1/G2/G3/G6 rows this
  ADR layers on); ADR 0021 (coverage, any-pass approval and the parse contract, reused unchanged);
  ADR 0029 (the label-generic reader, and the rule that an answer which only moves the run forward
  approves); ADR 0026, ADR 0027 and ADR 0028 (the `/sd:rca`, `/sd:perf` and `/sd:port` briefs);
  ADR 0012 (hook latency budget)
- Supersedes: none. Extends ADR 0016 with eleven rows and adds a reply check to six of its rows.

## Context

Since SW-96 parts 3 to 5, every `/sd:rca`, `/sd:perf` and `/sd:port` gate writes a
`## Gate <n> - <title> (pass <p>)` section to `gate-briefs.md` and records the user's answer on
its `Reply:` line. stop-gate read that file only for feature, bug and refactor. For these three
workflows, it checked only the ADR 0016 rows: on-disk evidence for perf Gate 2, rca Gate 2 and
port Gates 1, 2, 3 and 6. A session that moved past any other rca, perf or port gate without the
user's answer was never caught, and nothing checked whether the six ADR 0016 gates had a reply.

SW-108 made the reader take a workflow's gate labels as data. So each workflow here is an entry
in the order table, its non-approving tokens and its rule rows. Three things in these workflows
shape the rows:

- **Loops that end without a forward answer.** perf Gate 5's red face offers only `continue`
  (back to Gate 4). perf Gate 6 can be answered `revert` on every attempt. port Gate 6's Case B
  offers only resolutions that regenerate parity and show Gate 6 again.
- **A branch that skips gates.** perf Gate 2 Case A (the baseline already meets the goal) sets
  status `in-progress` and jumps to close-out. Gates 3 to 8 are never shown.
- **No `## Close-out` marker.** rca, perf and port do not open their retro entry with one. Close-out
  sets status `done`, and a `done` spec is never checked.

## Decision

`stop-gate` evaluates these rows. Spec selection, output, the loop guard and the opt-in flag are
ADR 0016's. Coverage, the any-pass approval and the parse contract are ADR 0021's. "Base" is
`details`, `refine`, `abort` and a bare `no`, as in ADR 0029. A reply's token is its first word, so
`gather more` is `gather`, `dig deeper` is `dig`, `re-run parity` is `re-run`, and
`abort hotspot` and `abort workflow` are both `abort`.

| Rule | Gate | Advanced (any of) | Non-approving tokens |
|---|---|---|---|
| RCA-G1 | Evidence gathered | status `approved` or `in-progress`; `## Hypothesis tree` has no `<<PHASE-2:` token; `## Root cause` has no `<<PHASE-3:` token | base, `gather` |
| RCA-G2 | Hypotheses enumerated | as ADR 0016 | base, `add` |
| RCA-G3 | Root cause confirmed | status `approved` or `in-progress` | base, `dig` |
| PERF-G1 | Target defined | status `approved` or `in-progress`; a `04-artifacts/baseline-*` file exists | base |
| PERF-G2 | Baseline measured | as ADR 0016 | base |
| PERF-G3 | Hotspot identified | a `04-artifacts/attempt-*-tests.txt` exists | base |
| PERF-G4 | Select hypothesis | a `04-artifacts/attempt-*-tests.txt` exists | base |
| PERF-G5 | Correctness verified | a `04-artifacts/attempt-*.json` exists; `04-artifacts/final-tests.txt` exists | base |
| PERF-G6 | Keep or revert decision | the Results log has a `kept` row; `final-tests.txt` exists | base |
| PERF-G7 | Regression pass | with `final-tests.txt`: a `## Gate 8` section exists; `## Trade-offs accepted` has no `<<PHASE-6:` token | base, `investigate` |
| PERF-G8 | Final review pass | with `final-tests.txt`: `## Trade-offs accepted` has no `<<PHASE-6:` token | base, `address` |
| PORT-G1 | Donor set frozen | ADR 0016's, and `03-decisions.md` exists | base, `re-capture` |
| PORT-G2 | Fidelity tables complete | ADR 0016's, and `03-decisions.md` has `## Behavior pinning` | base |
| PORT-G3 | Behavior pinned and green | ADR 0016's, and `01-plan.md` exists | base, `re-pin` |
| PORT-G4 | Plan approval | status `in-progress`; a task is `done`; a `04-artifacts/batches/batch-*-tests.txt` exists | base |
| PORT-G5 | Batch tests green | `04-artifacts/parity/INDEX.md` exists | base, `revert` |
| PORT-G6 | Justified-diff parity | ADR 0016's, and `05-retro.md` has `## PR description block` or `## Divergence record` | base, `re-run`, `revert-to-snapshot`, `add-deviation` |

Every other token approves. That includes `choose` (perf Gates 3 and 4), `proceed anyway` (perf
Gate 2 Case A), `continue` (perf Gate 5 Face B and port Gate 5 Face A), `keep`, `revert` and
`keep-with-reason` (perf Gate 6), and a reply in the conversation language.

1. **Advanced means written after the approving answer.** Each item is the first artifact a later
   phase writes. Nothing written before a gate's own brief counts for that gate. Otherwise a
   session correctly waiting at the gate would be blocked, the mistake ADR 0029 avoided for bug
   Gates 3 and 4.
2. **An answer that moves the run forward approves.** A token is non-approving only when another
   pass of the same gate must follow it. perf Gate 5 Face B's `continue` and perf Gate 6's `revert`
   are decisions: a run where every attempt is red, or every change is reverted, still reaches
   Phase 5. port Gate 5's `revert batch` and port Gate 6's Case B resolutions are always followed
   by another pass of that gate, so they do not approve.
3. **Layered on ADR 0016.** RCA-G2, PERF-G2 and PORT-G1/G2/G3/G6 keep their section and artifact
   checks. The reply check adds one more missing item to the same finding, as BUG-G2 does (ADR
   0029). The extra advanced items in the port rows count only when `gate-briefs.md` exists.
4. **No file, no rule.** Without `gate-briefs.md`, the new rows do not fire and the six ADR 0016
   rows produce today's output byte for byte. The fixtures that predate this ADR are unchanged.
5. **Gate labels.** `1 2 3` for rca, `1 2 3 4 5 6 7 8` for perf, `1 2 3 4 5 6` for port. None of
   these workflows has a lettered or Re-plan gate, so no label collides.
6. **Repeated gates.** perf Gates 3 to 6 repeat per hotspot and attempt, port Gate 5 per batch and
   port Gate 6 per parity run. All passes are headed `## Gate <n>` and count together. One
   approving reply in any pass satisfies the gate (the any-pass rule).

## Alternatives considered

- **Status `in-progress` as PERF-G3 evidence.** Rejected: Gate 2 Case A sets it and jumps to
  close-out without Gate 3, so a correct run would be blocked.
- **A `reverted` Results-log row as PERF-G6 evidence.** Rejected: Gate 5 Face B writes one before
  Gate 6 is ever shown. A session waiting at Gate 6 on attempt 2, after a red attempt 1, would be
  blocked.
- **The Gate 8 section, or a filled `## Trade-offs accepted`, without `final-tests.txt`.**
  Rejected: Case A reaches close-out, which fills the trade-offs, without Phase 5 or the review.
  Only Phase 5 writes `final-tests.txt`, so it marks a run that went through Gates 3 to 7.
- **`continue` and `revert` as non-approving at perf Gates 5 and 6.** Rejected for point 2: an
  all-red or all-reverted run would block on gates it answered.
- **Verification results as RCA-G2 evidence.** Phase 3 writes them under
  `### Verification results` before the root cause, so they would catch a skipped Gate 2 earlier.
  Not done: they need a parser for a `###` subsection and its verdict words. The ADR 0016 known
  limit stands: a skipped Gate 2 is caught once the root cause is written, which happens before
  the Gate 3 brief.
- **A `## Close-out` heading for the three workflows.** Would give perf Gate 8 and port Gate 6 the
  same evidence bug and refactor have. Rejected here: it changes what the commands write, which
  this ticket leaves to SW-110/111/112. The close-out files that already exist serve instead.
- **The `.specs/index.md` row as RCA-G1 evidence.** Gate 1 `yes` is what adds the rca row, but the
  hook does not parse the index, and the hypothesis tree follows straight after.

## Consequences

- An rca, perf or port spec past a gate with no approving `Reply:` is blocked with a readable
  reason, and a spec with no `gate-briefs.md` is never blocked by these rows.
  `tests/hooks/fixtures/stop-gate/` asserts that, identically for PowerShell and bash, with 36 new
  fixtures. The 7 rca, perf and port fixtures from before this ADR are unchanged.
- **Known limits:**
  - Any-pass across repeats. Approving one attempt or batch covers the later ones. Counting per
    hotspot, attempt or batch is the follow-up ADR 0029 named for refactor Gate 5.
  - `keep-with-reason` given without a reason still reads as approving. The command refuses it,
    but the reply line only shows the token.
  - `done` specs are not checked, as in ADR 0016.
- **Drift.** The rows restate what `commands/rca.md`, `perf.md` and `port.md` write at each gate,
  and their option sets. A change to either must update both hook twins and their fixtures.
- **Latency.** Reading the brief adds one pass over `gate-briefs.md` and a few globs. Measured p95
  is under ADR 0012's budgets (see the CHANGELOG entry).
