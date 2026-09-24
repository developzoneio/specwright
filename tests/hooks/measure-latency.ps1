#requires -Version 7.0
<#
.SYNOPSIS
    specwright: per-invocation latency measurement for the three shipped hooks (SW-50).

.DESCRIPTION
    Spawns each hook (spec-gate, prompt-router, subagent-retro) as a fresh child
    process, once per curated fixture case, under every available PowerShell
    flavor (Windows PowerShell 5.1 "powershell" and PowerShell 7+ "pwsh"), and
    reports p50/p95 wall-clock latency per (hook, flavor).

    Fixture cases are read from tests/hooks/fixtures/latency-selection.json - a
    small curated subset of the existing conformance fixtures under
    tests/hooks/fixtures/<hook>/<case>/, not the full suite, so a latency run
    stays fast and is not dominated by pathological edge cases.

    Method: for each (flavor, hook, case), run -WarmupIterations untimed passes
    (let OS file-cache / JIT settle) followed by -Iterations timed passes. Each
    timed pass gets a FRESH copy of the case's workspace/ tree (mirrors
    run-conformance.ps1's New-CaseWorkspace) so hook state (e.g. the
    subagent-retro debounce file, metrics event log) cannot leak between runs
    and skew later iterations. Elapsed time is measured with
    [System.Diagnostics.Stopwatch] around Process.Start()..WaitForExit() only -
    workspace setup/teardown happens outside the timed window. Percentiles use
    the nearest-rank method: for N sorted samples, the P-th percentile is
    sample number ceil(P/100 * N), 1-indexed.

    -CheckBudget compares the computed numbers against
    specwright.manifest.json's "hookLatencyBudgets" and exits non-zero if any
    (hook, flavor, percentile) exceeds its budget. It also fails when the budget
    block is missing, when a measured (hook, flavor) has no declared budget, when
    an explicitly requested -Flavors entry is not installed, and - before any
    measuring starts - when a declared p95 budget exceeds half that hook's
    "timeout" in templates/settings.template.json (the SW-50 AC-5 ceiling: a
    budget may not be raised past it without raising the timeout in the same
    commit). Without -CheckBudget the script only reports; it never fails the
    build on its own.

.NOTES
    PURE ASCII ONLY (see hooks/powershell/prompt-router.ps1 for why).
    No bash twin: like tests/hooks/run-conformance.ps1, this must drive
    multiple PowerShell flavors from one orchestrating process to produce
    directly comparable numbers, so a bash twin would itself be a source of
    drift rather than a benefit. scripts/validate.{sh,ps1} Check 3/9 (hook-pair
    parity) is scoped only to hooks/powershell/*.ps1 <-> hooks/bash/*.sh and
    does not reach tests/hooks/, matching run-conformance.ps1's precedent.

    This script intentionally spawns "powershell.exe" as its own child process
    when available. tests/hooks/run-conformance.ps1's "pwsh" side only ever
    spawns pwsh, even on windows-latest in CI - so today's CI never actually
    exercises real Windows PowerShell 5.1. Measuring that number is the whole
    point of SW-50, so this script must not repeat that gap.
#>

[CmdletBinding()]
param(
    [string[]]$Flavors,
    [int]$Iterations = 30,
    [int]$WarmupIterations = 2,
    [string]$SelectionFile,
    [string]$OutJson,
    [switch]$CheckBudget
)

$ErrorActionPreference = 'Stop'

$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot    = (Resolve-Path (Join-Path $scriptDir '..' '..')).Path
$fixturesDir = Join-Path $scriptDir 'fixtures'
$manifestPath = Join-Path $repoRoot 'specwright.manifest.json'
$settingsTemplatePath = Join-Path $repoRoot 'templates' 'settings.template.json'

if (-not $SelectionFile) {
    $SelectionFile = Join-Path $fixturesDir 'latency-selection.json'
}

# ---- workspace setup (mirrors run-conformance.ps1's New-CaseWorkspace) -----

function New-LatencyWorkspace {
    param([string]$CaseDir)

    $name = 'sd-latency-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 12)
    $ws = Join-Path ([System.IO.Path]::GetTempPath()) $name
    New-Item -ItemType Directory -Path $ws -Force | Out-Null

    $src = Join-Path $CaseDir 'workspace'
    if (Test-Path -LiteralPath $src) {
        Get-ChildItem -LiteralPath $src -Force | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $ws -Recurse -Force
        }
    }

    $setupPath = Join-Path $CaseDir 'setup.json'
    if (Test-Path -LiteralPath $setupPath) {
        $setup = Get-Content -LiteralPath $setupPath -Raw | ConvertFrom-Json
        foreach ($t in @($setup.touch)) {
            if ($null -eq $t) { continue }
            $target = Join-Path $ws $t.path
            if (Test-Path -LiteralPath $target) {
                $item = Get-Item -LiteralPath $target
                $item.LastWriteTimeUtc = [System.DateTime]::UtcNow.AddMinutes(-1 * [double]$t.ageMinutes)
            }
        }
        foreach ($w in @($setup.write)) {
            if ($null -eq $w) { continue }
            $content = [string]$w.content
            $content = [regex]::Replace($content, '\{\{UTCNOW([+-]\d+)M\}\}', {
                param($m)
                $offset = [int]$m.Groups[1].Value
                [System.DateTime]::UtcNow.AddMinutes($offset).ToString('yyyy-MM-ddTHH:mm:ssZ')
            })
            $target = Join-Path $ws $w.path
            $dir = Split-Path -Path $target -Parent
            if (-not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            Set-Content -LiteralPath $target -Value $content -Encoding ascii -NoNewline
        }
    }

    return $ws
}

function Invoke-TimedHookRun {
    param(
        [string]$Exe,
        [string]$HookScript,
        [string]$Payload
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Exe
    foreach ($a in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $HookScript)) {
        $psi.ArgumentList.Add($a)
    }
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        $proc.StandardInput.Write($Payload)
        $proc.StandardInput.Close()
    } catch [System.IO.IOException] {
        # Child exited without reading stdin - not a measurement failure.
    }
    $null = $proc.StandardOutput.ReadToEnd()
    $null = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    $sw.Stop()
    return $sw.Elapsed.TotalMilliseconds
}

function Get-Percentile {
    param([double[]]$Values, [double]$Percentile)
    if (@($Values).Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $n = $sorted.Count
    $rank = [Math]::Ceiling($Percentile / 100.0 * $n)
    if ($rank -lt 1) { $rank = 1 }
    if ($rank -gt $n) { $rank = $n }
    return [Math]::Round($sorted[$rank - 1], 1)
}

# ---- flavor discovery -------------------------------------------------------

function Get-AvailableFlavors {
    $available = [System.Collections.Generic.List[string]]::new()
    if ($null -ne (Get-Command pwsh -ErrorAction SilentlyContinue)) {
        $available.Add('pwsh')
    }
    if ($IsWindows -and ($null -ne (Get-Command powershell -ErrorAction SilentlyContinue))) {
        $available.Add('powershell')
    }
    return @($available)
}

$available = Get-AvailableFlavors
if ($null -eq $Flavors -or $Flavors.Count -eq 0) {
    $Flavors = $available
} else {
    foreach ($f in $Flavors) {
        if ($available -notcontains $f) {
            if ($CheckBudget) {
                # A CI job that asks for 'powershell' and silently measures only
                # pwsh would report green without ever touching 5.1 - the exact
                # gap this script exists to close.
                Write-Host "[FAIL] requested flavor '$f' is not available on this machine"
                exit 1
            }
            Write-Host "[WARN] requested flavor '$f' is not available on this machine; skipping"
        }
    }
    $Flavors = @($Flavors | Where-Object { $available -contains $_ })
}
if ($Flavors.Count -eq 0) {
    Write-Host '[FAIL] no requested PowerShell flavor is available (need pwsh and/or powershell)'
    exit 1
}

# ---- fixture selection -------------------------------------------------------

if (-not (Test-Path -LiteralPath $SelectionFile)) {
    Write-Host "[FAIL] selection file not found: $SelectionFile"
    exit 1
}
$selection = Get-Content -LiteralPath $SelectionFile -Raw | ConvertFrom-Json
$hookNames = @($selection.PSObject.Properties.Name | Where-Object { $_ -ne '_comment' })

# ---- budget load + timeout ceiling (before measuring, so a bad budget fails fast)

function Get-HookTimeoutSeconds {
    # Finds the "timeout" wired for <hookName>.ps1 in the settings template.
    # Returns $null when the hook is not wired there.
    param($Settings, [string]$HookName)
    foreach ($eventProp in $Settings.hooks.PSObject.Properties) {
        foreach ($matcherEntry in @($eventProp.Value)) {
            foreach ($h in @($matcherEntry.hooks)) {
                if ($null -eq $h -or $null -eq $h.command) { continue }
                if (([string]$h.command) -like "*/$HookName.ps1*") {
                    return [double]$h.timeout
                }
            }
        }
    }
    return $null
}

$budgets = $null
if ($CheckBudget) {
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        Write-Host "[FAIL] manifest not found: $manifestPath"
        exit 1
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $budgets = $manifest.hookLatencyBudgets.budgets
    if ($null -eq $budgets) {
        Write-Host '[FAIL] specwright.manifest.json has no hookLatencyBudgets.budgets'
        exit 1
    }
    if (-not (Test-Path -LiteralPath $settingsTemplatePath)) {
        Write-Host "[FAIL] settings template not found: $settingsTemplatePath"
        exit 1
    }
    $settings = Get-Content -LiteralPath $settingsTemplatePath -Raw | ConvertFrom-Json

    Write-Host '=== budget ceiling (p95 <= timeout / 2) ==='
    $ceilingViolations = 0
    foreach ($hookProp in $budgets.PSObject.Properties) {
        $timeoutSec = Get-HookTimeoutSeconds -Settings $settings -HookName $hookProp.Name
        if ($null -eq $timeoutSec -or $timeoutSec -le 0) {
            Write-Host "[FAIL] budgeted hook '$($hookProp.Name)' has no timeout in templates/settings.template.json"
            $ceilingViolations++
            continue
        }
        $ceilingMs = $timeoutSec * 1000.0 / 2.0
        foreach ($flavorProp in $hookProp.Value.PSObject.Properties) {
            $p95Budget = $flavorProp.Value.p95
            if ($null -eq $p95Budget) {
                Write-Host "[FAIL] $($hookProp.Name)/$($flavorProp.Name) declares no p95 budget"
                $ceilingViolations++
            } elseif ([double]$p95Budget -gt $ceilingMs) {
                Write-Host ("[FAIL] {0}/{1} p95 budget {2} ms exceeds ceiling {3} ms (timeout {4}s / 2) - raise the timeout in the same commit, or optimise" -f $hookProp.Name, $flavorProp.Name, $p95Budget, $ceilingMs, $timeoutSec)
                $ceilingViolations++
            } else {
                Write-Host ("[OK]   {0}/{1} p95 budget {2} ms <= ceiling {3} ms" -f $hookProp.Name, $flavorProp.Name, $p95Budget, $ceilingMs)
            }
        }
    }
    if ($ceilingViolations -gt 0) {
        Write-Host ''
        Write-Host "=== $ceilingViolations budget ceiling violation(s) ==="
        exit 1
    }
}

# ---- measurement loop ---------------------------------------------------------

# results[hook][flavor] = List[double] (ms), pooled across that hook's selected cases
$results = @{}
foreach ($hookName in $hookNames) {
    $results[$hookName] = @{}
    foreach ($flavor in $Flavors) { $results[$hookName][$flavor] = [System.Collections.Generic.List[double]]::new() }
}

foreach ($hookName in $hookNames) {
    $hookScript = Join-Path $repoRoot 'hooks' 'powershell' "$hookName.ps1"
    if (-not (Test-Path -LiteralPath $hookScript)) {
        Write-Host "[WARN] no hooks/powershell/$hookName.ps1 found; skipping"
        continue
    }
    $caseNames = @($selection.$hookName)
    Write-Host ''
    Write-Host "=== $hookName ==="
    foreach ($flavor in $Flavors) {
        foreach ($caseName in $caseNames) {
            $caseDir = Join-Path $fixturesDir $hookName $caseName
            if (-not (Test-Path -LiteralPath $caseDir)) {
                Write-Host "[WARN] fixture case not found: $hookName/$caseName; skipping"
                continue
            }
            $inputPath = Join-Path $caseDir 'input.json'
            $rawPayload = Get-Content -LiteralPath $inputPath -Raw

            $total = $WarmupIterations + $Iterations
            for ($i = 0; $i -lt $total; $i++) {
                $ws = New-LatencyWorkspace -CaseDir $caseDir
                try {
                    $wsForward = $ws.Replace('\', '/')
                    $payload = $rawPayload.Replace('{{CWD}}', $wsForward)
                    $elapsedMs = Invoke-TimedHookRun -Exe $flavor -HookScript $hookScript -Payload $payload
                    if ($i -ge $WarmupIterations) {
                        $results[$hookName][$flavor].Add($elapsedMs)
                    }
                } finally {
                    Remove-Item -LiteralPath $ws -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
        $samples = @($results[$hookName][$flavor])
        $p50 = Get-Percentile -Values $samples -Percentile 50
        $p95 = Get-Percentile -Values $samples -Percentile 95
        $mean = [Math]::Round((($samples | Measure-Object -Average).Average), 1)
        Write-Host ("  {0,-10} n={1,-4} p50={2,6} ms  p95={3,6} ms  mean={4,6} ms" -f $flavor, $samples.Count, $p50, $p95, $mean)
    }
}

# ---- summary object -----------------------------------------------------------

$summary = [ordered]@{
    unit = 'milliseconds'
    method = 'nearest-rank percentile over Iterations timed runs (WarmupIterations discarded), pooled across the case set in tests/hooks/fixtures/latency-selection.json'
    iterations = $Iterations
    warmupIterations = $WarmupIterations
    hooks = [ordered]@{}
}
foreach ($hookName in $hookNames) {
    $summary.hooks[$hookName] = [ordered]@{}
    foreach ($flavor in $Flavors) {
        $samples = @($results[$hookName][$flavor])
        $summary.hooks[$hookName][$flavor] = [ordered]@{
            samples = $samples.Count
            p50 = Get-Percentile -Values $samples -Percentile 50
            p95 = Get-Percentile -Values $samples -Percentile 95
            min = if ($samples.Count -gt 0) { [Math]::Round(($samples | Measure-Object -Minimum).Minimum, 1) } else { $null }
            max = if ($samples.Count -gt 0) { [Math]::Round(($samples | Measure-Object -Maximum).Maximum, 1) } else { $null }
        }
    }
}

if ($OutJson) {
    ($summary | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $OutJson -Encoding utf8
    Write-Host ''
    Write-Host "results written to $OutJson"
}

# ---- budget check ---------------------------------------------------------

if ($CheckBudget) {
    Write-Host ''
    Write-Host '=== budget check ==='
    # An unbudgeted (hook, flavor) is a failure, not a skip: a new hook or a new
    # flavor must declare its budget in the same commit that starts measuring it.
    $overBudget = 0
    foreach ($hookName in $hookNames) {
        $hookBudget = $budgets.$hookName
        if ($null -eq $hookBudget) {
            Write-Host "[FAIL] no budget declared for hook '$hookName'"
            $overBudget++
            continue
        }
        foreach ($flavor in $Flavors) {
            $flavorBudget = $hookBudget.$flavor
            if ($null -eq $flavorBudget) {
                Write-Host "[FAIL] no budget declared for '$hookName' / '$flavor'"
                $overBudget++
                continue
            }
            $measured = $summary.hooks[$hookName][$flavor]
            foreach ($pct in @('p50', 'p95')) {
                $budgetVal = $flavorBudget.$pct
                $measuredVal = $measured.$pct
                if ($null -eq $budgetVal) { continue }
                if ($null -eq $measuredVal) {
                    Write-Host ("[FAIL] {0}/{1} {2}: no samples measured (every selected case was skipped)" -f $hookName, $flavor, $pct)
                    $overBudget++
                    continue
                }
                if ($measuredVal -gt $budgetVal) {
                    Write-Host ("[FAIL] {0}/{1} {2}: {3} ms exceeds budget {4} ms" -f $hookName, $flavor, $pct, $measuredVal, $budgetVal)
                    $overBudget++
                } else {
                    Write-Host ("[OK]   {0}/{1} {2}: {3} ms within budget {4} ms" -f $hookName, $flavor, $pct, $measuredVal, $budgetVal)
                }
            }
        }
    }
    if ($overBudget -gt 0) {
        Write-Host ''
        Write-Host "=== $overBudget budget violation(s) ==="
        exit 1
    }
    Write-Host ''
    Write-Host '=== all measured percentiles within budget ==='
}

exit 0
