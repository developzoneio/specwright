#requires -Version 5.1
<#
.SYNOPSIS
    specwright: PostToolUse hook - handoff-integrity.

.DESCRIPTION
    Reads Claude Code hook JSON from stdin. After an Edit, Write or MultiEdit
    succeeds, flags the edit in the same turn when the file is outside the
    declared Files of the task being executed (SW-70, ADR 0017):
      1. Resolve the project root from the cwd (SW-78) and load
         .claude/project-config.json. hooks.handoffIntegrity.enabled must be
         the literal JSON true - the hook is OFF by default.
      2. The spec checked is the newest spec ID in the transcript tail whose
         folder has a 00-spec.md with status in-progress, and a 02-tasks.md.
         No fallback: a session driving no in-progress spec is never flagged.
      3. The active task is the READY SET of 02-tasks.md: every unchecked task
         whose Depends on tasks are all checked. The declared files are the
         union of their Files values. No ready task means no active task.
      4. An edit outside the project root, or inside the spec directory (the
         main thread's own check-offs and retro lines), is never flagged.
      5. Otherwise, a file that matches no declared entry prints
         {"decision":"block","reason":...} to stdout. PostToolUse cannot undo
         the edit (ADR 0015): the reason reaches the model as feedback, and
         this hook still exits 0.

    Every path exits 0. A failure, a missing transcript, spec or task file,
    or an in-scope edit prints nothing.

.NOTES
    PURE ASCII ONLY. PowerShell 5.1 reads UTF-8 without BOM as Windows-1252;
    a single em-dash byte sequence will cascade into "Missing closing '}'"
    parse errors. Use ASCII hyphen-minus, "->", "[OK]", "[WARN]" etc.
    The task parser, the match rules and the reason text must stay identical
    to handoff-integrity.sh; tests/hooks/fixtures/handoff-integrity/ asserts
    both against one golden.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'

# How much of the transcript tail to scan. Recent turns are at the end; a
# fixed cap keeps the cost flat however long the session has run.
$script:TranscriptTailBytes = 262144

# The write tools the settings template wires this hook on (ADR 0015: never
# a `*` matcher - every spawn costs about 330 ms on PS 5.1).
$script:WriteTools = @('Edit', 'Write', 'MultiEdit')

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
# Reading config and specs relative to it made a session sitting in a
# subdirectory see no spec folders and no in-progress work.
# Every project path is therefore resolved against the project root:
#   1. CLAUDE_PROJECT_DIR (set by Claude Code for hooks), when it is a directory.
#   2. The nearest ancestor of Cwd (Cwd included) holding .claude/project-config.json.
#   3. The nearest ancestor of Cwd holding a .specs/ directory.
#   4. Cwd itself - the pre-SW-78 behaviour.
# Step 2 walks the whole chain before step 3 starts, so a stray nested .specs/
# left behind by an older hook cannot shadow a configured root. Identical in all
# seven hooks; mirrors resolve_project_root in the .sh twins.
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

# A missing or malformed config yields $null, which Test-HookEnabled reads as
# OFF: like stop-gate, this hook is opt-in (ADR 0017).
function Get-ProjectConfig {
    param([string]$Root)
    $cfgPath = Join-Path $Root '.claude/project-config.json'
    if (-not (Test-Path -LiteralPath $cfgPath)) { return $null }
    # -ErrorAction Stop is required: the script-wide SilentlyContinue preference
    # would otherwise make a malformed config a NON-terminating error.
    try {
        return (Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 -ErrorAction Stop |
            ConvertFrom-Json -ErrorAction Stop)
    } catch {
        return $null
    }
}

function Test-HookEnabled {
    param($Config)
    try {
        if ($null -eq $Config) { return $false }
        # Type-strict: only a literal JSON boolean true enables the hook, to
        # match handoff-integrity.sh's jq `== true`. The string "true" does not.
        $en = $Config.hooks.handoffIntegrity.enabled
        return (($en -is [bool]) -and $en)
    } catch {
        return $false
    }
}

# --- spec prefix alternation (SW-44) ------------------------------------------
# Built-in fallback covers every prefix shipped in
# templates/project-config.template.json (FEAT, BUG, REF, PERF, RCA, PORT).
# Any config-declared prefix that fails the shape check
# ^[A-Z][A-Z0-9]{1,9}$ is dropped silently and the built-in default is used
# only if NOTHING declared validates. Must stay in sync with
# resolve_spec_prefixes in handoff-integrity.sh.
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
        if ($val -cmatch '^[A-Z][A-Z0-9]{1,9}$') {
            $valid.Add($val)
        }
    }
    if ($valid.Count -eq 0) {
        return ($script:DefaultSpecPrefixes -join '|')
    }
    return ($valid -join '|')
}

# A plain-token frontmatter value (`status:`) from the leading `---` block of
# 00-spec.md. Only [A-Za-z0-9_-]+ is accepted. Anything else, a missing file
# or a missing line all yield ''. Same reader as Get-SpecField in
# session-context.ps1.
function Get-SpecField {
    param([string]$SpecFile, [string]$Key)
    if (-not (Test-Path -LiteralPath $SpecFile -PathType Leaf)) { return '' }
    try {
        $lines = @(Get-Content -LiteralPath $SpecFile -TotalCount 200 -Encoding UTF8 -ErrorAction Stop)
    } catch {
        return ''
    }
    if ($lines.Count -eq 0 -or $lines[0] -cne '---') { return '' }
    $rx = '^' + $Key + ':[ \t]*([A-Za-z0-9_-]+)[ \t]*$'
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if ($l -ceq '---') { break }
        if ($l -cmatch $rx) { return $Matches[1] }
    }
    return ''
}

# A candidate is the spec whose tasks are being executed: its folder holds a
# 00-spec.md with status in-progress, and a 02-tasks.md.
function Test-ActiveCandidate {
    param([string]$SpecDir, [string]$Id)
    $dir = Join-Path $SpecDir $Id
    $specFile = Join-Path $dir '00-spec.md'
    if (-not (Test-Path -LiteralPath $specFile -PathType Leaf)) { return $false }
    if (-not (Test-Path -LiteralPath (Join-Path $dir '02-tasks.md') -PathType Leaf)) { return $false }
    return ((Get-SpecField -SpecFile $specFile -Key 'status') -ceq 'in-progress')
}

# The last TranscriptTailBytes bytes of the transcript, as text. The file is
# opened with FileShare.ReadWrite because the CLI still holds it open.
# Spec IDs are ASCII, so a multi-byte character cut at the seek point cannot
# change which IDs match.
function Get-TranscriptTail {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $len = $fs.Length
        $take = [int][Math]::Min([long]$script:TranscriptTailBytes, $len)
        if ($take -le 0) { return '' }
        [void]$fs.Seek(-1 * [long]$take, [System.IO.SeekOrigin]::End)
        $buf = New-Object byte[] $take
        $read = 0
        while ($read -lt $take) {
            $n = $fs.Read($buf, $read, $take - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        return [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
    } catch {
        return ''
    } finally {
        if ($null -ne $fs) { $fs.Dispose() }
    }
}

# Newest mention wins: walk the matches from the end, skipping IDs already
# checked, and return the first that passes Test-ActiveCandidate.
function Find-ActiveInTranscript {
    param([string]$Text, [string]$Prefixes, [string]$SpecDir)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $rx = [regex]::new("($Prefixes)-[A-Za-z0-9_-]+")
    $all = $rx.Matches($Text)
    $seen = New-Object System.Collections.Generic.HashSet[string]
    for ($i = $all.Count - 1; $i -ge 0; $i--) {
        $id = $all[$i].Value
        if (-not $seen.Add($id)) { continue }
        if (Test-ActiveCandidate -SpecDir $SpecDir -Id $id) { return $id }
    }
    return ''
}

# A spec file as text: CRs and a leading BOM removed, and every <!-- ... -->
# comment dropped, so an example task block inside a comment is never read as
# a task. $null when the file is absent. Same as Get-DocText in stop-gate.ps1.
function Get-DocText {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $t = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    } catch {
        return $null
    }
    $t = $t.Replace("`r", '').TrimStart([char]0xFEFF)
    return [regex]::Replace($t, '<!--[\s\S]*?-->', '')
}

# --- 02-tasks.md parser (sd-atomic-task-format) -------------------------------
# Field label grammar: `-` or `*` bullet, optional `**`, colon inside or outside
# the emphasis, label case-insensitive. Only the labels the format defines
# start a new field; any other line inside a block continues the field above
# it, so a multi-line Files value keeps its nested bullets. Mirrors the awk
# program in handoff-integrity.sh.
$script:LabelRx = '^[ \t]*[-*][ \t]+(\*\*)?[ \t]*(files|layer|step type|test|acceptance|covers|depends on|conflicts with|estimated complexity|reversibility|pattern refs|status|parallel batch|revised-by)[ \t]*(:[ \t]*\*\*|\*\*[ \t]*:|:)'
$script:TaskIdRx = '(^|[^A-Za-z0-9_])(T[0-9]+)([^A-Za-z0-9_]|$)'
$script:CheckMark = [string][char]0x2705

# One Files value -> its path entries. Split on commas and newlines; per piece
# drop a bullet, backticks and double quotes, a trailing `(...)` note, and
# everything after the first blank; `\` becomes `/` and a leading `./` goes.
function Get-FileEntries {
    param([string]$Value)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($piece in ($Value -split "[,`n]")) {
        $p = $piece.Trim([char[]]" `t")
        $p = [regex]::Replace($p, '^[-*+][ \t]+', '')
        $p = $p.Replace('`', '').Replace('"', '').Trim([char[]]" `t")
        $p = [regex]::Replace($p, '[ \t]+\(.*$', '')
        $m = [regex]::Match($p, '^[^ \t]+')
        if (-not $m.Success) { continue }
        $p = $m.Value.Replace('\', '/')
        while ($p.StartsWith('./')) { $p = $p.Substring(2) }
        if ($p.Length -eq 0 -or $p -ieq 'none') { continue }
        $out.Add($p)
    }
    return $out
}

# The ready set: every unchecked task whose Depends on tasks are all checked.
# A dependency on an ID the file does not define counts as met - the hook
# errs toward silence. Returns @{ Ids; Files } in document order.
function Get-ReadySet {
    param([string]$Text)
    $tasks = New-Object System.Collections.Generic.List[object]
    $cur = $null
    $field = ''
    foreach ($line in ($Text -split "`n")) {
        if ($line -match '^#{1,3}[ \t]') {
            if ($null -ne $cur) { $tasks.Add($cur) }
            $cur = $null
            $field = ''
            if ($line.StartsWith('### ')) {
                $m = [regex]::Match($line, $script:TaskIdRx)
                if ($m.Success) {
                    $prefix = $line.Substring(0, $m.Groups[2].Index)
                    $drift = ($prefix.ToLowerInvariant().Contains('[x]')) -or ($prefix.Contains($script:CheckMark))
                    $cur = @{ Id = $m.Groups[2].Value; Drift = $drift; Status = $null; Deps = ''; Files = '' }
                }
            }
            continue
        }
        if ($null -eq $cur) { continue }
        $lm = [regex]::Match($line.ToLowerInvariant(), $script:LabelRx)
        if ($lm.Success) {
            $field = $lm.Groups[2].Value
            $value = $line.Substring($lm.Index + $lm.Length)
            switch ($field) {
                'files' { $cur.Files = $value }
                'depends on' { $cur.Deps = $value }
                'status' {
                    $sv = $value.Replace('`', '').Replace('*', '').Trim([char[]]" `t").ToLowerInvariant()
                    $cur.Status = ([regex]::Match($sv, '^[a-z-]*')).Value
                }
            }
            continue
        }
        if ($field -ceq 'files') { $cur.Files = $cur.Files + "`n" + $line }
        elseif ($field -ceq 'depends on') { $cur.Deps = $cur.Deps + "`n" + $line }
    }
    if ($null -ne $cur) { $tasks.Add($cur) }

    # sd-atomic-task-format "Reading": Status decides when present; a heading
    # prefix counts only when Status is absent. Last block wins on a repeat ID.
    $checked = @{}
    foreach ($t in $tasks) {
        if ($null -ne $t.Status) { $checked[$t.Id] = ($t.Status -ceq 'done') }
        else { $checked[$t.Id] = $t.Drift }
    }
    $ids = New-Object System.Collections.Generic.List[string]
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($t in $tasks) {
        $isChecked = if ($null -ne $t.Status) { $t.Status -ceq 'done' } else { $t.Drift }
        if ($isChecked) { continue }
        $ready = $true
        foreach ($d in [regex]::Matches($t.Deps, 'T[0-9]+')) {
            if ($checked.ContainsKey($d.Value) -and -not $checked[$d.Value]) { $ready = $false; break }
        }
        if (-not $ready) { continue }
        $ids.Add($t.Id)
        foreach ($f in (Get-FileEntries -Value $t.Files)) { $files.Add($f) }
    }
    return @{ Ids = $ids; Files = $files }
}

# Case-insensitive, like the .sh twin's nocasematch: an exact path, a
# directory entry ending in `/` that prefixes the path, or an entry carrying
# `*` or `?` as a wildcard pattern.
function Test-Declared {
    param([string]$Rel, [System.Collections.Generic.List[string]]$Entries)
    foreach ($e in $Entries) {
        if ($Rel -ieq $e) { return $true }
        if ($e.EndsWith('/') -and $Rel.StartsWith($e, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        if (($e.Contains('*') -or $e.Contains('?')) -and ($Rel -like $e)) { return $true }
    }
    return $false
}

function Test-AbsolutePath {
    param([string]$Path)
    return ($Path.StartsWith('/') -or ($Path -match '^[A-Za-z]:/'))
}

# ---- main ----

try {
    $hookInput = Read-StdinJson
    if ($null -eq $hookInput) { exit 0 }
    if ($script:WriteTools -cnotcontains [string]$hookInput.tool_name) { exit 0 }

    $filePath = [string]$hookInput.tool_input.file_path
    if ([string]::IsNullOrWhiteSpace($filePath)) { exit 0 }

    $cwd = [string]$hookInput.cwd
    if ([string]::IsNullOrWhiteSpace($cwd)) { exit 0 }
    if (-not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 }
    $projectRoot = Resolve-ProjectRoot -Cwd $cwd

    $config = Get-ProjectConfig -Root $projectRoot
    if (-not (Test-HookEnabled -Config $config)) { exit 0 }

    $specRel = if ($config.spec.dir) { [string]$config.spec.dir } else { '.specs' }
    $specDir = Join-Path $projectRoot $specRel
    if (-not (Test-Path -LiteralPath $specDir -PathType Container)) { exit 0 }

    # The edited file relative to the project root, `/`-separated. A file
    # outside the root is not a project file and is never flagged.
    $file = $filePath.Replace('\', '/')
    if (-not (Test-AbsolutePath $file)) { $file = $cwd.Replace('\', '/').TrimEnd('/') + '/' + $file }
    $root = $projectRoot.Replace('\', '/').TrimEnd('/')
    if (-not $file.StartsWith($root + '/', [System.StringComparison]::OrdinalIgnoreCase)) { exit 0 }
    $rel = $file.Substring($root.Length + 1)
    while ($rel.StartsWith('./')) { $rel = $rel.Substring(2) }

    # Spec artifacts are the main thread's bookkeeping (check-offs, retro
    # lines, decisions), never a task's scope.
    $specPrefix = $specRel.Replace('\', '/').Trim('/')
    while ($specPrefix.StartsWith('./')) { $specPrefix = $specPrefix.Substring(2) }
    if ($rel.StartsWith($specPrefix + '/', [System.StringComparison]::OrdinalIgnoreCase)) { exit 0 }

    $prefixes = Get-SpecPrefixAlternation -Config $config
    $tail = Get-TranscriptTail -Path ([string]$hookInput.transcript_path)
    $id = Find-ActiveInTranscript -Text $tail -Prefixes $prefixes -SpecDir $specDir
    if (-not $id) { exit 0 }

    $tasksText = Get-DocText -Path (Join-Path (Join-Path $specDir $id) '02-tasks.md')
    if ($null -eq $tasksText) { exit 0 }
    $ready = Get-ReadySet -Text $tasksText
    if ($ready.Ids.Count -eq 0) { exit 0 }
    if (Test-Declared -Rel $rel -Entries $ready.Files) { exit 0 }

    $reason = 'specwright handoff-integrity: ' + $rel + ' is outside the declared Files of ' + $id +
        "'s ready task(s) " + ($ready.Ids -join ', ') + '. PostToolUse cannot undo it: the edit is already on disk.' +
        ' If it is out of scope, revert it. If the task needs this file, stop and surface a scope mismatch so the plan' +
        ' can be revised (sd-replan-loop) - do not widen the task silently.'
    $obj = [pscustomobject][ordered]@{ decision = 'block'; reason = $reason }
    [Console]::Out.WriteLine(($obj | ConvertTo-Json -Compress))
} catch { }
exit 0
