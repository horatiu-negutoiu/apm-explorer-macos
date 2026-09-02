# APMX-10: Passive Core Graphics activity source

## Production pipeline

The production adapter installs a `.listenOnly` Core Graphics event tap on a
dedicated thread and Core Foundation run loop. Its event mask contains only:

- key down
- mouse button down
- scroll wheel

Pointer movement and dragging are deliberately absent from the event mask, so
they cannot refresh session state or contribute an action.

The callback maps an event to `RawActivitySignal` and offers that value to a
bounded mailbox. It does not reduce activity, update session state, persist,
format, log, or call the main actor. `ActivitySignalIngestionExecutor` drains
the mailbox on one serial queue, applies `ActivityReducer`, updates aggregate
in-memory diagnostics, and passes surviving `ReducedActivity` values to
`SessionEngine`.

The mailbox holds at most 512 signals in production. When full, the newest
signal is discarded and one aggregate dropped-signal counter is incremented.

## Privacy boundary audit

`PrivacySafeInputSignalFactory` is the sole `CGEvent`-to-domain boundary. It
reads only:

- `keyboardEventAutorepeat`, to reject key autorepeat before enqueueing
- `scrollWheelEventMomentumPhase`, to classify momentum
- `scrollWheelEventScrollPhase`, to classify direct phase state

It never reads or models virtual key code, characters, modifier flags, pointer
coordinates, scroll deltas, application identity, process identity, window
identity, or window metadata. The callback and ingestion code contain no log or
database call. Neither `RawActivitySignal` nor `ReducedActivity` is passed to an
`ActivitySessionRepository`; the durable domain type remains the aggregate
`ActivitySession` summary.

Audit commands:

```sh
rg -n 'getIntegerValueField|\.location|\.flags|keyCode|virtualKey|unicode|delta|window|process' \
  APMExplorer/PassiveInputCapture.swift

rg -n 'SQLite|ActivitySessionRepository|logger|os_log|print\(' \
  APMExplorer/PassiveInputCapture.swift
```

The first command should report only the three allow-listed Core Graphics
fields (plus explanatory privacy comments). The second command should report
no matches.

## Permission, lifecycle, and recovery

Permission is checked without prompting every 15 seconds and whenever the app
becomes active. Loss of permission stops and releases the tap, rejects new
mailbox input, clears queued signals, and closes the live session with a
recovery boundary. Sleep, inactive login sessions, and application termination
use the corresponding session closure reason. Wake and login-session
activation resume only after permission is preflighted again.

Tap-disabled callbacks attempt a direct re-enable. If the tap remains disabled,
the coordinator releases and recreates it. Repeated creation failures retain a
capped exponential backoff guard and are retried on the low-frequency safety
check rather than by busy polling.

## Automated verification

The app tests cover the exact event mask and pointer exclusion, privacy-safe
classification, autorepeat rejection, scroll phase reduction,
disabled-tap detection, bounded overload behavior, live
`SessionEngine` ingestion, suspension, explicit-only permission prompting, and
settings links. The UI test verifies that the menu bar agent launches.

Run:

```sh
xcodebuild test \
  -project APMExplorer.xcodeproj \
  -scheme APMExplorer \
  -configuration Debug \
  -destination 'platform=macOS'

swift test --package-path APMXCore
```

## Signed owner-assisted verification

Verified on 2026-08-01 using the signed App Store Release build. The product
passed `codesign --verify --deep --strict`, identified bundle
`ca.horatiu.apmx` and team `87M55M486F`, included hardened-runtime flags, and
contained only the app-sandbox entitlement.

| Scenario | Result |
| --- | --- |
| Existing grant | **Pass.** Permission showed **Granted** and the event tap showed **Listening**. |
| Three activity categories | The original signed pass verified physical key down, mouse button down, and scroll gesture/burst. APMX-19 adds deterministic coverage that pointer movement and dragging are absent from capture; repeat the negative check in the next signed owner-assisted pass. |
| Load responsiveness | **Pass.** After 20 seconds of rapid input, the tap remained **Listening** and the app/settings remained responsive. The aggregate dropped-signal counter remained zero because ingestion kept up. |
| Runtime permission loss | **Pass with OS relaunch behavior.** Disabling Input Monitoring caused macOS to terminate and relaunch the app. After relaunch, permission showed **Not granted**, capture showed **Waiting for permission**, and all three counters remained zero while input was generated. No repeated prompt or error appeared. |
| Permission restoration | **Pass with OS relaunch behavior.** Re-enabling Input Monitoring caused another macOS relaunch. Permission returned to **Granted**, the tap returned to **Listening**, and all three activity categories resumed without calling **Request Access**. |
| Sleep/wake | **Pass.** The app remained stable, permission stayed granted, the tap resumed listening, and all categories resumed. The pre-sleep session closed; unlock-related activity started a new live session. |
| Clean shutdown | **Pass.** **Quit APM Explorer** removed the menu bar app without a crash or error dialog. |
| Tap-disabled recovery | **Deterministic path passed; OS callback not naturally observed.** Unit coverage verifies both disabled callback types and successful/failed direct re-enable accounting. The coordinator path recreates a failed tap with capped backoff. |

The naturally occurring tap-disable case remains recorded as unobserved rather
than inferred from the successful load test.
