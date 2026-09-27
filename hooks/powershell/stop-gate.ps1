#requires -Version 5.1
<#
.SYNOPSIS
    specwright: Stop hook - stop-gate.

.DESCRIPTION
    Reads Claude Code hook JSON from stdin. When the main thread tries to end
    its turn, refuses the stop if the spec the session was driving shows on
    disk that a HARD gate was skipped (SW-69, ADR 0016):
      1. If the payload carries stop_hook_active: true, allow the stop. The
         model has already had one continuation; blocking again would loop
         (ADR 0015).
      2. Resolve the project root from the cwd (SW-78) and load
         .claude/project-config.json. hooks.stopGate.enabled must be the
         literal JSON true - the hook is OFF by default.
      3. The spec checked is the newest spec ID in the transcript tail whose
         folder has a 00-spec.md and is not done/archived. No fallback: a
         turn that never touched a spec is never blocked.
      4. By the frontmatter type:, evaluate the invariant table of ADR 0016.
         A rule fires only when later-phase evidence exists AND the HARD
         gate's own evidence is missing.
      5. On a hit, print {"decision":"block","reason":...} to stdout. That
         blocks Stop exactly like exit 2 (ADR 0015) while this hook still
         exits 0.

    Every path exits 0. A failure, a missing transcript, spec or frontmatter,
    or an unknown type blocks nothing.

.NOTES
    PURE ASCII ONLY. PowerShell 5.1 reads UTF-8 without BOM as Windows-1252;
    a single em-dash byte sequence will cascade into "Missing closing '}'"
    parse errors. Use ASCII hyphen-minus, "->", "[OK]", "[WARN]" etc.
    The rule table and the reason text must stay identical to stop-gate.sh;
    tests/hooks/fixtures/stop-gate/ asserts both against one golden.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'

# How much of the transcript tail to scan. Recent turns are at the end; a
# fixed cap keeps the cost flat however long the session has run.
$script:TranscriptTailBytes = 262144

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
# six hooks; mirrors resolve_project_root in the .sh twins.
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
# OFF: unlike the other five hooks, this one is opt-in (ADR 0016).
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
        # match stop-gate.sh's jq `== true`. The string "true" does not.
        $en = $Config.hooks.stopGate.enabled
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
# resolve_spec_prefixes in stop-gate.sh.
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

# A plain-token frontmatter value (`status:`, `type:`) from the leading `---`
# block of 00-spec.md. Only [A-Za-z0-9_-]+ is accepted. Anything else, a
# missing file or a missing line all yield ''. Same reader as Get-SpecField in
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

# A candidate is the spec being driven when its folder holds a 00-spec.md and
# the spec is not finished.
function Test-ActiveCandidate {
    param([string]$SpecDir, [string]$Id)
    $specFile = Join-Path (Join-Path $SpecDir $Id) '00-spec.md'
    if (-not (Test-Path -LiteralPath $specFile -PathType Leaf)) { return $false }
    $status = Get-SpecField -SpecFile $specFile -Key 'status'
    if ($status -ceq 'done' -or $status -ceq 'archived') { return $false }
    return $true
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

# --- document helpers (ADR 0016) ----------------------------------------------
# A spec file as text: CRs and a leading BOM removed, and every <!-- ... -->
# comment dropped, so template guidance that quotes <<...>> never counts as an
# unfilled field. $null when the file is absent. Mirrors doc_text in the .sh.
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

# The lines under `## <Heading>` up to the next `## ` heading, or $null when
# the heading is absent. A `### ` subheading does not end the section.
function Get-Section {
    param([string]$Text, [string]$Heading)
    if ($null -eq $Text) { return $null }
    $inside = $false
    $found = $false
    $sb = New-Object System.Text.StringBuilder
    foreach ($l in ($Text -split "`n")) {
        if ($l.StartsWith('## ')) {
            if ($inside) { break }
            if ($l.TrimEnd() -ceq ('## ' + $Heading)) { $inside = $true; $found = $true }
            continue
        }
        if ($inside) { [void]$sb.Append($l).Append("`n") }
    }
    if (-not $found) { return $null }
    return $sb.ToString()
}

# An author-fill field is a <<...>> on one line that is not a <<PHASE-N: ...>>.
function Test-AuthorFill {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    foreach ($m in [regex]::Matches($Text, '<<[^<>\n]+>>')) {
        if (-not $m.Value.StartsWith('<<PHASE-')) { return $true }
    }
    return $false
}

function Test-LineMatch {
    param([string]$Text, [string]$Pattern)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    foreach ($l in ($Text -split "`n")) {
        if ($l -cmatch $Pattern) { return $true }
    }
    return $false
}

function Test-StatusIn {
    param([string]$Status, [string[]]$Allowed)
    return ($Allowed -ccontains $Status)
}

# One finding per fired rule. The phrases are part of the contract: the .sh
# twin builds the same strings and the fixtures assert them byte for byte.
function New-Finding {
    param([string]$Gate, [System.Collections.Generic.List[string]]$Missing, [System.Collections.Generic.List[string]]$Advanced)
    return (' Gate ' + $Gate + ': missing ' + ($Missing -join '; ') +
        '; later-phase evidence: ' + ($Advanced -join '; ') + '.')
}

function Get-Findings {
    param([string]$SpecType, [string]$Status, [string]$Dir)
    $out = New-Object System.Collections.Generic.List[string]
    $spec = Get-DocText -Path (Join-Path $Dir '00-spec.md')
    if ($null -eq $spec) { return $out }
    $hasDecisions = Test-Path -LiteralPath (Join-Path $Dir '03-decisions.md') -PathType Leaf
    $hasTasks = Test-Path -LiteralPath (Join-Path $Dir '02-tasks.md') -PathType Leaf

    switch -CaseSensitive ($SpecType) {
        'bug' {
            # BUG-G2: Reproduction confirmed.
            $adv = New-Object System.Collections.Generic.List[string]
            $mis = New-Object System.Collections.Generic.List[string]
            if (Test-StatusIn $Status @('approved', 'in-progress')) { $adv.Add("status is $Status") }
            if ($hasDecisions) { $adv.Add('03-decisions.md exists') }
            if (Test-AuthorFill (Get-Section $spec 'Reproduction')) {
                $retro = Get-DocText -Path (Join-Path $Dir '05-retro.md')
                $excepted = $false
                if ($null -ne $retro) {
                    foreach ($l in ($retro -split "`n")) {
                        if ($l -match 'constitution exception' -and $l -match 'reproduc|gate 2') { $excepted = $true; break }
                    }
                }
                if (-not $excepted) { $mis.Add('## Reproduction in 00-spec.md still has unfilled <<...>> fields') }
            }
            if ($adv.Count -gt 0 -and $mis.Count -gt 0) { $out.Add((New-Finding '2 (Reproduction confirmed)' $mis $adv)) }
        }
        'perf' {
            # PERF-G2: Baseline measured.
            $adv = New-Object System.Collections.Generic.List[string]
            $mis = New-Object System.Collections.Generic.List[string]
            $tree = Get-Section $spec 'Hypothesis tree'
            $log = Get-Section $spec 'Results log'
            $target = Get-Section $spec 'Target'
            if ($Status -ceq 'in-progress') { $adv.Add('status is in-progress') }
            if ($hasDecisions) { $adv.Add('03-decisions.md exists') }
            if ($null -ne $tree -and -not $tree.Contains('<<PHASE-3:')) { $adv.Add('## Hypothesis tree is filled') }
            if (Test-LineMatch $log '^\|[ \t]*[1-9][0-9]*[ \t]*\|') { $adv.Add('the Results log has rows after the baseline') }
            $artifacts = Join-Path $Dir '04-artifacts'
            $baseline = @(Get-ChildItem -LiteralPath $artifacts -File -Filter 'baseline-*' -ErrorAction SilentlyContinue)
            if ($baseline.Count -eq 0) { $mis.Add('no 04-artifacts/baseline-* file') }
            if (-not (Test-LineMatch $log '^\|[ \t]*0[ \t]*\|')) { $mis.Add('no Results log row 0') }
            if ($null -ne $target -and $target.Contains('<<PHASE-2:')) { $mis.Add('## Target still holds a <<PHASE-2: ...>> field') }
            if ($adv.Count -gt 0 -and $mis.Count -gt 0) { $out.Add((New-Finding '2 (Baseline measured)' $mis $adv)) }
        }
        'rca' {
            # RCA-G2: Hypotheses enumerated (SW-51).
            $adv = New-Object System.Collections.Generic.List[string]
            $mis = New-Object System.Collections.Generic.List[string]
            $root = Get-Section $spec 'Root cause'
            $tree = Get-Section $spec 'Hypothesis tree'
            if (Test-StatusIn $Status @('approved', 'in-progress')) { $adv.Add("status is $Status") }
            if ($null -ne $root -and -not $root.Contains('<<PHASE-3:')) { $adv.Add('## Root cause is filled') }
            if ($null -ne $tree -and $tree.Contains('<<PHASE-2:')) { $mis.Add('## Hypothesis tree still holds a <<PHASE-2: ...>> field') }
            if ($adv.Count -gt 0 -and $mis.Count -gt 0) { $out.Add((New-Finding '2 (Hypotheses enumerated)' $mis $adv)) }
        }
        'port' {
            $statusAdv = Test-StatusIn $Status @('approved', 'in-progress')

            # PORT-G1: Donor set frozen.
            $adv = New-Object System.Collections.Generic.List[string]
            $mis = New-Object System.Collections.Generic.List[string]
            if ($statusAdv) { $adv.Add("status is $Status") }
            if ($hasTasks) { $adv.Add('02-tasks.md exists') }
            if (-not (Test-Path -LiteralPath (Join-Path $Dir '04-artifacts/source/MANIFEST.md') -PathType Leaf)) {
                $mis.Add('no 04-artifacts/source/MANIFEST.md')
            }
            if (-not (Test-LineMatch $spec '^- \*\*Frozen\*\*:[ \t]*yes([^A-Za-z0-9_]|$)')) { $mis.Add('the Frozen line does not say yes') }
            if ($adv.Count -gt 0 -and $mis.Count -gt 0) { $out.Add((New-Finding '1 (Donor set frozen)' $mis $adv)) }

            # PORT-G2: Fidelity tables complete.
            $adv = New-Object System.Collections.Generic.List[string]
            $mis = New-Object System.Collections.Generic.List[string]
            if ($statusAdv) { $adv.Add("status is $Status") }
            if (Test-AuthorFill $spec) { $mis.Add('00-spec.md still has unfilled <<...>> fields') }
            if ($adv.Count -gt 0 -and $mis.Count -gt 0) { $out.Add((New-Finding '2 (Fidelity tables complete)' $mis $adv)) }

            # PORT-G3: Behavior pinned.
            $adv = New-Object System.Collections.Generic.List[string]
            $mis = New-Object System.Collections.Generic.List[string]
            if ($hasTasks) { $adv.Add('02-tasks.md exists') }
            $decisions = Get-DocText -Path (Join-Path $Dir '03-decisions.md')
            if (-not (Test-LineMatch $decisions '^## Behavior pinning')) { $mis.Add('03-decisions.md has no ## Behavior pinning section') }
            if ($adv.Count -gt 0 -and $mis.Count -gt 0) { $out.Add((New-Finding '3 (Behavior pinned)' $mis $adv)) }

            # PORT-G6: Justified-diff parity.
            $adv = New-Object System.Collections.Generic.List[string]
            $mis = New-Object System.Collections.Generic.List[string]
            if (Test-Path -LiteralPath (Join-Path $Dir '06-verify.md') -PathType Leaf) { $adv.Add('06-verify.md exists') }
            if (-not (Test-Path -LiteralPath (Join-Path $Dir '04-artifacts/parity/INDEX.md') -PathType Leaf)) {
                $mis.Add('no 04-artifacts/parity/INDEX.md')
            }
            if ($adv.Count -gt 0 -and $mis.Count -gt 0) { $out.Add((New-Finding '6 (Justified-diff parity)' $mis $adv)) }
        }
    }
    return $out
}

# ---- main ----

try {
    $hookInput = Read-StdinJson
    if ($null -eq $hookInput) { exit 0 }

    # ADR 0015: the re-fire after a block carries stop_hook_active: true.
    # Allowing it is what keeps an unsatisfiable gate from looping.
    $active = $hookInput.stop_hook_active
    if (($active -is [bool]) -and $active) { exit 0 }

    $cwd = [string]$hookInput.cwd
    if ([string]::IsNullOrWhiteSpace($cwd)) { exit 0 }
    if (-not (Test-Path -LiteralPath $cwd -PathType Container)) { exit 0 }
    $projectRoot = Resolve-ProjectRoot -Cwd $cwd

    $config = Get-ProjectConfig -Root $projectRoot
    if (-not (Test-HookEnabled -Config $config)) { exit 0 }

    $specRel = if ($config.spec.dir) { [string]$config.spec.dir } else { '.specs' }
    $specDir = Join-Path $projectRoot $specRel
    if (-not (Test-Path -LiteralPath $specDir -PathType Container)) { exit 0 }

    $prefixes = Get-SpecPrefixAlternation -Config $config
    $tail = Get-TranscriptTail -Path ([string]$hookInput.transcript_path)
    $id = Find-ActiveInTranscript -Text $tail -Prefixes $prefixes -SpecDir $specDir
    if (-not $id) { exit 0 }

    $dir = Join-Path $specDir $id
    $specFile = Join-Path $dir '00-spec.md'
    $specType = Get-SpecField -SpecFile $specFile -Key 'type'
    $status = Get-SpecField -SpecFile $specFile -Key 'status'
    if (-not $specType) { exit 0 }

    $findings = @(Get-Findings -SpecType $specType -Status $status -Dir $dir)
    if ($findings.Count -eq 0) { exit 0 }

    $reason = 'specwright stop-gate: ' + $id + ' (/sd:' + $specType + ') is past a HARD gate without its evidence.' +
        ($findings -join '') +
        ' Return to that gate: present it to the user and STOP for their answer, or undo the later-phase work. HARD gates have no override.'
    $obj = [pscustomobject][ordered]@{ decision = 'block'; reason = $reason }
    [Console]::Out.WriteLine(($obj | ConvertTo-Json -Compress))
} catch { }
exit 0
