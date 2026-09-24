<#
.SYNOPSIS
    Release-time prompt size report for the specwright ENGINE PRODUCT (Windows / PowerShell).

.DESCRIPTION
    Twin of scripts/prompt-size-report.sh. Both MUST print byte-identical stdout
    for the same tree and ref; tests/prompt-size-report/run-parity.ps1 runs both
    and diffs them.

    Replaces CL500 (the per-area byte-budget ratchet retired by SW-57, see
    docs/adr/0011-retire-cl500-byte-ratchet.md). Instead of a number someone has
    to bump, it reports every prompt file's growth since the last release, read
    once per minor release - see docs/contract-lint.md "Prompt size report".

    Scope is the manifest's contractLint.scanScope; the flag threshold is
    promptSizeReport.flagGrowthPercent.

    Output is TSV on stdout, one row per file, then one TOTAL row per area:
      <FILE><TAB><BEFORE><TAB><AFTER><TAB><DELTA><TAB><PCT><TAB><FLAG>
    BEFORE/AFTER are '-' for a file absent on that side. PCT is growth in percent
    to one decimal, truncated toward zero, signed by the delta ('new' / 'removed'
    when one side is absent). FLAG is 'FLAG' when growth exceeds the threshold,
    else '-'. File rows sort by DELTA descending, then path in ordinal order. The
    summary goes to stderr and is never parsed or compared.

    Byte counts are NORMALIZED, the measure CL500 used: CR bytes removed, one
    trailing LF not counted. *.md is 'text=auto' (see .gitattributes), so a raw
    count would differ between a Windows and a Linux checkout of identical
    content.

    Exit codes:
      0  report printed (the report is advisory - it never fails a build)
      2  cannot run (bad -Root, missing manifest or git, bad ref)

    THIS FILE MUST STAY PURE ASCII. Check 1 of validate scans every *.ps1.

.PARAMETER Root
    Repo to report on. Defaults to the repo this script lives in.

.PARAMETER Since
    Git ref to compare the working tree against. Defaults to the highest v* tag
    by version order, whether or not it is an ancestor - release tags are cut on
    main, not on the development branch.
#>
[CmdletBinding()]
param(
    [string]$Root = '',
    [string]$Since = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Stop-Report([string]$Message) {
    [Console]::Error.WriteLine("prompt-size-report: $Message")
    exit 2
}

# Runs git and returns @{ Code; Bytes }. stdout is read as raw bytes off the
# process stream: a PowerShell pipeline would decode and re-encode it, and on
# PS 5.1 that mangles non-ASCII bytes and so the byte count.
function Invoke-Git([string[]]$GitArgs) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $quoted = foreach ($a in (@('-C', $Root) + $GitArgs)) { '"' + $a.Replace('"', '\"') + '"' }
    $psi.Arguments = $quoted -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $ms = New-Object System.IO.MemoryStream
    $p.StandardOutput.BaseStream.CopyTo($ms)
    $p.WaitForExit()
    [void]$errTask.Result
    return @{ Code = $p.ExitCode; Bytes = $ms.ToArray() }
}

function Get-GitLines([string[]]$GitArgs) {
    $r = Invoke-Git $GitArgs
    if ($r.Code -ne 0) { return $null }
    $text = [System.Text.Encoding]::UTF8.GetString($r.Bytes).Replace("`r", '')
    return @($text.Split([char]10) | Where-Object { $_.Length -gt 0 })
}

function Get-NormalizedBytes([byte[]]$Bytes) {
    $n = 0
    foreach ($b in $Bytes) { if ($b -ne 13) { $n++ } }
    $last = -1
    for ($i = $Bytes.Length - 1; $i -ge 0; $i--) {
        if ($Bytes[$i] -ne 13) { $last = $Bytes[$i]; break }
    }
    if ($last -eq 10) { $n-- }
    return $n
}

# Percent to one decimal, truncated toward zero, signed by the delta.
function Format-Pct([long]$Before, [long]$Delta) {
    $rem = [long]0
    $t = [Math]::DivRem($Delta * 1000, $Before, [ref]$rem)
    $sign = ''
    if ($Delta -gt 0) { $sign = '+' } elseif ($Delta -lt 0) { $sign = '-' }
    $t = [Math]::Abs($t)
    return ('{0}{1}.{2}%' -f $sign, [Math]::Floor($t / 10), ($t % 10))
}

if ([string]::IsNullOrEmpty($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
if (-not (Test-Path -LiteralPath $Root -PathType Container)) { Stop-Report "-Root is not a directory: '$Root'" }
$Root = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\', '/')
$manifestPath = Join-Path $Root 'specwright.manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { Stop-Report "manifest not found: $manifestPath" }
if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { Stop-Report 'git is required' }
if ((Invoke-Git @('rev-parse', '--git-dir')).Code -ne 0) { Stop-Report "not a git repository: $Root" }

if ([string]::IsNullOrEmpty($Since)) {
    $tags = Get-GitLines @('tag', '--list', 'v*', '--sort=-v:refname')
    if ($null -eq $tags -or $tags.Count -eq 0) { Stop-Report 'no v* tag found; pass -Since <ref>' }
    $Since = $tags[0]
}
if ((Invoke-Git @('rev-parse', '--verify', '--quiet', "$Since^{commit}")).Code -ne 0) {
    Stop-Report "not a commit: '$Since'"
}

$manifest = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($manifestPath)) | ConvertFrom-Json
$threshold = $null
if ($manifest.PSObject.Properties.Name -contains 'promptSizeReport' -and
    $manifest.promptSizeReport.PSObject.Properties.Name -contains 'flagGrowthPercent') {
    $threshold = $manifest.promptSizeReport.flagGrowthPercent
}
if ($null -eq $threshold -or ([string]$threshold) -notmatch '^[0-9]+$') {
    Stop-Report 'promptSizeReport.flagGrowthPercent missing or not an integer'
}
$threshold = [long]$threshold
$scope = @($manifest.contractLint.scanScope | ForEach-Object { [string]$_ })
if ($scope.Count -eq 0) { Stop-Report 'contractLint.scanScope is empty' }

function Test-InScope([string]$Rel) {
    foreach ($g in $scope) { if ($Rel -clike $g) { return $true } }
    return $false
}

# Union of in-scope paths at the ref and on disk, ordinal-sorted and unique.
$pathSet = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
$refPaths = Get-GitLines @('ls-tree', '-r', '--name-only', $Since)
if ($null -eq $refPaths) { Stop-Report "cannot list tree at '$Since'" }
foreach ($p in $refPaths) { if (Test-InScope $p) { [void]$pathSet.Add($p) } }
foreach ($g in $scope) {
    $pattern = Join-Path $Root $g.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    foreach ($f in @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
        if (Test-InScope $rel) { [void]$pathSet.Add($rel) }
    }
}

$rows = New-Object 'System.Collections.Generic.List[object]'
$flagged = 0
foreach ($p in $pathSet) {
    $before = '-'; $after = '-'
    $blob = Invoke-Git @('cat-file', 'blob', "${Since}:$p")
    if ($blob.Code -eq 0) { $before = Get-NormalizedBytes $blob.Bytes }
    $abs = Join-Path $Root $p.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    if (Test-Path -LiteralPath $abs -PathType Leaf) {
        $after = Get-NormalizedBytes ([System.IO.File]::ReadAllBytes($abs))
    }
    $b = [long]0; $a = [long]0
    if ($before -ne '-') { $b = [long]$before }
    if ($after -ne '-') { $a = [long]$after }
    $delta = $a - $b
    $flag = '-'
    if ($before -eq '-') {
        $pct = 'new'
    } elseif ($after -eq '-') {
        $pct = 'removed'
    } elseif ($b -eq 0) {
        $pct = '0.0%'
    } else {
        $pct = Format-Pct $b $delta
        if ($delta * 100 -gt $b * $threshold) { $flag = 'FLAG'; $flagged++ }
    }
    $rows.Add([pscustomobject]@{
        Path = $p; Before = $before; After = $after; B = $b; A = $a
        Delta = $delta; Pct = $pct; Flag = $flag
    })
}

$rows.Sort([System.Comparison[object]] {
    param($x, $y)
    if ($x.Delta -ne $y.Delta) { return $y.Delta.CompareTo($x.Delta) }
    return [string]::CompareOrdinal($x.Path, $y.Path)
})

# Write-Output, never [Console]::Out.WriteLine: the latter bypasses '>'
# redirection, so the parity capture would collect an empty file.
$tab = [char]9
foreach ($r in $rows) {
    Write-Output ($r.Path, $r.Before, $r.After, $r.Delta, $r.Pct, $r.Flag -join $tab)
}

$areas = New-Object 'System.Collections.Generic.List[string]'
foreach ($r in $rows) {
    $area = $r.Path.Split('/')[0]
    if (-not $areas.Contains($area)) { $areas.Add($area) }
}
$areas.Sort([StringComparer]::Ordinal)

$totalDelta = [long]0
foreach ($area in $areas) {
    $b = [long]0; $a = [long]0
    foreach ($r in $rows) {
        if ($r.Path.StartsWith("$area/", [StringComparison]::Ordinal)) { $b += $r.B; $a += $r.A }
    }
    $delta = $a - $b
    $totalDelta += $delta
    if ($b -eq 0) { $pct = 'new' } else { $pct = Format-Pct $b $delta }
    Write-Output ("TOTAL:$area", $b, $a, $delta, $pct, '-' -join $tab)
}

[Console]::Error.WriteLine("prompt-size-report: $Since -> working tree: $($pathSet.Count) file(s), net $totalDelta byte(s), $flagged over the $threshold% flag (root: $Root)")
exit 0
