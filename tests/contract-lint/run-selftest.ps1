#Requires -Version 5.1
<#
.SYNOPSIS
    Fixture suite and negative self-test for scripts/contract-lint.{ps1,sh}.

.DESCRIPTION
    One pwsh runner drives BOTH implementations in a single process, so
    cross-implementation parity is ASSERTED rather than inferred from two green
    runs in different jobs. This mirrors tests/hooks/run-conformance.ps1.

    For every case under fixtures/ it builds a workspace (a fresh copy of
    fixtures/_base with the case's overlay/ copied over it), runs both linters
    against it, and checks four things:

      1. the findings match expected.json (rule, severity, file, and an anchor
         that is resolved at run time - see "Anchors" below);
      2. the exit code follows from the expected severities;
      3. the bash and PowerShell outputs are identical LINE FOR LINE, message
         text included, even though expected.json never pins a message;
      4. nothing extra fired.

    Harness invariants, each a hard failure rather than a skip:

      A. fixtures/_base itself must produce ZERO findings. A seeded violation
         that leaked into the base would make every case's golden wrong in the
         same direction, and nothing would notice.
      B. fixtures/_base/specwright.manifest.json's rule registry must equal the
         repo manifest's registry, ids AND severities. Otherwise a wave-2 rule
         lands in the engine and the fixtures keep testing the old contract.
      C. every rule id in the repo registry appears in at least one
         expected.json. This is what makes "add a rule" mean "add a fixture".
      D. every rule id in the repo registry appears in docs/contract-lint.md's
         table, and that table names no rule the registry lacks.
      E. every case directory is registered in README.md and every case named in
         README.md exists. An unregistered case FAILS; it never silently skips.
      F. bash and jq must be present. A validator that skips when its tools are
         missing is a validator that turns CI green while checking nothing.

.PARAMETER SelfTest
    Negative mode. Replaces the bash linter with a stub that exits 0 and prints
    nothing, then asserts the harness DETECTS that divergence. Run in two
    stages: the real sweep must pass first, otherwise a broken harness could
    "detect" the stub for the wrong reason.

.PARAMETER Case
    Run only case directories whose name contains this substring. Diagnostic
    aid; invariants C, D and E are skipped when it is used, because a filtered
    run cannot honestly assert full coverage.

.EXAMPLE
    .\tests\contract-lint\run-selftest.ps1
    .\tests\contract-lint\run-selftest.ps1 -SelfTest

.NOTES
    PURE ASCII. validate's Check 1 scans every *.ps1 recursively, so this file
    must contain no byte above 0x7F.
#>

[CmdletBinding()]
param(
    [switch]$SelfTest,
    [string]$Case = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$testsRoot = $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $testsRoot)
$fixturesRoot = Join-Path $testsRoot 'fixtures'
$baseRoot = Join-Path $fixturesRoot '_base'
$lintPs1 = Join-Path $repoRoot 'scripts\contract-lint.ps1'
$lintSh = (Join-Path $repoRoot 'scripts\contract-lint.sh') -replace '\\', '/'

$script:Failures = New-Object System.Collections.Generic.List[string]
function Write-Section { param([string]$t) Write-Host ''; Write-Host "=== $t ===" -ForegroundColor Cyan }
function Write-Ok { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-FailMsg { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Add-Failure { param([string]$m) $script:Failures.Add($m) }

# ---- preconditions (invariant F) -------------------------------------------

function Find-WorkingBash {
    # Same search order as scripts/validate.ps1: the bare 'bash' on PATH is
    # often the WSL launcher, which fails with no distro installed and
    # mistranslates Windows paths. Prefer Git for Windows' bash.
    $candidates = New-Object System.Collections.Generic.List[string]
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $gitRoot = Split-Path -Parent (Split-Path -Parent $git.Source)
        $candidates.Add((Join-Path $gitRoot 'bin\bash.exe'))
        $candidates.Add((Join-Path $gitRoot 'usr\bin\bash.exe'))
    }
    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\Programs")) {
        if ($pf) {
            $candidates.Add((Join-Path $pf 'Git\bin\bash.exe'))
            $candidates.Add((Join-Path $pf 'Git\usr\bin\bash.exe'))
        }
    }
    foreach ($c in (Get-Command bash -All -ErrorAction SilentlyContinue)) { $candidates.Add($c.Source) }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            try {
                & $c -c 'exit 0' 2>$null
                if ($LASTEXITCODE -eq 0) { return $c }
            } catch { }
        }
    }
    return $null
}

Write-Section 'contract-lint self-test'
Write-Host "  Repo root: $repoRoot"

$bashExe = Find-WorkingBash
if ($null -eq $bashExe) {
    Write-FailMsg 'no working bash found - this harness runs BOTH implementations and cannot skip one'
    exit 2
}
& $bashExe -c 'command -v jq >/dev/null 2>&1' 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-FailMsg 'jq not found on the bash PATH - contract-lint.sh cannot parse the manifest'
    exit 2
}
foreach ($p in @($lintPs1, ($lintSh -replace '/', '\'), $baseRoot)) {
    if (-not (Test-Path -LiteralPath $p)) {
        Write-FailMsg "missing required path: $p"
        exit 1
    }
}
Write-Ok "bash: $bashExe"

$psExe = (Get-Process -Id $PID).Path

# ---- linter invocation ------------------------------------------------------

function Invoke-Linters {
    param([string]$Root, [string]$BashScript)
    $rootFwd = $Root -replace '\\', '/'
    $bashOut = @(& $bashExe $BashScript --root $rootFwd --quiet 2>$null)
    $bashExit = $LASTEXITCODE

    $psArgs = @('-NoProfile')
    if ($env:OS -eq 'Windows_NT') { $psArgs += @('-ExecutionPolicy', 'Bypass') }
    $psArgs += @('-File', $lintPs1, '-Root', $Root, '-Quiet')
    $psOut = @(& $psExe @psArgs 2>$null)
    $psExit = $LASTEXITCODE

    return @{
        BashOut = @($bashOut | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        PsOut = @($psOut | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        BashExit = $bashExit
        PsExit = $psExit
    }
}

function ConvertTo-Findings {
    param([string[]]$Rows)
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in $Rows) {
        $p = $r.Split([char]9)
        if ($p.Count -lt 5) { continue }
        [void]$out.Add([PSCustomObject]@{
            Rule = $p[0]; Severity = $p[1]; File = $p[2]; Line = [int]$p[3]; Message = $p[4]
        })
    }
    # .ToArray(), not the list and not a comma-wrapped list: a comma-wrapped
    # return arrives at the caller as ONE object that happens to be a list, and
    # @() around it then yields a single-element array whose only member has no
    # .Rule property. An array emits its elements, so @() collects zero or more.
    return $out.ToArray()
}

# ---- anchors ----------------------------------------------------------------
#
# expected.json pins an ANCHOR, never a literal line number. A literal rots the
# instant a line above it shifts, and the case then passes vacuously - the exact
# lesson scripts/selftest-docs.sh was rewritten for.
#
#   anchor "file"  the finding is a whole-file verdict; its line must be 1.
#   anchor "seed"  the finding must land within SEED_WINDOW lines AFTER the
#                  '<!-- SEEDED: <name> - <why> -->' marker. A window, not the
#                  next non-comment line, because the CL9xx cases report ON a
#                  comment line (the suppression itself).

$SEED_WINDOW = 3

function Get-SeedLine {
    param([string]$Workspace, [string]$File, [string]$Seed)
    $path = Join-Path $Workspace ($File -replace '/', '\')
    if (-not (Test-Path -LiteralPath $path)) { return -1 }
    $text = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($path))
    $lines = $text.Split([char]10)
    $needle = '<!-- SEEDED: ' + $Seed + ' - '
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i].Contains($needle)) { return $i + 1 }
    }
    return -1
}

function Test-Anchor {
    param([object]$Expected, [object]$Actual, [string]$Workspace)
    if ($Expected.anchor -ceq 'file') {
        return ($Actual.Line -eq 1)
    }
    $seedLine = Get-SeedLine -Workspace $Workspace -File $Expected.file -Seed $Expected.seed
    if ($seedLine -lt 0) { return $false }
    return ($Actual.Line -gt $seedLine -and $Actual.Line -le ($seedLine + $SEED_WINDOW))
}

# ---- workspace --------------------------------------------------------------

function New-CaseWorkspace {
    param([string]$CaseDir)
    $ws = Join-Path ([System.IO.Path]::GetTempPath()) ("cl-selftest-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $ws -Force | Out-Null
    Copy-Item -Path (Join-Path $baseRoot '*') -Destination $ws -Recurse -Force
    $overlay = Join-Path $CaseDir 'overlay'
    if (Test-Path -LiteralPath $overlay) {
        $items = @(Get-ChildItem -LiteralPath $overlay -Force)
        if ($items.Count -gt 0) {
            Copy-Item -Path (Join-Path $overlay '*') -Destination $ws -Recurse -Force
        }
    }
    return $ws
}

# ---- the sweep --------------------------------------------------------------

function Invoke-Sweep {
    param([string]$BashScript, [switch]$Silent)
    $result = @{ Failures = New-Object 'System.Collections.Generic.List[string]'; RulesSeen = (New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)) }

    $caseDirs = @(Get-ChildItem -LiteralPath $fixturesRoot -Directory |
        Where-Object { $_.Name -cne '_base' } | Sort-Object -Property Name)
    foreach ($cd in $caseDirs) {
        if ($Case.Length -gt 0 -and -not $cd.Name.Contains($Case)) { continue }
        $expPath = Join-Path $cd.FullName 'expected.json'
        if (-not (Test-Path -LiteralPath $expPath)) {
            $result.Failures.Add("$($cd.Name): no expected.json - an unregistered case fails, it does not skip")
            continue
        }
        $exp = (Get-Content -LiteralPath $expPath -Raw | ConvertFrom-Json)
        $expected = @()
        if ($null -ne $exp.findings) { $expected = @($exp.findings) }
        foreach ($e in $expected) { [void]$result.RulesSeen.Add([string]$e.rule) }

        $ws = New-CaseWorkspace -CaseDir $cd.FullName
        try {
            $run = Invoke-Linters -Root $ws -BashScript $BashScript

            # Parity first: if the twins disagree, every other verdict is noise.
            $diff = Compare-Object $run.BashOut $run.PsOut
            if ($null -ne $diff) {
                $result.Failures.Add("$($cd.Name): bash and PowerShell disagree ($($run.BashOut.Count) vs $($run.PsOut.Count) row(s))")
                foreach ($d in $diff) {
                    $side = if ($d.SideIndicator -eq '<=') { 'bash only' } else { 'pwsh only' }
                    $result.Failures.Add("$($cd.Name):   $side : $($d.InputObject)")
                }
            }
            if ($run.BashExit -ne $run.PsExit) {
                $result.Failures.Add("$($cd.Name): exit codes differ (bash $($run.BashExit), pwsh $($run.PsExit))")
            }

            $actual = @(ConvertTo-Findings -Rows $run.PsOut)
            $wantExit = 0
            foreach ($e in $expected) { if ($e.severity -ceq 'BLOCK') { $wantExit = 1 } }
            if ($run.PsExit -ne $wantExit) {
                $result.Failures.Add("$($cd.Name): expected exit $wantExit, got $($run.PsExit)")
            }

            $matched = New-Object 'System.Collections.Generic.List[int]'
            foreach ($e in $expected) {
                $hit = -1
                for ($i = 0; $i -lt $actual.Count; $i++) {
                    if ($matched.Contains($i)) { continue }
                    $a = $actual[$i]
                    if ($a.Rule -cne $e.rule) { continue }
                    if ($a.Severity -cne $e.severity) { continue }
                    if ($a.File -cne $e.file) { continue }
                    if (-not (Test-Anchor -Expected $e -Actual $a -Workspace $ws)) { continue }
                    $hit = $i; break
                }
                if ($hit -lt 0) {
                    $where = if ($e.anchor -ceq 'file') { 'line 1' } else { "seed '$($e.seed)'" }
                    $result.Failures.Add("$($cd.Name): expected $($e.rule) $($e.severity) in $($e.file) at $where - not found")
                } else {
                    [void]$matched.Add($hit)
                }
            }
            for ($i = 0; $i -lt $actual.Count; $i++) {
                if ($matched.Contains($i)) { continue }
                $a = $actual[$i]
                $result.Failures.Add("$($cd.Name): unexpected $($a.Rule) at $($a.File):$($a.Line) - $($a.Message)")
            }

            if (-not $Silent) {
                $n = $result.Failures.Count
                if ($n -eq $script:sweepMark) {
                    Write-Ok "$($cd.Name) ($($expected.Count) expected finding(s))"
                } else {
                    Write-FailMsg "$($cd.Name)"
                }
                $script:sweepMark = $n
            }
        } finally {
            Remove-Item -LiteralPath $ws -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return $result
}

# ---- invariant A: the base tree is clean -----------------------------------

Write-Section 'Invariant A: fixtures/_base produces no findings'
$baseRun = Invoke-Linters -Root $baseRoot -BashScript $lintSh
if ($baseRun.BashOut.Count -ne 0 -or $baseRun.PsOut.Count -ne 0) {
    Write-FailMsg "fixtures/_base is not clean (bash $($baseRun.BashOut.Count), pwsh $($baseRun.PsOut.Count) finding(s))"
    foreach ($r in $baseRun.PsOut) { Write-Host "         $r" }
    Add-Failure 'base tree is not clean'
} elseif ($baseRun.BashExit -ne 0 -or $baseRun.PsExit -ne 0) {
    Write-FailMsg "fixtures/_base exit codes are not both 0 (bash $($baseRun.BashExit), pwsh $($baseRun.PsExit))"
    Add-Failure 'base tree exit code'
} else {
    Write-Ok 'base tree is clean on both implementations'
}

# ---- invariant B: fixture registry mirrors the repo registry ---------------

Write-Section 'Invariant B: fixture rule registry mirrors the repo registry'
$repoManifest = Get-Content -LiteralPath (Join-Path $repoRoot 'specwright.manifest.json') -Raw | ConvertFrom-Json
$baseManifest = Get-Content -LiteralPath (Join-Path $baseRoot 'specwright.manifest.json') -Raw | ConvertFrom-Json
$repoReg = @($repoManifest.contractLint.rules | ForEach-Object { "$($_.id)=$($_.severity)" })
$baseReg = @($baseManifest.contractLint.rules | ForEach-Object { "$($_.id)=$($_.severity)" })
$regDiff = Compare-Object $repoReg $baseReg
if ($null -ne $regDiff) {
    foreach ($d in $regDiff) {
        $side = if ($d.SideIndicator -eq '<=') { 'repo only' } else { 'fixture only' }
        Write-FailMsg "registry mismatch ($side): $($d.InputObject)"
    }
    Add-Failure 'fixture registry differs from repo registry'
} else {
    Write-Ok "$($repoReg.Count) rule(s), identical id and severity in both manifests"
}

# ---- the case sweep --------------------------------------------------------

Write-Section 'Fixture cases'
$script:sweepMark = 0
$sweep = Invoke-Sweep -BashScript $lintSh
foreach ($f in $sweep.Failures) { Write-FailMsg $f; Add-Failure $f }
if ($sweep.Failures.Count -eq 0) { Write-Host '' }

# ---- invariants C, D, E ----------------------------------------------------

if ($Case.Length -gt 0) {
    Write-Section 'Invariants C, D, E'
    Write-Ok 'skipped: -Case filters the sweep, so coverage cannot be asserted honestly'
} else {
    Write-Section 'Invariant C: every rule has a fixture'
    $uncovered = @()
    foreach ($r in $repoManifest.contractLint.rules) {
        if (-not $sweep.RulesSeen.Contains([string]$r.id)) { $uncovered += [string]$r.id }
    }
    if ($uncovered.Count -gt 0) {
        Write-FailMsg "no expected.json mentions: $($uncovered -join ', ')"
        Add-Failure 'rules without a fixture'
    } else {
        Write-Ok "all $($repoReg.Count) rule(s) appear in at least one expected.json"
    }

    Write-Section 'Invariant D: registry matches docs/contract-lint.md'
    $docPath = Join-Path $repoRoot 'docs\contract-lint.md'
    if (-not (Test-Path -LiteralPath $docPath)) {
        Write-FailMsg 'docs/contract-lint.md not found'
        Add-Failure 'contract-lint doc missing'
    } else {
        $docIds = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($line in (Get-Content -LiteralPath $docPath)) {
            $m = [regex]::Match($line, '^\| `(CL[0-9][0-9][0-9])` \|')
            if ($m.Success) { [void]$docIds.Add($m.Groups[1].Value) }
        }
        $regIds = @($repoManifest.contractLint.rules | ForEach-Object { [string]$_.id })
        $docDiff = Compare-Object $regIds @($docIds)
        if ($null -ne $docDiff) {
            foreach ($d in $docDiff) {
                $side = if ($d.SideIndicator -eq '<=') { 'in the registry, missing from the doc' } else { 'in the doc, missing from the registry' }
                Write-FailMsg "$($d.InputObject) is $side"
            }
            Add-Failure 'registry and docs/contract-lint.md disagree'
        } else {
            Write-Ok "$($docIds.Count) rule(s) documented, both directions"
        }
    }

    Write-Section 'Invariant E: every case is registered in README.md'
    $readmePath = Join-Path $testsRoot 'README.md'
    if (-not (Test-Path -LiteralPath $readmePath)) {
        Write-FailMsg 'tests/contract-lint/README.md not found'
        Add-Failure 'fixture README missing'
    } else {
        $readme = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($readmePath))
        $onDisk = @(Get-ChildItem -LiteralPath $fixturesRoot -Directory |
            Where-Object { $_.Name -cne '_base' } | ForEach-Object { $_.Name } | Sort-Object)
        $named = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
        foreach ($m in [regex]::Matches($readme, '`(clean|cl[0-9]{3}-[a-z0-9-]+|fp-[a-z0-9-]+)`')) {
            [void]$named.Add($m.Groups[1].Value)
        }
        $caseDiff = Compare-Object $onDisk @($named)
        if ($null -ne $caseDiff) {
            foreach ($d in $caseDiff) {
                $side = if ($d.SideIndicator -eq '<=') { 'on disk but not in README.md' } else { 'in README.md but not on disk' }
                Write-FailMsg "$($d.InputObject) is $side"
            }
            Add-Failure 'case directories and README.md disagree'
        } else {
            Write-Ok "$($onDisk.Count) case(s), all registered"
        }
    }
}

# ---- negative self-test ----------------------------------------------------

if ($SelfTest) {
    Write-Section 'Negative self-test: does the harness notice a dead linter?'
    if ($script:Failures.Count -gt 0) {
        # Two-stage, as in tests/hooks/run-conformance.ps1: a harness that is
        # already failing could "detect" the stub for entirely the wrong reason.
        Write-FailMsg 'the real sweep did not pass, so a stub failure would prove nothing'
        Add-Failure 'self-test precondition: real sweep must pass first'
    } else {
        $stubDir = Join-Path ([System.IO.Path]::GetTempPath()) ("cl-stub-" + [System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $stubDir -Force | Out-Null
        try {
            $stub = Join-Path $stubDir 'contract-lint.sh'
            $stubBody = "#!/usr/bin/env bash" + [char]10 + "# stub: reports nothing and claims success" + [char]10 + "exit 0" + [char]10
            [System.IO.File]::WriteAllText($stub, $stubBody, (New-Object System.Text.UTF8Encoding($false)))
            $stubFwd = $stub -replace '\\', '/'
            $stubSweep = Invoke-Sweep -BashScript $stubFwd -Silent
            if ($stubSweep.Failures.Count -eq 0) {
                Write-FailMsg 'a linter that reports NOTHING passed the whole suite - the harness is not checking anything'
                Add-Failure 'self-test: stub linter went undetected'
            } else {
                Write-Ok "stub linter detected: $($stubSweep.Failures.Count) failure(s) raised"
            }
        } finally {
            Remove-Item -LiteralPath $stubDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---- summary ---------------------------------------------------------------

Write-Section 'Summary'
if ($script:Failures.Count -eq 0) {
    Write-Host '  [OK]   contract-lint self-test passed.' -ForegroundColor Green
    # GitHub Actions appends 'exit $LASTEXITCODE' to every pwsh step, so an
    # implicit success must still be an explicit 0.
    exit 0
} else {
    Write-Host "  [FAIL] $($script:Failures.Count) failure(s):" -ForegroundColor Red
    foreach ($m in $script:Failures) { Write-Host "         - $m" -ForegroundColor Red }
    exit 1
}
