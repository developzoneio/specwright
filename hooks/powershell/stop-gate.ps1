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
      4. By the frontmatter type:, evaluate the invariant table of ADR 0016
         (feature rows: ADR 0021; bug and refactor rows and Gate Re-plan:
         ADR 0029; all read from gate-briefs.md). A rule fires only when
         later-phase evidence exists AND the HARD gate's own evidence is
         missing.
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
# OFF: like handoff-integrity, and unlike the other hooks, this one is opt-in (ADR 0016).
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

# --- gate briefs (ADR 0021, ADR 0029) -----------------------------------------
# /sd:feature, /sd:bug and /sd:refactor gates are evidenced by gate-briefs.md
# (sd-gate-brief): one `## Gate <label> ...` section per gate pass, closed by a
# `Reply: <reply verbatim>` line. Only those two kinds of line are read.
# Mirrors read_brief in the .sh.

# The gate labels a workflow's brief records, in workflow order; R is Gate
# Re-plan. The position is the label's rank for the coverage rule. A label not
# listed is not a gate of that workflow, so `3` and `3a` never collide. Adding
# a workflow is one entry here plus its Get-DenyTokens entries.
$script:BriefOrder = @{
    feature  = @('1', '2', 'R', '3')
    bug      = @('1', '2', '3a', '3', '4', '5')
    refactor = @('1', '2', '3', '4', '5', 'R', '6')
}

# The option tokens that keep gate <type>:<label> open or leave it, plus a bare
# "no". Any other reply approves, so a reply in the conversation language
# still counts.
function Get-DenyTokens {
    param([string]$Key)
    $base = @('details', 'refine', 'abort', 'no')
    switch -CaseSensitive -Regex ($Key) {
        '^feature:1$' { return @('details', 'refine', 'abort', 'no') }
        '^feature:2$' { return @('details', 'refine', 'abort', 'approve', 'no') }
        '^feature:3$' { return @('details', 'address', 'abort', 'no') }
        '^bug:2$' { return ($base + 'partial') }
        '^bug:3$' { return ($base + 'dig') }
        '^(bug:5|refactor:6)$' { return ($base + 'address') }
        '^refactor:[23]$' { return ($base + 'add') }
        '^refactor:5$' { return ($base + @('revert', 'fix')) }
        ':R$' { return ($base + 'revise') }
    }
    return $base
}

# A reply's token: the first word after `Reply:`, with surrounding markdown
# quotes and trailing punctuation removed, lowercased. '' means no reply.
function Get-ReplyToken {
    param([string]$Line)
    $t = $Line.Substring($Line.IndexOf('Reply:') + 6).Trim()
    $t = $t.TrimStart([char[]]'`*_"''')
    $t = ($t -split '\s', 2)[0]
    $t = $t.TrimEnd([char[]]'.,;:!?`*_"''')
    return $t.ToLowerInvariant()
}

# A fresh counter set for one gate label or one Re-plan revision.
function New-GateCounter {
    return @{ Seen = $false; Replies = 0; Ok = $false; Deny = '' }
}

# One pass over the brief of workflow $Type. Gates maps each label of
# BriefOrder to its counters: Seen (a section exists), Replies (Reply: lines
# with a token), Ok (one of them approves), Deny (the last non-approving
# token). Rp holds the same per Re-plan revision number; RpMin is the lowest
# number with a section. Start is the rank of the first gate heading. A `### `
# subheading does not end a section; any other `## ` heading does. In a
# feature brief, a `## Gate 1+2` heading (the S lane's combined approval,
# ADR 0030) opens one section that counts for Gate 1 and Gate 2 at once,
# ranked as Gate 1, with Gate 1's non-approving tokens.
function Get-BriefState {
    param([string]$Text, [string]$Type)
    $state = @{ Start = 0; Rank = @{}; Gates = @{}; Rp = @{}; RpMin = 0 }
    $i = 0
    foreach ($g in $script:BriefOrder[$Type]) {
        $i++
        $state.Rank[$g] = $i
        $state.Gates[$g] = New-GateCounter
    }
    $cur = $null
    $cur2 = $null
    $curKey = ''
    foreach ($l in ($Text -split "`n")) {
        if ($l.StartsWith('## ')) {
            $h = $l.TrimEnd()
            $cur = $null
            $cur2 = $null
            $rank = 0
            if ($Type -ceq 'feature' -and $h -cmatch '^## Gate 1\+2([^0-9]|$)') {
                $rank = $state.Rank['1']
                $cur = $state.Gates['1']
                $cur2 = $state.Gates['2']
                $cur.Seen = $true
                $cur2.Seen = $true
                $curKey = 'feature:1'
            } elseif ($h -cmatch '^## Gate Re-plan') {
                # It marks where a brief starts even when the workflow has no
                # Re-plan rule; its replies count only under a `- R<n>` heading.
                if ($state.Rank.ContainsKey('R')) { $rank = $state.Rank['R'] }
                if ($rank -gt 0 -and $h -cmatch '^## Gate Re-plan - R([0-9]{1,6})([^0-9]|$)') {
                    $n = [int]$Matches[1]
                    if (-not $state.Rp.ContainsKey($n)) { $state.Rp[$n] = New-GateCounter }
                    $cur = $state.Rp[$n]
                    $cur.Seen = $true
                    $curKey = "${Type}:R"
                    if ($state.RpMin -eq 0 -or $n -lt $state.RpMin) { $state.RpMin = $n }
                }
            } elseif ($h -cmatch '^## Gate ([0-9]+[a-z]?)([^0-9a-z]|$)') {
                $lab = $Matches[1]
                if ($state.Rank.ContainsKey($lab)) {
                    $rank = $state.Rank[$lab]
                    $cur = $state.Gates[$lab]
                    $cur.Seen = $true
                    $curKey = "${Type}:$lab"
                }
            }
            if ($state.Start -eq 0 -and $rank -gt 0) { $state.Start = $rank }
            continue
        }
        if ($null -eq $cur) { continue }
        if ($l -cnotmatch '^[ \t]*Reply:') { continue }
        $tok = Get-ReplyToken $l
        if (-not $tok) { continue }
        $isDeny = ((Get-DenyTokens $curKey) -ccontains $tok)
        foreach ($c in @($cur, $cur2)) {
            if ($null -eq $c) { continue }
            $c.Replies = $c.Replies + 1
            if ($isDeny) {
                $c.Deny = $tok
            } else {
                $c.Ok = $true
            }
        }
    }
    return $state
}

# What the gates $Gates lack together: one label, or a pool whose sections all
# record one decision (refactor Gates 2 and 3). The pool is checked when the
# brief covers it: its last gate is at or after the first gate the brief
# records. A gate before that point (a resumed spec, or one created before gate
# briefs existed) is never checked: a missing record is not a skipped gate.
# -Conditional (bug Gate 3a) checks a gate whenever it has a section, wherever
# the brief starts. '' when nothing is missing.
function Get-BriefMissing {
    param($State, [string[]]$Gates, [switch]$Conditional)
    if ($State.Start -eq 0) { return '' }
    $top = 0
    $seen = $false
    $replies = 0
    $deny = ''
    foreach ($g in $Gates) {
        $c = $State.Gates[$g]
        if ($c.Ok) { return '' }
        if ($State.Rank[$g] -gt $top) { $top = $State.Rank[$g] }
        if ($c.Seen) { $seen = $true }
        $replies += $c.Replies
        if ($c.Deny) { $deny = $c.Deny }
    }
    if ($Conditional) {
        if (-not $seen) { return '' }
    } elseif ($top -lt $State.Start) {
        return ''
    }
    $names = ($Gates | ForEach-Object { "## Gate $_" }) -join ' or '
    if (-not $seen) { return ('a ## Gate ' + $Gates[0] + ' section in gate-briefs.md') }
    if ($replies -eq 0) { return "a Reply: line in a $names section of gate-briefs.md" }
    return "an approving Reply: line in a $names section of gate-briefs.md (last reply: $deny)"
}

# Gate Re-plan (ADR 0029): every revision R<n> in `## Revisions` of $Plan
# needs an approving reply in some `## Gate Re-plan - R<n>` section. A revision
# numbered below the first one the brief records predates gate briefs; with no
# Re-plan section at all, no revision is checked. Adds findings to $Out.
function Add-ReplanFindings {
    param($State, [string]$Plan, [System.Collections.Generic.List[string]]$Out)
    if ($State.RpMin -eq 0) { return }
    $revs = Get-Section $Plan 'Revisions'
    if ($null -eq $revs) { return }
    $done = New-Object System.Collections.Generic.HashSet[int]
    foreach ($l in ($revs -split "`n")) {
        if ($l -cnotmatch '^###[ \t]+R([0-9]{1,6})([^0-9]|$)') { continue }
        $n = [int]$Matches[1]
        if ($n -lt $State.RpMin -or -not $done.Add($n)) { continue }
        $c = $State.Rp[$n]
        $mis = New-Object System.Collections.Generic.List[string]
        if ($null -eq $c) {
            $mis.Add("a ## Gate Re-plan - R$n section in gate-briefs.md")
        } elseif ($c.Ok) {
            continue
        } elseif ($c.Replies -eq 0) {
            $mis.Add("a Reply: line in a ## Gate Re-plan - R$n section of gate-briefs.md")
        } else {
            $mis.Add("an approving Reply: line in a ## Gate Re-plan - R$n section of gate-briefs.md (last reply: " +
                $c.Deny + ')')
        }
        $adv = New-Object System.Collections.Generic.List[string]
        $adv.Add("01-plan.md ## Revisions records R$n")
        $Out.Add((New-Finding "Re-plan R$n" $mis $adv))
    }
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

    # No gate-briefs.md: a spec from before gate briefs, or one no session has
    # presented a gate for yet. Not evidence of a skipped gate, so Start stays 0
    # and Get-BriefMissing reports nothing. Read only for the workflows with
    # brief rules.
    $script:BriefRead = $false
    $brief = $null
    $b = @{ Start = 0; Rank = @{}; Gates = @{}; Rp = @{}; RpMin = 0 }
    if ($script:BriefOrder.ContainsKey($SpecType) -and $script:BriefOrder.Keys -ccontains $SpecType) {
        $brief = Get-DocText -Path (Join-Path $Dir 'gate-briefs.md')
        if (-not [string]::IsNullOrEmpty($brief)) {
            $b = Get-BriefState $brief $SpecType
            $script:BriefRead = $true
        }
    }

    # Phase 7 of /sd:bug and /sd:refactor opens its 05-retro.md entry with this
    # heading; the Gate 5/6 suggestions logged before the brief never carry it.
    $retro = Get-DocText -Path (Join-Path $Dir '05-retro.md')
    $hasCloseout = Test-LineMatch $retro '^## Close-out[ \t]*$'

    switch -CaseSensitive ($SpecType) {
        'feature' {
            if (-not $script:BriefRead) { break }

            # FEAT-G1: Spec approval.
            $adv = New-Object System.Collections.Generic.List[string]
            $mis = New-Object System.Collections.Generic.List[string]
            if (Test-StatusIn $Status @('approved', 'in-progress')) { $adv.Add("status is $Status") }
            if ($hasTasks) { $adv.Add('02-tasks.md exists') }
            if ($hasDecisions) { $adv.Add('03-decisions.md exists') }
            $m = Get-BriefMissing $b 1
            if ($m) { $mis.Add($m) }
            if ($adv.Count -gt 0 -and $mis.Count -gt 0) { $out.Add((New-Finding '1 (Spec approval)' $mis $adv)) }

            # FEAT-G2: Plan approval, either face (Complexity: no-split approves).
            $adv = New-Object System.Collections.Generic.List[string]
            $mis = New-Object System.Collections.Generic.List[string]
            if ($Status -ceq 'in-progress') { $adv.Add('status is in-progress') }
            $tasks = Get-DocText -Path (Join-Path $Dir '02-tasks.md')
            if (Test-LineMatch $tasks '^- \*\*Status\*\*:[ \t]*done([^A-Za-z0-9_]|$)') {
                $adv.Add('a task in 02-tasks.md is done')
            }
            # An outline in 01-plan.md means Phase 3b may write 02-tasks.md only
            # after Gate 2 approved it (ADR 0022); a legacy plan has no outline.
            $plan = Get-DocText -Path (Join-Path $Dir '01-plan.md')
            if ($hasTasks -and (Test-LineMatch $plan '^## Outline[ \t]*$')) {
                $adv.Add('02-tasks.md is expanded from the outline')
            }
            $m = Get-BriefMissing $b 2
            if ($m) { $mis.Add($m) }
            if ($adv.Count -gt 0 -and $mis.Count -gt 0) { $out.Add((New-Finding '2 (Plan approval)' $mis $adv)) }

            # Gate Re-plan (ADR 0029).
            Add-ReplanFindings $b $plan $out

            # FEAT-G3: Integration and review.
            $adv = New-Object System.Collections.Generic.List[string]
            $mis = New-Object System.Collections.Generic.List[string]
            $verify = Get-DocText -Path (Join-Path $Dir '06-verify.md')
            if (Test-LineMatch $verify '^result:[ \t]*pass[ \t]*$') { $adv.Add('06-verify.md records result: pass') }
            $m = Get-BriefMissing $b 3
            if ($m) { $mis.Add($m) }
            if ($adv.Count -gt 0 -and $mis.Count -gt 0) { $out.Add((New-Finding '3 (Integration and review)' $mis $adv)) }
        }
        'bug' {
            $root = Get-Section $spec 'Root cause'
            $rootFilled = ($null -ne $root -and -not $root.Contains('<<PHASE-3:'))
            $hasFailing = Test-Path -LiteralPath (Join-Path $Dir '04-artifacts/repro/failing-test-output.txt') -PathType Leaf
            $statusAdv = Test-StatusIn $Status @('approved', 'in-progress')

            # BUG-G1: Symptom captured (ADR 0029).
            $adv = New-Object System.Collections.Generic.List[string]
            $mis = New-Object System.Collections.Generic.List[string]
            if ($statusAdv) { $adv.Add("status is $Status") }
            if ($hasDecisions) { $adv.Add('03-decisions.md exists') }
            $m = Get-BriefMissing $b 1
            if ($m) { $mis.Add($m) }
            if ($adv.Count -gt 0 -and $mis.Count -gt 0) { $out.Add((New-Finding '1 (Symptom captured)' $mis $adv)) }

            # BUG-G2: Reproduction confirmed. The constitution exception logged
            # on the insist path excuses both the unfilled section and the reply.
            $adv = New-Object System.Collections.Generic.List[string]
            $mis = New-Object System.Collections.Generic.List[string]
            if ($statusAdv) { $adv.Add("status is $Status") }
            if ($hasDecisions) { $adv.Add('03-decisions.md exists') }
            if (Test-AuthorFill (Get-Section $spec 'Reproduction')) {
                $mis.Add('## Reproduction in 00-spec.md still has unfilled <<...>> fields')
            }
            $m = Get-BriefMissing $b 2
            if ($m) { $mis.Add($m) }
            if ($mis.Count -gt 0 -and $null -ne $retro) {
                foreach ($l in ($retro -split "`n")) {
                    if ($l -match 'constitution exception' -and $l -match 'reproduc|gate 2') { $mis.Clear(); break }
                }
            }
            if ($adv.Count -gt 0 -and $mis.Count -gt 0) { $out.Add((New-Finding '2 (Reproduction confirmed)' $mis $adv)) }

            # BUG-G3a: Hypothesis tree exhausted. Conditional: checked only when
            # it was presented. re-enumerate and observe answer it.
            $adv = New-Object System.Collections.Generic.List[string]
            $mis = New-Object System.Collections.Generic.List[string]
            if ($rootFilled) { $adv.Add('## Root cause is filled') }
            if ($hasFailing) { $adv.Add('04-artifacts/repro/failing-test-output.txt exists') }
            $m = Get-BriefMissing $b '3a' -Conditional
            if ($m) { $mis.Add($m) }
            if ($adv.Count -gt 0 -and $mis.Count -gt 0) { $out.Add((New-Finding '3a (Hypothesis tree exhausted)' $mis $adv)) }

            # BUG-G3: Root cause confirmed. The root cause is written before its
            # brief, so the failing test is the first evidence past it.
            $adv = New-Object System.Collections.Generic.List[string]
            $mis = New-Object System.Collections.Generic.List[string]
            if ($hasFailing) { $adv.Add('04-artifacts/repro/failing-test-output.txt exists') }
            if ($Status -ceq 'in-progress') { $adv.Add('status is in-progress') }
            $m = Get-BriefMissing $b 3
            if ($m) { $mis.Add($m) }
            if ($adv.Count -gt 0 -and $mis.Count -gt 0) { $out.Add((New-Finding '3 (Root cause confirmed)' $mis $adv)) }

            # BUG-G4: Failing test confirmed.
            $adv = New-Object System.Collections.Generic.List[string]
            $mis = New-Object System.Collections.Generic.List[string]
            if ($Status -ceq 'in-progress') { $adv.Add('status is in-progress') }
            $m = Get-BriefMissing $b 4
            if ($m) { $mis.Add($m) }
            if ($adv.Count -gt 0 -and $mis.Count -gt 0) { $out.Add((New-Finding '4 (Failing test confirmed)' $mis $adv)) }

            # BUG-G5: Regression and review.
            $adv = New-Object System.Collections.Generic.List[string]
            $mis = New-Object System.Collections.Generic.List[string]
            if ($hasCloseout) { $adv.Add('05-retro.md has a ## Close-out section') }
            $m = Get-BriefMissing $b 5
            if ($m) { $mis.Add($m) }
            if ($adv.Count -gt 0 -and $mis.Count -gt 0) { $out.Add((New-Finding '5 (Regression and review)' $mis $adv)) }
        }
        'refactor' {
            if (-not $script:BriefRead) { break }
            $hasPlan = Test-Path -LiteralPath (Join-Path $Dir '01-plan.md') -PathType Leaf
            $tasks = Get-DocText -Path (Join-Path $Dir '02-tasks.md')
            $taskDone = Test-LineMatch $tasks '^- \*\*Status\*\*:[ \t]*done([^A-Za-z0-9_]|$)'

            # REF-G1: Spec approval.
            $adv = New-Object System.Collections.Generic.List[string]
            $mis = New-Object System.Collections.Generic.List[string]
            if (Test-StatusIn $Status @('approved', 'in-progress')) { $adv.Add("status is $Status") }
            if ($hasDecisions) { $adv.Add('03-decisions.md exists') }
            if ($hasPlan) { $adv.Add('01-plan.md exists') }
            $m = Get-BriefMissing $b 1
            if ($m) { $mis.Add($m) }
            if ($adv.Count -gt 0 -and $mis.Count -gt 0) { $out.Add((New-Finding '1 (Spec approval)' $mis $adv)) }

            # REF-G2: Coverage threshold met. `add tests` leads to Gate 3, so
            # the decision is the approving reply in either gate.
            $adv = New-Object System.Collections.Generic.List[string]
            $mis = New-Object System.Collections.Generic.List[string]
            if ($hasPlan) { $adv.Add('01-plan.md exists') }
            if ($hasTasks) { $adv.Add('02-tasks.md exists') }
            if ($Status -ceq 'in-progress') { $adv.Add('status is in-progress') }
            $m = Get-BriefMissing $b @('2', '3')
            if ($m) { $mis.Add($m) }
            if ($adv.Count -gt 0 -and $mis.Count -gt 0) { $out.Add((New-Finding '2 (Coverage threshold met)' $mis $adv)) }

            # REF-G4: Plan approval.
            $adv = New-Object System.Collections.Generic.List[string]
            $mis = New-Object System.Collections.Generic.List[string]
            if ($Status -ceq 'in-progress') { $adv.Add('status is in-progress') }
            if ($taskDone) { $adv.Add('a task in 02-tasks.md is done') }
            $batches = @(Get-ChildItem -LiteralPath (Join-Path $Dir '04-artifacts/batches') -File -Filter 'batch-*-tests.txt' -ErrorAction SilentlyContinue)
            if ($batches.Count -gt 0) { $adv.Add('a 04-artifacts/batches/batch-*-tests.txt file exists') }
            $m = Get-BriefMissing $b 4
            if ($m) { $mis.Add($m) }
            if ($adv.Count -gt 0 -and $mis.Count -gt 0) { $out.Add((New-Finding '4 (Plan approval)' $mis $adv)) }

            # REF-G5: Tests green per batch.
            $adv = New-Object System.Collections.Generic.List[string]
            $mis = New-Object System.Collections.Generic.List[string]
            if ($taskDone) { $adv.Add('a task in 02-tasks.md is done') }
            if (Test-Path -LiteralPath (Join-Path $Dir '04-artifacts/coverage/after-refactor.txt') -PathType Leaf) {
                $adv.Add('04-artifacts/coverage/after-refactor.txt exists')
            }
            $m = Get-BriefMissing $b 5
            if ($m) { $mis.Add($m) }
            if ($adv.Count -gt 0 -and $mis.Count -gt 0) { $out.Add((New-Finding '5 (Tests green per batch)' $mis $adv)) }

            # Gate Re-plan (ADR 0029).
            Add-ReplanFindings $b (Get-DocText -Path (Join-Path $Dir '01-plan.md')) $out

            # REF-G6: Holistic review.
            $adv = New-Object System.Collections.Generic.List[string]
            $mis = New-Object System.Collections.Generic.List[string]
            if ($hasCloseout) { $adv.Add('05-retro.md has a ## Close-out section') }
            $m = Get-BriefMissing $b 6
            if ($m) { $mis.Add($m) }
            if ($adv.Count -gt 0 -and $mis.Count -gt 0) { $out.Add((New-Finding '6 (Holistic review)' $mis $adv)) }
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

    $briefNote = ''
    if ($script:BriefRead) {
        # No apostrophe: ConvertTo-Json on 5.1 escapes it as ', and the
        # stdout of the two twins would no longer be byte-identical.
        $briefNote = ' A /sd:' + $specType + ' gate is evidenced by its section in gate-briefs.md and the reply recorded' +
            ' on its Reply: line; if the user already answered that gate in this conversation, append that answer' +
            ' verbatim as the Reply: line with the Edit tool instead of asking again.'
    }
    $reason = 'specwright stop-gate: ' + $id + ' (/sd:' + $specType + ') is past a HARD gate without its evidence.' +
        ($findings -join '') + $briefNote +
        ' Return to that gate: present it to the user and STOP for their answer, or undo the later-phase work. HARD gates have no override.'
    $obj = [pscustomobject][ordered]@{ decision = 'block'; reason = $reason }
    [Console]::Out.WriteLine(($obj | ConvertTo-Json -Compress))
} catch { }
exit 0
