#!/usr/bin/env bash
# specwright: hook smoke test (Unix / bash).
#
# Pipes sample Claude Code hook JSON into hooks/bash/*.sh against a fixture
# .specs/ tree and asserts exit codes + key output substrings - not just
# "did not crash". Mirror of scripts/smoke-hooks.ps1 (runs the PowerShell
# hook twins). Both must agree on the routed workflow for prompt-router.
#
# Exit 0 = all cases passed; 1 = at least one failed; 2 = cannot run (missing
# dependency on the runner - reported as such, never blamed on a hook).

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

pass=0
fail=0

if [[ -t 1 ]]; then
    c_reset=$'\033[0m'; c_green=$'\033[32m'; c_red=$'\033[31m'; c_cyan=$'\033[36m'
else
    c_reset=''; c_green=''; c_red=''; c_cyan=''
fi

section() { echo; echo "${c_cyan}=== $* ===${c_reset}"; }
ok()      { echo "  ${c_green}[OK]${c_reset}   $*"; pass=$((pass + 1)); }
bad()     { echo "  ${c_red}[FAIL]${c_reset} $*"; fail=$((fail + 1)); }

assert_exit0() {
    local desc="$1" code="$2"
    if [[ "$code" -eq 0 ]]; then ok "$desc : exit 0"; else bad "$desc : exit $code (expected 0)"; fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        ok "$desc : contains \"$needle\""
    else
        bad "$desc : missing \"$needle\" -- got: ${haystack:0:200}"
    fi
}

assert_empty() {
    local desc="$1" haystack="$2"
    if [[ -z "$haystack" ]]; then ok "$desc : empty output"; else bad "$desc : expected empty, got: ${haystack:0:200}"; fi
}

# ---- preflight --------------------------------------------------------------
# Hooks exit 0 silently without jq so they never block a user. That same silence
# would make every assertion below fail and blame the hooks for a dependency the
# RUNNER is missing - so refuse to start instead, and say which dependency.

if ! command -v jq >/dev/null 2>&1; then
    echo "  ${c_red}[FAIL]${c_reset} jq is required to run the hook smoke suite - install jq." >&2
    echo "         This is a missing runner dependency, not a hook failure." >&2
    exit 2
fi

# ---- fixture repo -----------------------------------------------------------

fixture="$(mktemp -d)"
cleanup() { rm -rf "$fixture"; }
trap cleanup EXIT

mkdir -p "$fixture/.claude" "$fixture/.specs/FEAT-TEST-001"

cat > "$fixture/.claude/project-config.json" <<JSON
{
  "spec": {"dir": ".specs", "indexFile": ".specs/index.md"},
  "ticket": {"pattern": "^[A-Z]+-[0-9]+\$"},
  "workflow": {
    "keywords": {
      "bug": ["bug", "fix", "broken", "error", "crash", "regression", "defect"],
      "feature": ["feature", "add", "implement", "new", "support"],
      "refactor": ["refactor", "restructure", "clean up", "extract", "rename"],
      "perf": ["perf", "performance", "slow", "optimize", "latency", "throughput"],
      "rca": ["incident", "outage", "rca", "root cause", "post-mortem", "postmortem"]
    }
  },
  "hooks": {
    "userPromptRouter": {"enabled": true},
    "specGate": {"enabled": true, "mode": "block"},
    "subagentRetro": {"enabled": true, "retroStaleMinutes": 0, "debounceMinutes": 10}
  }
}
JSON

# in-progress spec with the marker and ID on the same line
cat > "$fixture/.specs/index.md" <<'MD'
| ID | Type | Status | Title |
|---|---|---|---|
| FEAT-TEST-001 | feature | in-progress | Test feature |
MD

# "in-progress" appears only in a header/legend line - no row has it on the
# same line as a spec ID (mirrors the doc-02 same-line-detection fix).
cat > "$fixture/.specs/index-header-only.md" <<'MD'
| ID | Type | Status (in-progress = active work) | Title |
|---|---|---|---|
| FEAT-DONE-002 | feature | done | Finished feature |
MD

run_hook() {
    # run_hook <hook-script> <stdin-payload> -> sets STDOUT, STDERR, CODE
    local hook="$1" payload="$2"
    local out_file err_file
    out_file="$(mktemp)"; err_file="$(mktemp)"
    # Capture the exit code explicitly: under set -e a non-zero hook exit would
    # otherwise abort the suite instead of being reported by assert_exit0.
    CODE=0
    printf '%s' "$payload" | bash "$hook" >"$out_file" 2>"$err_file" || CODE=$?
    STDOUT="$(cat "$out_file")"
    STDERR="$(cat "$err_file")"
    rm -f "$out_file" "$err_file"
}

# ---- prompt-router: keyword match --------------------------------------------

section "prompt-router (bash): keyword match routes to /sd:bug"
payload="$(printf '{"prompt":"please fix this bug","cwd":"%s"}' "$fixture")"
run_hook "$repo_root/hooks/bash/prompt-router.sh" "$payload"
assert_exit0 "prompt-router keyword match" "$CODE"
assert_contains "prompt-router keyword match" "$STDOUT" "<context-router>"
assert_contains "prompt-router keyword match" "$STDOUT" "/sd:bug"
BASH_ROUTER_OUT="$STDOUT"

# ---- spec-gate: (a) code edit with in-progress spec -> allow ----------------

section "spec-gate (bash): (a) code edit with in-progress spec -> allow"
payload="$(printf '{"tool_name":"Edit","cwd":"%s","tool_input":{"file_path":"%s/src/Foo.py"}}' "$fixture" "$fixture")"
run_hook "$repo_root/hooks/bash/spec-gate.sh" "$payload"
assert_exit0 "spec-gate (a) in-progress -> allow" "$CODE"
assert_empty "spec-gate (a) in-progress -> allow" "$STDOUT"

# ---- spec-gate: (b) header-only "in-progress" -> block/warn, not allow ------

section "spec-gate (bash): (b) header-only in-progress text -> block (mode=block)"
config_block="$fixture/.claude/project-config.json"
cp "$fixture/.specs/index-header-only.md" "$fixture/.specs/index.md.bak-swap"
mv "$fixture/.specs/index.md" "$fixture/.specs/index.md.real"
mv "$fixture/.specs/index-header-only.md" "$fixture/.specs/index.md"
payload="$(printf '{"tool_name":"Edit","cwd":"%s","tool_input":{"file_path":"%s/src/Bar.py"}}' "$fixture" "$fixture")"
run_hook "$repo_root/hooks/bash/spec-gate.sh" "$payload"
assert_exit0 "spec-gate (b) header-only, mode=block" "$CODE"
assert_contains "spec-gate (b) header-only, mode=block" "$STDOUT" '"decision":"block"'
assert_contains "spec-gate (b) header-only, mode=block" "$STDOUT" '"permissionDecision":"deny"'

section "spec-gate (bash): (b) header-only in-progress text -> warn (mode=warn)"
python_free_sed() { sed -i.bak 's/"mode": "block"/"mode": "warn"/' "$config_block" && rm -f "$config_block.bak"; }
python_free_sed
run_hook "$repo_root/hooks/bash/spec-gate.sh" "$payload"
assert_exit0 "spec-gate (b) header-only, mode=warn" "$CODE"
assert_empty "spec-gate (b) header-only, mode=warn stdout" "$STDOUT"
assert_contains "spec-gate (b) header-only, mode=warn stderr" "$STDERR" "[WARN]"
sed -i.bak 's/"mode": "warn"/"mode": "block"/' "$config_block" && rm -f "$config_block.bak"
mv "$fixture/.specs/index.md" "$fixture/.specs/index-header-only.md.used"
mv "$fixture/.specs/index.md.real" "$fixture/.specs/index.md"
rm -f "$fixture/.specs/index.md.bak-swap" "$fixture/.specs/index-header-only.md.used"

# ---- spec-gate: (c) docs edit -> always allow --------------------------------

section "spec-gate (bash): (c) docs edit -> allow regardless of spec state"
payload="$(printf '{"tool_name":"Edit","cwd":"%s","tool_input":{"file_path":"%s/docs/guide.md"}}' "$fixture" "$fixture")"
run_hook "$repo_root/hooks/bash/spec-gate.sh" "$payload"
assert_exit0 "spec-gate (c) docs edit -> allow" "$CODE"
assert_empty "spec-gate (c) docs edit -> allow" "$STDOUT"

# ---- spec-gate: (d) malformed JSON on stdin -> exit 0 silently --------------

section "spec-gate (bash): (d) malformed JSON on stdin -> exit 0 silently"
run_hook "$repo_root/hooks/bash/spec-gate.sh" '{not valid json'
assert_exit0 "spec-gate (d) malformed JSON" "$CODE"
assert_empty "spec-gate (d) malformed JSON" "$STDOUT"

# ---- spec-gate: (e)/(f) archived parent + registered child -> complexity split (SW-31) ----
# Same pending index.md content in both cases - only paths.protected differs.
# (e) proves the split is recorded when the edit is actually ALLOWED through.
# (f) proves it is NOT recorded when the SAME edit is denied (index.md
# protected, the default) - nothing reached disk, so no split happened.

split_fixture="$(mktemp -d)"
mkdir -p "$split_fixture/.specs" "$split_fixture/.claude"
cat > "$split_fixture/.specs/index.md" <<'MD'
| ID | Type | Status | Created | Title |
|---|---|---|---|---|
| FEAT-big | feature | in-progress | 2026-08-01 | Big oversized thing |
| FEAT-big-partA | feature | draft | 2026-08-09 | Part A |
MD
new_content='| ID | Type | Status | Created | Title |
|---|---|---|---|---|
| FEAT-big | feature | archived | 2026-08-01 | Big oversized thing |
| FEAT-big-partA | feature | draft | 2026-08-09 | Part A |'
payload="$(jq -n --arg cwd "$split_fixture" --arg fp ".specs/index.md" --arg newc "$new_content" \
    '{tool_name:"Write",cwd:$cwd,tool_input:{file_path:$fp,content:$newc}}')"

section "spec-gate (bash): (e) allowed edit with archived parent + registered child -> complexity split metric"
cat > "$split_fixture/.claude/project-config.json" <<'JSON'
{"spec":{"dir":".specs","indexFile":".specs/index.md"},"paths":{"protected":[]}}
JSON
run_hook "$repo_root/hooks/bash/spec-gate.sh" "$payload"
assert_exit0 "spec-gate (e) complexity split, allowed" "$CODE"
events="$(cat "$split_fixture/.specs/_metrics/events.jsonl" 2>/dev/null || true)"
assert_contains "spec-gate (e) complexity split, allowed" "$events" '"gate":"complexity","decision":"split"'
assert_contains "spec-gate (e) complexity split, allowed" "$events" '"spec_id":"FEAT-big"'

section "spec-gate (bash): (f) blocked edit (default protected index.md) -> no complexity split metric"
rm -f "$split_fixture/.specs/_metrics/events.jsonl"
rm -f "$split_fixture/.claude/project-config.json"
run_hook "$repo_root/hooks/bash/spec-gate.sh" "$payload"
assert_exit0 "spec-gate (f) complexity split, blocked" "$CODE"
assert_contains "spec-gate (f) complexity split, blocked" "$STDOUT" '"decision":"block"'
events="$(cat "$split_fixture/.specs/_metrics/events.jsonl" 2>/dev/null || true)"
if [[ "$events" == *'"gate":"complexity"'* ]]; then
    bad "spec-gate (f) complexity split, blocked : split metric wrongly recorded for a denied edit"
else
    ok "spec-gate (f) complexity split, blocked : no split metric recorded"
fi
rm -rf "$split_fixture"

# ---- subagent-retro: missing retro names the spec, then debounces ----------

section "subagent-retro (bash): missing 05-retro.md names the real spec ID"
payload="$(printf '{"cwd":"%s","session_id":"smoke-test-session"}' "$fixture")"
run_hook "$repo_root/hooks/bash/subagent-retro.sh" "$payload"
assert_exit0 "subagent-retro first run" "$CODE"
assert_contains "subagent-retro first run" "$STDOUT" "<retro-reminder>"
assert_contains "subagent-retro first run" "$STDOUT" "FEAT-TEST-001"

section "subagent-retro (bash): second run within debounce window is silent"
run_hook "$repo_root/hooks/bash/subagent-retro.sh" "$payload"
assert_exit0 "subagent-retro second run (debounced)" "$CODE"
assert_empty "subagent-retro second run (debounced)" "$STDOUT"

# ---- summary -----------------------------------------------------------------

section "Summary"
echo "  $pass passed, $fail failed"
if [[ $fail -eq 0 ]]; then
    echo "  ${c_green}[OK]${c_reset}   All hook smoke tests passed."
    exit 0
else
    echo "  ${c_red}[FAIL]${c_reset} $fail smoke test(s) failed."
    exit 1
fi
