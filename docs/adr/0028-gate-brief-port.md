# ADR 0028: Gate brief - /sd:port gates

- Status: accepted
- Date: 2026-10-29
- Source spec: Jira SW-112 (`FEAT-gate-brief-rollout`, SW-96 part 5 of 5, E12 / SW-87)
- Relates to: ADR 0005 (the port pipeline); ADR 0018 (the gate brief artifact); ADR 0019
  (`details` targets, language); ADR 0020 (printed means reply text); ADR 0024 (the `/sd:bug`
  pilot); ADR 0025 (the `/sd:refactor` gates); ADR 0027 (the `/sd:perf` gates);
  `skills/sd-gate-brief/SKILL.md` (the rules); `skills/sd-port-fidelity/SKILL.md` (the tables)
- Supersedes: none. Extends ADR 0024 decisions 1, 2, 3 and 5 to `/sd:port`. Closes SW-96.

## Context

After SW-96 parts 1-4, `/sd:feature`, `/sd:bug`, `/sd:refactor`, `/sd:rca` and `/sd:perf` present
their gates as briefs. `/sd:port` still displays raw counts and tables at its six gates (Gates 1,
2, 3 and 6 HARD), and a WARN of Phase 1 names `ESC-PORT-01` to the user.

Three facts set it apart. What a port gate approves is a table, and the tables grow with the donor:
a 40-member module puts 40 manifest rows in front of the user at Gate 2. The decisions in a port
are the deviation rows, and their citations are `§N.M` and `file:line`, the two forms the text rule
forbids. And the user must name a deviation row in a reply (`details`, `add-deviation`), so the
`D<NN>` handle cannot simply be hidden.

## Decision

1. **A `/sd:port` part in the skill.** `sd-gate-brief` "Per-workflow parts" gains section headings,
   shown lines and `details` targets for Gates 1-6. The shapes are reused by reference: Gate 4 is
   the `/sd:refactor` plan approval with its batch table, Gate 5 the `/sd:refactor` batch gate with
   both faces, Gate 6 the review shape. New lines exist only for the donor set summary (Gate 1),
   the fidelity tables as counts plus blocking rows (Gate 2), the behavior-pin result (Gate 3 and
   `Pinned suite:` at Gate 5) and the parity verdict (`Parity:` at Gate 6). `commands/port.md`
   reads the skill in Phase 0 and only names it at each gate. The table rules and the hunk
   vocabulary stay in `sd-port-fidelity`.
2. **Who composes each brief.** Gate 4 reuses the architect's `gate: plan` block, with a `What
   changes` line the main thread writes from the port decompose metric it computed. Gate 6 reuses
   the reviewer's `gate: review` block, which `port-parity` now returns. The main thread composes
   Gates 1, 2, 3 and 5 from what it already wrote. The architect's `gate: spec` block for `create`
   and `refine` is not used: Gate 2 approves the tables, which the main thread counts mechanically
   in Phase 4 anyway.
3. **Large tables compress to counts and blocking rows.** Gate 2 shows one `Tables:` line (files by
   kind, members by status) and one `Deviations:` line by group. On a complete table the deviations
   are the decisions, top 3 shown, ranked agreed donor fix first because it changes behavior. On an
   incomplete table up to 4 blocking lines replace them; `yes` is refused there, so no decision is
   hidden. Gate 6 counts justified hunks and lists every blocking one, merging more than 3 of one
   class in one file into a single line.
4. **Deviation IDs are an allowed handle, glossed.** `D<NN>` may appear on the same line as its
   `<donor form> -> <host form>`, and what forced it is said in words (`host rule on naming`), never
   as its `§N.M` or `file:line` citation. This is the one `D<n>` the user sees; a feature's decision
   reference stays forbidden.
5. **`port-parity` returns `gate: review` plus a `parity:` line.** The line carries the three counts
   of the review's summary (justified hunks, members present, files outside the mapping), so the
   brief takes them from the block rather than from prose. It appears only for `port-parity`, as
   `invariant:` appears only for a refactor review.
6. **Four new saves.** Phase 5 writes `04-artifacts/pinning/pinned-tests.txt` and `tree-check.txt`
   (the empty-diff checks and their output); Phase 7 writes `04-artifacts/batches/batch-<n>-tests.txt`
   after each batch; Phase 8 writes the reviewer's report to `04-artifacts/parity/REPORT.md`, which is
   regenerated with the rest of `parity/`. Each gives a `details` target a file to print verbatim.
7. **Gate 5 gets two faces.** Face A (green) offers `continue`, Face B (red) offers `revert batch`
   only, so a red batch is never shown with a `continue` the gate would refuse.
8. **Every `/sd:port` gate offers `details`.** Gate count stays 6, Gates 1, 2, 3 and 6 stay HARD and
   list no override: `details` never approves, so `CL305` is unaffected. `contractLint.gateBriefs`
   declares labels `1` to `6` for both briefs and `details`.

## Alternatives considered

- **Show the three tables at Gate 2, capped.** Rejected: a cap on table rows hides rows the user
  approves, and the counts are what the gate refuses on.
- **Hide deviation IDs and refer to rows by position.** Rejected: `add-deviation` and `details`
  need a stable name, and the PR description copies the table with its IDs.
- **The main thread classifies the parity counts itself from `REPORT.md`.** Rejected: the summary
  line is prose; a field in the block the reviewer already returns is the same data, typed.
- **A `gate: tables` architect block for Gate 2.** Rejected: the architect authored the tables, and
  the gate exists to check them by count; the summary must come from the counter.

## Consequences

- `CL307` covers `commands/port.md`. Its shapes are pinned by existing fixtures: the two-face HARD
  gate (Gate 6), option tokens with arguments plus `details`, and a two-face non-HARD gate, so no
  fixture is added.
- e2e scenario `17-port-gate-brief` runs `/sd:port` fresh on an in-repo donor in the fixture
  project (`src/legacy/title-format.js`, scope `module`) with one deviation the host constitution
  forces, and reaches all 6 gates on the happy path. Without GitNexus the extraction escalates, so
  the run also exercises plain-word narration of that escalation. It asserts the 6 sections, the
  `Reply:` lines, the transcript printout, the new saves, and the absence of internal IDs and
  unglossed deviation IDs in the file and in every assistant text block.
  - **Not reached by the run**, covered by the lint only: the incomplete face of Gate 2, a dirty
    production tree at Gate 3, the red face of Gate 5, Case B of Gate 6, a bridged donor and a plan
    over the split threshold.
- **No hook change.** stop-gate's PORT rules (ADR 0016) read `00-spec.md`, `MANIFEST.md`,
  `03-decisions.md` and `parity/INDEX.md`, which are unchanged. Follow-up: PORT rules evidenced by
  the brief (SW-114).
- With this part SW-96 is complete: `/sd:feature`, `/sd:bug`, `/sd:refactor`, `/sd:rca`,
  `/sd:perf` and `/sd:port` all present their gates as briefs.
