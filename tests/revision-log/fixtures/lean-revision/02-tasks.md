# Tasks - FEAT-example

### T01 - Add the Feed value type

- **Files**: src/Feed.cs (new)
- **Acceptance**: `Feed` constructs from a valid source and rejects an empty one, asserted by
  tests/FeedTests.cs.
- **Covers**: SC-1
- **Depends on**: none
- **Pattern refs**: src/Odds.cs:12 - mirror the value-type validation shape.
- **Status**: open

### T02 - Wire the feed handler onto the stream

- **Files**: src/FeedHandler.cs
- **Acceptance**: handler consumes the feed stream and emits one event per streamed item,
  asserted by tests/FeedHandlerTests.cs.
- **Covers**: SC-2
- **Depends on**: T01
- **Estimated complexity**: M
- **Reversibility**: moderate
- **Revised-by**: R1
- **Status**: open
