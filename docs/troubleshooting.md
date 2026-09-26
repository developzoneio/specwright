# Troubleshooting

Common issues and fixes. Skim the table of contents first; the fix you need is usually one section away.

## Contents

- [Install issues](#install-issues)
- [Hooks not firing](#hooks-not-firing)
- [Workflow issues](#workflow-issues)
- [Spec issues](#spec-issues)
- [Porting issues](#porting-issues)
- [Spec-gate blocking unexpectedly](#spec-gate-blocking-unexpectedly)
- [Spec metrics log](#spec-metrics-log)
- [MCP issues](#mcp-issues)
- [Resetting](#resetting)

---

## Install issues

### `Missing required source directories`

```
[FAIL] commands
[FAIL] agents
...
Missing required source directories. Are you running this from a clean specwright checkout?
```

**Cause**: you ran the installer from outside the repo root.

**Fix**: `cd` to the repo root (the directory containing `install/`, `commands/`, etc.) and re-run. The installer derives the repo root from its own location, so it must be invoked as `.\install\install.ps1` or `./install/install.sh`, not from inside `install/`.

### `install.ps1 cannot be loaded because running scripts is disabled`

**Cause**: PowerShell execution policy restricts script files.

**Fix**: invoke with bypass:
```powershell
powershell -ExecutionPolicy Bypass -File install\install.ps1
```
Or persist the policy for your user:
```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

### `bash: ./install/install.sh: Permission denied`

**Cause**: `+x` bit not set on the installer (e.g. after extracting a `.zip` on macOS).

**Fix**:
```bash
chmod +x install/install.sh
./install/install.sh
```

### `jq: command not found` (Unix only, when hooks run)

**Cause**: bash hooks use `jq` for JSON parsing. Without it, hooks exit `0` silently - your workflow still functions, but the hooks contribute nothing.

**Fix**:
```bash
# macOS
brew install jq
# Debian/Ubuntu
sudo apt install jq
# Fedora
sudo dnf install jq
```

### Hooks installed but `~/.claude/hooks/sd/*.sh` not executable

**Cause**: rare - the installer ran with an unusual umask or as a different user than expected.

**Fix**:
```bash
chmod +x ~/.claude/hooks/sd/*.sh
```

---

## Hooks not firing

If `/sd:*` commands work but `<context-router>` blocks never appear, run through these checks in order.

### Check 1: `settings.json` wires hooks for THIS project

`/sd:setup` writes `.claude/settings.json` per project. Without it, Claude Code does not invoke any hooks. Verify:

```bash
cat .claude/settings.json
```

The file should contain `hooks` entries for `SessionStart`, `UserPromptSubmit`, `PreToolUse`, and `SubagentStop`. If empty or missing, re-run `/sd:setup`.

In-progress specs no longer appear on each prompt? Since SW-67 they come from the `SessionStart`
hook (`session-context`), once per session start, resume, fork, compact or clear - not from
`prompt-router`. A project set up before SW-67 has no `SessionStart` entry; re-run `/sd:setup`,
whose drift check adds it.

### Check 2: Hook scripts are executable (Unix)

```bash
ls -l ~/.claude/hooks/sd/
```

Every `.sh` hook should have `-rwxr-xr-x`. If not:
```bash
chmod +x ~/.claude/hooks/sd/*.sh
```

### Check 3: Hooks are enabled in project-config

```bash
cat .claude/project-config.json
```

Look at the `hooks` section:
```json
"hooks": {
  "sessionContext":   { "enabled": true },
  "userPromptRouter": { "enabled": true },
  "specGate":         { "enabled": true, "mode": "warn" },
  "subagentRetro":    { "enabled": true, "retroStaleMinutes": 30, "debounceMinutes": 10 }
}
```

If any is `"enabled": false`, that hook is intentionally silent.

### Check 4: PowerShell execution policy (Windows)

Even when invoked via `powershell -NoProfile -ExecutionPolicy Bypass`, some systems are locked down further. Test manually:

```powershell
'{"prompt":"fix bug INV-2501","cwd":"' + (Get-Location).Path + '"}' | powershell -NoProfile -ExecutionPolicy Bypass -File $env:USERPROFILE\.claude\hooks\sd\prompt-router.ps1
```

If this errors with execution policy complaints, your system's group policy may be overriding the `-ExecutionPolicy Bypass`. Talk to your admin.

### Manually verify a hook works

Pipe a JSON payload to the hook and check the output:

**Unix:**
```bash
echo '{"prompt":"fix bug INV-2501","cwd":"'"$PWD"'"}' | ~/.claude/hooks/sd/prompt-router.sh
```

**Windows:**
```powershell
'{"prompt":"fix bug INV-2501","cwd":"' + (Get-Location).Path + '"}' | powershell -File "$env:USERPROFILE\.claude\hooks\sd\prompt-router.ps1"
```

Expect a `<context-router>` block on stdout. Empty output means no signal was detected (which is correct behavior for prompts without keywords or tickets).

---

## Workflow issues

### Phase 0 aborts: "Constitution not found"

**Cause**: `.specs/constitution.md` does not exist in the project.

**Fix**: run `/sd:setup`. If it ran before but the constitution was deleted, re-run `/sd:setup` - it will detect `partial` state and recreate the missing file.

### Workflow refuses to proceed at a hard gate

This is **by design**. Hard gates exist precisely to prevent skipping steps. The workflow tells you what is missing. Options:

1. **Provide what's missing.** For `/sd:bug` Gate 2 (Reproduction), gather telemetry or reproduce locally. For `/sd:perf` Gate 2 (Baseline), run the benchmark and check in the artifact.
2. **Log a constitution exception.** If you have a defensible reason to skip, the workflow accepts that with explicit acknowledgement and logs to `05-retro.md`. The exception is visible at audit time.
3. **Abort.** Spec stays at its current state; you can resume later by re-running the command.

The system surfaces the choice. The human decides.

### Workflow restarts from Phase 1 when I want to resume

**Cause**: the state-machine detection saw something it interpreted as "fresh start" - usually because a key file is missing.

**Fix**: check `.specs/<ID>/` for the expected files. Each workflow's state-machine table lists what should be present at each state. If a file is missing (e.g. you deleted `02-tasks.md` thinking it was scratch), the workflow correctly detects the earlier state. Restore the file or accept the restart.

### Subagent invocation errors

```
The spec-architect agent failed due to a model access issue.
```

**Cause**: the agent's `model:` field in frontmatter is invalid OR your account doesn't have access to that model.

**Fix**: agents must use **aliases** (`sonnet`, `haiku`, `opus`, `inherit`). If the file has a full model ID like `claude-sonnet-4-7` or `claude-sonnet-4-6`, replace with the alias:

```yaml
model: sonnet   # NOT model: claude-sonnet-4-7
```

If aliases also fail, verify your Claude Code account has access to the relevant model tier.

---

## Spec issues

### `.specs/index.md` is out of sync with folder contents

**Cause**: a spec was moved, archived, or status-changed by a tool that didn't update the index (e.g. you manually edited a file's frontmatter).

**Fix**:
```
/sd:spec validate --all
```

This lists every inconsistency. Then fix manually (recommended) or remove the misaligned row from the index and re-add via `/sd:spec status`.

### "Illegal status transition: draft -> done"

**Cause**: skipping intermediate states.

**Fix**: lifecycle is `draft -> approved -> in-progress -> done`. Use `/sd:spec status <ID> approved` then `in-progress` then `done`. Every workflow (`/sd:feature`, `/sd:bug`, `/sd:refactor`, `/sd:perf`, `/sd:rca`) walks all four states itself, including specs with no code execution (e.g. an RCA or a PERF spec whose baseline already meets SLA) - don't manually transition mid-workflow.

### A spec is stuck in `in-progress` for weeks

**Cause**: workflow aborted mid-execution; nothing pulled it forward to `done`.

**Fix**:
- Re-run the original command: `/sd:feature <arg>`. The state machine resumes at the right phase.
- If the work was abandoned, transition to `done` with a retro note explaining why: `/sd:spec status <ID> done` and edit `05-retro.md`.

### `/sd:spec stats` shows aging warnings

The aging report flags specs in `in-progress` > 7 days and `draft` > 14 days (defaults). These are signals, not errors. Decide per case: resume, close, or archive.

---

## Porting issues

### The host build or lint now fails on files under `.specs/<PORT-ID>/04-artifacts/source/`

**Cause**: the frozen snapshot is a real subtree of the repo, so a build or lint step that globs
the whole repo root picks up donor files that were never meant to compile or lint against this
project's rules.

**Fix**: add a `.specs/` exclusion to the host's own build/lint configuration. `/sd:port` Phase 2
warns about this when no such exclusion is found, but deliberately does not edit that
configuration itself (out of scope). Alternatively, freeze with `--snapshot contract` when the
donor source does not need to sit on disk.

### Coverage dropped the moment the snapshot was frozen

**Cause**: the coverage tool counts the frozen snapshot files as uninstrumented source.

**Fix**: exclude `.specs/` from `commands.coverage`, re-measure, and compare quality bars (e.g.
`quality.refactorCoverageThreshold`) against the corrected number. `/sd:port` never edits coverage
configuration itself, same as the build/lint case above.

### `/sd:port` Gate 3 refuses: host production tree is dirty

**Cause**: uncommitted or untracked changes under `paths.src` (or a declared `paths.layers` path)
make the Phase 8 parity diff unattributable - a hunk in the parity diff could be prior work, not
part of the port.

**Fix**: commit or stash those changes under their own spec, then re-run the check. The gate has no
override; it re-runs `git diff --quiet` / `git status --porcelain` and refuses until both are
empty.

### spec-gate blocks an edit under `04-artifacts/source/`

**Cause**: `/sd:port` Phase 2 appended those exact paths, plus `MANIFEST.md`, to `paths.protected`
at freeze time - `spec-gate` matches by exact string, not glob.

**Fix**: this is by design - the snapshot is frozen evidence. If the freeze itself was wrong, use
Gate 1's `re-capture` resolution, which removes exactly the entries it added. Note `spec-gate`
guards `Edit`/`Write` only - it does not stop a shell delete.

### The port parity diff has to be produced by hand

**Cause**: `sd-reviewer`'s `port-parity` mode reads a diff artifact it cannot produce - it has no
`Bash` and no write tool, deliberately, because the adjudicator must not be able to fix what it
judges. `/sd:port` Phase 8 now generates `04-artifacts/parity/` for you before invoking the
reviewer, so this only applies when adjudicating a port outside the `/sd:port` pipeline.

**Fix**: generate `04-artifacts/parity/` yourself - one unified diff per non-`omit` path mapping
row (snapshot side first), an all-deletion diff for a row whose host file is absent, an
all-addition diff for a changeset file with no row, and an `INDEX.md` listing them all. The exact
layout is in `sd-port-fidelity`'s "Parity artifacts" section, and `examples/port-parity-fixture/`
is a worked pair whose shape you can copy.

---

## Spec-gate blocking unexpectedly

### Editing a file that should be safe and getting `decision=block`

**Cause**: the file matches `paths.protected` in `.claude/project-config.json`.

**Fix**: check the list:
```bash
jq '.paths.protected' .claude/project-config.json
```

If a path is there by mistake, remove it. If it should stay protected, update the file via a refactor spec (the protection exists for a reason).

### Spec-gate blocks me even when I HAVE a spec in progress

**Cause**: most often, the in-progress spec is recorded in `00-spec.md` frontmatter but **not** mirrored in `.specs/index.md`. The hook reads the index.

**Fix**:
```
/sd:spec validate --all
```
If the index row is missing or has the wrong status, fix it via `/sd:spec status <ID> in-progress` or by editing `.specs/index.md` directly with the Edit tool to add the row. A shell write to it
(`sed -i`, `>`, `Set-Content`) is denied by design (SW-79).

### I want to disable spec-gate temporarily

Set `hooks.specGate.mode` to `"off"` in `.claude/project-config.json`. Don't forget to flip back. A separate setting `hooks.specGate.enabled: false` disables it entirely.

---

## Spec metrics log

### `.specs/_metrics/events.jsonl` keeps growing

**Cause**: `spec-gate` and `subagent-retro` each append one line per gate decision, `.specs/index.md` lifecycle transition, or subagent-stop check. Each line is small (roughly 120 bytes). The log is bounded by `hooks.metrics.maxSizeKb` (default `1024` = ~1 MB): when the live file reaches the cap, the next write rolls it to `events.jsonl.1` and starts fresh, keeping at most one previous generation. If you see the *live* file far past 1 MB, either `maxSizeKb` is set to `0` (rotation disabled), or every roll is failing silently - most likely a read-only `_metrics/` directory or the file being held open, both of which degrade to "keep appending" by design.

**Fix**: no action needed for normal growth - it rotates itself. To change the cap, set `hooks.metrics.maxSizeKb` (in KB) in `.claude/project-config.json`; set it to `0` to disable rotation entirely. To stop all writes instead:
```json
"hooks": {
  "metrics": { "enabled": false }
}
```
Existing lines are left untouched; only future writes stop. Note that the consumer of the metrics log, `/sd:status`, reads only the live `events.jsonl` - `events.jsonl.1` is a grace buffer and a generation may be discarded on the next roll, so do not rely on `.1` for a complete history.

### Is it safe to commit or share `.specs/_metrics/events.jsonl`?

**Yes, by design.** Every line is metadata only: a timestamp, a spec ID, a lifecycle phase, an event kind and decision, and (for code-edit gates) a lowercased file extension. It never contains a file path, a file name, or any code content - see `docs/architecture.md`'s event log schema for the exact field list.

Whether to actually commit it is still your call, not the engine's. If you'd rather keep it purely local, add `.specs/_metrics/` to the project's `.gitignore` yourself - specwright does not add this entry automatically.

---

## MCP issues

### Atlassian: "Failed to fetch ticket"

**Cause**: MCP server not configured OR authentication expired OR ticket ID outside the configured project.

**Fix**:
1. Verify the server is installed and connected in Claude Code (settings -> MCP).
2. Re-authenticate the Atlassian connector if the auth flow has expired.
3. Check `ticket.baseUrl` and `ticket.pattern` in `.claude/project-config.json` match the ticket you provided.

### Context7: docs feel stale

**Cause**: Context7 indexes versioned docs. If your project pins an old version, that's what you'll get (correct behavior).

**Fix**: in the implementer or debugger invocation, specify the version explicitly via the `resolve-library-id` call. Or - better - check that your project's stated library version in `CLAUDE.md` matches reality.

### GitNexus: "No index for this repo"

**Cause**: GitNexus indexes on first run; large repos take time. Or your `.gitnexus/` directory was cleared.

**Fix**: trigger a re-index from the GitNexus client. While indexing, code-explorer falls back to grep with a noted caveat.

### Database: "Cannot execute UPDATE / DELETE / INSERT"

**Cause**: this is the intended behavior. The debugger has read-only access by constitution.

**Fix**: if you need to mutate state to test a hypothesis, do it outside the workflow (your DB client, a migration, a feature spec). Then re-run the debugger to verify.

---

## Resetting

### Reset a single spec

Delete the folder and the index row:
```bash
rm -rf .specs/FEAT-INV-2501
# manually remove the row in .specs/index.md (or use editor)
```

You can then re-run `/sd:feature INV-2501` from scratch.

### Reset the engine for one project

Remove `CLAUDE.md`, `.specs/`, `.claude/`:
```bash
rm -rf CLAUDE.md .specs .claude
/sd:setup
```

Backups created during the last `/sd:setup` run can be found at `CLAUDE.md.bak.<timestamp>` if you want to recover.

### Reset the engine globally

```bash
# Unix
rm -rf ~/.claude/commands/sd \
       ~/.claude/agents/sd \
       ~/.claude/hooks/sd \
       ~/.claude/templates/sd
./install/install.sh

# Windows
Remove-Item -Recurse -Force $env:USERPROFILE\.claude\commands\sd
Remove-Item -Recurse -Force $env:USERPROFILE\.claude\agents\sd
Remove-Item -Recurse -Force $env:USERPROFILE\.claude\hooks\sd
Remove-Item -Recurse -Force $env:USERPROFILE\.claude\templates\sd
.\install\install.ps1
```

This leaves your per-project specs untouched.

### Nuclear: remove everything

```bash
# from a project
rm -rf CLAUDE.md .specs .claude
# globally
rm -rf ~/.claude/commands/sd ~/.claude/agents/sd ~/.claude/hooks/sd ~/.claude/templates/sd
```

You're back to plain Claude Code.

---

## When all else fails

Open an issue at the project repository with:
- OS + shell version.
- Claude Code version (`claude --version`).
- The exact command you ran.
- The error message verbatim.
- The output of `/sd:spec validate --all` (if relevant).

Smaller reproductions are easier to fix.
