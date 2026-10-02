# Decisions - FEAT-e2e-resume-demo

## Impact map

- `src/application/todo-service.js` - gains two read-only methods; no caller changes.
- `tests/todo-service.test.js` - gains two tests.

## Precedents & conventions

- Query methods delegate to the injected store (`listTodos()`, src/application/todo-service.js:31).
