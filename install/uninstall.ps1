#requires -Version 5.1
<#
.SYNOPSIS
    Uninstaller for specwright from a Claude Code base directory.

.DESCRIPTION
    Removes the specwright engine directories installed by install.ps1 from a
    base path (default $env:USERPROFILE\.claude). Exactly five directories are
    removed, including any installer-created .bak.* backups inside them:

        <BasePath>\commands\sd\
        <BasePath>\agents\sd\
        <BasePath>\hooks\sd\
        <BasePath>\templates\sd\
        <BasePath>\skills\sd\

    Nothing else under the base path is touched. Per-project artifacts
    (.claude/settings.json hook wiring, .claude/.hookstate/, .specs/) are
    reported at the end but never removed by this script.

    Features:
      - Dry-run preview (-DryRun).
      - Single confirmation prompt before removal (suppressed by -Force).
      - Idempotent: running with nothing installed exits 0.

    PURE ASCII. PowerShell 5.1 reads UTF-8 without BOM as Windows-1252;
    em-dash and other non-ASCII bytes cause cascading parse errors.

.PARAMETER BasePath
    Claude Code base directory. Default: $env:USERPROFILE\.claude.

.PARAMETER Prefix
    Namespace subfolder under each engine directory. Default: sd.

.PARAMETER DryRun
    Show what would be removed without deleting anything.

.PARAMETER Force
    Skip the confirmation prompt.

.EXAMPLE
    .\uninstall.ps1 -DryRun
    .\uninstall.ps1
    .\uninstall.ps1 -BasePath C:\temp\sd-test -Force
#>

param(
    [string]  $BasePath = (Join-Path $env:USERPROFILE '.claude'),
    [string]  $Prefix   = 'sd',
    [switch]  $DryRun,
    [switch]  $Force
)

$ErrorActionPreference = 'Stop'

# ---- helpers ---------------------------------------------------------------

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host "=== $Title ===" -ForegroundColor Cyan
}

function Write-Info  { param([string]$m) Write-Host "  $m" }
function Write-OK    { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-Skip  { param([string]$m) Write-Host "  [SKIP] $m" -ForegroundColor DarkGray }
function Write-Plan  { param([string]$m) Write-Host "  [PLAN] $m" -ForegroundColor Yellow }
function Write-Warn  { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Write-Fail  { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red }

# ---- prefix safety guard ---------------------------------------------------

if ([string]::IsNullOrWhiteSpace($Prefix) -or
    $Prefix.Contains('/') -or $Prefix.Contains('\') -or $Prefix.Contains('..')) {
    Write-Fail "Invalid prefix '$Prefix'. Must be a plain folder name (no separators, no '..')."
    exit 1
}

# ---- base-path safety guard -------------------------------------------------
# Mirrors install.ps1's guard exactly - install and uninstall must accept the
# same set of base paths, or a base path legal for one and rejected by the
# other leaves orphaned or unreachable files.

if ([string]::IsNullOrWhiteSpace($BasePath)) {
    Write-Fail "Invalid base path '$BasePath'. Must not be empty or whitespace-only."
    exit 2
}

Write-Section 'specwright uninstaller'
Write-Info  "Script:    $PSCommandPath"
Write-Info  "Base path: $BasePath"
Write-Info  "Prefix:    $Prefix"
Write-Info  ("Mode:      " + ($(if ($DryRun) { 'DRY RUN (no changes)' } else { 'UNINSTALL' })) + ($(if ($Force) { ' [Force]' } else { '' })))

# ---- enumerate targets -----------------------------------------------------

# Same five areas the installer writes to.
$areas = @('commands', 'agents', 'hooks', 'templates', 'skills')

Write-Section 'Removal plan'

$targets = @()
$totalFiles = 0
$totalBackups = 0

foreach ($a in $areas) {
    $dir = Join-Path (Join-Path $BasePath $a) $Prefix
    if (Test-Path -LiteralPath $dir -PathType Container) {
        $files = @(Get-ChildItem -LiteralPath $dir -File -Recurse)
        $backups = @($files | Where-Object { $_.Name -match '\.bak\.\d{8}-\d{6}$' })
        Write-Plan ("$dir (" + $files.Count + " file(s))")
        $targets += [pscustomobject]@{ Dir = $dir; Files = $files.Count }
        $totalFiles += $files.Count
        $totalBackups += $backups.Count
    } else {
        Write-Skip "$dir (not found)"
    }
}

if ($totalBackups -gt 0) {
    Write-Warn "$totalBackups installer backup file(s) (.bak.*) will be deleted too."
}

if ($targets.Count -eq 0) {
    Write-Host ''
    Write-OK 'Nothing to remove.'
    exit 0
}

# ---- dry run stops here ----------------------------------------------------

if ($DryRun) {
    Write-Section 'Summary'
    Write-Info ("Would remove: $totalFiles file(s) across " + $targets.Count + " director(ies)")
    Write-Info ''
    Write-Info 'Run without -DryRun to apply.'
    exit 0
}

# ---- confirm ---------------------------------------------------------------

if (-not $Force) {
    $ans = Read-Host -Prompt ("Remove $totalFiles file(s) across " + $targets.Count + " director(ies)? [y/N]")
    if ($ans -ne 'y') {
        Write-Skip 'Aborted. Nothing removed.'
        exit 0
    }
}

# ---- remove ----------------------------------------------------------------

Write-Section 'Removing'

$removedDirs = 0
foreach ($t in $targets) {
    Remove-Item -LiteralPath $t.Dir -Recurse -Force
    Write-OK $t.Dir
    $removedDirs++
}

# ---- summary ---------------------------------------------------------------

Write-Section 'Summary'
Write-Info ("Removed: $totalFiles file(s) across $removedDirs director(ies)")

Write-Section 'Per-project leftovers (not touched by this script)'
Write-Info '1. Projects that wired hooks in .claude/settings.json now point at deleted'
Write-Info '   scripts. Remove the "hooks" block there, or re-run /sd:setup after a reinstall.'
Write-Info ''
Write-Info '2. Per-project artifacts remain until you remove them manually:'
Write-Info '     .claude\.hookstate\          (subagent-retro debounce, PreCompact pointers)'
Write-Info '     .claude\project-config.json'
Write-Info '     .specs\'
Write-Info '     CLAUDE.md'

exit 0
