### T01 - Add countOverdue to TodoService

- **Files**: src/application/todo-service.js
- **Layer**: Application
- **Step type**: behavior
- **Test**: tests/todo-service.test.js
- **Acceptance**: `countOverdue()` returns the count of todos whose due date is past.
- **Covers**: AC-1
- **Depends on**: none
- **Conflicts with**: none
- **Estimated complexity**: S
- **Reversibility**: trivial
- **Pattern refs**: src/application/todo-service.js:20-30 - mirror the existing counter
- **Status**: open
