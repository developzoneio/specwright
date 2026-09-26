#!/usr/bin/env bash
# specwright: PreCompact hook - precompact-state (bash).
#
# Reads Claude Code hook JSON from stdin. Before a compaction (manual or auto)
# it records WHICH spec the session was working on, so the SessionStart hook
# can re-inject it once the compaction is done (SW-68):
#   1. Resolve the project root from the cwd (SW-78) and load
#      .claude/project-config.json (or sane defaults if absent).
#   2. Scan the tail of the session transcript for spec IDs, newest first. The
#      first one that has <spec.dir>/<ID>/00-spec.md and is not done/archived
#      is the active spec. When the transcript names none, a single
#      in-progress index row is used instead.
#   3. Write the pointer {specId, trigger} to
#      .claude/.hookstate/precompact-<session_id>.json.
#
# session-context.sh reads the pointer on SessionStart `source: compact`, which
# fires after the compaction with the same session_id (ADR 0015), and builds
# the context from disk. This hook only records the pointer: one context
# builder, not two. It never writes to stdout - what the CLI does with
# PreCompact stdout is not documented.
#
# Exit 2 would BLOCK the compaction (ADR 0015). Every path here exits 0,
# silently, including jq missing and every failure.
#
# Note: we deliberately do NOT use `set -u` because bash 3.2's empty-array
# expansion is brittle under it; the hook must never fail noisily.
# Must stay bash-3.2 compatible (macOS system bash): no `declare -A`.

# How much of the transcript tail to scan. Recent turns are at the end; a
# fixed cap keeps the cost flat however long the session has run.
readonly TRANSCRIPT_TAIL_BYTES=262144

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
# $defaults in precompact-state.ps1. Any new read must keep that property.
config_path="${project_root}/.claude/project-config.json"
config_json="{}"
if [[ -f "${config_path}" ]]; then
    if jq -e . "${config_path}" >/dev/null 2>&1; then
        config_json="$(cat "${config_path}")"
    fi
fi

# Hook enabled? The jq alternative operator treats an explicit `false` as
# absent, so compare directly against `false` instead of relying on it here.
enabled="$(jq_str "${config_json}" 'if .hooks.precompactState.enabled == false then "false" else "true" end')"
if [[ "${enabled}" == "false" ]]; then
    exit 0
fi

spec_rel="$(jq_str "${config_json}"  '.spec.dir       // ".specs"')"
index_rel="$(jq_str "${config_json}" '.spec.indexFile // ".specs/index.md"')"
spec_path="${project_root}/${spec_rel}"
index_path="${project_root}/${index_rel}"

# No spec tree: nothing to preserve.
if [[ ! -d "${spec_path}" || ! -f "${index_path}" ]]; then
    exit 0
fi

# Echo only a plain lowercase word (manual, auto); anything else is recorded
# as `unknown` rather than trusted into the context.
trigger="$(jq_str "${input}" 'if (.trigger | type) == "string" then .trigger else empty end')"
if [[ ! "${trigger}" =~ ^[a-z]+$ ]]; then
    trigger="unknown"
fi

session_id="$(jq_str "${input}" '(.session_id // "no-session") | tostring')"
[[ -z "${session_id//[[:space:]]/}" ]] && session_id="no-session"
safe_id="$(printf '%s' "${session_id}" | tr -c 'A-Za-z0-9_-' '_')"

transcript_path="$(jq_str "${input}" 'if (.transcript_path | type) == "string" then .transcript_path else empty end')"

# --- spec prefix alternation (SW-44) ------------------------------------------
# Built-in fallback covers every prefix shipped in
# templates/project-config.template.json (FEAT, BUG, REF, PERF, RCA, PORT).
# Any config-declared prefix that fails the shape check
# ^[A-Z][A-Z0-9]{1,9}$ is dropped silently and the built-in default is used
# only if NOTHING declared validates. Must stay in sync with
# Get-SpecPrefixAlternation in precompact-state.ps1.
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
id_rx="(${spec_prefixes})-[A-Za-z0-9_-]+"

# --- helpers ------------------------------------------------------------------

# `status:` from the leading `---` frontmatter block of 00-spec.md. Only a
# plain token ([A-Za-z0-9_-]+) is accepted. Anything else, a missing file or a
# missing line all yield ''. Same reader as spec_field in session-context.sh.
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

# A candidate is the active spec when its folder holds a 00-spec.md and the
# spec is not finished. A missing or odd status still counts: the folder is
# the evidence that the session was working on it.
is_active_candidate() {
    local id="$1" st
    [[ -f "${spec_path}/${id}/00-spec.md" ]] || return 1
    st="$(spec_status "${spec_path}/${id}/00-spec.md")"
    [[ "${st}" == "done" || "${st}" == "archived" ]] && return 1
    return 0
}

# --- active spec: newest transcript mention -----------------------------------
# Every match in the transcript tail, newest first, each ID once. Spec IDs are
# ASCII, so a multi-byte character cut by `tail -c` cannot change the matches.
# The awk reverse stands in for `tac`, which macOS does not ship.

active=""
if [[ -n "${transcript_path}" && -f "${transcript_path}" ]]; then
    while IFS= read -r cand; do
        cand="${cand%$'\r'}"
        [[ -z "${cand}" ]] && continue
        if is_active_candidate "${cand}"; then
            active="${cand}"
            break
        fi
    done < <(tail -c "${TRANSCRIPT_TAIL_BYTES}" "${transcript_path}" 2>/dev/null \
        | grep -aoE "${id_rx}" 2>/dev/null \
        | awk '{ a[NR] = $0 } END { for (i = NR; i > 0; i--) if (!s[a[i]]++) print a[i] }')
fi

# --- fallback: the sole in-progress index row ---------------------------------
# The ID is the LEFTMOST prefix match on a row containing the literal text
# `in-progress` (as in session-context.sh); used only when there is exactly one.

if [[ -z "${active}" ]]; then
    ip_ids=()
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
    done < "${index_path}"
    if [[ ${#ip_ids[@]} -eq 1 ]] && is_active_candidate "${ip_ids[0]}"; then
        active="${ip_ids[0]}"
    fi
fi

# --- prune pointers older than 24h, as subagent-retro does ---------------------

state_dir="${project_root}/.claude/.hookstate"

get_mtime() {
    local f="$1"
    if [[ ! -e "${f}" ]]; then
        echo "0"
        return
    fi
    if stat -c %Y "${f}" >/dev/null 2>&1; then
        stat -c %Y "${f}"
    elif stat -f %m "${f}" >/dev/null 2>&1; then
        stat -f %m "${f}"
    else
        echo "0"
    fi
}

if [[ -d "${state_dir}" ]]; then
    now_epoch="$(date +%s)"
    cutoff=$(( now_epoch - 24*3600 ))
    while IFS= read -r f; do
        [[ -z "${f}" ]] && continue
        m="$(get_mtime "${f}")"
        if [[ "${m}" =~ ^[0-9]+$ && ${m} -gt 0 && ${m} -lt ${cutoff} ]]; then
            rm -f "${f}" 2>/dev/null || true
        fi
    done < <(find "${state_dir}" -maxdepth 1 -type f -name 'precompact-*.json' 2>/dev/null)
fi

# --- write the pointer --------------------------------------------------------

[[ -z "${active}" ]] && exit 0

mkdir -p "${state_dir}" 2>/dev/null || exit 0
# Both values are regex-constrained, so a literal printf is valid JSON.
printf '{"specId":"%s","trigger":"%s"}\n' "${active}" "${trigger}" \
    > "${state_dir}/precompact-${safe_id}.json" 2>/dev/null || true

exit 0
