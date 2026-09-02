# APMX-18: Mac App Store submission dossier

This dossier is the review source of truth for APM Explorer 1.0. It records the
owner-approved product-page content, privacy answers, review guidance, build
contract, and submission evidence without storing App Store Connect credentials
or private review-contact details in the repository.

## Release identity

| Field | Approved value |
| --- | --- |
| App name | APM Explorer |
| Subtitle | Private activity analytics |
| Platform | macOS |
| Version | 1.0.0 (App Store Connect version 1.0) |
| Build | 1 |
| Bundle identifier | `ca.horatiu.apmx` |
| SKU | `apmx-macos` (existing immutable App Store Connect value) |
| Architecture | Apple Silicon (`arm64`) |
| Minimum OS | macOS 13.0 |
| Primary language | English |
| Primary category | Productivity |
| Secondary category | None |
| Price | Free |
| Availability | All regions offered by App Store Connect |
| Release setting | Manually release after approval |
| Copyright | 2026 Horatiu Negutoiu |

The app is a menu-bar-only agent. `LSUIElement` is enabled, so it has no Dock or
app-switcher presence. The menu bar item is the entry point.

## URLs

- Marketing URL: <https://apmx.horatiu.ca/>
- Support URL: <https://apmx.horatiu.ca/support/>
- Privacy policy URL: <https://apmx.horatiu.ca/privacy/>
- Reviewer setup guide: <https://apmx.horatiu.ca/getting-started/>
- Public source: <https://github.com/horatiu-negutoiu/apm-explorer-macos>

Verify every URL immediately before submission.

## Product-page copy

### Description

APM Explorer is a private, local-first activity tracker for macOS. It helps you
understand your interaction rhythm without recording what you type or which
apps you use.

See your actions per minute throughout the day and explore up to 60 days of
hourly activity history. APM Explorer counts physical key presses, mouse-button
presses, and reduced scroll gestures, then relates them to the time monitoring
was active.

Privacy is built in:

- All activity data stays on your Mac.
- Keys, characters, and typed content are never recorded.
- Pointer locations, clipboard contents, and individual input events are never
  stored.
- APM Explorer never tracks which apps, windows, or websites you use.
- There are no accounts, cloud sync, telemetry, advertisements, subscriptions,
  or in-app purchases.

APM Explorer requires Input Monitoring permission to count activity while you
use other apps. You can revoke this permission at any time through System
Settings.

Requires macOS 13 or later on an Apple Silicon Mac.

In implementation terms, “physical key presses” in the submitted product copy
means non-autorepeat `keyDown` events observed by the passive event tap. The app
does not inspect event-source identity, so a synthetic non-autorepeat event can
also contribute to the aggregate count.

### Keywords

`activity tracker,productivity,focus,analytics,privacy,work habits,actions per minute`

### Promotional text

See broad patterns in your work rhythm without recording what you type, where
you click, or which apps you use.

### Version notes

Initial Mac App Store release.

## Screenshots

Upload in this order:

1. `../apm-explorer-assets/previews/apmx-preview-1.jpg` — 1280 × 800,
   fourteen-day hourly analytics.
2. `../apm-explorer-assets/previews/apmx-preview-2.jpg` — 1280 × 800,
   menu-bar status and actions.

Both assets are opaque JPEGs at an App Store-supported 16:10 Mac screenshot
size. Run the release verifier against the containing directory before upload.

## App Privacy

Select **No, we do not collect data from this app**.

For App Privacy, Apple defines collection around data transmitted off the
device. The app has no account, telemetry, advertising, analytics service,
cloud sync, or network entitlement. It does not transmit user or activity data.
Local-only processing and storage are disclosed in the public privacy policy:

- raw events are reduced immediately to non-autorepeat key-down,
  mouse-button-down,
  and scroll-gesture/burst activity signals;
- key codes, characters, typed content, pointer coordinates, scroll deltas,
  application/window identity, clipboard contents, and individual input events
  never enter persistent storage;
- local session summaries contain start, last-activity, and end times, aggregate
  action count, timeout, and end reason, and are retained for 48 hours;
- local hourly aggregates contain an hour boundary, aggregate action count, and
  aggregate monitored duration, and are retained for a rolling 60 days;
- the launch-at-login preference is retained until changed; and
- **Delete Activity Data…** deletes session and hourly history while retaining
  that preference.

Tracking is not used.

## Age rating and content rights

Answer **No** or **None** for every content-frequency and capability question:
the app contains no objectionable content, unrestricted web access, gambling,
contests, loot boxes, advertising, messaging, user-generated content, health or
wellness claims, or age-restricted services. Its fixed external destinations are
the APM Explorer homepage and About / FAQ page, the author's website, and the
voluntary Buy Me a Coffee project-support page. The App Store listing separately
provides the public support and getting-started URLs.

Select the lowest rating produced by App Store Connect. The app displays and
analyzes only the local user's aggregate activity totals. It does not contain,
sell, or stream third-party content, so it does not require third-party content
rights.

## Export compliance

The app and its linked dependencies do not use encryption or a network stack.
`ITSAppUsesNonExemptEncryption` is `NO`. Use that build declaration for the
export-compliance flow; do not claim a legal exemption different from the build
without owner review.

## App Review information

The owner enters the review contact name, email address, and phone number
directly in App Store Connect. The app requires no account, demo credentials,
subscription, purchase, special hardware, or backend service.

### Review notes

APM Explorer is a menu-bar-only macOS app, so it intentionally has no Dock icon.
After launch, use the APM Explorer menu bar item to open its panel.

The app creates a public Core Graphics event tap with the listen-only option. It
uses this passive API solely to count non-autorepeat key-down events,
mouse-button downs, and reduced scroll gestures or bursts. macOS requires
user-granted Input Monitoring for this behavior. The app never records keys,
characters, typed content, modifier flags, pointer coordinates, scroll deltas,
clipboard data, application/window identity, or individual input events.

All processing and storage are local. Privacy-safe session summaries remain for
48 hours; hourly aggregate action and monitoring totals remain for 60 days. The
app has no account, telemetry, cloud sync, analytics SDK, network entitlement,
or updater, and no user or activity data leaves the Mac.

To exercise the app:

1. Launch APM Explorer. If Input Monitoring is missing, a welcome or recovery
   window appears automatically. The menu bar icon also opens the app controls.
2. Select **Enable Input Monitoring** in the welcome window, or **Allow Input
   Monitoring** from the menu or Settings. If macOS directs you to System Settings,
   open **Privacy & Security → Input Monitoring**, enable APM Explorer, and
   return to the app.
3. Permission status updates automatically when you return. If a relaunch is
   required, select **Relaunch APMX** and reopen the menu bar item.
4. Press ordinary keys, click a mouse button, or scroll. The panel will show
   **Allowed · Listening** and update its aggregate metrics; no input content is
   displayed or retained.
5. Select **Analytics…** to inspect privacy-safe hourly totals and monitoring
   coverage.
6. Open **Settings… → Privacy and data** to inspect the retention disclosure or
   use **Delete Activity Data…**.

If Input Monitoring is denied, the rest of the app remains usable and explains
how to grant the permission later. The public setup guide is
<https://apmx.horatiu.ca/getting-started/>.

## Build and validation procedure

Run the complete maintainer release gate first:

```sh
Scripts/test-release.sh
```

Create and export the App Store archive:

```sh
xcodebuild archive \
  -project APMExplorer.xcodeproj \
  -scheme APMExplorer-AppStore \
  -archivePath build/APMExplorer-AppStore.xcarchive \
  -destination 'generic/platform=macOS' \
  -allowProvisioningUpdates

xcodebuild -exportArchive \
  -archivePath build/APMExplorer-AppStore.xcarchive \
  -exportPath build/AppStore \
  -exportOptionsPlist Distribution/AppStoreExportOptions.plist \
  -allowProvisioningUpdates

Scripts/test-verify-app-store-release.sh \
  'build/APMExplorer-AppStore.xcarchive/Products/Applications/APM Explorer.app' \
  ../apm-explorer-assets/previews \
  build/AppStore/DistributionSummary.plist

Scripts/verify-app-store-release.sh \
  'build/APMExplorer-AppStore.xcarchive/Products/Applications/APM Explorer.app' \
  ../apm-explorer-assets/previews \
  build/AppStore/DistributionSummary.plist
```

The verifier requires the export's `DistributionSummary.plist` so that an
Apple Distribution certificate, Mac App Store provisioning profile, final
entitlements, version/build, and architecture are checked independently of the
development-signed archive. It also checks the exact filenames, order, and
SHA-256 hashes in `Distribution/AppStoreScreenshotManifest.sha256`.

Upload through Xcode or App Store Connect's supported uploader, wait for
processing, select build 1 for version 1.0, and resolve every validation warning
or error before submission. The reproducible command-line upload uses the
checked-in upload destination:

```sh
xcodebuild -exportArchive \
  -archivePath build/APMExplorer-AppStore.xcarchive \
  -exportPath build/AppStoreUpload \
  -exportOptionsPlist Distribution/AppStoreUploadOptions.plist \
  -allowProvisioningUpdates
```

## Submission evidence

| Check | Result | Evidence |
| --- | --- | --- |
| Owner-approved listing posture | Approved | User approval on 2026-09-01 and APMX-18 owner approval comment |
| Dependency tickets | Passed | APMX-15 and APMX-16 are Done |
| Source and unit/UI release gate | Passed 2026-09-01 | Core suite, 44 app tests, one UI test, signed release checks; `Scripts/test-release.sh` exited 0 |
| Bundle/version/build/architecture | Passed 2026-09-01 | Final archive is `ca.horatiu.apmx` 1.0.0 (1), arm64 |
| Sandbox, entitlements, signature, offline/updater audit | Passed 2026-09-01 | App Store verifier checked the archive plus export distribution summary; Cloud Managed Apple Distribution, Mac App Store profile, sandbox plus Apple application/team identifiers only |
| Screenshot identity, order, dimensions, alpha | Passed 2026-09-01 | Two opaque 1280 × 800 JPEGs match the versioned filenames, order, and SHA-256 manifest |
| Public privacy/support URLs | Passed 2026-09-01 | Marketing, privacy, support, and getting-started pages resolved over HTTPS |
| App Store Connect upload processing | Passed 2026-09-01 | Build 1.0.0 (1) is processed and available for selection |
| Pricing and availability | Passed 2026-09-01 | Free in all 175 storefronts; public distribution |
| App Privacy | Passed 2026-09-01 | Published as Data Not Collected; privacy URL verified |
| Version metadata | Passed 2026-09-01 | Subtitle/category, screenshots, URLs, build, review contact/notes, and manual release are saved |
| App Review submission | Passed 2026-09-01 | macOS 1.0 with build 1.0.0 (1) submitted; status Waiting for Review |
| Add for Review / Submit for Review | Passed 2026-09-01 | Owner confirmed both actions; Apple accepted the submission and returned Waiting for Review |

The APMX-18 completion conditions are satisfied. Track any subsequent App Review
validation or review feedback as a Bug or Task under APMX-1.
