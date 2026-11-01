# Tasks - FEAT-TEST-001

### T01 - Add countByStatus to the todo model

- **Files**: src/domain/todo.js, tests/todo.test.js
- **Acceptance**: countByStatus() counts done and pending todos, asserted by tests/todo.test.js.
- **Covers**: SC-1
- **Depends on**: none
- **Status**: open

### T02 - Expose countByStatus on TodoService

- **Files**: src/application/todo-service.js, tests/todo-service.test.js
- **Acceptance**: TodoService.countByStatus() delegates to the model, asserted by tests/todo-service.test.js.
- **Covers**: SC-2
- **Depends on**: T01
- **Status**: open
