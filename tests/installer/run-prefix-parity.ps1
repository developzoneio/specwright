#requires -Version 7.0
<#
.SYNOPSIS
    specwright: installer --prefix parity runner (SW-53).

.DESCRIPTION
    For every case in tests/installer/prefix-cases.json, runs all four
    installer scripts (install.sh, uninstall.sh, install.ps1, uninstall.ps1)
    in dry-run mode against a fresh, non-existent base path and classifies
    each outcome:
      accept - exit 0
      reject - exit 1 and "Invalid prefix" in the output
      error  - anything else (the harness cannot tell what happened)
    A case passes only when all four outcomes equal the case's `expect`, and
    the dry run left nothing on disk. A mismatch prints all four outcomes so
    a one-script divergence is obvious.

    -SelfTest runs the real sweep first (it must pass), then swaps install.sh
    for a mutant carrying the pre-SW-53 spaces-only guard (`${PREFIX// /}`)
    and asserts the harness DETECTS the divergence on the tab-only case.

.PARAMETER SelfTest
    Negative mode - proves the harness would notice this exact regression.

.EXAMPLE
    .\tests\installer\run-prefix-parity.ps1
    .\tests\installer\run-prefix-parity.ps1 -SelfTest

.NOTES
    PURE ASCII. validate's Check 1 scans every *.ps1 recursively.
    Single cross-platform runner by design (same posture as
    tests/hooks/run-conformance.ps1): parity is asserted in one process
    rather than inferred from two green platform-native jobs. CI runs this
    under pwsh on every matrix OS.
#>

[CmdletBinding()]
param(
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testsRoot  = $PSScriptRoot
$repoRoot   = Split-Path -Parent (Split-Path -Parent $testsRoot)
$installDir = Join-Path $repoRoot 'install'
$casesPath  = Join-Path $testsRoot 'prefix-cases.json'

$script:pass = 0
$script:fail = 0

function Write-Ok  { param([string]$m) Write-Host "  [OK]   $m"; $script:pass++ }
function Write-Bad { param([string]$m) Write-Host "  [FAIL] $m"; $script:fail++ }

function Resolve-BashPath {
    # On Windows prefer Git Bash explicitly: System32 bash.exe is WSL's
    # stub and fails when no distro is installed.
    if ($IsWindows) {
        $gitBash = 'C:\Program Files\Git\bin\bash.exe'
        if (Test-Path -LiteralPath $gitBash) { return $gitBash }
    }
    $cmd = Get-Command bash -ErrorAction SilentlyContinue
    if ($null -ne $cmd) { return $cmd.Source }
    return $null
}

function Format-Prefix {
    # Printable form of a prefix for log lines (control chars made visible).
    param([string]$Value)
    return '"' + ($Value -replace "`t", '\t' -replace "`n", '\n' -replace "`r", '\r') + '"'
}

function Invoke-Installer {
    param(
        [string]$Kind,      # 'bash' or 'pwsh'
        [string]$Script,
        [string]$Prefix
    )

    # Fresh, never-created base path per run: a dry run must not create it.
    $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ('sd-prefix-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 12))
    New-Item -ItemType Directory -Path $scratch -Force | Out-Null
    $base = Join-Path $scratch 'base'

    try {
        if ($Kind -eq 'bash') {
            $out = & $script:bashExe ($Script -replace '\\', '/') --dry-run --base-path ($base -replace '\\', '/') --prefix $Prefix 2>&1 | Out-String
        } else {
            $out = & $script:pwshExe -NoProfile -File $Script -DryRun -BasePath $base -Prefix $Prefix *>&1 | Out-String
        }
        $rc = $LASTEXITCODE

        $leftover = @(Get-ChildItem -LiteralPath $scratch -Force -Recurse -ErrorAction SilentlyContinue)
        if ($leftover.Count -gt 0) {
            return [pscustomobject]@{ Outcome = 'error'; Detail = "dry run wrote $($leftover.Count) item(s)"; Output = $out }
        }

        $outcome = 'error'
        if ($rc -eq 0) {
            $outcome = 'accept'
        } elseif ($rc -eq 1 -and $out -match 'Invalid prefix') {
            $outcome = 'reject'
        }
        return [pscustomobject]@{ Outcome = $outcome; Detail = "exit $rc"; Output = $out }
    } finally {
        Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Sweep {
    param(
        [string]$InstallSh,
        [switch]$Silent
    )

    $targets = @(
        [pscustomobject]@{ Label = 'install.sh';    Kind = 'bash'; Path = $InstallSh }
        [pscustomobject]@{ Label = 'uninstall.sh';  Kind = 'bash'; Path = (Join-Path $installDir 'uninstall.sh') }
        [pscustomobject]@{ Label = 'install.ps1';   Kind = 'pwsh'; Path = (Join-Path $installDir 'install.ps1') }
        [pscustomobject]@{ Label = 'uninstall.ps1'; Kind = 'pwsh'; Path = (Join-Path $installDir 'uninstall.ps1') }
    )

    $failed = New-Object System.Collections.Generic.List[string]
    foreach ($c in $script:cases) {
        $results = foreach ($t in $targets) {
            $r = Invoke-Installer -Kind $t.Kind -Script $t.Path -Prefix $c.prefix
            [pscustomobject]@{ Label = $t.Label; Outcome = $r.Outcome; Detail = $r.Detail; Output = $r.Output }
        }
        $bad = @($results | Where-Object { $_.Outcome -ne $c.expect })
        if ($bad.Count -eq 0) {
            if (-not $Silent) { Write-Ok ("{0} {1} -> {2}" -f $c.name, (Format-Prefix $c.prefix), $c.expect) }
            continue
        }
        $failed.Add($c.name)
        if ($Silent) { continue }
        Write-Bad ("{0} {1} expected {2}" -f $c.name, (Format-Prefix $c.prefix), $c.expect)
        foreach ($r in $results) {
            Write-Host ("         {0,-14} {1,-7} ({2})" -f $r.Label, $r.Outcome, $r.Detail)
        }
        foreach ($r in $bad) {
            Write-Host "         --- $($r.Label) output ---"
            ($r.Output.TrimEnd() -split "`r?`n") | ForEach-Object { Write-Host "         $_" }
        }
    }
    return ,$failed
}

# ---- preconditions ----------------------------------------------------------

$script:bashExe = Resolve-BashPath
if ($null -eq $script:bashExe) {
    Write-Host '[FAIL] bash not found; parity requires both implementations.'
    exit 2
}
$script:pwshExe = (Get-Process -Id $PID).Path

$script:cases = @((Get-Content -LiteralPath $casesPath -Raw | ConvertFrom-Json).cases)
if ($script:cases.Count -eq 0) {
    Write-Host "[FAIL] no cases in $casesPath"
    exit 1
}

# ---- real sweep -------------------------------------------------------------

Write-Host "=== installer prefix parity ($($script:cases.Count) cases x 4 scripts) ==="
$realFailed = Invoke-Sweep -InstallSh (Join-Path $installDir 'install.sh')

if (-not $SelfTest) {
    Write-Host ''
    Write-Host "=== Summary: $($script:pass) passed, $($script:fail) failed ==="
    if ($script:fail -gt 0) { exit 1 }
    exit 0
}

# ---- self-test --------------------------------------------------------------

Write-Host ''
Write-Host '=== self-test: harness must DETECT a spaces-only prefix guard ==='
if ($realFailed.Count -gt 0) {
    # A harness that is already failing could "detect" the mutant for the
    # wrong reason (same two-stage rule as the other self-tests).
    Write-Host '  [FAIL] real sweep did not pass, so a mutant failure would prove nothing'
    exit 1
}

# The mutant lives beside the real script so its REPO_ROOT (resolved from its
# own path) still points at this checkout.
$mutant = Join-Path $installDir ('.selftest-install-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8) + '.sh')
$fixed  = '${PREFIX//[[:space:]]/}'
$source = [System.IO.File]::ReadAllText((Join-Path $installDir 'install.sh'))
if (-not $source.Contains($fixed)) {
    Write-Host "  [FAIL] self-test precondition: install.sh no longer contains $fixed"
    exit 1
}
[System.IO.File]::WriteAllText($mutant, $source.Replace($fixed, '${PREFIX// /}'), (New-Object System.Text.UTF8Encoding($false)))
try {
    $mutantFailed = Invoke-Sweep -InstallSh $mutant -Silent
} finally {
    Remove-Item -LiteralPath $mutant -Force -ErrorAction SilentlyContinue
}

if ($mutantFailed -notcontains 'tab-only') {
    Write-Host '  [FAIL] self-test: harness did NOT detect the spaces-only guard on tab-only'
    exit 1
}
Write-Host ("  [OK]   self-test: divergence detected on " + ($mutantFailed -join ', '))
exit 0
