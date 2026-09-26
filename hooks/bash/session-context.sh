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
# Exits 0 silently if jq is missing, if stdin is empty/invalid, if the hook is
# disabled, or if there is nothing to say. Never writes to disk.
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
# walk, no `cd`/`realpath`. Identical in all four hooks; mirrors
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

# `status:` from the leading `---` frontmatter block of 00-spec.md. Only a
# plain token ([A-Za-z0-9_-]+) is accepted. Anything else, a missing file or a
# missing line all yield '' and the spec is listed without a status.
spec_status() {
    local file="$1" l n=0
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
        if [[ "${l}" =~ ^status:[[:blank:]]*([A-Za-z0-9_-]+)[[:blank:]]*$ ]]; then
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

# --- nothing to say? ----------------------------------------------------------

if [[ ${has_constitution} -eq 0 && ${#ip_ids[@]} -eq 0 ]]; then
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
            st="$(spec_status "${spec_path}/${ip_ids[i]}/00-spec.md")"
            [[ -n "${st}" ]] && item="${item} [status: ${st}]"
            [[ -n "${ip_titles[i]}" ]] && item="${item} ${ip_titles[i]}"
            printf '%s\n' "${item}"
        done
    fi

    echo '</session-context>'
}

exit 0
