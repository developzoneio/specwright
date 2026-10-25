# Tasks - FEAT-e2e-escalation-demo

Spec: `.specs/FEAT-e2e-escalation-demo/00-spec.md` | Plan: `.specs/FEAT-e2e-escalation-demo/01-plan.md`

Test command: `npm test` (`commands.test` in `.claude/project-config.json`).

### T01 - Add countTodos to TodoService

- **Files**: src/application/todo-service.js (new symbol), tests/todo-service.test.js
- **Acceptance**: `countTodos()` returns `2` after two `addTodo` calls, asserted by a new test in
  tests/todo-service.test.js.
- **Covers**: SC-1, AC-1
- **Depends on**: none
- **Estimated complexity**: L
- **Pattern refs**: src/application/todo-service.js:31 - mirror `listTodos()`; tests/todo-service.test.js:11 - mirror test shape
- **Status**: open

### T02 - Add countDone to TodoService

- **Files**: src/application/todo-service.js (new symbol), tests/todo-service.test.js
- **Acceptance**: `countDone()` returns `1` after two `addTodo` calls and one `completeTodo`,
  asserted by a new test in tests/todo-service.test.js.
- **Covers**: SC-2, AC-2
- **Depends on**: T01
- **Pattern refs**: src/application/todo-service.js:31 - mirror `listTodos()`; tests/todo-service.test.js:19 - mirror test shape
- **Status**: open
