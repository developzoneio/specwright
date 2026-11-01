---
id: FEAT-e2e-s-lane
type: feature
status: draft
jira: none
created: 2026-10-31
complexity: S # set by the fixture author on purpose so the S lane has a spec to run on
linked_specs: []
---

# E2E S-lane demo spec (count todos)

## Why

Seeded fixture spec for tests/e2e/scenarios/21-feature-s-lane. Phase 1 has written it and no gate
has been presented yet. It exercises the `/sd:feature` S lane (SW-94): bounded discovery, one
combined spec and outline approval, then Phase 3b and Phase 4 with no Phase 2 impact map.

## What

### SC-1: count all todos

- **Given** a `TodoService` holding two todos
- **When** a caller calls `countTodos()`
- **Then** it returns `2`

## Success criteria

- [ ] AC-1: `TodoService.countTodos()` returns the number of todos in the store.

## Out of scope

- Any change to the domain or infrastructure layers.

## Open questions

None.

## Constitution check

- Section 1.1 (dependency direction): the method lives in the Application layer and reads only
  through the injected store.
