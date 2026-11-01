# Tasks - FEAT-TEST-001

### T01 - Add countByStatus to the todo model

- **Files**: src/domain/todo.js, tests/todo.test.js
- **Acceptance**: countByStatus() counts done and pending todos, asserted by tests/todo.test.js.
- **Covers**: SC-1
- **Depends on**: none
- **Status**: open

### T02 - Reject an unknown status in countByStatus

- **Files**: src/domain/todo.js, tests/todo-count.test.js (new)
- **Acceptance**: an unknown status throws, asserted by tests/todo-count.test.js.
- **Covers**: SC-2
- **Depends on**: T01
- **Status**: open
