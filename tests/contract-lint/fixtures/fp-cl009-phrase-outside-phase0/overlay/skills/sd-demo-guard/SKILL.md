# sd-demo-guard

Demo bootstrap guard read at runtime by the alpha command. It owns the messages below; a skill is
never scanned by CL009, even under its own Phase 0 heading.

## Phase 0 - Bootstrap

1. Read `CLAUDE.md`. If missing, WARN: "No `CLAUDE.md` found; stack conventions may be
   incomplete." The constitution is the binding Layer-2 contract.
2. If `.specs/` is missing, STOP: "No `.specs/` found."
3. If the project config failed to parse, STOP.
