# Plan - FEAT-example

## Approach

Add the Feed value type first, then wire the handler that consumes it.

## Risks

- The handler may be wired before the feed is validated. Mitigation: T02 depends on T01.

## Outline

| Task | Title | Files | Covers |
|---|---|---|---|
| T01 | Add the Feed value type | `src/Feed.cs`, `tests/FeedTests.cs` | SC-1 |
| T02 | Wire the feed handler | `src/FeedHandler.cs`, `tests/FeedHandlerTests.cs` | SC-2, AC-1 |
