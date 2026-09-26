---
description: Read-only code exploration via sd-code-explorer. Single subagent invocation. No spec created. `--port` runs a fixed-section donor-side extraction for a later port (SW-39).
argument-hint: <target or query> | --port <entry point or symbol> --scope <endpoint|module|feature|pattern> [--snapshot contract|contract+source]
---

# /sd:explore

Fast, read-only code navigation. One `sd-code-explorer` invocation, no spec is created, no code is modified.

Two modes, selected in Phase 1:
- **Free-form query** (default) - `$ARGUMENTS` is a natural-language query. Optional save to
  `.specs/_explorations/`.
- **Port extraction** (`--port`) - a fixed-section, donor-side extraction bridging a donor
  entry point into a later host-side `PORT` spec (see `sd-port-fidelity`). This mode is
  MANDATORY-save (see Phase 3b) and never reads a host project - it describes the project this
  session is rooted in, only.

**Argument**: `$ARGUMENTS` -> free-form query, OR `--port <entry point> --scope <scope> [--snapshot
<mode>]`.

---

## Phase 0 - Bootstrap

1. Read `.claude/project-config.json` for paths and MCP servers (GitNexus enabled?).
2. Read `CLAUDE.md` for stack hints (for query intent parsing).
3. **Do NOT** require constitution or index. This command runs on any project state, including fresh repos with no `.specs/`.

---

## Phase 1 - Parse arguments

1. Check whether `$ARGUMENTS` contains the `--port` flag.
   - Present -> go to **Phase 1b**. Phase 1a does not run.
   - Absent -> go to **Phase 1a**, the original free-form-query behavior, unchanged.

### Phase 1a - Parse intent (free-form query)

Inspect `$ARGUMENTS` to detect intent. Detect by keyword first, fall back to `pattern` if nothing matches.

| Pattern in query | Detected intent | `INTENT` value |
|---|---|---|
| "where is <X>", "define <X>", "definition of <X>" | Find definition | `definition` |
| "who calls <X>", "callers of <X>", "uses of <X>" | Find callers | `callers` |
| "trace <X>", "how does <X> flow", "follow <X>" | Trace execution | `trace` |
| "what depends on <X>", "impact of changing <X>" | Impact map | `impact` |
| "show all <X>", "list <X> patterns", "find all <pattern>" | Pattern search | `pattern` |
| "show structure", "overview", "layout of <module>" | Structural overview | `structure` |
| anything else | Default | `pattern` |

Print: "Detected intent: <INTENT>. Routing to sd-code-explorer."

### Phase 1b - Parse port-extract arguments

Grammar: `--port <entry point or symbol> --scope <endpoint|module|feature|pattern> [--snapshot
contract|contract+source]`.

1. `ENTRY_POINT` = the text between `--port` and the next `--` flag (or end of string), trimmed.
   STOP if empty: "`--port` requires an entry point or symbol."
2. `SCOPE` = the value following `--scope`. STOP if missing, or not one of `endpoint`, `module`,
   `feature`, `pattern`: "`--scope` is required with `--port` and must be one of endpoint /
   module / feature / pattern."
3. `SNAPSHOT` = the value following `--snapshot` when present, else `contract`. STOP if present
   and not one of `contract`, `contract+source`.
4. Print: "Port extraction: ENTRY_POINT=<ENTRY_POINT>, SCOPE=<SCOPE>, SNAPSHOT=<SNAPSHOT>.
   Routing to sd-code-explorer."

---

## Phase 2 - Invoke `sd-code-explorer`

### Standard exploration - Invoke `sd-code-explorer`

Runs only when Phase 1a ran.

1. Invoke `sd-code-explorer` with:
   - `TASK = standalone`
   - `DETECTED_INTENT = <INTENT from Phase 1a>`
   - `QUERY = $ARGUMENTS`
   - `GITNEXUS_AVAILABLE = <true|false from project-config.mcp.gitnexus.enabled>`

Explorer routes internally based on `DETECTED_INTENT`:
- `definition` -> GitNexus `context`, fallback to `Grep` for definition markers.
- `callers` -> GitNexus `impact` (`direction: upstream`), fallback to `Grep` for invocation patterns.
- `trace` -> GitNexus `impact` (`direction: downstream`, 1-2 hops).
- `impact` -> direct callers (1-hop) + transitive (2-3 hop) + tests touching the target + DI / config refs.
- `pattern` -> `Grep` with refined query, return file:line snippets.
- `structure` -> directory listing + top-level symbols per file.

### Port extraction - Invoke `sd-code-explorer`

Runs only when Phase 1b ran.

1. Invoke `sd-code-explorer` with:
   - `TASK = port-extract`
   - `ENTRY_POINT = <ENTRY_POINT from Phase 1b>`
   - `SCOPE = <SCOPE from Phase 1b>`
   - `GITNEXUS_AVAILABLE = <true|false from project-config.mcp.gitnexus.enabled>`

Explorer fills all eight fixed sections (Entry surface, Output surface, Member closure,
Complement set, Collaborators, Non-obvious invariants, Dead paths on this entry point, Precedent
conventions), each `file:line`-cited or explicitly `None found (searched: ...)`. `SNAPSHOT` is
never passed to the agent - it only controls what the command itself does in Phase 3b.

Explorer's output discipline (both branches): every finding cites `file:line`. No prose without citations.

---

## Phase 3 - Present and save output

### Phase 3a - Present output (free-form query)

Runs only when Phase 1a ran.

1. Display the explorer's findings inline.
2. Group by source file when more than 5 hits in one file.
3. At the bottom, offer:

> Save this exploration? (yes / no)

- `no` (default if user does not respond positively) -> end.
- `yes` -> proceed to save:
  1. Slugify the query for a filename: lowercase, alphanumerics + hyphens, max 40 chars.
  2. Write to `.specs/_explorations/<slug>-<YYYYMMDD-HHmm>.md`.
  3. File contents:
     ```
     ---
     type: exploration
     query: "<original query>"
     detected_intent: <INTENT>
     created: <ISO timestamp>
     ---

     # Exploration: <query>

     <explorer output>
     ```
  4. Print the saved path.

The `.specs/_explorations/` folder is NOT tracked in `.specs/index.md` - it's a scratchpad, not a workflow spec.

### Phase 3b - Save port-extract output (mandatory)

Runs only when Phase 1b ran. Unlike Phase 3a, this save is NOT optional and is NOT prompted - the
whole point of `--port` is a durable, donor-side artifact for a later host-side `PORT` spec.

1. Slugify `ENTRY_POINT` for a directory name: lowercase, alphanumerics + hyphens, max 40 chars.
2. Directory: `.specs/_explorations/<slug>-<YYYYMMDD-HHmm>/` - a DIRECTORY, not a flat file. This
   is the one place `--port`'s save differs structurally from Phase 3a's, because a
   `contract+source` snapshot needs a subtree.
3. Compute `source_commit` in this project's own working tree (the donor - this command never
   touches a second project):
   - Run `git rev-parse HEAD`.
   - Run `git status --porcelain`.
     - Non-empty -> the tree is dirty. Do NOT record a sha as if the tree were clean. Write:
       `source_commit: dirty (uncommitted changes present as of <ISO timestamp>)`.
     - Empty -> `source_commit: <full sha from the first command>`.
4. Write `<dir>/contract.md`:
   ```
   ---
   type: port-extraction
   entry_point: "<ENTRY_POINT>"
   scope: <SCOPE>
   snapshot: <SNAPSHOT>
   source_commit: <sha, or the dirty-tree sentence from step 3>
   created: <ISO timestamp>
   ---

   # Port extraction: <ENTRY_POINT>

   <explorer's eight-section output, verbatim>
   ```
5. Only when `SNAPSHOT = contract+source`:
   1. Create `<dir>/source/`.
   2. For every distinct `Donor path` in the explorer's Member closure and Complement set tables,
      copy that donor file into `<dir>/source/<same relative path>` (create parent directories as
      needed; copy each path once even if several rows share it).
   3. Compute `sha256` (lowercase hex) and byte count for each copied file, over the bytes as
      captured.
   4. Resolve the donor identity for the manifest header: `project.repo` from
      `.claude/project-config.json` (Phase 0); if absent, `git remote get-url origin`; if that
      also fails, the repo's local path.
   5. Write `<dir>/source/MANIFEST.md`, in the exact format `sd-port-fidelity`'s "Snapshot
      artifacts" section defines:
      ```
      - **Donor**: <resolved donor identity from step 5.4>
      - **Commit**: <sha, or the dirty-tree sentence from step 3>
      - **Captured**: <YYYY-MM-DD>
      - **Mode**: contract+source
      - **Hash algorithm**: sha256, lowercase hex, over the bytes as captured

      | Snapshot path | Donor path | Commit | Bytes | SHA-256 | Member ranges |
      |---|---|---|---|---|---|
      | `<path under source/>` | `<same donor-relative path>` | `<sha>` | `<bytes>` | `<hash>` | `<ordinal: member firstLine-lastLine; ...>` |
      ```
      One row per copied file. `Member ranges` groups the Member closure table's rows for that
      `Donor path`, semicolon-separated, ordinals contiguous from 1 - the input the host's Member
      manifest table will be built from.
6. Print the saved path(s): `<dir>/contract.md`, and `<dir>/source/` + its `MANIFEST.md` when
   step 5 ran.
7. Tell the user: "This bundle is intended to be copied verbatim into the host spec's
   `04-artifacts/source/` directory once that `PORT` spec exists. Copying between the two repos
   is a manual or scripted step outside this command."

---

## Rules (hard constraints)

<!-- sd-model-escalation: no rule -
     single read-only sd-code-explorer call per run, and no spec frontmatter exists to read a
     trigger from (no 00-spec.md is created, in either branch). Decided in SW-62, not forgotten. -->
- Read-only invocation. Code-explorer's tool allowlist does not include `Write`, `Edit`,
  `MultiEdit`, or `Bash` write modes, in either branch. The command MUST NOT escalate the
  AGENT's allowlist - the agent always returns text only.
- `--port` is the only other supported flag today (the same style of extension `--calibration`
  established for `/sd:status`). `--scope` is required alongside `--port`; `--snapshot` is
  optional, defaulting to `contract`.
- Phase 3b's `git rev-parse` / `git status --porcelain` / file copy / hash steps are run by the
  COMMAND, never by `sd-code-explorer`. This is not a new escalation: the command has always had
  `Write` (Phase 3a already writes an exploration file today) - it is the same main-thread
  read/write surface, just exercised for a second purpose, and it never runs inside the agent
  invocation.
- No spec lifecycle is started, in either branch. No `00-spec.md` is created. A `--port`
  extraction is a scratchpad artifact, not itself a `PORT` spec - authoring the spec is a
  separate, later step outside this command.
- Every finding cites `file:line`. If a finding has no citation, the explorer is misbehaving and
  should be re-prompted.
- If GitNexus is disabled or unavailable, fall back to grep / read - in both branches. Tell the
  user "GitNexus disabled, using grep fallback - results may be less precise on transitive
  callers, dynamic dispatch, and DI-resolved collaborators."
- If the user follows up an exploration with "now fix X" or "now refactor X", REDIRECT to the
  appropriate workflow command (`/sd:bug`, `/sd:refactor`, etc.). Do not implement inline.
- Save destination is always `.specs/_explorations/`. Phase 3a's save is a flat file, optional,
  prompted (default no). Phase 3b's save (`--port`) is a directory, mandatory, never prompted.
  Neither is tracked in `.specs/index.md`. If `.specs/` does not exist, create the underscore
  folder ad-hoc; this does not require `/sd:setup`.
- `--port` never reads, infers, or names a host project. This command runs rooted at one project
  only - the Layer 2 boundary (a session loads at most one project's `CLAUDE.md` and
  constitution) holds in both branches.
