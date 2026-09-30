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

    -ResultsFile <path> (SW-77) also writes the run as JSON: date, mode,
    claude version, auth mode, OS, git commit, and per scenario the result,
    assertion counts, exit code, total_cost_usd and duration. It holds no
    prompt, transcript or credential. Nothing is written on the exit-2
    prerequisite path, since no scenario ran.

    Each scenario directory under scenarios/<name>/ may contain:
      source.txt   - optional, one line: a repo-relative path to copy as the
                      base workspace (e.g. examples/fixture-project).
      workspace/   - optional overlay copied on top of the base afterward
                      (added/overwritten files only - mirrors the
                      tests/contract-lint fixture _base + overlay pattern).
      prompt.txt   - the literal prompt fed to `claude -p`.
      expect.json  - declarative assertions evaluated after the run.
      budget.txt   - optional, one line: --max-budget-usd override (default 3).
      timeout.txt  - optional, one line: seconds before claude -p is killed
                      (default 600). An explicit -TimeoutSeconds wins over it.
      requires.txt - optional, one command name per line that must be on
                      PATH (e.g. node, npm); checked by the preflight.

    Preflight: before any sandbox is built, the harness checks the claude
    CLI (present, >= the minimum version), that some claude auth is
    available (CLAUDE_CODE_OAUTH_TOKEN, ~/.claude/.credentials.json, or
    ANTHROPIC_API_KEY - subscription auth needs no API key), and every
    requires.txt command of the selected scenarios, and that no ancestor of
    the sandbox root holds a `.claude/` (SW-73). A missing prerequisite
    exits 2 with the dependency named, never as a failed assertion.

    -SelfTest re-runs the negative scenarios (03, 04) once per guard
    mutation of spec-gate's installed hook files - an always-allow stub, and
    the real hook with its deny JSON in the pre-SW-80 shape (SW-82) - and
    asserts they now FAIL, proving the harness would catch a regression that
    removes the guard or breaks its output (mirrors
    tests/hooks/run-conformance.ps1 and tests/contract-lint/run-selftest.ps1's
    own -SelfTest modes).

    A scenario whose claude -p timed out, printed no parseable result, or
    returned is_error: true "could not run" (SW-81): its assertions are
    skipped, it is reported as [ERROR] and counted apart from failed
    assertions, and the run exits 1. Under -SelfTest it fails the self-test,
    since a session that never ran cannot show the guard was exercised.

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
    [int]$TimeoutSeconds = 600,
    [string]$ResultsFile
)

$ErrorActionPreference = 'Stop'
$script:timeoutExplicit = $PSBoundParameters.ContainsKey('TimeoutSeconds')

$scriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot     = (Resolve-Path (Join-Path $scriptDir '..' '..')).Path
$scenariosDir = Join-Path $scriptDir 'scenarios'
$installPs1   = Join-Path $repoRoot 'install' 'install.ps1'

$script:pass = 0
$script:fail = 0
$script:couldNotRun = 0
$script:claudeVersion = $null
$script:authMode = $null
$script:scenarioResults = [System.Collections.Generic.List[object]]::new()

function Write-Ok   { param([string]$m) Write-Host "  [OK]   $m"; $script:pass++ }
function Write-Bad  { param([string]$m) Write-Host "  [FAIL] $m"; $script:fail++ }
function Write-Info { param([string]$m) Write-Host "         $m" }
function Write-CouldNotRun { param([string]$m) Write-Host "  [ERROR] $m"; $script:couldNotRun++ }

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
    $script:claudeVersion = [version]$Matches[1]
    if ($script:claudeVersion -lt $script:minClaudeVersion) {
        Exit-MissingPrereq "claude CLI $($script:claudeVersion) is older than the required $($script:minClaudeVersion); update the claude CLI."
    }
    Write-Host "[INFO] claude CLI: $($script:claudeVersion)"

    $script:authMode = Get-AuthMode
    $authMode = $script:authMode
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
        Assert-ScenarioPosture -ScenarioDir $dir
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

    if (-not $IsWindows) { Convert-HookShellToPwsh -Workspace $ws }
    return $ws
}

function Convert-HookShellToPwsh {
    # SW-81: the committed fixture settings are Windows-first and call
    # `powershell`, which Linux/macOS runners lack (they ship `pwsh`). A hook
    # whose command is not found exits 127 - non-blocking - so every hook
    # silently no-ops. Rewrite only this throwaway workspace's copy.
    param([string]$Workspace)
    $settingsPath = Join-Path $Workspace '.claude' 'settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) { return }
    $raw = Get-Content -LiteralPath $settingsPath -Raw
    $rewritten = $raw -replace '"command":\s*"powershell\s', '"command": "pwsh '
    if ($rewritten -ne $raw) {
        Set-Content -LiteralPath $settingsPath -Value $rewritten -NoNewline -Encoding utf8
    }
}

# ---- guard mutations (for -SelfTest) ----------------------------------------

$guardMutations = @('always-allow', 'malformed-deny')

function Set-SpecGateMutation {
    # Rewrites the INSTALLED copy in the fake home - never the repo's real
    # hooks/ source. install.ps1 installs only spec-gate.ps1, which is what
    # the fixture's settings.json invokes; spec-gate.sh is covered too in
    # case a sandbox ever carries it.
    #   always-allow   - a stub that decides nothing, so the guard is gone.
    #   malformed-deny - the real hook with its deny JSON in the pre-SW-80
    #                    shape (no hookSpecificOutput.hookEventName). It still
    #                    decides to block and records the block event, but
    #                    the CLI drops the deny, so a granted edit lands
    #                    (SW-82). Only the outcome assertions can catch it.
    param([string]$FakeHome, [string]$Mutation)
    $pwshPath = Join-Path $FakeHome '.claude' 'hooks' 'sd' 'spec-gate.ps1'
    $bashPath = Join-Path $FakeHome '.claude' 'hooks' 'sd' 'spec-gate.sh'
    switch ($Mutation) {
        'always-allow' {
            $stubPwsh = "#requires -Version 5.1`n[Console]::In.ReadToEnd() | Out-Null`nexit 0`n"
            $stubBash = "#!/usr/bin/env bash`ncat >/dev/null`nexit 0`n"
            Set-Content -LiteralPath $pwshPath -Value $stubPwsh -NoNewline -Encoding ascii
            Set-Content -LiteralPath $bashPath -Value $stubBash -NoNewline -Encoding ascii
        }
        'malformed-deny' {
            # `$$` is a literal `$` in a -replace replacement string.
            $pwshPattern = "hookEventName\s*=\s*'PreToolUse'\s*" +
                "permissionDecision\s*=\s*'deny'\s*permissionDecisionReason\s*=\s*\`$Reason"
            Edit-InstalledHook -Path $pwshPath -Pattern $pwshPattern `
                -Replacement "permissionDecision = 'deny'; reason = `$`$Reason"
            if (Test-Path -LiteralPath $bashPath) {
                Edit-InstalledHook -Path $bashPath `
                    -Pattern 'hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:\$r' `
                    -Replacement 'permissionDecision:"deny",reason:$$r'
            }
        }
        default { throw "unknown guard mutation '$Mutation'" }
    }
}

function Edit-InstalledHook {
    # A pattern that no longer matches means the hook's deny emitter changed
    # shape. Fail loudly rather than run the real guard and call it mutated.
    param([string]$Path, [string]$Pattern, [string]$Replacement)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "malformed-deny mutation: installed hook not found: $Path"
    }
    $raw = [System.IO.File]::ReadAllText($Path)
    if ($raw -notmatch $Pattern) {
        throw "malformed-deny mutation: deny emitter not found in $Path; update Set-SpecGateMutation"
    }
    [System.IO.File]::WriteAllText($Path, ($raw -replace $Pattern, $Replacement))
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
        [string[]]$AllowedTools,
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
    # Permission posture (SW-80, verified on claude 2.1.283 with
    # probe-permission-posture.ps1). dontAsk refuses every tool call no rule
    # allows, so a scenario that writes files or runs its test command grants
    # exactly those via AllowedTools (allowed-tools.txt). A hook's deny wins
    # over that grant - and over acceptEdits and skip-permissions too -
    # provided the hook's JSON carries hookSpecificOutput.hookEventName;
    # spec-gate's did not before SW-80, which is why every one of those
    # postures used to look like it overrode the deny. The narrow grant is
    # still the point: acceptEdits and skip-permissions also let a Bash
    # `echo x > file` through, which dontAsk refuses. Skip is kept only for
    # 01-setup (writes .claude/settings.json, asserts no deny), and
    # Assert-ScenarioPosture refuses it for any scenario that asserts one.
    $cliArgs += '--permission-mode'
    $cliArgs += $PermissionMode
    if ($SkipPermissions) {
        $cliArgs += '--dangerously-skip-permissions'
    }
    if ($AllowedTools -and $AllowedTools.Count -gt 0) {
        $cliArgs += '--allowedTools'
        $cliArgs += ($AllowedTools -join ',')
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

function Get-ScenarioAllowedTools {
    # Optional allowed-tools.txt (SW-80): one permission rule per line, blank
    # lines and # comments ignored, passed as --allowedTools. One per line
    # because a rule such as Bash(npm test:*) contains a space.
    param([string]$ScenarioDir)
    $p = Join-Path $ScenarioDir 'allowed-tools.txt'
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    return @(Get-Content -LiteralPath $p |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') })
}

function Assert-ScenarioPosture {
    # SW-80: a scenario that asserts a hook deny runs under dontAsk with a
    # narrow grant, never acceptEdits or skip-permissions. A well-formed deny
    # holds under all of them, but those two also approve Bash file writes
    # that only spec-gate's shell-write heuristic would catch, and SW-27 sets a
    # no-skip-permissions bar. The negative scenarios and any scenario with a
    # permission-denied assertion count as asserting a deny. A misconfigured
    # scenario exits 2 before any spend.
    param([string]$ScenarioDir)
    $name = Split-Path -Leaf $ScenarioDir
    $expectPath = Join-Path $ScenarioDir 'expect.json'
    $assertsDeny = $negativeScenarios -contains $name
    if ((-not $assertsDeny) -and (Test-Path -LiteralPath $expectPath)) {
        $assertsDeny = @(Get-Content -LiteralPath $expectPath -Raw | ConvertFrom-Json |
            Where-Object { $_.type -eq 'permission-denied' }).Count -gt 0
    }
    if (-not $assertsDeny) { return }
    $mode = Get-ScenarioPermissionMode -ScenarioDir $ScenarioDir
    if ((Get-ScenarioSkipPermissions -ScenarioDir $ScenarioDir) -or
        ($mode -in @('acceptEdits', 'bypassPermissions'))) {
        Write-Host "[FAIL] scenario $name asserts a hook deny but runs under a posture broader than dontAsk + a narrow grant"
        Write-Host '       (skip-permissions.txt, or permission-mode.txt acceptEdits/bypassPermissions).'
        Write-Host '       Grant what it needs in allowed-tools.txt instead. See tests/e2e/README.md "Permission mode".'
        exit 2
    }
}

# ---- assertions ---------------------------------------------------------------

# Precedence: an explicitly passed -TimeoutSeconds, then timeout.txt, then the
# parameter default (600). A slow end-to-end scenario (02-feature-happy runs
# about 11 minutes, SW-79) carries its own ceiling instead of raising the
# default for every fast scenario.
function Get-ScenarioTimeout {
    param([string]$ScenarioDir)
    if ($script:timeoutExplicit) { return $TimeoutSeconds }
    $timeoutTxt = Join-Path $ScenarioDir 'timeout.txt'
    if (Test-Path -LiteralPath $timeoutTxt) {
        return [int](Get-Content -LiteralPath $timeoutTxt -Raw).Trim()
    }
    return $TimeoutSeconds
}

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
        'permission-denied' {
            # SW-80: the CLI recorded a refused call to a tool matching `tool`
            # (a regex) on a file ending in `path`. Under a posture that grants
            # the tool, only a hook deny puts it in permission_denials.
            if (-not $Run.Result) { return $false }
            $suffix = $Assertion.path.Replace('\', '/')
            foreach ($d in @($Run.Result.permission_denials)) {
                if ($null -eq $d -or $d.tool_name -notmatch "^($($Assertion.tool))$") { continue }
                $fp = if ($d.tool_input -and $d.tool_input.file_path) { [string]$d.tool_input.file_path } else { '' }
                if ($fp.Replace('\', '/').EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
            }
            return $false
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
        'permission-denied' { return "permission-denied: $($Assertion.tool) on $($Assertion.path)" }
        default            { return "unknown: $($Assertion.type)" }
    }
}

# ---- scenario execution -------------------------------------------------------

function Invoke-Scenario {
    param(
        [string]$ScenarioDir,
        [string]$GuardMutation,
        [switch]$ExpectFailure
    )
    $name = Split-Path -Leaf $ScenarioDir
    Write-Host ''
    Write-Host "=== $name $(if ($GuardMutation) { "(guard mutation: $GuardMutation)" }) ==="

    $fakeHome = $null
    $ws = $null
    # One -ResultsFile entry per scenario (SW-77). Appended in finally, so a
    # timeout or a thrown error is recorded too; passed stays false unless a
    # return below sets it.
    $record = [ordered]@{
        name             = $name
        neuteredGuard    = [bool]$GuardMutation
        guardMutation    = $(if ($GuardMutation) { $GuardMutation } else { $null })
        passed           = $false
        assertionsPassed = 0
        assertionsTotal  = 0
        couldNotRun      = $false
        timedOut         = $false
        exitCode         = $null
        isError          = $null
        totalCostUsd     = $null
        durationSeconds  = $null
    }
    try {
        $fakeHome = New-FakeHome
        if ($GuardMutation) { Set-SpecGateMutation -FakeHome $fakeHome -Mutation $GuardMutation }
        $ws = New-ScenarioWorkspace -ScenarioDir $ScenarioDir

        $prompt = Get-Content -LiteralPath (Join-Path $ScenarioDir 'prompt.txt') -Raw
        $budget = Get-ScenarioBudget -ScenarioDir $ScenarioDir
        $skipPermissions = Get-ScenarioSkipPermissions -ScenarioDir $ScenarioDir
        $disallowedTools = Get-ScenarioDisallowedTools -ScenarioDir $ScenarioDir
        $allowedTools = Get-ScenarioAllowedTools -ScenarioDir $ScenarioDir
        $permissionMode = Get-ScenarioPermissionMode -ScenarioDir $ScenarioDir

        $timeoutSec = Get-ScenarioTimeout -ScenarioDir $ScenarioDir
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $run = Invoke-ClaudeHeadless -Workspace $ws -FakeHome $fakeHome -Prompt $prompt `
            -MaxBudgetUsd $budget -TimeoutSec $timeoutSec -PermissionMode $permissionMode `
            -SkipPermissions:$skipPermissions -DisallowedTools $disallowedTools `
            -AllowedTools $allowedTools
        $stopwatch.Stop()
        $record.durationSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
        $record.timedOut = [bool]$run.TimedOut
        $record.exitCode = $run.ExitCode
        if ($run.Result) {
            $record.isError = $run.Result.is_error
            $record.totalCostUsd = $run.Result.total_cost_usd
        }

        # SW-81: a run that never produced a usable session (timeout, no
        # parseable result, is_error) is its own outcome, not failed
        # assertions. Every assertion fails against an untouched workspace, so
        # counting them would let -SelfTest "detect" a neutered guard it never
        # exercised - run #49 did exactly that with no auth configured.
        $isUnusable = $run.TimedOut -or ($null -eq $run.Result) -or ($run.Result.is_error -eq $true)
        if ($env:SD_E2E_DEBUG -or $isUnusable) {
            Write-Info "exit code: $($run.ExitCode)"
            Write-Info "result   : $($run.Result.result)"
            Write-Info "is_error : $($run.Result.is_error)  cost: $($run.Result.total_cost_usd)"
            if ($null -eq $run.Result -and $run.Stdout) {
                Write-Info "stdout   : $($run.Stdout.Substring(0, [Math]::Min(2000, $run.Stdout.Length)))"
            }
            if ($run.Stderr) { Write-Info "stderr   : $($run.Stderr.Substring(0, [Math]::Min(2000, $run.Stderr.Length)))" }
        }
        if ($isUnusable) {
            $reason = if ($run.TimedOut) { "timed out after $timeoutSec s" }
                elseif ($null -eq $run.Result) { "no parseable result (exit $($run.ExitCode))" }
                else { 'is_error: true' }
            Write-CouldNotRun "$name : claude -p could not run ($reason) - assertions skipped"
            $record.couldNotRun = $true
            return $false
        }

        $expectPath = Join-Path $ScenarioDir 'expect.json'
        $assertions = @(Get-Content -LiteralPath $expectPath -Raw | ConvertFrom-Json)
        $record.assertionsTotal = $assertions.Count

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
                $record.assertionsPassed++
            } else {
                Write-Bad "$name : $label"
                $scenarioOk = $false
            }
        }

        if ($ExpectFailure) {
            # -SelfTest inverted expectation: the guard is mutated, so the
            # scenario's assertions (which describe blocked behavior) must
            # NOT all pass - if they do, the harness failed to notice.
            $record.passed = (-not $scenarioOk)
            return $record.passed
        }
        $record.passed = $scenarioOk
        return $scenarioOk
    } finally {
        $script:scenarioResults.Add([pscustomobject]$record)
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

function Write-ResultsFile {
    # -ResultsFile (SW-77): the run as JSON, so repeated runs are compared
    # from files rather than copied from the console. No-op without it.
    param([string]$Mode, [bool]$Passed)
    if ([string]::IsNullOrWhiteSpace($ResultsFile)) { return }

    $gitCommit = $null
    try {
        $gitCommit = (& git -C $repoRoot rev-parse --short HEAD 2>$null | Out-String).Trim()
        if (-not $gitCommit) { $gitCommit = $null }
    } catch { $gitCommit = $null }

    $costs = @($script:scenarioResults |
        Where-Object { $null -ne $_.totalCostUsd } |
        ForEach-Object { [double]$_.totalCostUsd })
    $totalCost = $null
    if ($costs.Count -gt 0) { $totalCost = [Math]::Round(($costs | Measure-Object -Sum).Sum, 4) }

    $doc = [ordered]@{
        date          = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        mode          = $Mode
        claudeVersion = "$($script:claudeVersion)"
        authMode      = $script:authMode
        os            = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
        pwshVersion   = "$($PSVersionTable.PSVersion)"
        gitCommit     = $gitCommit
        passed        = $Passed
        totalCostUsd  = $totalCost
        scenarios     = @($script:scenarioResults)
    }

    # Resolve against $PWD, not the process cwd GetFullPath would use.
    $path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ResultsFile)
    $parent = Split-Path -Parent $path
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    # pwsh 7's utf8 encoding writes no BOM.
    $doc | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding utf8
    Write-Host "[INFO] results written: $path"
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
    Write-Host '=== e2e self-test: harness must DETECT a removed or malformed guard ==='
    $allDetected = $true
    foreach ($mutation in $guardMutations) {
        foreach ($n in $negativeScenarios) {
            $dir = Join-Path $scenariosDir $n
            if (-not (Test-Path -LiteralPath $dir)) {
                Write-Bad "self-test: scenario '$n' not found"
                $allDetected = $false
                continue
            }
            $detected = Invoke-Scenario -ScenarioDir $dir -GuardMutation $mutation -ExpectFailure
            if ($script:scenarioResults[-1].couldNotRun) {
                Write-CouldNotRun ("self-test: $n [$mutation] : could not run, " +
                    'so it cannot tell whether the guard was exercised')
                $allDetected = $false
            } elseif ($detected) {
                Write-Ok "self-test: $n [$mutation] : harness detected the mutated guard"
            } else {
                Write-Bad "self-test: $n [$mutation] : harness did NOT notice the guard was mutated"
                $allDetected = $false
            }
        }
    }
    Write-ResultsFile -Mode 'selftest' -Passed $allDetected
    if ($allDetected) { exit 0 } else { exit 1 }
}

# ---- main -----------------------------------------------------------------------

foreach ($dir in $selectedDirs) {
    Invoke-Scenario -ScenarioDir $dir | Out-Null
}

Write-Host ''
Write-Host ("=== Summary: $($script:pass) passed, $($script:fail) failed, " +
    "$($script:couldNotRun) scenario(s) could not run ===")
$suitePassed = ($script:fail -eq 0) -and ($script:couldNotRun -eq 0)
Write-ResultsFile -Mode $(if ($Case) { 'case' } else { 'full' }) -Passed $suitePassed
if ($suitePassed -eq $false) { exit 1 }
exit 0
