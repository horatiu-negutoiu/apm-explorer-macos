import Foundation
import XCTest

@testable import APMXCore

final class HourlyAnalyticsTests: XCTestCase {
  private let hour: Int64 = HourlyActivityAggregate.hourMilliseconds
  private let utc = TimeZone(secondsFromGMT: 0)!

  func testCurrentDayReturnsStableChronologicalCellsAndFixedDenominator() throws {
    let current = try point(
      "2024-06-15T10:00:00Z",
      actions: 120,
      monitored: 5 * 60 * 1_000
    )
    let zero = try point(
      "2024-06-15T09:00:00Z",
      actions: 0,
      monitored: 0
    )

    let day = try HourlyAnalytics.currentDay(
      from: [current, zero],
      now: instant("2024-06-15T10:05:00Z"),
      timeZone: utc
    )

    XCTAssertEqual(day.day, LocalCalendarDay(year: 2024, month: 6, day: 15))
    XCTAssertEqual(day.hours.map(\.hour), Array(0..<24))
    XCTAssertEqual(day.hours[9].coverage, .zero)
    XCTAssertEqual(day.hours[9].actionCount, 0)
    XCTAssertEqual(day.hours[10].coverage, .partial)
    XCTAssertEqual(day.hours[10].actionsPerMinute, 2)
    XCTAssertEqual(day.hours[10].intensity, 1)
    XCTAssertEqual(day.hours[11].coverage, .unavailable)
    XCTAssertNil(day.hours[11].actionCount)
    XCTAssertNil(day.hours[11].actionsPerMinute)
  }

  func testCurrentDayUsesItsOwnMaximumWhileHistorySharesOneMaximum() throws {
    let points = [
      try point("2023-12-31T08:00:00Z", actions: 60),
      try point("2024-01-01T08:00:00Z", actions: 120),
    ]
    let now = instant("2024-01-01T12:00:00Z")

    let current = try HourlyAnalytics.currentDay(
      from: points,
      now: now,
      timeZone: utc
    )
    let history = try HourlyAnalytics.history(
      from: points,
      now: now,
      timeZone: utc,
      dayCount: 2
    )

    XCTAssertEqual(current.hours[8].intensity, 1)
    XCTAssertEqual(
      history.map(\.day),
      [
        LocalCalendarDay(year: 2023, month: 12, day: 31),
        LocalCalendarDay(year: 2024, month: 1, day: 1),
      ])
    XCTAssertEqual(history[0].hours[8].intensity, 0.5)
    XCTAssertEqual(history[1].hours[8].intensity, 1)
  }

  func testExactHourAndDayRolloverIncludesNewBucketOnly() throws {
    let previous = try point("2024-12-31T23:00:00Z", actions: 30)
    let current = try point("2025-01-01T00:00:00Z", actions: 90, monitored: 0)

    let day = try HourlyAnalytics.currentDay(
      from: [previous, current],
      now: instant("2025-01-01T00:00:00Z"),
      timeZone: utc
    )

    XCTAssertEqual(day.day, LocalCalendarDay(year: 2025, month: 1, day: 1))
    XCTAssertEqual(totalActions(in: [day]), 90)
    XCTAssertEqual(day.hours[0].actionCount, 90)
    XCTAssertEqual(day.hours[0].coverage, .zero)
    XCTAssertEqual(day.hours[0].actionsPerMinute, 1.5)
  }

  func testSpringForwardKeepsTwentyFourPositionsAndMarksSkippedHourUnavailable() throws {
    let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    let now = instant("2024-03-10T16:00:00Z")
    let interval = try HourlyAnalytics.sourceInterval(
      containing: now,
      timeZone: zone,
      dayCount: 1
    )
    let points = try completePoints(in: interval)

    let day = try HourlyAnalytics.currentDay(
      from: points,
      now: now,
      timeZone: zone
    )

    XCTAssertEqual(day.hours.count, 24)
    XCTAssertEqual(day.hours[2].coverage, .unavailable)
    XCTAssertNil(day.hours[2].actionCount)
    XCTAssertEqual(day.hours.filter { $0.coverage == .complete }.count, 23)
  }

  func testFallBackCombinesBothOccurrencesIntoOneLocalHour() throws {
    let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    let now = instant("2024-11-03T18:00:00Z")
    let interval = try HourlyAnalytics.sourceInterval(
      containing: now,
      timeZone: zone,
      dayCount: 1
    )
    let points = try completePoints(
      in: interval,
      actions: [
        instant("2024-11-03T05:00:00Z").epochMilliseconds: 60,
        instant("2024-11-03T06:00:00Z").epochMilliseconds: 120,
      ])

    let day = try HourlyAnalytics.currentDay(
      from: points,
      now: now,
      timeZone: zone
    )

    XCTAssertEqual(day.hours[1].coverage, .complete)
    XCTAssertEqual(day.hours[1].actionCount, 180)
    XCTAssertEqual(day.hours[1].actionsPerMinute, 3)
    XCTAssertEqual(day.hours[1].intensity, 1)
    XCTAssertEqual(day.hours.filter { $0.coverage == .complete }.count, 24)
  }

  func testFallBackIsPartialWhenOneRepeatedOccurrenceIsMissing() throws {
    let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    let now = instant("2024-11-03T18:00:00Z")
    let interval = try HourlyAnalytics.sourceInterval(
      containing: now,
      timeZone: zone,
      dayCount: 1
    )
    let missing = instant("2024-11-03T06:00:00Z")
    let points = try completePoints(in: interval).filter { $0.hourStart != missing }

    let day = try HourlyAnalytics.currentDay(
      from: points,
      now: now,
      timeZone: zone
    )

    XCTAssertEqual(day.hours[1].coverage, .partial)
    XCTAssertEqual(day.hours[1].actionCount, 0)
  }

  func testExplicitTimezoneReprojectsCanonicalBucketsWithoutLosingActions() throws {
    let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
    let points = [
      try point("2024-01-01T12:00:00Z", actions: 17),
      try point("2024-01-02T00:00:00Z", actions: 29),
    ]
    let now = instant("2024-01-02T12:00:00Z")

    let western = try HourlyAnalytics.history(
      from: points,
      now: now,
      timeZone: newYork,
      dayCount: 2
    )
    let eastern = try HourlyAnalytics.history(
      from: points,
      now: now,
      timeZone: tokyo,
      dayCount: 2
    )

    XCTAssertEqual(totalActions(in: western), 46)
    XCTAssertEqual(totalActions(in: eastern), 46)
    XCTAssertEqual(western[0].hours[7].actionCount, 17)
    XCTAssertEqual(western[0].hours[19].actionCount, 29)
    XCTAssertEqual(eastern[0].hours[21].actionCount, 17)
    XCTAssertEqual(eastern[1].hours[9].actionCount, 29)
  }

  func testFutureDataAfterClockRollbackIsNotIncludedInCurrentDay() throws {
    let future = try point("2024-01-02T03:00:00Z", actions: 500)

    let day = try HourlyAnalytics.currentDay(
      from: [future],
      now: instant("2024-01-01T23:30:00Z"),
      timeZone: utc
    )

    XCTAssertEqual(totalActions(in: [day]), 0)
    XCTAssertTrue(day.hours.allSatisfy { $0.intensity == 0 })
  }

  func testEmptyAndUnavailableOnlyRangesHaveStableZeroIntensity() throws {
    let history = try HourlyAnalytics.history(
      from: [],
      now: instant("2024-02-01T00:00:00Z"),
      timeZone: utc
    )

    XCTAssertEqual(history.count, 14)
    XCTAssertTrue(history.allSatisfy { $0.hours.count == 24 })
    XCTAssertTrue(
      history.flatMap(\.hours).allSatisfy {
        $0.coverage == .unavailable && $0.intensity == 0
      })
  }

  func testLargeRepeatedCountsSaturateAndRemainFinite() throws {
    let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    let now = instant("2024-11-03T18:00:00Z")
    let interval = try HourlyAnalytics.sourceInterval(
      containing: now,
      timeZone: zone,
      dayCount: 1
    )
    let points = try completePoints(
      in: interval,
      actions: [
        instant("2024-11-03T05:00:00Z").epochMilliseconds: .max,
        instant("2024-11-03T06:00:00Z").epochMilliseconds: .max,
      ])

    let day = try HourlyAnalytics.currentDay(
      from: points,
      now: now,
      timeZone: zone
    )

    XCTAssertEqual(day.hours[1].actionCount, .max)
    XCTAssertTrue(try XCTUnwrap(day.hours[1].actionsPerMinute).isFinite)
    XCTAssertEqual(day.hours[1].intensity, 1)
  }

  func testDuplicateSourceHoursAreRejected() throws {
    let point = try point("2024-01-01T00:00:00Z", actions: 1)
    XCTAssertThrowsError(
      try HourlyAnalytics.currentDay(
        from: [point, point],
        now: instant("2024-01-01T12:00:00Z"),
        timeZone: utc
      )
    ) { error in
      XCTAssertEqual(
        error as? HourlyAnalyticsError,
        .duplicateSourceHour(point.hourStart)
      )
    }
  }

  func testInvalidDayCountIsRejected() throws {
    XCTAssertThrowsError(
      try HourlyAnalytics.history(
        from: [],
        now: instant("2024-01-01T00:00:00Z"),
        timeZone: utc,
        dayCount: 0
      )
    ) { error in
      XCTAssertEqual(error as? HourlyAnalyticsError, .invalidDayCount)
    }
  }

  func testRollingHoursReturnsExactlyTwelveChronologicalPositionsAcrossMidnight() throws {
    let now = instant("2024-06-15T03:30:00Z")
    let cells = try HourlyAnalytics.rollingHours(
      from: [
        try point("2024-06-14T23:00:00Z", actions: 60),
        try point("2024-06-15T03:00:00Z", actions: 120),
      ],
      now: now,
      timeZone: utc
    )

    XCTAssertEqual(cells.count, 12)
    XCTAssertEqual(cells.map(\.hour), Array(16...23) + Array(0...3))
    XCTAssertEqual(cells.map(\.hourStart), cells.map(\.hourStart).sorted())
    XCTAssertEqual(cells[7].intensity, 0.5)
    XCTAssertEqual(cells[11].intensity, 1)
  }

  func testRollingHoursKeepsRepeatedDSTHoursDistinct() throws {
    let zone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
    let now = instant("2024-11-03T08:30:00Z")
    let cells = try HourlyAnalytics.rollingHours(
      from: [
        try point("2024-11-03T05:00:00Z", actions: 60),
        try point("2024-11-03T06:00:00Z", actions: 120),
      ],
      now: now,
      timeZone: zone
    )
    let repeated = cells.filter { $0.hour == 1 }

    XCTAssertEqual(repeated.count, 2)
    XCTAssertEqual(repeated.map(\.actionCount), [60, 120])
    XCTAssertNotEqual(repeated[0].hourStart, repeated[1].hourStart)
  }

  private func point(
    _ timestamp: String,
    actions: Int64,
    monitored: Int64? = nil
  ) throws -> HourlyActivityPoint {
    let start = instant(timestamp)
    let aggregate = try HourlyActivityAggregate(
      hourStart: start,
      actionCount: actions,
      monitoredMilliseconds: monitored ?? hour
    )
    return HourlyActivityPoint(hourStart: start, aggregate: aggregate)
  }

  private func completePoints(
    in interval: HourlyAnalyticsSourceInterval,
    actions: [Int64: Int64] = [:]
  ) throws -> [HourlyActivityPoint] {
    var result: [HourlyActivityPoint] = []
    var cursor = interval.start
    while cursor < interval.end {
      let aggregate = try HourlyActivityAggregate(
        hourStart: cursor,
        actionCount: actions[cursor.epochMilliseconds] ?? 0,
        monitoredMilliseconds: hour
      )
      result.append(HourlyActivityPoint(hourStart: cursor, aggregate: aggregate))
      cursor = cursor.advanced(byMilliseconds: hour)
    }
    return result
  }

  private func instant(_ value: String) -> WallClockInstant {
    let formatter = ISO8601DateFormatter()
    return WallClockInstant(date: formatter.date(from: value)!)
  }

  private func totalActions(in days: [HourlyAnalyticsDay]) -> Int64 {
    days.flatMap(\.hours).compactMap(\.actionCount).reduce(0, +)
  }
}
