# ADR 0012: hook latency - keep the timeouts, enforce a p95 budget below half of them

- Status: accepted
- Date: 2026-09-24
- Source spec: Jira SW-50 (`FEAT-hook-latency-budget`)
- Relates to: ADR 0011 (retired CL500 byte ratchet); `docs/architecture.md` ("Hook invocation
  latency")
- Supersedes: none

## Context

The shipped wiring (`templates/settings.template.json`) runs every PowerShell hook as a fresh
`powershell -NoProfile -ExecutionPolicy Bypass -File ...` process: Windows PowerShell 5.1, not
pwsh. `spec-gate` fires on every `Edit|Write|MultiEdit` and grew from about 250 to about 800 lines
across 1.4.0-1.6.0. Nothing measured what that cost, and nothing in CI would notice if it doubled.
The configured timeouts are 5 s (`spec-gate`, `prompt-router`) and 3 s (`subagent-retro`). The
ticket's worry was that 5.1 cold start plus the script could approach them on a slow machine.

SW-50 AC-5: if p95 on PowerShell 5.1 exceeds roughly half the configured timeout, raise the
timeout or optimise the hot path, and record the decision either way.

## Evidence

Measured with `tests/hooks/measure-latency.ps1`. The method and the full table are in
`docs/architecture.md`. The rows that decide AC-5:

| Hook | Timeout | Half | Worst 5.1 p95 (windows-latest, 2 runs) | Worst p95, any flavor or machine |
|---|---|---|---|---|
| `spec-gate` | 5 s | 2500 ms | 510 ms | 641 ms (pwsh, windows-latest) |
| `prompt-router` | 5 s | 2500 ms | 474 ms | 608 ms (pwsh, windows-latest) |
| `subagent-retro` | 3 s | 1500 ms | 534 ms | 650 ms (pwsh, windows-latest) |

One developer workstation measured earlier in SW-50 (commit 2/6, CHANGELOG) was much slower on
5.1: `spec-gate` p50 1217 ms. Its p95 was not recorded. Even allowing a generous tail on top of
that p50, it stays under the 2500 ms half-timeout. This is the only 5.1 number from outside CI,
and it is n=1.

Two findings changed what this ADR could claim:

1. **The first CI numbers were not trusted as-is.** On windows-latest, 5.1 came out about 20%
   faster than pwsh, the reverse of the workstation. Hooks exit 0 on every failure path and the
   script discarded their output, so a hook dying early under 5.1 would have looked exactly like
   this. Commit 5/6 made every timed run match its fixture's `expected.json` outcome before it
   counts. The numbers above are from runs that passed that check.
2. **pwsh is not a universal speedup.** Which flavor starts faster depends on the machine. The
   `_pwsh_recommended` note in the settings template (commit 3/6) said 5.1 is "measurably slower"
   as a general fact. It now says to measure first.

## Decision

1. **Keep every timeout as it is.** The worst measured p95 is under half of every timeout, on
   every flavor and every runner, by at least 2.3x (`subagent-retro`: 650 ms against 1500 ms).
   Raising a timeout would only let a regressed hook hang longer before Claude Code gives up.
2. **Do not optimise the hot path in SW-50.** Commit 2/6 already moved `spec-gate`'s free early
   exits ahead of the config read. The measured effect was within noise, because process start-up
   dominates. The remaining cost is interpreter start-up, which no change inside the script can
   remove. The ticket's other idea, exiting before loading the script's functions when the path is
   obviously irrelevant, would save parse time on the common case. It is not worth the risk while
   p95 sits at under a quarter of the timeout.
3. **Make the half-timeout rule mechanical, not a promise.** `hookLatencyBudgets` in
   `specwright.manifest.json` holds a p95 budget per hook and flavor. `measure-latency.ps1
   -CheckBudget` refuses any budget above half that hook's `timeout` before it measures anything,
   and CI fails any run over budget. AC-5 is therefore re-checked on every push, not just once:
   a hook that drifts toward its timeout fails CI long before users feel it. The only way past the
   ceiling is to raise the timeout in the same commit and say why.
4. **Budgets carry headroom: about 2x the worst CI p95, rounded up to 100 ms.** The same runner
   type moved a p95 by 40% between two consecutive runs. ADR 0011 showed what a zero-headroom
   ratchet turns into: 8 fires, 8 reflex raises, 0 trims. A budget that noise can trip gets
   raised on reflex; a budget at 2x still fails a hook that doubles its cost.

## Alternatives considered

- **Wire pwsh by default.** Rejected. It adds a dependency the README does not promise
  ("PowerShell 5.1+"), and on windows-latest it was the slower flavor. It stays an opt-in, to be
  measured per machine.
- **Budget p50 as well as p95.** Not done. p95 is the number that meets the timeout. A p50 budget
  would add a second noisy threshold without catching anything p95 misses.
- **A budget per runner OS.** Not done. The budget is keyed by flavor only, and the slowest runner
  sets it. One number per pair keeps the manifest readable. The headroom already covers the
  cross-OS spread measured here (worst pwsh 641 ms on Windows, 575 ms on macOS).
- **Measure the bash twins in the same harness.** Not done. They sit an order of magnitude under
  the PowerShell ones (`spec-gate` p95 about 119 ms on a Linux container), and `measure-latency.ps1`
  exists to drive PowerShell flavors from one process.

## Known gaps

- **5.1 data from real user machines is thin.** CI shows one Windows image, and there is one
  workstation data point. The budget protects against regressions in the hooks; it cannot promise
  anything about a slow machine it never runs on.
- **The fixture workspaces are small.** A project with a large `.specs/index.md` or event log does
  more I/O per call than these cases. If that ever dominates start-up, it will show up as user
  reports, not as a CI failure.
- **`spec-gate` still parses the whole script on every call.** Decision 2 defers the early-exit
  split, it does not reject it. Revisit if a budget raise is ever proposed for `spec-gate`.

## Consequences

**Positive.** Hook cost is now visible and guarded. A change that slows a hook enough to matter
fails CI in the same push, with the hook, flavor and number named. The pwsh recommendation now
rests on a measurement, not an assumption.

**Negative.** CI takes about 3 more minutes on windows-latest, which measures both flavors, and
about 1 more on ubuntu and macOS. Shared-runner noise can still, rarely, push a p95 past a budget
set at 2x. When that happens the remedy is a re-run, not a raise. A second failure in a row is a
real regression.
