import XCTest

@testable import APMXCore

final class SessionEngineTests: XCTestCase {
  private let timeout = try! SessionTimeout(milliseconds: 60_000)

  func testFirstActivityStartsSession() {
    let fixture = Fixture(timeout: timeout)

    let transitions = fixture.engine.recordActivity(countedAction: .keyDown)

    guard case .started(let session) = transitions.first else {
      return XCTFail("Expected a started transition")
    }
    XCTAssertEqual(session.startedAt.epochMilliseconds, 1_000_000)
    XCTAssertEqual(session.lastActivityAt, session.startedAt)
    XCTAssertEqual(session.actionCount, 1)
    XCTAssertEqual(session.timeout, timeout)
    XCTAssertNil(session.endedAt)
    XCTAssertEqual(
      fixture.engine.nextDeadline,
      MonotonicInstant(uptimeMilliseconds: 70_000)
    )
  }

  func testEvidenceBeforeDeadlineExtendsSameSession() {
    let fixture = Fixture(timeout: timeout)
    fixture.engine.recordActivity(countedAction: .keyDown)
    let originalID = fixture.engine.openSession?.id
    fixture.advance(milliseconds: 59_999)

    let transitions = fixture.engine.recordActivity(countedAction: .mouseButtonDown)

    guard case .updated(let session) = transitions.first else {
      return XCTFail("Expected an updated transition")
    }
    XCTAssertEqual(session.id, originalID)
    XCTAssertEqual(session.lastActivityAt.epochMilliseconds, 1_059_999)
    XCTAssertEqual(session.actionCount, 2)
    XCTAssertEqual(
      fixture.engine.nextDeadline?.uptimeMilliseconds,
      129_999
    )
    XCTAssertTrue(fixture.engine.completedSessions.isEmpty)
  }

  func testEvidenceCanExtendLeaseWithoutCountingAction() {
    let fixture = Fixture(timeout: timeout)
    fixture.engine.recordActivity(countedAction: .scroll)
    fixture.advance(milliseconds: 10_000)

    fixture.engine.recordActivity(countedAction: nil)

    XCTAssertEqual(fixture.engine.openSession?.actionCount, 1)
    XCTAssertEqual(
      fixture.engine.openSession?.lastActivityAt.epochMilliseconds,
      1_010_000
    )
  }

  func testEvidenceExactlyAtDeadlineEndsOldSessionAndStartsNewSession() {
    let fixture = Fixture(timeout: timeout)
    fixture.engine.recordActivity(countedAction: .keyDown)
    let firstID = fixture.engine.openSession?.id
    fixture.advance(milliseconds: 60_000)

    let transitions = fixture.engine.recordActivity(countedAction: .scroll)

    XCTAssertEqual(transitions.count, 2)
    guard
      case .ended(let ended) = transitions[0],
      case .started(let started) = transitions[1]
    else {
      return XCTFail("Expected ended then started transitions")
    }
    XCTAssertEqual(ended.id, firstID)
    XCTAssertEqual(ended.endReason, .inactivityTimeout)
    XCTAssertEqual(ended.endedAt?.epochMilliseconds, 1_060_000)
    XCTAssertEqual(ended.durationMilliseconds, 60_000)
    XCTAssertNotEqual(started.id, firstID)
    XCTAssertEqual(started.startedAt, ended.endedAt)
    XCTAssertEqual(started.actionCount, 1)
  }

  func testEvidenceAfterDeadlinePreservesMonotonicIdleGap() {
    let fixture = Fixture(timeout: timeout)
    fixture.engine.recordActivity(countedAction: .keyDown)
    fixture.advance(milliseconds: 75_000)

    let transitions = fixture.engine.recordActivity(countedAction: .keyDown)

    guard
      case .ended(let ended) = transitions[0],
      case .started(let started) = transitions[1]
    else {
      return XCTFail("Expected ended then started transitions")
    }
    XCTAssertEqual(ended.endedAt?.epochMilliseconds, 1_060_000)
    XCTAssertEqual(started.startedAt.epochMilliseconds, 1_075_000)
  }

  func testTimeoutEndsSessionExactlyOnce() {
    let fixture = Fixture(timeout: timeout)
    fixture.engine.recordActivity(countedAction: .mouseButtonDown)
    fixture.advance(milliseconds: 60_000)

    let first = fixture.engine.expireIfNeeded()
    let second = fixture.engine.expireIfNeeded()

    guard case .ended(let session) = first else {
      return XCTFail("Expected an ended transition")
    }
    XCTAssertEqual(session.endReason, .inactivityTimeout)
    XCTAssertEqual(fixture.engine.completedSessions.count, 1)
    XCTAssertNil(second)
    XCTAssertNil(fixture.engine.openSession)
  }

  func testSingleActivityCreatesNonzeroLeaseInterval() {
    let fixture = Fixture(timeout: timeout)
    fixture.engine.recordActivity(countedAction: .mouseButtonDown)
    fixture.advance(milliseconds: 90_000)

    fixture.engine.expireIfNeeded()

    XCTAssertEqual(fixture.engine.completedSessions.first?.durationMilliseconds, 60_000)
  }

  func testLifecycleReasonsCloseEarly() {
    let reasons: [SessionEndReason] = [
      .sleep,
      .sessionInactive,
      .shutdown,
      .recovery,
    ]

    for reason in reasons {
      let fixture = Fixture(timeout: timeout)
      fixture.engine.recordActivity(countedAction: .keyDown)
      fixture.advance(milliseconds: 5_000)

      let transition = fixture.engine.close(reason: reason)

      guard case .ended(let session) = transition else {
        return XCTFail("Expected close for \(reason)")
      }
      XCTAssertEqual(session.endReason, reason)
      XCTAssertEqual(session.durationMilliseconds, 5_000)
      XCTAssertNil(fixture.engine.close(reason: reason))
    }
  }

  func testExpiredLeaseTakesPrecedenceOverLateLifecycleClose() {
    let fixture = Fixture(timeout: timeout)
    fixture.engine.recordActivity(countedAction: .keyDown)
    fixture.advance(milliseconds: 90_000)

    let transition = fixture.engine.close(reason: .sleep)

    guard case .ended(let session) = transition else {
      return XCTFail("Expected an ended transition")
    }
    XCTAssertEqual(session.endReason, .inactivityTimeout)
    XCTAssertEqual(session.durationMilliseconds, 60_000)
  }

  func testChangingTimeoutReschedulesAndStoresItOnOpenSession() throws {
    let fixture = Fixture(timeout: timeout)
    fixture.engine.recordActivity(countedAction: .keyDown)
    fixture.advance(milliseconds: 30_000)
    let longerTimeout = try SessionTimeout(milliseconds: 120_000)

    let transition = fixture.engine.updateTimeout(longerTimeout)

    guard case .updated(let session) = transition else {
      return XCTFail("Expected an updated transition")
    }
    XCTAssertEqual(session.timeout, longerTimeout)
    XCTAssertEqual(
      fixture.engine.nextDeadline?.uptimeMilliseconds,
      130_000
    )
    fixture.advance(milliseconds: 90_000)
    XCTAssertNotNil(fixture.engine.expireIfNeeded())
    XCTAssertEqual(fixture.engine.completedSessions.first?.timeout, longerTimeout)
  }

  func testShorteningTimeoutPastNowClosesAtRecomputedDeadline() throws {
    let fixture = Fixture(timeout: timeout)
    fixture.engine.recordActivity(countedAction: .keyDown)
    fixture.advance(milliseconds: 30_000)

    let transition = fixture.engine.updateTimeout(
      try SessionTimeout(milliseconds: 20_000)
    )

    guard case .ended(let session) = transition else {
      return XCTFail("Expected an ended transition")
    }
    XCTAssertEqual(session.endedAt?.epochMilliseconds, 1_020_000)
    XCTAssertEqual(session.timeout.milliseconds, 20_000)
    XCTAssertEqual(session.endReason, .inactivityTimeout)
  }

  func testWallClockRollbackCannotCreateNegativeOrOverlappingSessions() {
    let fixture = Fixture(timeout: timeout)
    fixture.engine.recordActivity(countedAction: .keyDown)
    fixture.monotonic.advance(milliseconds: 30_000)
    fixture.wall.set(milliseconds: 500_000)
    fixture.engine.recordActivity(countedAction: .mouseButtonDown)
    fixture.monotonic.advance(milliseconds: 60_000)
    fixture.wall.set(milliseconds: 100_000)

    fixture.engine.recordActivity(countedAction: .keyDown)

    XCTAssertEqual(fixture.engine.completedSessions.count, 1)
    let ended = fixture.engine.completedSessions[0]
    let next = fixture.engine.openSession!
    XCTAssertEqual(ended.durationMilliseconds, 90_000)
    XCTAssertGreaterThanOrEqual(next.startedAt, ended.endedAt!)
    XCTAssertGreaterThanOrEqual(ended.lastActivityAt, ended.startedAt)
  }

  func testWallClockJumpForwardCannotInflateDuration() {
    let fixture = Fixture(timeout: timeout)
    fixture.engine.recordActivity(countedAction: .keyDown)
    fixture.monotonic.advance(milliseconds: 5_000)
    fixture.wall.set(milliseconds: 9_000_000)

    fixture.engine.close(reason: .shutdown)

    let ended = fixture.engine.completedSessions[0]
    XCTAssertEqual(ended.lastActivityAt.epochMilliseconds, 1_000_000)
    XCTAssertEqual(ended.endedAt?.epochMilliseconds, 1_005_000)
    XCTAssertEqual(ended.durationMilliseconds, 5_000)
  }

  func testOutOfOrderMonotonicEvidenceIsIgnored() {
    let fixture = Fixture(timeout: timeout)
    fixture.engine.recordActivity(countedAction: .keyDown)
    let stale = ReducedActivity(
      evidenceAt: .init(epochMilliseconds: 2_000_000),
      monotonicTime: .init(uptimeMilliseconds: 9_999),
      countedAction: .scroll
    )

    let transitions = fixture.engine.ingest(stale)

    XCTAssertTrue(transitions.isEmpty)
    XCTAssertEqual(fixture.engine.openSession?.actionCount, 1)
    XCTAssertEqual(
      fixture.engine.openSession?.lastActivityAt.epochMilliseconds,
      1_000_000
    )
  }

  func testRestoredSessionUsesRemainingLeaseAndAcceptsNewEvidence() throws {
    let fixture = Fixture(timeout: timeout)
    let recovered = try ActivitySession(
      id: UUID(),
      startedAt: .init(epochMilliseconds: 950_000),
      lastActivityAt: .init(epochMilliseconds: 990_000),
      endedAt: nil,
      actionCount: 12,
      timeout: timeout,
      endReason: nil
    )

    XCTAssertTrue(fixture.engine.restoreOpenSession(
      recovered,
      atWallTime: .init(epochMilliseconds: 1_000_000),
      atMonotonicTime: .init(uptimeMilliseconds: 10_000)
    ))
    XCTAssertEqual(
      fixture.engine.nextDeadline,
      .init(uptimeMilliseconds: 60_000)
    )

    fixture.advance(milliseconds: 10_000)
    let transitions = fixture.engine.recordActivity(countedAction: .keyDown)

    guard case .updated(let updated) = transitions.first else {
      return XCTFail("Expected the recovered session to be updated")
    }
    XCTAssertEqual(updated.id, recovered.id)
    XCTAssertEqual(updated.actionCount, 13)
    XCTAssertEqual(updated.lastActivityAt.epochMilliseconds, 1_010_000)
  }

  func testRestoredSessionClampsRemainingLeaseAfterWallClockRollback() throws {
    let fixture = Fixture(timeout: timeout)
    let recovered = try ActivitySession(
      id: UUID(),
      startedAt: .init(epochMilliseconds: 950_000),
      lastActivityAt: .init(epochMilliseconds: 990_000),
      endedAt: nil,
      actionCount: 12,
      timeout: timeout,
      endReason: nil
    )

    XCTAssertTrue(fixture.engine.restoreOpenSession(
      recovered,
      atWallTime: .init(epochMilliseconds: 100_000),
      atMonotonicTime: .init(uptimeMilliseconds: 10_000)
    ))
    XCTAssertEqual(
      fixture.engine.nextDeadline,
      .init(uptimeMilliseconds: 70_000)
    )
  }
}

private struct Fixture {
  let wall = TestWallClock(milliseconds: 1_000_000)
  let monotonic = TestMonotonicClock(milliseconds: 10_000)
  let engine: SessionEngine

  init(timeout: SessionTimeout) {
    engine = SessionEngine(
      timeout: timeout,
      wallClock: wall,
      monotonicClock: monotonic
    )
  }

  func advance(milliseconds: Int64) {
    wall.advance(milliseconds: milliseconds)
    monotonic.advance(milliseconds: milliseconds)
  }
}
