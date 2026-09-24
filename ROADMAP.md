# Roadmap

Planned and exploratory work for specwright. Shipped items live in [`CHANGELOG.md`](CHANGELOG.md);
this file is forward-looking only and intentionally non-binding - priorities shift as the engine is
dogfooded on real projects.

Current released version: **1.6.0** (see the [changelog](CHANGELOG.md) for what shipped).

## Near-term

Small, well-scoped items targeted at the next minor release.

- **GitHub Issue auto-fetch (`gh issue view`)** - extend the JIRA-only ticket snapshot path so a
  GitHub Issue `<ID>` argument is fetched and snapshotted into `04-artifacts/ticket/` the same way
  JIRA tickets are. Mirrors the existing case in `sd-spec-architect`; GitHub and Linear are already
  recognized as trackers, but their ticket content is not yet auto-fetched (it has to be pasted in).

## Planned

Larger items that each warrant a full `/sd:feature` spec before building.

_Nothing new proposed right now. Substantial work is already specced and built, queued for the
next version cut - see the `[Unreleased]` section of [`CHANGELOG.md`](CHANGELOG.md) for what
that is._

## Exploratory

Ideas under consideration; no committed timeline.

- **Local-only usage analytics** - opt-in, telemetry-free counters (kept on disk, never transmitted)
  to surface which workflows and gates get used most.

## Non-goals

specwright stays a generic, stack-agnostic engine. Project-specific commands, hardcoded stack
commands (`dotnet test`, `npm test`), and anything that couples the engine to one language or
framework are explicit non-goals - all project specifics are read at runtime from `CLAUDE.md`,
`constitution.md`, and `project-config.json`. See [`docs/architecture.md`](docs/architecture.md).

---

Have a request or want to pick something up? Open an issue or see [`CONTRIBUTING.md`](CONTRIBUTING.md).
