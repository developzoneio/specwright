#!/usr/bin/env bash
# specwright: retro escalation-line validator (Unix / bash).
#
# Mirror of scripts/validate-escalation-lines.ps1 - both must accept and reject
# exactly the same lines. Like validate-lessons, this runs against a CONSUMER
# repo's spec tree: specwright itself has no .specs/, so here it only checks
# tests/retro-escalation/fixtures/.
#
#   bash scripts/validate-escalation-lines.sh [--spec-dir DIR] [FILE ...]
#
# FILEs are 05-retro.md files. --spec-dir DIR checks every DIR/*/05-retro.md.
# With neither, it checks .specs/*/05-retro.md under the current directory; a
# missing .specs/ is NOT an error (nothing has run yet), a missing explicit
# FILE or DIR is.
#
# The contract (skills/sd-model-escalation/SKILL.md, "Logging contract"):
#   escalation: <agent> <from> -> <to> (trigger: <rule-id>)
#   escalation: <agent> <from> -> <reached> (trigger: <rule-id>) capped
#   escalation: <agent> <from> -> <to> (trigger: <rule-id>) unapplied
# A line is an escalation line when, after an optional '- ' or '* ' bullet and
# an optional backtick, it starts with 'escalation:'. Each one must name a rule
# in specwright.manifest.json's contractLint.escalationTriggers, that rule's
# agent and from tier, alias-only tiers, and exactly the rule's one-rung to
# tier - or, for 'capped', a tier between from and the rule's to.
#
# This checks what the main thread SAID it did. It is not evidence of the model
# a subagent was served (docs/adr/0014-escalation-policy-lint.md).
#
# Exit 0 = every escalation line conforms; 1 = at least one violation or a
# missing explicit target; 2 = cannot run (no manifest, no jq, no rows).

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
manifest="$repo_root/specwright.manifest.json"

# Same patterns as the PowerShell twin. [^ ] not \S, [[:blank:]] not \s, so
# ERE and .NET agree. Held in variables and referenced unquoted inside
# [[ =~ ]] so the spaces need no escaping.
CANDIDATE_RE='^[[:blank:]]*([-*][[:blank:]]+)?`?(escalation:.*)$'
LINE_RE='^escalation: (sd-[a-z0-9-]+) ([^ ]+) -> ([^ ]+) \(trigger: ([^)]+)\)( capped| unapplied)?$'

if [[ -t 1 ]]; then
    c_reset=$'\033[0m'; c_cyan=$'\033[36m'; c_green=$'\033[32m'; c_red=$'\033[31m'
else
    c_reset=''; c_cyan=''; c_green=''; c_red=''
fi

section() { echo; echo "${c_cyan}=== $* ===${c_reset}"; }
ok()      { echo "  ${c_green}[OK]${c_reset}   $*"; }
fail()    { echo "  ${c_red}[FAIL]${c_reset} $*"; }

if ! command -v jq >/dev/null 2>&1; then
    echo "validate-escalation-lines: jq is required to read specwright.manifest.json" >&2
    exit 2
fi
if [[ ! -f "$manifest" ]]; then
    echo "validate-escalation-lines: manifest not found: $manifest" >&2
    exit 2
fi

# jq.exe on Windows can emit CRLF; a stray \r breaks every comparison.
mjq() { jq -r "$1" "$manifest" | tr -d '\r'; }

ROWS=""   # id \x1f agent \x1f from \x1f to
while IFS=$'\x1f' read -r _id _ag _fr _to; do
    [[ -z "$_id" ]] && continue
    ROWS="${ROWS}${_id}"$'\x1f'"${_ag}"$'\x1f'"${_fr}"$'\x1f'"${_to}"$'\n'
done < <(mjq '.contractLint.escalationTriggers[]? | "\(.id // "")\u001f\(.agent // "")\u001f\(.from // "")\u001f\(.to // "")"')
ALIASES=" $(mjq '.contractLint.escalationPolicy.aliases[]?' | tr '\n' ' ')"
LADDER="$(mjq '.contractLint.escalationPolicy.ladder[]?')"

if [[ -z "$ROWS" || -z "$LADDER" ]]; then
    echo "validate-escalation-lines: manifest declares no contractLint.escalationTriggers rows or no escalationPolicy.ladder" >&2
    exit 2
fi

ladder_index() { # alias -> stdout 0-based position, or -1
    local _t _n=0
    while IFS= read -r _t; do
        [[ -z "$_t" ]] && continue
        if [[ "$_t" == "$1" ]]; then echo "$_n"; return; fi
        _n=$((_n + 1))
    done <<< "$LADDER"
    echo "-1"
}

is_alias() { case "$ALIASES " in *" $1 "*) return 0 ;; esac; return 1; }

violations=0
lines_seen=0

report() {
    fail "$1:$2 : $3"
    violations=$((violations + 1))
}

# One verdict per line, first failure wins - the twin checks in the same order.
check_line() { # file lineno text
    local _f="$1" _n="$2" _t="$3" _agent _from _to _rule _suffix
    local _rid _rag _rfr _rto _found=0 _fi _ti _ri
    if ! [[ "$_t" =~ $LINE_RE ]]; then
        report "$_f" "$_n" "malformed escalation line - want 'escalation: <agent> <from> -> <to> (trigger: <rule-id>)' plus an optional ' capped' or ' unapplied'"
        return
    fi
    _agent="${BASH_REMATCH[1]}"; _from="${BASH_REMATCH[2]}"; _to="${BASH_REMATCH[3]}"
    _rule="${BASH_REMATCH[4]}"; _suffix="${BASH_REMATCH[5]# }"
    while IFS=$'\x1f' read -r _rid _rag _rfr _rto; do
        if [[ "$_rid" == "$_rule" ]]; then _found=1; break; fi
    done <<< "$ROWS"
    if [[ $_found -eq 0 ]]; then
        report "$_f" "$_n" "unknown rule '$_rule' - not in contractLint.escalationTriggers"
        return
    fi
    if [[ "$_agent" != "$_rag" ]]; then
        report "$_f" "$_n" "rule $_rule escalates '$_rag', not '$_agent'"
        return
    fi
    if ! is_alias "$_from"; then
        report "$_f" "$_n" "tier '$_from' is not a model alias"
        return
    fi
    if ! is_alias "$_to"; then
        report "$_f" "$_n" "tier '$_to' is not a model alias"
        return
    fi
    if [[ "$_from" != "$_rfr" ]]; then
        report "$_f" "$_n" "rule $_rule escalates from '$_rfr', not '$_from'"
        return
    fi
    if [[ "$_suffix" == "capped" ]]; then
        _fi="$(ladder_index "$_from")"; _ti="$(ladder_index "$_to")"; _ri="$(ladder_index "$_rto")"
        if [[ $_ti -lt 0 || $_ti -lt $_fi || $_ti -gt $_ri ]]; then
            report "$_f" "$_n" "capped tier '$_to' is outside $_from..$_rto, the range rule $_rule allows"
        fi
        return
    fi
    if [[ "$_to" != "$_rto" ]]; then
        report "$_f" "$_n" "rule $_rule escalates to '$_rto' (one rung), not '$_to'"
    fi
}

check_file() { # path display
    local _p="$1" _d="$2" _ln _n=0 _c
    while IFS= read -r _ln || [[ -n "$_ln" ]]; do
        _n=$((_n + 1))
        _ln="${_ln%$'\r'}"
        [[ "$_ln" =~ $CANDIDATE_RE ]] || continue
        _c="${BASH_REMATCH[2]}"
        _c="${_c%"${_c##*[![:blank:]]}"}"
        _c="${_c%\`}"
        _c="${_c%"${_c##*[![:blank:]]}"}"
        lines_seen=$((lines_seen + 1))
        check_line "$_d" "$_n" "$_c"
    done < "$_p"
}

# ---- targets ----------------------------------------------------------------

spec_dir=""
explicit=0
targets=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --spec-dir) spec_dir="${2:-}"; explicit=1; shift 2 ;;
        -h|--help)  grep -E '^# ' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          targets+=("$1"); explicit=1; shift ;;
    esac
done

section "specwright validate-escalation-lines"

if [[ $explicit -eq 0 ]]; then
    if [[ ! -d ".specs" ]]; then
        ok "no .specs/ in $(pwd) - nothing to validate"
        exit 0
    fi
    spec_dir=".specs"
fi

if [[ -n "$spec_dir" ]]; then
    if [[ ! -d "$spec_dir" ]]; then
        fail "spec directory not found: $spec_dir"
        exit 1
    fi
    while IFS= read -r _p; do
        [[ -n "$_p" ]] && targets+=("$_p")
    done < <(for _p in "$spec_dir"/*/05-retro.md; do [[ -f "$_p" ]] && printf '%s\n' "$_p"; done | LC_ALL=C sort)
fi

for t in "${targets[@]+"${targets[@]}"}"; do
    if [[ ! -f "$t" ]]; then
        fail "file not found: $t"
        exit 1
    fi
done

for t in "${targets[@]+"${targets[@]}"}"; do
    check_file "$t" "$t"
done

if [[ $violations -eq 0 ]]; then
    ok "$lines_seen escalation line(s) across ${#targets[@]} file(s): known rules, alias-only tiers, one rung"
    exit 0
else
    fail "$violations violation(s) across $lines_seen escalation line(s)"
    exit 1
fi
