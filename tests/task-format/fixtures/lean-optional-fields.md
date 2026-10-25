### T01 - Migrate the orders table primary key

- **Files**: src/Orders/OrderRepository.cs, migrations/0042_orders_pk.sql (new)
- **Acceptance**: `OrderRepository` reads and writes against the new `OrderId` primary key,
  asserted by test/Orders/OrderRepositoryTests.cs.
- **Covers**: none
- **Depends on**: none
- **Estimated complexity**: L
- **Reversibility**: hard
- **Pattern refs**: migrations/0031_customers_pk.sql:1 - mirror the two-phase migration shape.
- **Status**: open

### T02 - Add a null check to the order total

- **Files**: src/Orders/OrderTotalCalculator.cs
- **Acceptance**: a null line item is skipped, not thrown, asserted by
  test/Orders/OrderTotalCalculatorTests.cs.
- **Covers**: none
- **Depends on**: none
- **Status**: open
