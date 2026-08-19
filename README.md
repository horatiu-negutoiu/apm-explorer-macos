# APM Explorer for macOS

APM Explorer is a native Swift 6 menu bar application for macOS 13 and later.
It has no Dock or app-switcher presence. Use its menu bar item to open the
60-day hourly Analytics window, open Settings, or quit the application.

## Requirements

- macOS 13 or later to build and run the application
- macOS 14 or later to run the Xcode unit and UI tests
- Xcode 26 or later

The checked-in project uses the official Apple Development team `87M55M486F`
and bundle identifier `ca.horatiu.apmx`. Contributors do not need access to that
team. The application uses App Sandbox and Hardened Runtime. Its single
entitlement is `com.apple.security.app-sandbox`; it has no network entitlement.

## Project structure

- `APMExplorer`: SwiftUI application lifecycle and macOS adapters
- `APMXCore`: independent Swift 6 package containing reusable domain code and
  no AppKit, SwiftUI, or OSLog adapter
- `APMExplorerTests`: application composition unit tests
- `APMExplorerUITests`: launch smoke tests for the menu bar agent
- `Distribution`: App Store and Developer ID export options

`ApplicationLogging` accepts only fixed, allow-listed lifecycle events. The
OSLog adapter cannot accept raw strings or input events, so key codes,
characters, coordinates, deltas, application identity, and individual input
timestamps cannot be logged through that facade.

The listen-only Core Graphics event tap converts input to privacy-safe category,
autorepeat, and scroll-phase signals at the capture boundary. A monotonic-time
reducer discards key repeats and momentum and counts one action per scroll
gesture or phase-less burst. Pointer movement and dragging are not included in
the event-tap mask. The original APMX-5
owner-assisted permission and revocation test matrix is documented in
[`Documentation/APMX-5-Passive-Input-Spike.md`](Documentation/APMX-5-Passive-Input-Spike.md).
The production permission states, onboarding copy, recovery actions, and
owner-assisted checks are documented in
[`Documentation/APMX-9-Input-Monitoring-Onboarding.md`](Documentation/APMX-9-Input-Monitoring-Onboarding.md).

## Build and test

### Run the application locally

Open `APMExplorer.xcodeproj`, select the **APMExplorer** scheme, and run on
**My Mac**. To exercise Input Monitoring, the application needs a stable code
signature. Before the first run:

1. Select the **APMExplorer** project and open **Signing & Capabilities**.
2. For the Debug configuration of the `APMExplorer`, `APMExplorerTests`, and
   `APMExplorerUITests` targets, select your own Apple Development team.
3. Give the three targets unique bundle identifiers. For example, use
   `com.yourname.apmx`, `com.yourname.apmx.tests`, and
   `com.yourname.apmx.uitests`, replacing `yourname` with a unique value.
4. Run the **APMExplorer** scheme on **My Mac**.

A free Personal Team is sufficient for local development. Signing and bundle
identifier edits are local configuration; do not include them in a pull
request. macOS associates Input Monitoring approval with the signed code
identity, so changing the team or bundle identifier creates a separate entry in
System Settings.

### Run tests without signing

The portable core tests do not require an Apple Development account:

```sh
swift test --package-path APMXCore
```

Run the macOS unit and UI smoke tests without using the maintainer's signing
identity:

```sh
xcodebuild test \
  -project APMExplorer.xcodeproj \
  -scheme APMExplorer \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

The unsigned test build intentionally cannot request Input Monitoring access.
Permission prompts and live event capture require the signed local build
described above.

### Maintainer release gate

Run the complete release gate (core, privacy regression, macOS adapter, and UI
smoke tests) with one command:

```sh
Scripts/test-release.sh
```

This command also verifies the official bundle identifier and Team ID, so it
requires the maintainer's signing identity. Contributors are expected to run
the unsigned commands above.

Fixture conventions, Xcode instructions, and the privacy allow-list are
documented in
[`Documentation/APMX-14-Testing-and-Privacy.md`](Documentation/APMX-14-Testing-and-Privacy.md).

Maintainers can compile each supported configuration without producing an
archive:

```sh
xcodebuild build -project APMExplorer.xcodeproj -scheme APMExplorer \
  -configuration Debug -destination 'platform=macOS'
xcodebuild build -project APMExplorer.xcodeproj -scheme APMExplorer-AppStore \
  -configuration 'App Store Release' -destination 'generic/platform=macOS'
xcodebuild build -project APMExplorer.xcodeproj -scheme APMExplorer \
  -configuration 'Developer ID Release' -destination 'generic/platform=macOS'
```

## Archives and export

The two shared schemes use the same app target and source files. They differ
only in archive configuration and export method.

```sh
xcodebuild archive \
  -project APMExplorer.xcodeproj \
  -scheme APMExplorer-AppStore \
  -archivePath build/APMExplorer-AppStore.xcarchive \
  -destination 'generic/platform=macOS'

xcodebuild -exportArchive \
  -archivePath build/APMExplorer-AppStore.xcarchive \
  -exportPath build/AppStore \
  -exportOptionsPlist Distribution/AppStoreExportOptions.plist

xcodebuild archive \
  -project APMExplorer.xcodeproj \
  -scheme APMExplorer \
  -archivePath build/APMExplorer-DeveloperID.xcarchive \
  -destination 'generic/platform=macOS'

xcodebuild -exportArchive \
  -archivePath build/APMExplorer-DeveloperID.xcarchive \
  -exportPath build/DeveloperID \
  -exportOptionsPlist Distribution/DeveloperIDExportOptions.plist
```

Distribution archives require the matching Apple distribution certificates and
profiles to be available to Xcode.

## License

APM Explorer is available under the [MIT License](LICENSE).
