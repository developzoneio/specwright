#Requires -Version 5.1
<#
.SYNOPSIS
    specwright: retro escalation-line validator (Windows / PowerShell).

.DESCRIPTION
    Mirror of scripts/validate-escalation-lines.sh - both must accept and reject
    exactly the same lines. Like validate-lessons, this runs against a CONSUMER
    repo's spec tree: specwright itself has no .specs/, so here it only checks
    tests/retro-escalation/fixtures/.

    The contract (skills/sd-model-escalation/SKILL.md, "Logging contract"):
      escalation: <agent> <from> -> <to> (trigger: <rule-id>)
      escalation: <agent> <from> -> <reached> (trigger: <rule-id>) capped
      escalation: <agent> <from> -> <to> (trigger: <rule-id>) unapplied
    A line is an escalation line when, after an optional '- ' or '* ' bullet and
    an optional backtick, it starts with 'escalation:'. Each one must name a rule
    in specwright.manifest.json's contractLint.escalationTriggers, that rule's
    agent and from tier, alias-only tiers, and exactly the rule's one-rung to
    tier - or, for 'capped', a tier between from and the rule's to.

    This checks what the main thread SAID it did. It is not evidence of the model
    a subagent was served (docs/adr/0014-escalation-policy-lint.md).

    Exit 0 = every escalation line conforms; 1 = at least one violation or a
    missing explicit target; 2 = cannot run (no manifest, no rows).

    THIS FILE MUST STAY PURE ASCII (validate Check 1).

.PARAMETER Path
    05-retro.md files to check.

.PARAMETER SpecDir
    Check every <SpecDir>/*/05-retro.md. With neither -Path nor -SpecDir, checks
    .specs/*/05-retro.md under the current directory; a missing .specs/ is not an
    error, a missing explicit target is.
#>

[CmdletBinding()]
param(
    [string[]] $Path = @(),
    [string] $SpecDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Same patterns as the bash twin. [^ ] not \S, [ \t] not \s, and [regex]::Match
# only - never -match, which is case-insensitive.
$CANDIDATE_RE = '^[ \t]*([-*][ \t]+)?`?(escalation:.*)$'
$LINE_RE = '^escalation: (sd-[a-z0-9-]+) ([^ ]+) -> ([^ ]+) \(trigger: ([^)]+)\)( capped| unapplied)?$'

function Write-Section([string]$Text) { Write-Host ''; Write-Host "=== $Text ===" -ForegroundColor Cyan }
function Write-Ok([string]$Text) { Write-Host "  [OK]   $Text" -ForegroundColor Green }
function Write-Fail([string]$Text) { Write-Host "  [FAIL] $Text" -ForegroundColor Red }

$manifestPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'specwright.manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    [Console]::Error.WriteLine("validate-escalation-lines: manifest not found: $manifestPath")
    exit 2
}
$manifest = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($manifestPath)) | ConvertFrom-Json
$cl = $manifest.contractLint

function Get-OptionalString([object]$Obj, [string]$Name) {
    if ($null -eq $Obj) { return '' }
    if (-not $Obj.PSObject.Properties.Name.Contains($Name)) { return '' }
    if ($null -eq $Obj.$Name) { return '' }
    return [string]$Obj.$Name
}

$rows = New-Object 'System.Collections.Generic.List[object]'
if ($cl.PSObject.Properties.Name.Contains('escalationTriggers') -and $null -ne $cl.escalationTriggers) {
    foreach ($r in @($cl.escalationTriggers)) {
        $id = Get-OptionalString $r 'id'
        if ($id.Length -eq 0) { continue }
        [void]$rows.Add([PSCustomObject]@{
            Id = $id; Agent = (Get-OptionalString $r 'agent')
            From = (Get-OptionalString $r 'from'); To = (Get-OptionalString $r 'to')
        })
    }
}
$aliases = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$ladder = New-Object 'System.Collections.Generic.List[string]'
if ($cl.PSObject.Properties.Name.Contains('escalationPolicy') -and $null -ne $cl.escalationPolicy) {
    $ep = $cl.escalationPolicy
    if ($ep.PSObject.Properties.Name.Contains('aliases')) {
        foreach ($t in @($ep.aliases)) { if ([string]$t -cne '') { [void]$aliases.Add([string]$t) } }
    }
    if ($ep.PSObject.Properties.Name.Contains('ladder')) {
        foreach ($t in @($ep.ladder)) { if ([string]$t -cne '') { [void]$ladder.Add([string]$t) } }
    }
}
if ($rows.Count -eq 0 -or $ladder.Count -eq 0) {
    [Console]::Error.WriteLine('validate-escalation-lines: manifest declares no contractLint.escalationTriggers rows or no escalationPolicy.ladder')
    exit 2
}

$script:violations = 0
$script:linesSeen = 0

function Add-Violation([string]$File, [int]$LineNo, [string]$Message) {
    Write-Fail "${File}:${LineNo} : $Message"
    $script:violations++
}

# One verdict per line, first failure wins - the twin checks in the same order.
function Test-EscalationLine([string]$File, [int]$LineNo, [string]$Text) {
    $m = [regex]::Match($Text, $LINE_RE)
    if (-not $m.Success) {
        Add-Violation $File $LineNo "malformed escalation line - want 'escalation: <agent> <from> -> <to> (trigger: <rule-id>)' plus an optional ' capped' or ' unapplied'"
        return
    }
    $agent = $m.Groups[1].Value; $from = $m.Groups[2].Value; $to = $m.Groups[3].Value
    $rule = $m.Groups[4].Value; $suffix = $m.Groups[5].Value.TrimStart(' ')
    $row = $null
    foreach ($r in $rows) { if ($r.Id -ceq $rule) { $row = $r; break } }
    if ($null -eq $row) {
        Add-Violation $File $LineNo "unknown rule '$rule' - not in contractLint.escalationTriggers"
        return
    }
    if ($agent -cne $row.Agent) {
        Add-Violation $File $LineNo "rule $rule escalates '$($row.Agent)', not '$agent'"
        return
    }
    if (-not $aliases.Contains($from)) {
        Add-Violation $File $LineNo "tier '$from' is not a model alias"
        return
    }
    if (-not $aliases.Contains($to)) {
        Add-Violation $File $LineNo "tier '$to' is not a model alias"
        return
    }
    if ($from -cne $row.From) {
        Add-Violation $File $LineNo "rule $rule escalates from '$($row.From)', not '$from'"
        return
    }
    if ($suffix -ceq 'capped') {
        $fi = $ladder.IndexOf($from); $ti = $ladder.IndexOf($to); $ri = $ladder.IndexOf($row.To)
        if ($ti -lt 0 -or $ti -lt $fi -or $ti -gt $ri) {
            Add-Violation $File $LineNo "capped tier '$to' is outside $from..$($row.To), the range rule $rule allows"
        }
        return
    }
    if ($to -cne $row.To) {
        Add-Violation $File $LineNo "rule $rule escalates to '$($row.To)' (one rung), not '$to'"
    }
}

function Test-RetroFile([string]$FullPath, [string]$Display) {
    $text = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($FullPath))
    $raw = $text.Split([char]10)
    $n = $raw.Length
    # A trailing newline yields one empty final element in .NET but no final
    # line in bash's read loop; an empty line is never an escalation line either way.
    for ($i = 0; $i -lt $n; $i++) {
        $line = $raw[$i].TrimEnd([char]13)
        $cm = [regex]::Match($line, $CANDIDATE_RE)
        if (-not $cm.Success) { continue }
        $c = $cm.Groups[2].Value.TrimEnd([char[]]@([char]32, [char]9))
        if ($c.EndsWith('`', [StringComparison]::Ordinal)) { $c = $c.Substring(0, $c.Length - 1) }
        $c = $c.TrimEnd([char[]]@([char]32, [char]9))
        $script:linesSeen++
        Test-EscalationLine $Display ($i + 1) $c
    }
}

# ---- targets ----------------------------------------------------------------

Write-Section 'specwright validate-escalation-lines'

$explicit = ($Path.Count -gt 0 -or $SpecDir.Length -gt 0)
if (-not $explicit) {
    if (-not (Test-Path -LiteralPath '.specs' -PathType Container)) {
        Write-Ok "no .specs/ in $((Get-Location).Path) - nothing to validate"
        exit 0
    }
    $SpecDir = '.specs'
}

$targets = New-Object 'System.Collections.Generic.List[string]'
foreach ($p in $Path) { [void]$targets.Add($p) }
if ($SpecDir.Length -gt 0) {
    if (-not (Test-Path -LiteralPath $SpecDir -PathType Container)) {
        Write-Fail "spec directory not found: $SpecDir"
        exit 1
    }
    $found = New-Object 'System.Collections.Generic.List[string]'
    foreach ($d in @(Get-ChildItem -LiteralPath $SpecDir -Directory)) {
        if (Test-Path -LiteralPath (Join-Path $d.FullName '05-retro.md') -PathType Leaf) {
            [void]$found.Add($SpecDir.TrimEnd('/', '\') + '/' + $d.Name + '/05-retro.md')
        }
    }
    $found.Sort([StringComparer]::Ordinal)
    foreach ($f in $found) { [void]$targets.Add($f) }
}

foreach ($t in $targets) {
    if (-not (Test-Path -LiteralPath $t -PathType Leaf)) {
        Write-Fail "file not found: $t"
        exit 1
    }
}

foreach ($t in $targets) {
    Test-RetroFile (Resolve-Path -LiteralPath $t).ProviderPath $t
}

if ($script:violations -eq 0) {
    Write-Ok "$($script:linesSeen) escalation line(s) across $($targets.Count) file(s): known rules, alias-only tiers, one rung"
    exit 0
} else {
    Write-Fail "$($script:violations) violation(s) across $($script:linesSeen) escalation line(s)"
    exit 1
}
