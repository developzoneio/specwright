# Tasks - FEAT-TEST-001

### T01 - Add countByStatus to the todo model

- **Files**: src/domain/todo.js, tests/todo.test.js
- **Acceptance**: countByStatus() counts done and pending todos, asserted by tests/todo.test.js.
- **Covers**: SC-1
- **Depends on**: none
- **Status**: open

### T02 - Migrate stored todos to the new status field

- **Files**: src/domain/todo.js, tests/todo-count.test.js (new)
- **Acceptance**: stored todos carry a status field, asserted by tests/todo-count.test.js.
- **Covers**: SC-2
- **Depends on**: T01
- **Reversibility**: hard
- **Status**: open

### T03 - Expose countByStatus on TodoService

- **Files**: tests/todo-count.test.js, src/application/todo-service.js
- **Acceptance**: TodoService.countByStatus() delegates to the model, asserted by tests/todo-count.test.js.
- **Covers**: SC-3
- **Depends on**: T02
- **Status**: open
