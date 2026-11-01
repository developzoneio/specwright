# Tasks - FEAT-e2e-batched-demo

Spec: `.specs/FEAT-e2e-batched-demo/00-spec.md` | Plan: `.specs/FEAT-e2e-batched-demo/01-plan.md`

Test command: `npm test` (`commands.test` in `.claude/project-config.json`).

### T01 - Add reopenTodo to the todo model

- **Files**: src/domain/todo.js (new symbol), tests/todo.test.js
- **Acceptance**: `reopenTodo(completeTodo(todo)).done` is `false` and the input is unchanged,
  asserted by a new test in tests/todo.test.js.
- **Covers**: SC-1, AC-1
- **Depends on**: none
- **Pattern refs**: src/domain/todo.js:41 - mirror `completeTodo()`; tests/todo.test.js:23 - mirror test shape
- **Status**: open

### T02 - Add renameTodo to the todo model

- **Files**: src/domain/todo.js (new symbol), tests/todo-rename.test.js (new)
- **Acceptance**: `renameTodo(todo, 'New title').title` is `'New title'`, and
  `renameTodo(todo, '  ')` throws `InvalidTitleError`, asserted by tests/todo-rename.test.js.
- **Covers**: SC-2, AC-2
- **Depends on**: T01
- **Pattern refs**: src/domain/todo.js:41 - mirror `completeTodo()`; tests/todo.test.js:1 - mirror imports and test shape
- **Status**: open

### T03 - Add countByStatus to TodoService

- **Files**: src/application/todo-service.js (new symbol), tests/todo-service.test.js
- **Acceptance**: `countByStatus()` returns `{ done: 1, pending: 1 }` after two `addTodo` calls
  and one `completeTodo`, asserted by a new test in tests/todo-service.test.js.
- **Covers**: SC-3, AC-3
- **Depends on**: T02
- **Pattern refs**: src/application/todo-service.js:31 - mirror `listTodos()`; tests/todo-service.test.js:19 - mirror test shape
- **Status**: open
