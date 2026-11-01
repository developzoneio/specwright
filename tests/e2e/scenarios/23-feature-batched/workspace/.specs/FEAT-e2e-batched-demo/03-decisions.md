# Decisions - FEAT-e2e-batched-demo

## Impact map

- `src/domain/todo.js` - gains two pure functions; no caller changes.
- `src/application/todo-service.js` - gains one read-only method; no caller changes.
- `tests/todo.test.js`, `tests/todo-rename.test.js` (new), `tests/todo-service.test.js` - one test each.

## Precedents & conventions

- Domain transitions return a new object (`completeTodo()`, src/domain/todo.js:41).
- Query methods delegate to the injected store (`listTodos()`, src/application/todo-service.js:31).
