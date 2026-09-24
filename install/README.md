# Installing specwright

The installer copies the engine (commands, agents, hooks, templates) into a Claude Code base directory, under the `sd/` subfolder of each engine directory:

```
<base>/
├── commands/sd/        14 slash commands
├── agents/sd/          6 subagent definitions
├── hooks/sd/           3 hook scripts (.ps1 on Windows, .sh on Unix)
├── templates/sd/       10 templates (4 setup + 6 spec)
└── skills/sd/          11 skills (one folder per skill with SKILL.md)
```

Default base is `$HOME/.claude` (Unix) or `$env:USERPROFILE\.claude` (Windows).

---

## Default install

**Windows (PowerShell 5.1+):**
```powershell
.\install\install.ps1 -DryRun     # preview first (recommended)
.\install\install.ps1             # apply
```

**Unix / macOS (bash 4+):**
```bash
./install/install.sh --dry-run    # preview first (recommended)
./install/install.sh              # apply
```

---

## Options

| Option (PS / sh) | Default | Effect |
|---|---|---|
| `-DryRun` / `--dry-run` | off | Show the install plan; no files written. |
| `-Force` / `--force` | off | Overwrite differing files without prompting. Backups are still created. |
| `-BasePath <path>` / `--base-path <path>` | `~/.claude` | Install to a custom base directory (useful for sandboxed testing). |
| `-Prefix <name>` / `--prefix <name>` | `sd` | Namespace subfolder under each engine directory. |

---

## What gets installed

| Source (in repo) | Target (under `<base>/`) | Files | Notes |
|---|---|---|---|
| `commands/` | `commands/sd/` | 14 | `feature`, `bug`, `rca`, `refactor`, `perf`, `port`, `spec`, `explore`, `review`, `setup`, `release`, `adr`, `verify`, `status` |
| `agents/` | `agents/sd/` | 6 | `sd-spec-architect`, `sd-code-explorer`, `sd-debugger`, `sd-implementer`, `sd-reviewer`, `sd-docs-writer` |
| `hooks/powershell/` (Windows installer) | `hooks/sd/` | 3 | `prompt-router.ps1`, `spec-gate.ps1`, `subagent-retro.ps1` |
| `hooks/bash/` (Unix installer) | `hooks/sd/` | 3 | `prompt-router.sh`, `spec-gate.sh`, `subagent-retro.sh` (chmod +x applied) |
| `templates/` | `templates/sd/` | 4 + 6 | Setup templates + `specs/` subfolder with 6 spec templates |
| `skills/` | `skills/sd/` | 11 | One folder per skill, each with a `SKILL.md` |
| _(generated at install)_ | `<area>/sd/specwright-version.txt` | 5 | One version stamp per installed area, derived from `CHANGELOG.md`'s newest release, removed by uninstall |

**Total**: 49 files per OS.

---

## Behavior on existing files

The installer is **idempotent**:

1. **Identical content** (SHA256 match) -> silently skipped. No backup, no overwrite.
2. **Different content, no `-Force`** -> interactive prompt:
   ```
   Overwrite 'foo.md' ? [y/N/a=all]
   ```
   - `y` -> back up existing as `<file>.bak.<yyyyMMdd-HHmmss>` then copy.
   - `N` (default if you press Enter) -> skip; existing file untouched.
   - `a` -> answer `y` to all remaining prompts in this run.
3. **Different content, `-Force`** -> always overwrite, but a timestamped backup is still created.

This means: running the installer twice in a row produces no churn. Upgrading produces backups you can roll back to.

---

## Verification

After install, check the target directories:

**Windows:**
```powershell
Get-ChildItem $env:USERPROFILE\.claude\commands\sd\     # expect 14 .md files
Get-ChildItem $env:USERPROFILE\.claude\agents\sd\       # expect 6 .md files
Get-ChildItem $env:USERPROFILE\.claude\hooks\sd\        # expect 3 .ps1 files
Get-ChildItem $env:USERPROFILE\.claude\templates\sd\    # expect 5 files + specs\ folder
```

**Unix:**
```bash
ls ~/.claude/commands/sd/      # 14 .md files
ls ~/.claude/agents/sd/        # 6 .md files
ls ~/.claude/hooks/sd/         # 3 .sh files (executable)
ls -l ~/.claude/hooks/sd/      # confirm +x bits set
ls ~/.claude/templates/sd/     # 5 files + specs/ folder
```

Then in a real project:
```
cd <your-project>
claude
> /sd:setup
> /sd:explore "where is the entrypoint"
```

If `/sd:explore` returns findings with `file:line` citations, the install is working.

---

## Uninstall

Use the uninstall script. It removes exactly the five `sd/` directories the installer created
(including installer-made `.bak.*` backups inside them) and touches nothing else:

**Windows:**
```powershell
.\install\uninstall.ps1 -DryRun     # preview first (recommended)
.\install\uninstall.ps1             # apply (asks for confirmation)
```

**Unix / macOS:**
```bash
./install/uninstall.sh --dry-run    # preview first (recommended)
./install/uninstall.sh              # apply (asks for confirmation)
```

The uninstaller accepts the same `-BasePath`/`--base-path`, `-Prefix`/`--prefix`, and
`-Force`/`--force` options as the installer. It is idempotent: running it with nothing
installed exits cleanly.

**Manual fallback** (equivalent to what the script does):

**Windows:**
```powershell
Remove-Item -Recurse -Force $env:USERPROFILE\.claude\commands\sd
Remove-Item -Recurse -Force $env:USERPROFILE\.claude\agents\sd
Remove-Item -Recurse -Force $env:USERPROFILE\.claude\hooks\sd
Remove-Item -Recurse -Force $env:USERPROFILE\.claude\templates\sd
Remove-Item -Recurse -Force $env:USERPROFILE\.claude\skills\sd
```

**Unix:**
```bash
rm -rf ~/.claude/commands/sd \
       ~/.claude/agents/sd \
       ~/.claude/hooks/sd \
       ~/.claude/templates/sd \
       ~/.claude/skills/sd
```

Per-project artifacts remain in your projects until you remove them manually: `.specs/`,
`.claude/project-config.json`, `.claude/.hookstate/` (subagent-retro debounce state),
`CLAUDE.md`, and the hook wiring in `.claude/settings.json` (which now points at deleted
scripts - remove the `"hooks"` block or re-run `/sd:setup` after reinstalling).

---

## Troubleshooting basics

| Symptom | Likely cause | Fix |
|---|---|---|
| `install.ps1 cannot be loaded ... execution policy` | PS execution policy | Run: `powershell -ExecutionPolicy Bypass -File install\install.ps1` |
| `bash: ./install/install.sh: Permission denied` | Missing +x on the installer itself | `chmod +x install/install.sh` then re-run |
| `Missing required source directories` | Running from wrong directory | `cd` to the repo root (the parent of `install/`) and re-run |
| Hooks not firing in Claude Code after install | settings.json not wired in the project | Run `/sd:setup` in the project; it writes `.claude/settings.json` |
| `jq: command not found` warnings in hook output | `jq` not installed (Unix only) | Install via `brew install jq` (macOS) or `apt install jq` (Linux). Hooks exit 0 silently without it. |

Further troubleshooting in [`docs/troubleshooting.md`](../docs/troubleshooting.md).
