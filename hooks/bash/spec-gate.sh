#!/usr/bin/env bash
# specwright: PreToolUse hook - spec-gate (bash).
#
# Decides whether an Edit / Write / MultiEdit is allowed:
#   - Spec index        -> FEAT- done needs a passing /sd:verify (Rule 0); an
#                          edit that is only legal status transitions / new
#                          draft rows is allowed (Rule 0b, SW-75).
#   - Protected paths   -> otherwise always block.
#   - Allow-listed dirs / extensions -> always allow.
#   - Code files        -> require an in-progress spec in .specs/index.md.
#       mode=block -> emit block JSON (see emit_block below).
#       mode=warn  -> warn to stderr; allow.
#       mode=off   -> always allow.
# A Bash / PowerShell tool call is checked by the shell-write rule instead
# (SW-79): a command that visibly writes a protected path or the spec index
# (sed -i, perl -i, >, >>, tee, Set-Content, Add-Content, Out-File) is
# blocked in every mode. Heuristic - see shell_write_target below.
# Exits 0 silently on any missing tool or parse error.
#
# Output schema (dual-format for forward + backward compatibility):
#   New:    hookSpecificOutput.permissionDecision = "deny"   (CLI >= schema v2)
#   Legacy: decision = "block"                               (CLI < schema v2)
# Both are emitted in the same JSON object so either CLI generation can act.
#
# Note: hooks must never fail noisily. `set -u` is intentionally omitted.

if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

input="$(cat 2>/dev/null || true)"
if [[ -z "${input}" ]]; then
    exit 0
fi

tool_name="$(printf '%s' "${input}" | jq -r '.tool_name // empty' 2>/dev/null)"
is_shell=0
case "${tool_name}" in
    Edit|Write|MultiEdit) ;;
    Bash|PowerShell) is_shell=1 ;;
    *) exit 0 ;;
esac

cwd="$(printf '%s' "${input}" | jq -r '.cwd // empty' 2>/dev/null)"
if [[ -z "${cwd}" ]]; then
    cwd="$(pwd)"
fi

file_path=""
shell_cmd_lower=""
if [[ ${is_shell} -eq 1 ]]; then
    # SW-79: a shell command has no file_path. This pre-filter is pure string
    # work with no disk read, because the hook now runs on EVERY shell call
    # (ADR 0012 latency budget): a command that carries none of the write
    # markers the shell-write rule looks for cannot trip it, so it exits here.
    shell_cmd="$(printf '%s' "${input}" | jq -r '.tool_input.command // empty' 2>/dev/null)"
    if [[ -z "${shell_cmd}" ]]; then
        exit 0
    fi
    shell_cmd_lower="$(printf '%s' "${shell_cmd}" | tr '[:upper:]' '[:lower:]')"
    case "${shell_cmd_lower}" in
        *'>'*|*sed*|*perl*|*tee*|*set-content*|*add-content*|*out-file*) ;;
        *) exit 0 ;;
    esac
else
    file_path="$(printf '%s' "${input}" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
    if [[ -z "${file_path}" ]]; then
        exit 0
    fi
fi

# --- project root (SW-78) -----------------------------------------------------
# `cwd` is the session's CURRENT directory, and a Bash `cd` moves it. Resolving
# config, the index, the metrics log and the edited path against it let a
# session sitting in a subdirectory bypass every rule (and grow a nested
# .specs/_metrics/ there). Everything below resolves against the project root:
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

# --- load config --------------------------------------------------------------

# A project with no .claude/project-config.json (the normal state before
# /sd:setup has run) must still get the built-in protected paths, so the
# fallback is a full default document rather than an empty object. This must
# stay byte-identical in meaning to $defaults in spec-gate.ps1.
default_config='{"spec":{"dir":".specs","indexFile":".specs/index.md"},"paths":{"protected":[".specs/constitution.md",".specs/index.md","LICENSE"]},"hooks":{"specGate":{"enabled":true,"mode":"warn"},"metrics":{"enabled":true,"path":".specs/_metrics/events.jsonl","maxSizeKb":1024}}}'

config_path="${project_root}/.claude/project-config.json"
config_json="${default_config}"
if [[ -f "${config_path}" ]] && jq -e . "${config_path}" >/dev/null 2>&1; then
    config_json="$(cat "${config_path}")"
fi

# `//` treats explicit `false` as absent, so compare directly against
# `false` instead of relying on the alternative operator here.
enabled="$(printf '%s' "${config_json}" | jq -r 'if .hooks.specGate.enabled == false then "false" else "true" end' 2>/dev/null)"
if [[ "${enabled}" == "false" ]]; then
    exit 0
fi

mode="$(printf '%s' "${config_json}" | jq -r '.hooks.specGate.mode // "warn"' 2>/dev/null)"
if [[ "${mode}" == "off" ]]; then
    exit 0
fi

index_rel="$(printf '%s' "${config_json}" | jq -r '.spec.indexFile // ".specs/index.md"' 2>/dev/null)"
index_path="${project_root}/${index_rel}"

# --- spec prefix alternation (SW-44) ------------------------------------------
# Built-in fallback covers every prefix shipped in
# templates/project-config.template.json (FEAT, BUG, REF, PERF, RCA, PORT).
# Any config-declared prefix that fails the shape check
# ^[A-Z][A-Z0-9]{1,9}$ is dropped silently and the built-in default is used
# only if NOTHING declared validates - a config with one bad entry among
# good ones still uses the good ones. Must stay in sync with
# Get-SpecPrefixAlternation in spec-gate.ps1.
readonly SD_DEFAULT_SPEC_PREFIXES='FEAT|BUG|REF|PERF|RCA|PORT'

resolve_spec_prefixes() {
    local raw valid=() p
    raw="$(printf '%s' "${config_json}" | jq -r '.spec.prefixes // {} | to_entries[]?.value // empty' 2>/dev/null)"
    if [[ -z "${raw}" ]]; then
        printf '%s' "${SD_DEFAULT_SPEC_PREFIXES}"
        return 0
    fi
    while IFS= read -r p; do
        # A native Windows jq.exe ends every output line with CRLF, and only
        # the last line's CR is dropped by Git Bash's $(...); strip it so a valid
        # prefix is not rejected by the shape check below.
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

# --- path helpers -------------------------------------------------------------

# All path comparisons in this hook are case-INSENSITIVE, matching
# spec-gate.ps1's OrdinalIgnoreCase. Windows and macOS filesystems are
# case-insensitive by default, so a case-sensitive gate is bypassable there by
# simply retyping the path in a different case - unacceptable for a rule whose
# whole job is to protect specific files.
to_lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Collapses '.' and '..' segments in a forward-slash path using pure string
# processing - no filesystem access, no `realpath`/`readlink -f`/`cd`. This
# mirrors [System.IO.Path]::GetFullPath's string-only resolution in
# spec-gate.ps1, which is what let a path like "src/../.specs/constitution.md"
# reach a protected file while presenting a relative form that never matched
# any entry in paths.protected under the un-collapsed bash comparison.
#
# A ROOTED path (Unix leading '/' or a Windows drive prefix like 'C:/') clamps
# a '..' at its own root instead of walking above it, matching GetFullPath's
# drive/root clamp. A path with no such root has nothing to clamp against, so
# an unresolved leading '..' is kept rather than discarded - it must not be
# allowed to silently walk above its own top.
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

normalize_rel() {
    local fp="$1" base="$2"
    # If fp is already relative, collapse dot segments but there is no known
    # root to compare against a root prefix, so return the collapsed path as-is.
    if [[ "${fp}" != /* && "${fp}" != ?:* ]]; then
        printf '%s' "$(collapse_dot_segments "${fp//\\//}")"
        return
    fi
    # Collapse '.'/'..' BEFORE the prefix strip, so a path that traverses
    # through a directory and back (e.g. root/src/../.specs/x) is compared
    # against base in its fully-resolved form, not its literal typed form.
    local fp_raw="${fp//\\//}"
    local base_norm="${base//\\//}"
    local fp_norm base_collapsed
    fp_norm="$(collapse_dot_segments "${fp_raw}")"
    base_collapsed="$(collapse_dot_segments "${base_norm}")"
    local fp_lower base_lower
    fp_lower="$(to_lower "${fp_norm}")"
    base_lower="$(to_lower "${base_collapsed}")"
    if [[ "${fp_lower}" == "${base_lower}"* ]]; then
        # Cut by the base's LENGTH, not by pattern, so the surviving remainder
        # keeps its original case for the user-facing reason string.
        local rel="${fp_norm:${#base_collapsed}}"
        rel="${rel#/}"
        printf '%s' "${rel}"
    else
        # Resolving fp lands outside base entirely (e.g. enough leading '..' to
        # escape the workspace) - fall back to the raw, un-collapsed path, same
        # as spec-gate.ps1's ConvertTo-RelativePath fallback branch.
        printf '%s' "${fp_raw}"
    fi
}

# A relative file_path is relative to the SESSION cwd. When that is the root,
# keep the historical relative handling untouched; otherwise anchor it on cwd
# first so e.g. '../index.md' typed from .specs/FEAT-x lands on .specs/index.md.
# A shell command has no file_path; it is decided by the shell-write rule below.
rel=""
if [[ ${is_shell} -eq 0 ]]; then
    if [[ "${file_path}" != /* && "${file_path}" != ?:* ]] &&
       [[ "$(collapse_dot_segments "${cwd//\\//}")" != "$(collapse_dot_segments "${project_root}")" ]]; then
        file_path="${cwd%/}/${file_path}"
    fi

    rel="$(normalize_rel "${file_path}" "${project_root}")"
    if [[ -z "${rel}" ]]; then
        exit 0
    fi
fi

# --- emit-block helper --------------------------------------------------------
# Emits dual-format JSON: new hookSpecificOutput schema + legacy decision field.
# The CLI reads whichever field it understands; both are harmless to the other.

emit_block() {
    local reason="$1"
    jq -nc --arg r "${reason}" \
        '{decision:"block",reason:$r,hookSpecificOutput:{permissionDecision:"deny",reason:$r}}'
}

# --- metrics: shared event writer ---------------------------------------------
# Append-only, metadata-only event log for the retro loop (SW-10). Every
# failure path here is a silent no-op - metrics must NEVER surface as a hook
# error or change a gate decision. Every call site invokes this AFTER the
# decision is already computed (and, for a block, already emitted) - never
# from inside the decision path itself.

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

# gate metric: $1=spec_id $2=phase $3=gate $4=decision $5=ext (optional)
emit_gate_metric() {
    local spec_id="$1" phase="$2" gate="$3" decision="$4" ext="${5:-}"
    local body
    if [[ -n "${ext}" ]]; then
        body="$(jq -nc --arg spec_id "${spec_id}" --arg phase "${phase}" --arg gate "${gate}" --arg decision "${decision}" --arg ext "${ext}" \
            '{spec_id:$spec_id,phase:$phase,event:"gate",gate:$gate,decision:$decision,ext:$ext}' 2>/dev/null)"
    else
        body="$(jq -nc --arg spec_id "${spec_id}" --arg phase "${phase}" --arg gate "${gate}" --arg decision "${decision}" \
            '{spec_id:$spec_id,phase:$phase,event:"gate",gate:$gate,decision:$decision}' 2>/dev/null)"
    fi
    [[ -z "${body}" ]] && return 0
    write_metric_line "${body}"
}

# --- protected-path match (Rule 1 and the shell-write rule) ------------------
# $1 = root-relative path. Case-insensitive exact match against every
# paths.protected entry. Mirrors Test-IsProtected in spec-gate.ps1.
is_protected_rel() {
    local rel_l p p_norm
    rel_l="$(to_lower "$1")"
    while IFS= read -r p; do
        # Some jq builds (e.g. Windows jq.exe) emit CRLF when a filter yields
        # multiple values, as this array iteration does; strip a trailing CR so
        # the exact-match comparison below isn't corrupted.
        p="${p%$'\r'}"
        [[ -z "${p}" ]] && continue
        p_norm="$(to_lower "${p//\\//}")"
        if [[ "${rel_l}" == "${p_norm}" ]]; then
            return 0
        fi
    done < <(printf '%s' "${config_json}" | jq -r '.paths.protected // [] | .[]' 2>/dev/null)
    return 1
}

# --- shell-write rule: Bash / PowerShell tool (SW-79) --------------------------
# A shell command can change .specs/index.md or a protected file without the
# Edit tool, which would sidestep Rules 0, 0b and 1 and leave no
# spec_transition event. This rule denies a command that VISIBLY writes a
# protected path or the spec index. It is a HEURISTIC, not a guarantee: it
# reads the command text only, so `cd .specs && sed -i ... index.md`, an
# interpreter one-liner (python -c, node -e) or a path held in a variable
# gets through. The workflows' own "Edit tool only" instruction is the
# primary control; this is the backstop.
#
# Algorithm (must stay identical to Get-ShellWriteTarget in spec-gate.ps1):
#   1. Lowercase the command and turn '\' into '/'.
#   2. Scan it once, tracking single / double quotes. Outside quotes:
#      ';', '|', '&', CR and LF end the SEGMENT; blank, tab, '(' and ')' end
#      the token; '>' ends the token and is a '>' token of its own; a quote
#      character opens a quote and is dropped. Inside a quote every character
#      is part of the token until the matching quote closes it. Empty tokens
#      are dropped. So `sed -i 's/| draft |/| approved |/' f` stays one
#      segment, and an unterminated quote simply runs to the end.
#   3. The segment is a WRITER when its command word (basename of the first
#      token) is tee / set-content / add-content / out-file, or is
#      sed / gsed / perl with an in-place flag (a single-dash cluster that
#      reaches an 'i', e.g. -i, -i.bak, -pi, or --in-place).
#   4. Candidate paths: every token after the command word of a writer
#      segment, and the token after any '>' (a redirect target, '>>'
#      included) in any segment.
#   5. A candidate starting with '$' or '~' drops its first segment
#      ($ROOT/.specs/index.md -> .specs/index.md); any other relative one is
#      anchored on cwd as file_path is; then normalize_rel. A result that is
#      the spec index or matches paths.protected is a hit.
# Prints the first hit's root-relative path; prints nothing on no hit.

# Appends the pending token (if any) to SW_TOKS. Reads/clears the caller's
# `tok` through bash's dynamic scoping.
sw_flush_token() {
    if [[ -n "${tok}" ]]; then
        SW_TOKS+=("${tok}")
    fi
    tok=""
}

# Steps 3-5 for the segment held in SW_TOKS. Uses the caller's cwd_c,
# root_c and index_l. Prints the hit and returns 0, or returns 1.
sw_segment_hit() {
    local verb writer k t prev cand rel
    [[ ${#SW_TOKS[@]} -eq 0 ]] && return 1
    verb="${SW_TOKS[0]##*/}"
    writer=0
    case "${verb}" in
        tee|set-content|add-content|out-file) writer=1 ;;
        sed|gsed|perl)
            for (( k = 1; k < ${#SW_TOKS[@]}; k++ )); do
                t="${SW_TOKS[$k]}"
                if [[ "${t}" =~ ^-[a-z0-9.]*i || "${t}" == --in-place* ]]; then
                    writer=1
                    break
                fi
            done
            ;;
    esac
    prev=""
    for (( k = 0; k < ${#SW_TOKS[@]}; k++ )); do
        t="${SW_TOKS[$k]}"
        if [[ "${t}" == ">" ]]; then
            prev=">"
            continue
        fi
        if [[ "${prev}" == ">" ]] || [[ ${writer} -eq 1 && ${k} -ge 1 ]]; then
            rel=""
            if [[ "${t}" == '$'* || "${t}" == '~'* ]]; then
                if [[ "${t}" == */* ]]; then
                    rel="$(collapse_dot_segments "${t#*/}")"
                fi
            else
                cand="${t}"
                if [[ "${cand}" != /* && "${cand}" != ?:* && "${cwd_c}" != "${root_c}" ]]; then
                    cand="${cwd%/}/${cand}"
                fi
                rel="$(normalize_rel "${cand}" "${project_root}")"
            fi
            if [[ -n "${rel}" ]]; then
                if [[ "$(to_lower "${rel}")" == "${index_l}" ]] || is_protected_rel "${rel}"; then
                    printf '%s' "${rel}"
                    return 0
                fi
            fi
        fi
        prev=""
    done
    return 1
}

shell_write_target() {
    # Byte-wise indexing: keeps ${cmd:i:1} O(1) on a long command.
    local LC_ALL=C
    local cmd="$1" n i c q="" tok="" cwd_c root_c index_l
    cmd="${cmd//\\//}"
    cwd_c="$(collapse_dot_segments "${cwd//\\//}")"
    root_c="$(collapse_dot_segments "${project_root}")"
    index_l="$(to_lower "$(collapse_dot_segments "${index_rel//\\//}")")"
    SW_TOKS=()
    n=${#cmd}
    for (( i = 0; i <= n; i++ )); do
        if (( i == n )); then
            # End of input closes any open quote and the last segment.
            q=""
            c=$'\n'
        else
            c="${cmd:i:1}"
        fi
        if [[ -n "${q}" ]]; then
            if [[ "${c}" == "${q}" ]]; then
                q=""
            else
                tok+="${c}"
            fi
            continue
        fi
        case "${c}" in
            "'"|'"') q="${c}" ;;
            ' '|$'\t'|'('|')') sw_flush_token ;;
            '>') sw_flush_token; SW_TOKS+=(">") ;;
            ';'|'|'|'&'|$'\r'|$'\n')
                sw_flush_token
                sw_segment_hit && return 0
                SW_TOKS=()
                ;;
            *) tok+="${c}" ;;
        esac
    done
    return 0
}

if [[ ${is_shell} -eq 1 ]]; then
    shell_hit="$(shell_write_target "${shell_cmd_lower}")"
    if [[ -n "${shell_hit}" ]]; then
        # Blocks in every mode, like Rule 1: mode only governs code edits.
        emit_block "spec-gate: this shell command writes '${shell_hit}', which is protected (paths.protected or the spec index). Make the change with the Edit tool so spec-gate can check it (Rules 0, 0b, 1)."
        emit_gate_metric "-" "-" "shell-write" "block"
    fi
    exit 0
fi

# spec_transition metric: $1=spec_id $2=phase $3=from $4=decision
emit_transition_metric() {
    local spec_id="$1" phase="$2" from="$3" decision="$4"
    local body
    body="$(jq -nc --arg spec_id "${spec_id}" --arg phase "${phase}" --arg from "${from}" --arg decision "${decision}" \
        '{spec_id:$spec_id,phase:$phase,event:"spec_transition",from:$from,decision:$decision}' 2>/dev/null)"
    [[ -z "${body}" ]] && return 0
    write_metric_line "${body}"
}

# --- spec_transition: general lifecycle scan (read-only, all 5 prefixes x any status) ---
# Deliberately a SEPARATE scan from the FEAT-/done-only `pending_done`
# extraction inside Rule 0 below: that one backs a live gate decision (see its
# Rule 0 scope comment) and must not be refactored into this one, which only
# feeds the observational spec_transition metric. Row shape is
# "| ID | Type | Status | Title |" - split on '|' and read columns 2 and 4
# rather than a loose substring match, so a Title that happens to mention
# another id/status word cannot be misread as that row's own id or status.
extract_id_status_pairs() {
    # sub() drops a CRLF line ending (a CRLF index, or new_string text from a
    # jq.exe that writes CRLF) before the row is split, so no cell carries a CR.
    awk -F'|' -v prefixes="${spec_prefixes}" '
        { sub(/\r$/, "") }
        NF >= 5 {
            id = $2; gsub(/^[ \t]+|[ \t]+$/, "", id)
            status = $4; gsub(/^[ \t]+|[ \t]+$/, "", status)
            if (id ~ ("^(" prefixes ")-[A-Za-z0-9_-]+$") && status ~ /^(draft|approved|in-progress|done|archived)$/) {
                print id "\t" status
            }
        }
    '
}

# Populates the parallel arrays transition_id[] / transition_phase[] /
# transition_from[] for the CURRENT pending edit. No-op (arrays left empty)
# unless this edit targets index.md - checked by the caller via rel/index_rel
# before calling, same scoping as Rule 0.
declare -a transition_id=()
declare -a transition_phase=()
declare -a transition_from=()

collect_spec_transitions() {
    local old_pairs="" new_pairs=""
    if [[ -f "${index_path}" ]]; then
        old_pairs="$(extract_id_status_pairs < "${index_path}")"
    fi
    case "${tool_name}" in
        Edit)      new_pairs="$(printf '%s' "${input}" | jq -r '.tool_input.new_string // empty' 2>/dev/null | extract_id_status_pairs)" ;;
        Write)     new_pairs="$(printf '%s' "${input}" | jq -r '.tool_input.content // empty' 2>/dev/null | extract_id_status_pairs)" ;;
        MultiEdit) new_pairs="$(printf '%s' "${input}" | jq -r '[.tool_input.edits[]?.new_string // empty] | join("\n")' 2>/dev/null | extract_id_status_pairs)" ;;
    esac
    [[ -z "${new_pairs}" ]] && return 0

    local seen="|"
    while IFS=$'\t' read -r id newstatus; do
        [[ -z "${id}" ]] && continue
        case "${seen}" in
            *"|${id}|"*) continue ;;
        esac
        seen="${seen}${id}|"

        local oldstatus="-"
        if [[ -n "${old_pairs}" ]]; then
            local found
            found="$(printf '%s\n' "${old_pairs}" | awk -F'\t' -v want="${id}" '$1==want {print $2; exit}')"
            [[ -n "${found}" ]] && oldstatus="${found}"
        fi

        if [[ "${oldstatus}" != "${newstatus}" ]]; then
            transition_id+=("${id}")
            transition_phase+=("${newstatus}")
            transition_from+=("${oldstatus}")
        fi
    done <<< "${new_pairs}"
}

# Emits one spec_transition event per entry in transition_id[] with the given
# overall decision - the decision is for the WHOLE edit (there is only one per
# hook invocation), not per-id, so every entry shares it.
emit_transition_metrics() {
    local decision="$1"
    for i in "${!transition_id[@]}"; do
        emit_transition_metric "${transition_id[$i]}" "${transition_phase[$i]}" "${transition_from[$i]}" "${decision}"
    done
}

# --- metrics: complexity-gate split detection (observational, SW-31) ----------
# Gate Complexity (ADR 0002) is decided as model-executed prose inside
# /sd:feature Phase 3 Gate 2 - no hook observes that decision directly. What
# IS observable here is one of its two possible outcomes: an "approve split"
# resolution always leaves a structural trace in THIS index.md edit or an
# earlier one - the parent row moves to `archived` (commands/feature.md
# Face B, "make the parent an umbrella record") and each child is registered
# under the `FEAT-<parent>-<slug>` naming convention (feature.md's child-ID
# step). A FEAT-X row newly transitioning to `archived` alongside any
# already-registered FEAT-X-<slug> row (in the on-disk registry OR this same
# pending edit) is read as a completed split.
#
# This can only ever detect a SPLIT, never a bare trip: Face A (never
# tripped) and Face B "no-split" (tripped, user declined) both leave the
# parent `in-progress` with no distinguishing mark in index.md, so trip rate
# on its own is not recoverable from this signal. See ADR
# docs/adr/0004-threshold-calibration.md "Scope declined" - deliberately not
# fixed here to avoid making a HARD gate's prose responsible for feeding a
# metrics pipeline the rest of this file keeps strictly hook-authored.
#
# Callers MUST only invoke this on a path where the edit was actually
# ALLOWED through (Rule 0's verify-allow exit, Rule 0b's transition-allow
# exit, Rule 2's allow-listed exit).
# On a block exit the edit never reached disk, so recording "split" there
# would assert a split that did not happen - never add a call site here on a
# block/deny path.
#
# Scoped to FEAT- parents only: Gate Complexity decompose is a /sd:feature
# mechanism (commands/feature.md Face B); BUG-/REF-/PERF-/RCA- rows can never
# go through it, so matching their prefix too would only add false-positive
# surface for coincidental id-prefix collisions with no corresponding
# real-world case.
emit_complexity_split_metrics() {
    [[ ${#transition_id[@]} -eq 0 ]] && return 0

    local registry_pairs="" new_fragment="" new_pairs=""
    if [[ -f "${index_path}" ]]; then
        registry_pairs="$(extract_id_status_pairs < "${index_path}")"
    fi
    case "${tool_name}" in
        Edit)      new_fragment="$(printf '%s' "${input}" | jq -r '.tool_input.new_string // empty' 2>/dev/null)" ;;
        Write)     new_fragment="$(printf '%s' "${input}" | jq -r '.tool_input.content // empty' 2>/dev/null)" ;;
        MultiEdit) new_fragment="$(printf '%s' "${input}" | jq -r '[.tool_input.edits[]?.new_string // empty] | join("\n")' 2>/dev/null)" ;;
    esac
    [[ -n "${new_fragment}" ]] && new_pairs="$(printf '%s' "${new_fragment}" | extract_id_status_pairs)"

    local all_ids
    all_ids="$(printf '%s\n%s\n' "${registry_pairs}" "${new_pairs}" | awk -F'\t' '{if ($1!="") print $1}' | LC_ALL=C sort -u)"

    local i id other child_found
    for i in "${!transition_id[@]}"; do
        id="${transition_id[$i]}"
        [[ "${transition_phase[$i]}" == "archived" ]] || continue
        case "${id}" in
            FEAT-*) ;;
            *) continue ;;
        esac
        child_found=0
        while IFS= read -r other; do
            [[ -z "${other}" || "${other}" == "${id}" ]] && continue
            case "${other}" in
                "${id}-"*) child_found=1; break ;;
            esac
        done <<< "${all_ids}"
        [[ ${child_found} -eq 1 ]] && emit_gate_metric "${id}" "archived" "complexity" "split"
    done
}

# --- Rule 0: verify gate on the spec index ------------------------------------
# A row transitioning to done requires a passing /sd:verify artifact; a
# verified close-out is allowed through the protected-path rule. Any other
# direct index edit falls through to Rule 1. Mirrors spec-gate.ps1 Rule 0.
#
# Scope: FEAT- rows only. Bug/refactor/perf/rca workflows do not produce
# 02-tasks.md and never run /sd:verify, so gating them here would hard-STOP
# their close-out at VF002 with no way through. Non-FEAT rows fall through to
# Rule 0b, which allows their `in-progress -> done` like any other legal
# status transition (SW-75) - until their workflows integrate /sd:verify
# (follow-up spec).
#
# Bundled-edit limitation: when every newly-done FEAT row in the pending edit
# has a passing artifact, the WHOLE edit is allowed - including any unrelated
# row changes bundled into the same Write/Edit/MultiEdit. This hook inspects
# only the done-transition lines, not a full diff, so a bundled edit could in
# principle piggyback an unrelated change. Accepted limitation (hook-scale
# diff inspection is out of scope); the /sd:spec registry commands are the
# semantic guard for anything this coarse check cannot see.

verify_gate="$(printf '%s' "${config_json}" | jq -r 'if .hooks.specGate.verifyGate == false then "false" else "true" end' 2>/dev/null)"
spec_dir="$(printf '%s' "${config_json}" | jq -r '.spec.dir // ".specs"' 2>/dev/null)"

rel_lower="$(to_lower "${rel}")"
index_rel_norm="${index_rel//\\//}"
index_rel_lower="$(to_lower "${index_rel_norm}")"

# spec_transition metric: read-only, general lifecycle scan of THIS index.md
# edit. Populated unconditionally of verify_gate (it never influences the
# gate decision, only records whatever decision is ultimately reached below);
# left empty whenever this edit is not to the index file.
if [[ "${rel_lower}" == "${index_rel_lower}" ]]; then
    collect_spec_transitions
fi

if [[ "${verify_gate}" == "true" && "${rel_lower}" == "${index_rel_lower}" ]]; then
    fragments=""
    case "${tool_name}" in
        Edit)      fragments="$(printf '%s' "${input}" | jq -r '.tool_input.new_string // empty' 2>/dev/null)" ;;
        Write)     fragments="$(printf '%s' "${input}" | jq -r '.tool_input.content // empty' 2>/dev/null)" ;;
        MultiEdit) fragments="$(printf '%s' "${input}" | jq -r '[.tool_input.edits[]?.new_string // empty] | join("\n")' 2>/dev/null)" ;;
    esac

    if [[ -n "${fragments}" ]]; then
        # IDs marked done in the pending edit's new content. Extracts only the
        # FIRST id per line (matches pwsh's `-match` + $Matches[0] semantics) -
        # a `grep -o` here would emit every id on the line, including one that
        # is merely mentioned in a title (e.g. "Follow-up to BUG-002"), which
        # would wrongly fold an unrelated spec into the transition set.
        # FEAT- only (see Rule 0 scope comment above): DELIBERATELY narrower
        # than Rule 3's in-progress scan below.
        pending_done="$(printf '%s' "${fragments}" \
            | grep -E '\|[[:space:]]*done[[:space:]]*\|' 2>/dev/null \
            | awk 'match($0, /FEAT-[A-Za-z0-9_-]+/) { print substr($0, RSTART, RLENGTH) }' \
            | tr -d '\r' | LC_ALL=C sort -u)"
        # IDs the on-disk index already records as done (not a transition).
        # Same first-match-per-line extraction as above.
        already_done=""
        if [[ -f "${index_path}" ]]; then
            already_done="$(grep -E '\|[[:space:]]*done[[:space:]]*\|' "${index_path}" 2>/dev/null \
                | awk 'match($0, /FEAT-[A-Za-z0-9_-]+/) { print substr($0, RSTART, RLENGTH) }' \
                | tr -d '\r' | LC_ALL=C sort -u)"
        fi

        transition_ids=""
        while IFS= read -r id; do
            [[ -z "${id}" ]] && continue
            if [[ -n "${already_done}" ]] && printf '%s\n' "${already_done}" | grep -qx "${id}"; then
                continue
            fi
            transition_ids="${transition_ids}${id}"$'\n'
        done <<< "${pending_done}"

        if [[ -n "${transition_ids}" ]]; then
            missing=""
            while IFS= read -r id; do
                [[ -z "${id}" ]] && continue
                artifact="${project_root}/${spec_dir}/${id}/06-verify.md"
                if [[ ! -f "${artifact}" ]] \
                   || ! grep -q -i -E '^result:[[:space:]]*pass[[:space:]]*$' "${artifact}" 2>/dev/null; then
                    if [[ -z "${missing}" ]]; then
                        missing="${id}"
                    else
                        missing="${missing}, ${id}"
                    fi
                fi
            done <<< "${transition_ids}"

            if [[ -n "${missing}" ]]; then
                emit_block "spec-gate: index row(s) [${missing}] -> done but no passing /sd:verify artifact. Run /sd:verify <spec-ID>; close-out is allowed only after ${spec_dir}/<ID>/06-verify.md records 'result: pass'."
                # Metrics are emitted AFTER the block decision above is
                # already written to stdout - never inside the decision path.
                while IFS= read -r id; do
                    [[ -z "${id}" ]] && continue
                    id_decision="allow"
                    if printf '%s\n' "${missing}" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -qx "${id}"; then
                        id_decision="block"
                    fi
                    emit_gate_metric "${id}" "done" "verify" "${id_decision}"
                done <<< "${transition_ids}"
                emit_transition_metrics "block"
                # No emit_complexity_split_metrics here: the whole edit is
                # denied, so nothing in it - including any bundled parent
                # archive + child registration - actually reached disk. See
                # the function's own comment.
                exit 0
            fi
            # Every transitioning spec has a passing artifact - allow the close-out.
            while IFS= read -r id; do
                [[ -z "${id}" ]] && continue
                emit_gate_metric "${id}" "done" "verify" "allow"
            done <<< "${transition_ids}"
            emit_transition_metrics "allow"
            emit_complexity_split_metrics
            exit 0
        fi
    fi
fi

# --- Rule 0b: legal status transitions on the spec index (SW-75) -------------
# Every workflow (/sd:feature, /sd:bug, /sd:refactor, /sd:perf, /sd:rca,
# /sd:port, /sd:spec, /sd:release) registers its row and moves its Status by
# editing index.md with the Edit tool. Rule 1 alone would deny all of that
# under a permission mode that honors hook decisions. This rule lets through
# an edit whose NET effect is only:
#   - new rows registered at `draft` or `approved` (refactor registers at its
#     Gate 1), and/or
#   - existing rows whose Status cell - and nothing else - moves along a
#     workflow edge (index_edges below).
# Everything else - a title/date change, a deleted or reordered row, a header
# change, an illegal jump - falls through to Rule 1 and is blocked.
#
# The post-edit file is rebuilt (Write content, or Edit/MultiEdit literal
# replacement applied to the on-disk file) and compared row-by-row with each
# row's Status cell masked, so a change riding along with a legal transition
# cannot slip through (unlike Rule 0's fragment scan). A FEAT- row moving to
# `done` is NOT an edge here: Rule 0 owns it (verify artifact required), and
# with verifyGate off it stays blocked by Rule 1 exactly as before.
#
# The whole decision runs in ONE jq program so line splitting and literal
# replacement match spec-gate.ps1's .NET string ops (Test-IndexTransitionEdit)
# exactly. Output: one "id<TAB>from<TAB>to" line per changed row, or nothing
# when the edit is not a pure legal transition.
index_transition_changes() {
    [[ -f "${index_path}" ]] || return 0
    printf '%s' "${input}" | jq -r --rawfile old "${index_path}" --arg prefixes "${spec_prefixes}" '
        def norm: gsub("\r\n"; "\n");
        def lines: ltrimstr("﻿") | norm | split("\n") | map(rtrimstr("\r"));
        def trimws: gsub("^[ \t]+|[ \t]+$"; "");
        def row: (split("|")) as $f
            | if ($f | length) >= 5 then
                  ($f[1] | trimws) as $id | ($f[3] | trimws) as $st
                  | if ($id | test("^(" + $prefixes + ")-[A-Za-z0-9_-]+$"))
                       and ($st | IN("draft", "approved", "in-progress", "done", "archived"))
                    then {id: $id, st: $st, mask: ($f | .[3] = "@" | join("|"))}
                    else null end
              else null end;
        def apply($e):
            if . == null then null
            else
                (($e.old_string // "") | tostring | norm) as $o
                | (($e.new_string // "") | tostring | norm) as $n
                | if $o == "" then null
                  else split($o) as $parts
                  | if ($parts | length) < 2 then null
                    elif $e.replace_all == true then $parts | join($n)
                    else $parts[0] + $n + ($parts[1:] | join($o)) end
                  end
            end;
        def edges: ["draft>approved", "approved>in-progress", "in-progress>done",
                    "done>archived", "archived>in-progress", "draft>archived",
                    "approved>archived"];

        . as $in
        | ($old | ltrimstr("﻿") | norm) as $oldtext
        | (if $in.tool_name == "Write" then
               (if ($in.tool_input.content | type) == "string" then $in.tool_input.content else null end)
           elif $in.tool_name == "Edit" then
               ($oldtext | apply($in.tool_input))
           elif $in.tool_name == "MultiEdit" then
               reduce ($in.tool_input.edits // [])[] as $e ($oldtext; apply($e))
           else null end) as $newtext
        | if $newtext == null then empty else
            ($oldtext | lines) as $ol | ($newtext | lines) as $nl
            | [$ol[] | row | select(. != null)] as $orows
            | [$nl[] | row | select(. != null)] as $nrows
            | ($orows | map(.id)) as $oids | ($nrows | map(.id)) as $nids
            | if ($oids | unique | length) != ($oids | length)
                 or ($nids | unique | length) != ($nids | length) then empty
              else
                ($orows | map({(.id): .st}) | add // {}) as $ost
                | [$ol[] | (row) as $r | if $r == null then . else $r.mask end] as $omask
                | [$nl[] | (row) as $r
                    | if $r == null then .
                      elif ($ost | has($r.id)) then $r.mask
                      else empty end] as $nmask
                | [$nrows[] | {id, from: ($ost[.id] // "-"), to: .st} | select(.from != .to)] as $chg
                | if $omask != $nmask or ($chg | length) == 0 then empty
                  elif any($chg[];
                        if .from == "-" then (.to | IN("draft", "approved")) | not
                        elif (.id | startswith("FEAT-")) and .to == "done" then true
                        else ((.from + ">" + .to) | IN(edges[])) | not end) then empty
                  else $chg[] | "\(.id)\t\(.from)\t\(.to)" end
              end
          end
    ' 2>/dev/null
}

if [[ "${rel_lower}" == "${index_rel_lower}" ]]; then
    index_changes="$(index_transition_changes)"
    if [[ -n "${index_changes}" ]]; then
        # Record the transitions from Rule 0b's own diff, not the fragment
        # scan: a workflow edit that rewrites only the Status cell (old
        # "| draft |" -> new "| approved |") carries no full row in
        # new_string, so collect_spec_transitions would miss it entirely.
        transition_id=()
        transition_phase=()
        transition_from=()
        while IFS=$'\t' read -r c_id c_from c_to; do
            # A native Windows jq.exe ends every line but the last (which Git Bash's
            # $(...) trims) with CR, and it lands on c_to - the recorded phase,
            # and the "archived" test that detects a complexity split.
            c_to="${c_to%$'\r'}"
            [[ -z "${c_id}" ]] && continue
            transition_id+=("${c_id}")
            transition_phase+=("${c_to}")
            transition_from+=("${c_from}")
        done <<< "${index_changes}"
        emit_transition_metrics "allow"
        emit_complexity_split_metrics
        exit 0
    fi
fi

# --- Rule 1: protected paths -> block ----------------------------------------

is_protected=0
rel_lower="$(to_lower "${rel}")"
if is_protected_rel "${rel}"; then
    is_protected=1
fi

if [[ ${is_protected} -eq 1 ]]; then
    emit_block "spec-gate: '${rel}' is listed under paths.protected in .claude/project-config.json. Update via /sd:refactor or an ADR; never edit directly."
    emit_gate_metric "-" "-" "protected" "block"
    emit_transition_metrics "block"
    # No emit_complexity_split_metrics here: the edit is denied, so a
    # detected parent-archive-plus-child pattern in it never reached disk.
    exit 0
fi

# --- Rule 2: allow-listed paths -> allow -------------------------------------

is_allowed=0
for d in .specs/ .claude/ tests/ test/ docs/ spec/; do
    if [[ "${rel_lower}" == "${d}"* ]]; then
        is_allowed=1
        break
    fi
done

basename_only="$(basename "${rel}")"
# Only EXTENSION-LESS project files are allow-listed by name; anything with an
# extension is decided by the extension rules below. A name like README.old.py
# must not be allow-listed just because it starts with README - it is a Python
# file, and the gate exists to catch code edits.
case "$(to_lower "${basename_only}")" in
    readme|changelog|contributing|license|notice|authors)
        is_allowed=1
        ;;
esac

if [[ ${is_allowed} -eq 0 ]]; then
    ext="${basename_only##*.}"
    if [[ "${ext}" != "${basename_only}" ]]; then
        ext_lower="$(printf '%s' "${ext}" | tr '[:upper:]' '[:lower:]')"
        case "${ext_lower}" in
            md|markdown|txt|rst|adoc|json|yaml|yml|toml|ini|env|example)
                is_allowed=1
                ;;
        esac
    fi
fi

if [[ ${is_allowed} -eq 1 ]]; then
    emit_transition_metrics "allow"
    emit_complexity_split_metrics
    exit 0
fi

# --- Rule 3: code file -> require in-progress spec ----------------------------

is_code=0
ext="${basename_only##*.}"
if [[ "${ext}" != "${basename_only}" ]]; then
    ext_lower="$(printf '%s' "${ext}" | tr '[:upper:]' '[:lower:]')"
    case "${ext_lower}" in
        cs|fs|vb|ts|tsx|js|jsx|mjs|cjs|vue|svelte|py|pyi|rs|go|java|kt|kts|scala|rb|php|swift|m|mm|c|h|cpp|cxx|cc|hpp|hxx|sql|ps1|sh|bash|zsh|razor|cshtml)
            is_code=1
            ;;
    esac
fi

if [[ ${is_code} -eq 0 ]]; then
    exit 0
fi

# Metric ext value MUST include the leading dot (e.g. ".ps1") to match
# spec-gate.ps1's [System.IO.Path]::GetExtension output - ext_lower above has
# the dot already stripped for the extension-list case match.
metric_ext=".${ext_lower}"

# Check for in-progress spec. Both markers must appear on the SAME line
# (mirrors prompt-router.sh and spec-gate.ps1's same-line semantics). Also
# captures the first matching id (same lines, same pattern) for the
# code-edit allow metric below - this does not change the has_in_progress
# decision, only records which spec let the edit through.
has_in_progress=0
first_in_progress=""
if [[ -f "${index_path}" ]]; then
    first_in_progress="$(grep -E 'in-progress' "${index_path}" 2>/dev/null \
        | awk -v prefixes="${spec_prefixes}" 'match($0, "(" prefixes ")-[A-Za-z0-9_-]+") { print substr($0, RSTART, RLENGTH); exit }')"
    if [[ -n "${first_in_progress}" ]]; then
        has_in_progress=1
    fi
fi

if [[ ${has_in_progress} -eq 0 ]]; then
    msg="spec-gate: editing code file '${rel}' but no in-progress spec is recorded in .specs/index.md. Run /sd:feature, /sd:bug, /sd:refactor, or /sd:perf first to create a spec, or set hooks.specGate.mode='off' in .claude/project-config.json to disable."
    if [[ "${mode}" == "block" ]]; then
        emit_block "${msg}"
        emit_gate_metric "-" "-" "code-edit" "block" "${metric_ext}"
        exit 0
    else
        echo "[WARN] ${msg}" 1>&2
        emit_gate_metric "-" "-" "code-edit" "warn" "${metric_ext}"
        exit 0
    fi
else
    # An in-progress spec exists - the edit is allowed. Recording the allow
    # (not just the block/warn paths) is the point: the ratio of allow to
    # warn/block is what the retro loop measures.
    emit_gate_metric "${first_in_progress}" "in-progress" "code-edit" "allow" "${metric_ext}"
fi

exit 0
