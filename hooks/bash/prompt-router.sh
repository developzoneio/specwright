#!/usr/bin/env bash
# specwright: UserPromptSubmit hook - prompt-router (bash).
#
# Reads Claude Code hook JSON from stdin. Emits a <context-router> block on
# stdout when workflow keywords, ticket IDs, or in-progress specs are detected.
# Exits 0 silently if jq is missing, if stdin is empty/invalid, or if no hints
# apply. Never writes to disk.
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

prompt="$(printf '%s' "${input}" | jq -r '.prompt // empty' 2>/dev/null)"
cwd="$(printf '%s' "${input}"    | jq -r '.cwd    // empty' 2>/dev/null)"

if [[ -z "${prompt}" || -z "${cwd}" ]]; then
    exit 0
fi
if [[ ! -d "${cwd}" ]]; then
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
# reads has a `//` default below (and match_keywords has $default_list), and
# those defaults are the same values as $defaults in prompt-router.ps1. Any new
# read must keep that property or the fallback has to become a full default
# document, as it is in spec-gate.sh.
config_path="${project_root}/.claude/project-config.json"
config_json="{}"
if [[ -f "${config_path}" ]]; then
    if jq -e . "${config_path}" >/dev/null 2>&1; then
        config_json="$(cat "${config_path}")"
    fi
fi

# Hook enabled? The jq alternative operator treats an explicit `false` as
# absent, so compare directly against `false` instead of relying on it here.
enabled="$(printf '%s' "${config_json}" | jq -r 'if .hooks.userPromptRouter.enabled == false then "false" else "true" end' 2>/dev/null)"
if [[ "${enabled}" == "false" ]]; then
    exit 0
fi

spec_dir="$(printf '%s' "${config_json}"   | jq -r '.spec.dir       // ".specs"'         2>/dev/null)"
index_rel="$(printf '%s' "${config_json}"  | jq -r '.spec.indexFile // ".specs/index.md"' 2>/dev/null)"
ticket_pat="$(printf '%s' "${config_json}" | jq -r '.ticket.pattern // "^[A-Z]+-[0-9]+$"' 2>/dev/null)"

spec_path="${project_root}/${spec_dir}"
index_path="${project_root}/${index_rel}"

# --- spec prefix alternation (SW-44) ------------------------------------------
# Built-in fallback covers every prefix shipped in
# templates/project-config.template.json (FEAT, BUG, REF, PERF, RCA, PORT).
# Any config-declared prefix that fails the shape check
# ^[A-Z][A-Z0-9]{1,9}$ is dropped silently and the built-in default is used
# only if NOTHING declared validates. Must stay in sync with
# Get-SpecPrefixAlternation in prompt-router.ps1.
readonly SD_DEFAULT_SPEC_PREFIXES='FEAT|BUG|REF|PERF|RCA|PORT'

resolve_spec_prefixes() {
    local raw valid=() p
    raw="$(printf '%s' "${config_json}" | jq -r '.spec.prefixes // {} | to_entries[]?.value // empty' 2>/dev/null)"
    if [[ -z "${raw}" ]]; then
        printf '%s' "${SD_DEFAULT_SPEC_PREFIXES}"
        return 0
    fi
    while IFS= read -r p; do
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

# --- keyword match ------------------------------------------------------------

prompt_lower="$(printf '%s' "${prompt}" | tr '[:upper:]' '[:lower:]')"
# Parallel indexed arrays (bash 3.2 has no associative arrays): index i holds
# the i-th matched workflow and its comma-joined matched terms.
matched_workflows=()
matched_terms_list=()

match_keywords() {
    local workflow="$1"
    local default_list="$2"
    local list
    list="$(printf '%s' "${config_json}" | jq -r --arg w "${workflow}" '.workflow.keywords[$w] // []  | join("\n")' 2>/dev/null)"
    if [[ -z "${list}" ]]; then
        list="${default_list}"
    fi
    local kw terms=""
    while IFS= read -r kw; do
        # Some jq builds (e.g. Windows jq.exe) emit CRLF for join("\n") output;
        # strip a trailing CR so the comparison below isn't corrupted.
        kw="${kw%$'\r'}"
        [[ -z "${kw}" ]] && continue
        local kw_lower
        kw_lower="$(printf '%s' "${kw}" | tr '[:upper:]' '[:lower:]')"
        if [[ "${prompt_lower}" == *"${kw_lower}"* ]]; then
            if [[ -z "${terms}" ]]; then
                terms="${kw}"
            else
                terms="${terms}, ${kw}"
            fi
        fi
    done <<< "${list}"
    if [[ -n "${terms}" ]]; then
        matched_workflows+=("${workflow}")
        matched_terms_list+=("${terms}")
    fi
}

match_keywords bug      $'bug\nfix\nbroken\nerror\ncrash\nregression\ndefect'
match_keywords feature  $'feature\nadd\nimplement\nnew\nsupport'
match_keywords refactor $'refactor\nrestructure\nclean up\nextract\nrename'
match_keywords perf     $'perf\nperformance\nslow\noptimize\nlatency\nthroughput'
match_keywords rca      $'incident\noutage\nrca\nroot cause\npost-mortem\npostmortem'
match_keywords port     $'backport\nport from\nport the\ndonor repo\nmirror from\nreplicate from'

# --- ticket detection ---------------------------------------------------------

ticket_body="${ticket_pat#^}"
ticket_body="${ticket_body%\$}"

declare -a ticket_ids=()
if [[ -n "${ticket_body}" ]]; then
    while IFS= read -r tid; do
        [[ -z "${tid}" ]] && continue
        # de-dup
        local_found=0
        for existing in "${ticket_ids[@]:-}"; do
            if [[ "${existing}" == "${tid}" ]]; then local_found=1; break; fi
        done
        if [[ ${local_found} -eq 0 ]]; then
            ticket_ids+=("${tid}")
        fi
    done < <(printf '%s' "${prompt}" | grep -oE "${ticket_body}" 2>/dev/null || true)
fi

# --- spec folder match --------------------------------------------------------

declare -a ticket_specs=()
if [[ -d "${spec_path}" && ${#ticket_ids[@]} -gt 0 ]]; then
    while IFS= read -r folder; do
        base="$(basename "${folder}")"
        for tid in "${ticket_ids[@]}"; do
            if [[ "${base}" == *"${tid}"* ]]; then
                ticket_specs+=("${base}")
                break
            fi
        done
    done < <(find "${spec_path}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
fi

# --- in-progress specs --------------------------------------------------------

declare -a in_progress=()
if [[ -f "${index_path}" ]]; then
    while IFS= read -r id; do
        [[ -z "${id}" ]] && continue
        dup=0
        for existing in "${in_progress[@]:-}"; do
            if [[ "${existing}" == "${id}" ]]; then dup=1; break; fi
        done
        [[ ${dup} -eq 0 ]] && in_progress+=("${id}")
    done < <(grep 'in-progress' "${index_path}" 2>/dev/null | grep -oE "(${spec_prefixes})-[A-Za-z0-9_-]+" || true)
fi

# --- nothing to say? ----------------------------------------------------------

if [[ ${#matched_workflows[@]} -eq 0 && ${#ticket_ids[@]} -eq 0 && ${#in_progress[@]} -eq 0 ]]; then
    exit 0
fi

# --- emit context-router block -----------------------------------------------

{
    echo '<context-router>'
    echo 'Routing hints from specwright (UserPromptSubmit hook):'

    if [[ ${#matched_workflows[@]} -gt 0 ]]; then
        echo ''
        echo 'Workflow keyword matches:'
        for ((i=0; i<${#matched_workflows[@]}; i++)); do
            echo "  - /sd:${matched_workflows[i]}  (matched: ${matched_terms_list[i]})"
        done
    fi

    if [[ ${#ticket_ids[@]} -gt 0 ]]; then
        echo ''
        printf 'Ticket IDs detected: '
        printf '%s' "${ticket_ids[0]}"
        for ((i=1; i<${#ticket_ids[@]}; i++)); do printf ', %s' "${ticket_ids[i]}"; done
        printf '\n'

        if [[ ${#ticket_specs[@]} -gt 0 ]]; then
            echo 'Matching spec folders under .specs/:'
            for s in "${ticket_specs[@]}"; do echo "  - ${s}"; done
        else
            echo 'No matching spec folder found. Consider /sd:feature or /sd:bug to create one.'
        fi
    fi

    if [[ ${#in_progress[@]} -gt 0 ]]; then
        echo ''
        echo 'Specs currently in-progress (from .specs/index.md):'
        for s in "${in_progress[@]}"; do echo "  - ${s}"; done
    fi

    echo '</context-router>'
}

exit 0
