#requires -Version 7.0
<#
.SYNOPSIS
    specwright: cross-implementation hook conformance runner.

.DESCRIPTION
    For every fixture case under tests/hooks/fixtures/<hook>/<case>/:
      1. Create a fresh temp workspace PER IMPLEMENTATION and copy the
         case's workspace/ tree into it (fresh copy means hook state such
         as the subagent-retro debounce file cannot leak across runs).
      2. Apply setup.json actions (backdating file mtimes, planting files).
      3. Substitute {{ROOT}} in input.json with the workspace path and
         {{CWD}} with the session cwd (forward slashes; both implementations
         accept them) and pipe the payload into the implementation on stdin.
         The session cwd is the workspace unless setup.json names a `cwd`
         subdirectory (SW-78). The child environment never inherits
         CLAUDE_PROJECT_DIR; setup.json `env` sets it (or any other variable)
         per case, with {{ROOT}} substituted.
      4. Normalize what the hook did into a small decision object.
      5. Assert bash decision == pwsh decision == expected.json golden.

    A behavioral divergence in only one implementation fails the suite
    and prints all three decision objects for a clear diff.

    -SelfTest substitutes a stub bash spec-gate hook that always allows,
    then asserts the harness DETECTS the divergence. Proves the
    comparison would notice real drift (mirror of scripts/selftest-docs).

.NOTES
    PURE ASCII ONLY (see hooks/powershell/prompt-router.ps1 for why).
    Single cross-platform runner by design: unlike the platform-native
    scripts/ checks, conformance must run BOTH implementations in one
    process, so a bash twin of this script would itself be a drift risk.
    CI runs this under pwsh on every matrix OS.
#>

[CmdletBinding()]
param(
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$scriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot    = (Resolve-Path (Join-Path $scriptDir '..' '..')).Path
$fixturesDir = Join-Path $scriptDir 'fixtures'

$script:pass = 0
$script:fail = 0

function Write-Ok {
    param([string]$Message)
    Write-Host "  [OK]   $Message"
    $script:pass++
}

function Write-Bad {
    param([string]$Message)
    Write-Host "  [FAIL] $Message"
    $script:fail++
}

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

function New-CaseWorkspace {
    param([string]$CaseDir)

    $name = 'sd-conformance-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 12)
    $ws = Join-Path ([System.IO.Path]::GetTempPath()) $name
    New-Item -ItemType Directory -Path $ws -Force | Out-Null

    $src = Join-Path $CaseDir 'workspace'
    if (Test-Path -LiteralPath $src) {
        # -Force on Get-ChildItem: fixture trees are mostly dot-dirs
        # (.claude, .specs) which Unix wildcard copies would skip.
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
        # `write` plants a file whose CONTENT carries a timestamp - a hook state
        # file, say. The timestamp is computed at run time from a
        # {{UTCNOW-90M}} / {{UTCNOW+5M}} token rather than written literally
        # into the fixture, which would rot the moment the clock moved past it.
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

function Get-CaseSetup {
    param([string]$CaseDir)
    $setupPath = Join-Path $CaseDir 'setup.json'
    if (-not (Test-Path -LiteralPath $setupPath)) { return $null }
    return (Get-Content -LiteralPath $setupPath -Raw | ConvertFrom-Json)
}

# Variables the hooks read from the environment. Stripped from every child so
# a runner started inside a Claude Code session (which exports
# CLAUDE_PROJECT_DIR) cannot point the hooks at the real repo; a case that
# wants one sets it through setup.json `env`.
$script:scrubbedEnv = @('CLAUDE_PROJECT_DIR')

function Invoke-HookProcess {
    param(
        [string]$Exe,
        [string[]]$ProcArgs,
        [string]$Payload,
        [hashtable]$Env = @{}
    )
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $Exe
    foreach ($a in $ProcArgs) { $psi.ArgumentList.Add($a) }
    foreach ($name in $script:scrubbedEnv) { [void]$psi.Environment.Remove($name) }
    foreach ($name in $Env.Keys) { $psi.Environment[$name] = [string]$Env[$name] }
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.UseShellExecute        = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    try {
        $proc.StandardInput.Write($Payload)
        $proc.StandardInput.Close()
    } catch [System.IO.IOException] {
        # Child exited without reading stdin (e.g. the self-test's always-allow
        # stub, which never touches its input) - a broken pipe here just means
        # the child didn't need the payload, not a harness failure.
    }
    # Hook output is tiny (well under pipe buffer size), so sequential
    # reads cannot deadlock.
    $stdout = $proc.StandardOutput.ReadToEnd()
    $stderr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        Stdout   = $stdout.Replace("`r", '')
        Stderr   = $stderr.Replace("`r", '')
    }
}

function Get-MetricsEventsPath {
    param([string]$Ws)
    # Mirrors both hook implementations' own fallback: hooks.metrics.path from
    # the WORKSPACE's own project-config.json (a fresh per-run copy of the
    # case's workspace/ tree), defaulting to .specs/_metrics/events.jsonl when
    # the key or the file itself is absent/malformed. This is what lets the
    # metrics-custom-path case tell the harness where to look.
    $relPath = '.specs/_metrics/events.jsonl'
    $cfgPath = Join-Path $Ws '.claude/project-config.json'
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $cfg = Get-Content -LiteralPath $cfgPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($cfg.hooks.metrics.path) { $relPath = [string]$cfg.hooks.metrics.path }
        } catch { }
    }
    return (Join-Path $Ws ($relPath.Replace('/', [System.IO.Path]::DirectorySeparatorChar)))
}

function Read-NormalizedEventLines {
    param([string]$Path)
    # Read a JSONL metrics file BEFORE the caller deletes the workspace. Each
    # line is normalized independently: ts is wall-clock and can never match a
    # golden, so it is replaced with the literal "<TS>" once verified to look
    # like a real timestamp - a malformed ts becomes "<BAD-TS>" instead of
    # being silently erased, so a broken timestamp FAILS the case.
    $events = [System.Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $Path)) { return , @() }
    $lines = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue
    foreach ($line in @($lines)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $obj = $line | ConvertFrom-Json -ErrorAction Stop
        } catch {
            continue
        }
        # PowerShell 7's ConvertFrom-Json auto-converts an ISO-8601 "...Z"
        # string to a [datetime] with Kind=Utc (same gotcha documented in
        # subagent-retro.ps1's Test-DebounceElapsed); PowerShell 5.1 leaves it
        # as a plain string. Re-render a [datetime] back into the on-disk
        # format before pattern-matching it, rather than stringifying it
        # directly, which would use local culture and never match.
        $rawTs = $obj.ts
        if ($rawTs -is [datetime]) {
            $tsVal = $rawTs.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        } elseif ($null -ne $rawTs) {
            $tsVal = [string]$rawTs
        } else {
            $tsVal = ''
        }
        if ($tsVal -match '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$') {
            $obj.ts = '<TS>'
        } else {
            $obj.ts = '<BAD-TS>'
        }
        $events.Add($obj) | Out-Null
    }
    return , @($events)
}

# SW-78: a hook that trusted an off-root cwd created .specs/ or .claude/ state
# directories inside it. Lists whichever of the two exist under the session
# cwd; the caller diffs before/after so fixture-planted ones do not count.
function Get-NestedStateDirs {
    param([string]$CwdPath)
    $found = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @('.specs', '.claude')) {
        if (Test-Path -LiteralPath (Join-Path $CwdPath $name) -PathType Container) { $found.Add($name) }
    }
    return $found.ToArray()
}

function Get-CaseEvents {
    param([string]$Ws)
    return Read-NormalizedEventLines -Path (Get-MetricsEventsPath -Ws $Ws)
}

# Rotation (SW-15): the previous generation the hook rolled off to
# `events.jsonl.1`, read the same normalized way as the live log so a rotation
# case can assert the old lines survived the roll byte-for-byte. Empty when
# nothing rotated.
function Get-CaseRotatedEvents {
    param([string]$Ws)
    return Read-NormalizedEventLines -Path ((Get-MetricsEventsPath -Ws $Ws) + '.1')
}

function Invoke-HookImpl {
    param(
        [string]$Impl,
        [string]$HookScript,
        [string]$CaseDir
    )
    $ws = New-CaseWorkspace -CaseDir $CaseDir
    try {
        $wsForward = $ws.Replace('\', '/')
        $setup = Get-CaseSetup -CaseDir $CaseDir

        # Session cwd (SW-78): the workspace root unless the case names a
        # subdirectory. The subdirectory must come from the fixture's own
        # workspace/ tree - the runner never creates it, so the nested-state
        # check below can tell fixture content from hook output.
        $cwdForward = $wsForward
        $nestedBefore = @()
        if ($null -ne $setup -and -not [string]::IsNullOrWhiteSpace([string]$setup.cwd)) {
            $cwdForward = $wsForward + '/' + ([string]$setup.cwd).Trim('/')
            $nestedBefore = @(Get-NestedStateDirs -CwdPath $cwdForward)
        }

        $envMap = @{}
        if ($null -ne $setup -and $null -ne $setup.env) {
            foreach ($prop in $setup.env.PSObject.Properties) {
                $envMap[$prop.Name] = ([string]$prop.Value).Replace('{{ROOT}}', $wsForward)
            }
        }

        $inputPath = Join-Path $CaseDir 'input.json'
        $payload = (Get-Content -LiteralPath $inputPath -Raw).Replace('{{ROOT}}', $wsForward).Replace('{{CWD}}', $cwdForward)
        if ($Impl -eq 'bash') {
            $run = Invoke-HookProcess -Exe $script:bashExe -ProcArgs @($HookScript) -Payload $payload -Env $envMap
        } else {
            $run = Invoke-HookProcess -Exe 'pwsh' -ProcArgs @('-NoProfile', '-File', $HookScript) -Payload $payload -Env $envMap
        }
        $events = Get-CaseEvents -Ws $ws
        $rotated = Get-CaseRotatedEvents -Ws $ws
        $nestedCreated = @()
        if ($cwdForward -ne $wsForward) {
            $nestedCreated = @(Get-NestedStateDirs -CwdPath $cwdForward | Where-Object { $nestedBefore -notcontains $_ })
        }
        return [pscustomobject]@{
            ExitCode      = $run.ExitCode
            Stdout        = $run.Stdout
            Stderr        = $run.Stderr
            Events        = $events
            RotatedEvents = $rotated
            NestedCreated = $nestedCreated
            Workspace     = $ws
        }
    } finally {
        Remove-Item -LiteralPath $ws -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-EventsLeakNoPath {
    param(
        [object[]]$Events,
        [string]$Ws
    )
    # Structural guard for the metrics-code-edit-allow fixture (privacy
    # decision in SW-10-implementation-plan.md section 1: "record the file
    # extension only, never the path"). Golden-equality alone is not quite
    # enough here - a leaked absolute path would embed a per-run random temp
    # directory name and so would merely show up as SOME mismatching value
    # in the diff, not as an explicit "path leaked" failure. This walks every
    # field of every event (skipping ts, already normalized to "<TS>"/
    # "<BAD-TS>") and fails loudly if a value contains a path separator or
    # the workspace path itself, in either slash direction.
    $wsForward = $Ws.Replace('\', '/')
    foreach ($ev in @($Events)) {
        foreach ($prop in $ev.PSObject.Properties) {
            if ($prop.Name -eq 'ts') { continue }
            $val = [string]$prop.Value
            if ($val.Length -eq 0) { continue }
            if ($val.Contains('/') -or $val.Contains('\')) { return $false }
            if ($val.Contains($Ws) -or $val.Contains($wsForward)) { return $false }
        }
    }
    return $true
}

# ---- normalizers: one per hook, each maps a raw run to a decision object ----

function ConvertTo-SpecGateDecision {
    param($Run)
    $decision = 'allow'
    $permission = $null
    $reason = $null
    $stdoutTrim = $Run.Stdout.Trim()
    if ($stdoutTrim.Length -gt 0) {
        try {
            $obj = $stdoutTrim | ConvertFrom-Json
            if ($obj.decision) { $decision = [string]$obj.decision }
            if ($obj.hookSpecificOutput -and $obj.hookSpecificOutput.permissionDecision) {
                $permission = [string]$obj.hookSpecificOutput.permissionDecision
            }
            # The human-readable reason is duplicated into both schema halves by
            # both implementations; if the two copies ever disagree the object
            # must not silently keep one of them.
            $topReason = if ($obj.reason) { [string]$obj.reason } else { $null }
            $nestedReason = if ($obj.hookSpecificOutput -and $obj.hookSpecificOutput.reason) {
                [string]$obj.hookSpecificOutput.reason
            } else { $null }
            if ($topReason -ne $nestedReason) {
                $reason = 'REASON-MISMATCH-BETWEEN-SCHEMA-HALVES'
            } else {
                $reason = $topReason
            }
        } catch {
            $decision = 'unparseable-stdout'
        }
    } elseif ($Run.Stderr.Contains('[WARN]')) {
        $decision = 'warn'
    }
    # stderr is part of the decision: the repo invariant is that a hook stays
    # SILENT unless it has something to say, so an unexpected diagnostic on
    # stderr must fail the case rather than pass unnoticed.
    return [pscustomobject][ordered]@{
        exitCode           = $Run.ExitCode
        decision           = $decision
        permissionDecision = $permission
        reason             = $reason
        stderr             = $Run.Stderr.Trim()
        events             = @($Run.Events)
    }
}

function ConvertTo-PromptRouterDecision {
    param($Run)
    $workflows   = [System.Collections.Generic.List[string]]::new()
    $ticketIds   = [System.Collections.Generic.List[string]]::new()
    $specFolders = [System.Collections.Generic.List[string]]::new()
    $inProgress  = [System.Collections.Generic.List[string]]::new()
    $section = ''
    foreach ($line in ($Run.Stdout -split "`n")) {
        if ($line -match '^Workflow keyword matches:') { $section = 'workflows'; continue }
        if ($line -match '^Ticket IDs detected: (.*)$') {
            $section = 'tickets'
            foreach ($t in ($Matches[1] -split ', ')) {
                if ($t.Trim()) { $ticketIds.Add($t.Trim()) }
            }
            continue
        }
        if ($line -match '^Matching spec folders') { $section = 'folders'; continue }
        if ($line -match '^No matching spec folder') { $section = ''; continue }
        if ($line -match '^Specs currently in-progress') { $section = 'inprogress'; continue }
        if ($line -match '^\s+-\s+(.+)$') {
            $item = $Matches[1].Trim()
            switch ($section) {
                'workflows' {
                    if ($item -match '^/sd:([a-z]+)') { $workflows.Add($Matches[1]) }
                }
                'folders'    { $specFolders.Add($item) }
                'inprogress' { $inProgress.Add($item) }
            }
        }
    }
    return [pscustomobject][ordered]@{
        exitCode    = $Run.ExitCode
        emitted     = $Run.Stdout.Contains('<context-router>')
        workflows   = @($workflows | Sort-Object)
        ticketIds   = @($ticketIds | Sort-Object)
        specFolders = @($specFolders | Sort-Object)
        inProgress  = @($inProgress | Sort-Object)
        stderr      = $Run.Stderr.Trim()
        events      = @($Run.Events)
    }
}

function ConvertTo-SubagentRetroDecision {
    param($Run)
    $stale = [System.Collections.Generic.List[object]]::new()
    foreach ($line in ($Run.Stdout -split "`n")) {
        # The measured age and the threshold it was compared against are part of
        # the decision - dropping them would let the two implementations disagree
        # on arithmetic (truncate vs round) while still looking identical.
        if ($line -match '^\s+-\s+([A-Za-z0-9_\-]+): 05-retro\.md missing$') {
            $stale.Add([pscustomobject][ordered]@{
                id = $Matches[1]; reason = 'missing'; ageMinutes = $null; thresholdMinutes = $null
            })
        } elseif ($line -match '^\s+-\s+([A-Za-z0-9_\-]+): 05-retro\.md last touched (\d+) min ago \(threshold (\d+) min\)$') {
            $stale.Add([pscustomobject][ordered]@{
                id = $Matches[1]; reason = 'stale'
                ageMinutes = [int]$Matches[2]; thresholdMinutes = [int]$Matches[3]
            })
        }
    }
    # Lesson injection (SW-19). Captured verbatim and in EMISSION ORDER, not
    # sorted: which lessons are selected and the order they appear in is the
    # behaviour under test, and lessons.md is rendered in a total order upstream
    # precisely so that order is deterministic. Sorting here would hide a
    # divergence in selection order - the exact failure this fixture set exists
    # to catch.
    $lessons = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($Run.Stdout -split "`n")) {
        $trimmed = $line.TrimEnd("`r")
        if ($trimmed -cmatch '^  (- \[[a-z-]+\] [a-z]+/[a-z]+: .+)$') {
            $lessons.Add($Matches[1])
        }
    }

    return [pscustomobject][ordered]@{
        exitCode = $Run.ExitCode
        emitted  = $Run.Stdout.Contains('<retro-reminder>')
        stale    = @($stale | Sort-Object -Property id)
        lessons  = @($lessons)
        stderr   = $Run.Stderr.Trim()
        events   = @($Run.Events)
    }
}

$hookNormalizers = @{
    'spec-gate'      = ${function:ConvertTo-SpecGateDecision}
    'prompt-router'  = ${function:ConvertTo-PromptRouterDecision}
    'subagent-retro' = ${function:ConvertTo-SubagentRetroDecision}
}

function Get-CanonicalJson {
    param($Obj)
    return ($Obj | ConvertTo-Json -Depth 5 -Compress)
}

$script:noLeakCases = @{
    'spec-gate' = @('metrics-code-edit-allow')
}

# Rotation cases (SW-15). For these, the main golden (expected.json) proves the
# LIVE events.jsonl restarted - it lists only the post-roll line(s), so a
# rotation that never fired would leave the seed lines in the live file and
# mismatch. This map adds the other half of the proof: the rolled-off
# events.jsonl.1 must exist, be non-empty, hold exactly the pre-seeded lines
# (from the case's rotated-expected.json golden), and be identical across bash
# and pwsh - i.e. the roll preserved the old data byte-for-byte on both
# platforms and lost nothing. A case whose name is NOT listed here must produce
# NO .1 at all (no accidental rotation), which is asserted for every case.
$script:rotationCases = @{
    'spec-gate'      = @('metrics-rotates-at-cap')
    'subagent-retro' = @('metrics-rotates-at-cap')
}

function Invoke-ConformanceCase {
    param(
        [string]$HookName,
        [string]$CaseDir,
        [string]$BashHook,
        [string]$PwshHook
    )
    $normalizer = $hookNormalizers[$HookName]
    $bashRun = Invoke-HookImpl -Impl 'bash' -HookScript $BashHook -CaseDir $CaseDir
    $pwshRun = Invoke-HookImpl -Impl 'pwsh' -HookScript $PwshHook -CaseDir $CaseDir
    $expected = Get-Content -LiteralPath (Join-Path $CaseDir 'expected.json') -Raw | ConvertFrom-Json
    $bashJson     = Get-CanonicalJson (& $normalizer $bashRun)
    $pwshJson     = Get-CanonicalJson (& $normalizer $pwshRun)
    $expectedJson = Get-CanonicalJson $expected
    $match = ($bashJson -eq $expectedJson) -and ($pwshJson -eq $expectedJson)

    $caseName = Split-Path -Leaf $CaseDir
    $leakNote = $null
    $leakCases = $script:noLeakCases[$HookName]
    if ($null -ne $leakCases -and $leakCases -contains $caseName) {
        # Golden-equality alone would only surface a leaked path as an
        # unexplained mismatch (the leaked value embeds a per-run random temp
        # directory name, so it can never equal a fixed golden). This makes
        # the failure mode explicit instead of a generic diff.
        $bashClean = Test-EventsLeakNoPath -Events $bashRun.Events -Ws $bashRun.Workspace
        $pwshClean = Test-EventsLeakNoPath -Events $pwshRun.Events -Ws $pwshRun.Workspace
        if ((-not $bashClean) -or (-not $pwshClean)) {
            $match = $false
            $leakNote = "structural no-path-leak check FAILED (bash clean=$bashClean, pwsh clean=$pwshClean)"
        }
    }

    # Rotation proof (SW-15). Two halves, both required:
    #   1. Every case must produce NO events.jsonl.1 unless it is a declared
    #      rotation case - catches an accidental roll that the live-file golden
    #      alone would miss.
    #   2. A declared rotation case must roll the pre-seeded lines off to a
    #      non-empty .1 that equals rotated-expected.json, identically on bash
    #      and pwsh - the "old data survived byte-for-byte on both platforms"
    #      half that the live-file golden cannot see.
    $rotationNote = $null
    $rotationCases = $script:rotationCases[$HookName]
    $isRotationCase = ($null -ne $rotationCases -and $rotationCases -contains $caseName)
    if ($isRotationCase) {
        $rotExpectedPath = Join-Path $CaseDir 'rotated-expected.json'
        if (-not (Test-Path -LiteralPath $rotExpectedPath)) {
            $match = $false
            $rotationNote = 'rotation case is missing rotated-expected.json'
        } else {
            $rotExpected = Get-Content -LiteralPath $rotExpectedPath -Raw | ConvertFrom-Json
            $rotExpectedJson = Get-CanonicalJson $rotExpected
            $bashRot = Get-CanonicalJson ([pscustomobject]@{ rotated = @($bashRun.RotatedEvents) })
            $pwshRot = Get-CanonicalJson ([pscustomobject]@{ rotated = @($pwshRun.RotatedEvents) })
            if (@($bashRun.RotatedEvents).Count -eq 0 -or @($pwshRun.RotatedEvents).Count -eq 0) {
                $match = $false
                $rotationNote = "expected a rolled events.jsonl.1 but it was empty/absent (bash=$(@($bashRun.RotatedEvents).Count), pwsh=$(@($pwshRun.RotatedEvents).Count))"
            } elseif ($bashRot -ne $rotExpectedJson -or $pwshRot -ne $rotExpectedJson) {
                $match = $false
                $rotationNote = "rolled .1 content mismatch`n         rot-expected: $rotExpectedJson`n         bash .1     : $bashRot`n         pwsh .1     : $pwshRot"
            }
        }
    } else {
        # No non-rotation case may leave a .1 behind.
        if (@($bashRun.RotatedEvents).Count -gt 0 -or @($pwshRun.RotatedEvents).Count -gt 0) {
            $match = $false
            $rotationNote = "unexpected events.jsonl.1 produced by a non-rotation case (bash=$(@($bashRun.RotatedEvents).Count), pwsh=$(@($pwshRun.RotatedEvents).Count))"
        }
    }

    # SW-78: no hook may create state directories under an off-root cwd.
    $nestedNote = $null
    if (@($bashRun.NestedCreated).Count -gt 0 -or @($pwshRun.NestedCreated).Count -gt 0) {
        $match = $false
        $nestedNote = "hook created state dirs under the session cwd (bash=$(@($bashRun.NestedCreated) -join ','), pwsh=$(@($pwshRun.NestedCreated) -join ','))"
    }

    return [pscustomobject]@{
        CaseName     = $caseName
        NestedNote   = $nestedNote
        Bash         = $bashJson
        Pwsh         = $pwshJson
        Expected     = $expectedJson
        Match        = $match
        LeakNote     = $leakNote
        RotationNote = $rotationNote
    }
}

function Write-CaseDiff {
    param($Result)
    Write-Host "         expected : $($Result.Expected)"
    Write-Host "         bash     : $($Result.Bash)"
    Write-Host "         pwsh     : $($Result.Pwsh)"
    if ($Result.LeakNote) {
        Write-Host "         leak     : $($Result.LeakNote)"
    }
    if ($Result.RotationNote) {
        Write-Host "         rotation : $($Result.RotationNote)"
    }
    if ($Result.NestedNote) {
        Write-Host "         nested   : $($Result.NestedNote)"
    }
}

# ---- preconditions ----------------------------------------------------------

$script:bashExe = Resolve-BashPath
if ($null -eq $script:bashExe) {
    Write-Host '[FAIL] bash not found; conformance requires both implementations.'
    exit 2
}
if ($null -eq (Get-Command jq -ErrorAction SilentlyContinue)) {
    # Without jq the bash hooks exit 0 silently, which would make every
    # bash decision look like "allow" and the comparison meaningless.
    Write-Host '[FAIL] jq not found; the bash hooks would silently no-op.'
    exit 2
}

# ---- self-test mode ---------------------------------------------------------

if ($SelfTest) {
    Write-Host '=== conformance self-test: harness must DETECT divergence ==='
    $stubName = 'sd-selftest-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8) + '.sh'
    $stub = Join-Path ([System.IO.Path]::GetTempPath()) $stubName
    "#!/usr/bin/env bash`nexit 0`n" | Set-Content -LiteralPath $stub -NoNewline -Encoding ascii
    try {
        $caseDir = Join-Path $fixturesDir 'spec-gate' 'block-code-no-spec'
        $result = Invoke-ConformanceCase -HookName 'spec-gate' -CaseDir $caseDir `
            -BashHook $stub -PwshHook (Join-Path $repoRoot 'hooks' 'powershell' 'spec-gate.ps1')
    } finally {
        Remove-Item -LiteralPath $stub -Force -ErrorAction SilentlyContinue
    }
    if ($result.Pwsh -ne $result.Expected) {
        Write-Bad 'self-test precondition: real pwsh impl no longer matches the golden'
        Write-CaseDiff $result
        exit 1
    }
    if ($result.Match) {
        Write-Bad 'self-test: harness did NOT detect an always-allow bash stub'
        Write-CaseDiff $result
        exit 1
    }
    Write-Ok 'self-test: divergence in one implementation was detected'
    exit 0
}

# ---- main -------------------------------------------------------------------

foreach ($hookDir in (Get-ChildItem -LiteralPath $fixturesDir -Directory | Sort-Object Name)) {
    $hookName = $hookDir.Name
    if (-not $hookNormalizers.ContainsKey($hookName)) {
        Write-Bad "unknown fixture hook '$hookName' (no normalizer registered)"
        continue
    }
    $bashHook = Join-Path $repoRoot 'hooks' 'bash' "$hookName.sh"
    $pwshHook = Join-Path $repoRoot 'hooks' 'powershell' "$hookName.ps1"
    Write-Host ''
    Write-Host "=== $hookName ==="
    foreach ($caseDir in (Get-ChildItem -LiteralPath $hookDir.FullName -Directory | Sort-Object Name)) {
        $result = Invoke-ConformanceCase -HookName $hookName -CaseDir $caseDir.FullName `
            -BashHook $bashHook -PwshHook $pwshHook
        if ($result.Match) {
            Write-Ok $result.CaseName
        } else {
            Write-Bad $result.CaseName
            Write-CaseDiff $result
        }
    }
}

Write-Host ''
Write-Host "=== Summary: $($script:pass) passed, $($script:fail) failed ==="
if ($script:fail -gt 0) { exit 1 }
exit 0
