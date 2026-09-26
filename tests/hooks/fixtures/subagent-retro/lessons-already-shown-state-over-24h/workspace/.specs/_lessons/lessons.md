# Lessons

GENERATED FILE - do not edit by hand. Regenerate with
`scripts/aggregate-lessons.sh`; edits are lost on the next run.

Every rule below is written to be free of identifiers - no paths, file names,
line numbers, class or variable names - so this file can be shared outside the
organisation as-is. That contract is enforced by `scripts/validate-lessons.*`
and is the reason a lesson reads as a general rule rather than a bug report.

A trailing count is the number of retros a lesson was drawn from. Frequency
never raises severity.

## sibling-repo-assumption

- [sibling-repo-assumption] high/feature: When mirroring a sibling repository, verify the local shared helper matches before copying an attribute.

## missed-context

- [missed-context] high/all: A self-test that plants a hardcoded value stops testing the moment reality moves; derive the value it plants.
- [missed-context] high/feature: Re-run impact analysis after any spec refinement, since a refined scope invalidates the earlier map.

## baseline-attribution

- [baseline-attribution] low/all: Confirm pre-existing failures against a clean baseline before attributing or dismissing them. (2)

## tooling-surprise

- [tooling-surprise] low/all: Check the working tree state after any command that stashes or regenerates project metadata.

## gate-friction

- [gate-friction] medium/refactor: When waiving a coverage gate, record measured coverage, residual risk, and what would satisfy it later.

## test-gap

- [test-gap] medium/feature: Create the missing test project before the first task rather than midway, even under PowerShell tooling.
