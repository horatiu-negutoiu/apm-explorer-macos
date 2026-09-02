# APMX-16 Profiling and Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce input-path and SQLite overhead, eliminate recurring idle database writes, and add reproducible Apple Silicon release and profiling evidence for APMX-16.

**Architecture:** Keep the existing privacy boundary and serial ingestion executor. Replace its array mailbox with a circular buffer, extend the SQLite actor's non-sliding 500 ms batch to session-plus-hourly mutations, and make permission refresh perform maintenance without checkpointing unchanged monitoring coverage. Validate the arm64 release product with shell gates and record current-host and owner-assisted results separately.

**Tech Stack:** Swift 6, Swift Concurrency actors, Dispatch, SQLite3, XCTest, Xcode/xcodebuild, POSIX shell, codesign, lipo, otool, xctrace.

**Spec:** `docs/superpowers/specs/2026-09-01-apmx-16-profiling-hardening-design.md`

## Global Constraints

- Release architecture is Apple Silicon `arm64` only; Intel and Universal 2 are out of scope.
- The application deployment target remains macOS 13.
- The only application entitlement remains `com.apple.security.app-sandbox`.
- Add no network entitlement, telemetry, analytics SDK, updater, background networking, or app-added crash metadata.
- Raw keys, text, coordinates, deltas, app/window identity, clipboard data, and individual input events never cross the capture privacy boundary.
- The persistence deadline is non-sliding and defaults to exactly 500 ms.
- Protected permissions, VoiceOver, signing-candidate checks, credentials, macOS 13 hardware, and other physical Macs are recorded as owner-assisted or unavailable, never inferred to pass.

---

## File map

- `APMXCore/Sources/APMXCore/SQLiteActivitySessionRepository.swift` — stage and atomically flush session and hourly mutations through one coalescing window.
- `APMXCore/Tests/APMXCoreTests/SQLiteActivitySessionRepositoryTests.swift` — prove delayed atomic durability, non-sliding timing, query flushing, deletion, and failure behavior.
- `APMExplorer/PassiveInputCapture.swift` — implement the circular signal buffer and separate maintenance from monitoring coverage persistence.
- `APMExplorerTests/AppDependenciesTests.swift` — prove mailbox wraparound/drop behavior and zero monitoring mutations during unchanged maintenance refresh.
- `APMExplorer.xcodeproj/project.pbxproj` — make all application configurations arm64-only.
- `Scripts/verify-release-safety.sh` — inspect architecture, runtime flags, entitlements, linked frameworks, and prohibited source integrations.
- `Scripts/capture-performance-traces.sh` — capture repeatable launch, CPU, allocation, persistence, and wakeup traces without committing them.
- `Scripts/test-release.sh` — invoke the new release-safety inspection on the tested app.
- `Documentation/APMX-16-Profiling-and-Manual-Validation.md` — record environment, measurements, gates, matrix outcomes, and exact owner procedures.
- `README.md` — document Apple Silicon support and the APMX-16 validation entry points.

---

### Task 1: Coalesce session and hourly SQLite mutations

**Files:**
- Modify: `APMXCore/Tests/APMXCoreTests/SQLiteActivitySessionRepositoryTests.swift`
- Modify: `APMXCore/Sources/APMXCore/SQLiteActivitySessionRepository.swift`

**Interfaces:**
- Consumes: existing `ActivitySessionRepository.save(_:applying:)`, `applyHourlyUpdates(_:)`, `flush()`, and `hourlyActivity(overlapping:through:)`.
- Produces: one non-sliding pending batch containing `[UUID: ActivitySession]` and `[HourlyActivityUpdate]`; no public protocol change.

- [ ] **Step 1: Write failing atomic-coalescing tests**

Add raw SQLite inspection helpers and these tests:

```swift
func testAtomicSessionAndHourlyUpdatesRemainPendingUntilFlush() async throws {
  let fixture = try Fixture()
  let store = try SQLiteActivitySessionRepository(
    databaseURL: fixture.databaseURL,
    now: instant(0),
    coalescingMilliseconds: 60_000
  )
  let value = try session(started: 10, lastActivity: 20, actions: 2)
  let update = try HourlyActivityUpdate(
    hourStart: instant(0),
    actionCountIncrement: 2,
    monitoredMillisecondsIncrement: 20
  )

  try await store.save([value], applying: [update])

  let beforeFlush = try SQLiteInspection(path: fixture.databaseURL.path)
  XCTAssertEqual(try beforeFlush.sessionCount(), 0)
  XCTAssertEqual(try beforeFlush.hourlyActionCount(at: 0), nil)

  try await store.flush()

  let afterFlush = try SQLiteInspection(path: fixture.databaseURL.path)
  XCTAssertEqual(try afterFlush.sessionCount(), 1)
  XCTAssertEqual(try afterFlush.hourlyActionCount(at: 0), 2)
  XCTAssertEqual(try afterFlush.hourlyMonitoredMilliseconds(at: 0), 20)
}

func testHourlyQueryFlushesPendingAtomicUpdates() async throws {
  let fixture = try Fixture()
  let store = try SQLiteActivitySessionRepository(
    databaseURL: fixture.databaseURL,
    now: instant(0),
    coalescingMilliseconds: 60_000
  )
  try await store.applyHourlyUpdates([
    try HourlyActivityUpdate(
      hourStart: instant(0),
      actionCountIncrement: 3,
      monitoredMillisecondsIncrement: 40
    )
  ])

  let points = try await store.hourlyActivity(
    overlapping: instant(0),
    through: instant(hour)
  )

  XCTAssertEqual(points.first?.actionCount, 3)
  XCTAssertEqual(points.first?.monitoredMilliseconds, 40)
  XCTAssertEqual(
    try SQLiteInspection(path: fixture.databaseURL.path).hourlyActionCount(at: 0),
    3
  )
}

func testDefaultCoalescingWindowIsFiveHundredMilliseconds() {
  XCTAssertEqual(SQLiteActivitySessionRepository.defaultCoalescingMilliseconds, 500)
}

func testPendingClosureHidesPersistedOpenSession() async throws {
  let fixture = try Fixture()
  let store = try SQLiteActivitySessionRepository(
    databaseURL: fixture.databaseURL,
    now: instant(0),
    coalescingMilliseconds: 60_000
  )
  let open = try session(started: 10, lastActivity: 20, actions: 1)
  try await store.save(open)
  try await store.flush()
  let closed = try session(
    id: open.id,
    started: 10,
    lastActivity: 20,
    ended: 30,
    actions: 1
  )

  try await store.save([closed], applying: [])

  XCTAssertNil(try await store.openSession())
}
```

Add these methods to `SQLiteInspection`:

```swift
func hourlyActionCount(at hourStart: Int64) throws -> Int64? {
  try int64(
    "SELECT action_count FROM hourly_activity WHERE hour_start_ms = \(hourStart)"
  )
}

func hourlyMonitoredMilliseconds(at hourStart: Int64) throws -> Int64? {
  try int64(
    "SELECT monitored_ms FROM hourly_activity WHERE hour_start_ms = \(hourStart)"
  )
}
```

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```sh
swift test --package-path APMXCore \
  --filter SQLiteActivitySessionRepositoryTests.testAtomicSessionAndHourlyUpdatesRemainPendingUntilFlush
swift test --package-path APMXCore \
  --filter SQLiteActivitySessionRepositoryTests.testHourlyQueryFlushesPendingAtomicUpdates
```

Expected: the first test fails because `save(_:applying:)` writes immediately; the second demonstrates the current read contract and must be retained while implementation changes.

- [ ] **Step 3: Stage every mutation through the existing deadline**

Add pending hourly state and replace the three write entry points:

```swift
private var pendingSessions: [UUID: ActivitySession] = [:]
private var pendingHourlyUpdates: [HourlyActivityUpdate] = []

public func save(_ session: ActivitySession) throws {
  try stage(sessions: [session], hourlyUpdates: [])
}

public func save(
  _ sessions: [ActivitySession],
  applying hourlyUpdates: [HourlyActivityUpdate]
) throws {
  try stage(sessions: sessions, hourlyUpdates: hourlyUpdates)
}

public func applyHourlyUpdates(_ updates: [HourlyActivityUpdate]) throws {
  try stage(sessions: [], hourlyUpdates: updates)
}

private func stage(
  sessions: [ActivitySession],
  hourlyUpdates: [HourlyActivityUpdate]
) throws {
  try throwStoredFailure()
  guard !sessions.isEmpty || !hourlyUpdates.isEmpty else { return }
  for session in sessions {
    pendingSessions[session.id] = session
  }
  pendingHourlyUpdates.append(contentsOf: hourlyUpdates)
  scheduleFlushIfNeeded()
}
```

Rename `flushPendingSessions()` to `flushPendingMutations()` and make it preserve pending values until the transaction succeeds:

```swift
private func flushPendingMutations() throws {
  guard !pendingSessions.isEmpty || !pendingHourlyUpdates.isEmpty else { return }
  let sessions = Array(pendingSessions.values)
  let hourlyUpdates = pendingHourlyUpdates
  do {
    try database.upsert(sessions, applying: hourlyUpdates)
    pendingSessions.removeAll(keepingCapacity: true)
    pendingHourlyUpdates.removeAll(keepingCapacity: true)
  } catch let error as ActivitySessionStoreError {
    storedFailure = error
    throw error
  }
}
```

Update `flush()` and `runScheduledFlush()` to call `flushPendingMutations()`. Call `try flush()` at the beginning of `hourlyActivity(overlapping:through:)` so analytics reads are current and durable. Clear `pendingHourlyUpdates` in `deleteAllActivitySummaries()`.

Update `openSession()` so a staged closure hides the persisted open row while a
staged successor remains immediately visible:

```swift
public func openSession() throws -> ActivitySession? {
  try throwStoredFailure()
  if let pendingOpen = pendingSessions.values.first(where: \.isOpen) {
    return pendingOpen
  }
  guard let persisted = try database.openSession() else { return nil }
  return pendingSessions[persisted.id] == nil ? persisted : nil
}
```

- [ ] **Step 4: Run repository tests and verify GREEN**

Run:

```sh
swift test --package-path APMXCore \
  --filter SQLiteActivitySessionRepositoryTests
```

Expected: all repository tests pass.

- [ ] **Step 5: Add and verify the non-sliding deadline test**

Add:

```swift
func testLaterHourlyMutationDoesNotExtendFirstFlushDeadline() async throws {
  let fixture = try Fixture()
  let store = try SQLiteActivitySessionRepository(
    databaseURL: fixture.databaseURL,
    now: instant(0),
    coalescingMilliseconds: 100
  )
  try await store.applyHourlyUpdates([
    try HourlyActivityUpdate(hourStart: instant(0), actionCountIncrement: 1)
  ])
  try await Task.sleep(for: .milliseconds(70))
  try await store.applyHourlyUpdates([
    try HourlyActivityUpdate(hourStart: instant(0), actionCountIncrement: 1)
  ])
  try await Task.sleep(for: .milliseconds(70))
  try await store.checkHealth()

  XCTAssertEqual(
    try SQLiteInspection(path: fixture.databaseURL.path).hourlyActionCount(at: 0),
    2
  )
}

func testFailedAtomicBatchRollsBackAndRemainsUnhealthy() async throws {
  let fixture = try Fixture()
  let store = try SQLiteActivitySessionRepository(
    databaseURL: fixture.databaseURL,
    now: instant(0),
    coalescingMilliseconds: 60_000
  )
  let inspection = try SQLiteInspection(path: fixture.databaseURL.path)
  try inspection.execute(
    """
    CREATE TRIGGER reject_hourly_insert
    BEFORE INSERT ON hourly_activity
    BEGIN SELECT RAISE(FAIL, 'forced hourly failure'); END
    """
  )
  try await store.save(
    [try session(started: 10, lastActivity: 20, actions: 1)],
    applying: [try HourlyActivityUpdate(
      hourStart: instant(0),
      actionCountIncrement: 1
    )]
  )

  do {
    try await store.flush()
    XCTFail("Expected the forced SQLite failure")
  } catch {}

  XCTAssertEqual(try inspection.sessionCount(), 0)
  XCTAssertNil(try inspection.hourlyActionCount(at: 0))
  do {
    try await store.checkHealth()
    XCTFail("Expected the stored failure")
  } catch {}
}
```

Run:

```sh
swift test --package-path APMXCore \
  --filter SQLiteActivitySessionRepositoryTests.testLaterHourlyMutationDoesNotExtendFirstFlushDeadline
swift test --package-path APMXCore \
  --filter SQLiteActivitySessionRepositoryTests.testFailedAtomicBatchRollsBackAndRemainsUnhealthy
```

Expected: both pass, proving the second mutation did not create a new 100 ms
deadline and a failed atomic batch never exposes a partial durable result.

- [ ] **Step 6: Commit the persistence batch**

```sh
git add \
  APMXCore/Sources/APMXCore/SQLiteActivitySessionRepository.swift \
  APMXCore/Tests/APMXCoreTests/SQLiteActivitySessionRepositoryTests.swift
git commit -m "perf: coalesce atomic activity persistence"
```

---

### Task 2: Replace the signal array with a circular buffer

**Files:**
- Modify: `APMExplorerTests/AppDependenciesTests.swift`
- Modify: `APMExplorer/PassiveInputCapture.swift`

**Interfaces:**
- Consumes: `RawActivitySignal` and the executor's existing capacity.
- Produces: internal `BoundedActivitySignalBuffer.append(_:) -> Bool` and `removeFirst() -> RawActivitySignal?`.

- [ ] **Step 1: Write the failing wraparound test**

Add:

```swift
func testBoundedSignalBufferPreservesFIFOAcrossWraparound() {
    var buffer = BoundedActivitySignalBuffer(capacity: 3)
    XCTAssertTrue(buffer.append(signal(.keyDown, at: 0)))
    XCTAssertTrue(buffer.append(signal(.mouseButtonDown, at: 1)))
    XCTAssertEqual(buffer.removeFirst()?.kind, .keyDown)
    XCTAssertTrue(buffer.append(scroll(.directBegan, at: 2)))
    XCTAssertTrue(buffer.append(signal(.keyDown, at: 3)))
    XCTAssertFalse(buffer.append(signal(.mouseButtonDown, at: 4)))

    XCTAssertEqual(buffer.removeFirst()?.kind, .mouseButtonDown)
    XCTAssertEqual(buffer.removeFirst()?.kind, .scroll)
    XCTAssertEqual(buffer.removeFirst()?.kind, .keyDown)
    XCTAssertNil(buffer.removeFirst())
}
```

- [ ] **Step 2: Run the app test and verify RED**

Run:

```sh
xcodebuild test \
  -project APMExplorer.xcodeproj \
  -scheme APMExplorer \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  -only-testing:APMExplorerTests/AppDependenciesTests/testBoundedSignalBufferPreservesFIFOAcrossWraparound
```

Expected: compile failure because `BoundedActivitySignalBuffer` does not exist.

- [ ] **Step 3: Implement the circular buffer and connect the executor**

Add before `ActivitySignalIngestionExecutor`:

```swift
struct BoundedActivitySignalBuffer {
    private var storage: [RawActivitySignal?]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
        storage = Array(repeating: nil, count: max(capacity, 1))
    }

    mutating func append(_ signal: RawActivitySignal) -> Bool {
        guard count < storage.count else { return false }
        let index = (head + count) % storage.count
        storage[index] = signal
        count += 1
        return true
    }

    mutating func removeFirst() -> RawActivitySignal? {
        guard count > 0 else { return nil }
        let signal = storage[head]
        storage[head] = nil
        head = (head + 1) % storage.count
        count -= 1
        return signal
    }
}
```

Replace the executor's `capacity` and array properties with:

```swift
private var buffer: BoundedActivitySignalBuffer
```

Initialize it with `buffer = BoundedActivitySignalBuffer(capacity: capacity)`. In `enqueue(_:)`, use `guard buffer.append(signal)` for capacity enforcement. In `takeNextSignal()`, call `buffer.removeFirst()` and set `drainScheduled = false` only when the returned signal is nil.

- [ ] **Step 4: Run mailbox and ingestion tests and verify GREEN**

Run:

```sh
xcodebuild test \
  -project APMExplorer.xcodeproj \
  -scheme APMExplorer \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  -only-testing:APMExplorerTests/AppDependenciesTests/testBoundedSignalBufferPreservesFIFOAcrossWraparound \
  -only-testing:APMExplorerTests/AppDependenciesTests/testBoundedIngestionDropsNewestSignalWhenFull \
  -only-testing:APMExplorerTests/AppDependenciesTests/testIngestionConnectsReducerToSessionEngine
```

Expected: all selected tests pass.

- [ ] **Step 5: Commit the mailbox**

```sh
git add APMExplorer/PassiveInputCapture.swift APMExplorerTests/AppDependenciesTests.swift
git commit -m "perf: make activity mailbox constant time"
```

---

### Task 3: Remove recurring idle monitoring writes

**Files:**
- Modify: `APMExplorerTests/AppDependenciesTests.swift`
- Modify: `APMExplorer/PassiveInputCapture.swift`

**Interfaces:**
- Consumes: `ActivitySignalIngestionExecutor.beginMonitoring()`, event-driven `monitoringUpdates`, and repository daily maintenance.
- Produces: `ActivitySignalIngestionExecutor.performMaintenance()` that schedules retention work without advancing coverage.

- [ ] **Step 1: Write a failing maintenance test**

Extend `RecordingActivityRepository` with `maintenanceCallCount` and increment it in `performDailyMaintenanceIfNeeded`. Add:

```swift
func testMaintenanceDoesNotPersistUnchangedMonitoringCoverage() async throws {
    let clock = AdjustableClock(wall: 0, monotonic: 0)
    let repository = RecordingActivityRepository()
    let ingestion = ActivitySignalIngestionExecutor(
        accumulator: InputActivityAccumulator(),
        repository: repository,
        wallClock: clock,
        monotonicClock: clock,
        startsDraining: false
    )
    ingestion.beginMonitoring()
    try await ingestion.flushPersistence()
    let initialUpdates = await repository.hourlyUpdates

    clock.set(wall: 15_000, monotonic: 15_000)
    ingestion.performMaintenance()
    try await ingestion.flushPersistence()

    let finalUpdates = await repository.hourlyUpdates
    let maintenanceCallCount = await repository.maintenanceCallCount
    XCTAssertEqual(finalUpdates, initialUpdates)
    XCTAssertEqual(maintenanceCallCount, 1)
}
```

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```sh
xcodebuild test \
  -project APMExplorer.xcodeproj \
  -scheme APMExplorer \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  -only-testing:APMExplorerTests/AppDependenciesTests/testMaintenanceDoesNotPersistUnchangedMonitoringCoverage
```

Expected: compile failure because `performMaintenance()` does not exist.

- [ ] **Step 3: Separate maintenance from coverage checkpointing**

Replace `checkpointMonitoring()` with:

```swift
func performMaintenance() {
    queue.sync {
        scheduleMaintenance(at: wallClock.now())
    }
}
```

Change `PassiveInputCaptureModel.refresh()` to:

```swift
func refresh() {
    ingestion.expireSessionIfNeeded()
    ingestion.performMaintenance()
    publishInMemoryState()
    guard !lifecycleSuspended else {
        captureState = .suspended
        return
    }

    permissionState = permissionService.check()
    reconcileCaptureWithPermission()
}
```

Update tests that previously used `checkpointMonitoring()` to advance coverage by enqueuing a counted signal and draining it. Preserve assertions that deletion does not restore pre-deletion coverage and lifecycle gaps are not counted.

- [ ] **Step 4: Run app tests and verify GREEN**

Run:

```sh
xcodebuild test \
  -project APMExplorer.xcodeproj \
  -scheme APMExplorer \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  -only-testing:APMExplorerTests
```

Expected: all app tests pass and repeated maintenance performs no hourly mutation.

- [ ] **Step 5: Commit idle persistence hardening**

```sh
git add APMExplorer/PassiveInputCapture.swift APMExplorerTests/AppDependenciesTests.swift
git commit -m "perf: eliminate recurring idle database writes"
```

---

### Task 4: Enforce and inspect the Apple Silicon release boundary

**Files:**
- Modify: `APMExplorer.xcodeproj/project.pbxproj`
- Create: `Scripts/verify-release-safety.sh`
- Modify: `Scripts/test-release.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: one built `.app` path.
- Produces: `Scripts/verify-release-safety.sh /path/to/APM\ Explorer.app` with exit 0 only for the approved release boundary.

- [ ] **Step 1: Establish the failing gate**

Run:

```sh
Scripts/verify-release-safety.sh /tmp/nonexistent.app
```

Expected: exit 127 because the release-safety script does not exist.

- [ ] **Step 2: Enforce arm64 in all app configurations**

Add `ARCHS = arm64;` to the Debug, App Store Release, and Developer ID Release build settings for the `APMExplorer` target only. Do not change the deployment target or test target architectures.

Verify:

```sh
for configuration in Debug 'App Store Release' 'Developer ID Release'; do
  xcodebuild -showBuildSettings \
    -project APMExplorer.xcodeproj \
    -scheme APMExplorer \
    -configuration "$configuration" |
    sed -n 's/^[[:space:]]*ARCHS = /ARCHS = /p' |
    head -n 1
done
```

Expected: `ARCHS = arm64` three times.

- [ ] **Step 3: Create the release-safety inspector**

Create an executable POSIX shell script with these checks:

```sh
#!/bin/sh
set -eu

app_path=${1:?usage: verify-release-safety.sh /path/to/APM Explorer.app}
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

fail() {
  printf '%s\n' "Release safety verification failed: $1" >&2
  exit 1
}

[ -d "$app_path" ] || fail "missing app bundle $app_path"
info_plist="$app_path/Contents/Info.plist"
executable_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")
executable="$app_path/Contents/MacOS/$executable_name"
[ -x "$executable" ] || fail "missing executable $executable"

architectures=$(lipo -archs "$executable")
[ "$architectures" = "arm64" ] || fail "expected arm64 only, got $architectures"

signature_details=$(codesign -dvv "$app_path" 2>&1)
printf '%s\n' "$signature_details" | grep -q '^flags=.*runtime' \
  || fail "Hardened Runtime flag is missing"

entitlements_file=$(mktemp)
trap 'rm -f "$entitlements_file"' EXIT HUP INT TERM
codesign -d --entitlements :- "$app_path" >"$entitlements_file" 2>/dev/null
plutil -extract com.apple.security.app-sandbox raw "$entitlements_file" |
  grep -qx true || fail "App Sandbox entitlement is missing"
entitlement_keys=$(
  plutil -p "$entitlements_file" |
    sed -n 's/^  "\([^"]*\)".*/\1/p'
)
[ "$entitlement_keys" = "com.apple.security.app-sandbox" ] \
  || fail "unexpected entitlement set: $entitlement_keys"

if otool -L "$executable" |
  grep -Eiq 'Sparkle|Sentry|Telemetry|Mixpanel|FirebaseAnalytics|CFNetwork\.framework|Network\.framework'
then
  fail "prohibited linked analytics, updater, or networking framework"
fi

if rg -n \
  '^[[:space:]]*import[[:space:]]+(Network|CFNetwork)|URLSession|NWConnection|SentrySDK|SUUpdater|SPUUpdater|TelemetryClient|Mixpanel|FirebaseAnalytics|Crashlytics|MXMetricManager|NSSetUncaughtExceptionHandler' \
  "$repository_root/APMExplorer" "$repository_root/APMXCore/Sources"
then
  fail "prohibited networking, analytics, telemetry, or updater integration"
fi

printf '%s\n' "Release safety verified: arm64, Hardened Runtime, sandbox-only, offline."
```

Run `chmod +x Scripts/verify-release-safety.sh`.

- [ ] **Step 4: Connect the inspector to the release gate and README**

After the existing Debug identity check succeeds in `Scripts/test-release.sh`,
build and inspect the Developer ID Release configuration so Debug's
development-only signing allowances are never mistaken for release
entitlements:

```sh
xcodebuild build \
  -project "$repository_root/APMExplorer.xcodeproj" \
  -scheme APMExplorer \
  -configuration 'Developer ID Release' \
  -destination 'generic/platform=macOS'
release_build_settings=$(xcodebuild -showBuildSettings \
  -project "$repository_root/APMExplorer.xcodeproj" \
  -scheme APMExplorer \
  -configuration 'Developer ID Release')
release_target_build_dir=$(printf '%s\n' "$release_build_settings" |
  sed -n 's/^[[:space:]]*TARGET_BUILD_DIR = //p' | head -n 1)
release_wrapper_name=$(printf '%s\n' "$release_build_settings" |
  sed -n 's/^[[:space:]]*WRAPPER_NAME = //p' | head -n 1)
"$repository_root/Scripts/verify-release-safety.sh" \
  "$release_target_build_dir/$release_wrapper_name"
```

Update README requirements to say Apple Silicon is required and add:

````markdown
### Performance and release-safety validation

APMX-16 profiling procedures, measured baselines, and the owner-assisted matrix
are recorded in
[`Documentation/APMX-16-Profiling-and-Manual-Validation.md`](Documentation/APMX-16-Profiling-and-Manual-Validation.md).
Inspect an existing signed app product with:

```sh
Scripts/verify-release-safety.sh "/path/to/APM Explorer.app"
```
````

- [ ] **Step 5: Build and verify the signed Developer ID Release product**

Run:

```sh
xcodebuild build \
  -project APMExplorer.xcodeproj \
  -scheme APMExplorer \
  -configuration 'Developer ID Release' \
  -destination 'generic/platform=macOS'

build_settings=$(xcodebuild -showBuildSettings \
  -project APMExplorer.xcodeproj \
  -scheme APMExplorer \
  -configuration 'Developer ID Release')
target_build_dir=$(printf '%s\n' "$build_settings" |
  sed -n 's/^[[:space:]]*TARGET_BUILD_DIR = //p' | head -n 1)
wrapper_name=$(printf '%s\n' "$build_settings" |
  sed -n 's/^[[:space:]]*WRAPPER_NAME = //p' | head -n 1)
Scripts/verify-release-safety.sh "$target_build_dir/$wrapper_name"
```

Expected: build succeeds and the inspector prints the arm64/sandbox/offline
success line. If release signing is unavailable, record that exact
owner-assisted gap and run the build unsigned plus static build-setting checks;
do not weaken the inspector to accept Debug entitlements.

- [ ] **Step 6: Commit release safety**

```sh
git add \
  APMExplorer.xcodeproj/project.pbxproj \
  Scripts/verify-release-safety.sh \
  Scripts/test-release.sh \
  README.md
git commit -m "build: gate Apple Silicon release safety"
```

---

### Task 5: Add profiling capture and the APMX-16 evidence record

**Files:**
- Create: `Scripts/capture-performance-traces.sh`
- Create: `Documentation/APMX-16-Profiling-and-Manual-Validation.md`
- Modify: `README.md`

**Interfaces:**
- Consumes: app path, new empty output directory, and optional duration.
- Produces: local `.trace` bundles for App Launch, Time Profiler, Allocations, Data Persistence, and System Trace; no traces are committed.

- [ ] **Step 1: Establish the missing profiling helper**

Run:

```sh
Scripts/capture-performance-traces.sh /tmp/nonexistent.app /tmp/apmx-traces 5s
```

Expected: exit 127 because the helper does not exist.

- [ ] **Step 2: Create the trace-capture helper**

Create:

```sh
#!/bin/sh
set -eu

app_path=${1:?usage: capture-performance-traces.sh /path/to/APM Explorer.app output-directory [duration]}
output_directory=${2:?usage: capture-performance-traces.sh /path/to/APM Explorer.app output-directory [duration]}
duration=${3:-30s}

[ -d "$app_path" ] || {
  printf 'Missing app bundle: %s\n' "$app_path" >&2
  exit 1
}
[ ! -e "$output_directory" ] || {
  printf 'Output path already exists: %s\n' "$output_directory" >&2
  exit 1
}
mkdir -p "$output_directory"

record() {
  template=$1
  filename=$2
  xcrun xctrace record \
    --no-prompt \
    --template "$template" \
    --time-limit "$duration" \
    --output "$output_directory/$filename.trace" \
    --launch -- "$app_path"
}

record 'App Launch' app-launch
record 'Time Profiler' time-profiler
record 'Allocations' allocations
record 'Data Persistence' data-persistence
record 'System Trace' system-trace

printf 'Performance traces saved outside the repository: %s\n' "$output_directory"
```

Run `chmod +x Scripts/capture-performance-traces.sh`.

- [ ] **Step 3: Write the evidence document with explicit statuses**

Create the document with these sections and initial facts:

````markdown
# APMX-16 profiling and manual validation

## Engineering gates

| Gate | Target | Result | Evidence |
| --- | --- | --- | --- |
| Idle CPU | Effectively 0%; no fast polling | Measured on current host | System Trace and Time Profiler summary |
| Idle SQLite writes | Zero recurring writes | Measured on current host | Data Persistence trace |
| Inactive UI timer | No one-second timer | Pass by inspection | Five-minute visualization cadence; 15-second permission reconciliation |
| Event callback | No I/O or MainActor hop | Pass by inspection and tests | Privacy-safe factory and bounded mailbox |
| Resident memory | Under 50 MB | Measured on current host | Allocations plus `ps` RSS |
| Menu availability | Under 500 ms | Owner-assisted pending | App Launch trace plus visible status-item check |
| Abnormal action/session loss | At most 500 ms | Pass by design and tests | Non-sliding repository coalescing tests |

## Validation host

- Model: MacBook Pro `Mac15,6`
- Chip: Apple M3 Pro, 11 cores
- Memory: 36 GB
- macOS: 26.6.2 (25G83)
- Xcode: 26.6 (17F113)
- Swift: 6.3.3
- Release architecture: arm64 only

## Automated and static results

Record the exact command, date, pass/fail result, and relevant measurement for
core tests, app tests, release-safety inspection, entitlement inspection,
linked dependencies, source privacy scan, and SQLite schema/content checks.
The privacy subsection must separately record:

- `PrivacyRegressionTests` passing for durable model, schema, and capture data;
- the application preferences domain containing only the allow-listed settings
  keys after a local run;
- unified log entries containing only fixed `ApplicationLogEvent` messages;
- the UI displaying aggregate counts/coverage only;
- no `Crashlytics`, `MXMetricManager`, uncaught-exception handler, or other
  app-added crash metadata integration in production sources.

## Performance procedure and baselines

Record launch, idle, keyboard-heavy, mouse-heavy, and scroll-heavy workloads
separately. For each workload record duration, permission state, trace template,
CPU/wakeups, allocations or RSS, SQLite writes, dropped signals, and event-tap
recovery observations. Mark protected workloads Owner-assisted pending when
Input Monitoring interaction is unavailable.

## Manual matrix

Use only Pass, Fail, Owner-assisted pending, or Hardware unavailable for:
macOS 13/current macOS; fresh/denied/granted/revoked permission; mouse,
trackpad, external keyboard, dragging, held repeat, inertial scroll; sleep/wake,
lock/unlock, user switching, logout/login, clock change, force quit, upgrade;
launch-at-login enabled/disabled/denied; light/dark/high contrast, keyboard
navigation, VoiceOver; App Store and Developer ID candidates.

## Owner-assisted procedures

List exact launch, System Settings, input, lifecycle, appearance, signing, and
evidence-recording steps for every pending row. State that the idle force-quit
coverage tail is an exception requiring owner acceptance because eliminating it
would require periodic durable heartbeat writes.
````

Fill current-host results only from commands and traces actually run. Do not turn the descriptive labels `Measured on current host` into Pass until a numeric or trace observation has been recorded.

- [ ] **Step 4: Capture accessible traces and measurements**

For performance capture, build the signed Debug app with the stable identity
used by the existing permission-test workflow, resolve its product path, then
run:

```sh
Scripts/build-permission-test-app.sh
profile_app_path="$PWD/build/PermissionTestDerivedData/Build/Products/Debug/APM Explorer.app"
trace_root=$(mktemp -d)
Scripts/capture-performance-traces.sh \
  "$profile_app_path" \
  "$trace_root/apmx-baseline" \
  15s
```

Open the generated traces in Instruments and record summary values. Launch the app executable for a 60-second idle RSS sample:

```sh
"$profile_app_path/Contents/MacOS/APM Explorer" &
app_pid=$!
for sample_index in 1 2 3 4 5 6; do
  ps -p "$app_pid" -o rss=,%cpu=
  sleep 10
done
kill "$app_pid"
wait "$app_pid" 2>/dev/null || true
```

Record only observed values in the evidence document. Keep `trace_root` outside the repository.

- [ ] **Step 5: Link the profiling helper from README**

Add:

````markdown
Capture local Instruments traces into a new directory outside the repository:

```sh
Scripts/capture-performance-traces.sh \
  "/path/to/APM Explorer.app" \
  "/tmp/apmx-performance-traces" \
  30s
```

The command creates App Launch, Time Profiler, Allocations, Data Persistence,
and System Trace recordings. Review and summarize them using the APMX-16
evidence document; do not commit the trace bundles.
````

- [ ] **Step 6: Commit profiling assets and evidence**

```sh
git add \
  Scripts/capture-performance-traces.sh \
  Documentation/APMX-16-Profiling-and-Manual-Validation.md \
  README.md
git commit -m "docs: record APMX-16 validation evidence"
```

---

### Task 6: Run the complete gate and reconcile evidence

**Files:**
- Modify if measurements require correction: `Documentation/APMX-16-Profiling-and-Manual-Validation.md`

**Interfaces:**
- Consumes: all implementation tasks.
- Produces: verified source tree and an evidence document that distinguishes passes from owner/hardware gaps.

- [ ] **Step 1: Run the complete portable and unsigned gates**

```sh
swift test --package-path APMXCore
xcodebuild test \
  -project APMExplorer.xcodeproj \
  -scheme APMExplorer \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO
```

Expected: all core, app, and UI tests pass without warnings or failures.

- [ ] **Step 2: Run maintainer release checks when signing is available**

```sh
Scripts/test-release.sh
```

Expected: brand, core, app/UI, stable Input Monitoring identity, architecture, Hardened Runtime, exact entitlements, dependency, and offline checks all pass. If signing is unavailable, preserve the unsigned results and label the signed candidate row Owner-assisted pending.

- [ ] **Step 3: Verify source cleanliness and privacy signatures**

```sh
git diff --check
swift test --package-path APMXCore --filter PrivacyRegressionTests
defaults read ca.horatiu.apmx 2>/dev/null || true
log show --style compact --last 10m \
  --predicate 'subsystem == "ca.horatiu.apmx"' 2>/dev/null || true
rg -n \
  '^[[:space:]]*import[[:space:]]+(Network|CFNetwork)|URLSession|NWConnection|SentrySDK|SUUpdater|SPUUpdater|TelemetryClient|Mixpanel|FirebaseAnalytics|Crashlytics|MXMetricManager|NSSetUncaughtExceptionHandler' \
  APMExplorer APMXCore/Sources || true
git status --short
```

Expected: no whitespace errors, the privacy regression suite passes, any
preferences output contains only allow-listed settings keys, unified log output
contains only fixed lifecycle messages, no prohibited integration matches, and
only intentional evidence edits remain. Record the inspection result without
copying machine-local values into the repository.

- [ ] **Step 4: Reconcile every acceptance row**

For every engineering gate and manual-matrix row, confirm the document says exactly one of Pass, Fail, Owner-assisted pending, or Hardware unavailable and links to an observed command/trace or exact owner procedure. Leave the idle force-quit coverage-tail exception unaccepted unless the owner explicitly accepts it.

- [ ] **Step 5: Commit final measured corrections**

If Task 6 added observed measurements:

```sh
git add Documentation/APMX-16-Profiling-and-Manual-Validation.md
git commit -m "docs: finalize APMX-16 measured results"
```

If the evidence document already matches the observed output exactly, do not create an empty commit.
