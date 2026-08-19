import CSQLite
import Foundation
import XCTest

@testable import APMXCore

final class PrivacyRegressionTests: XCTestCase {
  private let allowedSessionFields: Set<String> = [
    "id", "startedAt", "lastActivityAt", "endedAt",
    "actionCount", "timeout", "endReason",
  ]
  private let allowedSignalBoundaryFields: Set<String> = [
    "kind", "keyDownPhase", "scrollPhase", "wallTime", "monotonicTime",
  ]
  private let allowedHourlyFields: Set<String> = [
    "hourStart", "actionCount", "monitoredMilliseconds",
  ]

  func testDurableModelContainsOnlyAggregateSessionFields() throws {
    let session = try ActivitySession(
      id: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!,
      startedAt: .init(epochMilliseconds: 1_000),
      lastActivityAt: .init(epochMilliseconds: 2_000),
      endedAt: .init(epochMilliseconds: 3_000),
      actionCount: 4,
      timeout: .oneMinute,
      endReason: .shutdown
    )
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any]
    )

    XCTAssertEqual(Set(object.keys), allowedSessionFields)
    assertNoProhibitedNames(in: object.keys)
  }

  func testPlatformSignalBoundaryCannotRepresentInputPayload() throws {
    let signal = RawActivitySignal(
      kind: .keyDown,
      keyDownPhase: .physical,
      wallTime: .init(epochMilliseconds: 1_000),
      monotonicTime: .init(uptimeMilliseconds: 2_000)
    )
    let keyObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(signal)) as? [String: Any]
    )
    let scrollSignal = RawActivitySignal(
      kind: .scroll,
      scrollPhase: .directBegan,
      wallTime: .init(epochMilliseconds: 1_000),
      monotonicTime: .init(uptimeMilliseconds: 2_000)
    )
    let scrollObject = try XCTUnwrap(
      JSONSerialization.jsonObject(with: JSONEncoder().encode(scrollSignal)) as? [String: Any]
    )
    let representedFields = Set(keyObject.keys).union(scrollObject.keys)

    XCTAssertEqual(representedFields, allowedSignalBoundaryFields)
    assertNoProhibitedNames(in: representedFields)
  }

  func testHourlyDurableModelContainsOnlyAggregateAllowListedFields() throws {
    let aggregate = try HourlyActivityAggregate(
      hourStart: .init(epochMilliseconds: 0),
      actionCount: 42,
      monitoredMilliseconds: 3_000
    )
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(
        with: JSONEncoder().encode(aggregate)
      ) as? [String: Any]
    )

    XCTAssertEqual(Set(object.keys), allowedHourlyFields)
    assertNoProhibitedNames(in: object.keys)
  }

  func testRepresentativeDatabaseHasOnlyAllowListedTablesAndColumns() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databaseURL = directory.appendingPathComponent("privacy.sqlite3")
    let store = try SQLiteActivitySessionRepository(
      databaseURL: databaseURL,
      now: .init(epochMilliseconds: 0)
    )
    try await store.save(ActivitySession(
      id: UUID(),
      startedAt: .init(epochMilliseconds: 100),
      lastActivityAt: .init(epochMilliseconds: 200),
      endedAt: .init(epochMilliseconds: 300),
      actionCount: 7,
      timeout: .oneMinute,
      endReason: .shutdown
    ))
    try await store.flush()

    let database = try PrivacyDatabase(path: databaseURL.path)
    XCTAssertEqual(
      try database.tables(),
      Set(["activity_sessions", "hourly_activity", "schema_metadata"])
    )
    let sessionColumns = try database.columns(in: "activity_sessions")
    XCTAssertEqual(sessionColumns, Set([
      "id", "started_at_ms", "last_activity_at_ms", "ended_at_ms",
      "action_count", "timeout_ms", "end_reason",
    ]))
    XCTAssertEqual(try database.rowCount(in: "activity_sessions"), 1)
    assertNoProhibitedNames(in: sessionColumns)
    let hourlyColumns = try database.columns(in: "hourly_activity")
    XCTAssertEqual(
      hourlyColumns,
      Set(["hour_start_ms", "action_count", "monitored_ms"])
    )
    assertNoProhibitedNames(in: hourlyColumns)
  }

  private func assertNoProhibitedNames<S: Sequence>(
    in names: S,
    file: StaticString = #filePath,
    line: UInt = #line
  ) where S.Element == String {
    let prohibitedFragments = [
      "keycode", "key_code", "text", "character", "coordinate", "delta",
      "application", "window", "clipboard", "event_timestamp", "event_time",
      "input_type", "event_type",
    ]
    for name in names {
      let normalized = name.lowercased()
      XCTAssertFalse(
        prohibitedFragments.contains { normalized.contains($0) },
        "Prohibited privacy field introduced: \(name)",
        file: file,
        line: line
      )
    }
  }
}

private final class PrivacyDatabase {
  private var connection: OpaquePointer?

  init(path: String) throws {
    guard sqlite3_open_v2(path, &connection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      throw DatabaseError.sqlite
    }
  }

  deinit { sqlite3_close(connection) }

  func tables() throws -> Set<String> {
    Set(try strings(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
    ))
  }

  func columns(in table: String) throws -> Set<String> {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(connection, "PRAGMA table_info(\(table))", -1, &statement, nil)
      == SQLITE_OK else { throw DatabaseError.sqlite }
    defer { sqlite3_finalize(statement) }
    var values: Set<String> = []
    while sqlite3_step(statement) == SQLITE_ROW {
      values.insert(String(cString: sqlite3_column_text(statement, 1)))
    }
    return values
  }

  func rowCount(in table: String) throws -> Int64 {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(connection, "SELECT COUNT(*) FROM \(table)", -1, &statement, nil)
      == SQLITE_OK else { throw DatabaseError.sqlite }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw DatabaseError.sqlite }
    return sqlite3_column_int64(statement, 0)
  }

  private func strings(_ sql: String) throws -> [String] {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else {
      throw DatabaseError.sqlite
    }
    defer { sqlite3_finalize(statement) }
    var values: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      values.append(String(cString: sqlite3_column_text(statement, 0)))
    }
    return values
  }

  private enum DatabaseError: Error { case sqlite }
}
