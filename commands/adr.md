---
description: Author an Architecture Decision Record (ADR) from a spec's decisions via sd-docs-writer. 1 hard gate before keeping the file.
argument-hint: <spec-ID | "decision title">
---

# /sd:adr

Promotes a durable decision into a numbered ADR under `.specs/_adr/`. Drives the `sd-docs-writer` agent.

**Argument:** a spec ID (e.g. `FEAT-012`) whose `03-decisions.md` holds the decision, OR a free-text
decision title for an ad-hoc ADR with no spec.

---

## Phase 0 - Bootstrap

1. Read `~/.claude/skills/sd/sd-bootstrap-guard/SKILL.md` and apply it before anything else here -
   it owns the Layer-2 reads and all of their messages (commands cannot load skills via
   frontmatter, so it is read at runtime). If that file is unreadable, STOP: "specwright install
   incomplete - bootstrap guard skill not found under `~/.claude/skills/sd/`. Re-run the installer."
2. No state detection: unlike the workflow commands, `/sd:adr` has no resume state machine.
   Phase 1 resolves the decision source directly.

## Phase 1 - Resolve the decision source

1. If the argument matches a spec ID in `.specs/index.md`:
   - Locate `.specs/<ID>/03-decisions.md`. If it is missing or has no decision content, STOP and ask the
     user to supply the decision inline or pick another spec. Never invent decisions.
   - Set `SPEC_REF = <ID>` and `DECISION_SOURCE = .specs/<ID>/03-decisions.md`.
2. Otherwise treat the argument as a free-text decision title:
   - Set `SPEC_REF = ad-hoc`. If the title alone is insufficient, ask the user once for the Context,
     Decision, and Consequences. `DECISION_SOURCE` = the gathered text.

## Phase 2 - Assign number and slug

1. Glob `.specs/_adr/` for files matching `^[0-9]{4}-`. Take the highest 4-digit prefix; `ADR_NUMBER` =
   that value + 1, zero-padded to 4 digits. If none exist, `ADR_NUMBER = 0001`.
2. Derive `<slug>` = kebab-case of the decision title (lowercase, alphanumerics and hyphens, <= 60 chars).
3. `ADR_PATH = .specs/_adr/<ADR_NUMBER>-<slug>.md`.
4. If the user names an existing ADR this decision replaces, set `SUPERSEDES` to its number; else `none`.
5. Idempotency: if an ADR whose title clearly matches this decision already exists, ask whether to update
   it in place or create a new number. Never silently clobber.

## Phase 3 - Draft via sd-docs-writer

Invoke the `sd-docs-writer` agent with `ADR_NUMBER`, `ADR_PATH`, `SPEC_REF`, `DECISION_SOURCE`,
`SUPERSEDES`, and today's date as `DATE`. The agent drafts and writes the file, then returns its content.

## Gate (HARD) - approve before keeping

Display the drafted ADR in full. STOP and ask: "Keep this ADR at `<ADR_PATH>`? (yes / edit / abort)".
Silence is not approval.
- `yes` -> keep the file. If `SUPERSEDES` is not `none`, edit that ADR's `Status` line to
  `superseded by <ADR_NUMBER>` and add a reciprocal "Superseded by" link.
- `edit` -> apply the requested changes (re-invoke the agent or edit directly) and re-display.
- `abort` -> delete the drafted file and report that no ADR was created.

## Phase 4 - Report

Print the ADR path, number, status (`proposed`), source spec, and any supersession link. Remind the user
the ADR stays `proposed` until they change its status to `accepted`.

---

## Rules (hard constraints)

- **Decisions come from the source, never invented.** Empty or absent decision content aborts the command.
- **1 hard gate.** Nothing is kept on disk without explicit approval.
- **ADRs are not specs.** No `.specs/index.md` lifecycle entry; ADRs live under `.specs/_adr/` with their
  own numbering.
- **The constitution is never edited here.** Amending a rule is a separate `/sd:refactor` or a manual ADR
  acceptance step.
