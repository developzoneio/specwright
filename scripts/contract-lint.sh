#!/usr/bin/env bash
# Cross-file contract linter for the specwright ENGINE PRODUCT (Unix / bash).
#
# Twin of scripts/contract-lint.ps1. Both read specwright.manifest.json's
# `contractLint` subtree and MUST report the same rule ids, in the same order,
# for the same tree. Check 8 of scripts/validate.{sh,ps1} runs this as a child
# process; tests/contract-lint/run-selftest.ps1 runs both and diffs them.
#
# Where validate's Check 7 guards INVENTORY (how many files exist), this guards
# the RELATIONSHIPS between them: which agent a command invokes, which skill an
# agent loads, how many hard gates a workflow declares.
#
# Wave 1 rule bands (see the manifest's rules[] for the authoritative registry):
#   CL0xx  reference resolution
#   CL3xx  gate integrity
#   CL9xx  suppression hygiene
#
# Usage:
#   contract-lint.sh [--root <path>] [--rule <ids>] [--quiet]
#
#   --root   tree to lint (default: the repo this script lives in). The manifest
#            is read from <root>/specwright.manifest.json, which is what lets a
#            fixture tree configure itself.
#   --rule   comma-separated rule ids; filters the EMITTED findings only. Every
#            rule still runs, so CL902 (suppresses nothing) stays truthful.
#   --quiet  suppress the stderr summary line.
#
# Output is TSV on stdout, one finding per line, and nothing else:
#   <RULE>\t<SEVERITY>\t<FILE>\t<LINE>\t<MESSAGE>
# Paths are root-relative with forward slashes. Sort order is byte order on
# file, then numeric line, then rule id. The human-readable summary goes to
# stderr and is never parsed or compared.
#
# Exit codes:
#   0  no BLOCK findings
#   1  at least one BLOCK finding
#   2  cannot run (bad --root, missing manifest, missing jq, registry mismatch)
#
# Exit 2 is separate on purpose: a validator that cannot distinguish "clean"
# from "crashed" is worthless.

set -euo pipefail

# Byte-indexed string ops and byte-order sorting. The gate-marker strip below
# slices a leading run of non-ASCII BYTES; under a UTF-8 locale ${var:n} would
# slice characters instead and the two implementations would diverge.
export LC_ALL=C

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$script_dir/.." && pwd)"
RULE_FILTER=""
QUIET=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --root)  ROOT="${2:-}"; shift 2 ;;
        --rule)  RULE_FILTER="${2:-}"; shift 2 ;;
        --quiet) QUIET=1; shift ;;
        -h|--help)
            grep -E '^# ' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "contract-lint: unknown argument '$1'" >&2
            exit 2 ;;
    esac
done

if [[ -z "$ROOT" || ! -d "$ROOT" ]]; then
    echo "contract-lint: --root is not a directory: '$ROOT'" >&2
    exit 2
fi
ROOT="$(cd "$ROOT" && pwd)"

MANIFEST="$ROOT/specwright.manifest.json"
if [[ ! -f "$MANIFEST" ]]; then
    echo "contract-lint: manifest not found: $MANIFEST" >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    # Hooks exit 0 silently without jq so they never block a user on their own
    # bugs. A linter must do the opposite - a silent pass would turn CI green
    # while checking nothing.
    echo "contract-lint: jq is required to parse specwright.manifest.json" >&2
    exit 2
fi

# Some jq builds (notably jq.exe on Windows) emit CRLF. An unstripped \r rides
# on the last field of every record and silently breaks set membership.
mjq() { jq -r "$1" "$MANIFEST" | tr -d '\r'; }

# ---- bash 3.2 collections ---------------------------------------------------
#
# macOS ships /bin/bash 3.2: no `declare -A`, no `mapfile`, no `${var^^}`.
# Two shapes only:
#   * SETS - one newline-delimited global per set, membership-tested in-process
#     with `case` glob matching. No subshell, no loop, no eval.
#   * RECORD TABLES - one newline-delimited scalar of records whose fields are
#     separated by US (0x1f), iterated with `while IFS=$'\x1f' read ...`.
#     US, not TAB: TAB is an IFS *whitespace* character, so bash collapses runs
#     of them and one empty middle field shifts every later field left.
# Nothing here is looked up by key at O(1); the sets are small and the tables
# are walked, so a linear scan is the right shape.

set_has() { # set_var_name value -> 0 if present
    local _set="${!1}" _val="$2"
    case $'\n'"$_set"$'\n' in
        *$'\n'"$_val"$'\n'*) return 0 ;;
    esac
    return 1
}

set_add() { # set_var_name value
    local _cur="${!1}"
    if [[ -z "$_cur" ]]; then
        printf -v "$1" '%s' "$2"
    else
        printf -v "$1" '%s\n%s' "$_cur" "$2"
    fi
}

# CL1xx token sets: comma-joined, never newline-delimited (a mode's token set is
# small and always inline in one record-table field). "none" (the literal the
# Inputs (optional): line uses for an empty set) normalizes to the empty string.
normalize_tokens() { # raw "A, B, C" or "none" -> stdout "A,B,C"
    local _raw="$1"
    [[ "$_raw" == "none" ]] && return
    printf '%s' "$_raw" | tr -d ' \t'
}

csv_has() { # csv value -> 0 if present
    local _csv="$1" _val="$2"
    case ",$_csv," in
        *",$_val,"*) return 0 ;;
    esac
    return 1
}

# ERE-escape a hand-maintained vocabulary token before it is spliced into a
# built regex. A plain bash character loop, never sed: GNU sed's bracket
# expression treats a LEADING '.' right after '[' as the start of a
# '[.symbol.]' collating construct, not a literal dot, which silently
# corrupts the escape for '.NET' specifically. This loop has no such
# ambiguity, and - critically - callers must invoke it ONCE per token and
# cache the result: `$(ere_escape ...)` forks a subshell, and CL400/CL401
# test every token against every scanScope line, so calling it from inside
# that per-line loop turned a few dozen forks into ~135k and blew the
# runtime past two minutes on the Windows runner.
ere_escape() { # raw_token -> stdout ERE-escaped
    local _s="$1" _out="" _c _i
    for ((_i = 0; _i < ${#_s}; _i++)); do
        _c="${_s:_i:1}"
        case "$_c" in
            '.'|'\'|'*'|'^'|'$'|'['|']'|'('|')'|'+'|'?'|'{'|'}'|'|'|'/')
                _out="${_out}\\${_c}" ;;
            *)
                _out="${_out}${_c}" ;;
        esac
    done
    printf '%s' "$_out"
}

# ---- regex constants --------------------------------------------------------
#
# Every pattern below must behave identically in POSIX ERE (here) and .NET
# (the twin). Use [0-9] not \d, [[:blank:]] not \s, no lookarounds.

RE_FENCE='^[[:blank:]]*```'
RE_HEADING='^(#{2,3}) (.+)$'
RE_SDREF='sd-[a-z0-9]+(-[a-z0-9]+)*'
RE_CMDREF='/sd:[a-z][a-z0-9-]*'
RE_TPLPATH='templates/[A-Za-z0-9_./-]+'
# The leading boundary alternative is load-bearing: without it the pattern also
# matches '07-cqrs-read-path.md' inside the ADR filename '0007-cqrs-read-path.md'
# (agents/docs-writer.md), which is not a spec artifact at all.
RE_ARTIFACT='(^|[^0-9A-Za-z_.-])[0-9][0-9]-[a-z0-9-]+\.md'
# CL009 - a command's Phase 0 section: opens at '## Phase 0' (not 'Phase 01'),
# closes at the next H1/H2 heading outside a fence.
RE_PHASE0='^## Phase 0([^0-9]|$)'
RE_SECTION_END='^#{1,2}[[:blank:]]'
RE_SUPPRESS='<!--[[:blank:]]*contract-lint:[[:blank:]]*allow[[:blank:]]+CL[0-9][0-9][0-9]'
# An option set: a slash-separated parenthetical carrying no nested parens.
RE_OPTPAREN='\(([^()/]+/)+[^()]+\)'
RE_BULLETTOK='^-[[:blank:]]+`([^`]+)`'
# CL1xx invocation contract. A mode heading carries its selector as a backticked
# `KEY = value` pair (Mode N: `TASK = create`, `WORKFLOW_TYPE = feature`), except
# the reviewer/debugger `Task type: `value`` grammar, whose selector key is the
# established convention TASK_TYPE, never present in the heading text itself.
RE_KV='`([A-Z][A-Z0-9_]*) = ([^`]*)`'
RE_TASKTYPE='^Task type: `([a-z][a-z0-9-]*)`$'
RE_INPUT_REQ='^Inputs \(required\):[[:blank:]]*(.*)$'
RE_INPUT_OPT='^Inputs \(optional\):[[:blank:]]*(.*)$'
# The `Task type: `value`` heading grammar names no key of its own - reviewer.md
# reads it as TASK_TYPE, debugger.md as TASK. Both say so once, in prose, in
# their own "Always do first" section ("Read the `TASK_TYPE` field." /
# "Read the `TASK` field."), which is the only disambiguating signal on disk.
RE_FIELD_KEY='Read the `([A-Z][A-Z0-9_]*)` field'
# An invocation's token span runs from its anchor line to the next heading, the
# next anchor, or the next top-level numbered step - whichever comes first. The
# numbered-step boundary is load-bearing: without it, a span like
# 'Invoke ... with `TASK = plan`, ...' followed by unrelated prose two numbered
# steps later ('returns ... `STATUS = needs-input`', commands/feature.md) would
# read STATUS as a passed token that was never actually part of the invocation.
RE_NUMSTEP='^[[:blank:]]*[0-9]+\.[[:blank:]]'
# Byte range 0x80-0xFF in the C locale = any non-ASCII byte. Built at runtime so
# this file itself stays pure ASCII, exactly as scripts/validate.sh:45 does.
non_ascii_re="$(printf '[\200-\377]')"
# CL2xx role and tool integrity. tools: is a single comma-joined frontmatter
# line (never a nested list like skills:), so one capture group holds every
# declared tool name for a comma-split.
RE_TOOLSKEY='^tools:[[:blank:]]*(.*)$'
# An mcp__* token is always mcp__<server>__<tool>, and both segments may embed
# their own underscores/hyphens (mcp__sequential-thinking__sequentialthinking,
# mcp__context7__resolve-library-id), so the class below is intentionally wide
# and greedy - it stops at the first character that cannot be part of a tool
# name (backtick, comma, space, closing paren).
RE_MCPTOOL='mcp__[A-Za-z0-9_-]+'
# CL200's imperative-verb scan. Line-initial only (after an optional bullet or
# numbered-step marker) is load-bearing: it is what lets
# 'Do not attempt to write files' (negated), 'The calling command appends your
# output' (third-person subject) and 'write `_No findings._`' (mid-sentence,
# after a comma) all pass, with no exclusion list, the same way
# classify_heading needs none for '## Gate activity'.
RE_WRITEVERB='^[[:blank:]]*(-[[:blank:]]+|[0-9]+\.[[:blank:]]+)?(Write|Append|Create)[[:blank:]]'
# CL205's predicates. A spec artifact is a numbered NN-name.md file or the
# 04-artifacts/ folder. The write form is word-bounded by hand (ERE has no \b)
# and case-folded only on its first letter, never via a locale-aware lowercase,
# so both twins agree byte-for-byte on non-ASCII lines. The actor test is a
# 'main thread' mention - the phrase every sibling step already uses - matched
# against the whole enclosing numbered step joined with single spaces, never
# the one line: commands/port.md Phase 3 wraps 'Main' / 'thread appends ...'
# across two lines, and names the actor in step 3's opening parenthetical.
RE_SPECARTIFACT='[0-9]{2}-[a-z][a-z0-9-]*\.md|04-artifacts/'
RE_ARTIFACTWRITE='(^|[^A-Za-z])([Ww]rit(e|es|ing|ten)|[Aa]ppend(s|ed|ing)?|[Ss]av(e|es|ed|ing)|[Rr]ecord(s|ed|ing)?|[Pp]ersist(s|ed|ing)?|[Ss]tor(e|es|ed|ing))([^A-Za-z]|$)'
RE_MAINTHREAD='[Mm]ain[[:blank:]]+thread'
# CL4xx stack-agnostic prose. A <<...>> placeholder span is scrubbed from a
# copy of the line before vocabulary/path matching (via a bash glob
# substitution at the call site, never a per-line sed fork - see
# rule_CL400_CL401_CL402), so a token that only ever appears inside a
# project-config-style placeholder never fires.
# A hardcoded absolute path: the character immediately before the leading '/'
# or drive letter must be a genuine word boundary (blank, backtick, quote,
# paren, or start of line) - never another path/placeholder character.
# Without this POSITIVE boundary set, '~/.claude/hooks/sd/' and
# '.specs/<ID>/04-artifacts/' both mint a phantom absolute path starting at
# their OWN interior '/', which is not what CL402 means to catch.
RE_ABSPATH_POSIX='(^|[[:blank:]`"'\''(])(/[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]*)'
RE_ABSPATH_WIN='(^|[[:blank:]`"'\''(])([A-Za-z]:\\[^[:blank:]`]+)'

# ---- Phase A: index ---------------------------------------------------------

NS_SEGMENT="$(mjq '.contractLint.installNamespaceSegment // "sd"')"

RULE_IDS=""
RULE_SEVERITY_TABLE=""
while IFS=$'\x1f' read -r r_id r_sev; do
    [[ -z "$r_id" ]] && continue
    set_add RULE_IDS "$r_id"
    RULE_SEVERITY_TABLE="${RULE_SEVERITY_TABLE}${r_id}"$'\x1f'"${r_sev}"$'\n'
done < <(mjq '.contractLint.rules[] | "\(.id)\u001f\(.severity)"')

severity_of() { # rule_id -> stdout BLOCK|WARN
    local _id="$1" _r _s
    while IFS=$'\x1f' read -r _r _s; do
        if [[ "$_r" == "$_id" ]]; then printf '%s' "$_s"; return; fi
    done <<< "$RULE_SEVERITY_TABLE"
}

# Every rule this implementation dispatches, in registry order. The parity guard
# below asserts this equals the manifest registry, so a wave-2 rule cannot land
# in the manifest, the docs or the fixtures without landing here too.
DISPATCH_IDS="CL001
CL002
CL003
CL004
CL005
CL006
CL007
CL008
CL009
CL100
CL101
CL102
CL103
CL104
CL200
CL201
CL202
CL203
CL204
CL205
CL300
CL301
CL302
CL303
CL304
CL305
CL306
CL400
CL401
CL402
CL900
CL901
CL902"

parity_bad=0
while IFS= read -r _id; do
    [[ -z "$_id" ]] && continue
    if ! set_has RULE_IDS "$_id"; then
        echo "contract-lint: dispatched rule '$_id' is absent from manifest contractLint.rules" >&2
        parity_bad=1
    fi
done <<< "$DISPATCH_IDS"
while IFS= read -r _id; do
    [[ -z "$_id" ]] && continue
    if ! set_has DISPATCH_IDS "$_id"; then
        echo "contract-lint: manifest rule '$_id' is not dispatched by this implementation" >&2
        parity_bad=1
    fi
done <<< "$RULE_IDS"
if [[ $parity_bad -ne 0 ]]; then
    echo "contract-lint: registry parity guard failed" >&2
    exit 2
fi

SPEC_ARTIFACTS=""
while IFS= read -r _a; do
    [[ -n "$_a" ]] && set_add SPEC_ARTIFACTS "$_a"
done < <(mjq '.contractLint.specArtifacts[]?')

SKILL_CONSUMERS=""
while IFS= read -r _s; do
    [[ -n "$_s" ]] && set_add SKILL_CONSUMERS "$_s"
done < <(mjq '.contractLint.skillConsumers // {} | keys[]?')

OVERRIDE_TOKENS=""
while IFS= read -r _t; do
    [[ -n "$_t" ]] && set_add OVERRIDE_TOKENS "$_t"
done < <(mjq '.contractLint.overrideOptionTokens[]?')

GATE_PROSE_ESCAPE_TOKENS=""
while IFS= read -r _t; do
    [[ -n "$_t" ]] && set_add GATE_PROSE_ESCAPE_TOKENS "$_t"
done < <(mjq '.contractLint.gateProseEscapeTokens[]?')

BOOTSTRAP_GUARD_PHRASES=""
while IFS= read -r _t; do
    [[ -n "$_t" ]] && set_add BOOTSTRAP_GUARD_PHRASES "$_t"
done < <(mjq '.contractLint.bootstrapGuardPhrases[]?')

STACK_COMMANDS=""
while IFS= read -r _t; do
    [[ -n "$_t" ]] && set_add STACK_COMMANDS "$_t"
done < <(mjq '.contractLint.stackTokens.commands[]?')

STACK_LANGUAGES=""
while IFS= read -r _t; do
    [[ -n "$_t" ]] && set_add STACK_LANGUAGES "$_t"
done < <(mjq '.contractLint.stackTokens.languages[]?')

# Pre-compiled ONCE here, never inside the per-line rule loop - see
# ere_escape's own comment for why that distinction is load-bearing.
# tok \x1f pattern, newline-delimited - the per-token detail used ONLY to
# name which token matched, on the rare line the COMBINED regex below hits.
STACK_CMD_PATTERNS=""
STACK_CMD_ALT=""
while IFS= read -r _t; do
    [[ -z "$_t" ]] && continue
    _esc="$(ere_escape "$_t")"
    STACK_CMD_PATTERNS="${STACK_CMD_PATTERNS}${_t}"$'\x1f'"(^|[^A-Za-z0-9_])${_esc}([^A-Za-z0-9_]|\$)"$'\n'
    [[ -n "$STACK_CMD_ALT" ]] && STACK_CMD_ALT="${STACK_CMD_ALT}|"
    STACK_CMD_ALT="${STACK_CMD_ALT}${_esc}"
done <<< "$STACK_COMMANDS"
# One alternation, tested ONCE per line - the common (no-hit) case pays for a
# single regex match instead of one per vocabulary entry. A ~5k-line scan
# tested per-token per-line (28 entries) took 1m50s on the Windows runner;
# this collapses that to one test, only falling back to STACK_CMD_PATTERNS
# to name the specific token on the rare line that actually matches.
STACK_CMD_COMBINED=""
[[ -n "$STACK_CMD_ALT" ]] && STACK_CMD_COMBINED="(^|[^A-Za-z0-9_])(${STACK_CMD_ALT})([^A-Za-z0-9_]|\$)"

STACK_LANG_PATTERNS=""
STACK_LANG_ALT=""
while IFS= read -r _t; do
    [[ -z "$_t" ]] && continue
    _esc="$(ere_escape "$_t")"
    STACK_LANG_PATTERNS="${STACK_LANG_PATTERNS}${_t}"$'\x1f'"(^|[^A-Za-z0-9_])${_esc}([^A-Za-z0-9_]|\$)"$'\n'
    [[ -n "$STACK_LANG_ALT" ]] && STACK_LANG_ALT="${STACK_LANG_ALT}|"
    STACK_LANG_ALT="${STACK_LANG_ALT}${_esc}"
done <<< "$STACK_LANGUAGES"
STACK_LANG_COMBINED=""
[[ -n "$STACK_LANG_ALT" ]] && STACK_LANG_COMBINED="(^|[^A-Za-z0-9_])(${STACK_LANG_ALT})([^A-Za-z0-9_]|\$)"

READONLY_AGENTS=""
while IFS= read -r _a; do
    [[ -n "$_a" ]] && set_add READONLY_AGENTS "$_a"
done < <(mjq '.contractLint.readOnlyAgents[]?')

KNOWN_MCP_TOOLS=""
while IFS= read -r _t; do
    [[ -n "$_t" ]] && set_add KNOWN_MCP_TOOLS "$_t"
done < <(mjq '.contractLint.knownMcpTools[]?')

# Write/Edit/MultiEdit, and nothing else - matches docs/architecture.md's own
# definition of a read-only agent. Bash CAN write a file, but that is a
# different, harder problem, deliberately out of scope for CL200/CL201.
is_write_tool() { # tool_name -> 0 if it is one of Write/Edit/MultiEdit
    case "$1" in
        Write|Edit|MultiEdit) return 0 ;;
    esac
    return 1
}

# gates: file <TAB> hard <TAB> conditional-labels-joined-by-comma
GATE_DECL_TABLE=""
GATE_DECL_FILES=""
while IFS=$'\x1f' read -r g_file g_hard g_cond; do
    [[ -z "$g_file" ]] && continue
    if [[ ! -f "$ROOT/$g_file" ]]; then
        echo "contract-lint: contractLint.gates names a file that does not exist: $g_file" >&2
        exit 2
    fi
    GATE_DECL_TABLE="${GATE_DECL_TABLE}${g_file}"$'\x1f'"${g_hard}"$'\x1f'"${g_cond}"$'\n'
    set_add GATE_DECL_FILES "$g_file"
done < <(mjq '.contractLint.gates // {} | to_entries[] | "\(.key)\u001f\(.value.hard)\u001f\(.value.conditional | join(","))"')

# Scan files: every scanScope glob, deduplicated, byte-sorted for a stable
# report order that the twin can reproduce exactly.
SCAN_FILES=""
shopt -s nullglob
while IFS= read -r _glob; do
    [[ -z "$_glob" ]] && continue
    for _p in "$ROOT"/$_glob; do
        [[ -f "$_p" ]] || continue
        set_add SCAN_FILES "${_p#"$ROOT"/}"
    done
done < <(mjq '.contractLint.scanScope[]')
shopt -u nullglob
SCAN_FILES="$(printf '%s\n' "$SCAN_FILES" | grep -v '^$' | sort -u || true)"

if [[ -z "$SCAN_FILES" ]]; then
    echo "contract-lint: contractLint.scanScope matched no files under $ROOT" >&2
    exit 2
fi

# ---- finding + suppression stores ------------------------------------------
#
# Defined before the disk-derived inventory below because CL104 (duplicate
# agent frontmatter name) is detected while that inventory is built, not in
# Phase B - the same precedent CL900/CL901 set for the suppression index.

F_N=0
f_rule=(); f_file=(); f_line=(); f_msg=()

add_finding() { # rule file line message
    f_rule[$F_N]="$1"
    f_file[$F_N]="$2"
    f_line[$F_N]="$3"
    # Sanitised at emit-time source, not at print-time: a tab or CR inside a
    # message silently corrupts the consumer's `IFS=$'\t' read`.
    f_msg[$F_N]="$(printf '%s' "$4" | tr -d '\r\t')"
    F_N=$((F_N + 1))
}

S_N=0
s_file=(); s_line=(); s_rule=(); s_used=(); s_bad=()

# ---- disk-derived inventory -------------------------------------------------
#
# Agents, skills and commands come from disk, never from the manifest - they are
# inventory, and the manifest's charter says inventory is derived.
AGENT_NAMES=""
AGENT_NAME_FILE_TABLE=""
shopt -s nullglob
for _p in "$ROOT"/agents/*.md; do
    _rel="${_p#"$ROOT"/}"
    _name="$(sed -n '1,20{s/^name:[[:space:]]*//p;}' "$_p" | head -n1 | tr -d '\r')"
    [[ -z "$_name" ]] && continue
    if set_has AGENT_NAMES "$_name"; then
        _nameln="$(sed -n '1,20{/^name:/=;}' "$_p" | head -n1)"
        _origfile=""
        while IFS=$'\x1f' read -r _oa _of; do
            [[ "$_oa" == "$_name" ]] && _origfile="$_of"
        done <<< "$AGENT_NAME_FILE_TABLE"
        add_finding CL104 "$_rel" "$_nameln" "agent name '$_name' is also declared by $_origfile"
        continue
    fi
    set_add AGENT_NAMES "$_name"
    AGENT_NAME_FILE_TABLE="${AGENT_NAME_FILE_TABLE}${_name}"$'\x1f'"${_rel}"$'\n'
done

SKILL_NAMES=""
SKILL_NAME_FILE_TABLE=""
for _p in "$ROOT"/skills/*/SKILL.md; do
    _rel="${_p#"$ROOT"/}"
    _dir="${_rel#skills/}"
    _dir="${_dir%/SKILL.md}"
    set_add SKILL_NAMES "$_dir"
    SKILL_NAME_FILE_TABLE="${SKILL_NAME_FILE_TABLE}${_dir}"$'\x1f'"${_rel}"$'\n'
done

COMMAND_NAMES=""
for _p in "$ROOT"/commands/*.md; do
    _rel="${_p#"$ROOT"/}"
    _base="${_rel#commands/}"
    set_add COMMAND_NAMES "${_base%.md}"
done
shopt -u nullglob

# ---- per-file line + fence cache -------------------------------------------
#
# One disk pass. Rules read these caches; none re-walks the tree.
#   FILE_LINES_<n> / FILE_FENCE_<n> are held per file inside load_file, which
#   every rule loop calls in the same byte-sorted order.

CUR_LINES=(); CUR_FENCE=(); CUR_N=0; CUR_REL=""

load_file() { # relative_path
    local _rel="$1" _abs="$ROOT/$1" _ln _i _in=0
    CUR_REL="$_rel"
    CUR_LINES=(); CUR_FENCE=(); CUR_N=0
    # Read raw and strip a trailing CR per line. .gitattributes does NOT pin
    # *.md to LF, so on a Windows checkout every file here is CRLF on disk.
    while IFS= read -r _ln || [[ -n "$_ln" ]]; do
        CUR_LINES[$CUR_N]="${_ln%$'\r'}"
        CUR_N=$((CUR_N + 1))
    done < "$_abs"
    for ((_i = 0; _i < CUR_N; _i++)); do
        if [[ "${CUR_LINES[$_i]}" =~ $RE_FENCE ]]; then
            CUR_FENCE[$_i]=1
            if [[ $_in -eq 0 ]]; then _in=1; else _in=0; fi
        else
            CUR_FENCE[$_i]=$_in
        fi
    done
}

# ---- reference index --------------------------------------------------------
#
# A flat (kind, target, file, line) table. EVERY CL0xx rule reads this table and
# none of them re-walks the disk, so a wave-2 rule means adding one kind to one
# extractor rather than a second traversal.

REFS=""   # kind \t target \t file \t line

collect_refs() {
    local _rel _lno _raw _tok _pat _kind
    while IFS= read -r _rel; do
        [[ -z "$_rel" ]] && continue
        load_file "$_rel"
        for _pat in "sdref:$RE_SDREF" "commandRef:$RE_CMDREF" \
                    "templatePath:$RE_TPLPATH" "specArtifact:$RE_ARTIFACT" \
                    "mcpTool:$RE_MCPTOOL"; do
            _kind="${_pat%%:*}"
            # grep -o once per (file, pattern) - 4 forks per file, never one per
            # line. A subshell inside a per-line loop is ~12k forks on this tree
            # and turns a 1s check into 40s on the Windows runner.
            while IFS= read -r _raw; do
                [[ -z "$_raw" ]] && continue
                _lno="${_raw%%:*}"
                _tok="${_raw#*:}"
                # grep line numbers are 1-based; the fence cache is 0-based.
                [[ "${CUR_FENCE[$((_lno - 1))]}" == "1" ]] && continue
                if [[ "$_kind" == "specArtifact" ]]; then
                    # Drop the boundary character the pattern had to consume.
                    case "$_tok" in
                        [0-9]*) : ;;
                        *) _tok="${_tok:1}" ;;
                    esac
                fi
                REFS="${REFS}${_kind}"$'\x1f'"${_tok}"$'\x1f'"${_rel}"$'\x1f'"${_lno}"$'\n'
            done < <(grep -onE "${_pat#*:}" "$ROOT/$_rel" || true)
        done
    done <<< "$SCAN_FILES"
}

collect_refs

# ---- agent `skills:` frontmatter index -------------------------------------

AGENT_SKILL_REFS=""   # agent_file \t line \t skill_name

collect_agent_skills() {
    local _rel _i _line _in_fm=0 _in_skills=0 _entry
    shopt -s nullglob
    for _p in "$ROOT"/agents/*.md; do
        _rel="${_p#"$ROOT"/}"
        load_file "$_rel"
        _in_fm=0; _in_skills=0
        for ((_i = 0; _i < CUR_N; _i++)); do
            _line="${CUR_LINES[$_i]}"
            if [[ "$_line" == "---" ]]; then
                if [[ $_in_fm -eq 0 ]]; then _in_fm=1; continue; else break; fi
            fi
            [[ $_in_fm -eq 1 ]] || continue
            if [[ "$_line" =~ ^skills:[[:blank:]]*$ ]]; then
                _in_skills=1
                continue
            fi
            if [[ $_in_skills -eq 1 ]]; then
                if [[ "$_line" =~ ^[[:blank:]]+-[[:blank:]]+(.+)$ ]]; then
                    _entry="${BASH_REMATCH[1]}"
                    AGENT_SKILL_REFS="${AGENT_SKILL_REFS}${_rel}"$'\x1f'"$((_i + 1))"$'\x1f'"${_entry}"$'\n'
                    continue
                fi
                _in_skills=0
            fi
        done
    done
    shopt -u nullglob
}

collect_agent_skills

# ---- agent `tools:` frontmatter index (CL2xx) ------------------------------
#
# tools: is one comma-joined line, never a nested list like skills:, so this is
# one line lookup per agent rather than a multi-line list walk.

AGENT_TOOL_REFS=""     # agent \x1f tool \x1f file \x1f line
# agent \x1f 1-based first body line (line right after the closing ---), so
# CL203 can search the agent's BODY for a tool mention without a frontmatter
# field (e.g. description:) counting as "the body uses it".
AGENT_BODY_START=""

collect_agent_tools() {
    local _name _file _i _line _in_fm=0 _body_start _tool _rest
    while IFS=$'\x1f' read -r _name _file; do
        [[ -z "$_name" ]] && continue
        load_file "$_file"
        _in_fm=0
        _body_start=$((CUR_N + 1))
        for ((_i = 0; _i < CUR_N; _i++)); do
            _line="${CUR_LINES[$_i]}"
            if [[ "$_line" == "---" ]]; then
                if [[ $_in_fm -eq 0 ]]; then _in_fm=1; continue; else
                    _body_start=$((_i + 2)); break
                fi
            fi
            [[ $_in_fm -eq 1 ]] || continue
            if [[ "$_line" =~ $RE_TOOLSKEY ]]; then
                _rest="${BASH_REMATCH[1]}"
                while IFS= read -r _tool; do
                    # Tool names never carry internal whitespace, so a blanket
                    # strip is safe here - the same technique normalize_tokens
                    # already uses for CL1xx's required/optional CSV pieces.
                    _tool="$(printf '%s' "$_tool" | tr -d ' \t')"
                    [[ -z "$_tool" ]] && continue
                    AGENT_TOOL_REFS="${AGENT_TOOL_REFS}${_name}"$'\x1f'"${_tool}"$'\x1f'"${_file}"$'\x1f'"$((_i + 1))"$'\n'
                done <<< "$(printf '%s' "$_rest" | tr ',' '\n')"
            fi
        done
        AGENT_BODY_START="${AGENT_BODY_START}${_name}"$'\x1f'"${_body_start}"$'\n'
    done <<< "$AGENT_NAME_FILE_TABLE"
}

collect_agent_tools

# WRITE_CAPABLE_AGENTS - derived from disk (AGENT_TOOL_REFS), not declared.
# Mirrors how CL200 itself decides write-capability: an agent whose own
# tools: line carries Write/Edit/MultiEdit right now, regardless of whether
# anyone remembers to list it anywhere. Used by CL203/CL204 to pick severity.
WRITE_CAPABLE_AGENTS=""
while IFS=$'\x1f' read -r _wca _wct _wcf _wcl; do
    [[ -z "$_wca" ]] && continue
    is_write_tool "$_wct" || continue
    set_add WRITE_CAPABLE_AGENTS "$_wca"
done <<< "$AGENT_TOOL_REFS"

body_start_of() { # agent_name -> stdout 1-based first body line
    local _n="$1" _an _al
    while IFS=$'\x1f' read -r _an _al; do
        [[ "$_an" == "$_n" ]] && { printf '%s' "$_al"; return; }
    done <<< "$AGENT_BODY_START"
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

MODE_DECLS=""   # agent \x1f key \x1f value \x1f file \x1f line \x1f requiredCsv \x1f optionalCsv

collect_mode_decls() {
    local _name _file _i _j _limit _headtext _key _value _reqidx _reqraw _optraw
    local _defaultkey
    while IFS=$'\x1f' read -r _name _file; do
        [[ -z "$_name" ]] && continue
        load_file "$_file"
        _defaultkey="TASK_TYPE"
        for ((_i = 0; _i < CUR_N; _i++)); do
            [[ "${CUR_FENCE[$_i]}" == "1" ]] && continue
            if [[ "${CUR_LINES[$_i]}" =~ $RE_FIELD_KEY ]]; then
                _defaultkey="${BASH_REMATCH[1]}"; break
            fi
        done
        for ((_i = 0; _i < CUR_N; _i++)); do
            [[ "${CUR_FENCE[$_i]}" == "1" ]] && continue
            [[ "${CUR_LINES[$_i]}" =~ $RE_HEADING ]] || continue
            _headtext="${BASH_REMATCH[2]}"
            _key=""; _value=""
            if [[ "$_headtext" =~ $RE_KV ]]; then
                _key="${BASH_REMATCH[1]}"; _value="${BASH_REMATCH[2]}"
            elif [[ "$_headtext" =~ $RE_TASKTYPE ]]; then
                _key="$_defaultkey"; _value="${BASH_REMATCH[1]}"
            else
                continue
            fi
            _reqidx=-1
            _limit=$((_i + 3))
            [[ $_limit -ge $CUR_N ]] && _limit=$((CUR_N - 1))
            for ((_j = _i + 1; _j <= _limit; _j++)); do
                [[ "${CUR_FENCE[$_j]}" == "1" ]] && continue
                if [[ "${CUR_LINES[$_j]}" =~ $RE_INPUT_REQ ]]; then
                    _reqidx=$_j; _reqraw="${BASH_REMATCH[1]}"; break
                fi
            done
            [[ $_reqidx -lt 0 ]] && continue
            (( _reqidx + 1 >= CUR_N )) && continue
            [[ "${CUR_FENCE[$((_reqidx + 1))]}" == "1" ]] && continue
            [[ "${CUR_LINES[$((_reqidx + 1))]}" =~ $RE_INPUT_OPT ]] || continue
            _optraw="${BASH_REMATCH[1]}"
            MODE_DECLS="${MODE_DECLS}${_name}"$'\x1f'"${_key}"$'\x1f'"${_value}"$'\x1f'"${_file}"$'\x1f'"$((_i + 1))"$'\x1f'"$(normalize_tokens "$_reqraw")"$'\x1f'"$(normalize_tokens "$_optraw")"$'\n'
        done
    done <<< "$AGENT_NAME_FILE_TABLE"
}

collect_mode_decls

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

ANCHOR_LINES=""     # SET of "file:line"
ANCHORS=""          # agent \x1f file \x1f line

collect_anchors() {
    local _k _t _f _l
    while IFS=$'\x1f' read -r _k _t _f _l; do
        [[ "$_k" == "sdref" ]] || continue
        case "$_f" in commands/*) ;; *) continue ;; esac
        if [[ "$CUR_REL" != "$_f" ]]; then load_file "$_f"; fi
        case "${CUR_LINES[$((_l - 1))]}" in
            *nvoke*) ;;
            *) continue ;;
        esac
        ANCHORS="${ANCHORS}${_t}"$'\x1f'"${_f}"$'\x1f'"${_l}"$'\n'
        set_add ANCHOR_LINES "${_f}:${_l}"
    done <<< "$REFS"
}

collect_anchors

INVOCATIONS=""   # agent \x1f key \x1f value \x1f file \x1f line \x1f tokensCsv

collect_invocations() {
    local _agent _file _line _start _j _tokens _modekey _modeval _k _v _m
    while IFS=$'\x1f' read -r _agent _file _line; do
        [[ -z "$_agent" ]] && continue
        if [[ "$CUR_REL" != "$_file" ]]; then load_file "$_file"; fi
        _tokens=""
        _modekey=""; _modeval=""
        _start=$((_line - 1))
        for ((_j = _start; _j < CUR_N; _j++)); do
            [[ "${CUR_FENCE[$_j]}" == "1" ]] && continue
            if [[ $_j -gt $_start ]]; then
                [[ "${CUR_LINES[$_j]}" =~ $RE_HEADING ]] && break
                [[ "${CUR_LINES[$_j]}" =~ $RE_NUMSTEP ]] && break
                set_has ANCHOR_LINES "${_file}:$((_j + 1))" && break
            fi
            _m="${CUR_LINES[$_j]}"
            while [[ "$_m" =~ $RE_KV ]]; do
                _k="${BASH_REMATCH[1]}"; _v="${BASH_REMATCH[2]}"
                if ! csv_has "$_tokens" "$_k"; then
                    if [[ -z "$_tokens" ]]; then _tokens="$_k"; else _tokens="${_tokens},${_k}"; fi
                fi
                if [[ -z "$_modekey" ]]; then
                    case "$_k" in
                        TASK|WORKFLOW_TYPE|TASK_TYPE) _modekey="$_k"; _modeval="$_v" ;;
                    esac
                fi
                _m="${_m/"${BASH_REMATCH[0]}"/}"
            done
        done
        [[ -z "$_modekey" ]] && continue
        INVOCATIONS="${INVOCATIONS}${_agent}"$'\x1f'"${_modekey}"$'\x1f'"${_modeval}"$'\x1f'"${_file}"$'\x1f'"${_line}"$'\x1f'"${_tokens}"$'\n'
    done <<< "$ANCHORS"
}

collect_invocations

# ---- gate index -------------------------------------------------------------
#
# A gate BLOCK is [heading line, next heading of any level or EOF). That window
# is the whole reason CL300 does not fire on the ~20 literal STOPs in Phase 0
# bootstrap error paths - they all sit under a '## Phase 0' heading, never
# inside a gate block.

GATES=""   # file \t line \t kind(hard|conditional) \t label \t isHard(0|1) \t blockEnd

# Strip the leading non-ASCII marker run, then an optional 'Phase N - ' prefix,
# and report whether the remainder names a gate. Sets GATE_KIND / GATE_LABEL.
classify_heading() { # heading_title -> 0 if a gate
    local _t="$1" _rest
    GATE_KIND=""; GATE_LABEL=""
    # Peel bytes, never encode the marker: contract-lint.ps1 must stay pure
    # ASCII and the twin peels UTF-16 chars over the same run. Both land on the
    # identical ASCII remainder, and nothing downstream reports a column offset.
    while [[ -n "$_t" && "${_t:0:1}" =~ $non_ascii_re ]]; do
        _t="${_t:1}"
    done
    while [[ "${_t:0:1}" == " " ]]; do _t="${_t:1}"; done
    if [[ "$_t" =~ ^Phase[[:blank:]]+[0-9]+[[:blank:]]+-[[:blank:]]+(.*)$ ]]; then
        _t="${BASH_REMATCH[1]}"
    fi
    case "$_t" in
        Gate*) _rest="${_t#Gate}" ;;
        *) return 1 ;;
    esac
    if [[ "$_rest" =~ ^\ ([0-9]+)([[:blank:]].*)?$ ]]; then
        GATE_KIND="hard"; GATE_LABEL="${BASH_REMATCH[1]}"; return 0
    fi
    if [[ "$_rest" =~ ^\ ([0-9]+[a-z])([[:blank:]].*)?$ ]]; then
        GATE_KIND="conditional"; GATE_LABEL="${BASH_REMATCH[1]}"; return 0
    fi
    if [[ "$_rest" =~ ^\ (Re-plan)([^A-Za-z0-9].*)?$ ]]; then
        GATE_KIND="conditional"; GATE_LABEL="Re-plan"; return 0
    fi
    if [[ "$_rest" =~ ^\ ?[-\(\[] ]]; then
        GATE_KIND="hard"; GATE_LABEL=""; return 0
    fi
    # Anything else is not a gate. This single row is the entire false-positive
    # defence and it needs no exclusion list: 'Gate' followed by a lowercase
    # word ('## Gate activity' in commands/status.md) is never a gate heading.
    return 1
}

collect_gates() {
    local _rel _i _j _line _title _end _hard
    while IFS= read -r _rel; do
        [[ -z "$_rel" ]] && continue
        load_file "$_rel"
        for ((_i = 0; _i < CUR_N; _i++)); do
            [[ "${CUR_FENCE[$_i]}" == "1" ]] && continue
            _line="${CUR_LINES[$_i]}"
            [[ "$_line" =~ $RE_HEADING ]] || continue
            _title="${BASH_REMATCH[2]}"
            classify_heading "$_title" || continue
            _end=$CUR_N
            for ((_j = _i + 1; _j < CUR_N; _j++)); do
                if [[ "${CUR_FENCE[$_j]}" != "1" && "${CUR_LINES[$_j]}" =~ ^#{1,6}[[:blank:]] ]]; then
                    _end=$_j; break
                fi
            done
            _hard=0
            case "$_line" in
                *'(HARD)'*|*'[HARD]'*) _hard=1 ;;
            esac
            GATES="${GATES}${_rel}"$'\x1f'"$((_i + 1))"$'\x1f'"${GATE_KIND}"$'\x1f'"${GATE_LABEL}"$'\x1f'"${_hard}"$'\x1f'"${_end}"$'\n'
        done
    done <<< "$SCAN_FILES"
}

collect_gates

# ---- suppression index ------------------------------------------------------
#
# Indexed ONLY inside scanScope and ONLY outside fenced code blocks, so
# docs/contract-lint.md and CONTRIBUTING.md can show the syntax without minting
# a phantom suppression that then trips CL902.

collect_suppressions() {
    local _rel _i _line _rule _reason _bare
    while IFS= read -r _rel; do
        [[ -z "$_rel" ]] && continue
        load_file "$_rel"
        for ((_i = 0; _i < CUR_N; _i++)); do
            [[ "${CUR_FENCE[$_i]}" == "1" ]] && continue
            _line="${CUR_LINES[$_i]}"
            [[ "$_line" =~ $RE_SUPPRESS ]] || continue
            [[ "$_line" =~ allow[[:blank:]]+(CL[0-9][0-9][0-9])(.*)$ ]] || continue
            _rule="${BASH_REMATCH[1]}"
            _reason="${BASH_REMATCH[2]}"
            _reason="${_reason%%-->*}"
            # Strip a leading separator, then measure the non-space payload.
            _bare="$(printf '%s' "$_reason" | tr -d ' \t-')"
            s_file[$S_N]="$_rel"
            s_line[$S_N]=$((_i + 1))
            s_rule[$S_N]="$_rule"
            s_used[$S_N]=0
            s_bad[$S_N]=0
            if ! set_has RULE_IDS "$_rule"; then
                s_bad[$S_N]=1
                add_finding CL901 "$_rel" "$((_i + 1))" "suppression names unknown rule '$_rule'"
            elif [[ ${#_bare} -lt 10 ]]; then
                add_finding CL900 "$_rel" "$((_i + 1))" "suppression for $_rule carries no usable reason"
            fi
            S_N=$((S_N + 1))
        done
    done <<< "$SCAN_FILES"
}

collect_suppressions

# ---- Phase B: rules ---------------------------------------------------------
#
# Each rule takes no arguments, reads the index, and calls add_finding. SEVERITY
# IS NEVER PASSED BY A RULE - it is looked up from the manifest at emit time, so
# a BLOCK/WARN divergence between the twins is structurally impossible.

line_text() { # file line -> stdout (1-based)
    local _rel="$1" _n="$2"
    if [[ "$CUR_REL" != "$_rel" ]]; then load_file "$_rel"; fi
    printf '%s' "${CUR_LINES[$((_n - 1))]}"
}

# True when (file, line) is an entry in an agent's `skills:` frontmatter list.
# CL002 owns those lines; without this both CL001 and CL002 would fire on the
# same missing skill, which is one problem reported twice - the same "one error,
# not two" doctrine that exempts a CL901 suppression from CL902.
is_agent_skill_entry() { # file line
    local _f="$1" _l="$2" _af _al _as
    while IFS=$'\x1f' read -r _af _al _as; do
        if [[ "$_af" == "$_f" && "$_al" == "$_l" ]]; then return 0; fi
    done <<< "$AGENT_SKILL_REFS"
    return 1
}

rule_CL001_CL003() {
    local _k _t _f _l _txt _lower
    while IFS=$'\x1f' read -r _k _t _f _l; do
        [[ "$_k" == "sdref" ]] || continue
        set_has AGENT_NAMES "$_t" && continue
        set_has SKILL_NAMES "$_t" && continue
        is_agent_skill_entry "$_f" "$_l" && continue
        _txt="$(line_text "$_f" "$_l")"
        _lower="$(printf '%s' "$_txt" | tr 'A-Z' 'a-z')"
        case "$_lower" in
            *skill*)
                add_finding CL003 "$_f" "$_l" "unresolved skill reference '$_t'" ;;
            *)
                add_finding CL001 "$_f" "$_l" "unresolved sd- reference '$_t'" ;;
        esac
    done <<< "$REFS"
}

rule_CL002() {
    local _f _l _s
    while IFS=$'\x1f' read -r _f _l _s; do
        [[ -z "$_f" ]] && continue
        [[ -f "$ROOT/skills/$_s/SKILL.md" ]] && continue
        add_finding CL002 "$_f" "$_l" "skills: entry '$_s' has no skills/$_s/SKILL.md"
    done <<< "$AGENT_SKILL_REFS"
}

rule_CL004() {
    local _s _self _k _t _f _l _referenced _af _al _as
    while IFS=$'\x1f' read -r _s _self; do
        [[ -z "$_s" ]] && continue
        set_has SKILL_CONSUMERS "$_s" && continue
        _referenced=0
        while IFS=$'\x1f' read -r _k _t _f _l; do
            [[ "$_k" == "sdref" ]] || continue
            [[ "$_t" == "$_s" ]] || continue
            [[ "$_f" == "$_self" ]] && continue
            _referenced=1; break
        done <<< "$REFS"
        if [[ $_referenced -eq 0 ]]; then
            while IFS=$'\x1f' read -r _af _al _as; do
                if [[ "$_as" == "$_s" ]]; then _referenced=1; break; fi
            done <<< "$AGENT_SKILL_REFS"
        fi
        if [[ $_referenced -eq 0 ]]; then
            add_finding CL004 "$_self" 1 "skill '$_s' is referenced by nothing in scan scope"
        fi
    done <<< "$SKILL_NAME_FILE_TABLE"
}

rule_CL005() {
    local _k _t _f _l _p
    while IFS=$'\x1f' read -r _k _t _f _l; do
        [[ "$_k" == "templatePath" ]] || continue
        _p="$_t"
        # templates/<ns>/... is the INSTALL target (~/.claude/templates/sd/),
        # not a repo path. Fold the namespace segment away before testing disk.
        case "$_p" in
            "templates/$NS_SEGMENT/"*) _p="templates/${_p#"templates/$NS_SEGMENT/"}" ;;
            "templates/$NS_SEGMENT") _p="templates" ;;
        esac
        _p="${_p%.}"
        _p="${_p%/}"
        [[ -e "$ROOT/$_p" ]] && continue
        add_finding CL005 "$_f" "$_l" "templates path does not exist: '$_t'"
    done <<< "$REFS"
}

rule_CL006() {
    local _k _t _f _l _name
    while IFS=$'\x1f' read -r _k _t _f _l; do
        [[ "$_k" == "commandRef" ]] || continue
        _name="${_t#/sd:}"
        set_has COMMAND_NAMES "$_name" && continue
        add_finding CL006 "$_f" "$_l" "no command file for '$_t'"
    done <<< "$REFS"
}

rule_CL007() {
    local _a _af _k _t _f _l _seen
    while IFS=$'\x1f' read -r _a _af; do
        [[ -z "$_a" ]] && continue
        _seen=0
        while IFS=$'\x1f' read -r _k _t _f _l; do
            [[ "$_k" == "sdref" ]] || continue
            [[ "$_t" == "$_a" ]] || continue
            case "$_f" in commands/*) _seen=1; break ;; esac
        done <<< "$REFS"
        if [[ $_seen -eq 0 ]]; then
            add_finding CL007 "$_af" 1 "agent '$_a' is invoked by no command"
        fi
    done <<< "$AGENT_NAME_FILE_TABLE"
}

rule_CL008() {
    local _k _t _f _l
    while IFS=$'\x1f' read -r _k _t _f _l; do
        [[ "$_k" == "specArtifact" ]] || continue
        set_has SPEC_ARTIFACTS "$_t" && continue
        add_finding CL008 "$_f" "$_l" "unknown spec artifact filename '$_t'"
    done <<< "$REFS"
}

# CL009 - a command's '## Phase 0' section restates text sd-bootstrap-guard
# owns. Commands cannot load skills via frontmatter, so they read the skill at
# runtime; a copy of its messages in Phase 0 is the drift SW-54 removed. A
# phrase wrapped across two lines is caught by joining each line with the
# next (trimmed, one space) - reported on the line where it starts, and only
# when the next line alone does not already carry it, so one occurrence is one
# finding. Case-sensitive literal match, the same as CL306. Fork-free trim.
rule_CL009() {
    local _rel _i _in _s _cur _nxt _phrase _hit _j
    while IFS= read -r _rel; do
        [[ -z "$_rel" ]] && continue
        case "$_rel" in commands/*) ;; *) continue ;; esac
        load_file "$_rel"
        _in=0
        for ((_i = 0; _i < CUR_N; _i++)); do
            [[ "${CUR_FENCE[$_i]}" == "1" ]] && continue
            if [[ "${CUR_LINES[$_i]}" =~ $RE_PHASE0 ]]; then _in=1; continue; fi
            if [[ $_in -eq 1 && "${CUR_LINES[$_i]}" =~ $RE_SECTION_END ]]; then _in=0; fi
            [[ $_in -eq 1 ]] || continue
            [[ "${CUR_LINES[$_i]}" =~ $RE_SUPPRESS ]] && continue
            _s="${CUR_LINES[$_i]}"
            _cur="${_s#"${_s%%[![:blank:]]*}"}"; _cur="${_cur%"${_cur##*[![:blank:]]}"}"
            _nxt=""
            _j=$((_i + 1))
            if [[ $_j -lt $CUR_N && "${CUR_FENCE[$_j]}" != "1" ]] \
                && ! [[ "${CUR_LINES[$_j]}" =~ $RE_SECTION_END ]] \
                && ! [[ "${CUR_LINES[$_j]}" =~ $RE_SUPPRESS ]]; then
                _s="${CUR_LINES[$_j]}"
                _nxt="${_s#"${_s%%[![:blank:]]*}"}"; _nxt="${_nxt%"${_nxt##*[![:blank:]]}"}"
            fi
            _hit=0
            while IFS= read -r _phrase; do
                [[ -z "$_phrase" ]] && continue
                case "$_cur" in *"$_phrase"*) _hit=1; break ;; esac
                if [[ -n "$_nxt" ]]; then
                    case "$_nxt" in *"$_phrase"*) continue ;; esac
                    case "$_cur $_nxt" in *"$_phrase"*) _hit=1; break ;; esac
                fi
            done <<< "$BOOTSTRAP_GUARD_PHRASES"
            if [[ $_hit -eq 1 ]]; then
                add_finding CL009 "$_rel" "$((_i + 1))" "Phase 0 restates '$_phrase', which sd-bootstrap-guard owns - read the skill instead of copying its text"
            fi
        done
    done <<< "$SCAN_FILES"
}

# CL100 / CL102 / CL103 - each invocation against the mode it names. A target
# agent that CL001 already flagged as unresolved gets no CL100 pile-on.
rule_CL100_CL102_CL103() {
    local _ia _ik _iv _if _il _itok _da _dk _dv _df _dl _dreq _dopt
    local _found _t _k
    while IFS=$'\x1f' read -r _ia _ik _iv _if _il _itok; do
        [[ -z "$_ia" ]] && continue
        set_has AGENT_NAMES "$_ia" || continue
        _found=0
        while IFS=$'\x1f' read -r _da _dk _dv _df _dl _dreq _dopt; do
            [[ "$_da" == "$_ia" && "$_dk" == "$_ik" && "$_dv" == "$_iv" ]] || continue
            _found=1
            break
        done <<< "$MODE_DECLS"
        if [[ $_found -eq 0 ]]; then
            add_finding CL100 "$_if" "$_il" "invocation sets $_ik = $_iv but agent '$_ia' declares no such mode"
            continue
        fi
        if [[ -n "$_dreq" ]]; then
            while IFS= read -r _t; do
                [[ -z "$_t" ]] && continue
                csv_has "$_itok" "$_t" && continue
                add_finding CL102 "$_if" "$_il" "invocation of '$_ia' ($_ik = $_iv) omits required input '$_t'"
            done <<< "$(printf '%s' "$_dreq" | tr ',' '\n')"
        fi
        if [[ -n "$_itok" ]]; then
            while IFS= read -r _k; do
                [[ -z "$_k" ]] && continue
                [[ "$_k" == "$_ik" ]] && continue
                csv_has "$_dreq" "$_k" && continue
                csv_has "$_dopt" "$_k" && continue
                add_finding CL103 "$_if" "$_il" "invocation of '$_ia' ($_ik = $_iv) passes undeclared input '$_k'"
            done <<< "$(printf '%s' "$_itok" | tr ',' '\n')"
        fi
    done <<< "$INVOCATIONS"
}

# CL101 - the inverse of CL100: a declared mode nobody ever selects.
rule_CL101() {
    local _da _dk _dv _df _dl _dreq _dopt _seen
    local _ia _ik _iv _iif _iil _iitok
    while IFS=$'\x1f' read -r _da _dk _dv _df _dl _dreq _dopt; do
        [[ -z "$_da" ]] && continue
        _seen=0
        while IFS=$'\x1f' read -r _ia _ik _iv _iif _iil _iitok; do
            [[ "$_ia" == "$_da" && "$_ik" == "$_dk" && "$_iv" == "$_dv" ]] || continue
            _seen=1; break
        done <<< "$INVOCATIONS"
        if [[ $_seen -eq 0 ]]; then
            add_finding CL101 "$_df" "$_dl" "agent '$_da' declares mode $_dk = $_dv that no command ever invokes"
        fi
    done <<< "$MODE_DECLS"
}

# CL200 - disk-only, no manifest input. Any agent whose OWN tools: line carries
# none of Write/Edit/MultiEdit is a candidate; its body is then scanned for a
# line-initial Write/Append/Create, which is what lets every negated,
# third-person or mid-sentence use of those words pass untouched.
rule_CL200() {
    local _name _file _has_write _at _atool _afile _aline _i _verb
    while IFS=$'\x1f' read -r _name _file; do
        [[ -z "$_name" ]] && continue
        _has_write=0
        while IFS=$'\x1f' read -r _at _atool _afile _aline; do
            [[ "$_at" == "$_name" ]] || continue
            if is_write_tool "$_atool"; then _has_write=1; break; fi
        done <<< "$AGENT_TOOL_REFS"
        [[ $_has_write -eq 1 ]] && continue
        load_file "$_file"
        for ((_i = 0; _i < CUR_N; _i++)); do
            [[ "${CUR_FENCE[$_i]}" == "1" ]] && continue
            [[ "${CUR_LINES[$_i]}" =~ $RE_WRITEVERB ]] || continue
            _verb="${BASH_REMATCH[2]}"
            add_finding CL200 "$_file" "$((_i + 1))" "agent '$_name' has no write tool but this line instructs it to $_verb"
        done
    done <<< "$AGENT_NAME_FILE_TABLE"
}

# CL201 - the declared-vs-disk half: an agent this manifest promises will stay
# read-only, but whose own tools: line has grown a write tool since.
rule_CL201() {
    local _a _tool _f _l
    while IFS=$'\x1f' read -r _a _tool _f _l; do
        [[ -z "$_a" ]] && continue
        set_has READONLY_AGENTS "$_a" || continue
        is_write_tool "$_tool" || continue
        add_finding CL201 "$_f" "$_l" "agent '$_a' is declared read-only in contractLint.readOnlyAgents but its tools: line includes write tool '$_tool'"
    done <<< "$AGENT_TOOL_REFS"
}

# CL202 - every mcp__* token anywhere in scan scope (frontmatter tools: lines
# included, which is exactly where the historical typo'd tool name lived)
# against the hand-maintained allowlist.
rule_CL202() {
    local _k _t _f _l
    while IFS=$'\x1f' read -r _k _t _f _l; do
        [[ "$_k" == "mcpTool" ]] || continue
        set_has KNOWN_MCP_TOOLS "$_t" && continue
        add_finding CL202 "$_f" "$_l" "mcp tool name '$_t' is absent from contractLint.knownMcpTools"
    done <<< "$REFS"
}

# CL203/CL204 - a tool this agent's own frontmatter declares, that its own
# body (everything after the closing ---) never mentions by name. WARN
# (CL203) when the agent has no write tool of its own; BLOCK (CL204) when
# the agent is write-capable - an unexplained unused Write/Edit/MultiEdit
# sibling on the one class of agent that holds write power is the
# highest-value thing this check can find. Severity is still looked up from
# the manifest at emit time per rule id (never computed) - CL204 is a
# distinct rule id precisely so that invariant holds.
rule_CL203_CL204() {
    local _a _tool _f _l _start _i _used _rid
    while IFS=$'\x1f' read -r _a _tool _f _l; do
        [[ -z "$_a" ]] && continue
        load_file "$_f"
        _start="$(body_start_of "$_a")"
        _used=0
        for ((_i = _start - 1; _i < CUR_N; _i++)); do
            case "${CUR_LINES[$_i]}" in
                *"$_tool"*) _used=1; break ;;
            esac
        done
        if [[ $_used -eq 0 ]]; then
            _rid="CL203"
            set_has WRITE_CAPABLE_AGENTS "$_a" && _rid="CL204"
            add_finding "$_rid" "$_f" "$_l" "agent '$_a' declares tool '$_tool' but its body never mentions it"
        fi
    done <<< "$AGENT_TOOL_REFS"
}

# CL205 - the command-side twin of CL200. An invocation of an agent with no
# write tool (read off disk, WRITE_CAPABLE_AGENTS) opens a window that runs to
# the next heading or the next anchor. Unlike the CL1xx token span it does NOT
# stop at a numbered step: the defect this catches (SW-51, rca.md Phase 2) lives
# in step 3, two steps after step 1's invocation. Inside the window, a line
# that names a spec artifact and a write form, in a numbered step that never
# says 'main thread', asserts a write nobody is told to perform - the agent
# cannot, and the main thread was never asked. The step is [nearest numbered
# step at or above the line (clamped to the anchor), next numbered step /
# heading / anchor), fenced lines skipped. Unresolved targets are CL001's
# problem, not this one.
step_text_around() { # startIdx0 idx0 file -> STEP_TEXT (non-fenced lines, space-joined)
    local _lo="$1" _i="$2" _f="$3" _s _k
    _s=$_i
    while [[ $_s -gt $_lo ]]; do
        [[ "${CUR_FENCE[$_s]}" != "1" && "${CUR_LINES[$_s]}" =~ $RE_NUMSTEP ]] && break
        _s=$((_s - 1))
    done
    STEP_TEXT=""
    for ((_k = _s; _k < CUR_N; _k++)); do
        [[ "${CUR_FENCE[$_k]}" == "1" ]] && continue
        if [[ $_k -gt $_s ]]; then
            [[ "${CUR_LINES[$_k]}" =~ $RE_HEADING ]] && break
            [[ "${CUR_LINES[$_k]}" =~ $RE_NUMSTEP ]] && break
            set_has ANCHOR_LINES "${_f}:$((_k + 1))" && break
        fi
        STEP_TEXT="${STEP_TEXT} ${CUR_LINES[$_k]}"
    done
}

rule_CL205() {
    local _agent _file _line _start _j _txt _seen=""
    while IFS=$'\x1f' read -r _agent _file _line; do
        [[ -z "$_agent" ]] && continue
        set_has AGENT_NAMES "$_agent" || continue
        set_has WRITE_CAPABLE_AGENTS "$_agent" && continue
        if [[ "$CUR_REL" != "$_file" ]]; then load_file "$_file"; fi
        _start=$((_line - 1))
        for ((_j = _start; _j < CUR_N; _j++)); do
            [[ "${CUR_FENCE[$_j]}" == "1" ]] && continue
            _txt="${CUR_LINES[$_j]}"
            if [[ $_j -gt $_start ]]; then
                [[ "$_txt" =~ $RE_HEADING ]] && break
                set_has ANCHOR_LINES "${_file}:$((_j + 1))" && break
            fi
            [[ "$_txt" =~ $RE_SPECARTIFACT ]] || continue
            [[ "$_txt" =~ $RE_ARTIFACTWRITE ]] || continue
            step_text_around "$_start" "$_j" "$_file"
            [[ "$STEP_TEXT" =~ $RE_MAINTHREAD ]] && continue
            set_has _seen "${_file}:$((_j + 1))" && continue
            set_add _seen "${_file}:$((_j + 1))"
            add_finding CL205 "$_file" "$((_j + 1))" "step asserts a spec-artifact write inside the block of '$_agent', which has no write tool, and names no main-thread writer"
        done
    done <<< "$ANCHORS"
}

# Collect a gate block's selectable OPTIONS: the slash-separated tokens of a
# parenthetical, plus the backticked leading token of each top-level bullet.
# Sets OPT_TOKENS (newline-delimited "line<US>token" records) and OPT_HAS_SET.
gate_options() { # file blockStartLine blockEndExclusive0
    local _rel="$1" _start="$2" _end="$3" _i _line _inner _piece _tok _bullets=0
    OPT_TOKENS=""; OPT_HAS_SET=0
    if [[ "$CUR_REL" != "$_rel" ]]; then load_file "$_rel"; fi
    for ((_i = _start - 1; _i < _end; _i++)); do
        _line="${CUR_LINES[$_i]}"
        if [[ "$_line" =~ $RE_OPTPAREN ]]; then
            OPT_HAS_SET=1
            _inner="${BASH_REMATCH[0]}"
            _inner="${_inner#\(}"
            _inner="${_inner%\)}"
            while IFS= read -r _piece; do
                _tok="$(normalize_option "$_piece")"
                [[ -n "$_tok" ]] && OPT_TOKENS="${OPT_TOKENS}$((_i + 1))"$'\x1f'"${_tok}"$'\n'
            done <<< "$(printf '%s' "$_inner" | tr '/' '\n')"
        fi
        if [[ "$_line" =~ ^-[[:blank:]] ]]; then
            _bullets=$((_bullets + 1))
            if [[ "$_line" =~ $RE_BULLETTOK ]]; then
                _tok="$(normalize_option "${BASH_REMATCH[1]}")"
                [[ -n "$_tok" ]] && OPT_TOKENS="${OPT_TOKENS}$((_i + 1))"$'\x1f'"${_tok}"$'\n'
            fi
        fi
    done
    [[ $_bullets -ge 2 ]] && OPT_HAS_SET=1
    return 0
}

trim_blank() { # string -> stdout, leading/trailing spaces and tabs removed
    local _s="$1" _c
    while [[ -n "$_s" ]]; do
        _c="${_s:0:1}"
        [[ "$_c" == " " || "$_c" == "$(printf '\t')" ]] || break
        _s="${_s:1}"
    done
    while [[ -n "$_s" ]]; do
        _c="${_s: -1}"
        [[ "$_c" == " " || "$_c" == "$(printf '\t')" ]] || break
        _s="${_s:0:${#_s}-1}"
    done
    printf '%s' "$_s"
}

# The seven steps below are a CONTRACT with contract-lint.ps1's Get-NormalizedOption.
# Both must produce byte-identical tokens or CL305 diverges between the twins.
#   1. truncate at the first backtick        5. drop every ` and " character
#   2. trim spaces/tabs                      6. lowercase A-Z only
#   3. truncate at the first " - "           7. trim spaces/tabs again
#   4. truncate at the first " <"
normalize_option() { # raw piece -> stdout lowercase leading token
    local _s="$1"
    _s="${_s%%\`*}"
    _s="$(trim_blank "$_s")"
    _s="${_s%% - *}"
    _s="${_s%% <*}"
    _s="$(printf '%s' "$_s" | tr -d '`"' | tr 'A-Z' 'a-z')"
    _s="$(trim_blank "$_s")"
    printf '%s' "$_s"
}

rule_CL300_CL301_CL305_CL306() {
    local _f _l _kind _label _hard _end _i _has_stop _ol _ot _phrase _hit
    while IFS=$'\x1f' read -r _f _l _kind _label _hard _end; do
        [[ -z "$_f" ]] && continue
        if [[ "$CUR_REL" != "$_f" ]]; then load_file "$_f"; fi
        _has_stop=0
        for ((_i = _l - 1; _i < _end; _i++)); do
            case "${CUR_LINES[$_i]}" in
                *STOP*) _has_stop=1; break ;;
            esac
        done
        if [[ $_has_stop -eq 0 ]]; then
            add_finding CL300 "$_f" "$_l" "gate block contains no literal STOP"
        fi
        gate_options "$_f" "$_l" "$_end"
        if [[ $OPT_HAS_SET -eq 0 ]]; then
            add_finding CL301 "$_f" "$_l" "gate block offers no option set"
        fi
        if [[ $_hard -eq 1 && -n "$OPT_TOKENS" ]]; then
            while IFS=$'\x1f' read -r _ol _ot; do
                [[ -z "$_ot" ]] && continue
                if set_has OVERRIDE_TOKENS "$_ot"; then
                    add_finding CL305 "$_f" "$_ol" "HARD gate offers override option '$_ot'"
                fi
            done <<< "$OPT_TOKENS"
        fi
        if [[ $_hard -eq 1 ]]; then
            # CL306 - a naive phrase scan over gate-block PROSE, deliberately
            # excluding whatever CL305 already governs: CLAUDE.md rule 6
            # frames "listed as a choice" and "described in prose" as the two
            # mutually exclusive halves of a HARD gate's escape-hatch
            # surface, so a line that is itself part of the option-set
            # syntax (the slash parenthetical, or a backtick-led option
            # bullet) is CL305's territory, not CL306's - without this
            # exclusion, perf.md's already CL305-suppressed Case A ('proceed
            # anyway' inside the option set) false-fires CL306 too, on both
            # the option line and its own suppression comment's reason text.
            # It fires on commands/bug.md's logged insist-and-proceed
            # sentence and commands/release.md's "may override the version"
            # bullet (neither is option-set syntax) unless annotated -
            # fixing that is the point of this rule, not a bug in it. See
            # GATE_PROSE_ESCAPE_TOKENS above.
            for ((_i = _l - 1; _i < _end; _i++)); do
                [[ "${CUR_FENCE[$_i]}" == "1" ]] && continue
                [[ "${CUR_LINES[$_i]}" =~ $RE_SUPPRESS ]] && continue
                [[ "${CUR_LINES[$_i]}" =~ $RE_OPTPAREN ]] && continue
                [[ "${CUR_LINES[$_i]}" =~ $RE_BULLETTOK ]] && continue
                _hit=0
                while IFS= read -r _phrase; do
                    [[ -z "$_phrase" ]] && continue
                    case "${CUR_LINES[$_i]}" in
                        *"$_phrase"*) _hit=1; break ;;
                    esac
                done <<< "$GATE_PROSE_ESCAPE_TOKENS"
                if [[ $_hit -eq 1 ]]; then
                    add_finding CL306 "$_f" "$((_i + 1))" "HARD gate prose describes an escape hatch ('$_phrase')"
                fi
            done
        fi
    done <<< "$GATES"
}

# CL400 / CL401 / CL402 - stack-agnostic prose + hardcoded absolute paths.
# One line-scan pass over scanScope, deliberately narrow (word-bounded
# vocabulary hits, positive-boundary path regex) to keep the false-positive
# band this wave occupies under control - see STACK_CMD_PATTERNS /
# STACK_LANG_PATTERNS above and the manifest's $stackTokensComment. Every
# pattern is PRE-COMPILED before this function runs - no command
# substitution and no external process anywhere in this per-line loop. The
# combined alternation is tested first; the per-token table only runs on a
# line that already matched it, which is what keeps ~5k lines x 28 vocabulary
# entries from paying for 28 regex tests each.
rule_CL400_CL401_CL402() {
    local _rel _i _line _scrubbed _tok _pat
    while IFS= read -r _rel; do
        [[ -z "$_rel" ]] && continue
        load_file "$_rel"
        for ((_i = 0; _i < CUR_N; _i++)); do
            [[ "${CUR_FENCE[$_i]}" == "1" ]] && continue
            _line="${CUR_LINES[$_i]}"
            # Fork-free scrub: a per-line sed subprocess across ~5k scanScope
            # lines is the exact anti-pattern collect_refs already warns
            # about (a Windows-runner fork is orders of magnitude slower than
            # a native bash op), so this only touches lines that actually
            # contain '<<' and uses bash's own glob substitution, never sed.
            _scrubbed="$_line"
            if [[ "$_scrubbed" == *"<<"* ]]; then
                _scrubbed="${_scrubbed//<<*>>/}"
            fi
            if [[ -n "$STACK_CMD_COMBINED" && "$_scrubbed" =~ $STACK_CMD_COMBINED ]]; then
                while IFS=$'\x1f' read -r _tok _pat; do
                    [[ -z "$_tok" ]] && continue
                    if [[ "$_scrubbed" =~ $_pat ]]; then
                        add_finding CL400 "$_rel" "$((_i + 1))" "hardcoded stack command token '$_tok'"
                    fi
                done <<< "$STACK_CMD_PATTERNS"
            fi
            if [[ -n "$STACK_LANG_COMBINED" && "$_scrubbed" =~ $STACK_LANG_COMBINED ]]; then
                while IFS=$'\x1f' read -r _tok _pat; do
                    [[ -z "$_tok" ]] && continue
                    if [[ "$_scrubbed" =~ $_pat ]]; then
                        add_finding CL401 "$_rel" "$((_i + 1))" "hardcoded language/framework name '$_tok'"
                    fi
                done <<< "$STACK_LANG_PATTERNS"
            fi
            if [[ "$_scrubbed" =~ $RE_ABSPATH_WIN ]]; then
                add_finding CL402 "$_rel" "$((_i + 1))" "hardcoded absolute path '${BASH_REMATCH[2]}'"
            elif [[ "$_scrubbed" =~ $RE_ABSPATH_POSIX ]]; then
                add_finding CL402 "$_rel" "$((_i + 1))" "hardcoded absolute path '${BASH_REMATCH[2]}'"
            fi
        done
    done <<< "$SCAN_FILES"
}

rule_CL302_CL303_CL304() {
    local _rel _f _l _kind _label _hard _end
    local _count _labels _decl_hard _decl_cond _c _want _dup _seen _n
    while IFS= read -r _rel; do
        [[ -z "$_rel" ]] && continue
        _count=0; _labels=""
        while IFS=$'\x1f' read -r _f _l _kind _label _hard _end; do
            [[ "$_f" == "$_rel" ]] || continue
            if [[ "$_kind" == "hard" ]]; then
                _count=$((_count + 1))
                [[ -n "$_label" ]] && _labels="${_labels}${_label}"$'\n'
            fi
        done <<< "$GATES"

        _decl_hard=0; _decl_cond=""
        if set_has GATE_DECL_FILES "$_rel"; then
            while IFS=$'\x1f' read -r _f _c _want; do
                if [[ "$_f" == "$_rel" ]]; then _decl_hard="$_c"; _decl_cond="$_want"; fi
            done <<< "$GATE_DECL_TABLE"
        fi
        if [[ "$_count" -ne "$_decl_hard" ]]; then
            add_finding CL302 "$_rel" 1 "hard gate count is $_count on disk, manifest declares $_decl_hard"
        fi

        # CL303 is SET-based, never file order: commands/bug.md authors
        # '### Gate 3a' before '### Gate 3' and must still pass.
        _labels="$(printf '%s' "$_labels" | grep -v '^$' | sort -n || true)"
        _n=0; _dup=0; _seen=""
        while IFS= read -r _c; do
            [[ -z "$_c" ]] && continue
            _n=$((_n + 1))
            if set_has _seen "$_c"; then _dup=1; fi
            set_add _seen "$_c"
        done <<< "$_labels"
        if [[ $_n -gt 0 ]]; then
            _want=1
            while IFS= read -r _c; do
                [[ -z "$_c" ]] && continue
                if [[ "$_c" != "$_want" ]]; then _dup=1; break; fi
                _want=$((_want + 1))
            done <<< "$_labels"
            if [[ $_dup -ne 0 ]]; then
                add_finding CL303 "$_rel" 1 "hard gate numbering is not 1..$_n without duplicates"
            fi
        fi

        # CL304 - symmetric set difference, both directions BLOCK. The
        # declared-but-absent half is the anti-rot direction.
        _seen=""
        while IFS=$'\x1f' read -r _f _l _kind _label _hard _end; do
            [[ "$_f" == "$_rel" ]] || continue
            [[ "$_kind" == "conditional" ]] || continue
            set_add _seen "$_label"
            case ",$_decl_cond," in
                *",$_label,"*) ;;
                *) add_finding CL304 "$_rel" "$_l" "conditional gate '$_label' is not declared in the manifest" ;;
            esac
        done <<< "$GATES"
        if [[ -n "$_decl_cond" ]]; then
            while IFS= read -r _c; do
                [[ -z "$_c" ]] && continue
                if ! set_has _seen "$_c"; then
                    add_finding CL304 "$_rel" 1 "manifest declares conditional gate '$_c' but it is absent from disk"
                fi
            done <<< "$(printf '%s' "$_decl_cond" | tr ',' '\n')"
        fi
    done <<< "$SCAN_FILES"
}

rule_CL001_CL003
rule_CL002
rule_CL004
rule_CL005
rule_CL006
rule_CL007
rule_CL008
rule_CL009
rule_CL100_CL102_CL103
rule_CL101
rule_CL200
rule_CL201
rule_CL202
rule_CL203_CL204
rule_CL205
rule_CL300_CL301_CL305_CL306
rule_CL302_CL303_CL304
rule_CL400_CL401_CL402

# ---- Phase C: suppressions, sort, emit -------------------------------------
#
# A suppression can never suppress CL900, CL901 or CL902 - otherwise
# '<!-- contract-lint: allow CL900 -->' would be a self-authorizing loophole.
# That exclusion is hardcoded, never manifest-driven.

resolve_suppressions() {
    local _i _j _keep_rule=() _keep_file=() _keep_line=() _keep_msg=() _n=0 _hit
    for ((_i = 0; _i < F_N; _i++)); do
        _hit=0
        case "${f_rule[$_i]}" in
            CL900|CL901|CL902) _hit=0 ;;
            *)
                for ((_j = 0; _j < S_N; _j++)); do
                    [[ "${s_bad[$_j]}" == "1" ]] && continue
                    [[ "${s_file[$_j]}" == "${f_file[$_i]}" ]] || continue
                    [[ "${s_rule[$_j]}" == "${f_rule[$_i]}" ]] || continue
                    if [[ "${s_line[$_j]}" -eq "${f_line[$_i]}" \
                       || "${s_line[$_j]}" -eq $(( ${f_line[$_i]} - 1 )) ]]; then
                        s_used[$_j]=1
                        _hit=1
                        break
                    fi
                done ;;
        esac
        if [[ $_hit -eq 0 ]]; then
            _keep_rule[$_n]="${f_rule[$_i]}"
            _keep_file[$_n]="${f_file[$_i]}"
            _keep_line[$_n]="${f_line[$_i]}"
            _keep_msg[$_n]="${f_msg[$_i]}"
            _n=$((_n + 1))
        fi
    done
    F_N=$_n
    f_rule=(); f_file=(); f_line=(); f_msg=()
    for ((_i = 0; _i < _n; _i++)); do
        f_rule[$_i]="${_keep_rule[$_i]}"
        f_file[$_i]="${_keep_file[$_i]}"
        f_line[$_i]="${_keep_line[$_i]}"
        f_msg[$_i]="${_keep_msg[$_i]}"
    done
    # CL902 runs LAST, over the used flags. A CL901-flagged suppression is
    # exempt - one error per broken suppression, never two.
    for ((_j = 0; _j < S_N; _j++)); do
        [[ "${s_bad[$_j]}" == "1" ]] && continue
        [[ "${s_used[$_j]}" == "1" ]] && continue
        add_finding CL902 "${s_file[$_j]}" "${s_line[$_j]}" \
            "suppression for ${s_rule[$_j]} suppressed nothing"
    done
}

resolve_suppressions

rule_wanted() { # rule_id -> 0 if it should be emitted
    [[ -z "$RULE_FILTER" ]] && return 0
    case ",$RULE_FILTER," in
        *",$1,"*) return 0 ;;
    esac
    return 1
}

blocks=0
warns=0
emit=""
for ((i = 0; i < F_N; i++)); do
    rule_wanted "${f_rule[$i]}" || continue
    sev="$(severity_of "${f_rule[$i]}")"
    [[ -z "$sev" ]] && sev="BLOCK"
    if [[ "$sev" == "BLOCK" ]]; then blocks=$((blocks + 1)); else warns=$((warns + 1)); fi
    # Sort key: file, then zero-padded line so lexical order IS numeric order,
    # then rule id, then message. The message is in the key so two findings that
    # agree on the first three components still order deterministically - `sort`
    # is not stable, and the twin's List.Sort is not stable either.
    printf -v padded '%09d' "${f_line[$i]}"
    emit="${emit}${f_file[$i]}"$'\x01'"${padded}"$'\x01'"${f_rule[$i]}"$'\x01'"${f_msg[$i]}"$'\t'"${f_rule[$i]}"$'\t'"${sev}"$'\t'"${f_file[$i]}"$'\t'"${f_line[$i]}"$'\t'"${f_msg[$i]}"$'\n'
done

if [[ -n "$emit" ]]; then
    printf '%s' "$emit" | grep -v '^$' | sort | cut -f2-
fi

if [[ $QUIET -eq 0 ]]; then
    echo "contract-lint: $blocks block, $warns warn (root: $ROOT)" >&2
fi

if [[ $blocks -gt 0 ]]; then exit 1; fi
exit 0
