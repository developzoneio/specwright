# Tasks - PORT-BROKEN-016

### T01 - Port ValidateCart (SL061 seed)

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
- **Pattern refs**: see donor validation logic

### T02 - Port ApplyDiscount, wrong-prefix citation (SL062 seed)

- **Files**: src/checkout/cart-totals
- **Layer**: Domain
- **Step type**: behavior
- **Test**: tests/checkout/CartTotalsTests
- **Acceptance**: `ApplyDiscount` computes `discountAmount` using the donor's rounding rule.
  Licensed deviations: D01
- **Covers**: AC-2
- **Depends on**: none
- **Conflicts with**: none
- **Estimated complexity**: S
- **Reversibility**: trivial
- **Pattern refs**: src/checkout/cart-totals:10-40 - mirror discount computation order

### T03 - Port ApplyDiscount, unknown snapshot path (SL063 seed)

- **Files**: src/checkout/cart-totals
- **Layer**: Domain
- **Step type**: behavior
- **Test**: tests/checkout/CartTotalsTests
- **Acceptance**: `ApplyDiscount` computes `discountAmount` using the donor's rounding rule.
  Licensed deviations: D01
- **Covers**: AC-2
- **Depends on**: none
- **Conflicts with**: none
- **Estimated complexity**: S
- **Reversibility**: trivial
- **Pattern refs**: 04-artifacts/source/checkout/unknown-member:10-40 - mirror discount computation
  order

### T04 - Port ApplyDiscount, out-of-range citation (SL064 seed)

- **Files**: src/checkout/cart-totals
- **Layer**: Domain
- **Step type**: behavior
- **Test**: tests/checkout/CartTotalsTests
- **Acceptance**: `ApplyDiscount` computes `discountAmount` using the donor's rounding rule.
  Licensed deviations: D01
- **Covers**: AC-2
- **Depends on**: none
- **Conflicts with**: none
- **Estimated complexity**: S
- **Reversibility**: trivial
- **Pattern refs**: 04-artifacts/source/checkout/cart-totals:100-120 - mirror discount computation
  order

### T05 - Port ApplyDiscount, no licensed-deviation list (SL065 seed)

- **Files**: src/checkout/cart-totals
- **Layer**: Domain
- **Step type**: behavior
- **Test**: tests/checkout/CartTotalsTests
- **Acceptance**: `ApplyDiscount` computes `discountAmount` using the donor's rounding rule.
- **Covers**: AC-2
- **Depends on**: none
- **Conflicts with**: none
- **Estimated complexity**: S
- **Reversibility**: trivial
- **Pattern refs**: 04-artifacts/source/checkout/cart-totals:42-70 - mirror discount computation
  order; identifier renamed per D01

### T06 - Port ApplyDiscount, uncited deviation ID (SL066 seed)

- **Files**: src/checkout/cart-totals
- **Layer**: Domain
- **Step type**: behavior
- **Test**: tests/checkout/CartTotalsTests
- **Acceptance**: `ApplyDiscount` computes `discountAmount` using the donor's rounding rule.
  Licensed deviations: D99
- **Covers**: AC-2
- **Depends on**: none
- **Conflicts with**: none
- **Estimated complexity**: S
- **Reversibility**: trivial
- **Pattern refs**: 04-artifacts/source/checkout/cart-totals:42-70 - mirror discount computation
  order; identifier renamed per D01
