# Plan - PORT-CLEAN-004

## Phased overview

- Foundation: T01 (port `ValidateCart`, no deviation)
- Behavior: T02 (port `ApplyDiscount`, D01 rename)

## Sequencing rationale

T01 lands the ported validation member first since `ApplyDiscount` (T02) depends on a cart that has
already passed validation. Critical path is T01 -> T02.

## Risks

- None beyond the fixture's own scope - this spec never executes; it exists to exercise
  `/sd:spec validate`'s `SL061`-`SL066` band.
