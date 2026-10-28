# Plan - FEAT-BROKEN-018

## Approach

Stamp `Retry-After` in the existing rate-limit middleware, then assert it end to end.

## Risks

- None beyond the usual header-ordering concern.

Complexity: 2 tasks, 1 production layer (Infrastructure), 1 impact file, 0 open questions - under threshold.

## Outline

| Task | Title | Files | Covers |
|---|---|---|---|
| T01 | Stamp the Retry-After header | `src/infrastructure/rate-limit-header.ts` | SC-1 |
| T02 | Assert the header end to end | `tests/infrastructure/retry-after.test.ts` | AC-1 |
