---
id: PORT-BROKEN-016
type: port
status: in-progress
jira: none
created: 2026-07-20
scope: pattern
source_repo: none
source_commit: none
source_license: proprietary
snapshot: contract+source
linked_specs: []
---

<!-- SEEDED: one violation per SL06x rule, isolated to its own task in 02-tasks.md so each finding
     is independently traceable:
       T01 Pattern refs "see donor validation logic" - not the snapshot-member-range shape - SL061
       T02 Pattern refs "src/checkout/cart-totals:10-40" - right shape, wrong prefix - SL062
       T03 Pattern refs "04-artifacts/source/checkout/unknown-member:10-40" - path absent from
           MANIFEST.md - SL063
       T04 Pattern refs "04-artifacts/source/checkout/cart-totals:100-120" - range outside the
           manifest's recorded 10-70 for that path - SL064
       T05 Acceptance has no "Licensed deviations:" line at all - SL065
       T06 Acceptance has "Licensed deviations: D99", not in the Deviation table below - SL066
     All other fields on every task are compliant so each finding stays isolated. -->

# Port cart-totals validation and discount rules to checkout (broken)

> **The donor is the specification. Every departure is a row in the deviation table, or it is a
> defect.** The three fidelity tables below (Path mapping, Member manifest, Deviation table) are
> defined and enforced by the **sd-port-fidelity** skill - read it before filling them.

## Why

This is the SW-49 `SL06x` fixture's `broken/` half - the matched pair to `PORT-CLEAN-004`. Same
donor scenario, same fidelity tables; only `02-tasks.md` differs, seeding exactly one `SL06x`
violation per task so `/sd:spec validate` reports all six and nothing else.

## Donor provenance

- **Donor**: none (pattern-scope fixture - see this fixture's README)
- **License**: proprietary - none
- **Snapshot mode**: contract+source
- **Snapshot root**: `04-artifacts/source/`
- **Manifest**: `04-artifacts/source/MANIFEST.md`
- **Frozen**: no - fixture only, never appended to `paths.protected`

## Behavioral contract

| Facet | Donor behavior (verbatim) |
|---|---|
| Route / entry point | n/a - library-style procedure, no entry route |
| Input shape | a cart with line items and a discount code |
| Output shape | a validated cart total |
| Status / result codes | n/a |
| Auth requirement | none |
| Side effects | none - pure computation |
| Error paths | empty cart; discount exceeds cart total |

## Behavioral invariants (non-obvious)

- INV-1: `ValidateCart` rejects an empty cart BEFORE `ApplyDiscount` runs, so a discount is never
  computed against zero items.

## Path mapping table

| Donor path | Host path | Kind | Reason |
|---|---|---|---|
| `checkout/cart-totals` | `src/checkout/cart-totals` | mirror | - |

## Member manifest

| Donor path | Member | Ordinal | Host path | Status | Deviation ID |
|---|---|---|---|---|---|
| `checkout/cart-totals` | `ValidateCart` | 1 | `src/checkout/cart-totals` | ported | - |
| `checkout/cart-totals` | `ApplyDiscount` | 2 | `src/checkout/cart-totals` | deviated | D01 |

## Deviation table

| ID | Donor form | Host form | Group | Citation |
|---|---|---|---|---|
| D01 | identifier `discount` | identifier `discountAmount` | 1 | `discount` (conflicts with an existing host symbol of the same name) |

## Spawned specs

None.

## Success criteria

- [ ] AC-1: Every host hunk in this port is either a structural mirror of its member-manifest row,
  or is covered by a deviation-table row whose citation satisfies its group and whose `Host form`
  accounts for the whole hunk. No `unjustified`, `missing`, `extra`, or `overreached` hunk remains
  (see sd-port-fidelity).
- [ ] AC-2: `discountAmount` matches the donor's rounding rule for `ApplyDiscount` (INV-1 area).

## Out of scope

Semantic equivalence testing of `ApplyDiscount`'s rounding beyond the AC-2 spot check.

## Open questions

None.

## Constitution check

- **§1.1 Layer rules**: n/a - fixture host has no declared layers.
- **Risk of violation**: none.
