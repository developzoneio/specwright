# installer prefix parity

Parity suite for the `--prefix` / `-Prefix` guard in all four installer scripts (SW-53).

```powershell
.\tests\installer\run-prefix-parity.ps1            # the suite
.\tests\installer\run-prefix-parity.ps1 -SelfTest  # plus: does the harness notice a regression?
```

`prefix-cases.json` is the single source of truth: each case names a prefix and whether it must be
accepted or rejected. The runner feeds every case to `install.sh`, `uninstall.sh`, `install.ps1` and
`uninstall.ps1` in dry-run mode against a never-created base path, and a case passes only when all
four agree with `expect` and nothing was written to disk. Install and uninstall must accept the same
prefix set on both platforms, or a prefix legal on one side leaves orphaned or unreachable files.

| Outcome | Means |
|---|---|
| `accept` | exit 0 |
| `reject` | exit 1 and `Invalid prefix` in the output |
| `error` | anything else - the harness cannot classify it, so the case fails |

`-SelfTest` runs the real sweep first (it must pass), then swaps in a copy of `install.sh` carrying
the pre-SW-53 spaces-only guard (`${PREFIX// /}`) and asserts the tab-only case is reported as a
divergence.

To add a case, append an entry to `prefix-cases.json`. Write control characters as JSON escapes
(`\t`, `\n`, `\r`) so the file stays pure ASCII. Unicode whitespace is deliberately absent: bash
`[[:space:]]` is locale-dependent for it, so such a case would be flaky rather than informative.

Like the other harnesses there is no `.sh` twin: one pwsh process drives both implementations, and
CI runs it on every matrix OS.
