# ADR 0019: Gate brief - details targets, brief language, plan-face decisions

- Status: accepted
- Date: 2026-10-22
- Source spec: Jira SW-102 (`FEAT-gate-brief-gaps`, E12 / SW-87)
- Relates to: ADR 0018 (the gate brief artifact this ADR extends); `skills/sd-gate-brief/SKILL.md`
  (the rules); Jira SW-99 (what "printed verbatim" means)
- Supersedes: none. Extends ADR 0018 decisions 2, 3 and 5; reverses none of them.

## Context

SW-89 shipped a narrower design than its ticket text. Three items of that text were still open,
and the SW-89 re-measure found a fourth:

- **G1.** The ticket asked for `details T02`, `details plan` and `details risks`. SW-89 shipped a
  bare `details` that shows the collapsed decisions and the artifact paths.
- **G2.** The ticket said the brief is "written in the user's conversation language; spec files
  stay English". The skill said nothing, and SW-99 needs to know whether "printed verbatim" is a
  copy or a translation.
- **G3.** The ticket said "about 15 lines" in fixed parts. SW-89 shipped at most 10 lines up to the
  question plus one row per task. SW-89 measured Gate 1 / 2 / 3 at 8 / 12 / 4 lines on the small
  run and 8 / 16 / 5 on the medium run.
- **G4.** On the small run, the Gate 2 brief re-listed three decisions the user had already
  approved at Gate 1.

## Decision

1. **`details <target>` on Gate 2 (both faces) and Gate 3.** Targets: none (the collapsed
   decisions, the artifact paths and the list of targets, as before), a task ID (that task's full
   block from `02-tasks.md`), `plan` (`01-plan.md`) and `risks` (the risks section of the plan and
   the risk assessment of the impact map). Each prints verbatim and records only the `Reply:` line;
   the printout is not appended, because it is a copy of a file already on disk. Gate 1 keeps a
   bare `details`: no plan, task list or impact map exists yet. The option set uses one
   placeholder, `details <target>`, like `refine <feedback>`. Both contract linters extract the
   token `details` from it, the same token as before, so `CL301` and `CL305` are unaffected.
2. **The brief is in the conversation language; the file and the chat are the same text.** Agents
   return English blocks. The main thread renders a block into the language the user types once,
   when it writes the section, and then prints the section verbatim. Section headings, the
   collapsed-decisions heading, the `Reply:` prefix, option tokens, the spec ID, task IDs and file
   paths stay English. Every other spec artifact stays English. For SW-99, "verbatim" therefore
   means a byte-identical copy of the section body, and it can be asserted by comparing the
   transcript with the file. A `details` excerpt is an artifact printed on request and keeps its
   English and its IDs.
3. **The line cap stays at 10 lines up to the question, plus the task table.** It replaces the
   ticket's "about 15". A total of 15 cannot hold one row per task for a plan at the decompose
   threshold of 8 tasks (about 7 fixed lines, 2 table lines and 8 rows), and every part the ticket
   named is already in the brief.
4. **A Gate 2 face lists only the decisions the plan adds.** A decision the approved `00-spec.md`
   already settles was approved by the Gate 1 `yes`, shown or collapsed. To make that durable, every
   decision in a spec-face block is stated in `00-spec.md`. The architect checks plan decisions
   against the spec it already reads for `TASK = plan`, so it gains no input and no tool. The main
   thread drops any such decision that still arrives before it writes the section. With no
   plan-added decision, the block is one line saying so.

## Alternatives considered

- **`details <T01 | plan | risks>` in the option set** (the ticket's example). It parses to the
  same `details` token under both linters, but it mixes literal targets into a placeholder, and at
  Gate 1 it would offer targets that do not exist yet.
- **English artifact, translated chat.** Rejected: the shown text and the stored text differ, so
  "verbatim" cannot be checked, which reopens the SW-88 finding that a gate can be reported as
  shown without being shown.
- **English artifact and English chat.** Rejected: it contradicts the ticket's language
  requirement, and the brief is the one text written for the user.
- **The architect reads `gate-briefs.md` to learn what Gate 1 approved.** Rejected: under
  decision 2 that file is in the conversation language, so matching would cross languages, and it
  would turn a record of what was shown into an agent input.
- **The main thread passes the Gate 1 decisions to the architect.** Rejected: the list is lost on a
  resume, and it lengthens the prompt with text the spec already holds.

## Consequences

- The e2e scenario `02-feature-happy` runs in English, so its ID and heading assertions are
  unchanged by decision 2. It gains one assertion that a `Reply: yes` line is on disk, which holds
  in any conversation language because the `Reply:` prefix and the option tokens stay English.
- `details <target>` replies are recorded like any other reply, so a resumed session can see what
  the user asked to read.
- The gate count stays 3, `contractLint.gates` is unchanged, and no hook changes.
- Other workflows adopt the brief in SW-96, and they take these rules from the same skill.
