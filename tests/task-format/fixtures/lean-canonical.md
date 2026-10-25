### T01 - Add a widget factory

- **Files**: src/Widgets/WidgetFactory.cs (new)
- **Acceptance**: `WidgetFactory.Create()` returns a non-null `Widget`, asserted by
  test/Widgets/WidgetFactoryTests.cs.
- **Covers**: none
- **Depends on**: none
- **Pattern refs**: src/Gadgets/GadgetFactory.cs:12 - mirror the factory shape and DI registration.
- **Status**: open

### T02 - Register the widget factory in the container

- **Files**: src/Widgets/ContainerSetup.cs
- **Acceptance**: `WidgetFactory` resolves from the container, asserted by
  test/Widgets/ContainerSetupTests.cs.
- **Covers**: none
- **Depends on**: T01
- **Status**: open
