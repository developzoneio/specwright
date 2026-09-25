# Decisions - FEAT-e2e-resume-mapped

<!-- Seeded by tests/e2e scenario 10: Phase 2 already ran before the session ended. -->

## Impact analysis (sd-code-explorer)

### Direct callers (1-hop)

- `src/demo.js:4` - module scope -> `TodoService` constructor (unchanged by this spec)
- `tests/todo-service.test.js:8` - `makeService` -> `TodoService` constructor (unchanged)

### Transitive callers (2-3 hop)

- None: `countTodos()` and `countDone()` are new, so nothing calls them yet.

### Test coverage scan

- Files in target scope that have direct test files: `src/application/todo-service.js` ->
  `tests/todo-service.test.js`
- Files in target scope WITHOUT direct tests: none

### DI / config grep

- DI registrations referencing target: none (constructor injection only, `src/application/todo-service.js:13`)
- Configuration keys referencing target: none

### Public API surface

- Public symbols in target scope: `src/application/todo-service.js:10` `class TodoService`
- Consumers (external to target scope): `src/demo.js:1`, `tests/todo-service.test.js:3`

### Risk assessment

- High risk: none
- Medium risk: none
- Low risk: `src/application/todo-service.js` - additive read-only methods, well tested

### Precedents & conventions

- Nearest similar implementations (1-3):
  - `src/application/todo-service.js:31` - `listTodos()` - read-only query that delegates to the
    injected store; the closest precedent for two more read-only counts
