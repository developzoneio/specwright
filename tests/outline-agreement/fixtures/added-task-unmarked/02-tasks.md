# Tasks - FEAT-example

### T01 - Add the Feed value type

- **Files**: src/Feed.cs (new), tests/FeedTests.cs (new)
- **Acceptance**: `Feed` constructs from a valid source and rejects an empty one, asserted by
  tests/FeedTests.cs.
- **Covers**: SC-1
- **Depends on**: none
- **Pattern refs**: src/Odds.cs:12 - mirror the value-type validation shape.
- **Status**: done

### T02 - Wire the feed handler

- **Files**: src/FeedHandler.cs (new), tests/FeedHandlerTests.cs (new)
- **Acceptance**: the handler emits one event per item in the feed, asserted by
  tests/FeedHandlerTests.cs.
- **Covers**: SC-2, AC-1
- **Depends on**: T01
- **Pattern refs**: src/OddsHandler.cs:20 - mirror the consumption loop.
- **Status**: done

### T03 - Log a skipped feed item

- **Files**: src/FeedHandler.cs, tests/FeedHandlerTests.cs
- **Acceptance**: the handler logs one warning per skipped item, asserted by
  tests/FeedHandlerTests.cs.
- **Covers**: AC-2
- **Depends on**: T02
- **Status**: open
