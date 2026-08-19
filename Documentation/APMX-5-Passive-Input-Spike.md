# APMX-5: Sandboxed passive input spike

This spike answers whether the signed, sandboxed macOS 13+ app can observe the
three production activity categories with a public, listen-only Core Graphics
event tap. It also exposes the permission and recovery states needed for the
owner-assisted validation pass.

## Implementation under test

- API: `CGEvent.tapCreate` at `.cgSessionEventTap`
- Option: `.listenOnly` (the app cannot modify or suppress events)
- Permission: `CGPreflightListenEventAccess()` for passive checks and
  `CGRequestListenEventAccess()` only after the owner clicks **Request Access**
- Categories: physical key-down, mouse-button-down, and scroll-wheel. Pointer
  movement and dragging are not included in the event-tap mask.
- Runtime behavior: permission is preflighted once per second; revocation
  releases the tap, and a later grant recreates it without prompting
- Recovery: `.tapDisabledByTimeout` and `.tapDisabledByUserInput` are counted
  and the existing tap is re-enabled immediately
- System Settings deep link:
  `x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent`
- Generic fallback:
  `x-apple.systempreferences:com.apple.preference.security?Privacy`

The callback branches on `CGEventType` and reads only keyboard autorepeat and
scroll-phase fields. App state contains aggregate totals for the three
categories plus disabled, successfully re-enabled, and dropped-signal tap
totals. No raw event is logged. No key code, character, coordinate, delta,
application/window identity, clipboard value, or individual event timestamp is
modeled or retained.

## Signing and entitlement inspection

The target uses automatic signing with team `87M55M486F` and bundle identifier
`ca.horatiu.apmx`. `ENABLE_APP_SANDBOX` and `ENABLE_HARDENED_RUNTIME` are both
enabled for Debug, App Store Release, and Developer ID Release.

The entitlement file contains only:

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
```

The spike adds no temporary exception, accessibility, input-posting, network,
file, device, or automation entitlement. The signed release product must be
inspected after building using the commands below. A Debug product prepared as
an XCTest host receives test-only temporary entitlements from Xcode and is not
the entitlement reference for this spike.

## Automated verification result

Verified on 2026-08-01 with macOS 26.5.2 and Xcode 26.6:

- Debug, App Store Release, and Developer ID Release builds succeeded.
- Six app unit tests, one app UI launch test, and all 18 `APMXCore` tests
  passed.
- `codesign --verify --deep --strict` passed for both release products.
- Both release signatures identify `ca.horatiu.apmx`, team `87M55M486F`, and
  have `flags=0x10000(runtime)`.
- Both release products contain exactly one entitlement:
  `com.apple.security.app-sandbox = true`.

These checks verify the implementation, build configurations, signatures, and
privacy boundary. They do not substitute for the protected TCC interactions in
the owner-assisted matrix below.

## Owner-assisted validation matrix

Build and run a signed app, open its menu bar item, and open Settings. The
results below were recorded on macOS 26.5.2 using the sandboxed App Store
Release build signed by team `87M55M486F`.

| Scenario | Procedure | Expected result | Actual result |
| --- | --- | --- | --- |
| First request | With APM Explorer absent from Input Monitoring, click **Request Access** once. | macOS presents its permission flow once; the app does not repeat it. | **Pass with OS variance.** The owner invoked the request once. This macOS installation showed no additional prompt and did not add the app to the list automatically; the app did not prompt again. |
| Denial | Deny or leave access disabled, then interact with keyboard and pointer. | Status stays **Waiting for permission** and all three activity totals stay unchanged. | **Pass.** Status remained **Not granted / Waiting for permission**, all three totals remained zero, and no prompt loop occurred. |
| Later grant | Use **Open Input Monitoring**, enable APM Explorer, then return to the app. | Permission becomes **Granted** and tap becomes **Listening**, or a relaunch requirement is recorded. | **Pass; relaunch required.** The owner added and enabled the exact signed build. macOS relaunched the app, which then showed **Granted / Listening**. |
| Three categories | Produce one or more physical key-downs, button-downs, and scrolls. Move and drag the pointer without clicking as a negative check. | Every corresponding aggregate total increases. Pointer movement alone changes no total or session state. No event payload appears in Console. | The three positive categories passed during the original signed validation. The pointer-exclusion behavior is covered deterministically by the APMX-19 event-mask and adapter tests and remains to be repeated in a signed owner-assisted pass. |
| Runtime revocation | While listening, disable APM Explorer in Input Monitoring and return to the app. | Within about one second, status becomes **Waiting for permission**, capture stops, and no prompt appears. | **Pass with OS variance.** Disabling access caused macOS to terminate the app. Relaunching it showed **Not granted / Waiting for permission**, zero totals, and no prompt. |
| Restore after revocation | Re-enable Input Monitoring without clicking **Request Access**. Relaunch only if needed. | Capture resumes automatically, or the required relaunch is documented. | **Pass; relaunch required.** After the owner re-enabled access, relaunching the exact signed build restored **Granted / Listening** and aggregate capture resumed without invoking **Request Access**. |
| Tap recovery | Induce or observe a disabled-tap callback during stress testing. | **Disable notifications** increases; **Successful re-enables** also increases when recovery succeeds. | **Deterministic path passed; OS callback not naturally observed.** Both UI values remained zero during the session. A unit test covers both disabled-tap types, successful and failed re-enable accounting, and rejection of ordinary input; the polling path recreates a failed tap. |
| Deep link | Click **Open Input Monitoring**. | System Settings opens Privacy & Security → Input Monitoring. | **Pass.** The exact Input Monitoring pane opened. |
| Generic fallback | Click **Privacy & Security Fallback**. | System Settings opens Privacy & Security so Input Monitoring can be selected manually. | **Pass.** The generic Privacy & Security pane opened. |

If macOS caches an earlier permission choice, reset only this development
bundle's Input Monitoring decision before repeating the first-request case:

```sh
tccutil reset ListenEvent ca.horatiu.apmx
```

This command removes the stored decision; the owner must still approve or deny
the next request personally.

## Build and signed-product checks

```sh
xcodebuild build \
  -project APMExplorer.xcodeproj \
  -scheme APMExplorer-AppStore \
  -configuration 'App Store Release' \
  -destination 'generic/platform=macOS'

app_path="/path/reported/by/xcodebuild/Build/Products/App Store Release/APM Explorer.app"
codesign --verify --deep --strict --verbose=2 "$app_path"
codesign --display --entitlements - "$app_path"
codesign --display --verbose=4 "$app_path"
```

In the final `codesign --display --verbose=4` output, `flags` must include
`runtime`. The release entitlements output must contain the sandbox entitlement
only; unexpected capability entitlements must be investigated.

## App Store review-note draft

APM Explorer uses Apple's public Core Graphics event-tap API in listen-only
mode to count aggregate activity categories for the user. Input Monitoring is
requested only after an explicit user action. The app does not inspect, store,
or transmit keystrokes, key codes, characters, pointer coordinates, scroll
deltas, application/window identity, clipboard data, or individual input
timestamps. The event tap cannot alter or suppress input. Revoking Input
Monitoring stops capture, and the app does not repeatedly prompt after denial.

The tap-recovery row is intentionally recorded as unobserved rather than being
presented as a verified runtime finding.
