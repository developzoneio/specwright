#!/usr/bin/env bash
# specwright: SessionStart hook - session-context (bash).
#
# Reads Claude Code hook JSON from stdin. Emits a <session-context> block on
# stdout with the parts of the spec context that do not change within a
# session (SW-67): the constitution pointer, and every in-progress spec in
# .specs/index.md with its title and its 00-spec.md `status:`. SessionStart
# fires on startup, resume (covers --continue), fork, compact and clear
# (ADR 0015); every source gets the same block. prompt-router keeps the
# per-prompt part.
#
# On `compact` only (SW-68), the block also names the spec the session was
# working on before the compaction. precompact-state records that pointer in
# .claude/.hookstate/precompact-<session_id>.json; this hook stays the one
# context builder and derives the rest from disk: the spec's status, a phase
# hint (open gate or task progress) and the /sd:<type> command to resume.
#
# Exits 0 silently if jq is missing, if stdin is empty/invalid, if the hook is
# disabled, or if there is nothing to say. Never writes to disk; it only reads
# the PreCompact pointer.
#
# Note: we deliberately do NOT use `set -u` because bash 3.2's empty-array
# expansion is brittle under it; the hook must never fail noisily.
# Must stay bash-3.2 compatible (macOS system bash): no `declare -A`.

# --- graceful exits -----------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

# --- read stdin ---------------------------------------------------------------

input="$(cat 2>/dev/null || true)"
if [[ -z "${input}" ]]; then
    exit 0
fi
if ! printf '%s' "${input}" | jq -e . >/dev/null 2>&1; then
    exit 0
fi

# Some jq builds (e.g. Windows jq.exe) emit CRLF; strip a trailing CR from
# every scalar read below so comparisons and paths are not corrupted.
jq_str() {
    local v
    v="$(printf '%s' "$1" | jq -r "$2" 2>/dev/null)"
    printf '%s' "${v%$'\r'}"
}

cwd="$(jq_str "${input}" 'if (.cwd | type) == "string" then .cwd else empty end')"
if [[ -z "${cwd}" || ! -d "${cwd}" ]]; then
    exit 0
fi

# Echo only a plain lowercase word; anything else (missing, a number, an
# object) is reported as `unknown` rather than trusted into the context.
source_val="$(jq_str "${input}" 'if (.source | type) == "string" then .source else empty end')"
if [[ ! "${source_val}" =~ ^[a-z]+$ ]]; then
    source_val="unknown"
fi

# --- project root (SW-78) -----------------------------------------------------
# `cwd` is the session's CURRENT directory, and a Bash `cd` moves it. Reading
# config and specs relative to it made a session sitting in a subdirectory see
# no spec folders and no in-progress work. Everything below resolves against
# the project root:
#   1. CLAUDE_PROJECT_DIR (set by Claude Code for hooks), when it is a directory.
#   2. The nearest ancestor of cwd (cwd included) holding .claude/project-config.json.
#   3. The nearest ancestor of cwd holding a .specs/ directory.
#   4. cwd itself - the pre-SW-78 behaviour.
# Step 2 walks the whole chain before step 3 starts, so a stray nested .specs/
# left behind by an older hook cannot shadow a configured root. Pure string
# walk, no `cd`/`realpath`. Identical in all five hooks; mirrors
# Resolve-ProjectRoot in the .ps1 twins.
resolve_project_root() {
    local start="${1//\\//}"
    if [[ -n "${CLAUDE_PROJECT_DIR:-}" && -d "${CLAUDE_PROJECT_DIR}" ]]; then
        printf '%s' "${CLAUDE_PROJECT_DIR//\\//}"
        return 0
    fi
    [[ "${start}" != "/" ]] && start="${start%/}"
    local marker dir i
    for marker in f:.claude/project-config.json d:.specs; do
        dir="${start}"
        for (( i = 0; i < 64; i++ )); do
            if [[ "${marker}" == f:* && -f "${dir%/}/${marker#f:}" ]] ||
               [[ "${marker}" == d:* && -d "${dir%/}/${marker#d:}" ]]; then
                printf '%s' "${dir}"
                return 0
            fi
            [[ "${dir}" == "/" || "${dir}" != */* ]] && break
            dir="${dir%/*}"
            [[ -z "${dir}" ]] && dir="/"
        done
    done
    printf '%s' "${start}"
}

project_root="$(resolve_project_root "${cwd}")"

# --- load config (defaults if missing) ---------------------------------------

# An empty object is a safe fallback HERE only because every value this hook
# reads has a `//` default below, and those defaults are the same values as
# $defaults in session-context.ps1. Any new read must keep that property.
config_path="${project_root}/.claude/project-config.json"
config_json="{}"
if [[ -f "${config_path}" ]]; then
    if jq -e . "${config_path}" >/dev/null 2>&1; then
        config_json="$(cat "${config_path}")"
    fi
fi

# Hook enabled? The jq alternative operator treats an explicit `false` as
# absent, so compare directly against `false` instead of relying on it here.
enabled="$(jq_str "${config_json}" 'if .hooks.sessionContext.enabled == false then "false" else "true" end')"
if [[ "${enabled}" == "false" ]]; then
    exit 0
fi

spec_rel="$(jq_str "${config_json}"   '.spec.dir              // ".specs"')"
index_rel="$(jq_str "${config_json}"  '.spec.indexFile        // ".specs/index.md"')"
const_rel="$(jq_str "${config_json}"  '.spec.constitutionFile // ".specs/constitution.md"')"

spec_path="${project_root}/${spec_rel}"
index_path="${project_root}/${index_rel}"
const_path="${project_root}/${const_rel}"

# --- spec prefix alternation (SW-44) ------------------------------------------
# Built-in fallback covers every prefix shipped in
# templates/project-config.template.json (FEAT, BUG, REF, PERF, RCA, PORT).
# Any config-declared prefix that fails the shape check
# ^[A-Z][A-Z0-9]{1,9}$ is dropped silently and the built-in default is used
# only if NOTHING declared validates. Must stay in sync with
# Get-SpecPrefixAlternation in session-context.ps1.
readonly SD_DEFAULT_SPEC_PREFIXES='FEAT|BUG|REF|PERF|RCA|PORT'

resolve_spec_prefixes() {
    local raw valid=() p
    raw="$(printf '%s' "${config_json}" | jq -r '.spec.prefixes // {} | to_entries[]?.value // empty' 2>/dev/null)"
    if [[ -z "${raw}" ]]; then
        printf '%s' "${SD_DEFAULT_SPEC_PREFIXES}"
        return 0
    fi
    while IFS= read -r p; do
        p="${p%$'\r'}"
        [[ -z "${p}" ]] && continue
        if [[ "${p}" =~ ^[A-Z][A-Z0-9]{1,9}$ ]]; then
            valid+=("${p}")
        fi
    done <<< "${raw}"
    if [[ ${#valid[@]} -eq 0 ]]; then
        printf '%s' "${SD_DEFAULT_SPEC_PREFIXES}"
        return 0
    fi
    local IFS='|'
    printf '%s' "${valid[*]}"
}

spec_prefixes="$(resolve_spec_prefixes)"

# --- helpers ------------------------------------------------------------------

# Title of an index row: its last non-empty `|` cell. That holds for both the
# 4-column (ID|Type|Status|Title) and 5-column (ID|Type|Status|Created|Title)
# shapes. A row too short to have a title yields its ID or its status as the
# last cell; neither is a title, so the result is empty.
row_title() {
    local line="$1" id="$2" rest cell last=""
    rest="${line}"
    while [[ -n "${rest}" ]]; do
        if [[ "${rest}" == *'|'* ]]; then
            cell="${rest%%|*}"
            rest="${rest#*|}"
        else
            cell="${rest}"
            rest=""
        fi
        # trim leading/trailing whitespace
        cell="${cell#"${cell%%[![:space:]]*}"}"
        cell="${cell%"${cell##*[![:space:]]}"}"
        [[ -n "${cell}" ]] && last="${cell}"
    done
    if [[ "${last}" == "${id}" || "${last}" == "in-progress" ]]; then
        last=""
    fi
    printf '%s' "${last}"
}

# A plain-token frontmatter value (`status:`, `type:`) from the leading `---`
# block of 00-spec.md. Only [A-Za-z0-9_-]+ is accepted. Anything else, a
# missing file or a missing line all yield '' and the value is left out.
spec_field() {
    local file="$1" key="$2" l n=0 rx
    rx="^${key}:[[:blank:]]*([A-Za-z0-9_-]+)[[:blank:]]*$"
    [[ -f "${file}" ]] || return 0
    while IFS= read -r l || [[ -n "${l}" ]]; do
        l="${l%$'\r'}"
        n=$((n + 1))
        if [[ ${n} -eq 1 ]]; then
            # Get-Content -Encoding UTF8 drops a BOM in the .ps1 twin; match it.
            l="${l#$'\xEF\xBB\xBF'}"
            [[ "${l}" == "---" ]] || return 0
            continue
        fi
        [[ ${n} -gt 200 || "${l}" == "---" ]] && return 0
        if [[ "${l}" =~ ${rx} ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    done < "${file}"
    return 0
}

# --- in-progress specs --------------------------------------------------------
# Index rows in file order, first row per ID wins. A row counts when it
# contains the literal text `in-progress` and a spec ID; the ID is the
# LEFTMOST prefix match on the row (case-sensitive, as in the .ps1 twin).

ip_ids=()
ip_titles=()
if [[ -f "${index_path}" ]]; then
    id_rx="(${spec_prefixes})-[A-Za-z0-9_-]+"
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%$'\r'}"
        [[ "${line}" == *in-progress* ]] || continue
        [[ "${line}" =~ ${id_rx} ]] || continue
        id="${BASH_REMATCH[0]}"
        dup=0
        for existing in "${ip_ids[@]:-}"; do
            if [[ "${existing}" == "${id}" ]]; then dup=1; break; fi
        done
        [[ ${dup} -eq 1 ]] && continue
        ip_ids+=("${id}")
        ip_titles+=("$(row_title "${line}" "${id}")")
    done < "${index_path}"
fi

has_constitution=0
[[ -f "${const_path}" ]] && has_constitution=1

# --- active spec after a compaction (SW-68) -----------------------------------

# How old a PreCompact pointer may be and still describe this compaction.
# SessionStart `compact` follows PreCompact within seconds; the margin covers a
# slow auto-compaction, and a pointer left by a failed earlier run expires.
readonly POINTER_MAX_AGE_MINUTES=30

get_mtime() {
    local f="$1"
    if stat -c %Y "${f}" >/dev/null 2>&1; then
        stat -c %Y "${f}"
    elif stat -f %m "${f}" >/dev/null 2>&1; then
        stat -f %m "${f}"
    else
        echo "0"
    fi
}

# Task progress from 02-tasks.md: every `- **Status**: open|done` line is one
# task (the check-off marker, skills/sd-atomic-task-format). Next is the
# `### T<NN>` heading above the first open marker. Sets tp_total, tp_done and
# tp_next.
task_progress() {
    local file="$1" l current=""
    local head_rx='^###[[:blank:]]+(T[0-9]+)([^0-9]|$)'
    local status_rx='^- \*\*Status\*\*:[[:blank:]]*(open|done)[[:blank:]]*$'
    tp_total=0; tp_done=0; tp_next=""
    [[ -f "${file}" ]] || return 0
    while IFS= read -r l || [[ -n "${l}" ]]; do
        l="${l%$'\r'}"
        if [[ "${l}" =~ ${head_rx} ]]; then
            current="${BASH_REMATCH[1]}"
            continue
        fi
        if [[ "${l}" =~ ${status_rx} ]]; then
            tp_total=$((tp_total + 1))
            if [[ "${BASH_REMATCH[1]}" == "done" ]]; then
                tp_done=$((tp_done + 1))
            elif [[ -z "${tp_next}" ]]; then
                tp_next="${current}"
            fi
        fi
    done < "${file}"
    return 0
}

# A type-agnostic hint of where the workflow stands, from the status and the
# task file alone. It is a hint: the workflow command's own state machine is
# the authority, which is why the block also names the command to re-invoke.
phase_hint() {
    local status="$1" folder="$2" tasks="$2/02-tasks.md" hint
    case "${status}" in
        draft)
            printf '%s' 'open gate: spec approval' ;;
        approved)
            if [[ -f "${tasks}" ]]; then
                printf '%s' 'open gate: plan approval'
            else
                printf '%s' 'spec approved'
            fi ;;
        in-progress)
            # bug, perf and rca keep no task list; their phase lives in the
            # spec's own sections, which only the workflow command reads.
            task_progress "${tasks}"
            if [[ ${tp_total} -eq 0 ]]; then
                printf '%s' 'in progress - no task list'
            elif [[ ${tp_done} -ge ${tp_total} ]]; then
                printf '%s' 'all tasks done - open gate: close-out / review'
            else
                hint="executing - ${tp_done}/${tp_total} tasks done"
                [[ -n "${tp_next}" ]] && hint="${hint}, next ${tp_next}"
                printf '%s' "${hint}"
            fi ;;
    esac
    return 0
}

# The pointer precompact-state wrote for this session. Sets active_id and
# active_trigger, or leaves them empty when the pointer is missing, stale,
# malformed, or names a spec that has no 00-spec.md.
active_id=""
active_trigger=""
if [[ "${source_val}" == "compact" ]]; then
    session_id="$(jq_str "${input}" '(.session_id // "no-session") | tostring')"
    [[ -z "${session_id//[[:space:]]/}" ]] && session_id="no-session"
    safe_id="$(printf '%s' "${session_id}" | tr -c 'A-Za-z0-9_-' '_')"
    pointer="${project_root}/.claude/.hookstate/precompact-${safe_id}.json"
    if [[ -f "${pointer}" ]]; then
        p_mtime="$(get_mtime "${pointer}")"
        p_age=$(( $(date +%s) - p_mtime ))
        if [[ "${p_mtime}" =~ ^[0-9]+$ && ${p_mtime} -gt 0 && ${p_age} -le $(( POINTER_MAX_AGE_MINUTES * 60 )) ]] &&
           jq -e 'type == "object"' "${pointer}" >/dev/null 2>&1; then
            p_json="$(cat "${pointer}")"
            p_id="$(jq_str "${p_json}" 'if (.specId | type) == "string" then .specId else empty end')"
            p_trigger="$(jq_str "${p_json}" 'if (.trigger | type) == "string" then .trigger else empty end')"
            if [[ "${p_id}" =~ ^(${spec_prefixes})-[A-Za-z0-9_-]+$ && -f "${spec_path}/${p_id}/00-spec.md" ]]; then
                active_id="${p_id}"
                active_trigger="${p_trigger}"
                [[ "${active_trigger}" =~ ^[a-z]+$ ]] || active_trigger="unknown"
            fi
        fi
    fi
fi

# --- nothing to say? ----------------------------------------------------------

if [[ ${has_constitution} -eq 0 && ${#ip_ids[@]} -eq 0 && -z "${active_id}" ]]; then
    exit 0
fi

# --- emit session-context block ----------------------------------------------

{
    echo '<session-context>'
    echo "Spec context from specwright (SessionStart hook, source: ${source_val}):"

    if [[ ${has_constitution} -eq 1 ]]; then
        echo ''
        echo "Constitution: ${const_rel}"
    fi

    if [[ ${#ip_ids[@]} -gt 0 ]]; then
        echo ''
        echo "Specs currently in-progress (from ${index_rel}):"
        for ((i=0; i<${#ip_ids[@]}; i++)); do
            item="  - ${ip_ids[i]}"
            st="$(spec_field "${spec_path}/${ip_ids[i]}/00-spec.md" status)"
            [[ -n "${st}" ]] && item="${item} [status: ${st}]"
            [[ -n "${ip_titles[i]}" ]] && item="${item} ${ip_titles[i]}"
            printf '%s\n' "${item}"
        done
    fi

    if [[ -n "${active_id}" ]]; then
        a_folder="${spec_path}/${active_id}"
        a_status="$(spec_field "${a_folder}/00-spec.md" status)"
        echo ''
        head="Active spec before compaction (trigger: ${active_trigger}): ${active_id}"
        [[ -n "${a_status}" ]] && head="${head} [status: ${a_status}]"
        printf '%s\n' "${head}"
        a_hint="$(phase_hint "${a_status}" "${a_folder}")"
        [[ -n "${a_hint}" ]] && printf '  Phase hint: %s\n' "${a_hint}"
        # The workflow commands take the ID without its prefix (FEAT-<arg>).
        a_type="$(spec_field "${a_folder}/00-spec.md" type)"
        if [[ "${a_type}" =~ ^(feature|bug|refactor|perf|rca|port)$ ]]; then
            printf '  Resume: /sd:%s %s - its state machine re-derives the exact phase from %s/\n' \
                "${a_type}" "${active_id#*-}" "${spec_rel}"
        fi
    fi

    echo '</session-context>'
}

exit 0
