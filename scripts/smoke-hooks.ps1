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
