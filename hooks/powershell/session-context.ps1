#requires -Version 5.1
<#
.SYNOPSIS
    specwright: SessionStart hook - session-context.

.DESCRIPTION
    Reads Claude Code hook JSON from stdin. Extracts the session cwd and the
    SessionStart `source`, resolving the project root from the cwd (SW-78).
    Loads .claude/project-config.json (or sane defaults if absent) and emits a
    <session-context> block with the parts of the spec context that do not
    change within a session (SW-67):
      1. The constitution pointer (spec.constitutionFile), when the file exists.
      2. Every spec marked in-progress in .specs/index.md, with its title from
         the index row and its `status:` from <spec.dir>/<ID>/00-spec.md.

    SessionStart fires on startup, resume (which covers --continue), fork,
    compact and clear (ADR 0015). Every source gets the same block; the source
    is only echoed in the header. prompt-router keeps the per-prompt part.

    The hook is defensive: any failure exits 0 silently to avoid blocking the
    user. It never writes to disk.

.NOTES
    PURE ASCII ONLY. PowerShell 5.1 reads UTF-8 without BOM as Windows-1252;
    a single em-dash byte sequence will cascade into "Missing closing '}'"
    parse errors. Use ASCII hyphen-minus, "->", "[OK]", "[WARN]" etc.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'

function Read-StdinJson {
    try {
        $raw = [Console]::In.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
}

# SW-78: `cwd` is the session's CURRENT directory, and a Bash `cd` moves it.
# Reading config and specs relative to it made a session sitting in a
# subdirectory see no spec folders and no in-progress work.
# Every project path is therefore resolved against the project root:
#   1. CLAUDE_PROJECT_DIR (set by Claude Code for hooks), when it is a directory.
#   2. The nearest ancestor of Cwd (Cwd included) holding .claude/project-config.json.
#   3. The nearest ancestor of Cwd holding a .specs/ directory.
#   4. Cwd itself - the pre-SW-78 behaviour.
# Step 2 walks the whole chain before step 3 starts, so a stray nested .specs/
# left behind by an older hook cannot shadow a configured root. Identical in all
# four hooks; mirrors resolve_project_root in the .sh twins.
function Resolve-ProjectRoot {
    param([string]$Cwd)
    $envRoot = $env:CLAUDE_PROJECT_DIR
    if (-not [string]::IsNullOrWhiteSpace($envRoot) -and (Test-Path -LiteralPath $envRoot -PathType Container)) {
        return $envRoot
    }
    $start = $Cwd.TrimEnd('/', '\')
    if ($start.Length -eq 0) { return $Cwd }
    $markers = @(
        @{ Rel = '.claude/project-config.json'; Type = 'Leaf' },
        @{ Rel = '.specs'; Type = 'Container' }
    )
    foreach ($m in $markers) {
        $dir = $start
        for ($i = 0; $i -lt 64 -and -not [string]::IsNullOrEmpty($dir); $i++) {
            if (Test-Path -LiteralPath (Join-Path $dir $m.Rel) -PathType $m.Type) { return $dir }
            $parent = [System.IO.Path]::GetDirectoryName($dir)
            if ([string]::IsNullOrEmpty($parent) -or $parent -eq $dir) { break }
            $dir = $parent
        }
    }
    return $Cwd
}

function Get-ProjectConfig {
    param([string]$Root)

    $defaults = [pscustomobject]@{
        spec  = [pscustomobject]@{
            dir              = '.specs'
            indexFile        = '.specs/index.md'
            constitutionFile = '.specs/constitution.md'
        }
        hooks = [pscustomobject]@{
            sessionContext = [pscustomobject]@{ enabled = $true }
        }
    }

    $cfgPath = Join-Path $Root '.claude/project-config.json'
    if (-not (Test-Path -LiteralPath $cfgPath)) { return $defaults }

    # -ErrorAction Stop is required: the script-wide SilentlyContinue preference
    # would otherwise make a malformed config a NON-terminating error, so the
    # catch never fires and the function returns $null instead of the defaults.
    try {
        $loaded = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $loaded) { return $defaults }
        return $loaded
    } catch {
        return $defaults
    }
}

function Test-HookEnabled {
    param($Config)
    try {
        if ($null -eq $Config.hooks) { return $true }
        if ($null -eq $Config.hooks.sessionContext) { return $true }
        # Type-strict: only a literal JSON boolean false disables the hook, to
        # match session-context.sh's jq `== false` (the SW-22 rule).
        $en = $Config.hooks.sessionContext.enabled
        if (($en -is [bool]) -and (-not $en)) { return $false }
        return $true
    } catch {
        return $true
    }
}

# --- spec prefix alternation (SW-44) ------------------------------------------
# Built-in fallback covers every prefix shipped in
# templates/project-config.template.json (FEAT, BUG, REF, PERF, RCA, PORT).
# Any config-declared prefix that fails the shape check
# ^[A-Z][A-Z0-9]{1,9}$ is dropped silently and the built-in default is used
# only if NOTHING declared validates. Must stay in sync with
# resolve_spec_prefixes in session-context.sh.
$script:DefaultSpecPrefixes = @('FEAT','BUG','REF','PERF','RCA','PORT')

function Get-SpecPrefixAlternation {
    param([object]$Config)
    $raw = $null
    try { $raw = $Config.spec.prefixes } catch { $raw = $null }
    if ($null -eq $raw) {
        return ($script:DefaultSpecPrefixes -join '|')
    }
    $valid = New-Object System.Collections.Generic.List[string]
    foreach ($prop in $raw.PSObject.Properties) {
        $val = [string]$prop.Value
        if ($val -cmatch '^[A-Z][A-Z0-9]{1,9}$') {
            $valid.Add($val)
        }
    }
    if ($valid.Count -eq 0) {
        return ($script:DefaultSpecPrefixes -join '|')
    }
    return ($valid -join '|')
}

# Title of an index row: its last non-empty `|` cell. That holds for both the
# 4-column (ID|Type|Status|Title) and 5-column (ID|Type|Status|Created|Title)
# shapes. A row too short to have a title yields its ID or its status as the
# last cell; neither is a title, so the result is empty.
function Get-RowTitle {
    param([string]$Line, [string]$Id)
    $last = ''
    foreach ($cell in $Line.Split('|')) {
        $c = $cell.Trim()
        if ($c.Length -gt 0) { $last = $c }
    }
    if ($last -ceq $Id -or $last -ceq 'in-progress') { return '' }
    return $last
}

# `status:` from the leading `---` frontmatter block of 00-spec.md. Only a
# plain token ([A-Za-z0-9_-]+) is accepted. Anything else, a missing file or a
# missing line all yield '' and the spec is listed without a status.
function Get-SpecStatus {
    param([string]$SpecFile)
    if (-not (Test-Path -LiteralPath $SpecFile -PathType Leaf)) { return '' }
    try {
        $lines = @(Get-Content -LiteralPath $SpecFile -TotalCount 200 -Encoding UTF8 -ErrorAction Stop)
    } catch {
        return ''
    }
    if ($lines.Count -eq 0 -or $lines[0] -cne '---') { return '' }
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -ceq '---') { break }
        if ($l -cmatch '^status:[ \t]*([A-Za-z0-9_-]+)[ \t]*$') { return $Matches[1] }
    }
    return ''
}

# In-progress rows of the index, in file order, first row per ID wins. A row
# counts when it contains the literal text `in-progress` and a spec ID; the ID
# is the LEFTMOST prefix match on the row (case-sensitive, as in the .sh twin).
function Get-InProgressSpecs {
    param([string]$IndexPath, [string]$Prefixes)
    $result = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $IndexPath -PathType Leaf)) { return ,$result }
    try {
        $lines = Get-Content -LiteralPath $IndexPath -Encoding UTF8 -ErrorAction Stop
    } catch {
        return ,$result
    }
    $seen = New-Object System.Collections.Generic.HashSet[string]
    $rx = [regex]::new("($Prefixes)-[A-Za-z0-9_-]+")
    foreach ($line in $lines) {
        if (-not $line.Contains('in-progress')) { continue }
        $m = $rx.Match($line)
        if (-not $m.Success) { continue }
        if (-not $seen.Add($m.Value)) { continue }
        $result.Add([pscustomobject]@{
            Id    = $m.Value
            Title = (Get-RowTitle -Line $line -Id $m.Value)
        }) | Out-Null
    }
    return ,$result
}

# ---- main ----

$hookInput = Read-StdinJson
if ($null -eq $hookInput) { exit 0 }

$cwd = [string]$hookInput.cwd
if ([string]::IsNullOrWhiteSpace($cwd)) { exit 0 }
if (-not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 }
$projectRoot = Resolve-ProjectRoot -Cwd $cwd

$config = Get-ProjectConfig -Root $projectRoot
if (-not (Test-HookEnabled -Config $config)) { exit 0 }

# Echo only a plain lowercase word; anything else (missing, a number, an
# object) is reported as `unknown` rather than trusted into the context.
$source = [string]$hookInput.source
if ($source -cnotmatch '^[a-z]+$') { $source = 'unknown' }

$specRel   = if ($config.spec.dir)              { [string]$config.spec.dir }              else { '.specs' }
$indexRel  = if ($config.spec.indexFile)        { [string]$config.spec.indexFile }        else { '.specs/index.md' }
$constRel  = if ($config.spec.constitutionFile) { [string]$config.spec.constitutionFile } else { '.specs/constitution.md' }
$specDir   = Join-Path $projectRoot $specRel
$indexPath = Join-Path $projectRoot $indexRel
$constPath = Join-Path $projectRoot $constRel

$hasConstitution = Test-Path -LiteralPath $constPath -PathType Leaf
$prefixes        = Get-SpecPrefixAlternation -Config $config
$inProgress      = Get-InProgressSpecs -IndexPath $indexPath -Prefixes $prefixes

if (-not $hasConstitution -and $inProgress.Count -eq 0) { exit 0 }

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('<session-context>') | Out-Null
$lines.Add("Spec context from specwright (SessionStart hook, source: $source):") | Out-Null

if ($hasConstitution) {
    $lines.Add('') | Out-Null
    $lines.Add("Constitution: $constRel") | Out-Null
}

if ($inProgress.Count -gt 0) {
    $lines.Add('') | Out-Null
    $lines.Add("Specs currently in-progress (from ${indexRel}):") | Out-Null
    foreach ($s in $inProgress) {
        $item = "  - $($s.Id)"
        $status = Get-SpecStatus -SpecFile (Join-Path (Join-Path $specDir $s.Id) '00-spec.md')
        if ($status) { $item += " [status: $status]" }
        if ($s.Title) { $item += " $($s.Title)" }
        $lines.Add($item) | Out-Null
    }
}

$lines.Add('</session-context>') | Out-Null

[Console]::Out.WriteLine($lines -join "`n")
exit 0
