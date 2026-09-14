# Tasks - PORT-CLEAN-004

### T01 - Port ValidateCart

- **Files**: src/checkout/cart-totals
- **Layer**: Domain
- **Step type**: behavior
- **Test**: tests/checkout/CartTotalsTests
- **Acceptance**: `ValidateCart` rejects an empty cart before any discount is computed. Licensed
  deviations: none
- **Covers**: AC-1
- **Depends on**: none
- **Conflicts with**: none
- **Estimated complexity**: S
- **Reversibility**: trivial
- **Pattern refs**: 04-artifacts/source/checkout/cart-totals:10-40 - mirror validation order and
  rejection message

### T02 - Port ApplyDiscount

- **Files**: src/checkout/cart-totals
- **Layer**: Domain
- **Step type**: behavior
- **Test**: tests/checkout/CartTotalsTests
- **Acceptance**: `ApplyDiscount` computes `discountAmount` using the donor's rounding rule.
  Licensed deviations: D01
- **Covers**: AC-2
- **Depends on**: T01
- **Conflicts with**: none
- **Estimated complexity**: S
- **Reversibility**: trivial
- **Pattern refs**: 04-artifacts/source/checkout/cart-totals:42-70 - mirror discount computation
  order; identifier renamed per D01
