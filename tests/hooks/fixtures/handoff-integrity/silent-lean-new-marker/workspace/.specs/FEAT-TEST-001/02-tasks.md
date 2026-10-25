# Tasks - FEAT-TEST-001

### T01 - Add widget model

- **Files**: src/widgets/model.ts, tests/widgets/model.test.ts
- **Acceptance**: the widget behaves as the spec says, asserted by tests/widgets/model.test.ts.
- **Covers**: SC-1
- **Depends on**: none
- **Status**: done

### T02 - Add widget service

- **Files**: src/widgets/service.ts (new), tests/widgets/service.test.ts
- **Acceptance**: the widget behaves as the spec says, asserted by tests/widgets/service.test.ts.
- **Covers**: SC-1
- **Depends on**: T01
- **Pattern refs**: src/widgets/model.ts:1 - mirror the module shape.
- **Status**: open

### T03 - Wire widget route

- **Files**: src/routes/widgets.ts
- **Acceptance**: the widget behaves as the spec says, asserted by tests/widgets/service.test.ts.
- **Covers**: SC-1
- **Depends on**: T02
- **Status**: open
