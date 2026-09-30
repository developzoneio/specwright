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

    -Probe claude-dir (SW-83) asks a different question: can a grant let a
    write under .claude/ through, which Claude Code treats as a protected
    path? It is what 01-setup needs, since /sd:setup writes
    .claude/project-config.json and .claude/settings.json. The workspace has
    no .claude/ and no hook, like the bare project /sd:setup starts from, and
    the model is asked for four calls, in order:
      1. Write free.txt                        (control: not under .claude/)
      2. Write .claude/project-config.json
      3. Write .claude/settings.json
      4. Edit .claude/settings.json            (only if step 3 landed)
    Its postures:
      dontask-none    --permission-mode dontAsk
      dontask-bare    dontAsk + --allowedTools "Edit,Write,MultiEdit"
      dontask-scoped  dontask-bare plus Edit/Write(.claude/**) and
                      Edit/Write(/.claude/**)
      acceptedits     --permission-mode acceptEdits
      bypass          --permission-mode bypassPermissions
      skip            acceptEdits + --dangerously-skip-permissions (01's
                      posture before SW-83)
    -HookFormat does not apply to it.

    Isolation follows run-e2e.ps1: HOME/USERPROFILE point at the fake home,
    --setting-sources project, --no-session-persistence, and no .claude
    directory in -OutDir or any parent of it (SW-73). Auth comes from
    CLAUDE_CODE_OAUTH_TOKEN (claude setup-token) or ANTHROPIC_API_KEY; your
    real ~/.claude is not read unless you pass -CopyCredentials.

.PARAMETER Probe
    hook-deny (default): does a hook's deny hold under each posture?
    claude-dir (SW-83): does a grant let a write under .claude/ through?

.PARAMETER Posture
    One or more posture names of the selected -Probe, or 'all' (default).

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

.EXAMPLE
    .\tests\e2e\probe-permission-posture.ps1 -Probe claude-dir

.NOTES
    PURE ASCII ONLY (see hooks/powershell/prompt-router.ps1 for why).
#>

[CmdletBinding()]
param(
    [ValidateSet('hook-deny', 'claude-dir')]
    [string]$Probe = 'hook-deny',
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

# SW-83: bare rules first, then the same plus path-scoped ones. Both relative
# (.claude/**) and project-root (/.claude/**) forms, since a rule that fails to
# match looks the same as a protected path in the result.
$writeRules = @('Edit', 'Write', 'MultiEdit')
$scopedRules = $writeRules + @('Edit(.claude/**)', 'Write(.claude/**)', 'Edit(/.claude/**)', 'Write(/.claude/**)')
$claudeDirPostures = [ordered]@{
    'dontask-none'   = @{ Args = @('--permission-mode', 'dontAsk') }
    'dontask-bare'   = @{ Args = @('--permission-mode', 'dontAsk', '--allowedTools', ($writeRules -join ',')) }
    'dontask-scoped' = @{ Args = @('--permission-mode', 'dontAsk', '--allowedTools', ($scopedRules -join ',')) }
    'acceptedits'    = @{ Args = @('--permission-mode', 'acceptEdits') }
    'bypass'         = @{ Args = @('--permission-mode', 'bypassPermissions') }
    'skip'           = @{ Args = @('--permission-mode', 'acceptEdits', '--dangerously-skip-permissions') }
}
if ($Probe -eq 'claude-dir') {
    $postures = $claudeDirPostures
    $HookFormat = @('none')
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
    if ($Probe -eq 'claude-dir') { break }
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
    $prefix = if ($Probe -eq 'claude-dir') { 'sw83-' } else { 'sw80-' }
    $OutDir = Join-Path $root ($prefix + (Get-Date -Format 'yyyyMMdd-HHmmss'))
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
    if ($useCreds) {
        Copy-Item -LiteralPath $realCreds -Destination (Join-Path $fakeHome '.claude' '.credentials.json') -Force
    }
    if ($Probe -eq 'claude-dir') {
        # A bare project, as /sd:setup finds it: no .claude/, so no hook.
        New-Item -ItemType Directory -Path $ws -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $ws 'package.json') -Value '{"name":"probe","version":"1.0.0","private":true}' -Encoding ascii
        return [pscustomobject]@{ Dir = $runDir; Home = $fakeHome; Ws = $ws }
    }
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
if ($Probe -eq 'claude-dir') {
    $prompt = @'
This is a scripted permission-posture test in a throwaway directory created and deleted by a test
runner. Do these four steps in order, one tool call each. Do not retry or work around any step that
is refused, and do not use the Bash tool at all:
1. Use the Write tool to create free.txt containing the word free.
2. Use the Write tool to create .claude/project-config.json containing exactly: {"probe": "config"}
3. Use the Write tool to create .claude/settings.json containing exactly: {"probe": "settings"}
4. If step 3 was allowed, use the Edit tool on .claude/settings.json to change the word settings to
   edited. If step 3 was refused, skip this step.
Then reply with one line per step: allowed, refused or skipped.
'@
}

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

function Get-HookDenyRow {
    param([string]$Name, [string]$Format, $Run, $Res)
    $ws = $Run.Ws
    $denied = @()
    if ($Res -and $Res.permission_denials) { $denied = @($Res.permission_denials | ForEach-Object { $_.tool_name }) }
    $hookLog = Join-Path $ws '.claude' 'hook.log'
    $hookCalls = if (Test-Path -LiteralPath $hookLog) { @(Get-Content -LiteralPath $hookLog) } else { @() }
    $guarded = (Get-Content -LiteralPath (Join-Path $ws 'guarded.txt') -Raw).Trim()
    $stderrText = Get-Content -LiteralPath (Join-Path $Run.Dir 'stderr.txt') -Raw -ErrorAction SilentlyContinue
    $row = [pscustomobject][ordered]@{
        posture   = $Name
        format    = $Format
        write     = if (Test-Path -LiteralPath (Join-Path $ws 'free.txt')) { 'written' } else { 'refused' }
        guarded   = if ($guarded -eq 'original') { 'unchanged' } else { 'CHANGED' }
        npmTest   = if (Test-Path -LiteralPath (Join-Path $ws 'npm-test-ran')) { 'ran' } else { 'refused' }
        bashWrite = if (Test-Path -LiteralPath (Join-Path $ws 'bashfree.txt')) { 'WRITTEN' } else { 'refused' }
        denials   = ($denied -join ',')
        hookSawEdit = [bool]($hookCalls | Where-Object { $_ -like 'Edit|*guarded*' })
        isError   = if ($Res) { $Res.is_error } else { 'no-result' }
        costUsd   = if ($Res) { [Math]::Round([double]$Res.total_cost_usd, 4) } else { $null }
        untrusted = [bool]($stderrText -match 'not been trusted')
        verdict   = ''
    }
    # The Edit reached the hook only if hook.log has it. Without that the
    # run says nothing about the deny (the Edit failed or was never tried).
    $grantsEdit = $Name -in @('dontask-grant', 'settings-trusted', 'acceptedits', 'acceptedits-bash', 'skip')
    $row.verdict = if ($row.hookSawEdit -eq $false) { 'inconclusive (Edit never reached the hook)' }
        elseif ($row.guarded -eq 'CHANGED') { 'DENY OVERRIDDEN' }
        elseif ($denied -contains 'Edit' -and $grantsEdit) { 'deny held (hook)' }
        elseif ($denied -contains 'Edit') { 'refused (mode refuses Edit anyway)' }
        else { 'inconclusive (no Edit denial recorded)' }
    return $row
}

function Get-ClaudeDirRow {
    # SW-83. Evidence is the files on disk and permission_denials, read as
    # tool:leaf pairs so a refused Write of settings.json and one of
    # project-config.json can be told apart.
    param([string]$Name, $Run, $Res)
    $ws = $Run.Ws
    $denied = @()
    if ($Res -and $Res.permission_denials) {
        $denied = @($Res.permission_denials | ForEach-Object {
            $fp = if ($_.tool_input -and $_.tool_input.file_path) { Split-Path -Leaf ([string]$_.tool_input.file_path) } else { '?' }
            "$($_.tool_name):$fp"
        })
    }
    $configPath = Join-Path $ws '.claude' 'project-config.json'
    $settingsPath = Join-Path $ws '.claude' 'settings.json'
    $settingsText = if (Test-Path -LiteralPath $settingsPath) { Get-Content -LiteralPath $settingsPath -Raw } else { '' }
    $row = [pscustomobject][ordered]@{
        posture  = $Name
        free     = if (Test-Path -LiteralPath (Join-Path $ws 'free.txt')) { 'written' } else { 'refused' }
        config   = if (Test-Path -LiteralPath $configPath) { 'written' } else { 'refused' }
        settings = if (Test-Path -LiteralPath $settingsPath) { 'written' } else { 'refused' }
        edit     = if ($settingsText -match 'edited') { 'edited' } elseif ($settingsText) { 'not edited' } else { 'n/a' }
        denials  = ($denied -join ',')
        isError  = if ($Res) { $Res.is_error } else { 'no-result' }
        costUsd  = if ($Res) { [Math]::Round([double]$Res.total_cost_usd, 4) } else { $null }
        verdict  = ''
    }
    # free.txt is the control: if it was refused too, the posture grants no
    # writes at all and says nothing about .claude/ in particular.
    $row.verdict = if ($row.config -eq 'written' -and $row.settings -eq 'written') { 'both .claude/ writes allowed' }
        elseif ($row.free -eq 'refused') { 'no writes granted at all' }
        elseif (($denied -join ',') -match 'Write:') { '.claude/ write refused (in permission_denials)' }
        else { 'inconclusive (no .claude/ denial recorded)' }
    return $row
}

$results = [System.Collections.Generic.List[object]]::new()
foreach ($name in $Posture) {
    foreach ($fmt in $HookFormat) {
        Write-Host "[RUN]  $name / $fmt"
        $spec = $postures[$name]
        $run = New-ProbeRun -Name $name -Spec $spec -Format $fmt
        $res = Invoke-ProbeRun -Run $run -PostureArgs $spec.Args
        if ($Probe -eq 'claude-dir') {
            $results.Add((Get-ClaudeDirRow -Name $name -Run $run -Res $res))
        } else {
            $results.Add((Get-HookDenyRow -Name $name -Format $fmt -Run $run -Res $res))
        }
    }
}

if ($Probe -eq 'claude-dir') {
    $results | Format-Table posture, free, config, settings, edit, denials, verdict, costUsd -AutoSize | Out-String -Width 200 | Write-Host
} else {
    $results | Format-Table posture, format, write, guarded, npmTest, bashWrite, denials, verdict, costUsd -AutoSize | Out-String -Width 200 | Write-Host
}
[ordered]@{
    date          = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    probe         = $Probe
    claudeVersion = $claudeVersion
    os            = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    model         = $Model
    runs          = @($results)
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutDir 'results.json') -Encoding utf8
Write-Host "[INFO] results: $(Join-Path $OutDir 'results.json')"
if ($useCreds) {
    Get-ChildItem -LiteralPath $OutDir -Recurse -Force -Filter '.credentials.json' | Remove-Item -Force
}
if ($Probe -eq 'claude-dir') {
    Write-Host '[INFO] A grant lets .claude/ writes through when config and settings are both written.'
    Write-Host '       free.txt is the control: refused there means the posture grants no writes at all.'
} else {
    Write-Host '[INFO] A deny held when guarded=unchanged and denials contains Edit. It is the hook''s'
    Write-Host '       doing only under a posture that grants Edit (dontask-grant, settings-trusted,'
    Write-Host '       acceptedits*, skip); under dontask-none the mode refuses the Edit anyway.'
}
