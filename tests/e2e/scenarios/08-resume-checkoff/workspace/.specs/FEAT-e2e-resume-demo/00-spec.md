---
id: FEAT-e2e-resume-demo
type: feature
status: in-progress
jira: none
created: 2026-09-25
complexity: S # two one-method tasks seeded for tests/e2e scenario 08
linked_specs: []
---

# E2E check-off resume demo spec

## Why

Seeded fixture spec for tests/e2e/scenarios/08-resume-checkoff. It exercises the `/sd:feature`
resume state machine against the check-off marker defined in `sd-atomic-task-format`: `T01` is
already checked off (`Status: done`, code and test landed, retro line written) and `T02` is open.
A correct resume executes `T02` only and never re-runs `T01`.

## What

### SC-1: count all todos

- **Given** a `TodoService` holding two todos
- **When** a caller calls `countTodos()`
- **Then** it returns `2`

### SC-2: count completed todos

- **Given** a `TodoService` holding two todos, one completed
- **When** a caller calls `countDone()`
- **Then** it returns `1`

## Success criteria

- [ ] AC-1: `TodoService.countTodos()` returns the number of todos in the store.
- [ ] AC-2: `TodoService.countDone()` returns the number of completed todos in the store.

## Constitution check

- Section 1.1 (dependency direction): both methods live in the Application layer and read only
  through the injected store.
