#!/usr/bin/env bash
# Installer for specwright into a Claude Code base directory.
#
# Copies the engine (commands, agents, bash hooks, templates) under <base>/<prefix>/
# (default prefix "sd") for each engine folder:
#   <base>/commands/sd/   <base>/agents/sd/
#   <base>/hooks/sd/      <base>/templates/sd/
#
# Features:
#   - --dry-run preview.
#   - SHA256 dedup via shasum -a 256 OR sha256sum (portable).
#   - Timestamped backups before overwrite.
#   - Interactive prompt on differing files (y / N / a=all). Suppressed by --force.
#   - chmod +x for bash hooks after install.

set -Eeuo pipefail

# ---- defaults --------------------------------------------------------------

BASE_PATH="${HOME}/.claude"
PREFIX="sd"
DRY_RUN=0
FORCE=0
APPLY_ALL=0

# ---- color helpers ---------------------------------------------------------

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_CYAN=$'\033[36m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
    C_GRAY=$'\033[90m'
else
    C_RESET='' C_CYAN='' C_GREEN='' C_YELLOW='' C_RED='' C_GRAY=''
fi

section() { echo; echo "${C_CYAN}=== $* ===${C_RESET}"; }
info()    { echo "  $*"; }
ok()      { echo "  ${C_GREEN}[OK]${C_RESET}   $*"; }
skip()    { echo "  ${C_GRAY}[SKIP]${C_RESET} $*"; }
plan()    { echo "  ${C_YELLOW}[PLAN]${C_RESET} $*"; }
bak()     { echo "  ${C_YELLOW}[BAK]${C_RESET}  $*"; }
warn()    { echo "  ${C_YELLOW}[WARN]${C_RESET} $*"; }
fail()    { echo "  ${C_RED}[FAIL]${C_RESET} $*"; }

# ---- arg parsing -----------------------------------------------------------

usage() {
    cat <<'EOF'
specwright installer (Unix).

Usage:
  ./install.sh [options]

Options:
  --base-path <path>   Base directory (default: $HOME/.claude)
  --prefix <name>      Namespace subfolder under each engine dir (default: sd)
  --dry-run            Preview without copying.
  --force              Overwrite without prompting (backups still made).
  --help               Show this message.

Examples:
  ./install.sh --dry-run
  ./install.sh
  ./install.sh --base-path /tmp/sd-test --force
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-path)
            if [[ $# -lt 2 ]]; then
                fail "Missing value for $1"
                usage; exit 2
            fi
            BASE_PATH="$2"; shift 2 ;;
        --prefix)
            if [[ $# -lt 2 ]]; then
                fail "Missing value for $1"
                usage; exit 2
            fi
            PREFIX="$2"; shift 2 ;;
        --dry-run)
            DRY_RUN=1; shift ;;
        --force)
            FORCE=1; shift ;;
        --help|-h)
            usage; exit 0 ;;
        *)
            fail "Unknown argument: $1"
            usage; exit 2 ;;
    esac
done

# ---- prefix safety guard ---------------------------------------------------
# Mirrors uninstall.sh's guard exactly - install and uninstall must accept the
# same set of prefixes, or a prefix legal for one and rejected by the other
# leaves orphaned or unreachable files.
#
# [[:space:]] rather than a spaces-only `// /` strip: PowerShell's
# IsNullOrWhiteSpace also rejects tab/CR/LF/VT/FF, and a narrower check here
# would accept prefixes the .ps1 installers reject (SW-53). The shared case
# table in tests/installer/prefix-cases.json pins all four scripts together.

if [[ -z "${PREFIX//[[:space:]]/}" || "$PREFIX" == */* || "$PREFIX" == *\\* || "$PREFIX" == *..* ]]; then
    fail "Invalid prefix '$PREFIX'. Must be a plain folder name (no separators, no '..')."
    exit 1
fi

# ---- base-path safety guard -------------------------------------------------
# Mirrors uninstall.sh's guard exactly - install and uninstall must accept the
# same set of base paths, or a base path legal for one and rejected by the
# other leaves orphaned or unreachable files.
#
# Uses [[:space:]], same as the prefix guard above, to match PowerShell's
# IsNullOrWhiteSpace (tab/CR/LF/VT/FF, not just spaces).

if [[ -z "${BASE_PATH//[[:space:]]/}" ]]; then
    fail "Invalid base path '$BASE_PATH'. Must not be empty or whitespace-only."
    exit 2
fi

# ---- portable helpers ------------------------------------------------------

sha256_of() {
    local f="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" 2>/dev/null | awk '{print $1}' || true
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$f" 2>/dev/null | awk '{print $1}' || true
    else
        echo ""
    fi
}

now_stamp() {
    date +'%Y%m%d-%H%M%S'
}

engine_version() {
    local repo_root="$1"
    local changelog="$repo_root/CHANGELOG.md"
    if [[ ! -f "$changelog" ]]; then
        return 1
    fi
    local line
    line="$(grep -m1 -E '^##[[:space:]]+\[[0-9]+\.[0-9]+\.[0-9]+\][[:space:]]+-[[:space:]]+[^[:space:]]' "$changelog" || true)"
    if [[ "$line" =~ \[([0-9]+\.[0-9]+\.[0-9]+)\] ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    return 1
}

# ---- repo root -------------------------------------------------------------

# Resolve script directory portably
SCRIPT_PATH="${BASH_SOURCE[0]}"
if command -v readlink >/dev/null 2>&1; then
    SCRIPT_PATH="$(readlink -f "$SCRIPT_PATH" 2>/dev/null || readlink "$SCRIPT_PATH" 2>/dev/null || echo "$SCRIPT_PATH")"
fi
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

section "specwright installer"
info "Script:    $SCRIPT_PATH"
info "Repo root: $REPO_ROOT"
info "Base path: $BASE_PATH"
info "Prefix:    $PREFIX"
if [[ $DRY_RUN -eq 1 ]]; then
    info "Mode:      DRY RUN (no changes)"
elif [[ $FORCE -eq 1 ]]; then
    info "Mode:      INSTALL [Force]"
else
    info "Mode:      INSTALL"
fi

# ---- verify source layout --------------------------------------------------

section "Verifying source layout"

REQUIRED_DIRS=("commands" "agents" "hooks/bash" "templates" "skills")
MISSING=0
for d in "${REQUIRED_DIRS[@]}"; do
    if [[ -d "$REPO_ROOT/$d" ]]; then
        ok "$d"
    else
        fail "$d"
        MISSING=$((MISSING+1))
    fi
done

if [[ $MISSING -gt 0 ]]; then
    echo
    fail "Missing required source directories. Are you running this from a clean specwright checkout?"
    exit 1
fi

# Verify a sha256 tool exists
if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    warn "Neither sha256sum nor shasum found; content-hash dedup will be skipped (all existing files will be treated as differing)."
fi

# ---- resolve engine version -------------------------------------------------

CHANGELOG_PATH="$REPO_ROOT/CHANGELOG.md"
ENGINE_VERSION="$(engine_version "$REPO_ROOT")" || true
if [[ -z "$ENGINE_VERSION" ]]; then
    echo
    fail "$CHANGELOG_PATH : no dated release heading found (## [x.y.z] - <date>)"
    exit 1
fi

# ---- install plan ----------------------------------------------------------
# Format: "source_rel:target_rel:executable_flag"

PLAN=(
    "commands:commands/${PREFIX}:0"
    "agents:agents/${PREFIX}:0"
    "hooks/bash:hooks/${PREFIX}:1"
    "templates:templates/${PREFIX}:0"
    "skills:skills/${PREFIX}:0"
)

section "Install plan"
for entry in "${PLAN[@]}"; do
    IFS=':' read -r src tgt _ <<< "$entry"
    plan "$src  ->  $BASE_PATH/$tgt"
done

# ---- counters --------------------------------------------------------------

INSTALLED=0
SKIPPED_SAME=0
SKIPPED_DECLINE=0
BACKED_UP=0

# ---- partial-install guard --------------------------------------------------
# No transactional rollback (per-file backups already protect overwritten
# files) - on an unexpected failure mid-copy, tell the user what already
# landed and how to clean up rather than leaving a silent partial install.

on_error() {
    local code=$?
    if [[ $DRY_RUN -ne 1 && $INSTALLED -gt 0 ]]; then
        echo
        fail "Install aborted (exit $code) after installing $INSTALLED file(s)."
        warn "Partial install at '$BASE_PATH' (prefix '$PREFIX'). Run:"
        warn "  ./install/uninstall.sh --base-path \"$BASE_PATH\" --prefix \"$PREFIX\" --force"
        warn "then retry the install."
    fi
}
trap on_error ERR

# ---- copy one file ---------------------------------------------------------

copy_one() {
    local src_file="$1" tgt_file="$2" executable="$3"

    if [[ $DRY_RUN -eq 1 ]]; then
        if [[ -f "$tgt_file" ]]; then
            local sh tg
            sh="$(sha256_of "$src_file")"
            tg="$(sha256_of "$tgt_file")"
            if [[ -n "$sh" && -n "$tg" && "$sh" == "$tg" ]]; then
                skip "would skip (identical): $tgt_file"
                SKIPPED_SAME=$((SKIPPED_SAME+1))
            else
                plan "would overwrite (with backup): $tgt_file"
                INSTALLED=$((INSTALLED+1))
            fi
        else
            plan "would install: $tgt_file"
            INSTALLED=$((INSTALLED+1))
        fi
        return 0
    fi

    if [[ -f "$tgt_file" ]]; then
        local sh tg
        sh="$(sha256_of "$src_file")"
        tg="$(sha256_of "$tgt_file")"
        if [[ -n "$sh" && -n "$tg" && "$sh" == "$tg" ]]; then
            skip "identical: $tgt_file"
            SKIPPED_SAME=$((SKIPPED_SAME+1))
            return 0
        fi

        if [[ $FORCE -ne 1 && $APPLY_ALL -ne 1 ]]; then
            local rel="$(basename "$tgt_file")"
            local ans
            read -r -p "Overwrite '$rel' ? [y/N/a=all] " ans </dev/tty || ans=""
            if [[ "$ans" == "a" ]]; then
                APPLY_ALL=1
            elif [[ "$ans" != "y" ]]; then
                skip "declined: $tgt_file"
                SKIPPED_DECLINE=$((SKIPPED_DECLINE+1))
                return 0
            fi
        fi

        local stamp bakfile
        stamp="$(now_stamp)"
        bakfile="${tgt_file}.bak.${stamp}"
        cp -p "$tgt_file" "$bakfile"
        bak "$bakfile"
        BACKED_UP=$((BACKED_UP+1))
    fi

    mkdir -p "$(dirname "$tgt_file")"
    cp "$src_file" "$tgt_file"
    if [[ "$executable" == "1" ]]; then
        chmod +x "$tgt_file"
    fi
    ok "$tgt_file"
    INSTALLED=$((INSTALLED+1))
}

# ---- copy each plan entry --------------------------------------------------

section "Copying files"

for entry in "${PLAN[@]}"; do
    IFS=':' read -r src tgt exec_flag <<< "$entry"
    src_root="$REPO_ROOT/$src"
    tgt_root="$BASE_PATH/$tgt"

    while IFS= read -r -d '' f; do
        rel="${f#"$src_root"/}"
        copy_one "$f" "$tgt_root/$rel" "$exec_flag"
    done < <(find "$src_root" -type f -print0)
done

# ---- write version stamp ----------------------------------------------------
# Route the resolved version through the existing copy_one so hash-skip,
# backup, decline and dry-run logic apply identically to every other file.
# copy_one increments the counters itself; do not increment again here. The
# EXIT trap here is additional to (and does not replace) the ERR trap above.

STAMP_TMP="$(mktemp)"
trap 'rm -f "$STAMP_TMP"' EXIT
printf '%s\n' "$ENGINE_VERSION" > "$STAMP_TMP"

for entry in "${PLAN[@]}"; do
    IFS=':' read -r src tgt _ <<< "$entry"
    tgt_root="$BASE_PATH/$tgt"
    copy_one "$STAMP_TMP" "$tgt_root/specwright-version.txt" "0"
done

# ---- summary ---------------------------------------------------------------

section "Summary"
if [[ $DRY_RUN -eq 1 ]]; then
    info "Planned to install: $INSTALLED file(s)"
    info "Would skip identical: $SKIPPED_SAME"
    info ""
    info "Run without --dry-run to apply."
else
    info "Installed:          $INSTALLED file(s)"
    info "Skipped identical:  $SKIPPED_SAME"
    info "Declined:           $SKIPPED_DECLINE"
    info "Backups created:    $BACKED_UP"
fi

section "Next steps"
info "1. Verify install:"
info "     ls $BASE_PATH/commands/${PREFIX}/"
info "     ls $BASE_PATH/agents/${PREFIX}/"
info "     ls $BASE_PATH/hooks/${PREFIX}/"
info "     ls $BASE_PATH/skills/${PREFIX}/"
info ""
info "2. In a project directory:"
info "     claude"
info "     /sd:setup"
info ""
info "3. Restart Claude Code so hooks are picked up."
info ""
info "4. Hook wiring (Bash - add to your project .claude/settings.json):"
info "     \"hooks\": {"
info "       \"UserPromptSubmit\": [{\"matcher\":\"*\",\"hooks\":[{\"type\":\"command\","
info "         \"command\":\"bash \${HOME}/.claude/hooks/${PREFIX}/prompt-router.sh\",\"timeout\":5}]}],"
info "       \"PreToolUse\": [{\"matcher\":\"Edit|Write|MultiEdit|Bash|PowerShell\",\"hooks\":[{\"type\":\"command\","
info "         \"command\":\"bash \${HOME}/.claude/hooks/${PREFIX}/spec-gate.sh\",\"timeout\":5}]}],"
info "       \"SubagentStop\": [{\"matcher\":\"*\",\"hooks\":[{\"type\":\"command\","
info "         \"command\":\"bash \${HOME}/.claude/hooks/${PREFIX}/subagent-retro.sh\",\"timeout\":3}]}]"
info "     }"
info "   (Or run /sd:setup in your project - it generates settings.json automatically.)"

exit 0
