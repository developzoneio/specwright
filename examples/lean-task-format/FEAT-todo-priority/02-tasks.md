# Tasks - FEAT-todo-priority

All paths are relative to `examples/fixture-project/`. Test command is `npm test`.

### T01 - Add InvalidPriorityError and validatePriority to the Domain

- **Files**: src/domain/todo.js (new symbol)
- **Acceptance**: `InvalidPriorityError` and `validatePriority` are added to Domain, mirroring
  `InvalidTitleError`/`validateTitle`; `validatePriority` throws for anything outside
  `low`/`medium`/`high`, including `undefined` (AC-3), asserted by tests/todo.test.js.
- **Covers**: AC-3
- **Depends on**: none
- **Pattern refs**: src/domain/todo.js:1-6 - mirror `InvalidTitleError`'s class shape;
  src/domain/todo.js:8 - mirror `MAX_TITLE_LENGTH` as the precedent for an unexported constant;
  src/domain/todo.js:10-17 - mirror `validateTitle`'s void-throwing contract.
- **Status**: open

### T02 - Accept, default and validate priority in createTodo

- **Files**: src/domain/todo.js
- **Acceptance**: `createTodo` accepts and returns `priority`, defaulting to `medium` only when
  the argument is absent or `undefined` (AC-1, AC-2), and validates the title before the priority
  (AC-6), asserted by tests/todo.test.js.
- **Covers**: SC-1, SC-2, SC-3, SC-5, AC-1, AC-2, AC-6
- **Depends on**: T01
- **Status**: open

### T03 - Add Domain unit tests for the priority field

- **Files**: tests/todo.test.js
- **Acceptance**: new tests in tests/todo.test.js cover SC-1, SC-2, SC-3, SC-5 and a direct
  `validatePriority` call (AC-3), existing four tests untouched; `npm test` passes (AC-7).
- **Covers**: SC-1, SC-2, SC-3, SC-5, AC-1, AC-2, AC-3, AC-6, AC-7
- **Depends on**: T02
- **Estimated complexity**: M
- **Status**: open

### T04 - Forward the priority through TodoService.addTodo

- **Files**: src/application/todo-service.js
- **Acceptance**: `addTodo` takes `priority` as a second positional argument and forwards it to
  `createTodo` with no default and no validation in Application (AC-4), asserted by
  tests/todo-service.test.js.
- **Covers**: SC-1, SC-2, AC-4
- **Depends on**: T02, T03
- **Status**: open

### T05 - Add integration tests through TodoService

- **Files**: tests/todo-service.test.js
- **Acceptance**: new tests cover the Domain/Application crossing for SC-1, SC-2 and SC-4, and the
  rejected-add path for SC-3 (AC-5, AC-7), appended without editing the four existing tests.
- **Covers**: SC-1, SC-2, SC-3, SC-4, AC-4, AC-5, AC-7
- **Depends on**: T04
- **Estimated complexity**: M
- **Status**: open

### T06 - Refresh the two constitution example shapes

- **Files**: .specs/constitution.md
- **Acceptance**: the two example todo shapes read `{ id, title, done, priority }` via an in-place
  literal replacement - `git diff -- .specs/constitution.md` shows exactly two changed lines
  (AC-9); `git status` shows exactly the five files this feature touches (AC-8).
- **Covers**: AC-8, AC-9
- **Depends on**: T01, T02, T03, T04, T05
- **Status**: open
