### T01 - Fix the discount rounding rule

- **Files**: src/Pricing/DiscountCalculator.cs
- **Acceptance**: a 10% discount on 10.005 rounds to 9.00, not 9.01, asserted by
  test/Pricing/DiscountCalculatorTests.cs.
- **Covers**: none
- **Depends on**: none
- **Status**: open
