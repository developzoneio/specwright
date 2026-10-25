# Tasks - FEAT-BROKEN-017

### T01 - Add the rate-limit header middleware

- **Files**: src/infrastructure/rate-limit-header.ts (new)
- **Acceptance**: the middleware stamps `X-RateLimit-Remaining` from the per-endpoint limiter,
  asserted by tests/infrastructure/rate-limit-header.test.ts.
- **Covers**: AC-1
- **Depends on**: none
- **Status**: open
