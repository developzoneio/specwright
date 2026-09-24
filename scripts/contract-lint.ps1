#Requires -Version 5.1
<#
.SYNOPSIS
    Cross-file contract linter for the specwright ENGINE PRODUCT (Windows / PowerShell).

.DESCRIPTION
    Twin of scripts/contract-lint.sh. Both read specwright.manifest.json's
    `contractLint` subtree and MUST report the same rule ids, in the same order,
    for the same tree. Check 8 of scripts/validate.{ps1,sh} runs this as a child
    process; tests/contract-lint/run-selftest.ps1 runs both and diffs them.

    Where validate's Check 7 guards INVENTORY (how many files exist), this guards
    the RELATIONSHIPS between them: which agent a command invokes, which skill an
    agent loads, how many hard gates a workflow declares.

    Wave 1 rule bands (the manifest's rules[] is the authoritative registry):
      CL0xx  reference resolution
      CL3xx  gate integrity
      CL9xx  suppression hygiene

    Output is TSV on stdout, one finding per line, and nothing else:
      <RULE><TAB><SEVERITY><TAB><FILE><TAB><LINE><TAB><MESSAGE>
    Paths are root-relative with forward slashes. Sort order is ordinal on file,
    then numeric line, then rule id, then message. The human-readable summary
    goes to stderr and is never parsed or compared.

    Exit codes:
      0  no BLOCK findings
      1  at least one BLOCK finding
      2  cannot run (bad -Root, missing manifest, registry parity mismatch)

    Exit 2 is separate on purpose: a validator that cannot distinguish "clean"
    from "crashed" is worthless.

    THIS FILE MUST STAY PURE ASCII. Check 1 of validate scans every *.ps1
    recursively, so this script self-polices. The gate marker is a non-ASCII
    character and is NEVER encoded here - see Get-GateClassification.

.PARAMETER Root
    Tree to lint. Defaults to the repo this script lives in. The manifest is read
    from <Root>/specwright.manifest.json, which is what lets a fixture tree
    configure itself.

.PARAMETER Rule
    Comma-separated rule ids; filters the EMITTED findings only. Every rule still
    runs, so CL902 (suppresses nothing) stays truthful.

.PARAMETER Quiet
    Suppress the stderr summary line.
#>

[CmdletBinding()]
param(
    [string]$Root = '',
    [string]$Rule = '',
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- constants --------------------------------------------------------------
#
# Every pattern below must behave identically in .NET and POSIX ERE (the twin).
# Use [0-9] not \d, [ \t] not \s, no lookarounds. All matching goes through
# [regex]::Match / [regex]::Matches - NEVER the -match operator, which is
# case-insensitive and would silently diverge from bash's case-sensitive grep.

$RE_FENCE     = '^[ \t]*```'
$RE_HEADING   = '^(#{2,3}) (.+)$'
$RE_SDREF     = 'sd-[a-z0-9]+(-[a-z0-9]+)*'
$RE_CMDREF    = '/sd:[a-z][a-z0-9-]*'
$RE_TPLPATH   = 'templates/[A-Za-z0-9_./-]+'
# The leading boundary alternative is load-bearing: without it the pattern also
# matches '07-cqrs-read-path.md' inside the ADR filename '0007-cqrs-read-path.md'
# (agents/docs-writer.md), which is not a spec artifact at all.
$RE_ARTIFACT  = '(^|[^0-9A-Za-z_.-])[0-9][0-9]-[a-z0-9-]+\.md'
# CL009 - a command's Phase 0 section: opens at '## Phase 0' (not 'Phase 01'),
# closes at the next H1/H2 heading outside a fence.
$RE_PHASE0      = '^## Phase 0([^0-9]|$)'
$RE_SECTION_END = '^#{1,2}[ \t]'
$RE_SUPPRESS  = '<!--[ \t]*contract-lint:[ \t]*allow[ \t]+CL[0-9][0-9][0-9]'
$RE_SUPPARTS  = 'allow[ \t]+(CL[0-9][0-9][0-9])(.*)$'
# An option set: a slash-separated parenthetical carrying no nested parens.
$RE_OPTPAREN  = '\(([^()/]+/)+[^()]+\)'
$RE_BULLET    = '^-[ \t]'
$RE_BULLETTOK = '^-[ \t]+`([^`]+)`'
$RE_SUBHEAD   = '^#{1,6}[ \t]'
$RE_PHASE     = '^Phase[ \t]+[0-9]+[ \t]+-[ \t]+(.*)$'
$RE_GATE_NUM  = '^ ([0-9]+)([ \t].*)?$'
$RE_GATE_SUB  = '^ ([0-9]+[a-z])([ \t].*)?$'
$RE_GATE_REPL = '^ (Re-plan)([^A-Za-z0-9].*)?$'
$RE_GATE_UNN  = '^ ?[-([]'
$RE_SKILLSKEY = '^skills:[ \t]*$'
$RE_SKILLITEM = '^[ \t]+-[ \t]+(.+)$'
# CL1xx invocation contract. A mode heading carries its selector as a backticked
# `KEY = value` pair (Mode N: `TASK = create`, `WORKFLOW_TYPE = feature`), except
# the reviewer/debugger `Task type: `value`` grammar, whose selector key is the
# established convention TASK_TYPE, never present in the heading text itself.
$RE_KV        = '`([A-Z][A-Z0-9_]*) = ([^`]*)`'
$RE_TASKTYPE  = '^Task type: `([a-z][a-z0-9-]*)`$'
$RE_INPUT_REQ = '^Inputs \(required\):[ \t]*(.*)$'
$RE_INPUT_OPT = '^Inputs \(optional\):[ \t]*(.*)$'
# The `Task type: `value`` heading grammar names no key of its own - reviewer.md
# reads it as TASK_TYPE, debugger.md as TASK. Both say so once, in prose, in
# their own "Always do first" section ("Read the `TASK_TYPE` field." /
# "Read the `TASK` field."), which is the only disambiguating signal on disk.
$RE_FIELD_KEY = 'Read the `([A-Z][A-Z0-9_]*)` field'
# An invocation's token span runs from its anchor line to the next heading, the
# next anchor, or the next top-level numbered step - whichever comes first. The
# numbered-step boundary is load-bearing: without it, a span like
# 'Invoke ... with `TASK = plan`, ...' followed by unrelated prose two numbered
# steps later ('returns ... `STATUS = needs-input`', commands/feature.md) would
# read STATUS as a passed token that was never actually part of the invocation.
$RE_NUMSTEP   = '^[ \t]*[0-9]+\.[ \t]'
# Written as an ASCII escape sequence, never as the literal character: this file
# must survive Check 1's pure-ASCII scan. bash peels the same run as BYTES under
# LC_ALL=C while .NET peels it as UTF-16 chars - three bytes there, one char
# here, and both land on the identical ASCII remainder. Nothing downstream ever
# reports a column offset, so the difference is unobservable.
$RE_NONASCII  = '^[\u0080-\uFFFF]+'
# CL2xx role and tool integrity. tools: is a single comma-joined frontmatter
# line (never a nested list like skills:), so one capture group holds every
# declared tool name for a comma-split.
$RE_TOOLSKEY  = '^tools:[ \t]*(.*)$'
# An mcp__* token is always mcp__<server>__<tool>, and both segments may embed
# their own underscores/hyphens (mcp__sequential-thinking__sequentialthinking,
# mcp__context7__resolve-library-id), so the class below is intentionally wide
# and greedy - it stops at the first character that cannot be part of a tool
# name (backtick, comma, space, closing paren).
$RE_MCPTOOL   = 'mcp__[A-Za-z0-9_-]+'
# CL200's imperative-verb scan. Line-initial only (after an optional bullet or
# numbered-step marker) is load-bearing: it is what lets
# 'Do not attempt to write files' (negated), 'The calling command appends your
# output' (third-person subject) and 'write `_No findings._`' (mid-sentence,
# after a comma) all pass, with no exclusion list, the same way
# Get-GateClassification needs none for '## Gate activity'.
$RE_WRITEVERB = '^[ \t]*(-[ \t]+|[0-9]+\.[ \t]+)?(Write|Append|Create)[ \t]'
# CL205's predicates. A spec artifact is a numbered NN-name.md file or the
# 04-artifacts/ folder. The write form is word-bounded by hand (the bash twin's
# ERE has no \b) and case-folded only on its first letter, never via a
# culture-aware lowercase, so both twins agree byte-for-byte on non-ASCII
# lines. The actor test is a 'main thread' mention - the phrase every sibling
# step already uses - matched against the whole enclosing numbered step joined
# with single spaces, never the one line: commands/port.md Phase 3 wraps
# 'Main' / 'thread appends ...' across two lines, and names the actor in
# step 3's opening parenthetical.
$RE_SPECARTIFACT  = '[0-9]{2}-[a-z][a-z0-9-]*\.md|04-artifacts/'
$RE_ARTIFACTWRITE = '(^|[^A-Za-z])([Ww]rit(e|es|ing|ten)|[Aa]ppend(s|ed|ing)?|[Ss]av(e|es|ed|ing)|[Rr]ecord(s|ed|ing)?|[Pp]ersist(s|ed|ing)?|[Ss]tor(e|es|ed|ing))([^A-Za-z]|$)'
$RE_MAINTHREAD    = '[Mm]ain[ \t]+thread'
# CL4xx stack-agnostic prose. A <<...>> placeholder span is scrubbed from a
# copy of the line before vocabulary/path matching, so a token that only ever
# appears inside a project-config-style placeholder never fires.
$RE_PLACEHOLDER    = '<<[^>]*>>'
# A hardcoded absolute path: the character immediately before the leading '/'
# or drive letter must be a genuine word boundary (blank, backtick, quote,
# paren, or start of line) - never another path/placeholder character.
# Without this POSITIVE boundary set, '~/.claude/hooks/sd/' and
# '.specs/<ID>/04-artifacts/' both mint a phantom absolute path starting at
# their OWN interior '/', which is not what CL402 means to catch.
$RE_ABSPATH_POSIX  = '(^|[ \t`"''(])(/[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]*)'
$RE_ABSPATH_WIN     = '(^|[ \t`"''(])([A-Za-z]:\\[^ \t`]+)'

function Write-Err([string]$Message) {
    [Console]::Error.WriteLine($Message)
}

function New-OrdinalSet {
    New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
}

# ---- argument handling ------------------------------------------------------

if ([string]::IsNullOrEmpty($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}
if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    Write-Err "contract-lint: -Root is not a directory: '$Root'"
    exit 2
}
$Root = (Resolve-Path -LiteralPath $Root).ProviderPath.TrimEnd('\', '/')

$manifestPath = Join-Path $Root 'specwright.manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Write-Err "contract-lint: manifest not found: $manifestPath"
    exit 2
}

try {
    $manifestText = [System.Text.Encoding]::UTF8.GetString(
        [System.IO.File]::ReadAllBytes($manifestPath))
    $manifest = $manifestText | ConvertFrom-Json
} catch {
    Write-Err "contract-lint: cannot parse $manifestPath - $($_.Exception.Message)"
    exit 2
}

if (-not $manifest.PSObject.Properties.Name.Contains('contractLint')) {
    Write-Err "contract-lint: manifest has no contractLint subtree"
    exit 2
}
$cl = $manifest.contractLint

$ruleFilter = New-OrdinalSet
if (-not [string]::IsNullOrEmpty($Rule)) {
    foreach ($r in $Rule.Split(',')) {
        $t = $r.Trim()
        if ($t.Length -gt 0) { [void]$ruleFilter.Add($t) }
    }
}

# ---- Phase A: index ---------------------------------------------------------

$nsSegment = 'sd'
if ($cl.PSObject.Properties.Name.Contains('installNamespaceSegment') -and
    -not [string]::IsNullOrEmpty($cl.installNamespaceSegment)) {
    $nsSegment = [string]$cl.installNamespaceSegment
}

$ruleIds = New-OrdinalSet
$ruleSeverity = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
foreach ($r in $cl.rules) {
    [void]$ruleIds.Add([string]$r.id)
    $ruleSeverity[[string]$r.id] = [string]$r.severity
}

# Every rule this implementation dispatches, in registry order. The parity guard
# below asserts this equals the manifest registry, so a wave-2 rule cannot land
# in the manifest, the docs or the fixtures without landing here too.
$dispatchIds = @(
    'CL001', 'CL002', 'CL003', 'CL004', 'CL005', 'CL006', 'CL007', 'CL008', 'CL009',
    'CL100', 'CL101', 'CL102', 'CL103', 'CL104',
    'CL200', 'CL201', 'CL202', 'CL203', 'CL204', 'CL205',
    'CL300', 'CL301', 'CL302', 'CL303', 'CL304', 'CL305', 'CL306',
    'CL400', 'CL401', 'CL402',
    'CL500',
    'CL900', 'CL901', 'CL902'
)
$dispatchSet = New-OrdinalSet
foreach ($d in $dispatchIds) { [void]$dispatchSet.Add($d) }

$parityBad = $false
foreach ($d in $dispatchIds) {
    if (-not $ruleIds.Contains($d)) {
        Write-Err "contract-lint: dispatched rule '$d' is absent from manifest contractLint.rules"
        $parityBad = $true
    }
}
foreach ($r in $cl.rules) {
    if (-not $dispatchSet.Contains([string]$r.id)) {
        Write-Err "contract-lint: manifest rule '$($r.id)' is not dispatched by this implementation"
        $parityBad = $true
    }
}
if ($parityBad) {
    Write-Err "contract-lint: registry parity guard failed"
    exit 2
}

$specArtifacts = New-OrdinalSet
if ($cl.PSObject.Properties.Name.Contains('specArtifacts')) {
    foreach ($a in $cl.specArtifacts) { [void]$specArtifacts.Add([string]$a) }
}

$skillConsumers = New-OrdinalSet
if ($cl.PSObject.Properties.Name.Contains('skillConsumers') -and $null -ne $cl.skillConsumers) {
    foreach ($p in $cl.skillConsumers.PSObject.Properties) { [void]$skillConsumers.Add($p.Name) }
}

$overrideTokens = New-OrdinalSet
if ($cl.PSObject.Properties.Name.Contains('overrideOptionTokens')) {
    foreach ($t in $cl.overrideOptionTokens) { [void]$overrideTokens.Add([string]$t) }
}

$gateProseEscapeTokens = New-Object 'System.Collections.Generic.List[string]'
if ($cl.PSObject.Properties.Name.Contains('gateProseEscapeTokens')) {
    foreach ($t in $cl.gateProseEscapeTokens) { [void]$gateProseEscapeTokens.Add([string]$t) }
}

$bootstrapGuardPhrases = New-Object 'System.Collections.Generic.List[string]'
if ($cl.PSObject.Properties.Name.Contains('bootstrapGuardPhrases')) {
    foreach ($t in $cl.bootstrapGuardPhrases) { [void]$bootstrapGuardPhrases.Add([string]$t) }
}

$stackCommands = New-Object 'System.Collections.Generic.List[string]'
$stackLanguages = New-Object 'System.Collections.Generic.List[string]'
if ($cl.PSObject.Properties.Name.Contains('stackTokens') -and $null -ne $cl.stackTokens) {
    if ($cl.stackTokens.PSObject.Properties.Name.Contains('commands')) {
        foreach ($t in $cl.stackTokens.commands) { [void]$stackCommands.Add([string]$t) }
    }
    if ($cl.stackTokens.PSObject.Properties.Name.Contains('languages')) {
        foreach ($t in $cl.stackTokens.languages) { [void]$stackLanguages.Add([string]$t) }
    }
}

$readOnlyAgents = New-OrdinalSet
if ($cl.PSObject.Properties.Name.Contains('readOnlyAgents')) {
    foreach ($a in $cl.readOnlyAgents) { [void]$readOnlyAgents.Add([string]$a) }
}

$knownMcpTools = New-OrdinalSet
if ($cl.PSObject.Properties.Name.Contains('knownMcpTools')) {
    foreach ($t in $cl.knownMcpTools) { [void]$knownMcpTools.Add([string]$t) }
}

# CL500's per-area byte ceilings. $null (not 0) when unconfigured, so a
# manifest with no budgets subtree makes CL500 a structural no-op rather than
# firing on every file with a phantom zero ceiling.
$budgetCommands = $null
$budgetAgents = $null
$budgetSkills = $null
if ($cl.PSObject.Properties.Name.Contains('budgets') -and $null -ne $cl.budgets) {
    $b = $cl.budgets
    if ($b.PSObject.Properties.Name.Contains('commandsBytes')) { $budgetCommands = [int]$b.commandsBytes }
    if ($b.PSObject.Properties.Name.Contains('agentsBytes')) { $budgetAgents = [int]$b.agentsBytes }
    if ($b.PSObject.Properties.Name.Contains('skillsBytes')) { $budgetSkills = [int]$b.skillsBytes }
}

function Get-BudgetForFile([string]$Rel) {
    if ($Rel.StartsWith('commands/')) { return $budgetCommands }
    if ($Rel.StartsWith('agents/')) { return $budgetAgents }
    if ($Rel.StartsWith('skills/')) { return $budgetSkills }
    return $null
}

# Write/Edit/MultiEdit, and nothing else - matches docs/architecture.md's own
# definition of a read-only agent. Bash CAN write a file, but that is a
# different, harder problem, deliberately out of scope for CL200/CL201.
$writeTools = New-OrdinalSet
foreach ($t in @('Write', 'Edit', 'MultiEdit')) { [void]$writeTools.Add($t) }

# Declared gate contracts. Ordinal dictionaries throughout - NEVER an @{} literal,
# whose keys are case-insensitive and would silently diverge from bash's `case`.
$gateHard = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::Ordinal)
$gateCond = New-Object 'System.Collections.Generic.Dictionary[string,string[]]' ([StringComparer]::Ordinal)
$gateFiles = New-OrdinalSet
if ($cl.PSObject.Properties.Name.Contains('gates') -and $null -ne $cl.gates) {
    foreach ($p in $cl.gates.PSObject.Properties) {
        $gf = $p.Name
        if (-not (Test-Path -LiteralPath (Join-Path $Root $gf) -PathType Leaf)) {
            Write-Err "contract-lint: contractLint.gates names a file that does not exist: $gf"
            exit 2
        }
        $gateHard[$gf] = [int]$p.Value.hard
        $conds = @()
        if ($null -ne $p.Value.conditional) { $conds = @($p.Value.conditional | ForEach-Object { [string]$_ }) }
        $gateCond[$gf] = $conds
        [void]$gateFiles.Add($gf)
    }
}

# Scan files: every scanScope glob, deduplicated, ordinal-sorted for a stable
# report order the twin reproduces exactly.
$scanSet = New-OrdinalSet
foreach ($glob in $cl.scanScope) {
    $pattern = Join-Path $Root ([string]$glob).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    $found = @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue)
    foreach ($f in $found) {
        $rel = $f.FullName.Substring($Root.Length).TrimStart('\', '/').Replace('\', '/')
        [void]$scanSet.Add($rel)
    }
}
$scanFiles = New-Object 'System.Collections.Generic.List[string]'
foreach ($s in $scanSet) { [void]$scanFiles.Add($s) }
$scanFiles.Sort([StringComparer]::Ordinal)

if ($scanFiles.Count -eq 0) {
    Write-Err "contract-lint: contractLint.scanScope matched no files under $Root"
    exit 2
}

# ---- per-file line + fence cache -------------------------------------------
#
# One disk pass. Rules read these caches; none re-walks the tree.

$fileLines = New-Object 'System.Collections.Generic.Dictionary[string,string[]]' ([StringComparer]::Ordinal)
$fileFence = New-Object 'System.Collections.Generic.Dictionary[string,bool[]]' ([StringComparer]::Ordinal)

function Read-FileLines([string]$Rel) {
    if ($fileLines.ContainsKey($Rel)) { return }
    $abs = Join-Path $Root $Rel.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    # Read raw bytes and decode UTF-8 explicitly. Get-Content's default encoding
    # on PS 5.1 mangles the non-ASCII gate marker into codepage mojibake, and
    # .gitattributes does NOT pin *.md to LF, so on a Windows checkout every
    # file here is CRLF on disk. One read fixes both.
    $text = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($abs))
    $raw = $text.Split([char]10)
    # A trailing newline yields one empty final element in .NET but no final
    # line in bash's read loop. Drop it so line counts match the twin.
    $n = $raw.Length
    if ($n -gt 0 -and $raw[$n - 1].Length -eq 0) { $n = $n - 1 }
    $lines = New-Object 'string[]' $n
    for ($i = 0; $i -lt $n; $i++) { $lines[$i] = $raw[$i].TrimEnd([char]13) }
    $fence = New-Object 'bool[]' $n
    $inFence = $false
    for ($i = 0; $i -lt $n; $i++) {
        if ([regex]::IsMatch($lines[$i], $RE_FENCE)) {
            $fence[$i] = $true
            $inFence = -not $inFence
        } else {
            $fence[$i] = $inFence
        }
    }
    $fileLines[$Rel] = $lines
    $fileFence[$Rel] = $fence
}

foreach ($rel in $scanFiles) { Read-FileLines $rel }

# ---- finding + suppression stores ------------------------------------------
#
# Defined before the disk-derived inventory below because CL104 (duplicate
# agent frontmatter name) is detected while that inventory is built, not in
# Phase B - the same precedent CL900/CL901 set for the suppression index.

$findings = New-Object 'System.Collections.Generic.List[object]'

function Add-Finding([string]$RuleId, [string]$File, [int]$Line, [string]$Message) {
    # Sanitised at the source, not at print time: a tab or CR inside a message
    # silently corrupts the consumer's tab-delimited read.
    $clean = $Message.Replace([string][char]9, '').Replace([string][char]13, '')
    [void]$findings.Add([PSCustomObject]@{
        Rule = $RuleId; File = $File; Line = $Line; Message = $clean
    })
}

$suppressions = New-Object 'System.Collections.Generic.List[object]'

# ---- disk-derived inventory -------------------------------------------------
#
# Agents, skills and commands come from disk, never from the manifest - they are
# inventory, and the manifest's charter says inventory is derived.

$agentNames = New-OrdinalSet
$agentFileOf = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
$agentOrder = New-Object 'System.Collections.Generic.List[string]'
$agentDir = Join-Path $Root 'agents'
if (Test-Path -LiteralPath $agentDir -PathType Container) {
    $agentPaths = @(Get-ChildItem -Path (Join-Path $agentDir '*.md') -File -ErrorAction SilentlyContinue |
        Sort-Object -Property Name)
    foreach ($p in $agentPaths) {
        $rel = 'agents/' + $p.Name
        Read-FileLines $rel
        $name = ''
        $lines = $fileLines[$rel]
        $limit = [Math]::Min(20, $lines.Length)
        for ($i = 0; $i -lt $limit; $i++) {
            $m = [regex]::Match($lines[$i], '^name:[ \t]*(.+)$')
            if ($m.Success) { $name = $m.Groups[1].Value.Trim(); break }
        }
        if ($name.Length -eq 0) { continue }
        if ($agentNames.Contains($name)) {
            Add-Finding 'CL104' $rel ($i + 1) "agent name '$name' is also declared by $($agentFileOf[$name])"
            continue
        }
        [void]$agentNames.Add($name)
        $agentFileOf[$name] = $rel
        [void]$agentOrder.Add($name)
    }
}

$skillNames = New-OrdinalSet
$skillFileOf = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
$skillOrder = New-Object 'System.Collections.Generic.List[string]'
$skillsDir = Join-Path $Root 'skills'
if (Test-Path -LiteralPath $skillsDir -PathType Container) {
    $skillPaths = @(Get-ChildItem -Path (Join-Path $skillsDir '*') -Directory -ErrorAction SilentlyContinue |
        Sort-Object -Property Name)
    foreach ($d in $skillPaths) {
        $sm = Join-Path $d.FullName 'SKILL.md'
        if (-not (Test-Path -LiteralPath $sm -PathType Leaf)) { continue }
        [void]$skillNames.Add($d.Name)
        $skillFileOf[$d.Name] = 'skills/' + $d.Name + '/SKILL.md'
        [void]$skillOrder.Add($d.Name)
    }
}

$commandNames = New-OrdinalSet
$commandsDir = Join-Path $Root 'commands'
if (Test-Path -LiteralPath $commandsDir -PathType Container) {
    foreach ($p in @(Get-ChildItem -Path (Join-Path $commandsDir '*.md') -File -ErrorAction SilentlyContinue)) {
        [void]$commandNames.Add([System.IO.Path]::GetFileNameWithoutExtension($p.Name))
    }
}

# ---- reference index --------------------------------------------------------
#
# A flat (kind, target, file, line) table. EVERY CL0xx rule reads this table and
# none of them re-walks the disk, so a wave-2 rule means adding one kind to one
# extractor rather than a second traversal.

$refs = New-Object 'System.Collections.Generic.List[object]'
$refPatterns = @(
    @{ Kind = 'sdref';        Pattern = $RE_SDREF },
    @{ Kind = 'commandRef';   Pattern = $RE_CMDREF },
    @{ Kind = 'templatePath'; Pattern = $RE_TPLPATH },
    @{ Kind = 'specArtifact'; Pattern = $RE_ARTIFACT },
    @{ Kind = 'mcpTool';      Pattern = $RE_MCPTOOL }
)

foreach ($rel in $scanFiles) {
    $lines = $fileLines[$rel]
    $fence = $fileFence[$rel]
    foreach ($rp in $refPatterns) {
        for ($i = 0; $i -lt $lines.Length; $i++) {
            if ($fence[$i]) { continue }
            foreach ($m in [regex]::Matches($lines[$i], $rp.Pattern)) {
                $tok = $m.Value
                if ($rp.Kind -eq 'specArtifact') {
                    # Drop the boundary character the pattern had to consume.
                    if ($tok.Length -gt 0 -and -not ($tok[0] -ge '0' -and $tok[0] -le '9')) {
                        $tok = $tok.Substring(1)
                    }
                }
                [void]$refs.Add([PSCustomObject]@{
                    Kind = $rp.Kind; Target = $tok; File = $rel; Line = ($i + 1)
                })
            }
        }
    }
}

# ---- agent `skills:` frontmatter index -------------------------------------

$agentSkillRefs = New-Object 'System.Collections.Generic.List[object]'
foreach ($name in $agentOrder) {
    $rel = $agentFileOf[$name]
    $lines = $fileLines[$rel]
    $inFm = $false
    $inSkills = $false
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        if ($line -ceq '---') {
            if (-not $inFm) { $inFm = $true; continue } else { break }
        }
        if (-not $inFm) { continue }
        if ([regex]::IsMatch($line, $RE_SKILLSKEY)) { $inSkills = $true; continue }
        if ($inSkills) {
            $m = [regex]::Match($line, $RE_SKILLITEM)
            if ($m.Success) {
                [void]$agentSkillRefs.Add([PSCustomObject]@{
                    File = $rel; Line = ($i + 1); Skill = $m.Groups[1].Value.Trim()
                })
                continue
            }
            $inSkills = $false
        }
    }
}

# ---- agent `tools:` frontmatter index (CL2xx) ------------------------------
#
# tools: is one comma-joined line, never a nested list like skills:, so this is
# one line lookup per agent rather than a multi-line list walk.

# agentBodyStart is the 0-based index of the first line AFTER the closing ---,
# so CL203 can search the agent's BODY for a tool mention without a frontmatter
# field (e.g. description:) counting as "the body uses it".
$agentToolRefs = New-Object 'System.Collections.Generic.List[object]'
$agentBodyStart = New-Object 'System.Collections.Generic.Dictionary[string,int]' ([StringComparer]::Ordinal)
foreach ($name in $agentOrder) {
    $rel = $agentFileOf[$name]
    $lines = $fileLines[$rel]
    $inFm = $false
    $bodyStart = $lines.Length
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        if ($line -ceq '---') {
            if (-not $inFm) { $inFm = $true; continue } else { $bodyStart = $i + 1; break }
        }
        if (-not $inFm) { continue }
        $mt = [regex]::Match($line, $RE_TOOLSKEY)
        if (-not $mt.Success) { continue }
        foreach ($piece in $mt.Groups[1].Value.Split(',')) {
            $tool = $piece.Trim()
            if ($tool.Length -eq 0) { continue }
            [void]$agentToolRefs.Add([PSCustomObject]@{
                Agent = $name; Tool = $tool; File = $rel; Line = ($i + 1)
            })
        }
    }
    $agentBodyStart[$name] = $bodyStart
}

# writeCapableAgents - derived from disk (agentToolRefs), not declared. Mirrors
# how CL200 itself decides write-capability: an agent whose own tools: line
# carries Write/Edit/MultiEdit right now, regardless of whether anyone
# remembers to list it anywhere. Used by CL203/CL204 to pick severity.
$writeCapableAgents = New-OrdinalSet
foreach ($t in $agentToolRefs) {
    if ($writeTools.Contains($t.Tool)) { [void]$writeCapableAgents.Add($t.Agent) }
}

# ---- mode declaration index (CL1xx) -----------------------------------------
#
# A mode heading carries a selector as a backticked `KEY = value` pair, except
# the `Task type: `value`` grammar (reviewer, debugger) whose selector key is
# never in the heading text - TASK_TYPE is the established convention. Either
# way, the heading is a real modeDecl only if it is immediately followed (within
# a small window, allowing blank lines) by 'Inputs (required):' then
# 'Inputs (optional):' - that gate is what lets 'Scoped re-plan (`TASK = plan`
# with `REPLAN_SCOPE`)' (agents/spec-architect.md) coexist with Mode 2 itself:
# it repeats the same backticked pair but has no Inputs lines of its own, so it
# never registers as a second declaration of `TASK = plan`.

function Get-TokenSet([string]$Raw) {
    $set = New-OrdinalSet
    if ($Raw -cne 'none') {
        foreach ($piece in $Raw.Split(',')) {
            $t = $piece.Trim()
            if ($t.Length -gt 0) { [void]$set.Add($t) }
        }
    }
    # The comma operator is load-bearing: 'return $set' on an EMPTY HashSet
    # enumerates it onto the pipeline (zero objects), and the caller's property
    # assignment then captures $null instead of the empty set. Wrapping forces
    # exactly one output object regardless of how many elements $set holds.
    return ,$set
}

$modeDecls = New-Object 'System.Collections.Generic.List[object]'
foreach ($name in $agentOrder) {
    $rel = $agentFileOf[$name]
    $lines = $fileLines[$rel]
    $fence = $fileFence[$rel]

    $defaultKey = 'TASK_TYPE'
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($fence[$i]) { continue }
        $mf = [regex]::Match($lines[$i], $RE_FIELD_KEY)
        if ($mf.Success) { $defaultKey = $mf.Groups[1].Value; break }
    }

    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($fence[$i]) { continue }
        $mh = [regex]::Match($lines[$i], $RE_HEADING)
        if (-not $mh.Success) { continue }
        $headText = $mh.Groups[2].Value
        $key = ''
        $value = ''
        $mk = [regex]::Match($headText, $RE_KV)
        if ($mk.Success) {
            $key = $mk.Groups[1].Value
            $value = $mk.Groups[2].Value
        } else {
            $mt = [regex]::Match($headText, $RE_TASKTYPE)
            if ($mt.Success) { $key = $defaultKey; $value = $mt.Groups[1].Value }
        }
        if ($key.Length -eq 0) { continue }

        $reqLine = -1
        $limit = [Math]::Min($i + 3, $lines.Length - 1)
        for ($j = $i + 1; $j -le $limit; $j++) {
            if ($fence[$j]) { continue }
            if ([regex]::IsMatch($lines[$j], $RE_INPUT_REQ)) { $reqLine = $j; break }
        }
        if ($reqLine -lt 0) { continue }
        if ($reqLine + 1 -ge $lines.Length -or $fence[$reqLine + 1]) { continue }
        $mo = [regex]::Match($lines[$reqLine + 1], $RE_INPUT_OPT)
        if (-not $mo.Success) { continue }
        $mr = [regex]::Match($lines[$reqLine], $RE_INPUT_REQ)

        [void]$modeDecls.Add([PSCustomObject]@{
            Agent = $name; Key = $key; Value = $value; File = $rel; Line = ($i + 1)
            Required = (Get-TokenSet $mr.Groups[1].Value.Trim())
            Optional = (Get-TokenSet $mo.Groups[1].Value.Trim())
        })
    }
}

# ---- invocation index (CL1xx) ------------------------------------------------
#
# An invocation ANCHOR is any commands/*.md line already indexed as an sdref
# whose raw text mentions "nvoke" (catches Invoke/invoke, and a heading like
# '## Phase 2 - Invoke `sd-reviewer`'). From the anchor, tokens are collected
# forward through every `KEY = value` pair up to the next heading or the next
# anchor - whichever comes first - which is what lets a bullet-block
# ('Invoke X with:' then '- `A = b`'), a same-line inline form, and a wrapped
# multi-line inline form (a continuation that itself starts with a backtick)
# all resolve the same way, and what keeps two invocations in one un-headed
# section (bug.md's enumerate then its verify loop) from bleeding into each
# other's token set.

$anchorLines = New-OrdinalSet
$anchors = New-Object 'System.Collections.Generic.List[object]'
foreach ($r in $refs) {
    if ($r.Kind -cne 'sdref') { continue }
    if (-not $r.File.StartsWith('commands/', [System.StringComparison]::Ordinal)) { continue }
    if (-not $fileLines[$r.File][$r.Line - 1].Contains('nvoke')) { continue }
    [void]$anchors.Add([PSCustomObject]@{ Agent = $r.Target; File = $r.File; Line = $r.Line })
    [void]$anchorLines.Add($r.File + ':' + $r.Line)
}

$invocations = New-Object 'System.Collections.Generic.List[object]'
foreach ($a in $anchors) {
    $lines = $fileLines[$a.File]
    $fence = $fileFence[$a.File]
    $tokens = New-OrdinalSet
    $modeKey = ''
    $modeValue = ''
    $startIdx = $a.Line - 1
    for ($j = $startIdx; $j -lt $lines.Length; $j++) {
        if ($fence[$j]) { continue }
        if ($j -gt $startIdx) {
            if ([regex]::IsMatch($lines[$j], $RE_HEADING)) { break }
            if ([regex]::IsMatch($lines[$j], $RE_NUMSTEP)) { break }
            if ($anchorLines.Contains($a.File + ':' + ($j + 1))) { break }
        }
        foreach ($m in [regex]::Matches($lines[$j], $RE_KV)) {
            $k = $m.Groups[1].Value
            [void]$tokens.Add($k)
            if ($modeKey.Length -eq 0 -and ($k -ceq 'TASK' -or $k -ceq 'WORKFLOW_TYPE' -or $k -ceq 'TASK_TYPE')) {
                $modeKey = $k
                $modeValue = $m.Groups[2].Value
            }
        }
    }
    if ($modeKey.Length -eq 0) { continue }
    [void]$invocations.Add([PSCustomObject]@{
        Agent = $a.Agent; Key = $modeKey; Value = $modeValue; File = $a.File; Line = $a.Line; Tokens = $tokens
    })
}

# ---- gate index -------------------------------------------------------------
#
# A gate BLOCK is [heading line, next heading of any level or EOF). That window
# is the whole reason CL300 does not fire on the ~20 literal STOPs in Phase 0
# bootstrap error paths - they all sit under a '## Phase 0' heading, never
# inside a gate block.

function Get-GateClassification([string]$Title) {
    # Peel the leading non-ASCII marker run, then an optional 'Phase N - '
    # prefix, and report whether the remainder names a gate.
    $t = [regex]::Replace($Title, $RE_NONASCII, '')
    while ($t.Length -gt 0 -and $t[0] -eq ' ') { $t = $t.Substring(1) }
    $mp = [regex]::Match($t, $RE_PHASE)
    if ($mp.Success) { $t = $mp.Groups[1].Value }
    if (-not $t.StartsWith('Gate', [System.StringComparison]::Ordinal)) { return $null }
    $rest = $t.Substring(4)

    $m = [regex]::Match($rest, $RE_GATE_NUM)
    if ($m.Success) { return @{ Kind = 'hard'; Label = $m.Groups[1].Value } }
    $m = [regex]::Match($rest, $RE_GATE_SUB)
    if ($m.Success) { return @{ Kind = 'conditional'; Label = $m.Groups[1].Value } }
    $m = [regex]::Match($rest, $RE_GATE_REPL)
    if ($m.Success) { return @{ Kind = 'conditional'; Label = 'Re-plan' } }
    if ([regex]::IsMatch($rest, $RE_GATE_UNN)) { return @{ Kind = 'hard'; Label = '' } }
    # Anything else is not a gate. This single branch is the entire
    # false-positive defence and it needs no exclusion list: 'Gate' followed by a
    # lowercase word ('## Gate activity' in commands/status.md) is never a gate.
    return $null
}

$gates = New-Object 'System.Collections.Generic.List[object]'
foreach ($rel in $scanFiles) {
    $lines = $fileLines[$rel]
    $fence = $fileFence[$rel]
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($fence[$i]) { continue }
        $mh = [regex]::Match($lines[$i], $RE_HEADING)
        if (-not $mh.Success) { continue }
        $cls = Get-GateClassification $mh.Groups[2].Value
        if ($null -eq $cls) { continue }
        $end = $lines.Length
        for ($j = $i + 1; $j -lt $lines.Length; $j++) {
            if ((-not $fence[$j]) -and [regex]::IsMatch($lines[$j], $RE_SUBHEAD)) { $end = $j; break }
        }
        $isHard = ($lines[$i].Contains('(HARD)') -or $lines[$i].Contains('[HARD]'))
        [void]$gates.Add([PSCustomObject]@{
            File = $rel; Line = ($i + 1); Kind = $cls.Kind; Label = $cls.Label
            HardMarked = $isHard; BlockEnd = $end
        })
    }
}

# ---- suppression index ------------------------------------------------------
#
# Indexed ONLY inside scanScope and ONLY outside fenced code blocks, so
# docs/contract-lint.md and CONTRIBUTING.md can show the syntax without minting
# a phantom suppression that then trips CL902.

foreach ($rel in $scanFiles) {
    $lines = $fileLines[$rel]
    $fence = $fileFence[$rel]
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($fence[$i]) { continue }
        if (-not [regex]::IsMatch($lines[$i], $RE_SUPPRESS)) { continue }
        $m = [regex]::Match($lines[$i], $RE_SUPPARTS)
        if (-not $m.Success) { continue }
        $sRule = $m.Groups[1].Value
        $reason = $m.Groups[2].Value
        $cut = $reason.IndexOf('-->', [System.StringComparison]::Ordinal)
        if ($cut -ge 0) { $reason = $reason.Substring(0, $cut) }
        # Measure the payload with separators removed, mirroring `tr -d ' \t-'`.
        $bare = $reason.Replace(' ', '').Replace([string][char]9, '').Replace('-', '')
        $bad = $false
        if (-not $ruleIds.Contains($sRule)) {
            $bad = $true
            Add-Finding 'CL901' $rel ($i + 1) "suppression names unknown rule '$sRule'"
        } elseif ($bare.Length -lt 10) {
            Add-Finding 'CL900' $rel ($i + 1) "suppression for $sRule carries no usable reason"
        }
        [void]$suppressions.Add([PSCustomObject]@{
            File = $rel; Line = ($i + 1); Rule = $sRule; Used = $false; Bad = $bad
        })
    }
}

# ---- Phase B: rules ---------------------------------------------------------
#
# Each rule reads the index and calls Add-Finding. SEVERITY IS NEVER PASSED BY A
# RULE - it is looked up from the manifest at emit time, so a BLOCK/WARN
# divergence between the twins is structurally impossible.

# CL002 owns the lines of an agent's `skills:` frontmatter list. Without this
# set, both CL001 and CL002 would fire on the same missing skill - one problem
# reported twice, the same "one error, not two" doctrine that exempts a
# CL901-flagged suppression from CL902.
$skillEntryLines = New-OrdinalSet
foreach ($a in $agentSkillRefs) { [void]$skillEntryLines.Add($a.File + ':' + $a.Line) }

# CL001 / CL003
foreach ($r in $refs) {
    if ($r.Kind -cne 'sdref') { continue }
    if ($agentNames.Contains($r.Target)) { continue }
    if ($skillNames.Contains($r.Target)) { continue }
    if ($skillEntryLines.Contains($r.File + ':' + $r.Line)) { continue }
    $txt = $fileLines[$r.File][$r.Line - 1].ToLowerInvariant()
    if ($txt.Contains('skill')) {
        Add-Finding 'CL003' $r.File $r.Line "unresolved skill reference '$($r.Target)'"
    } else {
        Add-Finding 'CL001' $r.File $r.Line "unresolved sd- reference '$($r.Target)'"
    }
}

# CL002
foreach ($a in $agentSkillRefs) {
    $sm = Join-Path (Join-Path (Join-Path $Root 'skills') $a.Skill) 'SKILL.md'
    if (Test-Path -LiteralPath $sm -PathType Leaf) { continue }
    Add-Finding 'CL002' $a.File $a.Line "skills: entry '$($a.Skill)' has no skills/$($a.Skill)/SKILL.md"
}

# CL004
foreach ($s in $skillOrder) {
    if ($skillConsumers.Contains($s)) { continue }
    $self = $skillFileOf[$s]
    $referenced = $false
    foreach ($r in $refs) {
        if ($r.Kind -cne 'sdref') { continue }
        if ($r.Target -cne $s) { continue }
        if ($r.File -ceq $self) { continue }
        $referenced = $true; break
    }
    if (-not $referenced) {
        foreach ($a in $agentSkillRefs) {
            if ($a.Skill -ceq $s) { $referenced = $true; break }
        }
    }
    if (-not $referenced) {
        Add-Finding 'CL004' $self 1 "skill '$s' is referenced by nothing in scan scope"
    }
}

# CL005
$nsPrefix = 'templates/' + $nsSegment + '/'
foreach ($r in $refs) {
    if ($r.Kind -cne 'templatePath') { continue }
    $p = $r.Target
    # templates/<ns>/... is the INSTALL target (~/.claude/templates/sd/), not a
    # repo path. Fold the namespace segment away before testing disk.
    if ($p.StartsWith($nsPrefix, [System.StringComparison]::Ordinal)) {
        $p = 'templates/' + $p.Substring($nsPrefix.Length)
    } elseif ($p -ceq ('templates/' + $nsSegment)) {
        $p = 'templates'
    }
    if ($p.EndsWith('.', [System.StringComparison]::Ordinal)) { $p = $p.Substring(0, $p.Length - 1) }
    if ($p.EndsWith('/', [System.StringComparison]::Ordinal)) { $p = $p.Substring(0, $p.Length - 1) }
    $abs = Join-Path $Root $p.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
    if (Test-Path -LiteralPath $abs) { continue }
    Add-Finding 'CL005' $r.File $r.Line "templates path does not exist: '$($r.Target)'"
}

# CL006
foreach ($r in $refs) {
    if ($r.Kind -cne 'commandRef') { continue }
    $name = $r.Target.Substring(4)
    if ($commandNames.Contains($name)) { continue }
    Add-Finding 'CL006' $r.File $r.Line "no command file for '$($r.Target)'"
}

# CL007
foreach ($a in $agentOrder) {
    $seen = $false
    foreach ($r in $refs) {
        if ($r.Kind -cne 'sdref') { continue }
        if ($r.Target -cne $a) { continue }
        if ($r.File.StartsWith('commands/', [System.StringComparison]::Ordinal)) { $seen = $true; break }
    }
    if (-not $seen) {
        Add-Finding 'CL007' $agentFileOf[$a] 1 "agent '$a' is invoked by no command"
    }
}

# CL008
foreach ($r in $refs) {
    if ($r.Kind -cne 'specArtifact') { continue }
    if ($specArtifacts.Contains($r.Target)) { continue }
    Add-Finding 'CL008' $r.File $r.Line "unknown spec artifact filename '$($r.Target)'"
}

# CL009 - a command's '## Phase 0' section restates text sd-bootstrap-guard
# owns. Commands cannot load skills via frontmatter, so they read the skill at
# runtime; a copy of its messages in Phase 0 is the drift SW-54 removed. A
# phrase wrapped across two lines is caught by joining each line with the
# next (trimmed, one space) - reported on the line where it starts, and only
# when the next line alone does not already carry it, so one occurrence is one
# finding. Ordinal .Contains, the same as CL306. Trim is space/tab ONLY: a bare
# .Trim() also strips Unicode whitespace and would diverge from the bash twin.
$blankChars = [char[]]@([char]32, [char]9)
foreach ($rel in $scanFiles) {
    if (-not $rel.StartsWith('commands/', [StringComparison]::Ordinal)) { continue }
    $lines = $fileLines[$rel]
    $fence = $fileFence[$rel]
    $inPhase0 = $false
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($fence[$i]) { continue }
        if ([regex]::IsMatch($lines[$i], $RE_PHASE0)) { $inPhase0 = $true; continue }
        if ($inPhase0 -and [regex]::IsMatch($lines[$i], $RE_SECTION_END)) { $inPhase0 = $false }
        if (-not $inPhase0) { continue }
        if ([regex]::IsMatch($lines[$i], $RE_SUPPRESS)) { continue }
        $cur = $lines[$i].Trim($blankChars)
        $nxt = ''
        $j = $i + 1
        if ($j -lt $lines.Length -and -not $fence[$j] -and
            -not [regex]::IsMatch($lines[$j], $RE_SECTION_END) -and
            -not [regex]::IsMatch($lines[$j], $RE_SUPPRESS)) {
            $nxt = $lines[$j].Trim($blankChars)
        }
        foreach ($phrase in $bootstrapGuardPhrases) {
            if ($phrase.Length -eq 0) { continue }
            $hit = $cur.Contains($phrase)
            if (-not $hit -and $nxt.Length -gt 0 -and -not $nxt.Contains($phrase)) {
                $hit = ($cur + ' ' + $nxt).Contains($phrase)
            }
            if ($hit) {
                Add-Finding 'CL009' $rel ($i + 1) "Phase 0 restates '$phrase', which sd-bootstrap-guard owns - read the skill instead of copying its text"
                break
            }
        }
    }
}

# CL100 / CL102 / CL103 - each invocation against the mode it names. A target
# agent that CL001 already flagged as unresolved gets no CL100 pile-on.
foreach ($inv in $invocations) {
    if (-not $agentNames.Contains($inv.Agent)) { continue }
    $md = $null
    foreach ($d in $modeDecls) {
        if ($d.Agent -cne $inv.Agent) { continue }
        if ($d.Key -cne $inv.Key) { continue }
        if ($d.Value -cne $inv.Value) { continue }
        $md = $d; break
    }
    if ($null -eq $md) {
        Add-Finding 'CL100' $inv.File $inv.Line "invocation sets $($inv.Key) = $($inv.Value) but agent '$($inv.Agent)' declares no such mode"
        continue
    }
    foreach ($t in $md.Required) {
        if ($inv.Tokens.Contains($t)) { continue }
        Add-Finding 'CL102' $inv.File $inv.Line "invocation of '$($inv.Agent)' ($($inv.Key) = $($inv.Value)) omits required input '$t'"
    }
    foreach ($t in $inv.Tokens) {
        if ($t -ceq $inv.Key) { continue }
        if ($md.Required.Contains($t) -or $md.Optional.Contains($t)) { continue }
        Add-Finding 'CL103' $inv.File $inv.Line "invocation of '$($inv.Agent)' ($($inv.Key) = $($inv.Value)) passes undeclared input '$t'"
    }
}

# CL101 - the inverse of CL100: a declared mode nobody ever selects.
foreach ($d in $modeDecls) {
    $seen = $false
    foreach ($inv in $invocations) {
        if ($inv.Agent -cne $d.Agent) { continue }
        if ($inv.Key -cne $d.Key) { continue }
        if ($inv.Value -cne $d.Value) { continue }
        $seen = $true; break
    }
    if (-not $seen) {
        Add-Finding 'CL101' $d.File $d.Line "agent '$($d.Agent)' declares mode $($d.Key) = $($d.Value) that no command ever invokes"
    }
}

# CL200 - disk-only, no manifest input. Any agent whose OWN tools: line carries
# none of Write/Edit/MultiEdit is a candidate; its body is then scanned for a
# line-initial Write/Append/Create, which is what lets every negated,
# third-person or mid-sentence use of those words pass untouched.
foreach ($name in $agentOrder) {
    $hasWriteTool = $false
    foreach ($t in $agentToolRefs) {
        if ($t.Agent -cne $name) { continue }
        if ($writeTools.Contains($t.Tool)) { $hasWriteTool = $true; break }
    }
    if ($hasWriteTool) { continue }
    $rel = $agentFileOf[$name]
    $lines = $fileLines[$rel]
    $fence = $fileFence[$rel]
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($fence[$i]) { continue }
        $mv = [regex]::Match($lines[$i], $RE_WRITEVERB)
        if (-not $mv.Success) { continue }
        $verb = $mv.Groups[2].Value
        Add-Finding 'CL200' $rel ($i + 1) "agent '$name' has no write tool but this line instructs it to $verb"
    }
}

# CL201 - the declared-vs-disk half: an agent this manifest promises will stay
# read-only, but whose own tools: line has grown a write tool since.
foreach ($t in $agentToolRefs) {
    if (-not $readOnlyAgents.Contains($t.Agent)) { continue }
    if (-not $writeTools.Contains($t.Tool)) { continue }
    Add-Finding 'CL201' $t.File $t.Line "agent '$($t.Agent)' is declared read-only in contractLint.readOnlyAgents but its tools: line includes write tool '$($t.Tool)'"
}

# CL202 - every mcp__* token anywhere in scan scope (frontmatter tools: lines
# included, which is exactly where the historical typo'd tool name lived)
# against the hand-maintained allowlist.
foreach ($r in $refs) {
    if ($r.Kind -cne 'mcpTool') { continue }
    if ($knownMcpTools.Contains($r.Target)) { continue }
    Add-Finding 'CL202' $r.File $r.Line "mcp tool name '$($r.Target)' is absent from contractLint.knownMcpTools"
}

# CL203/CL204 - a tool this agent's own frontmatter declares, that its own
# body (everything after the closing ---) never mentions by name. WARN
# (CL203) when the agent has no write tool of its own; BLOCK (CL204) when
# the agent is write-capable - an unexplained unused Write/Edit/MultiEdit
# sibling on the one class of agent that holds write power is the
# highest-value thing this check can find. Severity is still looked up from
# the manifest at emit time per rule id (never computed) - CL204 is a
# distinct rule id precisely so that invariant holds.
foreach ($t in $agentToolRefs) {
    $lines = $fileLines[$t.File]
    $start = $agentBodyStart[$t.Agent]
    $used = $false
    for ($i = $start; $i -lt $lines.Length; $i++) {
        if ($lines[$i].IndexOf($t.Tool, [System.StringComparison]::Ordinal) -ge 0) { $used = $true; break }
    }
    if (-not $used) {
        $rid = if ($writeCapableAgents.Contains($t.Agent)) { 'CL204' } else { 'CL203' }
        Add-Finding $rid $t.File $t.Line "agent '$($t.Agent)' declares tool '$($t.Tool)' but its body never mentions it"
    }
}

# CL205 - the command-side twin of CL200. An invocation of an agent with no
# write tool (read off disk, $writeCapableAgents) opens a window that runs to
# the next heading or the next anchor. Unlike the CL1xx token span it does NOT
# stop at a numbered step: the defect this catches (SW-51, rca.md Phase 2) lives
# in step 3, two steps after step 1's invocation. Inside the window, a line
# that names a spec artifact and a write form, in a numbered step that never
# says 'main thread', asserts a write nobody is told to perform - the agent
# cannot, and the main thread was never asked. The step is [nearest numbered
# step at or above the line (clamped to the anchor), next numbered step /
# heading / anchor), fenced lines skipped. Unresolved targets are CL001's
# problem, not this one.
function Get-StepText([string]$Rel, [int]$Lo, [int]$Idx) {
    $lines = $fileLines[$Rel]
    $fence = $fileFence[$Rel]
    $s = $Idx
    while ($s -gt $Lo) {
        if (-not $fence[$s] -and [regex]::IsMatch($lines[$s], $RE_NUMSTEP)) { break }
        $s--
    }
    $sb = New-Object System.Text.StringBuilder
    for ($k = $s; $k -lt $lines.Length; $k++) {
        if ($fence[$k]) { continue }
        if ($k -gt $s) {
            if ([regex]::IsMatch($lines[$k], $RE_HEADING)) { break }
            if ([regex]::IsMatch($lines[$k], $RE_NUMSTEP)) { break }
            if ($anchorLines.Contains($Rel + ':' + ($k + 1))) { break }
        }
        [void]$sb.Append(' ').Append($lines[$k])
    }
    return $sb.ToString()
}

$cl205Seen = New-OrdinalSet
foreach ($a in $anchors) {
    if (-not $agentNames.Contains($a.Agent)) { continue }
    if ($writeCapableAgents.Contains($a.Agent)) { continue }
    $lines = $fileLines[$a.File]
    $fence = $fileFence[$a.File]
    $startIdx = $a.Line - 1
    for ($j = $startIdx; $j -lt $lines.Length; $j++) {
        if ($fence[$j]) { continue }
        $txt = $lines[$j]
        if ($j -gt $startIdx) {
            if ([regex]::IsMatch($txt, $RE_HEADING)) { break }
            if ($anchorLines.Contains($a.File + ':' + ($j + 1))) { break }
        }
        if (-not [regex]::IsMatch($txt, $RE_SPECARTIFACT)) { continue }
        if (-not [regex]::IsMatch($txt, $RE_ARTIFACTWRITE)) { continue }
        if ([regex]::IsMatch((Get-StepText $a.File $startIdx $j), $RE_MAINTHREAD)) { continue }
        if (-not $cl205Seen.Add($a.File + ':' + ($j + 1))) { continue }
        Add-Finding 'CL205' $a.File ($j + 1) "step asserts a spec-artifact write inside the block of '$($a.Agent)', which has no write tool, and names no main-thread writer"
    }
}

# The seven steps below are a CONTRACT with contract-lint.sh's normalize_option.
# Both must produce byte-identical tokens or CL305 diverges between the twins.
#   1. truncate at the first backtick        5. drop every ` and " character
#   2. trim spaces/tabs                      6. lowercase A-Z only
#   3. truncate at the first " - "           7. trim spaces/tabs again
#   4. truncate at the first " <"
function Get-NormalizedOption([string]$Raw) {
    $trimChars = [char[]]@([char]32, [char]9)
    $s = $Raw
    $i = $s.IndexOf('`', [System.StringComparison]::Ordinal)
    if ($i -ge 0) { $s = $s.Substring(0, $i) }
    $s = $s.Trim($trimChars)
    $i = $s.IndexOf(' - ', [System.StringComparison]::Ordinal)
    if ($i -ge 0) { $s = $s.Substring(0, $i) }
    $i = $s.IndexOf(' <', [System.StringComparison]::Ordinal)
    if ($i -ge 0) { $s = $s.Substring(0, $i) }
    $s = $s.Replace('`', '').Replace('"', '').ToLowerInvariant()
    return $s.Trim($trimChars)
}

function Get-GateOptions([string]$Rel, [int]$StartLine, [int]$BlockEnd) {
    $lines = $fileLines[$Rel]
    $tokens = New-Object 'System.Collections.Generic.List[object]'
    $hasSet = $false
    $bullets = 0
    for ($i = $StartLine - 1; $i -lt $BlockEnd; $i++) {
        $line = $lines[$i]
        $mp = [regex]::Match($line, $RE_OPTPAREN)
        if ($mp.Success) {
            $hasSet = $true
            $inner = $mp.Value
            $inner = $inner.Substring(1, $inner.Length - 2)
            foreach ($piece in $inner.Split([char]47)) {
                $tok = Get-NormalizedOption $piece
                if ($tok.Length -gt 0) {
                    [void]$tokens.Add([PSCustomObject]@{ Line = ($i + 1); Token = $tok })
                }
            }
        }
        if ([regex]::IsMatch($line, $RE_BULLET)) {
            $bullets = $bullets + 1
            $mb = [regex]::Match($line, $RE_BULLETTOK)
            if ($mb.Success) {
                $tok = Get-NormalizedOption $mb.Groups[1].Value
                if ($tok.Length -gt 0) {
                    [void]$tokens.Add([PSCustomObject]@{ Line = ($i + 1); Token = $tok })
                }
            }
        }
    }
    if ($bullets -ge 2) { $hasSet = $true }
    return @{ HasSet = $hasSet; Tokens = $tokens }
}

# CL300 / CL301 / CL305 / CL306
foreach ($g in $gates) {
    $lines = $fileLines[$g.File]
    $fence = $fileFence[$g.File]
    $hasStop = $false
    for ($i = $g.Line - 1; $i -lt $g.BlockEnd; $i++) {
        if ($lines[$i].Contains('STOP')) { $hasStop = $true; break }
    }
    if (-not $hasStop) {
        Add-Finding 'CL300' $g.File $g.Line 'gate block contains no literal STOP'
    }
    $opts = Get-GateOptions $g.File $g.Line $g.BlockEnd
    if (-not $opts.HasSet) {
        Add-Finding 'CL301' $g.File $g.Line 'gate block offers no option set'
    }
    if ($g.HardMarked) {
        foreach ($t in $opts.Tokens) {
            if ($overrideTokens.Contains($t.Token)) {
                Add-Finding 'CL305' $g.File $t.Line "HARD gate offers override option '$($t.Token)'"
            }
        }
        # CL306 - a naive phrase scan over gate-block PROSE, deliberately
        # excluding whatever CL305 already governs: CLAUDE.md rule 6 frames
        # "listed as a choice" and "described in prose" as the two mutually
        # exclusive halves of a HARD gate's escape-hatch surface, so a line
        # that is itself part of the option-set syntax (the slash
        # parenthetical, or a backtick-led option bullet) is CL305's
        # territory, not CL306's - without this exclusion, perf.md's already
        # CL305-suppressed Case A ('proceed anyway' inside the option set)
        # false-fires CL306 too, on both the option line and its own
        # suppression comment's reason text. It fires on commands/bug.md's
        # logged insist-and-proceed sentence and commands/release.md's "may
        # override the version" bullet (neither is option-set syntax) unless
        # annotated - fixing that is the point of this rule, not a bug in it.
        # See gateProseEscapeTokens in the manifest.
        for ($i = $g.Line - 1; $i -lt $g.BlockEnd; $i++) {
            if ($fence[$i]) { continue }
            if ([regex]::IsMatch($lines[$i], $RE_SUPPRESS)) { continue }
            if ([regex]::IsMatch($lines[$i], $RE_OPTPAREN)) { continue }
            if ([regex]::IsMatch($lines[$i], $RE_BULLETTOK)) { continue }
            foreach ($phrase in $gateProseEscapeTokens) {
                if ($lines[$i].Contains($phrase)) {
                    Add-Finding 'CL306' $g.File ($i + 1) "HARD gate prose describes an escape hatch ('$phrase')"
                    break
                }
            }
        }
    }
}

# CL400 / CL401 / CL402 - stack-agnostic prose + hardcoded absolute paths.
# One line-scan pass over scanScope, deliberately narrow (word-bounded
# vocabulary hits, positive-boundary path regex) to keep the false-positive
# band this wave occupies under control - see the manifest's
# $stackTokensComment.
foreach ($rel in $scanFiles) {
    $lines = $fileLines[$rel]
    $fence = $fileFence[$rel]
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($fence[$i]) { continue }
        $scrubbed = [regex]::Replace($lines[$i], $RE_PLACEHOLDER, '')
        foreach ($tok in $stackCommands) {
            $pat = '(^|[^A-Za-z0-9_])' + [regex]::Escape($tok) + '([^A-Za-z0-9_]|$)'
            if ([regex]::IsMatch($scrubbed, $pat)) {
                Add-Finding 'CL400' $rel ($i + 1) "hardcoded stack command token '$tok'"
            }
        }
        foreach ($tok in $stackLanguages) {
            $pat = '(^|[^A-Za-z0-9_])' + [regex]::Escape($tok) + '([^A-Za-z0-9_]|$)'
            if ([regex]::IsMatch($scrubbed, $pat)) {
                Add-Finding 'CL401' $rel ($i + 1) "hardcoded language/framework name '$tok'"
            }
        }
        $mw = [regex]::Match($scrubbed, $RE_ABSPATH_WIN)
        if ($mw.Success) {
            Add-Finding 'CL402' $rel ($i + 1) "hardcoded absolute path '$($mw.Groups[2].Value)'"
        } else {
            $mp = [regex]::Match($scrubbed, $RE_ABSPATH_POSIX)
            if ($mp.Success) {
                Add-Finding 'CL402' $rel ($i + 1) "hardcoded absolute path '$($mp.Groups[2].Value)'"
            }
        }
    }
}

# CL500 - file budgets. Byte count is NORMALIZED (sum of each line's UTF-8
# byte length, plus one separator per line boundary), never a raw disk read:
# this repo's *.md scanScope is 'text=auto', checking out LF on Linux CI and
# CRLF on Windows, so [System.IO.File]::ReadAllBytes(...).Length would make
# CL500 disagree with itself across platforms for byte-identical content -
# see the manifest's $budgetsComment.
foreach ($rel in $scanFiles) {
    $budget = Get-BudgetForFile $rel
    if ($null -eq $budget) { continue }
    $lines = $fileLines[$rel]
    $bytes = 0
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $bytes += [System.Text.Encoding]::UTF8.GetByteCount($lines[$i])
    }
    if ($lines.Length -gt 1) { $bytes += ($lines.Length - 1) }
    if ($bytes -gt $budget) {
        $over = $bytes - $budget
        Add-Finding 'CL500' $rel 1 "file is $bytes bytes, $over over the $budget-byte budget"
    }
}

# CL302 / CL303 / CL304
foreach ($rel in $scanFiles) {
    $count = 0
    $labels = New-Object 'System.Collections.Generic.List[int]'
    foreach ($g in $gates) {
        if ($g.File -cne $rel) { continue }
        if ($g.Kind -cne 'hard') { continue }
        $count = $count + 1
        if ($g.Label.Length -gt 0) { [void]$labels.Add([int]$g.Label) }
    }

    $declHard = 0
    $declCond = @()
    if ($gateFiles.Contains($rel)) {
        $declHard = $gateHard[$rel]
        $declCond = $gateCond[$rel]
    }
    if ($count -ne $declHard) {
        Add-Finding 'CL302' $rel 1 "hard gate count is $count on disk, manifest declares $declHard"
    }

    # CL303 is SET-based, never file order: commands/bug.md authors
    # '### Gate 3a' before '### Gate 3' and must still pass.
    if ($labels.Count -gt 0) {
        $sorted = @($labels | Sort-Object)
        $bad = $false
        $seen = New-OrdinalSet
        foreach ($v in $sorted) {
            if (-not $seen.Add([string]$v)) { $bad = $true }
        }
        $want = 1
        foreach ($v in $sorted) {
            if ($v -ne $want) { $bad = $true; break }
            $want = $want + 1
        }
        if ($bad) {
            Add-Finding 'CL303' $rel 1 "hard gate numbering is not 1..$($labels.Count) without duplicates"
        }
    }

    # CL304 - symmetric set difference, both directions BLOCK. The
    # declared-but-absent half is the anti-rot direction.
    $onDisk = New-OrdinalSet
    $declSet = New-OrdinalSet
    foreach ($c in $declCond) { [void]$declSet.Add($c) }
    foreach ($g in $gates) {
        if ($g.File -cne $rel) { continue }
        if ($g.Kind -cne 'conditional') { continue }
        [void]$onDisk.Add($g.Label)
        if (-not $declSet.Contains($g.Label)) {
            Add-Finding 'CL304' $rel $g.Line "conditional gate '$($g.Label)' is not declared in the manifest"
        }
    }
    foreach ($c in $declCond) {
        if (-not $onDisk.Contains($c)) {
            Add-Finding 'CL304' $rel 1 "manifest declares conditional gate '$c' but it is absent from disk"
        }
    }
}

# ---- Phase C: suppressions, sort, emit -------------------------------------
#
# A suppression can never suppress CL900, CL901 or CL902 - otherwise
# '<!-- contract-lint: allow CL900 -->' would be a self-authorizing loophole.
# That exclusion is hardcoded, never manifest-driven.

$kept = New-Object 'System.Collections.Generic.List[object]'
foreach ($f in $findings) {
    $hit = $false
    if ($f.Rule -cne 'CL900' -and $f.Rule -cne 'CL901' -and $f.Rule -cne 'CL902') {
        foreach ($s in $suppressions) {
            if ($s.Bad) { continue }
            if ($s.File -cne $f.File) { continue }
            if ($s.Rule -cne $f.Rule) { continue }
            if ($s.Line -eq $f.Line -or $s.Line -eq ($f.Line - 1)) {
                $s.Used = $true
                $hit = $true
                break
            }
        }
    }
    if (-not $hit) { [void]$kept.Add($f) }
}
$findings = $kept

# CL902 runs LAST, over the used flags. A CL901-flagged suppression is exempt -
# one error per broken suppression, never two.
foreach ($s in $suppressions) {
    if ($s.Bad) { continue }
    if ($s.Used) { continue }
    Add-Finding 'CL902' $s.File $s.Line "suppression for $($s.Rule) suppressed nothing"
}

$blocks = 0
$warns = 0
$rows = New-Object 'System.Collections.Generic.List[string]'
foreach ($f in $findings) {
    if ($ruleFilter.Count -gt 0 -and -not $ruleFilter.Contains($f.Rule)) { continue }
    $sev = 'BLOCK'
    if ($ruleSeverity.ContainsKey($f.Rule)) { $sev = $ruleSeverity[$f.Rule] }
    if ($sev -ceq 'BLOCK') { $blocks = $blocks + 1 } else { $warns = $warns + 1 }
    # Sort key: file, then zero-padded line so lexical order IS numeric order,
    # then rule id, then message. The twin builds the identical key and sorts it
    # byte-wise, which is what makes the two outputs comparable line for line.
    $key = '{0}{1}{2:D9}{1}{3}{1}{4}' -f $f.File, [char]1, $f.Line, $f.Rule, $f.Message
    $row = '{0}{1}{2}{1}{3}{1}{4}{1}{5}' -f $f.Rule, [char]9, $sev, $f.File, $f.Line, $f.Message
    [void]$rows.Add(($key + [char]9 + $row))
}
$rows.Sort([StringComparer]::Ordinal)

foreach ($r in $rows) {
    # Write-Output, never [Console]::Out.WriteLine: the latter writes straight to
    # the console handle and silently bypasses PowerShell's '>' redirection, so
    # the parity capture in run-selftest.ps1 would collect an empty file while
    # the findings scrolled past on screen.
    $tab = $r.IndexOf([char]9)
    Write-Output $r.Substring($tab + 1)
}

if (-not $Quiet) {
    Write-Err "contract-lint: $blocks block, $warns warn (root: $Root)"
}

if ($blocks -gt 0) { exit 1 }
exit 0
