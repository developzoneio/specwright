---
id: FEAT-e2e-resume-mapped
type: feature
status: approved
jira: none
created: 2026-09-25
complexity: L # set by the fixture author on purpose so ESC-FEAT-02 has a trigger to fire on
linked_specs: []
---

# E2E resume-from-approved demo spec (impact map present)

## Why

Seeded fixture spec for tests/e2e/scenarios/10-resume-impact-mapped. Gate 1 has passed and the approving session ended
before any later phase ran. It exercises the `/sd:feature` state machine rows for an `approved`
spec with no `02-tasks.md` (SW-74). The `complexity` value is set by the fixture author on
purpose, not measured.

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

## Out of scope

- Any change to the domain or infrastructure layers.

## Constitution check

- Section 1.1 (dependency direction): both methods live in the Application layer and read only
  through the injected store.
