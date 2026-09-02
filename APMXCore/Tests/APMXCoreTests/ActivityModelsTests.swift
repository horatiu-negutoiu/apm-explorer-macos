import APMXCore
import Foundation
import XCTest

final class ActivityModelsTests: XCTestCase {
  func testNonScrollSignalDropsScrollMetadataAtPrivacyBoundary() {
    let signal = RawActivitySignal(
      kind: .keyDown,
      scrollPhase: .momentum,
      wallTime: .init(epochMilliseconds: 1_000),
      monotonicTime: .init(uptimeMilliseconds: 100)
    )

    XCTAssertNil(signal.scrollPhase)
  }

  func testMetadataIsKeptOnlyForItsApplicableSignalKind() {
    let button = RawActivitySignal(
      kind: .mouseButtonDown,
      keyDownPhase: .autoRepeat,
      scrollPhase: .momentum,
      wallTime: .init(epochMilliseconds: 1_000),
      monotonicTime: .init(uptimeMilliseconds: 100)
    )
    let key = RawActivitySignal(
      kind: .keyDown,
      wallTime: .init(epochMilliseconds: 1_000),
      monotonicTime: .init(uptimeMilliseconds: 100)
    )

    XCTAssertNil(button.keyDownPhase)
    XCTAssertNil(button.scrollPhase)
    XCTAssertEqual(key.keyDownPhase, .physical)
  }

  func testTimeoutMustBePositive() {
    XCTAssertThrowsError(try SessionTimeout(milliseconds: 0))
    XCTAssertThrowsError(try SessionTimeout(milliseconds: -1))
    XCTAssertEqual(SessionTimeout.oneMinute.milliseconds, 60_000)
  }

  func testTimeoutCannotDecodeAnInvalidValue() throws {
    let invalid = Data("0".utf8)

    XCTAssertThrowsError(try JSONDecoder().decode(SessionTimeout.self, from: invalid))
  }

  func testPersistedSessionModelRejectsInvalidIntervals() throws {
    XCTAssertThrowsError(
      try ActivitySession(
        id: UUID(),
        startedAt: .init(epochMilliseconds: 2_000),
        lastActivityAt: .init(epochMilliseconds: 1_000),
        endedAt: nil,
        actionCount: 1,
        timeout: .oneMinute,
        endReason: nil
      )
    )

    XCTAssertThrowsError(
      try ActivitySession(
        id: UUID(),
        startedAt: .init(epochMilliseconds: 1_000),
        lastActivityAt: .init(epochMilliseconds: 2_000),
        endedAt: nil,
        actionCount: 1,
        timeout: .oneMinute,
        endReason: .recovery
      )
    )
  }
}
