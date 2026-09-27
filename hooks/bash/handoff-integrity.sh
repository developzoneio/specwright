#!/usr/bin/env bash
# specwright: PostToolUse hook - handoff-integrity (bash).
#
# Reads Claude Code hook JSON from stdin. After an Edit, Write or MultiEdit
# succeeds, flags the edit in the same turn when the file is outside the
# declared Files of the task being executed (SW-70, ADR 0017):
#   1. Resolve the project root from the cwd (SW-78) and load
#      .claude/project-config.json. hooks.handoffIntegrity.enabled must be the
#      literal JSON true - the hook is OFF by default.
#   2. The spec checked is the newest spec ID in the transcript tail whose
#      folder has a 00-spec.md with status in-progress, and a 02-tasks.md. No
#      fallback: a session driving no in-progress spec is never flagged.
#   3. The active task is the READY SET of 02-tasks.md: every unchecked task
#      whose Depends on tasks are all checked. The declared files are the
#      union of their Files values. No ready task means no active task.
#   4. An edit outside the project root, or inside the spec directory (the
#      main thread's own check-offs and retro lines), is never flagged.
#   5. Otherwise, a file that matches no declared entry prints
#      {"decision":"block","reason":...} to stdout. PostToolUse cannot undo the
#      edit (ADR 0015): the reason reaches the model as feedback, and this hook
#      still exits 0.
#
# Every path exits 0. jq missing, a failure, a missing transcript, spec or task
# file, or an in-scope edit prints nothing. The task parser, the match rules
# and the reason text must stay identical to handoff-integrity.ps1;
# tests/hooks/fixtures/handoff-integrity/ asserts both against one golden.
#
# Note: we deliberately do NOT use `set -u` because bash 3.2's empty-array
# expansion is brittle under it; the hook must never fail noisily.
# Must stay bash-3.2 compatible (macOS system bash): no `declare -A`, no
# `${var,,}`. The awk program must stay POSIX (macOS awk): no interval
# expressions, no gawk extensions.

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

# The write tools the settings template wires this hook on (ADR 0015: never a
# `*` matcher - every spawn costs about 330 ms on PS 5.1).
tool_name="$(jq_str "${input}" 'if (.tool_name | type) == "string" then .tool_name else empty end')"
case "${tool_name}" in
    Edit|Write|MultiEdit) ;;
    *) exit 0 ;;
esac

file_path="$(jq_str "${input}" 'if (.tool_input.file_path | type) == "string" then .tool_input.file_path else empty end')"
if [[ -z "${file_path//[[:space:]]/}" ]]; then
    exit 0
fi

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
# walk, no `cd`/`realpath`. Identical in all seven hooks; mirrors
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

# --- load config --------------------------------------------------------------
# Like stop-gate this hook is opt-in (ADR 0017): a missing or malformed config
# leaves `{}`, which reads as disabled below.
config_path="${project_root}/.claude/project-config.json"
config_json="{}"
if [[ -f "${config_path}" ]]; then
    if jq -e . "${config_path}" >/dev/null 2>&1; then
        config_json="$(cat "${config_path}")"
    fi
fi

# Type-strict: only a literal JSON boolean true enables the hook, to match
# Test-HookEnabled in handoff-integrity.ps1. The string "true" does not.
enabled="$(jq_str "${config_json}" 'if .hooks.handoffIntegrity.enabled == true then "true" else "false" end')"
if [[ "${enabled}" != "true" ]]; then
    exit 0
fi

spec_rel="$(jq_str "${config_json}" '.spec.dir // ".specs"')"
spec_path="${project_root}/${spec_rel}"
if [[ ! -d "${spec_path}" ]]; then
    exit 0
fi

# --- the edited file, relative to the project root ----------------------------
# `/`-separated. A file outside the root is not a project file and is never
# flagged. Paths compare case-insensitively, like the .ps1 twin.
shopt -s nocasematch

file="${file_path//\\//}"
if [[ "${file}" != /* && ! "${file}" =~ ^[A-Za-z]:/ ]]; then
    base="${cwd//\\//}"
    while [[ "${base}" == */ ]]; do base="${base%/}"; done
    file="${base}/${file}"
fi
root="${project_root//\\//}"
while [[ "${root}" == */ ]]; do root="${root%/}"; done
[[ "${file}" == "${root}/"* ]] || exit 0
rel="${file:$(( ${#root} + 1 ))}"
while [[ "${rel}" == ./* ]]; do rel="${rel:2}"; done

# Spec artifacts are the main thread's bookkeeping (check-offs, retro lines,
# decisions), never a task's scope.
spec_prefix="${spec_rel//\\//}"
while [[ "${spec_prefix}" == /* ]]; do spec_prefix="${spec_prefix#/}"; done
while [[ "${spec_prefix}" == */ ]]; do spec_prefix="${spec_prefix%/}"; done
while [[ "${spec_prefix}" == ./* ]]; do spec_prefix="${spec_prefix:2}"; done
[[ "${rel}" == "${spec_prefix}/"* ]] && exit 0

shopt -u nocasematch

transcript_path="$(jq_str "${input}" 'if (.transcript_path | type) == "string" then .transcript_path else empty end')"

# --- spec prefix alternation (SW-44) ------------------------------------------
# Built-in fallback covers every prefix shipped in
# templates/project-config.template.json (FEAT, BUG, REF, PERF, RCA, PORT).
# Any config-declared prefix that fails the shape check
# ^[A-Z][A-Z0-9]{1,9}$ is dropped silently and the built-in default is used
# only if NOTHING declared validates. Must stay in sync with
# Get-SpecPrefixAlternation in handoff-integrity.ps1.
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

# A plain-token frontmatter value (`status:`) from the leading `---` block of
# 00-spec.md. Only [A-Za-z0-9_-]+ is accepted. Anything else, a missing file or
# a missing line all yield ''. Same reader as spec_field in session-context.sh.
spec_field() {
    local file="$1" key="$2" l n=0
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
        if [[ "${l}" =~ ^${key}:[[:blank:]]*([A-Za-z0-9_-]+)[[:blank:]]*$ ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    done < "${file}"
    return 0
}

# A candidate is the spec whose tasks are being executed: its folder holds a
# 00-spec.md with status in-progress, and a 02-tasks.md.
is_active_candidate() {
    local id="$1"
    [[ -f "${spec_path}/${id}/00-spec.md" ]] || return 1
    [[ -f "${spec_path}/${id}/02-tasks.md" ]] || return 1
    [[ "$(spec_field "${spec_path}/${id}/00-spec.md" status)" == "in-progress" ]]
}

# --- spec being driven: newest transcript mention -----------------------------
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

[[ -z "${active}" ]] && exit 0

# A spec file as text: CRs and a leading BOM removed, and every <!-- ... -->
# comment dropped, so an example task block inside a comment is never read as a
# task. Fails (status 1) when the file is absent. Same as doc_text in
# stop-gate.sh.
doc_text() {
    [[ -f "$1" ]] || return 1
    jq -Rrs 'gsub("\r"; "") | ltrimstr([65279] | implode) | gsub("<!--[\\s\\S]*?-->"; "")' "$1" 2>/dev/null | tr -d '\r'
}

tasks_text="$(doc_text "${spec_path}/${active}/02-tasks.md")" || exit 0

# --- 02-tasks.md parser (sd-atomic-task-format) -------------------------------
# Field label grammar: `-` or `*` bullet, optional `**`, colon inside or outside
# the emphasis, label case-insensitive. Only the labels the format defines
# start a new field; any other line inside a block continues the field above
# it, so a multi-line Files value keeps its nested bullets.
#
# Prints `I<TAB><id>` for each task in the READY SET (unchecked, every Depends
# on task checked) and `F<TAB><entry>` for each of its Files entries, in
# document order. A dependency on an ID the file does not define counts as met
# - the hook errs toward silence. Status decides when present; a `[x]` or
# check-mark heading prefix counts only when Status is absent; the last block
# wins on a repeat ID. Mirrors Get-ReadySet and Get-FileEntries in the .ps1.
ready_set() {
    awk '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function flush() {
    if (cur == "") return
    n++
    tid[n] = cur; tdrift[n] = drift; tstat[n] = stat; thas[n] = hasstat
    tdeps[n] = deps; tfiles[n] = files
    cur = ""
}
function is_checked(i) { return thas[i] ? (tstat[i] == "done") : tdrift[i] }
BEGIN {
    cur = ""; field = ""; n = 0
    label = "^[ \t]*[-*][ \t]+(\\*\\*)?[ \t]*(files|layer|step type|test|acceptance|covers|depends on|conflicts with|estimated complexity|reversibility|pattern refs|status|parallel batch|revised-by)[ \t]*(:[ \t]*\\*\\*|\\*\\*[ \t]*:|:)"
}
{
    line = $0
    if (line ~ /^(#|##|###)[ \t]/) {
        flush(); field = ""
        if (substr(line, 1, 4) == "### " && match(line, /(^|[^A-Za-z0-9_])T[0-9]+([^A-Za-z0-9_]|$)/)) {
            idstart = RSTART + index(substr(line, RSTART, RLENGTH), "T") - 1
            rest = substr(line, idstart)
            match(rest, /^T[0-9]+/)
            prefix = substr(line, 1, idstart - 1)
            cur = substr(rest, 1, RLENGTH)
            drift = (index(tolower(prefix), "[x]") > 0 || index(prefix, "\342\234\205") > 0) ? 1 : 0
            stat = ""; hasstat = 0; deps = ""; files = ""
        }
        next
    }
    if (cur == "") next
    low = tolower(line)
    if (match(low, label)) {
        value = substr(line, RSTART + RLENGTH)
        name = substr(low, RSTART, RLENGTH)
        sub(/^[ \t]*[-*][ \t]+/, "", name); gsub(/\*/, "", name); sub(/:.*$/, "", name)
        field = trim(name)
        if (field == "files") files = value
        else if (field == "depends on") deps = value
        else if (field == "status") {
            v = value; gsub(/`/, "", v); gsub(/\*/, "", v); v = tolower(trim(v))
            stat = (match(v, /^[a-z-]+/) ? substr(v, 1, RLENGTH) : "")
            hasstat = 1
        }
        next
    }
    if (field == "files") files = files "\n" line
    else if (field == "depends on") deps = deps "\n" line
}
END {
    flush()
    for (i = 1; i <= n; i++) chk[tid[i]] = is_checked(i)
    for (i = 1; i <= n; i++) {
        if (is_checked(i)) continue
        ok = 1; d = tdeps[i]
        while (match(d, /T[0-9]+/)) {
            dep = substr(d, RSTART, RLENGTH); d = substr(d, RSTART + RLENGTH)
            if ((dep in chk) && !chk[dep]) { ok = 0; break }
        }
        if (!ok) continue
        print "I\t" tid[i]
        m = split(tfiles[i], parts, "[,\n]")
        for (j = 1; j <= m; j++) {
            p = trim(parts[j])
            sub(/^[-*+][ \t]+/, "", p)
            gsub(/`/, "", p); gsub(/"/, "", p); p = trim(p)
            sub(/[ \t]+\(.*$/, "", p)
            if (!match(p, /^[^ \t]+/)) continue
            p = substr(p, 1, RLENGTH)
            gsub(/\\/, "/", p)
            while (substr(p, 1, 2) == "./") p = substr(p, 3)
            if (p == "" || tolower(p) == "none") continue
            print "F\t" p
        }
    }
}' 2>/dev/null
}

ids=()
entries=()
while IFS= read -r row; do
    row="${row%$'\r'}"
    case "${row}" in
        I$'\t'*) ids+=("${row#I$'\t'}") ;;
        F$'\t'*) entries+=("${row#F$'\t'}") ;;
    esac
done < <(printf '%s\n' "${tasks_text}" | ready_set)

[[ ${#ids[@]} -eq 0 ]] && exit 0

# Case-insensitive, like the .ps1 twin: an exact path, a directory entry ending
# in `/` that prefixes the path, or an entry carrying `*` or `?` as a wildcard
# pattern (deliberately unquoted below).
shopt -s nocasematch
for e in "${entries[@]}"; do
    [[ "${rel}" == "${e}" ]] && exit 0
    [[ "${e}" == */ && "${rel}" == "${e}"* ]] && exit 0
    if [[ "${e}" == *[*?]* ]]; then
        # shellcheck disable=SC2053
        [[ "${rel}" == ${e} ]] && exit 0
    fi
done
shopt -u nocasematch

joined=""
for t in "${ids[@]}"; do
    if [[ -n "${joined}" ]]; then joined+=", ${t}"; else joined="${t}"; fi
done

reason="specwright handoff-integrity: ${rel} is outside the declared Files of ${active}'s ready task(s) ${joined}. PostToolUse cannot undo it: the edit is already on disk. If it is out of scope, revert it. If the task needs this file, stop and surface a scope mismatch so the plan can be revised (sd-replan-loop) - do not widen the task silently."
jq -nc --arg r "${reason}" '{decision:"block",reason:$r}' 2>/dev/null | tr -d '\r'
exit 0
