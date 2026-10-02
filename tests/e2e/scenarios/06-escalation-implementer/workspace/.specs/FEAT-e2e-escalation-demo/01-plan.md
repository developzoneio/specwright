# Plan - FEAT-e2e-escalation-demo

Seeded plan for tests/e2e scenario 06. Gate 2 already passed (status `in-progress`).

## Approach

Add two read-only query methods to `TodoService`, each derived from `listTodos()`, each with its
own test in `tests/todo-service.test.js`.

## Model escalation

`T01` is hand-marked `Estimated complexity: L` so `ESC-FEAT-04` fires for it; `T02` is `S` /
`trivial` so neither `ESC-FEAT-04` nor `ESC-FEAT-04b` fires. The scenario's project-config sets
`models.escalation.ceiling` to `sonnet`, which must not cap a `haiku -> sonnet` escalation.
