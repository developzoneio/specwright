#requires -Version 7.0
<#
.SYNOPSIS
    specwright: headless behavioral eval harness for commands and gates (SW-27).

.DESCRIPTION
    Drives real `claude -p` (headless) sessions against a throwaway copy of a
    fixture project, one scenario per run, and asserts on PRODUCED ARTIFACTS
    (files, frontmatter, status values) rather than transcript wording.

    Isolation: each scenario gets a fresh "fake home" directory with the
    engine installed into it via install.ps1 -BasePath <fakehome>/.claude
    (the same sandbox pattern CI's install/uninstall round-trip job uses),
    and a fresh workspace directory holding the project under test. The
    claude subprocess runs with HOME/USERPROFILE pointed at the fake home and
    cwd set to the workspace, so `~/.claude/...` (used literally in command
    prompts, e.g. setup.md Phase 0) and `${HOME}` (used in settings.json hook
    command strings) both resolve to the sandbox, never the real user
    install. --setting-sources project is passed as a second, independent
    guarantee that no real user-scope settings.json can merge in.

    Neither of those stops the ANCESTOR WALK (SW-73): when no git root stops
    it, Claude Code loads every ancestor `.claude/` of the cwd as PROJECT
    scope, which outranks the fake home's user scope. So the sandbox root
    must have no `.claude/` above it. On Windows GetTempPath() sits under the
    user profile (next to the real ~/.claude), so the root defaults to
    <SystemDrive>\sd-e2e there; Unix keeps GetTempPath(). SD_E2E_ROOT
    overrides both.

    Debug switches (any non-empty value turns one on): SD_E2E_DEBUG prints
    claude's result and the workspace's events.jsonl; SD_E2E_KEEP keeps the
    workspace and fake home; SD_E2E_TRANSCRIPT (SW-79) drops
    --no-session-persistence so the session transcript is written under
    <fakeHome>/.claude/projects/, and implies SD_E2E_KEEP.

    Each scenario directory under scenarios/<name>/ may contain:
      source.txt   - optional, one line: a repo-relative path to copy as the
                      base workspace (e.g. examples/fixture-project).
      workspace/   - optional overlay copied on top of the base afterward
                      (added/overwritten files only - mirrors the
                      tests/contract-lint fixture _base + overlay pattern).
      prompt.txt   - the literal prompt fed to `claude -p`.
      expect.json  - declarative assertions evaluated after the run.
      budget.txt   - optional, one line: --max-budget-usd override (default 3).
      requires.txt - optional, one command name per line that must be on
                      PATH (e.g. node, npm); checked by the preflight.

    Preflight: before any sandbox is built, the harness checks the claude
    CLI (present, >= the minimum version), that some claude auth is
    available (CLAUDE_CODE_OAUTH_TOKEN, ~/.claude/.credentials.json, or
    ANTHROPIC_API_KEY - subscription auth needs no API key), and every
    requires.txt command of the selected scenarios, and that no ancestor of
    the sandbox root holds a `.claude/` (SW-73). A missing prerequisite
    exits 2 with the dependency named, never as a failed assertion.

    -SelfTest re-runs the negative scenarios (03, 04) with spec-gate's
    installed hook files replaced by an always-allow stub, and asserts they
    now FAIL - proving the harness would catch a regression that removes the
    guard (mirrors tests/hooks/run-conformance.ps1 and
    tests/contract-lint/run-selftest.ps1's own -SelfTest modes).

.NOTES
    PURE ASCII ONLY (see hooks/powershell/prompt-router.ps1 for why).
    Single cross-platform runner by design, same posture as
    tests/hooks/run-conformance.ps1 and tests/contract-lint/run-selftest.ps1:
    this is a test harness, not a hooks/ file, so the "hooks ship in pairs"
    rule in CLAUDE.md does not apply.
#>

[CmdletBinding()]
param(
    [string]$Case,
    [switch]$SelfTest,
    [int]$TimeoutSeconds = 600
)

$ErrorActionPreference = 'Stop'

$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot     = (Resolve-Path (Join-Path $scriptDir '..' '..')).Path
$scenariosDir = Join-Path $scriptDir 'scenarios'
$installPs1   = Join-Path $repoRoot 'install' 'install.ps1'

$script:pass = 0
$script:fail = 0

function Write-Ok   { param([string]$m) Write-Host "  [OK]   $m"; $script:pass++ }
function Write-Bad  { param([string]$m) Write-Host "  [FAIL] $m"; $script:fail++ }
function Write-Info { param([string]$m) Write-Host "         $m" }

# ---- prerequisites -----------------------------------------------------------

$script:minClaudeVersion = [version]'2.1.196'

function Exit-MissingPrereq {
    # A missing prerequisite exits 2 and names the dependency, before any
    # sandbox is built - it must never surface as a failed scenario assertion.
    param([string]$Message)
    Write-Host "[FAIL] $Message"
    Write-Host '       See tests/e2e/README.md "Prerequisites".'
    exit 2
}

function Test-EnvSet {
    # GitHub Actions sets an env var bound to an absent secret to "", so an
    # empty value counts as unset.
    param([string]$Name)
    return (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($Name)))
}

function Get-CredentialsPath {
    return (Join-Path $HOME '.claude' '.credentials.json')
}

function Get-AuthMode {
    # First match wins; the order is the order the README recommends.
    if (Test-EnvSet 'CLAUDE_CODE_OAUTH_TOKEN') { return 'subscription (CLAUDE_CODE_OAUTH_TOKEN)' }
    if (Test-Path -LiteralPath (Get-CredentialsPath)) { return 'subscription (~/.claude/.credentials.json)' }
    if (Test-EnvSet 'ANTHROPIC_API_KEY') { return 'API key (ANTHROPIC_API_KEY)' }
    return $null
}

function Get-ScenarioRequirements {
    # Optional requires.txt: one command name per line that must be on PATH
    # for this scenario (blank lines and # comments ignored).
    param([string]$ScenarioDir)
    $p = Join-Path $ScenarioDir 'requires.txt'
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    return @(Get-Content -LiteralPath $p |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') })
}

function Assert-Prerequisites {
    param([string[]]$ScenarioDirs)

    if ($null -eq (Get-Command claude -ErrorAction SilentlyContinue)) {
        Exit-MissingPrereq 'claude CLI not found on PATH; the e2e harness drives real `claude -p` sessions.'
    }
    $versionText = (& claude --version 2>$null | Out-String).Trim()
    if ($versionText -notmatch '(\d+\.\d+\.\d+)') {
        Exit-MissingPrereq "claude CLI version unreadable ('claude --version' printed '$versionText'); need $($script:minClaudeVersion) or later."
    }
    $claudeVersion = [version]$Matches[1]
    if ($claudeVersion -lt $script:minClaudeVersion) {
        Exit-MissingPrereq "claude CLI $claudeVersion is older than the required $($script:minClaudeVersion); update the claude CLI."
    }
    Write-Host "[INFO] claude CLI: $claudeVersion"

    $authMode = Get-AuthMode
    if ($null -eq $authMode) {
        Exit-MissingPrereq ('no claude auth found. Provide one of: ' +
            'CLAUDE_CODE_OAUTH_TOKEN (subscription - run `claude setup-token`), ' +
            'a claude.ai login in ~/.claude/.credentials.json (subscription - run `claude` and /login), ' +
            'or ANTHROPIC_API_KEY (API billing).')
    }
    Write-Host "[INFO] auth: $authMode"
    if ((Test-EnvSet 'ANTHROPIC_API_KEY') -and $authMode -like 'subscription*') {
        Write-Host '[WARN] ANTHROPIC_API_KEY is also set; claude -p prefers it, so this run bills the API, not the subscription. Unset it to run on the subscription.'
    }

    foreach ($dir in $ScenarioDirs) {
        foreach ($cmd in (Get-ScenarioRequirements -ScenarioDir $dir)) {
            if ($null -eq (Get-Command $cmd -ErrorAction SilentlyContinue)) {
                Exit-MissingPrereq "'$cmd' not found on PATH; scenario $(Split-Path -Leaf $dir) requires it (requires.txt)."
            }
        }
    }

    $leak = Find-AncestorClaudeDir -Root $script:sandboxRoot
    if ($leak) {
        Write-Host "[FAIL] sandbox root '$($script:sandboxRoot)' is not isolated: '$leak' sits above it."
        Write-Host '       Claude Code would load it as PROJECT scope, shadowing the fake-home engine (SW-73).'
        Write-Host '       Set SD_E2E_ROOT to a directory with no .claude folder in it or any ancestor.'
        Write-Host '       See tests/e2e/README.md "Isolation and auth".'
        exit 2
    }
    Write-Host "[INFO] sandbox root: $($script:sandboxRoot)"
}

# ---- sandbox construction ---------------------------------------------------

function Get-SandboxRoot {
    # SW-73: the root every fake home and workspace is created under. It must
    # sit outside the user profile - see Find-AncestorClaudeDir.
    if (Test-EnvSet 'SD_E2E_ROOT') {
        return [System.IO.Path]::GetFullPath($env:SD_E2E_ROOT)
    }
    if ($IsWindows) {
        $drive = if ($env:SystemDrive) { $env:SystemDrive } else { 'C:' }
        return (Join-Path ($drive + '\') 'sd-e2e')
    }
    return [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
}

function Find-AncestorClaudeDir {
    # Returns the first `.claude` directory in $Root or any of its ancestors,
    # or $null. $Root itself counts: it is an ancestor of every workspace
    # created under it. Works on a $Root that does not exist yet.
    param([string]$Root)
    $dir = [System.IO.DirectoryInfo]::new($Root)
    while ($null -ne $dir) {
        $candidate = Join-Path $dir.FullName '.claude'
        if (Test-Path -LiteralPath $candidate -PathType Container) { return $candidate }
        $dir = $dir.Parent
    }
    return $null
}

$script:sandboxRoot = Get-SandboxRoot

function New-EmptyTempDir {
    param([string]$Prefix)
    $name = $Prefix + '-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 12)
    $dir = Join-Path $script:sandboxRoot $name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function New-FakeHome {
    # Fresh, empty "fake home" with the engine installed into <fakehome>/.claude
    # via the installer's own -BasePath flag - the sandbox recipe from
    # CLAUDE.md / the CI install-uninstall round-trip job, reused verbatim.
    $fakeHome = New-EmptyTempDir -Prefix 'sd-e2e-home'
    $basePath = Join-Path $fakeHome '.claude'
    & pwsh -NoProfile -File $installPs1 -BasePath $basePath -Force *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "engine install into fake home failed (exit $LASTEXITCODE): $fakeHome"
    }

    # `claude -p` needs org/identity context from .credentials.json even when
    # billing resolves through ANTHROPIC_API_KEY - an empty HOME alone is not
    # enough (verified directly: without it, every headless run fails with
    # "Not logged in" despite a valid API key). Copied fresh into the
    # throwaway fake home per run and discarded on cleanup; never written
    # anywhere persistent. When the file is absent, auth comes from an
    # environment variable instead - the preflight below has already
    # established that one is present (see Get-AuthMode).
    $realCreds = Get-CredentialsPath
    if (Test-Path -LiteralPath $realCreds) {
        New-Item -ItemType Directory -Path $basePath -Force | Out-Null
        Copy-Item -LiteralPath $realCreds -Destination (Join-Path $basePath '.credentials.json') -Force
    }

    return $fakeHome
}

function Copy-TreeContents {
    param([string]$Source, [string]$Destination)
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "copy source does not exist: $Source"
    }
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}

function New-ScenarioWorkspace {
    param([string]$ScenarioDir)
    $ws = New-EmptyTempDir -Prefix 'sd-e2e-ws'

    $sourceTxt = Join-Path $ScenarioDir 'source.txt'
    if (Test-Path -LiteralPath $sourceTxt) {
        $rel = (Get-Content -LiteralPath $sourceTxt -Raw).Trim()
        $src = Join-Path $repoRoot $rel
        Copy-TreeContents -Source $src -Destination $ws
    }

    $overlay = Join-Path $ScenarioDir 'workspace'
    if (Test-Path -LiteralPath $overlay) {
        Copy-TreeContents -Source $overlay -Destination $ws
    }

    return $ws
}

# ---- guard neutering (for -SelfTest) ----------------------------------------

function Set-SpecGateNeutered {
    param([string]$FakeHome)
    # Overwrite the INSTALLED copy in the fake home with an always-allow stub -
    # never touches the repo's real hooks/ source.
    $stubPwsh = "#requires -Version 5.1`n[Console]::In.ReadToEnd() | Out-Null`nexit 0`n"
    $stubBash = "#!/usr/bin/env bash`ncat >/dev/null`nexit 0`n"
    $pwshPath = Join-Path $FakeHome '.claude' 'hooks' 'sd' 'spec-gate.ps1'
    $bashPath = Join-Path $FakeHome '.claude' 'hooks' 'sd' 'spec-gate.sh'
    Set-Content -LiteralPath $pwshPath -Value $stubPwsh -NoNewline -Encoding ascii
    Set-Content -LiteralPath $bashPath -Value $stubBash -NoNewline -Encoding ascii
}

# ---- headless invocation -----------------------------------------------------

function Invoke-ClaudeHeadless {
    param(
        [string]$Workspace,
        [string]$FakeHome,
        [string]$Prompt,
        [double]$MaxBudgetUsd,
        [int]$TimeoutSec,
        [switch]$SkipPermissions,
        [string[]]$DisallowedTools,
        [string]$PermissionMode = 'dontAsk'
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'claude'
    $cliArgs = @(
        '-p', $Prompt,
        '--output-format', 'json',
        '--setting-sources', 'project',
        '--add-dir', $FakeHome,
        '--max-budget-usd', $MaxBudgetUsd.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    )
    # SD_E2E_TRANSCRIPT (SW-79) keeps the session transcript for diagnosis:
    # without --no-session-persistence the CLI writes it under
    # <FakeHome>/.claude/projects/, and the fake home is then kept (see the
    # finally block in Invoke-Scenario). Off by default - a transcript is
    # debugging evidence, not an assertion input.
    if (-not $env:SD_E2E_TRANSCRIPT) { $cliArgs += '--no-session-persistence' }
    # PermissionMode matters a lot more here than it looks. Verified directly
    # (minimal repro: a trivial always-deny PreToolUse hook, no spec-gate
    # involved): under --permission-mode acceptEdits, OR under dontAsk
    # combined with an explicit --allowedTools grant for Edit/Write, the CLI
    # auto-approves the tool call and the hook's deny is silently ignored
    # (0 permission_denials recorded, file still changes). Only "dontAsk"
    # with NO --allowedTools override actually respects a hook's deny -
    # everything not explicitly hook/default-allowed is refused, which is
    # exactly the posture the negative scenarios need. Positive scenarios
    # (01, 02) that need free writes use SkipPermissions instead of
    # acceptEdits, for the same reason.
    $cliArgs += '--permission-mode'
    $cliArgs += $PermissionMode
    if ($SkipPermissions) {
        # Only for scenarios that legitimately need to write files Claude Code
        # itself treats as sensitive (.claude/settings.json) or run arbitrary
        # Bash (npm test). NEVER set for the negative scenarios - see above.
        $cliArgs += '--dangerously-skip-permissions'
    }
    if ($DisallowedTools -and $DisallowedTools.Count -gt 0) {
        $cliArgs += '--disallowedTools'
        $cliArgs += ($DisallowedTools -join ',')
    }
    foreach ($a in $cliArgs) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory       = $Workspace
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $psi.EnvironmentVariables['HOME']        = $FakeHome
    $psi.EnvironmentVariables['USERPROFILE'] = $FakeHome
    # Drop auth variables that are set but empty (an absent CI secret), so
    # claude never sees a blank credential alongside the real one.
    foreach ($authVar in @('ANTHROPIC_API_KEY', 'CLAUDE_CODE_OAUTH_TOKEN')) {
        if ($psi.EnvironmentVariables.ContainsKey($authVar) -and -not (Test-EnvSet $authVar)) {
            $psi.EnvironmentVariables.Remove($authVar)
        }
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $finished = $proc.WaitForExit($TimeoutSec * 1000)
    if (-not $finished) {
        try { $proc.Kill($true) } catch { }
        return [pscustomobject]@{
            TimedOut = $true; ExitCode = -1; Stdout = ''; Stderr = ''; Result = $null
        }
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    $resultObj = $null
    try { $resultObj = $stdout | ConvertFrom-Json -ErrorAction Stop } catch { }

    return [pscustomobject]@{
        TimedOut = $false
        ExitCode = $proc.ExitCode
        Stdout   = $stdout
        Stderr   = $stderr
        Result   = $resultObj
    }
}

function Get-ScenarioSkipPermissions {
    param([string]$ScenarioDir)
    return (Test-Path -LiteralPath (Join-Path $ScenarioDir 'skip-permissions.txt'))
}

function Get-ScenarioPermissionMode {
    param([string]$ScenarioDir)
    $p = Join-Path $ScenarioDir 'permission-mode.txt'
    if (Test-Path -LiteralPath $p) { return (Get-Content -LiteralPath $p -Raw).Trim() }
    return 'dontAsk'
}

function Get-ScenarioDisallowedTools {
    param([string]$ScenarioDir)
    $p = Join-Path $ScenarioDir 'disallowed-tools.txt'
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    $line = (Get-Content -LiteralPath $p -Raw).Trim()
    if ([string]::IsNullOrWhiteSpace($line)) { return @() }
    return @($line -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# ---- assertions ---------------------------------------------------------------

function Get-ScenarioBudget {
    param([string]$ScenarioDir)
    $budgetTxt = Join-Path $ScenarioDir 'budget.txt'
    if (Test-Path -LiteralPath $budgetTxt) {
        return [double](Get-Content -LiteralPath $budgetTxt -Raw).Trim()
    }
    return 3.0
}

function Test-OneAssertion {
    param($Assertion, [string]$Workspace, $Run)
    $type = $Assertion.type
    switch ($type) {
        'file-exists' {
            $p = Join-Path $Workspace $Assertion.path
            return (Test-Path -LiteralPath $p)
        }
        'file-not-exists' {
            $p = Join-Path $Workspace $Assertion.path
            return (-not (Test-Path -LiteralPath $p))
        }
        'file-matches' {
            $p = Join-Path $Workspace $Assertion.path
            if (-not (Test-Path -LiteralPath $p)) { return $false }
            $content = Get-Content -LiteralPath $p -Raw
            return ($content -match $Assertion.pattern)
        }
        'file-not-matches' {
            $p = Join-Path $Workspace $Assertion.path
            if (-not (Test-Path -LiteralPath $p)) { return $true }
            $content = Get-Content -LiteralPath $p -Raw
            return ($content -notmatch $Assertion.pattern)
        }
        'output-contains' {
            $text = if ($Run.Result -and $Run.Result.result) { [string]$Run.Result.result } else { $Run.Stdout }
            return ($text -match [regex]::Escape($Assertion.value))
        }
        'exit-code' {
            return ($Run.ExitCode -eq [int]$Assertion.value)
        }
        'file-no-bom' {
            $p = Join-Path $Workspace $Assertion.path
            if (-not (Test-Path -LiteralPath $p)) { return $false }
            $bytes = [System.IO.File]::ReadAllBytes($p)
            if ($bytes.Length -lt 3) { return $true }
            return -not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        }
        default {
            throw "unknown assertion type '$type'"
        }
    }
}

function Get-AssertionLabel {
    param($Assertion)
    switch ($Assertion.type) {
        'file-exists'      { return "file-exists: $($Assertion.path)" }
        'file-not-exists'  { return "file-not-exists: $($Assertion.path)" }
        'file-matches'     { return "file-matches: $($Assertion.path) ~= $($Assertion.pattern)" }
        'file-not-matches' { return "file-not-matches: $($Assertion.path) !~ $($Assertion.pattern)" }
        'output-contains'  { return "output-contains: $($Assertion.value)" }
        'exit-code'        { return "exit-code: $($Assertion.value)" }
        'file-no-bom'      { return "file-no-bom: $($Assertion.path)" }
        default            { return "unknown: $($Assertion.type)" }
    }
}

# ---- scenario execution -------------------------------------------------------

function Invoke-Scenario {
    param(
        [string]$ScenarioDir,
        [switch]$NeuterGuard,
        [switch]$ExpectFailure
    )
    $name = Split-Path -Leaf $ScenarioDir
    Write-Host ''
    Write-Host "=== $name $(if ($NeuterGuard) { '(neutered guard)' }) ==="

    $fakeHome = $null
    $ws = $null
    try {
        $fakeHome = New-FakeHome
        if ($NeuterGuard) { Set-SpecGateNeutered -FakeHome $fakeHome }
        $ws = New-ScenarioWorkspace -ScenarioDir $ScenarioDir

        $prompt = Get-Content -LiteralPath (Join-Path $ScenarioDir 'prompt.txt') -Raw
        $budget = Get-ScenarioBudget -ScenarioDir $ScenarioDir
        $skipPermissions = Get-ScenarioSkipPermissions -ScenarioDir $ScenarioDir
        $disallowedTools = Get-ScenarioDisallowedTools -ScenarioDir $ScenarioDir
        $permissionMode = Get-ScenarioPermissionMode -ScenarioDir $ScenarioDir

        $run = Invoke-ClaudeHeadless -Workspace $ws -FakeHome $fakeHome -Prompt $prompt `
            -MaxBudgetUsd $budget -TimeoutSec $TimeoutSeconds -PermissionMode $permissionMode `
            -SkipPermissions:$skipPermissions -DisallowedTools $disallowedTools

        if ($run.TimedOut) {
            Write-Bad "$name : claude -p timed out after $TimeoutSeconds s"
            return $false
        }

        if ($env:SD_E2E_DEBUG) {
            Write-Info "exit code: $($run.ExitCode)"
            Write-Info "result   : $($run.Result.result)"
            Write-Info "is_error : $($run.Result.is_error)  cost: $($run.Result.total_cost_usd)"
            if ($run.Stderr) { Write-Info "stderr   : $($run.Stderr.Substring(0, [Math]::Min(2000, $run.Stderr.Length)))" }
        }

        $expectPath = Join-Path $ScenarioDir 'expect.json'
        $assertions = @(Get-Content -LiteralPath $expectPath -Raw | ConvertFrom-Json)

        $scenarioOk = $true
        foreach ($a in $assertions) {
            $label = Get-AssertionLabel -Assertion $a
            $ok = $false
            try {
                $ok = Test-OneAssertion -Assertion $a -Workspace $ws -Run $run
            } catch {
                Write-Bad "$name : $label (error: $($_.Exception.Message))"
                $scenarioOk = $false
                continue
            }
            if ($ok) {
                Write-Ok "$name : $label"
            } else {
                Write-Bad "$name : $label"
                $scenarioOk = $false
            }
        }

        if ($ExpectFailure) {
            # -SelfTest inverted expectation: the guard is neutered, so the
            # scenario's assertions (which describe blocked behavior) must
            # NOT all pass - if they do, the harness failed to notice.
            return (-not $scenarioOk)
        }
        return $scenarioOk
    } finally {
        if ($env:SD_E2E_DEBUG -and $ws) {
            $eventsPath = Join-Path $ws '.specs' '_metrics' 'events.jsonl'
            if (Test-Path -LiteralPath $eventsPath) {
                Write-Info 'events.jsonl:'
                Get-Content -LiteralPath $eventsPath | ForEach-Object { Write-Info "  $_" }
            }
        }
        if (-not $env:SD_E2E_KEEP -and -not $env:SD_E2E_TRANSCRIPT) {
            if ($ws) { Remove-Item -LiteralPath $ws -Recurse -Force -ErrorAction SilentlyContinue }
            if ($fakeHome) { Remove-Item -LiteralPath $fakeHome -Recurse -Force -ErrorAction SilentlyContinue }
        } elseif ($ws) {
            Write-Info "kept workspace: $ws"
            Write-Info "kept fakeHome : $fakeHome"
            if ($env:SD_E2E_TRANSCRIPT -and $fakeHome) {
                Write-Info "transcripts  : $(Join-Path $fakeHome '.claude' 'projects')"
            }
        }
    }
}

# ---- scenario selection and preconditions -------------------------------------

$negativeScenarios = @('03-spec-gate-negative', '04-closeout-negative')

if ($SelfTest) {
    $selectedDirs = @($negativeScenarios |
        ForEach-Object { Join-Path $scenariosDir $_ } |
        Where-Object { Test-Path -LiteralPath $_ })
} else {
    $scenarioDirs = Get-ChildItem -LiteralPath $scenariosDir -Directory | Sort-Object Name
    if ($Case) {
        $scenarioDirs = @($scenarioDirs | Where-Object { $_.Name -eq $Case })
        if ($scenarioDirs.Count -eq 0) {
            Write-Host "[FAIL] no scenario named '$Case' under $scenariosDir"
            exit 1
        }
    }
    $selectedDirs = @($scenarioDirs | ForEach-Object { $_.FullName })
}

Assert-Prerequisites -ScenarioDirs $selectedDirs

# ---- self-test mode ------------------------------------------------------------

if ($SelfTest) {
    Write-Host '=== e2e self-test: harness must DETECT a removed guard ==='
    $allDetected = $true
    foreach ($n in $negativeScenarios) {
        $dir = Join-Path $scenariosDir $n
        if (-not (Test-Path -LiteralPath $dir)) {
            Write-Bad "self-test: scenario '$n' not found"
            $allDetected = $false
            continue
        }
        $detected = Invoke-Scenario -ScenarioDir $dir -NeuterGuard -ExpectFailure
        if ($detected) {
            Write-Ok "self-test: $n : harness detected the neutered guard"
        } else {
            Write-Bad "self-test: $n : harness did NOT notice the guard was removed"
            $allDetected = $false
        }
    }
    if ($allDetected) { exit 0 } else { exit 1 }
}

# ---- main -----------------------------------------------------------------------

foreach ($dir in $selectedDirs) {
    Invoke-Scenario -ScenarioDir $dir | Out-Null
}

Write-Host ''
Write-Host "=== Summary: $($script:pass) passed, $($script:fail) failed ==="
if ($script:fail -gt 0) { exit 1 }
exit 0
