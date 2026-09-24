#requires -Version 5.1
<#
.SYNOPSIS
    Repo invariant validator for specwright (Windows / PowerShell).

.DESCRIPTION
    Runs every documented engine invariant as a single command:
      1. Pure-ASCII scan of all *.ps1 files (this file included).
      2. bash -n syntax check on hooks/bash/*.sh, install/*.sh, scripts/*.sh.
      3. Hook-pair parity: every hooks/powershell/X.ps1 has a hooks/bash/X.sh
         and vice-versa.
      4. Model-alias-only: agent frontmatter model: in {sonnet,haiku,opus,inherit}.
      5. Install-target count: a real install to a temp base lands the expected
         file counts under each <area>/sd/ subfolder.
      6. CHANGELOG gate: the [Unreleased] section is non-empty.
      7. Docs consistency: published numbers in the docs match disk, per
         specwright.manifest.json.
      8. Cross-file contract lint: the relationships between commands, agents
         and skills, per specwright.manifest.json's contractLint subtree.
         Delegated to scripts/contract-lint.ps1 as a child process.
      9. Root-level ad-hoc notes guard: no root-level file matches a declared
         ad-hoc-notes pattern (specwright.manifest.json's adHocNotesGuard),
         e.g. REVIEW-TODO.md, TODO.md, FIXME.md, NOTES.md, *-FINDINGS.md.
     10. Bash strict mode: every *.sh in the repo opens with
         `set -euo pipefail` unless declared in specwright.manifest.json's
         bashStrictMode.exceptions.

    Exit code 0 = all checks passed; 1 = at least one check failed.

    PURE ASCII. This file is scanned by check 1, so it must contain no byte
    above 0x7F (no em-dash, arrows, or box-drawing characters).

.EXAMPLE
    .\scripts\validate.ps1
#>

param()

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$repoRoot  = Split-Path -Parent $scriptDir

# ---- expected install-target counts ----------------------------------------
# Counts are derived from the source tree, not hardcoded - a new command/agent/skill/template
# only needs to land in its source dir, never a constant bumped in two scripts. Each count is
# asserted > 0 below so an empty/misnamed source dir fails loudly instead of vacuously passing.
# One platform's hooks land per install (PowerShell hooks here), so this counts
# hooks/powershell/*.ps1 only; Check 3 (hook-pair parity) already asserts the bash count matches.
$ExpectedCommands  = (Get-ChildItem (Join-Path $repoRoot 'commands') -Filter *.md -File).Count
$ExpectedAgents    = (Get-ChildItem (Join-Path $repoRoot 'agents') -Filter *.md -File).Count
$ExpectedSkills    = (Get-ChildItem (Join-Path $repoRoot 'skills') -Filter 'SKILL.md' -File -Recurse).Count
$ExpectedHooks     = (Get-ChildItem (Join-Path $repoRoot 'hooks\powershell') -Filter *.ps1 -File).Count
$ExpectedTemplates = (Get-ChildItem (Join-Path $repoRoot 'templates') -File -Recurse).Count

# The version stamp has no source-tree counterpart - it is generated at install time from
# CHANGELOG.md, never copied from a source dir - so unlike the counts above it cannot be
# derived from a glob. This is the one hand-written constant Check 5 uses: how many stamp
# files land per installed area.
$StampFilesPerArea = 1

foreach ($pair in @(
    @{ Name = 'commands';  Count = $ExpectedCommands },
    @{ Name = 'agents';    Count = $ExpectedAgents },
    @{ Name = 'skills';    Count = $ExpectedSkills },
    @{ Name = 'hooks';     Count = $ExpectedHooks },
    @{ Name = 'templates'; Count = $ExpectedTemplates }
)) {
    if ($pair.Count -eq 0) {
        Write-Host "FATAL: derived expected count for $($pair.Name) is 0 - source dir empty or missing?" -ForegroundColor Red
        exit 1
    }
}

$ModelAliases = @('sonnet', 'haiku', 'opus', 'inherit')

# ---- output helpers ---------------------------------------------------------

function Write-Section { param([string]$Title) Write-Host ''; Write-Host "=== $Title ===" -ForegroundColor Cyan }
function Write-Ok      { param([string]$m) Write-Host "  [OK]   $m" -ForegroundColor Green }
function Write-FailMsg { param([string]$m) Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Write-WarnMsg { param([string]$m) Write-Host "  [WARN] $m" -ForegroundColor Yellow }

$script:Failures = New-Object System.Collections.Generic.List[string]
function Add-Failure { param([string]$m) $script:Failures.Add($m) }

function Get-RelPath { param([string]$Path) $Path.Substring($repoRoot.Length).TrimStart('\', '/') }

# Returns the 1-based line number of the first non-ASCII byte, or 0 if clean.
function Get-FirstNonAsciiLine {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $line = 1
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $b = $bytes[$i]
        if ($b -eq 10) { $line++ }
        if ($b -gt 127) { return $line }
    }
    return 0
}

# Locate a usable bash. On Windows the bare 'bash' on PATH is often the WSL
# launcher, which fails when no distro is installed and mistranslates Windows
# paths; prefer Git for Windows' bash, which handles C:/... paths natively.
# Returns the path to the first bash that passes a smoke test, or $null.
function Find-WorkingBash {
    $candidates = New-Object System.Collections.Generic.List[string]
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $gitRoot = Split-Path -Parent (Split-Path -Parent $git.Source)
        $candidates.Add((Join-Path $gitRoot 'bin\bash.exe'))
        $candidates.Add((Join-Path $gitRoot 'usr\bin\bash.exe'))
    }
    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)}, "$env:LOCALAPPDATA\Programs")) {
        if ($pf) {
            $candidates.Add((Join-Path $pf 'Git\bin\bash.exe'))
            $candidates.Add((Join-Path $pf 'Git\usr\bin\bash.exe'))
        }
    }
    foreach ($c in (Get-Command bash -All -ErrorAction SilentlyContinue)) {
        $candidates.Add($c.Source)
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            try {
                & $c -c 'exit 0' 2>$null
                if ($LASTEXITCODE -eq 0) { return $c }
            } catch { }
        }
    }
    return $null
}

# Counts files under Dir and compares against Expected, reporting through the same
# Write-Ok / Write-FailMsg / Add-Failure vocabulary as every other check. Reused by
# Check 5 for both the fresh install and the idempotent re-run, so both runs are
# asserted through one code path rather than two hand-copied loops.
function Test-AreaCount {
    param([string]$Name, [string]$Dir, [int]$Expected)
    $cnt = 0
    if (Test-Path -LiteralPath $Dir) {
        $cnt = (Get-ChildItem -LiteralPath $Dir -Recurse -File).Count
    }
    if ($cnt -eq $Expected) {
        Write-Ok "$Name/sd : $cnt file(s)"
    } else {
        Write-FailMsg "$Name/sd : expected $Expected, found $cnt"
        Add-Failure "install: $Name/sd expected $Expected found $cnt"
    }
}

Write-Section 'specwright validate'
Write-Host "  Repo root: $repoRoot"

# ---- Check 1: pure-ASCII scan ----------------------------------------------

Write-Section 'Check 1/10: Pure-ASCII scan (*.ps1)'
$ps1Files = Get-ChildItem -Path $repoRoot -Recurse -Filter *.ps1 -File |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }
$asciiBad = 0
foreach ($f in $ps1Files) {
    $line = Get-FirstNonAsciiLine -Path $f.FullName
    if ($line -gt 0) {
        $rel = Get-RelPath $f.FullName
        Write-FailMsg "$rel : non-ASCII byte at line $line"
        Add-Failure "ASCII: $rel (line $line)"
        $asciiBad++
    }
}
if ($asciiBad -eq 0) { Write-Ok "$($ps1Files.Count) .ps1 file(s) are pure ASCII" }

# ---- Check 2: bash -n syntax -----------------------------------------------

Write-Section 'Check 2/10: bash -n syntax (*.sh)'
$shFiles = @()
foreach ($sub in @('hooks\bash', 'install', 'scripts')) {
    $dir = Join-Path $repoRoot $sub
    if (Test-Path -LiteralPath $dir) {
        $shFiles += Get-ChildItem -Path $dir -Filter *.sh -File
    }
}
$bashExe = Find-WorkingBash
if ($null -eq $bashExe) {
    Write-WarnMsg 'No working bash found; skipping syntax check (CI runs this on Ubuntu).'
} else {
    $synBad = 0
    foreach ($f in $shFiles) {
        $p = $f.FullName -replace '\\', '/'
        $out = & $bashExe -n $p 2>&1
        if ($LASTEXITCODE -ne 0) {
            $rel = Get-RelPath $f.FullName
            Write-FailMsg "$rel : $out"
            Add-Failure "bash -n: $rel"
            $synBad++
        }
    }
    if ($synBad -eq 0) { Write-Ok "$($shFiles.Count) .sh file(s) pass bash -n" }
}

# ---- Check 3: hook-pair parity ---------------------------------------------

Write-Section 'Check 3/10: Hook-pair parity'
$psHooks = Get-ChildItem (Join-Path $repoRoot 'hooks\powershell') -Filter *.ps1 -File |
    ForEach-Object { $_.BaseName }
$shHooks = Get-ChildItem (Join-Path $repoRoot 'hooks\bash') -Filter *.sh -File |
    ForEach-Object { $_.BaseName }
$parityBad = 0
foreach ($h in $psHooks) {
    if ($shHooks -notcontains $h) {
        Write-FailMsg "hooks/powershell/$h.ps1 has no hooks/bash/$h.sh"
        Add-Failure "parity: missing bash twin for $h"
        $parityBad++
    }
}
foreach ($h in $shHooks) {
    if ($psHooks -notcontains $h) {
        Write-FailMsg "hooks/bash/$h.sh has no hooks/powershell/$h.ps1"
        Add-Failure "parity: missing PowerShell twin for $h"
        $parityBad++
    }
}
if ($parityBad -eq 0) { Write-Ok "$($psHooks.Count) hook pair(s) present on both platforms" }

# ---- Check 4: agent model aliases ------------------------------------------

Write-Section 'Check 4/10: Agent model aliases'
$agentFiles = Get-ChildItem (Join-Path $repoRoot 'agents') -Filter *.md -File
$modelBad = 0
foreach ($f in $agentFiles) {
    $rel = Get-RelPath $f.FullName
    $match = Select-String -Path $f.FullName -Pattern '^model:\s*(.+?)\s*$' | Select-Object -First 1
    if ($null -eq $match) {
        Write-FailMsg "$rel : no model: field"
        Add-Failure "model: $rel missing model field"
        $modelBad++
        continue
    }
    $val = ($match.Matches[0].Groups[1].Value -replace '\s*#.*$', '').Trim()
    if ($ModelAliases -notcontains $val) {
        Write-FailMsg "$rel : model '$val' is not an alias ($($ModelAliases -join ', '))"
        Add-Failure "model: $rel = $val"
        $modelBad++
    }
}
if ($modelBad -eq 0) { Write-Ok "$($agentFiles.Count) agent(s) use a model alias" }

# ---- Check 5: install-target counts ----------------------------------------

Write-Section 'Check 5/10: Install-target counts'
$installPs1 = Join-Path $repoRoot 'install\install.ps1'
$tmp = Join-Path $env:TEMP "sd-validate-$PID"
$tmpNc = Join-Path $env:TEMP "sd-validate-nc-$PID"
$tmpNcBase = Join-Path $env:TEMP "sd-validate-nc-base-$PID"
$psExe = (Get-Process -Id $PID).Path
try {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -Recurse -Force $tmp }
    if (Test-Path -LiteralPath $tmpNc) { Remove-Item -Recurse -Force $tmpNc }
    if (Test-Path -LiteralPath $tmpNcBase) { Remove-Item -Recurse -Force $tmpNcBase }
    if ($env:OS -eq 'Windows_NT') {
        $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $installPs1, '-BasePath', $tmp, '-Force')
    } else {
        $childArgs = @('-NoProfile', '-File', $installPs1, '-BasePath', $tmp, '-Force')
    }
    & $psExe @childArgs *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-FailMsg "installer exited with code $LASTEXITCODE"
        Add-Failure "install: installer exit $LASTEXITCODE"
    } else {
        $targets = @(
            [pscustomobject]@{ Name = 'commands';  Path = 'commands\sd';  Expected = $ExpectedCommands  + $StampFilesPerArea },
            [pscustomobject]@{ Name = 'agents';    Path = 'agents\sd';    Expected = $ExpectedAgents    + $StampFilesPerArea },
            [pscustomobject]@{ Name = 'skills';    Path = 'skills\sd';    Expected = $ExpectedSkills    + $StampFilesPerArea },
            [pscustomobject]@{ Name = 'hooks';     Path = 'hooks\sd';     Expected = $ExpectedHooks     + $StampFilesPerArea },
            [pscustomobject]@{ Name = 'templates'; Path = 'templates\sd'; Expected = $ExpectedTemplates + $StampFilesPerArea }
        )
        foreach ($t in $targets) {
            Test-AreaCount -Name $t.Name -Dir (Join-Path $tmp $t.Path) -Expected $t.Expected
        }

        # ---- stamp content: every area's stamp equals the CHANGELOG-derived version ----
        $stampChangelog = Join-Path $repoRoot 'CHANGELOG.md'
        $stampVersion = $null
        foreach ($line in (Get-Content -LiteralPath $stampChangelog)) {
            $m = [regex]::Match($line, '^##\s+\[([0-9]+\.[0-9]+\.[0-9]+)\]\s+-\s+\S')
            if ($m.Success) { $stampVersion = $m.Groups[1].Value; break }
        }
        if ([string]::IsNullOrEmpty($stampVersion)) {
            Write-FailMsg 'CHANGELOG.md : no dated release heading found (## [x.y.z] - <date>)'
            Add-Failure 'install: stamp version source unreadable'
        } else {
            $stampBad = 0
            foreach ($t in $targets) {
                $stampPath = Join-Path (Join-Path $tmp $t.Path) 'specwright-version.txt'
                if (-not (Test-Path -LiteralPath $stampPath -PathType Leaf)) {
                    Write-FailMsg "$($t.Name)/sd/specwright-version.txt : not found"
                    Add-Failure "install: $($t.Name)/sd stamp missing"
                    $stampBad++
                    continue
                }
                # Tolerate a stray trailing CR on read - the byte contract itself is
                # asserted below on one stamp; this comparison only cares about content.
                $stampContent = (Get-Content -LiteralPath $stampPath -Raw) -replace '[\r\n]+$', ''
                if ($stampContent -ne $stampVersion) {
                    Write-FailMsg "$($t.Name)/sd/specwright-version.txt : content '$stampContent' != CHANGELOG version '$stampVersion'"
                    Add-Failure "install: $($t.Name)/sd stamp content mismatch"
                    $stampBad++
                }
            }
            if ($stampBad -eq 0) { Write-Ok "5 stamp(s) match CHANGELOG version $stampVersion" }

            # Byte-level contract on one stamp (commands): no BOM, no CR, exactly one trailing LF.
            $byteStampPath = Join-Path (Join-Path $tmp 'commands\sd') 'specwright-version.txt'
            if (Test-Path -LiteralPath $byteStampPath -PathType Leaf) {
                $stampBytes = [System.IO.File]::ReadAllBytes($byteStampPath)
                $hasBom = ($stampBytes.Length -ge 3) -and ($stampBytes[0] -eq 0xEF) -and ($stampBytes[1] -eq 0xBB) -and ($stampBytes[2] -eq 0xBF)
                $hasCr = $stampBytes -contains 0x0D
                $endsWithLf = ($stampBytes.Length -gt 0) -and ($stampBytes[$stampBytes.Length - 1] -eq 0x0A)
                $doubleLf = ($stampBytes.Length -gt 1) -and ($stampBytes[$stampBytes.Length - 2] -eq 0x0A)
                if ($hasBom -or $hasCr -or (-not $endsWithLf) -or $doubleLf) {
                    Write-FailMsg "commands/sd/specwright-version.txt : byte contract violated (BOM=$hasBom CR=$hasCr trailingLF=$endsWithLf doubleLF=$doubleLf)"
                    Add-Failure 'install: commands/sd stamp byte contract'
                } else {
                    Write-Ok 'commands/sd/specwright-version.txt : LF, no BOM, no CR, single trailing newline'
                }
            }
        }

        # ---- idempotent re-run: second -Force pass must be a no-op for the stamp ----
        & $psExe @childArgs *> $null
        if ($LASTEXITCODE -ne 0) {
            Write-FailMsg "second installer run exited with code $LASTEXITCODE"
            Add-Failure "install: second installer run exit $LASTEXITCODE"
        } else {
            $bakFiles = @(Get-ChildItem -LiteralPath $tmp -Recurse -File -Filter '*.bak.*' -ErrorAction SilentlyContinue)
            if ($bakFiles.Count -gt 0) {
                Write-FailMsg "second install run created $($bakFiles.Count) *.bak.* file(s) - stamp is not idempotent"
                Add-Failure 'install: second run produced .bak files'
            } else {
                Write-Ok 'second -Force run created zero *.bak.* file(s)'
            }
            foreach ($t in $targets) {
                Test-AreaCount -Name $t.Name -Dir (Join-Path $tmp $t.Path) -Expected $t.Expected
            }
        }
    }

    # ---- negative case: missing version source fails loudly, copies nothing ----
    # The required-source-directory list is mirrored FROM install.ps1's own
    # $requiredDirs block, not hand-duplicated here, so a future added requirement
    # fails this scenario visibly instead of silently changing what it proves.
    $reqDirsFromInstaller = New-Object System.Collections.Generic.List[string]
    $inReqBlock = $false
    foreach ($line in (Get-Content -LiteralPath $installPs1)) {
        if ($line -match '^\$requiredDirs\s*=\s*@\(') { $inReqBlock = $true; continue }
        if ($inReqBlock) {
            if ($line -match '^\)') { break }
            $m = [regex]::Match($line, "Path\s*=\s*'([^']+)'")
            if ($m.Success) { $reqDirsFromInstaller.Add($m.Groups[1].Value) }
        }
    }
    if ($reqDirsFromInstaller.Count -eq 0) {
        Write-FailMsg 'install.ps1 : could not parse $requiredDirs - missing-CHANGELOG scenario skipped'
        Add-Failure 'install: could not parse install.ps1 required dirs'
    } else {
        New-Item -ItemType Directory -Path (Join-Path $tmpNc 'install') -Force | Out-Null
        Copy-Item -LiteralPath $installPs1 -Destination (Join-Path $tmpNc 'install\install.ps1') -Force
        foreach ($d in $reqDirsFromInstaller) {
            New-Item -ItemType Directory -Path (Join-Path $tmpNc $d) -Force | Out-Null
        }
        $ncInstallPs1 = Join-Path $tmpNc 'install\install.ps1'
        if ($env:OS -eq 'Windows_NT') {
            $ncArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ncInstallPs1, '-BasePath', $tmpNcBase, '-Force')
        } else {
            $ncArgs = @('-NoProfile', '-File', $ncInstallPs1, '-BasePath', $tmpNcBase, '-Force')
        }
        $ncOut = & $psExe @ncArgs 2>&1 | Out-String
        $ncExit = $LASTEXITCODE
        $ncBad = 0
        if ($ncExit -eq 0) {
            Write-FailMsg 'missing-CHANGELOG scenario: installer exited 0, expected non-zero'
            Add-Failure 'install: missing-changelog scenario did not fail'
            $ncBad++
        }
        if ($ncOut -notmatch 'CHANGELOG\.md') {
            Write-FailMsg 'missing-CHANGELOG scenario: installer output did not mention CHANGELOG.md'
            Add-Failure 'install: missing-changelog scenario message missing CHANGELOG.md'
            $ncBad++
        }
        $ncFileCount = 0
        if (Test-Path -LiteralPath $tmpNcBase) {
            $ncFileCount = (Get-ChildItem -LiteralPath $tmpNcBase -Recurse -File -Force -ErrorAction SilentlyContinue).Count
        }
        if ($ncFileCount -ne 0) {
            Write-FailMsg "missing-CHANGELOG scenario: base contains $ncFileCount file(s), expected 0"
            Add-Failure 'install: missing-changelog scenario copied files'
            $ncBad++
        }
        if ($ncBad -eq 0) {
            Write-Ok 'missing-CHANGELOG.md scenario: installer failed loudly and copied nothing'
        }
    }
} finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $tmpNc) { Remove-Item -Recurse -Force $tmpNc -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $tmpNcBase) { Remove-Item -Recurse -Force $tmpNcBase -ErrorAction SilentlyContinue }
}

# ---- Check 6: CHANGELOG [Unreleased] non-empty -----------------------------

Write-Section 'Check 6/10: CHANGELOG [Unreleased] gate'
$changelog = Join-Path $repoRoot 'CHANGELOG.md'
$lines = Get-Content -LiteralPath $changelog
$start = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^##\s+\[Unreleased\]') { $start = $i; break }
}
if ($start -lt 0) {
    Write-FailMsg 'no ## [Unreleased] section found'
    Add-Failure 'changelog: no [Unreleased] header'
} else {
    $hasEntry = $false
    $nextHeader = $null
    for ($i = $start + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^##\s+\[') { $nextHeader = $lines[$i]; break }
        if ($lines[$i] -match '^\s*-\s+\S') { $hasEntry = $true; break }
    }
    # An empty [Unreleased] passes only immediately after a release: the next
    # section must be a dated [x.y.z] - <date> heading (the freshly cut
    # version). Otherwise every PR must add an entry under [Unreleased].
    $justReleased = ($null -ne $nextHeader) -and ($nextHeader -match '^##\s+\[\d+\.\d+\.\d+\]\s+-\s+\S')
    if ($hasEntry) {
        Write-Ok '[Unreleased] has at least one entry'
    } elseif ($justReleased) {
        Write-Ok '[Unreleased] empty but sits directly above a dated release (just cut)'
    } else {
        Write-FailMsg '[Unreleased] section is empty (add a changelog entry)'
        Add-Failure 'changelog: [Unreleased] empty'
    }
}

# ---- Check 7: docs consistency ---------------------------------------------

Write-Section 'Check 7/10: Docs consistency (published numbers vs disk)'
$manifestPath = Join-Path $repoRoot 'specwright.manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-FailMsg 'specwright.manifest.json not found at repo root'
    Add-Failure 'docs: manifest missing'
} else {
    $docsBad = 0
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $quantities = @{}
    $filePatterns = @{}

    # Area counts are derived from disk, never stored in the manifest.
    foreach ($areaProp in $manifest.areas.PSObject.Properties) {
        $areaName = $areaProp.Name
        $area = $areaProp.Value
        $areaCount = 0
        if ($area.glob) {
            $globPath = Join-Path $repoRoot ($area.glob -replace '/', '\')
            $areaCount = @(Get-ChildItem -Path $globPath -File -ErrorAction SilentlyContinue).Count
        } else {
            foreach ($relFile in $area.files) {
                $full = Join-Path $repoRoot ($relFile -replace '/', '\')
                if (Test-Path -LiteralPath $full -PathType Leaf) {
                    $areaCount++
                } else {
                    Write-FailMsg "area '$areaName' lists a file that does not exist: $relFile"
                    Add-Failure "docs: area $areaName missing $relFile"
                    $docsBad++
                }
            }
        }
        if ($areaCount -eq 0) {
            Write-FailMsg "area '$areaName' matched 0 files"
            Add-Failure "docs: area $areaName derived 0"
            $docsBad++
        }
        $quantities[$areaName] = $areaCount
    }

    # Stamp count is a THIRD kind of quantity here: not read from a source-tree glob (there
    # is no stamp source dir) but derived from areas.*.installTo - one stamp lands in each
    # distinct '<area>/sd/' root the installer writes to. Seeded here, before the derived
    # loop, so derived.installTotalWithStamps can reference it without depending on JSON key
    # order, and it self-corrects if an area is added or removed.
    $installRoots = @()
    foreach ($areaProp in $manifest.areas.PSObject.Properties) {
        $installTo = $areaProp.Value.installTo
        if ([string]::IsNullOrEmpty($installTo)) { continue }
        $segments = @($installTo -split '/' | Where-Object { $_ -ne '' })
        if ($segments.Count -lt 2) { continue }
        $root = "$($segments[0])/$($segments[1])"
        if ($installRoots -notcontains $root) { $installRoots += $root }
    }
    $quantities['installStamps'] = $installRoots.Count

    foreach ($derProp in $manifest.derived.PSObject.Properties) {
        $derTotal = 0
        foreach ($part in $derProp.Value) {
            if ($quantities.ContainsKey($part)) { $derTotal += [int]$quantities[$part] }
        }
        $quantities[$derProp.Name] = $derTotal
    }

    # Gate quantities are DECLARED, not derived: nothing on disk is a second
    # source for "how many hard gates /sd:feature has". Seeding them here gives
    # the topology README <- manifest (this check) and manifest <- disk (Check
    # 8's CL302), hence transitively README == disk, with zero duplication of the
    # gate parser into this file. A null quantity means the gate block is real
    # but no doc publishes a number for it.
    if ($null -ne $manifest.contractLint -and $null -ne $manifest.contractLint.gates) {
        foreach ($gateProp in $manifest.contractLint.gates.PSObject.Properties) {
            $qName = $gateProp.Value.quantity
            if ([string]::IsNullOrEmpty($qName)) { continue }
            $quantities[$qName] = [int]$gateProp.Value.hard
        }
    }

    foreach ($claim in $manifest.docClaims) {
        if (-not $filePatterns.ContainsKey($claim.file)) {
            $filePatterns[$claim.file] = New-Object System.Collections.Generic.List[string]
        }
        $filePatterns[$claim.file].Add($claim.pattern)

        $target = Join-Path $repoRoot ($claim.file -replace '/', '\')
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            Write-FailMsg "$($claim.file) : declared claim file does not exist"
            Add-Failure "docs: missing claim file $($claim.file)"
            $docsBad++
            continue
        }
        if (-not $quantities.ContainsKey($claim.equals)) {
            Write-FailMsg "$($claim.file) : claim references unknown quantity '$($claim.equals)'"
            Add-Failure "docs: unknown quantity $($claim.equals)"
            $docsBad++
            continue
        }
        $expected = "$($quantities[$claim.equals])"

        $hits = 0
        $lineNo = 0
        foreach ($line in (Get-Content -LiteralPath $target)) {
            $lineNo++
            # [regex] rather than -match: PowerShell's -match is case-insensitive by
            # default, which would silently diverge from the bash twin's [[ =~ ]].
            $m = [regex]::Match($line, $claim.pattern)
            if ($m.Success) {
                $hits++
                $found = $m.Groups[1].Value
                if ($found -ne $expected) {
                    Write-FailMsg "$($claim.file):$lineNo : says $found, disk has $expected ($($claim.equals))"
                    Add-Failure "docs: $($claim.file):$lineNo $($claim.equals) says $found not $expected"
                    $docsBad++
                }
            }
        }

        # A pattern that matches nothing is a rotted regex, not a pass - without this
        # a reworded doc sentence silently turns the claim into a no-op.
        if ($hits -eq 0) {
            Write-FailMsg "$($claim.file) : pattern matched no lines (reworded?): $($claim.pattern)"
            Add-Failure "docs: vacuous claim in $($claim.file) ($($claim.equals))"
            $docsBad++
        }
    }

    # ---- Version claims: published version vs newest dated CHANGELOG heading ---
    # Independent of Check 6's $nextHeader - that variable stays $null in the normal
    # non-just-released state, since [Unreleased] currently has bullets right after its
    # header and the Check 6 loop breaks on the bullet before ever hitting a '## [' line.
    # Scan the whole file for the first dated release heading instead.
    $releasedVersion = $null
    foreach ($line in (Get-Content -LiteralPath $changelog)) {
        $m = [regex]::Match($line, '^##\s+\[([0-9]+\.[0-9]+\.[0-9]+)\]\s+-\s+\S')
        if ($m.Success) { $releasedVersion = $m.Groups[1].Value; break }
    }
    if ([string]::IsNullOrEmpty($releasedVersion)) {
        Write-FailMsg 'CHANGELOG.md : no dated release heading found (## [x.y.z] - <date>)'
        Add-Failure 'docs: no dated release heading in CHANGELOG.md'
        $docsBad++
    }

    foreach ($claim in @($manifest.versionClaims)) {
        $target = Join-Path $repoRoot ($claim.file -replace '/', '\')
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            Write-FailMsg "$($claim.file) : declared version-claim file does not exist"
            Add-Failure "docs: missing version-claim file $($claim.file)"
            $docsBad++
            continue
        }
        if ([string]::IsNullOrEmpty($releasedVersion)) { continue }

        $hits = 0
        $lineNo = 0
        foreach ($line in (Get-Content -LiteralPath $target)) {
            $lineNo++
            $m = [regex]::Match($line, $claim.pattern)
            if ($m.Success) {
                $hits++
                $found = $m.Groups[1].Value
                if ($found -ne $releasedVersion) {
                    Write-FailMsg "$($claim.file):$lineNo : says $found, CHANGELOG has $releasedVersion"
                    Add-Failure "docs: $($claim.file):$lineNo version says $found not $releasedVersion"
                    $docsBad++
                }
            }
        }

        # A pattern that matches nothing is a rotted regex, not a pass - same rationale
        # as the docClaims vacuous-claim check above.
        if ($hits -eq 0) {
            Write-FailMsg "$($claim.file) : version pattern matched no lines (reworded?): $($claim.pattern)"
            Add-Failure "docs: vacuous version claim in $($claim.file)"
            $docsBad++
        }
    }

    # Undeclared-claim scan: any line that looks like an inventory claim but is not
    # covered by a docClaims entry. This is what keeps the manifest canonical - a new
    # doc cannot publish a number that nothing checks.
    $phrasesRe = ($manifest.claimPhrases) -join '|'
    $mdFiles = Get-ChildItem -Path $repoRoot -Recurse -Filter *.md -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }
    foreach ($f in $mdFiles) {
        $rel = (Get-RelPath $f.FullName) -replace '\\', '/'
        $skip = $false
        foreach ($ex in $manifest.historicalExclusions) {
            if ($rel.StartsWith($ex)) { $skip = $true; break }
        }
        if ($skip) { continue }

        $lineNo = 0
        foreach ($line in (Get-Content -LiteralPath $f.FullName)) {
            $lineNo++
            if (-not [regex]::IsMatch($line, $phrasesRe)) { continue }
            $covered = $false
            if ($filePatterns.ContainsKey($rel)) {
                foreach ($pat in $filePatterns[$rel]) {
                    if ([regex]::IsMatch($line, $pat)) { $covered = $true; break }
                }
            }
            if (-not $covered) {
                Write-FailMsg "${rel}:$lineNo : undeclared inventory claim (add a docClaims entry or an exclusion)"
                Add-Failure "docs: undeclared claim ${rel}:$lineNo"
                $docsBad++
            }
        }
    }

    if ($docsBad -eq 0) {
        $versionClaimCount = @($manifest.versionClaims).Count
        Write-Ok "$($manifest.docClaims.Count) published claim(s) + $versionClaimCount version claim(s) match disk/CHANGELOG; no undeclared claims"
    }
}

# ---- Check 8: cross-file contract lint --------------------------------------

Write-Section 'Check 8/10: Cross-file contract lint (commands / agents / skills)'
$lintPs1 = Join-Path $scriptDir 'contract-lint.ps1'
if (-not (Test-Path -LiteralPath $lintPs1 -PathType Leaf)) {
    Write-FailMsg 'scripts/contract-lint.ps1 not found'
    Add-Failure 'contract-lint: script missing'
} else {
    # Spawned as a CHILD PROCESS, never with '&': contract-lint.ps1 calls exit,
    # and an inline '&' would terminate validate.ps1 outright - leaving a green
    # Check 7 line already printed and no summary at all. Same pattern as the
    # installer invocation in Check 5.
    $lintArgs = @('-NoProfile')
    if ($env:OS -eq 'Windows_NT') { $lintArgs += @('-ExecutionPolicy', 'Bypass') }
    $lintArgs += @('-File', $lintPs1, '-Root', $repoRoot, '-Quiet')
    $lintOut = & $psExe @lintArgs 2>$null
    $lintExit = $LASTEXITCODE

    # The linter is a dumb TSV emitter; all human formatting happens here, so
    # both twins stay identical and neither learns about colours or [OK] tags.
    $clBlocks = 0
    $clWarns = 0
    $clWarnsBudgeted = 0
    foreach ($row in @($lintOut)) {
        if ([string]::IsNullOrWhiteSpace($row)) { continue }
        $parts = $row.Split([char]9)
        if ($parts.Count -lt 5) { continue }
        $text = "$($parts[2]):$($parts[3]) $($parts[0]) - $($parts[4])"
        if ($parts[1] -ceq 'BLOCK') {
            Write-FailMsg $text
            Add-Failure "contract-lint: $($parts[0]) $($parts[2]):$($parts[3])"
            $clBlocks++
        } else {
            Write-WarnMsg $text
            $clWarns++
            # CL500/CL202 are permanent-WARN ratchets by design (byte
            # budgets, unrecognized MCP tool names) - never counted against
            # the standing-warning budget below, or a legitimate CL500 bump
            # would fail the build through a rule explicitly meant not to.
            if ($parts[0] -cne 'CL500' -and $parts[0] -cne 'CL202') { $clWarnsBudgeted++ }
        }
    }
    if ($lintExit -ge 2) {
        # Exit 2 means the linter could not run at all. Treating that as a pass
        # is the failure mode this whole check exists to prevent.
        Write-FailMsg "contract-lint could not run (exit $lintExit)"
        Add-Failure "contract-lint: exit $lintExit"
    } else {
        # Ratchet, not a ceiling: contractLint.warnBudget is the max standing
        # WARN count (excluding CL500/CL202). Lowering it below actual requires
        # lowering it in the SAME commit that resolves the warnings - never
        # raise it to make a new warning pass quietly.
        $warnBudget = 0
        try {
            $budgetManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
            if ($null -ne $budgetManifest.contractLint.warnBudget) {
                $warnBudget = [int]$budgetManifest.contractLint.warnBudget
            }
        } catch {}
        if ($clBlocks -eq 0 -and $clWarnsBudgeted -le $warnBudget) {
            if ($clWarns -eq 0) {
                Write-Ok 'no contract violations'
            } else {
                Write-Ok "no BLOCK violations ($clWarns warning(s) above, $clWarnsBudgeted/$warnBudget standing-warning budget)"
            }
        } elseif ($clBlocks -eq 0) {
            Write-FailMsg "standing-warning budget exceeded: $clWarnsBudgeted budgeted warning(s) > contractLint.warnBudget ($warnBudget)"
            Add-Failure "contract-lint: warn budget $clWarnsBudgeted > $warnBudget"
        }
    }
}

# ---- Check 9: root-level ad-hoc notes guard ---------------------------------

Write-Section 'Check 9/10: Root-level ad-hoc notes guard'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-FailMsg 'specwright.manifest.json not found at repo root'
    Add-Failure 'root-guard: manifest missing'
} else {
    $guardManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $guardPatterns = @($guardManifest.adHocNotesGuard.patterns)
    $guardBad = 0
    foreach ($item in (Get-ChildItem -LiteralPath $repoRoot -File)) {
        foreach ($pat in $guardPatterns) {
            if ($item.Name -like $pat) {
                Write-FailMsg "$($item.Name) : matches ad-hoc notes pattern '$pat' - file review findings as a Jira issue instead (see CONTRIBUTING.md), then delete this file"
                Add-Failure "root-guard: $($item.Name) matches $pat"
                $guardBad++
                break
            }
        }
    }
    if ($guardBad -eq 0) {
        Write-Ok "no ad-hoc review-findings files at repo root ($($guardPatterns.Count) pattern(s) checked)"
    }
}

# ---- Check 10: bash strict mode --------------------------------------------

Write-Section 'Check 10/10: Bash strict mode (*.sh)'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-FailMsg 'specwright.manifest.json not found at repo root'
    Add-Failure 'strict-mode: manifest missing'
} else {
    $strictManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $strictExceptions = @()
    if ($strictManifest.bashStrictMode -and $strictManifest.bashStrictMode.exceptions) {
        $strictExceptions = @($strictManifest.bashStrictMode.exceptions | ForEach-Object { $_.path })
    }

    $strictBad = 0
    # A declared exception that no longer exists is a stale entry - fail it, or the
    # list quietly grows into a blanket waiver.
    foreach ($exc in $strictExceptions) {
        if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $exc) -PathType Leaf)) {
            Write-FailMsg "$exc : listed in bashStrictMode.exceptions but does not exist - remove the entry"
            Add-Failure "strict-mode: stale exception $exc"
            $strictBad++
        }
    }

    $strictCount = 0
    $gitDir = Join-Path $repoRoot '.git'
    $shFiles = Get-ChildItem -LiteralPath $repoRoot -Recurse -File -Filter '*.sh' -ErrorAction SilentlyContinue |
        Where-Object { -not $_.FullName.StartsWith($gitDir) }
    foreach ($sh in $shFiles) {
        $rel = (Get-RelPath $sh.FullName) -replace '\\', '/'
        if ($strictExceptions -contains $rel) { continue }
        $strictCount++

        # First statement = first line that is not blank, a comment, or the shebang.
        $firstStmt = ''
        foreach ($line in (Get-Content -LiteralPath $sh.FullName)) {
            if ($line -match '^\s*(#|$)') { continue }
            $firstStmt = $line.TrimEnd("`r")
            break
        }
        # Accepts any flag cluster carrying e, u and o (e.g. install.sh's -Eeuo).
        # -cmatch: set flags are case-sensitive (-E is not -e).
        $flags = ''
        if ($firstStmt -cmatch '^set\s+-([A-Za-z]+)\s+pipefail\s*$') { $flags = $Matches[1] }
        if (-not ($flags.Contains('e') -and $flags.Contains('u') -and $flags.Contains('o'))) {
            $got = if ($firstStmt) { $firstStmt } else { '<none>' }
            Write-FailMsg "$rel : first statement is not 'set -euo pipefail' (got: $got) - add it, or declare an exception with a reason in specwright.manifest.json bashStrictMode"
            Add-Failure "strict-mode: $rel"
            $strictBad++
        }
    }

    if ($strictBad -eq 0) {
        Write-Ok "$strictCount .sh file(s) use set -euo pipefail ($($strictExceptions.Count) declared exception(s))"
    }
}

# ---- summary ---------------------------------------------------------------

Write-Section 'Summary'
if ($script:Failures.Count -eq 0) {
    Write-Host '  [OK]   All checks passed.' -ForegroundColor Green
    exit 0
} else {
    Write-Host "  [FAIL] $($script:Failures.Count) check(s) failed:" -ForegroundColor Red
    foreach ($m in $script:Failures) { Write-Host "         - $m" -ForegroundColor Red }
    exit 1
}
