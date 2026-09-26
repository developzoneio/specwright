#requires -Version 5.1
<#
.SYNOPSIS
    specwright: SubagentStop hook - subagent-retro.

.DESCRIPTION
    Reads Claude Code hook JSON from stdin. After a subagent finishes:
      1. Loads .claude/project-config.json (or defaults).
      2. Parses .specs/index.md for in-progress specs (skips RCAs - those
         do not require a retro file since the spec itself is the deliverable).
      3. For each in-progress spec, checks the mtime of <spec>/05-retro.md
         against retroStaleMinutes.
      4. Debounces per session by tracking the last reminder time in
         .claude/.hookstate/subagent-retro-<sessionId>.json.
      5. If any stale retros exist AND debounce window has elapsed, emits a
         <retro-reminder> block to stdout.
      6. Cleans up state files older than 24 hours.

.NOTES
    PURE ASCII ONLY. See prompt-router.ps1 for the rationale.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'

function Read-StdinJson {
    try {
        $raw = [Console]::In.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
}

# SW-78: `cwd` is the session's CURRENT directory, and a Bash `cd` moves it.
# Reading config, specs, hook state and the metrics log relative to it made a
# session sitting in a subdirectory miss every spec and grow a nested
# .specs/_metrics/ and .claude/.hookstate/ there.
# Every project path is therefore resolved against the project root:
#   1. CLAUDE_PROJECT_DIR (set by Claude Code for hooks), when it is a directory.
#   2. The nearest ancestor of Cwd (Cwd included) holding .claude/project-config.json.
#   3. The nearest ancestor of Cwd holding a .specs/ directory.
#   4. Cwd itself - the pre-SW-78 behaviour.
# Step 2 walks the whole chain before step 3 starts, so a stray nested .specs/
# left behind by an older hook cannot shadow a configured root. Identical in all
# three hooks; mirrors resolve_project_root in the .sh twins.
function Resolve-ProjectRoot {
    param([string]$Cwd)
    $envRoot = $env:CLAUDE_PROJECT_DIR
    if (-not [string]::IsNullOrWhiteSpace($envRoot) -and (Test-Path -LiteralPath $envRoot -PathType Container)) {
        return $envRoot
    }
    $start = $Cwd.TrimEnd('/', '\')
    if ($start.Length -eq 0) { return $Cwd }
    $markers = @(
        @{ Rel = '.claude/project-config.json'; Type = 'Leaf' },
        @{ Rel = '.specs'; Type = 'Container' }
    )
    foreach ($m in $markers) {
        $dir = $start
        for ($i = 0; $i -lt 64 -and -not [string]::IsNullOrEmpty($dir); $i++) {
            if (Test-Path -LiteralPath (Join-Path $dir $m.Rel) -PathType $m.Type) { return $dir }
            $parent = [System.IO.Path]::GetDirectoryName($dir)
            if ([string]::IsNullOrEmpty($parent) -or $parent -eq $dir) { break }
            $dir = $parent
        }
    }
    return $Cwd
}

function Get-ProjectConfig {
    param([string]$Root)

    $defaults = [pscustomobject]@{
        spec  = [pscustomobject]@{
            dir       = '.specs'
            indexFile = '.specs/index.md'
        }
        hooks = [pscustomobject]@{
            subagentRetro = [pscustomobject]@{
                enabled           = $true
                retroStaleMinutes = 30
                debounceMinutes   = 10
            }
            metrics = [pscustomobject]@{ enabled = $true; path = '.specs/_metrics/events.jsonl'; maxSizeKb = 1024 }
        }
    }

    $cfgPath = Join-Path $Root '.claude/project-config.json'
    if (-not (Test-Path -LiteralPath $cfgPath)) { return $defaults }
    # -ErrorAction Stop is required: the script-wide SilentlyContinue preference
    # would otherwise make a malformed config a NON-terminating error, so the
    # catch never fires and the function returns $null instead of the defaults.
    try {
        $loaded = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $loaded) { return $defaults }
        return $loaded
    } catch {
        return $defaults
    }
}

function Test-IsRootedPath {
    param([string]$Path)
    # Mirrors spec-gate.sh's rootedness test ("${fp}" != /* && "${fp}" != ?:*),
    # evaluated on the RAW path (before backslash->slash conversion): a leading
    # '/' or a drive-letter prefix like 'C:' is rooted, anything else - a plain
    # relative path such as 'src/../.specs/constitution.md' - is not.
    if ([string]::IsNullOrEmpty($Path)) { return $false }
    if ($Path[0] -eq '/') { return $true }
    if ($Path.Length -ge 2 -and $Path[1] -eq ':') { return $true }
    return $false
}

function ConvertTo-CollapsedPath {
    param([string]$Path)
    # Pure string-based collapse of '.' and '..' segments on a forward-slash
    # path - no filesystem access, no .NET path resolution. This mirrors
    # collapse_dot_segments in spec-gate.sh exactly, including:
    #   - a rooted path (leading '/' or a drive prefix 'C:/') clamps a '..' at
    #     its own root instead of walking above it;
    #   - an unrooted path with nothing to clamp against keeps an unresolved
    #     leading '..' rather than discarding it;
    #   - an empty segment (produced by '//' or by a TRAILING separator, e.g.
    #     ".specs/constitution.md/") is a no-op, same as a '.' segment - this
    #     is what makes a trailing separator collapse away instead of
    #     defeating the later exact-match comparison against paths.protected.
    $rootPrefix = ''
    $body = $Path
    $rooted = $false
    if ($Path.StartsWith('/')) {
        $rootPrefix = '/'
        $body = $Path.Substring(1)
        $rooted = $true
    } elseif ($Path.Length -ge 2 -and $Path[1] -eq ':') {
        $rootPrefix = $Path.Substring(0, 2) + '/'
        $body = $Path.Substring(2)
        if ($body.StartsWith('/')) { $body = $body.Substring(1) }
        $rooted = $true
    }

    $acc = ''
    foreach ($seg in $body -split '/') {
        if ($seg -eq '' -or $seg -eq '.') {
            continue
        }
        if ($seg -eq '..') {
            if ($acc -ne '') {
                $lastSlash = $acc.LastIndexOf('/')
                if ($lastSlash -ge 0) { $last = $acc.Substring($lastSlash + 1) } else { $last = $acc }
                if ($last -eq '..') {
                    # Already-stacked leading '..' (unrooted overflow) - keep stacking.
                    $acc = "$acc/.."
                } elseif ($lastSlash -ge 0) {
                    $acc = $acc.Substring(0, $lastSlash)
                } else {
                    # acc was a single segment with no slash - pop to empty.
                    $acc = ''
                }
            } elseif ($rooted) {
                # Cannot go above the root - drop it, matching the bash clamp.
            } else {
                # No root to clamp against - keep the unresolved '..'.
                $acc = '..'
            }
        } else {
            if ($acc -eq '') { $acc = $seg } else { $acc = "$acc/$seg" }
        }
    }

    return "$rootPrefix$acc"
}

function Test-MetricsPathSafe {
    param([string]$RelPath)
    # A metrics path is not an arbitrary-write primitive: reject anything
    # rooted (absolute, or a drive-letter path) or that escapes Root via '..'
    # rather than ever writing outside the workspace. Reuses the same
    # rootedness test and dot-segment collapse used for the gate's own path
    # safety above, so the two safety checks cannot silently diverge.
    if ([string]::IsNullOrWhiteSpace($RelPath)) { return $false }
    if (Test-IsRootedPath -Path $RelPath) { return $false }
    $collapsed = ConvertTo-CollapsedPath -Path ($RelPath.Replace('\','/'))
    if ($collapsed -eq '..' -or $collapsed.StartsWith('../')) { return $false }
    return $true
}

function Write-MetricEvent {
    param(
        [string]$Root,
        [object]$Config,
        [string]$SpecId,
        [string]$Phase,
        [string]$EventKind,
        [System.Collections.Specialized.OrderedDictionary]$Fields
    )
    # Fully wrapped: a metrics failure must NEVER surface as a hook error or
    # change a gate decision. Every call site invokes this AFTER the decision
    # is already computed (and, for a block, already written to stdout) -
    # never from inside the decision path itself.
    try {
        $enabled = $true
        # Type-strict: only a literal JSON boolean false disables metrics -
        # copies the verifyGate `-is [bool]` pattern above so a string
        # "false" in project-config.json leaves metrics on, matching
        # spec-gate.sh's `== false` jq comparison.
        if (($Config.hooks.metrics.enabled -is [bool]) -and (-not $Config.hooks.metrics.enabled)) {
            $enabled = $false
        }
        if (-not $enabled) { return }

        $relPath = '.specs/_metrics/events.jsonl'
        try { if ($Config.hooks.metrics.path) { $relPath = [string]$Config.hooks.metrics.path } } catch { }
        $relPath = $relPath.Replace('\','/')

        if (-not (Test-MetricsPathSafe -RelPath $relPath)) { return }

        $fullPath = Join-Path $Root $relPath
        $parent = Split-Path -Path $fullPath -Parent
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
        }

        # [ordered] (not a plain hashtable) so ConvertTo-Json emits keys in
        # the exact insertion order below - a plain hashtable does not
        # guarantee enumeration order, which would let the two
        # implementations drift apart on key order for the same input.
        $ordered = [ordered]@{}
        $ordered['ts']      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $ordered['spec_id'] = $SpecId
        $ordered['phase']   = $Phase
        $ordered['event']   = $EventKind
        foreach ($key in $Fields.Keys) { $ordered[$key] = $Fields[$key] }

        $line = ([pscustomobject]$ordered) | ConvertTo-Json -Compress

        # --- rotation (SW-15) --------------------------------------------------
        # Bounded log: before appending, if the live file already meets or
        # exceeds the byte cap, roll it to '.1' (single generation, overwriting
        # any prior roll). maxSizeKb defaults to 1024 when the key is ABSENT, so
        # a project-config.json written before SW-15 still gets a bounded log
        # with no edit; an explicit 0 or negative disables rotation (the opt-out)
        # and any non-number is invalid and also disables it (SW-22 scar - never
        # let a bad type silently flip behavior). Best-effort - the Move-Item has
        # its own -ErrorAction Stop / catch so a file the other hook holds open
        # on Windows, or a read-only dir, is a silent no-op that falls through to
        # the append below: rotation must NEVER stop the append (silent data loss
        # reads as "metrics working", which the ticket flags as worse than
        # growth) nor surface as a hook error. (Get-Item).Length is the raw byte
        # count matching bash's `wc -c`, and the absent->1024 / bad-type->off
        # rules match subagent-retro.sh's jq, so PS and bash trip at the same
        # boundary.
        try {
            $maxKb = 1024
            $m = $Config.hooks.metrics
            if (($null -ne $m) -and ($m.PSObject.Properties.Name -contains 'maxSizeKb')) {
                $maxKb = $m.maxSizeKb
            }
            if (($maxKb -is [int] -or $maxKb -is [long] -or $maxKb -is [double]) -and ($maxKb -gt 0)) {
                $maxBytes = [long][math]::Floor([double]$maxKb * 1024)
                if (Test-Path -LiteralPath $fullPath) {
                    if ((Get-Item -LiteralPath $fullPath).Length -ge $maxBytes) {
                        Move-Item -LiteralPath $fullPath -Destination "$fullPath.1" -Force -ErrorAction Stop
                    }
                }
            }
        } catch { }

        # Add-Content opens and closes the file handle per call and is not
        # safe against the concurrent PreToolUse + SubagentStop appends this
        # log can see; retry briefly on a transient sharing violation instead
        # of failing loudly.
        $attempt = 0
        while ($attempt -lt 5) {
            try {
                # UTF8Encoding($false): NO byte-order-mark. [Encoding]::UTF8
                # writes a BOM preamble on the FIRST write to a new/empty
                # file, which subagent-retro.sh's plain `>>` append never
                # does - that would make the two implementations' first line
                # differ by 3 bytes for the exact same input.
                [System.IO.File]::AppendAllText($fullPath, "$line`n", (New-Object System.Text.UTF8Encoding($false)))
                break
            } catch {
                $attempt++
                if ($attempt -ge 5) { break }
                Start-Sleep -Milliseconds 20
            }
        }
    } catch { }
}

function Write-SubagentStopMetric {
    param(
        [string]$Root,
        [object]$Config,
        [string]$SpecId,
        [string]$Phase,
        [int]$Stale
    )
    $fields = [ordered]@{ stale = $Stale }
    Write-MetricEvent -Root $Root -Config $Config -SpecId $SpecId -Phase $Phase -EventKind 'subagent_stop' -Fields $fields
}

function Get-IndexSpecs {
    param([string]$IndexPath, [string]$Prefixes)
    # Returns array of objects: @{Id, Type, Status}
    $result = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $IndexPath)) { return $result }
    try {
        $lines = Get-Content -LiteralPath $IndexPath -Encoding UTF8 -ErrorAction Stop
    } catch {
        return $result
    }
    foreach ($line in $lines) {
        if ($line -match 'in-progress' -and $line -match "($Prefixes)-[A-Za-z0-9_\-]+") {
            $id = $Matches[0]
            $type = ($id -split '-')[0]
            $obj = [pscustomobject]@{
                Id     = $id
                Type   = $type
                Status = 'in-progress'
            }
            $result.Add($obj) | Out-Null
        }
    }
    return $result
}

# --- spec prefix alternation (SW-44) ------------------------------------------
# Built-in fallback covers every prefix shipped in
# templates/project-config.template.json (FEAT, BUG, REF, PERF, RCA, PORT).
# Any config-declared prefix that fails the shape check
# ^[A-Z][A-Z0-9]{1,9}$ is dropped silently and the built-in default is used
# only if NOTHING declared validates. Must stay in sync with
# resolve_spec_prefixes in subagent-retro.sh.
$script:DefaultSpecPrefixes = @('FEAT','BUG','REF','PERF','RCA','PORT')

function Get-SpecPrefixAlternation {
    param([object]$Config)
    $raw = $null
    try { $raw = $Config.spec.prefixes } catch { $raw = $null }
    if ($null -eq $raw) {
        return ($script:DefaultSpecPrefixes -join '|')
    }
    $valid = New-Object System.Collections.Generic.List[string]
    foreach ($prop in $raw.PSObject.Properties) {
        $val = [string]$prop.Value
        if ($val -match '^[A-Z][A-Z0-9]{1,9}$') {
            $valid.Add($val)
        }
    }
    if ($valid.Count -eq 0) {
        return ($script:DefaultSpecPrefixes -join '|')
    }
    return ($valid -join '|')
}

function Get-StaleRetros {
    param(
        [string]$SpecDir,
        $Specs,
        [int]$StaleMinutes
    )
    $stale = New-Object System.Collections.Generic.List[object]
    $now = Get-Date
    foreach ($spec in $Specs) {
        if ($spec.Type -eq 'RCA') { continue }  # RCAs are their own deliverable
        $retroPath = Join-Path $SpecDir (Join-Path $spec.Id '05-retro.md')
        if (-not (Test-Path -LiteralPath $retroPath)) {
            $stale.Add([pscustomobject]@{ Id = $spec.Id; Reason = 'missing'; AgeMinutes = -1 }) | Out-Null
            continue
        }
        try {
            $mtime = (Get-Item -LiteralPath $retroPath).LastWriteTime
            $ageMin = [int]([Math]::Round(($now - $mtime).TotalMinutes))
            if ($ageMin -ge $StaleMinutes) {
                $stale.Add([pscustomobject]@{ Id = $spec.Id; Reason = 'stale'; AgeMinutes = $ageMin }) | Out-Null
            }
        } catch { }
    }
    return $stale
}

# Read once, written once - mirrors the single state read in subagent-retro.sh.
# The state file is an ON-DISK CONTRACT shared with that twin and carries two
# keys: lastReminderUtc (debounce stamp) and shownLessons (lesson lines already
# surfaced in THIS session). Both writers must preserve the key they are not
# updating, or a reminder would wipe the session's lesson history and every
# lesson would repeat.
function Read-State {
    param([string]$StatePath)

    $result = [pscustomobject]@{
        LastIso = ''
        Shown   = (New-Object 'System.Collections.Generic.List[string]')
    }
    if (-not (Test-Path -LiteralPath $StatePath)) { return $result }
    try {
        $st = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        # PowerShell 7's ConvertFrom-Json auto-converts an ISO-8601 "...Z" string to a
        # [datetime] with Kind=Utc; PowerShell 5.1 leaves it as a plain string. Re-Parse-ing
        # an already-converted [datetime] stringifies it with the local culture (dropping the
        # UTC marker), so a later Parse silently re-interprets it as local time - skewing the
        # debounce by the machine's UTC offset. Normalise back to the on-disk format here so
        # everything downstream sees the same plain string the bash twin sees.
        if ($null -ne $st.lastReminderUtc) {
            if ($st.lastReminderUtc -is [datetime]) {
                $result.LastIso = $st.lastReminderUtc.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            } else {
                $result.LastIso = [string]$st.lastReminderUtc
            }
        }
        if ($null -ne $st.shownLessons) {
            foreach ($s in $st.shownLessons) { [void]$result.Shown.Add([string]$s) }
        }
    } catch { }
    return $result
}

function Test-DebounceElapsed {
    param(
        [string]$LastIso,
        [int]$DebounceMinutes
    )
    if ([string]::IsNullOrWhiteSpace($LastIso)) { return $true }
    try {
        $last = [datetimeoffset]::Parse($LastIso).UtcDateTime
        $age = (Get-Date).ToUniversalTime() - $last
        return ($age.TotalMinutes -ge $DebounceMinutes)
    } catch {
        return $true
    }
}

function Save-State {
    param(
        [string]$StatePath,
        [string]$LastIso,
        $Shown
    )
    try {
        # -Path, not -LiteralPath: some PowerShell builds reject -LiteralPath combined
        # with -Parent as an unresolvable parameter set. -Parent does no filesystem
        # globbing (only -Resolve would), so -Path is exactly as safe here.
        $dir = Split-Path -Path $StatePath -Parent
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        # Key order matches the jq object written by subagent-retro.sh. The
        # whole-second UTC format must stay identical in both - 'o' was writing
        # 7 fractional digits that only the bash side ever had to cope with.
        $arr = @()
        if ($null -ne $Shown) { $arr = @($Shown) }
        if ([string]::IsNullOrEmpty($LastIso)) {
            $obj = [pscustomobject]@{ shownLessons = $arr }
        } else {
            $obj = [pscustomobject]@{ lastReminderUtc = $LastIso; shownLessons = $arr }
        }
        $obj | ConvertTo-Json -Compress -Depth 3 | Set-Content -LiteralPath $StatePath -Encoding UTF8
    } catch { }
}

# Lesson selection (SW-19). Returns the lines to surface, in file order.
#
# lessons.md is rendered in a total, deterministic order by aggregate-lessons.*,
# so "the first N that match" is itself deterministic - no sorting is done or
# needed here, and there is no tie-break that could diverge from the bash twin.
# All comparisons are ORDINAL: PowerShell's default -eq is case-insensitive and
# would drop a lesson the bash twin keeps.
function Select-Lessons {
    param(
        [string]$LessonsPath,
        $Specs,
        [int]$MaxLessons,
        $Shown
    )
    $picked = New-Object 'System.Collections.Generic.List[string]'
    if ($MaxLessons -le 0) { return $picked }
    if (-not (Test-Path -LiteralPath $LessonsPath -PathType Leaf)) { return $picked }

    # Scope selector: the workflow types currently in flight, plus 'all'.
    $wanted = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    [void]$wanted.Add('all')
    foreach ($spec in $Specs) {
        switch ($spec.Type) {
            'FEAT' { [void]$wanted.Add('feature') }
            'BUG'  { [void]$wanted.Add('bug') }
            'REF'  { [void]$wanted.Add('refactor') }
            'PERF' { [void]$wanted.Add('perf') }
            'RCA'  { [void]$wanted.Add('rca') }
            'PORT' { [void]$wanted.Add('port') }
        }
    }

    $shownSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    if ($null -ne $Shown) { foreach ($s in $Shown) { [void]$shownSet.Add([string]$s) } }

    $lessonRe = '^- \[([a-z-]+)\] ([a-z]+)/([a-z]+): (.+)$'
    try {
        foreach ($line in (Get-Content -LiteralPath $LessonsPath)) {
            if (-not $line.StartsWith('- [')) { continue }
            if ($line -cnotmatch $lessonRe) { continue }
            if (-not $wanted.Contains($Matches[3])) { continue }
            if ($shownSet.Contains($line)) { continue }

            [void]$picked.Add($line)
            if ($picked.Count -ge $MaxLessons) { break }
        }
    } catch { }
    return $picked
}

function Remove-StaleStateFiles {
    param([string]$StateDir)
    if (-not (Test-Path -LiteralPath $StateDir)) { return }
    $cutoff = (Get-Date).AddHours(-24)
    try {
        $files = Get-ChildItem -LiteralPath $StateDir -File -Filter 'subagent-retro-*.json' -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            if ($f.LastWriteTime -lt $cutoff) {
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    } catch { }
}

# ---- main ----

$hookInput = Read-StdinJson
if ($null -eq $hookInput) { exit 0 }

$cwd = $hookInput.cwd
if ([string]::IsNullOrWhiteSpace($cwd)) { $cwd = (Get-Location).Path }
if (-not (Test-Path -LiteralPath $cwd)) { exit 0 }
$projectRoot = Resolve-ProjectRoot -Cwd $cwd

$sessionId = $hookInput.session_id
if ([string]::IsNullOrWhiteSpace($sessionId)) { $sessionId = 'no-session' }

$config = Get-ProjectConfig -Root $projectRoot
try {
    # Type-strict: only a literal JSON boolean false disables the hook. A plain
    # `-not ...enabled` fires on an ABSENT key ($null), silently disabling the
    # hook when a hand-trimmed config carries a subagentRetro block with no
    # `enabled` - diverging from subagent-retro.sh's `== false`, which leaves it
    # on. -is [bool] matches jq (SW-22); mirrors the metrics/injectLessons reads.
    if (($config.hooks.subagentRetro.enabled -is [bool]) -and (-not $config.hooks.subagentRetro.enabled)) {
        exit 0
    }
} catch { }

$staleMinutes    = 30
$debounceMinutes = 10
# `$null -ne`, NOT a truthiness test: PowerShell treats 0 as falsy, so
# `if ($config...retroStaleMinutes)` would silently ignore an explicit 0 and keep
# the default while the bash twin's `// 30` / `// 10` accept 0. Mirrors the
# maxLessons read that SW-19 already fixed for exactly this reason (SW-22).
try { if ($null -ne $config.hooks.subagentRetro.retroStaleMinutes) { $staleMinutes = [int]$config.hooks.subagentRetro.retroStaleMinutes } } catch { }
try { if ($null -ne $config.hooks.subagentRetro.debounceMinutes)   { $debounceMinutes = [int]$config.hooks.subagentRetro.debounceMinutes } } catch { }

# Lesson injection (SW-19). Same explicit-false handling as the enabled flag:
# an absent key means on, only a literal false turns it off.
$injectLessons = $true
$maxLessons    = 3
try { if ($null -ne $config.hooks.subagentRetro.injectLessons -and -not $config.hooks.subagentRetro.injectLessons) { $injectLessons = $false } } catch { }
# `$null -ne`, NOT a truthiness test: PowerShell treats 0 as falsy, so
# `if ($config...maxLessons)` would silently ignore an explicit 0 and keep the
# default of 3 while the bash twin's `// 3` accepts 0 and goes quiet. A
# non-numeric or negative value falls back to 3 in both, matching the bash
# `^[0-9]+$` guard.
try {
    if ($null -ne $config.hooks.subagentRetro.maxLessons) {
        $maxLessons = [int]$config.hooks.subagentRetro.maxLessons
    }
} catch { $maxLessons = 3 }
if ($maxLessons -lt 0) { $maxLessons = 3 }

$specDir   = if ($config.spec.dir)       { Join-Path $projectRoot $config.spec.dir }       else { Join-Path $projectRoot '.specs' }
$indexFile = if ($config.spec.indexFile) { Join-Path $projectRoot $config.spec.indexFile } else { Join-Path $projectRoot '.specs/index.md' }
$stateDir    = Join-Path $projectRoot '.claude/.hookstate'
$safeId      = ($sessionId -replace '[^A-Za-z0-9_\-]','_')
$statePath   = Join-Path $stateDir ("subagent-retro-$safeId.json")
$lessonsPath = Join-Path $specDir (Join-Path '_lessons' 'lessons.md')

# Read THIS session's state before the sweep, as subagent-retro.sh does
# (state read at the top, >24h cleanup later). Sweeping first deleted a session
# state file older than 24h before it was read, so shownLessons was forgotten
# and already-shown lessons were surfaced again - a twin divergence the
# lessons-already-shown fixture caught once its checkout was a day old.
$state = Read-State -StatePath $statePath

Remove-StaleStateFiles -StateDir $stateDir

$specPrefixes = Get-SpecPrefixAlternation -Config $config
$specs = Get-IndexSpecs -IndexPath $indexFile -Prefixes $specPrefixes
if ($specs.Count -eq 0) { exit 0 }

$stale = Get-StaleRetros -SpecDir $specDir -Specs $specs -StaleMinutes $staleMinutes

# Metrics: one subagent_stop event per in-progress spec, emitted regardless
# of staleness or debounce - debounce below only suppresses the user-facing
# reminder, never this measurement (SW-10). A spec not in $stale (including
# every RCA, which Get-StaleRetros always skips) reports stale=0.
$staleIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($s in $stale) { [void]$staleIds.Add($s.Id) }
foreach ($spec in $specs) {
    $staleCount = if ($staleIds.Contains($spec.Id)) { 1 } else { 0 }
    Write-SubagentStopMetric -Root $projectRoot -Config $config -SpecId $spec.Id -Phase 'in-progress' -Stale $staleCount
}

# --- lesson injection (SW-19) ---
#
# PLACEMENT IS LOAD-BEARING. This sits beside the metrics emit above, BEFORE the
# staleness early-exit and BEFORE the debounce window - deliberately, and for the
# same reason the metrics call site does. Moved down to the reminder block, it
# would only ever surface lessons to users who are already behind on their
# retros, which is exactly the population that needs them least.
#
# The one gate it keeps is the in-progress-spec check above: no spec in flight,
# no output. That gate IS the relevance filter - the workflow type of the
# in-progress spec selects which lessons apply.
#
# Repetition is bounded per SESSION, not by a clock. shownLessons records what
# has already been surfaced, so maxLessons caps how many NEW lessons appear at
# one stop and a session converges to silence once it has said everything
# relevant. A time debounce was rejected: it would suppress a lesson the user
# has never seen purely because a different one was shown recently.
if ($injectLessons) {
    $picked = Select-Lessons -LessonsPath $lessonsPath -Specs $specs -MaxLessons $maxLessons -Shown $state.Shown
    if ($picked.Count -gt 0) {
        $lessonLines = New-Object System.Collections.Generic.List[string]
        $lessonLines.Add('<retro-lessons>') | Out-Null
        $lessonLines.Add('Lessons recorded in earlier retros of this project, matching the workflow') | Out-Null
        $lessonLines.Add('type of the spec(s) currently in progress:') | Out-Null
        foreach ($p in $picked) { $lessonLines.Add("  $p") | Out-Null }
        $lessonLines.Add('') | Out-Null
        $lessonLines.Add('These are not shown again this session.') | Out-Null
        $lessonLines.Add('</retro-lessons>') | Out-Null

        # Write, not WriteLine: WriteLine appends [Environment]::NewLine, which is
        # CRLF on Windows, so the final line would differ from the bash twin by
        # exactly one byte and fail the conformance comparison. The body is
        # already LF-joined; terminate it the same way.
        [Console]::Out.Write(($lessonLines -join "`n") + "`n")

        foreach ($p in $picked) { [void]$state.Shown.Add($p) }
        Save-State -StatePath $statePath -LastIso $state.LastIso -Shown $state.Shown
    }
}

if ($stale.Count -eq 0) { exit 0 }

if (-not (Test-DebounceElapsed -LastIso $state.LastIso -DebounceMinutes $debounceMinutes)) { exit 0 }

# Emit reminder
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('<retro-reminder>') | Out-Null
$lines.Add('Retro files appear stale or missing for the following in-progress specs:') | Out-Null
foreach ($s in $stale) {
    if ($s.Reason -eq 'missing') {
        $lines.Add("  - $($s.Id): 05-retro.md missing") | Out-Null
    } else {
        $lines.Add("  - $($s.Id): 05-retro.md last touched $($s.AgeMinutes) min ago (threshold $staleMinutes min)") | Out-Null
    }
}
$lines.Add('') | Out-Null
$lines.Add('Consider appending: decisions made, surprises encountered, follow-ups identified.') | Out-Null
$lines.Add('</retro-reminder>') | Out-Null

# Write, not WriteLine - see the note on the lesson block above. This block had
# the same one-byte CRLF divergence from the bash twin before SW-19.
[Console]::Out.Write(($lines -join "`n") + "`n")

# Re-emits shownLessons alongside the new stamp - dropping it here would clear
# the session's lesson history and make every lesson repeat.
$stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
Save-State -StatePath $statePath -LastIso $stamp -Shown $state.Shown
exit 0
