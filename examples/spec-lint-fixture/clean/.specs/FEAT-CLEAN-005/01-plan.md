# Plan - FEAT-CLEAN-005

## Approach

Add a response middleware that stamps `X-RateLimit-Remaining` on every webhook response, backed
by the existing per-endpoint limiter.

## Risks

- None beyond the usual header-ordering concern, already covered by the limiter's own tests.

Complexity: 2 tasks, 1 production layer (Infrastructure), 1 impact file, 0 open questions - under threshold.

## Outline

| Task | Title | Files | Covers |
|---|---|---|---|
| T01 | Add the rate-limit header middleware | `src/infrastructure/rate-limit-header.ts` | AC-1 |
| T02 | Register the middleware on the webhook route | `src/infrastructure/webhook-routes.ts` | AC-1 |
