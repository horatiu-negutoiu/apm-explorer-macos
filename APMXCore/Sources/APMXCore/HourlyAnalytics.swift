import Foundation

/// A Gregorian calendar day in the timezone supplied to an analytics request.
public struct LocalCalendarDay: Hashable, Sendable {
  public let year: Int
  public let month: Int
  public let day: Int

  public init(year: Int, month: Int, day: Int) {
    self.year = year
    self.month = month
    self.day = day
  }
}

/// A stable position in a local day's 24-hour presentation.
public struct HourlyAnalyticsCell: Equatable, Sendable {
  /// The local clock-hour position, in `0...23`.
  public let hour: Int
  /// Actions assigned to this position, or `nil` when no monitoring data exists.
  public let actionCount: Int64?
  /// Actions divided by 60. The denominator is fixed even for a partial hour.
  public let actionsPerMinute: Double?
  public let coverage: MonitoringCoverage
  /// A finite value in `0...1`, normalized for the containing result.
  public let intensity: Double

  init(
    hour: Int,
    actionCount: Int64?,
    coverage: MonitoringCoverage,
    intensity: Double = 0
  ) {
    self.hour = hour
    self.actionCount = actionCount
    self.actionsPerMinute = actionCount.map { Double($0) / 60 }
    self.coverage = coverage
    self.intensity = intensity
  }

  func withIntensity(_ intensity: Double) -> Self {
    Self(
      hour: hour,
      actionCount: actionCount,
      coverage: coverage,
      intensity: intensity
    )
  }
}

public struct HourlyAnalyticsDay: Equatable, Sendable {
  public let day: LocalCalendarDay
  /// Always contains 24 cells ordered from local hour 0 through 23.
  public let hours: [HourlyAnalyticsCell]

  init(day: LocalCalendarDay, hours: [HourlyAnalyticsCell]) {
    precondition(hours.count == 24)
    self.day = day
    self.hours = hours
  }
}

/// One UTC-backed position in a rolling hourly strip. Keeping the source hour
/// makes repeated local clock hours distinct across daylight-saving changes.
public struct RollingHourlyAnalyticsCell: Equatable, Sendable {
  public let hourStart: WallClockInstant
  public let day: LocalCalendarDay
  public let hour: Int
  public let actionCount: Int64?
  public let actionsPerMinute: Double?
  public let coverage: MonitoringCoverage
  public let intensity: Double

  init(
    hourStart: WallClockInstant,
    day: LocalCalendarDay,
    hour: Int,
    actionCount: Int64?,
    coverage: MonitoringCoverage,
    intensity: Double = 0
  ) {
    self.hourStart = hourStart
    self.day = day
    self.hour = hour
    self.actionCount = actionCount
    self.actionsPerMinute = actionCount.map { Double($0) / 60 }
    self.coverage = coverage
    self.intensity = intensity
  }

  func withIntensity(_ intensity: Double) -> Self {
    Self(
      hourStart: hourStart,
      day: day,
      hour: hour,
      actionCount: actionCount,
      coverage: coverage,
      intensity: intensity
    )
  }
}

/// The half-open UTC query interval required to build an analytics result.
public struct HourlyAnalyticsSourceInterval: Equatable, Sendable {
  public let start: WallClockInstant
  public let end: WallClockInstant

  public init(start: WallClockInstant, end: WallClockInstant) {
    precondition(end > start)
    self.start = start
    self.end = end
  }
}

public enum HourlyAnalyticsError: Error, Equatable, Sendable {
  case invalidDayCount
  case invalidHourCount
  case calendarCalculationFailed
  case duplicateSourceHour(WallClockInstant)
}

/// Pure analytics for UTC-aligned durable aggregates.
///
/// Every request requires an explicit timezone. Stored UTC buckets are never
/// rewritten when that timezone changes: a bucket is projected exactly once,
/// according to the local date and hour containing its midpoint. Midpoint
/// projection also gives deterministic behavior in timezones whose UTC offset
/// is not a whole number of hours.
public enum HourlyAnalytics {
  public static let historyDayCount = 14
  public static let activityStripHourCount = 12

  /// Builds a rolling sequence ending with the UTC bucket containing `now`.
  /// Positions remain chronological and distinct when a local hour repeats.
  public static func rollingHours(
    from points: [HourlyActivityPoint],
    now: WallClockInstant,
    timeZone: TimeZone,
    hourCount: Int = activityStripHourCount
  ) throws -> [RollingHourlyAnalyticsCell] {
    guard hourCount > 0 else { throw HourlyAnalyticsError.invalidHourCount }
    let pointsByHour = try index(points)
    let calendar = calendar(in: timeZone)
    let currentHour = HourlyActivityAggregate.hourStart(containing: now)
    let firstHour = currentHour.advanced(
      byMilliseconds: -Int64(hourCount - 1)
        * HourlyActivityAggregate.hourMilliseconds
    )

    var cells: [RollingHourlyAnalyticsCell] = []
    cells.reserveCapacity(hourCount)
    for offset in 0..<hourCount {
      let hourStart = firstHour.advanced(
        byMilliseconds: Int64(offset) * HourlyActivityAggregate.hourMilliseconds
      )
      let midpoint = hourStart.advanced(
        byMilliseconds: HourlyActivityAggregate.hourMilliseconds / 2
      )
      let point = pointsByHour[hourStart]
      cells.append(RollingHourlyAnalyticsCell(
        hourStart: hourStart,
        day: localDay(containing: midpoint.date, calendar: calendar),
        hour: calendar.component(.hour, from: midpoint.date),
        actionCount: point?.actionCount,
        coverage: point?.coverage ?? .unavailable
      ))
    }

    let maximum = cells.compactMap(\.actionsPerMinute).filter { $0 > 0 }.max() ?? 0
    guard maximum > 0, maximum.isFinite else { return cells }
    return cells.map { cell in
      let value = (cell.actionsPerMinute ?? 0) / maximum
      return cell.withIntensity(value.isFinite ? min(max(value, 0), 1) : 0)
    }
  }

  /// Builds the current local day's strip. Intensity is relative to this day's
  /// maximum nonzero APM.
  public static func currentDay(
    from points: [HourlyActivityPoint],
    now: WallClockInstant,
    timeZone: TimeZone
  ) throws -> HourlyAnalyticsDay {
    let days = try makeDays(
      from: points,
      now: now,
      timeZone: timeZone,
      dayCount: 1
    )
    return normalizeEachDay(days)[0]
  }

  /// Builds a rolling history ending with the current local day. By default it
  /// returns 14 chronological days. One maximum is shared by every returned
  /// cell so intensities remain comparable across days.
  public static func history(
    from points: [HourlyActivityPoint],
    now: WallClockInstant,
    timeZone: TimeZone,
    dayCount: Int = historyDayCount
  ) throws -> [HourlyAnalyticsDay] {
    normalizeTogether(
      try makeDays(
        from: points,
        now: now,
        timeZone: timeZone,
        dayCount: dayCount
      ))
  }

  /// Returns the UTC-aligned repository interval needed for `currentDay` or
  /// `history`. Its end is the end of the current local day, not `now`, so a
  /// bucket at an exact current-hour boundary is included by half-open queries.
  public static func sourceInterval(
    containing now: WallClockInstant,
    timeZone: TimeZone,
    dayCount: Int = historyDayCount
  ) throws -> HourlyAnalyticsSourceInterval {
    guard dayCount > 0 else { throw HourlyAnalyticsError.invalidDayCount }
    let calendar = calendar(in: timeZone)
    let currentDayStart = calendar.startOfDay(for: now.date)
    guard
      let firstDayStart = calendar.date(
        byAdding: .day,
        value: -(dayCount - 1),
        to: currentDayStart
      ),
      let endOfCurrentDay = calendar.date(
        byAdding: .day,
        value: 1,
        to: currentDayStart
      )
    else {
      throw HourlyAnalyticsError.calendarCalculationFailed
    }

    let rawStart = WallClockInstant(date: firstDayStart)
    let rawEnd = WallClockInstant(date: endOfCurrentDay)
    let start = HourlyActivityAggregate.hourStart(containing: rawStart)
    let endFloor = HourlyActivityAggregate.hourStart(containing: rawEnd)
    let end =
      endFloor == rawEnd
      ? rawEnd
      : endFloor.advanced(byMilliseconds: HourlyActivityAggregate.hourMilliseconds)
    return HourlyAnalyticsSourceInterval(start: start, end: end)
  }

  private static func makeDays(
    from points: [HourlyActivityPoint],
    now: WallClockInstant,
    timeZone: TimeZone,
    dayCount: Int
  ) throws -> [HourlyAnalyticsDay] {
    guard dayCount > 0 else { throw HourlyAnalyticsError.invalidDayCount }
    let calendar = calendar(in: timeZone)
    let interval = try sourceInterval(
      containing: now,
      timeZone: timeZone,
      dayCount: dayCount
    )
    let pointsByHour = try index(points)
    let currentDayStart = calendar.startOfDay(for: now.date)

    var orderedDays: [LocalCalendarDay] = []
    for offset in stride(from: -(dayCount - 1), through: 0, by: 1) {
      guard
        let date = calendar.date(
          byAdding: .day,
          value: offset,
          to: currentDayStart
        )
      else {
        throw HourlyAnalyticsError.calendarCalculationFailed
      }
      orderedDays.append(localDay(containing: date, calendar: calendar))
    }

    var expectedHours = Dictionary(
      uniqueKeysWithValues: orderedDays.map {
        ($0, Array(repeating: [WallClockInstant](), count: 24))
      }
    )
    var sourceHour = interval.start
    while sourceHour < interval.end {
      let midpoint = sourceHour.advanced(
        byMilliseconds: HourlyActivityAggregate.hourMilliseconds / 2
      )
      let day = localDay(containing: midpoint.date, calendar: calendar)
      let hour = calendar.component(.hour, from: midpoint.date)
      if expectedHours[day] != nil, (0..<24).contains(hour) {
        expectedHours[day]![hour].append(sourceHour)
      }
      sourceHour = sourceHour.advanced(
        byMilliseconds: HourlyActivityAggregate.hourMilliseconds
      )
    }

    return orderedDays.map { day in
      let sources = expectedHours[day]!
      let cells = (0..<24).map { hour in
        makeCell(
          hour: hour,
          expectedSourceHours: sources[hour],
          pointsByHour: pointsByHour
        )
      }
      return HourlyAnalyticsDay(day: day, hours: cells)
    }
  }

  private static func index(
    _ points: [HourlyActivityPoint]
  ) throws -> [WallClockInstant: HourlyActivityPoint] {
    var result: [WallClockInstant: HourlyActivityPoint] = [:]
    for point in points {
      guard result.updateValue(point, forKey: point.hourStart) == nil else {
        throw HourlyAnalyticsError.duplicateSourceHour(point.hourStart)
      }
    }
    return result
  }

  private static func makeCell(
    hour: Int,
    expectedSourceHours: [WallClockInstant],
    pointsByHour: [WallClockInstant: HourlyActivityPoint]
  ) -> HourlyAnalyticsCell {
    guard !expectedSourceHours.isEmpty else {
      return HourlyAnalyticsCell(
        hour: hour,
        actionCount: nil,
        coverage: .unavailable
      )
    }

    var availableCount = 0
    var actionCount: Int64 = 0
    var monitoredMilliseconds: Int64 = 0
    for sourceHour in expectedSourceHours {
      guard let aggregate = pointsByHour[sourceHour]?.aggregate else { continue }
      availableCount += 1
      actionCount = actionCount.addingClamped(aggregate.actionCount)
      monitoredMilliseconds = monitoredMilliseconds.addingClamped(
        aggregate.monitoredMilliseconds
      )
    }

    guard availableCount > 0 else {
      return HourlyAnalyticsCell(
        hour: hour,
        actionCount: nil,
        coverage: .unavailable
      )
    }

    let coverage: MonitoringCoverage
    if availableCount < expectedSourceHours.count {
      coverage = .partial
    } else if monitoredMilliseconds == 0 {
      coverage = .zero
    } else {
      let expectedDuration =
        Int64(expectedSourceHours.count) * HourlyActivityAggregate.hourMilliseconds
      coverage = monitoredMilliseconds >= expectedDuration ? .complete : .partial
    }
    return HourlyAnalyticsCell(
      hour: hour,
      actionCount: actionCount,
      coverage: coverage
    )
  }

  private static func normalizeEachDay(
    _ days: [HourlyAnalyticsDay]
  ) -> [HourlyAnalyticsDay] {
    days.map { day in
      HourlyAnalyticsDay(
        day: day.day,
        hours: normalize(day.hours, maximum: maximumAPM(in: day.hours))
      )
    }
  }

  private static func normalizeTogether(
    _ days: [HourlyAnalyticsDay]
  ) -> [HourlyAnalyticsDay] {
    let maximum = days.lazy.map(\.hours).map(maximumAPM).max() ?? 0
    return days.map { day in
      HourlyAnalyticsDay(
        day: day.day,
        hours: normalize(day.hours, maximum: maximum)
      )
    }
  }

  private static func maximumAPM(in cells: [HourlyAnalyticsCell]) -> Double {
    cells.compactMap(\.actionsPerMinute).filter { $0 > 0 }.max() ?? 0
  }

  private static func normalize(
    _ cells: [HourlyAnalyticsCell],
    maximum: Double
  ) -> [HourlyAnalyticsCell] {
    guard maximum > 0, maximum.isFinite else {
      return cells.map { $0.withIntensity(0) }
    }
    return cells.map { cell in
      let value = (cell.actionsPerMinute ?? 0) / maximum
      return cell.withIntensity(value.isFinite ? min(max(value, 0), 1) : 0)
    }
  }

  private static func calendar(in timeZone: TimeZone) -> Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = timeZone
    return value
  }

  private static func localDay(
    containing date: Date,
    calendar: Calendar
  ) -> LocalCalendarDay {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return LocalCalendarDay(
      year: components.year!,
      month: components.month!,
      day: components.day!
    )
  }
}
