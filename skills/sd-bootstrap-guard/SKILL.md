# sd-bootstrap-guard

Phase 0 bootstrap guard for specwright workflow commands. `/sd:feature`, `/sd:bug`, `/sd:rca`,
`/sd:refactor`, `/sd:perf`, `/sd:port` and `/sd:adr` read this file at runtime as Phase 0 step 1.
Commands cannot load skills via frontmatter, so this is a runtime read rather than a `skills:`
entry. The file is the single owner of the Layer-2 reads and of every message they print. A
command's `## Phase 0` must not restate them; contract-lint `CL009` blocks it.

---

## The guard

Run the steps in order and stop at the first STOP. Never skip a read because a later phase might
not need it.

1. Read `CLAUDE.md` at the project root. If it is missing, WARN and continue - print
   "No `CLAUDE.md` found; stack conventions may be incomplete." Never STOP here: the
   constitution is the binding Layer-2 contract, not `CLAUDE.md`.
2. Read `.specs/constitution.md`. If `.specs/` or this file is missing, STOP:
   "No `.specs/` found - run `/sd:setup` first."
3. Read `.claude/project-config.json`. If it is missing, STOP with the step 2 message. If it is
   present but fails to parse as JSON, STOP: "`.claude/project-config.json` failed to parse -
   fix it or re-run `/sd:setup`."
4. Read `.specs/index.md` for existing spec states. If it is missing, STOP with the step 2
   message.

Print every message verbatim. A STOP here ends the workflow run; the user fixes the cause and
re-invokes the command.

---

## After the guard

Keep all four in context. The calling command reads `commands.*`, `spec.*`, `ticket.*` and
`workflow.*` from the parsed project-config, and its state detection reads the index. Continue
at the calling command's Phase 0 step 2.

## What the guard does not do

- Detect state, parse arguments, compute dates or fetch tickets. The calling command owns those
  steps and lists them after step 1.
- Create or repair any file. A STOP is fixed by `/sd:setup` or by hand, never by the workflow.
- Apply to agents. Agents receive their context from the invoking command.

## Anti-patterns

- Restating any message above in a command's Phase 0. That is the drift this skill exists to
  remove.
- Downgrading a STOP to a WARN because "this command only needs the index".
- Treating a parse failure as a missing config and continuing with defaults.
