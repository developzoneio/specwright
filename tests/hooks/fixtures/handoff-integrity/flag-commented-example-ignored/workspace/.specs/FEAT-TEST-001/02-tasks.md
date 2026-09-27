<!--
### T09 - Example

- **Files**: src/util/strings.ts
- **Status**: open
-->
# Tasks - FEAT-TEST-001

### T01 - Add widget model

- **Files**: src/widgets/model.ts, tests/widgets/model.test.ts
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
- **Status**: done

### T02 - Add widget service

- **Files**: src/widgets/service.ts, tests/widgets/service.test.ts
- **Layer**: Application
- **Step type**: behavior
- **Test**: tests/widgets/service.test.ts
- **Acceptance**: the widget behaves as the spec says
- **Covers**: SC-1
- **Depends on**: T01
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
- **Depends on**: T02
- **Conflicts with**: none
- **Estimated complexity**: S
- **Reversibility**: trivial
- **Pattern refs**: none
- **Status**: open
