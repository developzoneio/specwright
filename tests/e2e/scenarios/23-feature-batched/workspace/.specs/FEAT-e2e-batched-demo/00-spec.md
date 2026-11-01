---
id: FEAT-e2e-batched-demo
type: feature
status: in-progress
jira: none
created: 2026-11-01
complexity: M # three tasks seeded for tests/e2e scenario 23
linked_specs: []
---

# E2E batched implementer demo spec

## Why

Seeded fixture spec for tests/e2e/scenarios/23-feature-batched (SW-95). `T01` and `T02` both
edit `src/domain/todo.js`, and `T02` depends on `T01`, so `/sd:feature` Phase 4 runs them as one
group with one `sd-implementer` call. `T03` shares no file with them and runs as its own group.

## What

### SC-1: reopen a todo

- **Given** a completed todo
- **When** a caller calls `reopenTodo(todo)`
- **Then** it returns a new todo with `done: false`, and the original is unchanged

### SC-2: rename a todo

- **Given** a todo
- **When** a caller calls `renameTodo(todo, title)`
- **Then** it returns a new todo with that title, and an invalid title throws `InvalidTitleError`

### SC-3: count todos by status

- **Given** a `TodoService` holding two todos, one completed
- **When** a caller calls `countByStatus()`
- **Then** it returns `{ done: 1, pending: 1 }`

## Success criteria

- [ ] AC-1: `reopenTodo(todo)` returns a new todo with `done: false`.
- [ ] AC-2: `renameTodo(todo, title)` validates the title and returns a new todo.
- [ ] AC-3: `TodoService.countByStatus()` returns the done and pending counts.

## Constitution check

- Section 1.1 (dependency direction): `reopenTodo` and `renameTodo` are pure Domain functions;
  `countByStatus` lives in the Application layer and reads only through the injected store.
