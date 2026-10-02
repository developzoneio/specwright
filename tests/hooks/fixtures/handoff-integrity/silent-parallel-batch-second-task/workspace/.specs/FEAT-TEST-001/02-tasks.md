# Tasks - FEAT-TEST-001

### T01 - Split widget model

- **Files**: src/widgets/model.ts
- **Layer**: Application
- **Step type**: behavior
- **Test**: tests/widgets/service.test.ts
- **Acceptance**: the widget behaves as the spec says
- **Covers**: SC-1
- **Depends on**: none
- **Conflicts with**: none
- **Estimated complexity**: S
- **Reversibility**: trivial
- **Pattern refs**: none
- **Status**: open

### T02 - Split widget service

- **Files**: src/widgets/service.ts
- **Layer**: Application
- **Step type**: behavior
- **Test**: tests/widgets/service.test.ts
- **Acceptance**: the widget behaves as the spec says
- **Covers**: SC-1
- **Depends on**: none
- **Conflicts with**: none
- **Estimated complexity**: S
- **Reversibility**: trivial
- **Pattern refs**: none
- **Status**: open

### T03 - Wire widget route

- **Files**: src/routes/widgets.ts
- **Layer**: Application
- **Step type**: behavior
- **Test**: tests/widgets/service.test.ts
- **Acceptance**: the widget behaves as the spec says
- **Covers**: SC-1
- **Depends on**: T01, T02
- **Conflicts with**: none
- **Estimated complexity**: S
- **Reversibility**: trivial
- **Pattern refs**: none
- **Status**: open
