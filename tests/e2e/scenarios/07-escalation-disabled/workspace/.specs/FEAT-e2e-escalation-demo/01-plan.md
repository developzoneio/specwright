# Plan - FEAT-e2e-escalation-demo

Seeded plan for tests/e2e scenario 07. Gate 2 already passed (status `in-progress`).

## Approach

Add two read-only query methods to `TodoService`, each derived from `listTodos()`, each with its
own test in `tests/todo-service.test.js`.

## Model escalation

`T01` is hand-marked `Estimated complexity: L` (the `ESC-FEAT-04` condition) and `T02` is
hand-marked `Reversibility: hard` (the `ESC-FEAT-04b` condition). The scenario's project-config
sets `models.escalation.enabled` to `false`, so neither rule may fire and no `escalation:` line
may be written; both tasks run at the implementer's default.
