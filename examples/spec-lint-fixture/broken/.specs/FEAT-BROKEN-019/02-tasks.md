# Tasks - FEAT-BROKEN-019

### T01 - Add the status code to the failure log line

- **Files**: src/infrastructure/webhook-log.ts
- **Acceptance**: a failed delivery logs the endpoint's status code, asserted by
  tests/webhook-log.test.ts.
- **Covers**: AC-1
- **Depends on**: none
- **Status**: open

### T02 - Drop the request body from the failure log line

- **Files**: src/infrastructure/webhook-log.ts
- **Acceptance**: the failure log line carries no request body.
- **Covers**: AC-2
- **Depends on**: T01
- **Status**: open
