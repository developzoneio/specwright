---
id: FEAT-e2e-closeout-quiet
type: feature
status: in-progress
jira: none
created: 2026-10-30
complexity: S # two one-method tasks seeded for tests/e2e scenario 18
linked_specs: []
---

# E2E quiet close-out demo spec

## Why

Seeded fixture spec for tests/e2e/scenarios/18-closeout-quiet. It is synthetic: every task is
already done, Phase 5 passed and Gate 3 was approved with no warnings and no follow-ups. The run
resumes at Phase 6 and must close out without asking the user anything.

## What

### SC-1: count all todos

- **Given** a `TodoService` holding two todos
- **When** a caller calls `countTodos()`
- **Then** it returns `2`

### SC-2: count completed todos

- **Given** a `TodoService` holding two todos, one completed
- **When** a caller calls `countDone()`
- **Then** it returns `1`

## Spawned specs

| Reserved ID | Type | Title | Owner |
|---|---|---|---|

## Success criteria

- [ ] AC-1: `TodoService.countTodos()` returns the number of todos in the store.
- [ ] AC-2: `TodoService.countDone()` returns the number of completed todos in the store.

## Constitution check

- Section 1.1 (dependency direction): both methods live in the Application layer and read only
  through the injected store.
