#!/usr/bin/env bash
# Release-time prompt size report for the specwright ENGINE PRODUCT (Unix / bash).
#
# Twin of scripts/prompt-size-report.ps1. Both MUST print byte-identical stdout
# for the same tree and ref; tests/prompt-size-report/run-parity.ps1 runs both
# and diffs them.
#
# Replaces CL500 (the per-area byte-budget ratchet retired by SW-57, see
# docs/adr/0011-retire-cl500-byte-ratchet.md). Instead of a number someone has
# to bump, it reports every prompt file's growth since the last release, read
# once per minor release - see docs/contract-lint.md "Prompt size report".
#
# Usage:
#   prompt-size-report.sh [--root <path>] [--since <ref>]
#
#   --root   repo to report on (default: the repo this script lives in).
#   --since  git ref to compare the working tree against (default: the highest
#            v* tag by version order, whether or not it is an ancestor - release
#            tags are cut on main, not on the development branch).
#
# Scope is the manifest's contractLint.scanScope; the flag threshold is
# promptSizeReport.flagGrowthPercent.
#
# Output is TSV on stdout, one row per file, then one TOTAL row per area:
#   <FILE>\t<BEFORE>\t<AFTER>\t<DELTA>\t<PCT>\t<FLAG>
# BEFORE/AFTER are '-' for a file absent on that side. PCT is growth in percent
# to one decimal, truncated toward zero, signed by the delta ('new' / 'removed'
# when one side is absent). FLAG is 'FLAG' when growth exceeds the threshold, else '-'. File rows
# sort by DELTA descending, then path in byte order. The summary goes to stderr
# and is never parsed or compared.
#
# Byte counts are NORMALIZED, the measure CL500 used: CR bytes removed, one
# trailing LF not counted. *.md is 'text=auto' (see .gitattributes), so a raw
# count would differ between a Windows and a Linux checkout of identical content.
#
# Exit codes:
#   0  report printed (the report is advisory - it never fails a build)
#   2  cannot run (bad --root, missing manifest, missing jq or git, bad ref)

set -euo pipefail
export LC_ALL=C

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$script_dir/.." && pwd)"
SINCE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)  ROOT="${2:-}"; shift 2 ;;
        --since) SINCE="${2:-}"; shift 2 ;;
        -h|--help)
            grep -E '^# ' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "prompt-size-report: unknown argument '$1'" >&2
            exit 2 ;;
    esac
done

die() { echo "prompt-size-report: $1" >&2; exit 2; }

[[ -n "$ROOT" && -d "$ROOT" ]] || die "--root is not a directory: '$ROOT'"
ROOT="$(cd "$ROOT" && pwd)"
MANIFEST="$ROOT/specwright.manifest.json"
[[ -f "$MANIFEST" ]] || die "manifest not found: $MANIFEST"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v git >/dev/null 2>&1 || die "git is required"
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $ROOT"

if [[ -z "$SINCE" ]]; then
    SINCE="$(git -C "$ROOT" tag --list 'v*' --sort=-v:refname | head -n 1)"
    [[ -n "$SINCE" ]] || die "no v* tag found; pass --since <ref>"
fi
git -C "$ROOT" rev-parse --verify --quiet "$SINCE^{commit}" >/dev/null \
    || die "not a commit: '$SINCE'"

THRESHOLD="$(jq -r '.promptSizeReport.flagGrowthPercent // empty' "$MANIFEST" | tr -d '\r')"
[[ "$THRESHOLD" =~ ^[0-9]+$ ]] || die "promptSizeReport.flagGrowthPercent missing or not an integer"

# Newline-separated, not an array: macOS ships /bin/bash 3.2, where an empty
# array under `set -u` is fatal and `declare -A` does not exist.
SCOPE="$(jq -r '.contractLint.scanScope[]?' "$MANIFEST" | tr -d '\r')"
[[ -n "$SCOPE" ]] || die "contractLint.scanScope is empty"

in_scope() { # rel_path -> 0 if it matches any scanScope glob
    local _g
    while IFS= read -r _g; do
        [[ -z "$_g" ]] && continue
        # shellcheck disable=SC2053 # unquoted on purpose: glob match
        [[ "$1" == $_g ]] && return 0
    done <<< "$SCOPE"
    return 1
}

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

norm_bytes() { # stdin -> normalized byte count
    local _n _last
    tr -d '\r' > "$TMP"
    _n="$(wc -c < "$TMP" | tr -d ' ')"
    if ((_n > 0)); then
        _last="$(tail -c 1 "$TMP" | od -An -tx1 | tr -d ' \n')"
        [[ "$_last" == "0a" ]] && _n=$((_n - 1))
    fi
    printf '%s' "$_n"
}

# Union of in-scope paths at the ref and on disk, byte-sorted and unique.
PATHS="$(
    {
        git -C "$ROOT" ls-tree -r --name-only "$SINCE"
        (cd "$ROOT" && while IFS= read -r _g; do
            [[ -z "$_g" ]] && continue
            for _f in $_g; do [[ -f "$_f" ]] && printf '%s\n' "$_f"; done
        done <<< "$SCOPE")
    } | while IFS= read -r _p; do
        in_scope "$_p" && printf '%s\n' "$_p"
    done | sort -u
)"

pct() { # before delta -> percent to one decimal, truncated toward zero
    local _t=$(( $2 * 1000 / $1 )) _sign=""
    # Sign from the delta, not the truncated value: -6 bytes reads '-0.0%'.
    if (($2 > 0)); then _sign="+"; elif (($2 < 0)); then _sign="-"; fi
    ((_t < 0)) && _t=$((-_t))
    printf '%s%d.%d%%' "$_sign" $((_t / 10)) $((_t % 10))
}

ROWS=""
flagged=0
nfiles=0
while IFS= read -r _p; do
    [[ -z "$_p" ]] && continue
    nfiles=$((nfiles + 1))
    _before="-"; _after="-"
    if git -C "$ROOT" cat-file -e "$SINCE:$_p" 2>/dev/null; then
        _before="$(git -C "$ROOT" cat-file blob "$SINCE:$_p" | norm_bytes)"
    fi
    if [[ -f "$ROOT/$_p" ]]; then
        _after="$(norm_bytes < "$ROOT/$_p")"
    fi
    _b=0; _a=0
    [[ "$_before" != "-" ]] && _b="$_before"
    [[ "$_after" != "-" ]] && _a="$_after"
    _delta=$((_a - _b))
    _flag="-"
    if [[ "$_before" == "-" ]]; then
        _pct="new"
    elif [[ "$_after" == "-" ]]; then
        _pct="removed"
    elif ((_b == 0)); then
        _pct="0.0%"
    else
        _pct="$(pct "$_b" "$_delta")"
        if ((_delta * 100 > _b * THRESHOLD)); then
            _flag="FLAG"; flagged=$((flagged + 1))
        fi
    fi
    ROWS+="$_p"$'\t'"$_before"$'\t'"$_after"$'\t'"$_delta"$'\t'"$_pct"$'\t'"$_flag"$'\n'
done <<< "$PATHS"

if [[ -n "$ROWS" ]]; then
    printf '%s' "$ROWS" | sort -t $'\t' -k4,4nr -k1,1
fi

total_delta=0
while IFS= read -r _area; do
    [[ -z "$_area" ]] && continue
    _sums="$(printf '%s' "$ROWS" | awk -F '\t' -v a="$_area/" '
        index($1, a) == 1 { if ($2 != "-") b += $2; if ($3 != "-") c += $3 }
        END { printf "%d %d", b, c }')"
    _b="${_sums% *}"; _a="${_sums#* }"
    _delta=$((_a - _b))
    total_delta=$((total_delta + _delta))
    if ((_b == 0)); then _pct="new"; else _pct="$(pct "$_b" "$_delta")"; fi
    printf 'TOTAL:%s\t%s\t%s\t%s\t%s\t-\n' "$_area" "$_b" "$_a" "$_delta" "$_pct"
done < <(printf '%s' "$ROWS" | cut -f1 | sed 's#/.*##' | sort -u)

echo "prompt-size-report: $SINCE -> working tree: $nfiles file(s), net $total_delta byte(s), $flagged over the ${THRESHOLD}% flag (root: $ROOT)" >&2
exit 0
