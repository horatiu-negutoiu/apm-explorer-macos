import XCTest

@testable import APMXCore

final class PropertyInvariantTests: XCTestCase {
  func testDeterministicSessionStreamNeverOverlapsOrHasNegativeDurations() throws {
    let timeout = try SessionTimeout(milliseconds: 1_000)
    let wallClock = TestWallClock(milliseconds: 10_000)
    let monotonicClock = TestMonotonicClock(milliseconds: 0)
    let engine = SessionEngine(
      timeout: timeout,
      wallClock: wallClock,
      monotonicClock: monotonicClock
    )
    var generator = DeterministicGenerator(seed: 0xA14)
    var monotonic: Int64 = 0
    var wall: Int64 = 10_000

    for _ in 0..<2_000 {
      monotonic += Int64(generator.next() % 1_500)
      // Deliberately make the observed wall clock jump in both directions.
      wall += Int64(generator.next() % 4_001) - 2_000
      _ = engine.ingest(
        ReducedActivity(
          evidenceAt: .init(epochMilliseconds: wall),
          monotonicTime: .init(uptimeMilliseconds: monotonic),
          countedAction: generator.next().isMultiple(of: 3) ? nil : .keyDown
        ))
    }

    wallClock.set(milliseconds: wall)
    monotonicClock.set(milliseconds: monotonic)
    _ = engine.close(reason: .shutdown)
    let sessions = engine.completedSessions.sorted { $0.startedAt < $1.startedAt }
    XCTAssertFalse(sessions.isEmpty)
    for session in sessions {
      XCTAssertGreaterThanOrEqual(try XCTUnwrap(session.durationMilliseconds), 0)
      XCTAssertGreaterThanOrEqual(session.lastActivityAt, session.startedAt)
    }
    for pair in zip(sessions, sessions.dropFirst()) {
      XCTAssertLessThanOrEqual(try XCTUnwrap(pair.0.endedAt), pair.1.startedAt)
    }
  }

  func testHourlyAnalyticsAlwaysProducesFiniteBoundedChronologicalCells() throws {
    let zones = try [
      XCTUnwrap(TimeZone(secondsFromGMT: 0)),
      XCTUnwrap(TimeZone(identifier: "America/New_York")),
      XCTUnwrap(TimeZone(identifier: "Asia/Kolkata")),
      XCTUnwrap(TimeZone(identifier: "Australia/Lord_Howe")),
    ]
    let now = WallClockInstant(epochMilliseconds: 1_730_673_000_000)
    var generator = DeterministicGenerator(seed: 0xA21)

    for zone in zones {
      let interval = try HourlyAnalytics.sourceInterval(
        containing: now,
        timeZone: zone,
        dayCount: 5
      )
      var points: [HourlyActivityPoint] = []
      var cursor = interval.start
      while cursor < interval.end {
        let hasData = !generator.next().isMultiple(of: 5)
        let aggregate: HourlyActivityAggregate?
        if hasData {
          aggregate = try HourlyActivityAggregate(
            hourStart: cursor,
            actionCount: Int64(generator.next() % 1_000_000),
            monitoredMilliseconds: Int64(
              generator.next() % UInt64(HourlyActivityAggregate.hourMilliseconds + 1)
            )
          )
        } else {
          aggregate = nil
        }
        points.append(HourlyActivityPoint(hourStart: cursor, aggregate: aggregate))
        cursor = cursor.advanced(
          byMilliseconds: HourlyActivityAggregate.hourMilliseconds
        )
      }

      let days = try HourlyAnalytics.history(
        from: points,
        now: now,
        timeZone: zone,
        dayCount: 5
      )

      XCTAssertEqual(days.count, 5)
      for day in days {
        XCTAssertEqual(day.hours.map(\.hour), Array(0..<24))
        for cell in day.hours {
          XCTAssertTrue(cell.intensity.isFinite)
          XCTAssertTrue((0...1).contains(cell.intensity))
          if let apm = cell.actionsPerMinute {
            XCTAssertTrue(apm.isFinite)
            XCTAssertGreaterThanOrEqual(apm, 0)
          } else {
            XCTAssertEqual(cell.coverage, .unavailable)
          }
        }
      }
    }
  }

}

private struct DeterministicGenerator {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return state
  }
}
