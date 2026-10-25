# Tasks - FEAT-CLEAN-005

### T01 - Add the rate-limit header middleware

- **Files**: src/infrastructure/rate-limit-header.ts (new)
- **Acceptance**: the middleware stamps `X-RateLimit-Remaining` from the per-endpoint limiter,
  asserted by tests/infrastructure/rate-limit-header.test.ts.
- **Covers**: AC-1
- **Depends on**: none
- **Pattern refs**: src/infrastructure/request-id-header.ts:1 - mirror this middleware's shape and
  registration.
- **Status**: open

### T02 - Register the middleware on the webhook route

- **Files**: src/infrastructure/webhook-routes.ts
- **Acceptance**: the webhook route runs the rate-limit header middleware before responding,
  asserted by tests/infrastructure/webhook-routes.test.ts.
- **Covers**: AC-1
- **Depends on**: T01
- **Status**: open
