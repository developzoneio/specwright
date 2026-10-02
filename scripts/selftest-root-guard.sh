#!/usr/bin/env bash
# Negative self-test for validate.sh Check 9 (root-level ad-hoc notes guard), Unix / bash.
#
# Mirror of scripts/selftest-root-guard.ps1.
#
# Check 9 only earns its place in CI if it FAILS when an ad-hoc notes file reappears at
# the repo root. A check that silently degrades into a no-op still reports success, so
# this test corrupts a throwaway copy of the repo in several ways and asserts the
# validator catches each:
#
#   1. Clean copy (real ROADMAP.md included) -> passes.
#   2. A literal filename (REVIEW-TODO.md)   -> fails, naming the pattern.
#   3. A suffix glob (*-FINDINGS.md)         -> fails, naming the pattern.
#   4. A lowercase-variant filename          -> fails identically (case-insensitive match).
#   5. Removing the offending file           -> restores a pass in the same sandbox copy.
#
# Scenario 4 is what actually machine-checks that bash and PowerShell agree on matching
# case-insensitively (NTFS/APFS are case-insensitive filesystems, so a case-sensitive
# guard would let a differently-cased ad-hoc notes file through on exactly those
# platforms) - a future edit that silently changed one side to case-sensitive matching
# would only be caught here.
#
# Exit 0 = the check behaves correctly; 1 = the check is broken.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

if [[ -t 1 ]]; then
    c_reset=$'\033[0m'; c_cyan=$'\033[36m'; c_green=$'\033[32m'; c_red=$'\033[31m'
else
    c_reset=''; c_cyan=''; c_green=''; c_red=''
fi
section() { echo; echo "${c_cyan}=== $* ===${c_reset}"; }
ok()      { echo "  ${c_green}[OK]${c_reset}   $*"; }
fail()    { echo "  ${c_red}[FAIL]${c_reset} $*"; }

failures=0

# Working dirs are throwaway copies - the real repo is never mutated.
SKIP_TOP=(".git" "node_modules" "_bmad" "_bmad-output" "design-artifacts" ".claude" "dist")

work_root="$(mktemp -d)"
cleanup() { rm -rf "$work_root"; }
trap cleanup EXIT

make_copy() {
    local dest="$1" entry base skip
    mkdir -p "$dest"
    for entry in "$repo_root"/* "$repo_root"/.[!.]*; do
        [[ -e "$entry" ]] || continue
        base="$(basename "$entry")"
        skip=0
        for s in "${SKIP_TOP[@]}"; do
            [[ "$base" == "$s" ]] && { skip=1; break; }
        done
        [[ $skip -eq 1 ]] && continue
        cp -R "$entry" "$dest/"
    done
}

# Run the validator inside a copy and assert exit status + expected message.
# expect_pass=1 -> exit 0 required; expect_pass=0 -> non-zero AND $needle in output.
run_case() {
    local name="$1" expect_pass="$2" needle="${3:-}" dir="$4"
    local out status=0
    out="$(bash "$dir/scripts/validate.sh" 2>&1)" || status=$?

    if [[ "$expect_pass" -eq 1 ]]; then
        if [[ $status -eq 0 ]]; then
            ok "$name : validator passed as expected"
        else
            fail "$name : expected exit 0, got $status"
            printf '%s\n' "$out" | sed -n '/Check 9/,$p' | sed 's/^/         /'
            failures=$((failures + 1))
        fi
        return
    fi

    if [[ $status -eq 0 ]]; then
        fail "$name : expected non-zero exit, got 0 - THE CHECK DID NOT BITE"
        failures=$((failures + 1))
        return
    fi
    if printf '%s\n' "$out" | grep -qF "$needle"; then
        ok "$name : failed with the right reason (exit $status)"
    else
        # Non-zero for the wrong reason is not a pass - it would mask a broken check.
        fail "$name : exited $status but never said '$needle'"
        printf '%s\n' "$out" | sed -n '/Check 9/,$p' | sed 's/^/         /'
        failures=$((failures + 1))
    fi
}

section "selftest: root-level ad-hoc notes guard (Check 9)"
echo "  Repo root: $repo_root"
echo "  Sandbox:   $work_root"

# ---- Scenario 1: clean copy passes -----------------------------------------

section "Scenario 1/5: clean copy (with real ROADMAP.md) passes"
clean="$work_root/clean"
make_copy "$clean"
run_case "clean" 1 "" "$clean"

# ---- Scenario 2: a literal filename fails ----------------------------------

section "Scenario 2/5: literal filename (REVIEW-TODO.md) fails"
literal="$work_root/literal"
make_copy "$literal"
: > "$literal/REVIEW-TODO.md"
run_case "literal" 0 "matches ad-hoc notes pattern 'REVIEW-TODO.md'" "$literal"

# ---- Scenario 3: a suffix glob fails ---------------------------------------

section "Scenario 3/5: suffix glob (*-FINDINGS.md) fails"
suffix="$work_root/suffix"
make_copy "$suffix"
: > "$suffix/SECURITY-AUDIT-FINDINGS.md"
run_case "suffix" 0 "matches ad-hoc notes pattern '*-FINDINGS.md'" "$suffix"

# ---- Scenario 4: a lowercase variant fails identically (case-insensitive) --

section "Scenario 4/5: lowercase variant (review-todo.md) fails"
lower="$work_root/lower"
make_copy "$lower"
: > "$lower/review-todo.md"
run_case "lower" 0 "matches ad-hoc notes pattern" "$lower"

# ---- Scenario 5: removing the offending file restores a pass --------------

section "Scenario 5/5: removing the offending file restores a pass"
removed="$work_root/removed"
make_copy "$removed"
: > "$removed/REVIEW-TODO.md"
run_case "removed (before)" 0 "matches ad-hoc notes pattern 'REVIEW-TODO.md'" "$removed"
rm -f "$removed/REVIEW-TODO.md"
run_case "removed (after)" 1 "" "$removed"

# ---- summary ---------------------------------------------------------------

section "Summary"
if [[ $failures -eq 0 ]]; then
    ok "Check 9 bites on all 5 scenarios."
    exit 0
else
    fail "$failures scenario(s) behaved wrong - Check 9 is not trustworthy."
    exit 1
fi
