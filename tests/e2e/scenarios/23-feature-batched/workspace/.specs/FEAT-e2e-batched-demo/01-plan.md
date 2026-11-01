# Plan - FEAT-e2e-batched-demo

Seeded plan for tests/e2e scenario 23. Gate 2 already passed (status `in-progress`).

## Approach

Two pure Domain functions next to `completeTodo()` in `src/domain/todo.js`, then one read-only
query on `TodoService`. Each task carries its own test.

## Outline

| ID | Title | Files | Covers |
|---|---|---|---|
| T01 | Add reopenTodo to the todo model | src/domain/todo.js, tests/todo.test.js | SC-1, AC-1 |
| T02 | Add renameTodo to the todo model | src/domain/todo.js, tests/todo-rename.test.js | SC-2, AC-2 |
| T03 | Add countByStatus to TodoService | src/application/todo-service.js, tests/todo-service.test.js | SC-3, AC-3 |
