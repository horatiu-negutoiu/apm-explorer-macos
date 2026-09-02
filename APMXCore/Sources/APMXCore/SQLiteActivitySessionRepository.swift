import CSQLite
import Foundation

public enum ActivitySessionStoreError: Error, Equatable, Sendable, CustomStringConvertible {
  case couldNotCreateDirectory(String)
  case sqlite(operation: String, code: Int32, message: String)
  case unsupportedSchemaVersion(Int64)
  case corruptSession(String)
  case corruptHourlyActivity(String)
  case invalidInterval

  public var description: String {
    switch self {
    case .couldNotCreateDirectory(let path):
      return "Could not create the activity database directory at \(path)."
    case .sqlite(let operation, let code, let message):
      return "SQLite \(operation) failed (\(code)): \(message)"
    case .unsupportedSchemaVersion(let version):
      return "The activity database uses unsupported schema version \(version)."
    case .corruptSession(let detail):
      return "The activity database contains an invalid session: \(detail)"
    case .corruptHourlyActivity(let detail):
      return "The activity database contains an invalid hourly aggregate: \(detail)"
    case .invalidInterval:
      return "The session query interval must have a positive duration."
    }
  }
}

/// A single-connection SQLite store for the app's privacy-safe session summaries.
///
/// The actor owns both the connection and the in-memory write buffer. Calls to
/// `save(_:)` update the buffer immediately and schedule a transactional flush
/// no later than `coalescingMilliseconds` after the first pending change.
typealias SQLiteRepositoryFlushScheduler = @Sendable (
  UInt64,
  @escaping @Sendable () async -> Void
) -> Task<Void, Never>

public actor SQLiteActivitySessionRepository:
  ActivitySessionRepository,
  ActivitySessionRepositoryFailureReporting
{
  public static let schemaVersion: Int64 = 2
  public static let defaultRetentionMilliseconds: Int64 = 48 * 60 * 60 * 1_000
  public static let defaultHourlyRetentionMilliseconds: Int64 = 60 * 24 * 60 * 60 * 1_000
  public static let defaultMaintenanceIntervalMilliseconds: Int64 = 24 * 60 * 60 * 1_000
  public static let defaultCoalescingMilliseconds: UInt64 = 500

  private enum MetadataKey {
    static let schemaVersion = "schema_version"
    static let lastRetentionPurge = "last_retention_purge_ms"
  }

  private let database: SQLiteDatabase
  private let retentionMilliseconds: Int64
  private let hourlyRetentionMilliseconds: Int64
  private let maintenanceIntervalMilliseconds: Int64
  private let coalescingNanoseconds: UInt64
  private let flushScheduler: SQLiteRepositoryFlushScheduler
  public nonisolated let persistenceFailures: AsyncStream<ActivitySessionStoreError>
  private let persistenceFailureContinuation:
    AsyncStream<ActivitySessionStoreError>.Continuation
  private var pendingSessions: [UUID: ActivitySession] = [:]
  private var pendingHourlyUpdates: [HourlyActivityUpdate] = []
  private var scheduledFlush: Task<Void, Never>?
  private var storedFailure: ActivitySessionStoreError?
  private var lastRetentionPurgeAt: WallClockInstant

  public init(
    databaseURL: URL,
    now: WallClockInstant = SystemWallClock().now(),
    retentionMilliseconds: Int64 = defaultRetentionMilliseconds,
    hourlyRetentionMilliseconds: Int64 = defaultHourlyRetentionMilliseconds,
    maintenanceIntervalMilliseconds: Int64 = defaultMaintenanceIntervalMilliseconds,
    coalescingMilliseconds: UInt64 = defaultCoalescingMilliseconds
  ) throws {
    try self.init(
      databaseURL: databaseURL,
      now: now,
      retentionMilliseconds: retentionMilliseconds,
      hourlyRetentionMilliseconds: hourlyRetentionMilliseconds,
      maintenanceIntervalMilliseconds: maintenanceIntervalMilliseconds,
      coalescingMilliseconds: coalescingMilliseconds,
      flushScheduler: { delay, operation in
        Task {
          if delay > 0 {
            try? await Task.sleep(nanoseconds: delay)
          }
          guard !Task.isCancelled else { return }
          await operation()
        }
      }
    )
  }

  init(
    databaseURL: URL,
    now: WallClockInstant,
    retentionMilliseconds: Int64 = defaultRetentionMilliseconds,
    hourlyRetentionMilliseconds: Int64 = defaultHourlyRetentionMilliseconds,
    maintenanceIntervalMilliseconds: Int64 = defaultMaintenanceIntervalMilliseconds,
    coalescingMilliseconds: UInt64,
    flushScheduler: @escaping SQLiteRepositoryFlushScheduler
  ) throws {
    let database = try SQLiteDatabase(path: databaseURL.path)
    try database.migrate()
    try database.purgeClosedSessions(
      endingBefore: now.advanced(byMilliseconds: -retentionMilliseconds)
    )
    try database.purgeHourlyActivity(
      startingBefore: Self.retentionHourCutoff(
        now: now,
        retentionMilliseconds: hourlyRetentionMilliseconds
      )
    )
    try database.setMetadata(now.epochMilliseconds, for: MetadataKey.lastRetentionPurge)

    self.database = database
    self.retentionMilliseconds = retentionMilliseconds
    self.hourlyRetentionMilliseconds = hourlyRetentionMilliseconds
    self.maintenanceIntervalMilliseconds = maintenanceIntervalMilliseconds
    let (nanoseconds, overflow) = coalescingMilliseconds.multipliedReportingOverflow(by: 1_000_000)
    self.coalescingNanoseconds = overflow ? UInt64.max : nanoseconds
    self.flushScheduler = flushScheduler
    let failureChannel = AsyncStream<ActivitySessionStoreError>.makeStream(
      bufferingPolicy: .bufferingNewest(1)
    )
    self.persistenceFailures = failureChannel.stream
    self.persistenceFailureContinuation = failureChannel.continuation
    self.lastRetentionPurgeAt = now
  }

  deinit {
    persistenceFailureContinuation.finish()
  }

  /// Returns the sandbox-friendly Application Support location used by the app.
  /// The directory is created, but no database is opened by this helper.
  public static func applicationSupportDatabaseURL(
    applicationIdentifier: String,
    fileManager: FileManager = .default
  ) throws -> URL {
    let base = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = base.appendingPathComponent(applicationIdentifier, isDirectory: true)
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      throw ActivitySessionStoreError.couldNotCreateDirectory(directory.path)
    }
    return directory.appendingPathComponent("activity.sqlite3", isDirectory: false)
  }

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

  public func flush() throws {
    scheduledFlush?.cancel()
    scheduledFlush = nil
    try flushPendingMutations()
    try throwStoredFailure()
  }

  public func checkHealth() throws {
    try throwStoredFailure()
  }

  public func openSession() throws -> ActivitySession? {
    try throwStoredFailure()
    if let pendingOpen = pendingSessions.values.first(where: \.isOpen) {
      return pendingOpen
    }
    guard let persisted = try database.openSession() else { return nil }
    return pendingSessions[persisted.id] == nil ? persisted : nil
  }

  /// Returns a still-valid open session, or durably closes an expired one at
  /// its original stored lease boundary. Recovery never grants a new timeout.
  public func recoverOpenSession(at now: WallClockInstant) throws -> ActivitySession? {
    try flush()
    guard var session = try database.openSession() else { return nil }
    guard now < session.leaseEndsAt else {
      session.endedAt = session.leaseEndsAt
      session.endReason = .recovery
      try database.upsert([session])
      return nil
    }
    return session
  }

  public func sessions(
    overlapping intervalStart: WallClockInstant,
    through intervalEnd: WallClockInstant
  ) throws -> [ActivitySession] {
    try throwStoredFailure()
    guard intervalEnd > intervalStart else {
      throw ActivitySessionStoreError.invalidInterval
    }

    var sessionsByID = Dictionary(
      uniqueKeysWithValues: try database.sessions(
        overlapping: intervalStart,
        through: intervalEnd
      ).map { ($0.id, $0) }
    )
    for sessionID in pendingSessions.keys {
      sessionsByID.removeValue(forKey: sessionID)
    }
    for session in pendingSessions.values
    where session.overlaps(start: intervalStart, end: intervalEnd) {
      sessionsByID[session.id] = session
    }
    return sessionsByID.values.sorted {
      if $0.startedAt == $1.startedAt { return $0.id.uuidString < $1.id.uuidString }
      return $0.startedAt < $1.startedAt
    }
  }

  public func hourlyActivity(
    overlapping intervalStart: WallClockInstant,
    through intervalEnd: WallClockInstant
  ) throws -> [HourlyActivityPoint] {
    try flush()
    guard intervalEnd > intervalStart else {
      throw ActivitySessionStoreError.invalidInterval
    }
    let firstHour = HourlyActivityAggregate.hourStart(containing: intervalStart)
    let aggregates = try database.hourlyActivity(
      startingAt: firstHour,
      before: intervalEnd
    )
    let byHour = Dictionary(uniqueKeysWithValues: aggregates.map {
      ($0.hourStart.epochMilliseconds, $0)
    })
    var points: [HourlyActivityPoint] = []
    var hour = firstHour
    while hour < intervalEnd {
      points.append(HourlyActivityPoint(
        hourStart: hour,
        aggregate: byHour[hour.epochMilliseconds]
      ))
      hour = hour.advanced(byMilliseconds: HourlyActivityAggregate.hourMilliseconds)
    }
    return points
  }

  public func purgeExpiredClosedSessions(at now: WallClockInstant) throws -> Int {
    try flush()
    let deletedSessions = try database.purgeClosedSessions(
      endingBefore: now.advanced(byMilliseconds: -retentionMilliseconds)
    )
    let deletedHours = try database.purgeHourlyActivity(
      startingBefore: Self.retentionHourCutoff(
        now: now,
        retentionMilliseconds: hourlyRetentionMilliseconds
      )
    )
    try database.setMetadata(now.epochMilliseconds, for: MetadataKey.lastRetentionPurge)
    lastRetentionPurgeAt = now
    return deletedSessions + deletedHours
  }

  public func performDailyMaintenanceIfNeeded(at now: WallClockInstant) throws -> Int {
    try throwStoredFailure()
    guard
      now.epochMilliseconds >= lastRetentionPurgeAt.epochMilliseconds,
      now.epochMilliseconds - lastRetentionPurgeAt.epochMilliseconds
        >= maintenanceIntervalMilliseconds
    else {
      return 0
    }
    return try purgeExpiredClosedSessions(at: now)
  }

  public func deleteAllActivitySummaries() throws {
    scheduledFlush?.cancel()
    scheduledFlush = nil
    pendingSessions.removeAll(keepingCapacity: false)
    pendingHourlyUpdates.removeAll(keepingCapacity: false)
    do {
      try database.deleteAllActivity()
      storedFailure = nil
    } catch let error as ActivitySessionStoreError {
      storedFailure = error
      throw error
    }
  }

  private func scheduleFlushIfNeeded() {
    guard scheduledFlush == nil else { return }
    let delay = coalescingNanoseconds
    scheduledFlush = flushScheduler(delay) { [weak self] in
      await self?.runScheduledFlush()
    }
  }

  private func runScheduledFlush() {
    scheduledFlush = nil
    do {
      try flushPendingMutations()
    } catch let error as ActivitySessionStoreError {
      recordFailure(error)
    } catch {
      recordFailure(.corruptSession(String(describing: error)))
    }
  }

  private func flushPendingMutations() throws {
    guard !pendingSessions.isEmpty || !pendingHourlyUpdates.isEmpty else { return }
    let sessions = Array(pendingSessions.values)
    let hourlyUpdates = pendingHourlyUpdates
    do {
      try database.upsert(sessions, applying: hourlyUpdates)
      pendingSessions.removeAll(keepingCapacity: true)
      pendingHourlyUpdates.removeAll(keepingCapacity: true)
    } catch let error as ActivitySessionStoreError {
      recordFailure(error)
      throw error
    }
  }

  private func recordFailure(_ error: ActivitySessionStoreError) {
    guard storedFailure == nil else { return }
    storedFailure = error
    persistenceFailureContinuation.yield(error)
  }

  private func throwStoredFailure() throws {
    if let storedFailure { throw storedFailure }
  }

  private static func retentionHourCutoff(
    now: WallClockInstant,
    retentionMilliseconds: Int64
  ) -> WallClockInstant {
    HourlyActivityAggregate.hourStart(
      containing: now.advanced(byMilliseconds: -retentionMilliseconds)
    )
  }
}

private extension ActivitySession {
  func overlaps(start: WallClockInstant, end: WallClockInstant) -> Bool {
    let effectiveEnd = endedAt ?? leaseEndsAt
    return startedAt < end && effectiveEnd > start
  }
}

private final class SQLiteDatabase {
  private static let transientDestructor = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
  )

  private var connection: OpaquePointer?

  init(path: String) throws {
    var connection: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    let result = sqlite3_open_v2(path, &connection, flags, nil)
    guard result == SQLITE_OK, let connection else {
      let message = connection.map { String(cString: sqlite3_errmsg($0)) }
        ?? "Could not allocate a SQLite connection."
      if let connection { sqlite3_close(connection) }
      throw ActivitySessionStoreError.sqlite(
        operation: "open",
        code: result,
        message: message
      )
    }
    self.connection = connection

    do {
      try execute("PRAGMA journal_mode = WAL", operation: "enable WAL")
      try execute("PRAGMA synchronous = NORMAL", operation: "set synchronous mode")
      try execute("PRAGMA busy_timeout = 5000", operation: "set busy timeout")
    } catch {
      sqlite3_close(connection)
      self.connection = nil
      throw error
    }
  }

  deinit {
    if let connection { sqlite3_close(connection) }
  }

  func migrate() throws {
    try transaction {
      try execute(
        """
        CREATE TABLE IF NOT EXISTS schema_metadata (
          key TEXT PRIMARY KEY NOT NULL,
          value INTEGER NOT NULL
        )
        """,
        operation: "create schema metadata"
      )

      let version = try metadata(for: "schema_version") ?? 0
      guard version <= SQLiteActivitySessionRepository.schemaVersion else {
        throw ActivitySessionStoreError.unsupportedSchemaVersion(version)
      }

      if version < 1 {
        try execute(
          """
          CREATE TABLE activity_sessions (
            id TEXT PRIMARY KEY NOT NULL,
            started_at_ms INTEGER NOT NULL,
            last_activity_at_ms INTEGER NOT NULL,
            ended_at_ms INTEGER,
            action_count INTEGER NOT NULL,
            timeout_ms INTEGER NOT NULL,
            end_reason INTEGER,
            CHECK (last_activity_at_ms >= started_at_ms),
            CHECK (ended_at_ms IS NULL OR ended_at_ms >= last_activity_at_ms),
            CHECK (action_count >= 0),
            CHECK (timeout_ms > 0),
            CHECK ((ended_at_ms IS NULL) = (end_reason IS NULL))
          )
          """,
          operation: "create activity sessions"
        )
        try execute(
          "CREATE INDEX activity_sessions_started_at ON activity_sessions(started_at_ms)",
          operation: "index session starts"
        )
        try execute(
          "CREATE INDEX activity_sessions_ended_at ON activity_sessions(ended_at_ms)",
          operation: "index session ends"
        )
        try execute(
          """
          CREATE UNIQUE INDEX activity_sessions_single_open
          ON activity_sessions((ended_at_ms IS NULL))
          WHERE ended_at_ms IS NULL
          """,
          operation: "index open session"
        )
        try setMetadata(
          1,
          for: "schema_version"
        )
      }

      if version < 2 {
        try execute(
          """
          CREATE TABLE hourly_activity (
            hour_start_ms INTEGER PRIMARY KEY NOT NULL,
            action_count INTEGER NOT NULL DEFAULT 0,
            monitored_ms INTEGER NOT NULL DEFAULT 0,
            CHECK (hour_start_ms % 3600000 = 0),
            CHECK (action_count >= 0),
            CHECK (monitored_ms >= 0 AND monitored_ms <= 3600000)
          )
          """,
          operation: "create hourly activity"
        )
        try setMetadata(
          SQLiteActivitySessionRepository.schemaVersion,
          for: "schema_version"
        )
      }
    }
  }

  func upsert(_ sessions: [ActivitySession]) throws {
    guard !sessions.isEmpty else { return }
    // A single transaction can contain both the closure of the previous
    // session and the start of its successor. Close rows first so the partial
    // unique index never observes two open sessions, regardless of the
    // dictionary order used by the coalescing buffer.
    let orderedSessions = sessions.sorted {
      if $0.isOpen != $1.isOpen { return !$0.isOpen }
      if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
      return $0.id.uuidString < $1.id.uuidString
    }
    try transaction {
      let statement = try prepare(
        """
        INSERT INTO activity_sessions (
          id, started_at_ms, last_activity_at_ms, ended_at_ms,
          action_count, timeout_ms, end_reason
        ) VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
          started_at_ms = excluded.started_at_ms,
          last_activity_at_ms = excluded.last_activity_at_ms,
          ended_at_ms = excluded.ended_at_ms,
          action_count = excluded.action_count,
          timeout_ms = excluded.timeout_ms,
          end_reason = excluded.end_reason
        """,
        operation: "prepare session upsert"
      )
      defer { sqlite3_finalize(statement) }

      for session in orderedSessions {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        try bind(session.id.uuidString, at: 1, to: statement, operation: "bind session id")
        try bind(session.startedAt.epochMilliseconds, at: 2, to: statement)
        try bind(session.lastActivityAt.epochMilliseconds, at: 3, to: statement)
        try bind(session.endedAt?.epochMilliseconds, at: 4, to: statement)
        try bind(session.actionCount, at: 5, to: statement)
        try bind(session.timeout.milliseconds, at: 6, to: statement)
        try bind(session.endReason.map { Int64($0.rawValue) }, at: 7, to: statement)
        try stepDone(statement, operation: "write session summary")
      }
    }
  }

  func upsert(
    _ sessions: [ActivitySession],
    applying hourlyUpdates: [HourlyActivityUpdate]
  ) throws {
    try transaction {
      let orderedSessions = sessions.sorted {
        if $0.isOpen != $1.isOpen { return !$0.isOpen }
        if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
        return $0.id.uuidString < $1.id.uuidString
      }
      try upsertSessionsInCurrentTransaction(orderedSessions)
      try applyHourlyUpdatesInCurrentTransaction(hourlyUpdates)
    }
  }

  func applyHourlyUpdates(_ updates: [HourlyActivityUpdate]) throws {
    guard !updates.isEmpty else { return }
    try transaction {
      try applyHourlyUpdatesInCurrentTransaction(updates)
    }
  }

  func hourlyActivity(
    startingAt start: WallClockInstant,
    before end: WallClockInstant
  ) throws -> [HourlyActivityAggregate] {
    let statement = try prepare(
      """
      SELECT hour_start_ms, action_count, monitored_ms
      FROM hourly_activity
      WHERE hour_start_ms >= ? AND hour_start_ms < ?
      ORDER BY hour_start_ms
      """,
      operation: "prepare hourly activity query"
    )
    defer { sqlite3_finalize(statement) }
    try bind(start.epochMilliseconds, at: 1, to: statement)
    try bind(end.epochMilliseconds, at: 2, to: statement)
    var values: [HourlyActivityAggregate] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { return values }
      guard result == SQLITE_ROW else {
        throw sqliteError(operation: "query hourly activity", code: result)
      }
      do {
        values.append(try HourlyActivityAggregate(
          hourStart: .init(epochMilliseconds: sqlite3_column_int64(statement, 0)),
          actionCount: sqlite3_column_int64(statement, 1),
          monitoredMilliseconds: sqlite3_column_int64(statement, 2)
        ))
      } catch {
        throw ActivitySessionStoreError.corruptHourlyActivity(
          String(describing: error)
        )
      }
    }
  }

  func openSession() throws -> ActivitySession? {
    let statement = try prepare(
      """
      SELECT id, started_at_ms, last_activity_at_ms, ended_at_ms,
             action_count, timeout_ms, end_reason
      FROM activity_sessions
      WHERE ended_at_ms IS NULL
      LIMIT 1
      """,
      operation: "prepare open-session recovery"
    )
    defer { sqlite3_finalize(statement) }
    let result = sqlite3_step(statement)
    if result == SQLITE_DONE { return nil }
    guard result == SQLITE_ROW else {
      throw sqliteError(operation: "read open session", code: result)
    }
    return try decodeSession(from: statement)
  }

  func sessions(
    overlapping start: WallClockInstant,
    through end: WallClockInstant
  ) throws -> [ActivitySession] {
    let statement = try prepare(
      """
      SELECT id, started_at_ms, last_activity_at_ms, ended_at_ms,
             action_count, timeout_ms, end_reason
      FROM activity_sessions
      WHERE started_at_ms < ?
        AND COALESCE(ended_at_ms, last_activity_at_ms + timeout_ms) > ?
      ORDER BY started_at_ms, id
      """,
      operation: "prepare interval query"
    )
    defer { sqlite3_finalize(statement) }
    try bind(end.epochMilliseconds, at: 1, to: statement)
    try bind(start.epochMilliseconds, at: 2, to: statement)

    var sessions: [ActivitySession] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { return sessions }
      guard result == SQLITE_ROW else {
        throw sqliteError(operation: "query session interval", code: result)
      }
      sessions.append(try decodeSession(from: statement))
    }
  }

  @discardableResult
  func purgeClosedSessions(endingBefore cutoff: WallClockInstant) throws -> Int {
    let statement = try prepare(
      "DELETE FROM activity_sessions WHERE ended_at_ms IS NOT NULL AND ended_at_ms < ?",
      operation: "prepare retention purge"
    )
    defer { sqlite3_finalize(statement) }
    try bind(cutoff.epochMilliseconds, at: 1, to: statement)
    try stepDone(statement, operation: "purge expired sessions")
    return Int(sqlite3_changes(requiredConnection))
  }

  @discardableResult
  func purgeHourlyActivity(startingBefore cutoff: WallClockInstant) throws -> Int {
    let statement = try prepare(
      "DELETE FROM hourly_activity WHERE hour_start_ms < ?",
      operation: "prepare hourly retention purge"
    )
    defer { sqlite3_finalize(statement) }
    try bind(cutoff.epochMilliseconds, at: 1, to: statement)
    try stepDone(statement, operation: "purge expired hourly activity")
    return Int(sqlite3_changes(requiredConnection))
  }

  func deleteAllActivity() throws {
    try transaction {
      try execute("DELETE FROM activity_sessions", operation: "delete session summaries")
      try execute("DELETE FROM hourly_activity", operation: "delete hourly aggregates")
    }
  }

  private func upsertSessionsInCurrentTransaction(
    _ sessions: [ActivitySession]
  ) throws {
    guard !sessions.isEmpty else { return }
    let statement = try prepare(
      """
      INSERT INTO activity_sessions (
        id, started_at_ms, last_activity_at_ms, ended_at_ms,
        action_count, timeout_ms, end_reason
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        started_at_ms = excluded.started_at_ms,
        last_activity_at_ms = excluded.last_activity_at_ms,
        ended_at_ms = excluded.ended_at_ms,
        action_count = excluded.action_count,
        timeout_ms = excluded.timeout_ms,
        end_reason = excluded.end_reason
      """,
      operation: "prepare atomic session upsert"
    )
    defer { sqlite3_finalize(statement) }
    for session in sessions {
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
      try bind(session.id.uuidString, at: 1, to: statement, operation: "bind session id")
      try bind(session.startedAt.epochMilliseconds, at: 2, to: statement)
      try bind(session.lastActivityAt.epochMilliseconds, at: 3, to: statement)
      try bind(session.endedAt?.epochMilliseconds, at: 4, to: statement)
      try bind(session.actionCount, at: 5, to: statement)
      try bind(session.timeout.milliseconds, at: 6, to: statement)
      try bind(session.endReason.map { Int64($0.rawValue) }, at: 7, to: statement)
      try stepDone(statement, operation: "write atomic session summary")
    }
  }

  private func applyHourlyUpdatesInCurrentTransaction(
    _ updates: [HourlyActivityUpdate]
  ) throws {
    guard !updates.isEmpty else { return }
    var merged: [Int64: (actions: Int64, monitored: Int64)] = [:]
    for update in updates {
      guard HourlyActivityAggregate.isHourAligned(update.hourStart) else {
        throw ActivitySessionStoreError.corruptHourlyActivity("unaligned update hour")
      }
      var value = merged[update.hourStart.epochMilliseconds, default: (0, 0)]
      value.actions = value.actions.addingClamped(update.actionCountIncrement)
      value.monitored = value.monitored.addingClamped(
        update.monitoredMillisecondsIncrement
      )
      merged[update.hourStart.epochMilliseconds] = value
    }

    let statement = try prepare(
      """
      INSERT INTO hourly_activity (hour_start_ms, action_count, monitored_ms)
      VALUES (?, ?, MIN(?, 3600000))
      ON CONFLICT(hour_start_ms) DO UPDATE SET
        action_count = CASE
          WHEN hourly_activity.action_count > 9223372036854775807 - excluded.action_count
            THEN 9223372036854775807
          ELSE hourly_activity.action_count + excluded.action_count
        END,
        monitored_ms = MIN(3600000, hourly_activity.monitored_ms + excluded.monitored_ms)
      """,
      operation: "prepare hourly activity update"
    )
    defer { sqlite3_finalize(statement) }
    for hourStart in merged.keys.sorted() {
      let value = merged[hourStart]!
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
      try bind(hourStart, at: 1, to: statement)
      try bind(value.actions, at: 2, to: statement)
      try bind(value.monitored, at: 3, to: statement)
      try stepDone(statement, operation: "update hourly activity")
    }
  }

  func metadata(for key: String) throws -> Int64? {
    let statement = try prepare(
      "SELECT value FROM schema_metadata WHERE key = ?",
      operation: "prepare metadata read"
    )
    defer { sqlite3_finalize(statement) }
    try bind(key, at: 1, to: statement, operation: "bind metadata key")
    let result = sqlite3_step(statement)
    if result == SQLITE_DONE { return nil }
    guard result == SQLITE_ROW else {
      throw sqliteError(operation: "read metadata", code: result)
    }
    return sqlite3_column_int64(statement, 0)
  }

  func setMetadata(_ value: Int64, for key: String) throws {
    let statement = try prepare(
      """
      INSERT INTO schema_metadata(key, value) VALUES (?, ?)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value
      """,
      operation: "prepare metadata write"
    )
    defer { sqlite3_finalize(statement) }
    try bind(key, at: 1, to: statement, operation: "bind metadata key")
    try bind(value, at: 2, to: statement)
    try stepDone(statement, operation: "write metadata")
  }

  private var requiredConnection: OpaquePointer {
    precondition(connection != nil, "SQLite connection used after close")
    return connection!
  }

  private func decodeSession(from statement: OpaquePointer) throws -> ActivitySession {
    guard let idText = sqlite3_column_text(statement, 0) else {
      throw ActivitySessionStoreError.corruptSession("missing id")
    }
    let idString = String(cString: idText)
    guard let id = UUID(uuidString: idString) else {
      throw ActivitySessionStoreError.corruptSession("invalid id \(idString)")
    }

    let endedAt: WallClockInstant? = sqlite3_column_type(statement, 3) == SQLITE_NULL
      ? nil
      : WallClockInstant(epochMilliseconds: sqlite3_column_int64(statement, 3))
    let endReason: SessionEndReason?
    if sqlite3_column_type(statement, 6) == SQLITE_NULL {
      endReason = nil
    } else {
      let rawReason = sqlite3_column_int(statement, 6)
      guard let decoded = SessionEndReason(rawValue: Int(rawReason)) else {
        throw ActivitySessionStoreError.corruptSession("unknown end reason \(rawReason)")
      }
      endReason = decoded
    }

    do {
      return try ActivitySession(
        id: id,
        startedAt: .init(epochMilliseconds: sqlite3_column_int64(statement, 1)),
        lastActivityAt: .init(epochMilliseconds: sqlite3_column_int64(statement, 2)),
        endedAt: endedAt,
        actionCount: sqlite3_column_int64(statement, 4),
        timeout: try SessionTimeout(
          milliseconds: sqlite3_column_int64(statement, 5)
        ),
        endReason: endReason
      )
    } catch {
      throw ActivitySessionStoreError.corruptSession(String(describing: error))
    }
  }

  private func transaction(_ body: () throws -> Void) throws {
    try execute("BEGIN IMMEDIATE", operation: "begin transaction")
    do {
      try body()
      try execute("COMMIT", operation: "commit transaction")
    } catch {
      try? execute("ROLLBACK", operation: "rollback transaction")
      throw error
    }
  }

  private func execute(_ sql: String, operation: String) throws {
    var errorMessage: UnsafeMutablePointer<CChar>?
    let result = sqlite3_exec(requiredConnection, sql, nil, nil, &errorMessage)
    guard result == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) }
        ?? String(cString: sqlite3_errmsg(requiredConnection))
      sqlite3_free(errorMessage)
      throw ActivitySessionStoreError.sqlite(
        operation: operation,
        code: result,
        message: message
      )
    }
  }

  private func prepare(_ sql: String, operation: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    let result = sqlite3_prepare_v2(requiredConnection, sql, -1, &statement, nil)
    guard result == SQLITE_OK, let statement else {
      throw sqliteError(operation: operation, code: result)
    }
    return statement
  }

  private func bind(
    _ value: String,
    at index: Int32,
    to statement: OpaquePointer,
    operation: String
  ) throws {
    let result = sqlite3_bind_text(
      statement,
      index,
      value,
      -1,
      Self.transientDestructor
    )
    guard result == SQLITE_OK else {
      throw sqliteError(operation: operation, code: result)
    }
  }

  private func bind(
    _ value: Int64?,
    at index: Int32,
    to statement: OpaquePointer
  ) throws {
    let result = value.map { sqlite3_bind_int64(statement, index, $0) }
      ?? sqlite3_bind_null(statement, index)
    guard result == SQLITE_OK else {
      throw sqliteError(operation: "bind integer", code: result)
    }
  }

  private func stepDone(_ statement: OpaquePointer, operation: String) throws {
    let result = sqlite3_step(statement)
    guard result == SQLITE_DONE else {
      throw sqliteError(operation: operation, code: result)
    }
  }

  private func sqliteError(operation: String, code: Int32) -> ActivitySessionStoreError {
    .sqlite(
      operation: operation,
      code: code,
      message: String(cString: sqlite3_errmsg(requiredConnection))
    )
  }
}
