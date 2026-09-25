# Tasks - FEAT-e2e-escalation-demo

Spec: `.specs/FEAT-e2e-escalation-demo/00-spec.md` | Plan: `.specs/FEAT-e2e-escalation-demo/01-plan.md`

Test command: `npm test` (`commands.test` in `.claude/project-config.json`).

### T01 - Add countTodos to TodoService

- **Files**: src/application/todo-service.js, tests/todo-service.test.js
- **Layer**: Application
- **Step type**: behavior
- **Test**: tests/todo-service.test.js
- **Acceptance**: `countTodos()` returns `2` after two `addTodo` calls; a new test asserts it and
  `npm test` passes.
- **Covers**: SC-1, AC-1
- **Depends on**: none
- **Conflicts with**: T02
- **Estimated complexity**: L
- **Reversibility**: trivial
- **Pattern refs**: src/application/todo-service.js:31 - mirror `listTodos()`; tests/todo-service.test.js:11 - mirror test shape

### T02 - Add countDone to TodoService

- **Files**: src/application/todo-service.js, tests/todo-service.test.js
- **Layer**: Application
- **Step type**: behavior
- **Test**: tests/todo-service.test.js
- **Acceptance**: `countDone()` returns `1` after two `addTodo` calls and one `completeTodo`; a new
  test asserts it and `npm test` passes.
- **Covers**: SC-2, AC-2
- **Depends on**: T01
- **Conflicts with**: T01
- **Estimated complexity**: S
- **Reversibility**: hard
- **Pattern refs**: src/application/todo-service.js:31 - mirror `listTodos()`; tests/todo-service.test.js:19 - mirror test shape
