---
id: FEAT-e2e-outline-split
type: feature
status: approved
jira: none
created: 2026-10-25
complexity: M # set by the fixture author on purpose so no model escalation rule fires
linked_specs: []
---

# E2E outline-first decompose demo spec

## Why

Seeded fixture spec for tests/e2e/scenarios/12-resume-outline-complexity (SW-92). Users need to
see which todos are overdue. The change crosses every production layer of the fixture, and one
product question is still open, so Gate 2 must show its complexity face. The scenario proves that
face is decided from the Phase 3a outline, before any full task block exists.

## What

### SC-1: a todo carries an optional due date

- **Given** a caller creating a todo with `dueDate` set to an ISO date string
- **When** the domain factory `createTodo` in `src/domain/todo.js` validates it
- **Then** the todo keeps `dueDate`, and an unparseable value throws `InvalidDueDateError`

### SC-2: the store answers a due-before query

- **Given** an `InMemoryStore` (`src/infrastructure/store.js`) holding todos with and without
  due dates
- **When** a caller calls `listDueBefore(date)`
- **Then** it returns only the todos whose `dueDate` is before `date`, oldest first

### SC-3: the service sets due dates and lists overdue todos

- **Given** a `TodoService` (`src/application/todo-service.js`)
- **When** a caller calls `setDueDate(id, date)` and then `listOverdue(now)`
- **Then** `listOverdue` returns the overdue todos, through the store query

## Success criteria

- [ ] AC-1: `createTodo` accepts and validates `dueDate` (domain layer).
- [ ] AC-2: `InMemoryStore.listDueBefore(date)` exists and is tested (infrastructure layer).
- [ ] AC-3: `TodoService.setDueDate` and `TodoService.listOverdue` exist and are tested
  (application layer).

## Out of scope

- Time zones, recurring due dates, reminders.

## Open questions

- Unresolved: should `listOverdue` include todos that are already done? The product owner has not
  decided; the answer changes the store query and the service contract. Left open on purpose by
  the fixture author - it is the user's call, not the architect's.

## Constitution check

- Section 1.1 (dependency direction): domain knows nothing of the store; the service reads only
  through the injected store.
