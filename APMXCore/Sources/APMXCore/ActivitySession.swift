import Foundation

public enum SessionEndReason: Int, Codable, CaseIterable, Sendable {
  case inactivityTimeout = 0
  case sleep = 1
  case sessionInactive = 2
  case shutdown = 3
  case recovery = 4
}

/// A session summary is the durable unit of activity data. Raw and reduced
/// signals are deliberately absent from this model.
public struct ActivitySession: Identifiable, Equatable, Codable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case lastActivityPrecedesStart
    case endPrecedesLastActivity
    case negativeActionCount
    case inconsistentClosure
  }

  public let id: UUID
  public internal(set) var startedAt: WallClockInstant
  public internal(set) var lastActivityAt: WallClockInstant
  public internal(set) var endedAt: WallClockInstant?
  public internal(set) var actionCount: Int64
  public internal(set) var timeout: SessionTimeout
  public internal(set) var endReason: SessionEndReason?

  public var isOpen: Bool { endedAt == nil }

  /// The wall-clock end of the current activity lease.
  public var leaseEndsAt: WallClockInstant {
    lastActivityAt.advanced(byMilliseconds: timeout.milliseconds)
  }

  public var durationMilliseconds: Int64? {
    guard let endedAt else { return nil }
    guard endedAt >= startedAt else { return 0 }
    let (duration, overflow) = endedAt.epochMilliseconds.subtractingReportingOverflow(
      startedAt.epochMilliseconds
    )
    return overflow ? .max : duration
  }

  /// Reconstructs a validated session summary from durable storage.
  public init(
    id: UUID,
    startedAt: WallClockInstant,
    lastActivityAt: WallClockInstant,
    endedAt: WallClockInstant?,
    actionCount: Int64,
    timeout: SessionTimeout,
    endReason: SessionEndReason?
  ) throws {
    guard lastActivityAt >= startedAt else {
      throw ValidationError.lastActivityPrecedesStart
    }
    if let endedAt, endedAt < lastActivityAt {
      throw ValidationError.endPrecedesLastActivity
    }
    guard actionCount >= 0 else { throw ValidationError.negativeActionCount }
    guard (endedAt == nil) == (endReason == nil) else {
      throw ValidationError.inconsistentClosure
    }

    self.id = id
    self.startedAt = startedAt
    self.lastActivityAt = lastActivityAt
    self.endedAt = endedAt
    self.actionCount = actionCount
    self.timeout = timeout
    self.endReason = endReason
  }

  init(
    id: UUID,
    startedAt: WallClockInstant,
    countedAction: CountedActionKind?,
    timeout: SessionTimeout
  ) {
    self.id = id
    self.startedAt = startedAt
    self.lastActivityAt = startedAt
    self.endedAt = nil
    self.actionCount = countedAction == nil ? 0 : 1
    self.timeout = timeout
    self.endReason = nil
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      id: container.decode(UUID.self, forKey: .id),
      startedAt: container.decode(WallClockInstant.self, forKey: .startedAt),
      lastActivityAt: container.decode(WallClockInstant.self, forKey: .lastActivityAt),
      endedAt: container.decodeIfPresent(WallClockInstant.self, forKey: .endedAt),
      actionCount: container.decode(Int64.self, forKey: .actionCount),
      timeout: container.decode(SessionTimeout.self, forKey: .timeout),
      endReason: container.decodeIfPresent(SessionEndReason.self, forKey: .endReason)
    )
  }
}

public enum SessionTransition: Equatable, Sendable {
  case started(ActivitySession)
  case updated(ActivitySession)
  case ended(ActivitySession)
}
