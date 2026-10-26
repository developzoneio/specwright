#requires -Version 5.1
<#
.SYNOPSIS
    specwright: hook smoke test (Windows / PowerShell).

.DESCRIPTION
    Pipes sample Claude Code hook JSON into hooks/powershell/*.ps1 against a
    fixture .specs/ tree and asserts exit codes + key output substrings - not
    just "did not crash". Mirror of scripts/smoke-hooks.sh (runs the bash hook
    twins). Both must agree on the routed workflow for prompt-router.

    Exit code 0 = all cases passed; 1 = at least one failed.

.NOTES
    PURE ASCII ONLY. See hooks/powershell/prompt-router.ps1 for the rationale.

.EXAMPLE
    .\scripts\smoke-hooks.ps1
#>

param()

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$repoRoot  = Split-Path -Parent $scriptDir

$script:Pass = 0
$script:Fail = 0

function Write-Section { param([string]$Title) Write-Host ''; Write-Host "=== $Title ===" -ForegroundColor Cyan }
function Add-Ok  { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green; $script:Pass++ }
function Add-Bad { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:Fail++ }

function Assert-Exit0 {
    param([string]$Desc, [int]$Code)
    if ($Code -eq 0) { Add-Ok "$Desc : exit 0" } else { Add-Bad "$Desc : exit $Code (expected 0)" }
}

function Assert-Contains {
    param([string]$Desc, [string]$Haystack, [string]$Needle)
    if ($Haystack -and $Haystack.Contains($Needle)) {
        Add-Ok "$Desc : contains `"$Needle`""
    } else {
        $preview = if ($Haystack) { $Haystack.Substring(0, [Math]::Min(200, $Haystack.Length)) } else { '' }
        Add-Bad "$Desc : missing `"$Needle`" -- got: $preview"
    }
}

function Assert-Empty {
    param([string]$Desc, [string]$Haystack)
    if ([string]::IsNullOrEmpty($Haystack)) {
        Add-Ok "$Desc : empty output"
    } else {
        Add-Bad "$Desc : expected empty, got: $($Haystack.Substring(0, [Math]::Min(200, $Haystack.Length)))"
    }
}

# ---- fixture repo ------------------------------------------------------------

$fixture = Join-Path $env:TEMP "sd-smoke-hooks-$PID"
if (Test-Path -LiteralPath $fixture) { Remove-Item -Recurse -Force $fixture }
New-Item -ItemType Directory -Force -Path (Join-Path $fixture '.claude') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $fixture '.specs\FEAT-TEST-001') | Out-Null

$configPath = Join-Path $fixture '.claude\project-config.json'
$configBlockJson = @'
{
  "spec": {"dir": ".specs", "indexFile": ".specs/index.md"},
  "ticket": {"pattern": "^[A-Z]+-[0-9]+$"},
  "workflow": {
    "keywords": {
      "bug": ["bug", "fix", "broken", "error", "crash", "regression", "defect"],
      "feature": ["feature", "add", "implement", "new", "support"],
      "refactor": ["refactor", "restructure", "clean up", "extract", "rename"],
      "perf": ["perf", "performance", "slow", "optimize", "latency", "throughput"],
      "rca": ["incident", "outage", "rca", "root cause", "post-mortem", "postmortem"]
    }
  },
  "hooks": {
    "userPromptRouter": {"enabled": true},
    "specGate": {"enabled": true, "mode": "block"},
    "subagentRetro": {"enabled": true, "retroStaleMinutes": 0, "debounceMinutes": 10}
  }
}
'@
Set-Content -LiteralPath $configPath -Value $configBlockJson -Encoding UTF8 -NoNewline

$indexRealPath = Join-Path $fixture '.specs\index.md'
$indexRealContent = @'
| ID | Type | Status | Title |
|---|---|---|---|
| FEAT-TEST-001 | feature | in-progress | Test feature |
'@
Set-Content -LiteralPath $indexRealPath -Value $indexRealContent -Encoding UTF8 -NoNewline

# "in-progress" appears only in a header/legend line - no row has it on the
# same line as a spec ID (mirrors the doc-02 same-line-detection fix).
$indexHeaderOnlyContent = @'
| ID | Type | Status (in-progress = active work) | Title |
|---|---|---|---|
| FEAT-DONE-002 | feature | done | Finished feature |
'@

function Invoke-Hook {
    # Runs a hook .ps1 with $Payload on stdin. Sets script-scope Stdout/Stderr/Code.
    param([string]$HookPath, [string]$Payload)
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $psExe = (Get-Process -Id $PID).Path
        $Payload | & $psExe -NoProfile -File $HookPath 1>$outFile 2>$errFile
        $script:Code = $LASTEXITCODE
        $script:Stdout = (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
        $script:Stderr = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
        if ($null -eq $script:Stdout) { $script:Stdout = '' }
        if ($null -eq $script:Stderr) { $script:Stderr = '' }
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -ErrorAction SilentlyContinue
    }
}

# ---- prompt-router: keyword match --------------------------------------------

Write-Section 'prompt-router (PowerShell): keyword match routes to /sd:bug'
$payload = "{`"prompt`":`"please fix this bug`",`"cwd`":`"$($fixture -replace '\\','\\\\')`"}"
Invoke-Hook (Join-Path $repoRoot 'hooks\powershell\prompt-router.ps1') $payload
Assert-Exit0 'prompt-router keyword match' $script:Code
Assert-Contains 'prompt-router keyword match' $script:Stdout '<context-router>'
Assert-Contains 'prompt-router keyword match' $script:Stdout '/sd:bug'

# ---- session-context: in-progress spec surfaced at session start ------------

Write-Section 'session-context (PowerShell): startup surfaces the in-progress spec'
$payload = "{`"source`":`"startup`",`"cwd`":`"$($fixture -replace '\\','\\\\')`"}"
Invoke-Hook (Join-Path $repoRoot 'hooks\powershell\session-context.ps1') $payload
Assert-Exit0 'session-context startup' $script:Code
Assert-Contains 'session-context startup' $script:Stdout '<session-context>'
Assert-Contains 'session-context startup' $script:Stdout 'FEAT-TEST-001'

# ---- spec-gate: (a) code edit with in-progress spec -> allow ----------------

Write-Section 'spec-gate (PowerShell): (a) code edit with in-progress spec -> allow'
$fixtureEsc = $fixture -replace '\\', '\\\\'
$payload = "{`"tool_name`":`"Edit`",`"cwd`":`"$fixtureEsc`",`"tool_input`":{`"file_path`":`"$fixtureEsc\\\\src\\\\Foo.py`"}}"
Invoke-Hook (Join-Path $repoRoot 'hooks\powershell\spec-gate.ps1') $payload
Assert-Exit0 'spec-gate (a) in-progress -> allow' $script:Code
Assert-Empty 'spec-gate (a) in-progress -> allow' $script:Stdout

# ---- spec-gate: (b) header-only "in-progress" -> block/warn, not allow ------

Write-Section 'spec-gate (PowerShell): (b) header-only in-progress text -> block (mode=block)'
Set-Content -LiteralPath $indexRealPath -Value $indexHeaderOnlyContent -Encoding UTF8 -NoNewline
$payload = "{`"tool_name`":`"Edit`",`"cwd`":`"$fixtureEsc`",`"tool_input`":{`"file_path`":`"$fixtureEsc\\\\src\\\\Bar.py`"}}"
Invoke-Hook (Join-Path $repoRoot 'hooks\powershell\spec-gate.ps1') $payload
Assert-Exit0 'spec-gate (b) header-only, mode=block' $script:Code
Assert-Contains 'spec-gate (b) header-only, mode=block' $script:Stdout '"decision":"block"'
Assert-Contains 'spec-gate (b) header-only, mode=block' $script:Stdout '"permissionDecision":"deny"'
Assert-Contains 'spec-gate (b) header-only, mode=block' $script:Stdout '"hookEventName":"PreToolUse"'

Write-Section 'spec-gate (PowerShell): (b) header-only in-progress text -> warn (mode=warn)'
(Get-Content -LiteralPath $configPath -Raw) -replace '"mode": "block"', '"mode": "warn"' |
    Set-Content -LiteralPath $configPath -Encoding UTF8 -NoNewline
Invoke-Hook (Join-Path $repoRoot 'hooks\powershell\spec-gate.ps1') $payload
Assert-Exit0 'spec-gate (b) header-only, mode=warn' $script:Code
Assert-Empty 'spec-gate (b) header-only, mode=warn stdout' $script:Stdout
Assert-Contains 'spec-gate (b) header-only, mode=warn stderr' $script:Stderr '[WARN]'
(Get-Content -LiteralPath $configPath -Raw) -replace '"mode": "warn"', '"mode": "block"' |
    Set-Content -LiteralPath $configPath -Encoding UTF8 -NoNewline
Set-Content -LiteralPath $indexRealPath -Value $indexRealContent -Encoding UTF8 -NoNewline

# ---- spec-gate: (c) docs edit -> always allow --------------------------------

Write-Section 'spec-gate (PowerShell): (c) docs edit -> allow regardless of spec state'
$payload = "{`"tool_name`":`"Edit`",`"cwd`":`"$fixtureEsc`",`"tool_input`":{`"file_path`":`"$fixtureEsc\\\\docs\\\\guide.md`"}}"
Invoke-Hook (Join-Path $repoRoot 'hooks\powershell\spec-gate.ps1') $payload
Assert-Exit0 'spec-gate (c) docs edit -> allow' $script:Code
Assert-Empty 'spec-gate (c) docs edit -> allow' $script:Stdout

# ---- spec-gate: (d) malformed JSON on stdin -> exit 0 silently --------------

Write-Section 'spec-gate (PowerShell): (d) malformed JSON on stdin -> exit 0 silently'
Invoke-Hook (Join-Path $repoRoot 'hooks\powershell\spec-gate.ps1') '{not valid json'
Assert-Exit0 'spec-gate (d) malformed JSON' $script:Code
Assert-Empty 'spec-gate (d) malformed JSON' $script:Stdout

# ---- spec-gate: (e)/(f) archived parent + registered child -> complexity split (SW-31) ----
# Same pending index.md content in both cases - only paths.protected differs.
# (e) proves the split is recorded when the edit is actually ALLOWED through.
# (f) proves it is NOT recorded when the SAME edit is denied (index.md
# protected, the default) - nothing reached disk, so no split happened.

$splitFixture = Join-Path $env:TEMP "sd-smoke-hooks-split-$PID"
if (Test-Path -LiteralPath $splitFixture) { Remove-Item -Recurse -Force $splitFixture }
New-Item -ItemType Directory -Force -Path (Join-Path $splitFixture '.specs') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $splitFixture '.claude') | Out-Null
$splitIndexContent = @'
| ID | Type | Status | Created | Title |
|---|---|---|---|---|
| FEAT-big | feature | in-progress | 2026-08-01 | Big oversized thing |
| FEAT-big-partA | feature | draft | 2026-08-09 | Part A |
'@
Set-Content -LiteralPath (Join-Path $splitFixture '.specs\index.md') -Value $splitIndexContent -Encoding UTF8 -NoNewline
$splitNewContent = @'
| ID | Type | Status | Created | Title |
|---|---|---|---|---|
| FEAT-big | feature | archived | 2026-08-01 | Big oversized thing |
| FEAT-big-partA | feature | draft | 2026-08-09 | Part A |
'@
$splitPayload = [pscustomobject]@{
    tool_name  = 'Write'
    cwd        = $splitFixture
    tool_input = [pscustomobject]@{ file_path = '.specs/index.md'; content = $splitNewContent }
} | ConvertTo-Json -Compress -Depth 5
$splitConfigPath = Join-Path $splitFixture '.claude\project-config.json'
$splitEventsPath = Join-Path $splitFixture '.specs\_metrics\events.jsonl'

Write-Section 'spec-gate (PowerShell): (e) allowed edit with archived parent + registered child -> complexity split metric'
Set-Content -LiteralPath $splitConfigPath -Value '{"spec":{"dir":".specs","indexFile":".specs/index.md"},"paths":{"protected":[]}}' -Encoding UTF8 -NoNewline
Invoke-Hook (Join-Path $repoRoot 'hooks\powershell\spec-gate.ps1') $splitPayload
Assert-Exit0 'spec-gate (e) complexity split, allowed' $script:Code
$splitEvents = Get-Content -LiteralPath $splitEventsPath -Raw -ErrorAction SilentlyContinue
if ($null -eq $splitEvents) { $splitEvents = '' }
Assert-Contains 'spec-gate (e) complexity split, allowed' $splitEvents '"gate":"complexity","decision":"split"'
Assert-Contains 'spec-gate (e) complexity split, allowed' $splitEvents '"spec_id":"FEAT-big"'

Write-Section 'spec-gate (PowerShell): (f) blocked edit (default protected index.md) -> no complexity split metric'
Remove-Item -LiteralPath $splitEventsPath -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $splitConfigPath -ErrorAction SilentlyContinue
Invoke-Hook (Join-Path $repoRoot 'hooks\powershell\spec-gate.ps1') $splitPayload
Assert-Exit0 'spec-gate (f) complexity split, blocked' $script:Code
Assert-Contains 'spec-gate (f) complexity split, blocked' $script:Stdout '"decision":"block"'
$splitEventsBlocked = Get-Content -LiteralPath $splitEventsPath -Raw -ErrorAction SilentlyContinue
if ($null -eq $splitEventsBlocked) { $splitEventsBlocked = '' }
if ($splitEventsBlocked.Contains('"gate":"complexity"')) {
    Add-Bad 'spec-gate (f) complexity split, blocked : split metric wrongly recorded for a denied edit'
} else {
    Add-Ok 'spec-gate (f) complexity split, blocked : no split metric recorded'
}

Remove-Item -Recurse -Force $splitFixture -ErrorAction SilentlyContinue

# ---- subagent-retro: missing retro names the spec, then debounces ----------

Write-Section 'subagent-retro (PowerShell): missing 05-retro.md names the real spec ID'
$payload = "{`"cwd`":`"$fixtureEsc`",`"session_id`":`"smoke-test-session`"}"
Invoke-Hook (Join-Path $repoRoot 'hooks\powershell\subagent-retro.ps1') $payload
Assert-Exit0 'subagent-retro first run' $script:Code
Assert-Contains 'subagent-retro first run' $script:Stdout '<retro-reminder>'
Assert-Contains 'subagent-retro first run' $script:Stdout 'FEAT-TEST-001'

Write-Section 'subagent-retro (PowerShell): second run within debounce window is silent'
Invoke-Hook (Join-Path $repoRoot 'hooks\powershell\subagent-retro.ps1') $payload
Assert-Exit0 'subagent-retro second run (debounced)' $script:Code
Assert-Empty 'subagent-retro second run (debounced)' $script:Stdout

# ---- precompact-state -> session-context: state survives a compaction -------

Write-Section 'precompact-state (PowerShell): records the spec named in the transcript'
Set-Content -LiteralPath (Join-Path $fixture '.specs\FEAT-TEST-001\00-spec.md') -Encoding UTF8 -NoNewline `
    -Value "---`nid: FEAT-TEST-001`ntype: feature`nstatus: in-progress`n---`n"
$transcript = Join-Path $fixture 'transcript.jsonl'
Set-Content -LiteralPath $transcript -Encoding UTF8 -NoNewline `
    -Value '{"type":"user","message":{"content":"resume FEAT-TEST-001"}}'
$payload = "{`"session_id`":`"smoke-compact`",`"trigger`":`"manual`",`"cwd`":`"$fixtureEsc`",`"transcript_path`":`"$($transcript -replace '\\','\\\\')`"}"
Invoke-Hook (Join-Path $repoRoot 'hooks\powershell\precompact-state.ps1') $payload
Assert-Exit0 'precompact-state manual' $script:Code
Assert-Empty 'precompact-state manual' $script:Stdout
$pointer = Join-Path $fixture '.claude\.hookstate\precompact-smoke-compact.json'
if ((Test-Path -LiteralPath $pointer) -and ((Get-Content -LiteralPath $pointer -Raw) -match 'FEAT-TEST-001')) {
    Add-Ok 'precompact-state manual: pointer names FEAT-TEST-001'
} else {
    Add-Bad 'precompact-state manual: pointer missing or wrong'
}

Write-Section 'session-context (PowerShell): compact re-injects the active spec'
$payload = "{`"session_id`":`"smoke-compact`",`"source`":`"compact`",`"cwd`":`"$fixtureEsc`"}"
Invoke-Hook (Join-Path $repoRoot 'hooks\powershell\session-context.ps1') $payload
Assert-Exit0 'session-context compact' $script:Code
Assert-Contains 'session-context compact' $script:Stdout 'Active spec before compaction (trigger: manual): FEAT-TEST-001'
Assert-Contains 'session-context compact' $script:Stdout '/sd:feature TEST-001'

# ---- stop-gate: a skipped HARD gate blocks the stop, once (SW-69) -----------

# Its own workspace: the hook is opt-in, and enabling it in the shared fixture
# would change nothing above but is not this section's business. The project
# root must come from cwd, not from a CLAUDE_PROJECT_DIR the runner inherited.
$savedProjectDir = $env:CLAUDE_PROJECT_DIR
Remove-Item Env:\CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue
$sg = Join-Path $fixture 'stop-gate-ws'
New-Item -ItemType Directory -Force -Path (Join-Path $sg '.claude'), (Join-Path $sg '.specs\BUG-SMOKE-1') | Out-Null
Set-Content -LiteralPath (Join-Path $sg '.specs\BUG-SMOKE-1\00-spec.md') -Encoding UTF8 -NoNewline `
    -Value "---`nid: BUG-SMOKE-1`ntype: bug`nstatus: approved`n---`n`n## Reproduction`n`n1. <<step 1>>`n"
Set-Content -LiteralPath (Join-Path $sg '.specs\BUG-SMOKE-1\03-decisions.md') -Encoding UTF8 -Value '# Decisions'
Set-Content -LiteralPath (Join-Path $sg 'transcript.jsonl') -Encoding UTF8 -NoNewline `
    -Value '{"type":"user","message":{"content":"continue BUG-SMOKE-1"}}'
$sgCfg = Join-Path $sg '.claude\project-config.json'
$sgEsc = $sg -replace '\\', '\\\\'
$sgPayload = "{`"session_id`":`"smoke-stop`",`"cwd`":`"$sgEsc`",`"transcript_path`":`"$sgEsc\\transcript.jsonl`",`"stop_hook_active`":false}"

Write-Section 'stop-gate (PowerShell): off by default - silent'
Set-Content -LiteralPath $sgCfg -Encoding UTF8 -Value '{"spec":{"dir":".specs"}}'
Invoke-Hook (Join-Path $repoRoot 'hooks\powershell\stop-gate.ps1') $sgPayload
Assert-Exit0 'stop-gate default off' $script:Code
Assert-Empty 'stop-gate default off' $script:Stdout

Write-Section 'stop-gate (PowerShell): enabled, skipped Gate 2 - blocks'
Set-Content -LiteralPath $sgCfg -Encoding UTF8 -Value '{"spec":{"dir":".specs"},"hooks":{"stopGate":{"enabled":true}}}'
Invoke-Hook (Join-Path $repoRoot 'hooks\powershell\stop-gate.ps1') $sgPayload
Assert-Exit0 'stop-gate skipped gate' $script:Code
Assert-Contains 'stop-gate skipped gate' $script:Stdout '"decision":"block"'
Assert-Contains 'stop-gate skipped gate' $script:Stdout 'Gate 2 (Reproduction confirmed)'

Write-Section 'stop-gate (PowerShell): re-fire with stop_hook_active - silent'
Invoke-Hook (Join-Path $repoRoot 'hooks\powershell\stop-gate.ps1') ($sgPayload -replace '"stop_hook_active":false', '"stop_hook_active":true')
Assert-Exit0 'stop-gate re-fire' $script:Code
Assert-Empty 'stop-gate re-fire' $script:Stdout

# ---- stop-gate: /sd:feature gates read from gate-briefs.md (SW-100) ---------

$fg = Join-Path $fixture 'stop-gate-feat-ws'
$fd = Join-Path $fg '.specs\FEAT-SMOKE-2'
New-Item -ItemType Directory -Force -Path (Join-Path $fg '.claude'), $fd | Out-Null
Set-Content -LiteralPath (Join-Path $fg '.claude\project-config.json') -Encoding UTF8 `
    -Value '{"spec":{"dir":".specs"},"hooks":{"stopGate":{"enabled":true}}}'
Set-Content -LiteralPath (Join-Path $fg 'transcript.jsonl') -Encoding UTF8 -NoNewline `
    -Value '{"type":"user","message":{"content":"/sd:feature SMOKE-2 (FEAT-SMOKE-2)"}}'
$fgEsc = $fg -replace '\\', '\\\\'
$fPayload = "{`"session_id`":`"smoke-stop-feat`",`"cwd`":`"$fgEsc`",`"transcript_path`":`"$fgEsc\\transcript.jsonl`",`"stop_hook_active`":false}"

# Set-FeatState <status> <T01 status|''> <06-verify result|''> <briefs>
# <briefs> is '-' for no gate-briefs.md (a spec from before SW-89), else
# space-separated gate=reply pairs; an empty reply leaves that section open.
function Set-FeatState {
    param([string]$Status, [string]$Task, [string]$Verify, [string]$Briefs)
    Get-ChildItem -LiteralPath $fd -Filter '*.md' | Remove-Item -Force
    Set-Content -LiteralPath (Join-Path $fd '00-spec.md') -Encoding UTF8 -NoNewline `
        -Value "---`nid: FEAT-SMOKE-2`ntype: feature`nstatus: $Status`n---`n"
    if ($Status -ne 'draft') { Set-Content -LiteralPath (Join-Path $fd '03-decisions.md') -Encoding UTF8 -Value '# Decisions' }
    if ($Task) {
        Set-Content -LiteralPath (Join-Path $fd '02-tasks.md') -Encoding UTF8 -NoNewline `
            -Value "### T01 - Count`n`n- **Status**: $Task`n"
    }
    if ($Verify) {
        Set-Content -LiteralPath (Join-Path $fd '06-verify.md') -Encoding UTF8 -NoNewline -Value "---`nresult: $Verify`n---`n"
    }
    if ($Briefs -eq '-') { return }
    $text = "# Gate briefs - FEAT-SMOKE-2`n"
    foreach ($g in ($Briefs -split ' ')) {
        $gate, $reply = $g -split '=', 2
        # The gate key 12 writes the S lane's combined `## Gate 1+2` heading (ADR 0024).
        if ($gate -eq '12') { $gate = '1+2' }
        $text += "`n## Gate $gate - smoke (pass 1)`n`nApprove? (yes / abort)`n"
        if ($reply) { $text += "`nReply: $reply`n" }
    }
    Set-Content -LiteralPath (Join-Path $fd 'gate-briefs.md') -Encoding UTF8 -NoNewline -Value $text
}

# Test-FeatCase <label> <'silent' | substring of the block reason> <Set-FeatState args...>
function Test-FeatCase {
    param([string]$Label, [string]$Expect, [string]$Status, [string]$Task, [string]$Verify, [string]$Briefs)
    Set-FeatState $Status $Task $Verify $Briefs
    Write-Section "stop-gate (PowerShell): feature $Label"
    Invoke-Hook (Join-Path $repoRoot 'hooks\powershell\stop-gate.ps1') $fPayload
    Assert-Exit0 "stop-gate feature $Label" $script:Code
    if ($Expect -eq 'silent') {
        Assert-Empty "stop-gate feature $Label" $script:Stdout
    } else {
        Assert-Contains "stop-gate feature $Label" $script:Stdout '"decision":"block"'
        Assert-Contains "stop-gate feature $Label" $script:Stdout $Expect
    }
}

Test-FeatCase 'Gate 1 passed without a reply - blocks' 'Gate 1 (Spec approval)' 'approved' '' '' '1='
Test-FeatCase 'Gate 1 passed with Reply: yes - silent' 'silent' 'approved' '' '' '1=yes'
Test-FeatCase 'at Gate 1 - silent' 'silent' 'draft' '' '' '1='
Test-FeatCase 'Gate 1 passed, no brief (pre-SW-89) - silent' 'silent' 'approved' '' '' '-'
Test-FeatCase 'Gate 2 passed without a reply - blocks' 'Gate 2 (Plan approval)' 'in-progress' 'done' '' '1=yes 2='
Test-FeatCase 'Gate 2 passed with Reply: yes - silent' 'silent' 'in-progress' 'done' '' '1=yes 2=yes'
Test-FeatCase 'at Gate 2 - silent' 'silent' 'approved' 'open' '' '1=yes 2='
Test-FeatCase 'Gate 2 passed, no brief (pre-SW-89) - silent' 'silent' 'in-progress' 'done' '' '-'
Test-FeatCase 'Gate 3 passed without a reply - blocks' 'Gate 3 (Integration and review)' 'in-progress' 'done' 'pass' '1=yes 2=yes 3='
Test-FeatCase 'Gate 3 passed with Reply: yes - silent' 'silent' 'in-progress' 'done' 'pass' '1=yes 2=yes 3=yes'
Test-FeatCase 'at Gate 3 - silent' 'silent' 'in-progress' 'done' '' '1=yes 2=yes 3='
Test-FeatCase 'Gate 3 passed, no brief (pre-SW-89) - silent' 'silent' 'in-progress' 'done' 'pass' '-'
Test-FeatCase 'S lane combined approval with Reply: yes - silent' 'silent' 'in-progress' 'done' '' '12=yes'
Test-FeatCase 'S lane combined approval without a reply - blocks' 'Gate 2 (Plan approval)' 'in-progress' 'done' '' '12='
Test-FeatCase 'at the S lane combined approval - silent' 'silent' 'draft' '' '' '12='

Write-Section 'stop-gate (PowerShell): feature re-fire with stop_hook_active - silent'
Set-FeatState 'in-progress' 'done' 'pass' '1=yes 2=yes 3='
Invoke-Hook (Join-Path $repoRoot 'hooks\powershell\stop-gate.ps1') ($fPayload -replace '"stop_hook_active":false', '"stop_hook_active":true')
Assert-Exit0 'stop-gate feature re-fire' $script:Code
Assert-Empty 'stop-gate feature re-fire' $script:Stdout

# ---- stop-gate: /sd:bug, /sd:refactor and Gate Re-plan (SW-108) ------------

$bg = Join-Path $fixture 'stop-gate-brief-ws'
New-Item -ItemType Directory -Force -Path (Join-Path $bg '.claude') | Out-Null
Set-Content -LiteralPath (Join-Path $bg '.claude\project-config.json') -Encoding UTF8 `
    -Value '{"spec":{"dir":".specs"},"hooks":{"stopGate":{"enabled":true}}}'
$bgEsc = $bg -replace '\\', '\\\\'
$bPayload = "{`"session_id`":`"smoke-stop-brief`",`"cwd`":`"$bgEsc`",`"transcript_path`":`"$bgEsc\\transcript.jsonl`",`"stop_hook_active`":false}"

# Set-BriefState <type> <status> <files> <briefs>
# <files> is a space-separated subset of: decisions failing closeout plan
# plan-r1 tasks-done. <briefs> is '-' for no gate-briefs.md, else gate=reply
# pairs; R<n> is a Gate Re-plan section; an empty reply leaves it open.
function Set-BriefState {
    param([string]$Type, [string]$Status, [string]$Files, [string]$Briefs)
    $id = if ($Type -eq 'bug') { 'BUG-SMOKE-3' } else { 'REF-SMOKE-4' }
    $specs = Join-Path $bg '.specs'
    if (Test-Path -LiteralPath $specs) { Remove-Item -LiteralPath $specs -Recurse -Force }
    $bd = Join-Path $specs $id
    New-Item -ItemType Directory -Force -Path $bd | Out-Null
    Set-Content -LiteralPath (Join-Path $bg 'transcript.jsonl') -Encoding UTF8 -NoNewline `
        -Value "{`"type`":`"user`",`"message`":{`"content`":`"continue $id`"}}"
    Set-Content -LiteralPath (Join-Path $bd '00-spec.md') -Encoding UTF8 -NoNewline `
        -Value "---`nid: $id`ntype: $Type`nstatus: $Status`n---`n"
    foreach ($f in ($Files -split ' ')) {
        switch ($f) {
            'decisions' { Set-Content -LiteralPath (Join-Path $bd '03-decisions.md') -Encoding UTF8 -Value '# Decisions' }
            'failing' {
                New-Item -ItemType Directory -Force -Path (Join-Path $bd '04-artifacts\repro') | Out-Null
                Set-Content -LiteralPath (Join-Path $bd '04-artifacts\repro\failing-test-output.txt') -Encoding UTF8 -Value 'FAIL'
            }
            'closeout' { Set-Content -LiteralPath (Join-Path $bd '05-retro.md') -Encoding UTF8 -NoNewline -Value "# Retro`n`n## Close-out`n" }
            'plan' { Set-Content -LiteralPath (Join-Path $bd '01-plan.md') -Encoding UTF8 -Value '# Plan' }
            'plan-r1' {
                Set-Content -LiteralPath (Join-Path $bd '01-plan.md') -Encoding UTF8 -NoNewline `
                    -Value "# Plan`n`n## Revisions`n`n### R1 - 2026-10-29T10:00:00Z`n"
            }
            'tasks-done' {
                Set-Content -LiteralPath (Join-Path $bd '02-tasks.md') -Encoding UTF8 -NoNewline `
                    -Value "### T01 - Extract`n`n- **Status**: done`n"
            }
        }
    }
    if ($Briefs -eq '-') { return }
    $text = "# Gate briefs - $id`n"
    foreach ($g in ($Briefs -split ' ')) {
        $gate, $reply = $g -split '=', 2
        if ($gate.StartsWith('R')) { $gate = "Re-plan - $gate" }
        $text += "`n## Gate $gate - smoke (pass 1)`n`nProceed? (yes / abort)`n"
        if ($reply) { $text += "`nReply: $reply`n" }
    }
    Set-Content -LiteralPath (Join-Path $bd 'gate-briefs.md') -Encoding UTF8 -NoNewline -Value $text
}

# Test-BriefCase <label> <'silent' | substring of the block reason> <Set-BriefState args...>
function Test-BriefCase {
    param([string]$Label, [string]$Expect, [string]$Type, [string]$Status, [string]$Files, [string]$Briefs)
    Set-BriefState $Type $Status $Files $Briefs
    Write-Section "stop-gate (PowerShell): $Label"
    Invoke-Hook (Join-Path $repoRoot 'hooks\powershell\stop-gate.ps1') $bPayload
    Assert-Exit0 "stop-gate $Label" $script:Code
    if ($Expect -eq 'silent') {
        Assert-Empty "stop-gate $Label" $script:Stdout
    } else {
        Assert-Contains "stop-gate $Label" $script:Stdout '"decision":"block"'
        Assert-Contains "stop-gate $Label" $script:Stdout $Expect
    }
}

Test-BriefCase 'bug Gate 1 passed without a reply - blocks' 'Gate 1 (Symptom captured)' 'bug' 'approved' 'decisions' '1='
Test-BriefCase 'bug Gate 2 partial only - blocks' '(last reply: partial)' 'bug' 'approved' 'decisions' '1=yes 2=partial'
Test-BriefCase 'bug Gate 3a reply does not answer Gate 3 - blocks' 'Gate 3 (Root cause confirmed)' `
    'bug' 'approved' 'decisions failing' '1=yes 2=yes 3a=re-enumerate 3='
Test-BriefCase 'bug at Gate 4 - silent' 'silent' 'bug' 'approved' 'decisions failing' '1=yes 2=yes 3=yes 4='
Test-BriefCase 'bug past Gate 4, no brief - silent' 'silent' 'bug' 'in-progress' 'decisions failing' '-'
Test-BriefCase 'bug Gate 5 closed out without a reply - blocks' 'Gate 5 (Regression and review)' `
    'bug' 'in-progress' 'decisions failing closeout' '1=yes 2=yes 3=yes 4=yes 5='
Test-BriefCase 'refactor Gate 2 add tests only - blocks' 'Gate 2 (Coverage threshold met)' `
    'refactor' 'approved' 'decisions plan' '1=yes 2=add'
Test-BriefCase 'refactor Gate 2 add, Gate 3 yes - silent' 'silent' 'refactor' 'approved' 'decisions plan' '1=yes 2=add 3=yes'
Test-BriefCase 'refactor Gate 5 passed without a reply - blocks' 'Gate 5 (Tests green per batch)' `
    'refactor' 'in-progress' 'decisions plan tasks-done' '1=yes 2=yes 4=yes 5='
Test-BriefCase 'refactor Re-plan revise only - blocks' 'Gate Re-plan R1' `
    'refactor' 'in-progress' 'decisions plan-r1' '1=yes 2=yes 4=yes R1=revise'
Test-BriefCase 'refactor Re-plan approved - silent' 'silent' 'refactor' 'in-progress' 'decisions plan-r1' '1=yes 2=yes 4=yes R1=approve'
Test-BriefCase 'refactor revision with no Re-plan section - silent' 'silent' `
    'refactor' 'in-progress' 'decisions plan-r1' '1=yes 2=yes 4=yes'

Write-Section 'stop-gate (PowerShell): bug/refactor re-fire with stop_hook_active - silent'
Set-BriefState 'refactor' 'in-progress' 'decisions plan-r1' '1=yes 2=yes 4=yes R1=revise'
Invoke-Hook (Join-Path $repoRoot 'hooks\powershell\stop-gate.ps1') ($bPayload -replace '"stop_hook_active":false', '"stop_hook_active":true')
Assert-Exit0 'stop-gate brief re-fire' $script:Code
Assert-Empty 'stop-gate brief re-fire' $script:Stdout

# The shipped example: FEAT-todo-priority is done and has no gate-briefs.md.
# Its project enables stop-gate, so the nightly e2e runs these rules there.
Write-Section 'stop-gate (PowerShell): examples/fixture-project FEAT-todo-priority - silent, unchanged'
$fp = Join-Path $repoRoot 'examples\fixture-project'
$fpEsc = $fp -replace '\\', '\\\\'
Set-Content -LiteralPath (Join-Path $fg 'transcript-fp.jsonl') -Encoding UTF8 -NoNewline `
    -Value '{"type":"user","message":{"content":"/sd:feature todo-priority (FEAT-todo-priority)"}}'
Invoke-Hook (Join-Path $repoRoot 'hooks\powershell\stop-gate.ps1') `
    "{`"session_id`":`"smoke-stop-fp`",`"cwd`":`"$fpEsc`",`"transcript_path`":`"$fgEsc\\transcript-fp.jsonl`",`"stop_hook_active`":false}"
Assert-Exit0 'stop-gate fixture-project' $script:Code
Assert-Empty 'stop-gate fixture-project' $script:Stdout
if ($null -ne (Get-Command git -ErrorAction SilentlyContinue)) {
    $fpStatus = (& git -C $repoRoot status --porcelain -- 'examples/fixture-project/.specs/FEAT-todo-priority') -join "`n"
    if ($LASTEXITCODE -eq 0) { Assert-Empty 'stop-gate fixture-project FEAT-todo-priority unchanged' $fpStatus }
}

# ---- handoff-integrity: an edit outside the ready task's Files is flagged (SW-70)

# Its own workspace, for the same reason as stop-gate: the hook is opt-in.
$hi = Join-Path $fixture 'handoff-ws'
New-Item -ItemType Directory -Force -Path (Join-Path $hi '.claude'), (Join-Path $hi '.specs\FEAT-SMOKE-1') | Out-Null
Set-Content -LiteralPath (Join-Path $hi '.specs\FEAT-SMOKE-1\00-spec.md') -Encoding UTF8 -NoNewline `
    -Value "---`nid: FEAT-SMOKE-1`ntype: feature`nstatus: in-progress`n---`n"
Set-Content -LiteralPath (Join-Path $hi '.specs\FEAT-SMOKE-1\02-tasks.md') -Encoding UTF8 -NoNewline `
    -Value "### T01 - Add service`n`n- **Files**: src/service.ts`n- **Depends on**: none`n- **Status**: open`n"
Set-Content -LiteralPath (Join-Path $hi 'transcript.jsonl') -Encoding UTF8 -NoNewline `
    -Value '{"type":"user","message":{"content":"/sd:feature SMOKE-1 (FEAT-SMOKE-1)"}}'
$hiCfg = Join-Path $hi '.claude\project-config.json'
$hiEsc = $hi -replace '\\', '\\\\'
$hiPayload = "{`"session_id`":`"smoke-ptu`",`"cwd`":`"$hiEsc`",`"transcript_path`":`"$hiEsc\\transcript.jsonl`",`"tool_name`":`"Edit`",`"tool_input`":{`"file_path`":`"$hiEsc\\src\\other.ts`"}}"

Write-Section 'handoff-integrity (PowerShell): off by default - silent'
Set-Content -LiteralPath $hiCfg -Encoding UTF8 -Value '{"spec":{"dir":".specs"}}'
Invoke-Hook (Join-Path $repoRoot 'hooks\powershell\handoff-integrity.ps1') $hiPayload
Assert-Exit0 'handoff-integrity default off' $script:Code
Assert-Empty 'handoff-integrity default off' $script:Stdout

Write-Section 'handoff-integrity (PowerShell): enabled, out-of-scope edit - flagged'
Set-Content -LiteralPath $hiCfg -Encoding UTF8 -Value '{"spec":{"dir":".specs"},"hooks":{"handoffIntegrity":{"enabled":true}}}'
Invoke-Hook (Join-Path $repoRoot 'hooks\powershell\handoff-integrity.ps1') $hiPayload
Assert-Exit0 'handoff-integrity out of scope' $script:Code
Assert-Contains 'handoff-integrity out of scope' $script:Stdout '"decision":"block"'
Assert-Contains 'handoff-integrity out of scope' $script:Stdout 'src/other.ts is outside the declared Files'

Write-Section 'handoff-integrity (PowerShell): in-scope edit - silent'
Invoke-Hook (Join-Path $repoRoot 'hooks\powershell\handoff-integrity.ps1') ($hiPayload -replace 'other\.ts', 'service.ts')
Assert-Exit0 'handoff-integrity in scope' $script:Code
Assert-Empty 'handoff-integrity in scope' $script:Stdout
if ($null -ne $savedProjectDir) { $env:CLAUDE_PROJECT_DIR = $savedProjectDir }

# ---- cleanup + summary --------------------------------------------------------

Remove-Item -Recurse -Force $fixture -ErrorAction SilentlyContinue

Write-Section 'Summary'
Write-Host "  $($script:Pass) passed, $($script:Fail) failed"
if ($script:Fail -eq 0) {
    Write-Host '  [OK]   All hook smoke tests passed.' -ForegroundColor Green
    exit 0
} else {
    Write-Host "  [FAIL] $($script:Fail) smoke test(s) failed." -ForegroundColor Red
    exit 1
}
