#!/usr/bin/env bash
# specwright: Stop hook - stop-gate (bash).
#
# Reads Claude Code hook JSON from stdin. When the main thread tries to end its
# turn, refuses the stop if the spec the session was driving shows on disk that
# a HARD gate was skipped (SW-69, ADR 0016):
#   1. If the payload carries stop_hook_active: true, allow the stop. The model
#      has already had one continuation; blocking again would loop (ADR 0015).
#   2. Resolve the project root from the cwd (SW-78) and load
#      .claude/project-config.json. hooks.stopGate.enabled must be the literal
#      JSON true - the hook is OFF by default.
#   3. The spec checked is the newest spec ID in the transcript tail whose
#      folder has a 00-spec.md and is not done/archived. No fallback: a turn
#      that never touched a spec is never blocked.
#   4. By the frontmatter type:, evaluate the invariant table of ADR 0016
#      (feature rows: ADR 0021; bug and refactor rows and Gate Re-plan: ADR
#      0029; all read from gate-briefs.md). A rule fires only when later-phase
#      evidence exists AND the HARD gate's own evidence is missing.
#   5. On a hit, print {"decision":"block","reason":...} to stdout. That blocks
#      Stop exactly like exit 2 (ADR 0015) while this hook still exits 0.
#
# Every path exits 0. jq missing, a failure, a missing transcript, spec or
# frontmatter, or an unknown type blocks nothing. The rule table and the reason
# text must stay identical to stop-gate.ps1; tests/hooks/fixtures/stop-gate/
# asserts both against one golden.
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

# ADR 0015: the re-fire after a block carries stop_hook_active: true. Allowing
# it is what keeps an unsatisfiable gate from looping.
if [[ "$(jq_str "${input}" 'if .stop_hook_active == true then "true" else "false" end')" == "true" ]]; then
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
# Like handoff-integrity, and unlike the other hooks, this one is opt-in (ADR 0016): a missing or
# malformed config leaves `{}`, which reads as disabled below.
config_path="${project_root}/.claude/project-config.json"
config_json="{}"
if [[ -f "${config_path}" ]]; then
    if jq -e . "${config_path}" >/dev/null 2>&1; then
        config_json="$(cat "${config_path}")"
    fi
fi

# Type-strict: only a literal JSON boolean true enables the hook, to match
# Test-HookEnabled in stop-gate.ps1. The string "true" does not.
enabled="$(jq_str "${config_json}" 'if .hooks.stopGate.enabled == true then "true" else "false" end')"
if [[ "${enabled}" != "true" ]]; then
    exit 0
fi

spec_rel="$(jq_str "${config_json}" '.spec.dir // ".specs"')"
spec_path="${project_root}/${spec_rel}"
if [[ ! -d "${spec_path}" ]]; then
    exit 0
fi

transcript_path="$(jq_str "${input}" 'if (.transcript_path | type) == "string" then .transcript_path else empty end')"

# --- spec prefix alternation (SW-44) ------------------------------------------
# Built-in fallback covers every prefix shipped in
# templates/project-config.template.json (FEAT, BUG, REF, PERF, RCA, PORT).
# Any config-declared prefix that fails the shape check
# ^[A-Z][A-Z0-9]{1,9}$ is dropped silently and the built-in default is used
# only if NOTHING declared validates. Must stay in sync with
# Get-SpecPrefixAlternation in stop-gate.ps1.
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

# A plain-token frontmatter value (`status:`, `type:`) from the leading `---`
# block of 00-spec.md. Only [A-Za-z0-9_-]+ is accepted. Anything else, a
# missing file or a missing line all yield ''. Same reader as spec_field in
# session-context.sh.
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

# A candidate is the spec being driven when its folder holds a 00-spec.md and
# the spec is not finished.
is_active_candidate() {
    local id="$1" st
    [[ -f "${spec_path}/${id}/00-spec.md" ]] || return 1
    st="$(spec_field "${spec_path}/${id}/00-spec.md" status)"
    [[ "${st}" == "done" || "${st}" == "archived" ]] && return 1
    return 0
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

dir="${spec_path}/${active}"
spec_type="$(spec_field "${dir}/00-spec.md" type)"
status="$(spec_field "${dir}/00-spec.md" status)"
[[ -z "${spec_type}" ]] && exit 0

# --- document helpers (ADR 0016) ----------------------------------------------

# A spec file as text: CRs and a leading BOM removed, and every <!-- ... -->
# comment dropped, so template guidance that quotes <<...>> never counts as an
# unfilled field. Fails (status 1) when the file is absent. jq does the
# multi-line comment removal; `tr` drops the CRs a native Windows jq.exe
# writes. Mirrors Get-DocText in the .ps1.
doc_text() {
    [[ -f "$1" ]] || return 1
    jq -Rrs 'gsub("\r"; "") | ltrimstr([65279] | implode) | gsub("<!--[\\s\\S]*?-->"; "")' "$1" 2>/dev/null | tr -d '\r'
}

# The lines under `## <Heading>` up to the next `## ` heading. Fails when the
# heading is absent. A `### ` subheading does not end the section.
section_of() {
    local text="$1" heading="$2" l trimmed inside=0 found=0 out=""
    while IFS= read -r l || [[ -n "${l}" ]]; do
        if [[ "${l}" == "## "* ]]; then
            [[ ${inside} -eq 1 ]] && break
            trimmed="${l%"${l##*[![:space:]]}"}"
            if [[ "${trimmed}" == "## ${heading}" ]]; then
                inside=1
                found=1
            fi
            continue
        fi
        [[ ${inside} -eq 1 ]] && out+="${l}"$'\n'
    done <<< "${text}"
    [[ ${found} -eq 1 ]] || return 1
    printf '%s' "${out}"
}

# An author-fill field is a <<...>> on one line that is not a <<PHASE-N: ...>>.
has_author_fill() {
    printf '%s' "$1" | grep -oE '<<[^<>]+>>' 2>/dev/null | grep -v '^<<PHASE-' 2>/dev/null | grep -q .
}

has_line() {
    printf '%s\n' "$1" | grep -qE "$2" 2>/dev/null
}

findings=""

# One finding per fired rule. The phrases are part of the contract: the .ps1
# twin builds the same strings and the fixtures assert them byte for byte.
# $1 gate label; $2 missing items; $3 advanced items (both "; "-joined).
add_finding() {
    [[ -n "$2" && -n "$3" ]] || return 0
    findings+=" Gate $1: missing $2; later-phase evidence: $3."
}

# Appends "$2" to the "; "-separated list named by $1.
push() {
    local cur="${!1}"
    if [[ -n "${cur}" ]]; then
        printf -v "$1" '%s; %s' "${cur}" "$2"
    else
        printf -v "$1" '%s' "$2"
    fi
}

# --- gate briefs (ADR 0021, ADR 0029) -----------------------------------------
# /sd:feature, /sd:bug and /sd:refactor gates are evidenced by gate-briefs.md
# (sd-gate-brief): one `## Gate <label> ...` section per gate pass, closed by a
# `Reply: <reply verbatim>` line. Only those two kinds of line are read.
# Mirrors Get-BriefState in the .ps1.

# The gate labels a workflow's brief records, in workflow order; R is Gate
# Re-plan. The position is the label's rank for the coverage rule. A label not
# listed is not a gate of that workflow, so `3` and `3a` never collide. Adding
# a workflow is one line here plus its deny_token entries.
brief_order() {
    case "$1" in
        feature) printf '%s' '1 2 R 3' ;;
        bug) printf '%s' '1 2 3a 3 4 5' ;;
        refactor) printf '%s' '1 2 3 4 5 R 6' ;;
    esac
}

# A reply's token: the first word after `Reply:`, with surrounding markdown
# quotes and trailing punctuation removed. Sets reply_tok; empty means the line
# carries no reply.
reply_token() {
    local t="${1#*Reply:}"
    t="${t#"${t%%[![:space:]]*}"}"
    while [[ "${t}" == [\`\*_\"\']* ]]; do t="${t#?}"; done
    t="${t%%[[:space:]]*}"
    while [[ "${t}" == *[.,\;:\!\?\`\*_\"\'] ]]; do t="${t%?}"; done
    reply_tok="${t}"
}

# The option tokens that keep gate <type>:<label> ($1) open or leave it, plus a
# bare "no". Any other reply approves, so a reply in the conversation language
# still counts. Sets deny_tok to the matched token, lowercase, or ''.
deny_token() {
    local w words base="details refine abort no"
    case "$1" in
        feature:1) words="details refine abort no" ;;
        feature:2) words="details refine abort approve no" ;;
        feature:3) words="details address abort no" ;;
        bug:2) words="${base} partial" ;;
        bug:3) words="${base} dig" ;;
        bug:5 | refactor:6) words="${base} address" ;;
        refactor:2 | refactor:3) words="${base} add" ;;
        refactor:5) words="${base} revert fix" ;;
        *:R) words="${base} revise" ;;
        *) words="${base}" ;;
    esac
    deny_tok=""
    shopt -s nocasematch
    for w in ${words}; do
        if [[ "$2" == "${w}" ]]; then
            deny_tok="${w}"
            break
        fi
    done
    shopt -u nocasematch
}

# Records a Reply: token in the counters named by prefix $1 (brief_<x> for a
# gate label, brief_rp_<x> for a Re-plan revision); $2 is <type>:<label>.
count_reply() {
    local n="${1}_replies"
    printf -v "${n}" '%s' "$(( ${!n:-0} + 1 ))"
    deny_token "$2" "${reply_tok}"
    if [[ -n "${deny_tok}" ]]; then
        printf -v "${1}_deny" '%s' "${deny_tok}"
    else
        printf -v "${1}_ok" 1
    fi
}

# One pass over the brief ($1) of workflow $2. Per gate label g of
# brief_order: brief_rank_g, brief_g_seen (a section exists), brief_g_replies
# (Reply: lines with a token), brief_g_ok (one of them approves), brief_g_deny
# (the last non-approving token). Per Re-plan revision n, the same four as
# brief_rp_n_*; brief_rp_min is the lowest n with a section. brief_start is
# the rank of the first gate heading. A `### ` subheading does not end a
# section; any other `## ` heading does.
read_brief() {
    local l h g i=0 rank cur='' rx_gate rx_lab rx_rp
    rx_gate='^## Gate ([0-9]+[[:lower:]]?)([^0-9[:lower:]]|$)'
    rx_rp='^## Gate Re-plan - R([0-9]{1,6})([^0-9]|$)'
    for g in $(brief_order "$2"); do
        i=$((i + 1))
        printf -v "brief_rank_${g}" '%s' "${i}"
        printf -v "brief_${g}_seen" 0
        printf -v "brief_${g}_replies" 0
        printf -v "brief_${g}_ok" 0
        printf -v "brief_${g}_deny" ''
    done
    while IFS= read -r l || [[ -n "${l}" ]]; do
        if [[ "${l}" == "## "* ]]; then
            h="${l%"${l##*[![:space:]]}"}"
            cur=''
            rank=0
            if [[ "${h}" == "## Gate Re-plan"* ]]; then
                # It marks where a brief starts even when the workflow has no
                # Re-plan rule; its replies count only under a `- R<n>` heading.
                rank="${brief_rank_R:-0}"
                if [[ ${rank} -gt 0 && "${h}" =~ ${rx_rp} ]]; then
                    g=$((10#${BASH_REMATCH[1]}))
                    cur="brief_rp_${g}"
                    printf -v "${cur}_seen" 1
                    [[ ${brief_rp_min} -eq 0 || ${g} -lt ${brief_rp_min} ]] && brief_rp_min=${g}
                fi
            elif [[ "${h}" =~ ${rx_gate} ]]; then
                rx_lab="brief_rank_${BASH_REMATCH[1]}"
                if [[ -n "${!rx_lab:-}" ]]; then
                    rank="${!rx_lab}"
                    cur="brief_${BASH_REMATCH[1]}"
                    printf -v "${cur}_seen" 1
                fi
            fi
            [[ ${brief_start} -eq 0 && ${rank} -gt 0 ]] && brief_start=${rank}
            continue
        fi
        [[ -z "${cur}" ]] && continue
        [[ "${l}" =~ ^[[:blank:]]*Reply: ]] || continue
        reply_token "${l}"
        [[ -z "${reply_tok}" ]] && continue
        if [[ "${cur}" == brief_rp_* ]]; then
            count_reply "${cur}" "$2:R"
        else
            count_reply "${cur}" "$2:${cur#brief_}"
        fi
    done <<< "$1"
}

# Pushes onto `mis` what the gates "$@" lack together: one label, or a pool
# whose sections all record one decision (refactor Gates 2 and 3). The pool is
# checked when the brief covers it: its last gate is at or after the first gate
# the brief records. A gate before that point (a resumed spec, or one created
# before gate briefs existed) is never checked: a missing record is not a
# skipped gate. With -c first, a conditional gate (bug Gate 3a) is checked
# whenever it has a section, wherever the brief starts.
brief_missing() {
    local g v cond=0 top=0 seen=0 replies=0 deny='' names=''
    if [[ "$1" == "-c" ]]; then
        cond=1
        shift
    fi
    [[ ${brief_start} -gt 0 ]] || return 0
    for g in "$@"; do
        v="brief_${g}_ok"
        [[ "${!v:-0}" -eq 1 ]] && return 0
        v="brief_rank_${g}"
        [[ "${!v:-0}" -gt ${top} ]] && top="${!v}"
        v="brief_${g}_seen"
        [[ "${!v:-0}" -eq 1 ]] && seen=1
        v="brief_${g}_replies"
        replies=$((replies + ${!v:-0}))
        v="brief_${g}_deny"
        [[ -n "${!v:-}" ]] && deny="${!v}"
        if [[ -n "${names}" ]]; then
            names+=" or ## Gate ${g}"
        else
            names="## Gate ${g}"
        fi
    done
    if [[ ${cond} -eq 1 ]]; then
        [[ ${seen} -eq 1 ]] || return 0
    else
        [[ ${top} -ge ${brief_start} ]] || return 0
    fi
    if [[ ${seen} -eq 0 ]]; then
        push mis "a ## Gate $1 section in gate-briefs.md"
    elif [[ ${replies} -eq 0 ]]; then
        push mis "a Reply: line in a ${names} section of gate-briefs.md"
    else
        push mis "an approving Reply: line in a ${names} section of gate-briefs.md (last reply: ${deny})"
    fi
}

# Gate Re-plan (ADR 0029): every revision R<n> in `## Revisions` of the plan
# text $1 needs an approving reply in some `## Gate Re-plan - R<n>` section. A
# revision numbered below the first one the brief records predates gate
# briefs; with no Re-plan section at all, no revision is checked.
replan_findings() {
    local l n v seen done_rs=' ' revs
    [[ ${brief_rp_min} -gt 0 ]] || return 0
    revs="$(section_of "$1" "Revisions")" || return 0
    while IFS= read -r l || [[ -n "${l}" ]]; do
        [[ "${l}" =~ ^###[[:blank:]]+R([0-9]{1,6})([^0-9]|$) ]] || continue
        n=$((10#${BASH_REMATCH[1]}))
        [[ ${n} -ge ${brief_rp_min} && "${done_rs}" != *" ${n} "* ]] || continue
        done_rs+="${n} "
        mis=""
        v="brief_rp_${n}_seen"
        seen="${!v:-0}"
        v="brief_rp_${n}_ok"
        [[ "${!v:-0}" -eq 1 ]] && continue
        v="brief_rp_${n}_replies"
        if [[ ${seen} -eq 0 ]]; then
            push mis "a ## Gate Re-plan - R${n} section in gate-briefs.md"
        elif [[ "${!v:-0}" -eq 0 ]]; then
            push mis "a Reply: line in a ## Gate Re-plan - R${n} section of gate-briefs.md"
        else
            v="brief_rp_${n}_deny"
            push mis "an approving Reply: line in a ## Gate Re-plan - R${n} section of gate-briefs.md (last reply: ${!v})"
        fi
        add_finding "Re-plan R${n}" "${mis}" "01-plan.md ## Revisions records R${n}"
    done <<< "${revs}"
}

spec_text="$(doc_text "${dir}/00-spec.md")" || exit 0
has_decisions=0; [[ -f "${dir}/03-decisions.md" ]] && has_decisions=1
has_tasks=0; [[ -f "${dir}/02-tasks.md" ]] && has_tasks=1

brief_note=""
brief_start=0
brief_rp_min=0

# No gate-briefs.md: a spec from before gate briefs, or one no session has
# presented a gate for yet. Not evidence of a skipped gate, so brief_start stays
# 0 and brief_missing adds nothing. Read only for the workflows with brief rules.
brief=""
if [[ -n "$(brief_order "${spec_type}")" ]]; then
    brief="$(doc_text "${dir}/gate-briefs.md")" || brief=""
    if [[ -n "${brief}" ]]; then
        read_brief "${brief}" "${spec_type}"
        # No apostrophe: PowerShell 5.1's ConvertTo-Json would escape it as
        # ' and the twins' stdout would no longer be byte-identical.
        brief_note=" A /sd:${spec_type} gate is evidenced by its section in gate-briefs.md and the reply recorded on its Reply: line; if the user already answered that gate in this conversation, append that answer verbatim as the Reply: line with the Edit tool instead of asking again."
    fi
fi

# Phase 7 of /sd:bug and /sd:refactor opens its 05-retro.md entry with this
# heading; the Gate 5/6 suggestions logged before the brief never carry it.
has_closeout=0
retro="$(doc_text "${dir}/05-retro.md")" && has_line "${retro}" '^## Close-out[[:blank:]]*$' && has_closeout=1

case "${spec_type}" in
    feature)
        if [[ -n "${brief}" ]]; then

            # FEAT-G1: Spec approval.
            adv=""; mis=""
            [[ "${status}" == "approved" || "${status}" == "in-progress" ]] && push adv "status is ${status}"
            [[ ${has_tasks} -eq 1 ]] && push adv "02-tasks.md exists"
            [[ ${has_decisions} -eq 1 ]] && push adv "03-decisions.md exists"
            brief_missing 1
            add_finding "1 (Spec approval)" "${mis}" "${adv}"

            # FEAT-G2: Plan approval, either face (Complexity: no-split approves).
            adv=""; mis=""
            [[ "${status}" == "in-progress" ]] && push adv "status is in-progress"
            tasks="$(doc_text "${dir}/02-tasks.md")" || tasks=""
            has_line "${tasks}" '^- \*\*Status\*\*:[[:blank:]]*done([^A-Za-z0-9_]|$)' \
                && push adv "a task in 02-tasks.md is done"
            # An outline in 01-plan.md means Phase 3b may write 02-tasks.md only
            # after Gate 2 approved it (ADR 0022); a legacy plan has no outline.
            plan="$(doc_text "${dir}/01-plan.md")" || plan=""
            [[ ${has_tasks} -eq 1 ]] && has_line "${plan}" '^## Outline[[:blank:]]*$' \
                && push adv "02-tasks.md is expanded from the outline"
            brief_missing 2
            add_finding "2 (Plan approval)" "${mis}" "${adv}"

            # Gate Re-plan (ADR 0029).
            replan_findings "${plan}"

            # FEAT-G3: Integration and review.
            adv=""; mis=""
            verify="$(doc_text "${dir}/06-verify.md")" || verify=""
            has_line "${verify}" '^result:[[:blank:]]*pass[[:blank:]]*$' && push adv "06-verify.md records result: pass"
            brief_missing 3
            add_finding "3 (Integration and review)" "${mis}" "${adv}"
        fi
        ;;
    bug)
        root=""; root_filled=0
        root="$(section_of "${spec_text}" "Root cause")" && [[ "${root}" != *"<<PHASE-3:"* ]] && root_filled=1
        has_failing=0; [[ -f "${dir}/04-artifacts/repro/failing-test-output.txt" ]] && has_failing=1

        # BUG-G1: Symptom captured (ADR 0029).
        adv=""; mis=""
        [[ "${status}" == "approved" || "${status}" == "in-progress" ]] && push adv "status is ${status}"
        [[ ${has_decisions} -eq 1 ]] && push adv "03-decisions.md exists"
        brief_missing 1
        add_finding "1 (Symptom captured)" "${mis}" "${adv}"

        # BUG-G2: Reproduction confirmed. The constitution exception logged on
        # the insist path excuses both the unfilled section and the reply.
        adv=""; mis=""
        [[ "${status}" == "approved" || "${status}" == "in-progress" ]] && push adv "status is ${status}"
        [[ ${has_decisions} -eq 1 ]] && push adv "03-decisions.md exists"
        if repro="$(section_of "${spec_text}" "Reproduction")" && has_author_fill "${repro}"; then
            push mis "## Reproduction in 00-spec.md still has unfilled <<...>> fields"
        fi
        brief_missing 2
        if [[ -n "${mis}" && -n "${retro}" ]]; then
            if printf '%s\n' "${retro}" | grep -iE 'constitution exception' 2>/dev/null \
                | grep -qiE 'reproduc|gate 2' 2>/dev/null; then
                mis=""
            fi
        fi
        add_finding "2 (Reproduction confirmed)" "${mis}" "${adv}"

        # BUG-G3a: Hypothesis tree exhausted. Conditional: checked only when it
        # was presented. re-enumerate and observe answer it.
        adv=""; mis=""
        [[ ${root_filled} -eq 1 ]] && push adv "## Root cause is filled"
        [[ ${has_failing} -eq 1 ]] && push adv "04-artifacts/repro/failing-test-output.txt exists"
        brief_missing -c 3a
        add_finding "3a (Hypothesis tree exhausted)" "${mis}" "${adv}"

        # BUG-G3: Root cause confirmed. The root cause is written before its
        # brief, so the failing test is the first evidence past it.
        adv=""; mis=""
        [[ ${has_failing} -eq 1 ]] && push adv "04-artifacts/repro/failing-test-output.txt exists"
        [[ "${status}" == "in-progress" ]] && push adv "status is in-progress"
        brief_missing 3
        add_finding "3 (Root cause confirmed)" "${mis}" "${adv}"

        # BUG-G4: Failing test confirmed.
        adv=""; mis=""
        [[ "${status}" == "in-progress" ]] && push adv "status is in-progress"
        brief_missing 4
        add_finding "4 (Failing test confirmed)" "${mis}" "${adv}"

        # BUG-G5: Regression and review.
        adv=""; mis=""
        [[ ${has_closeout} -eq 1 ]] && push adv "05-retro.md has a ## Close-out section"
        brief_missing 5
        add_finding "5 (Regression and review)" "${mis}" "${adv}"
        ;;
    refactor)
        if [[ -n "${brief}" ]]; then
            has_plan=0; [[ -f "${dir}/01-plan.md" ]] && has_plan=1
            tasks="$(doc_text "${dir}/02-tasks.md")" || tasks=""
            task_done=0
            has_line "${tasks}" '^- \*\*Status\*\*:[[:blank:]]*done([^A-Za-z0-9_]|$)' && task_done=1

            # REF-G1: Spec approval.
            adv=""; mis=""
            [[ "${status}" == "approved" || "${status}" == "in-progress" ]] && push adv "status is ${status}"
            [[ ${has_decisions} -eq 1 ]] && push adv "03-decisions.md exists"
            [[ ${has_plan} -eq 1 ]] && push adv "01-plan.md exists"
            brief_missing 1
            add_finding "1 (Spec approval)" "${mis}" "${adv}"

            # REF-G2: Coverage threshold met. `add tests` leads to Gate 3, so
            # the decision is the approving reply in either gate.
            adv=""; mis=""
            [[ ${has_plan} -eq 1 ]] && push adv "01-plan.md exists"
            [[ ${has_tasks} -eq 1 ]] && push adv "02-tasks.md exists"
            [[ "${status}" == "in-progress" ]] && push adv "status is in-progress"
            brief_missing 2 3
            add_finding "2 (Coverage threshold met)" "${mis}" "${adv}"

            # REF-G4: Plan approval.
            adv=""; mis=""
            [[ "${status}" == "in-progress" ]] && push adv "status is in-progress"
            [[ ${task_done} -eq 1 ]] && push adv "a task in 02-tasks.md is done"
            for f in "${dir}"/04-artifacts/batches/batch-*-tests.txt; do
                [[ -f "${f}" ]] && { push adv "a 04-artifacts/batches/batch-*-tests.txt file exists"; break; }
            done
            brief_missing 4
            add_finding "4 (Plan approval)" "${mis}" "${adv}"

            # REF-G5: Tests green per batch.
            adv=""; mis=""
            [[ ${task_done} -eq 1 ]] && push adv "a task in 02-tasks.md is done"
            [[ -f "${dir}/04-artifacts/coverage/after-refactor.txt" ]] \
                && push adv "04-artifacts/coverage/after-refactor.txt exists"
            brief_missing 5
            add_finding "5 (Tests green per batch)" "${mis}" "${adv}"

            # Gate Re-plan (ADR 0029).
            plan="$(doc_text "${dir}/01-plan.md")" || plan=""
            replan_findings "${plan}"

            # REF-G6: Holistic review.
            adv=""; mis=""
            [[ ${has_closeout} -eq 1 ]] && push adv "05-retro.md has a ## Close-out section"
            brief_missing 6
            add_finding "6 (Holistic review)" "${mis}" "${adv}"
        fi
        ;;
    perf)
        # PERF-G2: Baseline measured.
        adv=""; mis=""
        tree=""; has_tree=0
        tree="$(section_of "${spec_text}" "Hypothesis tree")" && has_tree=1
        log="$(section_of "${spec_text}" "Results log")" || log=""
        target=""; has_target=0
        target="$(section_of "${spec_text}" "Target")" && has_target=1
        [[ "${status}" == "in-progress" ]] && push adv "status is in-progress"
        [[ ${has_decisions} -eq 1 ]] && push adv "03-decisions.md exists"
        [[ ${has_tree} -eq 1 && "${tree}" != *"<<PHASE-3:"* ]] && push adv "## Hypothesis tree is filled"
        has_line "${log}" '^\|[[:blank:]]*[1-9][0-9]*[[:blank:]]*\|' && push adv "the Results log has rows after the baseline"
        baseline=0
        for f in "${dir}"/04-artifacts/baseline-*; do
            [[ -f "${f}" ]] && { baseline=1; break; }
        done
        [[ ${baseline} -eq 0 ]] && push mis "no 04-artifacts/baseline-* file"
        has_line "${log}" '^\|[[:blank:]]*0[[:blank:]]*\|' || push mis "no Results log row 0"
        [[ ${has_target} -eq 1 && "${target}" == *"<<PHASE-2:"* ]] && push mis "## Target still holds a <<PHASE-2: ...>> field"
        add_finding "2 (Baseline measured)" "${mis}" "${adv}"
        ;;
    rca)
        # RCA-G2: Hypotheses enumerated (SW-51).
        adv=""; mis=""
        root=""; has_root=0
        root="$(section_of "${spec_text}" "Root cause")" && has_root=1
        tree=""; has_tree=0
        tree="$(section_of "${spec_text}" "Hypothesis tree")" && has_tree=1
        [[ "${status}" == "approved" || "${status}" == "in-progress" ]] && push adv "status is ${status}"
        [[ ${has_root} -eq 1 && "${root}" != *"<<PHASE-3:"* ]] && push adv "## Root cause is filled"
        [[ ${has_tree} -eq 1 && "${tree}" == *"<<PHASE-2:"* ]] && push mis "## Hypothesis tree still holds a <<PHASE-2: ...>> field"
        add_finding "2 (Hypotheses enumerated)" "${mis}" "${adv}"
        ;;
    port)
        status_adv=0
        [[ "${status}" == "approved" || "${status}" == "in-progress" ]] && status_adv=1

        # PORT-G1: Donor set frozen.
        adv=""; mis=""
        [[ ${status_adv} -eq 1 ]] && push adv "status is ${status}"
        [[ ${has_tasks} -eq 1 ]] && push adv "02-tasks.md exists"
        [[ -f "${dir}/04-artifacts/source/MANIFEST.md" ]] || push mis "no 04-artifacts/source/MANIFEST.md"
        has_line "${spec_text}" '^- \*\*Frozen\*\*:[[:blank:]]*yes([^A-Za-z0-9_]|$)' || push mis "the Frozen line does not say yes"
        add_finding "1 (Donor set frozen)" "${mis}" "${adv}"

        # PORT-G2: Fidelity tables complete.
        adv=""; mis=""
        [[ ${status_adv} -eq 1 ]] && push adv "status is ${status}"
        has_author_fill "${spec_text}" && push mis "00-spec.md still has unfilled <<...>> fields"
        add_finding "2 (Fidelity tables complete)" "${mis}" "${adv}"

        # PORT-G3: Behavior pinned.
        adv=""; mis=""
        [[ ${has_tasks} -eq 1 ]] && push adv "02-tasks.md exists"
        decisions="$(doc_text "${dir}/03-decisions.md")" || decisions=""
        has_line "${decisions}" '^## Behavior pinning' || push mis "03-decisions.md has no ## Behavior pinning section"
        add_finding "3 (Behavior pinned)" "${mis}" "${adv}"

        # PORT-G6: Justified-diff parity.
        adv=""; mis=""
        [[ -f "${dir}/06-verify.md" ]] && push adv "06-verify.md exists"
        [[ -f "${dir}/04-artifacts/parity/INDEX.md" ]] || push mis "no 04-artifacts/parity/INDEX.md"
        add_finding "6 (Justified-diff parity)" "${mis}" "${adv}"
        ;;
esac

[[ -z "${findings}" ]] && exit 0

reason="specwright stop-gate: ${active} (/sd:${spec_type}) is past a HARD gate without its evidence.${findings}${brief_note} Return to that gate: present it to the user and STOP for their answer, or undo the later-phase work. HARD gates have no override."
jq -nc --arg r "${reason}" '{decision:"block",reason:$r}' 2>/dev/null | tr -d '\r'
exit 0
