# Plan - FEAT-e2e-uncovered

<!-- Seeded by tests/e2e scenario 25: Phase 3a already ran. The outline leaves the
completed-count criterion with no task, on purpose (SW-90). -->

## Approach

Add two read-only counting methods to `TodoService`, each delegating to the injected store as
`listTodos()` does. Alternative considered: a single `count(filter)` method - rejected, the spec
names two methods.

## Risks

- A count that reads a stale snapshot of the store. Mitigation: read through `listTodos()`.

Complexity: M - 2 tasks, 1 production layer (Application), impact surface 2 files.

## Outline

| Task | Title | Files | Covers |
|---|---|---|---|
| T01 | Count all todos | src/application/todo-service.js, tests/todo-service.test.js | SC-1, AC-1 |
| T02 | Count completed todos | src/application/todo-service.js, tests/todo-service.test.js | SC-2 |
