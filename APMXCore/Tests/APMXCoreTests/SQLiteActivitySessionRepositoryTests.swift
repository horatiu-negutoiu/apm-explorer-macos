import CSQLite
import Foundation
import XCTest

@testable import APMXCore

final class SQLiteActivitySessionRepositoryTests: XCTestCase {
  private let hour: Int64 = 60 * 60 * 1_000

  func testEmptyDatabaseMigrationAndIdempotentReopen() async throws {
    let fixture = try Fixture()

    _ = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(100)
    )
    _ = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(200)
    )

    let schema = try SQLiteInspection(path: fixture.databaseURL.path)
    XCTAssertEqual(
      try schema.tableNames(),
      ["activity_sessions", "hourly_activity", "schema_metadata"]
    )
    XCTAssertEqual(
      try schema.columns(in: "hourly_activity"),
      ["hour_start_ms", "action_count", "monitored_ms"]
    )
    XCTAssertEqual(
      try schema.columns(in: "activity_sessions"),
      [
        "id", "started_at_ms", "last_activity_at_ms", "ended_at_ms",
        "action_count", "timeout_ms", "end_reason",
      ]
    )
    XCTAssertEqual(
      try schema.metadataValue(for: "schema_version"),
      SQLiteActivitySessionRepository.schemaVersion
    )
    XCTAssertEqual(try schema.pragmaString("journal_mode").lowercased(), "wal")
  }

  func testCoalescedWritesPersistLatestEvidenceAndActionCount() async throws {
    let fixture = try Fixture()
    let id = UUID()
    let store = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(0),
      coalescingMilliseconds: 20
    )

    try await store.save(
      session(id: id, started: 100, lastActivity: 100, actions: 1)
    )
    try await store.save(
      session(id: id, started: 100, lastActivity: 250, actions: 9)
    )

    try await Task.sleep(nanoseconds: 80_000_000)
    try await store.checkHealth()

    let reopened = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(300)
    )
    let recovered = try await reopened.openSession()
    XCTAssertEqual(recovered?.id, id)
    XCTAssertEqual(recovered?.lastActivityAt, instant(250))
    XCTAssertEqual(recovered?.actionCount, 9)
  }

  func testSessionRolloverClosesBeforeWritingItsSuccessor() async throws {
    let fixture = try Fixture()
    let store = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(0),
      coalescingMilliseconds: 60_000
    )
    var open = try session(started: 0, lastActivity: 10, timeout: 100)
    try await store.save(open)
    try await store.flush()

    for index in 1...25 {
      let endedAt = Int64(index) * 1_000
      let closed = try session(
        id: open.id,
        started: open.startedAt.epochMilliseconds,
        lastActivity: open.lastActivityAt.epochMilliseconds,
        ended: endedAt,
        actions: open.actionCount,
        timeout: open.timeout.milliseconds
      )
      let successor = try session(
        started: endedAt,
        lastActivity: endedAt,
        actions: Int64(index),
        timeout: 100
      )
      try await store.save(closed)
      try await store.save(successor)
      try await store.flush()
      open = successor
    }

    let persistedOpen = try await store.openSession()
    XCTAssertEqual(persistedOpen, open)
    try await store.checkHealth()
  }

  func testPendingSessionIsImmediatelyVisibleWithoutForcingAWrite() async throws {
    let fixture = try Fixture()
    let store = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(0),
      coalescingMilliseconds: 500
    )
    let pending = try session(started: 10, lastActivity: 20, actions: 2)

    try await store.save(pending)
    let visible = try await store.sessions(
      overlapping: instant(0),
      through: instant(1_000)
    )

    XCTAssertEqual(visible, [pending])
    XCTAssertEqual(
      try SQLiteInspection(path: fixture.databaseURL.path).sessionCount(),
      0
    )
  }

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

  func testLaterHourlyMutationDoesNotScheduleASecondFlushDeadline() async throws {
    let fixture = try Fixture()
    let scheduler = RecordingFlushScheduler()
    let store = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(0),
      coalescingMilliseconds: 100,
      flushScheduler: scheduler.schedule
    )
    try await store.applyHourlyUpdates([
      try HourlyActivityUpdate(hourStart: instant(0), actionCountIncrement: 1)
    ])
    XCTAssertEqual(scheduler.delays, [100_000_000])

    try await store.applyHourlyUpdates([
      try HourlyActivityUpdate(hourStart: instant(0), actionCountIncrement: 1)
    ])
    XCTAssertEqual(scheduler.delays, [100_000_000])

    try await store.flush()
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

    let pendingOpen = try await store.openSession()
    XCTAssertNil(pendingOpen)
  }

  func testPendingSnapshotOutsideQueryRemovesPersistedVersionFromSessionResults() async throws {
    let fixture = try Fixture()
    let store = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(0),
      coalescingMilliseconds: 60_000
    )
    let persistedOpen = try session(
      started: 0,
      lastActivity: 10,
      actions: 1,
      timeout: 1_000
    )
    try await store.save(persistedOpen)
    try await store.flush()
    let stagedClosed = try session(
      id: persistedOpen.id,
      started: 0,
      lastActivity: 10,
      ended: 100,
      actions: 1,
      timeout: 1_000
    )
    try await store.save(stagedClosed)

    let result = try await store.sessions(
      overlapping: instant(500),
      through: instant(600)
    )

    XCTAssertEqual(result, [])
    XCTAssertEqual(
      try SQLiteInspection(path: fixture.databaseURL.path).sessionCount(),
      1
    )
  }

  func testIntervalQueryReturnsOnlySessionsOverlappingHalfOpenWindow() async throws {
    let fixture = try Fixture()
    let store = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(0)
    )
    let before = try session(started: 0, lastActivity: 10, ended: 100)
    let overlapping = try session(started: 90, lastActivity: 100, ended: 150)
    let open = try session(started: 180, lastActivity: 190, timeout: 20)
    let after = try session(started: 200, lastActivity: 200, ended: 220)
    for value in [before, overlapping, open, after] {
      try await store.save(value)
    }
    try await store.flush()

    let result = try await store.sessions(
      overlapping: instant(100),
      through: instant(200)
    )

    XCTAssertEqual(result.map(\.id), [overlapping.id, open.id])
  }

  func testRecoveryReturnsValidSessionWithoutExtendingStoredLease() async throws {
    let fixture = try Fixture()
    let store = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(0)
    )
    let open = try session(started: 100, lastActivity: 200, timeout: 500)
    try await store.save(open)
    try await store.flush()

    let recovered = try await store.recoverOpenSession(at: instant(699))

    XCTAssertEqual(recovered, open)
    XCTAssertEqual(recovered?.leaseEndsAt, instant(700))
  }

  func testRecoveryClosesExpiredSessionAtStoredLeaseBoundary() async throws {
    let fixture = try Fixture()
    let store = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(0)
    )
    let open = try session(started: 100, lastActivity: 200, timeout: 500)
    try await store.save(open)
    try await store.flush()

    let recovered = try await store.recoverOpenSession(at: instant(5_000))
    let remainingOpenSession = try await store.openSession()
    XCTAssertNil(recovered)
    XCTAssertNil(remainingOpenSession)
    let sessions = try await store.sessions(
      overlapping: instant(0),
      through: instant(5_000)
    )
    XCTAssertEqual(sessions.count, 1)
    XCTAssertEqual(sessions[0].endedAt, instant(700))
    XCTAssertEqual(sessions[0].endReason, .recovery)
  }

  func testStartupRetentionRemovesExpiredClosedSessionsButPreservesRecentAndOpen() async throws {
    let fixture = try Fixture()
    let initial = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(0)
    )
    let expired = try session(
      started: 1 * hour,
      lastActivity: 1 * hour,
      ended: 2 * hour
    )
    let recent = try session(
      started: 190 * hour,
      lastActivity: 190 * hour,
      ended: 191 * hour
    )
    let open = try session(
      started: 195 * hour,
      lastActivity: 195 * hour,
      timeout: hour
    )
    for value in [expired, recent, open] { try await initial.save(value) }
    try await initial.flush()

    let reopened = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(200 * hour)
    )
    let remaining = try await reopened.sessions(
      overlapping: instant(0),
      through: instant(201 * hour)
    )

    XCTAssertEqual(Set(remaining.map(\.id)), Set([recent.id, open.id]))
  }

  func testDailyMaintenanceRunsAtMostOncePerDay() async throws {
    let fixture = try Fixture()
    let store = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(100 * hour)
    )
    let old = try session(started: 1 * hour, lastActivity: 1 * hour, ended: 2 * hour)
    try await store.save(old)
    try await store.flush()

    let beforeDay = try await store.performDailyMaintenanceIfNeeded(
      at: instant(123 * hour)
    )
    let atOneDay = try await store.performDailyMaintenanceIfNeeded(
      at: instant(124 * hour)
    )
    let afterPurge = try await store.performDailyMaintenanceIfNeeded(
      at: instant(125 * hour)
    )
    XCTAssertEqual(beforeDay, 0)
    XCTAssertEqual(atOneDay, 1)
    XCTAssertEqual(afterPurge, 0)
  }

  func testDeletingSummariesClearsPendingAndPersistedDataButNotPreferences() async throws {
    let fixture = try Fixture()
    let suiteName = "SQLiteActivitySessionRepositoryTests.\(UUID().uuidString)"
    let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { preferences.removePersistentDomain(forName: suiteName) }
    preferences.set(true, forKey: "launchAtLogin")

    let store = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(0)
    )
    try await store.save(session(started: 0, lastActivity: 1, ended: 2))
    try await store.flush()
    try await store.save(session(started: 10, lastActivity: 10))
    try await store.applyHourlyUpdates([
      try HourlyActivityUpdate(
        hourStart: instant(0),
        actionCountIncrement: 3,
        monitoredMillisecondsIncrement: 10
      )
    ])

    try await store.deleteAllActivitySummaries()

    let remaining = try await store.sessions(
      overlapping: instant(0),
      through: instant(100)
    )
    let remainingHourly = try await store.hourlyActivity(
      overlapping: instant(0),
      through: instant(hour)
    )
    XCTAssertTrue(remaining.isEmpty)
    XCTAssertEqual(remainingHourly.map(\.coverage), [.unavailable])
    XCTAssertEqual(preferences.object(forKey: "launchAtLogin") as? Bool, true)
  }

  func testHourlyUpdatesSplitCoverageAndAttributeBoundaryActions() async throws {
    let fixture = try Fixture()
    let store = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(0)
    )
    let first = HourlyActivityUpdate.aggregating(
      monitoringFrom: instant(hour - 1_000),
      through: instant(hour + 1_000),
      countedActionAt: instant(hour - 1)
    )
    try await store.save(
      [try session(started: hour - 1_000, lastActivity: hour - 1)],
      applying: first
    )
    try await store.applyHourlyUpdates(
      HourlyActivityUpdate.aggregating(
        monitoringFrom: nil,
        through: nil,
        countedActionAt: instant(hour)
      )
    )

    let points = try await store.hourlyActivity(
      overlapping: instant(0),
      through: instant(3 * hour)
    )

    XCTAssertEqual(points.map(\.coverage), [.partial, .partial, .unavailable])
    XCTAssertEqual(points.map(\.actionCount), [1, 1, nil])
    XCTAssertEqual(points.map(\.monitoredMilliseconds), [1_000, 1_000, nil])
  }

  func testCoverageRepresentsZeroPartialCompleteAndUnavailable() async throws {
    let fixture = try Fixture()
    let store = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(0)
    )
    try await store.applyHourlyUpdates([
      .markingCoverageAvailable(at: instant(0)),
      try HourlyActivityUpdate(
        hourStart: instant(hour),
        monitoredMillisecondsIncrement: 1
      ),
      try HourlyActivityUpdate(
        hourStart: instant(2 * hour),
        monitoredMillisecondsIncrement: hour
      ),
    ])

    let points = try await store.hourlyActivity(
      overlapping: instant(0),
      through: instant(4 * hour)
    )

    XCTAssertEqual(points.map(\.coverage), [.zero, .partial, .complete, .unavailable])
    XCTAssertEqual(points.map(\.actionCount), [0, 0, 0, nil])
  }

  func testVersionOneMigrationDoesNotEstimateHourlyHistoryFromSessions() async throws {
    let fixture = try Fixture()
    _ = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(0)
    )
    let inspection = try SQLiteInspection(path: fixture.databaseURL.path)
    try inspection.execute("DROP TABLE hourly_activity")
    try inspection.execute(
      "UPDATE schema_metadata SET value = 1 WHERE key = 'schema_version'"
    )
    try inspection.execute(
      """
      INSERT INTO activity_sessions (
        id, started_at_ms, last_activity_at_ms, ended_at_ms,
        action_count, timeout_ms, end_reason
      ) VALUES ('00000000-0000-0000-0000-000000000020', 0, 3600000, 7200000, 99, 60000, 3)
      """
    )

    let migrated = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(2 * hour)
    )
    let history = try await migrated.hourlyActivity(
      overlapping: instant(0),
      through: instant(2 * hour)
    )

    XCTAssertEqual(history.map(\.coverage), [.unavailable, .unavailable])
    XCTAssertEqual(try inspection.metadataValue(for: "schema_version"), 2)
    XCTAssertEqual(try inspection.sessionCount(), 1)
  }

  func testHourlyRetentionKeepsOnlyRollingSixtyDays() async throws {
    let fixture = try Fixture()
    let day = 24 * hour
    let initial = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(0)
    )
    try await initial.applyHourlyUpdates([
      try HourlyActivityUpdate(hourStart: instant(0), actionCountIncrement: 1),
      try HourlyActivityUpdate(hourStart: instant(2 * day), actionCountIncrement: 2),
      try HourlyActivityUpdate(hourStart: instant(61 * day), actionCountIncrement: 3),
    ])
    try await initial.flush()

    let reopened = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(61 * day)
    )
    let points = try await reopened.hourlyActivity(
      overlapping: instant(0),
      through: instant(62 * day)
    )

    XCTAssertEqual(points[0].coverage, .unavailable)
    XCTAssertEqual(points[48].actionCount, 2)
    XCTAssertEqual(points[61 * 24].actionCount, 3)
  }

  func testAtomicSessionAndHourlyWriteRollsBackTogether() async throws {
    let fixture = try Fixture()
    let store = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(0)
    )
    try await store.save(try session(started: 0, lastActivity: 1))
    try await store.flush()

    do {
      try await store.save(
        [try session(started: 10, lastActivity: 11)],
        applying: [try HourlyActivityUpdate(
          hourStart: instant(0),
          actionCountIncrement: 1
        )]
      )
      try await store.flush()
      XCTFail("Expected the second open session to violate the unique index")
    } catch { }

    let reopened = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(20)
    )
    let point = try await reopened.hourlyActivity(
      overlapping: instant(0),
      through: instant(hour)
    ).first
    XCTAssertEqual(point?.coverage, .unavailable)
  }

  func testCorruptHourlyAggregateIsPropagated() async throws {
    let fixture = try Fixture()
    _ = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(0)
    )
    let inspection = try SQLiteInspection(path: fixture.databaseURL.path)
    try inspection.execute("PRAGMA ignore_check_constraints = ON")
    try inspection.execute(
      "INSERT INTO hourly_activity VALUES (0, 1, 3600001)"
    )
    let store = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(0)
    )

    do {
      _ = try await store.hourlyActivity(
        overlapping: instant(0),
        through: instant(hour)
      )
      XCTFail("Expected corrupt hourly activity error")
    } catch let error as ActivitySessionStoreError {
      guard case .corruptHourlyActivity = error else {
        return XCTFail("Unexpected store error: \(error)")
      }
    }
  }

  func testNewerSchemaVersionIsReportedWithoutDeletingDatabase() throws {
    let fixture = try Fixture()
    let inspection = try SQLiteInspection(path: fixture.databaseURL.path)
    try inspection.execute(
      "CREATE TABLE schema_metadata (key TEXT PRIMARY KEY NOT NULL, value INTEGER NOT NULL)"
    )
    try inspection.execute(
      "INSERT INTO schema_metadata(key, value) VALUES ('schema_version', 99)"
    )

    XCTAssertThrowsError(
      try SQLiteActivitySessionRepository(
        databaseURL: fixture.databaseURL,
        now: instant(0)
      )
    ) { error in
      XCTAssertEqual(error as? ActivitySessionStoreError, .unsupportedSchemaVersion(99))
    }
    XCTAssertEqual(try inspection.metadataValue(for: "schema_version"), 99)
  }

  func testCorruptPersistedSessionIsPropagated() async throws {
    let fixture = try Fixture()
    _ = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(0)
    )
    let inspection = try SQLiteInspection(path: fixture.databaseURL.path)
    try inspection.execute("PRAGMA ignore_check_constraints = ON")
    try inspection.execute(
      """
      INSERT INTO activity_sessions (
        id, started_at_ms, last_activity_at_ms, ended_at_ms,
        action_count, timeout_ms, end_reason
      ) VALUES ('00000000-0000-0000-0000-000000000014', 0, 0, 10, -1, 1000, 3)
      """
    )
    let store = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(0)
    )

    do {
      _ = try await store.sessions(overlapping: instant(-1), through: instant(100))
      XCTFail("Expected corrupt session error")
    } catch let error as ActivitySessionStoreError {
      guard case .corruptSession = error else {
        return XCTFail("Unexpected store error: \(error)")
      }
    }
  }

  func testActorSerializesConcurrentConnectionUse() async throws {
    let fixture = try Fixture()
    let store = try SQLiteActivitySessionRepository(
      databaseURL: fixture.databaseURL,
      now: instant(0),
      coalescingMilliseconds: 60_000
    )

    var values: [ActivitySession] = []
    for index in 0..<100 {
      let offset = Int64(index) * 10
      values.append(try session(
        started: offset,
        lastActivity: offset,
        ended: offset + 5
      ))
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      for value in values {
        group.addTask {
          try await store.save(value)
        }
      }
      try await group.waitForAll()
    }
    try await store.flush()

    let sessions = try await store.sessions(
      overlapping: instant(-1),
      through: instant(2_000)
    )
    XCTAssertEqual(sessions.count, 100)
    try await store.checkHealth()
  }

  private func instant(_ milliseconds: Int64) -> WallClockInstant {
    .init(epochMilliseconds: milliseconds)
  }

  private func session(
    id: UUID = UUID(),
    started: Int64,
    lastActivity: Int64,
    ended: Int64? = nil,
    actions: Int64 = 1,
    timeout: Int64 = 60_000
  ) throws -> ActivitySession {
    try ActivitySession(
      id: id,
      startedAt: instant(started),
      lastActivityAt: instant(lastActivity),
      endedAt: ended.map(instant),
      actionCount: actions,
      timeout: try SessionTimeout(milliseconds: timeout),
      endReason: ended == nil ? nil : .inactivityTimeout
    )
  }
}

private final class Fixture {
  let directoryURL: URL
  let databaseURL: URL

  init() throws {
    directoryURL = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true
    )
    databaseURL = directoryURL.appendingPathComponent("activity.sqlite3")
  }

  deinit {
    try? FileManager.default.removeItem(at: directoryURL)
  }
}

private final class RecordingFlushScheduler: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedDelays: [UInt64] = []

  var delays: [UInt64] {
    lock.lock()
    defer { lock.unlock() }
    return recordedDelays
  }

  func schedule(
    _ delay: UInt64,
    _ operation: @escaping @Sendable () async -> Void
  ) -> Task<Void, Never> {
    lock.lock()
    recordedDelays.append(delay)
    lock.unlock()
    return Task {}
  }
}

private final class SQLiteInspection {
  private var connection: OpaquePointer?

  init(path: String) throws {
    guard sqlite3_open(path, &connection) == SQLITE_OK else {
      throw InspectionError.sqlite
    }
  }

  deinit { sqlite3_close(connection) }

  func execute(_ sql: String) throws {
    guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
      throw InspectionError.sqlite
    }
  }

  func tableNames() throws -> [String] {
    try strings(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
    )
  }

  func columns(in table: String) throws -> [String] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(connection, "PRAGMA table_info(\(table))", -1, &statement, nil)
      == SQLITE_OK
    else { throw InspectionError.sqlite }
    defer { sqlite3_finalize(statement) }
    var values: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      values.append(String(cString: sqlite3_column_text(statement, 1)))
    }
    return values
  }

  func metadataValue(for key: String) throws -> Int64? {
    try int64(
      "SELECT value FROM schema_metadata WHERE key = '\(key)'"
    )
  }

  func sessionCount() throws -> Int64 {
    try int64("SELECT COUNT(*) FROM activity_sessions") ?? -1
  }

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

  func pragmaString(_ name: String) throws -> String {
    try strings("PRAGMA \(name)").first ?? ""
  }

  func pragmaInt(_ name: String) throws -> Int64 {
    try int64("PRAGMA \(name)") ?? -1
  }

  private func strings(_ sql: String) throws -> [String] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
      throw InspectionError.sqlite
    }
    defer { sqlite3_finalize(statement) }
    var values: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      values.append(String(cString: sqlite3_column_text(statement, 0)))
    }
    return values
  }

  private func int64(_ sql: String) throws -> Int64? {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
      throw InspectionError.sqlite
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    return sqlite3_column_int64(statement, 0)
  }

  private enum InspectionError: Error { case sqlite }
}
