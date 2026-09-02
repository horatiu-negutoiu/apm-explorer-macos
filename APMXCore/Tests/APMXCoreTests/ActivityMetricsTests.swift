import Foundation
import XCTest

@testable import APMXCore

final class ActivityMetricsTests: XCTestCase {
  private let minute: Int64 = 60_000

  func testTwoHundredFortyActionsOverTwoMinutesProducesOneHundredTwentyAPM() throws {
    let session = try makeSession(
      startedAt: 0,
      lastActivityAt: minute,
      endedAt: nil,
      actionCount: 240,
      timeout: minute
    )

    let result = APMCalculator.calculate(
      for: session,
      now: .init(epochMilliseconds: 2 * minute)
    )

    XCTAssertEqual(result.actionsPerMinute, 120)
  }

  func testAPMUsesLeaseEndWhenNowIsLaterAndRetainsPrecision() throws {
    let session = try makeSession(
      startedAt: 0,
      lastActivityAt: 500,
      endedAt: nil,
      actionCount: 1,
      timeout: 800
    )

    let result = APMCalculator.calculate(
      for: session,
      now: .init(epochMilliseconds: 10_000)
    )

    XCTAssertEqual(result.actionsPerMinute!, 60_000 / 1_300, accuracy: 0.000_000_1)
  }

  func testSubOneSecondAPMIsUndefinedAndExactBoundaryIsDefined() throws {
    let session = try makeSession(
      startedAt: 10_000,
      lastActivityAt: 10_000,
      endedAt: nil,
      actionCount: 1,
      timeout: minute
    )

    XCTAssertEqual(
      APMCalculator.calculate(
        for: session,
        now: .init(epochMilliseconds: 10_999)
      ),
      .undefined
    )
    XCTAssertEqual(
      APMCalculator.calculate(
        for: session,
        now: .init(epochMilliseconds: 11_000)
      ).actionsPerMinute,
      60
    )
  }

  func testAPMIsUndefinedForNoSessionClosedSessionAndWallClockRollback() throws {
    let closed = try makeSession(
      startedAt: 10_000,
      lastActivityAt: 11_000,
      endedAt: 12_000,
      actionCount: 2,
      timeout: minute
    )
    let open = try makeSession(
      startedAt: 10_000,
      lastActivityAt: 10_000,
      endedAt: nil,
      actionCount: 1,
      timeout: minute
    )

    XCTAssertEqual(
      APMCalculator.calculate(for: nil, now: .init(epochMilliseconds: 12_000)), .undefined)
    XCTAssertEqual(
      APMCalculator.calculate(for: closed, now: .init(epochMilliseconds: 12_000)), .undefined)
    XCTAssertEqual(
      APMCalculator.calculate(for: open, now: .init(epochMilliseconds: 9_000)), .undefined)
  }

  private func makeSession(
    startedAt: Int64,
    lastActivityAt: Int64,
    endedAt: Int64?,
    actionCount: Int64 = 0,
    timeout: Int64? = nil
  ) throws -> ActivitySession {
    try ActivitySession(
      id: UUID(),
      startedAt: .init(epochMilliseconds: startedAt),
      lastActivityAt: .init(epochMilliseconds: lastActivityAt),
      endedAt: endedAt.map(WallClockInstant.init(epochMilliseconds:)),
      actionCount: actionCount,
      timeout: try SessionTimeout(milliseconds: timeout ?? minute),
      endReason: endedAt == nil ? nil : .inactivityTimeout
    )
  }
}
