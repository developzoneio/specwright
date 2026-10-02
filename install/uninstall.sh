#!/usr/bin/env bash
# Uninstaller for specwright from a Claude Code base directory.
#
# Removes the engine directories installed by install.sh from <base>
# (default $HOME/.claude). Exactly five directories are removed, including
# any installer-created .bak.* backups inside them:
#   <base>/commands/sd/   <base>/agents/sd/
#   <base>/hooks/sd/      <base>/templates/sd/
#   <base>/skills/sd/
#
# Nothing else under the base path is touched. Per-project artifacts
# (.claude/settings.json hook wiring, .claude/.hookstate/, .specs/) are
# reported at the end but never removed by this script.
#
# Features:
#   - --dry-run preview.
#   - Single confirmation prompt before removal (suppressed by --force).
#   - Idempotent: running with nothing installed exits 0.

set -euo pipefail

# ---- defaults --------------------------------------------------------------

BASE_PATH="${HOME}/.claude"
PREFIX="sd"
DRY_RUN=0
FORCE=0

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
warn()    { echo "  ${C_YELLOW}[WARN]${C_RESET} $*"; }
fail()    { echo "  ${C_RED}[FAIL]${C_RESET} $*"; }

# ---- arg parsing -----------------------------------------------------------

usage() {
    cat <<'EOF'
specwright uninstaller (Unix).

Usage:
  ./uninstall.sh [options]

Options:
  --base-path <path>   Base directory (default: $HOME/.claude)
  --prefix <name>      Namespace subfolder under each engine dir (default: sd)
  --dry-run            Preview without deleting.
  --force              Skip the confirmation prompt.
  --help               Show this message.

Examples:
  ./uninstall.sh --dry-run
  ./uninstall.sh
  ./uninstall.sh --base-path /tmp/sd-test --force
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
# Mirrors install.sh's guard exactly - install and uninstall must accept the
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
# Mirrors install.sh's guard exactly - install and uninstall must accept the
# same set of base paths, or a base path legal for one and rejected by the
# other leaves orphaned or unreachable files.
#
# Uses [[:space:]], same as the prefix guard above, to match PowerShell's
# IsNullOrWhiteSpace (tab/CR/LF/VT/FF, not just spaces).

if [[ -z "${BASE_PATH//[[:space:]]/}" ]]; then
    fail "Invalid base path '$BASE_PATH'. Must not be empty or whitespace-only."
    exit 2
fi

section "specwright uninstaller"
info "Script:    ${BASH_SOURCE[0]}"
info "Base path: $BASE_PATH"
info "Prefix:    $PREFIX"
if [[ $DRY_RUN -eq 1 ]]; then
    info "Mode:      DRY RUN (no changes)"
elif [[ $FORCE -eq 1 ]]; then
    info "Mode:      UNINSTALL [Force]"
else
    info "Mode:      UNINSTALL"
fi

# ---- enumerate targets -----------------------------------------------------

# Same five areas the installer writes to.
AREAS=("commands" "agents" "hooks" "templates" "skills")

section "Removal plan"

TARGETS=()
TOTAL_FILES=0
TOTAL_BACKUPS=0

for a in "${AREAS[@]}"; do
    dir="$BASE_PATH/$a/$PREFIX"
    if [[ -d "$dir" ]]; then
        file_count="$(find "$dir" -type f 2>/dev/null | wc -l | tr -d ' ')"
        backup_count="$(find "$dir" -type f -name '*.bak.*' 2>/dev/null | wc -l | tr -d ' ')"
        plan "$dir (${file_count} file(s))"
        TARGETS+=("$dir")
        TOTAL_FILES=$((TOTAL_FILES + file_count))
        TOTAL_BACKUPS=$((TOTAL_BACKUPS + backup_count))
    else
        skip "$dir (not found)"
    fi
done

if [[ $TOTAL_BACKUPS -gt 0 ]]; then
    warn "$TOTAL_BACKUPS installer backup file(s) (.bak.*) will be deleted too."
fi

if [[ ${#TARGETS[@]} -eq 0 ]]; then
    echo
    ok "Nothing to remove."
    exit 0
fi

# ---- dry run stops here ----------------------------------------------------

if [[ $DRY_RUN -eq 1 ]]; then
    section "Summary"
    info "Would remove: $TOTAL_FILES file(s) across ${#TARGETS[@]} director(ies)"
    info ""
    info "Run without --dry-run to apply."
    exit 0
fi

# ---- confirm ---------------------------------------------------------------

if [[ $FORCE -ne 1 ]]; then
    ans=""
    read -r -p "Remove $TOTAL_FILES file(s) across ${#TARGETS[@]} director(ies)? [y/N] " ans </dev/tty || ans=""
    if [[ "$ans" != "y" ]]; then
        skip "Aborted. Nothing removed."
        exit 0
    fi
fi

# ---- remove ----------------------------------------------------------------

section "Removing"

REMOVED_DIRS=0
for dir in "${TARGETS[@]}"; do
    rm -rf "$dir"
    ok "$dir"
    REMOVED_DIRS=$((REMOVED_DIRS + 1))
done

# ---- summary ---------------------------------------------------------------

section "Summary"
info "Removed: $TOTAL_FILES file(s) across $REMOVED_DIRS director(ies)"

section "Per-project leftovers (not touched by this script)"
info "1. Projects that wired hooks in .claude/settings.json now point at deleted"
info "   scripts. Remove the \"hooks\" block there, or re-run /sd:setup after a reinstall."
info ""
info "2. Per-project artifacts remain until you remove them manually:"
info "     .claude/.hookstate/          (subagent-retro debounce, PreCompact pointers)"
info "     .claude/project-config.json"
info "     .specs/"
info "     CLAUDE.md"

exit 0
