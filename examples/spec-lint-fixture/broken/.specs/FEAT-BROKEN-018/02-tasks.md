# Tasks - FEAT-BROKEN-018

### T01 - Stamp the Retry-After header

- **Files**: src/infrastructure/rate-limit-header.ts
- **Acceptance**: a rate-limited response carries `Retry-After`, asserted by
  tests/infrastructure/rate-limit-header.test.ts.
- **Covers**: SC-1
- **Depends on**: none
- **Status**: done

### T02 - Assert the header end to end

- **Files**: tests/infrastructure/retry-after.test.ts, src/infrastructure/retry-after.ts
- **Acceptance**: the end-to-end test sees `Retry-After` on a rate-limited webhook response,
  asserted by tests/infrastructure/retry-after.test.ts.
- **Covers**: AC-1
- **Depends on**: T01
- **Status**: open
