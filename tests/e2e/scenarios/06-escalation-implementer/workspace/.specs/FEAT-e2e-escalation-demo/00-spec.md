---
id: FEAT-e2e-escalation-demo
type: feature
status: in-progress
jira: none
created: 2026-09-25
complexity: S # two one-method tasks seeded for tests/e2e scenario 06
linked_specs: []
---

# E2E implementer escalation demo spec

## Why

Seeded fixture spec for tests/e2e/scenarios/06-escalation-implementer. It exercises the
`/sd:feature` Phase 4 model escalation check (`sd-model-escalation` rules `ESC-FEAT-04` and
`ESC-FEAT-04b`): one task hand-marked at the trigger threshold and one below it. The task-level
estimates in `02-tasks.md` are set by the fixture author on purpose, not measured.

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
