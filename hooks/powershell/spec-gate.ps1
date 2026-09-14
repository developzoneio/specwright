#requires -Version 5.1
<#
.SYNOPSIS
    specwright: PreToolUse hook - spec-gate.

.DESCRIPTION
    Reads Claude Code hook JSON from stdin. If the tool is Edit / Write /
    MultiEdit, the hook decides whether the edit is allowed:
      - Edits to paths listed under paths.protected -> ALWAYS blocked.
      - Edits to allow-listed paths (.specs/, .claude/, tests/, *.md, *.json,
        *.yaml, README, CHANGELOG, LICENSE) -> always allowed.
      - Edits to code files (cs, ts, py, rs, go, java, kt, rb, php, swift,
        cpp, c, h, hpp, scala, js, jsx, tsx, vue, sql) -> require an
        in-progress spec recorded in .specs/index.md.
          mode=block -> output block JSON to stdout (see Write-BlockDecision).
          mode=warn  -> write a warning to stderr; allow the edit.
          mode=off   -> always allow.

    Output schema (dual-format for forward + backward compatibility):
      New:    hookSpecificOutput.permissionDecision = "deny"   (CLI >= schema v2)
      Legacy: decision = "block"                               (CLI < schema v2)
    Both are emitted in the same JSON object so either CLI generation can act.

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

function Get-ProjectConfig {
    param([string]$Cwd)

    $defaults = [pscustomobject]@{
        spec  = [pscustomobject]@{
            dir       = '.specs'
            indexFile = '.specs/index.md'
        }
        paths = [pscustomobject]@{
            protected = @('.specs/constitution.md','.specs/index.md','LICENSE')
        }
        hooks = [pscustomobject]@{
            specGate = [pscustomobject]@{ enabled = $true; mode = 'warn' }
            metrics  = [pscustomobject]@{ enabled = $true; path = '.specs/_metrics/events.jsonl'; maxSizeKb = 1024 }
        }
    }

    $cfgPath = Join-Path $Cwd '.claude/project-config.json'
    if (-not (Test-Path -LiteralPath $cfgPath)) { return $defaults }

    # -ErrorAction Stop is required: the script-wide SilentlyContinue preference
    # would otherwise make a malformed config a NON-terminating error, so the
    # catch never fires and the function returns $null instead of the defaults -
    # silently dropping the built-in protected paths.
    try {
        $loaded = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $loaded) { return $defaults }
        return $loaded
    } catch {
        return $defaults
    }
}

# --- spec prefix alternation (SW-44) ------------------------------------------
# Built-in fallback covers every prefix shipped in
# templates/project-config.template.json (FEAT, BUG, REF, PERF, RCA, PORT).
# Any config-declared prefix that fails the shape check
# ^[A-Z][A-Z0-9]{1,9}$ is dropped silently and the built-in default is used
# only if NOTHING declared validates - a config with one bad entry among
# good ones still uses the good ones. Must stay in sync with
# resolve_spec_prefixes in spec-gate.sh.
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

# Single-prefix lookup (used by Write-ComplexitySplitMetrics, which is
# deliberately scoped to the 'feature' prefix only - see that function's
# comment). Falls back to $DefaultValue when the key is absent or the
# declared value fails the same shape check as Get-SpecPrefixAlternation.
function Get-SpecPrefixValue {
    param([object]$Config, [string]$Key, [string]$DefaultValue)
    try {
        $val = $Config.spec.prefixes.$Key
        if ($val -and ([string]$val -match '^[A-Z][A-Z0-9]{1,9}$')) {
            return [string]$val
        }
    } catch { }
    return $DefaultValue
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

function ConvertTo-RelativePath {
    param(
        [string]$Cwd,
        [string]$FilePath
    )
    if ([string]::IsNullOrWhiteSpace($FilePath)) { return $null }
    try {
        # If FilePath is not rooted (no leading '/' and no drive-letter prefix
        # such as 'C:'), it is already relative to Cwd by construction, so
        # collapsing its own dot segments directly yields the correct
        # relative-to-Cwd path. Joining it onto Cwd and calling
        # [System.IO.Path]::GetFullPath would resolve against THIS SCRIPT
        # PROCESS's own working directory instead of the hook payload's Cwd -
        # that mismatch was the root cause of the
        # 'src/../.specs/constitution.md' traversal bypass, since the
        # resulting absolute path never started with $base and fell through
        # to the raw-path fallback below. This mirrors spec-gate.sh's
        # normalize_rel first branch exactly.
        if (-not (Test-IsRootedPath $FilePath)) {
            return ConvertTo-CollapsedPath -Path ($FilePath.Replace('\','/'))
        }

        # Collapse '.'/'..' BEFORE the prefix strip, so a path that traverses
        # through a directory and back (e.g. cwd/src/../.specs/x) is compared
        # against base in its fully-resolved form, not its literal typed form.
        # A trailing separator collapses away here too (see
        # ConvertTo-CollapsedPath), which fixes the second bypass: without
        # this, [System.IO.Path]::GetExtension on a path ending in '/' or '\'
        # returns "" and the path escapes both the protected-path equality
        # check and the code-file extension check.
        $fpRaw = $FilePath.Replace('\','/')
        $baseNorm = $Cwd.Replace('\','/')
        $fpNorm = ConvertTo-CollapsedPath -Path $fpRaw
        $baseCollapsed = ConvertTo-CollapsedPath -Path $baseNorm

        if ($fpNorm.StartsWith($baseCollapsed, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rel = $fpNorm.Substring($baseCollapsed.Length).TrimStart('/')
            return $rel
        }
        # Resolving FilePath lands outside Cwd entirely (e.g. enough leading
        # '..' to escape the workspace) - fall back to the raw, un-collapsed
        # path, same as spec-gate.sh's normalize_rel fallback branch.
        return $fpRaw
    } catch {
        return $FilePath.Replace('\','/')
    }
}

function Test-IsProtected {
    param(
        [string]$RelPath,
        [string[]]$Protected
    )
    if (-not $Protected) { return $false }
    foreach ($p in $Protected) {
        $norm = $p.Replace('\','/')
        if ([string]::Equals($RelPath, $norm, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-IsAllowListed {
    param([string]$RelPath)
    $allowDirs = @('.specs/', '.claude/', 'tests/', 'test/', 'docs/', 'spec/')
    foreach ($d in $allowDirs) {
        if ($RelPath.StartsWith($d, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    # Only EXTENSION-LESS project files are allow-listed by name; anything with
    # an extension is decided by the extension rules below. The old pattern
    # accepted one optional extension, which allow-listed README.py outright and
    # (having no multi-dot form) split hairs over README.old.py. Neither should
    # bypass the gate - they are source files whatever they are called.
    $name = [System.IO.Path]::GetFileName($RelPath)
    if ($name -match '^(README|CHANGELOG|CONTRIBUTING|LICENSE|NOTICE|AUTHORS)$') { return $true }

    $ext = [System.IO.Path]::GetExtension($RelPath).ToLowerInvariant()
    $docExts = @('.md','.markdown','.txt','.rst','.adoc','.json','.yaml','.yml','.toml','.ini','.env','.example')
    if ($docExts -contains $ext) { return $true }
    return $false
}

function Test-IsCodeFile {
    param([string]$RelPath)
    $ext = [System.IO.Path]::GetExtension($RelPath).ToLowerInvariant()
    $codeExts = @(
        '.cs','.fs','.vb',
        '.ts','.tsx','.js','.jsx','.mjs','.cjs','.vue','.svelte',
        '.py','.pyi',
        '.rs',
        '.go',
        '.java','.kt','.kts','.scala',
        '.rb','.php',
        '.swift','.m','.mm',
        '.c','.h','.cpp','.cxx','.cc','.hpp','.hxx',
        '.sql','.ps1','.sh','.bash','.zsh',
        '.razor','.cshtml'
    )
    return ($codeExts -contains $ext)
}

function Get-InProgressSpecs {
    param([string]$IndexPath, [string]$Prefixes)
    $result = New-Object System.Collections.Generic.List[string]
    if (-not (Test-Path -LiteralPath $IndexPath)) { return $result }
    try {
        $lines = Get-Content -LiteralPath $IndexPath -Encoding UTF8 -ErrorAction Stop
    } catch {
        return $result
    }
    foreach ($line in $lines) {
        if ($line -match 'in-progress' -and $line -match "($Prefixes)-[A-Za-z0-9_\-]+") {
            $result.Add($Matches[0]) | Out-Null
        }
    }
    return $result
}

function Get-DoneTransitionIds {
    param(
        [object]$HookInput,
        [string]$IndexPath
    )
    # IDs that the pending edit marks as done but that the on-disk index does
    # not yet record as done. Fragments are the tool-specific NEW content.
    # FEAT- only (see Rule 0 comment below): the id extraction here is
    # DELIBERATELY narrower than Rule 3's in-progress scan.
    $fragments = New-Object System.Collections.Generic.List[string]
    try {
        $tool = $HookInput.tool_name
        if ($tool -eq 'Edit') {
            if ($HookInput.tool_input.new_string) {
                $fragments.Add([string]$HookInput.tool_input.new_string) | Out-Null
            }
        } elseif ($tool -eq 'Write') {
            if ($HookInput.tool_input.content) {
                $fragments.Add([string]$HookInput.tool_input.content) | Out-Null
            }
        } elseif ($tool -eq 'MultiEdit') {
            foreach ($e in @($HookInput.tool_input.edits)) {
                if ($e.new_string) { $fragments.Add([string]$e.new_string) | Out-Null }
            }
        }
    } catch { }

    $alreadyDone = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    if (Test-Path -LiteralPath $IndexPath) {
        try {
            foreach ($line in (Get-Content -LiteralPath $IndexPath -Encoding UTF8 -ErrorAction Stop)) {
                if ($line -match '\|\s*done\s*\|' -and $line -match 'FEAT-[A-Za-z0-9_\-]+') {
                    [void]$alreadyDone.Add($Matches[0])
                }
            }
        } catch { }
    }

    $result = New-Object System.Collections.Generic.List[string]
    foreach ($frag in $fragments) {
        foreach ($line in ($frag -split "`n")) {
            if ($line -match '\|\s*done\s*\|' -and $line -match 'FEAT-[A-Za-z0-9_\-]+') {
                $id = $Matches[0]
                if (-not $alreadyDone.Contains($id) -and -not $result.Contains($id)) {
                    $result.Add($id) | Out-Null
                }
            }
        }
    }
    return ,$result
}

function Get-SpecStatusTransitions {
    param(
        [object]$HookInput,
        [string]$IndexPath,
        [string]$Prefixes
    )
    # Read-only, general-purpose lifecycle scan (all configured prefixes x all
    # 5 statuses) that backs the observational spec_transition metric. This is
    # DELIBERATELY a separate function from Get-DoneTransitionIds above - that
    # one is FEAT-/done-only and backs the live Rule 0 gate decision (see its
    # Rule 0 scope comment). Folding the two together would make a future
    # edit to either accidentally change the other's behavior.
    $result = New-Object System.Collections.Generic.List[object]
    try {
        $rowPattern = "\|\s*((?:$Prefixes)-[A-Za-z0-9_\-]+)\s*\|\s*[^|]*\|\s*(draft|approved|in-progress|done|archived)\s*\|"

        # Statuses recorded on disk BEFORE this pending edit lands - PreToolUse
        # runs before the write, so the file still reflects the prior state.
        $oldStatus = @{}
        if (Test-Path -LiteralPath $IndexPath) {
            try {
                foreach ($line in (Get-Content -LiteralPath $IndexPath -Encoding UTF8 -ErrorAction Stop)) {
                    if ($line -match $rowPattern) { $oldStatus[$Matches[1]] = $Matches[2] }
                }
            } catch { }
        }

        $fragments = New-Object System.Collections.Generic.List[string]
        $tool = $HookInput.tool_name
        if ($tool -eq 'Edit') {
            if ($HookInput.tool_input.new_string) { $fragments.Add([string]$HookInput.tool_input.new_string) | Out-Null }
        } elseif ($tool -eq 'Write') {
            if ($HookInput.tool_input.content) { $fragments.Add([string]$HookInput.tool_input.content) | Out-Null }
        } elseif ($tool -eq 'MultiEdit') {
            foreach ($e in @($HookInput.tool_input.edits)) {
                if ($e.new_string) { $fragments.Add([string]$e.new_string) | Out-Null }
            }
        }

        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        foreach ($frag in $fragments) {
            foreach ($line in ($frag -split "`n")) {
                if (-not ($line -match $rowPattern)) { continue }
                $id = $Matches[1]
                $newStatus = $Matches[2]
                if ($seen.Contains($id)) { continue }
                [void]$seen.Add($id)
                $from = if ($oldStatus.ContainsKey($id)) { $oldStatus[$id] } else { '-' }
                if ($from -ne $newStatus) {
                    $result.Add([pscustomobject]@{ Id = $id; Phase = $newStatus; From = $from }) | Out-Null
                }
            }
        }
    } catch { }
    return ,$result
}

function Test-MetricsPathSafe {
    param([string]$RelPath)
    # A metrics path is not an arbitrary-write primitive: reject anything
    # rooted (absolute, or a drive-letter path) or that escapes Cwd via '..'
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
        [string]$Cwd,
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

        $fullPath = Join-Path $Cwd $relPath
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
        # rules match spec-gate.sh's jq, so PS and bash trip at the same
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
                # file, which spec-gate.sh's plain `>>` append never does -
                # that would make the two implementations' first line differ
                # by 3 bytes for the exact same input.
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

function Write-GateMetric {
    param(
        [string]$Cwd,
        [object]$Config,
        [string]$SpecId,
        [string]$Phase,
        [string]$Gate,
        [string]$Decision,
        [string]$Ext = ''
    )
    $fields = [ordered]@{ gate = $Gate; decision = $Decision }
    if ($Ext) { $fields['ext'] = $Ext }
    Write-MetricEvent -Cwd $Cwd -Config $Config -SpecId $SpecId -Phase $Phase -EventKind 'gate' -Fields $fields
}

function Write-TransitionMetrics {
    param(
        [string]$Cwd,
        [object]$Config,
        [object[]]$Transitions,
        [string]$Decision
    )
    foreach ($t in $Transitions) {
        $fields = [ordered]@{ from = $t.From; decision = $Decision }
        Write-MetricEvent -Cwd $Cwd -Config $Config -SpecId $t.Id -Phase $t.Phase -EventKind 'spec_transition' -Fields $fields
    }
}

# Gate Complexity (ADR 0002) is decided as model-executed prose inside
# /sd:feature Phase 3 Gate 2 - no hook observes that decision directly. What
# IS observable here is one of its two possible outcomes: an "approve split"
# resolution always leaves a structural trace in THIS index.md edit or an
# earlier one - the parent row moves to 'archived' (commands/feature.md
# Face B, "make the parent an umbrella record") and each child is registered
# under the 'FEAT-<parent>-<slug>' naming convention (feature.md's child-ID
# step). A FEAT-X row newly transitioning to 'archived' alongside any
# already-registered FEAT-X-<slug> row (in the on-disk registry OR this same
# pending edit) is read as a completed split.
#
# This can only ever detect a SPLIT, never a bare trip: Face A (never
# tripped) and Face B "no-split" (tripped, user declined) both leave the
# parent 'in-progress' with no distinguishing mark in index.md, so trip rate
# on its own is not recoverable from this signal. See ADR
# docs/adr/0004-threshold-calibration.md "Scope declined" - deliberately not
# fixed here to avoid making a HARD gate's prose responsible for feeding a
# metrics pipeline the rest of this file keeps strictly hook-authored.
#
# Callers MUST only invoke this on a path where the edit was actually
# ALLOWED through (Rule 0's verify-allow exit, Rule 2's allow-listed exit).
# On a block exit the edit never reached disk, so recording "split" there
# would assert a split that did not happen - never add a call site here on a
# block/deny path.
#
# Scoped to FEAT- parents only: Gate Complexity decompose is a /sd:feature
# mechanism (commands/feature.md Face B); BUG-/REF-/PERF-/RCA- rows can never
# go through it, so matching their prefix too would only add false-positive
# surface for coincidental id-prefix collisions with no corresponding
# real-world case.
function Write-ComplexitySplitMetrics {
    param(
        [string]$Cwd,
        [object]$Config,
        [object[]]$Transitions,
        [string]$IndexPath,
        [object]$HookInput,
        [string]$FeaturePrefix = 'FEAT'
    )
    if (-not $Transitions -or $Transitions.Count -eq 0) { return }
    try {
        # Scoped to the single 'feature' prefix (see the function-level
        # comment above) - not the full multi-prefix alternation, since a
        # split's children always share the parent's own (feature) prefix.
        $rowPattern = "\|\s*($FeaturePrefix-[A-Za-z0-9_\-]+)\s*\|\s*[^|]*\|\s*(draft|approved|in-progress|done|archived)\s*\|"
        $allIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
        if (Test-Path -LiteralPath $IndexPath) {
            try {
                foreach ($line in (Get-Content -LiteralPath $IndexPath -Encoding UTF8 -ErrorAction Stop)) {
                    if ($line -match $rowPattern) { [void]$allIds.Add($Matches[1]) }
                }
            } catch { }
        }

        $fragments = New-Object System.Collections.Generic.List[string]
        $tool = $HookInput.tool_name
        if ($tool -eq 'Edit') {
            if ($HookInput.tool_input.new_string) { $fragments.Add([string]$HookInput.tool_input.new_string) | Out-Null }
        } elseif ($tool -eq 'Write') {
            if ($HookInput.tool_input.content) { $fragments.Add([string]$HookInput.tool_input.content) | Out-Null }
        } elseif ($tool -eq 'MultiEdit') {
            foreach ($e in @($HookInput.tool_input.edits)) {
                if ($e.new_string) { $fragments.Add([string]$e.new_string) | Out-Null }
            }
        }
        foreach ($frag in $fragments) {
            foreach ($line in ($frag -split "`n")) {
                if ($line -match $rowPattern) { [void]$allIds.Add($Matches[1]) }
            }
        }

        foreach ($t in $Transitions) {
            if ($t.Phase -ne 'archived') { continue }
            if ($t.Id -notlike "$FeaturePrefix-*") { continue }
            $childFound = $false
            foreach ($other in $allIds) {
                if ($other -eq $t.Id) { continue }
                if ($other.StartsWith("$($t.Id)-", [System.StringComparison]::Ordinal)) { $childFound = $true; break }
            }
            if ($childFound) {
                Write-GateMetric -Cwd $Cwd -Config $Config -SpecId $t.Id -Phase 'archived' -Gate 'complexity' -Decision 'split'
            }
        }
    } catch { }
}

function Test-VerifyArtifactPass {
    param(
        [string]$Cwd,
        [string]$SpecDir,
        [string]$SpecId
    )
    $artifact = Join-Path $Cwd (Join-Path $SpecDir (Join-Path $SpecId '06-verify.md'))
    if (-not (Test-Path -LiteralPath $artifact)) { return $false }
    try {
        $content = Get-Content -LiteralPath $artifact -Raw -Encoding UTF8 -ErrorAction Stop
    } catch {
        return $false
    }
    return ($content -match '(?im)^result:\s*pass\s*$')
}

function Write-BlockDecision {
    param([string]$Reason)
    # Dual-format: new hookSpecificOutput schema + legacy decision field.
    # The CLI reads whichever field it understands; both are harmless to the other.
    $obj = [pscustomobject]@{
        decision           = 'block'
        reason             = $Reason
        hookSpecificOutput = [pscustomobject]@{
            permissionDecision = 'deny'
            reason             = $Reason
        }
    }
    [Console]::Out.WriteLine(($obj | ConvertTo-Json -Compress))
}

# ---- main ----

$hookInput = Read-StdinJson
if ($null -eq $hookInput) { exit 0 }

$toolName = $hookInput.tool_name
if ($toolName -ne 'Edit' -and $toolName -ne 'Write' -and $toolName -ne 'MultiEdit') { exit 0 }

$cwd = $hookInput.cwd
if ([string]::IsNullOrWhiteSpace($cwd)) { $cwd = (Get-Location).Path }

# SW-50: these two checks are pure string ops with zero I/O, so they run
# BEFORE Get-ProjectConfig (which reads project-config.json from disk).
# Most tool calls in a session never touch a gate-relevant path, so this
# ordering avoids a config-file read on the common case. Mirrors
# spec-gate.sh, which already checked file_path before reading config.
$filePath = $hookInput.tool_input.file_path
if ([string]::IsNullOrWhiteSpace($filePath)) { exit 0 }

$rel = ConvertTo-RelativePath -Cwd $cwd -FilePath $filePath
if ([string]::IsNullOrWhiteSpace($rel)) { exit 0 }

$config = Get-ProjectConfig -Cwd $cwd
$specPrefixes = Get-SpecPrefixAlternation -Config $config
$featurePrefix = Get-SpecPrefixValue -Config $config -Key 'feature' -DefaultValue 'FEAT'

# Hook globally disabled?
try {
    # Type-strict: only a literal JSON boolean false disables the gate. A plain
    # `-not ...enabled` fires on an ABSENT key ($null), silently disabling the
    # gate when a hand-trimmed config carries a specGate block with no `enabled`
    # - diverging from spec-gate.sh's `== false`, which leaves it on. -is [bool]
    # matches jq (SW-22); mirrors the verifyGate/metrics reads below.
    if (($config.hooks.specGate.enabled -is [bool]) -and (-not $config.hooks.specGate.enabled)) {
        exit 0
    }
} catch { }

$mode = 'warn'
try { if ($config.hooks.specGate.mode) { $mode = [string]$config.hooks.specGate.mode } } catch { }
if ($mode -eq 'off') { exit 0 }

# Rule 0: verify gate on the spec index. A row transitioning to done requires
# a passing /sd:verify artifact; a verified close-out is allowed through the
# protected-path rule. Any other direct index edit falls through to Rule 1.
#
# Scope: FEAT- rows only. Bug/refactor/perf/rca workflows do not produce
# 02-tasks.md and never run /sd:verify, so gating them here would hard-STOP
# their close-out at VF002 with no way through. Non-FEAT rows fall through to
# the unconditional Rule 1 protected-path block, exactly as before this
# gate existed - until their workflows integrate /sd:verify (follow-up spec).
#
# Bundled-edit limitation: when every newly-done FEAT row in the pending edit
# has a passing artifact, the WHOLE edit is allowed - including any unrelated
# row changes bundled into the same Write/Edit/MultiEdit. This hook inspects
# only the done-transition lines, not a full diff, so a bundled edit could in
# principle piggyback an unrelated change. Accepted limitation (hook-scale
# diff inspection is out of scope); the /sd:spec registry commands are the
# semantic guard for anything this coarse check cannot see.
$verifyGateOn = $true
try {
    # Type-strict: only a literal JSON boolean false disables the gate. Plain
    # `-eq $false` would also match the JSON STRING "false" (PowerShell coerces
    # a string to bool via -eq's LHS type), diverging from jq's `== false`
    # in spec-gate.sh, which is type-strict and leaves the gate ON for a
    # string value. -is [bool] keeps this branch aligned with jq.
    if (($config.hooks.specGate.verifyGate -is [bool]) -and (-not $config.hooks.specGate.verifyGate)) {
        $verifyGateOn = $false
    }
} catch { }

$indexRel = '.specs/index.md'
try { if ($config.spec.indexFile) { $indexRel = ([string]$config.spec.indexFile).Replace('\','/') } } catch { }
$specDir = '.specs'
try { if ($config.spec.dir) { $specDir = [string]$config.spec.dir } } catch { }

# spec_transition metric: read-only, general lifecycle scan of THIS index.md
# edit. Computed unconditionally (independent of $verifyGateOn and of which
# rule ultimately decides the edit) - it never influences the gate decision,
# only records whatever that decision turns out to be at whichever exit below
# is actually reached. Empty (a no-op below) whenever $rel is not the index.
$transitions = @()
if ([string]::Equals($rel, $indexRel, [System.StringComparison]::OrdinalIgnoreCase)) {
    $transitions = Get-SpecStatusTransitions -HookInput $hookInput -IndexPath (Join-Path $cwd $indexRel) -Prefixes $specPrefixes
}

if ($verifyGateOn -and [string]::Equals($rel, $indexRel, [System.StringComparison]::OrdinalIgnoreCase)) {
    $indexAbs = Join-Path $cwd $indexRel
    $doneIds = Get-DoneTransitionIds -HookInput $hookInput -IndexPath $indexAbs
    if ($doneIds.Count -gt 0) {
        $missing = New-Object System.Collections.Generic.List[string]
        foreach ($id in $doneIds) {
            if (-not (Test-VerifyArtifactPass -Cwd $cwd -SpecDir $specDir -SpecId $id)) {
                $missing.Add($id) | Out-Null
            }
        }
        if ($missing.Count -gt 0) {
            # Ordinal sort (PS 5.1-safe), not culture-aware Sort-Object - matches
            # `LC_ALL=C sort -u` in spec-gate.sh so both implementations order
            # a multi-ID missing list identically regardless of host locale.
            $missingArr = @($missing)
            [Array]::Sort($missingArr, [System.StringComparer]::Ordinal)
            $ids = $missingArr -join ', '
            Write-BlockDecision "spec-gate: index row(s) [$ids] -> done but no passing /sd:verify artifact. Run /sd:verify <spec-ID>; close-out is allowed only after $specDir/<ID>/06-verify.md records 'result: pass'."
            # Metrics are emitted AFTER the block decision above is already
            # written to stdout - never inside the decision path itself.
            # Ordinal-sort a COPY for the metric loop only, so a bundled
            # multi-ID edit emits events in the same order as spec-gate.sh's
            # `LC_ALL=C sort -u` transition_ids - this does not touch
            # $doneIds itself or Get-DoneTransitionIds' own ordering.
            $doneIdsForMetrics = @($doneIds)
            [Array]::Sort($doneIdsForMetrics, [System.StringComparer]::Ordinal)
            foreach ($id in $doneIdsForMetrics) {
                $idDecision = if ($missing.Contains($id)) { 'block' } else { 'allow' }
                Write-GateMetric -Cwd $cwd -Config $config -SpecId $id -Phase 'done' -Gate 'verify' -Decision $idDecision
            }
            Write-TransitionMetrics -Cwd $cwd -Config $config -Transitions $transitions -Decision 'block'
            # No Write-ComplexitySplitMetrics here: the whole edit is denied,
            # so nothing in it - including any bundled parent archive + child
            # registration - actually reached disk. See the function's own
            # comment.
            exit 0
        }
        # Every transitioning spec has a passing artifact - allow the close-out.
        $doneIdsForMetrics = @($doneIds)
        [Array]::Sort($doneIdsForMetrics, [System.StringComparer]::Ordinal)
        foreach ($id in $doneIdsForMetrics) {
            Write-GateMetric -Cwd $cwd -Config $config -SpecId $id -Phase 'done' -Gate 'verify' -Decision 'allow'
        }
        Write-TransitionMetrics -Cwd $cwd -Config $config -Transitions $transitions -Decision 'allow'
        Write-ComplexitySplitMetrics -Cwd $cwd -Config $config -Transitions $transitions -IndexPath $indexAbs -HookInput $hookInput -FeaturePrefix $featurePrefix
        exit 0
    }
}

# Rule 1: protected paths -> always block
$protected = @()
try { if ($config.paths.protected) { $protected = @($config.paths.protected) } } catch { }
if (Test-IsProtected -RelPath $rel -Protected $protected) {
    Write-BlockDecision "spec-gate: '$rel' is listed under paths.protected in .claude/project-config.json. Update via /sd:refactor or an ADR; never edit directly."
    Write-GateMetric -Cwd $cwd -Config $config -SpecId '-' -Phase '-' -Gate 'protected' -Decision 'block'
    Write-TransitionMetrics -Cwd $cwd -Config $config -Transitions $transitions -Decision 'block'
    # No Write-ComplexitySplitMetrics here: the edit is denied, so a detected
    # parent-archive-plus-child pattern in it never reached disk.
    exit 0
}

# Rule 2: allow-listed paths -> always allow
if (Test-IsAllowListed -RelPath $rel) {
    Write-TransitionMetrics -Cwd $cwd -Config $config -Transitions $transitions -Decision 'allow'
    Write-ComplexitySplitMetrics -Cwd $cwd -Config $config -Transitions $transitions -IndexPath (Join-Path $cwd $indexRel) -HookInput $hookInput -FeaturePrefix $featurePrefix
    exit 0
}

# Rule 3: code file -> require in-progress spec
if (Test-IsCodeFile -RelPath $rel) {
    $ext = [System.IO.Path]::GetExtension($rel).ToLowerInvariant()
    $indexFile = if ($config.spec.indexFile) { Join-Path $cwd $config.spec.indexFile } else { Join-Path $cwd '.specs/index.md' }
    # @() forces a real array even when exactly one in-progress spec is
    # found - PowerShell's pipeline otherwise unwraps a single-element
    # List[string] into a bare string, which would make $inProgress[0]
    # below silently index a CHARACTER of the id instead of the id itself.
    $inProgress = @(Get-InProgressSpecs -IndexPath $indexFile -Prefixes $specPrefixes)
    if ($inProgress.Count -eq 0) {
        $msg = "spec-gate: editing code file '$rel' but no in-progress spec is recorded in .specs/index.md. Run /sd:feature, /sd:bug, /sd:refactor, or /sd:perf first to create a spec, or set hooks.specGate.mode='off' in .claude/project-config.json to disable."
        if ($mode -eq 'block') {
            Write-BlockDecision $msg
            Write-GateMetric -Cwd $cwd -Config $config -SpecId '-' -Phase '-' -Gate 'code-edit' -Decision 'block' -Ext $ext
            exit 0
        } else {
            [Console]::Error.WriteLine("[WARN] $msg")
            Write-GateMetric -Cwd $cwd -Config $config -SpecId '-' -Phase '-' -Gate 'code-edit' -Decision 'warn' -Ext $ext
            exit 0
        }
    } else {
        # An in-progress spec exists - the edit is allowed. Recording the
        # allow (not just the block/warn paths) is the point: the ratio of
        # allow to warn/block is what the retro loop measures.
        Write-GateMetric -Cwd $cwd -Config $config -SpecId $inProgress[0] -Phase 'in-progress' -Gate 'code-edit' -Decision 'allow' -Ext $ext
    }
}

exit 0
