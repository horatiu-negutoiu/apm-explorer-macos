# APMX-14 release-gating tests

The release gate is deterministic and does not request Input Monitoring access.
Protected permission dialogs remain owner-assisted integration checks and are not
part of the automated suite.

## Run the complete gate

From the repository root:

```sh
Scripts/test-release.sh
```

This runs the portable `APMXCore` domain, invariant, persistence, fixture, and
privacy-regression tests first, followed by the macOS adapter, view-model, and UI
smoke tests through the shared Xcode scheme.
The gate then verifies that the tested app has the stable TCC identity
`ca.horatiu.apmx` from Team `87M55M486F`; an ad-hoc build fails the gate because
macOS cannot associate its Input Monitoring grant with the signed app.

For owner-assisted Input Monitoring checks, run
`Scripts/build-permission-test-app.sh`. It creates a signed app in the stable
`build/PermissionTestDerivedData` location. Remove any older APM Explorer row
from System Settings before adding this exact app; enabling a row tied to an
older Derived Data product can cause macOS to relaunch that older executable.

In Xcode, open `APMExplorer.xcodeproj` and use **Product > Test** with the
`APMExplorer` scheme for app and UI tests. Open `APMXCore/Package.swift` and use
**Product > Test** for the portable core release gate.

## Shared fixtures

`APMXCore/Tests/APMXCoreTests/Fixtures/requirements-examples.json` is a
platform-neutral JSON contract. It uses integer epoch milliseconds, integer
action counts, stable UUID strings, nullable close fields, and string enum
values so the same file can be consumed by the later Windows implementation.
The fixture includes the requirements example of APM 120. Version 2 removes the
retired rolling-activity metric fixture.

When extending the fixture, increment its top-level version only for a breaking
shape or semantic change. Additive examples do not require a version change.

## Privacy regression boundary

The automated privacy gate checks all three durable boundaries:

- encoded `ActivitySession` values contain only aggregate session fields;
- the SQLite database contains only metadata and aggregate session tables with
  an exact column allow-list;
- adapter-to-core signals contain only key-down, mouse-button-down, or scroll
  category; applicable phase; and transient timing
  needed for monotonic reduction—never key codes, text, coordinates, deltas,
  application/window identity, or clipboard content.

The representative database check writes and inspects a real row. Introducing a
new table or column fails until the privacy allow-list is deliberately reviewed.
