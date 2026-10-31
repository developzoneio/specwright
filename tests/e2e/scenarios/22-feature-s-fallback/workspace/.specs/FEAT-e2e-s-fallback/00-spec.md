---
id: FEAT-e2e-s-fallback
type: feature
status: draft
jira: none
created: 2026-10-31
complexity: S # set by the fixture author on purpose: the request below spans three layers, so the S-lane outline must breach
linked_specs: []
---

# E2E S-lane fallback demo spec (due dates)

## Why

Seeded fixture spec for tests/e2e/scenarios/22-feature-s-fallback. Phase 1 has written it and no
gate has been presented yet. Its `complexity: S` estimate is wrong on purpose: the change needs the
domain, application and infrastructure layers, so the S-lane outline breaches the S limits and the
workflow must fall back to the full path on its own (SW-94).

## What

### SC-1: a todo carries a validated due date

- **Given** a new todo created with `dueDate: "2026-12-01"`
- **When** it is created
- **Then** the todo's `dueDate` is that date, and an unparseable date is rejected with a domain error

### SC-2: the store persists and filters by due date

- **Given** an `InMemoryStore` holding todos with and without due dates
- **When** a caller asks the store for todos due before a date
- **Then** only the todos with an earlier `dueDate` are returned

### SC-3: the service lists overdue todos

- **Given** a `TodoService` whose store holds one overdue and one future todo
- **When** a caller calls `listOverdue(now)`
- **Then** it returns only the overdue todo

## Success criteria

- [ ] AC-1: `Todo` accepts and validates an optional `dueDate` in the domain layer.
- [ ] AC-2: `InMemoryStore` persists `dueDate` and offers a due-before query.
- [ ] AC-3: `TodoService.listOverdue(now)` returns the overdue todos.

## Out of scope

- Reminders or notifications.

## Open questions

None.

## Constitution check

- Section 1.1 (dependency direction): validation lives in the domain, the query in the
  infrastructure store behind its interface, and the use case in the application layer.
