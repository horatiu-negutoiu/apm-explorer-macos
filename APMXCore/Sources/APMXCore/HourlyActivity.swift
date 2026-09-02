import Foundation

public enum MonitoringCoverage: Equatable, Sendable {
  case unavailable
  case zero
  case partial
  case complete
}

/// The durable, privacy-safe activity total for one UTC-aligned hour.
///
/// This model deliberately has no event category, event timestamp, or source
/// identity. An absent aggregate represents unavailable monitoring history.
public struct HourlyActivityAggregate: Equatable, Codable, Sendable {
  public enum ValidationError: Error, Equatable, Sendable {
    case unalignedHour
    case negativeActionCount
    case invalidMonitoringDuration
  }

  public static let hourMilliseconds: Int64 = 60 * 60 * 1_000

  public let hourStart: WallClockInstant
  public let actionCount: Int64
  public let monitoredMilliseconds: Int64

  public var coverage: MonitoringCoverage {
    switch monitoredMilliseconds {
    case 0: .zero
    case Self.hourMilliseconds...: .complete
    default: .partial
    }
  }

  public init(
    hourStart: WallClockInstant,
    actionCount: Int64,
    monitoredMilliseconds: Int64
  ) throws {
    guard Self.isHourAligned(hourStart) else {
      throw ValidationError.unalignedHour
    }
    guard actionCount >= 0 else {
      throw ValidationError.negativeActionCount
    }
    guard (0...Self.hourMilliseconds).contains(monitoredMilliseconds) else {
      throw ValidationError.invalidMonitoringDuration
    }
    self.hourStart = hourStart
    self.actionCount = actionCount
    self.monitoredMilliseconds = monitoredMilliseconds
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    try self.init(
      hourStart: container.decode(WallClockInstant.self, forKey: .hourStart),
      actionCount: container.decode(Int64.self, forKey: .actionCount),
      monitoredMilliseconds: container.decode(
        Int64.self,
        forKey: .monitoredMilliseconds
      )
    )
  }

  static func hourStart(containing instant: WallClockInstant) -> WallClockInstant {
    let value = instant.epochMilliseconds
    let remainder = value % hourMilliseconds
    let aligned = remainder >= 0
      ? value - remainder
      : value - remainder - hourMilliseconds
    return WallClockInstant(epochMilliseconds: aligned)
  }

  static func isHourAligned(_ instant: WallClockInstant) -> Bool {
    instant.epochMilliseconds % hourMilliseconds == 0
  }
}

/// A query point preserves the distinction between an unavailable hour and a
/// monitored hour with no counted actions.
public struct HourlyActivityPoint: Equatable, Sendable {
  public let hourStart: WallClockInstant
  public let aggregate: HourlyActivityAggregate?

  public var actionCount: Int64? { aggregate?.actionCount }
  public var monitoredMilliseconds: Int64? { aggregate?.monitoredMilliseconds }
  public var coverage: MonitoringCoverage { aggregate?.coverage ?? .unavailable }

  public init(hourStart: WallClockInstant, aggregate: HourlyActivityAggregate?) {
    precondition(
      HourlyActivityAggregate.isHourAligned(hourStart),
      "Hourly activity points must begin on an hour boundary"
    )
    precondition(
      aggregate == nil || aggregate?.hourStart == hourStart,
      "The aggregate must belong to the point's hour"
    )
    self.hourStart = hourStart
    self.aggregate = aggregate
  }
}

/// An aggregate-only repository mutation. It is intentionally not Codable so
/// it cannot become an alternate durable event representation.
public struct HourlyActivityUpdate: Equatable, Sendable {
  public let hourStart: WallClockInstant
  public let actionCountIncrement: Int64
  public let monitoredMillisecondsIncrement: Int64

  public init(
    hourStart: WallClockInstant,
    actionCountIncrement: Int64 = 0,
    monitoredMillisecondsIncrement: Int64 = 0
  ) throws {
    guard HourlyActivityAggregate.isHourAligned(hourStart) else {
      throw HourlyActivityAggregate.ValidationError.unalignedHour
    }
    guard actionCountIncrement >= 0 else {
      throw HourlyActivityAggregate.ValidationError.negativeActionCount
    }
    guard monitoredMillisecondsIncrement >= 0 else {
      throw HourlyActivityAggregate.ValidationError.invalidMonitoringDuration
    }
    self.hourStart = hourStart
    self.actionCountIncrement = actionCountIncrement
    self.monitoredMillisecondsIncrement = monitoredMillisecondsIncrement
  }

  /// Creates a zero-duration marker so a known monitoring start is distinct
  /// from an hour for which the app has no coverage information.
  public static func markingCoverageAvailable(
    at instant: WallClockInstant
  ) -> HourlyActivityUpdate {
    try! HourlyActivityUpdate(
      hourStart: HourlyActivityAggregate.hourStart(containing: instant)
    )
  }

  /// Reduces a monitoring interval and an optional counted action into hourly
  /// deltas. No individual timestamp survives in the returned values.
  public static func aggregating(
    monitoringFrom start: WallClockInstant?,
    through end: WallClockInstant?,
    countedActionAt actionTime: WallClockInstant?
  ) -> [HourlyActivityUpdate] {
    var values: [Int64: (actions: Int64, monitored: Int64)] = [:]

    if let start, let end, end > start {
      var cursor = start
      while cursor < end {
        let hourStart = HourlyActivityAggregate.hourStart(containing: cursor)
        let hourEnd = hourStart.advanced(
          byMilliseconds: HourlyActivityAggregate.hourMilliseconds
        )
        let segmentEnd = min(end, hourEnd)
        let duration = segmentEnd.epochMilliseconds - cursor.epochMilliseconds
        values[hourStart.epochMilliseconds, default: (0, 0)].monitored += duration
        cursor = segmentEnd
      }
    }

    if let actionTime {
      let hourStart = HourlyActivityAggregate.hourStart(containing: actionTime)
      values[hourStart.epochMilliseconds, default: (0, 0)].actions += 1
    }

    return values.keys.sorted().map { hourStart in
      let value = values[hourStart]!
      return try! HourlyActivityUpdate(
        hourStart: WallClockInstant(epochMilliseconds: hourStart),
        actionCountIncrement: value.actions,
        monitoredMillisecondsIncrement: value.monitored
      )
    }
  }
}
