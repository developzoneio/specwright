#requires -Version 7.0
<#
.SYNOPSIS
    ADR 0013 (SW-72): does /sd:feature actually pass the Agent tool's `model`
    parameter when an escalation rule fires, and is the call served on that tier?
    Manual, paid, not part of run-e2e.ps1 or CI - re-run it when the minimum
    claude version is raised or a release changes subagent model resolution.

.DESCRIPTION
    Runs real headless `claude -p` sessions against sandbox installs, in pairs:
    one run where a rule must fire, one control run where it must not. For each
    run it reads every subagent's evidence from the session transcript:

      <fakehome>\.claude\projects\<ws>\<session>\subagents\agent-<id>.meta.json
          -> agentType + the `model` the main thread passed to the Agent tool
      <fakehome>\.claude\projects\<ws>\<session>\subagents\agent-<id>.jsonl
          -> message.model on each assistant turn = the model the API served

    It never reads the model's own account of what it did.

    Cases:
      feat04 - Phase 4, ESC-FEAT-04. e2e scenario 06 as shipped (T01 is L)
               vs. the same workspace with T01 set to S.
               Expect: L run has an sd-implementer call with model=sonnet
               served on claude-sonnet-*; control has no model on any call.
      feat03 - Phase 2 + 3, ESC-FEAT-02 and ESC-FEAT-03. Scenario 06's spec
               reseeded as `draft` (so Phase 2 runs - the state machine sends
               `approved` straight to Phase 3), complexity L vs. M, and
               escalation ceiling raised to opus (scenario 06 pins sonnet,
               which would cap ESC-FEAT-03). Stops at Gate 2.
               Expect: L run has sd-code-explorer model=sonnet and
               sd-spec-architect model=opus, each served on that tier;
               control has neither.
      feat04b - Phase 4, ESC-FEAT-04b (SW-76). Scenario 06 with T01 at
               `Estimated complexity: S` and `Reversibility: hard` vs. T01 at
               S with the default `trivial`.
               Expect: run has an sd-implementer call with model=sonnet
               served on claude-sonnet-*; control has no model on any call.
      feat03b - Gate 2 Face B `no-split`, ESC-FEAT-03b (SW-76). A `draft`
               spec at complexity M (so ESC-FEAT-03 does not fire) whose
               scope spans all three production layers, which puts the plan
               over Gate 2's layer threshold. Two turns: turn 1 stops at
               Gate 2; if it showed Face B, turn 2 resumes the session
               (--resume) with `no-split` (run) or `approve split` (control).
               Expect: run has an sd-spec-architect call at the default and a
               re-invoked one with model=opus served on claude-opus-*;
               control has no model on any sd-spec-architect call.
               If turn 1 shows Face A the case is inconclusive, not Verdict B.

    Isolation is the same as tests/e2e/run-e2e.ps1, plus a guard that -OutDir
    has no .claude folder in any parent directory (see the guard for why): install.ps1 -BasePath into
    a fresh fake home, HOME/USERPROFILE pointed at it, --setting-sources
    project, --add-dir <fakehome>. Auth comes from CLAUDE_CODE_OAUTH_TOKEN
    (claude setup-token) or ANTHROPIC_API_KEY in the environment. Your real
    ~/.claude is not read unless you pass -CopyCredentials. One difference
    from the harness, on purpose: NO --no-session-persistence, because the
    transcript is the evidence.

    The runs use --permission-mode acceptEdits --dangerously-skip-permissions,
    like scenario 06 (npm test and file writes, no human to approve). The
    blast radius is the throwaway workspace under -OutDir.

.PARAMETER RepoRoot
    specwright checkout. Default: the checkout this script lives in.

.PARAMETER Case
    feat04, feat03, feat04b, feat03b or all (default).

.PARAMETER BudgetUsd
    --max-budget-usd per claude -p session (default 4, same as scenario 06).
    "all" makes 10 sessions: 2 per single-turn case, 4 for feat03b.

.PARAMETER OutDir
    Where sandboxes, results and the evidence report go. Kept after the run.
    Credentials copied into it are deleted at the end unless -KeepCredentials.

.PARAMETER CopyCredentials
    Copy ~/.claude/.credentials.json into each fake home instead of using an
    auth env var. Risky: if the access token has expired, a sandbox run
    refreshes it, the server rotates the single-use refresh token, and your
    real CLI is logged out. Prefer CLAUDE_CODE_OAUTH_TOKEN.

.PARAMETER EvaluateOnly
    Do not build sandboxes or call claude. Re-read the transcripts already in
    -OutDir from an earlier run and re-apply the checks. Costs nothing.

.EXAMPLE
    .\tests\e2e\probe-model-override.ps1 -Case feat04

.EXAMPLE
    .\tests\e2e\probe-model-override.ps1 -Case feat04 -EvaluateOnly -OutDir C:\sw72-20260925-130826

.NOTES
    Exit 0 = every case matched its expectation (workflow-level Verdict A).
    Exit 1 = at least one case did not match (see report; possible Verdict B
             for the workflow even though the mechanism is A).
    Exit 2 = could not run (missing prerequisite, install failure, timeout).
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = (Join-Path $PSScriptRoot '..' '..'),
    [ValidateSet('feat04', 'feat03', 'feat04b', 'feat03b', 'all')]
    [string]$Case = 'all',
    [double]$BudgetUsd = 4,
    [int]$TimeoutSec = 1800,
    # Default is the drive root, NOT %TEMP%: on Windows %TEMP% is under the user
    # profile, and Claude Code loads .claude/ from ancestor directories - so the
    # real ~/.claude would be read as a PROJECT dir and shadow the sandbox.
    [string]$OutDir = (Join-Path ([System.IO.Path]::GetPathRoot([System.IO.Path]::GetTempPath())) ('sw72-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))),
    [switch]$KeepCredentials,
    [switch]$CopyCredentials,
    [switch]$EvaluateOnly
)

$ErrorActionPreference = 'Stop'

# ---- helpers -----------------------------------------------------------------

function Write-Info { param([string]$Msg) Write-Host "[INFO] $Msg" }
function Write-Ok   { param([string]$Msg) Write-Host "[OK]   $Msg" -ForegroundColor Green }
function Write-Bad  { param([string]$Msg) Write-Host "[FAIL] $Msg" -ForegroundColor Red }

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

# ---- preflight ---------------------------------------------------------------

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$pwshExe = (Get-Process -Id $PID).Path
$installPs1 = Join-Path $RepoRoot 'install' 'install.ps1'
$scenario06 = Join-Path $RepoRoot 'tests' 'e2e' 'scenarios' '06-escalation-implementer'
$fixture = Join-Path $RepoRoot 'examples' 'fixture-project'

foreach ($p in @($installPs1, $scenario06, $fixture)) {
    if ((Test-Path -LiteralPath $p) -eq $false) {
        Exit-CannotRun "not a specwright checkout (missing $p). Pass -RepoRoot."
    }
}
$hasCreds = $CopyCredentials -and (Test-Path -LiteralPath (Get-RealCredentialsPath))
$claudeVersion = 'n/a (EvaluateOnly)'
if ($EvaluateOnly -eq $false) {
    foreach ($cmd in @('claude', 'node', 'npm')) {
        if ($null -eq (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            Exit-CannotRun "'$cmd' not found on PATH."
        }
    }

    $claudeVersion = (& claude --version 2>$null | Out-String).Trim()
    Write-Info "claude CLI: $claudeVersion"

    if (((Test-EnvSet 'CLAUDE_CODE_OAUTH_TOKEN') -eq $false) -and ($hasCreds -eq $false) -and ((Test-EnvSet 'ANTHROPIC_API_KEY') -eq $false)) {
        Exit-CannotRun 'no claude auth: set CLAUDE_CODE_OAUTH_TOKEN (claude setup-token) or ANTHROPIC_API_KEY. -CopyCredentials also works but can log out your real CLI (see its help).'
    }
    if (Test-EnvSet 'ANTHROPIC_API_KEY') {
        Write-Host '[WARN] ANTHROPIC_API_KEY is set; claude -p prefers it, so these runs bill the API.' -ForegroundColor Yellow
    }
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path
Write-Info "output dir: $OutDir"

# Isolation guard. With no git root to stop it, Claude Code walks up from the
# workspace and loads every ancestor .claude/ (agents, skills) as project
# scope, which outranks the fake home's user scope. Verified on 2.1.282: an
# ancestor sd-implementer with model: sonnet shadowed the sandbox's haiku one.
$ancestor = Split-Path -Parent $OutDir
while ([string]::IsNullOrEmpty($ancestor) -eq $false) {
    if (Test-Path -LiteralPath (Join-Path $ancestor '.claude')) {
        Exit-CannotRun ("$ancestor\.claude exists above -OutDir; the sandbox would load it as a project dir " +
            'and stop being isolated. Pick an -OutDir with no .claude folder in any parent (e.g. D:\sw72).')
    }
    $next = Split-Path -Parent $ancestor
    if ($next -eq $ancestor) { break }
    $ancestor = $next
}

# ---- sandbox construction ----------------------------------------------------

function New-FakeHome {
    param([string]$RunDir)
    $fakeHome = Join-Path $RunDir 'home'
    $basePath = Join-Path $fakeHome '.claude'
    New-Item -ItemType Directory -Path $basePath -Force | Out-Null
    & $pwshExe -NoProfile -File $installPs1 -BasePath $basePath -Force *> (Join-Path $RunDir 'install.log')
    if ($LASTEXITCODE -ne 0) {
        Exit-CannotRun "engine install into $basePath failed (exit $LASTEXITCODE); see install.log"
    }
    if ($hasCreds) {
        Copy-Item -LiteralPath (Get-RealCredentialsPath) -Destination (Join-Path $basePath '.credentials.json') -Force
    }
    return $fakeHome
}

function Copy-TreeContents {
    param([string]$Source, [string]$Destination)
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Destination -Recurse -Force
    }
}

function New-Workspace {
    param([string]$RunDir, [scriptblock]$Mutate, $MutateArg)
    $ws = Join-Path $RunDir 'ws'
    New-Item -ItemType Directory -Path $ws -Force | Out-Null
    Copy-TreeContents -Source $fixture -Destination $ws
    Copy-TreeContents -Source (Join-Path $scenario06 'workspace') -Destination $ws
    if ($null -ne $Mutate) { & $Mutate $ws $MutateArg }
    return $ws
}

function Set-FileText {
    param([string]$Path, [string]$Pattern, [string]$Replacement)
    $text = Get-Content -LiteralPath $Path -Raw
    if (($text -match $Pattern) -eq $false) {
        Exit-CannotRun "fixture drifted: pattern '$Pattern' not found in $Path"
    }
    $text = [regex]::Replace($text, $Pattern, $Replacement)
    [System.IO.File]::WriteAllText($Path, $text, [System.Text.UTF8Encoding]::new($false))
}

# ---- claude invocation -------------------------------------------------------

function Get-StepFileName {
    param([string]$StepName, [string]$Kind)
    if ($StepName -eq 'result') {
        if ($Kind -eq 'json') { return 'result.json' } else { return 'stderr.txt' }
    }
    if ($Kind -eq 'json') { return "$StepName.result.json" } else { return "$StepName.stderr.txt" }
}

function Read-StepResult {
    param([string]$RunDir, [string]$StepName)
    $p = Join-Path $RunDir (Get-StepFileName $StepName 'json')
    if ((Test-Path -LiteralPath $p) -eq $false) { return $null }
    try { return (Get-Content -LiteralPath $p -Raw | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

function Invoke-ClaudeRun {
    # StepName 'result' keeps the single-turn file names (result.json, stderr.txt).
    param([string]$RunDir, [string]$FakeHome, [string]$Workspace, [string]$Prompt,
        [string]$StepName = 'result', [string]$Resume)

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    # Same resolution as tests/e2e/run-e2e.ps1 (a known-working invocation).
    $psi.FileName = 'claude'
    $cliArgs = @(
        '-p', $Prompt,
        '--output-format', 'json',
        '--setting-sources', 'project',
        '--add-dir', $FakeHome,
        '--max-budget-usd', $BudgetUsd.ToString([System.Globalization.CultureInfo]::InvariantCulture),
        '--permission-mode', 'acceptEdits',
        '--dangerously-skip-permissions'
    )
    if ([string]::IsNullOrEmpty($Resume) -eq $false) { $cliArgs += @('--resume', $Resume) }
    foreach ($a in $cliArgs) { $psi.ArgumentList.Add($a) }
    $psi.WorkingDirectory = $Workspace
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.EnvironmentVariables['HOME'] = $FakeHome
    $psi.EnvironmentVariables['USERPROFILE'] = $FakeHome
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
        Exit-CannotRun "claude -p timed out after $TimeoutSec s ($RunDir)"
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    [System.IO.File]::WriteAllText((Join-Path $RunDir (Get-StepFileName $StepName 'json')), $stdout)
    [System.IO.File]::WriteAllText((Join-Path $RunDir (Get-StepFileName $StepName 'stderr')), $stderr)

    $result = $null
    try { $result = $stdout | ConvertFrom-Json -ErrorAction Stop } catch { }
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Result = $result }
}

# ---- evidence extraction -----------------------------------------------------

function Get-SubagentEvidence {
    param([string]$FakeHome)
    $projects = Join-Path $FakeHome '.claude' 'projects'
    if ((Test-Path -LiteralPath $projects) -eq $false) { return @() }

    $rows = @()
    $metas = Get-ChildItem -LiteralPath $projects -Recurse -Filter '*.meta.json' |
        Where-Object { $_.Directory.Name -eq 'subagents' }
    foreach ($meta in $metas) {
        $m = Get-Content -LiteralPath $meta.FullName -Raw | ConvertFrom-Json
        $jsonl = $meta.FullName -replace '\.meta\.json$', '.jsonl'
        $served = @()
        if (Test-Path -LiteralPath $jsonl) {
            foreach ($line in [System.IO.File]::ReadLines($jsonl)) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $o = $null
                try { $o = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
                # '<synthetic>' marks a CLI-generated turn (no API call), not a served model.
                if (($o.type -eq 'assistant') -and ($null -ne $o.message) -and ($null -ne $o.message.model) -and ($o.message.model -ne '<synthetic>')) {
                    $served += [string]$o.message.model
                }
            }
        }
        # '' = the main thread passed no model parameter (key absent or null).
        $requested = ''
        if (($m.PSObject.Properties.Name -contains 'model') -and ($null -ne $m.model)) { $requested = [string]$m.model }
        $rows += [pscustomobject]@{
            AgentType   = [string]$m.agentType
            Description = [string]$m.description
            Requested   = $requested
            Served      = (($served | Select-Object -Unique) -join ',')
            Transcript  = [System.IO.Path]::GetRelativePath($FakeHome, $jsonl)
        }
    }
    return $rows
}

function Test-Row {
    # Does any row for AgentType carry a model param in $Requested ('' = none)
    # and serve only a model matching $ServedLike?
    param($Rows, [string]$AgentType, [string[]]$Requested, [string]$ServedLike)
    $hit = $Rows | Where-Object {
        ($_.AgentType -eq $AgentType) -and
        ($Requested -contains $_.Requested) -and
        ($_.Served -like $ServedLike) -and
        (($_.Served -split ',').Count -eq 1)
    }
    return ($null -ne $hit)
}

function Test-NoEscalation {
    # At least one row for AgentType, and every one of them carries a model
    # param in $Requested ('' = none, or the default alias passed explicitly)
    # and serves only a model matching $ServedLike.
    param($Rows, [string]$AgentType, [string[]]$Requested, [string]$ServedLike)
    $mine = @($Rows | Where-Object { $_.AgentType -eq $AgentType })
    if ($mine.Count -eq 0) { return $false }
    $bad = $mine | Where-Object {
        (($Requested -contains $_.Requested) -eq $false) -or
        (($_.Served -like $ServedLike) -eq $false) -or
        (($_.Served -split ',').Count -ne 1)
    }
    return ($null -eq $bad)
}

# ---- case definitions --------------------------------------------------------

$specRel = Join-Path '.specs' 'FEAT-e2e-escalation-demo'
$feat04Prompt = Get-Content -LiteralPath (Join-Path $scenario06 'prompt.txt') -Raw

$feat03Prompt = @'
/sd:feature e2e-escalation-demo

FEAT-e2e-escalation-demo is a synthetic fixture spec seeded by this test. It is in `draft`
status. Its `complexity` frontmatter value was set by the fixture author on purpose; use it
exactly as written and do not edit it.

This is a headless, scripted test run with no human available to reply mid-workflow. Do not stop
and wait for a real person. At Gate 1 (spec approval), present the gate as instructed, then treat
"yes" as the standing reply and continue immediately within this single turn.

Run Phase 2 and Phase 3 exactly as written, including each phase's step 0 model escalation
check. Stop as soon as Gate 2 has been presented, whichever face it shows. Do not answer Gate 2,
do not re-invoke Phase 3, and do not start Phase 4. Report which subagents ran and at which model
in your last message.
'@

$feat03Mutate = {
    param($ws, $complexity)
    $dir = Join-Path $ws $specRel
    foreach ($f in @('01-plan.md', '02-tasks.md', '03-decisions.md', '05-retro.md')) {
        $p = Join-Path $dir $f
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
    $spec = Join-Path $dir '00-spec.md'
    Set-FileText -Path $spec -Pattern '(?m)^status: in-progress\s*$' -Replacement 'status: draft'
    Set-FileText -Path $spec -Pattern '(?m)^complexity: .*$' -Replacement "complexity: $complexity"
    Set-FileText -Path (Join-Path $ws '.specs' 'index.md') `
        -Pattern '(\| FEAT-e2e-escalation-demo \| feature \| )in-progress' -Replacement '${1}draft'
    Set-FileText -Path (Join-Path $ws '.claude' 'project-config.json') `
        -Pattern '"ceiling":\s*"sonnet"' -Replacement '"ceiling": "opus"'
}

$t01ToS = {
    param($ws)
    Set-FileText -Path (Join-Path $ws $specRel '02-tasks.md') `
        -Pattern '(?m)^- \*\*Estimated complexity\*\*: L\s*$' -Replacement '- **Estimated complexity**: S'
}

# T01 at S and Reversibility hard; T02 keeps its trivial. The pattern is
# scoped to the T01 block by the lazy match up to the first Reversibility line.
$t01Hard = {
    param($ws)
    & $t01ToS $ws
    Set-FileText -Path (Join-Path $ws $specRel '02-tasks.md') `
        -Pattern '(?s)(### T01 .*?- \*\*Reversibility\*\*: )trivial' -Replacement '${1}hard'
}

# feat03b: one cohesive feature that must touch all three production layers of
# the fixture (domain, infrastructure, application), so the plan crosses Gate 2's
# "spans > 2 production layers" threshold whatever the architect's discretion.
$feat03bSpec = @'
---
id: FEAT-e2e-escalation-demo
type: feature
status: in-progress
jira: none
created: 2026-09-27
complexity: S # replaced by the probe
linked_specs: []
---

# E2E no-split escalation demo spec

## Why

Seeded fixture spec for tests/e2e/probe-model-override.ps1 case feat03b (SW-76). Users need to
see which todos are overdue. The change is one cohesive feature, but it has to cross every
production layer of the fixture.

## What

### SC-1: a todo carries an optional due date

- **Given** a caller creating a todo with `dueDate` set to an ISO date string
- **When** the domain factory `createTodo` in `src/domain/todo.js` validates it
- **Then** the todo keeps `dueDate`, and an unparseable value throws `InvalidDueDateError`

### SC-2: the store answers a due-before query

- **Given** an `InMemoryStore` (`src/infrastructure/store.js`) holding todos with and without
  due dates
- **When** a caller calls `listDueBefore(date)`
- **Then** it returns only the todos whose `dueDate` is before `date`, oldest first

### SC-3: the service sets due dates and lists overdue todos

- **Given** a `TodoService` (`src/application/todo-service.js`)
- **When** a caller calls `setDueDate(id, date)` and then `listOverdue(now)`
- **Then** `listOverdue` returns the open (not done) todos due before `now`, through the store query

## Success criteria

- [ ] AC-1: `createTodo` accepts and validates `dueDate` (domain layer).
- [ ] AC-2: `InMemoryStore.listDueBefore(date)` exists and is tested (infrastructure layer).
- [ ] AC-3: `TodoService.setDueDate` and `TodoService.listOverdue` exist and are tested
  (application layer).

## Out of scope

- Time zones, recurring due dates, reminders.

## Constitution check

- Section 1.1 (dependency direction): domain knows nothing of the store; the service reads only
  through the injected store.
'@

$feat03bMutate = {
    param($ws)
    $spec = Join-Path $ws $specRel '00-spec.md'
    [System.IO.File]::WriteAllText($spec, $feat03bSpec, [System.Text.UTF8Encoding]::new($false))
    & $feat03Mutate $ws 'M'
}

$feat03bFraming = @'


This is a headless, scripted test run with no human available to reply mid-workflow. The line
above is the reply to Gate 2. Apply that branch of Gate 2 exactly as written in /sd:feature,
including any model escalation rule it names. Do not stop and wait for a real person.
'@

$feat03bRunTurn2 = 'no-split this is one cohesive due-date feature; the three layers change together' + $feat03bFraming + @'

If that branch re-invokes Phase 3 and the new plan shows Gate 2 again, stop there. Stop before
Phase 4: do not implement any task. Report which subagents ran and at which model in your last
message.
'@

$feat03bCtlTurn2 = 'approve split' + $feat03bFraming + @'

Stop once the child specs are created, registered and linked. Do not run /sd:feature on any
child. Report which subagents ran and at which model in your last message.
'@

# Face B's option set (commands/feature.md Gate 2) is the only place 'no-split'
# is offered, so seeing it in turn 1's last message means Face B was presented.
$faceBShown = {
    param($result)
    return (($null -ne $result) -and ([string]$result.result -match 'no-split'))
}

$cases = @(
    [pscustomobject]@{
        Name = 'feat04'; Rules = 'ESC-FEAT-04'; Prompt = $feat04Prompt
        RunMutate = $null; RunArg = $null; CtlArg = $null
        CtlMutate = $t01ToS
        Turn2 = $null; CtlTurn2 = $null; Precondition = $null
        RunCheck = {
            param($rows)
            @(
                @{ Name = 'sd-implementer model=sonnet served sonnet'; Pass = (Test-Row $rows 'sd-implementer' @('sonnet') 'claude-sonnet*') },
                @{ Name = 'sd-implementer (model none or haiku) served haiku'; Pass = (Test-Row $rows 'sd-implementer' @('', 'haiku') 'claude-haiku*') }
            )
        }
        CtlCheck = {
            param($rows)
            @(
                @{ Name = 'every sd-implementer: model none or haiku, served haiku'; Pass = (Test-NoEscalation $rows 'sd-implementer' @('', 'haiku') 'claude-haiku*') }
            )
        }
    },
    [pscustomobject]@{
        Name = 'feat03'; Rules = 'ESC-FEAT-02, ESC-FEAT-03'; Prompt = $feat03Prompt
        RunMutate = $feat03Mutate; RunArg = 'L'
        CtlMutate = $feat03Mutate; CtlArg = 'M'
        Turn2 = $null; CtlTurn2 = $null; Precondition = $null
        RunCheck = {
            param($rows)
            @(
                @{ Name = 'sd-code-explorer model=sonnet served sonnet'; Pass = (Test-Row $rows 'sd-code-explorer' @('sonnet') 'claude-sonnet*') },
                @{ Name = 'sd-spec-architect model=opus served opus';    Pass = (Test-Row $rows 'sd-spec-architect' @('opus') 'claude-opus*') }
            )
        }
        CtlCheck = {
            param($rows)
            @(
                @{ Name = 'every sd-code-explorer: model none or haiku, served haiku';    Pass = (Test-NoEscalation $rows 'sd-code-explorer' @('', 'haiku') 'claude-haiku*') },
                @{ Name = 'every sd-spec-architect: model none or sonnet, served sonnet'; Pass = (Test-NoEscalation $rows 'sd-spec-architect' @('', 'sonnet') 'claude-sonnet*') }
            )
        }
    },
    [pscustomobject]@{
        Name = 'feat04b'; Rules = 'ESC-FEAT-04b'; Prompt = $feat04Prompt
        RunMutate = $t01Hard; RunArg = $null
        CtlMutate = $t01ToS; CtlArg = $null
        Turn2 = $null; CtlTurn2 = $null; Precondition = $null
        RunCheck = {
            param($rows)
            @(
                @{ Name = 'sd-implementer model=sonnet served sonnet (T01, hard)'; Pass = (Test-Row $rows 'sd-implementer' @('sonnet') 'claude-sonnet*') },
                @{ Name = 'sd-implementer (model none or haiku) served haiku (T02)'; Pass = (Test-Row $rows 'sd-implementer' @('', 'haiku') 'claude-haiku*') }
            )
        }
        CtlCheck = {
            param($rows)
            @(
                @{ Name = 'every sd-implementer: model none or haiku, served haiku'; Pass = (Test-NoEscalation $rows 'sd-implementer' @('', 'haiku') 'claude-haiku*') }
            )
        }
    },
    [pscustomobject]@{
        Name = 'feat03b'; Rules = 'ESC-FEAT-03b'; Prompt = $feat03Prompt
        RunMutate = $feat03bMutate; RunArg = $null
        CtlMutate = $feat03bMutate; CtlArg = $null
        Turn2 = $feat03bRunTurn2; CtlTurn2 = $feat03bCtlTurn2; Precondition = $faceBShown
        RunCheck = {
            param($rows)
            @(
                @{ Name = 'sd-spec-architect (model none or sonnet) served sonnet (turn-1 plan)'; Pass = (Test-Row $rows 'sd-spec-architect' @('', 'sonnet') 'claude-sonnet*') },
                @{ Name = 'sd-spec-architect model=opus served opus (no-split re-plan)'; Pass = (Test-Row $rows 'sd-spec-architect' @('opus') 'claude-opus*') }
            )
        }
        CtlCheck = {
            param($rows)
            @(
                @{ Name = 'every sd-spec-architect: model none or sonnet, served sonnet'; Pass = (Test-NoEscalation $rows 'sd-spec-architect' @('', 'sonnet') 'claude-sonnet*') }
            )
        }
    }
)
if ($Case -ne 'all') { $cases = @($cases | Where-Object { $_.Name -eq $Case }) }

# ---- run ---------------------------------------------------------------------

$report = [System.Text.StringBuilder]::new()
[void]$report.AppendLine("# SW-72 workflow-level model override probe")
[void]$report.AppendLine('')
[void]$report.AppendLine("- Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
[void]$report.AppendLine("- Claude Code: $claudeVersion")
[void]$report.AppendLine("- specwright commit: $((& git -C $RepoRoot rev-parse --short HEAD 2>$null) -join '')")
[void]$report.AppendLine("- OS: $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)")
[void]$report.AppendLine('')

$allPass = $true
foreach ($c in $cases) {
    foreach ($variant in @('run', 'control')) {
        $runName = "$($c.Name)-$variant"
        $runDir = Join-Path $OutDir $runName
        New-Item -ItemType Directory -Path $runDir -Force | Out-Null
        $fakeHome = Join-Path $runDir 'home'
        $ws = Join-Path $runDir 'ws'
        if ($EvaluateOnly) {
            if ((Test-Path -LiteralPath $fakeHome) -eq $false) {
                Exit-CannotRun "-EvaluateOnly: no earlier run at $runDir"
            }
            Write-Info "$runName : re-evaluating existing transcripts"
            $r = [pscustomobject]@{ ExitCode = 'n/a (EvaluateOnly)'; Result = (Read-StepResult -RunDir $runDir -StepName 'result') }
            $r2 = $null
            if ($null -ne $c.Turn2) {
                $prior2 = Read-StepResult -RunDir $runDir -StepName 'turn2'
                if ($null -ne $prior2) { $r2 = [pscustomobject]@{ ExitCode = 'n/a (EvaluateOnly)'; Result = $prior2 } }
            }
        }
        else {
            Write-Info "$runName : building sandbox"
            $fakeHome = New-FakeHome -RunDir $runDir
            $mutate = if ($variant -eq 'run') { $c.RunMutate } else { $c.CtlMutate }
            $mutateArg = if ($variant -eq 'run') { $c.RunArg } else { $c.CtlArg }
            $ws = New-Workspace -RunDir $runDir -Mutate $mutate -MutateArg $mutateArg

            Write-Info "$runName : running claude -p (budget $BudgetUsd USD, timeout $TimeoutSec s)"
            $r = Invoke-ClaudeRun -RunDir $runDir -FakeHome $fakeHome -Workspace $ws -Prompt $c.Prompt
            $r2 = $null
            $turn2 = if ($variant -eq 'run') { $c.Turn2 } else { $c.CtlTurn2 }
            if (($null -ne $turn2) -and (& $c.Precondition $r.Result)) {
                $sid = [string]$r.Result.session_id
                Write-Info "$runName : resuming session $sid for turn 2"
                $r2 = Invoke-ClaudeRun -RunDir $runDir -FakeHome $fakeHome -Workspace $ws -Prompt $turn2 -StepName 'turn2' -Resume $sid
            }
        }
        $rows = @(Get-SubagentEvidence -FakeHome $fakeHome)

        $checks = if ($variant -eq 'run') { & $c.RunCheck $rows } else { & $c.CtlCheck $rows }
        if ($null -ne $c.Precondition) {
            # A failed precondition means the rule's trigger was never reached:
            # inconclusive, not evidence against the rule (Verdict B).
            $pre = @{ Name = 'precondition: Gate 2 showed Face B and turn 2 ran (else inconclusive, not Verdict B)'; Pass = ((& $c.Precondition $r.Result) -and ($null -ne $r2)) }
            $checks = @($pre) + @($checks)
        }

        [void]$report.AppendLine("## $runName ($($c.Rules))")
        [void]$report.AppendLine('')
        $isError = if ($null -ne $r.Result) { $r.Result.is_error } else { 'n/a (no JSON result)' }
        $cost = if ($null -ne $r.Result) { $r.Result.total_cost_usd } else { 'n/a' }
        [void]$report.AppendLine("- claude exit: $($r.ExitCode); is_error: $isError; cost USD: $cost")
        if (($null -ne $r.Result) -and ($null -ne $r.Result.modelUsage)) {
            $usage = ($r.Result.modelUsage.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value.outputTokens)" }) -join ', '
            [void]$report.AppendLine("- modelUsage output tokens (second-best evidence): $usage")
        }
        if (($null -ne $r2) -and ($null -ne $r2.Result)) {
            [void]$report.AppendLine("- turn 2 (--resume): claude exit: $($r2.ExitCode); is_error: $($r2.Result.is_error); cost USD: $($r2.Result.total_cost_usd)")
        }
        $retro = Join-Path $ws $specRel '05-retro.md'
        if (Test-Path -LiteralPath $retro) {
            $escLines = @(Select-String -LiteralPath $retro -Pattern 'escalation: sd-' | ForEach-Object { $_.Line.Trim() })
            [void]$report.AppendLine("- retro escalation lines (self-report, context only): $(if ($escLines.Count -gt 0) { $escLines -join ' | ' } else { 'none' })")
        }
        [void]$report.AppendLine('')
        [void]$report.AppendLine('| agentType | description | model param | served (message.model) | transcript (relative to fake home) |')
        [void]$report.AppendLine('|---|---|---|---|---|')
        foreach ($row in $rows) {
            $req = if ([string]::IsNullOrEmpty($row.Requested)) { '(none)' } else { $row.Requested }
            [void]$report.AppendLine("| $($row.AgentType) | $($row.Description) | $req | $($row.Served) | ``$($row.Transcript)`` |")
        }
        if ($rows.Count -eq 0) { [void]$report.AppendLine('| (no subagent transcripts found) | | | | |') }
        [void]$report.AppendLine('')

        foreach ($chk in $checks) {
            if ($chk.Pass) {
                Write-Ok "$runName : $($chk.Name)"
                [void]$report.AppendLine("- [OK] $($chk.Name)")
            }
            else {
                Write-Bad "$runName : $($chk.Name)"
                foreach ($row in $rows) {
                    $req = if ([string]::IsNullOrEmpty($row.Requested)) { '(none)' } else { $row.Requested }
                    Write-Host "       $($row.AgentType) | model param: $req | served: $($row.Served) | $($row.Description)"
                }
                if ($rows.Count -eq 0) { Write-Host '       (no subagent transcripts found - did the run reach the phase? see result.json)' }
                [void]$report.AppendLine("- [FAIL] $($chk.Name)")
                $allPass = $false
            }
        }
        [void]$report.AppendLine('')

        if ($KeepCredentials -eq $false) {
            $creds = Join-Path $fakeHome '.claude' '.credentials.json'
            if (Test-Path -LiteralPath $creds) { Remove-Item -LiteralPath $creds -Force }
        }
    }
}

$verdict = if ($allPass) {
    'Workflow-level Verdict A: every escalated call carried the model parameter and was served on that tier; every control call carried none.'
}
else {
    'NOT confirmed: at least one expectation failed. If a run shows the rule firing in the retro but no model param in meta.json, that is workflow-level Verdict B (fix the prompt text, not the mechanism). Check result.json / stderr.txt first for a run that simply did not reach the phase.'
}
[void]$report.AppendLine("## Verdict")
[void]$report.AppendLine('')
[void]$report.AppendLine($verdict)

# -EvaluateOnly writes beside the live report, never over it: the live one holds
# the claude version and exit codes that a re-evaluation cannot recover.
$reportName = if ($EvaluateOnly) { 'sw72-report.evaluate.md' } else { 'sw72-report.md' }
$reportPath = Join-Path $OutDir $reportName
[System.IO.File]::WriteAllText($reportPath, $report.ToString(), [System.Text.UTF8Encoding]::new($false))
Write-Host ''
Write-Info "report: $reportPath"
if ($allPass) { Write-Ok $verdict; exit 0 } else { Write-Bad $verdict; exit 1 }
