# Plan - FEAT-BROKEN-017

## Approach

Add a response middleware that stamps `X-RateLimit-Remaining` on every webhook response.

## Risks

- None beyond the usual header-ordering concern.

Complexity: 1 task, 1 production layer (Infrastructure), 1 impact file, 0 open questions - under threshold.

## Outline

| Task | Title | Files | Covers |
|---|---|---|---|
| T01 | Add the rate-limit header middleware | `src/infrastructure/rate-limit-header.ts` | AC-1 |
