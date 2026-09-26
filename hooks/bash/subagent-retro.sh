#!/usr/bin/env bash
# specwright: SubagentStop hook - subagent-retro (bash).
#
# After a subagent finishes:
#   1. Load .claude/project-config.json (or defaults).
#   2. Parse .specs/index.md for in-progress specs (skip RCAs).
#   3. For each, check mtime of <spec>/05-retro.md vs retroStaleMinutes.
#   4. Debounce per session via .claude/.hookstate/subagent-retro-<sid>.json.
#   5. Emit <retro-reminder> block if any stale retros AND debounce elapsed.
#   6. Clean up state files older than 24h.
#
# Note: hooks must never fail noisily. `set -u` is intentionally omitted.

if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

input="$(cat 2>/dev/null || true)"
if [[ -z "${input}" ]]; then
    exit 0
fi

cwd="$(printf '%s' "${input}" | jq -r '.cwd // empty' 2>/dev/null)"
if [[ -z "${cwd}" ]]; then
    cwd="$(pwd)"
fi
if [[ ! -d "${cwd}" ]]; then
    exit 0
fi

# --- project root (SW-78) -----------------------------------------------------
# `cwd` is the session's CURRENT directory, and a Bash `cd` moves it. Reading
# config, specs, hook state and the metrics log relative to it made a session
# sitting in a subdirectory miss every spec and grow a nested .specs/_metrics/
# and .claude/.hookstate/ there. Everything below resolves against the root:
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

session_id="$(printf '%s' "${input}" | jq -r '.session_id // "no-session"' 2>/dev/null)"
safe_id="$(printf '%s' "${session_id}" | tr -c 'A-Za-z0-9_-' '_')"

# --- load config --------------------------------------------------------------

# An empty object is a safe fallback HERE only because every value this hook
# reads has a `//` default below, and those defaults are the same values as
# $defaults in subagent-retro.ps1. Any new read must keep that property or the
# fallback has to become a full default document, as it is in spec-gate.sh.
config_path="${project_root}/.claude/project-config.json"
config_json="{}"
if [[ -f "${config_path}" ]] && jq -e . "${config_path}" >/dev/null 2>&1; then
    config_json="$(cat "${config_path}")"
fi

# The jq alternative operator treats an explicit `false` as absent, so
# compare directly against `false` instead of relying on it here.
enabled="$(printf '%s' "${config_json}" | jq -r 'if .hooks.subagentRetro.enabled == false then "false" else "true" end' 2>/dev/null)"
if [[ "${enabled}" == "false" ]]; then
    exit 0
fi

stale_minutes="$(printf '%s' "${config_json}"    | jq -r '.hooks.subagentRetro.retroStaleMinutes // 30' 2>/dev/null)"
debounce_minutes="$(printf '%s' "${config_json}" | jq -r '.hooks.subagentRetro.debounceMinutes // 10'   2>/dev/null)"

# Lesson injection (SW-19). Same `== false` comparison as the enabled flag above:
# the jq alternative operator treats an explicit `false` as absent.
inject_lessons="$(printf '%s' "${config_json}" | jq -r 'if .hooks.subagentRetro.injectLessons == false then "false" else "true" end' 2>/dev/null)"
max_lessons="$(printf '%s' "${config_json}"    | jq -r '.hooks.subagentRetro.maxLessons // 3' 2>/dev/null)"
if [[ ! "${max_lessons}" =~ ^[0-9]+$ ]]; then
    max_lessons=3
fi

spec_dir_rel="$(printf '%s' "${config_json}" | jq -r '.spec.dir       // ".specs"'         2>/dev/null)"
index_rel="$(printf '%s' "${config_json}"    | jq -r '.spec.indexFile // ".specs/index.md"' 2>/dev/null)"

# --- spec prefix alternation (SW-44) ------------------------------------------
# Built-in fallback covers every prefix shipped in
# templates/project-config.template.json (FEAT, BUG, REF, PERF, RCA, PORT).
# Any config-declared prefix that fails the shape check
# ^[A-Z][A-Z0-9]{1,9}$ is dropped silently and the built-in default is used
# only if NOTHING declared validates. Must stay in sync with
# Get-SpecPrefixAlternation in subagent-retro.ps1.
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

spec_dir="${project_root}/${spec_dir_rel}"
index_path="${project_root}/${index_rel}"

state_dir="${project_root}/.claude/.hookstate"
state_path="${state_dir}/subagent-retro-${safe_id}.json"
lessons_path="${spec_dir}/_lessons/lessons.md"

# --- session state ------------------------------------------------------------
#
# Read once, written once. The state file is an ON-DISK CONTRACT shared with
# subagent-retro.ps1 (see write_state below) and now carries two keys:
#   lastReminderUtc - debounce stamp for the stale-retro reminder.
#   shownLessons    - lesson lines already surfaced in THIS session.
# Both writers must preserve the key they are not updating, or a reminder would
# wipe the session's lesson history and every lesson would repeat.

state_last_iso=""
declare -a shown_lessons=()
if [[ -f "${state_path}" ]]; then
    # Windows jq.exe emits CRLF, so every value read here can carry a trailing
    # CR. On a lesson line that CR makes the already-shown comparison below fail
    # against the identical line read from lessons.md, and every lesson repeats
    # forever; on the timestamp it corrupts the date parse. Same hazard the
    # prompt-router already documents for join("\n") output - strip it at the
    # boundary, once, rather than at each use.
    state_last_iso="$(jq -r '.lastReminderUtc // empty' "${state_path}" 2>/dev/null || true)"
    state_last_iso="${state_last_iso%$'\r'}"
    while IFS= read -r shown_line; do
        shown_line="${shown_line%$'\r'}"
        [[ -n "${shown_line}" ]] && shown_lessons+=("${shown_line}")
    done < <(jq -r '.shownLessons[]? // empty' "${state_path}" 2>/dev/null || true)
fi

write_state() {
    mkdir -p "${state_dir}" 2>/dev/null || true
    local shown_json
    shown_json="$(printf '%s\n' "${shown_lessons[@]:-}" \
        | jq -R . 2>/dev/null | jq -sc 'map(select(length > 0))' 2>/dev/null)" || shown_json=''
    [[ -z "${shown_json}" ]] && shown_json='[]'
    jq -nc --arg t "${state_last_iso}" --argjson s "${shown_json}" \
        'if $t == "" then {shownLessons:$s} else {lastReminderUtc:$t, shownLessons:$s} end' \
        > "${state_path}" 2>/dev/null || true
}

# --- metrics: shared event writer -----------------------------------------
# Duplicated verbatim from spec-gate.sh (hooks are standalone scripts with no
# shared library - keeping the two copies textually identical makes any
# future drift between them greppable). Append-only, metadata-only event log
# for the retro loop (SW-10). Every failure path here is a silent no-op -
# metrics must NEVER surface as a hook error. Emitted regardless of debounce;
# see the emit_subagent_stop_metric call site below.

# A metrics path is not an arbitrary-write primitive: reject anything rooted
# (leading '/' or a drive-letter prefix) or that escapes the root via '..' rather
# than ever writing outside the workspace. Reuses the same rootedness test and
# dot-segment collapse used for the gate's own path safety above, so the two
# checks cannot silently diverge. Mirrors Test-MetricsPathSafe in
# spec-gate.ps1.
metrics_path_is_safe() {
    local p="$1"
    [[ -z "${p}" ]] && return 1
    if [[ "${p}" == /* || "${p}" == ?:* ]]; then
        return 1
    fi
    local collapsed
    collapsed="$(collapse_dot_segments "${p//\\//}")"
    if [[ "${collapsed}" == ".." || "${collapsed}" == "../"* ]]; then
        return 1
    fi
    return 0
}

# $1 = a complete JSON object literal string containing every field EXCEPT
# ts, already in fixed key order (spec_id, phase, event, ...). ts is prepended
# here so each call site only has to build the part specific to its own event
# kind. jq's object-add operator appends keys from the right operand that are
# not already present in the left, in their own original order - since ts is
# never present in the body, this reliably yields ts first followed by the
# body's keys in the order the caller wrote them.
write_metric_line() {
    local body="$1"

    local metrics_enabled
    # `//` treats an explicit `false` as absent, so compare directly against
    # `false` (type-strict: only a literal JSON boolean false disables this).
    metrics_enabled="$(printf '%s' "${config_json}" | jq -r 'if .hooks.metrics.enabled == false then "false" else "true" end' 2>/dev/null)"
    [[ "${metrics_enabled}" == "false" ]] && return 0

    local metrics_path
    metrics_path="$(printf '%s' "${config_json}" | jq -r '.hooks.metrics.path // ".specs/_metrics/events.jsonl"' 2>/dev/null)"
    metrics_path="${metrics_path//\\//}"
    metrics_path_is_safe "${metrics_path}" || return 0

    local full_path="${project_root}/${metrics_path}"
    mkdir -p "$(dirname "${full_path}")" 2>/dev/null || return 0

    local ts
    ts="$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u)"

    local line
    line="$(printf '%s' "${body}" | jq -c --arg ts "${ts}" '{ts:$ts} + .' 2>/dev/null)"
    [[ -z "${line}" ]] && return 0

    # --- rotation (SW-15) -----------------------------------------------------
    # Bounded log: before appending, if the live file already meets or exceeds
    # the byte cap, roll it to `.1` (single generation, overwriting any prior
    # roll). maxSizeKb defaults to 1024 when the key is ABSENT, so a
    # project-config.json written before SW-15 - and this hook's own `{}`
    # no-config fallback - still gets a bounded log with no edit; an explicit 0
    # or negative disables rotation (the opt-out) and any non-number is invalid
    # and also disables it (SW-22 scar - never let a bad type silently flip
    # behavior). Best-effort - every failure path (a file the other hook holds
    # open on Windows, a read-only dir) is a silent no-op that falls through to
    # the append below: rotation must NEVER stop the append (silent data loss
    # reads as "metrics working", which the ticket flags as worse than growth)
    # nor surface as a hook error. jq floors maxSizeKb*1024 to an integer so
    # bash never does float math; `wc -c` is the byte count Write-MetricEvent
    # also measures, and the absent->1024 / bad-type->off rules match its guard,
    # so PS and bash trip at the same boundary.
    local max_bytes
    max_bytes="$(printf '%s' "${config_json}" | jq -r '(if (.hooks.metrics | type) == "object" and (.hooks.metrics | has("maxSizeKb")) then .hooks.metrics.maxSizeKb else 1024 end) as $k | if ($k | type) == "number" and $k > 0 then ($k * 1024 | floor) else "" end' 2>/dev/null)"
    if [[ -n "${max_bytes}" && -f "${full_path}" ]]; then
        local cur_bytes
        cur_bytes="$(wc -c < "${full_path}" 2>/dev/null | tr -d '[:space:]')"
        if [[ "${cur_bytes}" =~ ^[0-9]+$ && "${cur_bytes}" -ge "${max_bytes}" ]]; then
            mv -f "${full_path}" "${full_path}.1" 2>/dev/null || true
        fi
    fi

    printf '%s\n' "${line}" >> "${full_path}" 2>/dev/null || true
    return 0
}

# Collapses '.' and '..' segments in a forward-slash path using pure string
# processing - no filesystem access, no `realpath`/`readlink -f`/`cd`. Mirrors
# collapse_dot_segments in spec-gate.sh exactly (duplicated verbatim - see the
# metrics writer note above). Only used here by metrics_path_is_safe.
collapse_dot_segments() {
    local path="$1"
    local root_prefix="" body="${path}"
    if [[ "${path}" == /* ]]; then
        root_prefix="/"
        body="${path#/}"
    elif [[ "${path}" == ?:* ]]; then
        root_prefix="${path:0:2}/"
        body="${path:2}"
        body="${body#/}"
    fi

    local rooted=0
    [[ -n "${root_prefix}" ]] && rooted=1

    local acc="" seg rest="${body}"
    while [[ -n "${rest}" ]]; do
        seg="${rest%%/*}"
        if [[ "${rest}" == */* ]]; then
            rest="${rest#*/}"
        else
            rest=""
        fi
        case "${seg}" in
            ''|'.')
                continue
                ;;
            '..')
                if [[ -n "${acc}" ]]; then
                    local last="${acc##*/}"
                    if [[ "${last}" == '..' ]]; then
                        # Already-stacked leading '..' (unrooted overflow) - keep stacking.
                        acc="${acc}/.."
                    else
                        local trimmed="${acc%/*}"
                        if [[ "${trimmed}" == "${acc}" ]]; then
                            # acc was a single segment with no slash - pop to empty.
                            acc=""
                        else
                            acc="${trimmed}"
                        fi
                    fi
                elif [[ ${rooted} -eq 1 ]]; then
                    # Cannot go above the root - drop it, matching GetFullPath's clamp.
                    :
                else
                    # No root to clamp against - keep the unresolved '..'.
                    acc=".."
                fi
                ;;
            *)
                if [[ -z "${acc}" ]]; then
                    acc="${seg}"
                else
                    acc="${acc}/${seg}"
                fi
                ;;
        esac
    done

    printf '%s%s' "${root_prefix}" "${acc}"
}

# subagent_stop metric: $1=spec_id $2=phase $3=stale (0 or 1)
emit_subagent_stop_metric() {
    local spec_id="$1" phase="$2" stale="$3"
    local body
    body="$(jq -nc --arg spec_id "${spec_id}" --arg phase "${phase}" --argjson stale "${stale}" \
        '{spec_id:$spec_id,phase:$phase,event:"subagent_stop",stale:$stale}' 2>/dev/null)"
    [[ -z "${body}" ]] && return 0
    write_metric_line "${body}"
}

# --- portable mtime helper (Linux: -c %Y; macOS/BSD: -f %m) -------------------

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

# --- cleanup old state files (>24h) ------------------------------------------

if [[ -d "${state_dir}" ]]; then
    now_epoch="$(date +%s)"
    cutoff=$(( now_epoch - 24*3600 ))
    while IFS= read -r f; do
        [[ -z "${f}" ]] && continue
        m="$(get_mtime "${f}")"
        if [[ "${m}" =~ ^[0-9]+$ && ${m} -gt 0 && ${m} -lt ${cutoff} ]]; then
            rm -f "${f}" 2>/dev/null || true
        fi
    done < <(find "${state_dir}" -maxdepth 1 -type f -name 'subagent-retro-*.json' 2>/dev/null)
fi

# --- parse in-progress specs --------------------------------------------------

declare -a specs=()
declare -a spec_types=()

if [[ -f "${index_path}" ]]; then
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        if [[ "${line}" == *in-progress* ]]; then
            id="$(printf '%s' "${line}" | grep -oE "(${spec_prefixes})-[A-Za-z0-9_-]+" | head -n1)"
            if [[ -n "${id}" ]]; then
                dup=0
                for existing in "${specs[@]:-}"; do
                    if [[ "${existing}" == "${id}" ]]; then dup=1; break; fi
                done
                if [[ ${dup} -eq 0 ]]; then
                    specs+=("${id}")
                    spec_types+=("${id%%-*}")
                fi
            fi
        fi
    done < "${index_path}"
fi

if [[ ${#specs[@]} -eq 0 ]]; then
    exit 0
fi

# --- collect stale / missing retros (skip RCAs) ------------------------------

declare -a stale_id=()
declare -a stale_reason=()
declare -a stale_age=()

now_epoch="$(date +%s)"
threshold_secs=$(( stale_minutes * 60 ))

for i in "${!specs[@]}"; do
    sid="${specs[$i]}"
    stype="${spec_types[$i]}"
    if [[ "${stype}" == "RCA" ]]; then
        continue
    fi
    retro="${spec_dir}/${sid}/05-retro.md"
    if [[ ! -f "${retro}" ]]; then
        stale_id+=("${sid}")
        stale_reason+=("missing")
        stale_age+=("-1")
        continue
    fi
    m="$(get_mtime "${retro}")"
    if [[ ! "${m}" =~ ^[0-9]+$ || ${m} -eq 0 ]]; then
        continue
    fi
    age=$(( now_epoch - m ))
    if (( age >= threshold_secs )); then
        stale_id+=("${sid}")
        stale_reason+=("stale")
        # Round to the nearest minute rather than truncating, so the reported
        # age matches subagent-retro.ps1's [Math]::Round on the same mtime.
        stale_age+=("$(( (age + 30) / 60 ))")
    fi
done

# Metrics: one subagent_stop event per in-progress spec, emitted regardless
# of staleness or debounce - debounce below only suppresses the user-facing
# reminder, never this measurement (SW-10). A spec not in stale_id[]
# (including every RCA, which the loop above always skips) reports stale=0.
for i in "${!specs[@]}"; do
    sid="${specs[$i]}"
    is_stale=0
    for s in "${stale_id[@]:-}"; do
        if [[ "${s}" == "${sid}" ]]; then
            is_stale=1
            break
        fi
    done
    emit_subagent_stop_metric "${sid}" "in-progress" "${is_stale}"
done

# --- lesson injection (SW-19) -------------------------------------------------
#
# PLACEMENT IS LOAD-BEARING. This sits beside the metrics emit above, BEFORE the
# staleness early-exit and BEFORE the debounce window - deliberately, and for the
# same reason the metrics call site does. Moved down to the reminder block, it
# would only ever surface lessons to users who are already behind on their
# retros, which is exactly the population that needs them least.
#
# The one gate it does keep is the in-progress-spec check further up: no spec in
# flight, no output. That gate IS the relevance filter - the workflow type of the
# in-progress spec selects which lessons apply, so there is no ranking, no
# scoring, and therefore no tie-break that could diverge from the PowerShell
# twin.
#
# Repetition is bounded per SESSION, not by a clock. shownLessons in the state
# file records what has already been surfaced, so maxLessons caps how many NEW
# lessons appear at one stop and a session converges to silence once it has said
# everything relevant. A time debounce was rejected: it would suppress a lesson
# the user has never seen purely because a different one was shown recently.

emit_lessons() {
    [[ "${inject_lessons}" == "false" ]] && return 0
    [[ "${max_lessons}" -gt 0 ]] || return 0
    [[ -f "${lessons_path}" ]] || return 0

    # Scope selector: the workflow types currently in flight, plus 'all'.
    local wanted=" all "
    local sid stype
    for sid in "${specs[@]}"; do
        stype="${sid%%-*}"
        case "${stype}" in
            FEAT) wanted="${wanted}feature " ;;
            BUG)  wanted="${wanted}bug " ;;
            REF)  wanted="${wanted}refactor " ;;
            PERF) wanted="${wanted}perf " ;;
            RCA)  wanted="${wanted}rca " ;;
            PORT) wanted="${wanted}port " ;;
        esac
    done

    local lesson_re='^- \[([a-z-]+)\] ([a-z]+)/([a-z]+): (.+)$'
    local -a picked=()
    local line scope already prev

    # File order is the selection order. lessons.md is rendered in a total,
    # deterministic order by aggregate-lessons.*, so "the first N that match" is
    # itself deterministic - no sorting is done or needed here.
    while IFS= read -r line || [[ -n "${line}" ]]; do
        line="${line%$'\r'}"
        [[ "${line}" == "- ["* ]] || continue
        [[ "${line}" =~ ${lesson_re} ]] || continue

        scope="${BASH_REMATCH[3]}"
        [[ "${wanted}" == *" ${scope} "* ]] || continue

        already=0
        for prev in "${shown_lessons[@]:-}"; do
            if [[ "${prev}" == "${line}" ]]; then already=1; break; fi
        done
        [[ ${already} -eq 1 ]] && continue

        picked+=("${line}")
        [[ ${#picked[@]} -ge ${max_lessons} ]] && break
    done < "${lessons_path}"

    [[ ${#picked[@]} -gt 0 ]] || return 0

    {
        echo '<retro-lessons>'
        echo 'Lessons recorded in earlier retros of this project, matching the workflow'
        echo 'type of the spec(s) currently in progress:'
        for line in "${picked[@]}"; do
            echo "  ${line}"
        done
        echo ''
        echo 'These are not shown again this session.'
        echo '</retro-lessons>'
    }

    for line in "${picked[@]}"; do
        shown_lessons+=("${line}")
    done
    write_state
    return 0
}

emit_lessons

if [[ ${#stale_id[@]} -eq 0 ]]; then
    exit 0
fi

# --- debounce -----------------------------------------------------------------

debounce_secs=$(( debounce_minutes * 60 ))
# Reads the stamp captured in the single state read near the top rather than
# re-reading the file: emit_lessons may have rewritten it a moment ago, and that
# write never touches lastReminderUtc.
last_iso="${state_last_iso}"
if [[ -n "${last_iso}" ]]; then
    # Strip the UTC marker and any fractional seconds. BSD date's -f cannot
    # be given trailing unconverted text (it warns on stderr, which would
    # break the hook's silence), and a state file written by an older
    # subagent-retro.ps1 carries 7 fractional digits.
    iso_trimmed="${last_iso%Z}"
    iso_trimmed="${iso_trimmed%.*}"
    # Convert ISO8601 to epoch. GNU date supports -d; BSD date needs -j -f.
    # Both branches must interpret the value as UTC - it is written as UTC
    # by both implementations, so a local-time reading would skew the
    # debounce window by the machine's offset.
    last_epoch=""
    if last_epoch="$(date -u -d "${last_iso}" +%s 2>/dev/null)"; then
        :
    elif last_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "${iso_trimmed}" +%s 2>/dev/null)"; then
        :
    else
        last_epoch=""
    fi
    if [[ -n "${last_epoch}" && "${last_epoch}" =~ ^[0-9]+$ ]]; then
        if (( now_epoch - last_epoch < debounce_secs )); then
            exit 0
        fi
    fi
fi

# --- emit -------------------------------------------------------------------

{
    echo '<retro-reminder>'
    echo 'Retro files appear stale or missing for the following in-progress specs:'
    for i in "${!stale_id[@]}"; do
        sid="${stale_id[$i]}"
        reason="${stale_reason[$i]}"
        age="${stale_age[$i]}"
        if [[ "${reason}" == "missing" ]]; then
            echo "  - ${sid}: 05-retro.md missing"
        else
            echo "  - ${sid}: 05-retro.md last touched ${age} min ago (threshold ${stale_minutes} min)"
        fi
    done
    echo ''
    echo 'Consider appending: decisions made, surprises encountered, follow-ups identified.'
    echo '</retro-reminder>'
}

# --- save state --------------------------------------------------------------

# State-file shape is an ON-DISK CONTRACT shared with subagent-retro.ps1: a
# session can write it under one implementation and read it under the other, so
# both keys and the whole-second UTC format must stay identical in both.
# write_state re-emits shownLessons alongside the new stamp - dropping it here
# would clear the session's lesson history and make every lesson repeat.
state_last_iso="$(date -u +'%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u)"
write_state

exit 0
