#requires -Version 7.0
<#
.SYNOPSIS
    specwright: prompt-size-report parity runner (SW-57).

.DESCRIPTION
    Builds a throwaway git repo with two release tags and a dirty working
    tree, runs scripts/prompt-size-report.sh and scripts/prompt-size-report.ps1
    against it, and asserts:
      1. both exit 0 and print byte-identical stdout;
      2. that stdout equals a hand-computed golden table - so the two cannot
         agree on the same wrong answer;
      3. both exit 2 on a ref that does not exist.

    The fixture exercises every column the report has: growth over the flag
    threshold, shrinkage, a new file, a removed file, an unchanged file with
    multibyte UTF-8 content, a CRLF file (normalized bytes must ignore CR), an
    out-of-scope file that must not appear, and default-ref selection by
    version order (v0.10.0 beats v0.9.0, which a lexical sort would not pick).

.EXAMPLE
    .\tests\prompt-size-report\run-parity.ps1

.NOTES
    PURE ASCII. validate's Check 1 scans every *.ps1 recursively.
    Single cross-platform runner by design (same posture as
    tests/installer/run-prefix-parity.ps1): parity is asserted in one process
    rather than inferred from two green platform-native jobs.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$reportSh  = Join-Path $repoRoot 'scripts/prompt-size-report.sh'
$reportPs1 = Join-Path $repoRoot 'scripts/prompt-size-report.ps1'

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

$utf8 = New-Object System.Text.UTF8Encoding($false)
function Set-FixtureFile {
    param([string]$Rel, [string]$Content)
    $abs = Join-Path $script:fx $Rel
    New-Item -ItemType Directory -Path (Split-Path -Parent $abs) -Force | Out-Null
    [System.IO.File]::WriteAllText($abs, $Content, $utf8)
}

function Invoke-FixtureGit {
    param([string[]]$GitArgs)
    $all = @('-C', $script:fx, '-c', 'core.autocrlf=false', '-c', 'user.name=fixture',
        '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false',
        '-c', 'tag.gpgsign=false') + $GitArgs
    & git @all 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed" }
}

function Invoke-Report {
    param([string]$Kind, [string[]]$Extra)
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        if ($Kind -eq 'bash') {
            $out = & $script:bashExe ($reportSh -replace '\\', '/') --root ($script:fx -replace '\\', '/') @Extra 2>$errFile
        } else {
            $out = & $script:pwshExe -NoProfile -File $reportPs1 -Root $script:fx @Extra 2>$errFile
        }
        $rc = $LASTEXITCODE
        return [pscustomobject]@{ Code = $rc; Lines = @($out); Err = (Get-Content -LiteralPath $errFile -Raw) }
    } finally {
        Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    }
}

# ---- preconditions ----------------------------------------------------------

$script:bashExe = Resolve-BashPath
if ($null -eq $script:bashExe) {
    Write-Host '[FAIL] bash not found; parity requires both implementations.'
    exit 2
}
$script:pwshExe = (Get-Process -Id $PID).Path

# ---- fixture ----------------------------------------------------------------

$script:fx = Join-Path ([System.IO.Path]::GetTempPath()) ('sd-psr-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 12))
New-Item -ItemType Directory -Path $script:fx -Force | Out-Null

try {
    $manifest = @'
{
  "contractLint": { "scanScope": ["commands/*.md", "agents/*.md", "skills/*/SKILL.md"] },
  "promptSizeReport": { "flagGrowthPercent": 15 }
}
'@
    $eAcute = [string][char]0xE9   # 2 bytes in UTF-8; kept out of the source for Check 1

    Invoke-FixtureGit @('init', '-q')
    Set-FixtureFile 'specwright.manifest.json' $manifest
    Set-FixtureFile 'commands/alpha.md'    (('x' * 50) + "`n")
    Set-FixtureFile 'agents/beta.md'       (('y' * 200) + "`n")
    Set-FixtureFile 'skills/gone/SKILL.md' (('z' * 50) + "`n")
    Set-FixtureFile 'skills/keep/SKILL.md' (($eAcute * 10) + "`n")
    Set-FixtureFile 'notes/out.md'         "out of scope`n"
    Invoke-FixtureGit @('add', '-A')
    Invoke-FixtureGit @('commit', '-q', '-m', 'one')
    Invoke-FixtureGit @('tag', 'v0.9.0')

    Set-FixtureFile 'commands/alpha.md'    (('x' * 100) + "`n")
    Invoke-FixtureGit @('commit', '-q', '-a', '-m', 'two')
    Invoke-FixtureGit @('tag', 'v0.10.0')

    # Dirty working tree against v0.10.0.
    Set-FixtureFile 'commands/alpha.md'    (('x' * 60) + "`r`n" + ('x' * 59) + "`r`n")  # 120 normalized
    Set-FixtureFile 'agents/beta.md'       (('y' * 190) + "`n")
    Remove-Item -LiteralPath (Join-Path $script:fx 'skills/gone') -Recurse -Force
    Set-FixtureFile 'commands/new.md'      ('n' * 30)                                    # no trailing LF
    Set-FixtureFile 'notes/out.md'         "still out of scope, and longer`n"

    $t = [char]9
    $golden = @(
        "commands/new.md${t}-${t}30${t}30${t}new${t}-"
        "commands/alpha.md${t}100${t}120${t}20${t}+20.0%${t}FLAG"
        "skills/keep/SKILL.md${t}20${t}20${t}0${t}0.0%${t}-"
        "agents/beta.md${t}200${t}190${t}-10${t}-5.0%${t}-"
        "skills/gone/SKILL.md${t}50${t}-${t}-50${t}removed${t}-"
        "TOTAL:agents${t}200${t}190${t}-10${t}-5.0%${t}-"
        "TOTAL:commands${t}100${t}150${t}50${t}+50.0%${t}-"
        "TOTAL:skills${t}70${t}20${t}-50${t}-71.4%${t}-"
    )

    Write-Host '=== prompt-size-report parity (default ref) ==='
    $b = Invoke-Report 'bash' @()
    $p = Invoke-Report 'pwsh' @()
    foreach ($r in @(@('bash', $b), @('pwsh', $p))) {
        if ($r[1].Code -eq 0) { Write-Ok "$($r[0]) exit 0" }
        else { Write-Bad "$($r[0]) exit $($r[1].Code): $($r[1].Err)" }
    }
    $bText = $b.Lines -join "`n"
    $pText = $p.Lines -join "`n"
    if ($bText -ceq $pText) { Write-Ok 'bash and pwsh stdout identical' }
    else {
        Write-Bad 'bash and pwsh stdout differ'
        Compare-Object $b.Lines $p.Lines -CaseSensitive | ForEach-Object { Write-Host "         $($_.SideIndicator) $($_.InputObject)" }
    }
    if ($bText -ceq ($golden -join "`n")) { Write-Ok 'stdout matches the golden table' }
    else {
        Write-Bad 'stdout does not match the golden table'
        Write-Host '         --- expected ---'; $golden | ForEach-Object { Write-Host "         $_" }
        Write-Host '         --- bash ---';     $b.Lines | ForEach-Object { Write-Host "         $_" }
    }
    foreach ($r in @(@('bash', $b), @('pwsh', $p))) {
        if ($r[1].Err -match 'v0\.10\.0 -> working tree') { Write-Ok "$($r[0]) defaulted to v0.10.0 (version order)" }
        else { Write-Bad "$($r[0]) did not default to v0.10.0: $($r[1].Err)" }
    }

    Write-Host ''
    Write-Host '=== cannot-run exit code ==='
    $b = Invoke-Report 'bash' @('--since', 'no-such-ref')
    $p = Invoke-Report 'pwsh' @('-Since', 'no-such-ref')
    foreach ($r in @(@('bash', $b), @('pwsh', $p))) {
        if ($r[1].Code -eq 2) { Write-Ok "$($r[0]) exit 2 on a missing ref" }
        else { Write-Bad "$($r[0]) exit $($r[1].Code) on a missing ref, expected 2" }
    }
} finally {
    Remove-Item -LiteralPath $script:fx -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "=== Summary: $($script:pass) passed, $($script:fail) failed ==="
if ($script:fail -gt 0) { exit 1 }
exit 0
