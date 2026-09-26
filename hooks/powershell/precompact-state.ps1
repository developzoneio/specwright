#requires -Version 5.1
<#
.SYNOPSIS
    specwright: PreCompact hook - precompact-state.

.DESCRIPTION
    Reads Claude Code hook JSON from stdin. Before a compaction (manual or auto)
    it records WHICH spec the session was working on, so the SessionStart hook
    can re-inject it once the compaction is done (SW-68):
      1. Resolve the project root from the cwd (SW-78) and load
         .claude/project-config.json (or sane defaults if absent).
      2. Scan the tail of the session transcript for spec IDs, newest first.
         The first one that has <spec.dir>/<ID>/00-spec.md and is not
         done/archived is the active spec. When the transcript names none,
         a single in-progress index row is used instead.
      3. Write the pointer {specId, trigger} to
         .claude/.hookstate/precompact-<sessionId>.json.

    session-context.ps1 reads the pointer on SessionStart `source: compact`,
    which fires after the compaction with the same session_id (ADR 0015), and
    builds the context from disk. This hook only records the pointer: there is
    one context builder, not two. It never writes to stdout - what the CLI does
    with PreCompact stdout is not documented.

    Exit 2 would BLOCK the compaction (ADR 0015). Every path here exits 0,
    silently, including every failure.

.NOTES
    PURE ASCII ONLY. PowerShell 5.1 reads UTF-8 without BOM as Windows-1252;
    a single em-dash byte sequence will cascade into "Missing closing '}'"
    parse errors. Use ASCII hyphen-minus, "->", "[OK]", "[WARN]" etc.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'

# How much of the transcript tail to scan. Recent turns are at the end; a
# fixed cap keeps the cost flat however long the session has run.
$script:TranscriptTailBytes = 262144

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
# five hooks; mirrors resolve_project_root in the .sh twins.
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
            dir       = '.specs'
            indexFile = '.specs/index.md'
        }
        hooks = [pscustomobject]@{
            precompactState = [pscustomobject]@{ enabled = $true }
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
        if ($null -eq $Config.hooks.precompactState) { return $true }
        # Type-strict: only a literal JSON boolean false disables the hook, to
        # match precompact-state.sh's jq `== false` (the SW-22 rule).
        $en = $Config.hooks.precompactState.enabled
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
# resolve_spec_prefixes in precompact-state.sh.
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

# `status:` from the leading `---` frontmatter block of 00-spec.md. Only a
# plain token ([A-Za-z0-9_-]+) is accepted. Anything else, a missing file or a
# missing line all yield ''. Same reader as Get-SpecField in session-context.ps1.
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

# A candidate is the active spec when its folder holds a 00-spec.md and the
# spec is not finished. A missing or odd status still counts: the folder is the
# evidence that the session was working on it.
function Test-ActiveCandidate {
    param([string]$SpecDir, [string]$Id)
    $specFile = Join-Path (Join-Path $SpecDir $Id) '00-spec.md'
    if (-not (Test-Path -LiteralPath $specFile -PathType Leaf)) { return $false }
    $status = Get-SpecStatus -SpecFile $specFile
    if ($status -ceq 'done' -or $status -ceq 'archived') { return $false }
    return $true
}

# The last TranscriptTailBytes bytes of the transcript, as text. The file is
# opened with FileShare.ReadWrite because the CLI may still hold it open.
# Spec IDs are ASCII, so a multi-byte character cut at the seek point cannot
# change which IDs match.
function Get-TranscriptTail {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $len = $fs.Length
        $take = [int][Math]::Min([long]$script:TranscriptTailBytes, $len)
        if ($take -le 0) { return '' }
        [void]$fs.Seek(-1 * [long]$take, [System.IO.SeekOrigin]::End)
        $buf = New-Object byte[] $take
        $read = 0
        while ($read -lt $take) {
            $n = $fs.Read($buf, $read, $take - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        return [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
    } catch {
        return ''
    } finally {
        if ($null -ne $fs) { $fs.Dispose() }
    }
}

# Newest mention wins: walk the matches from the end, skipping IDs already
# checked, and return the first that passes Test-ActiveCandidate.
function Find-ActiveInTranscript {
    param([string]$Text, [string]$Prefixes, [string]$SpecDir)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $rx = [regex]::new("($Prefixes)-[A-Za-z0-9_-]+")
    $all = $rx.Matches($Text)
    $seen = New-Object System.Collections.Generic.HashSet[string]
    for ($i = $all.Count - 1; $i -ge 0; $i--) {
        $id = $all[$i].Value
        if (-not $seen.Add($id)) { continue }
        if (Test-ActiveCandidate -SpecDir $SpecDir -Id $id) { return $id }
    }
    return ''
}

# Fallback when the transcript names no usable spec: the single in-progress
# index row, if there is exactly one. The ID is the LEFTMOST prefix match on a
# row containing the literal text `in-progress` (as in session-context.ps1).
function Find-SoleInProgress {
    param([string]$IndexPath, [string]$Prefixes, [string]$SpecDir)
    if (-not (Test-Path -LiteralPath $IndexPath -PathType Leaf)) { return '' }
    try {
        $lines = Get-Content -LiteralPath $IndexPath -Encoding UTF8 -ErrorAction Stop
    } catch {
        return ''
    }
    $rx = [regex]::new("($Prefixes)-[A-Za-z0-9_-]+")
    $ids = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if (-not $line.Contains('in-progress')) { continue }
        $m = $rx.Match($line)
        if (-not $m.Success) { continue }
        if (-not $ids.Contains($m.Value)) { $ids.Add($m.Value) }
    }
    if ($ids.Count -ne 1) { return '' }
    if (Test-ActiveCandidate -SpecDir $SpecDir -Id $ids[0]) { return $ids[0] }
    return ''
}

# Pointers are per session; drop the ones older than 24h, as subagent-retro
# does with its own state files.
function Remove-StalePointers {
    param([string]$StateDir)
    if (-not (Test-Path -LiteralPath $StateDir)) { return }
    $cutoff = (Get-Date).AddHours(-24)
    try {
        $files = Get-ChildItem -LiteralPath $StateDir -File -Filter 'precompact-*.json' -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            if ($f.LastWriteTime -lt $cutoff) {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    } catch { }
}

# ---- main ----

try {
    $hookInput = Read-StdinJson
    if ($null -eq $hookInput) { exit 0 }

    $cwd = [string]$hookInput.cwd
    if ([string]::IsNullOrWhiteSpace($cwd)) { exit 0 }
    if (-not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 }
    $projectRoot = Resolve-ProjectRoot -Cwd $cwd

    $config = Get-ProjectConfig -Root $projectRoot
    if (-not (Test-HookEnabled -Config $config)) { exit 0 }

    $specRel   = if ($config.spec.dir)       { [string]$config.spec.dir }       else { '.specs' }
    $indexRel  = if ($config.spec.indexFile) { [string]$config.spec.indexFile } else { '.specs/index.md' }
    $specDir   = Join-Path $projectRoot $specRel
    $indexPath = Join-Path $projectRoot $indexRel

    # No spec tree: nothing to preserve.
    if (-not (Test-Path -LiteralPath $specDir -PathType Container)) { exit 0 }
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { exit 0 }

    # Echo only a plain lowercase word (manual, auto); anything else is
    # recorded as `unknown` rather than trusted into the context.
    $trigger = [string]$hookInput.trigger
    if ($trigger -cnotmatch '^[a-z]+$') { $trigger = 'unknown' }

    $sessionId = [string]$hookInput.session_id
    if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = 'no-session' }
    $safeId = ($sessionId -replace '[^A-Za-z0-9_\-]', '_')

    $prefixes = Get-SpecPrefixAlternation -Config $config
    $tail = Get-TranscriptTail -Path ([string]$hookInput.transcript_path)
    $active = Find-ActiveInTranscript -Text $tail -Prefixes $prefixes -SpecDir $specDir
    if (-not $active) {
        $active = Find-SoleInProgress -IndexPath $indexPath -Prefixes $prefixes -SpecDir $specDir
    }

    $stateDir = Join-Path $projectRoot '.claude/.hookstate'
    Remove-StalePointers -StateDir $stateDir
    if (-not $active) { exit 0 }

    if (-not (Test-Path -LiteralPath $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force -ErrorAction Stop | Out-Null
    }
    # Both values are regex-constrained, so plain concatenation is valid JSON.
    # WriteAllText writes UTF-8 without a BOM, which jq in the bash twin of
    # session-context needs; Set-Content -Encoding UTF8 on 5.1 would add one.
    $json = '{"specId":"' + $active + '","trigger":"' + $trigger + '"}'
    [System.IO.File]::WriteAllText((Join-Path $stateDir "precompact-$safeId.json"), $json + "`n")
} catch { }
exit 0
