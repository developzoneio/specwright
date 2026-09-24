# ADR 0005: `/sd:port` is a fidelity-first pipeline enforced by a justified-diff parity gate

- Status: accepted (shipped in 1.6.0)
- Date: 2026-09-24 (recorded retroactively by SW-56; decisions made 2026-08, SW-37..SW-41)
- Source spec: Jira SW-37 (`sd-port-fidelity`), SW-38 (`PORT` spec type), SW-39 (`port-extract`),
  SW-40 (parity adjudication), SW-41 (`/sd:port`)
- Relates to: ADR 0002 (Gate Complexity thresholds); `docs/architecture.md` ("Why port parity is a
  reviewer check, not a `/sd:verify` check")
- Supersedes: none

## Context

Porting a module from a donor codebase into a host is the one workflow where "the tests pass" says
almost nothing about correctness. An implementer asked to reproduce a donor's behavior drifts in
three ways that neither test-green nor contract compliance can see: logic drift, structural
mismatch, and silent simplification. Before SW-37 the only guard against all three was prose in a
prompt - an honour system.

The port epic (SW-37..SW-41) had to answer four questions: where port policy lives, what the
implementer is licensed to change, who adjudicates a deviation, and how the pipeline stays
stack-agnostic when "a member" and "a file" mean different things in every host language.

## Decision

1. **Structural mirror is the default posture, and port policy stays in Layer 2.** The engine ships
   the mechanism (`skills/sd-port-fidelity/SKILL.md`), never a hardcoded posture. `/sd:port`
   Phase 0 reads a `Port policy` heading from the host's `.specs/constitution.md` and always prints
   the effective policy, including the structural-mirror fallback when the host declares nothing.

2. **A closed deviation allowlist, with a citation per group.** A host may deviate from the donor
   only for compiler/namespace/assembly reasons, a host constitution rule, a host precedent, or an
   agreed behavior-parity fix, and each deviation must cite its source. Anything not on the
   spec's licensed-deviation list is reproduced as-is.

3. **One skill, two consumers.** The fidelity rules became a skill rather than agent prose because
   `sd-spec-architect` (authoring the deviation table and task blocks) and `sd-reviewer` (judging a
   diff hunk) need the identical rule body. Fidelity findings anchor to the port spec's mandatory
   fidelity acceptance criterion, which is already a legal code anchor, so
   `sd-severity-taxonomy`'s Anchors table stays untouched. The template's fixed AC-1 is reworded as
   the vocabulary grows but is never renumbered, because every fidelity finding anchors to it.

4. **The anti-drift mechanism lives in the task block, not only at the gate.** Every port task's
   `Pattern refs` cites a snapshot member range (`04-artifacts/source/<path>:<first>-<last>`) -
   never prose, never a host sibling - and `Acceptance` carries the licensed-deviation ID list. A
   defective block is a planning defect, refused before execution rather than caught at parity.

5. **Parity is adjudicated from a diff the adjudicator cannot write.** The main thread writes
   `04-artifacts/parity/` (one unified diff per non-`omit` path-mapping row, plus `INDEX.md`);
   `sd-reviewer` classifies every hunk. The reviewer gains no `Bash` and no write tool and stays in
   `contractLint.readOnlyAgents` (CL201): the reviewer that cannot produce the diff also cannot fix
   what the diff shows, and that is the whole structural guarantee.

6. **`overreached` is a first-class hunk class.** A deviation row covers the hunk, but the hunk
   changes more than the row's `Host form` states. That is where a rubber stamp hides, so it gets
   its own class rather than folding into `justified`. A `justified` hunk is a PASS and is
   deliberately not written up, so a real BLOCK cannot drown in a list of accepted diffs.

7. **The parity gate is HARD with exactly two resolutions** - revert the host toward the snapshot,
   or add a deviation row whose group and citation hold up and re-run. No override.

8. **Behavior pinning is scope-dependent and gate-verified.** `endpoint` gets a contract test suite
   runnable against donor and host; `module` gets characterization tests through an interface-typed
   construction seam, so re-pointing donor -> host changes one factory method and the assertion
   bodies stay byte-identical; `pattern` skips pinning (there is no donor instance) but the gate
   still proves the host production tree is unmodified with an empty `git diff` /
   `git status --porcelain`, not a good-faith claim. Because scope selects the pinning mechanism,
   `--scope` is always explicit: Phase 0 asks rather than infers.

9. **A port-specific complexity metric.** The decompose thresholds from ADR 0002 count impacted
   files and layers, which a port trips by construction (its file count equals the donor's). Phase 6
   counts deviation-table rows requiring adaptation instead - the quantity that actually scales with
   how much judgement the work needs.

10. **A fifth implementer mode, not a reuse.** `WORKFLOW_TYPE = port` exists because neither
    `feature` (new public API allowed freely) nor `refactor` (new public API forbidden, `INVARIANTS`
    required) is the right constraint set for reproducing a donor under a licensed-deviation list.

11. **Snapshot freezing reuses `paths.protected` as shipped.** Protected-path matching in both
    `spec-gate` implementations is exact-string, with no glob engine on either platform. Freezing
    enumerates every file under `04-artifacts/source/` plus `MANIFEST.md` as literal entries, so
    the snapshot needed zero hook changes (SW-38 deviated from its ticket's "adds a glob" wording on
    purpose).

12. **Lifecycle divergence on abort.** Unlike `/sd:feature` and `/sd:refactor`, `abort` never jumps
    a port spec to `archived`; it leaves the spec where it is so re-invoking resumes there. A
    partially frozen or partially pinned port has no clean "give up" shortcut.

13. **Explorer stays read-only.** `port-extract` on `sd-code-explorer` gets no write tool;
    `/sd:explore` itself computes `source_commit` (an explicit `dirty` sentence rather than a
    misleading sha), hashes and copies donor files, matching how `impact-map` output is appended by
    the caller, not the agent.

14. **Router keywords are multi-word phrases** (`backport`, `port from`, `donor repo`, ...). A bare
    `port` would fire on "support", "report" and "portal".

15. **The parity fixture is a demonstration, not a CI suite.** `examples/port-parity-fixture/` seeds
    one defect per BLOCK class. Seed markers live in the spec, not the ported files, because a
    comment inside a host file is itself an `extra` hunk. Members are separated by unchanged padding
    so each seed lands in its own hunk. It is not run in CI for the same reason
    `spec-lint-fixture` is not: the adjudicator is a prompt, and a script able to run it would be a
    second copy of the rules.

## Deliberately not built

- `--sync` / re-port drift detection, and multi-donor ports.
- Editing the host's build, lint or coverage configuration to exclude the snapshot. The command
  warns about tooling that globs `.specs/`; it never edits it.
- Semantic equivalence checking. That is the behavior-pinning phase's job, not the diff's.
- Auto-generating deviation rows from unexplained hunks. It would let the diff justify itself and
  turn the gate into a rubber stamp.
- A `VF0xx` rule in `/sd:verify` for member completeness or path conformance. The reasoning is in
  `docs/architecture.md`; it is not repeated here.

## Consequences

**Positive.** Fidelity is enforced by structure (tool allowlists, a gate with no override, a task
block contract) rather than by prose. The pipeline is stack-agnostic: the only language-aware step
is the reviewer's member-boundary judgement, which is exactly where judgement belongs.

**Negative.** Diff generation and the host side of the explore bridge are main-thread steps, so a
port costs more orchestration than a feature. Four HARD gates make a port slow by design.

**Known gaps at 1.6.0, and their status.**

- The port task-block contract (Pattern refs range + licensed-deviation list) was enforced only by
  Phase 6 refusing a defective block, not by `/sd:spec validate`. Closed by SW-49 (`SL061`-`SL066`).
- `spec-gate`, `subagent-retro` and `prompt-router` hardcoded the spec-prefix alternation, so a
  `PORT-` spec was invisible to enforcement. Closed by SW-44 (prefixes read from `spec.prefixes`).
