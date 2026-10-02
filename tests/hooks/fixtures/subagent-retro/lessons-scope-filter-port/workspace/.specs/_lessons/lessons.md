# Lessons

GENERATED FILE - do not edit by hand. Regenerate with
`scripts/aggregate-lessons.sh`; edits are lost on the next run.

Every rule below is written to be free of identifiers - no paths, file names,
line numbers, class or variable names - so this file can be shared outside the
organisation as-is. That contract is enforced by `scripts/validate-lessons.*`
and is the reason a lesson reads as a general rule rather than a bug report.

A trailing count is the number of retros a lesson was drawn from. Frequency
never raises severity.

## missed-context

- [missed-context] high/all: A self-test that plants a hardcoded value stops testing the moment reality moves; derive the value it plants.

## donor-drift

- [donor-drift] medium/port: Diff the donor file against the last-synced commit before porting, not just against local HEAD.

## sibling-repo-assumption

- [sibling-repo-assumption] high/feature: When mirroring a sibling repository, verify the local shared helper matches before copying an attribute.
