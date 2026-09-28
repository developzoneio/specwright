#requires -Version 7.0
<#
.SYNOPSIS
    SW-80: which `claude -p` permission postures keep a PreToolUse hook's deny?
    Manual, paid (about $0.04 per run with -Model haiku), not part of
    run-e2e.ps1 or CI. Re-run it when the minimum claude version is raised, or
    before changing the posture a scenario runs under.

.DESCRIPTION
    Each run builds a throwaway fake home and workspace. The workspace's
    .claude/settings.json wires one PreToolUse hook (deny-hook.ps1, run with
    pwsh) on Edit|Write|MultiEdit|Bash that denies any call whose file path or
    command mentions "guarded", and logs every call it sees to hook.log. The
    model is asked for four calls, in order:
      1. Write free.txt            (an ordinary write)
      2. Read, then Edit guarded.txt   (the hook denies the Edit)
      3. Bash: npm test            (the fixture's test command)
      4. Bash: echo x > bashfree.txt   (a shell write outside any grant)

    Evidence is never the model's account: files on disk, the result JSON's
    permission_denials, and hook.log.

    -HookFormat picks the deny JSON the hook prints:
      legacy  spec-gate before SW-80: {decision:block, hookSpecificOutput
              without hookEventName}
      fixed   spec-gate after SW-80: the same plus hookEventName:"PreToolUse"
      exit2   exit code 2 with the reason on stderr
    Run legacy next to fixed, so a hook-output bug cannot pass for CLI
    behaviour again (that is how the pre-SW-80 README claim arose).

    Postures (-Posture):
      dontask-none        --permission-mode dontAsk
      dontask-bash        dontAsk + --allowedTools "Bash(npm test:*)"
      dontask-grant       dontAsk + --allowedTools "Edit,Write,MultiEdit,Bash(npm test:*)"
      settings-trusted    dontAsk + the same rules in permissions.allow, workspace trusted
      settings-untrusted  same, workspace not trusted (rules are ignored)
      acceptedits         --permission-mode acceptEdits
      acceptedits-bash    acceptEdits + --allowedTools "Bash(npm test:*)"
      skip                acceptEdits + --dangerously-skip-permissions

    Read the "guarded" column. "unchanged" plus "Edit" in the denials means the
    deny held. Under dontask-none that proves nothing about the hook, because
    the mode refuses the Edit anyway; under a posture that grants Edit it does.

    Isolation follows run-e2e.ps1: HOME/USERPROFILE point at the fake home,
    --setting-sources project, --no-session-persistence, and no .claude
    directory in -OutDir or any parent of it (SW-73). Auth comes from
    CLAUDE_CODE_OAUTH_TOKEN (claude setup-token) or ANTHROPIC_API_KEY; your
    real ~/.claude is not read unless you pass -CopyCredentials.

.PARAMETER Posture
    One or more posture names, or 'all' (default).

.PARAMETER HookFormat
    One or more of legacy, fixed, exit2. Default: legacy, fixed.

.PARAMETER Model
    Model alias for every run (default haiku - the posture does not depend on
    the model, and haiku keeps the probe cheap).

.PARAMETER BudgetUsd
    --max-budget-usd per run (default 0.3).

.PARAMETER OutDir
    Where sandboxes and results.json go. Kept after the run. Default:
    <SystemDrive>\sd-e2e\sw80-<timestamp> on Windows, <temp>/sd-e2e/sw80-<timestamp>
    elsewhere, or under SD_E2E_ROOT when set.

.PARAMETER CopyCredentials
    Copy ~/.claude/.credentials.json into each fake home instead of using an
    auth env var. Risky: a sandbox run can refresh the token, rotate the
    single-use refresh token, and log out your real CLI (it happened during
    SW-68). Prefer CLAUDE_CODE_OAUTH_TOKEN.

.EXAMPLE
    $env:CLAUDE_CODE_OAUTH_TOKEN = '<from claude setup-token>'
    .\tests\e2e\probe-permission-posture.ps1

.EXAMPLE
    .\tests\e2e\probe-permission-posture.ps1 -Posture acceptedits,dontask-grant -HookFormat fixed

.NOTES
    PURE ASCII ONLY (see hooks/powershell/prompt-router.ps1 for why).
#>

[CmdletBinding()]
param(
    [string[]]$Posture = @('all'),
    [string[]]$HookFormat = @('legacy', 'fixed'),
    [string]$Model = 'haiku',
    [double]$BudgetUsd = 0.3,
    [string]$OutDir,
    [switch]$CopyCredentials
)

$ErrorActionPreference = 'Stop'

$grantRules = @('Edit', 'Write', 'MultiEdit', 'Bash(npm test:*)')
$postures = [ordered]@{
    'dontask-none'       = @{ Args = @('--permission-mode', 'dontAsk') }
    'dontask-bash'       = @{ Args = @('--permission-mode', 'dontAsk', '--allowedTools', 'Bash(npm test:*)') }
    'dontask-grant'      = @{ Args = @('--permission-mode', 'dontAsk', '--allowedTools', ($grantRules -join ',')) }
    'settings-trusted'   = @{ Args = @('--permission-mode', 'dontAsk'); Allow = $grantRules; Trust = $true }
    'settings-untrusted' = @{ Args = @('--permission-mode', 'dontAsk'); Allow = $grantRules; Trust = $false }
    'acceptedits'        = @{ Args = @('--permission-mode', 'acceptEdits') }
    'acceptedits-bash'   = @{ Args = @('--permission-mode', 'acceptEdits', '--allowedTools', 'Bash(npm test:*)') }
    'skip'               = @{ Args = @('--permission-mode', 'acceptEdits', '--dangerously-skip-permissions') }
}

function Exit-CannotRun {
    param([string]$Message)
    Write-Host "[FAIL] $Message"
    exit 2
}

function Test-EnvSet {
    param([string]$Name)
    return ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($Name)) -eq $false)
}

# ---- preflight ------------------------------------------------------------------

# `pwsh -File` passes "a,b" as one string; split so both call styles work.
$Posture = @($Posture | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$HookFormat = @($HookFormat | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($f in $HookFormat) {
    if ($f -notin @('legacy', 'fixed', 'exit2')) { Exit-CannotRun "unknown hook format '$f'. Known: legacy, fixed, exit2" }
}
if ($Posture -contains 'all') { $Posture = @($postures.Keys) }
foreach ($p in $Posture) {
    if ($postures.Contains($p) -eq $false) {
        Exit-CannotRun "unknown posture '$p'. Known: $(@($postures.Keys) -join ', ')"
    }
}
foreach ($cmd in @('claude', 'node', 'npm', 'pwsh')) {
    if ($null -eq (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Exit-CannotRun "'$cmd' not found on PATH."
    }
}
$realCreds = Join-Path $HOME '.claude' '.credentials.json'
$useCreds = $CopyCredentials -and (Test-Path -LiteralPath $realCreds)
if (((Test-EnvSet 'CLAUDE_CODE_OAUTH_TOKEN') -eq $false) -and ($useCreds -eq $false) -and
    ((Test-EnvSet 'ANTHROPIC_API_KEY') -eq $false)) {
    Exit-CannotRun 'no claude auth: set CLAUDE_CODE_OAUTH_TOKEN (claude setup-token) or ANTHROPIC_API_KEY. -CopyCredentials also works but can log out your real CLI (see its help).'
}

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $root = if (Test-EnvSet 'SD_E2E_ROOT') { $env:SD_E2E_ROOT }
            elseif ($IsWindows) { Join-Path "$($env:SystemDrive)\" 'sd-e2e' }
            else { Join-Path ([System.IO.Path]::GetTempPath()) 'sd-e2e' }
    $OutDir = Join-Path $root ('sw80-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

# SW-73: a .claude above the sandbox is loaded as project scope.
$dir = Split-Path -Parent $OutDir
while ($dir) {
    if (Test-Path -LiteralPath (Join-Path $dir '.claude')) {
        Exit-CannotRun "'$(Join-Path $dir '.claude')' sits above -OutDir and would load as project scope (SW-73). Pick another -OutDir or SD_E2E_ROOT."
    }
    $parent = Split-Path -Parent $dir
    if ($parent -eq $dir) { break }
    $dir = $parent
}

$claudeVersion = (& claude --version 2>$null | Out-String).Trim()
Write-Host "[INFO] claude: $claudeVersion"
Write-Host "[INFO] out dir: $OutDir"

# ---- sandbox ----------------------------------------------------------------------

function Get-HookScript {
    param([string]$Format)
    $emit = switch ($Format) {
        'legacy' { '[Console]::Out.WriteLine((@{ decision = ''block''; reason = $r; hookSpecificOutput = @{ permissionDecision = ''deny''; reason = $r } } | ConvertTo-Json -Compress)); exit 0' }
        'fixed'  { '[Console]::Out.WriteLine((@{ decision = ''block''; reason = $r; hookSpecificOutput = @{ hookEventName = ''PreToolUse''; permissionDecision = ''deny''; permissionDecisionReason = $r } } | ConvertTo-Json -Compress)); exit 0' }
        'exit2'  { '[Console]::Error.WriteLine($r); exit 2' }
    }
    return @"
`$in = [Console]::In.ReadToEnd() | ConvertFrom-Json
`$target = if (`$in.tool_input.file_path) { [string]`$in.tool_input.file_path } else { [string]`$in.tool_input.command }
Add-Content -LiteralPath (Join-Path `$PSScriptRoot 'hook.log') -Value ("{0}|{1}" -f `$in.tool_name, `$target)
if (`$target -like '*guarded*') {
    `$r = 'probe-permission-posture: guarded target'
    $emit
}
exit 0
"@
}

function New-ProbeRun {
    param([string]$Name, [hashtable]$Spec, [string]$Format)
    $runDir = Join-Path $OutDir "$Name-$Format"
    if (Test-Path -LiteralPath $runDir) { Remove-Item -LiteralPath $runDir -Recurse -Force }
    $fakeHome = Join-Path $runDir 'home'
    $ws = Join-Path $runDir 'ws'
    New-Item -ItemType Directory -Path (Join-Path $fakeHome '.claude') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $ws '.claude') -Force | Out-Null

    $hookPath = Join-Path $ws '.claude' 'deny-hook.ps1'
    Set-Content -LiteralPath $hookPath -Value (Get-HookScript -Format $Format) -Encoding ascii
    Set-Content -LiteralPath (Join-Path $ws 'guarded.txt') -Value 'original' -Encoding ascii
    $pkg = '{"name":"probe","version":"1.0.0","private":true,"scripts":{"test":"node -e \"require(''fs'').writeFileSync(''npm-test-ran'',''1'')\""}}'
    Set-Content -LiteralPath (Join-Path $ws 'package.json') -Value $pkg -Encoding ascii

    # Hook commands run through bash on Windows too, so the path needs forward
    # slashes (SW-68): C:\x\hook.ps1 would reach pwsh as C:xhook.ps1.
    $settings = [ordered]@{
        hooks = @{
            PreToolUse = @(@{
                matcher = 'Edit|Write|MultiEdit|Bash'
                hooks   = @(@{ type = 'command'; command = "pwsh -NoProfile -File $($hookPath.Replace('\', '/'))"; timeout = 15 })
            })
        }
    }
    if ($Spec.Allow) { $settings['permissions'] = @{ allow = $Spec.Allow } }
    $settings | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $ws '.claude' 'settings.json') -Encoding utf8

    if ($Spec.Trust) {
        # Both spellings of the key: the CLI's own form is not documented.
        $projects = [ordered]@{}
        foreach ($k in @($ws, $ws.Replace('\', '/')) | Select-Object -Unique) {
            $projects[$k] = @{ hasTrustDialogAccepted = $true }
        }
        @{ projects = $projects } | ConvertTo-Json -Depth 5 |
            Set-Content -LiteralPath (Join-Path $fakeHome '.claude.json') -Encoding utf8
    }
    if ($useCreds) {
        Copy-Item -LiteralPath $realCreds -Destination (Join-Path $fakeHome '.claude' '.credentials.json') -Force
    }
    return [pscustomobject]@{ Dir = $runDir; Home = $fakeHome; Ws = $ws }
}

$prompt = @'
This is a scripted permission-posture test in a throwaway directory created and deleted by a test
runner. Do these four steps in order, one tool call each, and do not retry or work around any step
that is refused:
1. Use the Write tool to create free.txt containing the word free.
2. Use the Read tool on guarded.txt, then the Edit tool to change the word original to changed in it.
3. Use the Bash tool to run exactly: npm test
4. Use the Bash tool to run exactly: echo x > bashfree.txt
Then reply with one line per step: allowed or refused.
'@

function Invoke-ProbeRun {
    param($Run, [string[]]$PostureArgs)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = (Get-Command claude).Source
    $cliArgs = @('-p', $prompt, '--output-format', 'json', '--no-session-persistence',
        '--setting-sources', 'project', '--model', $Model,
        '--max-budget-usd', $BudgetUsd.ToString([System.Globalization.CultureInfo]::InvariantCulture)) + $PostureArgs
    foreach ($a in $cliArgs) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = $Run.Ws
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.EnvironmentVariables['HOME'] = $Run.Home
    $psi.EnvironmentVariables['USERPROFILE'] = $Run.Home
    foreach ($authVar in @('ANTHROPIC_API_KEY', 'CLAUDE_CODE_OAUTH_TOKEN')) {
        if ($psi.EnvironmentVariables.ContainsKey($authVar) -and ((Test-EnvSet $authVar) -eq $false)) {
            $psi.EnvironmentVariables.Remove($authVar)
        }
    }
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if ($proc.WaitForExit(300000) -eq $false) {
        try { $proc.Kill($true) } catch { }
        return $null
    }
    $stdout = $outTask.GetAwaiter().GetResult()
    Set-Content -LiteralPath (Join-Path $Run.Dir 'out.json') -Value $stdout -Encoding utf8
    Set-Content -LiteralPath (Join-Path $Run.Dir 'stderr.txt') -Value $errTask.GetAwaiter().GetResult() -Encoding utf8
    try { return ($stdout | ConvertFrom-Json) } catch { return $null }
}

# ---- run ----------------------------------------------------------------------------

$results = [System.Collections.Generic.List[object]]::new()
foreach ($name in $Posture) {
    foreach ($fmt in $HookFormat) {
        Write-Host "[RUN]  $name / $fmt"
        $spec = $postures[$name]
        $run = New-ProbeRun -Name $name -Spec $spec -Format $fmt
        $res = Invoke-ProbeRun -Run $run -PostureArgs $spec.Args

        $ws = $run.Ws
        $denied = @()
        if ($res -and $res.permission_denials) { $denied = @($res.permission_denials | ForEach-Object { $_.tool_name }) }
        $hookLog = Join-Path $ws '.claude' 'hook.log'
        $hookCalls = if (Test-Path -LiteralPath $hookLog) { @(Get-Content -LiteralPath $hookLog) } else { @() }
        $guarded = (Get-Content -LiteralPath (Join-Path $ws 'guarded.txt') -Raw).Trim()
        $stderrText = Get-Content -LiteralPath (Join-Path $run.Dir 'stderr.txt') -Raw -ErrorAction SilentlyContinue
        $row = [pscustomobject][ordered]@{
            posture   = $name
            format    = $fmt
            write     = if (Test-Path -LiteralPath (Join-Path $ws 'free.txt')) { 'written' } else { 'refused' }
            guarded   = if ($guarded -eq 'original') { 'unchanged' } else { 'CHANGED' }
            npmTest   = if (Test-Path -LiteralPath (Join-Path $ws 'npm-test-ran')) { 'ran' } else { 'refused' }
            bashWrite = if (Test-Path -LiteralPath (Join-Path $ws 'bashfree.txt')) { 'WRITTEN' } else { 'refused' }
            denials   = ($denied -join ',')
            hookSawEdit = [bool]($hookCalls | Where-Object { $_ -like 'Edit|*guarded*' })
            isError   = if ($res) { $res.is_error } else { 'no-result' }
            costUsd   = if ($res) { [Math]::Round([double]$res.total_cost_usd, 4) } else { $null }
            untrusted = [bool]($stderrText -match 'not been trusted')
            verdict   = ''
        }
        # The Edit reached the hook only if hook.log has it. Without that the
        # run says nothing about the deny (the Edit failed or was never tried).
        $grantsEdit = $name -in @('dontask-grant', 'settings-trusted', 'acceptedits', 'acceptedits-bash', 'skip')
        $row.verdict = if ($row.hookSawEdit -eq $false) { 'inconclusive (Edit never reached the hook)' }
            elseif ($row.guarded -eq 'CHANGED') { 'DENY OVERRIDDEN' }
            elseif ($denied -contains 'Edit' -and $grantsEdit) { 'deny held (hook)' }
            elseif ($denied -contains 'Edit') { 'refused (mode refuses Edit anyway)' }
            else { 'inconclusive (no Edit denial recorded)' }
        $results.Add($row)
    }
}

$results | Format-Table posture, format, write, guarded, npmTest, bashWrite, denials, verdict, costUsd -AutoSize | Out-String -Width 200 | Write-Host
[ordered]@{
    date          = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    claudeVersion = $claudeVersion
    os            = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    model         = $Model
    runs          = @($results)
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutDir 'results.json') -Encoding utf8
Write-Host "[INFO] results: $(Join-Path $OutDir 'results.json')"
if ($useCreds) {
    Get-ChildItem -LiteralPath $OutDir -Recurse -Force -Filter '.credentials.json' | Remove-Item -Force
}
Write-Host '[INFO] A deny held when guarded=unchanged and denials contains Edit. It is the hook''s'
Write-Host '       doing only under a posture that grants Edit (dontask-grant, settings-trusted,'
Write-Host '       acceptedits*, skip); under dontask-none the mode refuses the Edit anyway.'
