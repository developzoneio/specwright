#!/usr/bin/env bash
# Repo invariant validator for specwright (Unix / bash).
#
# Mirror of scripts/validate.ps1 - see that file's header for the full check
# list. Runs every documented engine invariant as a single command:
#   1. Pure-ASCII scan of all *.ps1 files.
#   2. bash -n syntax check on hooks/bash/*.sh, install/*.sh, scripts/*.sh.
#   3. Hook-pair parity (every powershell hook has a bash twin and vice-versa).
#   4. Model-alias-only: agent frontmatter model: in {sonnet,haiku,opus,inherit}.
#   5. Install-target count: a real install to a temp base lands the expected
#      file counts under each <area>/sd/ subfolder.
#   6. CHANGELOG gate: the [Unreleased] section is non-empty.
#   7. Docs consistency: published numbers in the docs match disk, per
#      specwright.manifest.json.
#   8. Cross-file contract lint: the relationships between commands, agents and
#      skills, per the manifest's contractLint subtree. Delegated to
#      scripts/contract-lint.sh as a child process.
#   9. Root-level ad-hoc notes guard: no root-level file matches a declared
#      ad-hoc-notes pattern (specwright.manifest.json's adHocNotesGuard), e.g.
#      REVIEW-TODO.md, TODO.md, FIXME.md, NOTES.md, *-FINDINGS.md.
#  10. Bash strict mode: every *.sh in the repo opens with `set -euo pipefail`
#      unless declared in specwright.manifest.json's bashStrictMode.exceptions.
#
# Exit 0 = all checks passed; 1 = at least one failed.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

# Counts are derived from the source tree, not hardcoded - a new command/agent/skill/template
# only needs to land in its source dir, never a constant bumped in two scripts. Each count is
# asserted > 0 below so an empty/misnamed source dir fails loudly instead of vacuously passing.
# One platform's hooks land per install (bash hooks here), so this counts hooks/bash/*.sh only;
# Check 3 (hook-pair parity) already asserts the powershell count matches.
EXPECTED_COMMANDS="$(find "$repo_root/commands" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')"
EXPECTED_AGENTS="$(find "$repo_root/agents" -maxdepth 1 -type f -name '*.md' | wc -l | tr -d ' ')"
EXPECTED_SKILLS="$(find "$repo_root/skills" -mindepth 2 -maxdepth 2 -type f -name 'SKILL.md' | wc -l | tr -d ' ')"
EXPECTED_HOOKS="$(find "$repo_root/hooks/bash" -maxdepth 1 -type f -name '*.sh' | wc -l | tr -d ' ')"
EXPECTED_TEMPLATES="$(find "$repo_root/templates" -type f | wc -l | tr -d ' ')"

# The version stamp has no source-tree counterpart - it is generated at install time from
# CHANGELOG.md, never copied from a source dir - so unlike the counts above it cannot be
# derived from a glob. This is the one hand-written constant Check 5 uses: how many stamp
# files land per installed area.
STAMP_FILES_PER_AREA=1

for pair in "commands:$EXPECTED_COMMANDS" "agents:$EXPECTED_AGENTS" "skills:$EXPECTED_SKILLS" \
    "hooks:$EXPECTED_HOOKS" "templates:$EXPECTED_TEMPLATES"; do
    if [[ "${pair#*:}" -eq 0 ]]; then
        echo "FATAL: derived expected count for ${pair%%:*} is 0 - source dir empty or missing?" >&2
        exit 1
    fi
done

MODEL_ALIASES="sonnet haiku opus inherit"

# Byte range 0x80-0xFF in the C locale = any non-ASCII byte.
non_ascii_re="$(printf '[\200-\377]')"

# ---- output helpers (match installer vocabulary) ---------------------------

if [[ -t 1 ]]; then
    c_reset=$'\033[0m'; c_cyan=$'\033[36m'; c_green=$'\033[32m'
    c_yellow=$'\033[33m'; c_red=$'\033[31m'
else
    c_reset=''; c_cyan=''; c_green=''; c_yellow=''; c_red=''
fi

section() { echo; echo "${c_cyan}=== $* ===${c_reset}"; }
ok()      { echo "  ${c_green}[OK]${c_reset}   $*"; }
fail()    { echo "  ${c_red}[FAIL]${c_reset} $*"; }
warn()    { echo "  ${c_yellow}[WARN]${c_reset} $*"; }

failures=()
add_failure() { failures+=("$1"); }

# One wording for "jq is missing" across every manifest-reading check, so a runner
# without jq gets the same named cause from each of them - never a bare exit code.
jq_missing() {
    fail "jq is required to parse specwright.manifest.json - install jq"
    add_failure "$1: jq not installed"
}

section "specwright validate"
echo "  Repo root: $repo_root"

# ---- Check 1: pure-ASCII scan ----------------------------------------------

section "Check 1/10: Pure-ASCII scan (*.ps1)"
ascii_bad=0
ps1_count=0
while IFS= read -r -d '' f; do
    ps1_count=$((ps1_count + 1))
    if match="$(LC_ALL=C grep -n "$non_ascii_re" "$f")"; then
        rel="${f#"$repo_root"/}"
        first_line="$(printf '%s\n' "$match" | head -n1 | cut -d: -f1)"
        fail "$rel : non-ASCII byte at line $first_line"
        add_failure "ASCII: $rel (line $first_line)"
        ascii_bad=$((ascii_bad + 1))
    fi
done < <(find "$repo_root" -type f -name '*.ps1' -not -path '*/.git/*' -print0)
if [[ $ascii_bad -eq 0 ]]; then ok "$ps1_count .ps1 file(s) are pure ASCII"; fi

# ---- Check 2: bash -n syntax -----------------------------------------------

section "Check 2/10: bash -n syntax (*.sh)"
syn_bad=0
sh_count=0
while IFS= read -r -d '' f; do
    sh_count=$((sh_count + 1))
    if ! out="$(bash -n "$f" 2>&1)"; then
        rel="${f#"$repo_root"/}"
        fail "$rel : $out"
        add_failure "bash -n: $rel"
        syn_bad=$((syn_bad + 1))
    fi
done < <(find "$repo_root/hooks/bash" "$repo_root/install" "$repo_root/scripts" \
    -maxdepth 1 -type f -name '*.sh' -print0 2>/dev/null)
if [[ $syn_bad -eq 0 ]]; then ok "$sh_count .sh file(s) pass bash -n"; fi

# ---- Check 3: hook-pair parity ---------------------------------------------

section "Check 3/10: Hook-pair parity"
parity_bad=0
ps_count=0
for psf in "$repo_root"/hooks/powershell/*.ps1; do
    [[ -e "$psf" ]] || continue
    ps_count=$((ps_count + 1))
    base="$(basename "$psf" .ps1)"
    if [[ ! -f "$repo_root/hooks/bash/$base.sh" ]]; then
        fail "hooks/powershell/$base.ps1 has no hooks/bash/$base.sh"
        add_failure "parity: missing bash twin for $base"
        parity_bad=$((parity_bad + 1))
    fi
done
for shf in "$repo_root"/hooks/bash/*.sh; do
    [[ -e "$shf" ]] || continue
    base="$(basename "$shf" .sh)"
    if [[ ! -f "$repo_root/hooks/powershell/$base.ps1" ]]; then
        fail "hooks/bash/$base.sh has no hooks/powershell/$base.ps1"
        add_failure "parity: missing PowerShell twin for $base"
        parity_bad=$((parity_bad + 1))
    fi
done
if [[ $parity_bad -eq 0 ]]; then ok "$ps_count hook pair(s) present on both platforms"; fi

# ---- Check 4: agent model aliases ------------------------------------------

section "Check 4/10: Agent model aliases"
model_bad=0
agent_count=0
for af in "$repo_root"/agents/*.md; do
    [[ -e "$af" ]] || continue
    agent_count=$((agent_count + 1))
    rel="${af#"$repo_root"/}"
    line="$(grep -m1 -E '^model:' "$af" || true)"
    if [[ -z "$line" ]]; then
        fail "$rel : no model: field"
        add_failure "model: $rel missing model field"
        model_bad=$((model_bad + 1))
        continue
    fi
    val="$(printf '%s\n' "$line" | sed -E 's/^model:[[:space:]]*//; s/[[:space:]]*#.*$//; s/[[:space:]]+$//')"
    case " $MODEL_ALIASES " in
        *" $val "*) : ;;
        *)
            fail "$rel : model '$val' is not an alias ($MODEL_ALIASES)"
            add_failure "model: $rel = $val"
            model_bad=$((model_bad + 1))
            ;;
    esac
done
if [[ $model_bad -eq 0 ]]; then ok "$agent_count agent(s) use a model alias"; fi

# ---- Check 5: install-target counts ----------------------------------------

section "Check 5/10: Install-target counts"
install_sh="$repo_root/install/install.sh"
tmp="${TMPDIR:-/tmp}/sd-validate-$$"
tmp_nc_src="${TMPDIR:-/tmp}/sd-validate-nc-src-$$"
tmp_nc_base="${TMPDIR:-/tmp}/sd-validate-nc-base-$$"
cleanup_tmp() {
    [[ -n "${tmp:-}" && -d "$tmp" ]] && rm -rf "$tmp" || true
    [[ -n "${tmp_nc_src:-}" && -d "$tmp_nc_src" ]] && rm -rf "$tmp_nc_src" || true
    [[ -n "${tmp_nc_base:-}" && -d "$tmp_nc_base" ]] && rm -rf "$tmp_nc_base" || true
}
trap cleanup_tmp EXIT
rm -rf "$tmp" "$tmp_nc_src" "$tmp_nc_base"
# Counts files under dir and compares against expected, reporting through the same
# fail/ok/add_failure vocabulary as every other check. Reused below for both the
# fresh install and the idempotent re-run, so both runs are asserted through one
# code path rather than two hand-copied loops.
check_count() {
    local name="$1" dir="$2" expected="$3" cnt=0
    if [[ -d "$dir" ]]; then cnt="$(find "$dir" -type f | wc -l | tr -d ' ')"; fi
    if [[ "$cnt" -eq "$expected" ]]; then
        ok "$name/sd : $cnt file(s)"
    else
        fail "$name/sd : expected $expected, found $cnt"
        add_failure "install: $name/sd expected $expected found $cnt"
    fi
}
if bash "$install_sh" --base-path "$tmp" --force >/dev/null 2>&1; then
    EXPECTED_COMMANDS_WITH_STAMP=$((EXPECTED_COMMANDS + STAMP_FILES_PER_AREA))
    EXPECTED_AGENTS_WITH_STAMP=$((EXPECTED_AGENTS + STAMP_FILES_PER_AREA))
    EXPECTED_SKILLS_WITH_STAMP=$((EXPECTED_SKILLS + STAMP_FILES_PER_AREA))
    EXPECTED_HOOKS_WITH_STAMP=$((EXPECTED_HOOKS + STAMP_FILES_PER_AREA))
    EXPECTED_TEMPLATES_WITH_STAMP=$((EXPECTED_TEMPLATES + STAMP_FILES_PER_AREA))
    check_count "commands"  "$tmp/commands/sd"  "$EXPECTED_COMMANDS_WITH_STAMP"
    check_count "agents"    "$tmp/agents/sd"    "$EXPECTED_AGENTS_WITH_STAMP"
    check_count "skills"    "$tmp/skills/sd"    "$EXPECTED_SKILLS_WITH_STAMP"
    check_count "hooks"     "$tmp/hooks/sd"     "$EXPECTED_HOOKS_WITH_STAMP"
    check_count "templates" "$tmp/templates/sd" "$EXPECTED_TEMPLATES_WITH_STAMP"

    # ---- stamp content: every area's stamp equals the CHANGELOG-derived version ----
    stamp_changelog="$repo_root/CHANGELOG.md"
    stamp_version=""
    stamp_release_line="$(grep -m1 -E '^##[[:space:]]+\[[0-9]+\.[0-9]+\.[0-9]+\][[:space:]]+-[[:space:]]+[^[:space:]]' "$stamp_changelog" || true)"
    if [[ "$stamp_release_line" =~ \[([0-9]+\.[0-9]+\.[0-9]+)\] ]]; then
        stamp_version="${BASH_REMATCH[1]}"
    fi
    if [[ -z "$stamp_version" ]]; then
        fail "CHANGELOG.md : no dated release heading found (## [x.y.z] - <date>)"
        add_failure "install: stamp version source unreadable"
    else
        stamp_bad=0
        for area_dir in commands agents skills hooks templates; do
            stamp_file="$tmp/$area_dir/sd/specwright-version.txt"
            if [[ ! -f "$stamp_file" ]]; then
                fail "$area_dir/sd/specwright-version.txt : not found"
                add_failure "install: $area_dir/sd stamp missing"
                stamp_bad=$((stamp_bad + 1))
                continue
            fi
            # Tolerate a stray trailing CR on read - the byte contract itself is
            # asserted below on one stamp; this comparison only cares about content.
            stamp_content="$(cat "$stamp_file")"
            stamp_content="${stamp_content%$'\r'}"
            if [[ "$stamp_content" != "$stamp_version" ]]; then
                fail "$area_dir/sd/specwright-version.txt : content '$stamp_content' != CHANGELOG version '$stamp_version'"
                add_failure "install: $area_dir/sd stamp content mismatch"
                stamp_bad=$((stamp_bad + 1))
            fi
        done
        if [[ $stamp_bad -eq 0 ]]; then ok "5 stamp(s) match CHANGELOG version $stamp_version"; fi

        # Byte-level contract on one stamp (commands): no BOM, no CR, exactly one trailing LF.
        byte_stamp="$tmp/commands/sd/specwright-version.txt"
        if [[ -f "$byte_stamp" ]]; then
            read -r -a stamp_bytes <<< "$(od -A n -v -t x1 "$byte_stamp")"
            byte_count=${#stamp_bytes[@]}
            has_bom=0
            if [[ $byte_count -ge 3 && "${stamp_bytes[0]}" == "ef" && "${stamp_bytes[1]}" == "bb" && "${stamp_bytes[2]}" == "bf" ]]; then
                has_bom=1
            fi
            has_cr=0
            for b in "${stamp_bytes[@]}"; do
                if [[ "$b" == "0d" ]]; then has_cr=1; break; fi
            done
            ends_with_lf=0
            double_lf=0
            if [[ $byte_count -gt 0 && "${stamp_bytes[$((byte_count - 1))]}" == "0a" ]]; then
                ends_with_lf=1
                if [[ $byte_count -gt 1 && "${stamp_bytes[$((byte_count - 2))]}" == "0a" ]]; then
                    double_lf=1
                fi
            fi
            if [[ $has_bom -eq 1 || $has_cr -eq 1 || $ends_with_lf -eq 0 || $double_lf -eq 1 ]]; then
                fail "commands/sd/specwright-version.txt : byte contract violated (BOM=$has_bom CR=$has_cr trailingLF=$ends_with_lf doubleLF=$double_lf)"
                add_failure "install: commands/sd stamp byte contract"
            else
                ok "commands/sd/specwright-version.txt : LF, no BOM, no CR, single trailing newline"
            fi
        fi
    fi

    # ---- idempotent re-run: second --force pass must be a no-op for the stamp ----
    if bash "$install_sh" --base-path "$tmp" --force >/dev/null 2>&1; then
        bak_count="$(find "$tmp" -type f -name '*.bak.*' | wc -l | tr -d ' ')"
        if [[ "$bak_count" -gt 0 ]]; then
            fail "second install run created $bak_count *.bak.* file(s) - stamp is not idempotent"
            add_failure "install: second run produced .bak files"
        else
            ok "second --force run created zero *.bak.* file(s)"
        fi
        check_count "commands"  "$tmp/commands/sd"  "$EXPECTED_COMMANDS_WITH_STAMP"
        check_count "agents"    "$tmp/agents/sd"    "$EXPECTED_AGENTS_WITH_STAMP"
        check_count "skills"    "$tmp/skills/sd"    "$EXPECTED_SKILLS_WITH_STAMP"
        check_count "hooks"     "$tmp/hooks/sd"     "$EXPECTED_HOOKS_WITH_STAMP"
        check_count "templates" "$tmp/templates/sd" "$EXPECTED_TEMPLATES_WITH_STAMP"
    else
        fail "second installer run failed: bash install.sh --base-path <tmp> --force"
        add_failure "install: second installer run returned non-zero"
    fi
else
    fail "installer failed: bash install.sh --base-path <tmp> --force"
    add_failure "install: installer returned non-zero"
fi

# ---- negative case: missing version source fails loudly, copies nothing ----
# The required-source-directory list is mirrored FROM install.sh's own
# REQUIRED_DIRS array, not hand-duplicated here, so a future added requirement
# fails this scenario visibly instead of silently changing what it proves.
required_dirs=()
while IFS= read -r rd; do
    required_dirs+=("$rd")
done < <(grep -m1 '^REQUIRED_DIRS=' "$install_sh" | grep -oE '"[^"]+"' | tr -d '"')
if [[ ${#required_dirs[@]} -eq 0 ]]; then
    fail "install.sh : could not parse REQUIRED_DIRS - missing-CHANGELOG scenario skipped"
    add_failure "install: could not parse install.sh required dirs"
else
    mkdir -p "$tmp_nc_src/install"
    cp "$install_sh" "$tmp_nc_src/install/install.sh"
    for d in "${required_dirs[@]}"; do
        mkdir -p "$tmp_nc_src/$d"
    done
    nc_out=""
    nc_exit=0
    nc_out="$(bash "$tmp_nc_src/install/install.sh" --base-path "$tmp_nc_base" --force 2>&1)" || nc_exit=$?
    nc_bad=0
    if [[ $nc_exit -eq 0 ]]; then
        fail "missing-CHANGELOG scenario: installer exited 0, expected non-zero"
        add_failure "install: missing-changelog scenario did not fail"
        nc_bad=$((nc_bad + 1))
    fi
    if [[ "$nc_out" != *"CHANGELOG.md"* ]]; then
        fail "missing-CHANGELOG scenario: installer output did not mention CHANGELOG.md"
        add_failure "install: missing-changelog scenario message missing CHANGELOG.md"
        nc_bad=$((nc_bad + 1))
    fi
    nc_file_count=0
    if [[ -d "$tmp_nc_base" ]]; then
        nc_file_count="$(find "$tmp_nc_base" -type f | wc -l | tr -d ' ')"
    fi
    if [[ "$nc_file_count" -ne 0 ]]; then
        fail "missing-CHANGELOG scenario: base contains $nc_file_count file(s), expected 0"
        add_failure "install: missing-changelog scenario copied files"
        nc_bad=$((nc_bad + 1))
    fi
    if [[ $nc_bad -eq 0 ]]; then
        ok "missing-CHANGELOG.md scenario: installer failed loudly and copied nothing"
    fi
fi

cleanup_tmp
trap - EXIT

# ---- Check 6: CHANGELOG [Unreleased] non-empty -----------------------------

section "Check 6/10: CHANGELOG [Unreleased] gate"
changelog="$repo_root/CHANGELOG.md"
block="$(awk '
    /^##[[:space:]]+\[Unreleased\]/ { f=1; next }
    /^##[[:space:]]+\[/             { f=0 }
    f                               { print }
' "$changelog")"
# Header of the section immediately below [Unreleased].
next_header="$(awk '
    /^##[[:space:]]+\[Unreleased\]/ { f=1; next }
    f && /^##[[:space:]]+\[/        { print; exit }
' "$changelog")"
if printf '%s\n' "$block" | grep -qE '^[[:space:]]*-[[:space:]]+[^[:space:]]'; then
    ok "[Unreleased] has at least one entry"
elif printf '%s\n' "$next_header" \
    | grep -qE '^##[[:space:]]+\[[0-9]+\.[0-9]+\.[0-9]+\][[:space:]]+-[[:space:]]+[^[:space:]]'; then
    # Empty [Unreleased] is allowed only directly above a freshly cut release.
    ok "[Unreleased] empty but sits directly above a dated release (just cut)"
else
    fail "[Unreleased] section is empty (add a changelog entry)"
    add_failure "changelog: [Unreleased] empty"
fi

# ---- Check 7: docs consistency ---------------------------------------------

section "Check 7/10: Docs consistency (published numbers vs disk)"
manifest="$repo_root/specwright.manifest.json"
if [[ ! -f "$manifest" ]]; then
    fail "specwright.manifest.json not found at repo root"
    add_failure "docs: manifest missing"
elif ! command -v jq >/dev/null 2>&1; then
    # Hooks exit 0 silently when jq is absent so they never block a user on their own
    # bugs. A validator must do the opposite: a missing jq that passed would turn CI
    # green while checking nothing.
    jq_missing "docs"
else
    docs_bad=0
    # Plain (non-associative) arrays + linear-scan lookup functions, not `declare -A`:
    # macOS ships /bin/bash 3.2 (no associative arrays), and this script must run there.
    quantity_names=()
    quantity_values=()
    q_set() { # name value
        local name="$1" value="$2" i
        for i in "${!quantity_names[@]}"; do
            if [[ "${quantity_names[$i]}" == "$name" ]]; then
                quantity_values[$i]="$value"
                return
            fi
        done
        quantity_names+=("$name")
        quantity_values+=("$value")
    }
    q_get() { # name -> stdout value, empty if unset
        local name="$1" i
        for i in "${!quantity_names[@]}"; do
            if [[ "${quantity_names[$i]}" == "$name" ]]; then
                printf '%s' "${quantity_values[$i]}"
                return
            fi
        done
    }

    file_pattern_names=()
    file_pattern_values=()
    fp_append() { # file pattern
        local file="$1" pattern="$2" i
        for i in "${!file_pattern_names[@]}"; do
            if [[ "${file_pattern_names[$i]}" == "$file" ]]; then
                file_pattern_values[$i]="${file_pattern_values[$i]}${pattern}"$'\n'
                return
            fi
        done
        file_pattern_names+=("$file")
        file_pattern_values+=("${pattern}"$'\n')
    }
    fp_get() { # file -> stdout newline-joined patterns, empty if none
        local file="$1" i
        for i in "${!file_pattern_names[@]}"; do
            if [[ "${file_pattern_names[$i]}" == "$file" ]]; then
                printf '%s' "${file_pattern_values[$i]}"
                return
            fi
        done
    }

    # Some jq builds (notably jq.exe on Windows) emit CRLF. An unstripped \r rides on the
    # last field of every record and silently breaks glob matches, array keys and prefix
    # tests - failures that look like real drift but are not.
    mjq() { jq -r "$1" "$manifest" | tr -d '\r'; }

    # Area counts are derived from disk, never stored in the manifest.
    shopt -s nullglob
    while IFS=$'\t' read -r area_name area_kind area_value; do
        area_count=0
        if [[ "$area_kind" == "glob" ]]; then
            for p in "$repo_root"/$area_value; do
                [[ -f "$p" ]] && area_count=$((area_count + 1))
            done
        else
            for rel_f in $area_value; do
                if [[ -f "$repo_root/$rel_f" ]]; then
                    area_count=$((area_count + 1))
                else
                    fail "area '$area_name' lists a file that does not exist: $rel_f"
                    add_failure "docs: area $area_name missing $rel_f"
                    docs_bad=$((docs_bad + 1))
                fi
            done
        fi
        if [[ $area_count -eq 0 ]]; then
            fail "area '$area_name' ($area_kind '$area_value') matched 0 files"
            add_failure "docs: area $area_name derived 0"
            docs_bad=$((docs_bad + 1))
        fi
        q_set "$area_name" "$area_count"
    done < <(mjq '.areas | to_entries[] | "\(.key)\t\(if .value.glob then "glob" else "files" end)\t\(.value.glob // (.value.files | join(" ")))"')
    shopt -u nullglob

    # Stamp count is a THIRD kind of quantity here: not read from a source-tree glob (there
    # is no stamp source dir) but derived from areas.*.installTo - one stamp lands in each
    # distinct '<area>/sd/' root the installer writes to. Seeded here, before the derived
    # loop, so derived.installTotalWithStamps can reference it without depending on JSON key
    # order, and it self-corrects if an area is added or removed. Plain string + word-split,
    # not an array: an empty array under `set -u` is not safe on bash 3.2 (macOS).
    install_roots=""
    while IFS= read -r install_to; do
        [[ -z "$install_to" ]] && continue
        seg1="${install_to%%/*}"
        rest="${install_to#*/}"
        seg2="${rest%%/*}"
        [[ -z "$seg2" ]] && continue
        root="$seg1/$seg2"
        case " $install_roots " in
            *" $root "*) ;;
            *) install_roots="$install_roots $root" ;;
        esac
    done < <(mjq '.areas | to_entries[] | .value.installTo // empty')
    install_stamps=0
    for r in $install_roots; do
        install_stamps=$((install_stamps + 1))
    done
    q_set "installStamps" "$install_stamps"

    while IFS=$'\t' read -r der_name der_parts; do
        der_total=0
        for part in $der_parts; do
            part_val="$(q_get "$part")"
            der_total=$((der_total + ${part_val:-0}))
        done
        q_set "$der_name" "$der_total"
    done < <(mjq '.derived | to_entries[] | "\(.key)\t\(.value | join(" "))"')

    # Gate quantities are DECLARED, not derived: nothing on disk is a second
    # source for "how many hard gates /sd:feature has". Seeding them here gives
    # the topology README <- manifest (this check) and manifest <- disk (Check
    # 8's CL302), hence transitively README == disk, with zero duplication of the
    # gate parser into this file. A null quantity means the gate block is real
    # but no doc publishes a number for it.
    while IFS=$'\t' read -r gate_q gate_hard; do
        [[ -z "$gate_q" || "$gate_q" == "null" ]] && continue
        q_set "$gate_q" "$gate_hard"
    done < <(mjq '.contractLint.gates // {} | to_entries[] | "\(.value.quantity)\t\(.value.hard)"')

    while IFS=$'\t' read -r c_file c_pattern c_equals; do
        fp_append "$c_file" "$c_pattern"

        target="$repo_root/$c_file"
        if [[ ! -f "$target" ]]; then
            fail "$c_file : declared claim file does not exist"
            add_failure "docs: missing claim file $c_file"
            docs_bad=$((docs_bad + 1))
            continue
        fi
        expected="$(q_get "$c_equals")"
        if [[ -z "$expected" ]]; then
            fail "$c_file : claim references unknown quantity '$c_equals'"
            add_failure "docs: unknown quantity $c_equals"
            docs_bad=$((docs_bad + 1))
            continue
        fi

        hits=0
        lineno=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            lineno=$((lineno + 1))
            if [[ "$line" =~ $c_pattern ]]; then
                hits=$((hits + 1))
                found="${BASH_REMATCH[1]}"
                if [[ "$found" != "$expected" ]]; then
                    fail "$c_file:$lineno : says $found, disk has $expected ($c_equals)"
                    add_failure "docs: $c_file:$lineno $c_equals says $found not $expected"
                    docs_bad=$((docs_bad + 1))
                fi
            fi
        done < "$target"

        # A pattern that matches nothing is a rotted regex, not a pass - without this
        # a reworded doc sentence silently turns the claim into a no-op.
        if [[ $hits -eq 0 ]]; then
            fail "$c_file : pattern matched no lines (reworded?): $c_pattern"
            add_failure "docs: vacuous claim in $c_file ($c_equals)"
            docs_bad=$((docs_bad + 1))
        fi
    done < <(mjq '.docClaims[] | "\(.file)\t\(.pattern)\t\(.equals)"')

    # ---- Version claims: published version vs newest dated CHANGELOG heading ---
    # Independent of Check 6's next_header - that variable resolves to whatever line
    # sits directly below [Unreleased], which is a bullet (not a header) in the normal
    # non-just-released state, so it cannot be relied on here. Scan the whole file for
    # the first dated release heading instead.
    released_version=""
    release_line="$(grep -m1 -E '^##[[:space:]]+\[[0-9]+\.[0-9]+\.[0-9]+\][[:space:]]+-[[:space:]]+[^[:space:]]' "$changelog" || true)"
    if [[ "$release_line" =~ \[([0-9]+\.[0-9]+\.[0-9]+)\] ]]; then
        released_version="${BASH_REMATCH[1]}"
    fi
    if [[ -z "$released_version" ]]; then
        fail "CHANGELOG.md : no dated release heading found (## [x.y.z] - <date>)"
        add_failure "docs: no dated release heading in CHANGELOG.md"
        docs_bad=$((docs_bad + 1))
    fi

    while IFS=$'\t' read -r v_file v_pattern; do
        target="$repo_root/$v_file"
        if [[ ! -f "$target" ]]; then
            fail "$v_file : declared version-claim file does not exist"
            add_failure "docs: missing version-claim file $v_file"
            docs_bad=$((docs_bad + 1))
            continue
        fi
        [[ -z "$released_version" ]] && continue

        hits=0
        lineno=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            lineno=$((lineno + 1))
            if [[ "$line" =~ $v_pattern ]]; then
                hits=$((hits + 1))
                found="${BASH_REMATCH[1]}"
                if [[ "$found" != "$released_version" ]]; then
                    fail "$v_file:$lineno : says $found, CHANGELOG has $released_version"
                    add_failure "docs: $v_file:$lineno version says $found not $released_version"
                    docs_bad=$((docs_bad + 1))
                fi
            fi
        done < "$target"

        # A pattern that matches nothing is a rotted regex, not a pass - same rationale
        # as the docClaims vacuous-claim check above.
        if [[ $hits -eq 0 ]]; then
            fail "$v_file : version pattern matched no lines (reworded?): $v_pattern"
            add_failure "docs: vacuous version claim in $v_file"
            docs_bad=$((docs_bad + 1))
        fi
    done < <(mjq '.versionClaims[] | "\(.file)\t\(.pattern)"')

    # Undeclared-claim scan: any line that looks like an inventory claim but is not
    # covered by a docClaims entry. This is what keeps the manifest canonical - a new
    # doc cannot publish a number that nothing checks.
    phrases_re="$(mjq '.claimPhrases | join("|")')"
    # Not `mapfile` (bash 4+, absent from macOS's stock /bin/bash 3.2).
    exclusions=()
    while IFS= read -r ex; do
        exclusions+=("$ex")
    done < <(mjq '.historicalExclusions[]')

    while IFS= read -r -d '' f; do
        rel="${f#"$repo_root"/}"
        skip=0
        for ex in "${exclusions[@]}"; do
            if [[ "$rel" == "$ex"* ]]; then skip=1; break; fi
        done
        [[ $skip -eq 1 ]] && continue

        lineno=0
        while IFS= read -r line || [[ -n "$line" ]]; do
            lineno=$((lineno + 1))
            [[ "$line" =~ $phrases_re ]] || continue
            covered=0
            fp_val="$(fp_get "$rel")"
            if [[ -n "$fp_val" ]]; then
                while IFS= read -r pat; do
                    [[ -z "$pat" ]] && continue
                    if [[ "$line" =~ $pat ]]; then covered=1; break; fi
                done <<< "$fp_val"
            fi
            if [[ $covered -eq 0 ]]; then
                fail "$rel:$lineno : undeclared inventory claim (add a docClaims entry or an exclusion)"
                add_failure "docs: undeclared claim $rel:$lineno"
                docs_bad=$((docs_bad + 1))
            fi
        done < "$f"
    done < <(find "$repo_root" -type f -name '*.md' -not -path '*/.git/*' -print0)

    if [[ $docs_bad -eq 0 ]]; then
        claim_total="$(mjq '.docClaims | length')"
        version_total="$(mjq '.versionClaims | length')"
        ok "$claim_total published claim(s) + $version_total version claim(s) match disk/CHANGELOG; no undeclared claims"
    fi
fi

# ---- Check 8: cross-file contract lint -------------------------------------

section "Check 8/10: Cross-file contract lint (commands / agents / skills)"
lint_sh="$script_dir/contract-lint.sh"
if [[ ! -f "$lint_sh" ]]; then
    fail "scripts/contract-lint.sh not found"
    add_failure "contract-lint: script missing"
elif ! command -v jq >/dev/null 2>&1; then
    # The linter would exit 2 for this too, but its reason goes to stderr, which
    # is discarded below - name the cause here instead of a bare "exit 2".
    jq_missing "contract-lint"
else
    # Spawned as a CHILD PROCESS so its `exit` cannot terminate this validator,
    # and so its stdout stays a clean machine-readable stream. All human
    # formatting happens here; the linter stays a dumb TSV emitter and the two
    # linter twins never learn about colours or [OK] tags.
    lint_out=""
    lint_exit=0
    lint_out="$(bash "$lint_sh" --root "$repo_root" --quiet 2>/dev/null)" || lint_exit=$?

    cl_blocks=0
    cl_warns=0
    cl_warns_budgeted=0
    if [[ -n "$lint_out" ]]; then
        while IFS=$'\t' read -r cl_rule cl_sev cl_file cl_line cl_msg; do
            [[ -z "$cl_rule" ]] && continue
            if [[ "$cl_sev" == "BLOCK" ]]; then
                fail "$cl_file:$cl_line $cl_rule - $cl_msg"
                add_failure "contract-lint: $cl_rule $cl_file:$cl_line"
                cl_blocks=$((cl_blocks + 1))
            else
                warn "$cl_file:$cl_line $cl_rule - $cl_msg"
                cl_warns=$((cl_warns + 1))
                # CL202 is a permanent-WARN ratchet by design (unrecognized
                # MCP tool names) - never counted against the standing-warning
                # budget below, or a legitimate new tool name would fail the
                # build through a rule explicitly meant not to.
                case "$cl_rule" in
                    CL202) : ;;
                    *) cl_warns_budgeted=$((cl_warns_budgeted + 1)) ;;
                esac
            fi
        done <<< "$lint_out"
    fi

    if [[ $lint_exit -ge 2 ]]; then
        # Exit 2 means the linter could not run at all. Treating that as a pass
        # is the failure mode this whole check exists to prevent.
        fail "contract-lint could not run (exit $lint_exit)"
        add_failure "contract-lint: exit $lint_exit"
    else
        # Ratchet, not a ceiling: contractLint.warnBudget is the max standing
        # WARN count (excluding CL202). Lowering it below actual requires
        # lowering it in the SAME commit that resolves the warnings - never
        # raise it to make a new warning pass quietly.
        warn_budget=0
        if command -v jq >/dev/null 2>&1; then
            _wb="$(jq -r '.contractLint.warnBudget // 0' "$manifest" 2>/dev/null)"
            [[ "$_wb" =~ ^[0-9]+$ ]] && warn_budget="$_wb"
        fi
        if [[ $cl_blocks -eq 0 && $cl_warns_budgeted -le $warn_budget ]]; then
            if [[ $cl_warns -eq 0 ]]; then
                ok "no contract violations"
            else
                ok "no BLOCK violations ($cl_warns warning(s) above, $cl_warns_budgeted/$warn_budget standing-warning budget)"
            fi
        elif [[ $cl_blocks -eq 0 ]]; then
            fail "standing-warning budget exceeded: $cl_warns_budgeted budgeted warning(s) > contractLint.warnBudget ($warn_budget)"
            add_failure "contract-lint: warn budget $cl_warns_budgeted > $warn_budget"
        fi
    fi
fi

# ---- Check 9: root-level ad-hoc notes guard --------------------------------

section "Check 9/10: Root-level ad-hoc notes guard"
if [[ ! -f "$manifest" ]]; then
    fail "specwright.manifest.json not found at repo root"
    add_failure "root-guard: manifest missing"
elif ! command -v jq >/dev/null 2>&1; then
    jq_missing "root-guard"
else
    guard_patterns=()
    while IFS= read -r pat; do
        [[ -z "$pat" ]] && continue
        guard_patterns+=("$pat")
    done < <(jq -r '.adHocNotesGuard.patterns[]' "$manifest" | tr -d '\r')

    shopt -s nocasematch
    guard_bad=0
    for f in "$repo_root"/*; do
        [[ -f "$f" ]] || continue
        base="$(basename "$f")"
        for pat in "${guard_patterns[@]}"; do
            case "$base" in
                $pat)
                    fail "$base : matches ad-hoc notes pattern '$pat' - file review findings as a Jira issue instead (see CONTRIBUTING.md), then delete this file"
                    add_failure "root-guard: $base matches $pat"
                    guard_bad=$((guard_bad + 1))
                    break
                    ;;
            esac
        done
    done
    shopt -u nocasematch
    if [[ $guard_bad -eq 0 ]]; then
        ok "no ad-hoc review-findings files at repo root (${#guard_patterns[@]} pattern(s) checked)"
    fi
fi

# ---- Check 10: bash strict mode --------------------------------------------

section "Check 10/10: Bash strict mode (*.sh)"
if [[ ! -f "$manifest" ]]; then
    fail "specwright.manifest.json not found at repo root"
    add_failure "strict-mode: manifest missing"
elif ! command -v jq >/dev/null 2>&1; then
    jq_missing "strict-mode"
else
    strict_exceptions=()
    while IFS= read -r exc; do
        [[ -z "$exc" ]] && continue
        strict_exceptions+=("$exc")
    done < <(jq -r '.bashStrictMode.exceptions[]?.path' "$manifest" | tr -d '\r')

    strict_bad=0
    # A declared exception that no longer exists is a stale entry - fail it, or the
    # list quietly grows into a blanket waiver.
    for exc in ${strict_exceptions[@]+"${strict_exceptions[@]}"}; do
        if [[ ! -f "$repo_root/$exc" ]]; then
            fail "$exc : listed in bashStrictMode.exceptions but does not exist - remove the entry"
            add_failure "strict-mode: stale exception $exc"
            strict_bad=$((strict_bad + 1))
        fi
    done

    strict_count=0
    while IFS= read -r -d '' f; do
        rel="${f#"$repo_root"/}"
        is_exception=0
        for exc in ${strict_exceptions[@]+"${strict_exceptions[@]}"}; do
            if [[ "$rel" == "$exc" ]]; then is_exception=1; break; fi
        done
        [[ $is_exception -eq 1 ]] && continue
        strict_count=$((strict_count + 1))

        # First statement = first line that is not blank, a comment, or the shebang.
        first_stmt=""
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
            first_stmt="$line"
            break
        done < "$f"
        # Accepts any flag cluster carrying e, u and o (e.g. install.sh's -Eeuo).
        flags=""
        if [[ "$first_stmt" =~ ^set[[:space:]]+-([A-Za-z]+)[[:space:]]+pipefail[[:space:]]*$ ]]; then
            flags="${BASH_REMATCH[1]}"
        fi
        if [[ -z "$flags" || "$flags" != *e* || "$flags" != *u* || "$flags" != *o* ]]; then
            fail "$rel : first statement is not 'set -euo pipefail' (got: ${first_stmt:-<none>}) - add it, or declare an exception with a reason in specwright.manifest.json bashStrictMode"
            add_failure "strict-mode: $rel"
            strict_bad=$((strict_bad + 1))
        fi
    done < <(find "$repo_root" -name .git -prune -o -type f -name '*.sh' -print0 2>/dev/null)

    if [[ $strict_bad -eq 0 ]]; then
        ok "$strict_count .sh file(s) use set -euo pipefail (${#strict_exceptions[@]} declared exception(s))"
    fi
fi

# ---- summary ---------------------------------------------------------------

section "Summary"
if [[ ${#failures[@]} -eq 0 ]]; then
    ok "All checks passed."
    exit 0
else
    fail "${#failures[@]} check(s) failed:"
    for m in "${failures[@]}"; do echo "         - $m"; done
    exit 1
fi
