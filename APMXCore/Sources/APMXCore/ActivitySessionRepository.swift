import Foundation

/// Durable access to privacy-safe session summaries and hourly aggregates.
///
/// Repository implementations must never accept raw input events. Requiring an
/// `ActivitySession` and `HourlyActivityUpdate` at this boundary make the
/// durable privacy contract explicit in the type system.
public protocol ActivitySessionRepository: Sendable {
  func save(_ session: ActivitySession) async throws
  func save(
    _ sessions: [ActivitySession],
    applying hourlyUpdates: [HourlyActivityUpdate]
  ) async throws
  func applyHourlyUpdates(_ updates: [HourlyActivityUpdate]) async throws
  func flush() async throws
  func openSession() async throws -> ActivitySession?
  func recoverOpenSession(at now: WallClockInstant) async throws -> ActivitySession?
  func sessions(
    overlapping intervalStart: WallClockInstant,
    through intervalEnd: WallClockInstant
  ) async throws -> [ActivitySession]
  func hourlyActivity(
    overlapping intervalStart: WallClockInstant,
    through intervalEnd: WallClockInstant
  ) async throws -> [HourlyActivityPoint]
  func purgeExpiredClosedSessions(at now: WallClockInstant) async throws -> Int
  func performDailyMaintenanceIfNeeded(at now: WallClockInstant) async throws -> Int
  func deleteAllActivitySummaries() async throws
  func checkHealth() async throws
}

/// Optional failure notifications for repositories that perform deferred work.
///
/// Keeping this separate from `ActivitySessionRepository` preserves source
/// compatibility for repositories whose operations always finish in-call.
public protocol ActivitySessionRepositoryFailureReporting: ActivitySessionRepository {
  nonisolated var persistenceFailures: AsyncStream<ActivitySessionStoreError> { get }
}
