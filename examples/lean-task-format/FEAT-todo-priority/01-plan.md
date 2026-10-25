# Plan - FEAT-todo-priority

Spec: `.specs/FEAT-todo-priority/00-spec.md` (status `approved`, `complexity: M`)
Impact: `.specs/FEAT-todo-priority/03-decisions.md`

## Approach

Add one optional string field to the todo entity: a validator plus its error class in Domain, a
defaulted destructuring parameter on `createTodo`, a forwarded positional parameter on
`TodoService.addTodo`, tests on both sides of the Domain/Application boundary, and a two-literal
example refresh in the constitution (AC-9). `src/infrastructure/store.js` and `src/demo.js` are
untouched; `completeTodo`'s spread already carries the field.

Declined: an options object on the service (Gate 1 decided positional); defaulting inside
`validatePriority` (breaks AC-3's mirror of the void-throwing `validateTitle`); defaulting in
Application (§1.2 keeps the vocabulary in Domain).

## Design decisions

### D1 - The default lives on `createTodo`, never inside `validatePriority`

`validatePriority` is void-throwing, matching `validateTitle` (AC-3). `createTodo` applies the
default as a destructuring parameter (`priority = DEFAULT_PRIORITY`), never `??`/`||` - both would
silently default `null` and break AC-2.

### D2 - The Application layer forwards, it does not default and does not validate

`TodoService.addTodo(title, priority)` passes `priority` straight into `createTodo`. After this,
`src/application/todo-service.js` carries no priority string literal.

### D3 - Vocabulary and default stay module-private in Domain

Two unexported constants in `src/domain/todo.js`, mirroring `MAX_TITLE_LENGTH`.

## Risks

- `??`/`||` used instead of a destructuring default, silently defaulting `null` and breaking AC-2
  - mitigation: D1 restated in T02's Acceptance; T03 asserts `null` throws.
- Defaulting or validating duplicated into Application, violating §1.2 - mitigation: D2, plus
  T04's Acceptance that the file carries no priority literal.
- AC-9 edits `.specs/constitution.md`, a protected path - mitigation: pre-authorized by the Gate 1
  exception in `00-spec.md`; `hooks.specGate.mode` is `warn` in this fixture.
- Existing tests edited to accommodate the new field, destroying the regression signal -
  mitigation: both test tasks are append-only; the 8 existing tests pass unedited.

Complexity: 6 tasks, 2 production layers (Domain, Application), 5 impact files, 0 open questions - under threshold.

## Outline

| Task | Title | Files | Covers |
|---|---|---|---|
| T01 | Add InvalidPriorityError and validatePriority to the Domain | `src/domain/todo.js` | AC-3 |
| T02 | Accept, default and validate priority in createTodo | `src/domain/todo.js` | SC-1, SC-2, SC-3, SC-5, AC-1, AC-2, AC-6 |
| T03 | Add Domain unit tests for the priority field | `tests/todo.test.js` | SC-1, SC-2, SC-3, SC-5, AC-1, AC-2, AC-3, AC-6, AC-7 |
| T04 | Forward the priority through TodoService.addTodo | `src/application/todo-service.js` | SC-1, SC-2, AC-4 |
| T05 | Add integration tests through TodoService | `tests/todo-service.test.js` | SC-1, SC-2, SC-3, SC-4, AC-4, AC-5, AC-7 |
| T06 | Refresh the two constitution example shapes | `.specs/constitution.md` | AC-8, AC-9 |
