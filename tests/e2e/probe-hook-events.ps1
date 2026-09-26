#requires -Version 7.0
<#
.SYNOPSIS
    ADR 0015 (SW-66): which hook events really block, are prompt-type hooks
    available, what `source` does SessionStart report, and what does a hook on
    each event cost on Windows PowerShell 5.1? Manual, paid, not part of
    run-e2e.ps1 or CI - re-run it when the minimum claude version is raised or
    before building on a hook event this probe has not covered.

.DESCRIPTION
    Runs real headless `claude -p` sessions in throwaway sandboxes. Each sandbox
    workspace carries its own .claude/settings.json wiring a recorder hook
    (record.ps1, generated next to the workspace, run under powershell.exe =
    PS 5.1 - the shipped template's convention) on every event of interest.
    The recorder appends the raw stdin payload to <run>\events.jsonl and, for
    the event under test, blocks exactly once (exit 2 + stderr, or a JSON
    `decision: block`) with a token the model is told to repeat.

    Evidence is never the model's account of what happened:
      events.jsonl                -> which events fired, how often, payload fields
                                     (stop_hook_active, source, session_id)
      <fakehome>\.claude\projects -> transcripts (token reached the model?
                                     compact_boundary written?)
      debug.log (--debug-file)    -> prompt-type hook execution
      the workspace itself        -> did a PostToolUse block undo the write?

    Question map (SW-66):
      Q1 blocking   stop-exit2, stop-json, subagentstop-exit2,
                    precompact-exit2 (+ precompact-control), posttooluse-exit2
      Q2 prompt     prompt-<Event> for Stop, SubagentStop, UserPromptSubmit,
                    PreToolUse, PostToolUse, SessionStart, PreCompact
      Q3 source     sessionstart-source (fresh, --continue, --resume,
                    --resume --fork-session) + the compact control
      Q4 latency    replays one captured payload per event through the recorder
                    under powershell.exe and pwsh (process cost, see ADR 0015)

    Isolation is the same as tests/e2e/probe-model-override.ps1 (SW-72/SW-73):
    fresh fake home with HOME/USERPROFILE pointed at it, --setting-sources
    project, --add-dir <fakehome>, no .claude in any parent of -OutDir. Unlike
    that probe there is no engine install - the only hooks are the recorder -
    and no --dangerously-skip-permissions: it overrides hook denies, which is
    the behaviour under test. Runs use --permission-mode dontAsk with no
    --allowedTools; a case that needs a tool grants it via project
    permissions.allow.

.PARAMETER Case
    One case name (see the question map), a prefix ending in '*' (e.g.
    'prompt-*'), or 'all' (default). 'latency' needs earlier runs in -OutDir.

.PARAMETER BudgetUsd
    --max-budget-usd per claude invocation (default 0.5). 'all' makes ~20.

.PARAMETER LatencyRuns
    Timed replays per event per shell, after 2 discarded warm-ups (default 20).

.PARAMETER OutDir
    Where sandboxes, results and the report go. Kept after the run. Credentials
    copied into it are deleted at the end unless -KeepCredentials.

.PARAMETER EvaluateOnly
    Do not call claude. Re-read the evidence already in -OutDir and rebuild the
    report. Costs nothing (the latency replay still runs locally).

.EXAMPLE
    .\tests\e2e\probe-hook-events.ps1 -Case stop-exit2

.EXAMPLE
    .\tests\e2e\probe-hook-events.ps1 -EvaluateOnly -OutDir C:\sw66-20260926-120000

.NOTES
    Exit 0 = every case produced a definitive observation (each is reported as
             an observed fact, not pass/fail against the docs).
    Exit 1 = at least one case is INCONCLUSIVE (e.g. the event never fired).
    Exit 2 = could not run (missing prerequisite, timeout).
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Join-Path $PSScriptRoot '..' '..'),
    [string]$Case = 'all',
    [double]$BudgetUsd = 0.5,
    [int]$TimeoutSec = 600,
    [int]$LatencyRuns = 20,
    [string]$Model = 'haiku',
    # Drive root, NOT %TEMP%: %TEMP% is under the user profile, whose .claude
    # would be loaded as a project dir and shadow the sandbox (SW-73).
    [string]$OutDir = (Join-Path ([System.IO.Path]::GetPathRoot([System.IO.Path]::GetTempPath())) ('sw66-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))),
    [switch]$KeepCredentials,
    [switch]$EvaluateOnly
)

$ErrorActionPreference = 'Stop'

# ---- helpers -----------------------------------------------------------------

function Write-Info { param([string]$Msg) Write-Host "[INFO] $Msg" }
function Write-Ok   { param([string]$Msg) Write-Host "[OK]   $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "[WARN] $Msg" -ForegroundColor Yellow }

function Exit-CannotRun {
    param([string]$Msg)
    Write-Host "[FAIL] cannot run: $Msg" -ForegroundColor Red
    exit 2
}

function Test-EnvSet {
    param([string]$Name)
    $v = [Environment]::GetEnvironmentVariable($Name)
    return ([string]::IsNullOrWhiteSpace($v) -eq $false)
}

function Get-RealCredentialsPath {
    return (Join-Path $HOME '.claude' '.credentials.json')
}

function Write-Utf8 {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

# ---- preflight ---------------------------------------------------------------

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$hasCreds = Test-Path -LiteralPath (Get-RealCredentialsPath)
$claudeVersion = 'n/a (EvaluateOnly)'
if ($EvaluateOnly -eq $false) {
    if ($null -eq (Get-Command claude -ErrorAction SilentlyContinue)) {
        Exit-CannotRun "'claude' not found on PATH."
    }
    if ($IsWindows -and ($null -eq (Get-Command powershell -ErrorAction SilentlyContinue))) {
        Exit-CannotRun "'powershell' (Windows PowerShell 5.1) not found; the recorder hook runs under it."
    }
    $claudeVersion = (& claude --version 2>$null | Out-String).Trim()
    Write-Info "claude CLI: $claudeVersion"
    if (((Test-EnvSet 'CLAUDE_CODE_OAUTH_TOKEN') -eq $false) -and ($hasCreds -eq $false) -and ((Test-EnvSet 'ANTHROPIC_API_KEY') -eq $false)) {
        Exit-CannotRun 'no claude auth: set CLAUDE_CODE_OAUTH_TOKEN (claude setup-token), log in so ~/.claude/.credentials.json exists, or set ANTHROPIC_API_KEY.'
    }
    if (Test-EnvSet 'ANTHROPIC_API_KEY') {
        Write-Warn 'ANTHROPIC_API_KEY is set; claude -p prefers it, so these runs bill the API.'
    }
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
Write-Info "output dir: $OutDir"

# Isolation guard, same reasoning as probe-model-override.ps1 (SW-73).
$ancestor = Split-Path -Parent $OutDir
while ([string]::IsNullOrEmpty($ancestor) -eq $false) {
    if (Test-Path -LiteralPath (Join-Path $ancestor '.claude')) {
        Exit-CannotRun ("$ancestor\.claude exists above -OutDir; the sandbox would load it as a project dir " +
            'and stop being isolated. Pick an -OutDir with no .claude folder in any parent (e.g. D:\sw66).')
    }
    $next = Split-Path -Parent $ancestor
    if ($next -eq $ancestor) { break }
    $ancestor = $next
}

# ---- recorder hook -----------------------------------------------------------

# Runs under Windows PowerShell 5.1: pure ASCII, no pwsh-only syntax.
# -Mode log        record only
# -Mode exit2      first firing: record, stderr message, exit 2
# -Mode json       first firing: record, stdout {"decision":"block","reason":...}, exit 0
$recorderSource = @'
param([string]$EventName, [string]$Mode = 'log', [string]$Log, [string]$Marker)
$t0 = [DateTime]::UtcNow
$raw = [Console]::In.ReadToEnd()
$blocked = $false
if (($Mode -ne 'log') -and (-not (Test-Path -LiteralPath $Marker))) {
    [System.IO.File]::WriteAllText($Marker, 'x')
    $blocked = $true
}
$rec = New-Object PSObject -Property @{
    event = $EventName; mode = $Mode; blocked = $blocked; raw = $raw
    t_start = $t0.ToString('o'); t_end = [DateTime]::UtcNow.ToString('o')
}
$enc = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::AppendAllText($Log, ($rec | ConvertTo-Json -Compress) + "`n", $enc)
if ($blocked) {
    $msg = "Hook feedback: include the exact text SW66-TOKEN-$EventName in your reply."
    if ($Mode -eq 'exit2') { [Console]::Error.WriteLine($msg); exit 2 }
    if ($Mode -eq 'json') {
        [Console]::Out.Write((New-Object PSObject -Property @{ decision = 'block'; reason = $msg } | ConvertTo-Json -Compress))
        exit 0
    }
}
exit 0
'@

$allEvents = @('SessionStart', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop', 'SubagentStop', 'PreCompact', 'SessionEnd')

function Get-RecorderCommand {
    param([string]$RunDir, [string]$EventName, [string]$Mode)
    $rec = Join-Path $RunDir 'record.ps1'
    $log = Join-Path $RunDir 'events.jsonl'
    $marker = Join-Path $RunDir "$EventName.blocked"
    return "powershell -NoProfile -ExecutionPolicy Bypass -File `"$rec`" -EventName $EventName -Mode $Mode -Log `"$log`" -Marker `"$marker`""
}

function Get-PromptHookText {
    param([string]$EventName)
    # The token proves the hook's verdict reached the session; the loop guard
    # keeps a Stop/SubagentStop block from repeating forever.
    return ('You are a test hook. Input JSON: $ARGUMENTS. If the input has "stop_hook_active": true, ' +
        'respond with exactly {"ok": true}. Otherwise respond with exactly ' +
        '{"ok": false, "reason": "Hook feedback: include the exact text SW66-TOKEN-PROMPT-' + $EventName + ' in your reply."}')
}

function New-SettingsJson {
    # $Modes: event -> 'log' | 'exit2' | 'json' | 'prompt'. Every event in
    # $allEvents gets a log recorder unless overridden; a 'prompt' event gets
    # the prompt hook AND a log recorder, so the fire count is still visible.
    param([string]$RunDir, [hashtable]$Modes, [string[]]$Allow)
    $hooks = [ordered]@{}
    foreach ($ev in $allEvents) {
        $mode = if ($Modes.ContainsKey($ev)) { $Modes[$ev] } else { 'log' }
        $entries = @()
        if ($mode -eq 'prompt') {
            $entries += [ordered]@{ type = 'prompt'; prompt = (Get-PromptHookText $ev); timeout = 30 }
            $entries += [ordered]@{ type = 'command'; command = (Get-RecorderCommand $RunDir $ev 'log'); timeout = 30 }
        }
        else {
            $entries += [ordered]@{ type = 'command'; command = (Get-RecorderCommand $RunDir $ev $mode); timeout = 30 }
        }
        $group = [ordered]@{ hooks = $entries }
        if ($ev -in @('PreToolUse', 'PostToolUse')) { $group = [ordered]@{ matcher = '*'; hooks = $entries } }
        $hooks[$ev] = @($group)
    }
    $settings = [ordered]@{ hooks = $hooks }
    if ($null -ne $Allow -and $Allow.Count -gt 0) { $settings['permissions'] = [ordered]@{ allow = $Allow } }
    return ($settings | ConvertTo-Json -Depth 10)
}

# ---- sandbox -----------------------------------------------------------------

function New-Sandbox {
    param([string]$RunDir, [hashtable]$Modes, [string[]]$Allow)
    $fakeHome = Join-Path $RunDir 'home'
    New-Item -ItemType Directory -Path (Join-Path $fakeHome '.claude') -Force | Out-Null
    if ($hasCreds) {
        Copy-Item -LiteralPath (Get-RealCredentialsPath) -Destination (Join-Path $fakeHome '.claude' '.credentials.json') -Force
    }
    $ws = Join-Path $RunDir 'ws'
    New-Item -ItemType Directory -Path (Join-Path $ws '.claude') -Force | Out-Null
    # An untrusted workspace has its project permissions.allow IGNORED in -p
    # mode (stderr: "Ignoring N permissions.allow entries ... not been
    # trusted"), so the Write the PostToolUse cases need would be refused.
    # Pre-accept the trust dialog in the fake home's .claude.json instead.
    $trust = [ordered]@{ projects = [ordered]@{ ($ws -replace '\\', '/') = [ordered]@{ hasTrustDialogAccepted = $true } } }
    Write-Utf8 (Join-Path $fakeHome '.claude.json') ($trust | ConvertTo-Json -Depth 5)
    Write-Utf8 (Join-Path $ws 'README.md') "# sw66 probe workspace`n"
    Write-Utf8 (Join-Path $RunDir 'record.ps1') $recorderSource
    Write-Utf8 (Join-Path $ws '.claude' 'settings.json') (New-SettingsJson -RunDir $RunDir -Modes $Modes -Allow $Allow)
    return [pscustomobject]@{ FakeHome = $fakeHome; Ws = $ws }
}

# ---- claude invocation -------------------------------------------------------

function Invoke-ClaudeRun {
    param([string]$RunDir, [string]$FakeHome, [string]$Workspace, [string]$Prompt,
        [string]$StepName, [string]$Resume, [switch]$Continue, [switch]$ForkSession)

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = 'claude'
    $cliArgs = @(
        '-p', $Prompt,
        '--output-format', 'json',
        '--model', $Model,
        '--setting-sources', 'project',
        '--add-dir', $FakeHome,
        '--max-budget-usd', $BudgetUsd.ToString([System.Globalization.CultureInfo]::InvariantCulture),
        '--permission-mode', 'dontAsk',
        '--debug-file', (Join-Path $RunDir "$StepName.debug.log")
    )
    if ([string]::IsNullOrEmpty($Resume) -eq $false) { $cliArgs += @('--resume', $Resume) }
    if ($Continue) { $cliArgs += '--continue' }
    if ($ForkSession) { $cliArgs += '--fork-session' }
    foreach ($a in $cliArgs) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = $Workspace
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.EnvironmentVariables['HOME'] = $FakeHome
    $psi.EnvironmentVariables['USERPROFILE'] = $FakeHome
    [void]$psi.EnvironmentVariables.Remove('CLAUDE_PROJECT_DIR')
    foreach ($authVar in @('ANTHROPIC_API_KEY', 'CLAUDE_CODE_OAUTH_TOKEN')) {
        if ($psi.EnvironmentVariables.ContainsKey($authVar) -and ((Test-EnvSet $authVar) -eq $false)) {
            $psi.EnvironmentVariables.Remove($authVar)
        }
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    if ($proc.WaitForExit($TimeoutSec * 1000) -eq $false) {
        try { $proc.Kill($true) } catch { }
        Exit-CannotRun "claude -p timed out after $TimeoutSec s ($RunDir, $StepName)"
    }
    Write-Utf8 (Join-Path $RunDir "$StepName.result.json") $stdoutTask.GetAwaiter().GetResult()
    Write-Utf8 (Join-Path $RunDir "$StepName.stderr.txt") $stderrTask.GetAwaiter().GetResult()
    return (Read-StepResult -RunDir $RunDir -StepName $StepName)
}

function Read-StepResult {
    param([string]$RunDir, [string]$StepName)
    $p = Join-Path $RunDir "$StepName.result.json"
    if ((Test-Path -LiteralPath $p) -eq $false) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

# ---- evidence ----------------------------------------------------------------

function Get-Events {
    param([string]$RunDir)
    $p = Join-Path $RunDir 'events.jsonl'
    if ((Test-Path -LiteralPath $p) -eq $false) { return @() }
    $rows = @()
    foreach ($line in [System.IO.File]::ReadLines($p)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $o = $null
        try { $o = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $payload = $null
        try { $payload = $o.raw | ConvertFrom-Json -ErrorAction Stop } catch { }
        $rows += [pscustomobject]@{
            Event = [string]$o.event; Mode = [string]$o.mode; Blocked = [bool]$o.blocked
            Payload = $payload; Raw = [string]$o.raw
            InHookMs = (([datetime]$o.t_end).ToUniversalTime() - ([datetime]$o.t_start).ToUniversalTime()).TotalMilliseconds
        }
    }
    return $rows
}

function Get-TranscriptFiles {
    param([string]$FakeHome)
    $projects = Join-Path $FakeHome '.claude' 'projects'
    if ((Test-Path -LiteralPath $projects) -eq $false) { return @() }
    return @(Get-ChildItem -LiteralPath $projects -Recurse -Filter '*.jsonl')
}

function Test-TextInFiles {
    param($Files, [string]$Text)
    foreach ($f in @($Files)) {
        if ($null -eq $f) { continue }
        $path = if ($f -is [System.IO.FileInfo]) { $f.FullName } else { [string]$f }
        if ((Test-Path -LiteralPath $path) -and ((Get-Content -LiteralPath $path -Raw) -like "*$Text*")) { return $true }
    }
    return $false
}

function Test-CompactBoundary {
    param([string]$FakeHome)
    foreach ($f in (Get-TranscriptFiles $FakeHome)) {
        if ((Get-Content -LiteralPath $f.FullName -Raw) -match '"subtype"\s*:\s*"compact_boundary"') { return $true }
    }
    return $false
}

function Get-ResultText {
    param($Result)
    if ($null -eq $Result) { return '' }
    return [string]$Result.result
}

function Get-DebugHookLines {
    # Lines of the debug logs that mention a prompt hook or the event, for the
    # report. Filtering is loose on purpose: the debug format is not a contract.
    param([string]$RunDir, [string]$EventName)
    $lines = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $RunDir -Filter '*.debug.log' -ErrorAction SilentlyContinue)) {
        $lines += @(Select-String -LiteralPath $f.FullName -Pattern "prompt.?hook|type.?prompt|$EventName" -ErrorAction SilentlyContinue |
            Where-Object { $_.Line -match '(?i)hook' } | ForEach-Object { $_.Line.Trim() })
    }
    return $lines
}

# ---- case definitions --------------------------------------------------------

$okPrompt = 'Reply with the single word OK. Do not use any tools.'
$agentPrompt = ('Use the Agent tool exactly once, with subagent_type general-purpose and this prompt: ' +
    '"Reply with the single word DONE. Do not use any tools." Then reply with what it returned, ' +
    'plus, verbatim, any hook feedback you or it received.')
$writePrompt = ('Use the Write tool exactly once to create the file probe.txt in the current directory ' +
    'containing exactly: hello. Then, in your final reply, quote verbatim any hook feedback you received, or say NONE.')

# Steps: Name, Prompt, and how to attach to an earlier step's session.
function New-Step {
    param([string]$Name, [string]$Prompt, [string]$ResumeFrom, [switch]$Continue, [switch]$Fork)
    return [pscustomobject]@{ Name = $Name; Prompt = $Prompt; ResumeFrom = $ResumeFrom; Continue = [bool]$Continue; Fork = [bool]$Fork }
}

$compactSteps = @((New-Step 's1' $okPrompt), (New-Step 's2' '/compact' -ResumeFrom 's1'))

$cases = [System.Collections.Generic.List[object]]::new()

# Q1 - does the event block?
$cases.Add([pscustomobject]@{ Name = 'stop-exit2'; Q = 'Q1'; Event = 'Stop'; Modes = @{ Stop = 'exit2' }; Allow = @(); Steps = @(New-Step 's1' $okPrompt) })
$cases.Add([pscustomobject]@{ Name = 'stop-json'; Q = 'Q1'; Event = 'Stop'; Modes = @{ Stop = 'json' }; Allow = @(); Steps = @(New-Step 's1' $okPrompt) })
$cases.Add([pscustomobject]@{ Name = 'subagentstop-exit2'; Q = 'Q1'; Event = 'SubagentStop'; Modes = @{ SubagentStop = 'exit2' }; Allow = @('Agent', 'Task'); Steps = @(New-Step 's1' $agentPrompt) })
$cases.Add([pscustomobject]@{ Name = 'precompact-exit2'; Q = 'Q1'; Event = 'PreCompact'; Modes = @{ PreCompact = 'exit2' }; Allow = @(); Steps = $compactSteps })
$cases.Add([pscustomobject]@{ Name = 'precompact-control'; Q = 'Q1'; Event = 'PreCompact'; Modes = @{}; Allow = @(); Steps = $compactSteps })
$cases.Add([pscustomobject]@{ Name = 'posttooluse-exit2'; Q = 'Q1'; Event = 'PostToolUse'; Modes = @{ PostToolUse = 'exit2' }; Allow = @('Write'); Steps = @(New-Step 's1' $writePrompt) })

# Q2 - is a prompt-type hook accepted and effective on the event?
foreach ($ev in @('Stop', 'SubagentStop', 'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'SessionStart', 'PreCompact')) {
    $steps = switch ($ev) {
        'SubagentStop' { @(New-Step 's1' $agentPrompt) }
        'PreToolUse'   { @(New-Step 's1' $writePrompt) }
        'PostToolUse'  { @(New-Step 's1' $writePrompt) }
        'PreCompact'   { $compactSteps }
        default        { @(New-Step 's1' $okPrompt) }
    }
    $allow = switch ($ev) { 'SubagentStop' { @('Agent', 'Task') } 'PreToolUse' { @('Write') } 'PostToolUse' { @('Write') } default { @() } }
    $cases.Add([pscustomobject]@{ Name = "prompt-$($ev.ToLowerInvariant())"; Q = 'Q2'; Event = $ev; Modes = @{ $ev = 'prompt' }; Allow = $allow; Steps = $steps })
}

# Q3 - SessionStart source per entry point (one sandbox, sessions chained).
$cases.Add([pscustomobject]@{ Name = 'sessionstart-source'; Q = 'Q3'; Event = 'SessionStart'; Modes = @{}; Allow = @(); Steps = @(
    (New-Step 'fresh' $okPrompt),
    (New-Step 'continue' $okPrompt -Continue),
    (New-Step 'resume' $okPrompt -ResumeFrom 'fresh'),
    (New-Step 'fork' $okPrompt -ResumeFrom 'fresh' -Fork)
) })

$runLatency = ($Case -eq 'all') -or ($Case -eq 'latency')
$selected = @()
if ($Case -eq 'all') { $selected = @($cases) }
elseif ($Case -ne 'latency') {
    $selected = @($cases | Where-Object { $_.Name -like $Case })
    if ($selected.Count -eq 0) { Exit-CannotRun "no case matches '$Case'. Cases: $(($cases | ForEach-Object Name) -join ', '), latency" }
}

# ---- run ---------------------------------------------------------------------

function Invoke-Case {
    param($C)
    $runDir = Join-Path $OutDir $C.Name
    $fakeHome = Join-Path $runDir 'home'
    $ws = Join-Path $runDir 'ws'
    if ($EvaluateOnly) {
        if ((Test-Path -LiteralPath $runDir) -eq $false) { Exit-CannotRun "-EvaluateOnly: no earlier run at $runDir" }
        return
    }
    if (Test-Path -LiteralPath $runDir) { Remove-Item -LiteralPath $runDir -Recurse -Force }
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    $sb = New-Sandbox -RunDir $runDir -Modes $C.Modes -Allow $C.Allow
    $sessions = @{}
    foreach ($s in $C.Steps) {
        $resume = ''
        if ([string]::IsNullOrEmpty($s.ResumeFrom) -eq $false) { $resume = $sessions[$s.ResumeFrom] }
        Write-Info "$($C.Name)/$($s.Name) : claude -p (budget $BudgetUsd USD)$(if ($resume) { " --resume $resume" })$(if ($s.Continue) { ' --continue' })$(if ($s.Fork) { ' --fork-session' })"
        $r = Invoke-ClaudeRun -RunDir $runDir -FakeHome $sb.FakeHome -Workspace $sb.Ws -Prompt $s.Prompt -StepName $s.Name `
            -Resume $resume -Continue:$s.Continue -ForkSession:$s.Fork
        $sessions[$s.Name] = if ($null -ne $r) { [string]$r.session_id } else { '' }
    }
    if ($KeepCredentials -eq $false) {
        $creds = Join-Path $fakeHome '.claude' '.credentials.json'
        if (Test-Path -LiteralPath $creds) { Remove-Item -LiteralPath $creds -Force }
    }
}

function Get-CaseObservation {
    # Returns @{ Conclusive; Lines } - facts only, each with its evidence.
    param($C)
    $runDir = Join-Path $OutDir $C.Name
    $fakeHome = Join-Path $runDir 'home'
    $ws = Join-Path $runDir 'ws'
    $ev = @(Get-Events $runDir)
    $mine = @($ev | Where-Object { $_.Event -eq $C.Event })
    $transcripts = Get-TranscriptFiles $fakeHome
    $results = @{}
    foreach ($s in $C.Steps) { $results[$s.Name] = Read-StepResult $runDir $s.Name }
    $lastResult = $results[$C.Steps[-1].Name]
    $lines = [System.Collections.Generic.List[string]]::new()
    $conclusive = $true

    foreach ($s in $C.Steps) {
        $r = $results[$s.Name]
        if ($null -eq $r) { $lines.Add("step $($s.Name): no JSON result (see $($s.Name).stderr.txt)"); continue }
        $lines.Add("step $($s.Name): is_error=$($r.is_error) subtype=$($r.subtype) session_id=$($r.session_id) cost_usd=$($r.total_cost_usd) duration_ms=$($r.duration_ms)")
    }
    $lines.Add("events fired (all): $(($ev | Group-Object Event | ForEach-Object { "$($_.Name)x$($_.Count)" }) -join ', ')")

    switch -Wildcard ($C.Name) {
        'stop-*' {
            $second = @($mine | Where-Object { $null -ne $_.Payload -and $_.Payload.stop_hook_active -eq $true })
            $token = Test-TextInFiles $transcripts "SW66-TOKEN-Stop"
            $lines.Add("Stop fired $($mine.Count)x; firings with stop_hook_active=true: $($second.Count); token in transcript: $token; token in final result: $((Get-ResultText $lastResult) -like '*SW66-TOKEN-Stop*')")
            if ($mine.Count -eq 0) { $conclusive = $false; $lines.Add('INCONCLUSIVE: Stop never fired') }
            else { $lines.Add("OBSERVED: Stop $(if ($mine.Count -ge 2 -and $second.Count -ge 1) { 'BLOCKS' } else { 'does NOT block' }) on $($C.Modes['Stop'])") }
        }
        'subagentstop-*' {
            $second = @($mine | Where-Object { $null -ne $_.Payload -and $_.Payload.stop_hook_active -eq $true })
            $sub = @($transcripts | Where-Object { $_.Directory.Name -eq 'subagents' })
            $lines.Add("SubagentStop fired $($mine.Count)x; stop_hook_active=true: $($second.Count); token in subagent transcript: $(Test-TextInFiles $sub 'SW66-TOKEN-SubagentStop'); token anywhere: $(Test-TextInFiles $transcripts 'SW66-TOKEN-SubagentStop')")
            if ($mine.Count -eq 0) { $conclusive = $false; $lines.Add('INCONCLUSIVE: SubagentStop never fired (did the Agent call happen?)') }
            else { $lines.Add("OBSERVED: SubagentStop $(if ($mine.Count -ge 2 -and $second.Count -ge 1) { 'BLOCKS' } else { 'does NOT block' }) on exit2") }
        }
        'precompact-*' {
            $compacted = Test-CompactBoundary $fakeHome
            $ssCompact = @($ev | Where-Object { $_.Event -eq 'SessionStart' -and $null -ne $_.Payload -and $_.Payload.source -eq 'compact' })
            $trig = ($mine | ForEach-Object { if ($null -ne $_.Payload) { $_.Payload.trigger } }) -join ','
            $lines.Add("PreCompact fired $($mine.Count)x (trigger: $trig); compact_boundary in transcript: $compacted; SessionStart source=compact: $($ssCompact.Count)")
            $lines.Add("stderr tail: $(((Get-Content -LiteralPath (Join-Path $runDir 's2.stderr.txt') -Raw -ErrorAction SilentlyContinue) + '').Trim() -replace '\s+', ' ')")
            $lines.Add("result text: $((Get-ResultText $lastResult) -replace '\s+', ' ')")
            if ($mine.Count -eq 0) { $conclusive = $false; $lines.Add('INCONCLUSIVE: PreCompact never fired (/compact not honoured in -p?)') }
            elseif ($C.Name -eq 'precompact-exit2') { $lines.Add("OBSERVED: PreCompact exit2 $(if ($compacted) { 'does NOT block compaction' } else { 'BLOCKS compaction (compare the control)' })") }
            else {
                if ($compacted -eq $false) { $conclusive = $false; $lines.Add('INCONCLUSIVE: control did not compact either, so the exit2 case proves nothing') }
                else { $lines.Add('OBSERVED: control compacts (the method detects compaction)') }
            }
        }
        'posttooluse-*' {
            $probe = Join-Path $ws 'probe.txt'
            $exists = Test-Path -LiteralPath $probe
            $content = if ($exists) { (Get-Content -LiteralPath $probe -Raw).Trim() } else { '' }
            $toModel = Test-TextInFiles $transcripts 'SW66-TOKEN-PostToolUse'
            $lines.Add("PostToolUse fired $($mine.Count)x (tools: $(($mine | ForEach-Object { if ($null -ne $_.Payload) { $_.Payload.tool_name } }) -join ',')); probe.txt exists: $exists (content '$content'); token in transcript: $toModel")
            if ($mine.Count -eq 0) { $conclusive = $false; $lines.Add('INCONCLUSIVE: PostToolUse never fired (was Write allowed?)') }
            else { $lines.Add("OBSERVED: PostToolUse exit2 $(if ($exists) { 'does NOT undo the write' } else { 'the file is absent (undone or never written)' }); stderr $(if ($toModel) { 'DOES' } else { 'does NOT' }) reach the model") }
        }
        'prompt-*' {
            # Verdict comes from the debug log only. The token is NOT evidence
            # here: the hook's own prompt text contains it, and the CLI copies
            # hook text into the transcript (a hook_non_blocking_error
            # attachment, the /compact output's hook list) even when the
            # prompt hook never ran - seen on SessionStart and PreCompact.
            $token = "SW66-TOKEN-PROMPT-$($C.Event)"
            $inResult = (Get-ResultText $lastResult) -like "*$token*"
            $dbg = @(Get-DebugHookLines $runDir $C.Event)
            $ran = @($dbg | Where-Object { $_ -match 'Processing prompt hook' })
            $verdict = @($dbg | Where-Object { $_ -match 'Prompt hook condition was (not )?met' })
            $unsupported = @($dbg | Where-Object { $_ -match 'prompt-type hooks are not supported' })
            $stderrFiles = @(Get-ChildItem -LiteralPath $runDir -Filter '*.stderr.txt' -ErrorAction SilentlyContinue)
            $settingsErr = @($stderrFiles | ForEach-Object { Select-String -LiteralPath $_.FullName -Pattern '(?i)invalid|hook' -ErrorAction SilentlyContinue } | ForEach-Object { $_.Line.Trim() })
            $lines.Add("$($C.Event) (command recorder) fired $($mine.Count)x; debug: prompt hook processed $($ran.Count)x, verdicts $($verdict.Count), 'not supported' errors $($unsupported.Count); token in final result: $inResult")
            foreach ($d in (@($verdict) + @($unsupported) | Select-Object -First 4)) { $lines.Add("  debug: $($d.Substring(0, [Math]::Min(240, $d.Length)))") }
            foreach ($e in ($settingsErr | Select-Object -First 3)) { $lines.Add("  stderr: $($e.Substring(0, [Math]::Min(240, $e.Length)))") }
            if ($mine.Count -eq 0) { $conclusive = $false; $lines.Add("INCONCLUSIVE: $($C.Event) never fired, so the prompt hook had no chance") }
            elseif ($unsupported.Count -gt 0) { $lines.Add("OBSERVED: prompt hook on $($C.Event) REJECTED at run time (non-blocking error; session continues)") }
            elseif ($verdict.Count -gt 0) { $lines.Add("OBSERVED: prompt hook on $($C.Event) RUNS (model verdict in debug log)") }
            else { $lines.Add("OBSERVED: prompt hook on $($C.Event) SILENTLY SKIPPED (event fired, command hook ran, no prompt-hook trace)") }
        }
        'sessionstart-source' {
            $ss = @($mine)
            $i = 0
            foreach ($row in $ss) {
                $i++
                $src = if ($null -ne $row.Payload) { $row.Payload.source } else { '?' }
                $sid = if ($null -ne $row.Payload) { $row.Payload.session_id } else { '?' }
                $lines.Add("SessionStart #${i}: source=$src session_id=$sid")
            }
            $lines.Add("steps in order: $(($C.Steps | ForEach-Object Name) -join ', ') (fork result session_id vs resume: see the step lines above)")
            if ($ss.Count -lt $C.Steps.Count) { $lines.Add("NOTE: $($ss.Count) SessionStart firings for $($C.Steps.Count) invocations - some entry point did not fire it") }
            if ($ss.Count -eq 0) { $conclusive = $false; $lines.Add('INCONCLUSIVE: SessionStart never fired') }
            else {
                $pairs = for ($k = 0; $k -lt [Math]::Min($ss.Count, $C.Steps.Count); $k++) {
                    "$($C.Steps[$k].Name)=$(if ($null -ne $ss[$k].Payload) { $ss[$k].Payload.source } else { '?' })"
                }
                $lines.Add("OBSERVED: SessionStart fired $($ss.Count)x for $($C.Steps.Count) invocations; source per entry point: $($pairs -join ', ')")
            }
        }
    }
    return [pscustomobject]@{ Conclusive = $conclusive; Lines = $lines }
}

# ---- latency (Q4) ------------------------------------------------------------

# Mirrors tests/hooks/measure-latency.ps1 Invoke-TimedHookRun / Get-Percentile
# (that script runs its main body on load, so it cannot be dot-sourced).
function Invoke-TimedHookRun {
    param([string]$Exe, [string[]]$HookArgs, [string]$Payload)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Exe
    foreach ($a in @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File') + $HookArgs) { $psi.ArgumentList.Add($a) }
    [void]$psi.Environment.Remove('CLAUDE_PROJECT_DIR')
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::Start($psi)
    try { $proc.StandardInput.Write($Payload); $proc.StandardInput.Close() } catch [System.IO.IOException] { }
    $null = $proc.StandardOutput.ReadToEnd()
    $null = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    $sw.Stop()
    return [pscustomobject]@{ Ms = $sw.Elapsed.TotalMilliseconds; ExitCode = $proc.ExitCode }
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

function Get-LatencyTable {
    # One captured payload per event (first seen across all case dirs), replayed
    # through a log-mode recorder. In-hook ms comes from the live runs.
    $byEvent = @{}
    $inHook = @{}
    foreach ($dir in @(Get-ChildItem -LiteralPath $OutDir -Directory -ErrorAction SilentlyContinue)) {
        foreach ($row in (Get-Events $dir.FullName)) {
            if ($byEvent.ContainsKey($row.Event) -eq $false) { $byEvent[$row.Event] = $row.Raw }
            if ($inHook.ContainsKey($row.Event) -eq $false) { $inHook[$row.Event] = @() }
            $inHook[$row.Event] += $row.InHookMs
        }
    }
    $latDir = Join-Path $OutDir 'latency'
    New-Item -ItemType Directory -Path $latDir -Force | Out-Null
    $rec = Join-Path $latDir 'record.ps1'
    Write-Utf8 $rec $recorderSource
    $shells = @('powershell', 'pwsh') | Where-Object { $null -ne (Get-Command $_ -ErrorAction SilentlyContinue) }
    $rows = @()
    foreach ($evName in ($allEvents | Where-Object { $byEvent.ContainsKey($_) })) {
        foreach ($sh in $shells) {
            $hookArgs = @($rec, '-EventName', $evName, '-Mode', 'log', '-Log', (Join-Path $latDir 'replay.jsonl'), '-Marker', (Join-Path $latDir 'unused'))
            for ($w = 0; $w -lt 2; $w++) { $null = Invoke-TimedHookRun -Exe $sh -HookArgs $hookArgs -Payload $byEvent[$evName] }
            $ms = @()
            for ($i = 0; $i -lt $LatencyRuns; $i++) {
                $t = Invoke-TimedHookRun -Exe $sh -HookArgs $hookArgs -Payload $byEvent[$evName]
                if ($t.ExitCode -eq 0) { $ms += $t.Ms }
            }
            $rows += [pscustomobject]@{
                Event = $evName; Shell = $sh; N = $ms.Count
                P50 = (Get-Percentile $ms 50); P95 = (Get-Percentile $ms 95)
                InHookP50 = (Get-Percentile @($inHook[$evName]) 50)
            }
            Write-Info "latency $evName / $sh : p50 $((Get-Percentile $ms 50)) ms, p95 $((Get-Percentile $ms 95)) ms"
        }
    }
    return $rows
}

# ---- main --------------------------------------------------------------------

foreach ($c in $selected) { Invoke-Case $c }

$report = [System.Text.StringBuilder]::new()
[void]$report.AppendLine('# SW-66 hook event probe')
[void]$report.AppendLine('')
[void]$report.AppendLine("- Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
[void]$report.AppendLine("- Claude Code: $claudeVersion")
[void]$report.AppendLine("- Model: $Model; permission mode: dontAsk (no --allowedTools, no skip-permissions)")
[void]$report.AppendLine("- specwright commit: $((& git -C $RepoRoot rev-parse --short HEAD 2>$null) -join '')")
[void]$report.AppendLine("- OS: $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)")
[void]$report.AppendLine('')

# Report every case that has evidence in -OutDir, not only the ones run now,
# so a partial re-run still yields the full picture.
$allConclusive = $true
foreach ($c in $cases) {
    if ((Test-Path -LiteralPath (Join-Path $OutDir $c.Name)) -eq $false) { continue }
    $obs = Get-CaseObservation $c
    [void]$report.AppendLine("## $($c.Name) ($($c.Q), $($c.Event))")
    [void]$report.AppendLine('')
    foreach ($l in $obs.Lines) { [void]$report.AppendLine("- $l") }
    [void]$report.AppendLine('')
    $verdictLine = @($obs.Lines | Where-Object { $_ -like 'OBSERVED:*' -or $_ -like 'INCONCLUSIVE:*' }) -join ' / '
    if ($obs.Conclusive) { Write-Ok "$($c.Name) : $verdictLine" } else { Write-Warn "$($c.Name) : $verdictLine"; $allConclusive = $false }
}

if ($runLatency) {
    $lat = @(Get-LatencyTable)
    [void]$report.AppendLine('## latency (Q4)')
    [void]$report.AppendLine('')
    [void]$report.AppendLine("Replay of one captured payload per event through the log-mode recorder, $LatencyRuns runs after 2 warm-ups.")
    [void]$report.AppendLine('Process cost only (spawn + read stdin + append a line); excludes the CLI''s own dispatch. In-hook = t_end - t_start inside the live runs.')
    [void]$report.AppendLine('')
    [void]$report.AppendLine('| event | shell | n | p50 ms | p95 ms | in-hook p50 ms (live) |')
    [void]$report.AppendLine('|---|---|---|---|---|---|')
    foreach ($r in $lat) { [void]$report.AppendLine("| $($r.Event) | $($r.Shell) | $($r.N) | $($r.P50) | $($r.P95) | $($r.InHookP50) |") }
    [void]$report.AppendLine('')
    if ($lat.Count -eq 0) { $allConclusive = $false; Write-Warn 'latency: no captured payloads in -OutDir (run the other cases first)' }
}

$reportPath = Join-Path $OutDir 'sw66-report.md'
Write-Utf8 $reportPath $report.ToString()
Write-Host ''
Write-Info "report: $reportPath"
if ($allConclusive) { Write-Ok 'every case produced a definitive observation'; exit 0 }
Write-Warn 'at least one case is INCONCLUSIVE - see the report'
exit 1
