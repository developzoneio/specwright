---
id: PORT-CLEAN-004
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

# Port cart-totals validation and discount rules to checkout

> **The donor is the specification. Every departure is a row in the deviation table, or it is a
> defect.** The three fidelity tables below (Path mapping, Member manifest, Deviation table) are
> defined and enforced by the **sd-port-fidelity** skill - read it before filling them.

## Why

This is the SW-49 `SL06x` fixture's `clean/` half: a port spec whose task blocks fully satisfy the
port task-block contract (`Pattern refs` citing an in-range snapshot member, `Acceptance` carrying
a correct `Licensed deviations:` line), so `/sd:spec validate` must return `_No findings._` for
`SL061`-`SL066`. `scope: pattern` and `source_repo`/`source_commit: none` because there is no real
donor repository behind this fixture - same convention `PORT-order-intake-20260809` uses in
`examples/port-parity-fixture/`.

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
