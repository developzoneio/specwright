#requires -Version 5.1
<#
.SYNOPSIS
    Negative self-test for validate.ps1 Check 9 (root-level ad-hoc notes guard), Windows.

.DESCRIPTION
    Mirror of scripts/selftest-root-guard.sh.

    Check 9 only earns its place in CI if it FAILS when an ad-hoc notes file reappears
    at the repo root. A check that silently degrades into a no-op still reports success,
    so this test corrupts a throwaway copy of the repo in several ways and asserts the
    validator catches each:

      1. Clean copy (real ROADMAP.md included) -> passes.
      2. A literal filename (REVIEW-TODO.md)   -> fails, naming the pattern.
      3. A suffix glob (*-FINDINGS.md)         -> fails, naming the pattern.
      4. A lowercase-variant filename          -> fails identically (case-insensitive).
      5. Removing the offending file           -> restores a pass in the same sandbox copy.

    Scenario 4 is what actually machine-checks that bash and PowerShell agree on matching
    case-insensitively (NTFS/APFS are case-insensitive filesystems, so a case-sensitive
    guard would let a differently-cased ad-hoc notes file through on exactly those
    platforms) - a future edit that silently changed one side to case-sensitive matching
    would only be caught here.

    Exit code 0 = the check behaves correctly; 1 = the check is broken.

    PURE ASCII. Scanned by validate.ps1 Check 1.

.EXAMPLE
    .\scripts\selftest-root-guard.ps1
#>

param()

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$repoRoot  = Split-Path -Parent $scriptDir

function Write-Section { param([string]$Title) Write-Host ''; Write-Host "=== $Title ===" -ForegroundColor Cyan }
function Write-Ok      { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-FailMsg { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red }

$script:Failures = 0

# Working dirs are throwaway copies - the real repo is never mutated.
$SkipTop = @('.git', 'node_modules', '_bmad', '_bmad-output', 'design-artifacts', '.claude', 'dist')

$workRoot = Join-Path $env:TEMP "sd-selftest-root-guard-$PID"
$psExe = (Get-Process -Id $PID).Path

function New-RepoCopy {
    param([string]$Dest)
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
    foreach ($entry in (Get-ChildItem -LiteralPath $repoRoot -Force)) {
        if ($SkipTop -contains $entry.Name) { continue }
        Copy-Item -LiteralPath $entry.FullName -Destination $Dest -Recurse -Force
    }
}

# Run the validator inside a copy and assert exit status + expected message.
# ExpectPass -> exit 0 required; otherwise non-zero AND $Needle in the output.
function Invoke-Case {
    param(
        [string]$Name,
        [bool]$ExpectPass,
        [string]$Needle,
        [string]$Dir
    )
    $validator = Join-Path $Dir 'scripts\validate.ps1'
    $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File $validator 2>&1 | Out-String
    $status = $LASTEXITCODE

    if ($ExpectPass) {
        if ($status -eq 0) {
            Write-Ok "$Name : validator passed as expected"
        } else {
            Write-FailMsg "$Name : expected exit 0, got $status"
            Write-Host $out
            $script:Failures++
        }
        return
    }

    if ($status -eq 0) {
        Write-FailMsg "$Name : expected non-zero exit, got 0 - THE CHECK DID NOT BITE"
        $script:Failures++
        return
    }
    if ($out.Contains($Needle)) {
        Write-Ok "$Name : failed with the right reason (exit $status)"
    } else {
        # Non-zero for the wrong reason is not a pass - it would mask a broken check.
        Write-FailMsg "$Name : exited $status but never said '$Needle'"
        Write-Host $out
        $script:Failures++
    }
}

try {
    if (Test-Path -LiteralPath $workRoot) { Remove-Item -Recurse -Force $workRoot }

    Write-Section 'selftest: root-level ad-hoc notes guard (Check 9)'
    Write-Host "  Repo root: $repoRoot"
    Write-Host "  Sandbox:   $workRoot"

    # ---- Scenario 1: clean copy passes -------------------------------------

    Write-Section 'Scenario 1/5: clean copy (with real ROADMAP.md) passes'
    $clean = Join-Path $workRoot 'clean'
    New-RepoCopy -Dest $clean
    Invoke-Case -Name 'clean' -ExpectPass $true -Needle '' -Dir $clean

    # ---- Scenario 2: a literal filename fails -------------------------------

    Write-Section 'Scenario 2/5: literal filename (REVIEW-TODO.md) fails'
    $literal = Join-Path $workRoot 'literal'
    New-RepoCopy -Dest $literal
    New-Item -ItemType File -Path (Join-Path $literal 'REVIEW-TODO.md') -Force | Out-Null
    Invoke-Case -Name 'literal' -ExpectPass $false `
        -Needle "matches ad-hoc notes pattern 'REVIEW-TODO.md'" -Dir $literal

    # ---- Scenario 3: a suffix glob fails ------------------------------------

    Write-Section 'Scenario 3/5: suffix glob (*-FINDINGS.md) fails'
    $suffix = Join-Path $workRoot 'suffix'
    New-RepoCopy -Dest $suffix
    New-Item -ItemType File -Path (Join-Path $suffix 'SECURITY-AUDIT-FINDINGS.md') -Force | Out-Null
    Invoke-Case -Name 'suffix' -ExpectPass $false `
        -Needle "matches ad-hoc notes pattern '*-FINDINGS.md'" -Dir $suffix

    # ---- Scenario 4: a lowercase variant fails identically (case-insensitive) --

    Write-Section 'Scenario 4/5: lowercase variant (review-todo.md) fails'
    $lower = Join-Path $workRoot 'lower'
    New-RepoCopy -Dest $lower
    New-Item -ItemType File -Path (Join-Path $lower 'review-todo.md') -Force | Out-Null
    Invoke-Case -Name 'lower' -ExpectPass $false `
        -Needle 'matches ad-hoc notes pattern' -Dir $lower

    # ---- Scenario 5: removing the offending file restores a pass -----------

    Write-Section 'Scenario 5/5: removing the offending file restores a pass'
    $removed = Join-Path $workRoot 'removed'
    New-RepoCopy -Dest $removed
    $removedFile = Join-Path $removed 'REVIEW-TODO.md'
    New-Item -ItemType File -Path $removedFile -Force | Out-Null
    Invoke-Case -Name 'removed (before)' -ExpectPass $false `
        -Needle "matches ad-hoc notes pattern 'REVIEW-TODO.md'" -Dir $removed
    Remove-Item -LiteralPath $removedFile -Force
    Invoke-Case -Name 'removed (after)' -ExpectPass $true -Needle '' -Dir $removed

    # ---- summary -------------------------------------------------------------

    Write-Section 'Summary'
    if ($script:Failures -eq 0) {
        Write-Ok 'Check 9 bites on all 5 scenarios.'
        exit 0
    } else {
        Write-FailMsg "$($script:Failures) scenario(s) behaved wrong - Check 9 is not trustworthy."
        exit 1
    }
} finally {
    if (Test-Path -LiteralPath $workRoot) {
        Remove-Item -Recurse -Force $workRoot -ErrorAction SilentlyContinue
    }
}
