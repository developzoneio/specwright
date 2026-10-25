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
