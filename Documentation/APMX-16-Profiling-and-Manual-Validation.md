# APMX-16 profiling and manual validation

This record distinguishes observed local evidence from protected-permission,
visible-UI, signing, operating-system, and hardware checks. Trace bundles stay
outside the repository.

## Engineering gates

| Gate | Target | Result | Evidence |
| --- | --- | --- | --- |
| Idle CPU | Effectively 0%; no fast polling | Owner-assisted pending | The prior six `32` KB / `0.0`% readings are invalid: the PID was trace-launched and its direct-executable identity and state were not verified for every sample. Use the [direct-launch procedure](#owner-direct-launch). |
| Idle SQLite writes | Zero recurring writes | Owner-assisted pending | A Data Persistence trace alone cannot prove raw `sqlite3` writes on this toolchain. Use the [bounded idle-write procedure](#owner-idle-writes). |
| Inactive UI timer | No one-second timer | Pass | Source inspection of [`PassiveInputCapture.swift`](../APMExplorer/PassiveInputCapture.swift) found a five-minute visualization cadence and a 15-second steady-state permission cadence. Startup or interruption recovery may use 0.5-second checks, but only for the first 12 attempts (at most 6 seconds) before returning to the 15-second cadence; the loop is bounded rather than continuous, so the inactive-timer gate remains satisfied. The five-minute-cadence app test passed. |
| Event callback | No I/O or MainActor hop | Pass | Source inspection of [`PassiveInputCapture.swift`](../APMExplorer/PassiveInputCapture.swift) shows the callback creates a privacy-safe signal and enqueues it in the bounded mailbox; mailbox tests passed. |
| Resident memory | Under 50 MB | Owner-assisted pending | The prior six `32` KB readings are invalid for this gate for the same unverified/exited-PID reason; use the [direct-launch procedure](#owner-direct-launch) to capture PID, state, command, and RSS on every reading. |
| Menu availability | Under 500 ms | Owner-assisted pending | No valid trace-to-visible-status-item latency observation exists; use the [visible-menu procedure](#owner-menu-latency). |
| Abnormal action/session loss | At most 500 ms | Pass | Core tests in [`SQLiteActivitySessionRepositoryTests.swift`](../APMXCore/Tests/APMXCoreTests/SQLiteActivitySessionRepositoryTests.swift) passed `testDefaultCoalescingWindowIsFiveHundredMilliseconds` and the scheduler-driven `testLaterHourlyMutationDoesNotScheduleASecondFlushDeadline`. |

## Validation host

- Model: MacBook Pro `Mac15,6`
- Chip: Apple M3 Pro, 11 cores (5 performance and 6 efficiency)
- Memory: 36 GB
- macOS: 26.6.2 (25G83)
- Xcode: 26.6 (17F113)
- Swift: 6.3.3
- Release architecture requirement: arm64 only

These facts were read on 2026-09-01 with `system_profiler SPHardwareDataType`,
`sw_vers`, `xcodebuild -version`, and `swift --version`.

## Automated and static results

| Check | Command | Date | Result | Observed evidence |
| --- | --- | --- | --- | --- |
| Core tests | `swift test --package-path APMXCore` | 2026-09-01 | Pass | 81 tests, 0 failures; the full suite completed in 0.281 seconds. |
| App and UI tests | `xcodebuild test -project APMExplorer.xcodeproj -scheme APMExplorer -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO` | 2026-09-01 | Pass | The release workflow's test command exited 0: 44 app tests and 1 UI launch test, all with 0 failures. Expected local App Intents service and missing-debugger-version diagnostics were unaffected. This is not visible-status-item evidence. |
| Maintainer release workflow | `Scripts/test-release.sh` | 2026-09-01 | Pass | The bounded command exited 0 without a hang: brand assets, 81 core tests, 44 app tests, 1 UI launch test, stable Input Monitoring identity, local release build, and release-safety inspection completed. Expected App Intents metadata-skip, multiple-destination, and missing-debugger-version diagnostics were emitted. |
| Local release-configuration safety | `Scripts/verify-release-safety.sh "$local_release_app"` via `Scripts/test-release.sh` | 2026-09-01 | Pass | The local `Developer ID Release` configuration product verified as arm64-only, Hardened Runtime, sandbox-only, and offline. Its development signature is not distribution-candidate evidence. |
| Distribution-signed candidates | [Owner signing procedure](#owner-os-signing) | — | Owner-assisted pending | The local product is not signed with a Developer ID Application identity, and no exported Developer ID or App Store candidate was supplied. Use the [owner signing procedure](#owner-os-signing). |
| Entitlement inspection | `Scripts/verify-release-safety.sh "$local_release_app"` via `Scripts/test-release.sh` | 2026-09-01 | Pass | The local release-configuration product contained exactly `com.apple.security.app-sandbox`; distribution-candidate entitlement inspection remains part of the owner signing procedure. |
| Linked dependencies | `otool -L "$local_release_app/Contents/MacOS/APM Explorer"` via `Scripts/verify-release-safety.sh` | 2026-09-01 | Pass | The local arm64 release-configuration executable listed no prohibited networking, telemetry, analytics, or updater framework. |
| Source privacy scan | `rg -n '^[[:space:]]*import[[:space:]]+(Network|CFNetwork)|URLSession|NWConnection|SentrySDK|SUUpdater|SPUUpdater|TelemetryClient|Mixpanel|FirebaseAnalytics|Crashlytics|MXMetricManager|NSSetUncaughtExceptionHandler' APMExplorer APMXCore/Sources` | 2026-09-01 | Pass | No matches. |
| SQLite schema/content checks | `swift test --package-path APMXCore` | 2026-09-01 | Pass | `PrivacyRegressionTests` passed its representative-database allow-list assertion. |
| Preference-key policy test | `Scripts/test-preference-privacy-policy.sh` | 2026-09-01 | Pass | The deterministic test accepts the four exact app-authored keys and the framework-owned `NSWindow Frame ` prefix. It rejects the no-space form, arbitrary `NS*`, unknown app-style keys, missing/invalid/empty inputs, injected tool failures, and override variables without the explicitly validated internal test mode. |

### Privacy checks

The owner approved a narrow preferences-key policy refinement on 2026-09-01.
App-authored keys remain restricted to exactly
`inputMonitoring.hasBeenGranted`, `inputMonitoring.hasRequested`,
`settings.launchAtLogin`, `settings.hasCompletedLaunchAtLoginOnboarding`,
`settings.hasPendingPermissionRecovery`, and `settings.schemaVersion`.
The onboarding booleans remember whether the user handled the optional
login-startup offer and whether permission recovery should offer it again;
they contain no activity data. In addition, a key is
permitted only when its name begins with the exact framework-owned prefix
`NSWindow Frame `, including the trailing space. SwiftUI/AppKit writes those
keys to preserve window placement; they are not app-authored capture data. The
rule does not allow arbitrary `NS*` or other framework keys.

| Check | Result | Observed evidence |
| --- | --- | --- |
| Durable model, schema, and capture data | Pass | `PrivacyRegressionTests` passed 4 tests in the core-suite run. |
| Preferences-domain allow-list | Pass | `Scripts/verify-preference-privacy.sh` exited 0 through its public domain-owned path: 8 keys total, comprising all 4 exact app-authored keys and 4 framework-owned `NSWindow Frame ` keys, with 0 other keys. The script checks each defaults export, plist validation/conversion, key extraction, non-empty stream, and policy stage separately; private mode-safe temporary files are cleaned, and no preference values are output or recorded. |
| Unified logs contain fixed `ApplicationLogEvent` messages only | Pass | A bounded, private `log show` capture exited 0; key-free inspection found 4 entries, all matching the three fixed `ApplicationLogEvent` messages, with 0 unexpected messages. No raw log entries were recorded in the repository. |
| UI shows aggregate counts and coverage only | Owner-assisted pending | Automated launch does not establish a visible UI result; use the [privacy and aggregate-UI procedure](#owner-privacy-ui). |
| No app-added crash metadata integration | Pass | The source privacy scan had no `Crashlytics`, `MXMetricManager`, uncaught-exception-handler, or other prohibited integration match. |

## Retained trace status

The local trace root is outside the repository:

```text
/tmp/apmx-performance-traces.Vi5mhY/apmx-baseline
```

All five retained TOCs identify this Debug target, not the requested
stable-identity profiling path:

```text
/Users/horatiu/Library/Developer/Xcode/DerivedData/APMExplorer-ahvjylynpdpuitdsuzdyzceqauug/Build/Products/Debug/APM Explorer.app
```

Therefore none of these recordings establishes an APMX-16 gate. Each was
exported with `xcrun xctrace export --input <trace> --toc`.

| Trace | TOC duration | Result | Notes |
| --- | --- | --- | --- |
| `app-launch.trace` | 15.290946 s | Owner-assisted pending | Target ended by `SIGKILL`; no visible menu timing. Use the [visible-menu procedure](#owner-menu-latency). |
| `time-profiler.trace` | 15.815457 s | Owner-assisted pending | No CPU or wakeup summary inspected. Use the [workload protocol](#owner-workload-protocol). |
| `allocations.trace` | 15.719178 s | Owner-assisted pending | No allocation summary inspected. Use the [direct-launch procedure](#owner-direct-launch) and [workload protocol](#owner-workload-protocol). |
| `data-persistence.trace` | 15.665801 s | Owner-assisted pending | Cannot prove raw SQLite writes on this toolchain. Use the [bounded idle-write procedure](#owner-idle-writes). |
| `system-trace.trace` | 10.000000 s | Owner-assisted pending | Requested duration was 15 s; no file-I/O or wakeup summary inspected. Use the [workload protocol](#owner-workload-protocol) and [bounded idle-write procedure](#owner-idle-writes). |

The old foreground helper run was stopped by the command runner after its first
capture. Its remaining four recordings were separate `xcrun` commands and,
because every TOC target mismatched the requested app, are retained only as
diagnostic artifacts. The hardened helper now fails closed on that mismatch.

## Workload evidence matrix

Each cell is either measured evidence or a permitted status. The evidence
recording location for completed procedures is this table and the associated
gate row above; do not commit traces, screenshots, keys, input data, or logs.

| Workload | Duration | Permission | Trace(s) | CPU / wakeups | Allocations / RSS | SQLite / file writes | Dropped signals | Event-tap recovery | Result | Evidence or exact procedure |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Launch | Owner-assisted pending | Owner-assisted pending | App Launch | Owner-assisted pending | Owner-assisted pending | Owner-assisted pending | Owner-assisted pending | Owner-assisted pending | Owner-assisted pending | Use the [visible-menu procedure](#owner-menu-latency). |
| Idle | Owner-assisted pending | Owner-assisted pending | Time Profiler, Allocations, System Trace, File Activity | Owner-assisted pending | Owner-assisted pending | Owner-assisted pending | Owner-assisted pending | Owner-assisted pending | Owner-assisted pending | Use the [direct-launch](#owner-direct-launch), [bounded idle-write](#owner-idle-writes), and [workload](#owner-workload-protocol) procedures. |
| Keyboard-heavy | Owner-assisted pending | Owner-assisted pending | Time Profiler, System Trace | Owner-assisted pending | Owner-assisted pending | Owner-assisted pending | Owner-assisted pending | Owner-assisted pending | Owner-assisted pending | Use the [workload protocol](#owner-workload-protocol) and [protected keyboard/permission procedure](#owner-keyboard). |
| Mouse-heavy | Owner-assisted pending | Owner-assisted pending | Time Profiler, System Trace | Owner-assisted pending | Owner-assisted pending | Owner-assisted pending | Owner-assisted pending | Owner-assisted pending | Owner-assisted pending | Use the [workload protocol](#owner-workload-protocol) and [mouse procedure](#owner-mouse). |
| Scroll-heavy | Owner-assisted pending | Owner-assisted pending | Time Profiler, System Trace | Owner-assisted pending | Owner-assisted pending | Owner-assisted pending | Owner-assisted pending | Owner-assisted pending | Owner-assisted pending | Use the [workload protocol](#owner-workload-protocol) and [scroll, drag, and repeat procedure](#owner-scroll). |

## Manual matrix

| Area | Scenario | Result | Evidence or exact procedure |
| --- | --- | --- | --- |
| Operating system | macOS 13 | Hardware unavailable | No macOS 13 hardware was available; use the [OS and signing procedure](#owner-os-signing) when hardware is supplied. |
| Operating system | Current macOS | Owner-assisted pending | The host version was recorded, but visible and protected scenarios require the [OS and signing procedure](#owner-os-signing). |
| Permission | Fresh, denied, granted, revoked | Owner-assisted pending | Use the [protected keyboard/permission procedure](#owner-keyboard). |
| Input | Mouse, trackpad, external keyboard | Owner-assisted pending | Use the [keyboard](#owner-keyboard) and [mouse](#owner-mouse) procedures with owner-operated hardware. |
| Input | Dragging, held repeat, inertial scroll | Owner-assisted pending | Use the [scroll, drag, and repeat procedure](#owner-scroll). |
| Lifecycle | Sleep/wake, lock/unlock, user switching, logout/login | Owner-assisted pending | Use the [lifecycle procedure](#owner-lifecycle). |
| Lifecycle | Clock change, force quit, upgrade | Owner-assisted pending | Use the [lifecycle procedure](#owner-lifecycle). Owner acceptance of the idle force-quit coverage-tail exception has not been recorded, so that exception remains unaccepted. |
| Launch at login | Enabled, disabled, denied | Owner-assisted pending | Use the [login, appearance, and accessibility procedure](#owner-login-accessibility). |
| Appearance and accessibility | Light, dark, high contrast, keyboard navigation, VoiceOver | Owner-assisted pending | Use the [login, appearance, and accessibility procedure](#owner-login-accessibility); VoiceOver is not inferred from automated launch. |
| Signing | App Store candidate, Developer ID candidate, notarization | Owner-assisted pending | Use the [OS and signing procedure](#owner-os-signing); the local development-signed product is not distribution evidence. |

## Owner-assisted procedures

All procedures write only aggregate observations and status into the named row
of this document; retain raw trace, screenshot, console, and signing evidence
outside the repository.

<a id="owner-direct-launch"></a>
1. **Direct launch, CPU, and memory — Idle CPU / Resident memory / Idle row.**
   Set `app="/path/to/APM Explorer.app"`, resolve `executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")`, then launch `"$app/Contents/MacOS/$executable" & app_pid=$!` (not an `xctrace` target). Before and during each of six 10-second samples run `ps -p "$app_pid" -o pid=,state=,rss=,%cpu=,command=`. Record each PID, non-exited state, exact command, RSS, and CPU in the Idle row; stop and mark Fail if identity/state changes. Mark Pass only if all direct samples meet the CPU and under-50-MB targets and the Allocations summary agrees; otherwise mark Fail.
<a id="owner-menu-latency"></a>
2. **Launch menu latency — Menu availability / Launch row.** Run the hardened helper against the exact app, confirm each TOC target equals that app or its executable, then video-record a monotonic-clock launch-to-visible-status-item trial. Repeat five times, record all milliseconds in the Launch row, and mark Pass only if each is under 500 ms.
<a id="owner-idle-writes"></a>
3. **Idle writes — Idle SQLite writes / Idle row.** This remains
   Owner-assisted pending until the owner runs the procedure against the exact
   candidate. Use a fresh external directory, derive the sandbox container from
   the verified bundle identifier, and define every path before redirecting:
   ```sh
   evidence_dir=$(/usr/bin/mktemp -d /tmp/apmx-idle-writes.XXXXXX)
   test -d "$evidence_dir"
   app='/path/to/APM Explorer.app'
   executable=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")
   bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
   test "$bundle_identifier" = ca.horatiu.apmx
   app_executable="$app/Contents/MacOS/$executable"
   test -x "$app_executable"
   user_name=$(/usr/bin/id -un)
   user_home_directory=$(
     /usr/bin/dscl . -read "/Users/$user_name" NFSHomeDirectory |
       /usr/bin/awk '{print $2}'
   )
   case "$user_home_directory" in /*) ;; *) exit 1 ;; esac
   container_directory="$user_home_directory/Library/Containers/$bundle_identifier"
   database_directory="$container_directory/Data/Library/Application Support/$bundle_identifier"
   warmup_log="$evidence_dir/idle-warmup-fs_usage.log"
   measured_log="$evidence_dir/idle-measured-fs_usage.log"
   matched_log="$evidence_dir/idle-measured-db-lines.log"
   warmup_fs_pid=''
   measured_fs_pid=''
   app_pid=''

   verify_app() {
     phase=$1
     /bin/kill -0 "$app_pid"
     app_state=$(/bin/ps -p "$app_pid" -o state= | /usr/bin/tr -d ' ')
     test -n "$app_state"
     case "$app_state" in *Z*) exit 1 ;; esac
     app_command=$(/bin/ps -p "$app_pid" -o command=)
     test "$app_command" = "$app_executable"
     /bin/ps -p "$app_pid" -o pid=,state=,command= \
       > "$evidence_dir/app-$phase.txt"
   }
   verify_fs_usage() {
     fs_pid=$1
     phase=$2
     /bin/kill -0 "$fs_pid"
     fs_state=$(/bin/ps -p "$fs_pid" -o state= | /usr/bin/tr -d ' ')
     test -n "$fs_state"
     case "$fs_state" in *Z*) exit 1 ;; esac
     fs_command=$(/bin/ps -p "$fs_pid" -o command=)
     case "$fs_command" in
       *'/usr/bin/fs_usage -w -f filesys'*) ;;
       *) exit 1 ;;
     esac
     /bin/ps -p "$fs_pid" -o pid=,state=,command= \
       > "$evidence_dir/fs_usage-$phase.txt"
   }
   stop_if_running() {
     target_pid=${1:-}
     if test -n "$target_pid" && /bin/kill -0 "$target_pid" 2>/dev/null; then
       /bin/kill -INT "$target_pid" 2>/dev/null
     fi
   }
   cleanup() {
     set +e
     stop_if_running "$warmup_fs_pid"
     stop_if_running "$measured_fs_pid"
     if test -n "$app_pid" && /bin/kill -0 "$app_pid" 2>/dev/null; then
       /bin/kill -TERM "$app_pid" 2>/dev/null
     fi
   }
   trap cleanup EXIT
   trap 'exit 1' HUP INT TERM

   /usr/bin/sudo -v

   /usr/bin/sudo /usr/bin/fs_usage -w -f filesys > "$warmup_log" 2>&1 &
   warmup_fs_pid=$!
   verify_fs_usage "$warmup_fs_pid" warmup-before
   "$app_executable" &
   app_pid=$!
   verify_app warmup-before
   /bin/sleep 30
   verify_app warmup-after
   verify_fs_usage "$warmup_fs_pid" warmup-after
   test -d "$container_directory"
   container_directory=$(CDPATH= cd -- "$container_directory" && pwd -P)
   database_directory="$container_directory/Data/Library/Application Support/$bundle_identifier"
   test -d "$database_directory"
   database_directory=$(CDPATH= cd -- "$database_directory" && pwd -P)
   case "$database_directory" in "$container_directory"/*) ;; *) exit 1 ;; esac
   database="$database_directory/activity.sqlite3"
   test "$(/usr/bin/basename "$database")" = activity.sqlite3
   test -f "$database"
   database_wal="${database}-wal"
   database_shm="${database}-shm"
   /bin/kill -INT "$warmup_fs_pid"
   set +e
   wait "$warmup_fs_pid"
   warmup_status=$?
   set -e
   case "$warmup_status" in 0|130) ;; *) exit "$warmup_status" ;; esac
   warmup_fs_pid=''

   verify_app measured-before
   /usr/bin/sudo /usr/bin/fs_usage -w -f filesys -p "$app_pid" \
     > "$measured_log" 2>&1 &
   measured_fs_pid=$!
   verify_fs_usage "$measured_fs_pid" measured-before
   /bin/sleep 60
   verify_app measured-after
   verify_fs_usage "$measured_fs_pid" measured-after
   /bin/kill -INT "$measured_fs_pid"
   set +e
   wait "$measured_fs_pid"
   measured_status=$?
   set -e
   case "$measured_status" in 0|130) ;; *) exit "$measured_status" ;; esac
   measured_fs_pid=''

   if ! rg_command=$(command -v rg); then
     printf 'rg is required for fixed-string database-path inspection\n' >&2
     exit 2
   fi
   test -x "$rg_command"
   set +e
   "$rg_command" -n -F \
     -e "$database" -e "$database_wal" -e "$database_shm" \
     "$measured_log" > "$matched_log"
   rg_status=$?
   set -e
   case "$rg_status" in
     0) printf 'Database-path activity requires write-operation inspection: %s\n' "$matched_log" ;;
     1) : > "$matched_log" ;;
     *) printf 'rg inspection failed with status %s\n' "$rg_status" >&2; exit "$rg_status" ;;
   esac
   ```
   The first capture records initialization, initial-marker, and coalescing
   writes separately; do not use it for the gate. Keep the verified candidate
   idle with no input during the second, bounded 60-second capture. Inspect
   `idle-measured-fs_usage.log` and the fixed-string result for the real
   `activity.sqlite3`, WAL, and SHM paths. Record both raw-log paths in the Idle
   row. Status 0 means matching path activity was found and its operation type
   must be classified; status 1 means no matching path line; any higher status
   invalidates the run. Mark Pass only after a completed owner run shows zero
   write, create, truncate, `fsync`, or rename activity for all three paths;
   otherwise mark Fail. Data Persistence alone cannot prove this gate, and this
   row remains Owner-assisted pending until that run is recorded.
<a id="owner-workload-protocol"></a>
4. **Workload run protocol — Keyboard-heavy, Mouse-heavy, and Scroll-heavy rows.** Set `evidence_dir="/tmp/apmx-workloads-$(date +%Y%m%d-%H%M%S)"` and create it outside the repository. For every template/tool run, quit any prior test instance, launch the exact executable afresh, capture `ps -p "$app_pid" -o pid=,state=,rss=,%cpu=,command=` to `"$evidence_dir/<workload>-<tool>-pid.txt"`, and proceed only if PID is live and the command equals the executable. Do not combine tools: repeat the complete workload in four fresh 60-second runs—Time Profiler (`<workload>-time-profiler.trace`, CPU summary), System Trace (`<workload>-system-trace.trace`, wakeup summary), Allocations (`<workload>-allocations.trace`, allocation/RSS summary), and `sudo fs_usage -w -f filesys -p "$app_pid" > "$evidence_dir/<workload>-fs_usage.log"` (database, `-wal`, and `-shm` writes). Use `xcrun xctrace record --template '<template>' --time-limit 60s --output "$evidence_dir/<workload>-<template>.trace" --attach "$app_pid"` for each trace run. Record every private evidence path and the extracted aggregate numbers in that workload row.
<a id="owner-keyboard"></a>
5. **Keyboard-heavy — Keyboard-heavy row and Permission/Input matrix rows.** Remove the old Input Monitoring row in **System Settings > Privacy & Security > Input Monitoring**, launch the candidate, explicitly grant access, and record the visible state. For each fresh 60-second run in step 4, type non-sensitive test keys in a local throwaway document at a steady cadence; never record keys or text. Record CPU/wakeups, allocations/RSS, database/`-wal`/`-shm` writes, aggregate dropped signals, and event-tap recovery. Mark Pass only if every run has the verified PID/path, expected aggregate keyboard increase, trace/log evidence, and no unexpected drop or recovery; otherwise mark Fail.
<a id="owner-mouse"></a>
6. **Mouse-heavy — Mouse-heavy row and Permission/Input matrix rows.** With explicit grant, perform repeated primary, secondary, and other button clicks in a non-sensitive local test area for each fresh 60-second run in step 4; repeat the same protocol with a trackpad when available. Record the same CPU/wakeup, allocation/RSS, database/`-wal`/`-shm`, dropped-signal, and recovery evidence under `mouse-*` names. Mark Pass only if every run has verified PID/path, expected aggregate mouse increase, complete evidence, and no unexpected drop or recovery; otherwise mark Fail.
<a id="owner-scroll"></a>
7. **Scroll-heavy — Scroll-heavy row and Permission/Input matrix rows.** With explicit grant, perform direct then inertial scrolling in a non-sensitive local document for each fresh 60-second run in step 4. Separately exercise dragging and held-repeat for 60 seconds each and record those results in the Input matrix. Store the four run artifacts under `scroll-*` names and record the same CPU/wakeup, allocation/RSS, database/`-wal`/`-shm`, dropped-signal, and recovery evidence. Mark Pass only if every run has verified PID/path, expected aggregate scroll increase, complete evidence, and no unexpected drop or recovery; otherwise mark Fail.
<a id="owner-privacy-ui"></a>
8. **Preferences, logs, and aggregate UI — matching privacy rows.** Run `Scripts/verify-preference-privacy.sh` with no arguments so the public entry point owns the complete `ca.horatiu.apmx` defaults export, plist validation and conversion, key-only extraction, non-empty-stream check, and policy verification. Do not feed it from a pipeline. To inspect an already-private plist, use `Scripts/verify-preference-privacy.sh --plist /absolute/private/path.plist`; `--key-list` is reserved for deterministic test fixtures. The verifier permits exactly the four app-authored keys named in the privacy policy plus keys beginning with `NSWindow Frame `; it rejects every other key, including arbitrary `NS*`, and fails closed if any tool or stage fails. Record Pass only on exit 0. Run `log show --style compact --last 10m --predicate 'subsystem == "ca.horatiu.apmx"'` to a private file and record Pass only if every entry is a fixed `ApplicationLogEvent`, otherwise Fail. Visually inspect menu, analytics, and settings and record Pass only if they show aggregate counts/coverage without raw input; otherwise Fail. Put each private evidence path and result in the matching privacy row without copying preference values or raw logs into the repository.
<a id="owner-lifecycle"></a>
9. **Lifecycle — individual lifecycle rows.** With explicit grant and a known open session, run each scenario separately: sleep then wake (expect tap suspension before sleep and recovery after wake); lock then unlock (expect suspension while locked and recovery after unlock); switch user then return (expect no counting while away and recovery on return); log out then log in (expect durable close before logout and a fresh recovery state); change clock forward then restore it (expect no negative/duplicated aggregate coverage); force quit while idle (expect only the owner-accepted coverage tail); and install an upgrade over a prior version (expect preserved valid durable aggregates and recovery). In each matching matrix row record action, observed suspend/boundary/durable/recovery result, and Pass only if it matches the stated expectation; otherwise mark Fail. The idle force-quit coverage-tail exception remains unaccepted until the owner explicitly records acceptance.
<a id="owner-login-accessibility"></a>
10. **Login, appearance, and accessibility — individual matrix rows.** In Login Items, enable launch-at-login and relaunch (expect one enabled APM Explorer login item and launch after login), then disable and relaunch (expect no launch item and no automatic launch). If macOS presents a service denial, deny it and expect an unavailable/denied state; if macOS offers no denied-service path, keep that row Owner-assisted pending. For light, dark, and high contrast, verify that all menu labels and values remain legible. Using keyboard only, verify focus order reaches the status menu, Settings, and each actionable control and that Return/Space activates it. With VoiceOver enabled from **System Settings > Accessibility > VoiceOver** (or Command-F5), verify each menu/control has its expected aggregate-only label/value. Record Pass only for the stated observed outcome, otherwise Fail, in the matching matrix row.
<a id="owner-os-signing"></a>
11. **Operating systems and signing — OS/signing matrix rows.** On macOS 13 hardware and current macOS, repeat every applicable matrix scenario and mark Pass only for observed behavior; mark unavailable hardware accordingly. For Developer ID, run:
   ```sh
   developer_id_archive="$PWD/build/APMExplorer-DeveloperID.xcarchive"
   developer_id_export="$PWD/build/DeveloperID"
   developer_id_options="$PWD/Distribution/DeveloperIDExportOptions.plist"
   notary_profile='<owner-notary-keychain-profile>'
   xcodebuild archive -project APMExplorer.xcodeproj -scheme APMExplorer \
     -archivePath "$developer_id_archive" \
     -destination 'generic/platform=macOS'
   xcodebuild -exportArchive -archivePath "$developer_id_archive" \
     -exportPath "$developer_id_export" \
     -exportOptionsPlist "$developer_id_options"
   candidate="$developer_id_export/APM Explorer.app"
   notary_zip="/tmp/APM-Explorer-DeveloperID.zip"
   codesign --verify --deep --strict --verbose=2 "$candidate"
   Scripts/verify-release-safety.sh "$candidate"
   ditto -c -k --keepParent "$candidate" "$notary_zip"
   xcrun notarytool submit "$notary_zip" --keychain-profile "$notary_profile" --wait
   xcrun stapler staple "$candidate"
   xcrun stapler validate "$candidate"
   spctl --assess --type execute --verbose=4 "$candidate"
   ```
   Record every zero-exit result and private notarization submission ID in the
   Developer ID matrix row; Pass requires every command to succeed. For App
   Store, use an owner-provided export-options plist and API credentials:
   ```sh
   app_store_archive="$PWD/build/APMExplorer-AppStore.xcarchive"
   app_store_export="$PWD/build/AppStore"
   app_store_export_options='/absolute/path/to/OwnerAppStoreExportOptions.plist'
   app_store_package="$app_store_export/APM Explorer.pkg"
   app_store_api_key='<owner-app-store-api-key-id>'
   app_store_api_issuer='<owner-app-store-api-issuer-id>'
   app_store_evidence_dir=$(mktemp -d /tmp/apmx-app-store-evidence.XXXXXX)
   test -f "$app_store_export_options"
   xcodebuild archive -project APMExplorer.xcodeproj -scheme APMExplorer-AppStore \
     -archivePath "$app_store_archive" \
     -destination 'generic/platform=macOS'
   xcodebuild -exportArchive -archivePath "$app_store_archive" \
     -exportPath "$app_store_export" \
     -exportOptionsPlist "$app_store_export_options"
   test -f "$app_store_package"
   xcrun altool --validate-app "$app_store_package" \
     --api-key "$app_store_api_key" --api-issuer "$app_store_api_issuer" \
     > "$app_store_evidence_dir/validate.log" 2>&1
   xcrun altool --upload-app -f "$app_store_package" \
     --api-key "$app_store_api_key" --api-issuer "$app_store_api_issuer" \
     > "$app_store_evidence_dir/upload.log" 2>&1
   ```
   Record archive, export, validation, and upload output in a private evidence
   directory and the App Store matrix row. Pass requires zero exit and the
   validation/upload response to be Accepted. Credentials, the owner-provided
   ExportOptions plist, and App Store submission remain Owner-assisted pending.

## Reproducible command

```sh
Scripts/capture-performance-traces.sh \
  "/path/to/APM Explorer.app" \
  "/tmp/apmx-performance-traces" \
  30s
```

The helper validates the bundle executable and a canonical external output
path, captures into a temporary sibling directory, verifies every TOC target,
and only then moves the complete trace set to the requested final directory.
