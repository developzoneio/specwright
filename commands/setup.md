---
description: Idempotent project scaffold. Detects state, asks 3 questions, generates CLAUDE.md + .specs/ + .claude/. Stack-agnostic.
argument-hint: (no args - interactive)
---

# /sd:setup

Scaffolds a project to use `specwright`. Safe to re-run: detects existing state and only fills gaps.

**No arguments.** Fully interactive.

---

## Phase 0 - Prerequisites check

1. Verify the following installed paths exist (i.e. the engine has been installed via the installer):
   - `~/.claude/templates/sd/`
   - `~/.claude/skills/sd/`
   - If either is missing -> abort with: "specwright install incomplete — `<missing path>` not found. Run `install/install.ps1` (Windows) or `install/install.sh` (Unix) from the specwright repo first."
2. Verify the current directory looks like a project root.
   - Heuristics: presence of `.git/`, OR a package manifest (`package.json`, `*.csproj`, `*.sln`, `pyproject.toml`, `Cargo.toml`, `go.mod`, `pom.xml`, `build.gradle`). <!-- contract-lint: allow CL400 - a multi-stack detection heuristic enumerating several ecosystems' manifest filenames, not an assumption that any one of them applies -->
   - If nothing found -> warn and ask: "This directory does not appear to be a project root. Continue anyway? (yes / no)".
3. Read `~/.claude/templates/sd/CLAUDE.template.md`, `constitution.template.md`, `project-config.template.json`, `settings.template.json` into memory. (Spec templates remain on disk for later.)
4. Read `~/.claude/templates/sd/specwright-version.txt` into memory as "installed engine version". <!-- contract-lint: allow CL005 - specwright-version.txt is generated at install time from CHANGELOG.md, never a checked-in template source file -->
   If missing or unreadable (engine installed before this stamp existed), record it as `<unknown>`
   and do NOT abort Phase 0 over this file specifically - unlike the hard existence checks in step 1.

---

## Phase 1 - Detect existing state

Classify the project into one of four states:

| State | Detection | Action |
|---|---|---|
| `fresh` | No `CLAUDE.md`, no `.specs/`, no `.claude/` | Full scaffold |
| `post-init` | Has `CLAUDE.md` but no `.specs/` (e.g. ran `/init` only) | Backup `CLAUDE.md`, regenerate from template merging stack hints; scaffold `.specs/` and `.claude/` |
| `partial` | Has `.specs/` OR `.claude/` but not both, OR missing key files | Fill the missing pieces only; never overwrite existing |
| `complete` | Has `CLAUDE.md`, `.specs/constitution.md`, `.specs/index.md`, `.claude/project-config.json`, `.claude/settings.json` | Run Phase 1.5 (drift check). If no drift: print "already set up - run `/sd:spec list` to view specs" and exit cleanly. If drift: offer the gated migration, then exit. |

Print the detected state and the planned changes BEFORE writing anything.

If the project already has `.claude/project-config.json` or `.claude/settings.json` (states
`complete` or `partial`), run **Phase 1.5** before proceeding - even when the state is `complete`.

---

## Phase 1.5 - Drift check & migrate

Runs whenever `.claude/project-config.json` or `.claude/settings.json` already exists (states
`complete` and `partial`). The `complete` early exit happens ONLY after this phase finds no drift.
Presence of the five key files does NOT mean their *contents* are current - this is what migrates
projects scaffolded under an older engine name or template version.

Compare the existing `.claude/*` files against the templates loaded in Phase 0. Detection is
**rule-based, never a line-diff**: templates contain `<<placeholder>>` tokens and every project has
its own values, so a raw diff would flag legitimate content. Apply ONLY the checks below; preserve
every project-specific value and every already-filled field. The list is seeded with the known
`ck` -> `sd` rename; the *shape* of each check (renamed token / missing block / pinned-to-alias)
is generic, so future renames and newly-introduced template fields are caught the same way.

### Drift checks (read-only - detect, do not write yet)

**A. `.claude/settings.json`**

1. **Hook command paths (HIGH).** Each hook command's script path must use the namespace dir of
   the loaded `settings.template.json` (currently `.../hooks/sd/`). Flag any `/.claude/hooks/<other>/` <!-- contract-lint: allow CL402 - describes a settings.json path PATTERN to detect drift in the TARGET project's config, not a filesystem path on this machine -->
   segment (e.g. `.../hooks/ck/`) and record the old -> new rewrite per hook
   (SessionStart/session-context, UserPromptSubmit/prompt-router, PreToolUse/spec-gate,
   SubagentStop/subagent-retro).
2. **Missing top-level blocks.** Flag any template top-level key absent from the file - currently
   `_bash_adaptation` and `_schema_notes`. These are `_`-prefixed documentation keys; adding them
   verbatim from the template is non-destructive.
3. **Stale `_comment_top`.** If it names a previous engine ("ck-spec-system" / any value differing
   from the template's), flag replacement with the template's value.
4. **Narrow `spec-gate` matcher (HIGH).** The `PreToolUse` entry whose command runs `spec-gate` must
   carry the template's matcher (currently `Edit|Write|MultiEdit|Bash|PowerShell`). Flag a matcher
   that lacks `Bash` or `PowerShell` (e.g. the pre-SW-79 `Edit|Write|MultiEdit`) and record the
   old -> new matcher. Without it, a shell command can rewrite `.specs/index.md` or a protected
   file unseen. Rewrite only the `matcher` string; keep the entry's command and timeout.
5. **Missing `SessionStart` hook (HIGH).** If no `SessionStart` entry runs `session-context`,
   flag adding the template's `SessionStart` entry (SW-67). Since SW-67, `prompt-router` no longer
   lists in-progress specs, so without this entry a project set up earlier loses them. Match
   the form the file already uses: the template's PowerShell command line when the other hooks
   run `powershell ...`, the `bash <path>.sh` form (as in Phase 6 step 3) when they run bash, and
   both when both are present. Add the one event entry only; do not touch other entries.

**B. `.claude/project-config.json`**

6. **Stale `$schema` key (MEDIUM).** The current template publishes no `$schema` - no schema file
   is published for it. If the file still has a `$schema` key (leftover from an older template,
   e.g. the old `.../NXTK/ck-spec-system/...` host or the later dead `.../Developzone/specwright/...`
   URL), flag it for removal.
7. **Command/agent names in `_use` doc strings.** Scan every `_use` / `_*_use` string under
   `mcp.*`, `ticket.*`, `hooks.*`, `paths.*`. Flag old-namespace tokens: `/ck:*` -> `/sd:*` and
   `ck:<role>` / `ck-<role>` -> `sd-<role>`. Rewrite only the token, preserving the rest of the
   wording.
8. **Version gap and missing newly-introduced fields.** Two related sub-findings:
   - **Version gap.** Compare the file's `version` against the "installed engine version" read in
     Phase 0. If the installed engine is newer (or the file's version is missing/unrecognized),
     record `version: <old> -> <new>`. Skip this sub-finding if the installed engine version is
     `<unknown>`.
   - **Field diff.** Diff every top-level and nested key of the loaded `project-config.template.json`
     against the file, excluding: placeholder-only differences (`<<...>>` tokens), and every
     project-specific value already carved out below (project name/owner/repo, ticket settings,
     detected commands/paths, filled `paths.layers`, MCP `enabled` flags, `specGate.mode`). Flag
     any template key genuinely absent from the file, adding each from the template's default;
     `paths.layers` defaults to `[]` (never invent a layer map here - that is Phase 2.5's job on a
     real scaffold).
9. **Pinned model IDs -> aliases.** Under `models.*`, flag any dated/versioned ID
   (`claude-sonnet-4-6`, `claude-haiku-4-5-20251001`, ...) and map to the family alias
   (`claude-sonnet-*` -> `sonnet`, `claude-haiku-*` -> `haiku`, `claude-opus-*` -> `opus`). Leave
   values that are already aliases, and leave unrecognized custom strings untouched (flag nothing
   rather than guess).

**C. `.claude/settings.local.json` (if present)**

10. **Stale permission entries.** Scan `permissions.allow[]` / `deny[]` for paths referencing a
   previous engine namespace under `.claude/{templates,hooks,commands}/<other>/` and flag the
   rewrite to the current namespace (`...\templates\ck\` -> `...\templates\sd\`), matching the
   path segment regardless of slash direction. Do NOT add, remove, or reorder any other permission.

### Hook-resolution check (always, even with zero drift findings)

For each hook `command` in `settings.json`, expand `${HOME}`/`~` and confirm the script file
exists on disk. Warn LOUDLY for any miss - this is the symptom that made the bug invisible:

```
WARNING - hook script not found on disk:
  <HookEvent> -> <resolved path>
  This hook is NOT firing. Expected after install: ~/.claude/hooks/sd/<name>.<ext>
  Fix: repaired by the namespace rewrite below, OR re-run install/install.ps1 (Windows) /
       install/install.sh (Unix) if the sd hooks were never installed.
```

A miss explained by check A.1 is folded into that finding. A miss with no rename explanation means
the engine itself is not installed - tell the user to run the installer; do NOT create the hook
script (setup never writes into `~/.claude/`).

### Gate - confirm the migration plan (one batch confirmation, not a question)

If zero findings AND every hook path resolves: print "No drift detected - `.claude/*` is current."
and continue (in `complete` -> clean early exit; in `partial` -> continue filling missing pieces).

Otherwise print ONE table grouped by file (each line showing exact before -> after with a
HIGH/MED/LOW tag), then STOP for explicit approval:

> Reply to apply every change (each file backed up first), leave `.claude/*` untouched, or name the
> specific lines to exclude, e.g. "skip the models lines". (go / skip / <lines to exclude>)

This is a confirmation of a batch, not a 4th interrogation question - the 3-question rule still holds.

### Apply (only after explicit "go")

1. Back up each file to be changed: `<file>.bak.<YYYYMMDD-HHmmss>` (same scheme as Phase 4 and the
   installer). Never overwrite without a backup.
2. Apply ONLY the approved targeted patches: rewrite the specific drifted tokens/paths/URLs in
   place; add missing keys/blocks from the template at their template position. Do NOT reformat
   untouched content, reorder keys, drop `_`-prefixed comment keys, or change any project-specific
   value (project name, ticket settings, detected commands/paths, filled layers, MCP `enabled`
   flags, `specGate.mode`). Preserve unfilled `<<placeholder>>` tokens. Exception: `version` is
   engine-tracked, not project-specific - when the item-8 version-gap sub-finding is approved,
   overwrite the file's `version` with the installed engine version from Phase 0.
3. Validate each patched file still parses as JSON (mirrors Phase 7) and re-run the
   hook-resolution check; report backups written, change counts per file, and post-migration hook
   resolution. Tell the user to restart Claude Code so corrected hooks are picked up.

If state was `complete`, exit after this report. If `partial`, continue to the remaining phases.

---

## Phase 2 - Parse existing CLAUDE.md (if present)

Goal: extract stack info to pre-fill answers in Phase 3.

1. Read existing `CLAUDE.md`.
2. Try to extract:
   - **Language**: from headers like "## Stack" -> "Language" or "Language:" patterns; from filenames present in root (e.g. `*.csproj` -> .NET / C#). <!-- contract-lint: allow CL401 - illustrative example of the filename-heuristic pattern, not an assumed stack -->
   - **Framework**: similar.
   - **Database**: similar.
   - **Build / Test / Lint commands**: from "## Commands" or "## Scripts" sections.
3. Store extracted values as defaults for Phase 3. Do not assume; only pre-fill if confidence is high.

<!-- contract-lint: allow CL401 - multi-stack filename-heuristic examples, not an assumed stack -->
If `CLAUDE.md` does not exist, defaults come from filename heuristics (`*.csproj` -> .NET; `package.json` -> Node; `pyproject.toml` -> Python; etc.).

---

## Phase 2.5 - Scan codebase (facts only)

Goal: detect project **facts** by sampling actual source, turning `<<placeholder>>`s into defaults.
This is Claude-driven sampling - there is NO scanner script. Detect facts ONLY; never infer
constitution rules.

1. Build a bounded picture of the tree:
   - Glob top-level directories and file-extension counts.
   - Skip `node_modules`, `bin`, `obj`, `.git`, `dist`, `target`, `vendor`, `.venv` and similar
     build/dependency directories.
   - Cap the directory walk at depth 3 and read at most ~15-20 representative files total.
2. Detect and record:
   - **Stack** (language / framework / db): extend the Phase 2 filename heuristics with a content peek
     at the dominant package manifest (`package.json`, `*.csproj`, `pyproject.toml`, `go.mod`,
     <!-- contract-lint: allow CL400 - same multi-stack manifest-filename enumeration as Phase 0, not a single-stack assumption -->
     `Cargo.toml`, `pom.xml`, `build.gradle`).
   - **Paths**: `src`, `tests`, `docs` from the directory layout.
   - **Commands** (`build` / `test` / `lint` / `run` / `coverage`): read ONLY what the dominant
     manifest declares (e.g. `package.json` `scripts`, `Makefile` targets, csproj/pyproject targets).
     Never invent a stack command the manifest does not contain; leave unknown commands as
     `<<placeholder>>`.
   - **`paths.layers`**: an ordered inside-out array of `{ name, path }` inferred from top-level
     source folders that look like architectural layers (innermost first; `path` may be a glob).
     Use `[]` when no layered structure is detectable.
3. Log which files were sampled so the user can judge confidence.

### Gate - confirm detected facts (one batch confirmation, not a question)

Print a single table of detected facts, then STOP for explicit approval before writing:

```
Detected (edit any before I write, or say "go"):
  Language / framework / db : <values or "not detected">
  Paths   src / tests / docs : <values or "not detected">
  Layers (inside-out)        : <name:path, ... or "none">
  Commands build/test/lint/run/coverage : <values or "<<placeholder>>">
```

> Review these. Reply to accept them as-is, or send corrections such as "tests = test, drop the
> Infrastructure layer". (go / <corrections>)

This is a confirmation of a batch, not a 4th interrogation question - the 3-question rule still holds.
Anything the user does not correct is used as-is; anything still unknown stays `<<placeholder>>`.

---

## Phase 3 - Interactive questions

Ask **three** critical questions. Provide defaults from Phase 2 inference where possible.

### Q1: Ticket system

> What ticket system does this project use?
> 1. JIRA (default if existing CLAUDE.md mentions JIRA)
> 2. GitHub Issues
> 3. Linear
> 4. None / local only

If JIRA: ask `ticket.baseUrl` (e.g. `https://yourorg.atlassian.net/browse`).

> Heads up: automatic ticket-context fetch is **JIRA-only** today - the `sd-spec-architect` agent
> ships with Atlassian MCP tools only. GitHub Issues and Linear are still recorded as the project
> tracker (so the prompt hook recognizes their ID format), but their ticket content is **not**
> auto-fetched. For those, paste the relevant ticket details into the prompt when you start a
> workflow.

### Q2: Ticket pattern

> What ticket ID pattern should the hook recognize?
> Examples:
>   - JIRA: `^[A-Z]+-[0-9]+$` (e.g. INV-2501)
>   - GitHub: `^#[0-9]+$` (e.g. #1247)
>   - Custom: enter your own regex

Validate the pattern compiles.

### Q3: OS and shell

> Which shell will this project be developed with?
> 1. PowerShell (Windows)
> 2. Bash / Zsh (Unix / macOS)
> 3. Both (write settings.json for both; user picks one)

This determines which hook variant the generated `settings.json` references.

---

## Phase 4 - Generate CLAUDE.md

1. If existing `CLAUDE.md` is present:
   - Backup to `CLAUDE.md.bak.<YYYYMMDD-HHmmss>`.
   - Merge: take stack hints from existing into the new template; preserve user-customized sections under "## Code conventions" and "## Forbidden patterns" verbatim if they exist.
2. Generate new `CLAUDE.md` from `~/.claude/templates/sd/CLAUDE.template.md`:
   - Substitute `<<project-name>>` -> from current directory name or git remote.
   - Pre-fill the Stack, Commands, and Architecture sections from Phase 2.5 detected facts (including
     the layer list from `paths.layers`, rendered inside-out). Leave any field not detected and not
     confirmed in the Phase 2.5 gate as `<<placeholder>>` for the user to fill.
3. Display a diff summary (new vs old).

---

## Phase 5 - Scaffold .specs/

1. Create `.specs/` directory if missing.
2. Write `.specs/constitution.md` from `~/.claude/templates/sd/constitution.template.md`:
   - Substitute `<<project-name>>` and frontmatter fields.
   - Leave all rule placeholders as `<<placeholder>>` (the user must declare rules explicitly).
3. Write `.specs/index.md`:

```
# Spec index

Active specs (auto-updated by /sd:spec status transitions):

| ID | Type | Status | Created | Title |
|---|---|---|---|---|
```

4. Create empty subdirectories: `.specs/_explorations/`, `.specs/_reviews/`, `.specs/_adr/`.
5. If `.specs/constitution.md` already existed, do NOT overwrite. Print "Constitution already present - skipping. Edit manually if needed."

---

## Phase 6 - Scaffold .claude/

1. Create `.claude/` directory if missing.
2. Write `.claude/project-config.json` from `~/.claude/templates/sd/project-config.template.json`:
   - Set `version` to the installed engine version read in Phase 0 (not the template's literal
     `1.0.0`).
   - Substitute project name, owner (from git config), repo URL (from git remote).
   - Set `ticket.system`, `ticket.pattern`, `ticket.baseUrl` from Phase 3 Q1/Q2.
   - Set `commands.{build,test,lint,coverage,run}` from Phase 2.5 detected facts; any command not
     declared by the project manifest stays `<<placeholder>>`.
   - Set `paths.{src,tests,docs}` from Phase 2.5 detected facts.
   - Set `paths.layers` from Phase 2.5 as an ordered inside-out array of `{name, path}` objects
     (innermost first); write `[]` if no layered structure was detected.
   - Leave MCP servers `enabled: false` by default. Print: "MCP servers are disabled by default. Enable them by editing `.claude/project-config.json` after installing the corresponding MCP servers in `~/.claude.json`."
3. Write `.claude/settings.json` from the appropriate variant per Phase 3 Q3:
   - PowerShell -> use `settings.template.json` as-is.
   - Bash -> swap `powershell -NoProfile ...` invocations for `bash <path>.sh`.
   - Both -> write both, comment in the file noting which is active.
4. Backup any existing `.claude/settings.json` first.

---

## Phase 7 - Validate + report

1. Grep the generated `CLAUDE.md` for remaining `<<placeholder>>` tokens. List them.
2. Grep `.specs/constitution.md` for remaining `<<placeholder>>` tokens. List them.
3. Validate `.claude/project-config.json` is parseable JSON.
4. Validate `.claude/settings.json` is parseable JSON.
5. **Verify hooks resolve.** For each hook `command` in `.claude/settings.json`, expand
   `${HOME}`/`~` and confirm the script file exists on disk. Warn loudly for any miss (the hook is
   not firing) and point the user at `install/install.ps1` / `install/install.sh`. Same check as
   Phase 1.5; on a fresh scaffold it confirms the just-written settings point at really-installed
   hooks.
6. Print report:

```
Setup complete. Generated:
  - CLAUDE.md (N placeholders to fill)
  - .specs/constitution.md (N placeholders to fill)
  - .specs/index.md (empty registry)
  - .claude/project-config.json (M MCP servers disabled)
  - .claude/settings.json (hooks: session-context, prompt-router, spec-gate, subagent-retro)

Installed engine paths:
  - ~/.claude/commands/sd/     (14 workflow commands)
  - ~/.claude/agents/sd/       (6 specialist agents)
  - ~/.claude/hooks/sd/        (4 hooks)
  - ~/.claude/templates/sd/    (templates)
  - ~/.claude/skills/sd/       (11 skills: severity-taxonomy, hypothesis-tree, atomic-task-format, evidence-citation, spec-templates, pattern-discipline, retro-lessons, replan-loop, port-fidelity, bootstrap-guard, model-escalation)

Next steps:
  1. Fill placeholders in CLAUDE.md and .specs/constitution.md (open them in your editor).
  2. Enable MCP servers you use in .claude/project-config.json under the "mcp" section.
  3. Restart Claude Code so hooks are picked up.
  4. Try: /sd:explore "where is the entrypoint" to verify the install works.
```

---

## Rules (hard constraints)

- **Idempotent.** Safe to re-run. Never overwrites without a timestamped backup.
- **Migrates drift, never silently.** Phase 1.5 detects content drift in existing `.claude/*` (renamed engine paths/URLs/command names, newly-introduced template fields, pinned model IDs) via rule-based checks against the loaded templates - never a raw line-diff, so `<<placeholder>>` and project-specific values are preserved. Every change is previewed in one batch gate, each file is backed up first, and every hook `command` path is verified to resolve on disk.
- **Stack-agnostic.** Inference uses filename heuristics + CLAUDE.md parsing. Never hardcodes .NET / Node / Python assumptions. If inference fails, the field stays as `<<placeholder>>`. <!-- contract-lint: allow CL401 - this line IS the stack-agnostic rule statement; the names are forbidden-example illustration -->
- **Scan detects facts, never rules.** Phase 2.5 may pre-fill stack, paths, commands, and
  `paths.layers` only. It never writes `.specs/constitution.md` rules - those stay `<<placeholder>>`
  for the user to author explicitly.
- **Never asks more than 3 questions.** Other fields are inferred or left as placeholders for the user to fill in their editor. Excess prompting kills adoption.
- **Never enables MCP servers automatically.** They're opt-in; user must edit project-config.json after installing the server in `~/.claude.json`.
- **Never modifies the engine** (`~/.claude/`). The setup command writes ONLY into the current working directory.
- **Generated files have no BOM.** UTF-8 only.
- If state is `complete` **and Phase 1.5 finds no drift**, the command exits without writing. If Phase 1.5 finds drift, it offers a backed-up, gated migration first (silence is never approval), then exits. The user can manually edit any generated file at any time.
