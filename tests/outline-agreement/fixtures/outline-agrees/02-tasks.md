# Tasks - FEAT-example

### T01 - Add the Feed value type

- **Files**: src/Feed.cs, tests/FeedTests.cs
- **Layer**: Domain
- **Step type**: foundation
- **Test**: tests/FeedTests.cs
- **Acceptance**: `Feed` constructs from a valid source and rejects an empty one.
- **Covers**: SC-1
- **Depends on**: none
- **Conflicts with**: none
- **Estimated complexity**: S
- **Reversibility**: trivial
- **Pattern refs**: src/Odds.cs:12 - mirror the value-type validation shape.
- **Status**: open

### T02 - Wire the feed handler

- **Files**: src/FeedHandler.cs, tests/FeedHandlerTests.cs
- **Layer**: Application
- **Step type**: behavior
- **Test**: tests/FeedHandlerTests.cs
- **Acceptance**: the handler emits one event per item in the feed.
- **Covers**: SC-2, AC-1
- **Depends on**: T01
- **Conflicts with**: none
- **Estimated complexity**: M
- **Reversibility**: moderate
- **Pattern refs**: src/OddsHandler.cs:20 - mirror the consumption loop.
- **Status**: open
