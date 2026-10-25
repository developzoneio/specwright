# Decisions - FEAT-e2e-outline-split

<!-- Seeded by tests/e2e scenario 12: Phase 2 already ran before the session ended. -->

## Impact analysis (sd-code-explorer)

### Direct callers (1-hop)

- `src/demo.js:4` - module scope -> `TodoService` constructor (unchanged by this spec)
- `src/application/todo-service.js` - calls `createTodo` from `src/domain/todo.js` and the
  injected store from `src/infrastructure/store.js`
- `tests/todo-service.test.js:8` - `makeService` -> `TodoService` constructor (unchanged)

### Transitive callers (2-3 hop)

- None: `listDueBefore`, `setDueDate` and `listOverdue` are new, so nothing calls them yet.

### Test coverage scan

- Files in target scope that have direct test files: `src/application/todo-service.js` ->
  `tests/todo-service.test.js`; `src/domain/todo.js` -> `tests/todo.test.js`
- Files in target scope WITHOUT direct tests: `src/infrastructure/store.js`

### DI / config grep

- DI registrations referencing target: none (constructor injection only)
- Configuration keys referencing target: none

### Public API surface

- Public symbols in target scope: `createTodo` (domain), `InMemoryStore` (infrastructure),
  `class TodoService` (application)
- Consumers (external to target scope): `src/demo.js`, `tests/todo-service.test.js`,
  `tests/todo.test.js`

### Risk assessment

- High risk: none
- Medium risk: `src/domain/todo.js` - `createTodo` validation is shared by every caller
- Low risk: `src/infrastructure/store.js`, `src/application/todo-service.js` - additive methods

### Precedents & conventions

- Nearest similar implementations (1-3):
  - `src/application/todo-service.js` - `listTodos()` - read-only query that delegates to the
    injected store
  - `src/domain/todo.js` - `createTodo` - existing field validation and its error type
